# apply_sc7f0_tx_ddc_output_false_path.tcl
#
# Round-H gap 2 (measured, not assumed): on the final 26111403 routed checkpoint
#   * hdmi_tx_ddc_scl / hdmi_tx_ddc_sda are INOUT LVCMOS33 pads whose net carries one
#     IOBUF leaf (u_tx_ddc/u_scl, u_tx_ddc/u_sda); the leaf I pin is tied to GND and
#     the leaf T pin is driven from exactly ONE clocked startpoint,
#     u_hdmi_tx_ss/.../GEN_DDC.DDC_INST/clk_scl_out_reg / clk_sda_out_reg, FDPE,
#     clk_pl_0.  So the fabric really does drive the pads and the output cone is a
#     single clk_pl_0 register.
#   * methodology_final.rpt reports TIMING-18#1/#2 "An output delay is missing on
#     hdmi_tx_ddc_scl|sda relative to ... clk_pl_0", i.e. that cone is analysed
#     against a clk_pl_0 requirement with no output delay defined, and
#     report_exceptions -coverage shows NO -to [get_ports hdmi_tx_ddc_*] row while the
#     RX mirror carries async_out_hdmi_rx_ddc_scl/sda (constraints/sc7f0_async_io.xdc).
#
# An I2C/DDC pad is an asynchronous open-drain bus: the only fabric->pad logic is the
# open-drain output enable, there is no receiver timing to meet at the FPGA, and the
# real timing is set by the bus spec and the pull-up.  That is the same argument the
# RX side already accepts, applied to the TX side only, ending AT THE PAD.
#
# Scope discipline, enforced by the guards below (each one is an `error`, which stops
# the implementation step rather than shipping a wide or missing exception):
#   - exactly one port, DIRECTION INOUT, IOSTANDARD LVCMOS33, and exactly one
#     IOBUF-family pad leaf resolving to the measured leaf name of this pad
#     (u_tx_ddc/u_scl, u_tx_ddc/u_sda) - otherwise there is no output cone to except
#   - no pre-existing -to exception on that port; exactly one False Path row after,
#     shaped "1 ports"; the pad's input-direction exception rows are untouched before
#     and after; the pad keeps exactly its two measured sequential first-stage loads
#     (vendor clk_*_flt_reg[0] + u_hdmi_probe/*_sync_reg[0]), so the input direction and
#     its first-D exceptions stay exactly as constrained elsewhere
#   - no -name (set_false_path in 2023.2 has no -name), no managed-XDC if/concat, no
#     clock groups, no clock waveforms, no ASYNC_REG, nothing about the RX pads and
#     nothing about hdmi_tx_hpd.
#
# What this file deliberately does NOT claim: any board-level voltage property.
# The pads are asserted to be LVCMOS33 because that is what the routed checkpoint
# measures; the earlier "+5V-tolerant DDC bank" wording was an unproven assertion
# about the device/bank and has been removed (the DDC site's IOSTANDARD is
# measured, its tolerance behaviour toward an external supply is not, and nothing
# here depends on it).
#
# Every entry this file creates stays review_required = 1 in
# scripts/check_sc7f0_named_constraints.tcl; nothing here self-approves anything.
#
# This file is standalone on purpose: scripts/apply_sc7f0_tx_io_first_stage.tcl
# sources it after the three input chains, and a read-only constraint preflight can
# source THIS file alone, so the preflight applies byte-identically the same block and
# does not re-apply the three input exceptions (which would double them).
# Helper procs are defined only when the caller has not already defined them.

if {[info procs sc7f0_txio_prop] eq ""} {
proc sc7f0_txio_prop {prop objs} {
    array set r {values {} error {}}
    if {$objs eq "" || [llength $objs] == 0} {
        set r(error) "empty object list"
        return [array get r]
    }
    if {[catch {get_property $prop $objs} values]} {
        set r(error) "get_property $prop failed: $values"
        return [array get r]
    }
    if {[llength $values] != [llength $objs]} {
        set r(error) "get_property $prop returned [llength $values] value(s) for [llength $objs] object(s)"
        return [array get r]
    }
    set r(values) $values
    return [array get r]
}
}


if {[info procs sc7f0_txio_names] eq ""} {
proc sc7f0_txio_names {objs} {
    if {$objs eq "" || [llength $objs] == 0} {return {}}
    if {[catch {get_property NAME $objs} names]} {return {}}
    return $names
}
}


if {[info procs sc7f0_txio_sequential] eq ""} {
proc sc7f0_txio_sequential {cells} {
    set out {}
    if {$cells eq "" || [llength $cells] == 0} {return $out}
    array set p [sc7f0_txio_prop REF_NAME $cells]
    if {$p(error) ne ""} {error "SC7F0_TX_IO_REF_NAME_QUERY_FAILED $p(error)"}
    set i 0
    foreach cell $cells {
        set ref [lindex $p(values) $i]
        foreach family {FD LD IDDR IDES ISERDESE} {
            if {[string match ${family}* $ref]} {lappend out $cell; break}
        }
        incr i
    }
    return $out
}
}


if {[info procs sc7f0_txio_exc_rows] eq ""} {
proc sc7f0_txio_exc_rows {sel} {
    if {[catch {report_exceptions -coverage {*}$sel -quiet -return_string} txt]} {
        return [list "QUERY_ERROR $txt"]
    }
    set rows {}
    set seen 0
    foreach line [split $txt \n] {
        set t [string trim $line]
        if {[string match "Position*" $t]} {set seen 1; continue}
        if {!$seen} {continue}
        if {[regexp {^[0-9]+} $t]} {lappend rows $t}
    }
    return $rows
}
}

# Pad leaf resolution: which primitive actually drives this pad?
#
# WHY THIS IS A PROC AND NOT ONE QUERY.  On the routed 26111403 checkpoint the TX
# DDC pads do not attach to an IOBUF directly: the pad net enters the wrapper
# u_tx_ddc through a hierarchical pin, and the IOBUF-family primitive sits one
# level inside it (gap6 measurement: leaves u_tx_ddc/u_scl and u_tx_ddc/u_sda,
# REF_NAME IOBUF, pins I/IO/O/T).  `get_cells -of_objects [get_pins -of_objects
# [get_nets -of_objects <port>]]` therefore answers with the WRAPPER, whose
# REF_NAME is not IOBUF*, so the previous revision of this file would have
# reported "0 IOBUF-family leaf cells" and stopped the round on a design that is
# actually fine - a query bug dressed up as a design bug.
#
# The three spelling attempts below are all documented 2023.2 object walks; the
# one that produced the answer is recorded in the APPLIED line (`pad_leaf_method`)
# so the manifest says how the number was measured.  Whichever spelling works, the
# ANSWER is still pinned by a positive exact-name guard: exactly one cell, and its
# NAME must be the expected leaf of this pad.  An empty wildcard answer is never
# accepted as "good enough", and a wrong or duplicated leaf is an error.
if {[info procs sc7f0_txio_pad_leaf] eq ""} {
proc sc7f0_txio_pad_leaf {po expect_leaf} {
    set sc7f0_pl_attempts {}
    set sc7f0_pl_net [get_nets -quiet -of_objects $po]
    if {[llength $sc7f0_pl_net] != 1} {return [list {} {pad net did not resolve}]}
    set sc7f0_pl_cands {}

    # (A) direct: a primitive on the pad net itself
    if {[catch {get_cells -quiet -of_objects [get_pins -quiet -of_objects $sc7f0_pl_net]} sc7f0_pl_a] == 0} {
        lappend sc7f0_pl_cands [list {get_cells -of_objects <pad net pins>} $sc7f0_pl_a]
    }
    # (B) through hierarchical pins: all_connected is the documented query for
    #     connectivity that continues inside a wrapper
    if {[catch {all_connected -quiet $sc7f0_pl_net} sc7f0_pl_b] == 0} {
        if {[catch {get_cells -quiet -of_objects $sc7f0_pl_b} sc7f0_pl_b2] == 0} {
            lappend sc7f0_pl_cands [list {all_connected <pad net>} $sc7f0_pl_b2]
        }
    }
    # (C) bounded name search for the expected leaf, scoped to the pad primitive
    #     family and to the wrapper that the expected name already names
    if {[catch {get_cells -quiet $expect_leaf} sc7f0_pl_c] == 0 && [llength $sc7f0_pl_c] == 1} {
        lappend sc7f0_pl_cands [list {get_cells <expected leaf name>} $sc7f0_pl_c]
    }

    foreach sc7f0_pl_try $sc7f0_pl_cands {
        set sc7f0_pl_method [lindex $sc7f0_pl_try 0]
        lappend sc7f0_pl_attempts $sc7f0_pl_method
        set sc7f0_pl_keep {}
        array set sc7f0_pl_ref [sc7f0_txio_prop REF_NAME [lindex $sc7f0_pl_try 1]]
        if {$sc7f0_pl_ref(error) ne ""} {continue}
        set sc7f0_pl_i 0
        foreach sc7f0_pl_c [lindex $sc7f0_pl_try 1] {
            if {[string match IOBUF* [lindex $sc7f0_pl_ref(values) $sc7f0_pl_i]]} {
                lappend sc7f0_pl_keep $sc7f0_pl_c
            }
            incr sc7f0_pl_i
        }
        if {[llength $sc7f0_pl_keep] == 1} {
            array set sc7f0_pl_nm [sc7f0_txio_prop NAME $sc7f0_pl_keep]
            if {$sc7f0_pl_nm(error) eq "" && [lindex $sc7f0_pl_nm(values) 0] eq $expect_leaf} {
                return [list $sc7f0_pl_keep $sc7f0_pl_method]
            }
        }
    }
    return [list {} "no IOBUF-family leaf named $expect_leaf (tried: [join $sc7f0_pl_attempts {; }])"]
}
}

# =============================================================================
# OUTPUT direction of the same DDC pair: one false path per pad, ending at the
# pad.  Guards first, constraint second, readback third; any mismatch is `error`,
# which stops the implementation step instead of shipping an unconstrained or an
# over-broad exception.
#
# The expected values below are the round H measurements of THIS design
# (audit_final_dcp DCP queries, gap2b helper M2 section): hdmi_tx_ddc_scl /
# hdmi_tx_ddc_sda are INOUT, LVCMOS33, on bank 46, and the pad net carries one
# IOBUF-family leaf, i.e. the fabric really drives the pad and an output path
# exists.  An assertion here that the design contradicts is a design change and
# must stop the round, not be worked around.
# =============================================================================
set sc7f0_txio_out_ids {}
set sc7f0_txio_out_applied 0

foreach {sc7f0_txio_oid sc7f0_txio_oport sc7f0_txio_oleaf} {
    async_out_hdmi_tx_ddc_scl hdmi_tx_ddc_scl u_tx_ddc/u_scl
    async_out_hdmi_tx_ddc_sda hdmi_tx_ddc_sda u_tx_ddc/u_sda
} {
    set sc7f0_txio_po [get_ports -quiet $sc7f0_txio_oport]
    if {[llength $sc7f0_txio_po] != 1} {
        error "SC7F0_TX_IO_OUT_PORT $sc7f0_txio_oid: get_ports $sc7f0_txio_oport matched [llength $sc7f0_txio_po] objects, expected exactly 1. A set_false_path whose -to side is empty is not absent, it is device-wide."
    }
    array set sc7f0_txio_od [sc7f0_txio_prop DIRECTION $sc7f0_txio_po]
    set sc7f0_txio_odir [expr {$sc7f0_txio_od(error) eq "" ? [lindex $sc7f0_txio_od(values) 0] : {QUERY_ERROR}}]
    if {$sc7f0_txio_odir ne "INOUT"} {
        error "SC7F0_TX_IO_OUT_DIRECTION $sc7f0_txio_oid: $sc7f0_txio_oport measured $sc7f0_txio_odir, expected INOUT (an I2C pad is bidirectional; measured INOUT on the routed 26111403 checkpoint). A different direction means the pin plan or the pad primitive changed, and this row would then be an output exception on something that has no output."
    }
    array set sc7f0_txio_oi [sc7f0_txio_prop IOSTANDARD $sc7f0_txio_po]
    set sc7f0_txio_oistd [expr {$sc7f0_txio_oi(error) eq "" ? [lindex $sc7f0_txio_oi(values) 0] : {QUERY_ERROR}}]
    if {$sc7f0_txio_oistd ne "LVCMOS33"} {
        # This is a MEASURED property of the placed-and-routed checkpoint, not a
        # statement about the connector: round H reports LVCMOS33 on bank 46 for
        # both pads.  No 5V-tolerance or "5V-tolerant bank" claim is made here or
        # anywhere else in this file - that is a board/power-supply property of the
        # site and the datasheet, it was never measured on this design, and an
        # earlier revision of this header asserted it without evidence.
        error "SC7F0_TX_IO_OUT_IOSTANDARD $sc7f0_txio_oid: $sc7f0_txio_oport measured $sc7f0_txio_oistd, expected LVCMOS33 (the IOSTANDARD measured on the routed 26111403 checkpoint for the DDC pair on bank 46). A different IOSTANDARD means the pin plan changed and this row is being applied to a pad that was not reviewed."
    }
    # The pad must really be fabric-driven, otherwise there is no output cone and
    # this exception would be decoration.  The leaf is resolved through the pad
    # wrapper by sc7f0_txio_pad_leaf (see the note above the proc) and pinned to
    # the exact measured leaf name of this pad.
    set sc7f0_txio_onet [get_nets -quiet -of_objects $sc7f0_txio_po]
    if {[llength $sc7f0_txio_onet] != 1} {
        error "SC7F0_TX_IO_OUT_NET $sc7f0_txio_oid: $sc7f0_txio_oport resolves to [llength $sc7f0_txio_onet] pad net(s), expected exactly 1."
    }
    lassign [sc7f0_txio_pad_leaf $sc7f0_txio_po $sc7f0_txio_oleaf] sc7f0_txio_iobufs sc7f0_txio_leaf_method
    if {[llength $sc7f0_txio_iobufs] != 1} {
        error "SC7F0_TX_IO_OUT_DRIVER $sc7f0_txio_oid: the pad of $sc7f0_txio_oport resolves to no single IOBUF-family leaf named $sc7f0_txio_oleaf ($sc7f0_txio_leaf_method). The output-direction exception is written for a pad the fabric tri-states onto an I2C bus; without that leaf there is nothing to except."
    }

    # what the pad's OUTPUT cone looks like before the exception (TIMING-18 says
    # a clk_pl_0 launch reaches this pad with no output delay defined)
    if {[catch {set sc7f0_txio_opre [get_timing_paths -to $sc7f0_txio_po -delay_type max -max_paths 5 -nworst 1]} sc7f0_txio_e]} {
        error "SC7F0_TX_IO_OUT_PATHS_QUERY $sc7f0_txio_oid: get_timing_paths -to $sc7f0_txio_oport failed: $sc7f0_txio_e"
    }
    set sc7f0_txio_oworst "-"
    foreach sc7f0_txio_q $sc7f0_txio_opre {
        set sc7f0_txio_s [get_property SLACK $sc7f0_txio_q]
        if {$sc7f0_txio_s eq ""} {continue}
        if {$sc7f0_txio_oworst eq "-" || [expr {double($sc7f0_txio_s) < double($sc7f0_txio_oworst)}]} {
            set sc7f0_txio_oworst $sc7f0_txio_s
        }
    }

    # pre-state: no output-direction exception may already exist, and the input
    # direction must keep exactly as many exception rows as it had
    set sc7f0_txio_pre_to  [sc7f0_txio_exc_rows [list -to $sc7f0_txio_po]]
    set sc7f0_txio_pre_from [sc7f0_txio_exc_rows [list -from $sc7f0_txio_po]]
    if {[llength $sc7f0_txio_pre_to] != 0} {
        error "SC7F0_TX_IO_OUT_ALREADY_COVERED $sc7f0_txio_oid: $sc7f0_txio_oport already carries [llength $sc7f0_txio_pre_to] output-direction exception row(s) ([join $sc7f0_txio_pre_to { | }]); applying a second one hides the first."
    }

    set sc7f0_txio_sfp2 [set_false_path -to $sc7f0_txio_po]
    # update_timing is what makes the audit below describe the constraint that was
    # just applied.  Swallowing its error (the previous revision: `catch
    # {update_timing}`) would let a failed re-timing pass as "the exception is in
    # place", so a failure here stops the implementation step.
    if {[catch {update_timing} sc7f0_txio_ue]} {
        error "SC7F0_TX_IO_OUT_UPDATE_TIMING_FAILED $sc7f0_txio_oid: update_timing after set_false_path -to $sc7f0_txio_oport returned: $sc7f0_txio_ue"
    }

    set sc7f0_txio_post_to  [sc7f0_txio_exc_rows [list -to $sc7f0_txio_po]]
    set sc7f0_txio_post_from [sc7f0_txio_exc_rows [list -from $sc7f0_txio_po]]
    if {[llength $sc7f0_txio_post_to] != 1} {
        error "SC7F0_TX_IO_OUT_NOT_APPLIED $sc7f0_txio_oid: after set_false_path the audit for -to $sc7f0_txio_oport shows [llength $sc7f0_txio_post_to] row(s) ([join $sc7f0_txio_post_to { | }]), expected exactly 1."
    }
    set sc7f0_txio_orow [lindex $sc7f0_txio_post_to 0]
    if {![regexp {^[0-9]+\s+False\s+Path} $sc7f0_txio_orow]} {
        error "SC7F0_TX_IO_OUT_WRONG_TYPE $sc7f0_txio_oid: the row on -to $sc7f0_txio_oport is not a False Path: $sc7f0_txio_orow"
    }
    if {![regexp {(^|\s)1 ports?(\s|$)} $sc7f0_txio_orow]} {
        error "SC7F0_TX_IO_OUT_TOO_WIDE $sc7f0_txio_oid: the applied row is not exactly one port: $sc7f0_txio_orow"
    }
    if {[llength $sc7f0_txio_post_from] != [llength $sc7f0_txio_pre_from]} {
        error "SC7F0_TX_IO_OUT_INPUT_DISTURBED $sc7f0_txio_oid: $sc7f0_txio_oport had [llength $sc7f0_txio_pre_from] input-direction exception row(s) and now has [llength $sc7f0_txio_post_from] ([join $sc7f0_txio_post_from { | }]); the output row must not change the input side."
    }
    # What the tool still analyses at this pad is REPORTED, not assumed away.
    # Measured on the round H routed checkpoint (preflight2, 2026-11-14): after
    # set_false_path -to the pad and update_timing, `report_exceptions -coverage -to
    # <pad>` shows exactly ONE new False Path row scoped to "1 ports", while
    # `get_timing_paths -to <pad>` still returns ONE analysed path.  An earlier
    # revision of this file demanded zero paths and so stopped a design that is fine
    # (SC7F0_TX_IO_OUT_STILL_TIMED, preflight2 BLOCK_SOURCE rc=1): "no path object
    # left" is a guess about how the tool reports, not a fact about the design.  The
    # enforceable statements stay - the row exists, is a False Path, is exactly one
    # port wide, and leaves the input side alone - and the retained path is printed
    # with its identity so a reviewer can see what is still being analysed instead of
    # being told it disappeared.  TIMING-18 ("an output delay is missing") is a
    # methodology finding about an undefined output delay; whether it disappears from
    # report_methodology in a fresh session is a separate measurement, not something
    # this apply step may claim.
    if {[catch {set sc7f0_txio_opost [get_timing_paths -to $sc7f0_txio_po -delay_type max -max_paths 5 -nworst 1]} sc7f0_txio_e2]} {
        error "SC7F0_TX_IO_OUT_PATHS_QUERY2 $sc7f0_txio_oid: $sc7f0_txio_e2"
    }
    set sc7f0_txio_opost_desc {}
    foreach sc7f0_txio_q $sc7f0_txio_opost {
        set sc7f0_txio_sp "-"; set sc7f0_txio_ep "-"
        set sc7f0_txio_pt "-"; set sc7f0_txio_rq "-"; set sc7f0_txio_sk "-"
        foreach {sc7f0_txio_pp sc7f0_txio_vv} {
            STARTPOINT sc7f0_txio_sp ENDPOINT sc7f0_txio_ep
            PATH_TYPE sc7f0_txio_pt REQUIREMENT sc7f0_txio_rq SLACK sc7f0_txio_sk
        } {
            catch {set $sc7f0_txio_vv [get_property $sc7f0_txio_pp $sc7f0_txio_q]}
        }
        lappend sc7f0_txio_opost_desc "sp=$sc7f0_txio_sp ep=$sc7f0_txio_ep type=$sc7f0_txio_pt req=$sc7f0_txio_rq slack=$sc7f0_txio_sk"
    }
    # input first stages of the same pad must still be there, still two, still the
    # two chains constraints/sc7f0_async_io.xdc and the loop above name.
    # all_fanout accepts its source after -from on this tool (measured: BOTH the
    # positional and the -from spelling return the same 2 endpoint cells, while
    # `help all_fanout` itself does not print -from); a query that errors here must
    # stop the round instead of silently reporting zero loads.
    if {[catch {all_fanout -flat -endpoints_only -only_cells -from $sc7f0_txio_po} sc7f0_txio_ofan]} {
        error "SC7F0_TX_IO_OUT_FANOUT_QUERY $sc7f0_txio_oid: all_fanout -flat -endpoints_only -only_cells -from $sc7f0_txio_oport failed: $sc7f0_txio_ofan"
    }
    set sc7f0_txio_oseq [sc7f0_txio_sequential $sc7f0_txio_ofan]
    if {[llength $sc7f0_txio_oseq] != 2} {
        error "SC7F0_TX_IO_OUT_INPUT_LOADS $sc7f0_txio_oid: $sc7f0_txio_oport has [llength $sc7f0_txio_oseq] sequential first-stage load(s) ([join [sc7f0_txio_names $sc7f0_txio_oseq] {, }]), expected the two measured loads (vendor clk_*_flt_reg[0] + u_hdmi_probe). The output row is not allowed to change what the pad drives into the fabric."
    }
    set sc7f0_txio_oleaf_name [lindex [sc7f0_txio_names $sc7f0_txio_iobufs] 0]
    if {[catch {set sc7f0_txio_oleaf_ref [get_property REF_NAME $sc7f0_txio_iobufs]} sc7f0_txio_e3]} {set sc7f0_txio_oleaf_ref QUERY_ERROR}
    puts "SC7F0_TX_IO_OUT_APPLIED $sc7f0_txio_oid: set_false_path -to \[get_ports $sc7f0_txio_oport\]; port_dir=$sc7f0_txio_odir port_iostd=$sc7f0_txio_oistd pad_leaf=$sc7f0_txio_oleaf_name pad_leaf_ref=$sc7f0_txio_oleaf_ref pad_leaf_method=$sc7f0_txio_leaf_method out_timed_paths_before=[llength $sc7f0_txio_opre] out_worst_slack_before=$sc7f0_txio_oworst out_timed_paths_after=[llength $sc7f0_txio_opost] out_timed_paths_after_desc=[join $sc7f0_txio_opost_desc { ; }] pad_input_loads=[llength $sc7f0_txio_oseq] pad_input_load_names=[join [sc7f0_txio_names $sc7f0_txio_oseq] {,}] input_exception_rows_before=[llength $sc7f0_txio_pre_from] input_exception_rows_after=[llength $sc7f0_txio_post_from] audit_row=$sc7f0_txio_orow"
    lappend sc7f0_txio_out_ids $sc7f0_txio_oid
    incr sc7f0_txio_out_applied
}


if {$sc7f0_txio_out_applied != 2} {
    error "SC7F0_TX_IO_OUT_INCOMPLETE: $sc7f0_txio_out_applied of 2 TX DDC output rows were applied"
}
puts "SC7F0_TX_DDC_OUTPUT_APPLY_PASS rows=[join $sc7f0_txio_out_ids {, }] exceptions_out=2 width=port_only policy_rows_review_required=2"
