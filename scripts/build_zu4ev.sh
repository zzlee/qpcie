#!/bin/bash
# ============================================================================
# Script: build_zu4ev.sh
# Target Board: SC7F0 N1 HDMI2 V11
# Target FPGA: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
# Description: Clean and build the ZU4EV PCIe AV DMA Card Tandem bitstreams
# ============================================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$ROOT_DIR/build/qpcie_zu4ev_proj"

source /opt/Xilinx/Vivado/2023.2/settings64.sh

rm -rf "$PROJECT_DIR"

cd "$ROOT_DIR"
vivado -mode batch -source scripts/build_zu4ev.tcl -nolog -nojournal

echo "ZU4EV Build finished."
