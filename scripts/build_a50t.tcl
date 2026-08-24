# ==============================================================================
# Vivado TCL Build Script for Artix-7 A50T PCIe Video & Audio DMA Card (qpcie)
# Target Board: AMD/Xilinx Artix-7 (xc7a50t-csg325-2)
# Top-Level RTL: a50t_pcie_card_top.v (qpcie native RTL top)
# PCIe IP Core: pcie_7x_0 (7-Series Integrated Block for PCIe v3.3, Gen2 x4, 128-bit)
# Distinct Identification: Vendor ID 0x12AB, Device ID 0xE380
# ==============================================================================

set project_name "qpcie_a50t_card"
set project_dir "./build/qpcie_a50t_proj"
set device_part "xc7a50t-csg325-2"

puts "================================================================="
puts " Starting Vivado Build for qpcie Native RTL (a50t_pcie_card_top.v)"
puts " Target Part : $device_part"
puts " PCIe Core   : pcie_7x_0 (Gen2 x4, 128-bit AXI-Stream)"
puts " Distinct ID : Vendor 0x12AB / Device 0xE380 (qpcie Card)"
puts "================================================================="

file mkdir $project_dir
create_project $project_name $project_dir -part $device_part -force

# 1. Add qpcie RTL Source Files & Inject Dynamic Git Commit Hash + Date
set git_raw [string toupper [exec git rev-parse --short=8 HEAD]]
set date_raw [clock format [clock seconds] -format "%Y%m%d"]
set git_commit_hex "32'h$git_raw"
set build_date_hex "32'h$date_raw"

puts "   (GIT AUTO-INJECT) Commit Hash: 0x$git_raw, Build Date: $date_raw"

add_files [glob ./rtl/*.v]
set_property top a50t_pcie_card_top [current_fileset]
set_property verilog_define [list GIT_COMMIT_HASH_DEF=$git_commit_hex BUILD_TIMESTAMP_DEF=$build_date_hex] [current_fileset]

# 2. Add Constraints
add_files -fileset constrs_1 ./constraints/a50t_pcie_pinout.xdc

# 3. Generate Xilinx 7-Series Integrated PCIe Block IP Core (pcie_7x_0)
puts "Generating 7-Series PCIe IP Core (pcie_7x_0 - Gen2 x4, 128-bit, 12AB:E380)..."
create_ip -name pcie_7x -vendor xilinx.com -library ip -version 3.3 -module_name pcie_7x_0

set_property -dict [list \
  CONFIG.Link_Speed {5.0_GT/s} \
  CONFIG.Maximum_Link_Width {X4} \
  CONFIG.Interface_Width {128_bit} \
  CONFIG.User_Clk_Freq {125} \
  CONFIG.Vendor_ID {12AB} \
  CONFIG.Device_ID {E380} \
  CONFIG.Subsystem_Vendor_ID {12AB} \
  CONFIG.Subsystem_ID {0007} \
  CONFIG.Bar0_Scale {Megabytes} \
  CONFIG.Bar0_Size {1} \
  CONFIG.Bar1_Enabled {true} \
  CONFIG.Bar1_Scale {Kilobytes} \
  CONFIG.Bar1_Size {64} \
  CONFIG.Shared_Logic_In_Core {true} \
  CONFIG.en_ext_clk {false} \
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

# 6. Update Compile Order
update_compile_order -fileset sources_1

# 7. Run Synthesis and Implementation to Bitstream
puts "Launching Synthesis and Implementation for qpcie top module..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    puts "ERROR: Implementation failed for qpcie top module!"
    exit 1
}

open_run impl_1
set failing_path [get_timing_paths -quiet -slack_lesser_than 0 -max_paths 1]
if {[llength $failing_path] != 0} {
    set worst_slack [get_property SLACK [lindex $failing_path 0]]
    puts "ERROR: Routed design does not meet timing (worst slack $worst_slack ns)."
    exit 1
}

puts "================================================================="
puts " 🎉 SUCCESS: Artix-7 A50T qpcie Native RTL Bitstream Built (12AB:E380)!"
puts " Bitstream Location: $project_dir/$project_name.runs/impl_1/a50t_pcie_card_top.bit"
puts "================================================================="
close_project
