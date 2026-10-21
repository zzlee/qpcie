/* SPDX-License-Identifier: Apache-2.0 */
#ifndef IT6663_H
#define IT6663_H

#include <stdint.h>
#include <stdbool.h>

/* IT6663 7-bit I2C Slave Addresses */
#define IT6663_ADDR_SW     0x2C  /* 8-bit 0x58: Main switch / router */
#define IT6663_ADDR_RXP0   0x38  /* 8-bit 0x70: HDMI RX Port 0 core */
#define IT6663_ADDR_EDID   0x6C  /* 8-bit 0xD8: Internal EDID RAM */
#define IT6663_ADDR_TXCOM  0x4B  /* 8-bit 0x96: TX Common */
#define IT6663_ADDR_TXP0   0x34  /* 8-bit 0x68 */
#define IT6663_ADDR_TXP1   0x35  /* 8-bit 0x6A: TX Port 1 (to FPGA) */
#define IT6663_ADDR_TXP2   0x36  /* 8-bit 0x6C: TX Port 2 (Loopout) */
#define IT6663_ADDR_TXP3   0x37  /* 8-bit 0x6E */

#define NCT7717_I2C_ADDR   0x48  /* 8-bit 0x90: Temperature sensor */

typedef struct {
    bool     it6663_present;
    uint8_t  it6663_addr;       /* 0x2C */
    bool     nct7717_present;
    uint8_t  ven_id[2];         /* Expected: 0x54, 0x49 ("IT") */
    uint8_t  dev_id[2];         /* Expected: 0x63, 0x66 ("6663") */
    uint8_t  rev_id;            /* Revision ID: 0xA0 */
    uint8_t  temperature;       /* From NCT7717 */
    bool     hdmi_5v;           /* 5V Cable Detect */
    bool     clock_locked;      /* Checked clock + symbols + SCDT, never retained TX state */
    bool     hdmi_mode;         /* Meaningful only while clock_locked */
    uint16_t pixel_clk_mhz;     /* 0: not measured */
    uint16_t h_active;          /* Checked raw H counter; 0 if invalid, no color scaling */
    uint16_t v_active;          /* Checked raw V counter; 0 if invalid */
    uint8_t  num_slaves;        /* Total slaves detected on I2C1 */
    uint8_t  slaves[16];        /* List of detected slave addresses */
} it6663_info_t;

extern uint8_t g_active_edid[256];

void it6663_init(it6663_info_t *info);
int  it6663_probe(it6663_info_t *info);
void it6663_poll_status(it6663_info_t *info);
int  it6663_update_edid(const uint8_t *edid256);
int  it6663_rx_hpd(bool enable);
void it6663_tx_setup(uint8_t tx_addr, bool is_hdmi, bool is_hdmi20);
void it6663_tx_power_down(uint8_t tx_addr);
void it6663_tx_vclk_reset(uint8_t tx_addr);
void it6663_tx_scdc_write(uint8_t tx_addr, uint8_t offset, uint8_t val);

int  i2c1_write(uint8_t addr, const uint8_t *data, uint32_t len);
int  i2c1_read(uint8_t addr, uint8_t *data, uint32_t len);
int  i2c1_transfer(uint8_t addr, const uint8_t *tx, uint32_t txlen, uint8_t *rx, uint32_t rxlen);

int  it6663_wr(uint8_t addr, uint8_t offset, uint8_t val);
uint8_t it6663_rd(uint8_t addr, uint8_t offset);
int  it6663_set(uint8_t addr, uint8_t offset, uint8_t mask, uint8_t val);

#endif /* IT6663_H */
