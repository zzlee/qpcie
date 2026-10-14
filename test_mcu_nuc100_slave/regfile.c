/* Shared control regfile implementation. */
#include "regfile.h"
#include "NUC100Series.h"

static volatile uint8_t g_reg[REG_NUM];

static void apply_ctrl(uint8_t ctrl)
{
    if (ctrl & 0x01U)
        PB->DOUT |= (1UL << 10);
    else
        PB->DOUT &= ~(1UL << 10);

    if (ctrl & 0x02U)
        PB->DOUT |= (1UL << 15);
    else
        PB->DOUT &= ~(1UL << 15);
}

static uint8_t live_status(void)
{
    uint8_t st = 0;
    uint32_t pa = PA->PIN;
    uint32_t pb = PB->DOUT;

    if (pa & (1UL << 12))
        st |= 0x01U;
    if (pa & (1UL << 13))
        st |= 0x02U;
    if (pb & (1UL << 10))
        st |= 0x04U;
    if (pb & (1UL << 15))
        st |= 0x08U;
    return st;
}

void regfile_init(uint8_t ver, uint8_t ctrl_default)
{
    uint32_t i;
    for (i = 0; i < REG_NUM; i++)
        g_reg[i] = 0U;
    g_reg[REG_MAGIC] = 0x2AU;
    g_reg[REG_VER] = ver;
    g_reg[REG_CTRL] = ctrl_default;
    apply_ctrl(ctrl_default);
}

uint8_t regfile_ctrl(void)
{
    return g_reg[REG_CTRL];
}

uint8_t app_reg_read(uint8_t idx)
{
    idx &= 0x0FU;
    if (idx == REG_STATUS)
        return live_status();
    return g_reg[idx];
}

void app_reg_write(uint8_t idx, uint8_t val)
{
    idx &= 0x0FU;
    if (idx < REG_CTRL)
        return; /* 0x00/0x01/0x02 read-only */
    g_reg[idx] = val;
    if (idx == REG_CTRL)
        apply_ctrl(val);
}
