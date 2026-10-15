#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "NUC100Series.h"
#include "upg.h"

mock_sys_t mock_sys;
mock_fmc_t mock_fmc;
mock_clk_t mock_clk;
static unsigned commits;
void NVIC_SystemReset(void) { assert(!"unexpected reset"); }
uint8_t upg_role(void) { return UPG_ROLE_CONSOLE; }
int upg_request_flash(void) { commits++; return 0; }

static upg_resp_t command(const uint8_t *p, unsigned n)
{
    upg_resp_t r;
    upg_execute(0, p, n, &r);
    assert(r.resp_len);
    return r;
}

static unsigned chunk(unsigned off, const uint8_t *p, unsigned n)
{
    uint8_t cmd[37] = {UPG_CMD_CHUNK, off, off >> 8, n};
    memcpy(cmd + 4, p, n);
    cmd[4 + n] = upg_crc8(cmd + 1, n + 3);
    return command(cmd, n + 5).resp[0];
}

int main(void)
{
    uint8_t img[64], begin[7] = {UPG_CMD_BEGIN, 64, 0};
    memset(img, 0xA5, sizeof(img));
    uint32_t crc = upg_crc32(img, sizeof(img));
    for (unsigned i = 0; i < 4; i++) begin[3 + i] = crc >> (8 * i);
    assert(command(begin, 6).resp[0] == UPG_ST_CRCERR);
    assert(upg_state() == UPG_STATE_IDLE);
    assert(command(begin, 7).resp[0] == UPG_ST_OK);
    upg_resp_t other;
    upg_execute(1, begin, 7, &other);
    assert(other.resp[0] == UPG_ST_BUSY);
    uint8_t cancel = UPG_CMD_ABORT;
    upg_execute(1, &cancel, 1, &other);
    assert(other.resp[0] == UPG_ST_BUSY);
    assert(chunk(32, img + 32, 32) == UPG_ST_BADOFF);
    assert(upg_done() == 0);
    assert(chunk(0, img, 0) == UPG_ST_BADOFF);
    assert(chunk(0, img, 32) == UPG_ST_OK);
    assert(chunk(0, img, 32) == UPG_ST_OK); /* retry */
    img[0] ^= 1;
    assert(chunk(0, img, 32) == UPG_ST_BADOFF);
    img[0] ^= 1;
    uint8_t commit = UPG_CMD_COMMIT;
    assert(command(&commit, 1).resp[0] == UPG_ST_BADOFF);
    assert(commits == 0);
    uint8_t oversized[41] = {UPG_CMD_ABORT};
    assert(command(oversized, sizeof(oversized)).resp[0] == UPG_ST_CRCERR);
    assert(upg_done() == 32);
    assert(chunk(32, img + 32, 32) == UPG_ST_OK);
    assert(command(&commit, 1).resp[0] == UPG_ST_OK);
    assert(commits == 1);
    uint8_t abort_cmd = UPG_CMD_ABORT;
    assert(command(&abort_cmd, 1).resp[0] == UPG_ST_BUSY);
    puts("PASS: exact lengths, overflow, coverage, retries, commit/abort guards");
}
