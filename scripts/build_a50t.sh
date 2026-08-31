#!/bin/bash
# ============================================================================
# Script: build_a50t.sh
# Target FPGA: AMD/Xilinx Artix-7 A50T (xc7a50t-csg325-2)
# Description: Clean and build the A50T PCIe card bitstream with Vivado 2023.2.
# ============================================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$ROOT_DIR/build/qpcie_a50t_proj"
BITSTREAM="$PROJECT_DIR/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit"

source /opt/Xilinx/Vitis/2023.2/settings64.sh

rm -rf "$PROJECT_DIR"

cd "$ROOT_DIR"
vivado -mode batch -source scripts/build_a50t.tcl

if [[ ! -s "$BITSTREAM" ]]; then
    echo "ERROR: Bitstream was not generated: $BITSTREAM" >&2
    exit 1
fi

echo "Bitstream built successfully: $BITSTREAM"
