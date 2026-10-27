#include <assert.h>
#include "qpcie_hdmi_audio.h"
int main(void) {
    const char *info="Color Format: RGB\r\n Audio\n Format   : L-PCM\r\n Channels : 2\r\n ACR CTS  : 563063\n ACR N    : 5824\n";
    assert(qpcie_parse_hdmi_audio(info,594000000)==((2U<<16)|48000));
    assert(qpcie_parse_hdmi_audio(info,148500000)==0); /* incorrect TMDS ratio */
    assert(qpcie_parse_hdmi_audio(" Format : HBR\n Channels : 2\n ACR CTS : 563063\n ACR N : 5824\n",594000000)==0);
    for (unsigned ch=1;ch<=12;++ch) {
        char multichannel[160];
        snprintf(multichannel,sizeof(multichannel),
                 " Format : L-PCM\n Channels : %u\n ACR CTS : 563063\n ACR N : 5824\n",ch);
        uint32_t expected=(ch==2||ch==4||ch==6||ch==8)?((ch<<16)|48000):0;
        assert(qpcie_parse_hdmi_audio(multichannel,594000000)==expected);
    }
    assert(qpcie_parse_hdmi_audio(" Format : L-PCM\n Channels : 2\n",594000000)==0);
    assert(qpcie_parse_hdmi_audio(info,0)==0);
    puts("TB_PASS: PS HDMI audio telemetry parsing, ACR ratio and unsupported formats");
    return 0;
}
