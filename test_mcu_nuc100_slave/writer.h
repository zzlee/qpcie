/* APROM flash writer. Runs from LDROM (or SRAM), NEVER from APROM itself:
 * the FMC rejects APROM-block writes while PC is in APROM (ISPFF).
 * Stack-only: no globals/statics (LDROM calls this before/around its own
 * init; keep it independent of .data/.bss).
 */
#ifndef WRITER_H
#define WRITER_H

#include <stdint.h>

/* Program APROM [dst, dst+nwords*4) from SRAM src. Erases covered 512B
 * pages, programs words, verifies by readback.
 * Returns 0 ok, <0 error: -1 range, -2 unlock/clock, -3 erase, -4 program,
 * -5 verify. Never touches [0x0, 0x800) (stage0) or anything >= 128KB. */
int writer_program_aprom(uint32_t dst_addr, const uint32_t *src, uint32_t nwords);

/* LDROM magic probe for upg_writer_ready(). */
int writer_ldrom_valid(void);

#endif
