# generate_zu4ev_example.tcl - Generate official PG213 PCIe IP example design for ZU4EV SC7F0
set proj_dir "./build/zu4ev_example_proj"
file mkdir $proj_dir

create_project -in_memory -part xczu4ev-fbvb900-2-e

puts "Creating pcie4_uscale_plus IP (GTH_Quad_223, PCIE40E4_X0Y1, Gen3 x4, 128-bit)..."
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -version 1.3 -module_name pcie4_zu4ev

set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad {GTH_Quad_223} \
  CONFIG.pcie_blk_locn {X0Y1} \
  CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {8.0_GT/s} \
  CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
  CONFIG.axisten_if_width {128_bit} \
  CONFIG.AXISTEN_IF_CQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.AXISTEN_IF_RQ_ALIGNMENT_MODE {DWORD_Aligned} \
  CONFIG.PL_DISABLE_LANE_REVERSAL {FALSE} \
  CONFIG.vendor_id {12AB} \
  CONFIG.PF0_DEVICE_ID {E380} \
  CONFIG.pf0_bar0_64bit {false} \
  CONFIG.pf0_bar0_scale {Megabytes} \
  CONFIG.pf0_bar0_size {1} \
  CONFIG.pf0_bar1_enabled {true} \
  CONFIG.pf0_bar1_64bit {false} \
  CONFIG.pf0_bar1_scale {Kilobytes} \
  CONFIG.pf0_bar1_size {64} \
] [get_ips pcie4_zu4ev]

puts "Generating example design..."
open_example_project -force -dir $proj_dir [get_ips pcie4_zu4ev]

puts "ZU4EV PCIe PIO Example design generated successfully at $proj_dir"
exit
