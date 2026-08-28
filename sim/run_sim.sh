#!/bin/bash
# ============================================================================
# Script: run_sim.sh
# Description: Automated compilation and simulation runner using Vivado xsim
# ============================================================================

set -e
set -o pipefail

export XILINX_VIVADO="/opt/Xilinx/Vivado/2023.2"
export PATH="/opt/Xilinx/Vivado/2023.2/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "================================================================="
echo " Building & Simulating Custom PCIe AXI4-Stream DMA Project"
echo "================================================================="

mkdir -p work_sim
RUN_DIR="$ROOT_DIR/work_sim/run-$$"
SIM_WORK="$RUN_DIR/work"
mkdir -p "$SIM_WORK"

# XPM CDC library source (needed by custom_pcie_dma_top's descriptor and
# telemetry handshakes in system-level testbenches).
XPM_CDC_SV="/opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv"
XPM_FIFO_SV="/opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv"
XPM_MEMORY_SV="/opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv"

TESTS=(
    "tb_pcie_tag_manager rtl/pcie_tag_manager.v tb/tb_pcie_tag_manager.v"
    "tb_cq_rx_decoder rtl/cq_rx_decoder.v tb/tb_cq_rx_decoder.v"
    "tb_cc_tx_encoder rtl/cc_tx_encoder.v tb/tb_cc_tx_encoder.v"
    "tb_axil_reg_space rtl/axil_reg_space.v tb/tb_axil_reg_space.v"
    "tb_rq_tx_encoder rtl/rq_tx_encoder.v tb/tb_rq_tx_encoder.v"
    "tb_rc_rx_decoder rtl/rc_rx_decoder.v tb/tb_rc_rx_decoder.v"
    "tb_desc_fetch_engine rtl/desc_fetch_engine.v tb/tb_desc_fetch_engine.v"
    "tb_h2c_dma_engine rtl/h2c_dma_engine.v tb/tb_h2c_dma_engine.v"
    "tb_c2h_dma_engine rtl/c2h_dma_engine.v tb/tb_c2h_dma_engine.v"
    "tb_interrupt_ctrl rtl/interrupt_ctrl.v tb/tb_interrupt_ctrl.v"
    "tb_sg_dma_engine rtl/sg_dma_engine.v tb/tb_sg_dma_engine.v"
    "tb_sg_c2h_burst_boundary rtl/sg_dma_engine.v rtl/rq_tx_encoder.v tb/tb_sg_c2h_burst_boundary.v"
    "tb_nv12_capture_engine rtl/sg_segment_walker.v rtl/nv12_capture_engine.v tb/tb_nv12_capture_engine.v"
    "tb_nv12_capture_performance rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/rq_tx_encoder.v tb/tb_nv12_capture_performance.v"
    "tb_nv12_capture_4k_performance rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/rq_tx_encoder.v tb/tb_nv12_capture_4k_performance.v"
    "tb_video_cdc_system rtl/global_timer.v rtl/dma_telemetry.v rtl/qpcie_perfmon.v rtl/video_stream_engine.v rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/audio_stream_engine.v rtl/axil_reg_space.v rtl/c2h_dma_engine.v rtl/h2c_dma_engine.v rtl/desc_fetch_engine.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/pcie_tag_manager.v rtl/interrupt_ctrl.v rtl/sg_dma_engine.v rtl/sg_host_fetch_engine.v rtl/video_req_cdc.v rtl/custom_pcie_dma_top.v rtl/pcie_7x_axi_bridge.v tb/tb_video_cdc_system.v"
    "tb_pcie_dma_system rtl/global_timer.v rtl/dma_telemetry.v rtl/qpcie_perfmon.v rtl/video_stream_engine.v rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/audio_stream_engine.v rtl/axil_reg_space.v rtl/c2h_dma_engine.v rtl/h2c_dma_engine.v rtl/desc_fetch_engine.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/pcie_tag_manager.v rtl/interrupt_ctrl.v rtl/sg_dma_engine.v rtl/sg_host_fetch_engine.v rtl/video_req_cdc.v rtl/custom_pcie_dma_top.v tb/tb_pcie_dma_system.v"
    "tb_sg_segment_walker rtl/sg_segment_walker.v tb/tb_sg_segment_walker.v"
    "tb_sg_host_fetch_engine rtl/sg_host_fetch_engine.v tb/tb_sg_host_fetch_engine.v"
    "tb_pcie_7x_axi_bridge rtl/pcie_7x_axi_bridge.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/axil_reg_space.v rtl/desc_fetch_engine.v tb/tb_pcie_7x_axi_bridge.v"
    "tb_sg_dma_pipeline rtl/global_timer.v rtl/dma_telemetry.v rtl/qpcie_perfmon.v rtl/video_stream_engine.v rtl/sg_segment_walker.v rtl/nv12_capture_engine.v rtl/audio_stream_engine.v rtl/axil_reg_space.v rtl/c2h_dma_engine.v rtl/h2c_dma_engine.v rtl/desc_fetch_engine.v rtl/cq_rx_decoder.v rtl/cc_tx_encoder.v rtl/rq_tx_encoder.v rtl/rc_rx_decoder.v rtl/pcie_tag_manager.v rtl/interrupt_ctrl.v rtl/sg_dma_engine.v rtl/sg_host_fetch_engine.v rtl/video_req_cdc.v rtl/custom_pcie_dma_top.v rtl/pcie_7x_axi_bridge.v tb/tb_sg_dma_pipeline.v"
)

# Use a private simulator library for every invocation. Multiple sessions may
# run regressions in the same checkout, and XSim otherwise blocks indefinitely
# on the shared xsim.dir/work library. Precompile complete RTL/XPM contents so
RTL_FILES=$(ls rtl/*.v | grep -v 'card_top\|tlp_test')
timeout 600s xvlog --work work="$SIM_WORK" --sv \
    $RTL_FILES "$XPM_CDC_SV" "$XPM_FIFO_SV" "$XPM_MEMORY_SV" \
    "$XILINX_VIVADO/data/verilog/src/glbl.v" > /dev/null 2>&1

PASSED=0
FAILED=0

for TEST in "${TESTS[@]}"; do
    TB_NAME=$(echo $TEST | cut -d' ' -f1)
    FILES=$(echo $TEST | cut -d' ' -f2-)

    echo -n "Running $TB_NAME ... "
    
    SIM_LOG="$ROOT_DIR/work_sim/${TB_NAME}.log"
    if timeout 600s xvlog --work work="$SIM_WORK" --sv $FILES > /dev/null 2>&1 && \
       (cd "$RUN_DIR" && timeout 600s xelab -L work="$SIM_WORK" $TB_NAME work.glbl -s sim_$TB_NAME > /dev/null 2>&1) && \
       (cd "$RUN_DIR" && timeout 300s xsim sim_$TB_NAME -R > "$SIM_LOG" 2>&1) && \
       grep -Eq "PASSED|SUCCESS|VERIFIED 100% PASS" "$SIM_LOG"; then
        echo "[PASS]"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL]"
        FAILED=$((FAILED + 1))
    fi
done

echo "================================================================="
echo " Simulation Summary: $PASSED Passed, $FAILED Failed"
echo "================================================================="

if [ $FAILED -ne 0 ]; then
    exit 1
fi
