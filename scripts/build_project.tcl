# ============================================================================
# Vivado TCL Script: build_project.tcl
# Target Board: Xilinx Kintex UltraScale+ (xcku3p-ffva676-2-e)
# Description: Automated Vivado project generation, PCIe IP synthesis,
#              implementation, and bitstream build for Custom PCIe Card.
# Usage: vivado -mode batch -source scripts/build_project.tcl
# ============================================================================

set project_name "qpcie_ku3p_card"
set project_dir  "./build/qpcie_ku3p_proj"
set target_part  "xcku3p-ffva676-2-e"

puts "================================================================="
puts " Building Vivado Project: $project_name ($target_part)"
puts "================================================================="

# 1. Create Vivado Project
file mkdir $project_dir
create_project $project_name $project_dir -part $target_part -force

set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# 2. Add Source Files
puts "Adding RTL source files..."
add_files [glob ./rtl/*.v]

# 3. Add Constraints
puts "Adding Constraint file..."
add_files -fileset constrs_1 ./constraints/ku3p_pcie_pinout.xdc

# 4. Generate Xilinx UltraScale+ PCIe IP Core
puts "Generating UltraScale+ PCIe4 IP Core (Gen3 x4, 256-bit AXI-Stream)..."
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -version 1.3 -module_name pcie4_uscale_plus_0

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
] [get_ips pcie4_uscale_plus_0]

generate_target all [get_ips pcie4_uscale_plus_0]

# 4.1 Generate Xilinx Video Test Pattern Generator IP Core (v_tpg_0) - 4 PPC @ 4K60
puts "Generating Xilinx Video Test Pattern Generator IP Core (v_tpg_0) for 4 PPC 4K60..."
create_ip -name v_tpg -vendor xilinx.com -library ip -version 8.2 -module_name v_tpg_0

set_property -dict [list \
  CONFIG.SAMPLES_PER_CLOCK {4} \
  CONFIG.MAX_COLS {3840} \
  CONFIG.MAX_ROWS {2160} \
] [get_ips v_tpg_0]

generate_target all [get_ips v_tpg_0]

# 5. Set Top Module
set_property top ku3p_pcie_card_top [current_fileset]

# 6. Run Synthesis
puts "Starting Synthesis (synth_1)..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# 7. Run Implementation & Write Bitstream
puts "Starting Implementation (impl_1)..."
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [add_files -fileset constrs_1 ./constraints/ku3p_pcie_pinout.xdc] [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

puts "================================================================="
puts " SUCCESS: PCIe Kintex UltraScale+ Bitstream Built Successfully!"
puts " Bitstream Location: $project_dir/$project_name.runs/impl_1/ku3p_pcie_card_top.bit"
puts "================================================================="
