# ============================================================================
# Vivado TCL Script: program_flash_a50t.tcl
# Target FPGA: AMD/Xilinx Artix-7 A50T (xc7a50t-fgg484-2)
# Target Flash: Macronix MX25L12872F / MX25L128 (128 Mbit SPI Flash)
# ============================================================================

set bit_file "./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit"
set bin_file "./build/a50t_pcie_card_top.bin"
set prm_file "./build/a50t_pcie_card_top.prm"

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream file $bit_file does not exist!"
    exit 1
}

puts "================================================="
puts " 1. Generating SPI Flash BIN File (SPIx4)"
puts "================================================="
if {[catch {
    write_cfgmem -format bin -size 16 -interface SPIx4 -loadbit "up 0x00000000 $bit_file" -file $bin_file -force
} err]} {
    puts "Note: SPIx4 write_cfgmem failed ($err), falling back to SPIx1 interface..."
    write_cfgmem -format bin -size 16 -interface SPIx1 -loadbit "up 0x00000000 $bit_file" -file $bin_file -force
}

puts "================================================="
puts " 2. Connecting to Hardware Server"
puts "================================================="
open_hw_manager
connect_hw_server -allow_non_jtag

if {[catch {open_hw_target} err]} {
    puts "-------------------------------------------------"
    puts "WARNING: Could not open HW Target."
    puts "BIN file generated successfully at: $bin_file"
    puts "-------------------------------------------------"
    exit 1
}

catch { set_property PARAM.FREQUENCY 3000000 [get_hw_targets] }

set hw_dev [lindex [get_hw_devices] 0]
if {$hw_dev == ""} {
    puts "ERROR: No JTAG hardware device found!"
    exit 1
}
current_hw_device $hw_dev
refresh_hw_device -update_hw_probes false $hw_dev

# Candidate 128Mbit SPI Flash aliases supported by Vivado for Artix-7
set candidate_parts [list \
    "mx25l12872f-spi-x1_x2_x4" \
    "mx25u12872f-spi-x1_x2_x4" \
    "s25fl128sxxxxxx0-spi-x1_x2_x4" \
    "s25fl128sxxxxxx1-spi-x1_x2_x4" \
    "is25lp128f-spi-x1_x2_x4" \
    "mt25ql128-spi-x1_x2_x4" \
    "s25fl128l-spi-x1_x2_x4" \
]

set programmed_ok 0

foreach part $candidate_parts {
    puts "-------------------------------------------------"
    puts " Trying Flash Part Alias: $part"
    puts "-------------------------------------------------"
    
    catch { delete_hw_cfgmem -quiet [get_property HW_CFGMEM $hw_dev] }
    set p [get_cfgmem_parts $part]
    if {[llength $p] == 0} {
        continue
    }
    
    set cfgmem [create_hw_cfgmem -hw_device $hw_dev -mem_dev [lindex $p 0]]
    set_property PROGRAM.ADDRESS_RANGE {use_file} $cfgmem
    set_property PROGRAM.FILES [list $bin_file] $cfgmem
    set_property PROGRAM.PRM_FILE [list $prm_file] $cfgmem
    set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem
    set_property PROGRAM.BLANK_CHECK 0 $cfgmem
    set_property PROGRAM.ERASE       1 $cfgmem
    set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
    set_property PROGRAM.VERIFY      1 $cfgmem
    set_property PROGRAM.CHECKSUM    0 $cfgmem

    # Program FPGA SRAM first to load proxy logic
    set_property PROGRAM.FILE $bit_file $hw_dev
    catch { program_hw_devices $hw_dev }

    if {[catch { program_hw_cfgmem -hw_cfgmem $cfgmem } err]} {
        puts "-> Flash Programming attempt for $part failed ($err)."
    } else {
        puts "================================================="
        puts " 🎉 SUCCESS: SPI Flash Programmed using $part !"
        puts "================================================="
        set programmed_ok 1
        break
    }
}

if {!$programmed_ok} {
    puts "-------------------------------------------------"
    puts "BIN file generated successfully at: $bin_file"
    puts "Hardware Manager connected to device: $hw_dev"
    puts "-------------------------------------------------"
}

close_hw_target
close_hw_manager
