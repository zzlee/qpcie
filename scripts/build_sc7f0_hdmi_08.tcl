# HDMI08: 150 MHz capture domain; leave validated HDMI07 project/artifacts intact.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
open_project ./build/qpcie_zu4ev_hdmi_proj/qpcie_zu4ev_card.xpr
save_project_as qpcie_zu4ev_live ./build/qpcie_zu4ev_live_proj -force
foreach f {video_axis_async_fifo.v hdmi_rx_pixel_pack.v video_rgb_to_yuv709.v} {
    if {[get_files -quiet */$f] eq ""} { add_files -norecurse ./rtl/$f }
}
set version 26102204
if {[info exists ::env(SC7F0_VERSION)]} { set version $::env(SC7F0_VERSION) }
if {![regexp {^[0-9A-Fa-f]{8}$} $version]} { error "SC7F0_VERSION must be eight hex digits" }
set_property generic "C_VERSION=32'h$version" [current_fileset]
set git_hex [string toupper [exec git rev-parse --short=8 HEAD]]
set date_hex [clock format [clock seconds] -format "%Y%m%d"]
set_property verilog_define [list GIT_COMMIT_HASH_DEF=32'h$git_hex BUILD_TIMESTAMP_DEF=32'h$date_hex] [current_fileset]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
# The BD/IP interfaces are unchanged, but regenerate targets before export.
foreach bd [get_files -quiet *.bd] { generate_target all $bd }
update_compile_order -fileset sources_1
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
reset_runs synth_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs synth_1]]] >= 0} {
    error "HDMI08 synthesis failed"
}
launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1
if {[string first "write_bitstream Complete" [get_property STATUS [get_runs impl_1]]] < 0} {
    error "HDMI08 implementation failed"
}
open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained -file ./build/qpcie_zu4ev_live_proj/timing_summary.rpt
report_cdc -details -file ./build/qpcie_zu4ev_live_proj/cdc.rpt
report_bus_skew -warn_on_violation -file ./build/qpcie_zu4ev_live_proj/bus_skew.rpt
report_drc -file ./build/qpcie_zu4ev_live_proj/drc.rpt
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {
    error "HDMI08 timing failed; XSA export withheld"
}
write_hw_platform -fixed -include_bit -force ./hw_platform/sc7f0-hdmi08.xsa
close_project
puts "HDMI08_BUILD_PASS"
exit 0
