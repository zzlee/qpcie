#!/bin/bash
# ============================================================================
# run_tb.sh - Icarus Verilog regression runner for QPCIe testbenches
#
# Usage:
#   bash docker/run_tb.sh                      # run the full unit test-suite
#   bash docker/run_tb.sh <tb_name>            # run a single testbench
#   bash docker/run_tb.sh sg_                  # run every testbench containing "sg_"
#
# Notes:
#   * Mirrors the TESTS table from sim/run_sim.sh (Vivado xsim) but runs with
#     the open-source Icarus Verilog simulator (iverilog + vvp).
#   * The full RTL set is always pre-pended so missing-module errors (e.g.
#     run_sim.sh's latent omission of sg_segment_walker.v) can not occur.
#   * -s <tb_top> scopes elaboration to the testbench hierarchy, so the
#     Xilinx XPM primitives inside custom_pcie_dma_top.v are only required
#     for the system-level tests that actually instantiate it (see xpm/).
#   * Xilinx XPM primitives used by the system-level tests
#     (xpm_fifo_async, xpm_cdc_handshake) are provided as behavioral sim
#     models in docker/xpm/ (xpm_*_sim.v). Drop the real Vivado simulation
#     sources (xpm_cdc.sv / xpm_fifo.sv / xpm_memory.sv) into docker/xpm/
#     and they will be preferred automatically.
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FILTER="${1:-}"
SIM_DIR="${TMPDIR:-/tmp}/qpcie_tb_iverilog"
mkdir -p "$SIM_DIR"

cd "$ROOT_DIR" || exit 1

TESTS=(
    "tb_pcie_tag_manager        tb/tb_pcie_tag_manager.v"
    "tb_cq_rx_decoder           rtl/cq_rx_decoder.v tb/tb_cq_rx_decoder.v"
    "tb_cc_tx_encoder           rtl/cc_tx_encoder.v tb/tb_cc_tx_encoder.v"
    "tb_axil_reg_space          rtl/axil_reg_space.v tb/tb_axil_reg_space.v"
    "tb_rq_tx_encoder           rtl/rq_tx_encoder.v tb/tb_rq_tx_encoder.v"
    "tb_rc_rx_decoder           rtl/rc_rx_decoder.v tb/tb_rc_rx_decoder.v"
    "tb_desc_fetch_engine       rtl/desc_fetch_engine.v tb/tb_desc_fetch_engine.v"
    "tb_h2c_dma_engine          rtl/h2c_dma_engine.v tb/tb_h2c_dma_engine.v"
    "tb_c2h_dma_engine          rtl/c2h_dma_engine.v tb/tb_c2h_dma_engine.v"
    "tb_interrupt_ctrl          rtl/interrupt_ctrl.v tb/tb_interrupt_ctrl.v"
    "tb_sg_dma_engine           rtl/sg_dma_engine.v rtl/sg_segment_walker.v tb/tb_sg_dma_engine.v"
    "tb_sg_c2h_burst_boundary   rtl/sg_dma_engine.v rtl/rq_tx_encoder.v rtl/sg_segment_walker.v tb/tb_sg_c2h_burst_boundary.v"
    "tb_nv12_capture_engine     rtl/sg_segment_walker.v rtl/nv12_capture_engine.v tb/tb_nv12_capture_engine.v"
    "tb_nv12_capture_performance rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/rq_tx_encoder.v tb/tb_nv12_capture_performance.v"
    "tb_nv12_capture_4k_performance rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/rq_tx_encoder.v tb/tb_nv12_capture_4k_performance.v"
    "tb_video_cdc_system        rtl/global_timer.v rtl/dma_telemetry.v rtl/qpcie_perfmon.v rtl/video_stream_engine.v rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/audio_stream_engine.v rtl/axil_reg_space.v rtl/c2h_dma_engine.v rtl/h2c_dma_engine.v rtl/desc_fetch_engine.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/pcie_tag_manager.v rtl/interrupt_ctrl.v rtl/sg_dma_engine.v rtl/sg_host_fetch_engine.v rtl/video_req_cdc.v rtl/custom_pcie_dma_top.v rtl/pcie_7x_axi_bridge.v tb/tb_video_cdc_system.v"
    "tb_pcie_dma_system         rtl/global_timer.v rtl/dma_telemetry.v rtl/qpcie_perfmon.v rtl/video_stream_engine.v rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/audio_stream_engine.v rtl/axil_reg_space.v rtl/c2h_dma_engine.v rtl/h2c_dma_engine.v rtl/desc_fetch_engine.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/pcie_tag_manager.v rtl/interrupt_ctrl.v rtl/sg_dma_engine.v rtl/sg_host_fetch_engine.v rtl/video_req_cdc.v rtl/custom_pcie_dma_top.v tb/tb_pcie_dma_system.v"
    "tb_sg_segment_walker       rtl/sg_segment_walker.v tb/tb_sg_segment_walker.v"
    "tb_sg_host_fetch_engine    rtl/sg_host_fetch_engine.v tb/tb_sg_host_fetch_engine.v"
    "tb_pcie_7x_axi_bridge      rtl/pcie_7x_axi_bridge.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/axil_reg_space.v rtl/desc_fetch_engine.v tb/tb_pcie_7x_axi_bridge.v"
    "tb_sg_dma_pipeline         rtl/global_timer.v rtl/dma_telemetry.v rtl/qpcie_perfmon.v rtl/video_stream_engine.v rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/audio_stream_engine.v rtl/axil_reg_space.v rtl/c2h_dma_engine.v rtl/h2c_dma_engine.v rtl/desc_fetch_engine.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/pcie_tag_manager.v rtl/interrupt_ctrl.v rtl/sg_dma_engine.v rtl/sg_host_fetch_engine.v rtl/video_req_cdc.v rtl/custom_pcie_dma_top.v rtl/pcie_7x_axi_bridge.v tb/tb_sg_dma_pipeline.v"
)

RTL_ALL=$(ls rtl/*.v 2>/dev/null | grep -v 'card_top\|tlp_test')

XPM_SRCS=""
REAL_XPM=$(ls "$SCRIPT_DIR"/xpm/xpm_*.sv 2>/dev/null)
if [ -n "$REAL_XPM" ]; then
    XPM_SRCS="$REAL_XPM"
else
    XPM_SRCS=$(ls "$SCRIPT_DIR"/xpm/xpm_*_sim.v 2>/dev/null)
fi
SYSTEM_TB="tb_video_cdc_system tb_pcie_dma_system tb_sg_dma_pipeline"

PASSED=0
FAILED=0
SKIPPED=0

for TEST in "${TESTS[@]}"; do
    TB_NAME=$(echo "$TEST" | cut -d' ' -f1)
    FILES=$(echo "$TEST" | cut -d' ' -f2-)

    if [ -n "$FILTER" ]; then
        case "$TB_NAME" in
            *"$FILTER"*) ;;
            *) continue ;;
        esac
    fi

    if [ -z "$XPM_SRCS" ] && [[ " $SYSTEM_TB " == *" $TB_NAME "* ]]; then
        echo "$TB_NAME : SKIP (needs XPM sources/sim models in docker/xpm/)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    COMPILE_FILES=$(echo "$RTL_ALL $FILES" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
    VVP="$SIM_DIR/$TB_NAME.vvp"
    LOG="$SIM_DIR/$TB_NAME.log"

    echo -n "$TB_NAME ... "
    if timeout 180s iverilog -g2012 -s "$TB_NAME" -o "$VVP" $XPM_SRCS $COMPILE_FILES > "$LOG" 2>&1 &&
       timeout 600s vvp "$VVP" >> "$LOG" 2>&1 &&
       grep -Eq "PASSED|SUCCESS|VERIFIED 100% PASS" "$LOG"; then
        echo "[PASS]"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL]"
        FAILED=$((FAILED + 1))
    fi
done

echo "=============================================================="
echo " Icarus Verilog Summary: $PASSED passed, $FAILED failed, $SKIPPED skipped"
echo " Logs: $SIM_DIR"
echo "=============================================================="

if [ $FAILED -ne 0 ]; then
    exit 1
fi