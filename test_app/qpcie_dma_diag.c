/* Read-only BAR0 H2C stage evidence; --clear explicitly arms the next canary.
 * No DMA doorbell or eMMC write exists in this tool. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define REG_MAGIC     0x000
#define REG_VERSION   0x004
#define REG_DMASTAT   0x028
#define REG_CTRL      0x780
#define REG_SIZE      0x784
#define REG_STATUS    0x794
#define REG_BYTES     0x7a8
#define REG_PCIE_DIAG 0x7b0
#define REG_PL_DIAG   0x7b4
#define REG_CLEAR     0x7b8

static const char *const pcie_flags[] = {
    "start_sync", "descriptor_pending", "descriptor_accepted", "MRd_valid",
    "MRd_ack", "RQ_handshake", "RC_handshake", "H2C_completion",
    "loopback_valid", "loopback_accepted", "engine_busy", "engine_bytes_nonzero",
    "CDC_input_ready"
};
static const char *const pl_flags[] = {
    "start", "CDC_output_valid", "CDC_output_accepted", "HP0_AW_valid",
    "HP0_AW_handshake", "HP0_W_valid", "HP0_W_handshake", "HP0_WLAST",
    "HP0_B_valid", "HP0_B_handshake", "HP0_B_error", "writer_done",
    "writer_bytes_nonzero", "PL_reset_released"
};
static void print_bits(const char *title, uint32_t bits, const char *const *names, size_t count) {
    printf("%s=0x%08x\n", title, bits);
    for (size_t i = 0; i < count; i++)
        if (bits & (1u << i)) printf("  bit %zu: %s\n", i, names[i]);
}
int main(int argc, char **argv) {
    if (argc < 2 || argc > 3 || (argc == 3 && strcmp(argv[2], "--clear"))) {
        fprintf(stderr, "usage: %s /sys/bus/pci/devices/0000:BB:DD.F/resource0 [--clear]\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], argc == 3 ? O_RDWR | O_SYNC : O_RDONLY | O_SYNC);
    if (fd < 0) { perror("resource0"); return 1; }
    volatile uint32_t *r = mmap(NULL, 0x10000, argc == 3 ? PROT_READ | PROT_WRITE : PROT_READ,
                                MAP_SHARED, fd, 0);
    if (r == MAP_FAILED) { perror("mmap resource0"); close(fd); return 1; }
    int rc = 1;
    if (r[REG_MAGIC/4] != 0x12abe380 ||
        (r[REG_VERSION/4] != 0x26101205 && r[REG_VERSION/4] != 0x26101206)) {
        fprintf(stderr, "diagnostic RTL not installed: magic=%08x version=%08x\n",
                r[REG_MAGIC/4], r[REG_VERSION/4]);
        goto out;
    }
    printf("VERSION=%08x\n", r[REG_VERSION/4]);
    if (argc == 3) {
        if (r[REG_CTRL/4] & 1) {
            fprintf(stderr, "refusing to clear during active DMA START\n");
            goto out;
        }
        uint32_t old_toggle = r[REG_CLEAR/4] & 1;
        r[REG_CLEAR/4] = 1;
        (void)r[REG_CLEAR/4]; // fence posted MMIO write
        int acked = 0;
        for (int i = 0; i < 100; i++) {
            uint32_t state = r[REG_CLEAR/4];
            if ((state & 1) != old_toggle && ((state >> 1) & 1) == (state & 1)) {
                acked = 1;
                break;
            }
            struct timespec delay = {.tv_nsec = 1000000};
            nanosleep(&delay, NULL);
        }
        if (!acked) { fprintf(stderr, "clear ACK timeout; do not run canary\n"); goto out; }
        struct timespec settle = {.tv_nsec = 10000000};
        nanosleep(&settle, NULL); // let both sticky CDC stages settle
        if (r[REG_PCIE_DIAG/4] || (r[REG_PL_DIAG/4] & ~(1u << 13))) {
            fprintf(stderr, "sticky event(s) remained set after clear; do not run canary\n");
            goto out;
        }
        puts("DIAG_CLEAR_ACK: stage record reset; safe to run one 4096-byte canary");
    }
    printf("DMASTAT=%08x CTRL=%08x SIZE=%u STATUS=%08x BYTES=%u CLEAR=%x\n",
           r[REG_DMASTAT/4], r[REG_CTRL/4], r[REG_SIZE/4], r[REG_STATUS/4],
           r[REG_BYTES/4], r[REG_CLEAR/4]);
    print_bits("PCIe", r[REG_PCIE_DIAG/4], pcie_flags, sizeof pcie_flags / sizeof pcie_flags[0]);
    print_bits("Writer", r[REG_PL_DIAG/4], pl_flags, sizeof pl_flags / sizeof pl_flags[0]);
    rc = 0;
out:
    munmap((void *)r, 0x10000);
    close(fd);
    return rc;
}
