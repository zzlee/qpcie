/* Direct-FMC APROM writer (stack-only; see writer.h). */
#include "writer.h"
#include "NUC100Series.h"

#define WR_FMC_ISPCMD_READ       0x00UL
#define WR_FMC_ISPCMD_PROGRAM    0x21UL
#define WR_FMC_ISPCMD_PAGE_ERASE 0x22UL
#define WR_FMC_TIMEOUT           0x100000UL
#define WR_APROM_START           0x0800UL
#define WR_APROM_END             0x20000UL
#define WR_PAGE_SIZE             0x200UL
#define WR_LDROM_MAGIC           0x4C443130UL

#define RAMFUNC __attribute__((section(".ramfunc"), noinline))

static RAMFUNC void wr_unlock(void)
{
    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;
}

static RAMFUNC int wr_wait_done(void)
{
    uint32_t t = WR_FMC_TIMEOUT;
    while (FMC->ISPTRG & FMC_ISPTRG_ISPGO_Msk) {
        if (--t == 0UL)
            return -1;
    }
    if (FMC->ISPCON & FMC_ISPCON_ISPFF_Msk) {
        FMC->ISPCON |= FMC_ISPCON_ISPFF_Msk;
        return -1;
    }
    return 0;
}

int writer_ldrom_valid(void)
{
    return 1;
}

RAMFUNC int writer_program_aprom(uint32_t dst_addr, const uint32_t *src, uint32_t nwords)
{
    uint32_t start_page, end_page, page, i;
    uint32_t end_addr;

    if (nwords == 0UL)
        return -1;
    if ((dst_addr & 3UL) != 0UL)
        return -1;
    end_addr = dst_addr + nwords * 4UL;
    if (dst_addr < WR_APROM_START || end_addr > WR_APROM_END || end_addr < dst_addr)
        return -1;
    if (src == 0)
        return -1;

    wr_unlock();
    CLK->AHBCLK |= CLK_AHBCLK_ISP_EN_Msk;
    FMC->ISPCON |= FMC_ISPCON_ISPEN_Msk | FMC_ISPCON_APUEN_Msk;

    /* Clear any stale ISPFF */
    if (FMC->ISPCON & FMC_ISPCON_ISPFF_Msk)
        FMC->ISPCON |= FMC_ISPCON_ISPFF_Msk;

    start_page = dst_addr & ~(WR_PAGE_SIZE - 1UL);
    end_page = (end_addr - 1UL) & ~(WR_PAGE_SIZE - 1UL);

    for (page = start_page; page <= end_page; page += WR_PAGE_SIZE) {
        FMC->ISPCMD = WR_FMC_ISPCMD_PAGE_ERASE;
        FMC->ISPADR = page;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        if (wr_wait_done() != 0)
            return -3;
    }

    for (i = 0; i < nwords; i++) {
        FMC->ISPCMD = WR_FMC_ISPCMD_PROGRAM;
        FMC->ISPADR = dst_addr + i * 4UL;
        FMC->ISPDAT = src[i];
        FMC->ISPTRG = 0x1UL;
        __ISB();
        if (wr_wait_done() != 0)
            return -4;
    }

    /* Verify using FMC ISP Read because APROM [0..4KB) is shadowed by LDROM while BS=1 */
    for (i = 0; i < nwords; i++) {
        FMC->ISPCMD = WR_FMC_ISPCMD_READ;
        FMC->ISPADR = dst_addr + i * 4UL;
        FMC->ISPDAT = 0UL;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        if (wr_wait_done() != 0)
            return -5;
        if (FMC->ISPDAT != src[i])
            return -5;
    }
    return 0;
}
