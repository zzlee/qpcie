set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
if {![info exists ::env(SC7F0_STOP_SIM_OUT)]} {error "Set SC7F0_STOP_SIM_OUT"}
set out [file normalize $::env(SC7F0_STOP_SIM_OUT)]
if {[file exists $out]} {error "Refusing existing stop simulation output"}
create_project stop_ack_sim $out -part xczu4ev-fbvb900-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files -fileset sim_1 {rtl/sc7f0_dp_fifo.v rtl/sc7f0_gray64_sync.v rtl/sc7f0_tap_regs.v tb/sc7f0_tap_stop_ack_tb.sv}
set_property top sc7f0_tap_stop_ack_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
if {[get_value -radix unsigned /sc7f0_tap_stop_ack_tb/test_pass] ne "1"} {error "Stop ACK simulation did not PASS"}
puts "SC7F0_STOP_ACK_SIM_GATE_PASS"
exit 0
