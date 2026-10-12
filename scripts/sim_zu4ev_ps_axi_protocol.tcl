# Vivado 2023.2 focused PS AXI4 -> BAR0 AXI4-Lite simulation.
# Run from the repository root with Vivado set up, e.g.:
#   vivado -mode batch -source scripts/sim_zu4ev_ps_axi_protocol.tcl
set project_dir /tmp/opencode/qpcie_ps_axi_protocol_sim
create_project qpcie_ps_axi_protocol_sim $project_dir -part xczu4ev-fbvb900-2-e -force
create_ip -name axi_protocol_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_protocol_converter_0
set_property -dict [list \
  CONFIG.SI_PROTOCOL {AXI4} \
  CONFIG.MI_PROTOCOL {AXI4LITE} \
  CONFIG.ADDR_WIDTH {32} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.ID_WIDTH {16} \
] [get_ips axi_protocol_converter_0]
generate_target all [get_ips axi_protocol_converter_0]
add_files -fileset sim_1 ./tb/zu4ev_ps_axi_protocol_tb.sv
set_property top zu4ev_ps_axi_protocol_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
exit
