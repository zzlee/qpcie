/* SPDX-License-Identifier: GPL-2.0 */
#ifndef QPCIE_DEBUG_H
#define QPCIE_DEBUG_H
/* ABI 1: two single-producer/single-consumer framed mailboxes, not a TTY.
 * Offsets relative to BAR0+0x2000 / PS physical 0xA0002000.
 * All accesses are aligned little-endian u32. Publish SEQ last, ACK only
 * after payload consumption. Never replay a command after reconnection.
 */
#define QDBG_HW_VERSION 0x26101503U
#define QDBG_HW_VERSION_CDC 0x26101502U
#define QDBG_CAP_DEBUG_ONLY 0x80000000U
#define QDBG_HW_VERSION_INITIAL 0x26101501U
#define QDBG_BAR_OFFSET 0x2000U
#define QDBG_PS_ADDRESS 0xA0002000ULL
#define QDBG_SIZE       0x2000U
#define QDBG_MAGIC      0x53434442U
#define QDBG_ABI        1U
#define DB_MAGIC        0x00
#define DB_ABI          0x04
#define DB_READY        0x08 /* card owns: 1 only after initialization */
#define DB_CARD_EPOCH   0x0c /* card owns: random on daemon start */
#define DB_HOST_EPOCH   0x10 /* host owns: random on every open */
#define DB_ACK_EPOCH    0x14 /* card owns: acknowledges drained new session */
#define DB_CARD_BEAT    0x18 /* card owns: monotonic milliseconds (low 32 bits) */
#define DB_H2C_SEQ      0x1c /* host owns */
#define DB_H2C_ACK      0x20 /* card owns */
#define DB_H2C_TYPE     0x24
#define DB_H2C_ID       0x28
#define DB_H2C_LEN      0x2c
#define DB_C2H_SEQ      0x30 /* card owns */
#define DB_C2H_ACK      0x34 /* host owns */
#define DB_C2H_TYPE     0x38
#define DB_C2H_ID       0x3c
#define DB_C2H_LEN      0x40
#define DB_C2H_CODE     0x44 /* EXIT: shell status, 124 timeout, 125 cancellation */
#define DB_TIMEOUT_MS   0x48 /* host owns: EXEC budget, 1..300000 ms */
#define DB_HOST_BEAT    0x4c /* host owns: detect disconnected clients */
#define DB_H2C_DATA     0x400
#define DB_C2H_DATA     0x1000
#define DB_PAYLOAD      3072U
#define DB_EXEC         1U
#define DB_ECHO         2U
#define DB_CANCEL       3U
#define DB_STDOUT       1U
#define DB_STDERR       2U
#define DB_EXIT         3U
#define DB_ECHO_REPLY   4U
#define DB_MAX_TIMEOUT  300000U
#define DB_PEER_DEAD_MS 3000U
#endif
