set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out ./build/dualpath-sim
if {[info exists ::env(SC7F0_SIM_OUT)]} {set out $::env(SC7F0_SIM_OUT)}
create_project dualpath_sim $out -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files -fileset sim_1 [concat [glob ./rtl/sc7f0_*.v] [list ./rtl/rq_tx_encoder.v ./tb/sc7f0_dualpath_tb.sv]]
set_property top sc7f0_dualpath_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
if {[get_value -radix unsigned /sc7f0_dualpath_tb/test_pass] ne "1"} {
    error "Dualpath simulation failed; PASS not reached"
}
puts "DUALPATH_SIM_GATE_PASS"
exit
