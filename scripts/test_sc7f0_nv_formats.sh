#!/usr/bin/env bash
# Fast, byte-exact RTL regressions. No hardware access.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${SC7F0_NV_TEST_OUT:-build/validation/sc7f0-nv-formats}
mkdir -p "$OUT"
for sg in 0 1; do
for format in 2 3; do
    for geometry in '256 256' '384 512'; do
        read -r width stride <<< "$geometry"
        iverilog -g2012 -s tb_nv12_capture_engine \
            -Ptb_nv12_capture_engine.FORMAT="$format" \
            -Ptb_nv12_capture_engine.SG="$sg" \
            -Ptb_nv12_capture_engine.WIDTH="$width" \
            -Ptb_nv12_capture_engine.STRIDE="$stride" \
            -o "$OUT/nv_tb" rtl/nv12_capture_engine.v rtl/sg_segment_walker.v tb/tb_nv12_capture_engine.v
        vvp "$OUT/nv_tb"
    done
done
done
iverilog -g2012 -s video_rgb_to_yuv709_tb -o "$OUT/csc_tb" rtl/video_rgb_to_yuv709.v tb/video_rgb_to_yuv709_tb.sv
vvp "$OUT/csc_tb"
iverilog -g2012 -s thin_nv_formats_tb -o "$OUT/thin_tb" rtl/thin_desc_fetch_engine.v tb/thin_nv_formats_tb.sv
vvp "$OUT/thin_tb"
vvp "$OUT/thin_tb" +NV16
iverilog -g2012 -s thin_doorbell_order_tb -o "$OUT/doorbell_tb" rtl/thin_desc_fetch_engine.v tb/thin_doorbell_order_tb.sv
for args in '' '+UV_FIRST' '+NV16' '+NV16 +UV_FIRST'; do
    for geometry in '' '+UHD'; do
        vvp "$OUT/doorbell_tb" $args $geometry
    done
done
# The launch arbiter + format guard is what decides whether a frame reaches the
# thin walker at all (rtl/sc7f0_video_format_guard.v refuses a profile that is not
# the packed RGB24 single-plane format this build implements, and retires the frame
# through thin_frame_abort instead of leaving the walker waiting for a frame_done_in
# that a refused engine never sends).  This bench existed but no script ran it, so
# the guard/abort contract the RGB24 boot-time init depends on was unguarded; it is
# fast and green (checks=136 errors=0 as of 2026-11-17).
iverilog -g2012 -s tb_sc7f0_video_launch_arbiter -o "$OUT/launch_arb_tb" \
    rtl/sc7f0_video_launch_arbiter.v rtl/sc7f0_video_format_guard.v \
    rtl/thin_desc_fetch_engine.v rtl/sc7f0_rgb24_c2h_engine.v rtl/sg_segment_walker.v \
    tb/tb_sc7f0_video_launch_arbiter.sv
vvp "$OUT/launch_arb_tb"
iverilog -g2012 -s sc7f0_hdmi_pack_tb -o "$OUT/pack_tb" rtl/hdmi_rx_pixel_pack.v tb/sc7f0_hdmi_pack_tb.sv
vvp "$OUT/pack_tb"
