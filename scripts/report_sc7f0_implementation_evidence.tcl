# =============================================================================
# scripts/report_sc7f0_implementation_evidence.tcl
#
# Shared post-implementation evidence chain for the profiles built by
# scripts/build_zu4ev.tcl (SC7F0_PROFILE = debug | full | rgb_compositor).
#
# WHY THIS EXISTS (real gap, not a refactor for its own sake).
# scripts/check_sc7f0_timing.py grades two layers from ONE report directory:
#   Layer A  timing_summary.rpt, check-timing.rpt, cdc.rpt, methodology.rpt,
#            bus-skew.rpt and drc.rpt - DRC is mandatory there ("missing DRC
#            report ... a build that never reports DRC cannot be graded");
#   Layer B  named-constraint-evidence.json (written by
#            scripts/check_sc7f0_named_constraints.tcl, bound to the round by the
#            sha256 of cdc.rpt) plus clock-interaction.rpt, exceptions-ignored.rpt,
#            exceptions-scope-override.rpt, exceptions-coverage.rpt, io.rpt and
#            utilization_routed_hierarchical.rpt.  Each missing one is recorded as
#            "Layer B evidence report <name> was never produced".
# Before this file the chain was produced in exactly one place -
# scripts/impl_sc7f0_dual_video.tcl (report stage 571-597, hook source at 598) -
# and the only script that calls that flow pins SC7F0_PROFILE=full
# (scripts/build_sc7f0_dual_video_hw.sh:119).  scripts/build_zu4ev.tcl, which is
# the entry an SC7F0_PROFILE=rgb_compositor route actually uses, wrote six reports
# and never sourced the hook, so an RGB round could not produce a coverage manifest
# or a DRC report at any price.  That failed closed, which is honest but not
# useful: the reviewer never gets the routed coverage the RGB personality needs.
#
# What this does: writes the same chain, in the same order, with the same flags as
# the legacy full-profile script (that order is the reference and is deliberately
# not edited, so an old round and a new round stay comparable), then sources the
# Layer B producer.
#
# What this does NOT do: it approves nothing.  It does not add a REVIEWED_SAFE
# entry, does not relax WNS/TNS/hold, does not copy a clock-pair policy from an
# older round and does not invent coverage.  scripts/check_sc7f0_timing.py still
# decides, and scripts/gates/*.json still decides what may be classified safe.
#
# Contract:
#   * the caller sets ::env(SC7F0_REPORT_DIR) to an existing directory first (the
#     same contract the hook enforces), and points it at the round's own report
#     directory; nothing is written into the repository by this script;
#   * it must be sourced at Tcl level 0, because the hook creates its record arrays
#     in the CALLER's scope (its own header documents the collision that cost a
#     round of grading once);
#   * a Vivado command that fails here is a hard error, not a skipped report: a
#     chain that could not be written must stop the build, because a missing report
#     downstream is indistinguishable from a missing measurement.
# =============================================================================
if {[info level] != 0} {
    error "scripts/report_sc7f0_implementation_evidence.tcl must be sourced at Tcl level 0: scripts/check_sc7f0_named_constraints.tcl creates its record arrays in the caller's scope"
}
if {![info exists ::env(SC7F0_REPORT_DIR)]} {
    error "SC7F0_REPORT_DIR must name the directory this evidence chain is written to"
}
set sc7f0_ev_out [file normalize $::env(SC7F0_REPORT_DIR)]
if {![file isdirectory $sc7f0_ev_out]} {
    error "SC7F0_REPORT_DIR=$sc7f0_ev_out is not a directory"
}
set sc7f0_ev_hook [file normalize scripts/check_sc7f0_named_constraints.tcl]
if {![file exists $sc7f0_ev_hook]} {
    error "$sc7f0_ev_hook is missing; refusing to finish an implementation without the Layer B manifest producer"
}

# Exception audit trail.  The declarations themselves (report_exceptions without
# -coverage prints each -from/-to expression and max_dpo), the two lists that prove
# a named exception was not silently swallowed, and the summary the hook
# cross-checks.  max_delay / false_path / bus_skew / clock_group are not Tcl
# objects, so an exception can only be enumerated through this report.
report_exceptions -coverage       -file $sc7f0_ev_out/exceptions-coverage.rpt
report_exceptions                 -file $sc7f0_ev_out/exceptions-all.rpt
report_exceptions -ignored        -file $sc7f0_ev_out/exceptions-ignored.rpt
report_exceptions -scope_override -file $sc7f0_ev_out/exceptions-scope-override.rpt
report_exceptions -summary        -file $sc7f0_ev_out/exceptions-summary.rpt

# DRC is required by AGENTS.md and by Layer A.  Do not add -quiet: a DRC report
# that could not be written must abort, not read as a clean design.
report_drc -file $sc7f0_ev_out/drc.rpt
report_io -file $sc7f0_ev_out/io.rpt
report_clock_interaction -delay_type min_max -file $sc7f0_ev_out/clock-interaction.rpt
report_clock_networks -file $sc7f0_ev_out/clock-networks.rpt
# Only the user/declared disabled arcs.  The unscoped report measured 723 MB /
# 321842 rows on this design (see scripts/impl_sc7f0_dual_video.tcl:586-588), which
# is a disk incident rather than evidence.
report_disable_timing -user_disabled -file $sc7f0_ev_out/disable-timing-user.rpt
report_utilization -hierarchical -hierarchical_depth 4 \
    -file $sc7f0_ev_out/utilization_routed_hierarchical.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -file $sc7f0_ev_out/timing_summary.rpt
check_timing -verbose -file $sc7f0_ev_out/check-timing.rpt
report_cdc -details -file $sc7f0_ev_out/cdc.rpt
report_bus_skew -warn_on_violation -file $sc7f0_ev_out/bus-skew.rpt
report_methodology -file $sc7f0_ev_out/methodology.rpt

# Layer B coverage manifest.  Must run AFTER report_cdc: the manifest records the
# sha256 of cdc.rpt, so a manifest from another round cannot be reused (the gate
# rejects a hash mismatch).  The hook writes
# $SC7F0_REPORT_DIR/named-constraint-evidence.json and its own scratch subdir, and
# it records its own verdict so that a failing round still leaves complete,
# parseable evidence behind.
source $sc7f0_ev_hook
puts "SC7F0_EVIDENCE_CHAIN_WRITTEN $sc7f0_ev_out"
