# Rebuild SC7F0 HDMI project with C_VERSION=32'h26101904 and MAXIGP1 32-bit fix.
set project_dir ./build/qpcie_zu4ev_hdmi_proj
open_project $project_dir/qpcie_zu4ev_card.xpr

puts "Setting C_VERSION=32'h26101904..."
set_property generic {C_VERSION=32'h26101904} [current_fileset]

puts "Opening BD design zu4ev_ps_bd..."
open_bd_design [get_files zu4ev_ps_bd.bd]

puts "Current PSU__MAXIGP1__DATA_WIDTH: [get_property CONFIG.PSU__MAXIGP1__DATA_WIDTH [get_bd_cells zynq_ultra_ps_e_0]]"
puts "Updating PSU__MAXIGP1__DATA_WIDTH to 32..."
set_property CONFIG.PSU__MAXIGP1__DATA_WIDTH {32} [get_bd_cells zynq_ultra_ps_e_0]
puts "New PSU__MAXIGP1__DATA_WIDTH: [get_property CONFIG.PSU__MAXIGP1__DATA_WIDTH [get_bd_cells zynq_ultra_ps_e_0]]"

validate_bd_design
save_bd_design

puts "Regenerating BD targets..."
reset_target all [get_files zu4ev_ps_bd.bd]
generate_target all [get_files zu4ev_ps_bd.bd]

update_compile_order -fileset sources_1

puts "Resetting runs..."
reset_runs synth_1
if {[get_runs -quiet zu4ev_ps_bd_zynq_ultra_ps_e_0_0_synth_1] ne ""} {
    reset_runs zu4ev_ps_bd_zynq_ultra_ps_e_0_0_synth_1
}

puts "Launching synthesis with 16 jobs..."
launch_runs synth_1 -jobs 16
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    error "Synthesis failed!"
}
puts "SYNTHESIS_PASS: C_VERSION 0x26101904"

puts "Launching implementation & bitstream generation with 16 jobs..."
reset_runs impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    error "Implementation failed!"
}
puts "BITSTREAM_SUCCESS: C_VERSION 0x26101904 generated"

close_project
exit 0
