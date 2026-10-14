/* Upgrade protocol engine: command decode, SRAM staging, validation.
 * No I2C register access here (transport owned by i2c_slave.c).
 * Handoff (reboot) runs in main-loop context via upg_poll(), never in ISR.
 */
#include "upg.h"
#include "NUC100Series.h"

#define UPG_CMD_MAX 40U /* escape + CMD + worst args (CHUNK header + 32B + CRC8) */

__attribute__((section(".stage"))) static uint8_t upg_stage[UPG_STAGE_MAX];

static uint8_t  upg_cmdbuf[UPG_CMD_MAX];
static uint8_t  upg_cmdlen;
static uint8_t  upg_state_v = UPG_STATE_IDLE;
static uint32_t upg_exp_len;
static uint32_t upg_exp_crc;
static uint8_t  upg_err_v;
static uint16_t upg_done_v;
static uint8_t  upg_handoff; /* app path: BS=LDROM + reset */
uint8_t upg_flashing;        /* LDROM path: program in upg_poll */

static uint8_t  upg_shared_resp[8];
static uint8_t  upg_shared_len;

uint32_t upg_crc32(const uint8_t *data, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFUL, i, j;
    for (i = 0; i < len; i++) {
        crc ^= data[i];
        for (j = 0; j < 8; j++)
            crc = (crc & 1UL) ? (crc >> 1) ^ 0xEDB88320UL : (crc >> 1);
    }
    return ~crc;
}

uint8_t upg_crc8(const uint8_t *data, uint32_t len)
{
    uint8_t crc = 0, i, j;
    for (i = 0; i < len; i++) {
        crc ^= data[i];
        for (j = 0; j < 8; j++)
            crc = (crc & 0x80U) ? (uint8_t)((crc << 1) ^ 0x07U) : (uint8_t)(crc << 1);
    }
    return crc;
}

uint8_t upg_state(void) { return upg_state_v; }
uint16_t upg_done(void) { return upg_done_v; }
uint8_t upg_err(void) { return upg_err_v; }
uint8_t *upg_image_ptr(void) { return upg_stage; }
uint32_t upg_image_len(void)
{
    return (upg_state_v == UPG_STATE_FLASH) ? upg_exp_len : 0UL;
}

/* Default backend: APROM app hands off to LDROM (LDROM overrides flash). */
__attribute__((weak)) uint8_t upg_role(void) { return UPG_ROLE_APP; }
__attribute__((weak)) uint8_t upg_writer_ready(void)
{
    return (*((volatile uint32_t *)UPG_LDROM_BASE) == UPG_LDROM_MAGIC) ? 1U : 0U;
}

static void upg_unlock(void)
{
    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;
}

__attribute__((weak)) void upg_request_handoff(void) { upg_handoff = 1U; }
__attribute__((weak)) int upg_request_flash(void) { return -1; }
__attribute__((weak)) int upg_do_flash_pages(void) { return -1; }

/* Shared commit: validate staged image, then role-specific next step. */
int upg_backend_commit(void)
{
    if (upg_crc32(upg_stage, upg_exp_len) != upg_exp_crc)
        return 1;
    if (upg_role() == UPG_ROLE_APP) {
        upg_request_handoff();
    } else {
        if (upg_request_flash() != 0)
            return 1;
    }
    return 0;
}

void upg_rx_byte(uint8_t b)
{
    if (upg_cmdlen < UPG_CMD_MAX)
        upg_cmdbuf[upg_cmdlen++] = b;
}

void upg_rx_abort(void)
{
    upg_cmdlen = 0;
}

void upg_rx_end(void)
{
    uint8_t rsp[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    uint8_t rlen = 1;
    uint32_t i, off, n;

    upg_shared_len = 0;
    if (upg_cmdlen == 0)
        return;

    switch (upg_cmdbuf[0]) {
    case UPG_CMD_HELLO:
        rsp[0] = UPG_PROTO_VER;
        rsp[1] = upg_role();
        rsp[2] = (uint8_t)((upg_role() == UPG_ROLE_APP && upg_writer_ready()) ? 2U : 0U);
        rsp[3] = UPG_MAXCHUNK;
        rlen = 4;
        break;

    case UPG_CMD_BEGIN:
        if (upg_state_v == UPG_STATE_FLASH) {
            rsp[0] = UPG_ST_BUSY;
            break;
        }
        if (upg_cmdlen < 8) {
            rsp[0] = UPG_ST_CRCERR;
            break;
        }
        upg_exp_len = (uint32_t)upg_cmdbuf[1] | ((uint32_t)upg_cmdbuf[2] << 8);
        upg_exp_crc = (uint32_t)upg_cmdbuf[3] | ((uint32_t)upg_cmdbuf[4] << 8) |
                      ((uint32_t)upg_cmdbuf[5] << 16) | ((uint32_t)upg_cmdbuf[6] << 24);
        if (upg_exp_len == 0UL || upg_exp_len > UPG_STAGE_MAX) {
            rsp[0] = UPG_ST_TOOBIG;
            break;
        }
        upg_state_v = UPG_STATE_RX;
        upg_err_v = 0;
        upg_done_v = 0;
        rsp[0] = UPG_ST_OK;
        break;

    case UPG_CMD_CHUNK: {
        uint8_t calc;
        if (upg_state_v != UPG_STATE_RX && upg_state_v != UPG_STATE_READY) {
            rsp[0] = UPG_ST_NOSESSION;
            break;
        }
        if (upg_cmdlen < 5) {
            rsp[0] = UPG_ST_CRCERR;
            break;
        }
        off = (uint32_t)upg_cmdbuf[1] | ((uint32_t)upg_cmdbuf[2] << 8);
        n = upg_cmdbuf[3];
        if (n > UPG_MAXCHUNK || upg_cmdlen != (uint8_t)(5U + n) ||
            off + n > upg_exp_len) {
            rsp[0] = UPG_ST_BADOFF;
            break;
        }
        calc = upg_crc8(&upg_cmdbuf[1], (uint32_t)(3U + n));
        if (calc != upg_cmdbuf[4U + n]) {
            rsp[0] = UPG_ST_CRCERR;
            break;
        }
        for (i = 0; i < n; i++)
            upg_stage[off + i] = upg_cmdbuf[4U + i];
        if (off + n > upg_done_v)
            upg_done_v = (uint16_t)(off + n);
        upg_state_v = UPG_STATE_READY;
        rsp[0] = UPG_ST_OK;
        break;
    }

    case UPG_CMD_COMMIT:
        if (upg_state_v != UPG_STATE_READY && upg_state_v != UPG_STATE_RX) {
            rsp[0] = UPG_ST_NOSESSION;
            break;
        }
        if (upg_backend_commit() == 0) {
            upg_state_v = UPG_STATE_FLASH;
            rsp[0] = UPG_ST_OK;
        } else {
            upg_state_v = UPG_STATE_ERROR;
            upg_err_v = 1;
            rsp[0] = UPG_ST_CRCERR;
        }
        break;

    case UPG_CMD_ABORT:
        upg_state_v = UPG_STATE_IDLE;
        upg_err_v = 0;
        upg_done_v = 0;
        rsp[0] = UPG_ST_OK;
        break;

    case UPG_CMD_PROGRESS:
        rsp[0] = upg_state_v;
        rsp[1] = (uint8_t)(upg_done_v & 0xFFU);
        rsp[2] = (uint8_t)((upg_done_v >> 8) & 0xFFU);
        rsp[3] = upg_err_v;
        rlen = 4;
        break;

    case UPG_CMD_GOTOLDROM:
        rsp[0] = UPG_ST_OK;
        upg_handoff = 1U;
        upg_state_v = UPG_STATE_FLASH;
        break;

    default:
        rsp[0] = UPG_ST_CRCERR;
        break;
    }

    for (i = 0; i < rlen; i++)
        upg_shared_resp[i] = rsp[i];
    upg_shared_len = rlen;
    upg_cmdlen = 0;
}

/* Fill transport response (idempotent; transport manages index/wrap). */
void upg_tx_serve(upg_resp_t *r)
{
    uint8_t i;
    for (i = 0; i < upg_shared_len && i < 8; i++)
        r->resp[i] = upg_shared_resp[i];
    r->resp_len = upg_shared_len;
}

/* Main-loop context only. Handoff/flash never run in ISR. */
void upg_poll(void)
{
    volatile uint32_t d;
    if (upg_handoff == 0U && upg_flashing == 0U)
        return;
    if (upg_handoff != 0U) {
        upg_handoff = 0U;
        /* Host readout window for the COMMIT response (~500ms, IRQs live). */
        for (d = 0; d < 500000UL; d++) {
            __NOP();
        }
        upg_unlock();
        FMC->ISPCON |= FMC_ISPCON_BS_Msk; /* boot LDROM after reset */
        NVIC_SystemReset();
        while (1) {
        }
    }
    if (upg_flashing != 0U) {
        int rc;
        upg_flashing = 0U;
        __disable_irq();
        rc = upg_do_flash_pages();
        if (rc == 0) {
            upg_unlock();
            FMC->ISPCON &= ~FMC_ISPCON_BS_Msk; /* boot APROM after reset */
            NVIC_SystemReset();
            while (1) {
            }
        }
        __enable_irq();
        upg_state_v = UPG_STATE_ERROR;
        upg_err_v = (uint8_t)(0 - rc);
    }
}
