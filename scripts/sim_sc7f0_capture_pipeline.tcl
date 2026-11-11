set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
foreach name {SC7F0_PIPE_SIM_OUT SC7F0_FRMBUF_XCI SC7F0_CSC_XCI SC7F0_CLOCK_XCI SC7F0_WIDTH_XCI} {
    if {![info exists ::env($name)]} {error "Set $name"}
}
set out [file normalize $::env(SC7F0_PIPE_SIM_OUT)]
if {[file exists $out]} {error "Refusing existing capture simulation output"}
create_project capture_pipe_sim $out -part xczu4ev-fbvb900-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
foreach name {SC7F0_FRMBUF_XCI SC7F0_CSC_XCI SC7F0_CLOCK_XCI SC7F0_WIDTH_XCI} {read_ip $::env($name)}
add_files -fileset sim_1 {rtl/sc7f0_capture_pipeline.v rtl/sc7f0_frame_tap.v rtl/sc7f0_tap_regs.v rtl/sc7f0_gray64_sync.v rtl/sc7f0_dp_fifo.v tb/sc7f0_capture_pipeline_tb.sv}
set_property top sc7f0_capture_pipeline_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
if {[get_value -radix unsigned /sc7f0_capture_pipeline_tb/test_pass] ne "1"} {error "Capture pipeline did not PASS"}
puts "CAPTURE_PIPELINE_SIM_GATE_PASS"
exit
