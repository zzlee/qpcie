/* Shared I2C slave engine (APROM app + LDROM console).
 * One instance per bus. First W byte UPG_ESCAPE_BYTE escapes the
 * transaction to the upgrade engine (upg.c); SLA+R serves the pending
 * upgrade response if any, else the regfile hooks below.
 * Escape 0x04 (not 0xAA): 0xAA NACKs as a data byte on the M2_710 FPGA
 * I2C master path. Consequence: regfile offset 0x04 is unreachable as a
 * first W byte (scratch 0x05..0x0F unaffected; 0x04 reads still work
 * through pointer auto-increment).
 */
#ifndef I2C_SLAVE_H
#define I2C_SLAVE_H

#include <stdint.h>
#include "NUC100Series.h"
#include "i2c.h"
#include "upg.h"

#define UPG_ESCAPE_BYTE UPG_ESCAPE

typedef struct {
    volatile uint8_t ptr;
    volatile uint8_t rx_len;
    uint8_t  upg;             /* transaction routed to upgrade engine */
    uint8_t  bus;
    uint8_t  cmd[UPG_CMD_MAX];
    uint8_t  cmdlen;          /* MAX+1 means overflow; never wraps */
    uint8_t  resp[8];         /* pending upgrade response */
    uint8_t  resp_len;
    uint8_t  resp_idx;
} i2c_ch_t;

/* Regfile hooks. Weak dummies (console has no regfile); app overrides. */
uint8_t app_reg_read(uint8_t idx);
void app_reg_write(uint8_t idx, uint8_t val);

void i2c_slave_ch_init(I2C_T *i2c, i2c_ch_t *ch, uint8_t addr7);
void i2c_slave_isr(I2C_T *i2c, i2c_ch_t *ch);

#endif
