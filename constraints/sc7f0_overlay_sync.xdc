# =============================================================================
# DO NOT MOUNT THIS FILE.  It is kept as the analysis record of the three overlay
# synchroniser crossings; the LIVE application of exactly these numbers moved to
# scripts/apply_sc7f0_overlay_cdc.tcl, reached from the full-Tcl implementation
# PRE hook (STEPS.OPT_DESIGN.TCL.PRE = scripts/impl_pre_opt_sc7f0.tcl), because
# the managed read_xdc reader drops `if`/`concat`/variables:
# rgb-fullimpl-26111333-20261113T204036Z logs/build_full26111333.log:3800-3804
# ([Designutils 20-1307] 'if'/'concat' not supported, then [Common 17-1548]
# can't read "sc7f0_ovs_dst") prove that nothing below line 104 was applied in
# that round.  Mounting this file again would reproduce a silently missing
# exception; scripts/build_zu4ev.tcl no longer adds it to constrs_1.
#
# constraints/sc7f0_overlay_sync.xdc
#
# Named, BOUNDED first-stage exceptions for the three hand-rolled single-bit
# asynchronous synchronizers of the SC7F0-RGB overlay path, all of which cross
# pcie_user_clk (PCIe user, 8.000 ns) into capture_clk_300m / mem_clk
# (300 MHz, 3.333 ns):
#
#   1. rtl/sc7f0_overlay_writer.v:1197  (* ASYNC_REG = "TRUE" *) reg [2:0]
#      epoch_sync_l, stage 0 samples epoch_rst_n (the PCIe epoch/shell reset as
#      it leaves u_pcie_ip).
#   2. rtl/sc7f0_overlay_writer.v:1327  reg [1:0] poison_sync, stage 0 samples
#      debt_poison_epoch, a pcie_user_clk register of the same module.
#   3. rtl/sc7f0_overlay_ingress.v:950  reg sync0/sync1, stage 0 samples
#      arm_toggle, the pcie_user_clk arm toggle of the same module.
#
# Why these three paths cannot be timed as they are.  Measured on the routed
# candidate rgb-fullimpl-26111331-20261113T194329Z (this is the round that
# produced the numbers, evidence-r1/worst-paths-routed.rpt and
# impl_1/zu4ev_pcie_card_top_timing_summary_routed.rpt:42154, :42220, :42283):
#
#   user_reset_reg (pcie_user_clk) -> epoch_sync_l_reg[0]   -1.109 ns, 1 LUT,
#       data path 1.720 ns (0.132 logic + 1.588 route), requirement 0.337 ns
#   debt_poison_epoch_reg          -> poison_sync_reg[0]    -0.923 ns, 0 logic,
#       data path 1.421 ns, requirement 0.337 ns
#   arm_toggle_reg (ingress)       -> sync0_reg             -0.913 ns, 0 logic,
#       data path 1.448 ns, requirement 0.337 ns
#
# 0.337 ns is not a length the data has to travel: it is the gap between the
# 125 MHz launch edge and the *earliest possible* 300 MHz capture edge, i.e. the
# engine is timing an asynchronous crossing as if the two clocks were locked.
# Those three endpoints are the whole design's WNS and the only reason the round
# reports WNS < 0 outside its own 300 MHz groups.  The data path itself is
# 0-1 logic levels and 1.4-1.7 ns, so the fix is a proper exception, and the
# path still has to stay short - which is exactly what a bounded max_delay keeps.
#
# Why an exception here is legitimate and what it does NOT do.  Each destination
# is the FIRST stage of a 2-3 FF synchroniser chain (ASYNC_REG-tagged where the
# RTL tags it); the design's correctness never depends on when the first stage
# resolves, only on the stages behind it, and each crossing carries one level or
# one toggle that is held until it is seen (epoch_rst_n is a level,
# debt_poison_epoch is a level, arm_toggle is a persistent toggle compared
# against arm_last, so no event can be lost by extra latency).  AMD's own scoped
# constraint for this primitive is stronger still -
# /opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_single.tcl applies
# `set_false_path -to syncstages_ff_reg[0]`.  A false path is deliberately NOT
# copied here: this file uses a BOUNDED set_max_delay -datapath_only, which is
# stricter than the vendor form, keeps the crossing placed and routed short, and
# still leaves every path timable.  Nothing in this file declares a clock group,
# a false path, a multicyle path, a disabled arc or a lowered clock, and it does
# not touch any endpoint outside the three named first-stage FFs.
#
# The number.  min(source period, destination period) = min(8.000, 3.333) =
# 3.333 ns: one destination period, i.e. 2.4x tighter than the source-period rule
# the vendor uses for xpm_cdc_gray, and a bound this candidate already meets with
# margin (worst arrival 1.720 ns of 3.333 ns on round 26111331).  The tighter of
# the two sizes is chosen so the exception cannot be used as a disguised way to
# stop timing the crossing; it is a length limit on the network in front of the
# first stage, NOT a claim about MTBF, which depends on the synchroniser stages
# behind it (they exist, and scripts/check_sc7f0_overlay_sync.tcl requires them).
#
# The guard, and why it is before the constraint.  An empty -to collection is not
# "no constraint": set_max_delay then applies to EVERY endpoint of the device and
# silently un-times the design while reporting a clean route.  So the file first
# requires exactly one cell per named first-stage FF and errors at constraint
# read time (minutes into implementation, not after a full route) otherwise.
# The routed evidence is produced twice on purpose, and neither copy approves
# anything:
#   * scripts/apply_sc7f0_overlay_cdc.tcl (the LIVE application, see the banner
#     above) applies the bound in the full-Tcl implementation PRE hook and proves
#     in the same run, before placement, that the timing engine took it;
#   * scripts/check_sc7f0_overlay_sync.tcl re-measures it on the routed netlist:
#     per named endpoint it reads the real STARTPOINT/ENDPOINT clock names, the
#     REQUIREMENT the engine applied, the logic depth and the existence of the
#     second synchroniser stage, and it refuses (a) no path at all - which is what
#     a false path or a clock group would leave, (b) a requirement other than
#     3.333 ns, (c) a first stage with no second stage, (d) a source clock other
#     than pcie_user_clk.
# In addition, scripts/check_sc7f0_named_constraints.tcl carries three measurement
# rows for these crossings (overlay_epoch_sync_max_delay /
# overlay_poison_sync_max_delay / overlay_arm_sync_max_delay) so the Layer B
# manifest records object counts, timed paths and max_delay_measured_ns.  No
# review verdict is written anywhere: scripts/gates/*.json has no REVIEWED_SAFE
# entry for them, so the gate keeps failing them closed until a reviewer decides.
# A bounded max_delay in front of a first stage is not an MTBF proof by itself -
# metastability resolution is the property of the synchroniser stages behind it
# (present, and required by the checker); the bound only keeps the network in
# front of the first stage short and timable.
#
# Mounting: this file is NOT added to constrs_1 by scripts/build_zu4ev.tcl (see
# the banner).  The RGB-only rule now lives in scripts/impl_pre_opt_sc7f0.tcl,
# which sources scripts/apply_sc7f0_overlay_cdc.tcl only when
# SC7F0_RGB_COMPOSITOR is set; rtl/custom_pcie_dma_top.v puts both instances under
# `ifdef SC7F0_RGB_COMPOSITOR`, so in any other profile these patterns would match
# nothing - the failure mode the guards exist to catch.
#
# Two further reader facts, both measured in Vivado 2023.2 and both recorded here
# so no future round re-discovers them by burning a route:
#   * [Designutils 20-1307] "Command 'if' is not supported" / "Command 'concat'
#     is not supported": control flow in a mounted .xdc is dropped with a
#     CRITICAL WARNING and the run continues without the constraint
#     (rgb-fullimpl-26111333 logs/build_full26111333.log:3796-3804);
#   * [Constraints 18-540] "set_max_delay -datapath_only requires -from to be
#     non-empty": a -to-only datapath-only bound is not accepted, so the source
#     registers must be resolved and guarded (rgb-fullimpl-26111334
#     logs/build_full26111334.log, which is why the helper below is not the
#     application any more).
#
# Everything from here down is the original (unmounted) declarative attempt, kept
# only as the record of the object patterns and the numbers; the live application
# is scripts/apply_sc7f0_overlay_cdc.tcl.
#
# Tcl in XDC: the restricted interpreter blocks file/network access but does
# evaluate ordinary control flow; control flow is kept to the one guard below,
# and every regex tail is brace-quoted and appended (a double-quoted Tcl string
# would command-substitute [0-9] instead of matching it).
# =============================================================================
set sc7f0_ovs_guard 1
if {$sc7f0_ovs_guard} {
    foreach sc7f0_ovs_pat {
        {.*u_overlay_writer/epoch_sync_l_reg\[0\]$}
        {.*u_overlay_writer/poison_sync_reg\[0\]$}
        {.*u_overlay_ingress/sync0_reg$}
    } {
        set sc7f0_ovs_hit [get_cells -quiet -hier -regexp $sc7f0_ovs_pat]
        if {[llength $sc7f0_ovs_hit] != 1} {
            error "SC7F0_OVERLAY_SYNC_MISSING: $sc7f0_ovs_pat matched [llength $sc7f0_ovs_hit] cells, expected exactly 1 first-stage synchroniser FF; refusing to apply a -to exception over an empty or ambiguous endpoint collection"
        }
    }
}
set sc7f0_ovs_dst [concat \
    [get_cells -quiet -hier -regexp {.*u_overlay_writer/epoch_sync_l_reg\[0\]$}] \
    [get_cells -quiet -hier -regexp {.*u_overlay_writer/poison_sync_reg\[0\]$}] \
    [get_cells -quiet -hier -regexp {.*u_overlay_ingress/sync0_reg$}]]
if {$sc7f0_ovs_guard && [llength $sc7f0_ovs_dst] != 3} {
    error "SC7F0_OVERLAY_SYNC_MISSING: the union of the three named first-stage FFs resolved to [llength $sc7f0_ovs_dst] cells, expected 3"
}
set_max_delay -datapath_only 3.333 -to $sc7f0_ovs_dst
