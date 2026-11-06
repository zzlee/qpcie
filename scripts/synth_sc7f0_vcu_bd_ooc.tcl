# ==============================================================================
# Phase 1 / Todo 1.2 - Out-of-context synthesis of zu4ev_ps_bd (with VCU).
#
#   source /opt/Xilinx/Vivado/2023.2/settings64.sh
#   vivado -mode batch -notrace -source scripts/synth_sc7f0_vcu_bd_ooc.tcl                    # VCU on, slim xbar
#   vivado -mode batch -notrace -source scripts/synth_sc7f0_vcu_bd_ooc.tcl 0 control sweep     # VCU off
#   vivado -mode batch -notrace -source scripts/synth_sc7f0_vcu_bd_ooc.tcl 1 sc sweep "" sc   # SmartConnect baseline
#
# Builds zu4ev_ps_bd (create_zu4ev_ps_bd 1 <vcu>) in a throw-away project under
# /tmp/opencode/sc7f0-vcu/ooc-<tag>, generates the wrapper, runs
# synth_design -mode out_of_context on the BD wrapper (launch_runs brings up the
# per-IP OOC runs as dependencies first) and writes into the scratch directory:
#   utilization_synth.rpt        device-level (CLB / BRAM / URAM / DSP / VCU)
#   utilization_synth_hier.rpt   per-BD-cell split
#   timing_summary.rpt           post-synth timing (OOC, BD-internal clocks only)
#   vcu_hard_macro.txt           evidence for the Dedicated Hard Macro account
#   ooc-summary.txt              machine readable key=value summary
# plus the vivado/console logs.  Nothing outside the scratch tree is written;
# rtl/, constraints/ and both production projects are untouched, and
# scripts/build_zu4ev.tcl still calls create_zu4ev_ps_bd without the VCU arg.
#
# Disk: scratch project incl. run DCPs is ~0.5-1 GB.  A third argument "sweep"
# deletes the *.dcp files after the reports are written.  The optional 5th
# argument picks the VCU memory interconnect style (xbar | sc) that
# create_zu4ev_ps_bd is called with.
# ==============================================================================

set vcu   1
set tag   vcu
set sweep 0
set xdc   0
set ic    {}
if {[llength $argv] >= 1} { set vcu   [lindex $argv 0] }
if {[llength $argv] >= 2} { set tag   [lindex $argv 1] }
if {[llength $argv] >= 3} { set sweep [lindex $argv 2] }
if {[llength $argv] >= 4} { set xdc   [lindex $argv 3] }
if {[llength $argv] >= 5} { set ic    [lindex $argv 4] }
if {$vcu ni {0 1}} { error "argument 1 must be 0 (no VCU) or 1 (VCU)" }

set root     [file normalize [file join [file dirname [info script]] ..]]
set part     "xczu4ev-fbvb900-2-e"
set scratch  [file normalize "/tmp/opencode/sc7f0-vcu/ooc-$tag"]
set projname "zu4ev_vcu_ooc"
set outdir   $scratch
set jobs     8

file delete -force $scratch
file mkdir $scratch
cd $scratch

puts "SC7F0_VCU_OOC_START tag=$tag vcu=$vcu part=$part scratch=$scratch xdc=$xdc ic=$ic"

create_project -force $projname $scratch/$projname -part $part
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# Same BD the production build creates, plus the optional encoder-only VCU.
source $root/scripts/create_zu4ev_ps_bd.tcl
create_zu4ev_ps_bd 1 $vcu $ic

generate_target all [get_files zu4ev_ps_bd.bd]
set bd_wrapper [make_wrapper -files [get_files zu4ev_ps_bd.bd] -top]
add_files -norecurse $bd_wrapper
set_property top zu4ev_ps_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Match the production build: no shared IP cache, so nothing is reused from, or
# written to, a cache outside the scratch tree.
catch {config_ip_cache -disable_cache} cache_msg
puts "SC7F0_VCU_OOC IP_CACHE $cache_msg"

# The BD has no XDC of its own, so a bare OOC run leaves dp_mem_clk (the
# 150 MHz memory clock that clocks smc_vcu_enc / smc_vcu_mcu / HP2 / HP3 and the
# VCU AXI side) unconstrained - report_timing_summary then only covers the two
# clocks the PS IP declares itself.  With the optional 4th argument the scratch
# project gets the same 150 MHz period the card uses on capture_clk_150m
# (300.030 MHz / 2 = 6.666 ns, constraints/zu4ev_pcie_pinout.xdc), written here
# and nowhere else, so the 150 MHz fabric becomes timing-driven.
if {$xdc eq "xdc"} {
    set xdc_file $scratch/ooc_clocks.xdc
    set fh [open $xdc_file w]
    puts $fh "# scratch-only OOC clocking for Todo 1.2 (NOT a release constraint file)"
    puts $fh "create_clock -period 6.666 -name dp_mem_clk \[get_ports dp_mem_clk\]"
    close $fh
    add_files -fileset constrs_1 $xdc_file
    puts "SC7F0_VCU_OOC XDC $xdc_file"
}

# OOC mode for the top-level synthesis run.  A run object has no ARGS.MODE
# property, so the flag travels in MORE OPTIONS; runme.log is grepped below to
# prove synthesis really ran with -mode out_of_context.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} \
    -objects [get_runs synth_1]
puts "SC7F0_VCU_OOC RUNS_BEFORE [join [get_property NAME [get_runs]] {,}]"
puts "SC7F0_VCU_OOC SYNTH_ARGS more=\[[get_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} [get_runs synth_1]]\]"

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

set run_status [get_property STATUS [get_runs synth_1]]
set run_prog   [get_property PROGRESS [get_runs synth_1]]
set run_dir    [get_property DIRECTORY [get_runs synth_1]]
puts "SC7F0_VCU_OOC RUN_STATUS progress=$run_prog status=$run_status"
foreach r [get_runs] {
    if {[get_property NAME $r] eq "synth_1"} { continue }
    puts "SC7F0_VCU_OOC DEP_RUN [get_property NAME $r] progress=[get_property PROGRESS $r] status=[get_property STATUS $r]"
}

if {$run_prog ne "100%" || [string first "ERROR" $run_status] >= 0} {
    puts "SC7F0_VCU_OOC FAIL: synth_1 progress=$run_prog status=$run_status"
    if {[file exists $run_dir/runme.log]} {
        if {![catch {exec grep -n "^ERROR" $run_dir/runme.log} e]} { puts "SC7F0_VCU_OOC RUNME_ERRORS $e" }
    }
    exit 1
}
if {[file exists $run_dir/runme.log]} {
    if {![catch {exec grep -c "synth_design.*-mode out_of_context" $run_dir/runme.log} n]} {
        puts "SC7F0_VCU_OOC OOC_MODE_LINES $n"
    }
}

open_run synth_1 -name ooc_synth

# ------------------------------------------------------------------ reports --
report_utilization -file $outdir/utilization_synth.rpt
report_utilization -hierarchical -hierarchical_depth 3 \
    -file $outdir/utilization_synth_hier.rpt
report_timing_summary -delay_type max -report_unconstrained \
    -file $outdir/timing_summary.rpt
catch {check_timing -file $outdir/check_timing.rpt}
catch {report_clock_interaction -file $outdir/clock_interaction.rpt}
catch {report_methodology -file $outdir/methodology_synth.rpt}

# ------------------------------------------------- dedicated hard macro -----
# The VCU is a hard block: it must appear as a primitive that maps to a VCU site
# and must not consume LUT / FF / BRAM / URAM.  Dump the primitive census plus
# the black-box accounts as evidence.
set prim_counts [dict create]
foreach c [get_cells -quiet -hier -filter {IS_PRIMITIVE == true}] {
    set r [get_property REF_NAME $c]
    if {$r eq ""} { set r "<none>" }
    set n 0
    if {[dict exists $prim_counts $r]} { set n [dict get $prim_counts $r] }
    dict set prim_counts $r [expr {$n + 1}]
}
set fh [open $outdir/vcu_hard_macro.txt w]
puts $fh "== primitive census (post-synth OOC netlist, top=zu4ev_ps_bd_wrapper) =="
foreach r [lsort -dictionary [dict keys $prim_counts]] {
    puts $fh "primitive $r = [dict get $prim_counts $r]"
}
puts $fh "== cells whose REF_NAME is a VCU hard macro =="
set vcu_prims [get_cells -quiet -hier -filter {IS_PRIMITIVE == true && REF_NAME =~ "VCU*"}]
puts $fh "primitives_with_VCU_ref_name = [llength $vcu_prims]"
foreach c $vcu_prims {
    puts $fh "  vcu_cell=[get_property NAME $c] ref=[get_property REF_NAME $c] group=[get_property PRIMITIVE_GROUP $c] subgroup=[get_property PRIMITIVE_SUBGROUP $c]"
}
catch {
    set st [get_site_types -quiet]
    set vcu_site [filter $st {NAME =~ "VCU*"}]
    puts $fh "part_site_types_matching_VCU = [llength $vcu_site] ([join [get_property NAME $vcu_site] {,}])"
} site_msg
puts $fh "site_type_query: $site_msg"
puts $fh "== black boxes / encrypted netlists =="
set bb [get_cells -quiet -hier -filter {IS_PRIMITIVE == false && IS_BLACKBOX == true}]
puts $fh "black_box_instances = [llength $bb]"
foreach c $bb { puts $fh "  blackbox=[get_property NAME $c] ref=[get_property REF_NAME $c]" }
close $fh
catch {exec cat $outdir/vcu_hard_macro.txt} vv
puts $vv

# ------------------------------------------------------- machine summary -----
set urpt [report_utilization -return_string]
set fh [open $outdir/ooc-summary.txt w]
puts $fh "tag=$tag vcu=$vcu part=$part top=zu4ev_ps_bd_wrapper xdc=$xdc ic=$ic"
puts $fh "run_progress=$run_prog run_status=$run_status"
# Timing headline (WNS/TNS/failing endpoints) straight from the timing report.
foreach line [split [report_timing_summary -delay_type max -report_unconstrained -return_string] "\n"] {
    if {[regexp {^\s*(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)} $line m wns tns fail total]} {
        puts $fh "timing_wns=$wns tns=$tns failing_endpoints=$fail total_endpoints=$total"
        puts "SC7F0_VCU_OOC TIMING wns=$wns tns=$tns failing=$fail endpoints=$total"
        break
    }
}
foreach line [split $urpt "\n"] {
    if {![regexp {^\|\s*([^|]+?)\s*\|\s*([0-9,.]+)\s*\|\s*([0-9,.]+)\s*\|\s*([0-9,.]+)\s*\|\s*([0-9,.]+)\s*\|\s*([0-9,.]+)\s*\|} $line m name used fixed prohib avail util]} { continue }
    set name [string trim $name]
    if {[string match "LUT*" $name] || [string match "CLB*" $name]
        || [string match "RAMB*" $name] || [string match "Block RAM*" $name]
        || [string match "URAM*" $name] || [string match "VCU*" $name]
        || [string match "DSP*" $name] || [string match "Register*" $name]
        || [string match "SLICE*" $name] || [string match "FF*" $name]} {
        puts $fh "util \"$name\" used=$used avail=$avail util=$util"
        puts "SC7F0_VCU_OOC UTIL \"$name\" used=$used avail=$avail util=$util"
    }
}
close $fh
puts "SC7F0_VCU_OOC REPORTS $outdir"

if {$sweep eq "sweep"} {
    set freed 0
    catch {exec find $scratch -name "*.dcp" -type f} dcp_list
    foreach d [split [string trim $dcp_list] "\n"] {
        if {$d eq ""} { continue }
        catch {incr freed [file size $d]}
        file delete -force $d
    }
    puts "SC7F0_VCU_OOC SWEEP freed_bytes=$freed"
}

close_project
puts "SC7F0_VCU_OOC_PASS tag=$tag vcu=$vcu ic=$ic progress=$run_prog"
exit 0
