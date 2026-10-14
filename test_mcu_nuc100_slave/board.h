/* Shared board bring-up (APROM app + LDROM console).
 * Policy (matches VER03): HXT + PB.12 CLKO when crystal stable, PB.10 LOW
 * (releases cable HPD via M1), PB.15 HIGH (reset tree released),
 * PA.12/PA.13 inputs, I2C MFP for both buses. No I2C peripheral init here.
 */
#ifndef BOARD_H
#define BOARD_H

#include <stdint.h>

#define HXT_TIMEOUT 0x100000UL

/* Returns 1 when HXT stabilized (CLKO configured), 0 on HIRC fallback. */
int board_early_init(void);

#endif
