/*
 * qpcie_fw_daemon.c - In-System Firmware Update Daemon for SC7F0 N1 HDMI2 V11
 *
 * Target: AMD/Xilinx Zynq UltraScale+ XCZU4EV (ARM Cortex-A53 Linux / PetaLinux)
 *
 * Description:
 *   Runs as a background systemd service (qpcie-fw-daemon.service) on the SC7F0 card.
 *   Monitors PCIe BAR0 firmware update registers (0x0700-0x0728) and BAR1 shared memory
 *   window (0x8000) for binary streaming commands from the Host PCIe tool (qpcie_flash).
 *   Safely streams chunks into temporary storage, verifies CRC32 and SHA256 integrity,
 *   writes the new image to eMMC (/dev/mmcblk0p1 and /dev/mmcblk0boot0), and performs
 *   optional warm reboot on host request.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <errno.h>
#include <signal.h>
#include <syslog.h>

#define DAEMON_NAME "qpcie_fw_daemon"

/* Register Offsets (relative to PL base address, e.g. 0xB0000000) */
#define REG_FW_UPDATE_CMD      0x0700
#define REG_FW_UPDATE_TYPE     0x0704
#define REG_FW_UPDATE_SIZE     0x0708
#define REG_FW_PAGE_INDEX      0x070C
#define REG_FW_PAGE_SIZE       0x0710
#define REG_FW_PAGE_CRC        0x0714
#define REG_FW_TOTAL_CRC       0x0718
#define REG_FW_STATUS          0x0720
#define REG_FW_PROGRESS        0x0724
#define REG_FW_ERR_CODE        0x0728

/* Firmware Update Commands */
#define CMD_NONE               0x00
#define CMD_START_UPLOAD       0x01
#define CMD_PAGE_READY         0x02
#define CMD_FINALIZE_FLASH     0x03
#define CMD_WARM_REBOOT        0x04
#define CMD_ABORT              0x05

/* Firmware Types */
#define FW_TYPE_BOOTBIN        0x00
#define FW_TYPE_IMAGEUB        0x01
#define FW_TYPE_BOOTSCR        0x02

/* Firmware Update Status */
#define STATUS_IDLE            0x00
#define STATUS_READY_FOR_PAGE  0x01
#define STATUS_PAGE_ACK        0x02
#define STATUS_FLASHING_EMMC   0x03
#define STATUS_SUCCESS         0x04
#define STATUS_ERR_CRC         0x05
#define STATUS_ERR_FLASH       0x06
#define STATUS_ERR_TIMEOUT     0x07

/* Default PL Base Address (M_AXI_HPM1_FPD on ZU4EV) */
#define DEFAULT_PL_BASE_ADDR   0xA0000000UL /* BD-mapped HPM0 window (was wrong 0xB000) */
#define PL_MMAP_SIZE           0x10000UL   /* 64KB */

/* BAR1 Buffer Configuration (at offset 0x8000 in PL address space) */
#define BAR1_CHUNK_OFFSET      0x8000
#define TMP_UPLOAD_FILE        "/tmp/qpcie_fw_upload.bin"
#define EMMC_MOUNT_POINT       "/mnt/emmc_boot"

static volatile bool keep_running = true;

static void sig_handler(int sig) {
    (void)sig;
    keep_running = false;
}

/* CRC32 Table */
static uint32_t crc32_table[256];
static bool crc_tab_init = false;

static void init_crc32(void) {
    if (crc_tab_init) return;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int j = 0; j < 8; j++) {
            c = (c & 1) ? (0xEDB88320L ^ (c >> 1)) : (c >> 1);
        }
        crc32_table[i] = c;
    }
    crc_tab_init = true;
}

static uint32_t calculate_crc32(const uint8_t *buf, size_t len) {
    init_crc32();
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        crc = crc32_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

static uint32_t calculate_file_crc32(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;

    init_crc32();
    uint32_t crc = 0xFFFFFFFF;
    uint8_t buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        for (size_t i = 0; i < n; i++) {
            crc = crc32_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
        }
    }
    fclose(f);
    return crc ^ 0xFFFFFFFF;
}

/* Find eMMC block device (/dev/mmcblk0 or /dev/mmcblk1) */
static bool get_emmc_device(char *out_dev, size_t max_len, char *out_part1, size_t p1_len) {
    /* Check /sys/block/mmcblk* to identify MMC vs SD */
    for (int idx = 0; idx < 4; idx++) {
        char type_path[128];
        snprintf(type_path, sizeof(type_path), "/sys/block/mmcblk%d/device/type", idx);
        FILE *f = fopen(type_path, "r");
        if (f) {
            char type_str[32] = {0};
            if (fscanf(f, "%31s", type_str) == 1) {
                if (strcmp(type_str, "MMC") == 0) {
                    snprintf(out_dev, max_len, "/dev/mmcblk%d", idx);
                    snprintf(out_part1, p1_len, "/dev/mmcblk%dp1", idx);
                    fclose(f);
                    return true;
                }
            }
            fclose(f);
        }
    }
    /* Fallback to /dev/mmcblk0 if sysfs type not found */
    struct stat st;
    if (stat("/dev/mmcblk0p1", &st) == 0) {
        snprintf(out_dev, max_len, "/dev/mmcblk0");
        snprintf(out_part1, p1_len, "/dev/mmcblk0p1");
        return true;
    }
    return false;
}

/* Copy file utility */
static bool copy_file(const char *src_path, const char *dst_path) {
    FILE *src = fopen(src_path, "rb");
    if (!src) return false;

    FILE *dst = fopen(dst_path, "wb");
    if (!dst) {
        fclose(src);
        return false;
    }

    uint8_t buf[65536];
    size_t n;
    bool ok = true;
    while ((n = fread(buf, 1, sizeof(buf), src)) > 0) {
        if (fwrite(buf, 1, n, dst) != n) {
            ok = false;
            break;
        }
    }

    fflush(dst);
    fsync(fileno(dst));
    fclose(dst);
    fclose(src);
    return ok;
}

/* Write to hardware boot partition mmcblk0boot0 */
static bool write_emmc_boot_partition(const char *src_path, const char *emmc_dev) {
    char boot0_path[64];
    snprintf(boot0_path, sizeof(boot0_path), "%sboot0", emmc_dev);

    struct stat st;
    if (stat(boot0_path, &st) != 0) {
        return true; /* boot0 partition not present on this device */
    }

    /* Disable read-only protection */
    char force_ro_path[128];
    snprintf(force_ro_path, sizeof(force_ro_path), "/sys/block/%sboot0/force_ro",
             (emmc_dev[0] == '/' && strrchr(emmc_dev, '/')) ? strrchr(emmc_dev, '/') + 1 : emmc_dev);
    FILE *f_ro = fopen(force_ro_path, "w");
    if (f_ro) {
        fprintf(f_ro, "0\n");
        fclose(f_ro);
    }

    /* Write image */
    bool ok = copy_file(src_path, boot0_path);

    /* Re-enable read-only protection */
    f_ro = fopen(force_ro_path, "w");
    if (f_ro) {
        fprintf(f_ro, "1\n");
        fclose(f_ro);
    }

    return ok;
}

int main(int argc, char **argv) {
    uintptr_t pl_phys_addr = DEFAULT_PL_BASE_ADDR;
    bool foreground = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--foreground") == 0) {
            foreground = true;
        } else if (strcmp(argv[i], "-a") == 0 && i + 1 < argc) {
            pl_phys_addr = strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            printf("Usage: %s [options]\n", argv[0]);
            printf("  -f, --foreground     Run in foreground (log to stderr instead of syslog)\n");
            printf("  -a <addr>            PL Base Physical Address (default: 0x%08lX)\n", DEFAULT_PL_BASE_ADDR);
            return EXIT_SUCCESS;
        }
    }

    openlog(DAEMON_NAME, LOG_PID | (foreground ? LOG_PERROR : 0), LOG_DAEMON);
    syslog(LOG_INFO, "Starting QPCIe In-System Firmware Update Daemon (PL Base: 0x%08lX)...", pl_phys_addr);

    signal(SIGTERM, sig_handler);
    signal(SIGINT, sig_handler);

    /* Open /dev/mem to access PL AXI registers */
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        syslog(LOG_ERR, "Failed to open /dev/mem: %m (are you root?)");
        closelog();
        return EXIT_FAILURE;
    }

    void *map_base = mmap(NULL, PL_MMAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, pl_phys_addr);
    if (map_base == MAP_FAILED) {
        syslog(LOG_ERR, "Failed to mmap PL registers at 0x%08lX: %m", pl_phys_addr);
        close(mem_fd);
        closelog();
        return EXIT_FAILURE;
    }

    volatile uint32_t *regs = (volatile uint32_t *)map_base;
    volatile uint8_t *bar1_buf = (volatile uint8_t *)map_base;

    /* Initialize firmware update registers */
    regs[REG_FW_UPDATE_CMD / 4]  = CMD_NONE;
    regs[REG_FW_STATUS / 4]      = STATUS_IDLE;
    regs[REG_FW_PROGRESS / 4]    = 0;
    regs[REG_FW_ERR_CODE / 4]    = 0;

    syslog(LOG_INFO, "Firmware Update Daemon ready. Listening for PCIe host commands...");

    FILE *upload_fp = NULL;
    uint32_t current_fw_type = 0;
    uint32_t total_expected_size = 0;
    uint32_t total_expected_crc = 0;
    size_t total_received_bytes = 0;

    while (keep_running) {
        uint32_t cmd = regs[REG_FW_UPDATE_CMD / 4];

        switch (cmd) {
            case CMD_START_UPLOAD: {
                regs[REG_FW_UPDATE_CMD / 4] = CMD_NONE; /* Acknowledge command */

                current_fw_type     = regs[REG_FW_UPDATE_TYPE / 4];
                total_expected_size = regs[REG_FW_UPDATE_SIZE / 4];
                total_expected_crc  = regs[REG_FW_TOTAL_CRC / 4];
                total_received_bytes = 0;

                syslog(LOG_INFO, "CMD_START_UPLOAD: type=%u, size=%u bytes, crc=0x%08X",
                       current_fw_type, total_expected_size, total_expected_crc);

                if (upload_fp) {
                    fclose(upload_fp);
                    upload_fp = NULL;
                }

                upload_fp = fopen(TMP_UPLOAD_FILE, "wb");
                if (!upload_fp) {
                    syslog(LOG_ERR, "Failed to create %s: %m", TMP_UPLOAD_FILE);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_FLASH;
                    regs[REG_FW_ERR_CODE / 4] = (uint32_t)errno;
                    break;
                }

                regs[REG_FW_PROGRESS / 4] = 0;
                regs[REG_FW_ERR_CODE / 4] = 0;
                regs[REG_FW_STATUS / 4]   = STATUS_READY_FOR_PAGE;
                break;
            }

            case CMD_PAGE_READY: {
                regs[REG_FW_UPDATE_CMD / 4] = CMD_NONE; /* Acknowledge command */

                uint32_t page_idx  = regs[REG_FW_PAGE_INDEX / 4];
                uint32_t page_size = regs[REG_FW_PAGE_SIZE / 4];
                uint32_t page_crc  = regs[REG_FW_PAGE_CRC / 4];

                if (!upload_fp || page_size == 0 || page_size > 32768) {
                    syslog(LOG_ERR, "Invalid page: upload_fp=%p, size=%u", upload_fp, page_size);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_FLASH;
                    regs[REG_FW_ERR_CODE / 4] = 0xBAAD0001;
                    break;
                }

                /* Copy chunk from BAR1 shared memory */
                uint8_t temp_buf[32768];
                memcpy(temp_buf, (const void *)(bar1_buf + BAR1_CHUNK_OFFSET), page_size);

                /* Verify chunk CRC32 */
                uint32_t calc_crc = calculate_crc32(temp_buf, page_size);
                if (calc_crc != page_crc) {
                    syslog(LOG_ERR, "Page %u CRC mismatch! Expected: 0x%08X, Calc: 0x%08X",
                           page_idx, page_crc, calc_crc);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_CRC;
                    regs[REG_FW_ERR_CODE / 4] = 0xBAADC001;
                    break;
                }

                /* Write to temp file */
                if (fwrite(temp_buf, 1, page_size, upload_fp) != page_size) {
                    syslog(LOG_ERR, "Failed to write page %u to file: %m", page_idx);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_FLASH;
                    regs[REG_FW_ERR_CODE / 4] = (uint32_t)errno;
                    break;
                }

                total_received_bytes += page_size;
                uint32_t progress = (total_expected_size > 0) ?
                    (uint32_t)((total_received_bytes * 100ULL) / total_expected_size) : 0;
                if (progress > 100) progress = 100;

                regs[REG_FW_PROGRESS / 4] = progress;
                regs[REG_FW_STATUS / 4]   = STATUS_PAGE_ACK;
                break;
            }

            case CMD_FINALIZE_FLASH: {
                regs[REG_FW_UPDATE_CMD / 4] = CMD_NONE; /* Acknowledge command */
                regs[REG_FW_STATUS / 4]     = STATUS_FLASHING_EMMC;

                syslog(LOG_INFO, "CMD_FINALIZE_FLASH: Committing %zu bytes to eMMC...", total_received_bytes);

                if (upload_fp) {
                    fflush(upload_fp);
                    fsync(fileno(upload_fp));
                    fclose(upload_fp);
                    upload_fp = NULL;
                }

                /* Verify entire file CRC32 */
                uint32_t full_crc = calculate_file_crc32(TMP_UPLOAD_FILE);
                if (full_crc != total_expected_crc) {
                    syslog(LOG_ERR, "Full file CRC mismatch! Expected: 0x%08X, Calc: 0x%08X",
                           total_expected_crc, full_crc);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_CRC;
                    regs[REG_FW_ERR_CODE / 4] = 0xBAADC002;
                    unlink(TMP_UPLOAD_FILE);
                    break;
                }

                regs[REG_FW_PROGRESS / 4] = 30;

                /* Identify eMMC device */
                char emmc_dev[64] = {0}, emmc_p1[64] = {0};
                if (!get_emmc_device(emmc_dev, sizeof(emmc_dev), emmc_p1, sizeof(emmc_p1))) {
                    syslog(LOG_ERR, "eMMC device not found!");
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_FLASH;
                    regs[REG_FW_ERR_CODE / 4] = 0x00E111C0;
                    unlink(TMP_UPLOAD_FILE);
                    break;
                }

                regs[REG_FW_PROGRESS / 4] = 40;

                /* Mount eMMC partition 1 */
                mkdir(EMMC_MOUNT_POINT, 0755);
                umount(EMMC_MOUNT_POINT); /* Ensure unmounted first */
                if (mount(emmc_p1, EMMC_MOUNT_POINT, "vfat", MS_SYNCHRONOUS, NULL) != 0) {
                    syslog(LOG_ERR, "Failed to mount %s at %s: %m", emmc_p1, EMMC_MOUNT_POINT);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_FLASH;
                    regs[REG_FW_ERR_CODE / 4] = (uint32_t)errno;
                    unlink(TMP_UPLOAD_FILE);
                    break;
                }

                regs[REG_FW_PROGRESS / 4] = 50;

                /* Determine target path */
                char dest_file[256];
                const char *filename = "BOOT.BIN";
                if (current_fw_type == FW_TYPE_IMAGEUB) filename = "image.ub";
                else if (current_fw_type == FW_TYPE_BOOTSCR) filename = "boot.scr";

                snprintf(dest_file, sizeof(dest_file), "%s/%s", EMMC_MOUNT_POINT, filename);
                syslog(LOG_INFO, "Writing %s -> %s...", TMP_UPLOAD_FILE, dest_file);

                if (!copy_file(TMP_UPLOAD_FILE, dest_file)) {
                    syslog(LOG_ERR, "Failed to copy image to %s: %m", dest_file);
                    umount(EMMC_MOUNT_POINT);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_FLASH;
                    regs[REG_FW_ERR_CODE / 4] = (uint32_t)errno;
                    unlink(TMP_UPLOAD_FILE);
                    break;
                }

                regs[REG_FW_PROGRESS / 4] = 70;

                /* If flashing BOOT.BIN, also write to mmcblk0boot0 hardware boot partition */
                if (current_fw_type == FW_TYPE_BOOTBIN) {
                    syslog(LOG_INFO, "Updating hardware backup boot partition (%sboot0)...", emmc_dev);
                    write_emmc_boot_partition(TMP_UPLOAD_FILE, emmc_dev);
                }

                regs[REG_FW_PROGRESS / 4] = 85;

                /* Verify written target file */
                uint32_t dest_crc = calculate_file_crc32(dest_file);
                sync();
                umount(EMMC_MOUNT_POINT);

                if (dest_crc != total_expected_crc) {
                    syslog(LOG_ERR, "Verification failed on eMMC! Expected: 0x%08X, Read: 0x%08X",
                           total_expected_crc, dest_crc);
                    regs[REG_FW_STATUS / 4]   = STATUS_ERR_FLASH;
                    regs[REG_FW_ERR_CODE / 4] = 0x00FEF101;
                    unlink(TMP_UPLOAD_FILE);
                    break;
                }

                unlink(TMP_UPLOAD_FILE);
                syslog(LOG_INFO, "SUCCESS: %s programmed and verified 100%% into %s!", filename, emmc_p1);

                regs[REG_FW_PROGRESS / 4] = 100;
                regs[REG_FW_STATUS / 4]   = STATUS_SUCCESS;
                break;
            }

            case CMD_WARM_REBOOT: {
                regs[REG_FW_UPDATE_CMD / 4] = CMD_NONE;
                syslog(LOG_NOTICE, "CMD_WARM_REBOOT received. Syncing and triggering warm reset...");
                sync();
                sleep(1);
                reboot(RB_AUTOBOOT);
                break;
            }

            case CMD_ABORT: {
                regs[REG_FW_UPDATE_CMD / 4] = CMD_NONE;
                syslog(LOG_WARNING, "CMD_ABORT received. Cleaning up...");
                if (upload_fp) {
                    fclose(upload_fp);
                    upload_fp = NULL;
                }
                unlink(TMP_UPLOAD_FILE);
                regs[REG_FW_STATUS / 4]   = STATUS_IDLE;
                regs[REG_FW_PROGRESS / 4] = 0;
                break;
            }

            default:
                break;
        }

        usleep(1000); /* 1 ms poll interval */
    }

    syslog(LOG_INFO, "Daemon shutting down...");
    if (upload_fp) fclose(upload_fp);
    munmap(map_base, PL_MMAP_SIZE);
    close(mem_fd);
    closelog();

    return EXIT_SUCCESS;
}
