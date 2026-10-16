# Rebuild RTL/constraints using already-generated HDMI05 IP, without touching
# debug04 or regenerating/repackaging PS software. Optional routed review only.
set project_dir ./build/qpcie_zu4ev_hdmi_proj
open_project $project_dir/qpcie_zu4ev_card.xpr
if {[get_property generic [current_fileset]] ne {C_VERSION=32'h26101601}} {
    error "Refusing to continue anything other than the HDMI05 candidate"
}
update_compile_order -fileset sources_1
reset_runs synth_1
launch_runs synth_1 -jobs 16
wait_on_run synth_1
set run [get_runs synth_1]
if {[get_property PROGRESS $run] ne "100%" ||
    [string first "ERROR" [get_property STATUS $run]] >= 0} {
    error "HDMI05 top synthesis failed"
}
set fd [open [file join [get_property DIRECTORY $run] runme.log] r]
set synthesis_log [read $fd]
close $fd
if {[regexp {CRITICAL WARNING:} $synthesis_log]} {
    error "HDMI05 synthesis has a critical warning; implementation withheld"
}
puts "HDMI_SYNTH_PASS: latest RTL/XDC, no synthesis critical warnings"
if {[info exists ::env(SC7F0_HDMI_ROUTE)] && $::env(SC7F0_HDMI_ROUTE) eq "1"} {
    launch_runs impl_1 -to_step route_design -jobs 16
    wait_on_run impl_1
    if {[string first "route_design Complete" [get_property STATUS [get_runs impl_1]]] < 0} {
        error "HDMI05 routed implementation did not complete"
    }
    open_run impl_1
    report_timing_summary -delay_type min_max -report_unconstrained -file $project_dir/timing_summary.rpt
    check_timing -verbose -file $project_dir/check-timing.rpt
    report_cdc -details -file $project_dir/cdc.rpt
    report_methodology -file $project_dir/methodology.rpt
    report_drc -file $project_dir/drc.rpt
    report_bus_skew -file $project_dir/bus-skew.rpt
    report_clock_interaction -file $project_dir/clock-interaction.rpt
    report_ip_status -file $project_dir/ip-status.rpt
    puts "HDMI_ROUTE_REVIEW_READY: reports generated; NO bitstream/XSA/release publication"
}
close_project
exit 0
