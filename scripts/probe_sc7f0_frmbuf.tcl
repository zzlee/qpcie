# Isolated official-IP feasibility run; never changes R2 or exports a release.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
if {![info exists ::env(SC7F0_FRMBUF_PROBE_OUT)]} {error "Set a fresh SC7F0_FRMBUF_PROBE_OUT"}
set out [file normalize $::env(SC7F0_FRMBUF_PROBE_OUT)]
if {[file exists $out]} {error "Refusing to overwrite framebuffer probe $out"}
create_project frmbuf_probe $out -part xczu4ev-fbvb900-2-e
set_property target_language Verilog [current_project]
source scripts/create_sc7f0_frmbuf_ip.tcl
create_sc7f0_frmbuf_ip
report_ip_status -file $out/ip_status.rpt
create_ip_run [get_files */sc7f0_frmbuf_wr.xci]
launch_runs sc7f0_frmbuf_wr_synth_1 -jobs 4
wait_on_run sc7f0_frmbuf_wr_synth_1
if {[get_property PROGRESS [get_runs sc7f0_frmbuf_wr_synth_1]] ne "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs sc7f0_frmbuf_wr_synth_1]]] >= 0} {
    error "Framebuffer OOC synthesis failed"
}
open_run sc7f0_frmbuf_wr_synth_1
report_utilization -file $out/utilization_synth.rpt
report_timing_summary -file $out/timing_summary_synth.rpt
puts "SC7F0_FRMBUF_PROBE_PASS (OOC only; not full-card timing or V4L2 acceptance)"
close_project
exit
