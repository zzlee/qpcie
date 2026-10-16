/*
 * qpcie_it68051_tool.c - QPCIe A50T IT68051 HDMI Receiver Diagnostic & Init Tool
 *
 * Direct BAR1 MMIO access:
 *   - FRONT I2C master at BAR1 0x3000 (IT68051 @ 0x48, EDID RAM @ 0x6C, TLV320 @ 0x18)
 *   - MCU I2C master at BAR1 0x5000 (NUC100 slave @ 0x2A)
 *
 * Capabilities:
 *   --status      Read IT68051 chip ID, cable 5V, TMDS clock, and sync detect
 *   --init        Calibrate B1 RX, load 1080p EDID, pulse MCU HPD control, enable TTL
 *   --edid        Load 256-byte EDID into IT68051 EDID RAM
 *   --hpd         Pulse MCU HPD control; actual electrical HPD depends on board population
 *   --ttl         Program TTL video and I2S audio output registers
 *   --downscale-1080p  VIC97/8-bit/BT.709 limited YUV444 -> RGB1080p single-pixel SDR
 *   --monitor     Passively log HDMI telemetry (no repeated EQ/PLL resets)
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

#define BAR0_REG_C_VERSION        0x0004
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
static bool g_single_pixel;
static bool g_downscale_1080p;
static int g_i2c_error;

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

/* Genuine YUAN SC710 1080p60 FHD EDID Table (256 bytes) */
static const uint8_t g_sc710_edid_1080p[256] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x66, 0xAE, 0x90, 0x06, 0x74, 0x17, 0x31, 0x84,
    0x08, 0x1D, 0x01, 0x03, 0x80, 0x3C, 0x22, 0x78, 0x2A, 0xF6, 0xD5, 0xA7, 0x54, 0x4B, 0x9E, 0x25,
    0x0D, 0x50, 0x54, 0xBF, 0xEF, 0x80, 0x71, 0x4F, 0x81, 0x40, 0x81, 0x80, 0x81, 0xC0, 0x81, 0x00,
    0x95, 0x00, 0xB3, 0x00, 0xD1, 0xC0, 0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C,
    0x45, 0x00, 0x54, 0x4F, 0x21, 0x00, 0x00, 0x1E, 0x01, 0x1D, 0x00, 0x72, 0x51, 0xD0, 0x1E, 0x20,
    0x6E, 0x28, 0x55, 0x00, 0x54, 0x4F, 0x21, 0x00, 0x00, 0x1E, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x53,
    0x43, 0x20, 0x37, 0x31, 0x30, 0x20, 0x46, 0x48, 0x44, 0x0A, 0x20, 0x20, 0x00, 0x00, 0x00, 0xFD,
    0x00, 0x18, 0x4B, 0x0F, 0x55, 0x11, 0x00, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x01, 0x2C,
    0x02, 0x03, 0x1B, 0xF1, 0x48, 0x10, 0x04, 0x03, 0x02, 0x01, 0x1F, 0x14, 0x13, 0x23, 0x09, 0x07,
    0x07, 0x83, 0x01, 0x00, 0x00, 0x65, 0x03, 0x0C, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05
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
    g_i2c_error = 1;
    fprintf(stderr, "I2C write failed: slave=%02X reg=%02X rc=%d\n", addr7, off, r);
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
        if (r) goto stop;
    }
    return 0;
stop:
    write32(bar1, base + REG_I2C_CR, I2C_CR_STO);
    wait_tip(bar1, base);
    g_i2c_error = 1;
    fprintf(stderr, "I2C read failed: slave=%02X reg=%02X rc=%d\n", addr7, off, r);
    return r;
}

static int it68051_set_bank(volatile uint8_t *bar1, uint8_t bank)
{
    if (bank > 7) { g_i2c_error = 1; return -EINVAL; }
    uint8_t cur = 0;
    if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x0F, &cur, 1) != 0)
        return -1;
    uint8_t new_val = (cur & 0xF8) | (bank & 0x07);
    if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x0F, &new_val, 1) != 0)
        return -1;
    if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x0F, &cur, 1) ||
        (cur & 7) != bank) {
        g_i2c_error = 1;
        return -EIO;
    }
    return 0;
}

/* 0x20[4] gates the register RCLK on the B1 device. I2C ACK alone
 * does not prove that clocked configuration registers accepted a write. */
static int it68051_enable_register_clock(volatile uint8_t *bar1)
{
    uint8_t gate, rb;
    if (it68051_set_bank(bar1, 0) ||
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &gate, 1))
        return -EIO;
    uint8_t enabled = gate & ~0x10;
    if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &enabled, 1))
        return -EIO;
    usleep(1000);
    if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &rb, 1) ||
        (rb & 0x10)) {
        fprintf(stderr, "ERROR: IT68051 register clock remains gated\n");
        return -EIO;
    }
    return 0;
}

static int it68051_update(volatile uint8_t *bar1, uint8_t bank, uint8_t reg,
                         uint8_t mask, uint8_t value)
{
    uint8_t old = 0, rb;
    if (it68051_set_bank(bar1, bank) ||
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, reg, &old, 1)) return -EIO;
    uint8_t next = (old & ~mask) | (value & mask);
    if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, reg, &next, 1) ||
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, reg, &rb, 1)) return -EIO;
    if ((rb & mask) != (next & mask)) {
        g_i2c_error = 1;
        fprintf(stderr, "ERROR: B%u:%02X write %02X read %02X mask %02X\n",
                bank, reg, next, rb, mask);
        return -EIO;
    }
    return 0;
}

/* Port-0 analog offset calibration, required before equalization on B1.
 * Cross-checked against iTE6805 MCUSRC 1.31 (2019-03-05), Init_CAOF.
 * Only port 0 is connected on this board. */
static int it68051_calibrate_port0(volatile uint8_t *bar1)
{
    const uint8_t regs[] = {0xA0, 0xA1, 0xA2};
    if (it68051_update(bar1, 3, 0x3A, 0x86, 0x02)) return -EIO;
    for (size_t i = 0; i < sizeof(regs); i++)
        if (it68051_update(bar1, 3, regs[i], 0x80, 0x80)) return -EIO;
    if (it68051_update(bar1, 3, 0xA4, 0x08, 0x08) ||
        it68051_update(bar1, 3, 0x3B, 0xC0, 0) ||
        it68051_update(bar1, 3, 0xA7, 0x10, 0x10) ||
        it68051_update(bar1, 3, 0x48, 0x80, 0x80) ||
        it68051_update(bar1, 0, 0x29, 0x01, 0x01) ||
        it68051_update(bar1, 0, 0x2A, 0x41, 0x41)) return -EIO;
    usleep(10000);
    if (it68051_update(bar1, 0, 0x2A, 0x40, 0) ||
        it68051_update(bar1, 0, 0x24, 0x04, 0x04)) return -EIO;
    for (uint8_t r = 0x25; r <= 0x28; r++)
        if (it68051_update(bar1, 0, r, 0xFF, 0)) return -EIO;
    if (it68051_update(bar1, 0, 0x3C, 0x10, 0)) return -EIO;
    uint8_t irq = 0x30;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x08, &irq, 1);
    if (it68051_update(bar1, 3, 0x3A, 0x80, 0x80)) return -EIO;
    bool done = false;
    for (int n = 0; n < 100; n++) {
        it68051_set_bank(bar1, 0);
        if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x08, &irq, 1)) break;
        if (irq & 0x30) { done = (irq & 0x30) == 0x10; break; }
        usleep(10000);
    }
    printf("Port 0 CAOF: IRQ08=0x%02X %s\n", irq, done ? "PASS" : "FAIL/timeout");
    /* Always release calibration reset after completion or timeout. */
    int rc = it68051_update(bar1, 0, 0x24, 0x04, 0);
    rc |= it68051_update(bar1, 0, 0x29, 0x01, 0);
    rc |= it68051_update(bar1, 0, 0x3C, 0x10, 0x10);
    rc |= it68051_update(bar1, 3, 0x3A, 0x80, 0);
    for (size_t i = 0; i < sizeof(regs); i++)
        rc |= it68051_update(bar1, 3, regs[i], 0x80, 0);
    it68051_set_bank(bar1, 0);
    return (done && !rc) ? 0 : -EIO;
}

/* Read-only factory oscillator calibration through the indirect read window.
 * No OTP program command is issued. Watchdog thresholds must match this chip,
 * not the example oscillator frequency in a different receiver's driver. */
static int it68051_calibrate_clock(volatile uint8_t *bar1)
{
    uint8_t key = 0xC3;
    it68051_set_bank(bar1, 0);
    if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xF8, &key, 1)) return -EIO;
    key = 0xA5;
    if (wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xF8, &key, 1)) return -EIO;
    const uint8_t addresses[] = {0, 1, 0xB0, 0xB1};
    uint8_t bytes[4][2] = {{0}};
    int rc = it68051_update(bar1, 1, 0x5F, 0xFF, 4);
    rc |= it68051_update(bar1, 1, 0x5F, 0xFF, 5);
    rc |= it68051_update(bar1, 1, 0x58, 0xFF, 0x12);
    rc |= it68051_update(bar1, 1, 0x58, 0xFF, 0x02);
    rc |= it68051_update(bar1, 1, 0x57, 0xFF, 1);
    uint8_t block = 0;
    for (int i = 0; i < 4 && !rc; i++) {
        if (i == 2 && bytes[0][0] == 0xFF && bytes[0][1] == 0xFF &&
            bytes[1][0] == 0 && bytes[1][1] == 0) block = 4;
        rc |= it68051_update(bar1, 1, 0x50, 0xFF, block);
        rc |= it68051_update(bar1, 1, 0x51, 0xFF, addresses[i]);
        rc |= it68051_update(bar1, 1, 0x54, 0xFF, 4);
        rc |= rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x61, bytes[i], 2);
    }
    rc |= it68051_update(bar1, 1, 0x5F, 0xFF, 0);
    it68051_set_bank(bar1, 0);
    key = 0;
    rc |= wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xF8, &key, 1);
    uint32_t osc_khz = bytes[2][0] | ((uint32_t)bytes[2][1] << 8) |
                       ((uint32_t)bytes[3][0] << 16);
    if ((bytes[3][1] & 0xC0) == 0xC0) osc_khz /= 100;
    if (rc || osc_khz < 20000 || osc_khz > 70000) {
        fprintf(stderr, "ERROR: factory oscillator calibration invalid (%u kHz)\n", osc_khz);
        return -EIO;
    }
    uint32_t rclk = osc_khz / 2;
    uint32_t timer = rclk + rclk / 10;
    rc |= it68051_update(bar1, 3, 0xAA, 0x1F, 0x0C);
    rc |= it68051_update(bar1, 0, 0x91, 0x3F, timer / 1000);
    rc |= it68051_update(bar1, 0, 0x92, 0xFF, (timer % 1000) * 256 / 1000);
    rc |= it68051_update(bar1, 0, 0x44, 0xFF, (osc_khz / 312) / 5);
    rc |= it68051_update(bar1, 0, 0x45, 0xFF, osc_khz / 312);
    rc |= it68051_update(bar1, 0, 0x46, 0xFF, osc_khz / 2320);
    rc |= it68051_update(bar1, 0, 0x47, 0xFF, osc_khz / 5312);
    rc |= it68051_update(bar1, 1, 0xFD, 0xFF, rclk / 100);
    rc |= it68051_update(bar1, 1, 0xFE, 0xBF, 0x9C);
    it68051_set_bank(bar1, 0);
    printf("Factory oscillator: %u kHz; watchdog and B1 SCDC timers calibrated\n", osc_khz);
    return rc ? -EIO : 0;
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
    printf("Pulsing MCU HPD control (SM1 is NC on the schematic; physical HPD requires population/measurement verification)...\n");
    uint8_t ctrl_hpd_low = 0x03; /* bit0=1 (PB.10=1 SQ1 pulls HPD low), bit1=1 (PB.15=1 keep reset released) */
    uint8_t ctrl_hpd_hi  = 0x02; /* bit0=0 (PB.10=0 SQ1 off, HPD pulled high), bit1=1 (PB.15=1 keep reset released) */

    if (wr_regs(bar1, BAR1_OFFSET_I2C_MCU, NUC_ADDR, 0x03, &ctrl_hpd_low, 1) != 0) {
        printf("WARN: Failed to set MCU CTRL to deassert HPD\n");
    }

    /* Reset SCDC while HPD is low (IT68051 Chap 9 requirement) */
    it68051_set_bank(bar1, 0);
    uint8_t scdc_rst = 0x12;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC5, &scdc_rst, 1);
    usleep(150000); // 150ms
    uint8_t scdc_run = 0x02;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC5, &scdc_run, 1);

    /* Clear all IRQs */
    uint8_t ff = 0xFF;
    for (uint8_t r = 0x05; r <= 0x09; r++)
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, r, &ff, 1);
    for (uint8_t r = 0x10; r <= 0x12; r++)
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, r, &ff, 1);

    sleep(2); // 2.0s disconnect so source PC graphics driver flushes state and re-reads EDID!

    if (wr_regs(bar1, BAR1_OFFSET_I2C_MCU, NUC_ADDR, 0x03, &ctrl_hpd_hi, 1) != 0) {
        printf("WARN: Failed to set MCU CTRL to assert HPD\n");
    }
    usleep(300000); // 300ms
    printf("MCU control released (PB.10=0, PB.15=1); source renegotiation is NOT proven by this write.\n");
    return 0;
}

static uint8_t edid_pa_offset(const uint8_t *edid)
{
    if (edid[126] != 1 || edid[128] != 2 || edid[129] != 3 ||
        edid[130] < 4 || edid[130] > 127) return 0;
    unsigned end = 128 + edid[130];
    for (unsigned pos = 132; pos < end;) {
        unsigned len = edid[pos] & 31;
        if (pos + 1 + len > end) return 0;
        if ((edid[pos] >> 5) == 3 && len >= 5 &&
            edid[pos+1] == 3 && edid[pos+2] == 0x0C && edid[pos+3] == 0)
            return pos + 4;
        pos += len + 1;
    }
    return 0;
}

static int load_edid(volatile uint8_t *bar1, int is_4k)
{
    const uint8_t *edid = is_4k ? g_sc710_edid : g_sc710_edid_1080p;
    const char *desc = is_4k ? "YUAN SC710 4K HDR EDID" : "YUAN SC710 1080p60 FHD EDID";

    printf("--- Loading %s into IT68051 RAM (Official ITE Sequence) ---\n", desc);

    /* 1. Ensure Bank 0 */
    it68051_set_bank(bar1, 0);

    /* 2. Configure Reg 0x4B = 0xD9 (Enable EDID RAM at slave address 0x6C) */
    uint8_t reg4b = 0xD9;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4B, &reg4b, 1);
    usleep(20000);

    /* 3. Probe EDID RAM at 0x6C */
    if (probe(bar1, BAR1_OFFSET_I2C_FRONT, EDID_RAM_ADDR) != 0) {
        printf("ERROR: EDID RAM @ 0x%02X did not ACK!\n", EDID_RAM_ADDR);
        return -1;
    }
    printf("EDID RAM @ 0x%02X responded ACK.\n", EDID_RAM_ADDR);

    /* 4. Configure VSDB Address & Physical Address */
    /* Hardware substitutes PA bytes at C6, including for host DDC reads.
     * C6=0 would replace the EDID header, not disable PA substitution. */
    uint8_t c6 = edid_pa_offset(edid), c7 = 0x10, c8 = 0x00;
    if (!c6) { fprintf(stderr, "ERROR: invalid HDMI VSDB/PA in EDID\n"); return -EINVAL; }
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC6, &c6, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC7, &c7, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC8, &c8, 1);

    /* 5. Write Block 0 (bytes 0x00..0x7E) via single-byte writes */
    for (int i = 0; i < 0x7F; i++) {
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, EDID_RAM_ADDR, (uint8_t)i, &edid[i], 1);
    }
    /* Write Block 0 checksum to Bank 0 Reg 0xC9 */
    uint8_t sum0 = edid[0x7F];
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC9, &sum0, 1);

    /* 6. Write Block 1 (bytes 0x80..0xFE) via single-byte writes */
    for (int i = 0x80; i < 0xFF; i++) {
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, EDID_RAM_ADDR, (uint8_t)i, &edid[i], 1);
    }
    /* Write Block 1 checksum to Bank 0 Reg 0xCA */
    uint8_t sum1 = edid[0xFF];
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xCA, &sum1, 1);

    /* Verify first 8 bytes and checksum registers */
    uint8_t hdr[8] = {0};
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, EDID_RAM_ADDR, 0x00, hdr, 8);
    uint8_t rb_c9 = 0, rb_ca = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC9, &rb_c9, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xCA, &rb_ca, 1);

    printf("EDID Header: %02X %02X %02X %02X %02X %02X %02X %02X\n",
           hdr[0], hdr[1], hdr[2], hdr[3], hdr[4], hdr[5], hdr[6], hdr[7]);
    printf("EDID Checksums in Bank 0: 0xC9=0x%02X (exp 0x%02X), 0xCA=0x%02X (exp 0x%02X)\n",
           rb_c9, sum0, rb_ca, sum1);

    unsigned mismatches = 0;
    for (int offset = 0; offset < 256; offset += 16) {
        uint8_t bytes[16];
        if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, EDID_RAM_ADDR, offset, bytes, sizeof(bytes))) return -EIO;
        for (int j = 0; j < 16; j++) {
            int index = offset + j;
            /* Checksum locations are hardware-substituted on DDC, not RAM. */
            if (index != 127 && index != 255 && bytes[j] != edid[index]) mismatches++;
        }
    }
    uint8_t physical[3] = {0};
    if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC6, physical, 3)) return -EIO;
    if (g_i2c_error || mismatches || rb_c9 != sum0 || rb_ca != sum1 ||
        physical[0] != c6 || physical[1] != c7 || physical[2] != c8) {
        fprintf(stderr, "ERROR: EDID verification failed (%u RAM mismatches)\n", mismatches);
        return -EIO;
    }
    printf("EDID verified: 254 RAM bytes, 2 DDC checksum registers, PA offset=0x%02X\n", c6);

    return 0;
}

struct it6805_reg_seq {
    uint8_t bank;
    uint8_t reg;
    uint8_t mask;
    uint8_t val;
};

static const struct it6805_reg_seq g_it6805_init_table[] = {
    { 0x00, 0x22, 0xFF, 0x08 },
    { 0x00, 0x22, 0xFF, 0x17 },
    { 0x00, 0x23, 0xFF, 0x1F },
    { 0x00, 0x2B, 0xFF, 0x1F },
    { 0x00, 0x24, 0xFF, 0xF8 },
    { 0x00, 0x22, 0xFF, 0x10 },
    { 0x00, 0x23, 0xFF, 0xA0 },
    { 0x00, 0x2B, 0xFF, 0xA0 },
    { 0x00, 0x24, 0xFF, 0x00 },
    { 0x00, 0x34, 0xFF, 0x00 }, // Unegate all backend clocks including PCLK
    { 0x00, 0x35, 0xFF, 0x00 }, // Ensure MainPortSel = 0 (Port 0)
    { 0x03, 0xAA, 0xFF, 0xEC },
    { 0x03, 0xAC, 0xFF, 0x40 },
    { 0x00, 0x3A, 0xFF, 0x89 },
    { 0x00, 0x49, 0xFF, 0xE1 },
    { 0x00, 0x43, 0xFF, 0x01 },
    { 0x04, 0x43, 0xFF, 0x01 },
    { 0x04, 0x3A, 0xFF, 0x89 },
    { 0x03, 0xA8, 0xFF, 0x0B },
    { 0x00, 0x4F, 0xFF, 0x84 }, // Disable video auto-mute; leave data gate bit 5 clear
    { 0x00, 0x44, 0xFF, 0x19 },
    { 0x00, 0x46, 0xFF, 0x15 },
    { 0x00, 0x47, 0xFF, 0x88 },
    { 0x00, 0xD9, 0xFF, 0x00 },
    { 0x00, 0xF0, 0xFF, 0x78 },
    { 0x00, 0xF1, 0xFF, 0x10 },
    { 0x03, 0x3A, 0xFF, 0x02 },
    { 0x00, 0x28, 0xFF, 0x88 },
    { 0x00, 0x6E, 0xFF, 0x80 },
    { 0x00, 0x77, 0xFF, 0x87 },
    { 0x00, 0x7B, 0xFF, 0x00 },
    { 0x00, 0x86, 0xFF, 0x00 },
    { 0x00, 0x36, 0xFF, 0x06 },
    { 0x00, 0x8F, 0xFF, 0x41 },
    { 0x01, 0xC0, 0xFF, 0x43 }, // Dual-Pixel + Enable TTL Out!
    { 0x01, 0xC1, 0xFF, 0x01 }, // Dual-Pixel Mode
    { 0x01, 0xC4, 0xFF, 0x00 }, // DCLK normal phase
    { 0x01, 0xC5, 0xFF, 0x00 }, // Release all video IO tristates
    { 0x01, 0xC6, 0xFF, 0x00 }, // Release all dual-pixel data tristates
    { 0x01, 0xC7, 0xFF, 0x00 }, // Release all audio I2S tristates
    { 0x01, 0xC8, 0xFF, 0x00 }, // Release all control tristates
    { 0x01, 0xC9, 0xFF, 0x99 }, // 10mA driving strength on Video
    { 0x01, 0xCA, 0xFF, 0x99 }, // 10mA driving strength on Audio
    { 0x00, 0x86, 0x0C, 0x08 },
    { 0x00, 0x81, 0x80, 0x80 },
    { 0x01, 0x10, 0xFF, 0x00 },
    { 0x01, 0x11, 0xFF, 0x00 },
    { 0x01, 0x12, 0xFF, 0x00 },
    { 0x01, 0x13, 0xFF, 0x00 },
    { 0x01, 0x28, 0xFF, 0x00 },
    { 0x01, 0x29, 0xFF, 0x00 },
    { 0x01, 0x2A, 0xFF, 0x00 },
    { 0x01, 0x2B, 0xFF, 0x00 },
    { 0x01, 0x2C, 0xFF, 0x00 },
    { 0x01, 0xC0, 0xC0, 0x40 },
    { 0x03, 0xE3, 0xFF, 0x07 },
    { 0x03, 0x27, 0xFF, 0x9F },
    { 0x03, 0x28, 0xFF, 0x9F },
    { 0x03, 0x29, 0xFF, 0x9F },
    { 0x03, 0xA7, 0x40, 0x40 },
    { 0x07, 0xE3, 0xFF, 0x07 },
    { 0x07, 0x27, 0xFF, 0x9F },
    { 0x07, 0x28, 0xFF, 0x9F },
    { 0x07, 0x29, 0xFF, 0x9F },
    { 0x07, 0xA7, 0x40, 0x40 },
    { 0x00, 0xF8, 0xFF, 0xC3 },
    { 0x00, 0xF8, 0xFF, 0xA5 },
    { 0x01, 0x5F, 0xFF, 0x04 },
    { 0x01, 0x58, 0xFF, 0x12 },
    { 0x01, 0x58, 0xFF, 0x02 },
    { 0x01, 0x5F, 0xFF, 0x00 },
    { 0x00, 0xF8, 0xFF, 0xFF },
    { 0x05, 0x20, 0x03, 0x01 },
    { 0x04, 0x3C, 0x20, 0x00 },
    { 0x00, 0x91, 0x40, 0x40 },
    { 0x03, 0xF0, 0xFF, 0xC0 },
    { 0x00, 0x21, 0x40, 0x40 },
    { 0x00, 0xCE, 0x30, 0x00 },
    { 0x04, 0xCE, 0x30, 0x00 },
    { 0x04, 0x42, 0xC0, 0xC0 },
    { 0x00, 0x42, 0xC0, 0xC0 },
    { 0x00, 0x7B, 0x10, 0x10 },
    { 0x00, 0x3C, 0x21, 0x00 },
    { 0x00, 0x3B, 0xFF, 0x23 },
    { 0x00, 0xF6, 0xFF, 0x08 },
    { 0x04, 0x3C, 0x21, 0x00 },
    { 0x04, 0x3B, 0xFF, 0x23 },
    { 0x00, 0x59, 0xFF, 0x00 }
};

static int enable_receiver_afe(volatile uint8_t *bar1)
{
    if (it68051_enable_register_clock(bar1)) return -EIO;
    printf("--- Executing IT68051 Receiver Base Sequence (%zu steps) ---\n",
           sizeof(g_it6805_init_table) / sizeof(g_it6805_init_table[0]));

    int cur_bank = -1;
    for (size_t i = 0; i < sizeof(g_it6805_init_table) / sizeof(g_it6805_init_table[0]); i++) {
        const struct it6805_reg_seq *s = &g_it6805_init_table[i];
        if (s->bank != cur_bank) {
            it68051_set_bank(bar1, s->bank);
            cur_bank = s->bank;
        }
        if (s->mask == 0xFF) {
            wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, s->reg, &s->val, 1);
        } else {
            uint8_t cur = 0;
            rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, s->reg, &cur, 1);
            uint8_t new_val = (cur & ~s->mask) | (s->val & s->mask);
            wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, s->reg, &new_val, 1);
        }
        /* Register reset restores clock gates; reopen before the next write. */
        if (s->bank == 0 && s->reg == 0x22 && (s->val & 0x08)) {
            usleep(2000);
            if (it68051_enable_register_clock(bar1)) return -EIO;
            cur_bank = 0;
        }
    }

    it68051_set_bank(bar1, 0);
    printf("Receiver base sequence complete.\n");
    return 0;
}

static int it6805_select_port0(volatile uint8_t *bar1)
{
    printf("--- Configuring IT68051 Port 0 (preserving factory-calibrated clocks) ---\n");
    it68051_set_bank(bar1, 0);

    /* Bank 0: Enable Interrupts 0x56, 0x57 */
    uint8_t ff = 0xFF;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x56, &ff, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x57, &ff, 1);

    /* Bank 3: AFE & Equalizer & SCDC */
    it68051_set_bank(bar1, 3);
    uint8_t r_a8 = 0x0B;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xA8, &r_a8, 1);
    if (it68051_update(bar1, 3, 0xA7, 0x40, 0x40)) return -EIO;
    uint8_t zero = 0x00;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x26, &zero, 1);
    uint8_t r_9f = 0x9F;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x27, &r_9f, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x28, &r_9f, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x29, &r_9f, 1);
    uint8_t r_e3 = 0x07; // SCDC enable
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xE3, &r_e3, 1);
    uint8_t r_f0 = 0xC0;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xF0, &r_f0, 1);

    /* Bank 0: Port 0 Clock & Auto Reset Settings */
    it68051_set_bank(bar1, 0);
    uint8_t port = 0x02;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x35, &port, 1);
    uint8_t r_28 = 0x88;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x28, &r_28, 1);
    uint8_t r_2a = 0x01; // Invert COF Clock
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x2A, &r_2a, 1);
    uint8_t r_23 = 0xA0; // Auto reset
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x23, &r_23, 1);
    uint8_t r_53 = 0x0F; // Interrupts: PWR5V, RxCLK on
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x53, &r_53, 1);
    uint8_t r_3c = 0x12; // Preserve PLL buffer auto-reset and clock-valid check
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x3C, &r_3c, 1);
    uint8_t r_3b = 0x23; // Guide: CEDOPT bits 0 and 1 must remain set
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x3B, &r_3b, 1);
    uint8_t r_26 = 0x00; // Active-HIGH power-down bits: keep AFE and terminations ON
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x26, &r_26, 1);

    printf("Port 0 input path & clock detectors active.\n");
    return 0;
}

static int it6805_restart_eq(volatile uint8_t *bar1)
{
    printf("--- Restarting IT68051 Equalizer & Calibrating PHY ---\n");

    // 1. Disable EQ trigger before resetting the equalizer.
    it68051_set_bank(bar1, 3);
    uint8_t zero = 0x00, r2d = 0x07;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x22, &zero, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x2C, &zero, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x2D, &r2d, 1);

    // 2. Clear EQ IRQ in Bank 0 reg 0x07
    it68051_set_bank(bar1, 0);
    uint8_t ff = 0xFF;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x07, &ff, 1);

    // 3. Pulse EQ reset in Bank 0 reg 0x23 (0xB0 -> 2ms -> 0xA0) and set bit 1 (0x23 |= 0x02)
    uint8_t r23_b0 = 0xB0;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x23, &r23_b0, 1);
    usleep(10000);
    uint8_t r23_a0 = 0xA0;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x23, &r23_a0, 1);

    // 4. Bank 3 CAOF/EQ calibration registers
    it68051_set_bank(bar1, 3);
    uint8_t r9f = 0x9F; // Known-good initial manual EQ; HDMI1 auto-EQ overrides below
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x27, &r9f, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x28, &r9f, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x29, &r9f, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x22, &zero, 1);

    uint8_t r4b = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4B, &r4b, 1);
    r4b &= ~0x80;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4B, &r4b, 1);

    // 5. Read Bank 0 0x14 for Scrambling / High Clock status
    it68051_set_bank(bar1, 0);
    uint8_t s14 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x14, &s14, 1);
    bool is_hdmi2 = (s14 & 0x40) != 0;

    // 6. ENHEQ is for HDMI, ENMEQ is for MHL (not HDMI 2.0).
    it68051_set_bank(bar1, 3);
    uint8_t r3a = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x3A, &r3a, 1);
    uint8_t phy_mode = 0x02;
    r3a = (r3a & ~0x06) | phy_mode;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x3A, &r3a, 1);

    uint8_t ra7 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xA7, &ra7, 1);
    if (s14 & 0x41) ra7 |= 0x40; else ra7 &= ~0x40;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xA7, &ra7, 1);

    /* Start adaptation, rather than only resetting EQ. HDMI2 SAR/skew
     * training is not yet implemented: first validate 1080p HDMI1. */
    if (!is_hdmi2) {
        uint8_t csel = (s14 & 1) ? 0x36 : 0x1B;
        uint8_t rsel = (s14 & 1) ? 0x0E : 0x03;
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &csel, 1);
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x21, &rsel, 1);
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x26, &zero, 1);
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x27, &zero, 1);
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x28, &zero, 1);
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x29, &zero, 1);
        uint8_t eq = 0x38;
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x22, &eq, 1);
        eq = 0x3C;
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x22, &eq, 1);
        usleep(1000);
        eq = 0x38;
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x22, &eq, 1);
    }

    it68051_set_bank(bar1, 0);
    printf("EQ restarted: PHY Mode=0x%02X (%s), Status 0x14=0x%02X\n",
           phy_mode, is_hdmi2 ? "HDMI 2.0" : "HDMI 1.4", s14);
    return 0;
}

static void it6805_unlock_regs(volatile uint8_t *bar1)
{
    it68051_set_bank(bar1, 0);
    uint8_t c3 = 0xC3, a5 = 0xA5;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xF8, &c3, 1);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xF8, &a5, 1);
}

static void it6805_lock_regs(volatile uint8_t *bar1)
{
    it68051_set_bank(bar1, 0);
    uint8_t ff = 0xFF;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xF8, &ff, 1);
}

static int enable_ttl_output(volatile uint8_t *bar1)
{
    printf("--- Configuring IT68051 Output Bus (TTL %s-Pixel + I2S) ---\n", g_single_pixel ? "Single" : "Dual");

    /* Unlock register write protection (Bank 0 0xF8: 0xC3 -> 0xA5) */
    it6805_unlock_regs(bar1);

    /* First check link speed in Bank 0 reg 0x14 */
    it68051_set_bank(bar1, 0);
    uint8_t s14 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x14, &s14, 1);
    bool is_hdmi2 = (s14 & 0xC0) != 0; // Bit 7 (Scrambler) or Bit 6 (1:40 Clock Ratio)
    printf("  [Debug] Bank 0 0x14=0x%02X, is_hdmi2=%d\n", s14, is_hdmi2);

    /* Switch to Bank 1 */
    int r_b1 = it68051_set_bank(bar1, 1);

    /* 0xB0: Disable DE-only regenerate mode (normal video sync pass-through) */
    uint8_t zero = 0x00;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xB0, &zero, 1);

    /* 0xC0: Reg_TTLMode=1 (Dual pixel), Reg_EnTTLOut=1 (Enable TTL clock) -> 0x03 */
    uint8_t c0 = g_single_pixel ? 0x42 : 0x43;
    int r_c0 = wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC0, &c0, 1);

    /* The FPGA bridge samples rising edges only: single/dual-pixel SDR.
     * Scrambling is an input-link property, not a TTL DDR format selector. */
    uint8_t c1 = 0x00;
    int r_c1 = wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC1, &c1, 1);
    printf("  [Debug] Write Bank 1: set_bank=%d, C0=%d (val=0x%02X), C1=%d (val=0x%02X)\n",
           r_b1, r_c0, c0, r_c1, c1);

    /* On this A50T board, B0 loses every TLAST in the 148.5 MHz single-pixel
     * profile despite the independent timing probe locking. C4=00 restores
     * line-end sampling and live capture. Keep the legacy dual-pixel setting
     * separate: this is not a validated 297 MHz/4K sampling phase. */
    uint8_t c4 = g_downscale_1080p ? 0x00 : 0xB0;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC4, &c4, 1);
    if (it68051_update(bar1, 1, 0xBD, 0x30, g_single_pixel ? 0 : 0x10) ||
        it68051_update(bar1, 5, 0xD0, 0xFF, 0xF3)) return -EIO;
    it68051_set_bank(bar1, 1);

    uint8_t c5_val = 0x80; // Reg_VIOSel=1: VIO Tri-state controlled by Reg_TriVIO (1C6[7])
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC5, &c5_val, 1); // Release video IO tristates
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC6, &zero, 1); // Release dual-pixel data tristates & Reg_TriVIO=0
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC7, &zero, 1); // Release I2S audio & video control tristates
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC8, &zero, 1); // Release control tristates

    /* Driving strength: 10mA + fast slew rate (0x33 for 10mA/fast) */
    uint8_t drive = 0x33;
    int r_c9 = wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC9, &drive, 1);
    int r_ca = wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xCA, &drive, 1);
    printf("  [Debug] Write C9=%d, CA=%d\n", r_c9, r_ca);

    /* Switch to Bank 0 and ungate all backend clocks */
    it68051_set_bank(bar1, 0);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x34, &zero, 1);
    uint8_t port0 = 0x02;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x35, &port0, 1);

    /* Ensure PCLK and ACLK are not powered down (Bank 0 reg 0x22 bit 6,7 = 0) */
    uint8_t auto_video_reset = 0x10;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x22, &auto_video_reset, 1);

    /* Disable auto-mute (bit 7), open output data gate (bit 5). */
    uint8_t r4f = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4F, &r4f, 1);
    r4f = (r4f & ~0x20) | 0x80; // B1: bit 7 disables auto-mute; bit 5 gates data
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4F, &r4f, 1);

    /* Do not gate AVMute in the video-format detector. */
    uint8_t r68 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x68, &r68, 1);
    r68 &= ~0x02;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x68, &r68, 1);

    /* Require vertical timing stability; do not manufacture SCDT from clock only. */
    uint8_t r69 = 0x00;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x69, &r69, 1);

    /* Color quantization settings; H/V sync enable is 0x6D[3]. */
    uint8_t r6e = 0xA0;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x6E, &r6e, 1);
    if (it68051_update(bar1, 0, 0x6D, 0x08, 0x08)) return -EIO;

    /* Ensure RegForce_AVMute = 0 (Bank 0 reg 0x81 bit 2 = 0) */
    uint8_t r81 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x81, &r81, 1);
    r81 &= ~0x04;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x81, &r81, 1);

    /* Let the receiver select PCM/DSD format from the input. */
    uint8_t r8d = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x8D, &r8d, 1);
    r8d &= ~0x30; // Automatic PCM format selection, not forced DSD/PCM
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x8D, &r8d, 1);

    /* Pulse FIFO reset (Bank 0 0x64 bit 1) */
    uint8_t r64 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x64, &r64, 1);
    r64 &= ~0x06; // even/odd mode, preserve other pipeline enables
    uint8_t r64_reset = r64 | 0x02;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x64, &r64_reset, 1);
    usleep(1000);
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x64, &r64, 1);

    /* Switch to Bank 5: Ensure DownScaler is bypassed */
    it68051_set_bank(bar1, 5);
    uint8_t b5_r20 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &b5_r20, 1);
    if (!g_downscale_1080p) b5_r20 |= 0x40;
    wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &b5_r20, 1);

    /* Readback verification */
    it68051_set_bank(bar1, 1);
    uint8_t rb_c0=0, rb_c1=0, rb_c9=0, rb_ca=0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC0, &rb_c0, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC1, &rb_c1, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC9, &rb_c9, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xCA, &rb_ca, 1);

    it68051_set_bank(bar1, 5);
    uint8_t rb_b5_20=0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x20, &rb_b5_20, 1);

    it68051_set_bank(bar1, 0);
    uint8_t rb_4e=0, rb_4f=0, rb_68=0, rb_69=0, rb_6e=0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4E, &rb_4e, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4F, &rb_4f, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x68, &rb_68, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x69, &rb_69, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x6E, &rb_6e, 1);

    printf("TTL %s-Pixel SDR & I2S output registers programmed (signal validity checked separately).\n",
           g_single_pixel ? "Single" : "Dual");
    printf("  [Verified Settings] B1: C0=0x%02X C1=0x%02X C9=0x%02X | B5: 20=0x%02X | B0: 4E=0x%02X 4F=0x%02X 68=0x%02X 69=0x%02X 6E=0x%02X\n",
           rb_c0, rb_c1, rb_c9, rb_b5_20, rb_4e, rb_4f, rb_68, rb_69, rb_6e);
    it6805_lock_regs(bar1);
    return 0;
}

/* First supported downscale profile: CTA VIC 97, 3840x2160p60, 8-bit
 * limited-range BT.709 YUV444 -> 1920x1080p60 RGB, single-pixel SDR.
 * Reject other input modes rather than silently programming wrong timings. */
static bool it68051_supported_uhd60(const uint8_t *timing, const uint8_t *avi)
{
    unsigned width = timing[5] | ((timing[6] & 0x3F) << 8);
    unsigned height = timing[12] | ((timing[13] & 0x3F) << 8);
    unsigned htotal = timing[3] | ((timing[4] & 0x3F) << 8);
    unsigned vtotal = timing[10] | ((timing[11] & 0x3F) << 8);
    return width == 3840 && height == 2160 && htotal == 4400 && vtotal == 2250 &&
           (avi[3] & 0x7F) == 97 && ((avi[0] >> 5) & 3) == 2 && (avi[1] >> 6) == 2 &&
           !(avi[4] & 0xC0) && ((timing[0] & 0xF0) == 0 || (timing[0] & 0xF0) == 0x40) &&
           !(timing[0] & 2);
}

static int it68051_output_1080p(volatile uint8_t *bar1)
{
    uint8_t timing[24], avi[5], status;
    it68051_set_bank(bar1, 0);
    if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x19, &status, 1) || !(status & 0x80) ||
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x98, timing, sizeof(timing))) return -EIO;
    it68051_set_bank(bar1, 2);
    if (rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x15, avi, sizeof(avi))) return -EIO;
    unsigned width = timing[5] | ((timing[6] & 0x3F) << 8);
    unsigned height = timing[12] | ((timing[13] & 0x3F) << 8);
    if (!it68051_supported_uhd60(timing, avi)) {
        fprintf(stderr, "ERROR: downscale profile requires 3840x2160p60 BT.709 limited YUV444 8-bit (VIC 97)\n");
        fprintf(stderr, "Input %ux%u Reg98=%02X AVI=%02X %02X %02X %02X %02X\n",
                width, height, timing[0], avi[0], avi[1], avi[2], avi[3], avi[4]);
        it68051_set_bank(bar1, 0);
        return -EINVAL;
    }
    int rc = it68051_update(bar1, 0, 0x33, 0x08, 0x08);
    /* Source dimensions, horizontal 1/2 ratio (endpoint-aligned). */
    const uint16_t geometry[] = {3840, 2160, 3838, 1919, 1919};
    for (unsigned i = 0; i < sizeof(geometry)/sizeof(geometry[0]); i++) {
        rc |= it68051_update(bar1, 5, 0x21 + i*2, 0xFF, geometry[i]);
        rc |= it68051_update(bar1, 5, 0x22 + i*2, 0xFF, geometry[i] >> 8);
    }
    const uint8_t clamp[] = {0xFF, 0, 0x0F, 0xFF, 0, 0x0F};
    for (unsigned i = 0; i < sizeof(clamp); i++)
        rc |= it68051_update(bar1, 5, 0x2B + i, 0xFF, clamp[i]);
    rc |= it68051_update(bar1, 5, 0x31, 0xFF, 0x1B);
    const uint16_t output_timing[] = {88, 44, 148, 1920, 4, 5, 36, 1080};
    for (unsigned i = 0; i < sizeof(output_timing)/sizeof(output_timing[0]); i++) {
        rc |= it68051_update(bar1, 5, 0x32 + i*2, 0xFF, output_timing[i]);
        rc |= it68051_update(bar1, 5, 0x33 + i*2, 0x3F, output_timing[i] >> 8);
    }
    rc |= it68051_update(bar1, 5, 0x20, 0x73, 0x31);
    rc |= it68051_update(bar1, 0, 0x33, 0x08, 0);
    /* ITU709 limited YUV -> full RGB matrix, hardware register encoding. */
    const uint8_t matrix[] = {0x04,0x00,0xA7,0x4F,0x09,0xBA,0x3B,0x4B,0x3E,
                             0x4F,0x09,0x57,0x0E,0x02,0x00,0x4F,0x09,0xFE,0x3F,0xE8,0x10,0x00};
    for (unsigned i = 0; i < sizeof(matrix); i++)
        rc |= it68051_update(bar1, 1, 0x70 + i, 0xFF, matrix[i]);
    rc |= it68051_update(bar1, 0, 0x6B, 0x7F, 0x60);
    rc |= it68051_update(bar1, 0, 0x6C, 0x03, 0x03);
    /* The bridge packs B,G,R into ascending byte addresses. Swap RX R/B
     * so the packed RGB24 DMA path actually delivers V4L2 RGB24 (R,G,B),
     * not BGR. Do not feed this RGB profile to the YUV444->NV12 engine. */
    rc |= it68051_update(bar1, 1, 0xC2, 0x0C, 0x08);
    rc |= it68051_update(bar1, 1, 0xC4, 0xF0, 0x00);
    rc |= it68051_update(bar1, 0, 0x22, 0x01, 0x01);
    usleep(1000);
    rc |= it68051_update(bar1, 0, 0x22, 0x01, 0);
    /* Clear HW audio mute and use the recovered N/CTS clock. */
    rc |= it68051_update(bar1, 0, 0x81, 0x44, 0);
    rc |= it68051_update(bar1, 0, 0x86, 0x01, 0x01);
    rc |= it68051_update(bar1, 0, 0x8C, 0x58, 0x10);
    rc |= it68051_update(bar1, 0, 0x8C, 0x10, 0);
    it68051_set_bank(bar1, 0);
    printf("RX output profile: 1920x1080p60 RGB single-pixel SDR, RGB24 byte order (%s)\n", rc ? "FAILED" : "registers verified");
    printf("Capture with v4l2_rgb24_test_app; this RGB profile is NOT NV12/YUV444 input.\n");
    usleep(1200000); // Let the output PLL, format detector and audio settle
    return rc ? -EIO : 0;
}

static int it6805_service_link(volatile uint8_t *bar1)
{
    it68051_set_bank(bar1, 0);

    /* 1. Read IRQ registers 0x05..0x09 */
    uint8_t irq[5] = {0};
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x05, irq, 5);

    /* 2. Read link status 0x13, 0x14, 0x19 */
    uint8_t s13 = 0, s14 = 0, s19 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x13, &s13, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x14, &s14, 1);
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x19, &s19, 1);

    /* 3. Check PHY mode against link status */
    bool is_hdmi2 = (s14 & 0x40) != 0;
    it68051_set_bank(bar1, 3);
    uint8_t r3a = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x3A, &r3a, 1);
    uint8_t cur_phy = r3a & 0x06;
    uint8_t exp_phy = 0x02;
    (void)is_hdmi2;

    if (!(s19 & 0x80) && (cur_phy != exp_phy || (irq[3] & 0x01) || (irq[1] & 0x01) || (irq[0] & 0x04))) {
        printf("Link Service: IRQ=[0x%02X 0x%02X 0x%02X 0x%02X 0x%02X] Status=[0x%02X 0x%02X 0x%02X] -> Triggering EQ\n",
               irq[0], irq[1], irq[2], irq[3], irq[4], s13, s14, s19);
        it6805_restart_eq(bar1);
    }
    it68051_set_bank(bar1, 0);

    /* 4. Clear pending system IRQs (W1C) */
    if (irq[0]) wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x05, &irq[0], 1);
    if (irq[1]) wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x06, &irq[1], 1);
    if (irq[2]) wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x07, &irq[2], 1);
    if (irq[3]) wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x08, &irq[3], 1);
    uint8_t irq9 = irq[4] & ~0x04;
    if (irq9)   wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x09, &irq9, 1);

    /* 5. Clear pending common IRQs 0x10..0x12 */
    uint8_t cirq[3] = {0};
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x10, cirq, 3);
    if (cirq[0]) wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x10, &cirq[0], 1);
    if (cirq[1] & 0xBF) {
        uint8_t c11 = cirq[1] & 0xBF;
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x11, &c11, 1);
    }
    if (cirq[2] & 0x7F) {
        uint8_t c12 = cirq[2] & 0x7F;
        wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x12, &c12, 1);
    }

    /* 0x53..0x5F are interrupt masks, not deskew configuration. */

    static bool output_configured = false;
    if ((s19 & 0x80) && !output_configured) {
        if (enable_ttl_output(bar1)) return -EIO;
        output_configured = true;
    }
    if (!(s19 & 0x80)) output_configured = false;

    return 0;
}

static void dump_all_registers(volatile uint8_t *bar1)
{
    printf("====================================================\n");
    printf(" IT68051 Full Register Dump (Banks 0, 1, 3)\n");
    printf("====================================================\n");

    int banks[] = {0, 1, 3};
    for (size_t i = 0; i < sizeof(banks)/sizeof(banks[0]); i++) {
        int b = banks[i];
        it68051_set_bank(bar1, b);
        printf("\n--- Bank %d ---\n", b);
        printf("     00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F\n");
        for (int row = 0; row < 256; row += 16) {
            uint8_t buf[16] = {0};
            rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, (uint8_t)row, buf, 16);
            printf("%02X:  ", row);
            for (int col = 0; col < 16; col++) {
                printf("%02X ", buf[col]);
            }
            printf("\n");
        }
    }
    it68051_set_bank(bar1, 0);
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

    uint8_t r10[16] = {0};
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x10, r10, 16);
    uint8_t s13 = r10[0x13 - 0x10];
    uint8_t s14 = r10[0x14 - 0x10];
    uint8_t s15 = r10[0x15 - 0x10];
    uint8_t s19 = r10[0x19 - 0x10];

    printf("\n[HDMI Link Telemetry (Reg 0x13=0x%02X, 0x14=0x%02X, 0x15=0x%02X, 0x19=0x%02X)]\n", s13, s14, s15, s19);
    printf("  Port 0 +5V Cable Det : %s\n", (s13 & 0x01) ? "YES (Plugged)" : "NO (Unplugged)");
    printf("  HDMI/DVI Mode        : %s\n", (s13 & 0x02) ? "HDMI" : "DVI");
    printf("  TMDS Clock Detect    : %s\n", (s13 & 0x04) ? "YES" : "NO");
    printf("  TMDS Clock Valid     : %s\n", (s13 & 0x08) ? "YES" : "NO");
    printf("  TMDS Clock Stable    : %s\n", (s13 & 0x10) ? "YES" : "NO");
    printf("  IPLL Lock            : %s\n", (s13 & 0x20) ? "LOCKED" : "UNLOCKED");
    printf("  Symbol Lock (H2V)    : %s\n", (s13 & 0x80) ? "LOCKED" : "UNLOCKED");
    printf("  TMDS Ch status (raw) : %u / %u / %u (lock qualified by H2V/SCDT)\n",
           !!(s14 & 0x08), !!(s14 & 0x10), !!(s14 & 0x20));
    printf("  SCDC Scrambler / 1:40: %s / %s\n",
           (s14 & 0x80) ? "ENABLED" : "OFF",
           (s14 & 0x40) ? "1:40 (HDMI2.0)" : "1:10 (HDMI1.4)");
    printf("  VOut Detect Stable   : %s\n", (s19 & 0x02) ? "YES (Stable)" : "NO");
    printf("  SCDT Video Stable    : %s\n", (s19 & 0x80) ? "YES (Stable)" : "NO");
    printf("  OPLL Lock / HS       : %s / %s\n",
           (s19 & 0x10) ? "LOCKED" : "UNLOCKED",
           (s19 & 0x20) ? "High-Speed" : "Standard");

    /* Bank 0 control status */
    uint8_t b0_ctrl[4] = {0};
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x34, &b0_ctrl[0], 1); // 0x34
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x35, &b0_ctrl[1], 1); // 0x35
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4E, &b0_ctrl[2], 1); // 0x4E
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x4F, &b0_ctrl[3], 1); // 0x4F
    printf("\n[Bank 0 Registers: Gate34=0x%02X Port35=0x%02X AutoMute4E=0x%02X Gate4F=0x%02X]\n",
           b0_ctrl[0], b0_ctrl[1], b0_ctrl[2], b0_ctrl[3]);
    printf("  Video Auto Mute      : %s\n", (b0_ctrl[3] & 0x80) ? "DISABLED (Forced Pass)" : "ENABLED");
    printf("  Output Data Gating   : %s\n", (b0_ctrl[3] & 0x20) ? "GATED TO ZERO" : "OPEN (Passing Data)");

    if ((s13 & 0x08) || (s14 & 0x38) == 0x38) {
        uint8_t timing[24] = {0};
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x98, timing, 24);
        uint32_t hactive = ((timing[0x9E - 0x98] & 0x3F) << 8) | timing[0x9D - 0x98];
        uint32_t vactive = ((timing[0xA5 - 0x98] & 0x3F) << 8) | timing[0xA4 - 0x98];
        uint32_t htotal  = ((timing[0x9C - 0x98] & 0x3F) << 8) | timing[0x9B - 0x98];
        uint32_t vtotal  = ((timing[0xA3 - 0x98] & 0x3F) << 8) | timing[0xA2 - 0x98];

        printf("\n[Decoded Video Timing%s]\n", (s19 & 0x80) ? "" : " (UNSTABLE, not capture-ready)");
        printf("  Active Resolution    : %ux%u\n", hactive, vactive);
        printf("  Total Dimensions     : %ux%u\n", htotal, vtotal);
    }

    /* Bank 1 TTL status */
    it68051_set_bank(bar1, 1);
    uint8_t b1[8] = {0};
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xC0, b1, 8);
    uint8_t b1_b0 = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0xB0, &b1_b0, 1);
    it68051_set_bank(bar1, 0);
    uint8_t color = 0;
    rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x6B, &color, 1);

    printf("\n[Output Bus Status (Bank 1 0xC0=0x%02X, 0xC6=0x%02X, 0xC7=0x%02X)]\n",
           b1[0], b1[6], b1[7]);
    printf("  TTL Module Clock     : %s\n", (b1[0] & 0x02) ? "ENABLED" : "DISABLED");
    printf("  TTL Mode             : %s\n", (b1[0] & 0x01) ? "Dual Pixel" : "Single Pixel");
    printf("  TTL DCLK phase (C4)  : 0x%02X (invert=%u, delay=%u)\n",
           b1[4], b1[4] >> 7, (b1[4] >> 4) & 7);
    printf("  TTL channel swap(C2) : 0x%02X\n", b1[2]);
    printf("  Output color mode    : %s (B0:6B=0x%02X)\n",
           (color & 0x0C) == 0 ? "RGB444" : (color & 0x0C) == 8 ? "YUV444" :
           (color & 0x0C) == 4 ? "YUV422" : "reserved", color);
    printf("  DE Regeneration (B0): %s\n", (b1_b0 & 0x01) ? "ENABLED" : "DISABLED (pass-through)");
    printf("  Video Data IO (QD)   : %s\n", (b1[6] == 0x00) ? "DRIVING (Active)" : "TRISTATED");
    printf("  Audio I2S IO         : %s\n", (b1[7] == 0x00) ? "DRIVING (Active)" : "TRISTATED");

    /* MCU telemetry */
    uint8_t mcu_ver = 0, mcu_status = 0, mcu_ctrl = 0;
    if (rd_regs(bar1, BAR1_OFFSET_I2C_MCU, NUC_ADDR, 0x01, &mcu_ver, 1) == 0 &&
        rd_regs(bar1, BAR1_OFFSET_I2C_MCU, NUC_ADDR, 0x02, &mcu_status, 1) == 0 &&
        rd_regs(bar1, BAR1_OFFSET_I2C_MCU, NUC_ADDR, 0x03, &mcu_ctrl, 1) == 0) {
        printf("\n[MCU NUC100 Telemetry (Slave 0x2A: VER=0x%02X, STATUS=0x%02X, CTRL=0x%02X)]\n", mcu_ver, mcu_status, mcu_ctrl);
        if (mcu_status & 0xF0)
            printf("  WARNING: invalid reserved STATUS bits; MCU pin telemetry is not trustworthy for this sample\n");
        else
            printf("  PA.13 SCDT raw pin     : %s\n", (mcu_status & 0x02) ? "HIGH" : "LOW");
        printf("  PB.10 HPD control      : %s (physical HPD not measured)\n", (mcu_ctrl & 0x01) ? "ASSERTED" : "RELEASED");
        printf("  PB.15 Reset Tree       : %s\n", (mcu_ctrl & 0x02) ? "RELEASED (Normal)" : "HELD IN RESET");
    } else {
        printf("\n[MCU NUC100 Telemetry  : I2C NACK on 0x2A]\n");
    }
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
    printf("  %s Res : %ux%u\n", (status & 0x08) ? "Hardware Measured" : "Configured fallback (NOT measured)", width, height);
    printf("  %s Pixel Clock : %u Hz (%.3f MHz)\n",
           (status & 0x08) ? "Measured" : "Configured fallback (NOT measured)", clk_hz, (double)clk_hz / 1e6);
    printf("  Audio Sample Rate (WS) : %u Hz (video frame counter: %u)\n", aud & 0xFFFF, (aud >> 16) & 0xFFFF);
    printf("  FPGA Pixel Mode        : %s\n", ver < 0x26101502 ? "legacy dual-only" :
           ((ctrl & 0x08) ? "single" : "dual"));
    printf("  Hardware Capture Source: Video=%s, Audio=%s (CTRL=0x%02X)\n",
           (ctrl & 0x01) ? "Live HDMI RX" : "Internal TPG",
           (ctrl & 0x02) ? "Live HDMI I2S" : "Audio Pattern Gen",
           ctrl);
}

static void monitor_loop(volatile uint8_t *bar1, volatile uint8_t *bar0)
{
    printf("Starting passive HDMI monitor (no EQ/PLL resets; Ctrl+C to stop)...\n");
    fflush(stdout);
    uint8_t last_s13 = 0xFF, last_s19 = 0xFF;
    uint32_t last_h = 0, last_v = 0;
    int tick = 0;

    while (1) {
        uint8_t s13 = 0, s14 = 0, s19 = 0;
        it68051_set_bank(bar1, 0);
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x13, &s13, 1);
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x14, &s14, 1);
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x19, &s19, 1);

        uint32_t hactive = 0, vactive = 0;
        if (s19 & 0x80) {
            uint8_t timing[24] = {0};
            rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, 0x98, timing, 24);
            hactive = ((timing[0x9E - 0x98] & 0x3F) << 8) | timing[0x9D - 0x98];
            vactive = ((timing[0xA5 - 0x98] & 0x3F) << 8) | timing[0xA4 - 0x98];
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
            printf("[%02d:%02d:%02d] Chip: 5V=%d CLK=%d IPLL=%d SYM=%d SCDT=%d (%s) 0x14=0x%02X | PL: PCLK=%.1fMHz Lock=%d Res=%ux%u FPS=%u\n",
                   t->tm_hour, t->tm_min, t->tm_sec,
                   !!(s13 & 0x01), !!(s13 & 0x04), !!(s13 & 0x20), !!(s13 & 0x80),
                   !!(s19 & 0x80), (s19 & 0x80) ? "SIGNAL LOCKED" : "NO SIGNAL",
                   s14,
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
    bool is_4k       = false;
    bool do_edid     = false;
    bool do_hpd      = false;
    bool do_ttl      = false;
    bool do_dump     = false;
    bool do_monitor  = false;
    bool do_probe    = false;
    bool do_service  = false;
    bool do_mux_hdmi = false;
    bool do_mux_tpg  = false;
    bool do_pixel_mode = false;
    int exit_code = 0;

    static struct option long_options[] = {
        {"status",     no_argument, 0, 's'},
        {"init",       no_argument, 0, 'i'},
        {"init-4k",    no_argument, 0, 1003},
        {"edid",       no_argument, 0, 'e'},
        {"edid-1080p", no_argument, 0, 1004},
        {"edid-4k",    no_argument, 0, 1005},
        {"hpd",        no_argument, 0, 'h'},
        {"ttl",        no_argument, 0, 't'},
        {"dump",       no_argument, 0, 'd'},
        {"service",    no_argument, 0, 1006},
        {"monitor",    no_argument, 0, 'm'},
        {"probe",      no_argument, 0, 'p'},
        {"mux-hdmi",   no_argument, 0, 1001},
        {"mux-tpg",    no_argument, 0, 1002},
        {"single-pixel", no_argument, 0, 1007},
        {"dual-pixel", no_argument, 0, 1008},
        {"downscale-1080p", no_argument, 0, 1009},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "siehtdmp", long_options, NULL)) != -1) {
        switch (opt) {
            case 's': do_status   = true; break;
            case 'i': do_init     = true; is_4k = false; break;
            case 1003: do_init    = true; is_4k = true; break;
            case 'e':
            case 1004: do_edid    = true; is_4k = false; break;
            case 1005: do_edid    = true; is_4k = true; break;
            case 'h': do_hpd      = true; break;
            case 't': do_ttl      = true; break;
            case 'd': do_dump     = true; break;
            case 1006: do_service = true; break;
            case 'm': do_monitor  = true; break;
            case 'p': do_probe    = true; break;
            case 1001: do_mux_hdmi = true; break;
            case 1002: do_mux_tpg  = true; break;
            case 1007: do_pixel_mode = true; g_single_pixel = true; break;
            case 1008: do_pixel_mode = true; g_single_pixel = false; break;
            case 1009:
                do_pixel_mode = true;
                g_single_pixel = true;
                g_downscale_1080p = true;
                break;
            default:
                printf("Usage: %s [options]\n"
                       "  --status|-s         Display current chip and FPGA telemetry\n"
                       "  --init|-i           Full bringup with 1080p60 FHD EDID (default)\n"
                       "  --init-4k           Full bringup with 4K60 HDR EDID\n"
                       "  --edid-1080p        Load 1080p60 EDID only\n"
                       "  --edid-4k           Load 4K60 EDID only\n"
                       "  --hpd|-h            Pulse Hot-Plug Detect via MCU\n"
                       "  --ttl|-t            Enable TTL Dual-Pixel & I2S output and unmute\n"
                       "  --dump|-d           Full dump of registers (Banks 0, 1, 3)\n"
                       "  --service           Run one-shot link servicing & EQ restart\n"
                       "  --monitor|-m        Real-time telemetry monitor loop\n"
                       "  --probe|-p          Display FPGA PL-side telemetry only\n"
                       "  --mux-hdmi          Route Live HDMI RX Video & Audio to DMA\n"
                       "  --mux-tpg           Route Internal TPG & Tone Gen to DMA\n"
                       "  --single-pixel      Select FPGA single-pixel mode (26101601+)\n"
                       "  --dual-pixel        Select FPGA dual-pixel mode (26101601+)\n"
                       "  --downscale-1080p   RX VIC97/YUV444 -> RGB1080p single pixel\n",
                       argv[0]);
                return 1;
        }
    }

    if (!do_status && !do_init && !do_edid && !do_hpd && !do_ttl && !do_dump && !do_service && !do_monitor && !do_probe && !do_mux_hdmi && !do_mux_tpg)
        do_status = true;

    if (find_qpcie() < 0) {
        printf("ERROR: QPCIe device (12ab:e380) not found!\n");
        return 1;
    }

    /* Map BAR0 (1M) */
    char rp0[600];
    snprintf(rp0, sizeof(rp0), "%s/resource0", g_device_path);
    int fd0 = open(rp0, O_RDWR | O_SYNC);
    volatile uint8_t *bar0 = NULL;
    if (fd0 >= 0) {
        bar0 = mmap(NULL, 1048576, PROT_READ | PROT_WRITE, MAP_SHARED, fd0, 0);
        if (bar0 == MAP_FAILED) {
            bar0 = NULL;
            close(fd0);
        }
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

    if (argc >= 4 && strcmp(argv[1], "r") == 0) {
        int bank = strtoul(argv[2], NULL, 0);
        int reg  = strtoul(argv[3], NULL, 0);
        it68051_set_bank(bar1, bank);
        uint8_t val = 0;
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, reg, &val, 1);
        printf("Bank %d Reg 0x%02X = 0x%02X\n", bank, reg, val);
        goto cleanup;
    }

    if (argc >= 5 && strcmp(argv[1], "w") == 0) {
        int bank = strtoul(argv[2], NULL, 0);
        int reg  = strtoul(argv[3], NULL, 0);
        uint8_t val = (uint8_t)strtoul(argv[4], NULL, 0);
        it68051_set_bank(bar1, bank);
        int r = wr_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, reg, &val, 1);
        uint8_t rb = 0;
        rd_regs(bar1, BAR1_OFFSET_I2C_FRONT, IT68051_ADDR, reg, &rb, 1);
        printf("Bank %d Reg 0x%02X write 0x%02X (r=%d) -> readback 0x%02X\n",
               bank, reg, val, r, rb);
        goto cleanup;
    }

    if (argc >= 5 && strcmp(argv[1], "raw-r") == 0) {
        uint32_t base = (strcmp(argv[2], "mcu") == 0) ? BAR1_OFFSET_I2C_MCU : BAR1_OFFSET_I2C_FRONT;
        uint8_t addr7 = strtoul(argv[3], NULL, 0);
        uint8_t reg   = strtoul(argv[4], NULL, 0);
        unsigned long requested = (argc >= 6) ? strtoul(argv[5], NULL, 0) : 1;
        if (requested == 0 || requested > 256) {
            fprintf(stderr, "ERROR: raw-r length must be 1..256\n");
            exit_code = 1;
            goto cleanup;
        }
        int len = (int)requested;
        uint8_t buf[256] = {0};
        int r = rd_regs(bar1, base, addr7, reg, buf, len);
        printf("RAW-R [%s @ 0x%02X] Reg 0x%02X (len %d, r=%d):", argv[2], addr7, reg, len, r);
        for (int i = 0; i < len; i++) printf(" %02X", buf[i]);
        printf("\n");
        goto cleanup;
    }

    if (argc >= 6 && strcmp(argv[1], "raw-w") == 0) {
        uint32_t base = (strcmp(argv[2], "mcu") == 0) ? BAR1_OFFSET_I2C_MCU : BAR1_OFFSET_I2C_FRONT;
        uint8_t addr7 = strtoul(argv[3], NULL, 0);
        uint8_t reg   = strtoul(argv[4], NULL, 0);
        uint8_t val   = strtoul(argv[5], NULL, 0);
        int r = wr_regs(bar1, base, addr7, reg, &val, 1);
        printf("RAW-W [%s @ 0x%02X] Reg 0x%02X val 0x%02X (r=%d)\n", argv[2], addr7, reg, val, r);
        goto cleanup;
    }

    if ((do_init || do_edid || do_hpd || do_ttl || do_service || do_monitor || g_downscale_1080p) &&
        it68051_enable_register_clock(bar1)) {
        munmap((void *)bar1, 65536);
        close(fd);
        if (bar0) { munmap((void *)bar0, 1048576); close(fd0); }
        return 1;
    }

    if (do_mux_hdmi && bar0) {
        printf("Switching capture source to Live HDMI RX (Video Ch0 + Audio Ch0)...\n");
        uint32_t ctrl = (read32(bar0, BAR0_REG_HDMI_TX_CTRL) & ~0x07u) | 0x03;
        write32(bar0, BAR0_REG_HDMI_TX_CTRL, ctrl | 0x04);
        usleep(1000);
        write32(bar0, BAR0_REG_HDMI_TX_CTRL, ctrl);
        usleep(50000);
        show_fpga_probe(bar0);
    }

    if (do_mux_tpg && bar0) {
        printf("Switching capture source to Internal TPG & Tone Gen...\n");
        uint32_t ctrl = read32(bar0, BAR0_REG_HDMI_TX_CTRL) & ~0x07u;
        write32(bar0, BAR0_REG_HDMI_TX_CTRL, ctrl | 0x04);
        usleep(1000);
        write32(bar0, BAR0_REG_HDMI_TX_CTRL, ctrl);
        usleep(50000);
        show_fpga_probe(bar0);
    }

    if (do_init) {
        printf("====================================================\n");
        printf(" 🚀 Executing IT68051 Receiver Full Bringup (%s)\n", is_4k ? "4K60" : "1080p60");
        printf("====================================================\n");
        if (enable_receiver_afe(bar1)) {
            munmap((void *)bar1, 65536);
            close(fd);
            if (bar0) { munmap((void *)bar0, 1048576); close(fd0); }
            return 1;
        }
        if (it68051_calibrate_port0(bar1) || it68051_calibrate_clock(bar1)) {
            fprintf(stderr, "ERROR: Port 0 analog calibration failed\n");
            munmap((void *)bar1, 65536);
            close(fd);
            if (bar0) { munmap((void *)bar0, 1048576); close(fd0); }
            return 1;
        }
        if (load_edid(bar1, is_4k)) { exit_code = 1; goto cleanup; }
        if (it6805_select_port0(bar1) || it6805_restart_eq(bar1) ||
            enable_ttl_output(bar1) || pulse_hpd(bar1)) {
            exit_code = 1;
            goto cleanup;
        }
        printf("Waiting 2.5s for TMDS clock & link negotiation...\n");
        sleep(3);
        /* Run link servicing (EQ calibration, PHY mode selection, unmuting) */
        if (it6805_service_link(bar1)) { exit_code = 1; goto cleanup; }
        if (g_downscale_1080p && it68051_output_1080p(bar1)) exit_code = 1;
        show_status(bar1);
        if (bar0) show_fpga_probe(bar0);
    } else {
        if (do_edid && load_edid(bar1, is_4k)) { exit_code = 1; goto cleanup; }
        if (do_ttl && enable_ttl_output(bar1)) { exit_code = 1; goto cleanup; }
        if (do_hpd && pulse_hpd(bar1)) { exit_code = 1; goto cleanup; }
        if (do_service) {
            if (it6805_select_port0(bar1) || it6805_service_link(bar1)) {
                exit_code = 1;
                goto cleanup;
            }
            show_status(bar1);
            if (bar0) show_fpga_probe(bar0);
        }
        if (g_downscale_1080p &&
            (enable_ttl_output(bar1) || it68051_output_1080p(bar1))) exit_code = 1;
        if (do_dump) {
            dump_all_registers(bar1);
        }
        if (do_status) {
            show_status(bar1);
            if (bar0) show_fpga_probe(bar0);
        }
        if (do_probe && bar0) show_fpga_probe(bar0);
    }

    if ((do_pixel_mode || do_init || do_ttl) && !exit_code) {
        if (!bar0 || read32(bar0, BAR0_REG_C_VERSION) < 0x26101601) {
            if (g_single_pixel) {
                fprintf(stderr, "FPGA pixel mode NOT changed: requires C_VERSION 26101601+. RX configuration alone is not capture validation.\n");
                if (!g_downscale_1080p) exit_code = 1;
            }
        } else {
            uint32_t ctrl = read32(bar0, BAR0_REG_HDMI_TX_CTRL) & ~0x0Cu;
            if (g_single_pixel) ctrl |= 0x08;
            write32(bar0, BAR0_REG_HDMI_TX_CTRL, ctrl | 0x04);
            usleep(1000);
            write32(bar0, BAR0_REG_HDMI_TX_CTRL, ctrl);
            printf("FPGA pixel mode: %s\n", g_single_pixel ? "single" : "dual");
        }
    }
    if (do_monitor && !exit_code) monitor_loop(bar1, bar0);

cleanup:
    munmap((void *)bar1, 65536);
    close(fd);
    if (bar0) {
        munmap((void *)bar0, 1048576);
        close(fd0);
    }

    return exit_code || g_i2c_error;
}
