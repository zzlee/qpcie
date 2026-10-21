/* SPDX-License-Identifier: Apache-2.0 */
#ifndef IT6663_RX_STATE_H
#define IT6663_RX_STATE_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/* Pure observation/policy helpers, shared with host-side unit tests.
 * Vendor references: IT6664_hdmi2_rx.c get_vid_info_6664()/AutoEQ.
 * Status array: bank 0x0F, RXP0 0x13, 0x14, 0x19. Sequential reads are
 * conservative consistency checks, not a hardware-latched atomic snapshot.
 */
typedef struct {
    bool read_ok;
    bool cable_5v;
    uint8_t before[4], after[4];
    uint8_t timing[19], timing_after[19]; /* 0x98 .. 0xAA */
} it6663_rx_sample_t;

typedef struct {
    bool locked, timing_valid, hdmi, ratio40;
    uint16_t h_active, v_active;
} it6663_rx_observation_t;

static inline uint16_t it6663_rx_size(const uint8_t *p)
{
    return (uint16_t)(p[0] | ((uint16_t)(p[1] & 0x3F) << 8));
}

/* Equality only: avoid linking the general three-way libc memcmp on the
 * 8 KiB in-system-update image budget. */
static inline bool it6663_rx_equal(const uint8_t *a, const uint8_t *b, unsigned n)
{
    while (n--) {
        if (*a++ != *b++)
            return false;
    }
    return true;
}

static inline it6663_rx_observation_t it6663_rx_observe(const it6663_rx_sample_t *s)
{
    it6663_rx_observation_t o = {0};
    if (!s->read_ok || !s->cable_5v || (s->before[0] & 3) || (s->after[0] & 3)
            || !it6663_rx_equal(s->before, s->after, sizeof(s->before)))
        return o;
    o.locked = (s->before[1] & 0x11) == 0x11
            && (s->before[2] & 0x38) == 0x38 && (s->before[3] & 0x80) != 0;
    if (!o.locked)
        return o;
    o.hdmi = (s->before[2] & 0x40) != 0;
    /* Vendor RX code labels bit 7 as 1/10 vs 1/40. Never infer it from
     * active dimensions, totals or a guessed frame rate. */
    o.ratio40 = (s->before[2] & 0x80) != 0;
    if (!it6663_rx_equal(s->timing, s->timing_after, sizeof(s->timing)))
        return o;
    const uint8_t *t = s->timing;
    uint16_t ht = it6663_rx_size(&t[3]), ha = it6663_rx_size(&t[5]);
    uint16_t vt = it6663_rx_size(&t[10]), va = it6663_rx_size(&t[12]);
    uint16_t hf = (uint16_t)(t[8] | ((uint16_t)(t[9] & 0xF0) << 4));
    uint16_t hs = (uint16_t)(t[7] | ((uint16_t)(t[9] & 1) << 8));
    uint16_t vf = (uint16_t)(t[15] | ((uint16_t)(t[16] & 0xF0) << 4));
    uint16_t vs = (uint16_t)(t[14] | ((uint16_t)(t[16] & 1) << 8));
    if (ha && va && hs && vs && ht >= (uint32_t)ha + hf + hs
            && vt >= (uint32_t)va + vf + vs) {
        o.timing_valid = true;
        /* Raw counter units, no color/deep-color scaling or mode substitution. */
        o.h_active = ha;
        o.v_active = va;
    }
    return o;
}

typedef struct {
    uint8_t absent_polls, stable_polls;
    bool pending_hdmi, pending_ratio40;
} it6663_rx_policy_t;

typedef struct {
    bool power_down, configure;
} it6663_rx_action_t;

static inline it6663_rx_action_t it6663_rx_policy_step(
        it6663_rx_policy_t *p, bool cable_5v, const it6663_rx_observation_t *o)
{
    it6663_rx_action_t a = {0};
    if (!cable_5v) {
        p->stable_polls = 0;
        if (p->absent_polls < 20)
            ++p->absent_polls;
        a.power_down = p->absent_polls >= 20;
        return a;
    }
    p->absent_polls = 0;
    if (!o->timing_valid) {
        /* Report invalid immediately, but leave TX/EQ configuration alone. */
        p->stable_polls = 0;
        return a;
    }
    if (o->hdmi != p->pending_hdmi || o->ratio40 != p->pending_ratio40) {
        p->pending_hdmi = o->hdmi;
        p->pending_ratio40 = o->ratio40;
        p->stable_polls = 0;
    }
    if (p->stable_polls < 25)
        ++p->stable_polls;
    a.configure = p->stable_polls >= 25;
    return a;
}
#endif
