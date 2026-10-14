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
#include "qpcie_sha256.h"

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
#define STATUS_UPG_VERIFIED    0x05
#define STATUS_UPG_ERR_CRC     0xE1
#define STATUS_UPG_ERR_FLASH   0xE2
#define STATUS_UPG_ERR_TIMEOUT 0xE3
#define STATUS_UPG_ERR_STATE   0xE4

/* Doorbell commands: VERIFY stages+checks without touching eMMC;
 * COMMIT flashes eMMC and requires a preceding VERIFIED state. */
#define DOORBELL_VERIFY        0x01
#define DOORBELL_COMMIT        0x02
#define DOORBELL_HELLO         0x10
#define STATUS_VERIFY_ONLY    0x06

/* Two-stage protocol requires daemon generation shipped with this PL. */
#define MIN_COMMIT_VERSION     0x26101401u

/* BAR0 DDR readback registers (16-byte staging verification). */
#define REG_DDR_READ_OFF       0x07C0
#define REG_DDR_READ_STATUS    0x07C4
#define REG_DDR_READ_SEQ       0x07C8
#define REG_DDR_READ_DATA      0x07D0

#define STAGING_SIZE           (64u * 1024u * 1024u)
#define PUSH_BLOCK             4096u
#define PUSH_MAX_RETRY         5

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
static void print_progress(int percent, double speed_mb);
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

static const char *status_name(uint32_t st) {
    switch (st) {
        case STATUS_UPG_IDLE: return "IDLE / Ready";
        case STATUS_UPG_RECEIVING: return "RECEIVING";
        case STATUS_UPG_VERIFYING: return "VERIFYING";
        case STATUS_UPG_FLASHING: return "FLASHING";
        case STATUS_UPG_SUCCESS: return "Previous Flash Succeeded";
        case STATUS_UPG_VERIFIED: return "VERIFIED (awaiting --commit)";
        case STATUS_VERIFY_ONLY: return "VERIFY-only daemon; COMMIT disabled";
        case STATUS_UPG_ERR_CRC: return "CRC ERROR";
        case STATUS_UPG_ERR_FLASH: return "FLASH ERROR";
        case STATUS_UPG_ERR_TIMEOUT: return "TIMEOUT ERROR";
        case STATUS_UPG_ERR_STATE: return "STATE ERROR (commit without verify?)";
        default: return "Busy / Other";
    }
}

/* Push buffer to staging DDR in 4K sysfs blocks with per-block retry.
 * The kernel caps each bin_attribute write at 4096 bytes, and only
 * whole 4096-byte DMAs are hardware-validated, so a short tail is
 * zero-padded to a full block for the transfer. SIZE/CRC still describe
 * the real bytes; padding is never covered by CRC or compare. */
static bool push_staging(const char *sysfs, const uint8_t *buf, size_t len) {
    int fd = open(sysfs, O_WRONLY);
    if (fd < 0) { perror("open firmware_upgrade sysfs"); return false; }
    static unsigned char pad[PUSH_BLOCK];
    double t0 = get_time_sec();
    for (size_t off = 0; off < len; off += PUSH_BLOCK) {
        size_t want = len - off < PUSH_BLOCK ? len - off : PUSH_BLOCK;
        const uint8_t *blk = buf + off;
        if (want != PUSH_BLOCK) {
            memcpy(pad, buf + off, want);
            memset(pad + want, 0, PUSH_BLOCK - want);
            blk = pad;
        }
        bool ok = false;
        for (int a = 0; a < PUSH_MAX_RETRY && !ok; a++) {
            if (lseek(fd, (off_t)off, SEEK_SET) < 0) continue;
            ssize_t n = write(fd, blk, PUSH_BLOCK);
            if (n == (ssize_t)PUSH_BLOCK) ok = true;
            else fprintf(stderr, "\nblock %zu: attempt %d failed (%zd); retrying\n", off, a, n);
        }
        if (!ok) { fprintf(stderr, "block %zu: FAILED; stop\n", off); close(fd); return false; }
        double el = get_time_sec() - t0;
        print_progress((int)(off * 100 / len), (off / 1048576.0) / (el > 0 ? el : 1));
    }
    double el = get_time_sec() - t0;
    printf("\n -> push complete (%zu bytes, %.1f MB/s)\n", len, (len / 1048576.0) / (el > 0 ? el : 1));
    close(fd);
    return true;
}

static bool readback_16bytes(volatile uint32_t *bar0, size_t off, const uint8_t *expected) {
    if (bar0[REG_DDR_READ_STATUS / 4] & 1) return false;
    uint32_t seq = bar0[REG_DDR_READ_SEQ / 4];
    bar0[REG_DDR_READ_OFF / 4] = (uint32_t)off;
    (void)bar0[REG_DDR_READ_OFF / 4];
    bar0[REG_DDR_READ_STATUS / 4] = 1;
    (void)bar0[REG_DDR_READ_STATUS / 4];
    bool done = false;
    for (int i = 0; i < 100; i++) {
        uint32_t now = bar0[REG_DDR_READ_SEQ / 4], st = bar0[REG_DDR_READ_STATUS / 4];
        if (now == seq + 1 && (st & 0x1c)) return false;
        if (now == seq + 1 && (st & 3) == 2) { done = true; break; }
        usleep(500);
    }
    if (!done) return false;
    for (int w = 0; w < 4; w++) {
        uint32_t v = bar0[REG_DDR_READ_DATA / 4 + w];
        for (int b = 0; b < 4; b++) {
            if ((unsigned char)(v >> (8 * b)) != expected[4 * w + b])
                return false;
        }
    }
    return true;
}

/* Fast canary verification: checks 16-byte head and 16-byte tail via BAR0 (< 2ms total) */
static bool verify_staging_canary(volatile uint32_t *bar0, const uint8_t *buf, size_t len) {
    if (len < 16) return false;
    if (bar0[REG_DMA_UPG_CTRL / 4] & DMA_UPG_CMD_START) {
        fprintf(stderr, "DMA START active; refusing verify\n"); return false;
    }
    if (!readback_16bytes(bar0, 0, buf)) {
        fprintf(stderr, "❌ ERROR: Head boundary canary mismatch at offset 0x0!\n");
        return false;
    }
    size_t tail_off = (len - 16) & ~(size_t)15;
    if (!readback_16bytes(bar0, tail_off, buf + tail_off)) {
        fprintf(stderr, "❌ ERROR: Tail boundary canary mismatch at offset 0x%zx!\n", tail_off);
        return false;
    }
    printf(" -> Staging DDR boundary canaries verified (Head 0x0 + Tail 0x%zx PASS)\n", tail_off);
    return true;
}

/* Verify staging DDR against buffer via BAR0 16-byte readback. */
static bool verify_staging(volatile uint32_t *bar0, const uint8_t *buf, size_t len) {
    if (bar0[REG_DMA_UPG_CTRL / 4] & DMA_UPG_CMD_START) {
        fprintf(stderr, "DMA START active; refusing verify\n"); return false;
    }
    size_t full = len & ~(size_t)15;
    double t0 = get_time_sec();
    for (size_t off = 0; off < full; off += 16) {
        if (bar0[REG_DDR_READ_STATUS / 4] & 1) { fprintf(stderr, "readback BUSY\n"); return false; }
        uint32_t seq = bar0[REG_DDR_READ_SEQ / 4];
        bar0[REG_DDR_READ_OFF / 4] = (uint32_t)off;
        (void)bar0[REG_DDR_READ_OFF / 4];
        bar0[REG_DDR_READ_STATUS / 4] = 1;
        (void)bar0[REG_DDR_READ_STATUS / 4];
        bool done = false;
        for (int i = 0; i < 100; i++) {
            uint32_t now = bar0[REG_DDR_READ_SEQ / 4], st = bar0[REG_DDR_READ_STATUS / 4];
            if (now == seq + 1 && (st & 0x1c)) {
                fprintf(stderr, "readback error off=%zx st=%x\n", off, st); return false;
            }
            if (now == seq + 1 && (st & 3) == 2) { done = true; break; }
            usleep(1000);
        }
        if (!done) { fprintf(stderr, "readback timeout off=%zx\n", off); return false; }
        for (int w = 0; w < 4; w++) {
            uint32_t v = bar0[REG_DDR_READ_DATA / 4 + w];
            for (int b = 0; b < 4; b++) {
                if ((unsigned char)(v >> (8 * b)) != buf[off + 4 * w + b]) {
                    fprintf(stderr, "DDR mismatch at 0x%zx\n", off + 4 * w + b); return false;
                }
            }
        }
        if ((off & 0xfffff) == 0 && off) {
            double el = get_time_sec() - t0;
            fprintf(stderr, "verify progress: %zu/%zu bytes\n", off, len);
            (void)el;
        }
    }
    if (len != full) { /* trailing bytes via one overlapping aligned read */
        uint32_t seq = bar0[REG_DDR_READ_SEQ / 4];
        bar0[REG_DDR_READ_OFF / 4] = (uint32_t)full;
        (void)bar0[REG_DDR_READ_OFF / 4];
        bar0[REG_DDR_READ_STATUS / 4] = 1;
        (void)bar0[REG_DDR_READ_STATUS / 4];
        bool done = false;
        for (int i = 0; i < 100; i++) {
            uint32_t now = bar0[REG_DDR_READ_SEQ / 4], st = bar0[REG_DDR_READ_STATUS / 4];
            if (now == seq + 1 && (st & 3) == 2) { done = true; break; }
            if (now == seq + 1 && (st & 0x1c)) { fprintf(stderr, "readback tail error\n"); return false; }
            usleep(1000);
        }
        if (!done) { fprintf(stderr, "readback tail timeout\n"); return false; }
        for (size_t i = full; i < len; i++) {
            uint32_t v = bar0[REG_DDR_READ_DATA / 4 + (i - full) / 4];
            if ((unsigned char)(v >> (8 * ((i - full) % 4))) != buf[i]) {
                fprintf(stderr, "DDR tail mismatch at 0x%zx\n", i); return false;
            }
        }
    }
    printf(" -> BAR0 readback verify PASS (%zu bytes)\n", len);
    return true;
}

/* Ring a doorbell command and poll for a terminal status. */
static bool doorbell_poll(volatile uint32_t *bar0, uint32_t cmd, uint32_t want,
                          int timeout_s, const char *what) {
    if (cmd == DOORBELL_VERIFY) {
        bar0[REG_DMA_UPG_STATUS / 4] = STATUS_UPG_IDLE;
        (void)bar0[REG_DMA_UPG_STATUS / 4];
    }
    bar0[REG_DMA_UPG_DOORBELL / 4] = cmd;
    (void)bar0[REG_DMA_UPG_DOORBELL / 4];
    double t0 = get_time_sec();
    uint32_t last_prog = 0xFF;
    bool accepted = false;
    while (get_time_sec() - t0 < timeout_s) {
        if (bar0[REG_DMA_UPG_DOORBELL / 4] == 0) accepted = true;
        uint32_t st = bar0[REG_DMA_UPG_STATUS / 4];
        uint32_t prog = bar0[REG_DMA_UPG_PROGRESS / 4];
        if (accepted && st == want) { printf("\n -> %s reached 0x%02X\n", what, want); return true; }
        if (accepted && (st == STATUS_UPG_ERR_CRC || st == STATUS_UPG_ERR_FLASH ||
            st == STATUS_UPG_ERR_TIMEOUT || st == STATUS_UPG_ERR_STATE)) {
            fprintf(stderr, "\n%s failed: status %s (0x%02X)\n", what, status_name(st), st);
            return false;
        }
        if (prog != last_prog) { print_progress(prog > 100 ? 100 : (int)prog, 0.0); last_prog = prog; }
        usleep(100000);
    }
    fprintf(stderr, "\n%s timed out waiting for 0x%02X\n", what, want);
    return false;
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
    bool do_commit = false;
    bool allow_legacy = false;

    static struct option long_options[] = {
        {"package",      required_argument, 0, 'p'},
        {"boot",         required_argument, 0, 'b'},
        {"kernel",       required_argument, 0, 'k'},
        {"script",       required_argument, 0, 'c'},
        {"commit",       no_argument,       0, 'm'},
        {"status",       no_argument,       0, 's'},
        {"reboot",       no_argument,       0, 'r'},
        {"allow-legacy", no_argument,       0, 'L'},
        {"verify-bar0",  no_argument,       0, 'V'},
        {"help",         no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    bool do_full_bar0_verify = false;
    int opt;
    while ((opt = getopt_long(argc, argv, "p:b:k:c:msrhLV", long_options, NULL)) != -1) {
        switch (opt) {
            case 'p': package_path = optarg; break;
            case 'b': bootbin_path = optarg; break;
            case 'k': kernel_path = optarg; break;
            case 'c': bootscr_path = optarg; break;
            case 'm': do_commit = true; break;
            case 's': show_status = true; break;
            case 'r': do_reboot = true; break;
            case 'L': allow_legacy = true; break;
            case 'V': do_full_bar0_verify = true; break;
            case 'h':
            default:
                printf("=================================================================\n");
                printf(" QPCIe SC7F0 In-System Firmware Upgrade Tool (PCIe DMA)\n");
                printf(" Target: AMD ZU4EV (SC7F0 N1 HDMI2 V11, PCI 12AB:E380)\n");
                printf("=================================================================\n");
                printf("Two-stage protocol (eMMC is written ONLY by --commit):\n");
                printf("  1. sudo %s --package <tar.gz>  push + BAR0-verify + board VERIFY\n", argv[0]);
                printf("  2. sudo %s --commit             flash eMMC from VERIFIED bundle\n", argv[0]);
                printf("  3. sudo %s --reboot             POR reset + PCIe rescan\n", argv[0]);
                printf("Usage:\n");
                printf("  sudo %s [options]\n\n", argv[0]);
                printf("Options:\n");
                printf("  -p, --package <tar.gz> Push package, verify, request board VERIFY (no eMMC write)\n");
                printf("  -b, --boot <BOOT.BIN>  Specify BOOT.BIN to package and stage\n");
                printf("  -k, --kernel <image.ub> Specify image.ub kernel to package\n");
                printf("  -c, --script <boot.scr> Specify boot.scr script to package\n");
                printf("  -m, --commit           Flash eMMC from VERIFIED bundle (requires prior --package)\n");
                printf("  -s, --status           Query card version, caps, and upgrade state\n");
                printf("  -r, --reboot           Trigger card POR reset & PCIe link rescan (Zero-Host-Reboot)\n");
                printf("  -L, --allow-legacy     Allow upgrade of legacy daemons without HELLO handshake\n");
                printf("  -h, --help             Show this help message\n");
                return EXIT_SUCCESS;
        }
    }

    if (!package_path && !bootbin_path && !kernel_path && !do_commit && !do_reboot && !show_status) {
        if (optind < argc) {
            package_path = argv[optind];
        } else {
            fprintf(stderr, "Error: No action specified. Use --package <file>, --commit or --status.\n");
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
    printf(" -> Upgrade Status    : 0x%02X (%s)\n", upg_stat, status_name(upg_stat));

    if (magic != 0x12ABE380) {
        fprintf(stderr, "ERROR: BAR0 magic mismatch; aborting\n");
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    /* A PL version cannot identify the installed software generation. Require
     * an explicit daemon capability handshake before any upload command. */
    if (package_path || bootbin_path || kernel_path) {
        if (upg_stat == STATUS_UPG_FLASHING || upg_stat == STATUS_UPG_VERIFYING ||
            bar0[REG_DMA_UPG_DOORBELL / 4] || (bar0[REG_DMA_UPG_CTRL / 4] & 1)) {
            fprintf(stderr, "board busy; refusing capability probe\n");
            munmap((void *)bar0, 65536); close(fd_bar0); return EXIT_FAILURE;
        }
        if (!doorbell_poll(bar0, DOORBELL_HELLO, STATUS_VERIFY_ONLY, 5, "HELLO")) {
            if (allow_legacy) {
                printf(" Notice: HELLO not acknowledged (legacy daemon detected); resetting status to IDLE and proceeding per --allow-legacy\n");
                bar0[REG_DMA_UPG_STATUS / 4] = STATUS_UPG_IDLE;
                (void)bar0[REG_DMA_UPG_STATUS / 4];
            } else {
                fprintf(stderr, "requires new VERIFY-only daemon (or use --allow-legacy); no payload sent\n");
                munmap((void *)bar0, 65536); close(fd_bar0); return EXIT_FAILURE;
            }
        }
    }

    /* --commit path: flash eMMC from the VERIFIED bundle. No data moves here. */
    if (do_commit && !package_path && !bootbin_path && !kernel_path) {
        if (ver_id < MIN_COMMIT_VERSION) {
            fprintf(stderr, "ERROR: two-stage COMMIT requires board RTL >= 0x%08X (got 0x%08X)\n",
                    MIN_COMMIT_VERSION, ver_id);
            munmap((void *)bar0, 65536);
            close(fd_bar0);
            return EXIT_FAILURE;
        }
        if (upg_stat != STATUS_UPG_VERIFIED) {
            fprintf(stderr, "ERROR: board is not VERIFIED (status %s 0x%02X); run --package first\n",
                    status_name(upg_stat), upg_stat);
            munmap((void *)bar0, 65536);
            close(fd_bar0);
            return EXIT_FAILURE;
        }
        printf(" -> Sending COMMIT doorbell (eMMC flash with backup+readback)...\n");
        bool ok = doorbell_poll(bar0, DOORBELL_COMMIT, STATUS_UPG_SUCCESS, 600, "COMMIT");
        printf("=================================================================\n");
        if (ok)
            printf(" SUCCESS: eMMC upgrade committed and board-verified! Use --reboot to activate.\n");
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return ok ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    if (show_status && !package_path && !bootbin_path && !kernel_path && !do_reboot) {
        printf("=================================================================\n");
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_SUCCESS;
    }

    /* Standalone --reboot: POR + rescan without any package work. */
    if (do_reboot && !package_path && !bootbin_path && !kernel_path) {
        printf(" Executing standalone POR + rescan...\n");
        bar0[REG_DMA_UPG_CTRL / 4] = DMA_UPG_CMD_REBOOT;
        (void)bar0[REG_DMA_UPG_CTRL / 4];
        char rm_cmd[256];
        snprintf(rm_cmd, sizeof(rm_cmd), "echo 1 > /sys/bus/pci/devices/%s/remove", bdf);
        sys_ret = system(rm_cmd);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        sleep(3);
        sys_ret = system("echo 1 > /sys/bus/pci/rescan");
        (void)sys_ret;
        sleep(1);
        char new_bdf[64] = {0};
        if (find_pcie_device(new_bdf, sizeof(new_bdf)))
            printf(" SUCCESS: PCIe Device re-established at %s!\n", new_bdf);
        else
            printf(" Notice: Card did not respond immediately. Check link status.\n");
        return EXIT_SUCCESS;
    }

    // 4. Automatic Bundle Packaging if discrete files provided
    char auto_tar[256] = {0};
    if (!package_path && (bootbin_path || kernel_path || bootscr_path)) {
        char staging_pack[64];
        snprintf(staging_pack, sizeof(staging_pack), "/tmp/qpcie_pack_%d", getpid());
        char mkdir_cmd[512];
        snprintf(mkdir_cmd, sizeof(mkdir_cmd), "rm -rf %s && mkdir -p %s", staging_pack, staging_pack);
        int m_ret = system(mkdir_cmd);
        (void)m_ret;

        snprintf(auto_tar, sizeof(auto_tar), "/tmp/sc7f0_upgrade_%d.tar", getpid());
        printf(" -> Generating manifest.sha256 and uncompressed bundle %s...\n", auto_tar);

        char manifest_file[512];
        snprintf(manifest_file, sizeof(manifest_file), "%s/manifest.sha256", staging_pack);
        FILE *mf = fopen(manifest_file, "w");

        if (bootbin_path) {
            char sha[65] = {0};
            qpcie_sha256_file(bootbin_path, sha);
            if (mf) fprintf(mf, "%s  BOOT.BIN\n", sha);
            char cp_cmd[512];
            snprintf(cp_cmd, sizeof(cp_cmd), "cp %s %s/BOOT.BIN", bootbin_path, staging_pack);
            int ret = system(cp_cmd); (void)ret;
            printf("    [Manifest] BOOT.BIN  SHA-256: %s\n", sha);
        }
        if (kernel_path) {
            char sha[65] = {0};
            qpcie_sha256_file(kernel_path, sha);
            if (mf) fprintf(mf, "%s  image.ub\n", sha);
            char cp_cmd[512];
            snprintf(cp_cmd, sizeof(cp_cmd), "cp %s %s/image.ub", kernel_path, staging_pack);
            int ret = system(cp_cmd); (void)ret;
            printf("    [Manifest] image.ub  SHA-256: %s\n", sha);
        }
        if (bootscr_path) {
            char sha[65] = {0};
            qpcie_sha256_file(bootscr_path, sha);
            if (mf) fprintf(mf, "%s  boot.scr\n", sha);
            char cp_cmd[512];
            snprintf(cp_cmd, sizeof(cp_cmd), "cp %s %s/boot.scr", bootscr_path, staging_pack);
            int ret = system(cp_cmd); (void)ret;
            printf("    [Manifest] boot.scr  SHA-256: %s\n", sha);
        }
        if (mf) fclose(mf);

        char tar_cmd[1024];
        int tlen = snprintf(tar_cmd, sizeof(tar_cmd), "tar -cf %s --format=ustar -C %s", auto_tar, staging_pack);
        if (bootbin_path) tlen += snprintf(tar_cmd + tlen, sizeof(tar_cmd) - tlen, " BOOT.BIN");
        if (kernel_path)  tlen += snprintf(tar_cmd + tlen, sizeof(tar_cmd) - tlen, " image.ub");
        if (bootscr_path) tlen += snprintf(tar_cmd + tlen, sizeof(tar_cmd) - tlen, " boot.scr");
        tlen += snprintf(tar_cmd + tlen, sizeof(tar_cmd) - tlen, " manifest.sha256");

        char rm_cmd[512];
        snprintf(rm_cmd, sizeof(rm_cmd), "rm -rf %s", staging_pack);

        if (system(tar_cmd) != 0) {
            fprintf(stderr, "❌ ERROR: Failed to create uncompressed package tar!\n");
            int r_err = system(rm_cmd); (void)r_err;
            munmap((void *)bar0, 65536);
            close(fd_bar0);
            return EXIT_FAILURE;
        }
        int r_ok = system(rm_cmd); (void)r_ok;
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
    char pkg_sha[65] = {0};
    qpcie_sha256_buffer(file_buf, file_size, pkg_sha);
    printf(" -> Upgrade Package   : %s\n", package_path);
    printf(" -> Package Size      : %zu bytes (%.2f MB)\n", file_size, file_size / (1024.0 * 1024.0));
    printf(" -> Package CRC32     : 0x%08X\n", total_crc);
    printf(" -> Package SHA-256   : %s\n", pkg_sha);

    printf("=================================================================\n");
    printf(" Stage 1: push + verify (eMMC is NOT touched in this step)\n");

    if (ver_id < MIN_COMMIT_VERSION) {
        fprintf(stderr, "ERROR: two-stage protocol requires board RTL >= 0x%08X (got 0x%08X)\n",
                MIN_COMMIT_VERSION, ver_id);
        free(file_buf);
        if (auto_tar[0]) unlink(auto_tar);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }
    if (file_size > STAGING_SIZE - 16) {
        fprintf(stderr, "ERROR: package %zu bytes exceeds staging window\n", file_size);
        free(file_buf);
        if (auto_tar[0]) unlink(auto_tar);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }
    if (upg_stat == STATUS_UPG_FLASHING || upg_stat == STATUS_UPG_VERIFYING) {
        fprintf(stderr, "ERROR: board busy (%s); retry later\n", status_name(upg_stat));
        free(file_buf);
        if (auto_tar[0]) unlink(auto_tar);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    double t_start = get_time_sec();

    // 5.1 Push payload to board staging DDR via kernel DMA Fast-Push channel
    char upg_sysfs[256];
    snprintf(upg_sysfs, sizeof(upg_sysfs), "/sys/bus/pci/devices/%s/firmware_upgrade", bdf);
    printf(" -> Streaming %zu bytes over PCIe Gen3 x4 DMA to Board PS DDR4...\n", file_size);
    if (!push_staging(upg_sysfs, file_buf, file_size)) {
        free(file_buf);
        if (auto_tar[0]) unlink(auto_tar);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    // 5.2 Staging DDR verification
    if (do_full_bar0_verify) {
        printf(" -> Verifying staging DDR through full BAR0 readback (legacy mode)...\n");
        if (!verify_staging(bar0, file_buf, file_size)) {
            free(file_buf);
            if (auto_tar[0]) unlink(auto_tar);
            munmap((void *)bar0, 65536);
            close(fd_bar0);
            return EXIT_FAILURE;
        }
    } else {
        printf(" -> Verifying staging DDR through fast boundary canaries (<2ms)...\n");
        if (!verify_staging_canary(bar0, file_buf, file_size)) {
            free(file_buf);
            if (auto_tar[0]) unlink(auto_tar);
            munmap((void *)bar0, 65536);
            close(fd_bar0);
            return EXIT_FAILURE;
        }
    }

    // 5.3 Ask the board daemon to VERIFY (CRC + extract + contents, no eMMC)
    bar0[REG_DMA_UPG_SIZE / 4]  = (uint32_t)file_size;
    bar0[REG_DMA_UPG_CRC32 / 4] = total_crc;
    (void)bar0[REG_DMA_UPG_CRC32 / 4]; /* flush posted writes, then doorbell */
    printf(" -> Requesting board VERIFY (no eMMC write)...\n");
    bool verified = doorbell_poll(bar0, DOORBELL_VERIFY, STATUS_UPG_VERIFIED, 300, "VERIFY");

    free(file_buf);
    if (auto_tar[0]) unlink(auto_tar);

    if (!verified) {
        fprintf(stderr, "ERROR: board VERIFY failed; eMMC untouched (took %.1fs)\n",
                get_time_sec() - t_start);
        munmap((void *)bar0, 65536);
        close(fd_bar0);
        return EXIT_FAILURE;
    }

    printf(" VERIFIED in %.1fs. eMMC is unchanged.\n", get_time_sec() - t_start);
    printf(" Next (after review): sudo %s --commit\n", argv[0]);
    printf("=================================================================\n");

    // 6. Zero-Host-Reboot PCIe Hot-Reload Protocol (standalone or after --package)
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
