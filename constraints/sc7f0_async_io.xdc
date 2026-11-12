# =============================================================================
# SC7F0 named asynchronous IO exceptions (Layer B itemised exceptions)
# =============================================================================
# Rules this file follows, and why it is written the way it is:
#
#   1. No broad clock group and no whole-clock cut.  Every exception names one
#      port and, where the consumer set is proven, only that consumer's FIRST
#      synchroniser stage (`-to <chain[0]>`), so a consumer added later is never
#      silently excepted and check_timing keeps reporting the port until all of
#      its loads are reviewed.
#   2. No invented numbers.  None of these pads has a reference clock that a
#      set_input_delay/set_output_delay could legitimately be taken from, so the
#      exceptions are timing-path exceptions with a stated structural reason, not
#      fabricated delays taken from an unrelated clock.
#   3. Plain XDC commands only: this project's own lesson (see
#      constraints/sc7f0_capture_gray.xdc) is that if/foreach are ignored in a
#      constraint file.  All object-count checks live in
#      scripts/check_sc7f0_named_constraints.tcl, which runs in the
#      implementation hook with full Tcl and writes the per-item evidence used by
#      scripts/gates/sc7f0_cdc_review.json io_items.
#   4. Since round 26111202 the file also carries the six NAMED INTERNAL async
#      entries of rtl/sc7f0_hdmi_probe.v (`-from <source-domain flop> -to
#      <chain[0]>`), for the same reason it carries the pad entries: a flop-to-flop
#      asynchronous entry has to name both ends, and it is applied at implementation
#      time (USED_IN_SYNTHESIS false, PROCESSING_ORDER LATE) because it refers to
#      post-synthesis cell names.  See the two sections at the bottom.
#   5. Ports whose consumer set is NOT fully proven must stay out of this file, so
#      they remain HIGH in check_timing and fail Layer A.  The RX DDC pair and the
#      TX TMDS clock pads used to be there; they are now written as named,
#      per-consumer / per-port exceptions because the routed evidence closed the
#      structural questions (see the two sections at the bottom), and every one of
#      them is re-measured by scripts/check_sc7f0_named_constraints.tcl against
#      scripts/gates/sc7f0_cdc_review.json io_items.  What is still NOT written
#      here, and must not be, is any -from-port blanket exception and any invented
#      input/output delay.
#
# Measured first-stage structures: build/evidence-dcpio-26111106/query/
# s1-pad-first-stage.txt, s1-endpoints.csv, summary.json (items.item1_rx_ddc).

# -----------------------------------------------------------------------------
# Outputs with no timing relationship to any clock (quasi-static levels).
# A top-level output port can have no other load, so -to the port is complete.
# -----------------------------------------------------------------------------
set_false_path -to [get_ports {user_led_dma_active user_led_pcie_link_up}]

# HDMI RX HPD assert level driven by the RX subsystem; HPD is a millisecond
# protocol level (no FPGA-side reference clock), and the read-back copy is
# already an ASYNC_REG 2FF in the pcie_user_clk domain
# (rtl/zu4ev_pcie_card_top.v:960, :1149-1156).  Layer B keeps the port's pulse
# width question open in sc7f0_cdc_review.json io_items.async_out_hpd.
set_false_path -to [get_ports hdmi_rx_hpd_out]

# -----------------------------------------------------------------------------
# Inputs: exception limited to the measured first-stage flop of the named
# ASYNC_REG chain, never to the whole clock and never to the port alone.
# rtl/sc7f0_hdmi_probe.v:286-293 declares all eight 3-stage ASYNC_REG chains and
# :342-350 resets them from the pl_clk0 (clk_pl_0) domain only.
# -----------------------------------------------------------------------------

# TX HPD input: probe chain is the only sequential consumer in the
# SC7F0_C2H_ONLY personality (TX subsystem not built, rtl/zu4ev_pcie_card_top.v:1287).
set_false_path -from [get_ports hdmi_tx_hpd_in] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/tx_hpd_sync_reg\[0\]}]

# TX DDC observation pair (drivers tri-stated in this personality):
# rtl/zu4ev_pcie_card_top.v:758, :1292; the pad's own OBUFT->INBUF feedback arcs
# are the only user-disabled arcs in the design (report_disable_timing).
set_false_path -from [get_ports hdmi_tx_ddc_scl] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/tx_scl_sync_reg\[0\]}]
set_false_path -from [get_ports hdmi_tx_ddc_sda] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/tx_sda_sync_reg\[0\]}]

# 5V cable detect: async level sampled by three measured ASYNC_REG first stages -
# the probe chain, the pcie_user_clk status chain, and the RX subsystem's own
# CD_INST/DET_SYNC_INST/XPM_INST chain (s1-endpoints.csv rows 20-22,
# summary.json ...hdmi_rx_5v_det.async_reg_set=3 of 3).  One exception per chain,
# so no consumer is excepted by another one's row and a fourth consumer shows up
# as an unclaimed first stage in the coverage manifest.
set_false_path -from [get_ports hdmi_rx_5v_det] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/det5v_sync_reg\[0\]}]
set_false_path -from [get_ports hdmi_rx_5v_det] \
    -to [get_cells -hier -regexp {.*sync_5v_det_q_reg\[0\]}]
set_false_path -from [get_ports hdmi_rx_5v_det] \
    -to [get_cells -hier -regexp {.*CD_INST/DET_SYNC_INST/XPM_INST/syncstages_ff_reg\[0\]}]

# TX reference-clock lock status (G13 = X0_5319_LOL, active HIGH = not ready).
# Observed only; u_tx_link_reset uses !sys_100m_rst_n, not this pin
# (rtl/zu4ev_pcie_card_top.v:816-817), and the port gates no reset.  Both measured
# consumers get their own exception: the probe chain and the VPHY clock-detector
# chain (s1-endpoints.csv: both ASYNC_REG=1 on clk_pl_0), so the VPHY load is
# named instead of being silently covered by a -from-port cut.
set_false_path -from [get_ports hdmi_tx_refclk_rdy] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/tx_rdy_sync_reg\[0\]}]
set_false_path -from [get_ports hdmi_tx_refclk_rdy] \
    -to [get_cells -hier -regexp \
        {.*u_vid_phy_controller/inst/clock_detector_inst/TX_LOCK_CAP_INST/syncstages_ff_reg\[0\]}]

# -----------------------------------------------------------------------------
# RX DDC / EDID pair (the FPGA is the DDC slave, IT6663 P1TX drives the bus).
# Two consumers per pad, both measured (s1-endpoints.csv, summary.json
# ...hdmi_rx_ddc_scl: first_stage_cells=2, async_reg_set=1, async_reg_not_set=1,
# both on clk_pl_0 10.000 ns, endpoints_whose_pin_carries_a_clock=0):
#
#   * our own diagnostic chain u_hdmi_probe/{scl,sda}_sync_reg[0] (ASYNC_REG=1),
#   * the vendor pad-sample first stage DDC_INST/clk_{scl,sda}_flt_reg[0], whose
#     measured loads DDC_INST/clk_*_flt_reg[1] and DDC_INST/clk_*_in_reg are all in
#     the same clk_pl_0 domain and are still analysed by the timing engine.
#
# Each exception is written pad -> that first stage ONLY.  The internal filter and
# synchroniser flops keep their full-speed 10 ns timing: they are NOT excepted, and
# the coverage manifest re-measures both facts (internal_filter_same_domain and
# paths_analysed per item).  Nothing here adds an attribute to, or edits, vendor IP;
# the classification rests on the measured topology, not on the ASYNC_REG attribute
# (the vendor first stage does not carry it, and its absence is not treated as
# safer - it is simply not the evidence this entry uses).
# -----------------------------------------------------------------------------
set_false_path -from [get_ports hdmi_rx_ddc_scl] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/scl_sync_reg\[0\]}]
set_false_path -from [get_ports hdmi_rx_ddc_scl] \
    -to [get_cells -hier -regexp {.*v_hdmi_rx/inst/SYS_INST/DDC_INST/clk_scl_flt_reg\[0\]}]
set_false_path -from [get_ports hdmi_rx_ddc_sda] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/sda_sync_reg\[0\]}]
set_false_path -from [get_ports hdmi_rx_ddc_sda] \
    -to [get_cells -hier -regexp {.*v_hdmi_rx/inst/SYS_INST/DDC_INST/clk_sda_flt_reg\[0\]}]

# -----------------------------------------------------------------------------
# HDMI TX TMDS clock pads, capture-only personality.
#
# Approved-but-not-accepted scope: this build captures (video0) and encodes on the
# on-card VCU; HDMI TX is not part of the acceptance path.  The pads stay wired to
# the VPHY (u_vid_phy_controller drives one OBUFTDS each, OSERDESE3 on clkout1_1,
# build/evidence-dcpio-26111106/query/s4-tx-tmds-driver.txt) - nothing here claims
# the pad is undriven or has no external load.  Only the missing output-delay
# question is excepted, one command per port, and the driver identity plus the
# OSERDESE3 population are re-measured so a change of TX implementation fails the
# gate instead of inheriting this exception.  A TX personality must delete these
# two lines and re-review the pad with an output delay against hdmi_tx_clk_p
# (3.367 ns), which Vivado itself names in methodology.rpt.
# -----------------------------------------------------------------------------
set_false_path -to [get_ports hdmi_tx_tmds_clk_p]
set_false_path -to [get_ports hdmi_tx_tmds_clk_n]

# -----------------------------------------------------------------------------
# RX DDC / EDID pair, OUTPUT direction (check_timing HIGH of round 26111202).
#
# check-timing.rpt of build/vcu-release-26111202-r1 says it exactly:
#   "There are 2 ports with no output delay specified. (HIGH)"
#       hdmi_rx_ddc_scl
#       hdmi_rx_ddc_sda
# These are the two inout pads through which the FPGA is the DDC *slave* to the
# IT6663 P1TX source.  The driver is the RX subsystem's open-drain pair
# (DDC_INST clk_scl_o/clk_scl_t -> OBUFT -> pad; the same cells the probe reads at
# reg_probe_pins[5:4]), and DDC is a <=400 kHz asynchronous bidirectional protocol:
# there is NO FPGA-side clock from which an output delay could be taken, so
# inventing a set_output_delay number would be a fake constraint, and the pad keeps
# no synchronous closure relationship with anything.
#
# What these two commands do and do not do:
#   * one command per port, named, exactly as the input side is itemised; nothing
#     here covers a port that is not listed;
#   * `-to <port>` only ends paths at the pad.  It does not touch the input
#     direction (the `-from [get_ports ...] -to <first stage>` rows above), it does
#     not reach the vendor filter or any internal flop, and it is not a clock cut:
#     scripts/check_sc7f0_named_constraints.tcl re-measures, per entry, that the
#     exception is neither ignored nor scope-overridden, plus the pad driver cells,
#     their reference family and their clock domain, and the four RX-DDC input
#     entries still demand internal_filter_same_domain + min_paths_analysed.
#   * Layer B keeps the electrical/protocol question (IT6663 DDC timing, EDID under
#     hot plug) open in sc7f0_cdc_review.json io_items rx_ddc_scl / rx_ddc_sda
#     rather than pretending a netlist answered it.
# -----------------------------------------------------------------------------
set_false_path -name async_out_hdmi_rx_ddc_scl -to [get_ports hdmi_rx_ddc_scl]
set_false_path -name async_out_hdmi_rx_ddc_sda -to [get_ports hdmi_rx_ddc_sda]

# -----------------------------------------------------------------------------
# INTERNAL (flop -> first-stage-flop) asynchronous entries: the u_hdmi_probe
# diagnostic levels.  These are not IO, and they are deliberately written here
# rather than as a -from-clock/-to-clock cut, because the exception is one
# registered source flop to one named first-stage flop.
#
# Round 26111202 had six CDC-10 Critical rows with Exception = None here, and the
# same six endpoints were that round's WNS holders (-2.760 / -1.631 ns, requirement
# 0.002 ns).  rtl/sc7f0_hdmi_probe.v now registers each level in its own source
# clock first (clk_rx_video = clkout2 for the RX-SS stream qualifiers, clk_rxout =
# phy_rxoutclk for the VPHY channel valids), so:
#   * the path from the vendor content into *_src_reg is a plain SAME-domain path
#     at the source clock's own requirement (6.734 ns), not a 0.002 ns crossing;
#   * the crossing itself is *_src_reg -> <chain>_sync_reg[0], which is what these
#     six commands except, one per signal;
#   * the three internal chain stages ([0] -> [1] -> [2]) and the pin-level
#     array_single stay exactly as they were: NOT excepted, still in domain, still
#     analysed.  The hook measures that (min_paths_analysed on chain[0] -> chain[1]
#     and chain[2]) so a broadened exception - a -from-clock cut, a wildcard -to -
#     shows up as "0 analysed paths" instead of hiding behind this file.
# No ASYNC_REG or any other attribute is added here or in the RTL to make a report
# quieter, and rx_ss_video_tready has no entry because it is a constant at the top
# level (rtl/zu4ev_pcie_card_top.v:1053) and produced no CDC row.
#
# Round 26111204 measurement - why these six commands carry no `-name` (corrected
# 2026-11-12, validation build/wns-fix-20261112T044035Z):
#   * `set_false_path` in Vivado 2023.2 has NO `-name` option.  The frozen round
#     log says so at the exact lines of these six commands:
#       CRITICAL WARNING: [Common 17-170] Unknown option '-name'
#         .../constraints/sc7f0_async_io.xdc:199 / 202 / 205 / 208 / 211 / 214
#     (build/vcu-release-26111204-r1/fpga/project-logs/impl-vivado.log:3039-3044),
#     and the command is then not created at all:
#       - report_exceptions (-summary/-all/-coverage) of that round contains no
#         row for any of the six pairs, while the 40 other exceptions of the same
#         file that carry no `-name` do appear;
#       - the six crossings were therefore still analysed at the 0.002 ns async
#         requirement, which is exactly that round's -2.472 / -11.946 WNS/TNS;
#       - the object selection was never the problem: the round's own manifest
#         measured from_objects = 1 and to_objects = 1 for every one of the six
#         pairs (named-constraint-evidence.json, class internal_async), so both
#         ends resolve to exactly one named flop each and nothing is broadened.
#   * So the fix is the removal of the unsupported option and nothing else: same
#     -from flop, same -to first-stage flop, one command per named pair, no
#     -from-clock/-to-clock cut, no clock group, no extra pair.
#   * An exception can no longer carry a tool-visible name here, so the reviewed
#     identity of each pair stays in the comment above its command and is
#     re-measured by scripts/check_sc7f0_named_constraints.tcl, which resolves
#     every entry by its -from/-to objects (sc7f0_exception) and not by a name.
# -----------------------------------------------------------------------------
# probe_rxss_tlast_src_to_probe (clkout2 -> clk_pl_0)
set_false_path \
    -from [get_cells -hier -regexp {.*u_hdmi_probe/rxss_tlast_src_reg}] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/rxss_tlast_sync_reg\[0\]}]
# probe_rxss_tuser_src_to_probe (clkout2 -> clk_pl_0)
set_false_path \
    -from [get_cells -hier -regexp {.*u_hdmi_probe/rxss_tuser_src_reg}] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/rxss_tuser_sync_reg\[0\]}]
# probe_rxss_tvalid_src_to_probe (clkout2 -> clk_pl_0)
set_false_path \
    -from [get_cells -hier -regexp {.*u_hdmi_probe/rxss_tvalid_src_reg}] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/rxss_tvalid_sync_reg\[0\]}]
# probe_phy_ch0_tvalid_src_to_probe (phy_rxoutclk -> clk_pl_0)
set_false_path \
    -from [get_cells -hier -regexp {.*u_hdmi_probe/phy_ch0_tvalid_src_reg}] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/phy_ch0_tvalid_sync_reg\[0\]}]
# probe_phy_ch1_tvalid_src_to_probe (phy_rxoutclk -> clk_pl_0)
set_false_path \
    -from [get_cells -hier -regexp {.*u_hdmi_probe/phy_ch1_tvalid_src_reg}] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/phy_ch1_tvalid_sync_reg\[0\]}]
# probe_phy_ch2_tvalid_src_to_probe (phy_rxoutclk -> clk_pl_0)
set_false_path \
    -from [get_cells -hier -regexp {.*u_hdmi_probe/phy_ch2_tvalid_src_reg}] \
    -to [get_cells -hier -regexp {.*u_hdmi_probe/phy_ch2_tvalid_sync_reg\[0\]}]
