# apply_sc7f0_tx_tmds_clock_forward.tcl
#
# SC7F0 RGB-compositor (TX-live) profile ONLY.  Applied from
# scripts/impl_pre_opt_sc7f0.tcl = STEPS.OPT_DESIGN.TCL.PRE, after
# scripts/check_sc7f0_capture_gray.tcl and before opt_design, so the clock model is
# in force for placement, routing, opt, report_cdc/report_methodology/check_timing.
#
# WHAT THIS MODELS, AND WHY IT IS NOT A DATA OUTPUT
# ------------------------------------------------
# hdmi_tx_tmds_clk_p / hdmi_tx_tmds_clk_n are the HDMI *forwarded* TMDS clock, not
# asynchronous data.  The measured path in this design is (all of it readable vendor
# source, vid_phy_controller_rgb_gt_usrclk_source_8series.v:425-513, plus the routed
# checkpoint queries in the SC7F0_TX_TMDSCLOCK_APPLIED line this file prints):
#
#   hdmi_tx_clk_p (top port, 3.367 ns) -> VPHY tx_mmcm MMCM (MULT 4 / DIVIDE 1 /
#   OUT1_DIVIDE 4) -> CLKOUT1 net -> OSERDESE3 GT0_TX_MMCM_CLKOUT1_ODDR_INST with
#   ODDR_MODE=TRUE, CLK == CLKDIV == that same net, D[0]=1, D[4]=0, RST=0, no CE
#   -> OBUFTDS (.O -> the P pad, .OB -> the complement N pad, .T <- the AXI-bit
#   enable) -> the two top-level output pads.
#
# That is exactly the topology AMD's own constraint wizard calls a forwarded clock
# (UG903: "the ODDR and ODDRE1 primitives are automatically retargeted to OSERDESE3
# with the property ODDR_MODE=TRUE ... where OSERDESE3/D[0] is connected to 1 and
# OSERDESE3/D[4] is connected to 0 (no phase-shift)"; UG903 Example Six anchors the
# generated clock on the ODDR CLKDIV pin with -divide_by 1; UG949 "Creating an Output
# Clock").  The pad waveform is a copy of the forwarder's input clock, so the pad
# period is the master period, and the honest constraint is a generated clock, not an
# output delay against a clock (there is no fabric data output in this domain to
# reference: the three TMDS data pairs are GT serial pins, and
# C_Use_GT_CH4_HDMI(0) means no GT lane is the clock source - PG230).
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO
# ---------------------------------------
#   * no set_output_delay on either pad (that would be a fabricated receiver
#     requirement; the two legacy capture-only false paths were DELETED from
#     constraints/sc7f0_async_io.xdc and are mounted for the capture personality only
#     from constraints/sc7f0_tx_tmds_clk_capture_only.xdc - this file errors out if a
#     false path still covers either pad, so the RGB profile cannot keep both),
#   * no set_clock_groups / no new create_clock / no relaxed or lowered period: the
#     generated clock inherits its period and waveform from the real MMCM CLKOUT1
#     clock it is anchored to, and the file asserts the 1:1 ratio it claims,
#   * no invented board TSU/TCO, no cable or eye model, no MTBF or throughput claim,
#   * no attribute changes, no vendor IP edit, no change to the vendor
#     set_false_path -to ...ODDR_INST -filter {REF_PIN_NAME=~D*} waiver or to the two
#     CDC-13 waivers on the enable bit D[1] (those cover the AXI enable crossing, not
#     the steady clock).
#
# OPERATING-COVERAGE STATEMENT (do not over-read this)
# ---------------------------------------------------
# The static 3.367 ns (297 MHz) CLKOUT1 is what elaboration declares and it is the
# FASTEST case for the pad among the modes this card is asked to produce: for the
# requested 4K60 RGB8 mode (5.94 Gb/s/lane, 1:40 => 148.5 MHz TMDS clock channel) the
# driver DRP-lowers CLKOUT1 below 297 MHz, and PG230 says so ("in TX buffer bypass
# mode ... you have to program proper divider/multiplier values using driver APIs").
# Constraining the pad at 3.367 ns is therefore conservative for that mode.  This
# file makes NO claim about arbitrary EDID modes in the (297, 340] Mcsc window; that
# window is unproven here and no format whitelist, cap or drop is introduced to hide
# it.  Runtime frequency, lock and board eye behaviour remain unmeasured.
#
# Everything it prints stays review_required = 1; nothing in this file self-approves
# a review verdict.  Failure is fail-closed: every guard is `error`, which stops the
# implementation step instead of shipping an unconstrained pad.

# -----------------------------------------------------------------------------
# Query helpers.  Pin names containing [n] cannot be built with "$cell/D[0]": Tcl
# performs command substitution inside double quotes, and the escaped spelling is a
# second thing to get wrong, so every pin here is selected from the cell's own pin
# list by an exact tail comparison.  A miss is an error, never an empty list.
# -----------------------------------------------------------------------------
if {[info procs sc7f0_txclk_pin] eq ""} {
proc sc7f0_txclk_pin {cell suffix} {
    set n [string length $suffix]
    set out {}
    foreach p [get_pins -quiet -of_objects $cell] {
        set nm [get_property NAME $p]
        if {[string length $nm] >= $n && [string equal [string range $nm end-[expr {$n-1}] end] $suffix]} {
            lappend out $p
        }
    }
    return $out
}
}

if {[info procs sc7f0_txclk_net_of] eq ""} {
proc sc7f0_txclk_net_of {pin} {
    if {[llength $pin] != 1} {error "SC7F0_TX_TMDSCLOCK_QUERY: net lookup needs exactly 1 pin, got [llength $pin]"}
    # lindex, not the list itself: a one-element list whose element contains brackets
    # re-serialises with braces, and a braced word reaching get_nets -of_objects
    # resolves to nothing (measured in the tclsh dry run, logs/dryrun*.log), which
    # would look like an unconnected pin instead of a query bug.
    return [get_nets -quiet -of_objects [lindex $pin 0]]
}
}

# A primitive pin tied to a constant shows up on this routed checkpoint as a constant
# NET, measured on the frozen 26111403 DCP (logs/probe_r2.log):
#   D[0]/D[2]/D[3] -> net .../<const1> TYPE=POWER    D[4..7] -> .../<const0> TYPE=GROUND
#   RST            -> .../<const0> TYPE=GROUND
#   D[1] and T     -> the SAME SIGNAL net .../gt_usrclk_source_inst/D[0]  (= ~EN)
# which is the literal reading of the readable vendor source line
#   .D({4'h0,2'h3,~OBUFTDS_TX_EN,1'b1}), .RST(1'b0), .T(~OBUFTDS_TX_EN)   (no .CE)
# and the canonical UG903 forwarded-clock pattern D[0]=1 / D[4]=0.  The value used
# below therefore comes from the tool, not from a comment.
if {[info procs sc7f0_txclk_pin_state] eq ""} {
proc sc7f0_txclk_pin_state {cell suffix} {
    set p [sc7f0_txclk_pin $cell $suffix]
    if {[llength $p] != 1} {return "pin_absent([llength $p])"}
    set net [sc7f0_txclk_net_of $p]
    if {[llength $net] == 0} {return "no_net"}
    set nm [lindex [get_property NAME $net] 0]
    set ty [lindex [get_property TYPE $net] 0]
    if {[string match *<const1> $nm] && $ty eq "POWER"}  {return VCC}
    if {[string match *<const0> $nm] && $ty eq "GROUND"} {return GND}
    if {$ty eq "SIGNAL"} {return "SIGNAL:$nm"}
    return "OTHER:$ty:$nm"
}
}

set sc7f0_txclk_forwarder "u_vid_phy_controller/inst/gt_usrclk_source_inst/tx_mmcm.GT0_TX_MMCM_CLKOUT1_ODDR_INST"
set sc7f0_txclk_buf       "u_vid_phy_controller/inst/gt_usrclk_source_inst/tx_mmcm.GT0_TX_MMCM_CLKOUT1_OBUFTDS_INST"

# Vivado's Tcl accepts `string is true -quiet`, plain Tcl 8.6 does not, so the
# -quiet spelling is tried first and the strict spelling is the fallback; an
# unparseable value is false, never silently true.
if {[info procs sc7f0_txclk_truthy] eq ""} {
proc sc7f0_txclk_truthy {v} {
    if {[catch {string is true -quiet $v} r]} {
        if {[catch {string is true -strict $v} r]} {set r 0}
    }
    return $r
}
}

# --- 1. the forwarder is unique, is an OSERDESE3, and is in ODDR mode ----------
set sc7f0_tc_oddr [get_cells -quiet -hier -filter {NAME =~ *gt_usrclk_source_inst/tx_mmcm.GT0_TX_MMCM_CLKOUT1_ODDR_INST}]
if {[llength $sc7f0_tc_oddr] != 1} {
    error "SC7F0_TX_TMDSCLOCK_NO_FORWARDER: expected exactly 1 cell matching *gt_usrclk_source_inst/tx_mmcm.GT0_TX_MMCM_CLKOUT1_ODDR_INST, found [llength $sc7f0_tc_oddr]. The clock model is anchored on this specific OSERDESE3; 0 matches means the VPHY TX clock fabric moved or disappeared and >1 means the anchor is ambiguous. An empty anchor is never accepted as 'good enough'."
}
set sc7f0_tc_cell [lindex $sc7f0_tc_oddr 0]
set sc7f0_tc_cell_name [get_property NAME $sc7f0_tc_cell]
if {$sc7f0_tc_cell_name ne $sc7f0_txclk_forwarder} {
    error "SC7F0_TX_TMDSCLOCK_ANCHOR_NAME: the wildcard matched $sc7f0_tc_cell_name, not the reviewed forwarder $sc7f0_txclk_forwarder."
}
if {[get_property REF_NAME $sc7f0_tc_cell] ne "OSERDESE3"} {
    error "SC7F0_TX_TMDSCLOCK_REF_NAME: $sc7f0_tc_cell_name is [get_property REF_NAME $sc7f0_tc_cell], not OSERDESE3. A different serializer family is a different topology and must be re-reviewed."
}
# The source-level parameter is ODDR_MODE("TRUE")
# (vid_phy_controller_rgb_gt_usrclk_source_8series.v:480).  Measured on the routed
# 26111403 checkpoint the property IS exposed and reads TRUE; if a later tool version
# stops exposing it this helper reports that honestly and falls back to the measured
# structural signature (CLK == CLKDIV, no CE pin, D[0]/D[4] pattern, OBUFTDS P/N)
# instead of forcing a property or faking TRUE.
set sc7f0_tc_oddr_mode_query {}
set sc7f0_tc_oddr_mode_raw {}
if {[catch {get_property ODDR_MODE $sc7f0_tc_cell} sc7f0_tc_oddr_mode_raw]} {
    set sc7f0_tc_oddr_mode UNEXPOSED
    set sc7f0_tc_oddr_mode_query "get_property_failed"
} elseif {$sc7f0_tc_oddr_mode_raw eq ""} {
    set sc7f0_tc_oddr_mode UNEXPOSED
    set sc7f0_tc_oddr_mode_query "empty_property_value"
} else {
    switch -regexp -- [string tolower [string trim $sc7f0_tc_oddr_mode_raw]] {
        {^(true|1)$}  {set sc7f0_tc_oddr_mode TRUE;  set sc7f0_tc_oddr_mode_query "property_read"}
        {^(false|0)$} {error "SC7F0_TX_TMDSCLOCK_ODDR_MODE_FALSE: $sc7f0_tc_cell_name reports ODDR_MODE=$sc7f0_tc_oddr_mode_raw. That contradicts the reviewed source parameter ODDR_MODE(\"TRUE\") and means a real 8:1 serializer, for which a -divide_by 1 forwarded clock would be wrong. The property is NOT rewritten to make this pass; the round stops for re-review."}
        default {set sc7f0_tc_oddr_mode UNEXPOSED; set sc7f0_tc_oddr_mode_query "unrecognised_value"}
    }
}
# The documented structural fallback is only for an UNEXPOSED property (never for a
# value that reads FALSE, which is a contradiction): the same ODDR mode is what makes
# CLK and CLKDIV one net with no divide and D[0]/D[4] tied, so those facts are checked
# in steps 2-3 and re-asserted here before anything is applied.
set sc7f0_tc_structural_fallback [expr {$sc7f0_tc_oddr_mode eq "UNEXPOSED" ? 1 : 0}]

# --- 2. CLK and CLKDIV are the same net and that net carries exactly one clock ---
set sc7f0_tc_clk  [sc7f0_txclk_pin $sc7f0_tc_cell /CLK]
set sc7f0_tc_clkd [sc7f0_txclk_pin $sc7f0_tc_cell /CLKDIV]
if {[llength $sc7f0_tc_clk] != 1 || [llength $sc7f0_tc_clkd] != 1} {
    error "SC7F0_TX_TMDSCLOCK_PINS: CLK pins=[llength $sc7f0_tc_clk] CLKDIV pins=[llength $sc7f0_tc_clkd], expected 1 and 1."
}
set sc7f0_tc_clk_net  [sc7f0_txclk_net_of $sc7f0_tc_clk]
set sc7f0_tc_clkdn    [sc7f0_txclk_net_of $sc7f0_tc_clkd]
if {[llength $sc7f0_tc_clk_net] != 1 || [llength $sc7f0_tc_clkdn] != 1} {
    error "SC7F0_TX_TMDSCLOCK_CLK_NET: CLK net(s)=[llength $sc7f0_tc_clk_net] CLKDIV net(s)=[llength $sc7f0_tc_clkdn]; an unclocked forwarder cannot source a forwarded clock."
}
set sc7f0_tc_clk_net_name  [lindex [get_property NAME $sc7f0_tc_clk_net] 0]
set sc7f0_tc_clkdn_name    [lindex [get_property NAME $sc7f0_tc_clkdn] 0]
if {$sc7f0_tc_clk_net_name ne $sc7f0_tc_clkdn_name} {
    error "SC7F0_TX_TMDSCLOCK_CLKDIV_SPLIT: CLK net $sc7f0_tc_clk_net_name != CLKDIV net $sc7f0_tc_clkdn_name. ODDR-mode forwarding requires one net on both pins (UG903 D\[0\]=1 / D\[4\]=0, no phase shift); a split means a real 8:1 serializer, which is a different constraint and a different claim."
}
set sc7f0_tc_src_clocks [get_clocks -quiet -of_objects [lindex $sc7f0_tc_clk_net 0]]
if {[llength $sc7f0_tc_src_clocks] != 1} {
    error "SC7F0_TX_TMDSCLOCK_SOURCE_CLOCK: the forwarder clock net $sc7f0_tc_clk_net_name carries [llength $sc7f0_tc_src_clocks] clock object(s), expected exactly 1 (the MMCM CLKOUT1 derived clock). With 0 clocks the generated clock would have no master and would raise check_timing no_master_clock instead of modelling anything."
}
set sc7f0_tc_src_clock [lindex $sc7f0_tc_src_clocks 0]
set sc7f0_tc_src_name   [get_property NAME $sc7f0_tc_src_clock]
set sc7f0_tc_src_period [get_property PERIOD $sc7f0_tc_src_clock]
set sc7f0_tc_src_wave   [join [get_property WAVEFORM $sc7f0_tc_src_clock] { }]
set sc7f0_tc_src_gen    [get_property IS_GENERATED $sc7f0_tc_src_clock]
set sc7f0_tc_src_master [get_property MASTER_CLOCK $sc7f0_tc_src_clock]
# A period is only usable if it really is a positive finite number.  `catch {expr
# {double($p) > 0}}` alone is not a check: it returns 0 both when the expression is
# false and when it merely ran, so 0, -1 and "" all used to pass.  This version keeps
# the evaluated boolean.
proc sc7f0_txclk_period {label v} {
    if {$v eq "" || [catch {string is double -strict $v} sc7f0_ok] || !$sc7f0_ok} {
        error "SC7F0_TX_TMDSCLOCK_PERIOD_NOT_A_NUMBER: $label measured '$v'; a clock period that is not a number cannot anchor a forwarded clock."
    }
    if {[string match -nocase *inf* $v] || [string match -nocase *nan* $v]} {
        error "SC7F0_TX_TMDSCLOCK_PERIOD_NOT_FINITE: $label measured '$v'."
    }
    set sc7f0_d [expr {double($v)}]
    if {!($sc7f0_d > 0.0)} {
        error "SC7F0_TX_TMDSCLOCK_PERIOD_NOT_POSITIVE: $label measured '$v'."
    }
    return $sc7f0_d
}
set sc7f0_tc_src_period_ns [sc7f0_txclk_period "source clock $sc7f0_tc_src_name" $sc7f0_tc_src_period]
if {![sc7f0_txclk_truthy $sc7f0_tc_src_gen] || $sc7f0_tc_src_master eq ""} {
    error "SC7F0_TX_TMDSCLOCK_SOURCE_NOT_DERIVED: clock $sc7f0_tc_src_name IS_GENERATED=$sc7f0_tc_src_gen MASTER_CLOCK='$sc7f0_tc_src_master'. The pad clock is claimed to inherit a real MMCM output that itself inherits the declared board reference; a masterless source clock would make that claim false."
}
# Walk the real master chain down to the one non-generated root, which must be the
# declared TX reference clock on its own pad.  Clock objects on this tool expose
# MASTER_CLOCK but NOT ALL_MASTER_CLOCKS / SOURCE_PIN (measured, logs/probe_r2.log:
# "The object 'clock' does not have a property 'ALL_MASTER_CLOCKS'"), so the chain is
# walked one MASTER_CLOCK at a time instead of read from a single property.
set sc7f0_tc_chain [list $sc7f0_tc_src_name]
set sc7f0_tc_cur $sc7f0_tc_src_clock
set sc7f0_tc_root {}
for {set sc7f0_tc_i 0} {$sc7f0_tc_i < 12} {incr sc7f0_tc_i} {
    if {[sc7f0_txclk_truthy [get_property IS_GENERATED $sc7f0_tc_cur]]} {
        set sc7f0_tc_m [get_property MASTER_CLOCK $sc7f0_tc_cur]
        if {$sc7f0_tc_m eq ""} {break}
        set sc7f0_tc_cur [get_clocks -quiet $sc7f0_tc_m]
        if {[llength $sc7f0_tc_cur] != 1} {break}
        lappend sc7f0_tc_chain $sc7f0_tc_m
    } else {
        set sc7f0_tc_root $sc7f0_tc_cur
        break
    }
}
if {[llength $sc7f0_tc_root] != 1} {
    error "SC7F0_TX_TMDSCLOCK_ROOT: the master chain [join $sc7f0_tc_chain { -> }] never reached a non-generated root clock. The pad clock must provably inherit the declared board reference, otherwise -divide_by 1 copies an unanchored period."
}
set sc7f0_tc_root_clock [get_property NAME $sc7f0_tc_root]
set sc7f0_tc_root_port {}
if {[llength [get_ports -quiet -of_objects $sc7f0_tc_root]] == 1} {
    set sc7f0_tc_root_port [get_property NAME [get_ports -quiet -of_objects $sc7f0_tc_root]]
}
set sc7f0_tc_root_period [get_property PERIOD $sc7f0_tc_root]
# The root must be the declared TX reference on its own pad, and the pad clock must
# not be faster than that reference (-divide_by 1 copies the source period, and the
# source is a divided MMCM output of this reference).  Names are printed, not blindly
# required: what is required is the queried relationship plus a hdmi_tx_clk* root port,
# so a renamed chain still passes while an unanchored one cannot.
set sc7f0_tc_root_period_ns [sc7f0_txclk_period "root clock $sc7f0_tc_root_clock" $sc7f0_tc_root_period]
if {$sc7f0_tc_root_port eq "" || ![string match hdmi_tx_clk* $sc7f0_tc_root_port]} {
    error "SC7F0_TX_TMDSCLOCK_ROOT_PORT: the master chain [join $sc7f0_tc_chain { -> }] roots at clock $sc7f0_tc_root_clock defined on port '$sc7f0_tc_root_port'; the reviewed chain roots at the declared hdmi_tx_clk_p reference pad."
}
if {$sc7f0_tc_src_period_ns + 1e-6 < $sc7f0_tc_root_period_ns} {
    error "SC7F0_TX_TMDSCLOCK_ROOT_RATIO: source clock $sc7f0_tc_src_name is $sc7f0_tc_src_period ns, faster than its own root $sc7f0_tc_root_clock at $sc7f0_tc_root_period ns. The measured chain here is 1:1 (both 3.367 ns); anything faster means the MMCM dividers changed and the forwarded-clock period claim has to be re-derived, not copied."
}
set sc7f0_tc_ratio [format {%.4f} [expr {$sc7f0_tc_src_period_ns / $sc7f0_tc_root_period_ns}]]

# --- 3. the ODDR data pattern really is the canonical forwarded-clock pattern ---
# Readable source (quoted, not assumed): .D({4'h0,2'h3,~OBUFTDS_TX_EN,1'b1}),
# .RST(1'b0), .T(~OBUFTDS_TX_EN), no .CE => D[0]=1, D[4]=0, D[1]=~enable.
# Raw per-pin states first (VCC / GND / SIGNAL:<net> / no_net / pin_absent), then the
# human-readable label list.  Comparing labels against a state prefix would never
# match, so the guards below read sc7f0_tc_draw, never sc7f0_tc_dpat.
array set sc7f0_tc_draw {}
foreach i {0 1 2 3 4 5 6 7} {
    set sc7f0_tc_draw($i) [sc7f0_txclk_pin_state $sc7f0_tc_cell /D\[$i\]]
}
set sc7f0_tc_dpat {}
foreach i {0 1 2 3 4 5 6 7} {
    lappend sc7f0_tc_dpat "D\[$i\]=$sc7f0_tc_draw($i)"
}
set sc7f0_tc_rst_state [sc7f0_txclk_pin_state $sc7f0_tc_cell /RST]
set sc7f0_tc_ce_pins  [sc7f0_txclk_pin $sc7f0_tc_cell /CE]
# Exact expected pattern: measured on this DCP (logs/probe_r2.log) and equal to the
# vendor source line.  Anything else is a different serializer and stops the round.
foreach {sc7f0_tc_i sc7f0_tc_want} {0 VCC 1 SIGNAL 2 VCC 3 VCC 4 GND 5 GND 6 GND 7 GND} {
    set sc7f0_tc_got $sc7f0_tc_draw($sc7f0_tc_i)
    if {$sc7f0_tc_want eq "SIGNAL"} {
        set sc7f0_tc_hit [string match SIGNAL:* $sc7f0_tc_got]
    } else {
        set sc7f0_tc_hit [string equal $sc7f0_tc_got $sc7f0_tc_want]
    }
    if {!$sc7f0_tc_hit} {
        error "SC7F0_TX_TMDSCLOCK_D_PATTERN: pin D\[$sc7f0_tc_i\] measured $sc7f0_tc_got, expected $sc7f0_tc_want (UG903 forwarded-clock pattern D\[0\]=1 / D\[4\]=0; vendor source .D({4'h0,2'h3,~OBUFTDS_TX_EN,1'b1})). A driven D pin means a data serializer, not a forwarded clock."
    }
}
if {$sc7f0_tc_rst_state ne "GND"} {
    error "SC7F0_TX_TMDSCLOCK_RST: RST=$sc7f0_tc_rst_state, expected GND (source: .RST(1'b0)). A driven reset would blank the forwarded clock and the pad model would need that reset reviewed."
}
# T (tri-state) and D[1] must be the same ~enable net: the pad stays quiet until the
# AXI 0x138[0] bit is programmed, which is a runtime state, not a second clock.
set sc7f0_tc_t_state [sc7f0_txclk_pin_state $sc7f0_tc_cell /T]
set sc7f0_tc_d1_state $sc7f0_tc_draw(1)
if {$sc7f0_tc_t_state ne $sc7f0_tc_d1_state} {
    error "SC7F0_TX_TMDSCLOCK_ENABLE_NET: pin T measured $sc7f0_tc_t_state but pin D\[1\] measured $sc7f0_tc_d1_state; the reviewed topology ties both to ~OBUFTDS_TX_EN."
}
if {[llength $sc7f0_tc_ce_pins] != 0} {
    error "SC7F0_TX_TMDSCLOCK_CE: the forwarder exposes a CE pin ([llength $sc7f0_tc_ce_pins]); the reviewed topology has no clock enable on the forwarded clock."
}

# --- 4. P is the true leg and N the complement, through the measured OBUFTDS ----
set sc7f0_tc_buf [get_cells -quiet $sc7f0_txclk_buf]
if {[llength $sc7f0_tc_buf] != 1} {
    error "SC7F0_TX_TMDSCLOCK_BUFFER: expected exactly 1 cell named $sc7f0_txclk_buf, found [llength $sc7f0_tc_buf]."
}
set sc7f0_tc_buf_ref [get_property REF_NAME $sc7f0_tc_buf]
if {$sc7f0_tc_buf_ref ne "OBUFTDS"} {
    error "SC7F0_TX_TMDSCLOCK_BUFFER_REF: $sc7f0_txclk_buf is $sc7f0_tc_buf_ref, not OBUFTDS; the P/OB complement relationship below is not valid for another buffer."
}
# .I is the forwarder's OQ and .T is the forwarder's T_OUT (one net on both sides).
foreach {sc7f0_tc_bpin sc7f0_tc_expect_pin} {I /OQ T /T_OUT} {
    if {[llength [sc7f0_txclk_pin $sc7f0_tc_buf /$sc7f0_tc_bpin]] != 1 || [llength [sc7f0_txclk_pin $sc7f0_tc_cell $sc7f0_tc_expect_pin]] != 1} {
        error "SC7F0_TX_TMDSCLOCK_BUFFER_PIN: OBUFTDS/$sc7f0_tc_bpin or forwarder$sc7f0_tc_expect_pin did not resolve to exactly one pin."
    }
    set sc7f0_tc_bn [get_property NAME [sc7f0_txclk_net_of [sc7f0_txclk_pin $sc7f0_tc_buf /$sc7f0_tc_bpin]]]
    set sc7f0_tc_en [get_property NAME [sc7f0_txclk_net_of [sc7f0_txclk_pin $sc7f0_tc_cell $sc7f0_tc_expect_pin]]]
    if {$sc7f0_tc_bn ne $sc7f0_tc_en} {
        error "SC7F0_TX_TMDSCLOCK_BUFFER_PATH: OBUFTDS/$sc7f0_tc_bpin net '$sc7f0_tc_bn' is not the forwarder $sc7f0_tc_expect_pin net '$sc7f0_tc_en'."
    }
}
set sc7f0_tc_buf_p_net [get_property NAME [sc7f0_txclk_net_of [sc7f0_txclk_pin $sc7f0_tc_buf /O]]]
set sc7f0_tc_buf_n_net [get_property NAME [sc7f0_txclk_net_of [sc7f0_txclk_pin $sc7f0_tc_buf /OB]]]

# Walk a net's real connectivity and return {ports walk_used notes cell_endpoints
# other_classes}.  Three supported walks are tried in order, because which object
# class a fanout answers with is a property of this tool and not of the hardware, and
# none of them may be replaced by comparing IP-internal net-name tails: only a
# TOP-LEVEL PORT object is evidence of which pad this leg drives.
proc sc7f0_txclk_port_walk {netobj} {
    set sc7f0_tc_notes {}
    set sc7f0_tc_cells0 0
    set sc7f0_tc_oth0 {}
    foreach sc7f0_tc_try [list \
        [list all_fanout_flat_endpoints_only [list all_fanout -flat -endpoints_only -from $netobj]] \
        [list all_fanout_flat [list all_fanout -flat -from $netobj]] \
        [list all_connected_flat [list all_connected -flat $netobj]]] {
        set sc7f0_tc_label [lindex $sc7f0_tc_try 0]
        set sc7f0_tc_cmd   [lindex $sc7f0_tc_try 1]
        if {[catch {uplevel #0 $sc7f0_tc_cmd} sc7f0_tc_objs]} {
            lappend sc7f0_tc_notes "$sc7f0_tc_label=ERROR([string range $sc7f0_tc_objs 0 120])"
            continue
        }
        set sc7f0_tc_ps {}
        set sc7f0_tc_cells 0
        set sc7f0_tc_oth {}
        foreach sc7f0_tc_o $sc7f0_tc_objs {
            set sc7f0_tc_c [get_property -quiet CLASS $sc7f0_tc_o]
            set sc7f0_tc_n [get_property -quiet NAME $sc7f0_tc_o]
            if {$sc7f0_tc_c eq "port"} {
                lappend sc7f0_tc_ps $sc7f0_tc_n
            } elseif {$sc7f0_tc_c eq "cell"} {
                incr sc7f0_tc_cells
            } else {
                lappend sc7f0_tc_oth "$sc7f0_tc_c:$sc7f0_tc_n"
            }
        }
        set sc7f0_tc_noo [llength $sc7f0_tc_oth]
        if {$sc7f0_tc_noo > 12} {
            set sc7f0_tc_oth [linsert [lrange $sc7f0_tc_oth 0 11] end plus_${sc7f0_tc_noo}_total]
        }
        set sc7f0_tc_cells0 $sc7f0_tc_cells
        set sc7f0_tc_oth0 $sc7f0_tc_oth
        lappend sc7f0_tc_notes "$sc7f0_tc_label=[llength $sc7f0_tc_objs]obj-[llength $sc7f0_tc_ps]port"
        if {[llength $sc7f0_tc_ps] > 0} {
            set sc7f0_tc_u {}
            foreach sc7f0_tc_p $sc7f0_tc_ps {
                if {[lsearch -exact $sc7f0_tc_u $sc7f0_tc_p] < 0} {lappend sc7f0_tc_u $sc7f0_tc_p}
            }
            return [list $sc7f0_tc_u $sc7f0_tc_label [join $sc7f0_tc_notes {;}] $sc7f0_tc_cells $sc7f0_tc_oth]
        }
    }
    return [list {} none [join $sc7f0_tc_notes {;}] $sc7f0_tc_cells0 $sc7f0_tc_oth0]
}

set sc7f0_tc_ports {}
set sc7f0_tc_buf_loc {}
set sc7f0_tc_site_query {}
# Measured per-pad before-apply exception counts (the record line must not carry a
# literal 0 for what is supposed to be a measurement).
set sc7f0_tc_fp_before_p 0
set sc7f0_tc_fp_before_n 0
set sc7f0_tc_fp_after_p -1
set sc7f0_tc_fp_after_n -1
set pad_sc7f0_tc_first 1
# [list ...], not {..}: a braced list would hand the loop the literal text
# "$sc7f0_tc_buf_p_net" instead of the measured net name.
# The fifth field is the expected PACKAGE_PIN of that pad, read from
# constraints/zu4ev_pcie_pinout.xdc:38-39 (AH6 = P, AJ6 = N); it is asserted against
# the top-port property below, which needs no cross-hierarchy name comparison.
foreach {sc7f0_tc_pad sc7f0_tc_pname sc7f0_tc_pnet sc7f0_tc_pleg sc7f0_tc_expect_pin} [list \
    p hdmi_tx_tmds_clk_p $sc7f0_tc_buf_p_net tx_tmds_clk_p AH6 \
    n hdmi_tx_tmds_clk_n $sc7f0_tc_buf_n_net tx_tmds_clk_n AJ6] {
    set sc7f0_tc_po [get_ports -quiet $sc7f0_tc_pname]
    if {[llength $sc7f0_tc_po] != 1} {
        error "SC7F0_TX_TMDSCLOCK_PORT: get_ports $sc7f0_tc_pname matched [llength $sc7f0_tc_po] objects, expected 1."
    }
    set sc7f0_tc_dir  [get_property DIRECTION $sc7f0_tc_po]
    set sc7f0_tc_istd [get_property IOSTANDARD $sc7f0_tc_po]
    set sc7f0_tc_pkg  [get_property PACKAGE_PIN $sc7f0_tc_po]
    set sc7f0_tc_padnet [get_property NAME [get_nets -quiet -of_objects $sc7f0_tc_po]]
    # DIRECTION is measured OUT on this tool (logs/probe_r2.log: dir=OUT); OUTPUT is
    # accepted only as an alias and the actual value is printed.
    if {$sc7f0_tc_dir ni {OUT OUTPUT}} {
        error "SC7F0_TX_TMDSCLOCK_PORT_DIR: $sc7f0_tc_pname direction is $sc7f0_tc_dir, expected OUT (a forwarded clock leaves the device)."
    }
    if {$sc7f0_tc_pkg eq ""} {
        error "SC7F0_TX_TMDSCLOCK_PORT_LOC: $sc7f0_tc_pname has no PACKAGE_PIN; a clock model on an unplaced pad is not evidence about this card."
    }
    # The OBUFTDS leg must be the leg of THIS pad: .O -> .../tx_tmds_clk_p, .OB ->
    # .../tx_tmds_clk_n (the IP-internal net and the top-level net are different net
    # objects, so the comparison is on the leg name, not across the hierarchy edge).
    set sc7f0_tc_ptail [lindex [split $sc7f0_tc_pnet "/"] end]
    if {$sc7f0_tc_pnet eq "" || $sc7f0_tc_ptail ne $sc7f0_tc_pleg} {
        error "SC7F0_TX_TMDSCLOCK_PAD_NET: the OBUFTDS leg for the $sc7f0_tc_pad pad measured '$sc7f0_tc_pnet' (tail $sc7f0_tc_ptail), expected the $sc7f0_tc_pleg leg; top net of $sc7f0_tc_pname is $sc7f0_tc_padnet."
    }
    # PHYSICAL P/N truth by real fanout, not by net name.  The name-tail test above
    # only says which IP-internal leg this OBUFTDS drives; if the two top-level port
    # connections in rtl/zu4ev_pcie_card_top.v were swapped, that test still passes
    # while the non-inverted clock sits on the complement pad.  So walk the actual
    # connectivity: -flat crosses the hierarchy boundary and -endpoints_only WITHOUT
    # -only_cells makes a top-level port a legal endpoint, so the one and only port
    # endpoint reachable from this leg's net must be THIS pad's top port.
    set sc7f0_tc_fo_net [get_nets -quiet $sc7f0_tc_pnet]
    if {[llength $sc7f0_tc_fo_net] != 1} {
        error "SC7F0_TX_TMDSCLOCK_PAD_NET_OBJECT: get_nets $sc7f0_tc_pnet matched [llength $sc7f0_tc_fo_net] objects, expected 1; the OBUFTDS leg has to exist as a net to be walked."
    }
    set sc7f0_tc_eports {}
    set sc7f0_tc_ecells 0
    set sc7f0_tc_eother {}
    lassign [sc7f0_txclk_port_walk $sc7f0_tc_fo_net] sc7f0_tc_eports sc7f0_tc_fo_used sc7f0_tc_fo_err sc7f0_tc_ecells sc7f0_tc_eother
    if {[llength $sc7f0_tc_eports] == 0} {
        error "SC7F0_TX_TMDSCLOCK_PAD_FANOUT_UNSUPPORTED: no supported connectivity walk (all_fanout -flat -endpoints_only, all_fanout -flat, all_connected -flat) returned a top-level PORT object reachable from $sc7f0_tc_pnet (walks: $sc7f0_tc_fo_err; other object classes [join $sc7f0_tc_eother {,}]). Which physical pad this leg drives is then unknown, and an IP-internal net-name tail is NOT an acceptable substitute for that proof."
    }
    set sc7f0_tc_ep_s [join $sc7f0_tc_eports {+}]
    if {[lsearch -exact $sc7f0_tc_eports $sc7f0_tc_pname] < 0} {
        error "SC7F0_TX_TMDSCLOCK_PAD_ROUTING: the OBUFTDS leg $sc7f0_tc_pnet fans out to the top-level port(s) $sc7f0_tc_ep_s, which does not include $sc7f0_tc_pname; the true/complement assignment of hdmi_tx_tmds_clk_p/_n at the top level is wrong and a -invert on the N leg would clock the wrong pad."
    }
    foreach sc7f0_tc_ep $sc7f0_tc_eports {
        if {$sc7f0_tc_ep ne $sc7f0_tc_pname} {
            error "SC7F0_TX_TMDSCLOCK_PAD_EXTRA_CONSUMER: $sc7f0_tc_pnet drives $sc7f0_tc_ep in addition to $sc7f0_tc_pname; a forwarded clock may have exactly one pad consumer, and a second one changes what the pad clock means."
        }
    }
    # PACKAGE_PIN is a property of the top port itself, so this is a direct physical
    # assertion, not a name comparison across a hierarchy edge.
    if {$sc7f0_tc_pkg ne $sc7f0_tc_expect_pin} {
        error "SC7F0_TX_TMDSCLOCK_PAD_PIN: $sc7f0_tc_pname sits at PACKAGE_PIN $sc7f0_tc_pkg but constraints/zu4ev_pcie_pinout.xdc:38-39 declares $sc7f0_tc_expect_pin for it; the clock written on this pad would not be the clock the schematic expects."
    }
    puts "SC7F0_TX_TMDSCLOCK_PAD_FANOUT pad=$sc7f0_tc_pname leg_net=$sc7f0_tc_pnet port_endpoints=$sc7f0_tc_ep_s cell_endpoints=$sc7f0_tc_ecells other_endpoints=[expr {[llength $sc7f0_tc_eother] ? [join $sc7f0_tc_eother {,}] : {none}}] package_pin=$sc7f0_tc_pkg walk=$sc7f0_tc_fo_used walk_note='$sc7f0_tc_fo_err'"
    # Physical P/N evidence.  Secondary proof: the OBUFTDS .O net is the tx_tmds_clk_p
    # leg and .OB is the tx_tmds_clk_n leg (checked above by net name; the IP-internal
    # net .../gt_usrclk_source_inst/tx_tmds_clk_p is a different net object from the
    # top-level net hdmi_tx_tmds_clk_p, so an equality test across the boundary would
    # be a query bug, as round H learned for the DDC pad leaf).  Extra proof when the
    # tool exposes it: a differential OBUFTDS occupies one IOB site pair whose master
    # site is the P pad, so the placed site of the buffer is compared with the pad
    # site.  If no site property resolves, that is REPORTED, not asserted.
    set sc7f0_tc_site_query {}
    foreach sc7f0_tc_sp {LOC SITE PHY_SITE} {
        if {![catch {get_property $sc7f0_tc_sp $sc7f0_tc_buf} sc7f0_tc_try_loc] && $sc7f0_tc_try_loc ne ""} {
            set sc7f0_tc_buf_loc $sc7f0_tc_try_loc
            set sc7f0_tc_site_query "buffer_$sc7f0_tc_sp"
            break
        }
    }
    set sc7f0_tc_pad_site [get_property -quiet SITE $sc7f0_tc_po]
    # Round H measured buffer LOC = HPIOBDIFFOUTBUF_X0Y60 while the pad SITE is
    # IOB_X1Y...: two different site naming schemes for the same silicon, so string
    # equality between them proves nothing and must never gate the round.  The P/N
    # truth is the .O/.OB net-leg proof above; the sites are REPORTED side by side, and
    # they are only compared when the two strings are in the same scheme.
    if {$sc7f0_tc_buf_loc eq "" || $sc7f0_tc_pad_site eq ""} {
        puts "SC7F0_TX_TMDSCLOCK_NOTE site evidence incomplete (buffer_loc='$sc7f0_tc_buf_loc' pad_site='$sc7f0_tc_pad_site'); P/N is proven by the measured OBUFTDS .O/.OB net legs only"
    } elseif {[string match [string range $sc7f0_tc_buf_loc 0 2]* $sc7f0_tc_pad_site] ||
              [string match [string range $sc7f0_tc_pad_site 0 2]* $sc7f0_tc_buf_loc]} {
        if {$pad_sc7f0_tc_first && $sc7f0_tc_buf_loc ne $sc7f0_tc_pad_site} {
            error "SC7F0_TX_TMDSCLOCK_BUF_LOC_MISMATCH: buffer $sc7f0_tc_site_query=$sc7f0_tc_buf_loc but the P pad $sc7f0_tc_pname sits at $sc7f0_tc_pad_site in the same site naming scheme; the true/complement assignment of the two pad clocks would be wrong."
        }
        puts "SC7F0_TX_TMDSCLOCK_SITE_MATCH pad=$sc7f0_tc_pname pad_site=$sc7f0_tc_pad_site buffer_loc=$sc7f0_tc_buf_loc scheme=compatible"
    } else {
        puts "SC7F0_TX_TMDSCLOCK_NOTE different site naming schemes (pad $sc7f0_tc_pname SITE=$sc7f0_tc_pad_site vs $sc7f0_tc_site_query=$sc7f0_tc_buf_loc); not compared, P/N rests on the .O/.OB net legs"
    }
    set pad_sc7f0_tc_first 0
    if {[llength [get_clocks -quiet -of_objects $sc7f0_tc_po]] != 0} {
        error "SC7F0_TX_TMDSCLOCK_PORT_ALREADY_CLOCKED: $sc7f0_tc_pname already carries [get_property NAME [get_clocks -quiet -of_objects $sc7f0_tc_po]]. A second clock definition on the pad hides the first."
    }
    # A false path -to the pad would suppress the missing-output-delay / pad-closure
    # question this model is meant to answer, which is exactly the state the
    # capture-only personality used and left behind.  Fail closed instead of letting
    # the two mechanisms contradict each other.
    set sc7f0_tc_rows {}
    # Two independent measurements, because the first one alone is not trusted:
    #   (a) report_exceptions -coverage -to <pad>  (the filtered table)
    #   (b) a name scan of the FULL -coverage table for this pad's own row
    # Round 26111403 measured rows 247/248 in exceptions-all.rpt whose To column is
    # literally [get_ports hdmi_tx_tmds_clk_p]; the -to filter is the tool's view of
    # the same rows.  A query form that silently returns nothing (a scoped table that
    # does not resolve the pad, e.g. after the exception was translated to the IOB pin)
    # must not be able to read "no legacy exception" and let both mechanisms coexist,
    # so the union of the two counts is what has to be zero.
    set sc7f0_tc_exc [report_exceptions -coverage -quiet -return_string -to $sc7f0_tc_po]
    foreach sc7f0_tc_l [split $sc7f0_tc_exc \n] {
        if {[regexp {^\s*\d+\s+(False Path|Clock Groups|Multicycle Path|Max Delay.*)} [string trim $sc7f0_tc_l] -> sc7f0_tc_t]} {
            lappend sc7f0_tc_rows [string trim $sc7f0_tc_l]
        }
    }
    set sc7f0_tc_all [report_exceptions -coverage -quiet -return_string]
    set sc7f0_tc_plain [report_exceptions -quiet -return_string]
    set sc7f0_tc_scan {}
    foreach {sc7f0_tc_txt sc7f0_tc_need_type} [list $sc7f0_tc_all 1 $sc7f0_tc_plain 0] {
        foreach sc7f0_tc_l [split $sc7f0_tc_txt \n] {
            set sc7f0_tc_t [string trim $sc7f0_tc_l]
            if {$sc7f0_tc_need_type &&
                ![regexp {^\s*\d+\s+(False Path|Clock Groups|Multicycle Path|Max Delay.*)} $sc7f0_tc_t]} {continue}
            if {![regexp {^\s*\d+\s} $sc7f0_tc_t]} {continue}
            # The un-covered table prints the constraint as written - [get_ports
            # hdmi_tx_tmds_clk_p] - while -coverage prints resolved objects, so both
            # spellings are scanned and the largest count wins.
            set sc7f0_tc_pat  "get_ports $sc7f0_tc_pname"
            set sc7f0_tc_pat2 "$sc7f0_tc_pname]"
            set sc7f0_tc_pat3 "$sc7f0_tc_pname "
            # Patterns are precomputed into variables: inside if { } Tcl substitutes the
            # variables and then parses the result as an expression, so a literal "
            # anywhere in a pattern makes the whole condition a syntax error ("missing
            # \""), which is how revision r4/r5 of this helper failed.
            if {[string match *$sc7f0_tc_pat* $sc7f0_tc_t] ||
                [string match *$sc7f0_tc_pat2* $sc7f0_tc_t] ||
                [string match *$sc7f0_tc_pat3* $sc7f0_tc_t]} {lappend sc7f0_tc_scan $sc7f0_tc_t}
        }
    }
    if {[llength $sc7f0_tc_scan] > [llength $sc7f0_tc_rows]} {set sc7f0_tc_rows $sc7f0_tc_scan}
    if {[llength $sc7f0_tc_rows] != 0} {
        error "SC7F0_TX_TMDSCLOCK_LEGACY_EXCEPTION: $sc7f0_tc_pname still carries [llength $sc7f0_tc_rows] exception row(s) ([join $sc7f0_tc_rows { | }]). The TX-live profile must not keep the capture-only false paths (constraints/sc7f0_async_io.xdc:126-141) alongside the clock model; constraints/sc7f0_tx_tmds_clk_capture_only.xdc is mountable only for the capture personality, so this error means the mount or the file drifted."
    }
    if {$sc7f0_tc_pad eq "p"} {
        set sc7f0_tc_fp_before_p [llength $sc7f0_tc_rows]
    } else {
        set sc7f0_tc_fp_before_n [llength $sc7f0_tc_rows]
    }
    lappend sc7f0_tc_ports $sc7f0_tc_po
}
lassign $sc7f0_tc_ports sc7f0_tc_port_p sc7f0_tc_port_n

# Count the Clock Groups rows the tool actually holds, so "no new clock group" is a
# measured delta across the apply rather than a literal 0.  report_exceptions is
# called without -quiet inside a catch, because a query that errored must not be
# readable as "no rows".
proc sc7f0_txclk_cg_rows {} {
    if {[catch {report_exceptions -coverage -return_string} sc7f0_tc_t]} {
        error "SC7F0_TX_TMDSCLOCK_CG_QUERY_FAILED: report_exceptions -coverage returned an error ($sc7f0_tc_t); a failed query is not evidence of zero clock groups."
    }
    set sc7f0_tc_n 0
    foreach sc7f0_tc_l [split $sc7f0_tc_t \n] {
        if {[regexp {^\s*\d+\s+Clock Groups} [string trim $sc7f0_tc_l]]} {incr sc7f0_tc_n}
    }
    return $sc7f0_tc_n
}
set sc7f0_tc_cg_before [sc7f0_txclk_cg_rows]

# --- 5. the constraint itself: canonical UG903 forwarded-clock form -------------
# -source is the REAL forwarder CLK pin (CLK and CLKDIV are the same net here, which
# is measured above, so the UG903 example's CLKDIV anchor and this CLK anchor name the
# identical wire).  -divide_by 1 keeps the pad period equal to the master's; no
# waveform, no period and no oscillator is invented, and the N leg is the same real
# source with -invert because the measured OBUFTDS .OB is the complement of .O.
if {[catch {create_generated_clock -name hdmi_tx_tmds_clk_fwd_p -source [lindex $sc7f0_tc_clk 0] -divide_by 1 [lindex $sc7f0_tc_port_p 0]} sc7f0_tc_e]} {
    error "SC7F0_TX_TMDSCLOCK_APPLY_P_FAILED: $sc7f0_tc_e"
}
if {[catch {create_generated_clock -name hdmi_tx_tmds_clk_fwd_n -source [lindex $sc7f0_tc_clk 0] -divide_by 1 -invert [lindex $sc7f0_tc_port_n 0]} sc7f0_tc_e2]} {
    error "SC7F0_TX_TMDSCLOCK_APPLY_N_FAILED: $sc7f0_tc_e2"
}

# --- 6. read back what the tool actually took ----------------------------------
# Returned as a flat key/value list so `array set` and `puts` see the same record.
# Clock objects on this tool expose PERIOD / WAVEFORM / IS_GENERATED / MASTER_CLOCK;
# ALL_MASTER_CLOCKS and SOURCE_PIN do NOT exist on a clock here (measured), so the
# anchor is reported as the pin this file passed to -source and is verified through
# MASTER_CLOCK plus get_clocks -of <that pin>.
proc sc7f0_txclk_readback {name portname anchor_pin} {
    set k [get_clocks -quiet $name]
    if {[llength $k] != 1} {error "SC7F0_TX_TMDSCLOCK_READBACK: clock $name matched [llength $k] objects after apply"}
    set m [get_property MASTER_CLOCK $k]
    set mp {}
    if {$m ne ""} {set mp [get_property -quiet PERIOD [get_clocks -quiet $m]]}
    set anchor_clocks {}
    foreach c [get_clocks -quiet -of_objects [lindex $anchor_pin 0]] {lappend anchor_clocks [get_property NAME $c]}
    return [list name $name defined_on $portname period [get_property PERIOD $k] \
                 waveform [join [get_property WAVEFORM $k] -] \
                 is_generated [get_property IS_GENERATED $k] \
                 master $m master_period $mp \
                 source_anchor $anchor_pin source_anchor_clocks [join $anchor_clocks +]]
}
proc sc7f0_txclk_fmt {rec} {
    set out {}
    foreach {k v} $rec {lappend out "$k=[string map {, ; " " _} $v]"}
    return [join $out ,]
}
set sc7f0_tc_rb_p [sc7f0_txclk_readback hdmi_tx_tmds_clk_fwd_p hdmi_tx_tmds_clk_p $sc7f0_tc_clk]
set sc7f0_tc_rb_n [sc7f0_txclk_readback hdmi_tx_tmds_clk_fwd_n hdmi_tx_tmds_clk_n $sc7f0_tc_clk]
# Numeric helpers.  The tolerance is the tool's own PRINT precision (PERIOD and
# WAVEFORM are printed with 3 decimals), so it decides when two printed numbers name
# the same edge.  It is NOT a timing threshold: setup/hold are graded later by the
# tool's own WNS >= 0 / WHS >= 0, unrounded and unsoftened, and nothing here rounds a
# violation away.
set sc7f0_tc_tol 0.002
proc sc7f0_txclk_num {what v} {
    set sc7f0_tc_s [string trim $v]
    if {![string is double -strict $sc7f0_tc_s]} {
        error "SC7F0_TX_TMDSCLOCK_NOTNUMERIC: $what='$v' is not a numeric value."
    }
    set sc7f0_tc_d [expr {double($sc7f0_tc_s)}]
    if {![expr {$sc7f0_tc_d == $sc7f0_tc_d}] || [expr {abs($sc7f0_tc_d) >= 1e30}] || [expr {$sc7f0_tc_d < 0}]} {
        error "SC7F0_TX_TMDSCLOCK_NOTFINITE: $what=$sc7f0_tc_d is not a finite non-negative value."
    }
    return $sc7f0_tc_d
}
proc sc7f0_txclk_residue {v t} {
    set sc7f0_tc_d [expr {double($v)}]
    set sc7f0_tc_m [expr {double($t)}]
    if {$sc7f0_tc_m <= 0} {
        error "SC7F0_TX_TMDSCLOCK_PERIOD_ZERO: modulo by a period of $t is undefined."
    }
    set sc7f0_tc_r [expr {$sc7f0_tc_d - floor($sc7f0_tc_d / $sc7f0_tc_m) * $sc7f0_tc_m}]
    if {$sc7f0_tc_r < 0} {set sc7f0_tc_r [expr {$sc7f0_tc_r + $sc7f0_tc_m}]}
    return $sc7f0_tc_r
}
# Distance between two edge times on a clock of period t, taken around the wrap, so
# 0.000 and 3.366 are 0.001 apart and not 3.366 apart.
proc sc7f0_txclk_wdiff {a b t} {
    set sc7f0_tc_d [expr {abs(double($a) - double($b))}]
    set sc7f0_tc_m [expr {double($t)}]
    if {$sc7f0_tc_d > ($sc7f0_tc_m - $sc7f0_tc_d)} {set sc7f0_tc_d [expr {$sc7f0_tc_m - $sc7f0_tc_d}]}
    return $sc7f0_tc_d
}
array set sc7f0_tc_pb $sc7f0_tc_rb_p
array set sc7f0_tc_nb $sc7f0_tc_rb_n
set sc7f0_tc_T [sc7f0_txclk_num "source clock $sc7f0_tc_src_name period" $sc7f0_tc_src_period]
# BOTH legs must carry the source period.  The revision before this one printed
# readback_n.period but only gated readback_p.period, so an N leg with a different
# period (a wrong -divide_by, or a clock the tool derived from another master) passed.
foreach {sc7f0_tc_leg sc7f0_tc_per} [list p $sc7f0_tc_pb(period) n $sc7f0_tc_nb(period)] {
    set sc7f0_tc_pd [sc7f0_txclk_num "pad clock leg $sc7f0_tc_leg period" $sc7f0_tc_per]
    set sc7f0_tc_dev [expr {abs($sc7f0_tc_pd - $sc7f0_tc_T)}]
    if {$sc7f0_tc_dev > $sc7f0_tc_tol} {
        error "SC7F0_TX_TMDSCLOCK_RATIO_$sc7f0_tc_leg: pad clock leg $sc7f0_tc_leg period $sc7f0_tc_per != source clock $sc7f0_tc_src_name period $sc7f0_tc_src_period (|delta|=$sc7f0_tc_dev > print-precision tolerance $sc7f0_tc_tol); -divide_by 1 must copy the master period on BOTH legs."
    }
}
set sc7f0_tc_pad_ratio_p [format {%.6f} [expr {[sc7f0_txclk_num pad_p_period $sc7f0_tc_pb(period)] / $sc7f0_tc_T}]]
set sc7f0_tc_pad_ratio_n [format {%.6f} [expr {[sc7f0_txclk_num pad_n_period $sc7f0_tc_nb(period)] / $sc7f0_tc_T}]]
if {$sc7f0_tc_pb(master) ne $sc7f0_tc_src_name || $sc7f0_tc_nb(master) ne $sc7f0_tc_src_name} {
    error "SC7F0_TX_TMDSCLOCK_MASTER: masters are '$sc7f0_tc_pb(master)' / '$sc7f0_tc_nb(master)', expected $sc7f0_tc_src_name on both legs."
}
if {![sc7f0_txclk_truthy $sc7f0_tc_pb(is_generated)] || ![sc7f0_txclk_truthy $sc7f0_tc_nb(is_generated)]} {
    error "SC7F0_TX_TMDSCLOCK_NOT_GENERATED: readback IS_GENERATED p=$sc7f0_tc_pb(is_generated) n=$sc7f0_tc_nb(is_generated)."
}
# The N leg must be the opposite half phase.  Compared numerically on the rising
# edge, because the tool prints rounded values: two waveforms whose numbers differ
# only by rounding are the SAME waveform, and a silently un-inverted N leg must not
# pass as the complement of the measured OBUFTDS .OB.
# The N leg must be the real complement of the P leg, which is a statement about BOTH
# edge pairs, not about the rising edges alone: (N_rise - P_rise) mod T = T/2,
# P_fall = N_rise mod T, and N_fall = P_rise mod T.  Comparing only "P_rise != N_rise"
# (the previous revision) would accept, say, a 1 ns phase offset or an un-inverted N
# leg carrying a different duty point.  All four numbers are required to be finite,
# non-negative and a real toggling pair.
set sc7f0_tc_pe [split $sc7f0_tc_pb(waveform) -]
set sc7f0_tc_ne [split $sc7f0_tc_nb(waveform) -]
if {[llength $sc7f0_tc_pe] != 2 || [llength $sc7f0_tc_ne] != 2} {
    error "SC7F0_TX_TMDSCLOCK_WAVEFORM_PARSE: readback waveforms p='$sc7f0_tc_pb(waveform)' n='$sc7f0_tc_nb(waveform)' are not rise/fall pairs."
}
set sc7f0_tc_pr [sc7f0_txclk_num p_rise [lindex $sc7f0_tc_pe 0]]
set sc7f0_tc_pf [sc7f0_txclk_num p_fall [lindex $sc7f0_tc_pe 1]]
set sc7f0_tc_nr [sc7f0_txclk_num n_rise [lindex $sc7f0_tc_ne 0]]
set sc7f0_tc_nf [sc7f0_txclk_num n_fall [lindex $sc7f0_tc_ne 1]]
foreach {sc7f0_tc_leg sc7f0_tc_lr sc7f0_tc_lf} [list p $sc7f0_tc_pr $sc7f0_tc_pf n $sc7f0_tc_nr $sc7f0_tc_nf] {
    if {[sc7f0_txclk_wdiff $sc7f0_tc_lr $sc7f0_tc_lf $sc7f0_tc_T] <= $sc7f0_tc_tol} {
        error "SC7F0_TX_TMDSCLOCK_LEG_FLAT: the $sc7f0_tc_leg leg waveform rises at $sc7f0_tc_lr and falls at $sc7f0_tc_lf, i.e. the same edge within print precision; a forwarded clock must toggle."
    }
}
set sc7f0_tc_half [expr {$sc7f0_tc_T / 2.0}]
set sc7f0_tc_phase [sc7f0_txclk_residue [expr {$sc7f0_tc_nr - $sc7f0_tc_pr}] $sc7f0_tc_T]
set sc7f0_tc_pdev [sc7f0_txclk_wdiff $sc7f0_tc_phase $sc7f0_tc_half $sc7f0_tc_T]
if {$sc7f0_tc_pdev > $sc7f0_tc_tol} {
    error "SC7F0_TX_TMDSCLOCK_PHASE: (N_rise $sc7f0_tc_nr - P_rise $sc7f0_tc_pr) mod T = $sc7f0_tc_phase, which is $sc7f0_tc_pdev away from T/2 = $sc7f0_tc_half (tolerance $sc7f0_tc_tol). The measured buffer leg is the OBUFTDS .OB complement, so the N clock must sit exactly half a period off the P clock."
}
set sc7f0_tc_pf_dev [sc7f0_txclk_wdiff [sc7f0_txclk_residue $sc7f0_tc_pf $sc7f0_tc_T] [sc7f0_txclk_residue $sc7f0_tc_nr $sc7f0_tc_T] $sc7f0_tc_T]
if {$sc7f0_tc_pf_dev > $sc7f0_tc_tol} {
    error "SC7F0_TX_TMDSCLOCK_COMPLEMENT_P_FALL: P_fall $sc7f0_tc_pf mod T is not N_rise $sc7f0_tc_nr mod T (distance $sc7f0_tc_pf_dev > $sc7f0_tc_tol); the two legs are not a true/complement pair."
}
set sc7f0_tc_nf_dev [sc7f0_txclk_wdiff [sc7f0_txclk_residue $sc7f0_tc_nf $sc7f0_tc_T] [sc7f0_txclk_residue $sc7f0_tc_pr $sc7f0_tc_T] $sc7f0_tc_T]
if {$sc7f0_tc_nf_dev > $sc7f0_tc_tol} {
    error "SC7F0_TX_TMDSCLOCK_COMPLEMENT_N_FALL: N_fall $sc7f0_tc_nf mod T is not P_rise $sc7f0_tc_pr mod T (distance $sc7f0_tc_nf_dev > $sc7f0_tc_tol); the two legs are not a true/complement pair."
}
puts "SC7F0_TX_TMDSCLOCK_COMPLEMENT period=$sc7f0_tc_T p_rise=$sc7f0_tc_pr p_fall=$sc7f0_tc_pf n_rise=$sc7f0_tc_nr n_fall=$sc7f0_tc_nf half_period_dev=$sc7f0_tc_pdev p_fall_vs_n_rise_dev=$sc7f0_tc_pf_dev n_fall_vs_p_rise_dev=$sc7f0_tc_nf_dev tolerance=$sc7f0_tc_tol basis=tool_print_precision_not_sta_margin"
foreach sc7f0_tc_pad {hdmi_tx_tmds_clk_p hdmi_tx_tmds_clk_n} {
    set sc7f0_tc_c2 [get_clocks -quiet -of_objects [get_ports -quiet $sc7f0_tc_pad]]
    if {[llength $sc7f0_tc_c2] != 1} {
        error "SC7F0_TX_TMDSCLOCK_PORT_CLOCK_READBACK: $sc7f0_tc_pad carries [llength $sc7f0_tc_c2] clock(s) after apply, expected exactly 1."
    }
    set sc7f0_tc_x [report_exceptions -coverage -quiet -return_string -to [get_ports $sc7f0_tc_pad]]
    set sc7f0_tc_n2 0
    foreach sc7f0_tc_l [split $sc7f0_tc_x \n] {if {[regexp {^\s*\d+\s+(False Path|Clock Groups|Multicycle Path|Max Delay)} [string trim $sc7f0_tc_l]]} {incr sc7f0_tc_n2}}
    if {$sc7f0_tc_pad eq "hdmi_tx_tmds_clk_p"} {
        set sc7f0_tc_fp_after_p $sc7f0_tc_n2
    } else {
        set sc7f0_tc_fp_after_n $sc7f0_tc_n2
    }
    if {$sc7f0_tc_n2 != 0} {
        error "SC7F0_TX_TMDSCLOCK_EXCEPTION_AFTER: $sc7f0_tc_pad carries $sc7f0_tc_n2 exception row(s) after the clock was created."
    }
}
# An output delay would be a different, contradicting model; the clock must not have
# quietly become one.  "Unexposed", "exposed and empty (no delay)" and "a query that
# failed" are three different facts and must not collapse into one another:
# get_property -quiet answers "" for both of the first two, and a catch around the
# -quiet form can even return 0 while the property does not exist.  So ask the object
# which properties it has first (list_property, no -quiet, inside a catch), then read
# the value only when the property is really offered.
set sc7f0_tc_od_p {}
set sc7f0_tc_od_n {}
set sc7f0_tc_odq_p {}
set sc7f0_tc_odq_n {}
foreach {sc7f0_tc_pad sc7f0_tc_slot sc7f0_tc_qslot} {hdmi_tx_tmds_clk_p sc7f0_tc_od_p sc7f0_tc_odq_p hdmi_tx_tmds_clk_n sc7f0_tc_od_n sc7f0_tc_odq_n} {
    set sc7f0_tc_po2 [get_ports -quiet $sc7f0_tc_pad]
    if {[llength $sc7f0_tc_po2] != 1} {
        error "SC7F0_TX_TMDSCLOCK_OUTPUT_DELAY_QUERY: $sc7f0_tc_pad resolved to [llength $sc7f0_tc_po2] port object(s) during the output-delay query."
    }
    if {[catch {list_property $sc7f0_tc_po2} sc7f0_tc_props]} {
        set $sc7f0_tc_slot   QUERY_FAILED
        set $sc7f0_tc_qslot  list_property_error
        puts "SC7F0_TX_TMDSCLOCK_NOTE MAX_OUTPUT_DELAY list_property failed on $sc7f0_tc_pad; reported as QUERY_FAILED, not as 'no output delay'"
        continue
    }
    set sc7f0_tc_props [join $sc7f0_tc_props { }]
    if {[lsearch -exact [split $sc7f0_tc_props { }] MAX_OUTPUT_DELAY] < 0} {
        set $sc7f0_tc_slot  PROPERTY_UNEXPOSED
        set $sc7f0_tc_qslot "list_property_no_such_property"
        puts "SC7F0_TX_TMDSCLOCK_NOTE MAX_OUTPUT_DELAY is not an exposed property of $sc7f0_tc_pad on this tool; that is UNEXPOSED and is NOT read as 'no delay'"
        continue
    }
    if {[catch {get_property MAX_OUTPUT_DELAY $sc7f0_tc_po2} sc7f0_tc_od]} {
        set $sc7f0_tc_slot  QUERY_FAILED
        set $sc7f0_tc_qslot "get_property_error"
        continue
    }
    set $sc7f0_tc_qslot list_property_supported_get_property_ok
    if {$sc7f0_tc_od eq ""} {
        set $sc7f0_tc_slot none
    } else {
        set $sc7f0_tc_slot $sc7f0_tc_od
        if {$sc7f0_tc_od ne "0.000" && $sc7f0_tc_od ne "0"} {
            error "SC7F0_TX_TMDSCLOCK_OUTPUT_DELAY: $sc7f0_tc_pad carries MAX_OUTPUT_DELAY=$sc7f0_tc_od; this model creates a clock, not an output delay."
        }
    }
}
# Measured, per pad: an output delay exists only if the pad reports a non-empty value.
# Both pads are kept separate instead of the last loop iteration overwriting the pair.
set sc7f0_tc_no_od_added 1
foreach {sc7f0_tc_pad sc7f0_tc_odv} [list hdmi_tx_tmds_clk_p $sc7f0_tc_od_p hdmi_tx_tmds_clk_n $sc7f0_tc_od_n] {
    if {$sc7f0_tc_odv ni {none QUERY_FAILED PROPERTY_UNEXPOSED}} {set sc7f0_tc_no_od_added 0}
}
if {$sc7f0_tc_no_od_added == 1 && ($sc7f0_tc_od_p eq "QUERY_FAILED" || $sc7f0_tc_od_n eq "QUERY_FAILED")} {
    set sc7f0_tc_no_od_added QUERY_FAILED
}
if {$sc7f0_tc_od_p eq "QUERY_FAILED" || $sc7f0_tc_od_n eq "QUERY_FAILED"} {
    error "SC7F0_TX_TMDSCLOCK_OUTPUT_DELAY_QUERY_FAILED: the MAX_OUTPUT_DELAY state of a TMDS pad could not be established (p='$sc7f0_tc_od_p' n='$sc7f0_tc_od_n'); a failed query must not be reported as a clean pad."
}
# The clock-group claim, measured across the apply instead of asserted.
set sc7f0_tc_cg_after [sc7f0_txclk_cg_rows]
set sc7f0_tc_cg_added [expr {$sc7f0_tc_cg_after - $sc7f0_tc_cg_before}]
if {$sc7f0_tc_cg_added != 0} {
    error "SC7F0_TX_TMDSCLOCK_CLOCK_GROUP_APPEARED: the Clock Groups row count went $sc7f0_tc_cg_before -> $sc7f0_tc_cg_after across the clock apply; this model creates clocks only, and an unexplained clock group would untime the crossing it is meant to time."
}
set sc7f0_tc_clkdiv_same [expr {$sc7f0_tc_clk_net_name eq $sc7f0_tc_clkdn_name && $sc7f0_tc_clk_net_name ne "" ? "same_net" : "different_net"}]
if {$sc7f0_tc_clkdiv_same ne "same_net"} {
    error "SC7F0_TX_TMDSCLOCK_CLKDIV_NET: forwarder CLK is on net '$sc7f0_tc_clk_net_name' and CLKDIV on '$sc7f0_tc_clkdn_name'; the anchor claim in this file (CLK == CLKDIV, the UG903 forwarded-clock form) is false for this netlist."
}

set sc7f0_tc_dpat_s [string map {" " "" , ;} [join $sc7f0_tc_dpat {,}]]
set sc7f0_tc_wave_s [join [get_property WAVEFORM $sc7f0_tc_src_clock] -]
set sc7f0_tc_chain_s [join $sc7f0_tc_chain ->]
set sc7f0_tc_rbp_s [sc7f0_txclk_fmt $sc7f0_tc_rb_p]
set sc7f0_tc_rbn_s [sc7f0_txclk_fmt $sc7f0_tc_rb_n]
puts "SC7F0_TX_TMDSCLOCK_APPLIED forwarder=$sc7f0_tc_cell_name forwarder_ref=[get_property REF_NAME $sc7f0_tc_cell] oddr_mode=$sc7f0_tc_oddr_mode oddr_mode_query=$sc7f0_tc_oddr_mode_query structural_fallback=$sc7f0_tc_structural_fallback data_width=[get_property -quiet DATA_WIDTH $sc7f0_tc_cell] t_bypass=[get_property -quiet OSERDES_T_BYPASS $sc7f0_tc_cell] d_bypass=[get_property -quiet OSERDES_D_BYPASS $sc7f0_tc_cell] clk_net=$sc7f0_tc_clk_net_name clkdiv_net=$sc7f0_tc_clkdn_name clkdiv_same_net=$sc7f0_tc_clkdiv_same d_pattern=$sc7f0_tc_dpat_s rst=$sc7f0_tc_rst_state tri_state=$sc7f0_tc_t_state ce_pins=[llength $sc7f0_tc_ce_pins] buffer=$sc7f0_txclk_buf buffer_ref=$sc7f0_tc_buf_ref buffer_p_net=$sc7f0_tc_buf_p_net buffer_n_net=$sc7f0_tc_buf_n_net buffer_site=$sc7f0_tc_buf_loc buffer_site_query=$sc7f0_tc_site_query master_chain=$sc7f0_tc_chain_s source_clock=$sc7f0_tc_src_name source_period=$sc7f0_tc_src_period source_waveform=$sc7f0_tc_wave_s source_is_generated=$sc7f0_tc_src_gen root_clock=$sc7f0_tc_root_clock root_clock_period=$sc7f0_tc_root_period root_clock_port=$sc7f0_tc_root_port pad_p=hdmi_tx_tmds_clk_p pad_p_pkg=[get_property -quiet PACKAGE_PIN $sc7f0_tc_port_p] pad_p_iostd=[get_property -quiet IOSTANDARD $sc7f0_tc_port_p] pad_n=hdmi_tx_tmds_clk_n pad_n_pkg=[get_property -quiet PACKAGE_PIN $sc7f0_tc_port_n] pad_n_iostd=[get_property -quiet IOSTANDARD $sc7f0_tc_port_n] pad_to_source_ratio_p=$sc7f0_tc_pad_ratio_p pad_to_source_ratio_n=$sc7f0_tc_pad_ratio_n source_over_root_ratio=$sc7f0_tc_ratio root_to_pad_note=divide_by_1_on_real_source false_path_rows_before_p=$sc7f0_tc_fp_before_p false_path_rows_before_n=$sc7f0_tc_fp_before_n false_path_rows_after_p=$sc7f0_tc_fp_after_p false_path_rows_after_n=$sc7f0_tc_fp_after_n max_output_delay_p=$sc7f0_tc_od_p max_output_delay_p_query=$sc7f0_tc_odq_p max_output_delay_n=$sc7f0_tc_od_n max_output_delay_n_query=$sc7f0_tc_odq_n clock_group_rows_before=$sc7f0_tc_cg_before clock_group_rows_after=$sc7f0_tc_cg_after clock_group_rows_added=$sc7f0_tc_cg_added readback_p=$sc7f0_tc_rbp_s readback_n=$sc7f0_tc_rbn_s review_required=1"
puts "SC7F0_TX_TMDSCLOCK_SCOPE mode=this_round_target_4k60_rgb8_only static_source_period_ns=$sc7f0_tc_src_period runtime_clkout1_frequency=UNMEASURED board_clock_eye=NOT_CLAIMED edid_window_297_340MHz=UNPROVEN no_format_whitelist_added=1 output_delay_rows_added=$sc7f0_tc_no_od_added clock_group_rows_added=$sc7f0_tc_cg_added tolerance_basis=tool_print_precision"
puts "SC7F0_TX_TMDSCLOCK_APPLY_PASS clocks=2 anchored_on=$sc7f0_tc_cell_name/CLK master=$sc7f0_tc_src_name legacy_fp_removed_from_profile=1 policy_status=pending_independent_review"
