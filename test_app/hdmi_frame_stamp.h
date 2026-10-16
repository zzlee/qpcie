#ifndef QPCIE_HDMI_FRAME_STAMP_H
#define QPCIE_HDMI_FRAME_STAMP_H

#include <stddef.h>
#include <stdint.h>

enum hdmi_stamp_result {
    HDMI_STAMP_OK = 0, HDMI_STAMP_LAYOUT = -1, HDMI_STAMP_TAG = -2,
    HDMI_STAMP_ROW = -3, HDMI_STAMP_TORN = -4
};

/* Diagnostic pixels inserted before the HDMI CDC FIFO. The 24-bit ID counts
 * sampled RX VS edges, NOT DMA completions. This detects downstream loss;
 * an external source watermark is still needed to validate RX VS sampling. */
static inline int hdmi_stamp_check(const uint8_t *data, size_t length,
                                  uint32_t stride, uint32_t height,
                                  uint32_t *frame_id, uint32_t *bad_row)
{
    uint32_t first = 0;
    if (!data || !frame_id || !bad_row || stride < 12 || !height || height > 65536 ||
        stride > SIZE_MAX / height || length < (size_t)stride * height)
        return HDMI_STAMP_LAYOUT;
    for (uint32_t row = 0; row < height; row++) {
        const uint8_t *p = data + (size_t)row * stride;
        uint32_t id = p[1] | ((uint32_t)p[2] << 8) | ((uint32_t)p[3] << 16);
        *bad_row = row;
        if (p[0] != 0xA5 || p[11] != 0x5A ||
            (unsigned)p[6] + p[1] != 255 || (unsigned)p[7] + p[2] != 255 ||
            (unsigned)p[8] + p[3] != 255 || (unsigned)p[9] + p[4] != 255 ||
            (unsigned)p[10] + p[5] != 255)
            return HDMI_STAMP_TAG;
        if ((p[4] | ((uint32_t)p[5] << 8)) != row)
            return HDMI_STAMP_ROW;
        if (!row) first = id;
        else if (id != first) return HDMI_STAMP_TORN;
    }
    *frame_id = first;
    return HDMI_STAMP_OK;
}

static inline int hdmi_stamp_follows(uint32_t previous, uint32_t current)
{
    return current == ((previous + 1) & 0xFFFFFFu);
}
#endif
