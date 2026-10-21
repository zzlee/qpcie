/* SPDX-License-Identifier: Apache-2.0 */
#include "i2c0_slave.h"
#include "i2c_proxy_response.h"
#include "board.h"
#include "it6663.h"
#include "writer.h"
#include "i2c.h"
#include <string.h>

volatile i2c0_state_t g_i2c0;
volatile bool         g_upg_flash_pending = false;
volatile uint16_t     g_upg_flash_len = 0;

#define UPG_STAGE_ADDR   0x20001000UL
#define UPG_STAGE_MAX    8192U

static uint8_t  s_active_addr = 0;
static uint8_t  s_reg_ptr = 0;
static uint16_t s_edid_ptr = 0;
static uint8_t  s_rx_buf[64];
static uint8_t  s_rx_len = 0;

static struct {
    uint8_t  state;        /* 0: IDLE, 1: RX, 2: READY, 3: FLASH, 4: DONE, 5: ERROR */
    uint16_t total_len;
    uint32_t expected_crc;
    uint16_t rx_bytes;
    uint8_t  err;
    uint8_t  resp[8];
    uint8_t  resp_len;
    uint8_t  resp_idx;
} s_upg;

static uint32_t calc_crc32(const uint8_t *data, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFU;
    for (uint32_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            crc = (crc >> 1) ^ (0xEDB88320U & (-(crc & 1U)));
        }
    }
    return ~crc;
}

static uint8_t calc_crc8(const uint8_t *data, uint32_t len)
{
    uint8_t crc = 0x00;
    for (uint32_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

void i2c0_update_status(it6663_info_t *info)
{
    uint8_t st = board_get_status_byte();
    if (info->it6663_present) st |= (1 << 4);
    if (info->nct7717_present) st |= (1 << 5);
    if (info->clock_locked)   st |= (1 << 6);
    if (info->hdmi_mode)      st |= (1 << 7);
    g_i2c0.regs[0x04] = st;

    g_i2c0.regs[0x07] = info->rev_id;
    g_i2c0.regs[0x08] = info->ven_id[0];
    g_i2c0.regs[0x09] = info->ven_id[1];
    g_i2c0.regs[0x0A] = info->dev_id[0];
    g_i2c0.regs[0x0B] = info->dev_id[1];
    g_i2c0.regs[0x0C] = info->temperature;
    g_i2c0.regs[0x0D] = info->it6663_addr;

    /* Resolution telemetry */
    g_i2c0.regs[0x0E] = (uint8_t)(info->h_active & 0xFF);
    g_i2c0.regs[0x0F] = (uint8_t)(info->h_active >> 8);

    /* Populate detected slaves list at 0x10..0x1F */
    g_i2c0.regs[0x10] = info->num_slaves;
    for (uint8_t i = 0; i < 15; i++) {
        g_i2c0.regs[0x11 + i] = (i < info->num_slaves) ? info->slaves[i] : 0x00;
    }

    g_i2c0.regs[0x20] = (uint8_t)(info->v_active & 0xFF);
    g_i2c0.regs[0x21] = (uint8_t)(info->v_active >> 8);
}

static void handle_upg_cmd(const uint8_t *cmd, uint8_t len)
{
    if (len == 0) return;
    uint8_t opcode = cmd[0];
    s_upg.resp_len = 1;
    s_upg.resp_idx = 0;
    s_upg.resp[0] = 0;

    switch (opcode) {
    case 0x01: /* HELLO */
        s_upg.resp[0] = 0x01;
        s_upg.resp[1] = 0x00;
        s_upg.resp[2] = 0x02;
        s_upg.resp[3] = 32;
        s_upg.resp_len = 4;
        break;

    case 0x02: /* BEGIN: [LEN_L, LEN_H, CRC0..3] */
        if (len >= 7) {
            uint16_t l = cmd[1] | (cmd[2] << 8);
            uint32_t c = cmd[3] | (cmd[4] << 8) | (cmd[5] << 16) | (cmd[6] << 24);
            if (l > UPG_STAGE_MAX || (l & 3) != 0) {
                s_upg.resp[0] = 1;
                s_upg.state = 5;
            } else {
                s_upg.total_len = l;
                s_upg.expected_crc = c;
                s_upg.rx_bytes = 0;
                s_upg.state = 1;
                s_upg.err = 0;
                s_upg.resp[0] = 0;
            }
        } else {
            s_upg.resp[0] = 4;
        }
        break;

    case 0x03: /* CHUNK: [OFF_L, OFF_H, N, DATA... CRC8] */
        if (len >= 5) {
            uint16_t off = cmd[1] | (cmd[2] << 8);
            uint8_t n = cmd[3];
            if (len >= 4 + n + 1) {
                uint8_t crc = calc_crc8(&cmd[1], 3 + n);
                if (crc != cmd[4 + n]) {
                    s_upg.resp[0] = 3;
                } else if (off + n > s_upg.total_len) {
                    s_upg.resp[0] = 5;
                } else {
                    uint8_t *dst = (uint8_t *)(UPG_STAGE_ADDR + off);
                    memcpy(dst, &cmd[4], n);
                    s_upg.rx_bytes += n;
                    s_upg.resp[0] = 0;
                }
            } else {
                s_upg.resp[0] = 4;
            }
        }
        break;

    case 0x04: /* COMMIT */
        if (s_upg.rx_bytes == s_upg.total_len && s_upg.total_len > 0) {
            uint32_t actual_crc = calc_crc32((const uint8_t *)UPG_STAGE_ADDR, s_upg.total_len);
            if (actual_crc != s_upg.expected_crc) {
                s_upg.resp[0] = 3;
                s_upg.state = 5;
            } else {
                s_upg.state = 3; /* FLASH */
                s_upg.resp[0] = 0;
                g_upg_flash_len = s_upg.total_len;
                g_upg_flash_pending = true;
            }
        } else {
            s_upg.resp[0] = 4;
        }
        break;

    case 0x05: /* ABORT */
        s_upg.state = 0;
        s_upg.resp[0] = 0;
        break;

    case 0x06: /* PROGRESS */
        s_upg.resp[0] = s_upg.state;
        s_upg.resp[1] = (uint8_t)(s_upg.rx_bytes & 0xFF);
        s_upg.resp[2] = (uint8_t)(s_upg.rx_bytes >> 8);
        s_upg.resp[3] = s_upg.err;
        s_upg.resp_len = 4;
        break;

    case 0x10: /* EDID_CHUNK: [0x10, off, n, data... crc8] */
        if (len >= 4) {
            uint8_t off = cmd[1];
            uint8_t n = cmd[2];
            if (len >= 3 + n + 1) {
                uint8_t crc = calc_crc8(&cmd[1], 2 + n);
                if (crc != cmd[3 + n]) {
                    s_upg.resp[0] = 3; /* CRC error */
                } else if ((uint16_t)off + n > 256) {
                    s_upg.resp[0] = 5; /* Overflow */
                } else {
                    memcpy(&g_active_edid[off], &cmd[3], n);
                    s_upg.resp[0] = 0; /* OK */
                }
            } else {
                s_upg.resp[0] = 4; /* Bad len */
            }
        }
        break;

    case 0x11: /* EDID_APPLY: [0x11] */
        {
            int rc = it6663_update_edid(g_active_edid);
            s_upg.resp[0] = (rc == 0) ? 0 : 1;
        }
        break;

    case 0x12: /* EDID_READ: [0x12, off, n] */
        if (len >= 3) {
            uint8_t off = cmd[1];
            uint8_t n = cmd[2];
            if (n > 32) n = 32;
            if ((uint16_t)off + n > 256) n = (uint8_t)(256 - off);
            memcpy(s_upg.resp, &g_active_edid[off], n);
            s_upg.resp_len = n;
        } else {
            s_upg.resp[0] = 4;
        }
        break;

    default:
        s_upg.resp[0] = 4;
        break;
    }
}

static void handle_rx_complete(void)
{
    if (s_rx_len == 0) return;

    if (s_active_addr == (I2C_ADDR_REG << 1)) {
        uint8_t idx = s_rx_buf[0];
        for (uint8_t i = 1; i < s_rx_len; i++) {
            if (idx < REG_FILE_SIZE) {
                g_i2c0.regs[idx] = s_rx_buf[i];
                if (idx == 0x06) {
                    if (s_rx_buf[i] == 0x01) {
                        g_i2c0.reboot_requested = true;
                    } else if (s_rx_buf[i] == 0x02) {
                        g_i2c0.edid_update_requested = true;
                    }
                }
                idx++;
            }
        }
    } else if (s_active_addr == (I2C_ADDR_PROXY << 1)) {
        uint8_t raw_tgt = s_rx_buf[0];
        uint8_t target_7b = raw_tgt >> 1;
        int rc = -4;
        g_i2c0.proxy_rx_len = 0;
        g_i2c0.proxy_rx_idx = 0;
        if (!(raw_tgt & 1)) {
            if (s_rx_len > 1)
                rc = i2c1_write(target_7b, &s_rx_buf[1], s_rx_len - 1);
        } else if (s_rx_len >= 2 && s_rx_buf[1]
                   && s_rx_buf[1] <= sizeof(g_i2c0.proxy_rx_buf)) {
            uint8_t len = s_rx_buf[1];
            rc = i2c1_transfer(target_7b, &s_rx_buf[2], s_rx_len - 2,
                               (uint8_t *)g_i2c0.proxy_rx_buf, len);
            g_i2c0.proxy_rx_len = len;
        }
        g_i2c0.proxy_status = (uint8_t)-rc;
    } else if (s_active_addr == (I2C_ADDR_UPG << 1)) {
        handle_upg_cmd(s_rx_buf, s_rx_len);
    } else if (s_active_addr == (I2C_ADDR_EDID << 1)) {
        uint16_t off = s_rx_buf[0];
        for (uint8_t i = 1; i < s_rx_len; i++) {
            if (off < 256) {
                g_active_edid[off++] = s_rx_buf[i];
            }
        }
    }

    s_rx_len = 0;
}

void I2C0_IRQHandler(void)
{
    uint32_t status = I2C0->STATUS;

    if (I2C0->TOCTL & I2C_TOCTL_TOIF_Msk) {
        I2C0->TOCTL |= I2C_TOCTL_TOIF_Msk;
        s_rx_len = 0;
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
        return;
    }

    if (status == 0x60 || status == 0x68) {
        s_active_addr = (uint8_t)(I2C0->DAT & 0xFE);
        s_rx_len = 0;
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
    } else if (status == 0x80) {
        uint8_t b = (uint8_t)I2C0->DAT;
        if (s_rx_len < sizeof(s_rx_buf)) {
            s_rx_buf[s_rx_len++] = b;
        }
        if (s_rx_len == 1) {
            if (s_active_addr == (I2C_ADDR_REG << 1)) {
                s_reg_ptr = b;
            } else if (s_active_addr == (I2C_ADDR_EDID << 1)) {
                s_edid_ptr = b;
            }
        }
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
    } else if (status == 0xA8 || status == 0xB0) {
        handle_rx_complete();
        s_active_addr = (uint8_t)(I2C0->DAT & 0xFE);

        uint8_t tx_byte = 0xFF;
        if (s_active_addr == (I2C_ADDR_REG << 1)) {
            if (s_reg_ptr < REG_FILE_SIZE) {
                tx_byte = g_i2c0.regs[s_reg_ptr++];
            }
        } else if (s_active_addr == (I2C_ADDR_PROXY << 1)) {
            tx_byte = i2c_proxy_next(g_i2c0.proxy_rx_buf, g_i2c0.proxy_rx_len,
                                      &g_i2c0.proxy_rx_idx, g_i2c0.proxy_status);
        } else if (s_active_addr == (I2C_ADDR_UPG << 1)) {
            if (s_upg.resp_idx < s_upg.resp_len) {
                tx_byte = s_upg.resp[s_upg.resp_idx++];
            }
        } else if (s_active_addr == (I2C_ADDR_EDID << 1)) {
            if (s_edid_ptr < 256) {
                tx_byte = g_active_edid[s_edid_ptr++];
            }
        }

        I2C0->DAT = tx_byte;
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
    } else if (status == 0xB8) {
        uint8_t tx_byte = 0xFF;
        if (s_active_addr == (I2C_ADDR_REG << 1)) {
            if (s_reg_ptr < REG_FILE_SIZE) {
                tx_byte = g_i2c0.regs[s_reg_ptr++];
            }
        } else if (s_active_addr == (I2C_ADDR_PROXY << 1)) {
            tx_byte = i2c_proxy_next(g_i2c0.proxy_rx_buf, g_i2c0.proxy_rx_len,
                                      &g_i2c0.proxy_rx_idx, g_i2c0.proxy_status);
        } else if (s_active_addr == (I2C_ADDR_UPG << 1)) {
            if (s_upg.resp_idx < s_upg.resp_len) {
                tx_byte = s_upg.resp[s_upg.resp_idx++];
            }
        } else if (s_active_addr == (I2C_ADDR_EDID << 1)) {
            if (s_edid_ptr < 256) {
                tx_byte = g_active_edid[s_edid_ptr++];
            }
        }

        I2C0->DAT = tx_byte;
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
    } else if (status == 0xC0) {
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
    } else if (status == 0xA0) {
        handle_rx_complete();
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
    } else {
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_STO_SI);
        I2C_SET_CONTROL_REG(I2C0, I2C_CTL_SI_AA);
        s_rx_len = 0;
    }
}

void i2c0_slave_init(it6663_info_t *info)
{
    memset((void *)&g_i2c0, 0, sizeof(g_i2c0));

    g_i2c0.regs[0x00] = (uint8_t)(MCU_FW_VERSION & 0xFF);         /* 0x02 */
    g_i2c0.regs[0x01] = (uint8_t)((MCU_FW_VERSION >> 8) & 0xFF);  /* 0x01 */
    g_i2c0.regs[0x02] = (uint8_t)((MCU_FW_VERSION >> 16) & 0xFF); /* 0x62 */
    g_i2c0.regs[0x03] = (uint8_t)((MCU_FW_VERSION >> 24) & 0xFF); /* 0x12 */

    g_i2c0.regs[0x05] = 0xA5;

    i2c0_update_status(info);

    I2C_Open(I2C0, 100000);

    I2C_SetSlaveAddr(I2C0, 0, I2C_ADDR_REG, 0);   /* 0x32 */
    I2C_SetSlaveAddr(I2C0, 1, I2C_ADDR_PROXY, 0); /* 0x33 */
    I2C_SetSlaveAddr(I2C0, 2, I2C_ADDR_UPG, 0);   /* 0x2A */
    I2C_SetSlaveAddr(I2C0, 3, I2C_ADDR_EDID, 0);  /* 0x50 */

    I2C_SetSlaveAddrMask(I2C0, 0, 0x01);
    I2C_SetSlaveAddrMask(I2C0, 1, 0x01);
    I2C_SetSlaveAddrMask(I2C0, 2, 0x01);
    I2C_SetSlaveAddrMask(I2C0, 3, 0x01);

    I2C_EnableInt(I2C0);
    NVIC_EnableIRQ(I2C0_IRQn);
    I2C_SET_CONTROL_REG(I2C0, I2C_CTL_AA);
}
