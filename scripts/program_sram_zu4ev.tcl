# ============================================================================
# Vivado TCL Script: program_sram_zu4ev.tcl
# Target FPGA: AMD/Xilinx Zynq UltraScale+ XCZU4EV (xczu4ev-fbvb900-2-e)
# Description: Direct JTAG SRAM bitstream loader for ZU4EV SC7F0 PCIe card.
# ============================================================================

set bit_file "./build/zu4ev_example_proj/pcie4_zu4ev_ex/pcie4_zu4ev_ex.runs/impl_1/xilinx_pcie4_uscale_ep.bit"

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream file $bit_file does not exist! Run scripts/build_zu4ev_example.sh first."
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

# In Zynq UltraScale+, there are multiple devices on JTAG chain (e.g. arm_dap, xczu4ev)
set hw_dev [lindex [get_hw_devices -filter {NAME =~ "*xczu4ev*"}] 0]
if {$hw_dev == ""} {
    # Fallback to second device or first
    set dev_list [get_hw_devices]
    puts "Available devices: $dev_list"
    if {[llength $dev_list] >= 2} {
        set hw_dev [lindex $dev_list 1]
    } else {
        set hw_dev [lindex $dev_list 0]
    }
}

if {$hw_dev == ""} {
    puts "ERROR: No JTAG hardware device found!"
    exit 1
}

puts "Targeting device: $hw_dev"
current_hw_device $hw_dev
refresh_hw_device -update_hw_probes false $hw_dev

puts "================================================="
puts " 2. Loading Bitstream to ZU4EV FPGA ($hw_dev)"
puts "================================================="
set_property PROGRAM.FILE $bit_file $hw_dev
program_hw_devices $hw_dev

puts "================================================="
puts " 🎉 SUCCESS: ZU4EV SC7F0 PCIe Bitstream Programmed!"
puts "================================================="

close_hw_target
close_hw_manager
exit 0
