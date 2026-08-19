# ============================================================================
# Vivado TCL Script: program_flash_a50t.tcl
# Target FPGA: AMD/Xilinx Artix-7 A50T (xc7a50t-fgg484-2)
# Target Flash: Macronix MX25L12872F (mx25l12872f-spi-x1_x2_x4)
# Formatted exactly from user's successful Vivado GUI Log
# ============================================================================

set bit_file "./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit"
set bin_file "/home/zzlee/qpcie/build/a50t_pcie_card_top_spix1.bin"

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream file $bit_file does not exist!"
    exit 1
}

puts "================================================="
puts " 1. Generating SPI Flash BIN File (SPIx1)"
puts "================================================="
write_cfgmem -format bin -size 16 -interface SPIx1 -loadbit "up 0x00000000 $bit_file" -file $bin_file -force

puts "================================================="
puts " 2. Connecting to Hardware Server & Target"
puts "================================================="
open_hw_manager
connect_hw_server -allow_non_jtag

if {[catch {open_hw_target} err]} {
    puts "-------------------------------------------------"
    puts "WARNING: Could not open HW Target: $err"
    puts "BIN file generated successfully at: $bin_file"
    puts "-------------------------------------------------"
    exit 1
}

set dev [lindex [get_hw_devices xc7a50t_0] 0]
if {$dev == ""} {
    set dev [lindex [get_hw_devices] 0]
}
if {$dev == ""} {
    puts "ERROR: No JTAG hardware device found!"
    exit 1
}

current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

puts "================================================="
puts " 3. Setting Up Flash Device mx25l12872f-spi-x1_x2_x4"
puts "================================================="
catch { delete_hw_cfgmem -quiet [get_property HW_CFGMEM $dev] }

create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mx25l12872f-spi-x1_x2_x4}] 0]

set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.BLANK_CHECK  0 $cfgmem
set_property PROGRAM.ERASE        1 $cfgmem
set_property PROGRAM.CFG_PROGRAM  1 $cfgmem
set_property PROGRAM.VERIFY       1 $cfgmem
set_property PROGRAM.CHECKSUM     0 $cfgmem

refresh_hw_device $dev

set_property PROGRAM.ADDRESS_RANGE {use_file} $cfgmem
set_property PROGRAM.FILES [list $bin_file] $cfgmem
set_property PROGRAM.PRM_FILE {} $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem
set_property PROGRAM.BLANK_CHECK  0 $cfgmem
set_property PROGRAM.ERASE        1 $cfgmem
set_property PROGRAM.CFG_PROGRAM  1 $cfgmem
set_property PROGRAM.VERIFY       1 $cfgmem
set_property PROGRAM.CHECKSUM     0 $cfgmem

puts "================================================="
puts " 4. Executing SPI Flash Program Sequence"
puts "================================================="
startgroup
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
endgroup

puts "================================================="
puts " 🎉 SUCCESS: SPI Flash Programmed Successfully!"
puts "================================================="

close_hw_target
close_hw_manager
