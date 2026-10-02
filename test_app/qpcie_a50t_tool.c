/*
 * qpcie_a50t_tool.c - QPCIe Artix-7 A50T In-System SPI Flash Programmer & Utility
 *
 * Description:
 *   High-performance host utility for Artix-7 A50T PCIe Video DMA Card:
 *   1. Displays IT68051 HDMI Receiver status.
 *   2. Queries Macronix MX25L12872F / MX25L12835F SPI Flash JEDEC ID.
 *   3. In-System Programs FPGA bitstream (.bin) directly into SPI Flash over PCIe BAR1 MMIO.
 *   4. Verifies Flash contents with 100% bit-for-bit comparison.
 *   5. Triggers ICAPE2 IPROG warm boot without host reboot.
 *   6. Handles PCIe bus rescan & driver reload automatically.
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
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <errno.h>
#include <dirent.h>
#include <time.h>

#define SYSFS_PCI_BASE "/sys/bus/pci/devices"

/* SPI Flash Register Offsets in BAR1 */
#define BAR1_OFFSET_SPI_FLASH  0x4000
#define REG_SPI_CR             0x00
#define REG_SPI_SR             0x04
#define REG_SPI_TXD            0x08
#define REG_SPI_RXD            0x0C
#define REG_ICAP_CMD           0x20

#define ICAP_MAGIC_RELOAD      0x52454C4F /* "RELO" */

/* SPI Commands */
#define CMD_READ_ID            0x9F
#define CMD_WRITE_ENABLE       0x06
#define CMD_READ_STATUS        0x05
#define CMD_READ_DATA          0x03
#define CMD_PAGE_PROGRAM       0x02
#define CMD_SECTOR_ERASE_4K    0x20
#define CMD_BLOCK_ERASE_64K    0xD8

#define STATUS_WIP             0x01 /* Write In Progress */

/* Global Device Path and BDF */
static char g_device_path[512] = {0};
static char g_bdf[256] = {0};

static inline int run_cmd(const char *cmd)
{
    int ret = system(cmd);
    return ret;
}

/* MMIO helpers */
static inline void write32(volatile uint32_t *bar1, uint32_t offset, uint32_t val)
{
    *(volatile uint32_t *)((volatile uint8_t *)bar1 + offset) = val;
}

static inline uint32_t read32(volatile uint32_t *bar1, uint32_t offset)
{
    return *(volatile uint32_t *)((volatile uint8_t *)bar1 + offset);
}

/* SPI low-level routines */
static void spi_set_cs(volatile uint32_t *bar1, bool assert)
{
    /* CS_N=0 when asserted, CS_N=1 when deasserted. Divider=6 (~10.4MHz) */
    uint32_t cr = (6 << 4) | 0x02 | (assert ? 0 : 0x01);
    write32(bar1, BAR1_OFFSET_SPI_FLASH + REG_SPI_CR, cr);
    (void)read32(bar1, BAR1_OFFSET_SPI_FLASH + REG_SPI_CR); // Flush PCIe write
    usleep(20);
}

static uint8_t spi_xfer(volatile uint32_t *bar1, uint8_t tx)
{
    write32(bar1, BAR1_OFFSET_SPI_FLASH + REG_SPI_TXD, tx);
    usleep(35);
    return (uint8_t)(read32(bar1, BAR1_OFFSET_SPI_FLASH + REG_SPI_RXD) & 0xFF);
}

static void flash_write_enable(volatile uint32_t *bar1)
{
    spi_set_cs(bar1, true);
    spi_xfer(bar1, CMD_WRITE_ENABLE);
    spi_set_cs(bar1, false);
}

static int flash_wait_wip(volatile uint32_t *bar1, unsigned int timeout_ms)
{
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);

    while (1) {
        spi_set_cs(bar1, true);
        spi_xfer(bar1, CMD_READ_STATUS);
        uint8_t st = spi_xfer(bar1, 0xFF);
        spi_set_cs(bar1, false);

        if (!(st & STATUS_WIP))
            return 0;

        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed_ms = (now.tv_sec - start.tv_sec) * 1000.0 +
                            (now.tv_nsec - start.tv_nsec) / 1000000.0;
        if (elapsed_ms > timeout_ms)
            return -ETIMEDOUT;

        struct timespec ts = {0, 500000}; // 500us
        nanosleep(&ts, NULL);
    }
}

static int flash_read_id(volatile uint32_t *bar1, uint32_t *id)
{
    spi_set_cs(bar1, true);
    spi_xfer(bar1, CMD_READ_ID);
    uint8_t b0 = spi_xfer(bar1, 0xFF);
    uint8_t b1 = spi_xfer(bar1, 0xFF);
    uint8_t b2 = spi_xfer(bar1, 0xFF);
    spi_set_cs(bar1, false);

    *id = ((uint32_t)b0 << 16) | ((uint32_t)b1 << 8) | b2;
    return 0;
}

static int flash_erase_64k(volatile uint32_t *bar1, uint32_t addr)
{
    flash_write_enable(bar1);

    spi_set_cs(bar1, true);
    spi_xfer(bar1, CMD_BLOCK_ERASE_64K);
    spi_xfer(bar1, (addr >> 16) & 0xFF);
    spi_xfer(bar1, (addr >> 8) & 0xFF);
    spi_xfer(bar1, addr & 0xFF);
    spi_set_cs(bar1, false);

    return flash_wait_wip(bar1, 3000); // 3s timeout for 64KB block erase
}

static int flash_program_page(volatile uint32_t *bar1, uint32_t addr,
                              const uint8_t *data, size_t len)
{
    if (len > 256)
        len = 256;

    flash_write_enable(bar1);

    spi_set_cs(bar1, true);
    spi_xfer(bar1, CMD_PAGE_PROGRAM);
    spi_xfer(bar1, (addr >> 16) & 0xFF);
    spi_xfer(bar1, (addr >> 8) & 0xFF);
    spi_xfer(bar1, addr & 0xFF);

    for (size_t i = 0; i < len; i++) {
        spi_xfer(bar1, data[i]);
    }
    spi_set_cs(bar1, false);

    return flash_wait_wip(bar1, 100); // 100ms timeout for 256B page program
}

static int flash_read_range(volatile uint32_t *bar1, uint32_t addr,
                            uint8_t *buf, size_t len)
{
    spi_set_cs(bar1, true);
    spi_xfer(bar1, CMD_READ_DATA);
    spi_xfer(bar1, (addr >> 16) & 0xFF);
    spi_xfer(bar1, (addr >> 8) & 0xFF);
    spi_xfer(bar1, addr & 0xFF);

    for (size_t i = 0; i < len; i++) {
        buf[i] = spi_xfer(bar1, 0xFF);
    }
    spi_set_cs(bar1, false);
    return 0;
}

/* Auto-discover QPCIe device (12ab:e380) in sysfs */
static int find_qpcie_device(void)
{
    DIR *dir = opendir(SYSFS_PCI_BASE);
    struct dirent *entry;

    if (!dir) {
        perror("opendir " SYSFS_PCI_BASE);
        return -1;
    }

    while ((entry = readdir(dir)) != NULL) {
        char vendor_path[600], device_path[600];
        char vendor_buf[16] = {0}, device_buf[16] = {0};
        int fd;

        if (entry->d_name[0] == '.')
            continue;

        snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor", SYSFS_PCI_BASE, entry->d_name);
        fd = open(vendor_path, O_RDONLY);
        if (fd < 0) continue;
        if (read(fd, vendor_buf, sizeof(vendor_buf) - 1) < 0) {
            close(fd);
            continue;
        }
        close(fd);

        snprintf(device_path, sizeof(device_path), "%s/%s/device", SYSFS_PCI_BASE, entry->d_name);
        fd = open(device_path, O_RDONLY);
        if (fd < 0) continue;
        if (read(fd, device_buf, sizeof(device_buf) - 1) < 0) {
            close(fd);
            continue;
        }
        close(fd);

        if (strstr(vendor_buf, "0x12ab") && strstr(device_buf, "0xe380")) {
            snprintf(g_device_path, sizeof(g_device_path), "%s/%s", SYSFS_PCI_BASE, entry->d_name);
            snprintf(g_bdf, sizeof(g_bdf), "%s", entry->d_name);
            closedir(dir);
            return 0;
        }
    }

    closedir(dir);
    return -ENODEV;
}

static volatile uint32_t *map_bar1(int *p_fd)
{
    char res1_path[600];
    snprintf(res1_path, sizeof(res1_path), "%s/resource1", g_device_path);

    int fd = open(res1_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "ERROR: Cannot open %s: %s\n", res1_path, strerror(errno));
        fprintf(stderr, "Ensure you are running with root privileges (sudo).\n");
        return NULL;
    }

    void *ptr = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        perror("mmap resource1");
        close(fd);
        return NULL;
    }

    *p_fd = fd;
    return (volatile uint32_t *)ptr;
}

static void unmap_bar1(volatile uint32_t *bar1, int fd)
{
    if (bar1 && bar1 != MAP_FAILED) {
        munmap((void *)bar1, 65536);
    }
    if (fd >= 0) {
        close(fd);
    }
}

static bool is_driver_loaded(void)
{
    return (access("/sys/module/qpcie", F_OK) == 0);
}

static void show_hdmi_status(void)
{
    char path[600];
    char buf[512] = {0};
    int fd;

    snprintf(path, sizeof(path), "%s/hdmi_status", g_device_path);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("HDMI Status: Not available (%s: %s)\n", path, strerror(errno));
        return;
    }

    if (read(fd, buf, sizeof(buf) - 1) < 0) {
        close(fd);
        return;
    }
    close(fd);

    printf("========================================\n");
    printf("📺 QPCIe A50T HDMI Input Status\n");
    printf("========================================\n");
    printf("%s", buf);
}

static void show_flash_id(void)
{
    /* If driver is loaded, check driver sysfs flash_id first */
    char sysfs_id_path[600];
    snprintf(sysfs_id_path, sizeof(sysfs_id_path), "%s/flash_id", g_device_path);
    int sfd = open(sysfs_id_path, O_RDONLY);
    if (sfd >= 0) {
        char sbuf[256] = {0};
        if (read(sfd, sbuf, sizeof(sbuf) - 1) > 0) {
            printf("========================================\n");
            printf("💾 QPCIe A50T SPI Flash Identification (via Driver)\n");
            printf("========================================\n");
            printf("JEDEC ID: %s", sbuf);
            close(sfd);
            return;
        }
        close(sfd);
    }

    bool driver_was_loaded = is_driver_loaded();
    if (driver_was_loaded) {
        printf("ℹ️  Temporarily releasing driver for direct BAR1 MMIO access...\n");
        run_cmd("rmmod qpcie 2>/dev/null");
        usleep(200000);
    }

    int fd = -1;
    volatile uint32_t *bar1 = map_bar1(&fd);
    if (!bar1) {
        if (driver_was_loaded) {
            run_cmd("modprobe videobuf2-dma-sg 2>/dev/null");
            run_cmd("insmod /home/nvidia/qpcie/driver/qpcie.ko 2>/dev/null || modprobe qpcie 2>/dev/null");
        }
        return;
    }

    uint32_t id = 0;
    flash_read_id(bar1, &id);
    unmap_bar1(bar1, fd);

    if (driver_was_loaded) {
        run_cmd("modprobe videobuf2-dma-sg 2>/dev/null");
        run_cmd("insmod /home/nvidia/qpcie/driver/qpcie.ko 2>/dev/null || modprobe qpcie 2>/dev/null");
    }

    uint8_t mfr = (id >> 16) & 0xFF;
    uint8_t type = (id >> 8) & 0xFF;
    uint8_t cap = id & 0xFF;

    printf("========================================\n");
    printf("💾 QPCIe A50T SPI Flash Identification (via Direct MMIO)\n");
    printf("========================================\n");
    printf("JEDEC ID: 0x%06X (Manufacturer: 0x%02X, Memory Type: 0x%02X, Capacity: 0x%02X)\n",
           id, mfr, type, cap);

    if (mfr == 0xC2 && (type == 0x20 || type == 0x18)) {
        printf("Detected: Macronix MX25L12872F / MX25L12835F 128Mb (16MB) Flash [OK]\n");
    } else {
        printf("WARNING: Unexpected Flash ID! Check SPI connections.\n");
    }
}

static int program_flash_direct(const char *bin_filename)
{
    struct stat st;
    if (stat(bin_filename, &st) < 0) {
        perror("stat bitstream file");
        return -1;
    }

    if (st.st_size <= 0 || st.st_size > 16 * 1024 * 1024) {
        fprintf(stderr, "ERROR: Invalid bitstream file size (%ld bytes)\n", (long)st.st_size);
        return -1;
    }

    int file_fd = open(bin_filename, O_RDONLY);
    if (file_fd < 0) {
        perror("open bitstream file");
        return -1;
    }

    uint8_t *bin_data = malloc(st.st_size);
    if (!bin_data) {
        perror("malloc buffer");
        close(file_fd);
        return -1;
    }

    if (read(file_fd, bin_data, st.st_size) != st.st_size) {
        perror("read bitstream file");
        free(bin_data);
        close(file_fd);
        return -1;
    }
    close(file_fd);

    /* Verify Xilinx Sync Word (0xAA995566) */
    bool sync_found = false;
    for (size_t i = 0; i < st.st_size - 4 && i < 128; i++) {
        if (bin_data[i] == 0xAA && bin_data[i+1] == 0x99 &&
            bin_data[i+2] == 0x55 && bin_data[i+3] == 0x66) {
            sync_found = true;
            break;
        }
    }
    if (!sync_found) {
        printf("⚠️  WARNING: Xilinx bitstream Sync Word (0xAA995566) not found in header!\n");
        printf("    Proceeding anyway...\n");
    }

    /* Check if driver is loaded - unload temporarily to ensure exclusive BAR1 access */
    bool driver_was_loaded = is_driver_loaded();
    if (driver_was_loaded) {
        printf("ℹ️  Note: Temporarily unloading 'qpcie' driver for Flash programming...\n");
        run_cmd("rmmod qpcie 2>/dev/null");
        usleep(200000);
    }

    int bar1_fd = -1;
    volatile uint32_t *bar1 = map_bar1(&bar1_fd);
    if (!bar1) {
        if (driver_was_loaded) {
            run_cmd("modprobe videobuf2-dma-sg 2>/dev/null");
            run_cmd("insmod /home/nvidia/qpcie/driver/qpcie.ko 2>/dev/null || modprobe qpcie 2>/dev/null");
        }
        free(bin_data);
        return -1;
    }

    /* Check Flash ID first */
    uint32_t id = 0;
    flash_read_id(bar1, &id);
    if ((id >> 16) != 0xC2) {
        fprintf(stderr, "ERROR: Flash ID read failed (0x%06X). Expected 0xC2xxxx.\n", id);
        unmap_bar1(bar1, bar1_fd);
        free(bin_data);
        return -1;
    }

    size_t file_size = st.st_size;
    size_t block_size = 64 * 1024;
    size_t num_blocks = (file_size + block_size - 1) / block_size;
    size_t num_pages = (file_size + 255) / 256;

    printf("=======================================================\n");
    printf("🚀 In-System SPI Flash Programming Over PCIe BAR1 MMIO\n");
    printf("=======================================================\n");
    printf("Bitstream File : %s\n", bin_filename);
    printf("Total Size     : %ld bytes (%.2f MB)\n", (long)file_size, (double)file_size / (1024 * 1024));
    printf("Flash Sector   : %zu blocks (64 KB each), %zu pages (256 B each)\n", num_blocks, num_pages);
    printf("-------------------------------------------------------\n");

    struct timeval t_start, t_now;
    gettimeofday(&t_start, NULL);

    /* 1. Erase 64KB blocks */
    printf("[1/3] Erasing 64KB Flash Blocks...\n");
    for (size_t b = 0; b < num_blocks; b++) {
        uint32_t addr = b * block_size;
        int ret = flash_erase_64k(bar1, addr);
        if (ret < 0) {
            fprintf(stderr, "\nERROR: Block erase failed at 0x%06X (code %d)\n", addr, ret);
            unmap_bar1(bar1, bar1_fd);
            free(bin_data);
            return -1;
        }
        printf("\r  Erase Progress: [%3zu%%] (Block %zu / %zu at 0x%06X)",
               ((b + 1) * 100) / num_blocks, b + 1, num_blocks, addr);
        fflush(stdout);
    }
    printf("\n  Erase complete!\n");

    /* 2. Program Pages (256 bytes per page) */
    printf("[2/3] Programming Bitstream Pages...\n");
    size_t written = 0;
    while (written < file_size) {
        size_t chunk = (file_size - written > 256) ? 256 : (file_size - written);
        int ret = flash_program_page(bar1, (uint32_t)written, bin_data + written, chunk);
        if (ret < 0) {
            fprintf(stderr, "\nERROR: Page program failed at 0x%06zX\n", written);
            unmap_bar1(bar1, bar1_fd);
            free(bin_data);
            return -1;
        }
        written += chunk;

        if ((written % (16 * 1024) == 0) || (written == file_size)) {
            gettimeofday(&t_now, NULL);
            double elapsed = (t_now.tv_sec - t_start.tv_sec) +
                             (t_now.tv_usec - t_start.tv_usec) / 1000000.0;
            double speed = (written / 1024.0) / (elapsed > 0 ? elapsed : 0.001);
            printf("\r  Write Progress: [%3d%%] (%zu / %zu bytes) | %.1f KB/s",
                   (int)((written * 100) / file_size), written, file_size, speed);
            fflush(stdout);
        }
    }
    printf("\n  Programming complete!\n");

    /* 3. Verify Contents */
    printf("[3/3] Verifying Flash Contents 100%% Bit-for-Bit...\n");
    uint8_t page_buf[256];
    size_t verified = 0;
    bool mismatch = false;

    while (verified < file_size) {
        size_t chunk = (file_size - verified > 256) ? 256 : (file_size - verified);
        flash_read_range(bar1, (uint32_t)verified, page_buf, chunk);

        if (memcmp(page_buf, bin_data + verified, chunk) != 0) {
            printf("\n❌ Verification MISMATCH detected at offset 0x%06zX!\n", verified);
            for (size_t i = 0; i < chunk; i++) {
                if (page_buf[i] != bin_data[verified + i]) {
                    printf("   Byte 0x%06zX: expected 0x%02X, read 0x%02X\n",
                           verified + i, bin_data[verified + i], page_buf[i]);
                    break;
                }
            }
            mismatch = true;
            break;
        }

        verified += chunk;
        if ((verified % (64 * 1024) == 0) || (verified == file_size)) {
            printf("\r  Verify Progress: [%3d%%] (%zu / %zu bytes)",
                   (int)((verified * 100) / file_size), verified, file_size);
            fflush(stdout);
        }
    }

    unmap_bar1(bar1, bar1_fd);
    free(bin_data);

    if (mismatch) {
        fprintf(stderr, "\n❌ In-System Programming FAILED: Flash data corrupt!\n");
        return -1;
    }

    gettimeofday(&t_now, NULL);
    double total_elapsed = (t_now.tv_sec - t_start.tv_sec) +
                           (t_now.tv_usec - t_start.tv_usec) / 1000000.0;
    printf("\n=======================================================\n");
    printf("🎉 100%% BIT-FOR-BIT VERIFICATION SUCCESS!\n");
    printf("Total Elapsed Time: %.2f seconds\n", total_elapsed);
    printf("The FPGA bitstream has been safely written to SPI Flash!\n");
    printf("To boot this new bitstream, run: %s -r\n", "qpcie_a50t_tool");
    printf("=======================================================\n");

    if (driver_was_loaded) {
        printf("Restoring 'qpcie' driver...\n");
        run_cmd("modprobe videobuf2-dma-sg 2>/dev/null");
        run_cmd("insmod /home/nvidia/qpcie/driver/qpcie.ko 2>/dev/null || modprobe qpcie 2>/dev/null");
    }

    return 0;
}

static void retrain_parent_root_port(void)
{
    /* Find parent bridge, typically 0004:00:00.0 for 0004:01:00.0 */
    char parent_bdf[128] = "0004:00:00.0";
    char cmd[512];

    /* 1. Assert Secondary Bus Reset (SBR) */
    snprintf(cmd, sizeof(cmd), "setpci -s %s 3e.b=42 2>/dev/null", parent_bdf);
    run_cmd(cmd);
    usleep(100000); // 100ms

    /* 2. Deassert Secondary Bus Reset */
    snprintf(cmd, sizeof(cmd), "setpci -s %s 3e.b=02 2>/dev/null", parent_bdf);
    run_cmd(cmd);
    usleep(200000); // 200ms

    /* 3. Force Link Retraining */
    snprintf(cmd, sizeof(cmd), "setpci -s %s 80.w=0460 2>/dev/null", parent_bdf);
    run_cmd(cmd);
    usleep(500000); // 500ms
}

static int trigger_reload(void)
{
    printf("=======================================================\n");
    printf("🔄 Triggering FPGA ICAPE2 Warm Boot (IPROG Reload)\n");
    printf("=======================================================\n");

    bool driver_was_loaded = is_driver_loaded();
    if (driver_was_loaded) {
        printf("[1/5] Unloading 'qpcie' driver prior to reload...\n");
        run_cmd("rmmod qpcie 2>/dev/null");
        usleep(200000);
    }

    int bar1_fd = -1;
    volatile uint32_t *bar1 = map_bar1(&bar1_fd);
    if (!bar1) return -1;

    printf("[2/5] Writing ICAPE2 reload command (0x52454C4F) to BAR1 0x4020...\n");
    write32(bar1, BAR1_OFFSET_SPI_FLASH + REG_ICAP_CMD, ICAP_MAGIC_RELOAD);
    unmap_bar1(bar1, bar1_fd);

    printf("[3/5] Waiting 1.0s for FPGA to reconfigure from SPI Flash...\n");
    sleep(1);

    printf("[4/5] Retraining PCIe Root Port and rescanning bus...\n");
    char remove_cmd[512];
    snprintf(remove_cmd, sizeof(remove_cmd), "echo 1 > /sys/bus/pci/devices/%s/remove 2>/dev/null", g_bdf);
    run_cmd(remove_cmd);
    usleep(200000);

    /* Assert SBR and retrain link on root port */
    retrain_parent_root_port();

    run_cmd("echo 1 > /sys/bus/pci/rescan");
    usleep(500000);

    /* Check if device re-appeared */
    if (find_qpcie_device() < 0) {
        printf("⚠️  Warning: QPCIe device not immediately detected after rescan.\n");
        printf("   Retrying secondary bus retrain & rescan...\n");
        retrain_parent_root_port();
        run_cmd("echo 1 > /sys/bus/pci/rescan");
        sleep(1);
    }

    if (find_qpcie_device() == 0) {
        printf("🎉 PCIe device restored successfully at %s!\n", g_bdf);
    } else {
        fprintf(stderr, "❌ ERROR: QPCIe device failed to re-enumerate after reload.\n");
        return -1;
    }

    if (driver_was_loaded) {
        printf("[5/5] Reloading 'qpcie' driver...\n");
        run_cmd("modprobe videobuf2-dma-sg 2>/dev/null");
        run_cmd("insmod /home/nvidia/qpcie/driver/qpcie.ko 2>/dev/null || modprobe qpcie 2>/dev/null");
        sleep(1);

        char ver_path[600];
        snprintf(ver_path, sizeof(ver_path), "%s/version", g_device_path);
        int vfd = open(ver_path, O_RDONLY);
        if (vfd >= 0) {
            char vbuf[256] = {0};
            if (read(vfd, vbuf, sizeof(vbuf) - 1) > 0) {
                printf("Hardware Version: %s", vbuf);
            }
            close(vfd);
        }
    }

    printf("Warm boot complete! Hardware is active and running new bitstream.\n");
    return 0;
}

static void print_usage(const char *prog)
{
    printf("Usage: %s [options]\n", prog);
    printf("Options:\n");
    printf("  -s, --status              Show HDMI Receiver (IT68051) status\n");
    printf("  -i, --id                  Read on-board SPI Flash JEDEC ID (Macronix)\n");
    printf("  -w, --write <file.bin>    Program bitstream .bin directly into SPI Flash over PCIe\n");
    printf("  -r, --reload              Trigger ICAPE2 FPGA warm boot / IPROG reload & rescan\n");
    printf("  -u, --update <file.bin>   Full automated update: Write bitstream + Verify + Warm Reload\n");
    printf("  -h, --help                Show this help message\n");
}

int main(int argc, char **argv)
{
    static struct option long_options[] = {
        {"status", no_argument, 0, 's'},
        {"id",     no_argument, 0, 'i'},
        {"write",  required_argument, 0, 'w'},
        {"reload", no_argument, 0, 'r'},
        {"update", required_argument, 0, 'u'},
        {"help",   no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt, option_index = 0;
    const char *bin_file = NULL;
    bool do_status = false, do_id = false, do_reload = false;
    bool do_update = false;

    if (argc < 2) {
        print_usage(argv[0]);
        return 0;
    }

    while ((opt = getopt_long(argc, argv, "siw:ru:h", long_options, &option_index)) != -1) {
        switch (opt) {
            case 's': do_status = true; break;
            case 'i': do_id = true; break;
            case 'w': bin_file = optarg; break;
            case 'r': do_reload = true; break;
            case 'u': bin_file = optarg; do_update = true; break;
            case 'h': print_usage(argv[0]); return 0;
            default:  print_usage(argv[0]); return 1;
        }
    }

    if (find_qpcie_device() < 0) {
        printf("ERROR: No QPCIe device found (Vendor 0x12AB, Device 0xE380).\n");
        printf("Ensure the board is seated in the PCIe slot.\n");
        return 1;
    }

    printf("Found QPCIe device [%s] at: %s\n", g_bdf, g_device_path);

    if (do_status)
        show_hdmi_status();

    if (do_id)
        show_flash_id();

    if (bin_file && !do_update) {
        if (program_flash_direct(bin_file) < 0)
            return 1;
    }

    if (do_update) {
        if (program_flash_direct(bin_file) < 0) {
            fprintf(stderr, "Update aborted: programming failed.\n");
            return 1;
        }
        trigger_reload();
    } else if (do_reload) {
        trigger_reload();
    }

    return 0;
}
