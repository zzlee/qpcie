# ==============================================================================
# Rebuild SC7F0 HDMI project with C_VERSION=32'h26101906,
# expanded pl_ps_irq0[2:0], and direct M_AXI_HPM1_FPD export.
#
# Reuses existing Purchased HDMI RX/TX IP netlists in build/qpcie_zu4ev_hdmi_proj.
# ==============================================================================

set project_dir ./build/qpcie_zu4ev_hdmi_proj
open_project $project_dir/qpcie_zu4ev_card.xpr

puts "=== Step 1: Setting C_VERSION=32'h26101906 ==="
set_property generic {C_VERSION=32'h26101906} [current_fileset]

puts "=== Step 2: Updating BD design zu4ev_ps_bd for HDMI06 IRQ ==="
open_bd_design [get_files zu4ev_ps_bd.bd]

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

# Re-create pl_ps_irq0 with width [2:0] (GIC IDs 121..123, DT SPIs 89..91)
# bit 0: ps_irq_pulse, bit 1: Video PHY IRQ, bit 2: HDMI RX SS IRQ
if {[get_bd_ports -quiet pl_ps_irq0] ne ""} {
  delete_bd_objs [get_bd_ports pl_ps_irq0]
}
set irq_port [ create_bd_port -dir I -from 2 -to 0 -type intr pl_ps_irq0 ]
connect_bd_net $irq_port [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# Clock association
set_property CONFIG.ASSOCIATED_BUSIF {M_AXI_HPM0_FPD:M_AXI_HPM1_FPD:S_AXI_HP0_FPD} [get_bd_ports pl_clk0]

puts "Validating BD design..."
validate_bd_design
save_bd_design

puts "=== Step 4: Regenerating BD targets ==="
reset_target all [get_files zu4ev_ps_bd.bd]
generate_target all [get_files zu4ev_ps_bd.bd]
make_wrapper -files [get_files zu4ev_ps_bd.bd] -top -force

update_compile_order -fileset sources_1

puts "=== Step 5: Resetting synthesis runs (only top & PS BD) ==="
reset_runs synth_1
if {[get_runs -quiet zu4ev_ps_bd_zynq_ultra_ps_e_0_0_synth_1] ne ""} {
    reset_runs zu4ev_ps_bd_zynq_ultra_ps_e_0_0_synth_1
}

puts "=== Step 6: Launching synthesis with 16 jobs ==="
launch_runs synth_1 -jobs 16
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    error "Synthesis failed! See synth_1 run log."
}
puts "SYNTHESIS_PASS: C_VERSION 0x26101906"

puts "=== Step 7: Launching implementation & bitstream generation with 16 jobs ==="
reset_runs impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {[get_property PROGRESS [get_runs impl_1]] != "100%" || [string first "ERROR" $impl_status] >= 0 || [string first "write_bitstream Complete" $impl_status] < 0} {
    puts "ERROR: Implementation or write_bitstream failed: $impl_status"
    error "Implementation/bitstream failed!"
}
puts "BITSTREAM_SUCCESS: C_VERSION 0x26101906 generated"

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set probes_out "$impl_dir/zu4ev_pcie_card_top.ltx"
write_debug_probes -force $probes_out
puts " ILA debug probes: $probes_out"
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    puts " Bitstream: $f ([file size $f] bytes)"
}

puts "=== Step 8: Generating reports ==="
report_timing_summary -delay_type min_max -report_unconstrained -file $project_dir/timing_summary.rpt
check_timing -verbose -file $project_dir/check-timing.rpt
report_cdc -details -file $project_dir/cdc.rpt
report_methodology -file $project_dir/methodology.rpt
report_bus_skew -file $project_dir/bus-skew.rpt
report_clock_interaction -file $project_dir/clock-interaction.rpt

puts "=== Step 9: Exporting Hardware Platform XSA ==="
set xsa_out "./hw_platform/sc7f0_hdmi.xsa"
file mkdir [file dirname $xsa_out]
write_hw_platform -fixed -include_bit -force $xsa_out
puts "XSA_SUCCESS: Exported $xsa_out"

file copy -force $xsa_out "./hw_platform/sc7f0-hdmi06.xsa"
puts "XSA_COPIED: ./hw_platform/sc7f0-hdmi06.xsa"

close_project
puts "ALL_DONE_HDMI06"
exit 0
