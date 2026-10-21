/*
 * sc7f0_hdmi_init.c - Standalone Video PHY & HDMI RX Subsystem Initialization
 *                     and Telemetry Daemon for SC7F0 ZU4EV (SC7F0 N1 HDMI2 V11)
 *
 * Runs directly on the ZU4EV ARM Cortex-A53 Linux subsystem via /dev/mem.
 *
 * Register Maps:
 *   0xB0000000 - vid_phy_controller_0 (Base 0xB0000000, 64KB)
 *   0xB0010000 - v_hdmi_rx_ss_0       (Base 0xB0010000, 64KB)
 *   0xA0000000 - PL BAR0 CSR Space   (Base 0xA0000000, 64KB)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <signal.h>
#include <time.h>

#define VPHY_BASE_ADDR        0xB0000000ULL
#define HDMIRX_BASE_ADDR      0xB0010000ULL
#define PL_CSR_BASE_ADDR      0xA0000000ULL
#define MAP_SIZE              0x10000ULL

/* Video PHY Controller (vid_phy_controller) Registers */
#define VPHY_VER_ID_REG             0x000
#define VPHY_BANK_SELECT_REG        0x00C
#define VPHY_REF_CLK_SEL_REG        0x010
#define VPHY_PLL_RESET_REG          0x014
#define VPHY_PLL_LOCK_STATUS_REG    0x018
#define VPHY_TX_INIT_REG            0x01C
#define VPHY_TX_INIT_STATUS_REG     0x020
#define VPHY_RX_INIT_REG            0x024
#define VPHY_RX_INIT_STATUS_REG     0x028
#define VPHY_RX_CONTROL_REG         0x100
#define VPHY_RX_STATUS_REG          0x104
#define VPHY_CLKDET_CTRL_REG        0x200
#define VPHY_CLKDET_STAT_REG        0x204
#define VPHY_CLKDET_FREQ_TMR_TO_REG 0x208
#define VPHY_CLKDET_FREQ_TX_REG     0x20C
#define VPHY_CLKDET_FREQ_RX_REG     0x210
#define VPHY_CLKDET_TMR_RX_REG      0x218

/* HDMI RX Subsystem (v_hdmi_rx_ss) Registers */
#define HDMIRX_VER_ID_REG           0x000
#define HDMIRX_VER_VERSION_REG      0x004
#define HDMIRX_PIO_ID_REG           0x040
#define HDMIRX_PIO_CTRL_REG         0x044
#define HDMIRX_PIO_CTRL_SET_REG     0x048
#define HDMIRX_PIO_CTRL_CLR_REG     0x04C
#define HDMIRX_PIO_STA_REG          0x050
#define HDMIRX_PIO_OUT_REG          0x054
#define HDMIRX_PIO_OUT_SET_REG      0x058
#define HDMIRX_PIO_OUT_CLR_REG      0x05C
#define HDMIRX_PIO_IN_REG           0x064

#define HDMIRX_VTD_ID_REG           0x0C0
#define HDMIRX_VTD_CTRL_REG         0x0C4
#define HDMIRX_VTD_CTRL_SET_REG     0x0C8
#define HDMIRX_VTD_CTRL_CLR_REG     0x0CC
#define HDMIRX_VTD_STA_REG          0x0D0
#define HDMIRX_VTD_TOT_PIX_REG      0x0D4
#define HDMIRX_VTD_ACT_PIX_REG      0x0D8
#define HDMIRX_VTD_TOT_LIN_REG      0x0DC
#define HDMIRX_VTD_ACT_LIN_REG      0x0E0
#define HDMIRX_VTD_VSW_REG          0x0E4
#define HDMIRX_VTD_HSW_REG          0x0E8
#define HDMIRX_VTD_VFP_REG          0x0EC
#define HDMIRX_VTD_VBP_REG          0x0F0
#define HDMIRX_VTD_HFP_REG          0x0F4
#define HDMIRX_VTD_HBP_REG          0x0F8

/* PL CSR BAR0 Block 6 Registers (Offset 0x0600 - 0x0664) */
#define CSR_REG_HDMI_RX_STATUS      (0x0600 / 4)
#define CSR_REG_HDMI_RX_WIDTH       (0x0604 / 4)
#define CSR_REG_HDMI_RX_HEIGHT      (0x0608 / 4)
#define CSR_REG_HDMI_RX_PIXEL_CLK   (0x060C / 4)
#define CSR_REG_HDMI_RX_HFP         (0x0640 / 4)
#define CSR_REG_HDMI_RX_HSW         (0x0644 / 4)
#define CSR_REG_HDMI_RX_HBP         (0x0648 / 4)
#define CSR_REG_HDMI_RX_VFP         (0x064C / 4)
#define CSR_REG_HDMI_RX_VSW         (0x0650 / 4)
#define CSR_REG_HDMI_RX_VBP         (0x0654 / 4)
#define CSR_REG_HDMI_RX_COLOR_FMT   (0x0660 / 4)

static volatile bool keep_running = true;

static void sig_handler(int sig) {
    (void)sig;
    keep_running = false;
}

static inline void reg_write(volatile uint32_t *base, uint32_t offset, uint32_t val) {
    base[offset / 4] = val;
}

static inline uint32_t reg_read(volatile uint32_t *base, uint32_t offset) {
    return base[offset / 4];
}

static void print_diagnostics(volatile uint32_t *vphy,
                              volatile uint32_t *hdmirx,
                              volatile uint32_t *pl_csr)
{
    printf("\n=================================================================\n");
    printf(" SC7F0 ZU4EV HDMI RX & Video PHY Hardware Diagnostics\n");
    printf("=================================================================\n");

    /* Video PHY */
    uint32_t vphy_id      = reg_read(vphy, VPHY_VER_ID_REG);
    uint32_t ref_sel      = reg_read(vphy, VPHY_REF_CLK_SEL_REG);
    uint32_t pll_lock     = reg_read(vphy, VPHY_PLL_LOCK_STATUS_REG);
    uint32_t rx_init_st   = reg_read(vphy, VPHY_RX_INIT_STATUS_REG);
    uint32_t clkdet_ctrl  = reg_read(vphy, VPHY_CLKDET_CTRL_REG);
    uint32_t clkdet_stat  = reg_read(vphy, VPHY_CLKDET_STAT_REG);
    uint32_t rx_freq      = reg_read(vphy, VPHY_CLKDET_FREQ_RX_REG);

    printf("[Video PHY Controller (0xB0000000)]\n");
    printf("  Core ID / Version  : 0x%08X\n", vphy_id);
    printf("  RefClk Select Reg  : 0x%08X (CPLL RefClk=%u)\n", ref_sel, (ref_sel >> 4) & 0xF);
    printf("  PLL Lock Status    : 0x%08X (Ch1=%u, Ch2=%u, Ch3=%u)\n",
           pll_lock, pll_lock & 1, (pll_lock >> 1) & 1, (pll_lock >> 2) & 1);
    printf("  RX ResetDone Status: 0x%08X (ResetDone=0x%06X)\n", rx_init_st, rx_init_st & 0xFFFFFF);
    printf("  Clock Detector Ctrl: 0x%08X (Run=%u)\n", clkdet_ctrl, clkdet_ctrl & 1);
    printf("  Clock Detector Stat: 0x%08X (RX_Zero=%u)\n", clkdet_stat, (clkdet_stat >> 1) & 1);
    printf("  Measured TMDS Clock: %u Hz (%.3f MHz)\n", rx_freq, (double)rx_freq / 1000000.0);

    /* HDMI RX SS */
    uint32_t rx_id    = reg_read(hdmirx, HDMIRX_VER_ID_REG);
    uint32_t rx_ver   = reg_read(hdmirx, HDMIRX_VER_VERSION_REG);
    uint32_t pio_ctrl = reg_read(hdmirx, HDMIRX_PIO_CTRL_REG);
    uint32_t pio_out  = reg_read(hdmirx, HDMIRX_PIO_OUT_REG);
    uint32_t pio_in   = reg_read(hdmirx, HDMIRX_PIO_IN_REG);

    uint32_t vtd_ctrl = reg_read(hdmirx, HDMIRX_VTD_CTRL_REG);
    uint32_t vtd_sta  = reg_read(hdmirx, HDMIRX_VTD_STA_REG);
    uint32_t act_w    = reg_read(hdmirx, HDMIRX_VTD_ACT_PIX_REG);
    uint32_t act_h    = reg_read(hdmirx, HDMIRX_VTD_ACT_LIN_REG);
    uint32_t tot_w    = reg_read(hdmirx, HDMIRX_VTD_TOT_PIX_REG);
    uint32_t tot_h    = reg_read(hdmirx, HDMIRX_VTD_TOT_LIN_REG);
    uint32_t hsw      = reg_read(hdmirx, HDMIRX_VTD_HSW_REG);
    uint32_t hfp      = reg_read(hdmirx, HDMIRX_VTD_HFP_REG);
    uint32_t hbp      = reg_read(hdmirx, HDMIRX_VTD_HBP_REG);
    uint32_t vsw      = reg_read(hdmirx, HDMIRX_VTD_VSW_REG);
    uint32_t vfp      = reg_read(hdmirx, HDMIRX_VTD_VFP_REG);
    uint32_t vbp      = reg_read(hdmirx, HDMIRX_VTD_VBP_REG);

    printf("\n[HDMI RX Subsystem (0xB0010000)]\n");
    printf("  Core ID / Version  : 0x%08X / 0x%08X\n", rx_id, rx_ver);
    printf("  PIO State          : Ctrl=0x%08X, Out=0x%08X, In=0x%08X\n", pio_ctrl, pio_out, pio_in);
    printf("  HPD Signal State   : %s (Bit 3)\n", (pio_out & (1 << 3)) ? "HIGH (Asserted)" : "LOW (Deasserted)");
    printf("  Link/Video En      : LnkEn=%u, VidEn=%u, AxisEn=%u\n",
           (pio_out >> 1) & 1, (pio_out >> 2) & 1, (pio_out >> 19) & 1);
    printf("  VTD Detector State : Ctrl=0x%08X, Status=0x%08X (Locked=%u)\n",
           vtd_ctrl, vtd_sta, vtd_sta & 1);
    printf("  Detected Resolution: %u x %u (Total H=%u, Total V=%u)\n",
           act_w, act_h, tot_w, tot_h);
    if (act_w > 0 && act_h > 0) {
        printf("  Timing Parameters  : HFP=%u, HSW=%u, HBP=%u | VFP=%u, VSW=%u, VBP=%u\n",
               hfp, hsw, hbp, vfp, vsw, vbp);
    }

    /* PL BAR0 CSR */
    if (pl_csr) {
        printf("\n[PL BAR0 CSR Space (0xA0000600)]\n");
        printf("  REG_HDMI_RX_STATUS : 0x%08X\n", pl_csr[CSR_REG_HDMI_RX_STATUS]);
        printf("  REG_HDMI_RX_RES    : %u x %u\n",
               pl_csr[CSR_REG_HDMI_RX_WIDTH], pl_csr[CSR_REG_HDMI_RX_HEIGHT]);
        printf("  REG_HDMI_RX_CLK    : %u Hz\n", pl_csr[CSR_REG_HDMI_RX_PIXEL_CLK]);
    }
    printf("=================================================================\n\n");
}

static int init_vphy_and_rxss(volatile uint32_t *vphy,
                              volatile uint32_t *hdmirx,
                              volatile uint32_t *pl_csr)
{
    printf("[*] Starting Video PHY Controller & HDMI RX Subsystem Initialization...\n");

    /* 0. Unlock IT6663 via I2C */
    printf("[0/6] Unlocking IT6663 HDMI Receiver via I2C (Bus 0)...\n");
    int i2c_ret = system("i2ctransfer -y 0 w3@0x33 0x96 0xFF 0xC3 && "
                         "i2ctransfer -y 0 w3@0x33 0x96 0xFF 0xA5 && "
                         "i2ctransfer -y 0 w3@0x33 0x96 0x15 0x18 && "
                         "i2ctransfer -y 0 w3@0x33 0x6B 0x01 0x03 r1@0x33 > /dev/null 2>&1");
    if (i2c_ret == 0) {
        printf("      IT6663 unlocked successfully.\n");
    } else {
        printf("      IT6663 unlock command returned %d (continuing)...\n", i2c_ret);
    }
    usleep(20000);

    /* 1. Configure Video PHY CPLL Reference Clock */
    /* Ref Clk Sel (0x010): Set CPLL RefClk to GTREFCLK1 (value 2 -> bits [7:4] = 0x20) */
    printf("[1/6] Selecting CPLL Reference Clock: GTREFCLK1 (IT6663 TMDS)...\n");
    uint32_t ref_sel = reg_read(vphy, VPHY_REF_CLK_SEL_REG);
    ref_sel &= ~0x000000F0;
    ref_sel |= (2 << 4); /* GTREFCLK1 */
    reg_write(vphy, VPHY_REF_CLK_SEL_REG, ref_sel);
    usleep(10000);

    /* 2. Configure and start Clock Detector */
    printf("[2/6] Configuring and starting Clock Detector...\n");
    /* Timeout period = 100MHz (100,000,000 cycles) */
    reg_write(vphy, VPHY_CLKDET_FREQ_TMR_TO_REG, 100000000);
    /* Run=1, Threshold=40 (0x28 << 5), AccRange=8 (0x8 << 13) -> 0x10501 */
    reg_write(vphy, VPHY_CLKDET_CTRL_REG, 0x10501);
    usleep(50000);

    uint32_t measured_freq = reg_read(vphy, VPHY_CLKDET_FREQ_RX_REG);
    printf("      Clock Detector Measured Frequency: %u Hz (%.3f MHz)\n",
           measured_freq, (double)measured_freq / 1000000.0);

    /* 3. Reset Video PHY PLL & Transceivers */
    printf("[3/6] Asserting PLL and GT Resets for RX Channels (Ch1..Ch3)...\n");
    /* Reset PLL */
    reg_write(vphy, VPHY_PLL_RESET_REG, 0x01); /* CPLL Reset */
    usleep(10000);
    reg_write(vphy, VPHY_PLL_RESET_REG, 0x00);
    usleep(10000);

    /* Assert PLLGTRESET (0x808080) and GTRESET (0x010101) */
    reg_write(vphy, VPHY_RX_INIT_REG, 0x808080 | 0x010101);
    usleep(20000);
    reg_write(vphy, VPHY_RX_INIT_REG, 0x000000);
    usleep(50000);

    /* Wait for CPLL Lock (0x07 on Ch1..Ch3) */
    int lock_retries = 20;
    uint32_t pll_lock = 0;
    while (lock_retries-- > 0) {
        pll_lock = reg_read(vphy, VPHY_PLL_LOCK_STATUS_REG);
        if ((pll_lock & 0x07) == 0x07) {
            printf("      CPLL Lock Acquired! (0x%02X)\n", pll_lock & 0x07);
            break;
        }
        usleep(10000);
    }
    if ((pll_lock & 0x07) != 0x07) {
        printf("      [WARNING] CPLL Lock not yet reported (0x%02X), continuing...\n", pll_lock & 0x07);
    }

    /* Assert USERRDY for Ch1..Ch3 (0x404040) */
    printf("[4/6] Asserting RX USERRDY (0x404040)...\n");
    reg_write(vphy, VPHY_RX_INIT_REG, 0x404040);
    usleep(50000);

    uint32_t rx_init_st = reg_read(vphy, VPHY_RX_INIT_STATUS_REG);
    printf("      RX Init Status: 0x%08X (ResetDone=0x%06X)\n", rx_init_st, rx_init_st & 0xFFFFFF);

    /* 4. Configure HDMI RX Subsystem PIO and HPD */
    printf("[5/6] Initializing HDMI RX Subsystem PIO & HPD...\n");
    /* Run PIO */
    reg_write(hdmirx, HDMIRX_PIO_CTRL_SET_REG, 0x01);
    usleep(10000);

    /* Assert HPD (Bit 3 = 0x08) */
    reg_write(hdmirx, HDMIRX_PIO_OUT_SET_REG, 0x08);
    /* Enable Link (Bit 1 = 0x02), Video (Bit 2 = 0x04), AXIS (Bit 19 = 0x80000) */
    reg_write(hdmirx, HDMIRX_PIO_OUT_SET_REG, 0x080006);
    usleep(10000);

    /* 5. Start Video Timing Detector (VTD) */
    printf("[6/6] Starting Video Timing Detector (VTD)...\n");
    reg_write(hdmirx, HDMIRX_VTD_CTRL_SET_REG, 0x01); /* Run VTD */
    usleep(100000);

    /* Check VTD status */
    uint32_t act_w = reg_read(hdmirx, HDMIRX_VTD_ACT_PIX_REG);
    uint32_t act_h = reg_read(hdmirx, HDMIRX_VTD_ACT_LIN_REG);
    printf("      VTD Initial Read: %u x %u\n", act_w, act_h);

    /* Update CSR Space if locked or valid */
    if (pl_csr) {
        uint32_t status = 0x03; // 5V present + HPD high
        if (act_w > 0 && act_h > 0) {
            status |= 0x0C; // TMDS Lock + Video Stream Lock (Total 0x0F)
        }
        pl_csr[CSR_REG_HDMI_RX_STATUS]    = status;
        pl_csr[CSR_REG_HDMI_RX_WIDTH]     = act_w;
        pl_csr[CSR_REG_HDMI_RX_HEIGHT]    = act_h;
        pl_csr[CSR_REG_HDMI_RX_PIXEL_CLK] = measured_freq;
        pl_csr[CSR_REG_HDMI_RX_HFP]       = reg_read(hdmirx, HDMIRX_VTD_HFP_REG);
        pl_csr[CSR_REG_HDMI_RX_HSW]       = reg_read(hdmirx, HDMIRX_VTD_HSW_REG);
        pl_csr[CSR_REG_HDMI_RX_HBP]       = reg_read(hdmirx, HDMIRX_VTD_HBP_REG);
        pl_csr[CSR_REG_HDMI_RX_VFP]       = reg_read(hdmirx, HDMIRX_VTD_VFP_REG);
        pl_csr[CSR_REG_HDMI_RX_VSW]       = reg_read(hdmirx, HDMIRX_VTD_VSW_REG);
        pl_csr[CSR_REG_HDMI_RX_VBP]       = reg_read(hdmirx, HDMIRX_VTD_VBP_REG);
    }

    printf("[+] Initialization complete!\n");
    return 0;
}

static void toggle_hpd(volatile uint32_t *hdmirx) {
    printf("[*] Toggling HDMI RX HPD (deasserting 500ms then asserting)...\n");
    /* Deassert HPD */
    reg_write(hdmirx, HDMIRX_PIO_OUT_CLR_REG, 0x08);
    usleep(500000);
    /* Assert HPD */
    reg_write(hdmirx, HDMIRX_PIO_OUT_SET_REG, 0x08);
    usleep(100000);
    printf("[+] HPD toggle complete (HPD is now HIGH).\n");
}

int main(int argc, char *argv[]) {
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("Failed to open /dev/mem (run as root)");
        return 1;
    }

    /* Map Video PHY Controller */
    volatile uint32_t *vphy = (volatile uint32_t *)mmap(
        NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
        mem_fd, VPHY_BASE_ADDR
    );
    if (vphy == MAP_FAILED) {
        perror("Failed to mmap Video PHY at 0xB0000000");
        close(mem_fd);
        return 1;
    }

    /* Map HDMI RX Subsystem */
    volatile uint32_t *hdmirx = (volatile uint32_t *)mmap(
        NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
        mem_fd, HDMIRX_BASE_ADDR
    );
    if (hdmirx == MAP_FAILED) {
        perror("Failed to mmap HDMI RX SS at 0xB0010000");
        munmap((void *)vphy, MAP_SIZE);
        close(mem_fd);
        return 1;
    }

    /* Map PL CSR Space */
    volatile uint32_t *pl_csr = (volatile uint32_t *)mmap(
        NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
        mem_fd, PL_CSR_BASE_ADDR
    );
    if (pl_csr == MAP_FAILED) {
        fprintf(stderr, "Note: PL CSR at 0xA0000000 unavailable or unmapped\n");
        pl_csr = NULL;
    }

    bool do_init   = false;
    bool do_toggle = false;
    bool do_daemon = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--init") == 0)        do_init = true;
        else if (strcmp(argv[i], "--hpd-toggle") == 0) do_toggle = true;
        else if (strcmp(argv[i], "--daemon") == 0)     do_daemon = true;
    }

    if (do_toggle) {
        toggle_hpd(hdmirx);
    }

    if (do_init) {
        init_vphy_and_rxss(vphy, hdmirx, pl_csr);
    }

    print_diagnostics(vphy, hdmirx, pl_csr);

    if (do_daemon) {
        printf("[*] Entering telemetry daemon loop (Ctrl+C to stop)...\n");
        while (keep_running) {
            uint32_t act_w = reg_read(hdmirx, HDMIRX_VTD_ACT_PIX_REG);
            uint32_t act_h = reg_read(hdmirx, HDMIRX_VTD_ACT_LIN_REG);
            uint32_t rx_freq = reg_read(vphy, VPHY_CLKDET_FREQ_RX_REG);

            if (pl_csr) {
                uint32_t status = 0x03; // 5V + HPD
                if (act_w > 0 && act_h > 0) {
                    status |= 0x0C; // TMDS + Video lock
                }
                pl_csr[CSR_REG_HDMI_RX_STATUS]    = status;
                pl_csr[CSR_REG_HDMI_RX_WIDTH]     = act_w;
                pl_csr[CSR_REG_HDMI_RX_HEIGHT]    = act_h;
                pl_csr[CSR_REG_HDMI_RX_PIXEL_CLK] = rx_freq;
            }
            sleep(1);
        }
    }

    if (pl_csr) munmap((void *)pl_csr, MAP_SIZE);
    munmap((void *)hdmirx, MAP_SIZE);
    munmap((void *)vphy, MAP_SIZE);
    close(mem_fd);
    return 0;
}
