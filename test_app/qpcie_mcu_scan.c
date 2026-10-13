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
#define BAR0_REG_BOARD_VERSION 0x0008  /* relative to BAR0_OFFSET_ENV_BLOCK */

/* MCU I2C master in BAR1 (M05); FRONT master (M03) at HW-true 0x3000 */
#define BAR1_OFFSET_I2C_MCU  0x5000
#define BAR1_OFFSET_I2C_FRONT 0x3000

static uint32_t g_base = BAR1_OFFSET_I2C_MCU;
static const char *g_bus = "mcu";
static uint32_t g_prer = 249; /* ~100 kHz @ 125 MHz; try 2499 (~10 kHz) for test */
static int g_step_ms = 0; /* inter-byte delay for slow-mode debug */
static uint32_t g_slv = 0x2A;
static uint32_t g_len = 16;
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
        if (!(sr & I2C_SR_TIP)) {
            if (g_step_ms > 0) {
                struct timespec ts = {g_step_ms / 1000, (g_step_ms % 1000) * 1000000L};
                nanosleep(&ts, NULL);
            }
            return 0;
        }
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

/* Ensure PCI Memory Space + Bus Master are enabled (Jetson clears them
 * across rescans/error containment; without Mem+ all MMIO reads as F's). */
static void ensure_mem_enabled(void)
{
    char p[600];
    snprintf(p, sizeof(p), "%s/config", g_device_path);
    int fd = open(p, O_RDWR);
    if (fd < 0)
        return;
    uint16_t cmd = 0;
    if (pread(fd, &cmd, sizeof(cmd), 4) == sizeof(cmd) && !(cmd & 0x0006)) {
        cmd |= 0x0006;
        if (pwrite(fd, &cmd, sizeof(cmd), 4) == sizeof(cmd))
            printf("(PCI COMMAND enabled: 0x%04X)\n", cmd);
    }
    close(fd);
}

static void usage(const char *p)
{
    printf("Usage: %s [--bus mcu|front] [--scan|--dump|--loopback|--status|--board-ver|--spy|--sniff SEC|--probe HEX|--set-ctrl HEX]\n", p);
    printf("  Direct BAR MMIO: BAR1 I2C master (mcu=0x5000 default, front=0x3000);\n");
    printf("  BAR0 0x1008 board version. Unloads qpcie driver.\n");
}

int main(int argc, char **argv)
{
    bool do_scan = false, do_dump = false, do_lb = false, do_status = false;
    bool do_board = false;
    bool do_spy = false;
    int do_sniff = -1;
    const char *probe_hex = NULL;
    const char *ctrl_hex = NULL;
    static struct option lo[] = {
        {"scan", no_argument, 0, 's'},
        {"dump", no_argument, 0, 'd'},
        {"loopback", no_argument, 0, 'l'},
        {"status", no_argument, 0, 't'},
        {"board-ver", no_argument, 0, 'b'},
        {"probe", required_argument, 0, 'p'},
        {"spy", no_argument, 0, 'y'},
        {"sniff", required_argument, 0, 'n'},
        {"prescaler", required_argument, 0, 'P'},
        {"slave", required_argument, 0, 'S'},
        {"step-ms", required_argument, 0, 'T'},
        {"len", required_argument, 0, 'L'},
        {"bus", required_argument, 0, 'B'},
        {"set-ctrl", required_argument, 0, 'c'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    int o;
    while ((o = getopt_long(argc, argv, "sdlthbB:c:p:P:S:L:yn:T:", lo, NULL)) != -1) {
        switch (o) {
        case 's': do_scan = true; break;
        case 'd': do_dump = true; break;
        case 'l': do_lb = true; break;
        case 't': do_status = true; break;
        case 'b': do_board = true; break;
        case 'p': probe_hex = optarg; break;
        case 'y': do_spy = true; break;
        case 'n': do_sniff = atoi(optarg); break;
        case 'P': g_prer = (uint32_t)strtoul(optarg, NULL, 0); break;
        case 'S': g_slv = (uint32_t)strtoul(optarg, NULL, 0); break;
        case 'L': g_len = (uint32_t)strtoul(optarg, NULL, 0); break;
        case 'T': g_step_ms = atoi(optarg); break;
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
    if (!do_scan && !do_dump && !do_lb && !do_status && !do_board && !ctrl_hex && !probe_hex && !do_spy && do_sniff < 0) {
        usage(argv[0]);
        return 1;
    }

    if (find_qpcie() < 0) {
        printf("ERROR: No QPCIe device (12ab:e380).\n");
        return 1;
    }
    printf("Found QPCIe [%s]\n", g_bdf);

    ensure_mem_enabled();

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

    /* Init master: prescaler g_prer, enable */
    write32(bar1, g_base + REG_I2C_PRER_LO, g_prer & 0xFF);
    write32(bar1, g_base + REG_I2C_PRER_HI, (g_prer >> 8) & 0xFF);
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

    if (probe_hex) {
        uint8_t a = (uint8_t)strtoul(probe_hex, NULL, 0);
        int r = probe((volatile uint8_t *)bar1, a);
        printf("probe %s 0x%02X: %s\n", g_bus, a, r == 0 ? "ACK" : "NACK");
    }

    if (do_spy) {
        /* Passive bus spy at 0x18/0x1C: levels + SCL/START/STOP counters.
         * Requires bitstream C_VERSION >= 26101301. */
        uint32_t a0 = read32(bar1, g_base + 0x18);
        uint32_t b0 = read32(bar1, g_base + 0x1C);
        sleep(2);
        uint32_t a1 = read32(bar1, g_base + 0x18);
        uint32_t b1 = read32(bar1, g_base + 0x1C);
        printf("spy %s: idle SCL=%d SDA=%d | SCL+=%u START+=%u STOP+=%u (2s)\n",
               g_bus, (a1 >> 1) & 1, a1 & 1,
               (unsigned short)((a1 >> 16) - (a0 >> 16)),
               (unsigned short)(b1 - b0),
               (unsigned short)((b1 >> 16) - (b0 >> 16)));
    }

    if (do_sniff >= 0) {
        /* Sniffer transcript (needs bitstream C_VERSION >= 26101302):
         * arm+clear, capture for N sec (run traffic in parallel), dump. */
        write32(bar1, g_base + 0x40, 1);
        sleep(do_sniff < 0 ? 0 : do_sniff);
        uint32_t st = read32(bar1, g_base + 0x40);
        uint32_t n = st & 0x1FF;
        if (n > 256)
            n = 256;
        printf("sniff %s: avail=%u ovf=%d\n", g_bus, st & 0x1FF, !!(st & 0x400));
        for (uint32_t i = 0; i < n; i++) {
            uint32_t e = read32(bar1, g_base + 0x44) & 0xFFFF;
            uint32_t mk = e >> 8, dt = e & 0xFF;
            if (mk == 0x03)
                printf("  Sr\n");
            else if (mk == 0x02)
                printf("  Sp\n");
            else if (mk == 0x01)
                printf("  %s\n", dt ? "NACK" : "ACK");
            else
                printf("  %02X\n", dt);
        }
        write32(bar1, g_base + 0x40, 0);
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

    if ((do_status || do_lb || ctrl_hex) &&
        g_base != BAR1_OFFSET_I2C_MCU) {
        printf("ERROR: --status/--loopback/--set-ctrl need --bus mcu.\n");
        rc = 1;
        goto out;
    }

    if (do_dump || do_status || do_lb || ctrl_hex) {
        uint8_t regs[16];
        uint32_t n = g_len > 16 ? 16 : g_len;
        /* Quick presence check first */
        if (probe((volatile uint8_t *)bar1, (uint8_t)g_slv) != 0) {
            printf("ERROR: slave 0x%02X NACK. Check fw + FPGA bitstream.\n",
                   (unsigned)g_slv);
            rc = 1;
            goto out;
        }
        if (rd_regs((volatile uint8_t *)bar1, (uint8_t)g_slv, 0x00, regs, (int)n) != 0) {
            printf("ERROR: burst read failed.\n");
            rc = 1;
            goto out;
        }
        if (do_dump) {
            printf("--- slave 0x%02X regs ---\n", (unsigned)g_slv);
            for (uint32_t i = 0; i < n; i++)
                printf("  [%02X] 0x%02X%s\n", i, regs[i],
                       (g_slv == NUC_ADDR && i == 0) ? " MAGIC" :
                       (g_slv == NUC_ADDR && i == 1) ? " VER" :
                       (g_slv == NUC_ADDR && i == 2) ? " STATUS" :
                       (g_slv == NUC_ADDR && i == 3) ? " CTRL" : "");
            if (g_slv == NUC_ADDR && (regs[0] != 0x2A || regs[1] != 0x01)) {
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
