set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
create_project sc7f0_cdc_tests ./build/sc7f0_cdc_tests -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]
add_files [list ./rtl/video_req_cdc.v ./rtl/sc7f0_hdmi_probe.v]
add_files -fileset sim_1 [list ./tb/sc7f0_request_cdc_tb.sv ./tb/sc7f0_hdmi_probe_backpressure_tb.sv]
set_property xsim.simulate.custom_tcl [file normalize ./scripts/xsim_sc7f0_live_video.tcl] [get_filesets sim_1]
foreach {top pass} {sc7f0_request_cdc_tb REQUEST_CDC_PASS sc7f0_hdmi_probe_backpressure_tb BACKPRESSURE_PASS} {
    set_property top $top [get_filesets sim_1]
    launch_simulation -simset sim_1 -mode behavioral
    close_sim
    set fd [open ./build/sc7f0_cdc_tests/sc7f0_cdc_tests.sim/sim_1/behav/xsim/simulate.log r]
    set result [read $fd]
    close $fd
    file copy -force ./build/sc7f0_cdc_tests/sc7f0_cdc_tests.sim/sim_1/behav/xsim/simulate.log ./build/validation/sc7f0-live-capture/${top}.log
    if {[string first $pass $result] < 0 || [string first "Fatal:" $result] >= 0} {
        error "$top failed; see simulate.log"
    }
}
close_project
puts "SC7F0_CDC_TESTS_PASS"
exit 0
