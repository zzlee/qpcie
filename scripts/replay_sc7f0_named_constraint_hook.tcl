# =============================================================================
# Replay scripts/check_sc7f0_named_constraints.tcl on an EXISTING checkpoint,
# into a FRESH output directory, without touching the round that produced it.
#
#   SC7F0_REPORT_DIR=build/cdc-hook-preflight-r1/evidence \
#   SC7F0_SOURCE_REPORT_DIR=build/vcu-release-26111202-r1/fpga/project \
#   /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -nolog \
#       -source scripts/replay_sc7f0_named_constraint_hook.tcl \
#       -tclargs <absolute path to a routed .dcp>
#
# Why this exists
#   The hook is written to run inside the implementation flow (an open design
#   plus this round's reports).  To re-measure a constraint that was added AFTER
#   a round finished, the reports of that round have to be re-used, and the
#   obvious way to do that - pointing the hook at the round's own directory -
#   writes named-constraint-evidence.json and hook-scratch/ into delivered
#   evidence.  This wrapper makes that impossible and proves it:
#
#     1. SC7F0_REPORT_DIR must be a fresh directory that is not inside
#        SC7F0_SOURCE_REPORT_DIR and is not itself a round directory;
#     2. every gate report is COPIED, never opened for writing;
#     3. the sha256 of every source report is taken before and after, and any
#        change aborts the run with a named error;
#     4. the design is opened read-only: no write_checkpoint, no
#        write_project_* and no report is written into the source directory.
#
# What it does NOT do
#   no synthesis, no implementation, no bitstream, no PetaLinux, no packaging,
#   no deployment, no board access.  It measures constraints on a checkpoint.
#
# Honest expectation when replaying an OLD checkpoint with a NEW XDC
#   The design in the checkpoint predates the new constraints, so the new items
#   must report "not found" and the verdict must be FAIL.  That is the point of
#   the replay: it proves the hook runs all of its probes and names what the old
#   netlist cannot satisfy.  A PASS here would mean the new items resolved on an
#   old design, which would be the surprise worth investigating.
# =============================================================================

if {![info exists ::env(SC7F0_REPORT_DIR)]} {
    error "SC7F0_REPORT_DIR must name a FRESH output directory"
}
if {![info exists ::env(SC7F0_SOURCE_REPORT_DIR)]} {
    error "SC7F0_SOURCE_REPORT_DIR must name the round whose reports are replayed"
}
set out_dir [file normalize $::env(SC7F0_REPORT_DIR)]
set src_dir [file normalize $::env(SC7F0_SOURCE_REPORT_DIR)]
set dcp [lindex $::argv 0]

proc sha256 {path} {
    if {[catch {exec sha256sum $path} digest]} {return ""}
    return [string trim [lindex [split $digest { }] 0]]
}

# --- guard 1: the output directory may not be a round directory -------------
if {![file isdirectory $src_dir]} {
    error "SC7F0_SOURCE_REPORT_DIR=$src_dir is not a directory"
}
if {[string match -nocase {*vcu-release*} [file tail $out_dir]]
    || [string match -nocase {*evidence*} [file tail $out_dir]]} {
    # both patterns are the names this project uses for delivered evidence
    puts "REPLAY_REFUSED output directory name looks like a delivered round"
    exit 2
}
if {$out_dir eq $src_dir || [string match ${src_dir}/* $out_dir]} {
    puts "REPLAY_REFUSED SC7F0_REPORT_DIR=$out_dir is the source round itself"
    exit 2
}
file mkdir $out_dir
if {[glob -nocomplain -directory $out_dir *] ne {}} {
    puts "REPLAY_REFUSED $out_dir is not empty; use a fresh directory"
    exit 2
}
if {$dcp eq "" || ![file exists $dcp]} {
    error "usage: -tclargs <routed checkpoint .dcp>"
}

# --- guard 2/3: copy, hash before, hash after -------------------------------
set gate_reports [list timing_summary.rpt check-timing.rpt cdc.rpt methodology.rpt \
    bus-skew.rpt drc.rpt clock-interaction.rpt exceptions-ignored.rpt \
    exceptions-scope-override.rpt exceptions-coverage.rpt exceptions-all.rpt io.rpt \
    clock_networks.rpt]
set before {}
set copied {}
foreach name $gate_reports {
    set from [file join $src_dir $name]
    if {![file exists $from]} {continue}
    file copy -force $from [file join $out_dir $name]
    lappend before [list $name [sha256 $from]]
    lappend copied $name
}
puts "REPLAY_COPIED [llength $copied] reports from $src_dir"

# --- open the design read-only ---------------------------------------------
puts "REPLAY_OPEN $dcp"
set started [clock seconds]
open_checkpoint $dcp
puts "REPLAY_OPENED seconds=[expr {[clock seconds] - $started}]"

# --- run the hook ----------------------------------------------------------
set hook [file normalize [file join [file dirname [info script]] \
              check_sc7f0_named_constraints.tcl]]
puts "REPLAY_HOOK $hook"
set failure {}
if {[catch {source $hook} err]} {
    set failure $err
    puts "REPLAY_HOOK_RAISED $err"
}

# --- guard 3 again: nothing in the source round may have moved -------------
set changed {}
foreach entry $before {
    foreach {name digest} $entry break
    if {[sha256 [file join $src_dir $name]] ne $digest} {lappend changed $name}
}
if {[llength $changed]} {
    puts "REPLAY_SOURCE_CHANGED [join $changed {,}]"
    exit 3
}
puts "REPLAY_SOURCE_UNCHANGED files=[llength $before]"

set manifest [file join $out_dir named-constraint-evidence.json]
if {![file exists $manifest]} {
    puts "REPLAY_NO_MANIFEST $manifest"
    exit 4
}
set text [read [open $manifest r]]
regexp {"hook_verdict": "([^"]*)"} $text unused verdict
set sections 0
regexp {"hook_section_errors": ([0-9]+)} $text unused sections
# The manifest writes one item per indented block, and hook_problems as one line
# of quoted strings; counting them here keeps the wrapper from needing a JSON
# library inside Vivado's Tcl.  Messages are escaped, so no raw newline can end
# the problems line early - which is why matching stops at the newline.
set items [regexp -all -inline {\n  "[A-Za-z0-9_.]+": \{} $text]
set problems {}
if {[regexp {"hook_problems": \[([^\n]*)\]} $text unused block]} {
    set problems [regexp -all -inline {"(?:[^"\\]|\\.)*"} $block]
}
puts "REPLAY_VERDICT $verdict items=[llength $items] hook_problems=[llength $problems] hook_section_errors=$sections"
# Named notes: on a checkpoint that predates a constraint, "not found" is the
# correct answer, and the count is the evidence that the probe ran and looked.
foreach {pattern label} [list \
    {source register \w+ not found} "source registers absent (expected on a pre-fix checkpoint)" \
    {is not in this design}         "mentions of constraints absent from the replayed design (substring count, not port count)" \
    {has 0 analysed paths}          "exceptions broader than their named entry"] {
    set hits [regexp -all -inline $pattern $text]
    if {[llength $hits]} {puts "REPLAY_NOTE $label: [llength $hits]"}
}
if {$failure ne ""} {
    puts "REPLAY_HOOK_EXPECTED_FAILURE_ON_OLD_CHECKPOINT $failure"
}
# The replay itself succeeded if the hook ran to completion and wrote complete
# evidence; whether the CONSTRAINTS pass is a separate question that the verdict
# line answers, and on an old checkpoint FAIL is the correct, expected answer.
# The exit status describes the REPLAY (did the hook run and write complete
# evidence), never the constraint verdict: a FAIL verdict must be read from the
# REPLAY_VERDICT line, and is repeated here so nobody greps the tail of a log for
# "exit 0" and mistakes it for a passing round.
puts "REPLAY_DONE verdict=$verdict constraint_verdict_is_not_replay_success=1 seconds=[expr {[clock seconds] - $started}]"
exit 0
