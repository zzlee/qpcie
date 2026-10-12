/*
 * NUC100 I2C slave (minimal, 16-byte) for M2_710_N1_HDMI_4KP60_V21 (U2).
 *
 * Keeps test_mcu_minimal behavior (HXT/CLKO/PB.10/PB.15) and adds an
 * EEPROM-like 16-byte I2C slave so the PCIe host can reach the MCU through
 * the FPGA I2C master on the SDA/SCL_MCU bus.
 *
 * Default: I2C0 on PA.8(SDA)/PA.9(SCL), 7-bit address 0x2A.
 * Build with -DUSE_I2C1 to use I2C1 on PA.10/PA.11 instead (one rebuild,
 * no source change) if the assembled board wires SDA_MCU there.
 *
 * Register map (1-byte offset + auto-increment, wraps at 0x0F):
 *   0x00 MAGIC  RO = 0x2A
 *   0x01 VER    RO = 0x01
 *   0x02 STATUS RO (live): bit0=PA.4 INT_68051 raw, bit1=PA.5 SCDT raw,
 *                          bit2=PB.10 HPD state, bit3=PB.15 RSTn state
 *   0x03 CTRL   RW: bit0->PB.10 HPD0_CTRL (1=assert HPD),
 *                   bit1->PB.15 RSTn_PCIe (1=release reset tree)
 *   0x04..0x0F SCRATCH RW (loopback test)
 *
 * Writes to 0x00/0x01/0x02 are ignored. CTRL writes drive GPIOs immediately.
 */
#include "NUC100Series.h"
#include "i2c.h"

#ifndef SLAVE_ADDR_7BIT
#define SLAVE_ADDR_7BIT   (0x2AU)
#endif
#define REG_NUM           (16U)
#define REG_MAGIC         (0x00U)
#define REG_VER           (0x01U)
#define REG_STATUS        (0x02U)
#define REG_CTRL          (0x03U)
#define FW_VER            (0x01U)
#define HXT_TIMEOUT       (0x100000UL)

#ifdef USE_I2C1
#define SLV_I2C           I2C1
#define SLV_IRQn          I2C1_IRQn
#else
#define SLV_I2C           I2C0
#define SLV_IRQn          I2C0_IRQn
#endif

static volatile uint8_t g_reg[REG_NUM];
static volatile uint8_t g_ptr;
static volatile uint8_t g_rx_len;

void ProcessHardFault(void)
{
    while (1) {
    }
}

static void apply_ctrl(uint8_t ctrl)
{
    if (ctrl & 0x01U)
        PB->DOUT |= (1UL << 10);
    else
        PB->DOUT &= ~(1UL << 10);

    if (ctrl & 0x02U)
        PB->DOUT |= (1UL << 15);
    else
        PB->DOUT &= ~(1UL << 15);
}

static uint8_t live_status(void)
{
    uint8_t st = 0;
    uint32_t pa = PA->PIN;
    uint32_t pb = PB->DOUT;

    if (pa & (1UL << 4))
        st |= 0x01U;
    if (pa & (1UL << 5))
        st |= 0x02U;
    if (pb & (1UL << 10))
        st |= 0x04U;
    if (pb & (1UL << 15))
        st |= 0x08U;
    return st;
}

static void slave_next_tx(void)
{
    uint8_t idx = (uint8_t)(g_ptr & 0x0FU);

    if (idx == REG_STATUS)
        SLV_I2C->I2CDAT = live_status();
    else
        SLV_I2C->I2CDAT = g_reg[idx];
    g_ptr = (uint8_t)((idx + 1U) & 0x0FU);
}

static void slave_rx_byte(uint8_t dat)
{
    if (g_rx_len == 0U) {
        g_ptr = (uint8_t)(dat & 0x0FU);
    } else {
        uint8_t idx = (uint8_t)(g_ptr & 0x0FU);

        if (idx >= REG_CTRL) {
            g_reg[idx] = dat;
            if (idx == REG_CTRL)
                apply_ctrl(dat);
        }
        /* 0x00/0x01/0x02 are read-only: ignore data, still advance */
        g_ptr = (uint8_t)((idx + 1U) & 0x0FU);
    }
    g_rx_len++;
}

static void slave_handler(uint32_t status)
{
    if (status == 0x60U) {              /* SLA+W, ACK returned */
        g_rx_len = 0;
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else if (status == 0x80U) {       /* data received, ACK returned */
        slave_rx_byte((uint8_t)SLV_I2C->I2CDAT);
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else if (status == 0x88U) {       /* data received, NACK returned */
        g_rx_len = 0;
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else if (status == 0xA8U) {       /* SLA+R, ACK returned */
        slave_next_tx();
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else if (status == 0xB8U) {       /* data TXed, ACK received: more wanted */
        slave_next_tx();
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else if (status == 0xC0U) {       /* data TXed, NACK received: done */
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else if (status == 0xA0U) {       /* STOP or repeated START */
        g_rx_len = 0;
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else if ((status == 0x68U) || (status == 0xB0U)) {
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
    } else {
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_STO_SI);
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI);
        g_rx_len = 0;
    }
}

#ifndef USE_I2C1
void I2C0_IRQHandler(void)
{
    if (SLV_I2C->I2CTOC & I2C_I2CTOC_TIF_Msk) {
        SLV_I2C->I2CTOC |= I2C_I2CTOC_TIF_Msk;
        g_rx_len = 0;
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
        return;
    }
    slave_handler(SLV_I2C->I2CSTATUS);
}
#else
void I2C1_IRQHandler(void)
{
    if (SLV_I2C->I2CTOC & I2C_I2CTOC_TIF_Msk) {
        SLV_I2C->I2CTOC |= I2C_I2CTOC_TIF_Msk;
        g_rx_len = 0;
        I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
        return;
    }
    slave_handler(SLV_I2C->I2CSTATUS);
}
#endif

static void i2c_slave_init(void)
{
    uint32_t div;

#ifdef USE_I2C1
    SYS->IPRSTC2 |= SYS_IPRSTC2_I2C1_RST_Msk;
    SYS->IPRSTC2 &= ~SYS_IPRSTC2_I2C1_RST_Msk;
    CLK->APBCLK |= CLK_APBCLK_I2C1_EN_Msk;
    /* PA.10/PA.11 -> I2C1 (EBI_EN=0 + GPA_MFP10/11=1) */
    SYS->ALT_MFP &= ~(1UL << 11);
    SYS->GPA_MFP |= (1UL << 10) | (1UL << 11);
#else
    SYS->IPRSTC2 |= SYS_IPRSTC2_I2C0_RST_Msk;
    SYS->IPRSTC2 &= ~SYS_IPRSTC2_I2C0_RST_Msk;
    CLK->APBCLK |= CLK_APBCLK_I2C0_EN_Msk;
    /* PA.8/PA.9 -> I2C0 */
    SYS->GPA_MFP |= (1UL << 8) | (1UL << 9);
#endif

    SLV_I2C->I2CON |= I2C_I2CON_ENS1_Msk;

    /* Slave sampling clock; any sane divider works. CPU still on HIRC here. */
    SystemCoreClockUpdate();
    div = (SystemCoreClock / (100000UL * 4UL));
    if (div < 5UL)
        div = 5UL;
    SLV_I2C->I2CLK = (uint32_t)(div - 1UL);

    /* Exact-match 0x2A on ADDR0; park ADDR1-3 on 0x7F (unused). */
    SLV_I2C->I2CADDR0 = (uint32_t)((uint32_t)SLAVE_ADDR_7BIT << I2C_I2CADDR_I2CADDR_Pos);
    SLV_I2C->I2CADDR1 = (uint32_t)(0x7FU << I2C_I2CADDR_I2CADDR_Pos);
    SLV_I2C->I2CADDR2 = (uint32_t)(0x7FU << I2C_I2CADDR_I2CADDR_Pos);
    SLV_I2C->I2CADDR3 = (uint32_t)(0x7FU << I2C_I2CADDR_I2CADDR_Pos);
    SLV_I2C->I2CADM0 = 0UL;
    SLV_I2C->I2CADM1 = 0UL;
    SLV_I2C->I2CADM2 = 0UL;
    SLV_I2C->I2CADM3 = 0UL;

    SLV_I2C->I2CON |= (I2C_I2CON_EI_Msk | I2C_I2CON_AA_Msk);
    NVIC_EnableIRQ(SLV_IRQn);
    I2C_SET_CONTROL_REG(SLV_I2C, I2C_I2CON_SI_AA);
}

int main(void)
{
    uint32_t timeout;
    int hxt_ok = 0;
    uint32_t i;

    for (i = 0; i < REG_NUM; i++)
        g_reg[i] = 0U;
    g_reg[REG_MAGIC] = 0x2AU;
    g_reg[REG_VER] = FW_VER;
    g_reg[REG_CTRL] = 0x03U;   /* HPD asserted, reset released */
    g_ptr = 0;
    g_rx_len = 0;

    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;

    CLK->PWRCON |= CLK_PWRCON_XTL12M_EN_Msk;
    timeout = HXT_TIMEOUT;
    while (!(CLK->CLKSTATUS & CLK_CLKSTATUS_XTL12M_STB_Msk)) {
        if (--timeout == 0UL)
            break;
    }
    if (timeout != 0UL)
        hxt_ok = 1;

    if (hxt_ok) {
        SYS->ALT_MFP |= SYS_ALT_MFP_PB12_CLKO_Msk;
        SYS->GPB_MFP |= (1UL << 12);
        CLK->CLKSEL2 = (CLK->CLKSEL2 & ~CLK_CLKSEL2_FRQDIV_S_Msk)
                     | CLK_CLKSEL2_FRQDIV_S_HXT;
        CLK->FRQDIV &= ~CLK_FRQDIV_DIVIDER_EN_Msk;
        CLK->APBCLK |= CLK_APBCLK_FDIV_EN_Msk;
    }

    /* PA.4/PA.5 inputs (INT/SCDT sense); keep others untouched */
    PA->PMD &= ~((0x3UL << (4 * 2)) | (0x3UL << (5 * 2)));

    /* PB.10 (HPD) + PB.15 (RSTn_PCIe) push-pull HIGH */
    PB->PMD = (PB->PMD & ~((0x3UL << (10 * 2)) | (0x3UL << (15 * 2))))
            | ((0x1UL << (10 * 2)) | (0x1UL << (15 * 2)));
    PB->DOUT |= ((1UL << 10) | (1UL << 15));

    i2c_slave_init();

    SYS->REGWRPROT = 0x00UL;

    while (1) {
        __WFI();
    }
}
