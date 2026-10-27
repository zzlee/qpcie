set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
create_project sc7f0_audio ./build/sc7f0_audio_sim -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files [list ./rtl/hdmi_rx_pcm_converter.v ./rtl/audio_stream_engine.v]
add_files -fileset sim_1 [list ./tb/sc7f0_hdmi_pcm_tb.sv ./tb/sc7f0_audio_dma_tb.sv ./tb/sc7f0_hdmi_trace_tb.sv]
foreach top {sc7f0_hdmi_pcm_tb sc7f0_audio_dma_tb sc7f0_hdmi_trace_tb} {
    set_property top $top [get_filesets sim_1]
    set_property xsim.simulate.runtime 200us [get_filesets sim_1]
    launch_simulation -simset sim_1 -mode behavioral
    if {[get_value -radix unsigned /$top/test_passed] ne "1"} { error "$top did not pass" }
    close_sim
}
close_project
puts "SC7F0_AUDIO_SIM_PASS"
exit 0
