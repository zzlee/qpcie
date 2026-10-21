# ==============================================================================
# Resume implementation/bitstream for an already synthesized SC7F0 project.
#
# The reference synthesis run (scripts/build_zu4ev.tcl, SC7F0_BUILD_STAGE=synth)
# is expensive and its result is deterministic. This script re-opens that exact
# project instead of re-running create_project/IP generation, so the routed
# build is provably based on the reviewed netlist.
#
# Environment:
#   SC7F0_PROJECT_DIR  existing project directory (required)
#   SC7F0_XSA_OUT      candidate XSA path (default ./build/sc7f0_candidate.xsa)
#   SC7F0_GATE_STRICT  1 (default) = do not export XSA if the timing gate fails
#
# Usage:
#   vivado -mode batch -notrace -source scripts/impl_zu4ev_existing.tcl \
#     -log ... -journal ...
# ==============================================================================

set project_name "qpcie_zu4ev_card"
if {![info exists ::env(SC7F0_PROJECT_DIR)]} {
    error "SC7F0_PROJECT_DIR must point at a synthesized project"
}
set project_dir $::env(SC7F0_PROJECT_DIR)
set xsa_out "./build/sc7f0_candidate.xsa"
if {[info exists ::env(SC7F0_XSA_OUT)]} {set xsa_out $::env(SC7F0_XSA_OUT)}
set strict 1
if {[info exists ::env(SC7F0_GATE_STRICT)]} {set strict $::env(SC7F0_GATE_STRICT)}

set xpr "$project_dir/$project_name.xpr"
if {![file exists $xpr]} {
    error "synthesized project not found: $xpr"
}
puts " Opening synthesized project: $xpr"
open_project $xpr

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synth_1 is not complete; rerun scripts/build_zu4ev.tcl -stage synth"
}

# A resumed run must not silently reuse a stale routed result from another
# source revision: the caller is expected to use a fresh project directory.
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "Starting Implementation & Bitstream Generation (impl_1)..."
    launch_runs impl_1 -to_step write_bitstream -jobs 16
    wait_on_run impl_1
} else {
    puts " impl_1 already complete; regenerating reports from the routed design"
}

set impl_status [get_property STATUS [get_runs impl_1]]
if {[get_property PROGRESS [get_runs impl_1]] != "100%" ||
    [string first "ERROR" $impl_status] >= 0 ||
    [string first "write_bitstream Complete" $impl_status] < 0} {
    error "implementation/bitstream failed: $impl_status"
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set probes_out "$impl_dir/zu4ev_pcie_card_top.ltx"
write_debug_probes -force $probes_out
puts " ILA debug probes: $probes_out"
foreach f [glob -nocomplain "$impl_dir/*.bit"] {
    puts " Bitstream: $f ([file size $f] bytes)"
}

report_timing_summary -delay_type min_max -report_unconstrained -file $project_dir/timing_summary.rpt
check_timing -verbose -file $project_dir/check-timing.rpt
report_cdc -details -file $project_dir/cdc.rpt
report_methodology -file $project_dir/methodology.rpt
report_bus_skew -file $project_dir/bus-skew.rpt
report_clock_interaction -file $project_dir/clock-interaction.rpt

# Fail closed for BOTH profiles: a .bit alone is never a release.
set gate_ok 1
if {[catch {exec python3 ./scripts/check_sc7f0_timing.py $project_dir} gate_result]} {
    set gate_ok 0
    puts "TIMING_GATE_FAIL: routed design did not pass check_sc7f0_timing.py"
    puts $gate_result
} else {
    puts $gate_result
}

if {!$gate_ok && $strict} {
    puts "ERROR: timing/CDC/DRC gate failed; candidate XSA NOT exported."
    exit 2
}
if {!$gate_ok} {
    puts "WARNING: non-strict mode; exporting a candidate XSA that is NOT deployable."
}

file mkdir [file dirname $xsa_out]
puts "Exporting candidate Hardware Platform XSA ($xsa_out)..."
write_hw_platform -fixed -include_bit -force $xsa_out
puts "XSA_EXPORTED: $xsa_out"
close_project
exit 0
