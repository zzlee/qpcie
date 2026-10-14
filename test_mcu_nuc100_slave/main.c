/*
 * NUC100 APROM app (M2_710 U2): dual I2C slave + PCIe-driven APROM update.
 * Linked at 0x0800, dispatched by stage0. See docs/mcu-aprom-update.md.
 *
 * Register map (1-byte offset + auto-increment, wraps at 0x0F):
 *   0x00 MAGIC  RO = 0x2A
 *   0x01 VER    RO = 0x04 (upgrade-capable; tool accepts 02/03/04)
 *   0x02 STATUS RO live (PA.12 INT, PA.13 SCDT, PB.10/PB.15 latches)
 *   0x03 CTRL   RW raw GPIO (bit0 PB.10 inverted HPD, bit1 PB.15 RSTn)
 *   0x04..0x0F SCRATCH RW
 * First W byte 0xAA escapes the transaction to the upgrade engine.
 */
#include "NUC100Series.h"
#include "i2c.h"
#include "i2c_slave.h"
#include "board.h"
#include "regfile.h"
#include "upg.h"

#define APP_FW_VER 0x04U

/* App image header for stage0 (pinned @0x0800, len+crc patched post-link).
 * 64 bytes: stage0 validates magic/len/crc, inits app .data/.bss from these
 * fields, sets MSP, jumps to entry, and forwards I2C IRQs via i2c0h/i2c1h
 * (NOT the app vector table, which stays unused).
 */
extern uint32_t __etext, __data_start__, __data_end__, __bss_start__, __bss_end__;
extern uint32_t __StackTop;
int main(void);
void I2C0_IRQHandler(void);
void I2C1_IRQHandler(void);
__attribute__((section(".app_header"))) const struct {
    uint32_t magic, ver, len, crc;
    void (*entry)(void);
    void (*i2c0h)(void);
    void (*i2c1h)(void);
    uint32_t sp;
    uint32_t data_lma, data_vma, data_end;
    uint32_t bss_vma, bss_end;
    uint32_t resv[3];
} app_hdr = { UPG_APP_MAGIC, APP_FW_VER, 0UL, 0UL,
              (void (*)(void))main,
              (void (*)(void))I2C0_IRQHandler,
              (void (*)(void))I2C1_IRQHandler,
              (uint32_t)&__StackTop,
              (uint32_t)&__etext, (uint32_t)&__data_start__,
              (uint32_t)&__data_end__,
              (uint32_t)&__bss_start__,
              (uint32_t)&__bss_end__,
              0UL, 0UL, 0UL };

static i2c_ch_t g_c0, g_c1;

void ProcessHardFault(void)
{
    while (1) {
    }
}

void I2C0_IRQHandler(void)
{
    if (I2C0->I2CTOC & I2C_I2CTOC_TIF_Msk) {
        I2C0->I2CTOC |= I2C_I2CTOC_TIF_Msk;
        g_c0.rx_len = 0;
        g_c0.upg = 0;
        I2C_SET_CONTROL_REG(I2C0, I2C_I2CON_SI_AA);
        return;
    }
    i2c_slave_isr(I2C0, &g_c0);
}

void I2C1_IRQHandler(void)
{
    if (I2C1->I2CTOC & I2C_I2CTOC_TIF_Msk) {
        I2C1->I2CTOC |= I2C_I2CTOC_TIF_Msk;
        g_c1.rx_len = 0;
        g_c1.upg = 0;
        I2C_SET_CONTROL_REG(I2C1, I2C_I2CON_SI_AA);
        return;
    }
    i2c_slave_isr(I2C1, &g_c1);
}

int main(void)
{
    board_early_init();
    regfile_init(APP_FW_VER, 0x02U);
    i2c_slave_ch_init(I2C0, &g_c0, 0x2AU);
    i2c_slave_ch_init(I2C1, &g_c1, 0x2AU);
    NVIC_EnableIRQ(I2C0_IRQn);
    NVIC_EnableIRQ(I2C1_IRQn);
    SYS->REGWRPROT = 0x00UL;

    while (1) {
        upg_poll();
        __WFI();
    }
}
