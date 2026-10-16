create_project sc7f0_hdmi_bridges /tmp/opencode/sc7f0_hdmi_bridges -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]
add_files [list ./rtl/hdmi_tx_video_bridge.v ./rtl/hdmi_rx_audio_bridge.v ./rtl/hdmi_tx_audio_bridge.v]
add_files -fileset sim_1 ./tb/sc7f0_hdmi_bridges_tb.sv
set_property top sc7f0_hdmi_bridges_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 200us [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
if {[get_value -radix unsigned /sc7f0_hdmi_bridges_tb/test_passed] ne "1"} {
    error "HDMI bridge TB did not reach PASS"
}
exit 0
