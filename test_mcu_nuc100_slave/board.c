/* Shared board bring-up implementation. */
#include "board.h"
#include "NUC100Series.h"

static void check_enable_iap(void)
{
    uint32_t cfg0, cfg1;

    CLK->AHBCLK |= CLK_AHBCLK_ISP_EN_Msk;
    FMC->ISPCON |= FMC_ISPCON_ISPEN_Msk;

    /* Read Config0 directly from 0x00300000 (FMC_CONFIG_BASE) */
    FMC->ISPCMD = 0x00UL;
    FMC->ISPADR = 0x00300000UL;
    FMC->ISPTRG = 0x1UL;
    __ISB();
    while (FMC->ISPTRG & 0x1UL);
    cfg0 = FMC->ISPDAT;

    /* Check if CBS (bits [7:6]) is 10'b (APROM + IAP mode).
     * Factory default or erased CONFIG0 is 0xFF (CBS = 11'b, non-IAP mode). */
    if ((cfg0 & 0xC0UL) != 0x80UL) {
        FMC->ISPCON |= FMC_ISPCON_CFGUEN_Msk;

        /* Read Config1 */
        FMC->ISPCMD = 0x00UL;
        FMC->ISPADR = 0x00300004UL;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        while (FMC->ISPTRG & 0x1UL);
        cfg1 = FMC->ISPDAT;

        /* Set CBS to 10'b (APROM + IAP mode) */
        cfg0 &= ~0xC0UL;
        cfg0 |= 0x80UL;

        /* Page Erase Config Page */
        FMC->ISPCMD = 0x22UL;
        FMC->ISPADR = 0x00300000UL;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        while (FMC->ISPTRG & 0x1UL);

        /* Program Config0 */
        FMC->ISPCMD = 0x21UL;
        FMC->ISPADR = 0x00300000UL;
        FMC->ISPDAT = cfg0;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        while (FMC->ISPTRG & 0x1UL);

        /* Program Config1 */
        FMC->ISPCMD = 0x21UL;
        FMC->ISPADR = 0x00300004UL;
        FMC->ISPDAT = cfg1;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        while (FMC->ISPTRG & 0x1UL);

        /* Must perform whole-chip reset for new User Config (CBS) to reload into FMC hardware */
        SYS->IPRSTC1 = SYS_IPRSTC1_CHIP_RST_Msk;
        while (1);
    }
}

int board_early_init(void)
{
    uint32_t timeout;
    int hxt_ok = 0;

    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;

    check_enable_iap();

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
