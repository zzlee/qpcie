/*
 * NUC100 dual I2C slave (minimal, 16-byte) for M2_710_N1_HDMI_4KP60_V21 (U2).
 *
 * Keeps test_mcu_minimal behavior (HXT/CLKO/PB.10/PB.15) and adds an
 * EEPROM-like 16-byte I2C slave on BOTH I2C peripherals so the PCIe host
 * can reach the MCU through either FPGA I2C master:
 *   I2C0 on PA.8/PA.9  -> SDA/SCL_MCU   (FPGA N18/P18, ATECC508A bus)
 *   I2C1 on PA.10/PA.11 -> SDA/SCL_FRONT (FPGA T12/U12, IT68051/TLV bus)
 * Both answer at 7-bit 0x2A with a shared register file (separate offset
 * pointers per bus).
 *
 * Register map (1-byte offset + auto-increment, wraps at 0x0F):
 *   0x00 MAGIC  RO = 0x2A
 *   0x01 VER    RO = 0x03
 *   0x02 STATUS RO (live): bit0=PA.12 INT_68051 raw, bit1=PA.13 SCDT raw,
 *                          bit2=PB.10 HPD state, bit3=PB.15 RSTn state
 *   0x03 CTRL   RW: bit0->PB.10 HPD0_CTRL (1=HPD LOW, 0=HPD released),
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
#define FW_VER            (0x03U)
#define DEFAULT_CTRL      (0x02U) /* PB.10 LOW releases cable HPD via M1 */
#define HXT_TIMEOUT       (0x100000UL)
#define PARK_ADDR_7BIT    (0x7FU)

typedef struct {
    volatile uint8_t ptr;
    volatile uint8_t rx_len;
} slv_state_t;

static volatile uint8_t g_reg[REG_NUM];
static slv_state_t g_st0, g_st1;

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

    if (pa & (1UL << 12))
        st |= 0x01U;
    if (pa & (1UL << 13))
        st |= 0x02U;
    if (pb & (1UL << 10))
        st |= 0x04U;
    if (pb & (1UL << 15))
        st |= 0x08U;
    return st;
}

static void slave_next_tx(I2C_T *i2c, slv_state_t *s)
{
    uint8_t idx = (uint8_t)(s->ptr & 0x0FU);

    if (idx == REG_STATUS)
        i2c->I2CDAT = live_status();
    else
        i2c->I2CDAT = g_reg[idx];
    s->ptr = (uint8_t)((idx + 1U) & 0x0FU);
}

static void slave_rx_byte(slv_state_t *s, uint8_t dat)
{
    if (s->rx_len == 0U) {
        s->ptr = (uint8_t)(dat & 0x0FU);
    } else {
        uint8_t idx = (uint8_t)(s->ptr & 0x0FU);

        if (idx >= REG_CTRL) {
            g_reg[idx] = dat;
            if (idx == REG_CTRL)
                apply_ctrl(dat);
        }
        /* 0x00/0x01/0x02 are read-only: ignore data, still advance */
        s->ptr = (uint8_t)((idx + 1U) & 0x0FU);
    }
    s->rx_len++;
}

static void slave_handler(I2C_T *i2c, slv_state_t *s, uint32_t status)
{
    if (status == 0x60U) {              /* SLA+W, ACK returned */
        s->rx_len = 0;
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0x80U) {       /* data received, ACK returned */
        slave_rx_byte(s, (uint8_t)i2c->I2CDAT);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0x88U) {       /* data received, NACK returned */
        s->rx_len = 0;
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xA8U) {       /* SLA+R, ACK returned */
        slave_next_tx(i2c, s);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xB8U) {       /* data TXed, ACK received: more wanted */
        slave_next_tx(i2c, s);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xC0U) {       /* data TXed, NACK received: done */
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xA0U) {       /* STOP or repeated START */
        s->rx_len = 0;
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if ((status == 0x68U) || (status == 0xB0U)) {
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else {
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_STO_SI);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI);
        s->rx_len = 0;
    }
}

void I2C0_IRQHandler(void)
{
    if (I2C0->I2CTOC & I2C_I2CTOC_TIF_Msk) {
        I2C0->I2CTOC |= I2C_I2CTOC_TIF_Msk;
        g_st0.rx_len = 0;
        I2C_SET_CONTROL_REG(I2C0, I2C_I2CON_SI_AA);
        return;
    }
    slave_handler(I2C0, &g_st0, I2C0->I2CSTATUS);
}

void I2C1_IRQHandler(void)
{
    if (I2C1->I2CTOC & I2C_I2CTOC_TIF_Msk) {
        I2C1->I2CTOC |= I2C_I2CTOC_TIF_Msk;
        g_st1.rx_len = 0;
        I2C_SET_CONTROL_REG(I2C1, I2C_I2CON_SI_AA);
        return;
    }
    slave_handler(I2C1, &g_st1, I2C1->I2CSTATUS);
}

static void i2c_periph_slave_init(I2C_T *i2c)
{
    uint32_t div;

    i2c->I2CON |= I2C_I2CON_ENS1_Msk;

    /* Slave sampling clock; any sane divider works. CPU still on HIRC here. */
    SystemCoreClockUpdate();
    div = (SystemCoreClock / (100000UL * 4UL));
    if (div < 5UL)
        div = 5UL;
    i2c->I2CLK = (uint32_t)(div - 1UL);

    /* Exact-match 0x2A on ADDR0; park ADDR1-3 on 0x7F (unused). */
    i2c->I2CADDR0 = (uint32_t)((uint32_t)SLAVE_ADDR_7BIT << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADDR1 = (uint32_t)((uint32_t)PARK_ADDR_7BIT << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADDR2 = (uint32_t)((uint32_t)PARK_ADDR_7BIT << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADDR3 = (uint32_t)((uint32_t)PARK_ADDR_7BIT << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADM0 = 0UL;
    i2c->I2CADM1 = 0UL;
    i2c->I2CADM2 = 0UL;
    i2c->I2CADM3 = 0UL;

    i2c->I2CON |= (I2C_I2CON_EI_Msk | I2C_I2CON_AA_Msk);
    I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
}

static void i2c_slave_init(void)
{
    /* I2C0 on PA.8/PA.9 */
    SYS->IPRSTC2 |= SYS_IPRSTC2_I2C0_RST_Msk;
    SYS->IPRSTC2 &= ~SYS_IPRSTC2_I2C0_RST_Msk;
    CLK->APBCLK |= CLK_APBCLK_I2C0_EN_Msk;
    SYS->GPA_MFP |= (1UL << 8) | (1UL << 9);
    i2c_periph_slave_init(I2C0);

    /* I2C1 on PA.10/PA.11 (EBI_EN=0 + GPA_MFP10/11=1) */
    SYS->IPRSTC2 |= SYS_IPRSTC2_I2C1_RST_Msk;
    SYS->IPRSTC2 &= ~SYS_IPRSTC2_I2C1_RST_Msk;
    CLK->APBCLK |= CLK_APBCLK_I2C1_EN_Msk;
    SYS->ALT_MFP &= ~(1UL << 11);
    SYS->GPA_MFP |= (1UL << 10) | (1UL << 11);
    i2c_periph_slave_init(I2C1);

    NVIC_EnableIRQ(I2C0_IRQn);
    NVIC_EnableIRQ(I2C1_IRQn);
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
    g_reg[REG_CTRL] = DEFAULT_CTRL;
    g_st0.ptr = 0; g_st0.rx_len = 0;
    g_st1.ptr = 0; g_st1.rx_len = 0;

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

    /* PA.12/PA.13 inputs (INT/SCDT sense); keep others untouched */
    PA->PMD &= ~((0x3UL << (12 * 2)) | (0x3UL << (13 * 2)));

    /* Preload levels BEFORE switching to push-pull to avoid a GPIO glitch.
     * PB.10 is inverted by M1: LOW releases RX_HPD0 to SR3's +5V pullup.
     * Preserve legacy PB.15 behavior; only HPD polarity changes in VER03. */
    apply_ctrl(DEFAULT_CTRL);
    PB->PMD = (PB->PMD & ~((0x3UL << (10 * 2)) | (0x3UL << (15 * 2))))
            | ((0x1UL << (10 * 2)) | (0x1UL << (15 * 2)));

    i2c_slave_init();

    SYS->REGWRPROT = 0x00UL;

    while (1) {
        __WFI();
    }
}
