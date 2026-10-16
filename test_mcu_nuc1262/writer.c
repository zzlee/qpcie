/* SPDX-License-Identifier: Apache-2.0 */
#include "writer.h"
#include "NUC1262.h"

#define WR_FMC_ISPCMD_READ       0x00UL
#define WR_FMC_ISPCMD_PROGRAM    0x21UL
#define WR_FMC_ISPCMD_PAGE_ERASE 0x22UL
#define WR_FMC_TIMEOUT           0x100000UL

#define RAMFUNC __attribute__((section(".ramfunc"), noinline))

static RAMFUNC void wr_unlock(void)
{
    SYS->REGLCTL = 0x59UL;
    SYS->REGLCTL = 0x16UL;
    SYS->REGLCTL = 0x88UL;
}

static RAMFUNC int wr_wait_done(void)
{
    uint32_t t = WR_FMC_TIMEOUT;
    while (FMC->ISPTRG & FMC_ISPTRG_ISPGO_Msk) {
        if (--t == 0UL)
            return -1;
    }
    if (FMC->ISPSTS & FMC_ISPSTS_ISPFF_Msk) {
        FMC->ISPSTS |= FMC_ISPSTS_ISPFF_Msk;
        return -2;
    }
    return 0;
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
    if (end_addr > WR_APROM_END || end_addr < dst_addr)
        return -1;
    if (src == 0)
        return -1;

    wr_unlock();
    CLK->AHBCLK |= CLK_AHBCLK_ISPCKEN_Msk;
    FMC->ISPCTL = FMC_ISPCTL_ISPEN_Msk | FMC_ISPCTL_APUEN_Msk;

    /* Clear any stale ISPFF */
    if (FMC->ISPSTS & FMC_ISPSTS_ISPFF_Msk)
        FMC->ISPSTS |= FMC_ISPSTS_ISPFF_Msk;

    start_page = dst_addr & ~(WR_PAGE_SIZE - 1UL);
    end_page = (end_addr - 1UL) & ~(WR_PAGE_SIZE - 1UL);

    /* Erase pages */
    for (page = start_page; page <= end_page; page += WR_PAGE_SIZE) {
        FMC->ISPCMD = WR_FMC_ISPCMD_PAGE_ERASE;
        FMC->ISPADDR = page;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        if (wr_wait_done() != 0)
            return -3;
    }

    /* Program words */
    for (i = 0; i < nwords; i++) {
        FMC->ISPCMD = WR_FMC_ISPCMD_PROGRAM;
        FMC->ISPADDR = dst_addr + i * 4UL;
        FMC->ISPDAT = src[i];
        FMC->ISPTRG = 0x1UL;
        __ISB();
        if (wr_wait_done() != 0)
            return -4;
    }

    /* Verify words using FMC Read */
    for (i = 0; i < nwords; i++) {
        FMC->ISPCMD = WR_FMC_ISPCMD_READ;
        FMC->ISPADDR = dst_addr + i * 4UL;
        FMC->ISPDAT = 0UL;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        if (wr_wait_done() != 0)
            return -5;
        if (FMC->ISPDAT != src[i])
            return -6;
    }

    /* Re-lock */
    SYS->REGLCTL = 0UL;
    return 0;
}
