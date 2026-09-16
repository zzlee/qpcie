#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VIVADO_BIN="/opt/Xilinx/Vivado/2023.2/bin/vivado"
if [ ! -x "$VIVADO_BIN" ]; then
    echo "Error: Vivado 2023.2 binary not found at $VIVADO_BIN"
    exit 1
fi

cd "$ROOT_DIR"
echo "Programming ZU4EV SC7F0 PCIe Bitstream via JTAG..."
"$VIVADO_BIN" -mode batch -source ./scripts/program_sram_zu4ev.tcl -nolog -nojournal
echo "Programming complete."
