/*
 * Minimal bring-up firmware for NUC100LE3AN (U2) on P2140 board.
 *
 * Goal (and ONLY this): wake the HDMI front end so IT68051 answers I2C.
 *   1. PB.15 (RSTn_PCIe)  -> output HIGH : release reset tree (SU8 AND)
 *   2. PB.10 (HPD0_CTRL)   -> output HIGH : assert HPD to HDMI source
 *   3. PB.12 (CLKO)        -> 12.288 MHz HXT direct out -> FPGA E10
 *      (FRQDIV DIVIDER_EN=0 attempts bypass; if HXT dead, CLKO stays off
 *      and the core keeps running on HIRC -- never hangs waiting)
 *
 * What it does NOT do (left for Yuan FW or phase 2):
 *   EDID handling, ATECC/HDCP, audio ADC setup, LED, UART, I2C master use.
 */
#include "NUC100Series.h"

#define HXT_TIMEOUT   (0x100000UL)   /* ~100 ms-ish on HIRC, best effort */

/* Minimal HardFault stub required by BSP startup code */
void ProcessHardFault(void)
{
    while (1) {
        /* trap here for debugger inspection */
    }
}

int main(void)
{
    uint32_t timeout;
    int hxt_ok = 0;

    /* Unlock protected registers */
    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;

    /* Try external 12.288 MHz crystal, with timeout (never hangs) */
    CLK->PWRCON |= CLK_PWRCON_XTL12M_EN_Msk;
    timeout = HXT_TIMEOUT;
    while (!(CLK->CLKSTATUS & CLK_CLKSTATUS_XTL12M_STB_Msk)) {
        if (--timeout == 0)
            break;
    }
    if (timeout != 0)
        hxt_ok = 1;

    if (hxt_ok) {
        /* PB.12 -> CLKO: (EBI_EN=0, PB12_CLKO=1, GPB_MFP12=1) */
        SYS->ALT_MFP |= SYS_ALT_MFP_PB12_CLKO_Msk;
        SYS->GPB_MFP |= (1UL << 12);
        /* CKO source = HXT, divider bypassed (DIVIDER_EN=0) */
        CLK->CLKSEL2 = (CLK->CLKSEL2 & ~CLK_CLKSEL2_FRQDIV_S_Msk)
                     | CLK_CLKSEL2_FRQDIV_S_HXT;
        CLK->FRQDIV &= ~CLK_FRQDIV_DIVIDER_EN_Msk;
        CLK->APBCLK |= CLK_APBCLK_FDIV_EN_Msk;
    }

    /* PB.10 (HPD) + PB.15 (RSTn_PCIe) -> push-pull output, drive HIGH */
    PB->PMD = (PB->PMD & ~((0x3UL << (10 * 2)) | (0x3UL << (15 * 2))))
            | ((0x1UL << (10 * 2)) | (0x1UL << (15 * 2)));
    PB->DOUT |= ((1UL << 10) | (1UL << 15));

    /* Re-lock protected registers */
    SYS->REGWRPROT = 0x00UL;

    while (1) {
        __WFI();
    }
}
