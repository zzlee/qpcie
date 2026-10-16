/* SPDX-License-Identifier: Apache-2.0 */
#ifndef WRITER_H
#define WRITER_H

#include <stdint.h>

#define WR_PAGE_SIZE      0x800UL       /* NUC1262 page size = 2048 bytes */
#define WR_APROM_START    0x0000UL      /* APROM base */
#define WR_APROM_END      0x20000UL     /* 128KB APROM */

/* Flash writer executes from SRAM to allow in-system programming of APROM */
int writer_program_aprom(uint32_t dst_addr, const uint32_t *src, uint32_t nwords);

#endif /* WRITER_H */
