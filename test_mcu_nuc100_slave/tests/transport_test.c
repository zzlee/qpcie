#include <assert.h>
#include <stdio.h>
#include "i2c_slave.h"

mock_sys_t mock_sys;
mock_fmc_t mock_fmc;
I2C_T mock_i2c0, mock_i2c1;
uint32_t SystemCoreClock = 12000000;
void SystemCoreClockUpdate(void) {}
void NVIC_SystemReset(void) { assert(!"unexpected reset"); }
uint8_t upg_writer_ready(void) { return 0; }
static uint8_t regs[16];
uint8_t app_reg_read(uint8_t idx) { return regs[idx]; }
void app_reg_write(uint8_t idx, uint8_t value) { regs[idx] = value; }

static void event(I2C_T *hw, i2c_ch_t *ch, unsigned status, unsigned data)
{
    hw->I2CSTATUS = status;
    hw->I2CDAT = data;
    i2c_slave_isr(hw, ch);
}
static void hello(I2C_T *hw, i2c_ch_t *ch)
{
    /* Upgrade route: SLA+W (any address) + escape byte + CMD + STOP. */
    event(hw, ch, 0x60, 0x2A << 1);
    event(hw, ch, 0x80, UPG_ESCAPE_BYTE);
    event(hw, ch, 0x80, UPG_CMD_HELLO);
    event(hw, ch, 0xA0, 0);
}
int main(void)
{
    i2c_ch_t a = {0}, b = {0};
    regs[0] = 0x2A; /* MAGIC, so register fallback is observable */
    i2c_slave_ch_init(I2C0, &a, 0x2A);
    i2c_slave_ch_init(I2C1, &b, 0x2A);
    assert(I2C0->I2CADDR1 == (UPG_ADDR << 1)); /* 0x2B kept as hw alias */
    assert(I2C0->I2CADM1 == (1UL << I2C_I2CADM_I2CADM_Pos)); /* alias enabled */
    assert(a.bus == 0 && b.bus == 1);
    hello(I2C0, &a);
    assert(a.resp_len == 4 && !b.resp_len);
    event(I2C1, &b, 0xA8, (0x2A << 1) | 1);
    assert(I2C1->I2CDAT == 0x2A); /* bus b: plain register, no upg resp */
    event(I2C1, &b, 0xC0, 0);
    /* First byte 0xAA is a plain offset (0xAA & 0x0F = 0x0A), never escape. */
    event(I2C0, &a, 0x60, 0x2A << 1);
    event(I2C0, &a, 0x80, 0xAA);
    event(I2C0, &a, 0x80, 0x57);
    event(I2C0, &a, 0xA0, 0);
    assert(regs[10] == 0x57 && a.resp_len == 0); /* new W discards response */
    /* Escape with no command: engine answers CRCERR, not a crash. */
    event(I2C0, &a, 0x60, 0x2A << 1);
    event(I2C0, &a, 0x80, UPG_ESCAPE_BYTE);
    event(I2C0, &a, 0xA0, 0);
    assert(a.resp_len == 1 && a.resp[0] == UPG_ST_CRCERR);
    hello(I2C0, &a);
    event(I2C0, &a, 0xA8, (0x2A << 1) | 1);
    assert(I2C0->I2CDAT == UPG_PROTO_VER);
    for (unsigned i = 1; i < 4; i++) event(I2C0, &a, 0xB8, 0);
    event(I2C0, &a, 0xB8, 0);
    assert(I2C0->I2CDAT == 0xFF); /* no register fallback */
    event(I2C0, &a, 0xC0, 0);
    event(I2C0, &a, 0xA8, (0x2A << 1) | 1);
    assert(I2C0->I2CDAT == 0xFF); /* response consumed */
    event(I2C0, &a, 0xC0, 0);
    /* Same protocol at the 0x2B alias; overflow must yield CRCERR. */
    event(I2C0, &a, 0x60, UPG_ADDR << 1);
    event(I2C0, &a, 0x80, UPG_ESCAPE_BYTE);
    for (unsigned i = 0; i < 300; i++) event(I2C0, &a, 0x80, 1);
    event(I2C0, &a, 0xA0, 0);
    assert(a.resp_len == 1 && a.resp[0] == UPG_ST_CRCERR);
    hello(I2C1, &b);
    assert(b.resp_len == 4);
    event(I2C1, &b, 0xA8, (0x2A << 1) | 1);
    assert(I2C1->I2CDAT == UPG_PROTO_VER);
    event(I2C1, &b, 0xC0, 0); /* partial read retires response */
    assert(!b.resp_len);
    puts("PASS: escape routing on 0x2A/0x2B alias, bus isolation, response lifetime, overflow");
}
