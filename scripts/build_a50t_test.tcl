# ==============================================================================
# Vivado Build Script: Minimal PCIe TLP Loopback Test (no downstream IP)
# Target: xc7a50t-csg325-2
# Top: a50t_pcie_tlp_test_top
# ==============================================================================

set project_name "qpcie_tlp_test"
set project_dir "./build/qpcie_tlp_test_proj"
set device_part "xc7a50t-csg325-2"

puts "================================================================="
puts " Building Minimal PCIe TLP Loopback Test"
puts " Top: a50t_pcie_tlp_test_top"
puts "================================================================="

file mkdir $project_dir
create_project $project_name $project_dir -part $device_part -force

add_files [glob ./rtl/*.v]
set_property top a50t_pcie_tlp_test_top [current_fileset]

add_files -fileset constrs_1 ./constraints/a50t_pcie_pinout.xdc

puts "Generating 7-Series PCIe IP Core (pcie_7x_0)..."
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
  CONFIG.Bar0_Scale {Kilobytes} \
  CONFIG.Bar0_Size {256} \
  CONFIG.Bar1_Enabled {false} \
  CONFIG.Shared_Logic_In_Core {true} \
  CONFIG.en_ext_clk {false} \
] [get_ips pcie_7x_0]

generate_target all [get_ips pcie_7x_0]

update_compile_order -fileset sources_1

puts "Launching Synthesis and Implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

open_run impl_1
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 40 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

write_bitstream -force $project_dir/$project_name.runs/impl_1/a50t_pcie_tlp_test_top.bit -bin_file

puts "================================================================="
puts " SUCCESS: TLP Loopback Test Bitstream Built!"
puts " $project_dir/$project_name.runs/impl_1/a50t_pcie_tlp_test_top.bit"
puts "================================================================="
close_project
