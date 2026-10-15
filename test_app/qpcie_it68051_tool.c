/*
 * qpcie_it68051_tool.c - QPCIe A50T IT68051 HDMI Receiver Diagnostic & Init Tool
 *
 * Direct BAR1 MMIO access:
 *   - FRONT I2C master at BAR1 0x3000 (IT68051 @ 0x48, EDID RAM @ 0x6C, TLV320 @ 0x18)
 *   - MCU I2C master at BAR1 0x5000 (NUC100 slave @ 0x2A)
 *
 * Capabilities:
 *   --status      Read IT68051 chip ID, cable 5V, TMDS clock, and sync detect
 *   --init        Full initialization: enable EDID RAM, load SC710 4K EDID, pulse HPD, enable TTL
 *   --edid        Load 256-byte EDID into IT68051 EDID RAM
 *   --hpd         Pulse HPD to force HDMI source re-reading EDID
 *   --ttl         Enable TTL dual-pixel video and I2S audio output
 *   --monitor     Continuously poll and log HDMI signal telemetry and resolution
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
#include <errno.h>
#include <dirent.h>
#include <time.h>

#define SYSFS_PCI_BASE "/sys/bus/pci/devices"

#define BAR0_REG_C_VERSION        0x0030
#define BAR0_REG_HDMI_RX_STATUS   0x0600
#define BAR0_REG_HDMI_RX_WIDTH    0x0604
#define BAR0_REG_HDMI_RX_HEIGHT   0x0608
#define BAR0_REG_HDMI_RX_PCLK_HZ  0x060C
#define BAR0_REG_HDMI_TX_CTRL     0x0610
#define BAR0_REG_HDMI_RX_AUDIO    0x0664

#define BAR1_OFFSET_I2C_FRONT 0x3000
#define BAR1_OFFSET_I2C_MCU   0x5000

#define REG_I2C_PRER_LO       0x00
#define REG_I2C_PRER_HI       0x04
#define REG_I2C_CTR           0x08
#define REG_I2C_TXR           0x0C
#define REG_I2C_RXR           0x0C
#define REG_I2C_CR            0x10
#define REG_I2C_SR            0x14

#define I2C_CTR_EN            (1u << 7)
#define I2C_CR_STA            (1u << 7)
#define I2C_CR_STO            (1u << 6)
#define I2C_CR_RD             (1u << 5)
#define I2C_CR_WR             (1u << 4)
#define I2C_CR_ACK            (1u << 3)
#define I2C_SR_RXACK          (1u << 7)
#define I2C_SR_TIP            (1u << 1)

#define IT68051_ADDR          0x48
#define EDID_RAM_ADDR         0x6C
#define NUC_ADDR              0x2A

#define TIMEOUT_MS            25

static char g_device_path[512] = {0};
static char g_bdf[256] = {0};

/* Genuine YUAN SC710 4K HDR EDID Table (256 bytes) */
static const uint8_t g_sc710_edid[256] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x66, 0xAE, 0x90, 0x06, 0x74, 0x17, 0x31, 0x84,
    0x08, 0x1D, 0x01, 0x03, 0x80, 0x3C, 0x22, 0x78, 0x2A, 0xF6, 0xD5, 0xA7, 0x54, 0x4B, 0x9E, 0x25,
    0x0D, 0x50, 0x54, 0xBF, 0xEF, 0x80, 0x71, 0x4F, 0x81, 0x40, 0x81, 0x80, 0x81, 0xC0, 0x81, 0x00,
    0x95, 0x00, 0xB3, 0x00, 0xD1, 0xC0, 0x4D, 0xD0, 0x00, 0xA0, 0xF0, 0x70, 0x3E, 0x80, 0x30, 0x30,
    0x35, 0x00, 0x54, 0x4F, 0x21, 0x00, 0x00, 0x1A, 0x56, 0x5E, 0x00, 0xA0, 0xA0, 0xA0, 0x29, 0x50,
    0x30, 0x20, 0x35, 0x00, 0x54, 0x4F, 0x21, 0x00, 0x00, 0x1E, 0x00, 0x00, 0x00, 0xFD, 0x00, 0x28,
    0x3C, 0x1E, 0xA0, 0x3C, 0x00, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xFC,
    0x00, 0x53, 0x43, 0x20, 0x37, 0x31, 0x30, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x01, 0xA7,
    0x02, 0x03, 0x50, 0xF1, 0x54, 0x01, 0x03, 0x04, 0x12, 0x13, 0x05, 0x14, 0x1F, 0x10, 0x07, 0x06,
    0x02, 0x5D, 0x5E, 0x5F, 0x60, 0x61, 0x62, 0x15, 0x16, 0x23, 0x09, 0x07, 0x07, 0x83, 0x01, 0x00,
    0x00, 0x6D, 0x03, 0x0C, 0x00, 0x10, 0x00, 0x38, 0x3C, 0x20, 0x00, 0x60, 0x01, 0x02, 0x03, 0x67,
    0xD8, 0x5D, 0xC4, 0x01, 0x78, 0x88, 0x03, 0x68, 0x1A, 0x00, 0x00, 0x01, 0x01, 0x28, 0x3C, 0xED,
    0xE3, 0x05, 0xE3, 0x01, 0xE4, 0x0F, 0x00, 0x80, 0x01, 0xE6, 0x06, 0x0F, 0x01, 0x60, 0x60, 0x45,
    0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C, 0x45, 0x00, 0x54, 0x4F, 0x21, 0x00,
    0x00, 0x1E, 0x8C, 0x0A, 0xD0, 0x8A, 0x20, 0xE0, 0x2D, 0x10, 0x10, 0x3E, 0x96, 0x00, 0x54, 0x4F,
    0x21, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3A
};

static inline void write32(volatile uint8_t *bar1, uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(bar1 + off) = v;
}

static inline uint32_t read32(volatile uint8_t *bar1, uint32_t off)
{
    return *(volatile uint32_t *)(bar1 + off);
}

static int wait_tip(volatile uint8_t *bar1, uint32_t base)
{
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        uint32_t sr = read32(bar1, base + REG_I2C_SR);
        if (!(sr & I2C_SR_TIP))
            return 0;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double ms = (now.tv_sec - t0.tv_sec) * 1000.0 +
                    (now.tv_nsec - t0.tv_nsec) / 1000000.0;
        if (ms > TIMEOUT_MS)
            return -ETIMEDOUT;
        struct timespec ts = {0, 20000};
        nanosleep(&ts, NULL);
    }
}

static int send_byte(volatile uint8_t *bar1, uint32_t base, uint8_t byte, uint32_t flags)
{
    write32(bar1, base + REG_I2C_TXR, byte);
    write32(bar1, base + REG_I2C_CR, flags | I2C_CR_WR);
    (void)read32(bar1, base + REG_I2C_CR);
    int r = wait_tip(bar1, base);
    if (r) return r;
    if (read32(bar1, base + REG_I2C_SR) & I2C_SR_RXACK)
        return -ENXIO;
    return 0;
}

static int recv_byte(volatile uint8_t *bar1, uint32_t base, uint8_t *byte, bool last)
{
    uint32_t cr = I2C_CR_RD | (last ? (I2C_CR_ACK | I2C_CR_STO) : 0);
    write32(bar1, base + REG_I2C_CR, cr);
    (void)read32(bar1, base + REG_I2C_CR);
    int r = wait_tip(bar1, base);
    if (r) return r;
    *byte = (uint8_t)(read32(bar1, base + REG_I2C_RXR) & 0xFF);
    return 0;
}

static int probe(volatile uint8_t *bar1, uint32_t base, uint8_t addr7)
{
    int r = send_byte(bar1, base, (uint8_t)(addr7 << 1), I2C_CR_STA | I2C_CR_STO);
    if (r == -ENXIO) {
        write32(bar1, base + REG_I2C_CR, I2C_CR_STO);
        wait_tip(bar1, base);
    }
    return r;
}

static int wr_regs(volatile uint8_t *bar1, uint32_t base, uint8_t addr7, uint8_t off,
                   const uint8_t *data, int len)
{
    int r = send_byte(bar1, base, (uint8_t)(addr7 << 1), I2C_CR_STA);
    if (r) goto stop;
    for (int i = 0; i <= len; i++) {
        uint8_t b = (i == 0) ? off : data[i - 1];
        uint32_t f = (i == len) ? I2C_CR_STO : 0;
        r = send_byte(bar1, base, b, f);
        if (r) goto stop;
    }
    return 0;
stop:
    write32(bar1, base + REG_I2C_CR, I2C_CR_STO);
    wait_tip(bar1, base);
    return r;
}

static int rd_regs(volatile uint8_t *bar1, uint32_t base, uint8_t addr7, uint8_t off,
                   uint8_t *buf, int len)
{
    int r = send_byte(bar1, base, (uint8_t)(addr7 << 1), I2C_CR_STA);
    if (r) goto stop;
    r = send_byte(bar1, base, off, 0);
    if (r) goto stop;
    r = send_byte(bar1, base, (uint8_t)((addr7 << 1) | 1), I2C_CR_STA);
    if (r) goto stop;
    for (int i = 0; i < len; i++) {
        r = recv_byte(bar1, base, &buf[i], i == len - 1);
        if (r) return r;
    }
    return 0;
stop:
    write32(bar1, base + REG_I2C_CR, I2C_CR_STO);
    wait_tip(bar1, base);
    return r;
}

static int it68051_set_bank(volatile uint8_t *bar1, uint8_t bank)
{
    uint8_t cur = 0;
    if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x0F, &cur, 1) != 0)
        return -1;
    uint8_t new_val = (cur & 0xF8) | (bank & 0x07);
    if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x0F, &new_val, 1) != 0)
        return -1;
    return 0;
}

static int find_qpcie(void)
{
    DIR *dir = opendir(SYSFS_PCI_BASE);
    if (!dir) return -1;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        char p[600], line[128];
        snprintf(p, sizeof(p), "%s/%s/vendor", SYSFS_PCI_BASE, ent->d_name);
        FILE *f = fopen(p, "r");
        if (!f) continue;
        if (!fgets(line, sizeof(line), f)) { fclose(f); continue; }
        fclose(f);
        if (strtoul(line, NULL, 0) != 0x12AB) continue;

        snprintf(p, sizeof(p), "%s/%s/device", SYSFS_PCI_BASE, ent->d_name);
        f = fopen(p, "r");
        if (!f) continue;
        if (!fgets(line, sizeof(line), f)) { fclose(f); continue; }
        fclose(f);
        if (strtoul(line, NULL, 0) != 0xE380) continue;

        snprintf(g_bdf, sizeof(g_bdf), "%s", ent->d_name);
        snprintf(g_device_path, sizeof(g_device_path), "%s/%s", SYSFS_PCI_BASE, ent->d_name);
        closedir(dir);
        return 0;
    }
    closedir(dir);
    return -1;
}

/* Hot-Plug Detect Toggle via MCU */
static int pulse_hpd(volatile uint8_t *bar1)
{
    printf("Toggling HPD (disconnect 300ms -> reconnect)...\n");
    uint8_t ctrl_hpd_low = 0x03; /* bit0=1 (PB.10=1 SQ1 pulls HPD low), bit1=1 (PB.15=1 keep reset released) */
    uint8_t ctrl_hpd_hi  = 0x02; /* bit0=0 (PB.10=0 SQ1 off, HPD pulled high), bit1=1 (PB.15=1 keep reset released) */

    if (wr_regs(bar1, BAR1_OFFSET_I2C_MCU, NUC_ADDR, 0x03, &ctrl_hpd_low, 1) != 0) {
        printf("WARN: Failed to set MCU CTRL to deassert HPD\n");
    }
    usleep(300000); // 300ms

    if (wr_regs(bar1, BAR1_OFFSET_I2C_MCU, NUC_ADDR, 0x03, &ctrl_hpd_hi, 1) != 0) {
        printf("WARN: Failed to set MCU CTRL to assert HPD\n");
    }
    usleep(100000); // 100ms
    printf("HPD re-asserted (PB.10=0, PB.15=1).\n");
    return 0;
}

static int load_edid(volatile uint8_t *bar1)
{
    printf("--- Loading YUAN SC710 4K HDR EDID into IT68051 RAM ---\n");

    /* 1. Ensure Bank 0 */
    it68051_set_bank(bar1, 0);

    /* 2. Configure Reg 0x4B = 0xD9 (Enable EDID RAM at slave address 0x6C) */
    uint8_t reg4b = 0xD9;
    if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4B, &reg4b, 1) != 0) {
        printf("ERROR: Failed to write Reg 0x4B=0xD9\n");
        return -1;
    }
    usleep(50000);

    /* 3. Probe EDID RAM at 0x6C */
    if (probe(bar1, BAR1_OFFSET_I2C_FRONT, EDID_RAM_ADDR) != 0) {
        printf("ERROR: EDID RAM @ 0x%02X did not ACK!\n", EDID_RAM_ADDR);
        return -1;
    }
    printf("EDID RAM @ 0x%02X responded ACK.\n", EDID_RAM_ADDR);

    /* 4. Write 256 bytes in 16-byte blocks */
    for (int blk = 0; blk < 256; blk += 16) {
        if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, EDID_RAM_ADDR, (uint8_t)blk,
                    &g_sc710_edid[blk], 16) != 0) {
            printf("ERROR: Failed to write EDID block at offset 0x%02X\n", blk);
            return -1;
        }
    }
    printf("Successfully wrote 256 bytes to EDID RAM.\n");

    /* 5. Set VSDB Start Address & Port Checksums */
    uint8_t v0 = 0x00, v1 = 0x00, v2 = 0xFF;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC6, &v0, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC7, &v1, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC8, &v2, 1);

    uint8_t sum0 = g_sc710_edid[0x7F];
    uint8_t sum1 = g_sc710_edid[0xFF];
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC9, &sum0, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xCA, &sum1, 1);

    printf("EDID Checksums set: Bank0=0x%02X, Bank1=0x%02X\n", sum0, sum1);
    return 0;
}

static int enable_receiver_afe(volatile uint8_t *bar1)
{
    printf("--- Powering up IT68051 Clock Oscillators & AFE Channels ---\n");

    /* 1. Bank 3: Power up Ring Oscillator and Xtal Oscillator, configure EQ */
    if (it68051_set_bank(bar1, 3) != 0) {
        printf("ERROR: Failed to select Bank 3\n");
        return -1;
    }
    uint8_t ab = 0xCA; /* Reg 0x3AB: Power up XTAL and RING oscillators */
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xAB, &ab, 1);

    uint8_t eq = 0x9F;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x27, &eq, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x28, &eq, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x29, &eq, 1);

    uint8_t cs0 = 0x1B, cs1 = 0x03;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &cs0, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x21, &cs1, 1);

    uint8_t skew = 0x00;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x2D, &skew, 1);

    /* 2. Bank 0: Power up Port 0 logic, channels, and termination */
    it68051_set_bank(bar1, 0);
    uint8_t p0_pwd = 0x00; /* Reg 0x26 = 0: All digital logic, IPLL, OPLL, channels active */
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x26, &p0_pwd, 1);

    uint8_t rterm = 0x00; /* Reg 0x27 = 0: All channel differential terminations active */
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x27, &rterm, 1);

    uint8_t afe_all = 0x00; /* Reg 0x28 = 0: All AFEs active */
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x28, &afe_all, 1);

    uint8_t r55 = 0xFF;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x55, &r55, 1);

    printf("Oscillators & AFEs powered up, TMDS terminations active.\n");
    return 0;
}

static int enable_ttl_output(volatile uint8_t *bar1)
{
    printf("--- Configuring IT68051 Output Bus (TTL Dual-Pixel + I2S) ---\n");

    /* Switch to Bank 1 */
    if (it68051_set_bank(bar1, 1) != 0) {
        printf("ERROR: Failed to select Bank 1\n");
        return -1;
    }

    /* 0xC0: Reg_TTLMode=1 (Dual pixel), Reg_EnTTLOut=1 (Enable TTL clock) -> 0x03 */
    uint8_t c0 = 0x03;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC0, &c0, 1);

    /* 0xC6: Reg_TriDVDIO=0, Reg_TriVIO=0 (Release video TTL IO tri-state) -> 0x00 */
    uint8_t c6 = 0x00;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC6, &c6, 1);

    /* 0xC7: Reg_TriI2SIO=0, Reg_TriSPDIF=0 (Release audio IO tri-state) -> 0x00 */
    uint8_t c7 = 0x00;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC7, &c7, 1);

    /* 0xC9, 0xCA: Set driving strength to 10mA */
    uint8_t drive = 0xAA;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC9, &drive, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xCA, &drive, 1);

    /* Restore Bank 0 */
    it68051_set_bank(bar1, 0);

    printf("TTL Dual-Pixel Video & I2S Audio Outputs Enabled (Active Drivers).\n");
    return 0;
}

static void show_status(volatile uint8_t *bar1)
{
    uint8_t id[5] = {0};
    it68051_set_bank(bar1, 0);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x00, id, 5);
    printf("====================================================\n");
    printf(" IT68051 Receiver Hardware Diagnostics\n");
    printf("====================================================\n");
    printf("Vendor ID: 0x%02X%02X ('%c%c')\n", id[1], id[0], id[0], id[1]);
    printf("Device ID: 0x%02X%02X (IT%02X%02X)\n", id[3], id[2], id[3], id[2]);
    printf("Revision : 0x%02X\n", id[4]);

    uint8_t s13 = 0, s19 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x13, &s13, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x19, &s19, 1);

    printf("\n[HDMI Link Telemetry (Reg 0x13=0x%02X, 0x19=0x%02X)]\n", s13, s19);
    printf("  Port 0 +5V Cable Det : %s\n", (s13 & 0x01) ? "YES (Plugged)" : "NO (Unplugged)");
    printf("  HDMI/DVI Mode        : %s\n", (s13 & 0x02) ? "HDMI" : "DVI");
    printf("  TMDS Clock Detect    : %s\n", (s13 & 0x04) ? "YES" : "NO");
    printf("  TMDS Clock Valid     : %s\n", (s13 & 0x08) ? "YES" : "NO");
    printf("  TMDS Clock Stable    : %s\n", (s13 & 0x10) ? "YES" : "NO");
    printf("  IPLL Lock            : %s\n", (s13 & 0x20) ? "LOCKED" : "UNLOCKED");
    printf("  Symbol Lock          : %s\n", (s13 & 0x80) ? "LOCKED" : "UNLOCKED");
    printf("  SCDT (Video Stable)  : %s\n", (s19 & 0x80) ? "LOCKED (Stable)" : "NO");
    printf("  OPLL Lock            : %s\n", (s19 & 0x10) ? "LOCKED" : "UNLOCKED");

    if (s19 & 0x80) {
        uint8_t timing[24] = {0};
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x98, timing, 24);
        uint32_t hactive = ((timing[0x9E - 0x98] & 0x3F) << 8) | timing[0x9D - 0x98];
        uint32_t vactive = ((timing[0xA2 - 0x98] & 0x3F) << 8) | timing[0xA1 - 0x98];
        uint32_t htotal  = ((timing[0x9C - 0x98] & 0x3F) << 8) | timing[0x9B - 0x98];
        uint32_t vtotal  = ((timing[0xA0 - 0x98] & 0x3F) << 8) | timing[0x9F - 0x98];

        printf("\n[Decoded Video Timing]\n");
        printf("  Active Resolution    : %ux%u\n", hactive, vactive);
        printf("  Total Dimensions     : %ux%u\n", htotal, vtotal);
    }

    /* Bank 1 TTL status */
    it68051_set_bank(bar1, 1);
    uint8_t b1[8] = {0};
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC0, b1, 8);
    it68051_set_bank(bar1, 0);

    printf("\n[Output Bus Status (Bank 1 0xC0=0x%02X, 0xC6=0x%02X, 0xC7=0x%02X)]\n",
           b1[0], b1[6], b1[7]);
    printf("  TTL Module Clock     : %s\n", (b1[0] & 0x02) ? "ENABLED" : "DISABLED");
    printf("  TTL Mode             : %s\n", (b1[0] & 0x01) ? "Dual Pixel" : "Single Pixel");
    printf("  Video Data IO (QD)   : %s\n", (b1[6] == 0x00) ? "DRIVING (Active)" : "TRISTATED");
    printf("  Audio I2S IO         : %s\n", (b1[7] == 0x00) ? "DRIVING (Active)" : "TRISTATED");
    printf("====================================================\n");
}

static void show_fpga_probe(volatile uint8_t *bar0)
{
    if (!bar0) return;
    uint32_t ver    = read32(bar0, BAR0_REG_C_VERSION);
    uint32_t status = read32(bar0, BAR0_REG_HDMI_RX_STATUS);
    uint32_t width  = read32(bar0, BAR0_REG_HDMI_RX_WIDTH);
    uint32_t height = read32(bar0, BAR0_REG_HDMI_RX_HEIGHT);
    uint32_t clk_hz = read32(bar0, BAR0_REG_HDMI_RX_PCLK_HZ);
    uint32_t ctrl   = read32(bar0, BAR0_REG_HDMI_TX_CTRL);
    uint32_t aud    = read32(bar0, BAR0_REG_HDMI_RX_AUDIO);

    printf("\n[FPGA PL-Side Hardware Probe Telemetry (C_VERSION=0x%08X)]\n", ver);
    printf("  BAR0 0x0600 Raw Status : 0x%08X\n", status);
    printf("  TM0_PCLK Active (Bit 0): %s (%.1f MHz)\n",
           (status & 0x01) ? "YES" : "NO",
           (double)((status >> 16) & 0xFFFF) / 10.0);
    printf("  Link Lock       (Bit 2): %s\n", (status & 0x04) ? "LOCKED" : "UNLOCKED");
    printf("  Video Stream Up (Bit 3): %s\n", (status & 0x08) ? "YES (Stable)" : "NO");
    printf("  Audio I2S SCK   (Bit 4): %s\n", (status & 0x10) ? "ACTIVE" : "INACTIVE");
    printf("  Audio I2S Data  (Bit 5): %s\n", (status & 0x20) ? "ACTIVE" : "INACTIVE");
    printf("  Live Frame Rate (FPS)  : %u fps\n", (status >> 8) & 0xFF);
    printf("  Hardware Measured Res  : %ux%u\n", width, height);
    printf("  Measured Pixel Clock   : %u Hz (%.3f MHz)\n", clk_hz, (double)clk_hz / 1e6);
    printf("  Audio Sample Rate (WS) : %u Hz (Frames: %u)\n", aud & 0xFFFF, (aud >> 16) & 0xFFFF);
    printf("  Hardware Capture Source: Video=%s, Audio=%s (CTRL=0x%02X)\n",
           (ctrl & 0x01) ? "Live HDMI RX" : "Internal TPG",
           (ctrl & 0x02) ? "Live HDMI I2S" : "Audio Pattern Gen",
           ctrl);
}

static void monitor_loop(volatile uint8_t *bar1, volatile uint8_t *bar0)
{
    printf("Starting HDMI signal monitor loop (Ctrl+C to stop)...\n");
    fflush(stdout);
    uint8_t last_s13 = 0xFF, last_s19 = 0xFF;
    uint32_t last_h = 0, last_v = 0;
    int tick = 0;

    while (1) {
        uint8_t s13 = 0, s19 = 0;
        it68051_set_bank(bar1, 0);
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x13, &s13, 1);
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x19, &s19, 1);

        uint32_t hactive = 0, vactive = 0;
        if (s19 & 0x80) {
            uint8_t timing[24] = {0};
            rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x98, timing, 24);
            hactive = ((timing[0x9E - 0x98] & 0x3F) << 8) | timing[0x9D - 0x98];
            vactive = ((timing[0xA2 - 0x98] & 0x3F) << 8) | timing[0xA1 - 0x98];
        }

        uint32_t fpga_status = bar0 ? read32(bar0, BAR0_REG_HDMI_RX_STATUS) : 0;
        uint32_t fpga_w      = bar0 ? read32(bar0, BAR0_REG_HDMI_RX_WIDTH) : 0;
        uint32_t fpga_h      = bar0 ? read32(bar0, BAR0_REG_HDMI_RX_HEIGHT) : 0;
        double   fpga_mhz    = (double)((fpga_status >> 16) & 0xFFFF) / 10.0;

        bool changed = (s13 != last_s13 || s19 != last_s19 || hactive != last_h || vactive != last_v);
        if (changed || (++tick >= 10)) { // Every change or every 1.5s
            tick = 0;
            time_t now = time(NULL);
            struct tm *t = localtime(&now);
            printf("[%02d:%02d:%02d] Chip: 5V=%d TMDS_CLK=%d IPLL=%d SYM=%d SCDT=%d (%s) | PL: PCLK=%.1fMHz Lock=%d Res=%ux%u FPS=%u\n",
                   t->tm_hour, t->tm_min, t->tm_sec,
                   !!(s13 & 0x01), !!(s13 & 0x04), !!(s13 & 0x20), !!(s13 & 0x80),
                   !!(s19 & 0x80), (s19 & 0x80) ? "SIGNAL LOCKED" : "NO SIGNAL",
                   fpga_mhz, !!(fpga_status & 0x08),
                   fpga_w, fpga_h, (fpga_status >> 8) & 0xFF);
            fflush(stdout);
            last_s13 = s13;
            last_s19 = s19;
            last_h = hactive;
            last_v = vactive;
        }
        usleep(150000); // 150ms
    }
}

int main(int argc, char **argv)
{
    bool do_status   = false;
    bool do_init     = false;
    bool do_edid     = false;
    bool do_hpd      = false;
    bool do_ttl      = false;
    bool do_monitor  = false;
    bool do_probe    = false;
    bool do_mux_hdmi = false;
    bool do_mux_tpg  = false;

    static struct option long_options[] = {
        {"status",    no_argument, 0, 's'},
        {"init",      no_argument, 0, 'i'},
        {"edid",      no_argument, 0, 'e'},
        {"hpd",       no_argument, 0, 'h'},
        {"ttl",       no_argument, 0, 't'},
        {"monitor",   no_argument, 0, 'm'},
        {"probe",     no_argument, 0, 'p'},
        {"mux-hdmi",  no_argument, 0, 1001},
        {"mux-tpg",   no_argument, 0, 1002},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "siehtmp", long_options, NULL)) != -1) {
        switch (opt) {
            case 's': do_status   = true; break;
            case 'i': do_init     = true; break;
            case 'e': do_edid     = true; break;
            case 'h': do_hpd      = true; break;
            case 't': do_ttl      = true; break;
            case 'm': do_monitor  = true; break;
            case 'p': do_probe    = true; break;
            case 1001: do_mux_hdmi = true; break;
            case 1002: do_mux_tpg  = true; break;
            default:
                printf("Usage: %s [--status|-s] [--init|-i] [--edid|-e] [--hpd|-h] [--ttl|-t] [--monitor|-m] [--probe|-p] [--mux-hdmi] [--mux-tpg]\n", argv[0]);
                return 1;
        }
    }

    if (!do_status && !do_init && !do_edid && !do_hpd && !do_ttl && !do_monitor && !do_probe && !do_mux_hdmi && !do_mux_tpg)
        do_status = true;

    if (find_qpcie() < 0) {
        printf("ERROR: QPCIe device (12ab:e380) not found!\n");
        return 1;
    }

    bool had_drv = (access("/sys/module/qpcie", F_OK) == 0);
    if (had_drv) {
        printf("Temporarily unloading qpcie driver for direct BAR MMIO...\n");
        system("rmmod qpcie 2>/dev/null");
        usleep(200000);
    }

    /* Map BAR0 (1M) */
    char rp0[600];
    snprintf(rp0, sizeof(rp0), "%s/resource0", g_device_path);
    int fd0 = open(rp0, O_RDWR | O_SYNC);
    volatile uint8_t *bar0 = NULL;
    if (fd0 >= 0) {
        bar0 = mmap(NULL, 1048576, PROT_READ | PROT_WRITE, MAP_SHARED, fd0, 0);
    }

    /* Map BAR1 (64K) */
    char rp[600];
    snprintf(rp, sizeof(rp), "%s/resource1", g_device_path);
    int fd = open(rp, O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open resource1 (need sudo)");
        if (bar0) { munmap((void *)bar0, 1048576); close(fd0); }
        return 1;
    }

    volatile uint8_t *bar1 = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bar1 == MAP_FAILED) {
        perror("mmap resource1");
        close(fd);
        if (bar0) { munmap((void *)bar0, 1048576); close(fd0); }
        return 1;
    }

    /* Initialize FRONT I2C Master and MCU I2C Master (PRER=249 ~100kHz) */
    write32(bar1, BAR1_OFFSET_I2C_FRONT + REG_I2C_PRER_LO, 249 & 0xFF);
    write32(bar1, BAR1_OFFSET_I2C_FRONT + REG_I2C_PRER_HI, (249 >> 8) & 0xFF);
    write32(bar1, BAR1_OFFSET_I2C_FRONT + REG_I2C_CTR, I2C_CTR_EN);

    write32(bar1, BAR1_OFFSET_I2C_MCU + REG_I2C_PRER_LO, 249 & 0xFF);
    write32(bar1, BAR1_OFFSET_I2C_MCU + REG_I2C_PRER_HI, (249 >> 8) & 0xFF);
    write32(bar1, BAR1_OFFSET_I2C_MCU + REG_I2C_CTR, I2C_CTR_EN);

    if (do_mux_hdmi && bar0) {
        printf("Switching capture source to Live HDMI RX (Video Ch0 + Audio Ch0)...\n");
        write32(bar0, BAR0_REG_HDMI_TX_CTRL, 0x03);
        usleep(50000);
        show_fpga_probe(bar0);
    }

    if (do_mux_tpg && bar0) {
        printf("Switching capture source to Internal TPG & Tone Gen...\n");
        write32(bar0, BAR0_REG_HDMI_TX_CTRL, 0x00);
        usleep(50000);
        show_fpga_probe(bar0);
    }

    if (do_init) {
        printf("====================================================\n");
        printf(" 🚀 Executing IT68051 Receiver Full Bringup\n");
        printf("====================================================\n");
        enable_receiver_afe(bar1);
        load_edid(bar1);
        enable_ttl_output(bar1);
        pulse_hpd(bar1);
        printf("Waiting 2.0s for TMDS clock & video lock...\n");
        sleep(2);
        show_status(bar1);
        if (bar0) show_fpga_probe(bar0);
    } else {
        if (do_edid) load_edid(bar1);
        if (do_ttl)  enable_ttl_output(bar1);
        if (do_hpd)  pulse_hpd(bar1);
        if (do_status) {
            show_status(bar1);
            if (bar0) show_fpga_probe(bar0);
        }
        if (do_probe && bar0) show_fpga_probe(bar0);
        if (do_monitor) monitor_loop(bar1, bar0);
    }

    munmap((void *)bar1, 65536);
    close(fd);
    if (bar0) {
        munmap((void *)bar0, 1048576);
        close(fd0);
    }

    if (had_drv) {
        printf("Restoring qpcie driver...\n");
        system("insmod /home/nvidia/qpcie/driver/qpcie.ko 2>/dev/null");
    }

    return 0;
}
