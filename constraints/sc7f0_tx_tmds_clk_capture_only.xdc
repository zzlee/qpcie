# constraints/sc7f0_tx_tmds_clk_capture_only.xdc
#
# LEGACY CAPTURE-ONLY PERSONALITY ONLY.  scripts/build_zu4ev.tcl mounts this file
# when SC7F0_RGB_COMPOSITOR is NOT set (the `full` profile: video0 capture plus the
# on-card VCU H264 path).  It is deliberately NOT mounted for the RGB compositor
# profile, whose acceptance path is a live HDMI TX stream; see the end of this file
# and constraints/sc7f0_async_io.xdc:126-141.
#
# Commands: exactly two, one per port, byte-for-byte the two lines that used to sit
# in the managed common file constraints/sc7f0_async_io.xdc.  They were MOVED, not
# deleted-and-forgotten, so the legacy personality keeps its previous behaviour and
# the RGB profile provably does not carry them.  This file is declarative on
# purpose: the managed read_xdc reader drops `if`/`concat`/control flow with only a
# CRITICAL WARNING (measured in round rgb-fullimpl-26111333-20261113T204036Z,
# logs/build_full26111333.log:3796-3804), so a profile guard written inside an XDC
# is not a guard.  The profile decision therefore lives in the mount, in Tcl, where
# a wrong answer stops the build.
#
# -----------------------------------------------------------------------------
# Approved-but-not-accepted scope: this build captures (video0) and encodes on the
# on-card VCU; HDMI TX is not part of the acceptance path.  The pads stay wired to
# the VPHY (u_vid_phy_controller drives one OBUFTDS each, OSERDESE3 on clkout1_1,
# build/evidence-dcpio-26111106/query/s4-tx-tmds-driver.txt) - nothing here claims
# the pad is undriven or has no external load.  Only the missing output-delay
# question is excepted, one command per port, and the driver identity plus the
# OSERDESE3 population are re-measured so a change of TX implementation fails the
# gate instead of inheriting this exception.  A TX personality must delete these
# two lines and re-review the pad, which is what the RGB compositor profile now
# does with scripts/apply_sc7f0_tx_tmds_clock_forward.tcl (a forwarded clock model
# on the real OSERDESE3/OBUFTDS path, not an output-delay number).
# -----------------------------------------------------------------------------
set_false_path -to [get_ports hdmi_tx_tmds_clk_p]
set_false_path -to [get_ports hdmi_tx_tmds_clk_n]

# Scope statement for the gate (this file makes no claim about the RGB profile):
#   SC7F0_TX_TMDS_CLK_LEGACY_XDC_MOUNTED personality=capture_only_sc7f0_c2h
#   fp_rows_here=2 rgb_profile=0
# No clock is created here, no clock group, no output delay, no relaxed period, and
# nothing in this file applies to hdmi_tx_ddc_*, hdmi_tx_hpd_in or the RX side.
