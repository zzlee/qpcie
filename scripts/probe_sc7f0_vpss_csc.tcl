# Isolated official CSC feasibility run; not full-card signoff.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
if {![info exists ::env(SC7F0_CSC_PROBE_OUT)]} {error "Set a fresh SC7F0_CSC_PROBE_OUT"}
set out [file normalize $::env(SC7F0_CSC_PROBE_OUT)]
if {[file exists $out]} {error "Refusing to overwrite CSC probe $out"}
create_project csc_probe $out -part xczu4ev-fbvb900-2-e
set_property target_language Verilog [current_project]
source scripts/create_sc7f0_vpss_csc_ip.tcl
create_sc7f0_vpss_csc_ip
report_ip_status -file $out/ip_status.rpt
create_ip_run [get_files */sc7f0_vpss_csc.xci]
launch_runs sc7f0_vpss_csc_synth_1 -jobs 4
wait_on_run sc7f0_vpss_csc_synth_1
if {[get_property PROGRESS [get_runs sc7f0_vpss_csc_synth_1]] ne "100%" ||
    [string first "ERROR" [get_property STATUS [get_runs sc7f0_vpss_csc_synth_1]]] >= 0} {
    error "CSC OOC synthesis failed"
}
open_run sc7f0_vpss_csc_synth_1
report_utilization -hierarchical -file $out/utilization_synth.rpt
report_timing_summary -file $out/timing_summary_synth.rpt
puts "SC7F0_CSC_PROBE_PASS (OOC only; not full-card or image acceptance)"
close_project
exit
