/*
 * qpcie_control.h - Register offsets and structures for QPCIe Video TPG & Audio Pattern Gen
 */

#ifndef QPCIE_CONTROL_H
#define QPCIE_CONTROL_H

#include <stdint.h>

/* BAR1 Address Offsets */
#define BAR1_OFFSET_VIDEO_TPG      0x0000
#define BAR1_OFFSET_AUDIO_PATGEN   0x0100
#define BAR1_OFFSET_USER_REGS      0x0200

/* Video TPG (v_tpg_0) Register Offsets (s_axi_CTRL) */
#define TPG_REG_CTRL               0x00 /* Bit 0: AP_START, Bit 7: Auto-restart */
#define TPG_REG_ACTIVE_ROWS        0x10 /* Height (e.g. 1080) */
#define TPG_REG_ACTIVE_COLS        0x18 /* Width  (e.g. 1920) */
#define TPG_REG_PATTERN_ID         0x20 /* Pattern: 0: Pass-through, 1: Horizontal Ramp, 2: Vertical Ramp, 9: Color Bars, 10: Zone Plate */
#define TPG_REG_MOTION_SPEED       0x38 /* Motion speed for moving patterns */

/* Audio Pattern Generator Register Offsets */
#define AUD_REG_CTRL               0x00 /* Bit 0: Enable, Bit [3:1]: Pattern (0: 1kHz Sine, 1: Sawtooth, 2: 440Hz, 3: Mute) */
#define AUD_REG_DIVISOR            0x04 /* Sample Rate Divisor (Default 2604 for 48kHz @ 125MHz clk) */
#define AUD_REG_VOLUME             0x08 /* Volume Gain (0-255) */
#define AUD_REG_STATUS             0x0C /* Status (Bit 0: Running, Bit 1: AES3 Locked) */
#define AUD_REG_SAMPLE_CNT         0x10 /* Total Audio Subframes Generated Count */

#endif /* QPCIE_CONTROL_H */
