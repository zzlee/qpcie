/* SPDX-License-Identifier: Apache-2.0 */
#include "board.h"
#include "it6663.h"
#include "i2c1_plan.h"
#include "i2c.h"
#include <string.h>

#define I2C1_TIMEOUT_CYCLES 30000UL

static int wait_stop(void)
{
    uint32_t left = I2C1_TIMEOUT_CYCLES;
    while (I2C1->CTL & I2C_CTL_STO) {
        if (!--left)
            return -3;
    }
    return 0;
}

int i2c1_transfer(uint8_t addr, const uint8_t *tx, uint32_t txlen,
                  uint8_t *rx, uint32_t rxlen)
{
    if (addr > 0x7F || txlen > 64 || rxlen > 32
            || (txlen && !tx) || (rxlen && !rx))
        return -4;
    uint8_t *rx_begin = rx;
    if (rxlen)
        memset(rx, 0xFF, rxlen);

    /* Only I2C0 can call this master from an ISR. Mask that IRQ for ONE
     * transaction, never the whole poll/TX setup/EDID sequence. A pending
     * upstream request clock-stretches until STOP completes. Preserve its
     * previous enable state, including boot before slave initialization. */
    uint32_t enabled = NVIC_GetEnableIRQ(I2C0_IRQn);
    NVIC_DisableIRQ(I2C0_IRQn);
    int rc = wait_stop();
    if (rc)
        goto unlock;
    i2c1_plan_t p = {txlen, rxlen, 0x08};
    i2c1_action_t action = I2C1_START;
    for (;;) {
        uint32_t control = I2C_CTL_SI;
        switch (action) {
        case I2C1_START: control = I2C_CTL_STA_SI; break;
        case I2C1_ADDR_W: I2C1->DAT = addr << 1; break;
        case I2C1_ADDR_R: I2C1->DAT = (addr << 1) | 1; break;
        case I2C1_TX_BYTE: I2C1->DAT = *tx++; break;
        case I2C1_RX_ACK: control = I2C_CTL_SI_AA; break;
        default: break; /* RX_LAST: receive without AA */
        }
        I2C_SET_CONTROL_REG(I2C1, control);
        uint32_t left = I2C1_TIMEOUT_CYCLES;
        while (!(I2C1->CTL & I2C_CTL_SI)) {
            if (!--left) {
                rc = -1;
                goto stop;
            }
        }
        uint8_t status = (uint8_t)I2C1->STATUS;
        if (status == p.expected && (status == 0x50 || status == 0x58))
            *rx++ = (uint8_t)I2C1->DAT;
        action = i2c1_plan_next(&p, status);
        if (action == I2C1_BAD_STATE) {
            rc = -2;
            break;
        }
        if (action == I2C1_DONE)
            break;
    }
stop:
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
    if (wait_stop())
        rc = -3;
unlock:
    /* Do not expose partial data as valid to legacy callers either. */
    if (rc && rxlen)
        memset(rx_begin, 0xFF, rxlen);
    if (enabled)
        NVIC_EnableIRQ(I2C0_IRQn);
    return rc;
}

int i2c1_write(uint8_t addr, const uint8_t *data, uint32_t len)
{
    return i2c1_transfer(addr, data, len, NULL, 0);
}

int i2c1_read(uint8_t addr, uint8_t *data, uint32_t len)
{
    return i2c1_transfer(addr, NULL, 0, data, len);
}
