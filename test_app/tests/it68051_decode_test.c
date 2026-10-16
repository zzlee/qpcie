/* Pure software regression: no PCIe device or MMIO is accessed. */
#define main it68051_tool_main
#include "../qpcie_it68051_tool.c"
#undef main
#include <assert.h>

static void check_edid(const uint8_t *edid, uint8_t pa)
{
    for (int block = 0; block < 2; block++) {
        unsigned sum = 0;
        for (int i = 0; i < 128; i++) sum += edid[block*128 + i];
        assert((sum & 255) == 0);
    }
    assert(edid_pa_offset(edid) == pa);
    assert(edid[pa] == 0x10 && edid[pa+1] == 0);
}

int main(void)
{
    check_edid(g_sc710_edid, 0xA5);
    check_edid(g_sc710_edid_1080p, 0x99);
    uint8_t bad[256];
    memcpy(bad, g_sc710_edid_1080p, sizeof(bad));
    bad[130] = 0xFF;
    assert(edid_pa_offset(bad) == 0);
    memcpy(bad, g_sc710_edid_1080p, sizeof(bad));
    bad[132] = 0x7F; // VSDB length runs past the CTA data-block collection
    assert(edid_pa_offset(bad) == 0);

    uint8_t timing[24] = {0x08};
    const unsigned positions[] = {3, 5, 10, 12};
    const unsigned values[] = {4400, 3840, 2250, 2160};
    for (unsigned i = 0; i < 4; i++) {
        timing[positions[i]] = values[i];
        timing[positions[i]+1] = values[i] >> 8;
    }
    uint8_t avi[5] = {0x50, 0xA8, 0x04, 97, 0};
    assert(it68051_supported_uhd60(timing, avi));
    timing[0] = 0x48;
    assert(it68051_supported_uhd60(timing, avi));
    timing[0] = 0x58; // 10-bit deep color is not this profile
    assert(!it68051_supported_uhd60(timing, avi));
    timing[0] = 0x0A; // interlaced
    assert(!it68051_supported_uhd60(timing, avi));
    timing[0] = 8;
    avi[0] = 0x70; // YUV420 must not use the YUV444 geometry
    assert(!it68051_supported_uhd60(timing, avi));
    avi[0] = 0x50;
    avi[4] = 0x40; // full-range YUV requires a different CSC matrix
    assert(!it68051_supported_uhd60(timing, avi));
    avi[4] = 0;
    timing[6] = 0;
    assert(!it68051_supported_uhd60(timing, avi));
    assert(it68051_set_bank(NULL, 8) == -EINVAL);
    puts("PASS: EDID checksums/PA bounds and UHD profile validation");
    return 0;
}
