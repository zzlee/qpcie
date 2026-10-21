/* SPDX-License-Identifier: Apache-2.0 */
#include "it6663.h"
#include "it6663_rx_state.h"
#include "it6663_edid.h"
#include "board.h"
#include "i2c.h"
#include <string.h>

/* I2C1 controller execution and per-transaction ownership: i2c1_bus.c. */

int it6663_wr(uint8_t addr, uint8_t offset, uint8_t val)
{
    uint8_t buf[2] = {offset, val};
    return i2c1_write(addr, buf, 2);
}

uint8_t it6663_rd(uint8_t addr, uint8_t offset)
{
    uint8_t val = 0;
    i2c1_transfer(addr, &offset, 1, &val, 1);
    return val;
}

int it6663_set(uint8_t addr, uint8_t offset, uint8_t mask, uint8_t val)
{
    uint8_t cur;
    int rc = i2c1_transfer(addr, &offset, 1, &cur, 1);
    if (rc)
        return rc; /* Never write a read-modify-write value derived from failure. */
    cur = (cur & ~mask) | (val & mask);
    return it6663_wr(addr, offset, cur);
}

static int i2c1_ping(uint8_t addr)
{
    return i2c1_write(addr, NULL, 0);
}

/* Vendor-equivalent IT6663 internal RX HPD control.
 *
 * This is the HPD that the HDMI source sees on the IT6663 RX port. It is NOT
 * the board-level MCU0_HPD / H0_P1TXHPD line driven by board_hdmi_hpd():
 * without these register writes the source never starts TMDS even when the
 * GPIO HPD is high.
 *
 * Sequence copied from IT6664_hdmi2_rx.c:SetRxHpd():
 *   assert:   requires cable 5V, bank3 0xAB=0xCA, bank0 0x26=0x00, 0x55=0xFF
 *   deassert: bank3 0xAB=0x4A then 0x00, 0xAC=0x00,
 *             bank0 0x26=0xFF, 0x55=0x00
 * Bank 0 is always restored, including on partial I2C failure.
 */
int it6663_rx_hpd(bool enable)
{
    uint8_t ab = 0, reg_ab = 0xAB;
    int rc = 0;

    if (enable && !board_hdmi_5v_detected())
        return -1; /* Vendor only asserts RX HPD while cable 5V is present. */

    rc |= it6663_set(IT6663_ADDR_RXP0, 0x0F, 0x03, 0x03); /* Bank 3 */

    if (i2c1_transfer(IT6663_ADDR_RXP0, &reg_ab, 1, &ab, 1) != 0)
        ab = enable ? 0x00 : 0xCA; /* Fail closed: mimic the opposite state. */

    if (enable) {
        if (ab != 0xCA)
            rc |= it6663_wr(IT6663_ADDR_RXP0, 0xAB, 0xCA);
    } else if (ab == 0xCA) {
        rc |= it6663_wr(IT6663_ADDR_RXP0, 0xAB, 0x4A);
        rc |= it6663_wr(IT6663_ADDR_RXP0, 0xAB, 0x00);
        rc |= it6663_wr(IT6663_ADDR_RXP0, 0xAC, 0x00);
    }

    rc |= it6663_set(IT6663_ADDR_RXP0, 0x0F, 0x03, 0x00); /* Bank 0 */
    rc |= it6663_wr(IT6663_ADDR_RXP0, 0x26, enable ? 0x00 : 0xFF);
    rc |= it6663_wr(IT6663_ADDR_RXP0, 0x55, enable ? 0xFF : 0x00);
    return rc;
}

uint8_t g_active_edid[256];

int it6663_update_edid(const uint8_t *edid256)
{
    if (!edid256) return -1;

    if (edid256 != g_active_edid) {
        memcpy(g_active_edid, edid256, 256);
    }

    /* Calculate Block 0 and Block 1 checksums */
    uint8_t sum0 = 0, sum1 = 0;
    for (int i = 0; i < 127; i++) sum0 += edid256[i];
    uint8_t csum0 = (uint8_t)(0 - sum0);

    for (int i = 0; i < 127; i++) sum1 += edid256[128 + i];
    uint8_t csum1 = (uint8_t)(0 - sum1);

    /* 1. Pull HPD LOW (board line and IT6663 internal RX HPD) so the source
     *    stops and re-reads the EDID after the update. */
    board_hdmi_hpd(false);
    it6663_rx_hpd(false);
    board_delay_ms(50);

    /* 2. Enable ERCLK for EDID programming */
    it6663_set(IT6663_ADDR_RXP0, 0x34, 0x01, 0x00);

    /* 3. Enable EDID Slave Address at 0xD8 (7-bit 0x6C) */
    it6663_wr(IT6663_ADDR_RXP0, 0x4B, 0xD9);

    /* 4. Write Block 0 (bytes 0..126) */
    for (uint16_t i = 0; i < 127; i++) {
        it6663_wr(IT6663_ADDR_EDID, (uint8_t)i, edid256[i]);
    }
    it6663_wr(IT6663_ADDR_RXP0, 0xC9, csum0);

    /* 5. Write Block 1 (bytes 128..254) */
    for (uint16_t i = 0; i < 127; i++) {
        it6663_wr(IT6663_ADDR_EDID, (uint8_t)(128 + i), edid256[128 + i]);
    }
    it6663_wr(IT6663_ADDR_RXP0, 0xCA, csum1);

    /* 6. Enable Internal EDID */
    it6663_set(IT6663_ADDR_RXP0, 0xC5, 0x01, 0x00);
    it6663_set(IT6663_ADDR_RXP0, 0x34, 0x01, 0x01);

    /* 7. Re-assert HPD: board line first, then the IT6663 internal RX HPD
     *    (vendor order). Gated on 5V inside it6663_rx_hpd(). */
    board_delay_ms(50);
    board_hdmi_hpd(true);
    it6663_rx_hpd(true);

    return 0;
}

int it6663_probe(it6663_info_t *info)
{
    memset(info, 0, sizeof(*info));

    /* 1. Full bus scan on I2C1 (0x08..0x77) */
    for (uint8_t a = 0x08; a <= 0x77; a++) {
        if (i2c1_ping(a) == 0) {
            if (info->num_slaves < 16) {
                info->slaves[info->num_slaves++] = a;
            }
        }
    }

    /* 2. Check IT6663 at 0x2C */
    uint8_t bank0[2] = {0x0F, 0x00};
    if (i2c1_write(IT6663_ADDR_SW, bank0, 2) == 0) {
        uint8_t reg = 0x00;
        uint8_t buf[5] = {0};
        if (i2c1_transfer(IT6663_ADDR_SW, &reg, 1, buf, 5) == 0) {
            info->it6663_present = true;
            info->it6663_addr = IT6663_ADDR_SW;
            info->ven_id[0] = buf[0];
            info->ven_id[1] = buf[1];
            info->dev_id[0] = buf[2];
            info->dev_id[1] = buf[3];
            info->rev_id = buf[4];
        }
    }

    /* 3. Check NCT7717 at 0x48 */
    uint8_t reg = 0x00;
    uint8_t temp = 0;
    if (i2c1_transfer(NCT7717_I2C_ADDR, &reg, 1, &temp, 1) == 0) {
        info->nct7717_present = true;
        info->temperature = temp;
    }

    info->hdmi_5v = board_hdmi_5v_detected();

    return info->it6663_present ? 0 : -1;
}

void it6663_tx_vclk_reset(uint8_t tx_addr)
{
    it6663_wr(tx_addr, 0x01, 0x06);
    it6663_set(tx_addr, 0x94, 0x01, 0x01);
    it6663_set(tx_addr, 0x94, 0x01, 0x00);
    it6663_wr(tx_addr, 0x01, 0x04);
    it6663_wr(tx_addr, 0x01, 0x00);
}

void it6663_tx_power_down(uint8_t tx_addr)
{
    it6663_set(tx_addr, 0x84, 0x60, 0x60);
    it6663_set(tx_addr, 0x86, 0x08, 0x00);
    it6663_set(tx_addr, 0x88, 0x03, 0x03); /* DRV_RST=1, pwd=1 */
    it6663_set(tx_addr, 0x01, 0x26, 0x26);
    it6663_set(tx_addr, 0xC1, 0x01, 0x01); /* AVMUTE = 1 */
}

void it6663_tx_scdc_write(uint8_t tx_addr, uint8_t offset, uint8_t val)
{
    it6663_set(tx_addr, 0x28, 0x01, 0x01); /* Enable DDC Master */
    it6663_wr(tx_addr,  0x2E, 0x09);       /* Clear FIFO */
    it6663_wr(tx_addr,  0x29, 0xA8);       /* SCDC Slave Address */
    it6663_wr(tx_addr,  0x2A, offset);     /* SCDC Offset (0x20) */
    it6663_wr(tx_addr,  0x2B, 0x01);       /* Length: 1 byte */
    it6663_set(tx_addr, 0x2C, 0x03, 0x00);
    it6663_wr(tx_addr,  0x30, val);        /* Data */
    it6663_wr(tx_addr,  0x2E, 0x01);       /* Trigger DDC Write */
    board_delay_ms(10);
    it6663_set(tx_addr, 0x28, 0x01, 0x00);
}

void it6663_tx_setup(uint8_t tx_addr, bool is_hdmi, bool is_hdmi20)
{
    /* 1. Un-gate reference clock and power on basic TX blocks */
    it6663_set(tx_addr, 0x02, 0x01, 0x00); /* RegGateRCLK = 0 */
    it6663_set(tx_addr, 0xC1, 0xF0, 0x80); /* TX Output Power On */
    it6663_set(tx_addr, 0x84, 0xE0, 0x80); /* TX AFE Power On */
    it6663_set(tx_addr, 0x86, 0x08, 0x08); /* TX Clock AFE Power On */
    it6663_set(tx_addr, 0x19, 0x07, 0x07);

    /* 2. HDMI mode */
    if (tx_addr == IT6663_ADDR_TXP1) {
        it6663_set(tx_addr, 0xC0, 0x01, 0x01); /* Always HDMI mode for FPGA */
    } else {
        it6663_set(tx_addr, 0xC0, 0x01, is_hdmi ? 0x01 : 0x00);
    }

    /* 3. AFE electrical configuration */
    if (is_hdmi20) {
        /* 4K60 / HDMI 2.0 (5.94 Gbps, TMDS clock 148.5 MHz) */
        it6663_set(tx_addr, 0x84, 0x07, 0x04);
        it6663_set(tx_addr, 0x88, 0x04, 0x04);
        it6663_set(tx_addr, 0x87, 0x1F, 0x0E);        /* DRV_ISW = 0x0E */
        it6663_set(tx_addr, 0x89, 0xBF, 0x25);        /* DRV_TERMON=1, DRV_RTERM=0x5 */
        it6663_set(tx_addr, 0x8A, 0x0F, 0x00);        /* DRV_TPRE = 0 */
        it6663_set(tx_addr, 0x8B, 0x0F, 0x0D);        /* DRV_ISW_C = 0x0D */
    } else {
        /* HDMI 1.4 / 1080p60 / 4K30 */
        it6663_set(tx_addr, 0x84, 0x07, 0x04);
        it6663_set(tx_addr, 0x88, 0x04, 0x00);
        it6663_set(tx_addr, 0x87, 0x1F, 0x09);        /* DRV_ISW = 0x09 */
        it6663_set(tx_addr, 0x89, 0xBF, 0x21);        /* DRV_TERMON=1, DRV_RTERM=0x1 */
        it6663_set(tx_addr, 0x8A, 0x0F, 0x00);        /* DRV_TPRE = 0 */
        it6663_set(tx_addr, 0x8B, 0x0F, 0x09);        /* DRV_ISW_C = 0x09 */
    }

    /* 4. Reset VCLK */
    it6663_tx_vclk_reset(tx_addr);

    /* 5. HDMI 2.0 vs 1.4 clock ratio, scrambling & SCDC sink config */
    if (is_hdmi20) {
        it6663_set(tx_addr, 0x83, 0x08, 0x08); /* HDMI2ONPLL = 1 (1/40 TMDS clock) */
        it6663_set(tx_addr, 0xC0, 0x46, 0x46); /* H2ClkRatio=1, EnH2Scr=1, EnH2Enc=1 */
        it6663_tx_scdc_write(tx_addr, 0x20, 0x03); /* Tell Sink: 1/40 clock + Scrambler */
    } else {
        it6663_set(tx_addr, 0x83, 0x08, 0x00); /* 1/10 TMDS clock */
        it6663_set(tx_addr, 0xC0, 0x46, 0x00);
        it6663_tx_scdc_write(tx_addr, 0x20, 0x00);
    }

    /* 6. Enable Output Drivers */
    it6663_set(tx_addr, 0x18, 0x0C, 0x0C);
    it6663_wr(tx_addr,  0x85, 0x19);
    it6663_set(tx_addr, 0x1A, 0x0B, 0x0B);

    it6663_set(tx_addr, 0xC1, 0x08, 0x00);
    it6663_set(tx_addr, 0xC1, 0x08, 0x08);
    it6663_set(tx_addr, 0xC2, 0x80, 0x00); /* Clear force-mute */
    it6663_set(tx_addr, 0xC3, 0x30, 0x30); /* Enable GenCtrl Packet */
    it6663_set(tx_addr, 0x91, 0x10, 0x00); /* Disable black screen */

    /* Release Driver Reset and Power-down */
    it6663_set(tx_addr, 0x88, 0x03, 0x00); /* Set DRV_RST='0' and pwd='0' */

    /* 7. Verify stability and clear AVMUTE */
    board_delay_ms(150);
    uint8_t rddata = it6663_rd(tx_addr, 0x03);
    if ((rddata & 0x08) == 0) {
        it6663_tx_vclk_reset(tx_addr);
        it6663_set(tx_addr, 0xC1, 0xF0, 0x80);
        board_delay_ms(100);
    }
    it6663_set(tx_addr, 0xC1, 0x01, 0x00); /* Clear AVMUTE */
    it6663_wr(tx_addr,  0x12, 0xFF);        /* Clear pending TX interrupts */
}

static bool s_tx1_configured = false;
static bool s_tx1_is_hdmi20 = false;
static bool s_tx2_configured = false;
static bool s_tx2_is_hdmi20 = false;
static bool s_tx2_hdmi_mode = false;
static bool s_hpd_5v = false;
static it6663_rx_policy_t s_rx_policy;

static int it6663_read_rx_status(uint8_t status[4])
{
    static const uint8_t offsets[] = {0x0F, 0x13, 0x14, 0x19};
    for (unsigned i = 0; i < sizeof(offsets); ++i) {
        if (i2c1_transfer(IT6663_ADDR_RXP0, &offsets[i], 1, &status[i], 1) != 0)
            return -1;
    }
    return 0;
}

void it6663_poll_status(it6663_info_t *info)
{
    it6663_rx_sample_t sample;
    /* The decoder never reads bytes unless all transactions completed. */
    sample.read_ok = false;
    sample.cable_5v = board_hdmi_5v_detected();
    info->hdmi_5v = sample.cable_5v;

    /* Plug/unplug edge: mirror vendor SetRxHpd() so the source restarts TMDS
     * (assert) or sees HPD fall (deassert). Steady state is left untouched. */
    if (info->it6663_present && sample.cable_5v != s_hpd_5v) {
        it6663_rx_hpd(sample.cable_5v);
        s_hpd_5v = sample.cable_5v;
    }

    if (info->it6663_present && sample.cable_5v) {
        uint8_t reg = 0x98;
        sample.read_ok = it6663_read_rx_status(sample.before) == 0
            && i2c1_transfer(IT6663_ADDR_RXP0, &reg, 1, sample.timing, sizeof(sample.timing)) == 0
            && i2c1_transfer(IT6663_ADDR_RXP0, &reg, 1, sample.timing_after, sizeof(sample.timing_after)) == 0
            && it6663_read_rx_status(sample.after) == 0;
    }
    it6663_rx_observation_t observed = it6663_rx_observe(&sample);

    /* Observation is never derived from retained TX state or stale dimensions. */
    info->clock_locked = observed.locked;
    info->hdmi_mode = observed.hdmi;
    info->h_active = observed.h_active;
    info->v_active = observed.v_active;
    /* pixel_clk_mhz stays at its init value 0: not measured here. */

    it6663_rx_action_t action = it6663_rx_policy_step(&s_rx_policy, sample.cable_5v, &observed);
    if (action.power_down) {
        if (s_tx1_configured) {
            it6663_tx_power_down(IT6663_ADDR_TXP1);
            s_tx1_configured = false;
        }
        if (s_tx2_configured) {
            it6663_tx_power_down(IT6663_ADDR_TXP2);
            s_tx2_configured = false;
        }
    } else if (action.configure) {
        /* Keep the existing TX setup sequence. Only checked RX mode bits with
         * 25 consecutive valid observations can enter it. No polling EQ writes
         * or CDR kicks: boot EQ remains unchanged during invalid observations. */
        if (!s_tx1_configured || observed.ratio40 != s_tx1_is_hdmi20) {
            it6663_tx_setup(IT6663_ADDR_TXP1, true, observed.ratio40);
            s_tx1_configured = true;
            s_tx1_is_hdmi20 = observed.ratio40;
        }
        uint8_t reg = 0x03, tx2_sts = 0;
        if (i2c1_transfer(IT6663_ADDR_TXP2, &reg, 1, &tx2_sts, 1) == 0) {
            if (tx2_sts & 0x01) { /* Existing loopout detection policy. */
                if (!s_tx2_configured || observed.ratio40 != s_tx2_is_hdmi20
                        || observed.hdmi != s_tx2_hdmi_mode) {
                    it6663_tx_setup(IT6663_ADDR_TXP2, observed.hdmi, observed.ratio40);
                    s_tx2_configured = true;
                    s_tx2_is_hdmi20 = observed.ratio40;
                    s_tx2_hdmi_mode = observed.hdmi;
                }
            } else if (s_tx2_configured) {
                it6663_tx_power_down(IT6663_ADDR_TXP2);
                s_tx2_configured = false;
            }
        }
    }

    if (info->it6663_present) {
        uint8_t temp = 0, reg = 0;
        if (i2c1_transfer(NCT7717_I2C_ADDR, &reg, 1, &temp, 1) == 0)
            info->temperature = temp;
    }
}

void it6663_init(it6663_info_t *info)
{
    s_tx1_configured = false;
    s_tx2_configured = false;
    s_hpd_5v = false;
    memset(&s_rx_policy, 0, sizeof(s_rx_policy));
    info->clock_locked = false;
    info->hdmi_mode = false;
    info->h_active = info->v_active = info->pixel_clk_mhz = 0;

    I2C_Open(I2C1, 100000);

    /* 1. Initial probe */
    if (it6663_probe(info) != 0) {
        return;
    }

    /* 2. Switch to Bank 0 */
    it6663_wr(IT6663_ADDR_SW, 0x0F, 0x00);

    /* 3. Soft reset H2SP & SIPROM (Yuan sequence) */
    it6663_wr(IT6663_ADDR_SW, 0x0A, 0x01);
    board_delay_ms(5);
    it6663_wr(IT6663_ADDR_SW, 0x0A, 0x00);
    it6663_wr(IT6663_ADDR_SW, 0xFF, 0xC3);
    it6663_wr(IT6663_ADDR_SW, 0xFF, 0xA5);
    it6663_wr(IT6663_ADDR_SW, 0x5F, 0x04);
    it6663_wr(IT6663_ADDR_SW, 0x58, 0x12);
    it6663_wr(IT6663_ADDR_SW, 0x58, 0x02);
    it6663_wr(IT6663_ADDR_SW, 0x5F, 0x00);
    it6663_wr(IT6663_ADDR_SW, 0xFF, 0xFF);
    it6663_wr(IT6663_ADDR_SW, 0x10, 0x6E); /* Increase ring osc frequency */

    /* 4. Enable I2C Sub-Device Slave Addresses */
    it6663_wr(IT6663_ADDR_SW, 0xF0, 0x71); /* Enable RXP0 @ 0x70 (7-bit 0x38) */
    it6663_wr(IT6663_ADDR_SW, 0xF1, 0x97); /* Enable TXCom @ 0x96 (7-bit 0x4B) */
    it6663_set(IT6663_ADDR_SW, 0x08, 0x0F, 0x0F); /* Enable all 4 ports */
    it6663_wr(IT6663_ADDR_SW, 0x0D, 0x00);        /* Select original RX source for all TX ports */

    it6663_set(IT6663_ADDR_TXCOM, 0x50, 0x04, 0x00);
    it6663_wr(IT6663_ADDR_TXCOM, 0x2C, 0x69); /* TXP0 @ 0x68 (0x34) */
    it6663_wr(IT6663_ADDR_TXCOM, 0x2D, 0x6B); /* TXP1 @ 0x6A (0x35) -> FPGA */
    it6663_wr(IT6663_ADDR_TXCOM, 0x2E, 0x6D); /* TXP2 @ 0x6C (0x36) -> Loopout */
    it6663_wr(IT6663_ADDR_TXCOM, 0x2F, 0x6F); /* TXP3 @ 0x6E (0x37) */

    /* 5. Reset & Initialize RX Core */
    it6663_wr(IT6663_ADDR_RXP0, 0x22, 0x08);
    it6663_wr(IT6663_ADDR_RXP0, 0x23, 0x01);
    it6663_wr(IT6663_ADDR_RXP0, 0x22, 0x17);
    board_delay_ms(10);
    it6663_wr(IT6663_ADDR_RXP0, 0x23, 0xA0);
    it6663_wr(IT6663_ADDR_RXP0, 0x22, 0x00);

    /* 6. Configure TMDS termination, AutoEQ, and FPGA frequency thresholds */
    it6663_wr(IT6663_ADDR_RXP0, 0x56, 0xFF);
    it6663_wr(IT6663_ADDR_RXP0, 0x57, 0xFF);

    it6663_set(IT6663_ADDR_RXP0, 0x0F, 0x03, 0x03); /* Switch to Bank 3 */
    it6663_set(IT6663_ADDR_RXP0, 0xA8, 0x08, 0x08);
    it6663_set(IT6663_ADDR_RXP0, 0xA7, 0x40, 0x40);
    it6663_set(IT6663_ADDR_RXP0, 0x26, 0x20, 0x00);
    it6663_set(IT6663_ADDR_RXP0, 0x27, 0xFF, 0x87); /* IT6663 EQ channel 0: 4K60 standard */
    it6663_set(IT6663_ADDR_RXP0, 0x28, 0xFF, 0x87); /* IT6663 EQ channel 1: 4K60 standard */
    it6663_set(IT6663_ADDR_RXP0, 0x29, 0xFF, 0x87); /* IT6663 EQ channel 2: 4K60 standard */
    it6663_set(IT6663_ADDR_RXP0, 0xE3, 0x01, 0x01);
    it6663_set(IT6663_ADDR_RXP0, 0xE3, 0x06, 0x03);
    it6663_wr(IT6663_ADDR_RXP0,  0xF0, 0xA0);
    it6663_set(IT6663_ADDR_RXP0, 0x0F, 0x03, 0x00); /* Switch back to Bank 0 */

    it6663_set(IT6663_ADDR_RXP0, 0x28, 0x88, 0x88);
    it6663_set(IT6663_ADDR_RXP0, 0x3B, 0x20, 0x20); /* Enable cedopt */
    it6663_wr(IT6663_ADDR_RXP0,  0x26, 0xFF);
    it6663_set(IT6663_ADDR_RXP0, 0x2A, 0x01, 0x01);
    it6663_set(IT6663_ADDR_RXP0, 0x43, 0x02, 0x00);
    it6663_set(IT6663_ADDR_RXP0, 0x44, 0x3F, 0x19);
    it6663_wr(IT6663_ADDR_RXP0, 0x45, 0xDF); /* Modify lowest for FPGA freq */
    it6663_set(IT6663_ADDR_RXP0, 0x46, 0x3F, 0x15);
    it6663_set(IT6663_ADDR_RXP0, 0x47, 0xFF, 0x88);
    it6663_wr(IT6663_ADDR_RXP0, 0x23, 0xA0);
    it6663_wr(IT6663_ADDR_RXP0, 0x53, 0x0F); /* Interrupt on 5V and RXCLK */

    /* 7. Load Default 4K HDR EDID into IT6663 EDID RAM */
    it6663_update_edid(g_default_edid_4k);

    /* 8. Initialize TX Port 1 (P1TX to FPGA GTH) and Port 2 (Loopout) */
    uint8_t tx_ports[2] = {IT6663_ADDR_TXP1, IT6663_ADDR_TXP2};
    for (int i = 0; i < 2; i++) {
        uint8_t a = tx_ports[i];
        it6663_set(a, 0x08, 0x1C, 0x14); /* Force TMDS Stb & ROn */
        it6663_set(a, 0x02, 0x02, 0x02);
        it6663_set(a, 0xC0, 0x01, 0x01); /* Default HDMI mode */
        it6663_set(a, 0x18, 0x03, 0x03); /* Enable HPD & RxSen */
        it6663_wr(a,  0x88, 0x54);
        it6663_wr(a,  0x8A, 0x00);
        it6663_wr(a,  0x8B, 0x07);
        it6663_set(a, 0xC1, 0x01, 0x00); /* Clear AVMUTE */
    }

    /* 9. Refresh active slaves list */
    info->num_slaves = 0;
    for (uint8_t a = 0x08; a <= 0x77; a++) {
        if (i2c1_ping(a) == 0) {
            if (info->num_slaves < 16) {
                info->slaves[info->num_slaves++] = a;
            }
        }
    }

    /* Record the 5V state that init-time HPD handling already applied, so the
     * poll loop only reacts to real plug/unplug edges. */
    s_hpd_5v = board_hdmi_5v_detected();
}
