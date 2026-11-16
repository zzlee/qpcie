# Source-registered 300 MHz Gray status counters of the SC7F0-RGB overlay writer
# to the 125 MHz CSR shell: rtl/sc7f0_overlay_writer.v u_frames (frames_done),
# u_beats (bytes written) and u_errf (dropped frames), all WIDTH=32, each strictly
# +1 per increment (the lossless case xpm_cdc_gray documents).
#
# Why a project constraint is needed at all.  The XPM ships its own scoped
# constraints for this primitive (/opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_cdc/
# tcl/xpm_cdc_gray.tcl:1-27): set_max_delay -datapath_only <source period> from
# src_gray_ff_reg* to dest_graysync_ff_reg[0]*, set_bus_skew <min(source,
# destination period)>, plus an internal CDC-6 waiver.  Those two sizes come from
# `get_clocks -quiet -of [get_ports src_clk]`, with a documented fallback of
# src_clk_period=1000 / dest_clk_period=1001 ns when that query resolves to nothing.
# Whether that scoped file attaches to a MANUALLY instantiated XPM at all (this is
# one: xpm_cdc_gray #(...) u_frames, not an IPI IP instance), and what get_ports
# resolves to there, is NOT established by this file and is not claimed either way:
# no routed RGB round has been run with these constraints yet.  What is certain is
# that neither outcome is acceptable here - 1000 ns on a 300 MHz -> 125 MHz Gray
# crossing is the absence of a constraint, and no attachment at all leaves the
# crossing timed only by the default exception.  So the numbers below follow the
# VENDOR FORM with THIS design's real clocks, and the evidence that decides is
# report_exceptions -scope_override plus the routed re-check:
# scripts/check_sc7f0_overlay_gray.tcl fails unless REQUIREMENT == 3.333 and
# LOGIC_LEVELS == 0 on every named endpoint pair, and unless report_bus_skew has a
# row for them.
#
# Numbers: source = mem_clk = capture_clk = 300 MHz -> one source period = 3.333 ns
# (the vendor's max_delay value), destination = pcie_user_clk = 125 MHz -> min(
# 3.333, 8.000) = 3.333 ns for the bus skew.  Nothing is false-pathed and no clock
# group is declared: a Gray word that arrives late is recoverable, one that arrives
# mixed is not, and the destination samples a stable 2-FF-synchronised word either way.
#
# Tcl in this file.  XDC is read by a restricted interpreter that blocks file and
# network access but DOES evaluate ordinary Tcl control flow (if / foreach /
# llength); the older comment here claimed those commands were ignored, which is
# wrong.  Control flow is still kept to one guard, as policy.
#
# That guard is the point of writing it out.  An empty -from/-to collection is not
# "no constraint": the exception then applies over EVERY endpoint of the device, i.e.
# it becomes a global 3.333 ns max_delay plus a global bus-skew requirement, silently
# un-timing the rest of the design and reporting as a clean route.  So the file
# refuses to apply anything unless the named 32 source and 32 first-stage destination
# FFs of each crossing are all present, and it fails at constraint-read time
# (implementation start, minutes into the run) rather than after a full place and
# route.  scripts/check_sc7f0_overlay_gray.tcl stays as the routed re-check: this
# guard is a preflight, not a substitute, and it approves no CDC policy.
#
# Mounted by scripts/build_zu4ev.tcl only for SC7F0_PROFILE=rgb_compositor, with
# USED_IN_SYNTHESIS false and PROCESSING_ORDER LATE: implementation-only, read when
# the netlist exists, constraining place and route.  rtl/custom_pcie_dma_top.v:1770
# puts u_overlay_writer under `ifdef SC7F0_RGB_COMPOSITOR`, so in any other profile
# these patterns would match nothing - which, per the paragraph above, is exactly the
# failure mode the guard exists to catch rather than something to mount and hope.
# The guard is unconditional on purpose.  This file is mounted for the profile that
# contains the writer and for no other, so a mismatch here is always a broken name or a
# missing instance, never a legitimate other-profile case.
# The tails are brace-quoted ONCE and appended, never interpolated inside double
# quotes: a double-quoted Tcl string command-substitutes [0-9], which is how a guard
# like this silently becomes "invalid command name 0-9" instead of a missing-cell
# report (a stub resolver catches exactly that; see
# scripts/tests/fixtures/overlay_gray_xdc_stub.tcl).
set sc7f0_ovw_guard 1
if {$sc7f0_ovw_guard} {
    foreach sc7f0_ovw_blk {u_frames u_beats u_errf} {
        set sc7f0_ovw_pat {.*u_overlay_writer/}
        append sc7f0_ovw_pat $sc7f0_ovw_blk {/src_gray_ff_reg\[[0-9]+\]}
        set sc7f0_ovw_s [get_cells -hier -regexp $sc7f0_ovw_pat]
        set sc7f0_ovw_pat {.*u_overlay_writer/}
        append sc7f0_ovw_pat $sc7f0_ovw_blk {/dest_graysync_ff_reg\[0\]\[[0-9]+\]}
        set sc7f0_ovw_d [get_cells -hier -regexp $sc7f0_ovw_pat]
        if {[llength $sc7f0_ovw_s] != 32 || [llength $sc7f0_ovw_d] != 32} {
            error "SC7F0_OVERLAY_GRAY_MISSING: $sc7f0_ovw_blk matched [llength $sc7f0_ovw_s] src_gray_ff and [llength $sc7f0_ovw_d] dest_graysync_ff first-stage cells, expected 32 of each; refusing to apply a -from/-to exception over an empty endpoint collection"
        }
    }
}
set ovw_gray_src [get_cells -hier -regexp {.*u_overlay_writer/u_(frames|beats|errf)/src_gray_ff_reg\[[0-9]+\]}]
set ovw_gray_dst [get_cells -hier -regexp {.*u_overlay_writer/u_(frames|beats|errf)/dest_graysync_ff_reg\[0\]\[[0-9]+\]}]
if {$sc7f0_ovw_guard && ([llength $ovw_gray_src] != 96 || [llength $ovw_gray_dst] != 96)} {
    error "SC7F0_OVERLAY_GRAY_MISSING: the union matched [llength $ovw_gray_src]/[llength $ovw_gray_dst] cells, expected 96/96 (3 crossings x 32 bits)"
}
set_max_delay -datapath_only 3.333 -from $ovw_gray_src -to $ovw_gray_dst
set_bus_skew 3.333 -from $ovw_gray_src -to $ovw_gray_dst
