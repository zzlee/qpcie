/*
 * qpcie_sanity_check.c - Post-Flash Sanity Check Utility for Artix-7 A50T qpcie
 *
 * Description: Reads and parses BAR0 registers directly via sysfs/devmem:
 *              - Vendor ID / Device ID (12AB:E380)
 *              - Bitstream Firmware Version (REG_VERSION_ID 0x30)
 *              - Git Commit Hash (REG_GIT_COMMIT_HASH 0x34)
 *              - Build Date Timestamp (REG_BUILD_TIMESTAMP 0x38)
 *              - Hardware Capabilities (REG_HARDWARE_CAPS 0x3C)
 *              - Telemetry Timers & Status Registers
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>

#define REG_MAGIC_ID         0x00
#define REG_VERSION_ID       0x04
#define REG_HARDWARE_CAPS    0x08
#define REG_GIT_COMMIT_HASH  0x0C
#define REG_BUILD_TIMESTAMP  0x10
#define REG_GLOBAL_RESET     0x14
#define REG_GLOBAL_IRQ_TOP   0x18
#define REG_GLOBAL_TIMER_L   0x1C
#define REG_GLOBAL_TIMER_H   0x20
#define REG_GLOBAL_IRQ_STAT  0x24
#define REG_GLOBAL_DMA_STAT  0x28

int main(int argc, char **argv) {
    printf("=================================================================\n");
    printf(" 💳 qpcie Artix-7 A50T Post-Flash Sanity Check Tool\n");
    printf(" Target Card: 12AB:E380\n");
    printf("=================================================================\n");

    // 1. Find PCI BDF for 12AB:E380
    FILE *fp = popen("lspci -d 12ab:e380", "r");
    if (!fp) {
        perror("Failed to execute lspci");
        return EXIT_FAILURE;
    }

    char bdf_str[64] = {0};
    if (fscanf(fp, "%63s", bdf_str) != 1) {
        printf("❌ ERROR: No qpcie card (12ab:e380) found on PCI bus!\n");
        printf("   Please run 'sudo reboot' or warm-reset PCIe slot.\n");
        pclose(fp);
        return EXIT_FAILURE;
    }
    pclose(fp);

    printf(" -> Found PCIe Card BDF: %s\n", bdf_str);

    // Enable Memory Space via setpci
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "sudo setpci -s %s COMMAND=0x06", bdf_str);
    int ret = system(cmd);
    (void)ret;

    // 2. Open sysfs resource0 path (handling domain prefix e.g. 0004:01:00.0)
    char resource_path[256];
    if (strchr(bdf_str, ':') != strrchr(bdf_str, ':')) {
        // bdf_str already has domain prefix (e.g., 0004:01:00.0)
        snprintf(resource_path, sizeof(resource_path), "/sys/bus/pci/devices/%s/resource0", bdf_str);
    } else {
        // bdf_str is bus:dev.func (e.g., 01:00.0)
        snprintf(resource_path, sizeof(resource_path), "/sys/bus/pci/devices/0000:%s/resource0", bdf_str);
    }

    int fd = open(resource_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "❌ ERROR: Failed to open %s: %s\n", resource_path, strerror(errno));
        fprintf(stderr, "   Make sure to run with root privileges (sudo).\n");
        return EXIT_FAILURE;
    }

    void *bar0_ptr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bar0_ptr == MAP_FAILED) {
        perror("❌ ERROR: Failed to mmap BAR0");
        close(fd);
        return EXIT_FAILURE;
    }

    volatile uint32_t *regs = (volatile uint32_t *)bar0_ptr;

    // 3. Read BAR0 Registers
    uint32_t magic      = regs[REG_MAGIC_ID / 4];
    uint32_t ver        = regs[REG_VERSION_ID / 4];
    uint32_t caps       = regs[REG_HARDWARE_CAPS / 4];
    uint32_t git        = regs[REG_GIT_COMMIT_HASH / 4];
    uint32_t date       = regs[REG_BUILD_TIMESTAMP / 4];
    uint32_t irq_top    = regs[REG_GLOBAL_IRQ_TOP / 4];
    uint32_t timer_lo   = regs[REG_GLOBAL_TIMER_L / 4];
    uint32_t timer_hi   = regs[REG_GLOBAL_TIMER_H / 4];
    uint32_t irq_stat   = regs[REG_GLOBAL_IRQ_STAT / 4];
    uint32_t dma_stat   = regs[REG_GLOBAL_DMA_STAT / 4];
    uint64_t timer      = ((uint64_t)timer_hi << 32) | timer_lo;

    printf("\n[1/3] BAR0 Register Verification:\n");
    printf("   • Magic Device ID  : 0x%08X  (%s)\n",
           magic, (magic == 0x12ABE380) ? "VALID" : "INVALID");
    printf("   • Version ID       : 0x%08X  -->  v%u.%u.%u (Variant %u)\n",
           ver, (ver >> 24) & 0xFF, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF);
    printf("   • Git Commit Hash  : 0x%08X\n", git);
    printf("   • Build Date       : %08X (YYYY-MM-DD)\n", date);
    printf("   • Hardware Caps    : 0x%08X  -->  %u Video Ch, %u Audio Ch (Flags 0x%02X)\n",
           caps, (caps >> 8) & 0xFF, (caps >> 16) & 0xFF, caps & 0xFF);

    printf("\n[2/3] Hardware Telemetry Check:\n");
    printf("   • Global IRQ Top   : 0x%08X\n", irq_top);
    printf("   • Global IRQ Stat  : 0x%08X\n", irq_stat);
    printf("   • Global DMA Stat  : 0x%08X\n", dma_stat);
    printf("   • 125MHz HW Timer  : %lu ticks (%.3f ms uptime)\n",
           timer, timer * 0.000008); // 125MHz = 8ns per tick

    printf("\n[3/3] Sanity Status:\n");
    if (magic == 0x12ABE380 && ver != 0xFFFFFFFF && ver != 0x00000000) {
        printf(" 🎉 SUCCESS: BAR0 Register Read & Bitstream Board ID verified 100%% clean!\n");
    } else {
        printf(" ❌ WARNING: BAR0 Register returned invalid data (Magic 0x%08X, Ver 0x%08X)!\n", magic, ver);
    }

    printf("=================================================================\n");

    munmap(bar0_ptr, 4096);
    close(fd);
    return EXIT_SUCCESS;
}
