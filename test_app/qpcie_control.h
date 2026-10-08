/*
 * qpcie_control.h - Register offsets and structures for QPCIe Video TPG & Audio Pattern Gen
 */

#ifndef QPCIE_CONTROL_H
#define QPCIE_CONTROL_H

#include <stdint.h>

/* BAR1 Address Offsets */
#define BAR1_OFFSET_ENV            0x0000
#define BAR1_OFFSET_AUDIO_PATGEN   0x1000
#define BAR1_OFFSET_EDID_RAM       0x2000
#define BAR1_OFFSET_VIDEO_TPG      0x3000
#define BAR1_OFFSET_FW_STREAM      0x8000

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

/* BAR0 HDMI Status and Control Registers (Block 4'h6: 0x0600 - 0x0664) */
#define BAR0_REG_HDMI_RX_STATUS      0x0600 /* Bit 0: 5V Det, Bit 1: HPD Out, Bit 2: TMDS Lock, Bit 3: Vid Lock */
#define BAR0_REG_HDMI_RX_WIDTH       0x0604 /* Active Width (e.g. 1920) */
#define BAR0_REG_HDMI_RX_HEIGHT      0x0608 /* Active Height (e.g. 1080) */
#define BAR0_REG_HDMI_RX_PIXEL_CLK   0x060C /* Pixel Clock in Hz (e.g. 148500000) */

#define BAR0_REG_HDMI_TX_CTRL        0x0610 /* Bit 0: Out En, Bit 1: Aud En, [3:2]: ColorSpace, [5:4]: ColorDepth */
#define BAR0_REG_HDMI_TX_RES         0x0614 /* [15:0]: Width, [31:16]: Height */
#define BAR0_REG_HDMI_TX_FPS         0x0618 /* [15:0]: Target FPS Code */
#define BAR0_REG_HDMI_TX_STATUS      0x0620 /* Bit 0: HPD, Bit 1: Locked, Bit 2: Active */

/* Host <-> ARM PetaLinux PS IPC Mailbox Registers */
#define BAR0_REG_HDMI_IPC_CMD        0x0630
#define BAR0_REG_HDMI_IPC_ARG        0x0634
#define BAR0_REG_HDMI_IPC_STATUS     0x0638
#define BAR0_REG_HDMI_IPC_DOORBELL   0x063C

/* Detailed DV Timings & InfoFrames from xilinx-hdmirxss */
#define BAR0_REG_HDMI_RX_HFP         0x0640 /* H Front Porch */
#define BAR0_REG_HDMI_RX_HSW         0x0644 /* H Sync Width */
#define BAR0_REG_HDMI_RX_HBP         0x0648 /* H Back Porch */
#define BAR0_REG_HDMI_RX_VFP         0x064C /* V Front Porch */
#define BAR0_REG_HDMI_RX_VSW         0x0650 /* V Sync Width */
#define BAR0_REG_HDMI_RX_VBP         0x0654 /* V Back Porch */
#define BAR0_REG_HDMI_RX_POLARITIES  0x0658 /* Bit 0: VSync Pos, Bit 1: HSync Pos */
#define BAR0_REG_HDMI_RX_STANDARDS   0x065C /* Standards (e.g. V4L2_DV_BT_STD_CEA861) */
#define BAR0_REG_HDMI_RX_COLOR_FMT   0x0660 /* Colorspace, Quantization, YCbCr Enc */
#define BAR0_REG_HDMI_RX_AUDIO_FMT   0x0664 /* [15:0]=SampleRateHz, [23:16]=Channels, [31:24]=BitDepth */

#endif /* QPCIE_CONTROL_H */
