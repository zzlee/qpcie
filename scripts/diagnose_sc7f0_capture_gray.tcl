# Read-only diagnostic on an existing routed checkpoint. NOT a new release.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
if {![info exists ::env(SC7F0_DIAG_OUT)]} {error "SC7F0_DIAG_OUT is required"}
set out $::env(SC7F0_DIAG_OUT)
open_checkpoint build/dual-video-26102802-r4/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_routed.dcp
read_xdc constraints/sc7f0_capture_gray.xdc
source scripts/check_sc7f0_capture_gray.tcl
report_timing_summary -delay_type min_max -report_unconstrained -file $out/timing_summary.rpt
report_bus_skew -warn_on_violation -file $out/bus-skew.rpt
report_exceptions -coverage -file $out/exceptions-coverage.rpt
report_cdc -details -file $out/cdc.rpt
report_methodology -file $out/methodology.rpt
puts "SC7F0_GRAY_DIAGNOSTIC_COMPLETE: counterfactual constraints on R4 DCP; no bit/XSA export"
close_design
exit 0
