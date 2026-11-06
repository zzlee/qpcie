#!/usr/bin/env bash
# Local hardware-design tests only. Never SSH, flash, reboot, or test MCU.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p build
OUT=${1:-$(mktemp -d "$ROOT/build/dual-video-tests.XXXXXXXX")}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
set +u
source "${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"
set -u
SC7F0_NV_TEST_OUT="$OUT/fast" bash scripts/test_sc7f0_nv_formats.sh > "$OUT/fast.log" 2>&1
for width in 128 256; do
    tb=tb/tb_rq_tx_encoder.v
    [[ $width != 256 ]] || tb=tb/tb_rq_tx_encoder_256.v
    top=$(basename "$tb" .v)
    iverilog -g2012 -s "$top" -o "$OUT/rq$width" rtl/rq_tx_encoder.v "$tb"
    vvp "$OUT/rq$width" > "$OUT/rq$width.log"
done
iverilog -g2012 -i -s sc7f0_packet_arb_tb -o "$OUT/arbiter" \
    rtl/custom_pcie_dma_top.v rtl/rq_tx_encoder.v tb/sc7f0_packet_arb_tb.sv
vvp "$OUT/arbiter" > "$OUT/arbiter.log"
grep -q PACKET_ARBITER_PASS "$OUT/arbiter.log"
SC7F0_SIM_OUT="$OUT/xsim-dualpath" vivado -mode batch -notrace -nojournal \
    -log "$OUT/dualpath-vivado.log" -source scripts/sim_sc7f0_dualpath.tcl > "$OUT/dualpath.log" 2>&1
grep -q DUALPATH_SIM_GATE_PASS "$OUT/dualpath.log"
! grep -Eq 'Fatal:|ERROR:|unknown value' "$OUT/dualpath.log"
vivado -mode batch -notrace -nojournal -log "$OUT/audio-vivado.log" \
    -source scripts/test_sc7f0_audio.tcl > "$OUT/audio.log" 2>&1
grep -q SC7F0_AUDIO_SIM_PASS "$OUT/audio.log"
printf 'SC7F0_DUAL_VIDEO_LOCAL_TEST_PASS\n' > "$OUT/tests.ok"
printf 'Local RTL tests PASS: %s (not implementation/hardware acceptance)\n' "$OUT"
