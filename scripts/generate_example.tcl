# generate_example.tcl - Generate PCIe IP example design for reference
set build_dir "./build/example_ref"
file mkdir $build_dir
create_project -in_memory -part xcku3p-ffva676-2-e

# Create the PCIe IP with same config
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

# Generate example design
open_example_project -force -dir $build_dir [get_ips pcie4_uscale_plus_0]

puts "Example design generated at $build_dir"
