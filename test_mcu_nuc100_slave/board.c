/* Shared board bring-up implementation. */
#include "board.h"
#include "NUC100Series.h"

int board_early_init(void)
{
    uint32_t timeout;
    int hxt_ok = 0;

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

    /* PB.10 LOW (HPD released) + PB.15 HIGH, glitch-free preload */
    PB->DOUT &= ~(1UL << 10);
    PB->DOUT |= (1UL << 15);
    PB->PMD = (PB->PMD & ~((0x3UL << (10 * 2)) | (0x3UL << (15 * 2))))
            | ((0x1UL << (10 * 2)) | (0x1UL << (15 * 2)));

    /* I2C MFP: I2C0 PA.8/PA.9; I2C1 PA.10/PA.11 with EBI_EN=0 */
    SYS->ALT_MFP &= ~(1UL << 11);
    SYS->GPA_MFP |= (1UL << 8) | (1UL << 9) | (1UL << 10) | (1UL << 11);

    /* Reset + clock both I2C peripherals (REGWRPROT still unlocked). */
    SYS->IPRSTC2 |= SYS_IPRSTC2_I2C0_RST_Msk | SYS_IPRSTC2_I2C1_RST_Msk;
    SYS->IPRSTC2 &= ~(SYS_IPRSTC2_I2C0_RST_Msk | SYS_IPRSTC2_I2C1_RST_Msk);
    CLK->APBCLK |= CLK_APBCLK_I2C0_EN_Msk | CLK_APBCLK_I2C1_EN_Msk;

    /* Leave REGWRPROT unlocked: caller runs I2C init (protected regs),
     * then locks. */
    return hxt_ok;
}
