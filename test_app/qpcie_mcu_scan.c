/*
 * qpcie_mcu_scan.c - QPCIe A50T MCU I2C bus tool (NUC100 slave @ 0x2A)
 *
 * Direct BAR1 MMIO access to the MCU I2C master (BAR1 0x5000, M05).
 * Unloads qpcie driver for exclusive access, like qpcie_a50t_tool.c.
 *
 * Usage:
 *   qpcie_mcu_scan --scan              scan MCU bus (expect 0x2A + 0x60 ATECC)
 *   qpcie_mcu_scan --dump              dump NUC100 16-byte register file
 *   qpcie_mcu_scan --loopback          scratch R/W loopback test (0x04)
 *   qpcie_mcu_scan --status            decode STATUS (0x02) live bits
 *   qpcie_mcu_scan --set-ctrl <hex>    write CTRL (0x03), e.g. 0x03
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

/* MCU I2C master in BAR1 (M05) */
#define BAR0_OFFSET_ENV_BLOCK    0x1000
#define BAR0_REG_BOARD_VERSION 0x1008  /* zzlab_env_ctrl C_BOARD_VERSION */

/* MCU I2C master in BAR1 (M05); FRONT master (M03) at HW-true 0x3000 */
#define BAR1_OFFSET_I2C_MCU  0x5000
#define BAR1_OFFSET_I2C_FRONT 0x3000

static uint32_t g_base = BAR1_OFFSET_I2C_MCU;
static const char *g_bus = "mcu";
#define REG_I2C_PRER_LO      0x00
#define REG_I2C_PRER_HI      0x04
#define REG_I2C_CTR          0x08
#define REG_I2C_TXR          0x0C
#define REG_I2C_RXR          0x0C
#define REG_I2C_CR           0x10
#define REG_I2C_SR           0x14

#define I2C_CTR_EN           (1u << 7)
#define I2C_CR_STA           (1u << 7)
#define I2C_CR_STO           (1u << 6)
#define I2C_CR_RD            (1u << 5)
#define I2C_CR_WR            (1u << 4)
#define I2C_CR_ACK           (1u << 3)
#define I2C_SR_RXACK         (1u << 7)
#define I2C_SR_TIP           (1u << 1)

#define NUC_ADDR             0x2A
#define TIMEOUT_MS           20

static char g_device_path[512] = {0};
static char g_bdf[256] = {0};

static inline void write32(volatile uint8_t *bar1, uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(bar1 + off) = v;
}

static inline uint32_t read32(volatile uint8_t *bar1, uint32_t off)
{
    return *(volatile uint32_t *)(bar1 + off);
}

static int wait_tip(volatile uint8_t *bar1)
{
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        uint32_t sr = read32(bar1, g_base + REG_I2C_SR);
        if (!(sr & I2C_SR_TIP))
            return 0;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double ms = (now.tv_sec - t0.tv_sec) * 1000.0 +
                    (now.tv_nsec - t0.tv_nsec) / 1000000.0;
        if (ms > TIMEOUT_MS)
            return -ETIMEDOUT;
        struct timespec ts = {0, 30000};
        nanosleep(&ts, NULL);
    }
}

/* Send one byte; returns 0 on ACK, -ENXIO on NACK, -ETIMEDOUT on TIP stuck */
static int send_byte(volatile uint8_t *bar1, uint8_t byte, uint32_t flags)
{
    write32(bar1, g_base + REG_I2C_TXR, byte);
    write32(bar1, g_base + REG_I2C_CR, flags | I2C_CR_WR);
    (void)read32(bar1, g_base + REG_I2C_CR); /* flush */
    int r = wait_tip(bar1);
    if (r)
        return r;
    if (read32(bar1, g_base + REG_I2C_SR) & I2C_SR_RXACK)
        return -ENXIO;
    return 0;
}

static int recv_byte(volatile uint8_t *bar1, uint8_t *byte, bool last)
{
    uint32_t cr = I2C_CR_RD | (last ? (I2C_CR_ACK | I2C_CR_STO) : 0);
    write32(bar1, g_base + REG_I2C_CR, cr);
    (void)read32(bar1, g_base + REG_I2C_CR);
    int r = wait_tip(bar1);
    if (r)
        return r;
    *byte = (uint8_t)(read32(bar1, g_base + REG_I2C_RXR) & 0xFF);
    return 0;
}

/* Probe: START + addr+W + STOP. Returns 0 if slave ACKs. */
static int probe(volatile uint8_t *bar1, uint8_t addr7)
{
    int r = send_byte(bar1, (uint8_t)(addr7 << 1), I2C_CR_STA | I2C_CR_STO);
    if (r == -ENXIO) {
        write32(bar1, g_base + REG_I2C_CR, I2C_CR_STO);
        wait_tip(bar1);
    }
    return r;
}

static int wr_regs(volatile uint8_t *bar1, uint8_t addr7, uint8_t off,
                   const uint8_t *data, int len)
{
    int r = send_byte(bar1, (uint8_t)(addr7 << 1), I2C_CR_STA);
    if (r)
        goto stop;
    for (int i = 0; i <= len; i++) {
        uint8_t b = (i == 0) ? off : data[i - 1];
        uint32_t f = (i == len) ? I2C_CR_STO : 0;
        r = send_byte(bar1, b, f);
        if (r)
            goto stop;
    }
    return 0;
stop:
    write32(bar1, g_base + REG_I2C_CR, I2C_CR_STO);
    wait_tip(bar1);
    return r;
}

static int rd_regs(volatile uint8_t *bar1, uint8_t addr7, uint8_t off,
                   uint8_t *buf, int len)
{
    int r = send_byte(bar1, (uint8_t)(addr7 << 1), I2C_CR_STA);
    if (r)
        goto stop;
    r = send_byte(bar1, off, 0);
    if (r)
        goto stop;
    r = send_byte(bar1, (uint8_t)((addr7 << 1) | 1), I2C_CR_STA);
    if (r)
        goto stop;
    for (int i = 0; i < len; i++) {
        r = recv_byte(bar1, &buf[i], i == len - 1);
        if (r)
            return r;
    }
    return 0;
stop:
    write32(bar1, g_base + REG_I2C_CR, I2C_CR_STO);
    wait_tip(bar1);
    return r;
}

static int find_qpcie(void)
{
    DIR *dir = opendir(SYSFS_PCI_BASE);
    struct dirent *e;
    if (!dir) {
        perror("opendir " SYSFS_PCI_BASE);
        return -1;
    }
    while ((e = readdir(dir)) != NULL) {
        char p[600], v[16] = {0}, d[16] = {0};
        int fd;
        if (e->d_name[0] == '.')
            continue;
        snprintf(p, sizeof(p), "%s/%s/vendor", SYSFS_PCI_BASE, e->d_name);
        fd = open(p, O_RDONLY);
        if (fd < 0)
            continue;
        if (read(fd, v, sizeof(v) - 1) < 0) {
            close(fd);
            continue;
        }
        close(fd);
        snprintf(p, sizeof(p), "%s/%s/device", SYSFS_PCI_BASE, e->d_name);
        fd = open(p, O_RDONLY);
        if (fd < 0)
            continue;
        if (read(fd, d, sizeof(d) - 1) < 0) {
            close(fd);
            continue;
        }
        close(fd);
        if (strstr(v, "0x12ab") && strstr(d, "0xe380")) {
            snprintf(g_device_path, sizeof(g_device_path), "%s/%s",
                     SYSFS_PCI_BASE, e->d_name);
            snprintf(g_bdf, sizeof(g_bdf), "%s", e->d_name);
            closedir(dir);
            return 0;
        }
    }
    closedir(dir);
    return -ENODEV;
}

static void usage(const char *p)
{
    printf("Usage: %s [--bus mcu|front] [--scan|--dump|--loopback|--status|--board-ver|--set-ctrl HEX]\n", p);
    printf("  Direct BAR MMIO: BAR1 I2C master (mcu=0x5000 default, front=0x3000);\n");
    printf("  BAR0 0x1008 board version. Unloads qpcie driver.\n");
}

int main(int argc, char **argv)
{
    bool do_scan = false, do_dump = false, do_lb = false, do_status = false;
    bool do_board = false;
    const char *ctrl_hex = NULL;
    static struct option lo[] = {
        {"scan", no_argument, 0, 's'},
        {"dump", no_argument, 0, 'd'},
        {"loopback", no_argument, 0, 'l'},
        {"status", no_argument, 0, 't'},
        {"board-ver", no_argument, 0, 'b'},
        {"bus", required_argument, 0, 'B'},
        {"set-ctrl", required_argument, 0, 'c'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    int o;
    while ((o = getopt_long(argc, argv, "sdlthbB:c:", lo, NULL)) != -1) {
        switch (o) {
        case 's': do_scan = true; break;
        case 'd': do_dump = true; break;
        case 'l': do_lb = true; break;
        case 't': do_status = true; break;
        case 'b': do_board = true; break;
        case 'B':
            if (!strcmp(optarg, "front")) {
                g_base = BAR1_OFFSET_I2C_FRONT;
                g_bus = "front";
            } else if (!strcmp(optarg, "mcu")) {
                g_base = BAR1_OFFSET_I2C_MCU;
                g_bus = "mcu";
            } else {
                usage(argv[0]);
                return 1;
            }
            break;
        case 'c': ctrl_hex = optarg; break;
        default: usage(argv[0]); return o == 'h' ? 0 : 1;
        }
    }
    if (!do_scan && !do_dump && !do_lb && !do_status && !do_board && !ctrl_hex) {
        usage(argv[0]);
        return 1;
    }

    if (find_qpcie() < 0) {
        printf("ERROR: No QPCIe device (12ab:e380).\n");
        return 1;
    }
    printf("Found QPCIe [%s]\n", g_bdf);

    bool had_drv = (access("/sys/module/qpcie", F_OK) == 0);
    if (had_drv) {
        printf("Unloading qpcie driver for direct MMIO...\n");
        if (system("rmmod qpcie 2>/dev/null") != 0)
            printf("WARN: rmmod qpcie failed, continuing\n");
        usleep(200000);
    }

    char rp[600];
    snprintf(rp, sizeof(rp), "%s/resource1", g_device_path);
    int fd = open(rp, O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open resource1 (need root)");
        return 1;
    }
    volatile uint8_t *bar1 = mmap(NULL, 65536, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, 0);
    if (bar1 == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }
    int rc = 0;

    /* Init master: 100 kHz @ 125 MHz, enable */
    write32(bar1, g_base + REG_I2C_PRER_LO, 249);
    write32(bar1, g_base + REG_I2C_PRER_HI, 0);
    write32(bar1, g_base + REG_I2C_CTR, I2C_CTR_EN);

    if (do_board) {
        char r0[600];
        snprintf(r0, sizeof(r0), "%s/resource0", g_device_path);
        int fd0 = open(r0, O_RDONLY);
        if (fd0 < 0) {
            perror("open resource0");
            rc = 1;
        } else {
            volatile uint8_t *bar0 = mmap(NULL, 65536, PROT_READ,
                                          MAP_SHARED, fd0, 0);
            if (bar0 == MAP_FAILED) {
                perror("mmap resource0");
                rc = 1;
            } else {
                uint32_t bv = read32(bar0,
                    BAR0_OFFSET_ENV_BLOCK + BAR0_REG_BOARD_VERSION);
                printf("BOARD_VERSION 0x%08X (expect 0x00000201 M2_710 REV2.1)%s\n",
                       bv, bv == 0x00000201 ? "  [OK]" : "  [MISMATCH]");
                if (bv != 0x00000201)
                    rc = 1;
                munmap((void *)bar0, 65536);
            }
            close(fd0);
        }
    }

    if (do_scan) {
        bool is_mcu = (g_base == BAR1_OFFSET_I2C_MCU);
        printf("--- %s bus scan (BAR1 0x%04X) ---\n", g_bus, g_base);
        for (int a = 0x08; a < 0x78; a++) {
            if (probe((volatile uint8_t *)bar1, (uint8_t)a) == 0)
                printf("  ACK 0x%02X%s%s\n", a,
                       (is_mcu && a == NUC_ADDR) ? "  <- NUC100" : "",
                       (is_mcu && a == 0x60) ? "  <- ATECC508A?" :
                       (!is_mcu && a == 0x18) ? "  <- TLV320?" :
                       (!is_mcu && (a == 0x48 || a == 0x49)) ? "  <- IT68051?" : "");
        }
    }

    if ((do_dump || do_status || do_lb || ctrl_hex) &&
        g_base != BAR1_OFFSET_I2C_MCU) {
        printf("ERROR: --dump/--status/--loopback/--set-ctrl need --bus mcu.\n");
        rc = 1;
        goto out;
    }

    if (do_dump || do_status || do_lb || ctrl_hex) {
        uint8_t regs[16];
        /* Quick presence check first */
        if (probe((volatile uint8_t *)bar1, NUC_ADDR) != 0) {
            printf("ERROR: NUC100 0x2A NACK. Check MCU fw + FPGA bitstream.\n");
            rc = 1;
            goto out;
        }
        if (rd_regs((volatile uint8_t *)bar1, NUC_ADDR, 0x00, regs, 16) != 0) {
            printf("ERROR: burst read failed.\n");
            rc = 1;
            goto out;
        }
        if (do_dump) {
            printf("--- NUC100 regs ---\n");
            for (int i = 0; i < 16; i++)
                printf("  [%02X] 0x%02X%s\n", i, regs[i],
                       i == 0 ? " MAGIC" : i == 1 ? " VER" :
                       i == 2 ? " STATUS" : i == 3 ? " CTRL" : "");
            if (regs[0] != 0x2A || regs[1] != 0x01) {
                printf("WARN: MAGIC/VER mismatch (fw mismatch?)\n");
                rc = 1;
            }
        }
        if (do_status) {
            uint8_t st = regs[2];
            printf("STATUS 0x%02X: INT=%d SCDT=%d HPD=%d RSTn=%d\n", st,
                   !!(st & 1), !!(st & 2), !!(st & 4), !!(st & 8));
        }
        if (ctrl_hex) {
            uint8_t c = (uint8_t)strtoul(ctrl_hex, NULL, 0);
            if (wr_regs((volatile uint8_t *)bar1, NUC_ADDR, 0x03, &c, 1) != 0) {
                printf("ERROR: CTRL write failed.\n");
                rc = 1;
            } else {
                printf("CTRL <= 0x%02X OK\n", c);
            }
        }
        if (do_lb) {
            uint8_t w = 0xA5, r = 0;
            if (wr_regs((volatile uint8_t *)bar1, NUC_ADDR, 0x04, &w, 1) != 0 ||
                rd_regs((volatile uint8_t *)bar1, NUC_ADDR, 0x04, &r, 1) != 0) {
                printf("ERROR: loopback transaction failed.\n");
                rc = 1;
            } else if (r != w) {
                printf("FAIL: wrote 0x%02X read 0x%02X\n", w, r);
                rc = 1;
            } else {
                printf("PASS: scratch loopback 0x%02X\n", r);
            }
        }
    }

out:
    munmap((void *)bar1, 65536);
    close(fd);
    return rc;
}
