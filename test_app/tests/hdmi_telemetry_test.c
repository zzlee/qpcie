/* Pure register-publication regression; no /dev/mem or hardware access. */
#define main qpcie_hdmi_daemon_main
#include "../qpcie_hdmi_daemon.c"
#undef main
#include <assert.h>

static void test_valid_snapshot(void)
{
    uint32_t regs[PL_MMAP_SIZE / sizeof(uint32_t)];
    uint32_t heartbeat = 0;
    struct rx_state state;

    memset(regs, 0xa5, sizeof(regs));
    regs[BAR0_REG_HDMI_TLM_SEQ / 4] = 0;
    memset(&state, 0, sizeof(state));
    state.timing_valid = true;
    state.color_valid = true;
    state.interlaced = true;
    state.timings.type = V4L2_DV_BT_656_1120;
    state.timings.bt.width = 3840;
    state.timings.bt.height = 2160;
    state.timings.bt.pixelclock = 594000000;
    state.timings.bt.hfrontporch = 176;
    state.timings.bt.hsync = 88;
    state.timings.bt.hbackporch = 296;
    state.timings.bt.vfrontporch = 8;
    state.timings.bt.vsync = 10;
    state.timings.bt.vbackporch = 72;
    state.timings.bt.polarities = 3;
    state.timings.bt.standards = V4L2_DV_BT_STD_CEA861;
    state.fmt.code = MEDIA_BUS_FMT_UYVY8_1X16;
    state.fmt.colorspace = V4L2_COLORSPACE_REC709;
    state.fmt.quantization = V4L2_QUANTIZATION_LIM_RANGE;
    state.fmt.ycbcr_enc = V4L2_YCBCR_ENC_709;
    state.fmt.xfer_func = V4L2_XFER_FUNC_709;

    publish_snapshot(regs, &state, &heartbeat);

    /* SEQ must be even and advance by exactly two per publication. */
    assert((regs[BAR0_REG_HDMI_TLM_SEQ / 4] & 1U) == 0);
    assert(regs[BAR0_REG_HDMI_TLM_SEQ / 4] == 2);
    assert(heartbeat == 1);
    assert(regs[BAR0_REG_HDMI_TLM_HEARTBEAT / 4] == 1);

    assert(regs[BAR0_REG_HDMI_RX_WIDTH / 4] == 3840);
    assert(regs[BAR0_REG_HDMI_RX_HEIGHT / 4] == 2160);
    assert(regs[BAR0_REG_HDMI_RX_PIXEL_CLK / 4] == (uint32_t)594000000);
    assert(regs[BAR0_REG_HDMI_TLM_PIXELCLK_HI / 4] == 0);
    assert(regs[BAR0_REG_HDMI_RX_HFP / 4] == 176);
    assert(regs[BAR0_REG_HDMI_RX_HSW / 4] == 88);
    assert(regs[BAR0_REG_HDMI_RX_HBP / 4] == 296);
    assert(regs[BAR0_REG_HDMI_RX_VFP / 4] == 8);
    assert(regs[BAR0_REG_HDMI_RX_VSW / 4] == 10);
    assert(regs[BAR0_REG_HDMI_RX_VBP / 4] == 72);
    assert(regs[BAR0_REG_HDMI_RX_POLARITIES / 4] == 3);
    assert(regs[BAR0_REG_HDMI_RX_STANDARDS / 4] == V4L2_DV_BT_STD_CEA861);
    assert(regs[BAR0_REG_HDMI_TLM_MBUS_CODE / 4] == MEDIA_BUS_FMT_UYVY8_1X16);

    uint32_t flags = regs[BAR0_REG_HDMI_TLM_FLAGS / 4];
    assert(flags & HDMI_TLM_F_TIMING_VALID);
    assert(flags & HDMI_TLM_F_COLOR_VALID);
    assert(flags & HDMI_TLM_F_INTERLACED);
    assert(!(flags & HDMI_TLM_F_QUERY_ERROR));

    uint32_t color = regs[BAR0_REG_HDMI_RX_COLOR_FMT / 4];
    assert((color & 0xffU) == V4L2_COLORSPACE_REC709);
    assert(((color >> 8) & 0xfU) == V4L2_QUANTIZATION_LIM_RANGE);
    assert(((color >> 12) & 0xfU) == V4L2_YCBCR_ENC_709);
    assert(((color >> 16) & 0xfU) == V4L2_XFER_FUNC_709);
    assert(((color >> 24) & 0xfU) == HDMI_COLOR_ENC_YUV422);

    /* The daemon must never write hardware-owned cable/HPD/lock bits. */
    assert(regs[BAR0_REG_HDMI_RX_STATUS / 4] == 0xa5a5a5a5);
    assert(regs[BAR0_REG_HDMI_TX_CTRL / 4] == 0xa5a5a5a5);
    assert(regs[BAR0_REG_HDMI_IPC_CMD / 4] == 0xa5a5a5a5);

    /* A second publication advances SEQ by two and the heartbeat by one. */
    publish_snapshot(regs, &state, &heartbeat);
    assert(regs[BAR0_REG_HDMI_TLM_SEQ / 4] == 4);
    assert(heartbeat == 2);
    assert(regs[BAR0_REG_HDMI_TLM_HEARTBEAT / 4] == 2);
}

static void test_invalid_snapshot_clears_payload(void)
{
    uint32_t regs[PL_MMAP_SIZE / sizeof(uint32_t)];
    uint32_t heartbeat = 0;
    struct rx_state state;

    memset(regs, 0xff, sizeof(regs));
    memset(&state, 0, sizeof(state));
    state.query_error = true;

    publish_snapshot(regs, &state, &heartbeat);

    assert((regs[BAR0_REG_HDMI_TLM_SEQ / 4] & 1U) == 0);
    assert(regs[BAR0_REG_HDMI_TLM_FLAGS / 4] == HDMI_TLM_F_QUERY_ERROR);
    assert(regs[BAR0_REG_HDMI_RX_WIDTH / 4] == 0);
    assert(regs[BAR0_REG_HDMI_RX_HEIGHT / 4] == 0);
    assert(regs[BAR0_REG_HDMI_RX_PIXEL_CLK / 4] == 0);
    assert(regs[BAR0_REG_HDMI_TLM_PIXELCLK_HI / 4] == 0);
    assert(regs[BAR0_REG_HDMI_TLM_MBUS_CODE / 4] == 0);
    assert(regs[BAR0_REG_HDMI_RX_COLOR_FMT / 4] == 0);
    assert(regs[BAR0_REG_HDMI_RX_STATUS / 4] == 0xffffffff);
}

static void test_recovers_torn_sequence(void)
{
    uint32_t regs[PL_MMAP_SIZE / sizeof(uint32_t)];
    uint32_t heartbeat = 7;
    struct rx_state state;

    memset(regs, 0, sizeof(regs));
    memset(&state, 0, sizeof(state));
    regs[BAR0_REG_HDMI_TLM_SEQ / 4] = 41; /* killed mid-update */

    publish_snapshot(regs, &state, &heartbeat);

    assert(regs[BAR0_REG_HDMI_TLM_SEQ / 4] == 44);
    assert((regs[BAR0_REG_HDMI_TLM_SEQ / 4] & 1U) == 0);
    assert(heartbeat == 8);
}

int main(void)
{
    test_valid_snapshot();
    test_invalid_snapshot_clears_payload();
    test_recovers_torn_sequence();
    puts("HDMI telemetry tests passed");
    return 0;
}
