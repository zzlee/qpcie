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
iverilog -g2012 -s sc7f0_hdmi_pack_tb -o "$OUT/pack_tb" rtl/hdmi_rx_pixel_pack.v tb/sc7f0_hdmi_pack_tb.sv
vvp "$OUT/pack_tb"
