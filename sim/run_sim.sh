#!/bin/bash
# ============================================================================
# Script: run_sim.sh
# Description: Automated compilation and simulation runner using Vivado xsim
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "================================================================="
echo " Building & Simulating Custom PCIe AXI4-Stream DMA Project"
echo "================================================================="

mkdir -p work_sim

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
    "tb_pcie_dma_system rtl/*.v tb/tb_pcie_dma_system.v"
)

PASSED=0
FAILED=0

for TEST in "${TESTS[@]}"; do
    TB_NAME=$(echo $TEST | cut -d' ' -f1)
    FILES=$(echo $TEST | cut -d' ' -f2-)

    echo -n "Running $TB_NAME ... "
    
    if xvlog $FILES > /dev/null 2>&1 && xelab $TB_NAME -s sim_$TB_NAME > /dev/null 2>&1 && xsim sim_$TB_NAME -R | grep -q "PASSED\|SUCCESS"; then
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
