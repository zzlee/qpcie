/* SPDX-License-Identifier: Apache-2.0 */
#ifndef I2C0_SLAVE_H
#define I2C0_SLAVE_H

#include <stdint.h>
#include <stdbool.h>
#include "it6663.h"

#define I2C_ADDR_REG     0x32  /* Standard Register File */
#define I2C_ADDR_PROXY   0x33  /* I2C Proxy / Passthrough to I2C1 */
#define I2C_ADDR_UPG     0x2A  /* In-System Firmware Upgrade */
#define I2C_ADDR_EDID    0x50  /* EDID Emulation */

#define REG_FILE_SIZE    64

typedef struct {
    uint8_t regs[REG_FILE_SIZE];
    uint8_t proxy_rx_buf[32];
    uint8_t proxy_rx_len;
    uint8_t proxy_rx_idx;
    bool    reboot_requested;
    bool    edid_update_requested;
} i2c0_state_t;

extern volatile i2c0_state_t g_i2c0;
extern volatile bool         g_upg_flash_pending;
extern volatile uint16_t     g_upg_flash_len;

void i2c0_slave_init(it6663_info_t *info);
void i2c0_update_status(it6663_info_t *info);

#endif /* I2C0_SLAVE_H */
