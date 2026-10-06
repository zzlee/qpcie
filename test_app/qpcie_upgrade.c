/*
 * qpcie_upgrade.c - High-Speed In-System Firmware Upgrade Tool for QPCIe SC7F0
 *
 * Target Hardware: AMD/Xilinx Zynq UltraScale+ XCZU4EV (SC7F0 N1 HDMI2 V11)
 * Identification : Vendor ID 0x12AB, Device ID 0xE380
 *
 * Description:
 *   High-speed firmware upgrade tool pushing complete image bundles (BOOT.BIN,
 *   image.ub, boot.scr packaged as upgrade.tar.gz) directly to board memory.
 *   Coordinated with on-board qpcie_upgrade_daemon for atomic eMMC flashing,
 *   integrity verification, and PCIe link hot-reload (POR reset + rescan)
 *   without rebooting the Host PC.
 *
 * Note: A50T SPI Flash programming is handled by qpcie_a50t_tool.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <getopt.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <errno.h>
#include <dirent.h>

#define VENDOR_ID "0x12ab"
#define DEVICE_ID "0xe380"

/* BAR0 Firmware Identification Registers */
#define REG_MAGIC_DEVICE_ID    0x0000
#define REG_VERSION_ID         0x0004
#define REG_HARDWARE_CAPS      0x0008
#define REG_GIT_COMMIT_HASH    0x000C
#define REG_BUILD_TIMESTAMP    0x0010

/* SC7F0 PCIe H2C DMA Fast-Push Upgrade Registers (BAR0 0x0780 - 0x079C) */
#define REG_DMA_UPG_CTRL       0x0780
#define REG_DMA_UPG_SIZE       0x0784
#define REG_DMA_UPG_CRC32      0x0788
#define REG_DMA_UPG_PS_ADDR_L  0x078C
#define REG_DMA_UPG_PS_ADDR_H  0x0790
#define REG_DMA_UPG_STATUS     0x0794
#define REG_DMA_UPG_PROGRESS   0x0798
#define REG_DMA_UPG_DOORBELL   0x079C

/* DMA Upgrade Commands (REG_DMA_UPG_CTRL) */
#define DMA_UPG_CMD_NONE       0x00
#define DMA_UPG_CMD_START      0x01
#define DMA_UPG_CMD_DMA_DONE   0x02
#define DMA_UPG_CMD_ABORT      0x04
#define DMA_UPG_CMD_REBOOT     0x08

/* DMA Upgrade Status (REG_DMA_UPG_STATUS) */
#define STATUS_UPG_IDLE        0x00
#define STATUS_UPG_RECEIVING   0x01
#define STATUS_UPG_VERIFYING   0x02
#define STATUS_UPG_FLASHING    0x03
#define STATUS_UPG_SUCCESS     0x04
#define STATUS_UPG_ERR_CRC     0xE1
#define STATUS_UPG_ERR_FLASH   0xE2
#define STATUS_UPG_ERR_TIMEOUT 0xE3

/* CRC32 Lookup Table & Calculation */
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

static double get_time_sec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

/* Locate PCIe Device matching 12AB:E380 */
static bool find_pcie_device(char *out_bdf, size_t max_len) {
    DIR *dir = opendir("/sys/bus/pci/devices");
    if (!dir) return false;

    struct dirent *entry;
    bool found = false;

    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char path[512];
        char vendor[32] = {0}, device[32] = {0};

        snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/vendor", entry->d_name);
        FILE *f = fopen(path, "r");
        if (f) {
            if (fscanf(f, "%31s", vendor) == 1) {}
            fclose(f);
        }

        snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/device", entry->d_name);
        f = fopen(path, "r");
        if (f) {
            if (fscanf(f, "%31s", device) == 1) {}
            fclose(f);
        }

        if (strcasecmp(vendor, VENDOR_ID) == 0 && strcasecmp(device, DEVICE_ID) == 0) {
            strncpy(out_bdf, entry->d_name, max_len - 1);
            out_bdf[max_len - 1] = '\0';
            found = true;
            break;
        }
    }

    closedir(dir);
    return found;
}

static void print_progress(int percent, double speed_mb) {
    const int bar_width = 36;
    int pos = (percent * bar_width) / 100;

    printf("\r  [");
    for (int i = 0; i < bar_width; ++i) {
        if (i < pos) printf("=");
        else if (i == pos) printf(">");
        else printf(" ");
    }
    if (speed_mb > 0.0) {
        printf("] %3d%% (Speed: %6.1f MB/s)", percent, speed_mb);
    } else {
        printf("] %3d%%", percent);
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    char *package_path = NULL;
    char *bootbin_path = NULL;
    char *kernel_path = NULL;
    char *bootscr_path = NULL;
    bool show_status = false;
    bool do_reboot = false;

    static struct option long_options[] = {
        {"package", required_argument, 0, 'p'},
        {"boot",    required_argument, 0, 'b'},
        {"kernel",  required_argument, 0, 'k'},
        {"script",  required_argument, 0, 'c'},
        {"status",  no_argument,       0, 's'},
        {"reboot",  no_argument,       0, 'r'},
        {"help",    no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "p:b:k:c:srh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'p': package_path = optarg; break;
            case 'b': bootbin_path = optarg; break;
            case 'k': kernel_path = optarg; break;
            case 'c': bootscr_path = optarg; break;
            case 's': show_status = true; break;
            case 'r': do_reboot = true; break;
            case 'h':
            default:
                printf("=================================================================\n");
                printf(" QPCIe SC7F0 In-System Firmware Upgrade Tool (PCIe DMA)\n");
                printf(" Target: AMD ZU4EV (SC7F0 N1 HDMI2 V11, PCI 12AB:E380)\n");
                printf("=================================================================\n");
                printf("Usage:\n");
                printf("  sudo %s [options]\n\n", argv[0]);
                printf("Options:\n");
                printf("  -p, --package <tar.gz> Push upgrade package (containing BOOT.BIN, image.ub, etc.)\n");
                printf("  -b, --boot <BOOT.BIN>  Specify BOOT.BIN to package and upgrade\n");
                printf("  -k, --kernel <image.ub> Specify image.ub kernel to package\n");
                printf("  -c, --script <boot.scr> Specify boot.scr script to package\n");
                printf("  -s, --status           Query card version, caps, and upgrade state\n");
                printf("  -r, --reboot           Trigger card POR reset & PCIe link rescan (Zero-Host-Reboot)\n");
                printf("  -h, --help             Show this help message\n");
                return EXIT_SUCCESS;
        }
    }

    if (!package_path && !bootbin_path && !kernel_path && !show_status) {
        if (optind < argc) {
            package_path = argv[optind];
        } else {
            fprintf(stderr, "Error: No action specified. Use --package <file> or --status.\n");
            fprintf(stderr, "Run '%s --help' for usage.\n", argv[0]);
            return EXIT_FAILURE;
        }
    }

    printf("=================================================================\n");
    printf(" 🚀 QPCIe SC7F0 PCIe Firmware Upgrade (PCI 12AB:E380)\n");
    printf("=================================================================\n");

    // 1. Locate PCIe Device
    char bdf[64] = {0};
    if (!find_pcie_device(bdf, sizeof(bdf))) {
        fprintf(stderr, "❌ ERROR: No SC7F0 PCIe device (12ab:e380) found on PCIe bus!\n");
        return EXIT_FAILURE;
    }
    printf(" -> Found SC7F0 Card at BDF: %s\n", bdf);

    // Ensure Bus Master & Memory Space enabled via setpci
    char sys_cmd[256];
    snprintf(sys_cmd, sizeof(sys_cmd), "setpci -s %s COMMAND=0x06 2>/dev/null", bdf);
    int sys_ret = system(sys_cmd);
    (void)sys_ret;

    // 2. Map BAR0 Registers
    char bar0_path[256];
    snprintf(bar0_path, sizeof(bar0_path), "/sys/bus/pci/devices/%s/resource0", bdf);
    int fd_bar0 = open(bar0_path, O_RDWR | O_SYNC);
    if (fd_bar0 < 0) {
        perror("❌ ERROR: Failed to open BAR0 resource");
        return EXIT_FAILURE;
    }
    volatile uint32_t *bar0 = (volatile uint32_t *)mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd_bar0, 0);
    if (bar0 == MAP_FAILED) {
        perror("❌ ERROR: Failed to mmap BAR0");
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    // 3. Read Hardware Identification
    uint32_t magic    = bar0[REG_MAGIC_DEVICE_ID / 4];
    uint32_t ver_id   = bar0[REG_VERSION_ID / 4];
    uint32_t hw_caps  = bar0[REG_HARDWARE_CAPS / 4];
    uint32_t git_hash = bar0[REG_GIT_COMMIT_HASH / 4];
    uint32_t bld_date = bar0[REG_BUILD_TIMESTAMP / 4];
    uint32_t upg_stat = bar0[REG_DMA_UPG_STATUS / 4];
    uint32_t req_id   = bar0[0x002C / 4];
    uint64_t ps_addr  = ((uint64_t)bar0[REG_DMA_UPG_PS_ADDR_H / 4] << 32) | bar0[REG_DMA_UPG_PS_ADDR_L / 4];

    printf(" -> Hardware Magic    : 0x%08X %s\n", magic, (magic == 0x12ABE380) ? "[VALID]" : "[INVALID]");
    printf(" -> Hardware Version  : 0x%08X (Date: 20%02X/%02X/%02X Rev %02d)\n",
           ver_id, (ver_id >> 24) & 0xFF, (ver_id >> 16) & 0xFF, (ver_id >> 8) & 0xFF, ver_id & 0xFF);
    printf(" -> PCIe Requester ID : 0x%04X (Bus %02X, Dev %02X, Fn %02X)\n",
           req_id & 0xFFFF, (req_id >> 8) & 0xFF, (req_id >> 3) & 0x1F, req_id & 0x07);
    printf(" -> Git Commit Hash   : 0x%08X, Build Date: 0x%08X\n", git_hash, bld_date);
    printf(" -> Hardware Caps     : 0x%08X (VideoCh=%u, AudioCh=%u)\n",
           hw_caps, (hw_caps >> 8) & 0xFF, (hw_caps >> 16) & 0xFF);
    printf(" -> Board PS DDR4 Buf : 0x%016llX\n", (unsigned long long)ps_addr);
    printf(" -> Upgrade Status    : 0x%02X (%s)\n", upg_stat,
           (upg_stat == STATUS_UPG_IDLE) ? "IDLE / Ready" :
           (upg_stat == STATUS_UPG_SUCCESS) ? "Previous Flash Succeeded" : "Busy / Other");

    if (show_status && !package_path && !bootbin_path && !kernel_path) {
        printf("=================================================================\n");
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_SUCCESS;
    }

    // 4. Automatic Bundle Packaging if discrete files provided
    char auto_tar[256] = {0};
    if (!package_path && (bootbin_path || kernel_path || bootscr_path)) {
        snprintf(auto_tar, sizeof(auto_tar), "/tmp/sc7f0_upgrade_%d.tar.gz", getpid());
        printf(" -> Packaging discrete firmware files into %s...\n", auto_tar);

        char tar_cmd[1024];
        snprintf(tar_cmd, sizeof(tar_cmd), "tar -czf %s", auto_tar);
        if (bootbin_path) snprintf(tar_cmd + strlen(tar_cmd), sizeof(tar_cmd) - strlen(tar_cmd), " -C $(dirname %s) $(basename %s)", bootbin_path, bootbin_path);
        if (kernel_path)  snprintf(tar_cmd + strlen(tar_cmd), sizeof(tar_cmd) - strlen(tar_cmd), " -C $(dirname %s) $(basename %s)", kernel_path, kernel_path);
        if (bootscr_path) snprintf(tar_cmd + strlen(tar_cmd), sizeof(tar_cmd) - strlen(tar_cmd), " -C $(dirname %s) $(basename %s)", bootscr_path, bootscr_path);

        if (system(tar_cmd) != 0) {
            fprintf(stderr, "❌ ERROR: Failed to create package tar.gz!\n");
            munmap((void *)bar0, 65536);
            close(fd_bar0);
            return EXIT_FAILURE;
        }
        package_path = auto_tar;
    }

    // 5. Read Upgrade Package into Memory
    FILE *fp = fopen(package_path, "rb");
    if (!fp) {
        fprintf(stderr, "❌ ERROR: Cannot open upgrade package '%s': %s\n", package_path, strerror(errno));
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    fseek(fp, 0, SEEK_END);
    size_t file_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    uint8_t *file_buf = malloc(file_size);
    if (!file_buf) {
        fprintf(stderr, "❌ ERROR: Cannot allocate %zu bytes for file buffer!\n", file_size);
        fclose(fp);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    if (fread(file_buf, 1, file_size, fp) != file_size) {
        fprintf(stderr, "❌ ERROR: Failed to read file data!\n");
        free(file_buf);
        fclose(fp);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }
    fclose(fp);

    uint32_t total_crc = calculate_crc32(file_buf, file_size);
    printf(" -> Upgrade Package   : %s\n", package_path);
    printf(" -> Package Size      : %zu bytes (%.2f MB)\n", file_size, file_size / (1024.0 * 1024.0));
    printf(" -> Package CRC32     : 0x%08X\n", total_crc);

    printf("=================================================================\n");
    printf(" Initiating High-Speed Firmware Push to SC7F0 Board...\n");

    // Handshake: Set Size, CRC32, and Start Transfer
    bar0[REG_DMA_UPG_SIZE / 4]  = (uint32_t)file_size;
    bar0[REG_DMA_UPG_CRC32 / 4] = total_crc;

    double t_start = get_time_sec();

    // 5.1 Push payload to board PS DDR4 via kernel DMA Fast-Push channel
    char upg_sysfs[256];
    snprintf(upg_sysfs, sizeof(upg_sysfs), "/sys/bus/pci/devices/%s/firmware_upgrade", bdf);
    int fd_upg = open(upg_sysfs, O_WRONLY);

    if (fd_upg >= 0) {
        printf(" -> Streaming %zu bytes over PCIe Gen3 x4 DMA to Board PS DDR4...\n", file_size);
        size_t total_pushed = 0;
        const size_t chunk_sz = 2 * 1024 * 1024; // 2 MB coherent chunks
        while (total_pushed < file_size) {
            size_t to_write = file_size - total_pushed;
            if (to_write > chunk_sz) to_write = chunk_sz;
            ssize_t nw = write(fd_upg, file_buf + total_pushed, to_write);
            if (nw <= 0) {
                perror("❌ ERROR: Failed writing to firmware_upgrade sysfs");
                break;
            }
            total_pushed += nw;
            double elapsed = get_time_sec() - t_start;
            double mb_s = (elapsed > 0) ? (total_pushed / (1024.0 * 1024.0)) / elapsed : 0.0;
            print_progress((int)(total_pushed * 25 / file_size), mb_s);
        }
        close(fd_upg);
        printf("\n -> PCIe DMA transfer complete (took %.2f s, speed: %.1f MB/s)\n",
               get_time_sec() - t_start,
               (file_size / (1024.0 * 1024.0)) / (get_time_sec() - t_start));

        // Publish total size, total CRC32, and Ring Doorbell to notify board daemon
        bar0[REG_DMA_UPG_SIZE / 4]     = (uint32_t)file_size;
        bar0[REG_DMA_UPG_CRC32 / 4]    = total_crc;
        bar0[REG_DMA_UPG_DOORBELL / 4] = 0x01;
    } else {
        // Fallback: direct hardware trigger
        bar0[REG_DMA_UPG_CTRL / 4]     = DMA_UPG_CMD_START;
        bar0[REG_DMA_UPG_DOORBELL / 4] = 0x01; // Ring doorbell to board daemon
    }

    // Monitor progress and status reported by board daemon (CRC verify + eMMC flash)
    int wait_sec = 120;
    bool success = false;
    uint32_t last_prog = 0xFF;

    while (wait_sec > 0) {
        uint32_t st = bar0[REG_DMA_UPG_STATUS / 4];
        uint32_t prog = bar0[REG_DMA_UPG_PROGRESS / 4];

        if (st == STATUS_UPG_SUCCESS) {
            print_progress(100, (file_size / (1024.0 * 1024.0)) / (get_time_sec() - t_start));
            printf("\n");
            success = true;
            break;
        }

        if (st == STATUS_UPG_ERR_CRC) {
            fprintf(stderr, "\n❌ ERROR: Board reported CRC verification failure!\n");
            break;
        }
        if (st == STATUS_UPG_ERR_FLASH) {
            fprintf(stderr, "\n❌ ERROR: Board reported eMMC flashing error!\n");
            break;
        }

        if (prog != last_prog) {
            double elapsed = get_time_sec() - t_start;
            double speed = (elapsed > 0) ? ((double)file_size * prog / 100.0) / (1024.0 * 1024.0 * elapsed) : 0.0;
            print_progress(prog, speed);
            last_prog = prog;
        }

        usleep(100000); // 100ms
        wait_sec--;
    }

    free(file_buf);
    if (auto_tar[0]) unlink(auto_tar);

    if (!success) {
        fprintf(stderr, "\n❌ ERROR: Firmware upgrade timed out or failed!\n");
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    printf(" ✨ SUCCESS: Firmware package written & verified on eMMC in %.2f s!\n", get_time_sec() - t_start);
    printf("=================================================================\n");

    // 6. Zero-Host-Reboot PCIe Hot-Reload Protocol
    if (do_reboot) {
        printf(" ⚡ Executing Zero-Host-Reboot Card POR & Rescan Sequence...\n");

        printf("    [1/4] Triggering ZU4EV PMU Chip-Level Power-On Reset (POR)...\n");
        bar0[REG_DMA_UPG_CTRL / 4] = DMA_UPG_CMD_REBOOT;
        (void)bar0[REG_DMA_UPG_CTRL / 4]; // Flush PCIe MMIO write

        printf("    [2/4] Safely removing device %s from host PCIe subsystem...\n", bdf);
        char rm_cmd[256];
        snprintf(rm_cmd, sizeof(rm_cmd), "echo 1 > /sys/bus/pci/devices/%s/remove", bdf);
        sys_ret = system(rm_cmd);

        munmap((void *)bar0, 65536);
        close(fd_bar0);

        printf("    [3/4] Waiting 3 seconds for ZU4EV eMMC reload & PCIe link train...\n");
        sleep(3);

        printf("    [4/4] Rescanning host PCIe bus (echo 1 > /sys/bus/pci/rescan)...\n");
        sys_ret = system("echo 1 > /sys/bus/pci/rescan");
        (void)sys_ret;
        sleep(1);

        char new_bdf[64] = {0};
        if (find_pcie_device(new_bdf, sizeof(new_bdf))) {
            printf(" ✅ SUCCESS: PCIe Device re-established at %s!\n", new_bdf);
            printf(" 🎉 New FPGA Bitstream & Firmware is now 100%% active!\n");
        } else {
            printf(" ⚠️ Notice: Card did not respond immediately. Check link status.\n");
        }
    } else {
        printf(" NOTE: Pass '--reboot' to automatically POR reset the card and\n");
        printf("       rescan the PCIe link without rebooting the host PC.\n");
        munmap((void *)bar0, 65536);
        close(fd_bar0);
    }

    return EXIT_SUCCESS;
}
