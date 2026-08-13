# ============================================================================
# Vivado TCL Batch Build Script for Cost-Down Artix UltraScale+ (XCAU15P)
# Target Device: xcau15p-ffvb676-2-e
# Output Bitstream: ./build/qpcie_au15p_proj/qpcie_au15p_card.runs/impl_1/au15p_pcie_card_top.bit
# ============================================================================

set project_name "qpcie_au15p_card"
set project_dir  "./build/qpcie_au15p_proj"
set target_part  "xcau15p-ffvb676-2-e"

puts "================================================================="
puts " Building Cost-Down Vivado Project: $project_name ($target_part)"
puts "================================================================="

file mkdir $project_dir
create_project $project_name $project_dir -part $target_part -force

set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

puts "Adding RTL source files..."
add_files [glob ./rtl/*.v]

puts "Adding AU15P Constraint file..."
add_files -fileset constrs_1 ./constraints/au15p_pcie_pinout.xdc

puts "Generating UltraScale+ Compact PCIe Core (Gen3 x4, 256-bit AXI-Stream) for AU15P..."
create_ip -name pcie4c_uscale_plus -vendor xilinx.com -library ip -version 1.0 -module_name pcie4c_uscale_plus_0

set_property -dict [list \
  CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {8.0_GT/s} \
  CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
  CONFIG.axisten_if_width {256_bit} \
  CONFIG.pf0_bar0_64bit {true} \
  CONFIG.pf0_bar0_scale {Kilobytes} \
  CONFIG.pf0_bar0_size {64} \
  CONFIG.pf0_bar1_enabled {true} \
  CONFIG.pf0_bar1_64bit {true} \
  CONFIG.pf0_bar1_scale {Kilobytes} \
  CONFIG.pf0_bar1_size {64} \
  CONFIG.PF0_DEVICE_ID {9038} \
  CONFIG.vendor_id {10EE} \
] [get_ips pcie4c_uscale_plus_0]
generate_target all [get_ips pcie4c_uscale_plus_0]

puts "Generating Video TPG IP Core (v_tpg_0) for 4 PPC 4K60..."
create_ip -name v_tpg -vendor xilinx.com -library ip -version 8.2 -module_name v_tpg_0
set_property -dict [list \
  CONFIG.SAMPLES_PER_CLOCK {4} \
  CONFIG.MAX_COLS {3840} \
  CONFIG.MAX_ROWS {2160} \
] [get_ips v_tpg_0]
generate_target all [get_ips v_tpg_0]

puts "Generating Xilinx Official AXI Crossbar IP Core (axi_crossbar_0) for 1x3 Interconnect..."
create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_0
set_property -dict [list \
  CONFIG.NUM_SI {1} \
  CONFIG.NUM_MI {3} \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
] [get_ips axi_crossbar_0]
generate_target all [get_ips axi_crossbar_0]

set_property top au15p_pcie_card_top [current_fileset]

puts "Starting Synthesis (synth_1)..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

puts "Starting Implementation & Bitstream Generation (impl_1)..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

puts "================================================================="
puts " SUCCESS: Cost-Down Artix UltraScale+ (AU15P) Bitstream Built!"
puts " Bitstream Location: $project_dir/$project_name.runs/impl_1/au15p_pcie_card_top.bit"
puts "================================================================="
