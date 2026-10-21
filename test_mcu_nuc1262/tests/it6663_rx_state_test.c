/* SPDX-License-Identifier: Apache-2.0 */
/* Synthetic register fixtures exercise the production pure helpers only.
 * This is not a physical lock, I2C, or capture test. */
#include "it6663_rx_state.h"
#include <assert.h>
#include <stdio.h>

static void set_size(uint8_t *p, uint16_t n)
{
    p[0] = (uint8_t)n;
    p[1] = (uint8_t)(n >> 8);
}

static it6663_rx_sample_t valid_sample(void)
{
    it6663_rx_sample_t s = {0};
    s.read_ok = s.cable_5v = true;
    s.before[1] = 0x11;
    s.before[2] = 0xF8;
    s.before[3] = 0x80;
    memcpy(s.after, s.before, sizeof(s.before));
    set_size(&s.timing[3], 4400);
    set_size(&s.timing[5], 3840);
    set_size(&s.timing[10], 2250);
    set_size(&s.timing[12], 2160);
    s.timing[7] = 88;
    s.timing[8] = 176;
    s.timing[14] = 10;
    s.timing[15] = 8;
    memcpy(s.timing_after, s.timing, sizeof(s.timing));
    return s;
}

static void assert_invalid(it6663_rx_sample_t *s)
{
    it6663_rx_observation_t o = it6663_rx_observe(s);
    assert(!o.timing_valid && o.h_active == 0 && o.v_active == 0);
}

int main(void)
{
    it6663_rx_sample_t s = valid_sample();
    it6663_rx_observation_t o = it6663_rx_observe(&s);
    assert(o.locked && o.timing_valid && o.hdmi && o.ratio40);
    assert(o.h_active == 3840 && o.v_active == 2160);

    /* Captured live bytes from the broken v1.1.12 state: never locked/4K. */
    const uint8_t captured[] = {0, 0x14, 0x80, 3, 0, 0xD1, 1, 0x58, 3, 0,
                               0xC2, 8, 0x70, 8, 0x0A, 0, 0, 0x28, 1};
    memcpy(s.timing, captured, sizeof(captured));
    memcpy(s.timing_after, captured, sizeof(captured));
    s.before[1] = s.before[2] = 1;
    s.before[3] = 0x20;
    memcpy(s.after, s.before, sizeof(s.before));
    o = it6663_rx_observe(&s);
    assert(!o.locked && !o.hdmi && !o.ratio40);
    assert_invalid(&s);

    /* No single lock signal, cached size, or failed I2C can imply lock. */
    const uint8_t index[] = {1, 1, 2, 3};
    const uint8_t mask[] = {1, 0x10, 8, 0x80};
    for (unsigned side = 0; side < 2; ++side) {
        for (unsigned i = 0; i < sizeof(index); ++i) {
            s = valid_sample();
            (side ? s.after : s.before)[index[i]] &= (uint8_t)~mask[i];
            assert_invalid(&s);
            assert(!it6663_rx_observe(&s).locked);
        }
    }
    s = valid_sample(); s.read_ok = false; assert_invalid(&s);
    s = valid_sample(); s.cable_5v = false; assert_invalid(&s);
    s = valid_sample(); s.before[0] = s.after[0] = 3; assert_invalid(&s);
    s = valid_sample(); s.timing_after[5] ^= 1; assert_invalid(&s);
    s = valid_sample(); set_size(&s.timing[3], 3);
    memcpy(s.timing_after, s.timing, sizeof(s.timing)); assert_invalid(&s);
    /* High vertical porch/sync bits must participate in geometry validation. */
    s = valid_sample(); s.timing[16] = 0xF1;
    memcpy(s.timing_after, s.timing, sizeof(s.timing)); assert_invalid(&s);
    memset(&s, 0xFF, sizeof(s));
    /* Avoid non-canonical bool representations in a pure fixture. */
    s.read_ok = s.cable_5v = true;
    assert_invalid(&s);

    /* No standard-width substitution or guessed mode from vertical active. */
    s = valid_sample(); set_size(&s.timing[5], 3800);
    memcpy(s.timing_after, s.timing, sizeof(s.timing));
    s.before[2] = s.after[2] = 0x78; /* HDMI, 1/10, despite 2160 lines */
    o = it6663_rx_observe(&s);
    assert(o.timing_valid && o.h_active == 3800 && !o.ratio40);
    s.before[2] = s.after[2] = 0x38; /* DVI bits, no forced HDMI */
    assert(!it6663_rx_observe(&s).hdmi);

    /* Control debounce is independent of whether prior TX is configured. */
    s = valid_sample(); o = it6663_rx_observe(&s);
    it6663_rx_policy_t p = {0};
    it6663_rx_action_t a;
    for (int i = 0; i < 24; ++i) {
        a = it6663_rx_policy_step(&p, true, &o);
        assert(!a.configure && !a.power_down);
    }
    a = it6663_rx_policy_step(&p, true, &o);
    assert(a.configure && !a.power_down);
    it6663_rx_observation_t invalid = {0};
    for (int i = 0; i < 50; ++i) {
        a = it6663_rx_policy_step(&p, true, &invalid);
        assert(!a.configure && !a.power_down && p.stable_polls == 0);
    }
    /* A brief loss requires 25 fresh good observations, no reset request. */
    for (int i = 0; i < 24; ++i)
        assert(!it6663_rx_policy_step(&p, true, &o).configure);
    assert(it6663_rx_policy_step(&p, true, &o).configure);
    /* Alternating candidates cannot accumulate enough votes. */
    for (int i = 0; i < 60; ++i) {
        o.ratio40 = !o.ratio40;
        assert(!it6663_rx_policy_step(&p, true, &o).configure);
    }
    for (int i = 0; i < 19; ++i)
        assert(!it6663_rx_policy_step(&p, false, &invalid).power_down);
    assert(it6663_rx_policy_step(&p, false, &invalid).power_down);
    for (int i = 0; i < 300; ++i)
        assert(it6663_rx_policy_step(&p, false, &invalid).power_down);
    assert(p.absent_polls == 20); /* No counter wrap. */
    a = it6663_rx_policy_step(&p, true, &invalid);
    assert(!a.configure && !a.power_down && p.absent_polls == 0);
    puts("MCU_RX_STATE_PASS: observation and TX-hold policy (unit tests only)");
    return 0;
}
