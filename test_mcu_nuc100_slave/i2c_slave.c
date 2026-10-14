/* Generic I2C slave engine (APROM app + LDROM console).
 * Pure transport: 0x2A registers; 0x2B + 0xAA prefix routes to upg.c.
 * serving on SLA+R, else regfile hooks (weak dummies; app overrides).
 */
#include "i2c_slave.h"
#include "upg.h"

__attribute__((weak)) uint8_t app_reg_read(uint8_t idx)
{
    (void)idx;
    return 0xFFU;
}

__attribute__((weak)) void app_reg_write(uint8_t idx, uint8_t val)
{
    (void)idx;
    (void)val;
}

static void ch_rx_byte(i2c_ch_t *ch, uint8_t dat)
{
    if (ch->upg) {
        if (ch->cmdlen < UPG_CMD_MAX) {
            ch->cmd[ch->cmdlen++] = dat;
        } else {
            ch->cmdlen = UPG_CMD_MAX + 1U;
        }
    } else if (ch->rx_len == 0U) {
            ch->ptr = (uint8_t)(dat & 0x0FU);
    } else {
        uint8_t idx = (uint8_t)(ch->ptr & 0x0FU);
        app_reg_write(idx, dat);
        ch->ptr = (uint8_t)((idx + 1U) & 0x0FU);
    }
    if (ch->rx_len != 0xFFU)
        ch->rx_len++;
}

static void ch_rx_end(i2c_ch_t *ch)
{
    if (ch->upg && ch->rx_len) {
        upg_resp_t r;
        upg_execute(ch->bus, ch->cmd, ch->cmdlen, &r);
        for (uint8_t i = 0; i < r.resp_len; i++)
            ch->resp[i] = r.resp[i];
        ch->resp_len = r.resp_len;
        ch->resp_idx = 0U;
    }
    ch->rx_len = 0U;
    ch->cmdlen = 0U;
}

static void ch_next_tx(i2c_ch_t *ch, I2C_T *i2c)
{
    if (ch->upg) {
        if (ch->resp_idx >= ch->resp_len) {
            i2c->I2CDAT = 0xFFU;
            return;
        }
        /* Pending upgrade response: serve once, then clear. */
        i2c->I2CDAT = ch->resp[ch->resp_idx];
        ch->resp_idx++;
        return;
    }
    i2c->I2CDAT = app_reg_read((uint8_t)(ch->ptr & 0x0FU));
    ch->ptr = (uint8_t)((ch->ptr + 1U) & 0x0FU);
}

void i2c_slave_isr(I2C_T *i2c, i2c_ch_t *ch)
{
    uint32_t status;

    if (i2c->I2CTOC & I2C_I2CTOC_TIF_Msk) {
        i2c->I2CTOC |= I2C_I2CTOC_TIF_Msk;
        ch->rx_len = 0U;
        ch->upg = 0U;
        ch->cmdlen = 0U;
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
        return;
    }
    status = i2c->I2CSTATUS;

    if (status == 0x60U) {              /* SLA+W, ACK returned */
        ch->rx_len = 0U;
        ch->cmdlen = 0U;
        ch->upg = ((i2c->I2CDAT >> 1) == UPG_ADDR);
        if (ch->upg) {
            ch->resp_len = 0U;
            ch->resp_idx = 0U;
        }
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0x80U) {       /* data received, ACK returned */
        ch_rx_byte(ch, (uint8_t)i2c->I2CDAT);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0x88U) {       /* data received, NACK returned */
        ch->rx_len = 0U;
        ch->upg = 0U;
        ch->cmdlen = 0U;
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xA8U) {       /* SLA+R, ACK returned */
        uint8_t address = (uint8_t)(i2c->I2CDAT >> 1);
        ch_rx_end(ch);
        ch->upg = (address == UPG_ADDR);
        ch->resp_idx = 0U;
        ch_next_tx(ch, i2c);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xB8U) {       /* data TXed, ACK received */
        ch_next_tx(ch, i2c);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xC0U) {       /* data TXed, NACK received: done */
        if (ch->upg) {
            ch->resp_len = 0U;
            ch->resp_idx = 0U;
        }
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if (status == 0xA0U) {       /* STOP or repeated START */
        ch_rx_end(ch);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else if ((status == 0x68U) || (status == 0xB0U)) {
        ch->rx_len = 0U;
        ch->upg = 0U;
        ch->cmdlen = 0U;
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
    } else {
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_STO_SI);
        I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI);
        ch->rx_len = 0U;
        ch->upg = 0U;
        ch->cmdlen = 0U;
    }
}

void i2c_slave_ch_init(I2C_T *i2c, i2c_ch_t *ch, uint8_t addr7)
{
    uint32_t div;

    i2c->I2CON |= I2C_I2CON_ENS1_Msk;

    SystemCoreClockUpdate();
    div = (SystemCoreClock / (100000UL * 4UL));
    if (div < 5UL)
        div = 5UL;
    i2c->I2CLK = (uint32_t)(div - 1UL);

    i2c->I2CADDR0 = (uint32_t)((uint32_t)addr7 << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADDR1 = (uint32_t)(UPG_ADDR << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADDR2 = (uint32_t)(0x7FUL << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADDR3 = (uint32_t)(0x7FUL << I2C_I2CADDR_I2CADDR_Pos);
    i2c->I2CADM0 = 0UL;
    i2c->I2CADM1 = 0UL;
    i2c->I2CADM2 = 0UL;
    i2c->I2CADM3 = 0UL;

    i2c->I2CON |= (I2C_I2CON_EI_Msk | I2C_I2CON_AA_Msk);

    ch->ptr = 0U;
    ch->rx_len = 0U;
    ch->upg = 0U;
    ch->bus = (i2c == I2C0) ? 0U : 1U;
    ch->cmdlen = 0U;
    ch->resp_len = 0U;
    ch->resp_idx = 0U;

    I2C_SET_CONTROL_REG(i2c, I2C_I2CON_SI_AA);
}
