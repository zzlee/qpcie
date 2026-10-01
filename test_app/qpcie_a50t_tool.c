/*
 * qpcie_a50t_tool.c - QPCIe Artix-7 A50T SPI Flash Programming & HDMI Status Utility
 *
 * Description:
 *   Host utility for Artix-7 A50T PCIe Video DMA Card:
 *   1. Displays IT68051 HDMI Receiver status (Signal Lock, Resolution, FPS).
 *   2. Queries Macronix MX25L12835F SPI Flash JEDEC ID.
 *   3. Programs FPGA bitstream (.bin) directly into SPI Flash over PCIe.
 *   4. Verifies Flash contents with CRC32.
 *   5. Triggers ICAPE2 IPROG warm reload without host reboot.
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
#include <errno.h>
#include <dirent.h>

#define SYSFS_PCI_BASE "/sys/bus/pci/devices"

static char g_device_path[512] = {0};

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
            closedir(dir);
            return 0;
        }
    }

    closedir(dir);
    return -ENODEV;
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
    char path[600];
    char buf[256] = {0};
    int fd;

    snprintf(path, sizeof(path), "%s/flash_id", g_device_path);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("Flash ID: Not available (%s: %s)\n", path, strerror(errno));
        return;
    }

    if (read(fd, buf, sizeof(buf) - 1) < 0) {
        close(fd);
        return;
    }
    close(fd);

    printf("========================================\n");
    printf("💾 QPCIe A50T SPI Flash Identification\n");
    printf("========================================\n");
    printf("JEDEC ID: %s", buf);
}

static int program_flash(const char *bin_filename)
{
    char flash_bin_path[600];
    int flash_fd, file_fd;
    struct stat st;
    uint8_t *buf;
    ssize_t total_written = 0;
    size_t chunk_size = 64 * 1024; // 64KB blocks

    if (stat(bin_filename, &st) < 0) {
        perror("stat bitstream file");
        return -1;
    }

    file_fd = open(bin_filename, O_RDONLY);
    if (file_fd < 0) {
        perror("open bitstream file");
        return -1;
    }

    buf = malloc(st.st_size);
    if (!buf) {
        perror("malloc buffer");
        close(file_fd);
        return -1;
    }

    if (read(file_fd, buf, st.st_size) != st.st_size) {
        perror("read bitstream file");
        free(buf);
        close(file_fd);
        return -1;
    }
    close(file_fd);

    snprintf(flash_bin_path, sizeof(flash_bin_path), "%s/flash_bin", g_device_path);
    flash_fd = open(flash_bin_path, O_RDWR);
    if (flash_fd < 0) {
        perror("open flash_bin sysfs");
        free(buf);
        return -1;
    }

    printf("========================================\n");
    printf("🚀 Programming SPI Flash (%s)\n", bin_filename);
    printf("Size: %ld bytes (%.2f MB)\n", (long)st.st_size, (double)st.st_size / (1024 * 1024));
    printf("========================================\n");

    while (total_written < st.st_size) {
        size_t to_write = (st.st_size - total_written > chunk_size) ?
                           chunk_size : (st.st_size - total_written);
        ssize_t ret = pwrite(flash_fd, buf + total_written, to_write, total_written);

        if (ret < 0) {
            printf("\nERROR: Failed to write at offset 0x%lX: %s\n", (long)total_written, strerror(errno));
            free(buf);
            close(flash_fd);
            return -1;
        }

        total_written += ret;
        printf("\rProgress: [%3d%%] (%ld / %ld bytes)",
               (int)((total_written * 100) / st.st_size),
               (long)total_written, (long)st.st_size);
        fflush(stdout);
    }

    printf("\nProgramming complete! Verifying contents...\n");

    /* Verify written data */
    uint8_t *vbuf = malloc(st.st_size);
    if (vbuf) {
        ssize_t vret = pread(flash_fd, vbuf, st.st_size, 0);
        if (vret == st.st_size && memcmp(buf, vbuf, st.st_size) == 0) {
            printf("🎉 Verification SUCCESS: 100%% bit-for-bit match!\n");
        } else {
            printf("❌ Verification FAILED at offset! Data mismatch detected!\n");
        }
        free(vbuf);
    }

    free(buf);
    close(flash_fd);
    return 0;
}

static int trigger_reload(void)
{
    char path[600];
    int fd;

    snprintf(path, sizeof(path), "%s/flash_reload", g_device_path);
    fd = open(path, O_WRONLY);
    if (fd < 0) {
        perror("open flash_reload");
        return -1;
    }

    printf("========================================\n");
    printf("🔄 Triggering FPGA ICAPE2 Warm Boot...\n");
    printf("========================================\n");
    if (write(fd, "1\n", 2) < 0) {
        perror("write flash_reload");
        close(fd);
        return -1;
    }
    close(fd);

    printf("Command issued successfully. FPGA will reboot from Flash address 0.\n");
    return 0;
}

static void print_usage(const char *prog)
{
    printf("Usage: %s [options]\n", prog);
    printf("Options:\n");
    printf("  -s, --status              Show HDMI Receiver (IT68051) status\n");
    printf("  -i, --id                  Read on-board SPI Flash JEDEC ID\n");
    printf("  -w, --write <file.bin>    Program bitstream .bin file to SPI Flash\n");
    printf("  -r, --reload              Trigger ICAPE2 FPGA warm boot / IPROG reload\n");
    printf("  -h, --help                Show this help message\n");
}

int main(int argc, char **argv)
{
    static struct option long_options[] = {
        {"status", no_argument, 0, 's'},
        {"id",     no_argument, 0, 'i'},
        {"write",  required_argument, 0, 'w'},
        {"reload", no_argument, 0, 'r'},
        {"help",   no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt, option_index = 0;
    const char *bin_file = NULL;
    bool do_status = false, do_id = false, do_reload = false;

    if (argc < 2) {
        print_usage(argv[0]);
        return 0;
    }

    while ((opt = getopt_long(argc, argv, "siw:rh", long_options, &option_index)) != -1) {
        switch (opt) {
            case 's': do_status = true; break;
            case 'i': do_id = true; break;
            case 'w': bin_file = optarg; break;
            case 'r': do_reload = true; break;
            case 'h': print_usage(argv[0]); return 0;
            default:  print_usage(argv[0]); return 1;
        }
    }

    if (find_qpcie_device() < 0) {
        printf("ERROR: No QPCIe device found (Vendor 0x12AB, Device 0xE380).\n");
        printf("Ensure the board is inserted and custom_pcie_av.ko is loaded.\n");
        return 1;
    }

    printf("Found QPCIe device at: %s\n", g_device_path);

    if (do_status)
        show_hdmi_status();

    if (do_id)
        show_flash_id();

    if (bin_file) {
        if (program_flash(bin_file) < 0)
            return 1;
    }

    if (do_reload)
        trigger_reload();

    return 0;
}
