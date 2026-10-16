/* SPDX-License-Identifier: Apache-2.0 */
#include "it6663.h"
#include "it6663_edid.h"
#include "board.h"
#include "i2c.h"
#include <string.h>

#define I2C1_TIMEOUT_CYCLES  30000UL

static int i2c1_wait_si(void)
{
    uint32_t to = I2C1_TIMEOUT_CYCLES;
    while (!(I2C1->CTL & I2C_CTL_SI)) {
        if (--to == 0) {
            I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
            return -1;
        }
    }
    return 0;
}

int i2c1_write(uint8_t addr, const uint8_t *data, uint32_t len)
{
    /* 1. Send START */
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STA_SI);
    if (i2c1_wait_si() != 0) return -1;
    if (I2C1->STATUS != 0x08 && I2C1->STATUS != 0x10) {
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
        return -2;
    }

    /* 2. Send SLA+W */
    I2C1->DAT = (addr << 1) | 0;
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
    if (i2c1_wait_si() != 0) return -3;
    if (I2C1->STATUS != 0x18) { /* NACK */
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
        return -4;
    }

    /* 3. Send Data Bytes */
    for (uint32_t i = 0; i < len; i++) {
        I2C1->DAT = data[i];
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
        if (i2c1_wait_si() != 0) return -5;
        if (I2C1->STATUS != 0x28) {
            I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
            return -6;
        }
    }

    /* 4. Send STOP */
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
    return 0;
}

int i2c1_read(uint8_t addr, uint8_t *data, uint32_t len)
{
    if (len == 0) return 0;
    memset(data, 0xFF, len);

    /* 1. Send START */
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STA_SI);
    if (i2c1_wait_si() != 0) return -1;
    if (I2C1->STATUS != 0x08 && I2C1->STATUS != 0x10) {
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
        return -2;
    }

    /* 2. Send SLA+R */
    I2C1->DAT = (addr << 1) | 1;
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
    if (i2c1_wait_si() != 0) return -3;
    if (I2C1->STATUS != 0x40) {
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
        return -4;
    }

    /* 3. Receive Data Bytes */
    for (uint32_t i = 0; i < len; i++) {
        if (i == len - 1) {
            I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
        } else {
            I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI_AA);
        }
        if (i2c1_wait_si() != 0) return -5;
        data[i] = (uint8_t)I2C1->DAT;
    }

    /* 4. Send STOP */
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
    return 0;
}

int i2c1_transfer(uint8_t addr, const uint8_t *tx, uint32_t txlen, uint8_t *rx, uint32_t rxlen)
{
    if (rxlen > 0) {
        memset(rx, 0xFF, rxlen);
    }

    if (txlen > 0) {
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STA_SI);
        if (i2c1_wait_si() != 0) return -1;

        I2C1->DAT = (addr << 1) | 0;
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
        if (i2c1_wait_si() != 0) return -2;
        if (I2C1->STATUS != 0x18) {
            I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
            return -3;
        }

        for (uint32_t i = 0; i < txlen; i++) {
            I2C1->DAT = tx[i];
            I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
            if (i2c1_wait_si() != 0) return -4;
            if (I2C1->STATUS != 0x28) {
                I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
                return -5;
            }
        }
    }

    if (rxlen > 0) {
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STA_SI);
        if (i2c1_wait_si() != 0) return -6;

        I2C1->DAT = (addr << 1) | 1;
        I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
        if (i2c1_wait_si() != 0) return -7;
        if (I2C1->STATUS != 0x40) {
            I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
            return -8;
        }

        for (uint32_t i = 0; i < rxlen; i++) {
            if (i == rxlen - 1) {
                I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
            } else {
                I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI_AA);
            }
            if (i2c1_wait_si() != 0) return -9;
            rx[i] = (uint8_t)I2C1->DAT;
        }
    }

    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
    return 0;
}

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
    uint8_t cur = it6663_rd(addr, offset);
    cur = (cur & ~mask) | (val & mask);
    return it6663_wr(addr, offset, cur);
}

static int i2c1_ping(uint8_t addr)
{
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STA_SI);
    if (i2c1_wait_si() != 0) return -1;
    I2C1->DAT = (addr << 1) | 0;
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_SI);
    if (i2c1_wait_si() != 0) return -2;
    int ack = (I2C1->STATUS == 0x18);
    I2C_SET_CONTROL_REG(I2C1, I2C_CTL_STO_SI);
    return ack ? 0 : -3;
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

    /* 1. Temporarily pull HPD LOW to signal source that EDID is updating */
    board_hdmi_hpd(false);
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

    /* 7. Re-assert HPD */
    board_delay_ms(50);
    board_hdmi_hpd(true);

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

void it6663_poll_status(it6663_info_t *info)
{
    info->hdmi_5v = board_hdmi_5v_detected();

    if (info->it6663_present) {
        uint8_t rx14 = it6663_rd(IT6663_ADDR_RXP0, 0x14);
        info->clock_locked = (rx14 & 0x10) != 0;  /* SCDT clock detect */
        info->hdmi_mode = (rx14 & 0x40) != 0;     /* 1: HDMI, 0: DVI */

        if (info->clock_locked) {
            uint8_t h_l = it6663_rd(IT6663_ADDR_RXP0, 0x9D);
            uint8_t h_h = it6663_rd(IT6663_ADDR_RXP0, 0x9E) & 0x3F;
            info->h_active = (uint16_t)((h_h << 8) | h_l);

            uint8_t v_l = it6663_rd(IT6663_ADDR_RXP0, 0xA4);
            uint8_t v_h = it6663_rd(IT6663_ADDR_RXP0, 0xA5) & 0x3F;
            info->v_active = (uint16_t)((v_h << 8) | v_l);
        } else {
            info->h_active = 0;
            info->v_active = 0;
        }

        /* Check temperature */
        uint8_t temp = 0;
        uint8_t reg = 0x00;
        if (i2c1_transfer(NCT7717_I2C_ADDR, &reg, 1, &temp, 1) == 0) {
            info->temperature = temp;
        }
    }
}

void it6663_init(it6663_info_t *info)
{
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
    it6663_set(IT6663_ADDR_RXP0, 0x27, 0xFF, 0x9F); /* IT6663 EQ channel 0 */
    it6663_set(IT6663_ADDR_RXP0, 0x28, 0xFF, 0x9F); /* IT6663 EQ channel 1 */
    it6663_set(IT6663_ADDR_RXP0, 0x29, 0xFF, 0x9F); /* IT6663 EQ channel 2 */
    it6663_set(IT6663_ADDR_RXP0, 0x0F, 0x03, 0x00); /* Switch back to Bank 0 */

    it6663_set(IT6663_ADDR_RXP0, 0x28, 0x59, 0x59);
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

    /* 8. Initialize TX Port 1 (P1TX to FPGA GTH) */
    it6663_set(IT6663_ADDR_TXP1, 0x08, 0x1C, 0x14); /* Force TMDS Stb & ROn */
    it6663_set(IT6663_ADDR_TXP1, 0x02, 0x02, 0x02);
    it6663_set(IT6663_ADDR_TXP1, 0xC0, 0x01, 0x01); /* Default HDMI mode */
    it6663_set(IT6663_ADDR_TXP1, 0x18, 0x03, 0x03); /* Enable HPD & RxSen */
    it6663_wr(IT6663_ADDR_TXP1, 0x88, 0x54);
    it6663_wr(IT6663_ADDR_TXP1, 0x8A, 0x00);
    it6663_wr(IT6663_ADDR_TXP1, 0x8B, 0x07);
    it6663_set(IT6663_ADDR_TXP1, 0xC1, 0x01, 0x00); /* Clear AVMUTE */

    /* 9. Refresh active slaves list */
    info->num_slaves = 0;
    for (uint8_t a = 0x08; a <= 0x77; a++) {
        if (i2c1_ping(a) == 0) {
            if (info->num_slaves < 16) {
                info->slaves[info->num_slaves++] = a;
            }
        }
    }
}
