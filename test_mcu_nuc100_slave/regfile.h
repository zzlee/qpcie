/* Shared 16-byte control regfile (APROM app + LDROM console).
 * Offsets: 00 MAGIC=2A (RO), 01 VER (RO), 02 STATUS live (RO),
 * 03 CTRL RW (raw GPIO), 04..0F scratch RW.
 * CTRL bit0 -> PB.10 (HPD0_CTRL, INVERTED by M1: 1 = cable HPD LOW),
 * CTRL bit1 -> PB.15 (RSTn_PCIe).
 */
#ifndef REGFILE_H
#define REGFILE_H

#include <stdint.h>

#define REG_NUM   16U
#define REG_MAGIC 0x00U
#define REG_VER   0x01U
#define REG_STATUS 0x02U
#define REG_CTRL  0x03U

void regfile_init(uint8_t ver, uint8_t ctrl_default);
uint8_t app_reg_read(uint8_t idx);
void app_reg_write(uint8_t idx, uint8_t val);
uint8_t regfile_ctrl(void);

#endif
