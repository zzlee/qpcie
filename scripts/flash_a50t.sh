#!/bin/bash
# ============================================================================
# Script: flash_a50t.sh
# Target FPGA: AMD/Xilinx Artix-7 A50T (xc7a50t-fgg484-2)
# Target Flash: Macronix MX25L12872F (mx25l12872f-spi-x1_x2_x4)
# Description: Automated Vivado batch script to convert bitstream to SPI bin
#              and flash Macronix MX25L12872F SPI Flash Memory.
# ============================================================================

set -e

export PATH="/opt/Xilinx/Vivado/2023.2/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -source scripts/program_flash_a50t.tcl
