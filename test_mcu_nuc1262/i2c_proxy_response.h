/* SPDX-License-Identifier: Apache-2.0 */
#ifndef I2C_PROXY_RESPONSE_H
#define I2C_PROXY_RESPONSE_H
#include <stdint.h>

/* Legacy clients read only len data bytes. Checked clients read len+1, with
 * the transaction's status last. No stale status reads on a separate transfer.
 * Old firmware emits FF for that extra byte, so checked reads fail closed. */
static inline uint8_t i2c_proxy_next(const volatile uint8_t *data, uint8_t len,
                                    volatile uint8_t *index, uint8_t status)
{
    uint8_t i = *index;
    if (i <= len) {
        *index = i + 1;
        return i < len ? data[i] : status;
    }
    return 0xFF; /* Saturate: long reads must never wrap back to valid data. */
}
#endif
