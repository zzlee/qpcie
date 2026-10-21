set project_dir ./build/qpcie_zu4ev_hdmi_proj
open_project $project_dir/qpcie_zu4ev_card.xpr
set_property generic {C_VERSION=32'h26101903} [current_fileset]
update_compile_order -fileset sources_1
reset_runs synth_1
launch_runs synth_1 -jobs 16
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    error "Synthesis failed!"
}
puts "SYNTHESIS_PASS: C_VERSION 0x26101903"
reset_runs impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%" || [string first "ERROR" [get_property STATUS [get_runs impl_1]]] >= 0} {
    error "Implementation failed!"
}
puts "BITSTREAM_SUCCESS: C_VERSION 0x26101903 generated"
close_project
exit 0
