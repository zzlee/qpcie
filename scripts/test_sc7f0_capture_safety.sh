#!/usr/bin/env bash
# Actual-XPM stop barriers + actual vendor CSC/framebuffer AXI drain evidence.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
OUT=$(realpath -m "${1:?NEW_OUTPUT IP_DIRECTORY}")
IP=$(realpath "${2:?NEW_OUTPUT IP_DIRECTORY}")
[[ ! -e "$OUT" ]] || { echo 'Refusing existing safety output' >&2; exit 1; }
mkdir -p "$OUT"
trap 'rc=$?; printf "%s\n" "$rc" > "$OUT/tests.exit"' EXIT
inputs=(rtl/sc7f0_dp_fifo.v rtl/sc7f0_gray64_sync.v rtl/sc7f0_tap_regs.v rtl/sc7f0_frame_tap.v rtl/sc7f0_capture_pipeline.v tb/sc7f0_tap_stop_ack_tb.sv tb/sc7f0_capture_pipeline_tb.sv scripts/sim_sc7f0_stop_ack.tcl scripts/sim_sc7f0_capture_pipeline.tcl scripts/test_sc7f0_capture_safety.sh)
inputs+=(tb/sc7f0_capture_pipeline_4k_tb.sv scripts/sim_sc7f0_capture_pipeline_4k.tcl)
for name in sc7f0_frmbuf_wr sc7f0_vpss_csc axi_clock_converter_0 sc7f0_capture_width; do
    path=$(realpath --relative-to="$ROOT" "$IP/$name/$name.xci")
    [[ $path != ../* ]] || { echo 'IP must be inside this repository' >&2; exit 1; }
    inputs+=("$path")
done
sha256sum "${inputs[@]}" > "$OUT/INPUTS.sha256"
export SC7F0_STOP_SIM_OUT="$OUT/stop"
VIVADO=${VIVADO:-/opt/Xilinx/Vivado/2023.2/bin/vivado}
"$VIVADO" -mode batch -notrace -nojournal -log "$OUT/stop-vivado.log" -source scripts/sim_sc7f0_stop_ack.tcl > "$OUT/stop.log" 2>&1
grep -q SC7F0_STOP_ACK_SIM_GATE_PASS "$OUT/stop.log"
export SC7F0_PIPE_SIM_OUT="$OUT/pipeline"
export SC7F0_FRMBUF_XCI="$IP/sc7f0_frmbuf_wr/sc7f0_frmbuf_wr.xci"
export SC7F0_CSC_XCI="$IP/sc7f0_vpss_csc/sc7f0_vpss_csc.xci"
export SC7F0_CLOCK_XCI="$IP/axi_clock_converter_0/axi_clock_converter_0.xci"
export SC7F0_WIDTH_XCI="$IP/sc7f0_capture_width/sc7f0_capture_width.xci"
"$VIVADO" -mode batch -notrace -nojournal -log "$OUT/pipeline-vivado.log" -source scripts/sim_sc7f0_capture_pipeline.tcl > "$OUT/pipeline.log" 2>&1
grep -q CAPTURE_PIPELINE_SIM_GATE_PASS "$OUT/pipeline.log"
export SC7F0_PIPE_SIM_OUT="$OUT/pipeline-4k"
export SC7F0_4K_IDEAL_DDR=0
"$VIVADO" -mode batch -notrace -nojournal -log "$OUT/pipeline-4k-vivado.log" -source scripts/sim_sc7f0_capture_pipeline_4k.tcl > "$OUT/pipeline-4k.log" 2>&1
grep -q CAPTURE_PIPELINE_4K_SIM_GATE_PASS "$OUT/pipeline-4k.log"
if grep -E 'Error:|Fatal:|ERROR:|FATAL:' "$OUT/stop.log" "$OUT/pipeline.log" "$OUT/pipeline-4k.log"; then exit 1; fi
sha256sum -c "$OUT/INPUTS.sha256" > "$OUT/source-check.log"
printf 'SC7F0_CAPTURE_SAFETY_PASS\n' > "$OUT/tests.ok"
echo "Capture safety evidence PASS: $OUT (not full-card or Linux runtime acceptance)"
