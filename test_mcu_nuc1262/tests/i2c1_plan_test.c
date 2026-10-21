/* SPDX-License-Identifier: Apache-2.0 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "i2c1_plan.h"
#include "i2c_proxy_response.h"

static void trace(uint32_t tx, uint32_t rx, const uint8_t *states,
                  const i2c1_action_t *actions, unsigned n)
{
    i2c1_plan_t p = {tx, rx, 0x08};
    for (unsigned i = 0; i < n; ++i) {
        /* Every unexpected state must fail without advancing any counters. */
        for (unsigned status = 0; status < 256; ++status) {
            if (status == p.expected)
                continue;
            i2c1_plan_t bad = p;
            assert(i2c1_plan_next(&bad, status) == I2C1_BAD_STATE);
            assert(bad.tx_left == p.tx_left && bad.rx_left == p.rx_left);
            assert(bad.expected == p.expected);
        }
        assert(i2c1_plan_next(&p, states[i]) == actions[i]);
    }
    assert(!p.tx_left && !p.rx_left);
}

static void transactions(void)
{
    const uint8_t ping[] = {0x08, 0x18};
    const i2c1_action_t ping_a[] = {I2C1_ADDR_W, I2C1_DONE};
    trace(0, 0, ping, ping_a, 2);
    const uint8_t wr[] = {0x08, 0x18, 0x28, 0x28};
    const i2c1_action_t wr_a[] = {I2C1_ADDR_W, I2C1_TX_BYTE, I2C1_TX_BYTE, I2C1_DONE};
    trace(2, 0, wr, wr_a, 4);
    const uint8_t rd[] = {0x08, 0x40, 0x58};
    const i2c1_action_t rd_a[] = {I2C1_ADDR_R, I2C1_RX_LAST, I2C1_DONE};
    trace(0, 1, rd, rd_a, 3);
    const uint8_t combined[] = {0x08, 0x18, 0x28, 0x10, 0x40, 0x50, 0x50, 0x58};
    const i2c1_action_t combined_a[] = {I2C1_ADDR_W, I2C1_TX_BYTE, I2C1_START,
        I2C1_ADDR_R, I2C1_RX_ACK, I2C1_RX_ACK, I2C1_RX_LAST, I2C1_DONE};
    trace(1, 3, combined, combined_a, 8);
    for (unsigned len = 1; len <= 32; ++len) {
        i2c1_plan_t p = {0, len, 0x08};
        assert(i2c1_plan_next(&p, 0x08) == I2C1_ADDR_R);
        i2c1_action_t a = i2c1_plan_next(&p, 0x40);
        for (unsigned i = 0; i < len; ++i) {
            uint8_t state = i + 1 < len ? 0x50 : 0x58;
            assert(a == (i + 1 < len ? I2C1_RX_ACK : I2C1_RX_LAST));
            a = i2c1_plan_next(&p, state);
        }
        assert(a == I2C1_DONE && !p.rx_left);
    }
}

static void response(void)
{
    uint8_t data[32];
    for (unsigned i = 0; i < sizeof(data); ++i)
        data[i] = (uint8_t)(i ^ 0xFF); /* FF is valid data, not an error sentinel. */
    for (uint8_t len = 1; len <= sizeof(data); ++len) {
        for (uint8_t status = 0; status <= 4; ++status) {
            uint8_t idx = 0;
            for (unsigned i = 0; i < len; ++i)
                assert(i2c_proxy_next(data, len, &idx, status) == data[i]);
            assert(i2c_proxy_next(data, len, &idx, status) == status);
            /* A malformed long read cannot wrap back to data or success. */
            for (unsigned i = 0; i < 512; ++i)
                assert(i2c_proxy_next(data, len, &idx, status) == 0xFF);
        }
    }
    uint8_t idx = 0;
    assert(i2c_proxy_next(data, 0, &idx, 4) == 4);
    assert(i2c_proxy_next(data, 0, &idx, 4) == 0xFF);
}

int main(void)
{
    transactions();
    response();
    puts("I2C1_PLAN_AND_PROXY_PASS (pure production helpers; no peripheral emulation)");
    return 0;
}
