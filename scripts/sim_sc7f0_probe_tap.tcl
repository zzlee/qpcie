# Helper for scripts/check_sc7f0_probe_tap_mutation.sh - runs ONE (RTL, testbench)
# pair through the real XSim/XPM flow and reports the probe-level gate.  It is the
# same model set that scripts/sim_sc7f0_reset_cdc.tcl uses; it exists separately so
# a mutated copy of rtl/sc7f0_hdmi_probe.v can be substituted without touching the
# shipped file.  Simulation only: no synthesis, no implementation, no board.
#
#   SC7F0_PROBE_RTL=<file>       rtl/sc7f0_hdmi_probe.v, or a mutant copy of it
#   SC7F0_PROBE_TB=<file>        tb/sc7f0_hdmi_probe_async_levels_tb.sv (default)
#   SC7F0_PROBE_SIM_OUT=<dir>    run directory (created)
#
#   vivado -mode batch -notrace -nojournal -source scripts/sim_sc7f0_probe_tap.tcl
#
# exit 0 only when the testbench's own gate_pass register is 1.
proc gate_value {top} {
    if {[catch {get_value "/$top/gate_pass"} v]} {
        puts "PROBE_TAP_SIM_NO_VERDICT top=$top ($v)"
        return ""
    }
    return [string trim $v]
}

set root [file normalize [file join [file dirname [info script]] ..]]
cd $root

set rtl ./rtl/sc7f0_hdmi_probe.v
if {[info exists ::env(SC7F0_PROBE_RTL)]} {set rtl $::env(SC7F0_PROBE_RTL)}
set tb ./tb/sc7f0_hdmi_probe_async_levels_tb.sv
if {[info exists ::env(SC7F0_PROBE_TB)]} {set tb $::env(SC7F0_PROBE_TB)}
set out ./build/sc7f0-probe-tap-sim
if {[info exists ::env(SC7F0_PROBE_SIM_OUT)]} {set out $::env(SC7F0_PROBE_SIM_OUT)}
file mkdir $out

create_project sc7f0_probe_tap_sim $out -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files -fileset sim_1 [list $rtl $tb]
set_property top sc7f0_hdmi_probe_async_levels_tb [get_filesets sim_1]
set_property top_type {SIM_RTL} [get_filesets sim_1]
update_compile_order -fileset sim_1

set top sc7f0_hdmi_probe_async_levels_tb
set_property top $top [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
set raw [gate_value $top]
set ok 0
if {$raw ne "" && [string range $raw end end] eq "1"} {set ok 1}
foreach sig {model_checks model_mismatches chain_mismatches early_arrivals
             cap_checks cap_mismatches src_off_edge src_stalled_changes
             bad_off_edge bad_x checks failures} {
    if {![catch {get_value -radix unsigned "/$top/$sig"} iv]} {
        puts "PROBE_TAP_SIM_EVIDENCE top=$top $sig=$iv"
    }
}
catch {close_sim}
puts "PROBE_TAP_SIM rtl=$rtl tb=$tb gate_pass_raw=$raw gate_pass=$ok"
if {$ok eq "1"} {
    puts "PROBE_TAP_SIM_PASS"
    exit 0
}
puts "PROBE_TAP_SIM_FAIL"
exit 1
