set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
create_project sc7f0_live_sim ./build/sc7f0_live_sim -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]
add_files [list ./rtl/video_axis_async_fifo.v ./rtl/nv12_capture_engine.v ./rtl/video_req_cdc.v ./rtl/rq_tx_encoder.v ./rtl/sg_segment_walker.v]
add_files -fileset sim_1 ./tb/sc7f0_live_video_tb.sv
set_property top sc7f0_live_video_tb [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
set_property xsim.simulate.custom_tcl [file normalize ./scripts/xsim_sc7f0_live_video.tcl] [get_filesets sim_1]
if {[info exists ::env(SC7F0_TEST_NV12)]} {
    set_property xsim.simulate.xsim.more_options {-testplusarg NV12} [get_filesets sim_1]
}
launch_simulation -simset sim_1 -mode behavioral
close_sim
set fd [open ./build/sc7f0_live_sim/sc7f0_live_sim.sim/sim_1/behav/xsim/simulate.log r]
set result [read $fd]
close $fd
if {[string first "TB_PASS:" $result] < 0 || [string first "Fatal:" $result] >= 0} {
    error "Live video regression did not pass; inspect simulate.log"
}
close_project
exit 0
