/* SPDX-License-Identifier: Apache-2.0 */
#include "writer.h"
#include "NUC1262.h"

#define WR_FMC_ISPCMD_READ       0x00UL
#define WR_FMC_ISPCMD_PROGRAM    0x21UL
#define WR_FMC_ISPCMD_PAGE_ERASE 0x22UL
#define WR_FMC_TIMEOUT           0x100000UL

#define RAMFUNC __attribute__((section(".ramfunc"), noinline))

volatile writer_failure_t g_writer_failure;

static RAMFUNC void wr_unlock(void)
{
    SYS->REGLCTL = 0x59UL;
    SYS->REGLCTL = 0x16UL;
    SYS->REGLCTL = 0x88UL;
}

/* APROM may already be partially erased, including main and the vectors.
 * Never return to it, enable interrupts, or request a reset on this path.
 * This is an UPDATE-FAILURE HOLD, not a healthy runtime heartbeat: servicing
 * WDT here prevents it booting a partial image while an external MCU ICE is
 * attached. It does NOT survive power loss or provide bootable rollback.
 * No Flash helper, ISR, printf, or recovery_feed() may be called here. */
static RAMFUNC __attribute__((noreturn)) void wr_fail_stop(uint32_t error)
{
    __disable_irq();
    g_writer_failure.command = FMC->ISPCMD;
    g_writer_failure.address = FMC->ISPADDR;
    g_writer_failure.error = error;
    __DSB();
    g_writer_failure.magic = WRITER_FAILURE_MAGIC;
    for (;;) {
        WDT->RSTCNT = 0x5aa5;
        __NOP();
    }
}

static RAMFUNC void wr_wait_done(uint32_t error)
{
    uint32_t t = WR_FMC_TIMEOUT;
    while (FMC->ISPTRG & FMC_ISPTRG_ISPGO_Msk) {
        if (--t == 0UL)
            wr_fail_stop(error);
    }
    if (FMC->ISPSTS & FMC_ISPSTS_ISPFF_Msk) {
        FMC->ISPSTS |= FMC_ISPSTS_ISPFF_Msk;
        wr_fail_stop(error);
    }
#ifndef MCU_BRIDGE
    /* Successful in-SRAM FMC progress; no Flash helper or ISR. */
    WDT->RSTCNT = 0x5aa5;
#endif
}

RAMFUNC int writer_program_aprom(uint32_t dst_addr, const uint32_t *src, uint32_t nwords)
{
    /* Reject BEFORE any destructive command. Check count before multiplying. */
    uintptr_t p = (uintptr_t)src;
    if (dst_addr != WR_APROM_START || nwords < 2 || nwords > WR_STAGE_BYTES / 4 ||
        (p & 3U) || p < WR_STAGE_ADDR || p > WR_STAGE_END ||
        nwords * 4UL > WR_STAGE_END - p)
        return -1;
    uint32_t end_addr = nwords * 4UL;
    uint32_t sp = src[0], reset_pc = src[1] & ~1UL;
    if ((sp & 7U) || sp <= WR_STAGE_END || sp > WR_RAM_END ||
        !(src[1] & 1U) || reset_pc < 8 || reset_pc >= end_addr)
        return -1;

    __disable_irq();
    wr_unlock();
    CLK->AHBCLK |= CLK_AHBCLK_ISPCKEN_Msk;
    FMC->ISPCTL = FMC_ISPCTL_ISPEN_Msk | FMC_ISPCTL_APUEN_Msk;
    FMC->ISPSTS |= FMC_ISPSTS_ISPFF_Msk; /* W1C stale failure flag */

    /* From the FIRST erase attempt onward there is NO return to APROM. */
    uint32_t end_page = (end_addr - 1UL) & ~(WR_PAGE_SIZE - 1UL);
    for (uint32_t page = 0; page <= end_page; page += WR_PAGE_SIZE) {
        FMC->ISPCMD = WR_FMC_ISPCMD_PAGE_ERASE;
        FMC->ISPADDR = page;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        wr_wait_done(3);
    }

    for (uint32_t i = 0; i < nwords; i++) {
        FMC->ISPCMD = WR_FMC_ISPCMD_PROGRAM;
        FMC->ISPADDR = i * 4UL;
        FMC->ISPDAT = src[i];
        FMC->ISPTRG = 0x1UL;
        __ISB();
        wr_wait_done(4);
    }

    /* Read actual Flash via FMC, not just the staged SRAM CRC. */
    for (uint32_t i = 0; i < nwords; i++) {
        FMC->ISPCMD = WR_FMC_ISPCMD_READ;
        FMC->ISPADDR = i * 4UL;
        FMC->ISPDAT = 0UL;
        FMC->ISPTRG = 0x1UL;
        __ISB();
        wr_wait_done(5);
        if (FMC->ISPDAT != src[i])
            wr_fail_stop(6);
    }

    SYS->REGLCTL = 0UL;
    /* Do NOT call NVIC_SystemReset(): LTO can share its out-of-line body
     * with runtime callers in Flash. Request reset directly from this SRAM
     * function, only after complete FMC readback. NUC1262 is ARMv8-M baseline. */
    __DSB();
    SCB->AIRCR = 0x05fa0004UL; /* VECTKEY=0x5fa, SYSRESETREQ=1 */
    __DSB();
    for (;;) { __NOP(); }
}
