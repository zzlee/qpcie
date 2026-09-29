/*
 * qpcie_flash.c - In-System Firmware & Bitstream Update Tool over PCIe for QPCIe SC7F0
 *
 * Target: AMD/Xilinx Zynq UltraScale+ XCZU4EV (SC7F0 N1 HDMI2 V11, Vendor: 0x12AB, Device: 0xE380)
 *
 * Description:
 *   Transfers BOOT.BIN (FPGA Bitstream + FSBL + U-Boot) or image.ub (Kernel + Rootfs)
 *   directly over the PCIe bus into the card's shared memory buffer. The on-board
 *   PetaLinux daemon then writes and verifies the image onto the on-board eMMC.
 *   Optionally triggers PCIe link hot-reload to activate the new image without PC reboot.
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

/* BAR0 Firmware Update Register Offsets (0x0700 - 0x0728) */
#define REG_VERSION_ID         0x0030
#define REG_GIT_COMMIT_HASH    0x0034
#define REG_BUILD_TIMESTAMP    0x0038
#define REG_HARDWARE_CAPS      0x003C

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

/* BAR1 Buffer Configuration */
#define BAR1_CHUNK_OFFSET      0x8000  /* 32KB offset in BAR1 */
#define DEFAULT_CHUNK_SIZE     16384   /* 16 KB per page */

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

static void print_progress(size_t current, size_t total, double start_time) {
    const int bar_width = 40;
    float ratio = (float)current / total;
    int pos = (int)(ratio * bar_width);

    double elapsed = get_time_sec() - start_time;
    double speed_mb = (elapsed > 0) ? ((double)current / (1024.0 * 1024.0)) / elapsed : 0.0;

    printf("\r  [");
    for (int i = 0; i < bar_width; ++i) {
        if (i < pos) printf("=");
        else if (i == pos) printf(">");
        else printf(" ");
    }
    printf("] %3.0f%% (%5.1f / %5.1f MB) %5.1f MB/s",
           ratio * 100.0,
           (double)current / (1024.0 * 1024.0),
           (double)total / (1024.0 * 1024.0),
           speed_mb);
    fflush(stdout);
}

int main(int argc, char **argv) {
    char *bootbin_path = NULL;
    char *kernel_path = NULL;
    bool show_status = false;
    bool do_reboot = false;
    bool verbose = false;
    (void)verbose;

    static struct option long_options[] = {
        {"bootbin", required_argument, 0, 'b'},
        {"kernel",  required_argument, 0, 'k'},
        {"status",  no_argument,       0, 's'},
        {"reboot",  no_argument,       0, 'r'},
        {"verbose", no_argument,       0, 'v'},
        {"help",    no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:k:srvh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'b': bootbin_path = optarg; break;
            case 'k': kernel_path = optarg; break;
            case 's': show_status = true; break;
            case 'r': do_reboot = true; break;
            case 'v': verbose = true; break;
            case 'h':
            default:
                printf("Usage: sudo %s [options]\n", argv[0]);
                printf("Options:\n");
                printf("  -b, --bootbin <file>   Flash BOOT.BIN (Bitstream + FSBL + U-Boot) to eMMC\n");
                printf("  -k, --kernel <file>    Flash image.ub (Kernel + Rootfs) to eMMC\n");
                printf("  -s, --status           Query card status, versions and eMMC state\n");
                printf("  -r, --reboot           Trigger card warm-reboot & PCIe link rescan after flash\n");
                printf("  -v, --verbose          Enable verbose debug output\n");
                printf("  -h, --help             Show this help message\n");
                return EXIT_SUCCESS;
        }
    }

    if (!bootbin_path && !kernel_path && !show_status) {
        printf("Error: No action specified. Use --bootbin, --kernel or --status.\n");
        printf("Run '%s --help' for options.\n", argv[0]);
        return EXIT_FAILURE;
    }

    printf("=================================================================\n");
    printf(" 🚀 QPCIe In-System Firmware Update Tool over PCIe\n");
    printf(" Target: AMD ZU4EV (SC7F0 N1 HDMI2 V11, PCI 12AB:E380)\n");
    printf("=================================================================\n");

    // 1. Locate PCIe Device
    char bdf[64] = {0};
    if (!find_pcie_device(bdf, sizeof(bdf))) {
        fprintf(stderr, "❌ ERROR: No QPCIe card (12ab:e380) found on PCIe bus!\n");
        fprintf(stderr, "   Check that card is firmly seated and PCIe slot is powered.\n");
        return EXIT_FAILURE;
    }
    printf(" -> Found QPCIe Device at BDF: %s\n", bdf);

    // Ensure Bus Master & Memory Space enabled via setpci
    char sys_cmd[256];
    snprintf(sys_cmd, sizeof(sys_cmd), "setpci -s %s COMMAND=0x06 2>/dev/null", bdf);
    int sys_ret = system(sys_cmd);
    (void)sys_ret;

    // 2. Map BAR0 (Registers)
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

    // 3. Map BAR1 (Data Buffer)
    char bar1_path[256];
    snprintf(bar1_path, sizeof(bar1_path), "/sys/bus/pci/devices/%s/resource1", bdf);
    int fd_bar1 = open(bar1_path, O_RDWR | O_SYNC);
    if (fd_bar1 < 0) {
        perror("❌ ERROR: Failed to open BAR1 resource");
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }
    volatile uint8_t *bar1 = (volatile uint8_t *)mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd_bar1, 0);
    if (bar1 == MAP_FAILED) {
        perror("❌ ERROR: Failed to mmap BAR1");
        close(fd_bar1);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    // Read Version & Info
    uint32_t ver_id   = bar0[REG_VERSION_ID / 4];
    uint32_t git_hash = bar0[REG_GIT_COMMIT_HASH / 4];
    uint32_t bld_date = bar0[REG_BUILD_TIMESTAMP / 4];
    uint32_t hw_caps  = bar0[REG_HARDWARE_CAPS / 4];
    uint32_t fw_stat  = bar0[REG_FW_STATUS / 4];

    printf(" -> Current Hardware Version: v%d.%d.%d (Caps: 0x%08X)\n",
           (ver_id >> 24) & 0xFF, (ver_id >> 16) & 0xFF, (ver_id >> 8) & 0xFF, hw_caps);
    printf(" -> Active Bitstream Commit : %08X, Build Date: %08X\n", git_hash, bld_date);
    printf(" -> Current FW Update Status: 0x%02X\n", fw_stat);

    if (show_status && !bootbin_path && !kernel_path) {
        printf("=================================================================\n");
        printf(" Status Query Finished.\n");
        munmap((void *)bar1, 65536);
        close(fd_bar1);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_SUCCESS;
    }

    const char *flash_file = bootbin_path ? bootbin_path : kernel_path;
    uint32_t fw_type = bootbin_path ? FW_TYPE_BOOTBIN : FW_TYPE_IMAGEUB;
    const char *fw_name = bootbin_path ? "BOOT.BIN" : "image.ub";

    // 4. Open and verify source file
    FILE *fp = fopen(flash_file, "rb");
    if (!fp) {
        fprintf(stderr, "❌ ERROR: Cannot open file '%s': %s\n", flash_file, strerror(errno));
        return EXIT_FAILURE;
    }

    fseek(fp, 0, SEEK_END);
    size_t file_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    uint8_t *file_buf = malloc(file_size);
    if (!file_buf) {
        fprintf(stderr, "❌ ERROR: Failed to allocate %zu bytes for file buffer\n", file_size);
        fclose(fp);
        return EXIT_FAILURE;
    }

    if (fread(file_buf, 1, file_size, fp) != file_size) {
        fprintf(stderr, "❌ ERROR: Failed to read file data into memory\n");
        free(file_buf);
        fclose(fp);
        return EXIT_FAILURE;
    }
    fclose(fp);

    uint32_t total_crc = calculate_crc32(file_buf, file_size);
    printf(" -> File to flash   : %s (%s)\n", flash_file, fw_name);
    printf(" -> Size            : %zu bytes (%.2f MB)\n", file_size, file_size / (1024.0 * 1024.0));
    printf(" -> Calculated CRC32: 0x%08X\n", total_crc);

    printf("=================================================================\n");
    printf(" Initiating PCIe In-System Transfer...\n");

    // Handshake: START_UPLOAD
    bar0[REG_FW_UPDATE_TYPE / 4] = fw_type;
    bar0[REG_FW_UPDATE_SIZE / 4] = (uint32_t)file_size;
    bar0[REG_FW_TOTAL_CRC / 4]   = total_crc;
    bar0[REG_FW_UPDATE_CMD / 4]  = CMD_START_UPLOAD;

    // Wait for READY_FOR_PAGE or ACK
    int timeout_ms = 5000;
    while (timeout_ms > 0) {
        uint32_t st = bar0[REG_FW_STATUS / 4];
        if (st == STATUS_READY_FOR_PAGE || st == STATUS_IDLE) {
            break;
        }
        usleep(10000);
        timeout_ms -= 10;
    }

    // Stream pages into BAR1
    size_t chunk_size = DEFAULT_CHUNK_SIZE;
    size_t offset = 0;
    uint32_t page_idx = 0;
    double t_start = get_time_sec();

    while (offset < file_size) {
        size_t cur_chunk = (file_size - offset > chunk_size) ? chunk_size : (file_size - offset);
        uint32_t chunk_crc = calculate_crc32(&file_buf[offset], cur_chunk);

        // Copy chunk to BAR1 shared memory
        memcpy((void *)(bar1 + BAR1_CHUNK_OFFSET), &file_buf[offset], cur_chunk);

        // Write page parameters
        bar0[REG_FW_PAGE_INDEX / 4] = page_idx;
        bar0[REG_FW_PAGE_SIZE / 4]  = (uint32_t)cur_chunk;
        bar0[REG_FW_PAGE_CRC / 4]   = chunk_crc;
        bar0[REG_FW_UPDATE_CMD / 4] = CMD_PAGE_READY;

        // Wait for PAGE_ACK (with timeout)
        int ack_timeout = 2000; // 2 seconds
        bool acked = false;
        while (ack_timeout > 0) {
            uint32_t st = bar0[REG_FW_STATUS / 4];
            if (st == STATUS_PAGE_ACK || st == STATUS_READY_FOR_PAGE) {
                acked = true;
                break;
            }
            if (st == STATUS_ERR_CRC) {
                fprintf(stderr, "\n❌ ERROR: Page %u CRC mismatch reported by card!\n", page_idx);
                free(file_buf);
                return EXIT_FAILURE;
            }
            usleep(2000);
            ack_timeout -= 2;
        }

        if (!acked) {
            fprintf(stderr, "\n❌ ERROR: Timeout waiting for Page %u ACK from card!\n", page_idx);
            free(file_buf);
            return EXIT_FAILURE;
        }

        offset += cur_chunk;
        page_idx++;
        print_progress(offset, file_size, t_start);
    }
    printf("\n");

    printf(" -> All chunks streamed successfully in %.2f seconds.\n", get_time_sec() - t_start);
    printf(" -> Instructing on-board daemon to commit and verify into eMMC...\n");

    // Finalize and write eMMC
    bar0[REG_FW_UPDATE_CMD / 4] = CMD_FINALIZE_FLASH;

    int flash_timeout_sec = 60;
    bool flash_ok = false;
    while (flash_timeout_sec > 0) {
        uint32_t st = bar0[REG_FW_STATUS / 4];
        uint32_t prog = bar0[REG_FW_PROGRESS / 4];

        if (st == STATUS_SUCCESS) {
            flash_ok = true;
            break;
        }
        if (st == STATUS_ERR_FLASH || st == STATUS_ERR_CRC) {
            uint32_t err = bar0[REG_FW_ERR_CODE / 4];
            fprintf(stderr, "❌ ERROR: eMMC flash failed! Error code: 0x%08X\n", err);
            free(file_buf);
            return EXIT_FAILURE;
        }

        printf("\r  -> Writing eMMC Progress: %d%%...   ", prog);
        fflush(stdout);

        sleep(1);
        flash_timeout_sec--;
    }
    printf("\n");

    free(file_buf);

    if (!flash_ok) {
        fprintf(stderr, "❌ ERROR: Flashing eMMC timed out after 60 seconds!\n");
        return EXIT_FAILURE;
    }

    printf("=================================================================\n");
    printf(" ✨ SUCCESS: %s has been successfully written & verified in eMMC!\n", fw_name);
    printf(" Total elapsed time: %.2f seconds.\n", get_time_sec() - t_start);
    printf("=================================================================\n");

    // Optional Warm Reboot & PCIe Link Rescan
    if (do_reboot) {
        printf(" -> Initiating PCIe Link Hot-Reload Sequence...\n");
        printf("    1. Removing device %s from host PCIe subsystem...\n", bdf);

        char rm_cmd[256];
        snprintf(rm_cmd, sizeof(rm_cmd), "echo 1 > /sys/bus/pci/devices/%s/remove", bdf);
        sys_ret = system(rm_cmd);
        (void)sys_ret;

        printf("    2. Triggering ZU4EV warm reset to reload from eMMC...\n");
        bar0[REG_FW_UPDATE_CMD / 4] = CMD_WARM_REBOOT;

        munmap((void *)bar1, 65536);
        close(fd_bar1);
        munmap((void *)bar0, 65536);
        close(fd_bar0);

        printf("    3. Waiting 4 seconds for ZU4EV Tandem PCIe enumeration...\n");
        sleep(4);

        printf("    4. Rescanning PCIe bus...\n");
        sys_ret = system("echo 1 > /sys/bus/pci/rescan");
        (void)sys_ret;

        sleep(1);

        char new_bdf[64] = {0};
        if (find_pcie_device(new_bdf, sizeof(new_bdf))) {
            printf(" ✅ PCIe Link re-established at %s!\n", new_bdf);
            printf(" ✅ New FPGA bitstream & firmware is now live!\n");
        } else {
            printf(" ⚠️ Card not detected after rescan. A host reboot may be required.\n");
        }
    } else {
        printf(" NOTE: The new image will become active upon the next PCIe bus reset\n");
        printf("       or card reboot (pass '--reboot' to reload immediately).\n");
        munmap((void *)bar1, 65536);
        close(fd_bar1);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
    }

    return EXIT_SUCCESS;
}
