/* SPDX-License-Identifier: Apache-2.0 */
#ifndef I2C1_PLAN_H
#define I2C1_PLAN_H

#include <stdint.h>

/* Pure production transaction planner. Tests feed status codes, not emulated
 * peripherals. The executor alone owns IRQ masking, deadlines and STOP. */
typedef enum {
    I2C1_START, I2C1_ADDR_W, I2C1_ADDR_R, I2C1_TX_BYTE,
    I2C1_RX_ACK, I2C1_RX_LAST, I2C1_DONE, I2C1_BAD_STATE
} i2c1_action_t;

typedef struct {
    uint32_t tx_left, rx_left;
    uint8_t expected;
} i2c1_plan_t;

static inline i2c1_action_t i2c1_plan_next(i2c1_plan_t *p, uint8_t status)
{
    if (status != p->expected)
        return I2C1_BAD_STATE;
    switch (status) {
    case 0x08: /* START */
    case 0x10: /* repeated START */
        if (!p->tx_left && p->rx_left) {
            p->expected = 0x40;
            return I2C1_ADDR_R;
        }
        p->expected = 0x18;
        return I2C1_ADDR_W;
    case 0x18: /* SLA+W ACK */
    case 0x28: /* data transmitted ACK */
        if (p->tx_left) {
            --p->tx_left;
            p->expected = 0x28;
            return I2C1_TX_BYTE;
        }
        if (p->rx_left) {
            p->expected = 0x10;
            return I2C1_START;
        }
        return I2C1_DONE;
    case 0x50: /* data received, ACK sent */
    case 0x58: /* last data received, NACK sent */
        --p->rx_left;
        /* fall through */
    case 0x40: /* SLA+R ACK */
        if (!p->rx_left)
            return I2C1_DONE;
        if (p->rx_left > 1) {
            p->expected = 0x50;
            return I2C1_RX_ACK;
        }
        p->expected = 0x58;
        return I2C1_RX_LAST;
    default:
        return I2C1_BAD_STATE;
    }
}
#endif
