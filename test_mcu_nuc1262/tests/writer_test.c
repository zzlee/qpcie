/* Executes the actual writer.c against fake registers; no hardware access. */
#define _GNU_SOURCE
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "NUC1262.h"
#include "writer.h"

#define STAGE 0x20001000UL
#define STAGE_BYTES 8192U
#define ERASE 0x22U
#define PROGRAM 0x21U
#define READ 0x00U
#define RESET 1
#define HOLD 2

fake_fmc_t fake_fmc;
fake_clk_t fake_clk;
fake_sys_t fake_sys;
fake_wdt_t fake_wdt;
fake_scb_t fake_scb;
static uint8_t flash[WR_APROM_END];
static jmp_buf outcome;
static unsigned commands, matches, inject_cmd, inject_nth;
static unsigned inject_kind; /* 1=ISPFF, 2=timeout, 3=read mismatch */
static int irq_masked;
static unsigned passed;

void writer_test_barrier(void)
{
    if (SCB->AIRCR == 0x05fa0004U) longjmp(outcome, RESET);
}
void writer_test_irq_disable(void) { irq_masked = 1; }
_Noreturn void NVIC_SystemReset(void) { longjmp(outcome, RESET); }
void writer_test_idle(void) { longjmp(outcome, HOLD); }

void writer_test_fmc_complete(void)
{
    uint32_t cmd = FMC->ISPCMD, addr = FMC->ISPADDR;
    assert(irq_masked);
    assert(addr < WR_APROM_END);
    ++commands;
    int inject = cmd == inject_cmd && ++matches == inject_nth;
    FMC->ISPSTS = 0;
    if (inject && inject_kind == 2)
        return; /* ISPGO stays set: production wait must time out. */
    FMC->ISPTRG = 0;
    if (inject && inject_kind == 1) {
        FMC->ISPSTS = FMC_ISPSTS_ISPFF_Msk;
        return;
    }
    if (cmd == ERASE) {
        assert((addr & (WR_PAGE_SIZE - 1)) == 0);
        memset(flash + addr, 0xff, WR_PAGE_SIZE);
    } else if (cmd == PROGRAM) {
        memcpy(flash + addr, (const void *)&FMC->ISPDAT, 4);
    } else {
        assert(cmd == READ);
        memcpy((void *)&FMC->ISPDAT, flash + addr, 4);
        if (inject && inject_kind == 3)
            FMC->ISPDAT ^= 1;
    }
}

static void prepare(void)
{
    memset(&fake_fmc, 0, sizeof(fake_fmc));
    memset(&fake_clk, 0, sizeof(fake_clk));
    memset(&fake_sys, 0, sizeof(fake_sys));
    memset(&fake_wdt, 0, sizeof(fake_wdt));
    memset(&fake_scb, 0, sizeof(fake_scb));
    memset(flash, 0x5a, sizeof(flash));
    uint32_t *src = (uint32_t *)STAGE;
    for (unsigned i = 0; i < STAGE_BYTES / 4; ++i)
        src[i] = 0x12340000U + i;
    src[0] = 0x20005000U;
    src[1] = 0x81U;
    commands = matches = inject_nth = inject_kind = 0;
    inject_cmd = ~0U;
    irq_masked = 1; /* main.c masks IRQs before calling the writer. */
}

static int run_writer(uint32_t dst, const uint32_t *src, uint32_t words, int *rc)
{
    int event = setjmp(outcome);
    if (!event)
        *rc = writer_program_aprom(dst, src, words);
    return event;
}

static void failure_case(unsigned cmd, unsigned nth, unsigned kind, unsigned words)
{
    prepare();
    inject_cmd = cmd; inject_nth = nth; inject_kind = kind;
    int rc = 123;
    int event = run_writer(0, (const uint32_t *)STAGE, words, &rc);
    if (event != HOLD) {
        fprintf(stderr, "FAIL: destructive command 0x%x fault %u returned to Flash (rc=%d, event=%d)\n",
                cmd, kind, rc, event);
        exit(1);
    }
    assert(irq_masked);
    assert(fake_wdt.RSTCNT == 0x5aa5U);
    assert(matches == nth); /* No subsequent FMC command after failure. */
#ifdef WRITER_DIAGNOSTICS_ABI
    assert(g_writer_failure.magic == WRITER_FAILURE_MAGIC);
    assert(g_writer_failure.command == cmd);
    assert(g_writer_failure.error != 0);
#endif
    ++passed;
}

static void reject_case(uint32_t dst, const uint32_t *src, uint32_t words)
{
    int rc = 123;
    int event = run_writer(dst, src, words, &rc);
    assert(event == 0 && rc < 0);
    assert(commands == 0);
    for (unsigned i = 0; i < sizeof(flash); ++i)
        assert(flash[i] == 0x5a);
    ++passed;
}

int main(int argc, char **argv)
{
    (void)argv;
    void *mapped = mmap((void *)STAGE, STAGE_BYTES, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (mapped == MAP_FAILED) { perror("mmap fake SRAM"); return 1; }
    assert(mapped == (void *)STAGE);
    /* Run this first: on the old writer it reproduces the unsafe return. */
    failure_case(ERASE, 1, 1, 64);
    if (argc > 1) return 0;
    failure_case(ERASE, 2, 1, 1024);
    failure_case(PROGRAM, 1, 1, 64);
    failure_case(PROGRAM, 37, 1, 64);
    failure_case(READ, 1, 1, 64);
    failure_case(READ, 64, 1, 64);
    failure_case(READ, 1, 3, 64);
    failure_case(READ, 64, 3, 64);
    failure_case(ERASE, 1, 2, 64);
    failure_case(PROGRAM, 1, 2, 64);
    failure_case(READ, 64, 2, 64);

    prepare(); reject_case(0, (const uint32_t *)STAGE, 0);
    prepare(); reject_case(0, (const uint32_t *)STAGE, 1);
    prepare(); reject_case(0, (const uint32_t *)STAGE, 0x40000001U);
    prepare(); reject_case(0, (const uint32_t *)STAGE, STAGE_BYTES / 4 + 1);
    prepare(); reject_case(0, NULL, 64);
    prepare(); reject_case(0, (const uint32_t *)(STAGE + 1), 64);
    prepare(); reject_case(0, (const uint32_t *)(STAGE - 4), 64);
    prepare(); reject_case(0, (const uint32_t *)(STAGE + STAGE_BYTES - 4), 2);
    prepare(); reject_case(4, (const uint32_t *)STAGE, 64);
    prepare(); reject_case(WR_APROM_END, (const uint32_t *)STAGE, 64);
    const uint32_t bad_sp[] = {0, 0x20001000U, WR_STAGE_END, 0x20005008U, 0x20005004U};
    for (unsigned i = 0; i < sizeof(bad_sp) / sizeof(bad_sp[0]); ++i) {
        prepare(); ((uint32_t *)STAGE)[0] = bad_sp[i];
        reject_case(0, (const uint32_t *)STAGE, 64);
    }
    const uint32_t bad_pc[] = {0x80U, 1, 0x101U, ~0U};
    for (unsigned i = 0; i < sizeof(bad_pc) / sizeof(bad_pc[0]); ++i) {
        prepare(); ((uint32_t *)STAGE)[1] = bad_pc[i];
        reject_case(0, (const uint32_t *)STAGE, 64);
    }
    const unsigned sizes[] = {64, 1024, STAGE_BYTES / 4};
    for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i) {
        prepare(); int rc = 123;
        assert(run_writer(0, (const uint32_t *)STAGE, sizes[i], &rc) == RESET);
        assert(memcmp(flash, (const void *)STAGE, sizes[i] * 4) == 0);
        assert(SYS->REGLCTL == 0);
        ++passed;
    }
    printf("writer register-model tests: %u passed\n", passed);
    assert(munmap(mapped, STAGE_BYTES) == 0);
    return 0;
}
