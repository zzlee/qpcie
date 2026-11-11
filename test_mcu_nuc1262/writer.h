/* SPDX-License-Identifier: Apache-2.0 */
#ifndef WRITER_H
#define WRITER_H

#include <stdint.h>

#define WR_PAGE_SIZE      0x800UL       /* NUC1262 page size = 2048 bytes */
#define WR_APROM_START    0x0000UL      /* APROM base */
#define WR_APROM_END      0x20000UL     /* 128KB APROM */

#define WR_STAGE_ADDR     0x20001000UL
#define WR_STAGE_BYTES    8192UL
#define WR_STAGE_END      (WR_STAGE_ADDR + WR_STAGE_BYTES)
#define WR_RAM_END        0x20005000UL

#define WRITER_DIAGNOSTICS_ABI 1
#define WRITER_FAILURE_MAGIC 0x57524631UL /* WRF1; external MCU ICE inspection */
typedef struct {
    uint32_t magic, command, address, error;
} writer_failure_t;
extern volatile writer_failure_t g_writer_failure;

/* SRAM-only writer. A negative return means PRE-ERASE rejection, so APROM is
 * untouched. After the first erase attempt: success resets only after FMC
 * readback; failure masks IRQs and holds in SRAM awaiting external MCU rescue.
 * Failure hold services WDT intentionally; it is NOT runtime health or A/B.
 * Power/reset interruption can still brick this in-place APROM update. */
int writer_program_aprom(uint32_t dst_addr, const uint32_t *src, uint32_t nwords);

#endif /* WRITER_H */
