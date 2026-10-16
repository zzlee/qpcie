#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../hdmi_frame_stamp.h"

static void tag(uint8_t *p, uint32_t id, unsigned row)
{
    const uint8_t v[] = {0xA5, id, id >> 8, id >> 16, row, row >> 8,
                        ~id, ~(id >> 8), ~(id >> 16), ~row, ~(row >> 8), 0x5A};
    memcpy(p, v, sizeof(v));
}
int main(void)
{
    uint8_t frame[3 * 24] = {0};
    uint32_t id = 0, bad = 0;
    for (unsigned row=0; row<3; row++) tag(frame + row*24, 0x123456, row);
    assert(hdmi_stamp_check(frame,sizeof(frame),24,3,&id,&bad)==0 && id==0x123456);
    assert(hdmi_stamp_check(frame,sizeof(frame)-1,24,3,&id,&bad)==HDMI_STAMP_LAYOUT);
    frame[24] ^= 1;
    assert(hdmi_stamp_check(frame,sizeof(frame),24,3,&id,&bad)==HDMI_STAMP_TAG && bad==1);
    tag(frame+24,0x123456,2);
    assert(hdmi_stamp_check(frame,sizeof(frame),24,3,&id,&bad)==HDMI_STAMP_ROW);
    tag(frame+24,0x123457,1);
    assert(hdmi_stamp_check(frame,sizeof(frame),24,3,&id,&bad)==HDMI_STAMP_TORN);
    assert(hdmi_stamp_follows(1,2));
    assert(hdmi_stamp_follows(0xFFFFFF,0));
    assert(!hdmi_stamp_follows(1,1));
    assert(!hdmi_stamp_follows(1,3));
    puts("PASS: HDMI line/frame stamps reject corruption, row loss, tearing, duplicate/skipped IDs; wrap accepted");
    return 0;
}
