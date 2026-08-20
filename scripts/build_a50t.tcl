# ==============================================================================
# Vivado TCL Build Script for Artix-7 A50T (XC7A50T) PCIe Video & Audio DMA Card
# Target Board: AMD/Xilinx Artix-7 (xc7a50t-fgg484-2)
# PCIe IP Core: pcie_7x_0 (7 Series Integrated Block for PCIe v3.3, Gen2 x4, 128-bit)
# Vendor ID: 0x12AB, Device ID: 0xE380
# ==============================================================================

set project_name "qpcie_a50t_card"
set project_dir "./build/qpcie_a50t_proj"
set device_part "xc7a50t-fgg484-2"

puts "================================================================="
puts " Starting Vivado Build for Artix-7 A50T PCIe DMA Project"
puts " Target Part : $device_part"
puts " PCIe Config : Gen2 x4 (5.0 GT/s), 128-bit AXI-Stream @ 125MHz"
puts " Vendor/Dev  : 0x12AB / 0xE380"
puts "================================================================="

file mkdir $project_dir
create_project $project_name $project_dir -part $device_part -force

# 1. Add RTL Source Files
add_files [glob ./rtl/*.v]
set_property top a50t_pcie_card_top [current_fileset]

# 2. Add Constraints
add_files -fileset constrs_1 ./constraints/a50t_pcie_pinout.xdc

# 3. Generate Xilinx 7-Series Integrated PCIe Block IP Core (pcie_7x_0)
puts "Generating 7-Series PCIe IP Core (pcie_7x_0 - Gen2 x4, 128-bit)..."
create_ip -name pcie_7x -vendor xilinx.com -library ip -version 3.3 -module_name pcie_7x_0

set_property -dict [list \
  CONFIG.Link_Speed {5.0_GT/s} \
  CONFIG.Maximum_Link_Width {X4} \
  CONFIG.Interface_Width {128_bit} \
  CONFIG.User_Clk_Freq {125} \
  CONFIG.Vendor_ID {10EE} \
  CONFIG.Device_ID {E381} \
  CONFIG.Bar0_Scale {Kilobytes} \
  CONFIG.Bar0_Size {64} \
  CONFIG.Bar1_Enabled {true} \
  CONFIG.Bar1_Scale {Kilobytes} \
  CONFIG.Bar1_Size {64} \
] [get_ips pcie_7x_0]

generate_target all [get_ips pcie_7x_0]

# 4. Generate Xilinx Video Test Pattern Generator IP Core (v_tpg_0)
puts "Generating Xilinx Video Test Pattern Generator IP Core (v_tpg_0)..."
create_ip -name v_tpg -vendor xilinx.com -library ip -version 8.2 -module_name v_tpg_0

set_property -dict [list \
  CONFIG.SAMPLES_PER_CLOCK {4} \
  CONFIG.MAX_DATA_WIDTH {8} \
  CONFIG.MAX_COLS {3840} \
  CONFIG.MAX_ROWS {2160} \
] [get_ips v_tpg_0]

generate_target all [get_ips v_tpg_0]

# 5. Generate Xilinx AXI Crossbar IP (axi_crossbar_0)
puts "Generating AXI Crossbar IP Core (axi_crossbar_0)..."
create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_0

set_property -dict [list \
  CONFIG.NUM_SI {1} \
  CONFIG.NUM_MI {3} \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ADDR_WIDTH {32} \
] [get_ips axi_crossbar_0]

generate_target all [get_ips axi_crossbar_0]

# 6. Run Synthesis and Implementation
puts "Launching Synthesis and Implementation..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

puts "================================================================="
puts " SUCCESS: Artix-7 A50T 128-bit PCIe Bitstream Built Successfully!"
puts " Bitstream Location: $project_dir/$project_name.runs/impl_1/a50t_pcie_card_top.bit"
puts "================================================================="
