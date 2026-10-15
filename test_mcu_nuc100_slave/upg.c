/* Upgrade protocol engine: command decode, SRAM staging, validation.
 * No I2C register access here (transport owned by i2c_slave.c).
 * Handoff (reboot) runs in main-loop context via upg_poll(), never in ISR.
 */
#include "upg.h"
#include "NUC100Series.h"


__attribute__((section(".stage"))) static uint8_t upg_stage[UPG_STAGE_MAX];

static uint8_t upg_owner = 0xFFU;
static uint8_t  upg_state_v = UPG_STATE_IDLE;
static uint32_t upg_exp_len;
static uint32_t upg_exp_crc;
static uint8_t  upg_err_v;
static uint16_t upg_done_v;
static uint8_t  upg_handoff; /* app path: BS=LDROM + reset */
uint8_t upg_flashing;        /* LDROM path: program in upg_poll */


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
void upg_set_error(uint8_t err)
{
    upg_state_v = UPG_STATE_ERROR;
    upg_err_v = err;
}
uint8_t *upg_image_ptr(void) { return upg_stage; }
uint32_t upg_image_len(void)
{
    return (upg_state_v == UPG_STATE_FLASH) ? upg_exp_len : 0UL;
}

/* Default backend: APROM app hands off to LDROM (LDROM overrides flash). */
__attribute__((weak)) uint8_t upg_role(void) { return UPG_ROLE_APP; }
__attribute__((weak)) uint8_t upg_writer_ready(void)
{
    return 1U;
}

static void upg_unlock(void)
{
    SYS->REGWRPROT = 0x59UL;
    SYS->REGWRPROT = 0x16UL;
    SYS->REGWRPROT = 0x88UL;
}

#include "writer.h"

__attribute__((weak)) int writer_program_aprom(uint32_t dst_addr, const uint32_t *src, uint32_t nwords)
{
    (void)dst_addr;
    (void)src;
    (void)nwords;
    return 0;
}

int upg_do_flash_pages(void)
{
    uint32_t len = upg_image_len();
    uint32_t nwords;

    if (len == 0UL || len > UPG_STAGE_MAX)
        return -1;
    nwords = (len + 3UL) / 4UL;
    return writer_program_aprom(UPG_APP_BASE, (const uint32_t *)upg_stage, nwords);
}

__attribute__((weak)) int upg_request_flash(void) { return 0; }

/* Shared commit: validate staged image, then trigger in-place flash. */
int upg_backend_commit(void)
{
    if (upg_crc32(upg_stage, upg_exp_len) != upg_exp_crc)
        return 1;
    if (upg_role() == UPG_ROLE_APP) {
        volatile uint32_t *hs = (volatile uint32_t *)UPG_HANDSHAKE_ADDR;
        hs[0] = UPG_HANDSHAKE_MAGIC;
        hs[1] = upg_exp_len;
        hs[2] = upg_exp_crc;
        upg_handoff = 1U;
        return 0;
    }
    if (upg_request_flash() != 0)
        return 1;
    upg_flashing = 1U;
    return 0;
}

void upg_execute(uint8_t bus, const uint8_t *upg_cmdbuf, uint8_t upg_cmdlen,
                 upg_resp_t *response)
{
    uint8_t rsp[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    uint8_t rlen = 1;
    uint32_t i, off, n;

    if (upg_cmdlen == 0 || upg_cmdlen > UPG_CMD_MAX || bus > 1U) {
        rsp[0] = UPG_ST_CRCERR;
        goto respond;
    }
    if (
        (upg_cmdbuf[0] != UPG_CMD_BEGIN &&
         upg_cmdbuf[0] != UPG_CMD_CHUNK && upg_cmdlen != 1U)) {
        rsp[0] = UPG_ST_CRCERR;
        goto respond;
    }
    if (upg_owner != 0xFFU && upg_owner != bus &&
        upg_cmdbuf[0] != UPG_CMD_HELLO &&
        upg_cmdbuf[0] != UPG_CMD_PROGRESS) {
        rsp[0] = UPG_ST_BUSY;
        goto respond;
    }

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
        if (upg_cmdlen != 7U) {
            rsp[0] = UPG_ST_CRCERR;
            break;
        }
        n = (uint32_t)upg_cmdbuf[1] | ((uint32_t)upg_cmdbuf[2] << 8);
        if (n < UPG_APP_HDR_LEN || n > UPG_STAGE_MAX || (n & 3U)) {
            rsp[0] = UPG_ST_TOOBIG;
            break;
        }
        upg_exp_len = n;
        upg_exp_crc = (uint32_t)upg_cmdbuf[3] | ((uint32_t)upg_cmdbuf[4] << 8) |
                      ((uint32_t)upg_cmdbuf[5] << 16) | ((uint32_t)upg_cmdbuf[6] << 24);
        if (upg_exp_len == 0UL || upg_exp_len > UPG_STAGE_MAX) {
            rsp[0] = UPG_ST_TOOBIG;
            break;
        }
        upg_state_v = UPG_STATE_RX;
        upg_owner = bus;
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
        if (n == 0U || n > UPG_MAXCHUNK || upg_cmdlen != (uint8_t)(5U + n) ||
            off + n > upg_exp_len) {
            rsp[0] = UPG_ST_BADOFF;
            break;
        }
        calc = upg_crc8(&upg_cmdbuf[1], (uint32_t)(3U + n));
        if (calc != upg_cmdbuf[4U + n]) {
            rsp[0] = UPG_ST_CRCERR;
            break;
        }
        /* Contiguous coverage, with idempotent retries of accepted bytes.
         * Never count a high-offset chunk as proof of missing low bytes. */
        if (off != upg_done_v) {
            if (off + n > upg_done_v) {
                rsp[0] = UPG_ST_BADOFF;
                break;
            }
            for (i = 0; i < n; i++) {
                if (upg_stage[off + i] != upg_cmdbuf[4U + i]) {
                    rsp[0] = UPG_ST_BADOFF;
                    break;
                }
            }
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
        if (upg_done_v != upg_exp_len) {
            rsp[0] = UPG_ST_BADOFF;
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
        if (upg_state_v == UPG_STATE_FLASH) {
            rsp[0] = UPG_ST_BUSY;
            break;
        }
        upg_state_v = UPG_STATE_IDLE;
        upg_owner = 0xFFU;
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

respond:
    for (i = 0; i < rlen; i++)
        response->resp[i] = rsp[i];
    response->resp_len = rlen;
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
        CLK->AHBCLK |= CLK_AHBCLK_ISP_EN_Msk;
        FMC->ISPCON |= FMC_ISPCON_ISPEN_Msk | FMC_ISPCON_BS_Msk; /* boot LDROM after reset */
        NVIC_SystemReset();
        while (1) {
        }
    }
    if (upg_flashing != 0U) {
        int rc;
        upg_flashing = 0U;
        /* Host readout window for COMMIT response (~100ms, IRQs live). */
        for (d = 0; d < 100000UL; d++) {
            __NOP();
        }
        __disable_irq();
        rc = upg_do_flash_pages();
        if (rc == 0) {
            upg_unlock();
            FMC->ISPCON &= ~FMC_ISPCON_BS_Msk; /* boot APROM after reset */
            SYS->IPRSTC1 = SYS_IPRSTC1_CHIP_RST_Msk; /* Whole-chip reset */
            while (1) {
            }
        }
        __enable_irq();
        upg_state_v = UPG_STATE_ERROR;
        upg_err_v = (uint8_t)(0 - rc);
    }
}
