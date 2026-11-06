set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
if {![info exists ::env(SC7F0_TAP_SIM_OUT)]} {error "Set SC7F0_TAP_SIM_OUT"}
set out [file normalize $::env(SC7F0_TAP_SIM_OUT)]
if {[file exists $out]} {error "Refusing existing tap simulation output"}
create_project tap_sim $out -part xczu4ev-fbvb900-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files -fileset sim_1 {rtl/sc7f0_dp_fifo.v rtl/sc7f0_gray64_sync.v rtl/sc7f0_frame_tap.v tb/sc7f0_frame_tap_tb.sv}
set_property top sc7f0_frame_tap_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
if {[get_value -radix unsigned /sc7f0_frame_tap_tb/test_pass] ne "1"} {error "Frame tap did not PASS"}
puts "FRAME_TAP_SIM_GATE_PASS"
exit
