/* SPDX-License-Identifier: Apache-2.0 */
#ifndef BOARD_H
#define BOARD_H

#include <stdint.h>
#include <stdbool.h>
#include "NUC1262.h"

/* SC7F0 N1 HDMI2 V11 Exact Pinout:
 *   PA.10 (pin 9)  -> RSTn_MCU0 -> SU4 AND -> RSTn_GPIO_MCU0 [14] (IT6663 reset, active low)
 *   PA.11 (pin 8)  -> MCU0_HPD [14] (HDMI HPD assert)
 *   PB.2  (pin 5)  -> H0_RX_DET [14] (HDMI cable 5V detect input)
 *   PB.5  (pin 2)  -> H0_P1TXHPD [14] (IT6663 Port 1 TX HPD output)
 *   PB.6  (pin 1)  -> X0_PS_SRSTb [10] (PS reset input/monitor)
 *   PF.6  (pin 12) -> H0_RX_EN [14] (1.0V regulator enable output)
 *   PC.0  (pin 40) -> I2C0_SDA (ZU4EV PS I2C1 / Linux /dev/i2c-0)
 *   PC.1  (pin 39) -> I2C0_SCL (ZU4EV PS I2C1 / Linux /dev/i2c-0)
 *   PB.0  (pin 7)  -> I2C1_SDA (IT6663 / NCT7717 / EEPROM)
 *   PB.1  (pin 6)  -> I2C1_SCL (IT6663 / NCT7717 / EEPROM)
 */

#define MCU_FW_VERSION   0x1262010FUL  /* NUC1262 v1.1.15: vendor-equivalent RX HPD */

void board_init(void);
void board_delay_ms(uint32_t ms);
void board_it6663_power(bool enable);
void board_it6663_reset(bool assert_reset);
void board_hdmi_hpd(bool enable);
bool board_hdmi_5v_detected(void);
uint8_t board_get_status_byte(void);

#endif /* BOARD_H */
