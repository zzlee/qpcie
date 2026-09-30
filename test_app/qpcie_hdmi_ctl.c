/*
 * qpcie_hdmi_ctl.c - CLI tool for monitoring and configuring HDMI RX / TX on QPCIe A50T / ZU4EV
 *
 * Interacts with BAR0 Block 6 registers (0x0600 - 0x063C):
 *   0x0600: REG_HDMI_RX_STATUS (5V Cable Det, TMDS Lock, Video Lock, Audio Lock, ColorSpace, Depth)
 *   0x0604: REG_HDMI_RX_RES    (Width, Height)
 *   0x0608: REG_HDMI_RX_TIMING (FPS in mHz, Interlaced)
 *   0x060C: REG_HDMI_RX_AUDIO  (Channels, SampleRate, BitDepth)
 *   0x0610: REG_HDMI_TX_CTRL   (Output En, Audio En, ColorSpace, ColorDepth)
 *   0x0614: REG_HDMI_TX_RES    (Width, Height)
 *   0x0618: REG_HDMI_TX_FPS    (Target FPS)
 *   0x0620: REG_HDMI_TX_STATUS (Sink HPD, Video Locked, Active)
 *   0x0630 - 0x063C: Host <-> PetaLinux PS Mailbox IPC
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <dirent.h>
#include "qpcie_control.h"

#define VENDOR_ID "0x12ab"
#define DEVICE_ID "0xe380"
#define BAR0_SIZE 0x100000

static char pci_dev_path[512] = "";

static int find_qpcie_device(void) {
    DIR *dir = opendir("/sys/bus/pci/devices");
    if (!dir) return -1;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char path[512], buf[64];
        FILE *f;

        snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/vendor", entry->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(buf, sizeof(buf), f)) { fclose(f); continue; }
        fclose(f);
        if (strncmp(buf, VENDOR_ID, 6) != 0) continue;

        snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/device", entry->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(buf, sizeof(buf), f)) { fclose(f); continue; }
        fclose(f);
        if (strncmp(buf, DEVICE_ID, 6) != 0) continue;

        snprintf(pci_dev_path, sizeof(pci_dev_path), "/sys/bus/pci/devices/%s", entry->d_name);
        closedir(dir);
        return 0;
    }
    closedir(dir);
    return -1;
}

static void print_status(volatile uint32_t *bar0) {
    uint32_t rx_status = bar0[BAR0_REG_HDMI_RX_STATUS / 4];
    uint32_t rx_w      = bar0[BAR0_REG_HDMI_RX_WIDTH / 4];
    uint32_t rx_h      = bar0[BAR0_REG_HDMI_RX_HEIGHT / 4];
    uint32_t rx_clk    = bar0[BAR0_REG_HDMI_RX_PIXEL_CLK / 4];

    uint32_t rx_hfp    = bar0[BAR0_REG_HDMI_RX_HFP / 4];
    uint32_t rx_hsw    = bar0[BAR0_REG_HDMI_RX_HSW / 4];
    uint32_t rx_hbp    = bar0[BAR0_REG_HDMI_RX_HBP / 4];
    uint32_t rx_vfp    = bar0[BAR0_REG_HDMI_RX_VFP / 4];
    uint32_t rx_vsw    = bar0[BAR0_REG_HDMI_RX_VSW / 4];
    uint32_t rx_vbp    = bar0[BAR0_REG_HDMI_RX_VBP / 4];
    uint32_t rx_color  = bar0[BAR0_REG_HDMI_RX_COLOR_FMT / 4];
    uint32_t rx_audio  = bar0[BAR0_REG_HDMI_RX_AUDIO_FMT / 4];

    uint32_t tx_ctrl   = bar0[BAR0_REG_HDMI_TX_CTRL / 4];
    uint32_t tx_res    = bar0[BAR0_REG_HDMI_TX_RES / 4];
    uint32_t tx_fps    = bar0[BAR0_REG_HDMI_TX_FPS / 4];
    uint32_t tx_status = bar0[BAR0_REG_HDMI_TX_STATUS / 4];

    printf("=================================================================\n");
    printf(" QPCIe Multi-Channel HDMI RX / TX Hardware Telemetry\n");
    printf(" Device: %s (12AB:E380)\n", pci_dev_path);
    printf("=================================================================\n\n");

    // HDMI RX Status
    bool rx_5v       = (rx_status & 0x01) != 0;
    bool rx_hpd      = (rx_status & 0x02) != 0;
    bool rx_tmds_lck = (rx_status & 0x04) != 0;
    bool rx_stream_up= (rx_status & 0x08) != 0;

    int  rx_cs       = rx_color & 0x03;
    int  rx_range    = (rx_color >> 2) & 0x03;
    int  rx_std      = (rx_color >> 4) & 0x07;

    const char *cs_str[] = { "RGB 4:4:4", "YCbCr 4:2:2", "YCbCr 4:4:4", "YCbCr 4:2:0" };
    const char *range_str[] = { "Default", "Limited (16-235)", "Full (0-255)", "Reserved" };
    const char *std_str[] = { "Default", "BT.601", "BT.709", "BT.2020", "DCI-P3" };

    printf("[HDMI RX (C2H Ch 0)]\n");
    printf("  Cable 5V Present : %s\n", rx_5v ? "YES (Connected)" : "NO (Disconnected)");
    printf("  HPD Signal Assert: %s\n", rx_hpd ? "HIGH (Asserted)" : "LOW (Deasserted)");
    printf("  TMDS Link Status : %s\n", rx_tmds_lck ? "LOCKED" : "UNLOCKED");
    printf("  Stream State     : %s\n", rx_stream_up ? "STREAM UP" : "WAITING FOR TIMINGS");
    if (rx_5v && rx_w > 0 && rx_h > 0) {
        printf("  Active Resolution: %u x %u (Total H=%u, Total V=%u)\n",
               rx_w, rx_h, rx_w + rx_hfp + rx_hsw + rx_hbp, rx_h + rx_vfp + rx_vsw + rx_vbp);
        printf("  Pixel Clock      : %.3f MHz\n", (double)rx_clk / 1000000.0);
        printf("  Horizontal Porch : Front=%u, Sync=%u, Back=%u\n", rx_hfp, rx_hsw, rx_hbp);
        printf("  Vertical Porch   : Front=%u, Sync=%u, Back=%u\n", rx_vfp, rx_vsw, rx_vbp);
        printf("  Color Space      : %s, Range: %s, Standard: %s\n",
               cs_str[rx_cs], range_str[rx_range], rx_std < 5 ? std_str[rx_std] : "Unknown");
    }
    uint32_t aud_rate = rx_audio & 0xFFFF;
    uint32_t aud_ch   = (rx_audio >> 16) & 0xFF;
    uint32_t aud_bits = (rx_audio >> 24) & 0xFF;
    if (aud_rate > 0) {
        printf("  Audio Details    : %u channels, %u Hz, %u-bit L-PCM\n",
               aud_ch ? aud_ch : 2, aud_rate, aud_bits ? aud_bits : 24);
    }
    printf("\n");

    // HDMI TX Status
    bool tx_hpd    = (tx_status & 0x01) != 0;
    bool tx_locked = (tx_status & 0x02) != 0;
    bool tx_active = (tx_status & 0x04) != 0;
    bool tx_en     = (tx_ctrl & 0x01) != 0;
    bool tx_aud_en = (tx_ctrl & 0x02) != 0;

    uint32_t tx_w  = tx_res & 0xFFFF;
    uint32_t tx_h  = (tx_res >> 16) & 0xFFFF;

    printf("[HDMI TX (H2C Ch 1)]\n");
    printf("  Sink Display HPD : %s\n", tx_hpd ? "CONNECTED (HPD High)" : "DISCONNECTED (No Sink)");
    printf("  Output Enabled   : %s\n", tx_en ? "ENABLED" : "MUTED / DISABLED");
    printf("  Audio Embedding  : %s\n", tx_aud_en ? "ENABLED" : "MUTED");
    printf("  TX PHY Clock Lock: %s\n", tx_locked ? "LOCKED" : "UNLOCKED");
    printf("  Stream Status    : %s\n", tx_active ? "TRANSMITTING" : "IDLE");
    if (tx_w > 0 && tx_h > 0) {
        printf("  Target Resolution: %u x %u @ %u fps\n", tx_w, tx_h, tx_fps & 0xFFFF);
    }
    printf("\n");

    // IPC Mailbox Status
    uint32_t ipc_cmd  = bar0[BAR0_REG_HDMI_IPC_CMD / 4];
    uint32_t ipc_arg  = bar0[BAR0_REG_HDMI_IPC_ARG / 4];
    uint32_t ipc_stat = bar0[BAR0_REG_HDMI_IPC_STATUS / 4];
    printf("[Host <-> ARM PS IPC Mailbox]\n");
    printf("  Last CMD: 0x%08X, Arg: 0x%08X, Status: 0x%08X\n", ipc_cmd, ipc_arg, ipc_stat);
    printf("=================================================================\n");
}

int main(int argc, char *argv[]) {
    if (find_qpcie_device() < 0) {
        fprintf(stderr, "Error: QPCIe device 12AB:E380 not found in /sys/bus/pci/devices!\n");
        return 1;
    }

    char res_path[1024];
    snprintf(res_path, sizeof(res_path), "%s/resource0", pci_dev_path);
    int fd = open(res_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("Failed to open BAR0 resource");
        return 1;
    }

    volatile uint32_t *bar0 = mmap(NULL, BAR0_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bar0 == MAP_FAILED) {
        perror("mmap BAR0 failed");
        close(fd);
        return 1;
    }

    if (argc > 1) {
        if (strcmp(argv[1], "--tx-en") == 0 && argc > 2) {
            int en = atoi(argv[2]);
            uint32_t ctrl = bar0[BAR0_REG_HDMI_TX_CTRL / 4];
            if (en) ctrl |= 0x03; // Output + Audio En
            else    ctrl &= ~0x01;
            bar0[BAR0_REG_HDMI_TX_CTRL / 4] = ctrl;
            printf("HDMI TX Output %s\n", en ? "Enabled" : "Disabled");
        } else if (strcmp(argv[1], "--tx-mode") == 0 && argc >= 5) {
            uint32_t w   = atoi(argv[2]);
            uint32_t h   = atoi(argv[3]);
            uint32_t fps = atoi(argv[4]);
            bar0[BAR0_REG_HDMI_TX_RES / 4] = (h << 16) | (w & 0xFFFF);
            bar0[BAR0_REG_HDMI_TX_FPS / 4] = fps;
            printf("HDMI TX Target Set to %u x %u @ %u fps\n", w, h, fps);
        } else if (strcmp(argv[1], "--ipc") == 0 && argc >= 4) {
            uint32_t cmd = strtoul(argv[2], NULL, 0);
            uint32_t arg = strtoul(argv[3], NULL, 0);
            bar0[BAR0_REG_HDMI_IPC_ARG / 4] = arg;
            bar0[BAR0_REG_HDMI_IPC_CMD / 4] = cmd;
            bar0[BAR0_REG_HDMI_IPC_DOORBELL / 4] = 1;
            printf("Sent IPC Command 0x%08X (Arg: 0x%08X) via Mailbox\n", cmd, arg);
        }
    }

    print_status(bar0);

    munmap((void *)bar0, BAR0_SIZE);
    close(fd);
    return 0;
}
