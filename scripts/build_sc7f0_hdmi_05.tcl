# Rebuild SC7F0 HDMI project with C_VERSION=32'h26101905 and direct M_AXI_HPM1_FPD export.
set project_dir ./build/qpcie_zu4ev_hdmi_proj
open_project $project_dir/qpcie_zu4ev_card.xpr

puts "Setting C_VERSION=32'h26101905..."
set_property generic {C_VERSION=32'h26101905} [current_fileset]

puts "Opening BD design zu4ev_ps_bd..."
open_bd_design [get_files zu4ev_ps_bd.bd]

# Remove old BD cells and ports from previous revisions
if {[get_bd_cells -quiet hdmi_control_pc] ne ""} { delete_bd_objs [get_bd_cells hdmi_control_pc] }
if {[get_bd_cells -quiet hdmi_control_reset] ne ""} { delete_bd_objs [get_bd_cells hdmi_control_reset] }
if {[get_bd_cells -quiet hdmi_reset_locked] ne ""} { delete_bd_objs [get_bd_cells hdmi_reset_locked] }
if {[get_bd_cells -quiet hdmi_reset_unused] ne ""} { delete_bd_objs [get_bd_cells hdmi_reset_unused] }
if {[get_bd_intf_ports -quiet M_AXI_HDMI] ne ""} { delete_bd_objs [get_bd_intf_ports M_AXI_HDMI] }

# Ensure M_AXI_GP1 is enabled and DATA_WIDTH is 32
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP1 {1} \
  CONFIG.PSU__MAXIGP1__DATA_WIDTH {32} \
] [get_bd_cells zynq_ultra_ps_e_0]

# Create external interface port M_AXI_HPM1_FPD if not present
if {[get_bd_intf_ports -quiet M_AXI_HPM1_FPD] eq ""} {
  set m_axi1 [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_HPM1_FPD ]
  set_property -dict [list CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {40} CONFIG.FREQ_HZ {99990005}] $m_axi1
  connect_bd_intf_net $m_axi1 [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM1_FPD]
}

# Connect clock if not already connected
set hpm1_clk [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]
if {[get_bd_nets -quiet -of_objects $hpm1_clk] eq ""} {
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $hpm1_clk
}

# Address mapping
assign_bd_address
catch { assign_bd_address -force -offset 0xB0000000 -range 0x00100000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs M_AXI_HPM1_FPD/Reg] }

# Clock association
set_property CONFIG.ASSOCIATED_BUSIF {M_AXI_HPM0_FPD:M_AXI_HPM1_FPD:S_AXI_HP0_FPD} [get_bd_ports pl_clk0]

validate_bd_design
save_bd_design

puts "Regenerating BD targets..."
reset_target all [get_files zu4ev_ps_bd.bd]
generate_target all [get_files zu4ev_ps_bd.bd]
make_wrapper -files [get_files zu4ev_ps_bd.bd] -top -force

update_compile_order -fileset sources_1

puts "Resetting runs..."
reset_runs synth_1
if {[get_runs -quiet zu4ev_ps_bd_zynq_ultra_ps_e_0_0_synth_1] ne ""} {
    reset_runs zu4ev_ps_bd_zynq_ultra_ps_e_0_0_synth_1
}
if {[get_runs -quiet zu4ev_ps_bd_hdmi_control_pc_0_synth_1] ne ""} {
    delete_runs zu4ev_ps_bd_hdmi_control_pc_0_synth_1
}
if {[get_runs -quiet zu4ev_ps_bd_hdmi_control_reset_0_synth_1] ne ""} {
    delete_runs zu4ev_ps_bd_hdmi_control_reset_0_synth_1
}

puts "Launching synthesis with 16 jobs..."
launch_runs synth_1 -jobs 16
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    error "Synthesis failed!"
}
puts "SYNTHESIS_PASS: C_VERSION 0x26101905"

puts "Launching implementation & bitstream generation with 16 jobs..."
reset_runs impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    error "Implementation failed!"
}
puts "BITSTREAM_SUCCESS: C_VERSION 0x26101905 generated"

close_project
exit 0
