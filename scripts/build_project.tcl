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
  CONFIG.AXISTEN_IF_DATA_WIDTH {256_bit} \
  CONFIG.AXISTEN_IF_RC_STRADDLE {true} \
  CONFIG.PF0_BAR0_64BIT {true} \
  CONFIG.PF0_BAR0_SIZE {64_KB} \
  CONFIG.PF0_BAR0_TYPE {AXI_LITE} \
  CONFIG.PF0_BAR1_64BIT {true} \
  CONFIG.PF0_BAR1_SIZE {64_KB} \
  CONFIG.PF0_BAR1_TYPE {AXI_LITE} \
  CONFIG.PF0_CLASS_CODE {058000} \
  CONFIG.PF0_DEVICE_ID {9038} \
  CONFIG.PF0_VENDOR_ID {10EE} \
] [get_ips pcie4_uscale_plus_0]

generate_target all [get_ips pcie4_uscale_plus_0]

# 5. Set Top Module
set_property top custom_pcie_dma_top [current_fileset]

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
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

puts "================================================================="
puts " SUCCESS: PCIe Kintex UltraScale+ Bitstream Built Successfully!"
puts " Bitstream Location: $project_dir/$project_name.runs/impl_1/custom_pcie_dma_top.bit"
puts "================================================================="
