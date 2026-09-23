# ==============================================================================
# Vivado TCL Build Script for SC7F0 N1 HDMI2 V11 (ZU4EV PCIe Video & Audio DMA Card)
# Target Device: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
# Top-Level RTL: zu4ev_pcie_card_top.v
# PCIe IP Core: pcie4_uscale_plus_0 (Gen3 x4, 256-bit, Tandem PCIe)
# Distinct Identification: Vendor ID 0x12AB, Device ID 0xE380
# ==============================================================================

set project_name "qpcie_zu4ev_card"
set project_dir  "./build/qpcie_zu4ev_proj"
set device_part  "xczu4ev-fbvb900-2-e"

puts "================================================================="
puts " Starting Vivado Build for ZU4EV SC7F0 (zu4ev_pcie_card_top.v)"
puts " Target Part : $device_part"
puts " PCIe Core   : pcie4_uscale_plus_0 (Gen3 x4, 256-bit, Tandem PCIe)"
puts " Distinct ID : Vendor 0x12AB / Device 0xE380"
puts "================================================================="

file mkdir $project_dir
create_project $project_name $project_dir -part $device_part -force

set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# 1. Add RTL Sources & Dynamic Git Hash
set git_raw [string toupper [exec git rev-parse --short=8 HEAD]]
set date_raw [clock format [clock seconds] -format "%Y%m%d"]
set git_commit_hex "32'h$git_raw"
set build_date_hex "32'h$date_raw"

puts "   (GIT AUTO-INJECT) Commit Hash: 0x$git_raw, Build Date: $date_raw"

add_files [glob ./rtl/*.v]
set_property top zu4ev_pcie_card_top [current_fileset]

set verilog_defs [list GIT_COMMIT_HASH_DEF=$git_commit_hex BUILD_TIMESTAMP_DEF=$build_date_hex]
set_property verilog_define $verilog_defs [current_fileset]

# 2. Add Constraints
add_files -fileset constrs_1 ./constraints/zu4ev_pcie_pinout.xdc

# 3. Generate UltraScale+ PCIe Core with Tandem PCIe (Gen3 x4, 256-bit, Quad 223)
puts "Generating UltraScale+ PCIe IP Core (pcie4_uscale_plus_0 - Gen3 x4, 256-bit, Tandem PCIe)..."
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -version 1.3 -module_name pcie4_uscale_plus_0

set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad {GTH_Quad_223} \
  CONFIG.pcie_blk_locn {X0Y1} \
  CONFIG.mcap_enablement {Tandem_PCIe} \
  CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {8.0_GT/s} \
  CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
  CONFIG.axisten_if_width {256_bit} \
  CONFIG.AXISTEN_IF_CQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.AXISTEN_IF_RQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.PL_DISABLE_LANE_REVERSAL {FALSE} \
  CONFIG.vendor_id {12AB} \
  CONFIG.PF0_DEVICE_ID {E380} \
  CONFIG.PF0_SUBSYSTEM_VENDOR_ID {12AB} \
  CONFIG.PF0_SUBSYSTEM_ID {0007} \
  CONFIG.pf0_bar0_64bit {false} \
  CONFIG.pf0_bar0_scale {Megabytes} \
  CONFIG.pf0_bar0_size {1} \
  CONFIG.pf0_bar1_enabled {true} \
  CONFIG.pf0_bar1_64bit {false} \
  CONFIG.pf0_bar1_scale {Kilobytes} \
  CONFIG.pf0_bar1_size {64} \
  CONFIG.pf0_msi_enabled {true} \
] [get_ips pcie4_uscale_plus_0]

generate_target all [get_ips pcie4_uscale_plus_0]

# 4. Generate Video Test Pattern Generator IP Core (v_tpg_0)
puts "Generating Video TPG IP Core (v_tpg_0 - 4 PPC 4K60)..."
create_ip -name v_tpg -vendor xilinx.com -library ip -version 8.2 -module_name v_tpg_0

set_property -dict [list \
  CONFIG.SAMPLES_PER_CLOCK {4} \
  CONFIG.MAX_DATA_WIDTH {8} \
  CONFIG.MAX_COLS {4096} \
  CONFIG.MAX_ROWS {2160} \
] [get_ips v_tpg_0]

generate_target all [get_ips v_tpg_0]

# 5. Generate AXI Crossbar IP Core (axi_crossbar_0 - 1x3)
puts "Generating AXI Crossbar IP Core (axi_crossbar_0 - 1x3)..."
create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_0

set_property -dict [list \
  CONFIG.NUM_SI {1} \
  CONFIG.NUM_MI {3} \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.M00_A00_BASE_ADDR {0x0000000000000000} \
  CONFIG.M00_A00_ADDR_WIDTH {12} \
  CONFIG.M01_A00_BASE_ADDR {0x0000000000001000} \
  CONFIG.M01_A00_ADDR_WIDTH {12} \
  CONFIG.M02_A00_BASE_ADDR {0x0000000000002000} \
  CONFIG.M02_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]

generate_target all [get_ips axi_crossbar_0]

# 6. Update Compile Order
update_compile_order -fileset sources_1

# IP cache disable
config_ip_cache -disable_cache

puts "Starting Synthesis (synth_1)..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    puts "ERROR: Synthesis failed for ZU4EV top module!"
    exit 1
}

puts "Starting Implementation & Tandem Bitstream Generation (impl_1)..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    puts "ERROR: Implementation failed for ZU4EV top module!"
    exit 1
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
puts "================================================================="
puts " SUCCESS: ZU4EV Tandem PCIe Bitstreams Built (12AB:E380)!"
puts " Output Bitstreams in $impl_dir:"
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    set size [file size $f]
    puts "  [file tail $f] : $size bytes"
}
puts "================================================================="

report_timing_summary -file $project_dir/timing_summary.rpt
close_project
exit 0
