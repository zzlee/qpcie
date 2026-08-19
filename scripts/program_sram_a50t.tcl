# ============================================================================
# Vivado TCL Script: program_sram_a50t.tcl
# Target FPGA: AMD/Xilinx Artix-7 A50T (xc7a50t-fgg484-2)
# Description: Direct JTAG SRAM bitstream loader for Artix-7 A50T card.
# ============================================================================

set bit_file "./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit"

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream file $bit_file does not exist!"
    exit 1
}

puts "================================================="
puts " 1. Connecting to JTAG Hardware Target"
puts "================================================="
open_hw_manager
connect_hw_server -allow_non_jtag

if {[catch {open_hw_target} err]} {
    puts "ERROR: Could not open HW Target: $err"
    exit 1
}

set hw_dev [lindex [get_hw_devices] 0]
if {$hw_dev == ""} {
    puts "ERROR: No JTAG hardware device found!"
    exit 1
}
current_hw_device $hw_dev
refresh_hw_device -update_hw_probes false $hw_dev

puts "================================================="
puts " 2. Loading Bitstream to FPGA SRAM ($hw_dev)"
puts "================================================="
set_property PROGRAM.FILE $bit_file $hw_dev
program_hw_devices $hw_dev

puts "================================================="
puts " 🎉 SUCCESS: Artix-7 A50T SRAM Programmed & Active!"
puts "================================================="

close_hw_target
close_hw_manager
