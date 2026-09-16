#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VIVADO_BIN="/opt/Xilinx/Vivado/2023.2/bin/vivado"
if [ ! -x "$VIVADO_BIN" ]; then
    echo "Error: Vivado 2023.2 binary not found at $VIVADO_BIN"
    exit 1
fi

echo "=========================================================="
echo "  Building ZU4EV SC7F0 PCIe PIO Example Design (Vivado 2023.2)"
echo "=========================================================="

cd "$ROOT_DIR"

if [ ! -f "$ROOT_DIR/build/zu4ev_example_proj/pcie4_zu4ev_ex/pcie4_zu4ev_ex.xpr" ]; then
    echo "Step 1: Generating clean ZU4EV example project..."
    "$VIVADO_BIN" -mode batch -source ./scripts/generate_zu4ev_example.tcl -nolog -nojournal
fi

echo "Step 2: Synthesizing and implementing bitstream..."
"$VIVADO_BIN" -mode batch -source ./scripts/build_zu4ev_example.tcl -nolog -nojournal

echo "Done! Bitstream ready for testing on hardware."
