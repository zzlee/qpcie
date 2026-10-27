/* PS-only control-plane parsing. This is NOT an audio DMA/PS DDR path.
 * Vendor hdmi_info exposes actual audio coding/channels and ACR N/CTS.
 * Host PCM ABI extracts Front L/R (TID0/1) from 2/4/6/8ch 48k LPCM.
 * Publish SOURCE channel count truthfully; the host output remains stereo.
 * Sample word length is deliberately UNKNOWN (0), not hardcoded 24-bit.
 */
#ifndef QPCIE_HDMI_AUDIO_H
#define QPCIE_HDMI_AUDIO_H
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static uint32_t qpcie_parse_hdmi_audio(const char *info, uint64_t pixelclock)
{
    unsigned channels=0, n=0, cts=0;
    int pcm=0;
    const char *p=info;
    while (p && *p) {
        char line[256];
        size_t len=strcspn(p,"\n");
        if (len < sizeof(line)) {
            memcpy(line,p,len); line[len]=0;
            char format[64];
            if (sscanf(line," Format : %63s",format)==1)
                pcm=strcmp(format,"L-PCM")==0;
            (void)sscanf(line," Channels : %u",&channels);
            (void)sscanf(line," ACR N : %u",&n);
            (void)sscanf(line," ACR CTS : %u",&cts);
        }
        p=strchr(p,'\n'); if (p) ++p;
    }
    if (!pcm || (channels!=2 && channels!=4 && channels!=6 && channels!=8) ||
        !n || !cts || !pixelclock) return 0;
    uint64_t rate=(pixelclock*n + 64ULL*cts)/(128ULL*cts);
    if (rate < 47900 || rate > 48100) return 0;
    return (channels<<16)|48000;
}
#endif
