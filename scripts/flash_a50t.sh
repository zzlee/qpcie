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

BIT_FILE="$ROOT_DIR/build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit"
BIN_FILE="$ROOT_DIR/build/a50t_pcie_card_top.bin"
FLASH_PART="mx25l12872f-spi-x1_x2_x4"

if [ ! -f "$BIT_FILE" ]; then
    echo "ERROR: Bitstream file not found at $BIT_FILE"
    exit 1
fi

echo "================================================================="
echo " 1. Generating SPI Flash BIN Configuration File (Quad SPI x4)"
echo "================================================================="
vivado -mode batch -eval "
  write_cfgmem -format bin -size 16 -interface SPIx4 \
    -loadbit \"up 0x00000000 $BIT_FILE\" \
    -file $BIN_FILE -force
"

echo "================================================================="
echo " 2. Programming Macronix MX25L12872F SPI Flash via Vivado HW Manager"
echo "================================================================="
vivado -mode batch -eval "
  open_hw_manager
  connect_hw_server -allow_non_jtag
  open_hw_target
  create_hw_cfgmem -hw_device [current_hw_device] -mem_dev [lindex [get_cfgmem_parts {$FLASH_PART}] 0]
  set_property PROGRAM.BLANK_CHECK  0 [get_property PROGRAM.HW_CFGMEM [current_hw_device]]
  set_property PROGRAM.ERASE        1 [get_property PROGRAM.HW_CFGMEM [current_hw_device]]
  set_property PROGRAM.CFG_PROGRAM  1 [get_property PROGRAM.HW_CFGMEM [current_hw_device]]
  set_property PROGRAM.VERIFY       1 [get_property PROGRAM.HW_CFGMEM [current_hw_device]]
  set_property PROGRAM.CHECKSUM     0 [get_property PROGRAM.HW_CFGMEM [current_hw_device]]
  set_property PROGRAM.FILES [list \"$BIN_FILE\"] [get_property PROGRAM.HW_CFGMEM [current_hw_device]]
  program_hw_devices [current_hw_device]
  program_hw_cfgmem -hw_cfgmem [get_property PROGRAM.HW_CFGMEM [current_hw_device]]
  close_hw_target
  close_hw_manager
"

echo "================================================================="
echo " SUCCESS: Artix-7 A50T Flash ($FLASH_PART) Programmed Successfully!"
echo "================================================================="
