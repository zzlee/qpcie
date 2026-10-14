/* Shared upgrade protocol engine (APROM app + LDROM console).
 *
 * Transport (owned by i2c_slave.c): first W byte UPG_ESCAPE escapes the
 * whole transaction to the command decoder; the following Sr+R serves
 * the last response.
 * All multi-byte values little-endian. CRC32 = IEEE (poly 0xEDB88320),
 * CRC8 poly 0x07 init 0x00.
 *
 * Opcodes (after escape byte):
 *   0x01 HELLO  -> R[4]: [PROTO_VER, ROLE, FLAGS, MAXCHUNK]
 *   0x02 BEGIN [LEN_L LEN_H CRC32x4] -> R[1]: [STATUS]
 *   0x03 CHUNK [OFF_L OFF_H N DATA..N CRC8] -> R[1]: [STATUS]
 *   0x04 COMMIT -> R[1]: [STATUS] (accepted work continues after STOP)
 *   0x05 ABORT  -> R[1]: [0]
 *   0x06 PROGRESS -> R[4]: [STATE, DONE_L, DONE_H, ERR]
 *   0x07 GOTOLDROM -> R[1]: [0], then jump to LDROM console (app only)
 * STATUS: 0 ok / 1 too-big / 2 busy / 3 crc-err / 4 no-session / 5 bad-offset
 * ROLE: 0 = APROM app, 1 = LDROM recovery console.
 * FLAGS bit1 = writer path ready (LDROM valid for app).
 */
#ifndef UPG_H
#define UPG_H

#include <stdint.h>

#define UPG_ESCAPE        0x04U
#define UPG_ADDR          0x2BU  /* hardware alias only; same escape protocol */
#define UPG_CMD_MAX       40U
#define UPG_PROTO_VER     0x01U
#define UPG_ROLE_APP      0U
#define UPG_ROLE_CONSOLE  1U
#define UPG_MAXCHUNK      32U

#define UPG_CMD_HELLO     0x01U
#define UPG_CMD_BEGIN     0x02U
#define UPG_CMD_CHUNK     0x03U
#define UPG_CMD_COMMIT    0x04U
#define UPG_CMD_ABORT     0x05U
#define UPG_CMD_PROGRESS  0x06U
#define UPG_CMD_GOTOLDROM 0x07U

#define UPG_ST_OK         0U
#define UPG_ST_TOOBIG     1U
#define UPG_ST_BUSY       2U
#define UPG_ST_CRCERR     3U
#define UPG_ST_NOSESSION  4U
#define UPG_ST_BADOFF     5U

#define UPG_STATE_IDLE    0U
#define UPG_STATE_RX      1U
#define UPG_STATE_READY   2U
#define UPG_STATE_FLASH   3U
#define UPG_STATE_DONE    4U
#define UPG_STATE_ERROR   5U

/* Fixed SRAM staging (shared by APROM + LDROM builds via linker .stage). */
#define UPG_STAGE_BASE    0x20001000UL
#define UPG_STAGE_MAX     8192U

/* APROM layout shared by stage0 + writer + host tool.
 * 64-byte header @0x0800, code follows; CRC covers [0x840, base+len). */
#define UPG_APP_BASE      0x0800UL
#define UPG_APP_HDR       0x0800UL
#define UPG_APP_HDR_LEN   64UL
#define UPG_FLASH_END     0x20000UL
#define UPG_APP_MAGIC     0x41505032UL /* "APP2" */
#define UPG_LDROM_BASE    0x100000UL
#define UPG_LDROM_MAGIC   0x4C443130UL /* "LD10" */

typedef struct {
    uint8_t  resp[8];
    uint8_t  resp_len;
} upg_resp_t;

/* Feed one byte of an upgrade transaction (escape byte already consumed).
 * Decodes per-transaction buffer; executes command at transaction end. */
void upg_execute(uint8_t bus, const uint8_t *cmd, uint8_t len,
                 upg_resp_t *response);

/* Called from main loop (NOT ISR): reboot countdown + LDROM-side flashing. */
void upg_poll(void);

/* Backend hooks (weak defaults suit APROM app; LDROM overrides flash). */
int  upg_backend_commit(void); /* validate + arm next step, 0 accepted */
uint8_t upg_role(void);        /* UPG_ROLE_APP or UPG_ROLE_CONSOLE */
uint8_t upg_writer_ready(void);/* 1 when LDROM magic valid (app only) */
void upg_request_handoff(void);/* schedule BS=LDROM + reset (app path) */
int  upg_request_flash(void);  /* schedule in-place program (LDROM path) */
int  upg_do_flash_pages(void); /* LDROM: program+verify all, 0 ok */
extern uint8_t upg_flashing;   /* set by LDROM commit path */

uint32_t upg_crc32(const uint8_t *data, uint32_t len);
uint8_t  upg_crc8(const uint8_t *data, uint32_t len);

uint8_t upg_state(void);
uint16_t upg_done(void);
uint8_t upg_err(void);
uint8_t *upg_image_ptr(void);  /* staging base (fixed SRAM, both builds) */
uint32_t upg_image_len(void);  /* validated length (0 unless committed) */

#endif
