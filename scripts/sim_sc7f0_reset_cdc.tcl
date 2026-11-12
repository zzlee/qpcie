# Local reset/probe RTL simulation gate.  Read-only with respect to the repo: it
# only creates a throwaway project under build/.  Never flashes, never touches a
# board, never writes outside the output directory.
#
#   vivado -mode batch -notrace -nojournal -source scripts/sim_sc7f0_reset_cdc.tcl
#
#   SC7F0_RESET_SIM_OUT=<dir>    output/run directory
#   SC7F0_RESET_SIM_WAVE=1       also log every signal and write waves.wdb
#
# Uses the real XPM libraries (XPM_CDC, XPM_FIFO, XPM_MEMORY) so the vendor
# synchronizer, array_single and FIFO models are the ones under test, not a
# hand-written stand-in.  There is deliberately no local xpm stub: a stub that
# reports "never in reset" would make the whole gate meaningless.
#
# Two testbenches, both must pass:
#   sc7f0_reset_cdc_tb                reset-domain rework (rtl/sc7f0_reset_cdc.v,
#                                     rtl/sc7f0_dp_fifo.v)                 S0..S7
#   sc7f0_hdmi_probe_async_levels_tb  seven foreign-domain diagnostic levels
#                                     (rtl/sc7f0_hdmi_probe.v)             P0..P6
proc run_gate {top out wave} {
    set_property top $top [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation
    if {$wave} { catch {log_wave -r /} }
    run all
    set ok 0
    if {[catch {get_value "/$top/gate_pass"} v]} {
        puts "RESET_CDC_SIM_NO_VERDICT top=$top ($v)"
    } else {
        # xsim reports a single-bit register as "1"/"0", not "1'b1"; comparing
        # only against "1'b1" (as the first revision of this script did) silently
        # reported GATE_FAIL even when the testbench printed GATE_PASS.
        set ok [expr {[string range [string trim $v] end end] eq "1"}]
        puts "RESET_CDC_SIM_TOP top=$top gate_pass_raw=$v gate_pass=$ok"
    }
    # Evidence counters, printed so a reviewer can see they are non-zero/live
    # rather than trusting a bare PASS string.
    foreach sig {comb_runts old_runts ignored_time_zero cons_half_reset cons_moving
                 releases bad_valid_edge bad_off_edge bad_x model_checks model_mismatches
                 chain_mismatches early_arrivals cap_checks cap_mismatches
                 src_off_edge src_stalled_changes checks failures} {
        if {![catch {get_value -radix unsigned "/$top/$sig"} iv]} {
            puts "RESET_CDC_SIM_EVIDENCE top=$top $sig=$iv"
        }
    }
    if {$wave} {
        catch {write_db -file [file join $out "waves-$top.wdb"]}
    }
    catch {close_sim}
    return $ok
}

set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out ./build/sc7f0-reset-cdc-sim
if {[info exists ::env(SC7F0_RESET_SIM_OUT)]} {set out $::env(SC7F0_RESET_SIM_OUT)}
file mkdir $out
set wave 0
if {[info exists ::env(SC7F0_RESET_SIM_WAVE)] && $::env(SC7F0_RESET_SIM_WAVE) eq "1"} {
    set wave 1
}
create_project sc7f0_reset_cdc_sim $out -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files -fileset sim_1 [concat \
    [list ./rtl/sc7f0_reset_cdc.v ./rtl/sc7f0_dp_fifo.v ./rtl/sc7f0_hdmi_probe.v] \
    [list ./tb/sc7f0_reset_cdc_tb.sv ./tb/sc7f0_hdmi_probe_async_levels_tb.sv]]
set_property top sc7f0_reset_cdc_tb [get_filesets sim_1]
set_property top_type {SIM_RTL} [get_filesets sim_1]
update_compile_order -fileset sim_1

set reset_ok [run_gate sc7f0_reset_cdc_tb $out $wave]
set probe_ok [run_gate sc7f0_hdmi_probe_async_levels_tb $out $wave]

# The gate flags are registers inside the testbenches, so the verdict cannot
# depend on log parsing or on where the simulator wrote its transcript.
puts "RESET_CDC_SIM_VERDICT reset_domain_gate=$reset_ok probe_levels_gate=$probe_ok"
if {$reset_ok && $probe_ok} {
    puts "RESET_CDC_SIM_GATE_PASS"
    exit 0
}
puts "RESET_CDC_SIM_GATE_FAIL"
exit 1
