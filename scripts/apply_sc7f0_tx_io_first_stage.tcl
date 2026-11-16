# =============================================================================
# scripts/apply_sc7f0_tx_io_first_stage.tcl
#
# FULL-Tcl implementation pre-opt hook: names and APPLIES the three HDMI TX
# input exceptions that only exist once the TX subsystem is built, and measures
# them in the same run.  SC7F0-RGB profile only (it is sourced from
# scripts/impl_pre_opt_sc7f0.tcl inside the SC7F0_RGB_COMPOSITOR branch, after
# scripts/check_sc7f0_capture_gray.tcl, which always runs first, and after
# scripts/apply_sc7f0_overlay_cdc.tcl).
#
# Why these three rows exist now (measured, not theorised).  Round
# rgb-fullimpl-26111335-20261113T214238Z (candidate E), Layer B manifest
# E/evidence-r3-finaldcp/reports/named-constraint-evidence.json items=40
# verdict=FAIL, and E/logs/runner_post_r3.log:218-260.  Nine problem strings,
# which are THREE crossings reported as three fragments each:
#
#   hdmi_tx_ddc_scl  unclaimed u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/GEN_DDC.DDC_INST/clk_scl_flt_reg[0]
#   hdmi_tx_ddc_sda  unclaimed .../GEN_DDC.DDC_INST/clk_sda_flt_reg[0]
#   hdmi_tx_hpd_in   unclaimed .../SYS_INST/HPD_INST/HPD_CAP_INST/XPM_INST/syncstages_ff_reg[0]
#
# Each of those three pads measured endpoint_count = 2 and
# claimed_first_stage_endpoints = 1: one exception for our own diagnostic
# u_hdmi_probe chain (constraints/sc7f0_async_io.xdc:60-71) and NO exception for
# the TX subsystem's own first stage.  Those XDC rows were written for the
# capture-only personality and say so ("probe chain is the only sequential
# consumer in the SC7F0_C2H_ONLY personality (TX subsystem not built)"); with
# SC7F0_TX_VIDEO_PRESENT the TX SS is built, so its DDC glitch filters and its
# HPD capture chain became a second consumer of the same asynchronous pads.  The
# coverage model is not wrong and was not weakened: it enumerates the pad's
# loads with all_fanout -endpoints_only -only_cells and reported the mismatch by
# name (scripts/check_sc7f0_named_constraints.tcl:1446-1509).
#
# Shape of the repair, identical to the pads that already pass (the RX DDC pair
# and hdmi_rx_5v_det have one exception PER CHAIN, constraints/sc7f0_async_io.xdc
# :84-123): exactly one `set_false_path -from <input port> -to <that chain's own
# first-stage FF>` per chain.  No port-wide exception, no clock group, no
# set_clock_groups, no blanket max delay: an unclaimed load must stay visible.
#
# Why full Tcl and not the managed .xdc (measured in
# rgb-fullimpl-26111333-20261113T204036Z, logs/build_full26111333.log:3796-3804):
# the read_xdc reader drops `if` and `concat` with
# [Designutils 20-1307] and keeps going, and a failed apply line there becomes
# "constraint absent" ([Common 17-1548] at :3803) rather than a stopped run.  In
# a profile-conditional row that means either the row silently does not exist or
# - if -to resolves empty - set_false_path widens to the whole port, which is
# exactly the coverage hole this file exists to close.  Here `error` aborts.
#
# This file approves nothing.  It does not write scripts/gates/*.json, does not
# set any REVIEWED_SAFE verdict, and does not classify the crossing as an
# accepted CDC policy: the clock-domain / ASYNC_REG / later-stage rows it prints
# and returns are the measurements a reviewer needs to classify it, and
# scripts/check_sc7f0_named_constraints.tcl still marks every one of them
# review_required = 1.
#
# WHY TWO OUTPUT ROWS WERE ADDED (round H measurement, not theory).  Round H
# (rgb-fullimpl-26111403-20261114T041353Z) still reported
#
#   TIMING-18#1  An output delay is missing on hdmi_tx_ddc_scl relative to the
#                rising and/or falling clock edge(s) of clk_pl_0
#   TIMING-18#2  ... on hdmi_tx_ddc_sda ...
#
# (audit_final_dcp/methodology_final.rpt:1655-1663).  A missing output delay is
# the tool saying exactly one thing here: a fabric register launches this pad and
# no constraint describes when.  Those launches are the DDC drive/shift logic in
# the TX subsystem; the pad is a passive-open-drain I2C line whose real timing
# comes from the source's pull-ups and the bus protocol, not from clk_pl_0, so a
# pixel/link-clock requirement on that cone is meaningless and the correct object
# is an output-direction false path ending AT THE PAD - the same shape the RX DDC
# pair already carries (constraints/sc7f0_async_io.xdc:183/185, ids
# async_out_hdmi_rx_ddc_scl / async_out_hdmi_rx_ddc_sda).  Round H carried the RX
# rows but no TX rows, because the RX rows were written when the capture-only
# personality had the only DDC pad that was built.
#
# Narrowness, and what these rows deliberately do NOT touch: `-to <port>` ends
# paths at the pad.  It is not a clock cut, it does not cover the input direction
# (the pad's own `set_false_path -from <port> -to <first stage FF>` rows stay as
# they were and are re-counted before/after here), it does not reach the vendor
# clk_*_flt_reg[0..2] glitch filter or the u_hdmi_probe synchroniser chain, and it
# does not re-time or waive any of the stages after the first.  A bidirectional
# pad therefore keeps both directions measured separately, and the two
# async_out_hdmi_tx_ddc_* manifest items stay review_required = 1.
# =============================================================================

# One chain per row: logical id (the Layer B item id the coverage manifest uses),
# pad, the TX-SS first-stage pattern this file claims, and the u_hdmi_probe
# pattern the legacy .xdc already claims.  The probe pattern is repeated here
# only so the consumer set can be enumerated completely: this file does not
# apply, edit or duplicate that older exception.
set sc7f0_txio_chains {
    async_in_hdmi_tx_hpd_in_txss hdmi_tx_hpd_in
    {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/HPD_INST/HPD_CAP_INST/XPM_INST/syncstages_ff_reg\[0\]$}
    {.*u_hdmi_probe/tx_hpd_sync_reg\[0\]$}

    async_in_hdmi_tx_ddc_scl_filter hdmi_tx_ddc_scl
    {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/GEN_DDC.DDC_INST/clk_scl_flt_reg\[0\]$}
    {.*u_hdmi_probe/tx_scl_sync_reg\[0\]$}

    async_in_hdmi_tx_ddc_sda_filter hdmi_tx_ddc_sda
    {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/GEN_DDC.DDC_INST/clk_sda_flt_reg\[0\]$}
    {.*u_hdmi_probe/tx_sda_sync_reg\[0\]$}
}

# Property query funnel: a collection answers with one value per object, and a
# short answer is an error rather than a blank (the failure mode that made an
# earlier manifest report "0 loads" for a pad that had three).
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

proc sc7f0_txio_names {objs} {
    if {$objs eq "" || [llength $objs] == 0} {return {}}
    if {[catch {get_property NAME $objs} names]} {return {}}
    return $names
}

# Sequential classification mirrors the coverage checker's own funnel
# (scripts/check_sc7f0_named_constraints.tcl:235-240) so the two cannot disagree
# about what a first stage is.
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

proc sc7f0_txio_clocks {obj} {
    if {$obj eq "" || [llength $obj] == 0} {return "-"}
    if {[catch {get_clocks -quiet -of_objects $obj} clocks]} {return QUERY_ERROR}
    if {$clocks eq ""} {return "-"}
    if {[catch {join [lsort -unique [get_property NAME $clocks]] |} text]} {return QUERY_ERROR}
    return $text
}

# Exception audit rows for one scope, read from `report_exceptions -coverage`,
# which is the form that carries a Type column (measured 2023.2 row format:
#   1218      False Path  false  false  1 ports           1 cells  1  100.00  33.33
# - and, unlike the plain form, it reports "No timing exceptions found." as zero
# rows).  QUERY_ERROR is returned as a row so a failed query can never be read as
# "nothing to report".
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

set sc7f0_txio_rows {}
set sc7f0_txio_applied 0

foreach {sc7f0_txio_id sc7f0_txio_port sc7f0_txio_pat sc7f0_txio_probe_pat} $sc7f0_txio_chains {
    # --- guards, every one of them exact, before any constraint is applied -----
    set sc7f0_txio_pobj [get_ports -quiet $sc7f0_txio_port]
    if {[llength $sc7f0_txio_pobj] != 1} {
        error "SC7F0_TX_IO_PORT $sc7f0_txio_id: get_ports $sc7f0_txio_port matched [llength $sc7f0_txio_pobj] objects, expected exactly 1. A set_false_path whose -from side is empty is not absent, it is device-wide."
    }
    array set sc7f0_txio_pd [sc7f0_txio_prop DIRECTION $sc7f0_txio_pobj]
    # Vivado answers DIRECTION with IN / OUT / INOUT, measured on the routed
    # 26111335 checkpoint: hdmi_tx_hpd_in = IN, and hdmi_tx_ddc_scl / hdmi_tx_ddc_sda
    # = INOUT with LVCMOS33 (the DDC pair is a genuinely bidirectional pad; the
    # FPGA is a passive observer of the bus, so its receiver path is what the
    # exception covers).  An output-only pad would be the one case where a
    # "first-stage load of an asynchronous input" row makes no sense.
    if {$sc7f0_txio_pd(error) eq "" && [lindex $sc7f0_txio_pd(values) 0] ni {IN INPUT INOUT}} {
        error "SC7F0_TX_IO_DIRECTION $sc7f0_txio_id: $sc7f0_txio_port is a [lindex $sc7f0_txio_pd(values) 0] pin; this exception is written for an asynchronous input."
    }
    array set sc7f0_txio_pi [sc7f0_txio_prop IOSTANDARD $sc7f0_txio_pobj]
    set sc7f0_txio_iostd [expr {$sc7f0_txio_pi(error) eq "" ? [lindex $sc7f0_txio_pi(values) 0] : {QUERY_ERROR}}]
    set sc7f0_txio_dir [expr {$sc7f0_txio_pd(error) eq "" ? [lindex $sc7f0_txio_pd(values) 0] : {QUERY_ERROR}}]

    set sc7f0_txio_dst [get_cells -quiet -hier -regexp $sc7f0_txio_pat]
    if {[llength $sc7f0_txio_dst] != 1} {
        error "SC7F0_TX_IO_FIRST_STAGE $sc7f0_txio_id: $sc7f0_txio_pat matched [llength $sc7f0_txio_dst] cells, expected exactly 1. 0 means the TX subsystem is not in this netlist (then this profile must not carry the row at all, not a port-wide exception) and >1 means the pattern is wider than one first stage."
    }
    set sc7f0_txio_dst_name [lindex [sc7f0_txio_names $sc7f0_txio_dst] 0]
    # A first stage is a D-pin register; anything else is not the object this
    # exception was written for.
    set sc7f0_txio_dpin [get_pins -quiet [list ${sc7f0_txio_dst_name}/D]]
    if {[llength $sc7f0_txio_dpin] != 1} {
        error "SC7F0_TX_IO_D_PIN $sc7f0_txio_id: [list ${sc7f0_txio_dst_name}/D] resolved to [llength $sc7f0_txio_dpin] pins, expected exactly 1."
    }

    # --- complete consumer closure of the pad, measured ------------------------
    set sc7f0_txio_fan [all_fanout -flat -endpoints_only -only_cells $sc7f0_txio_pobj]
    if {$sc7f0_txio_fan eq ""} {
        error "SC7F0_TX_IO_NO_LOADS $sc7f0_txio_id: all_fanout -endpoints_only -only_cells found no load on $sc7f0_txio_port."
    }
    set sc7f0_txio_seq [sc7f0_txio_sequential $sc7f0_txio_fan]
    set sc7f0_txio_seq_names [lsort -unique [sc7f0_txio_names $sc7f0_txio_seq]]
    set sc7f0_txio_probe [get_cells -quiet -hier -regexp $sc7f0_txio_probe_pat]
    if {[llength $sc7f0_txio_probe] != 1} {
        error "SC7F0_TX_IO_PROBE_CHAIN $sc7f0_txio_id: $sc7f0_txio_probe_pat matched [llength $sc7f0_txio_probe] cells, expected exactly 1. constraints/sc7f0_async_io.xdc:60-71 excepts that chain; if it is gone the older row is stale and this round must stop, not silently re-scope the pad."
    }
    set sc7f0_txio_known [lsort -unique [concat [sc7f0_txio_names $sc7f0_txio_probe] \
                             [sc7f0_txio_names $sc7f0_txio_dst]]]
    set sc7f0_txio_extra {}
    foreach sc7f0_txio_c $sc7f0_txio_seq_names {
        if {[lsearch -exact $sc7f0_txio_known $sc7f0_txio_c] < 0} {lappend sc7f0_txio_extra $sc7f0_txio_c}
    }
    # A fourth consumer must stop the round here instead of surfacing as a FAIL
    # manifest after a 45-minute route.  Nothing is excepted to make it pass.
    if {[llength $sc7f0_txio_extra] > 0} {
        error "SC7F0_TX_IO_UNCLAIMED_CONSUMER $sc7f0_txio_id: $sc7f0_txio_port also has sequential first-stage load(s) [join $sc7f0_txio_extra {, }] that neither constraints/sc7f0_async_io.xdc nor this file names. A third consumer is a new asynchronous load of an unconstrained pad: name it or fix the logic, do not widen an existing exception."
    }

    # --- what the pad's exception set looks like BEFORE this file touches it ---
    # Measured on candidate E's final checkpoint (round 26111401 probe
    # smoke2b_paths.tcl): the pair query answered "No timing exceptions found."
    # there, i.e. this chain really was unexcepted, and exactly one False Path row
    # exists after the command below.
    set sc7f0_txio_sel [list -from $sc7f0_txio_pobj -to $sc7f0_txio_dst]
    set sc7f0_txio_sel_pad [list -from $sc7f0_txio_pobj]
    set sc7f0_txio_pre [sc7f0_txio_exc_rows $sc7f0_txio_sel]
    set sc7f0_txio_pre_pad [sc7f0_txio_exc_rows $sc7f0_txio_sel_pad]
    if {[llength $sc7f0_txio_pre] != 0} {
        error "SC7F0_TX_IO_ALREADY_COVERED $sc7f0_txio_id: $sc7f0_txio_port -> $sc7f0_txio_dst_name is already covered by [llength $sc7f0_txio_pre] exception row(s) before this file applies anything ([join $sc7f0_txio_pre { | }]); two exceptions for one chain mean one of them is not the narrow row this file intends."
    }

    # --- apply: one command, this chain only -----------------------------------
    set sc7f0_txio_sfp [set_false_path -from $sc7f0_txio_pobj -to $sc7f0_txio_dst]
    catch {update_timing}

    # --- read back what the engine actually took -------------------------------
    # The authoritative readback is the exception audit, not get_timing_paths: on
    # this design the same pad -> FF query returns four path objects with EMPTY
    # REQUIREMENT and EMPTY SLACK both before and after the exception (an input
    # port that carries no clock is not timed against a requirement), so "no paths
    # left" would be wrong in both directions.  Vivado 2023.2 has no -name on
    # set_false_path, so the id below is the coverage item's logical name, not a
    # tool object name.
    set sc7f0_txio_post [sc7f0_txio_exc_rows $sc7f0_txio_sel]
    set sc7f0_txio_post_pad [sc7f0_txio_exc_rows $sc7f0_txio_sel_pad]
    set sc7f0_txio_paths [get_timing_paths -from $sc7f0_txio_pobj -to $sc7f0_txio_dst -delay_type max -max_paths 4 -nworst 4]
    set sc7f0_txio_npaths [llength $sc7f0_txio_paths]
    set sc7f0_txio_preqs {}
    foreach sc7f0_txio_q $sc7f0_txio_paths {
        set sc7f0_txio_qr [get_property REQUIREMENT $sc7f0_txio_q]
        if {$sc7f0_txio_qr eq ""} {set sc7f0_txio_qr "-"}
        lappend sc7f0_txio_preqs $sc7f0_txio_qr
    }
    if {[llength $sc7f0_txio_post] != 1} {
        error "SC7F0_TX_IO_NOT_APPLIED $sc7f0_txio_id: after set_false_path the audit for $sc7f0_txio_port -> $sc7f0_txio_dst_name shows [llength $sc7f0_txio_post] row(s) ([join $sc7f0_txio_post { | }]), expected exactly 1."
    }
    set sc7f0_txio_row [lindex $sc7f0_txio_post 0]
    if {![regexp {^[0-9]+\s+False\s+Path} $sc7f0_txio_row]} {
        error "SC7F0_TX_IO_WRONG_TYPE $sc7f0_txio_id: the row covering this chain is not a False Path: $sc7f0_txio_row"
    }
    # narrowness: exactly one port on the -from side and exactly one cell on the
    # -to side.  A port-wide (or clock-wide) exception shows a different shape here
    # and is exactly what the managed-reader version of this row used to become.
    if {![regexp {(^|\s)1 ports?(\s|$)} $sc7f0_txio_row] ||
        ![regexp {(^|\s)1 cells?(\s|$)} $sc7f0_txio_row]} {
        error "SC7F0_TX_IO_TOO_WIDE $sc7f0_txio_id: the applied row is not one-port -> one-cell: $sc7f0_txio_row"
    }
    # every exception this pad carries must be a per-chain False Path over cells,
    # and this file must have added exactly one of them
    if {[llength $sc7f0_txio_post_pad] != [expr {[llength $sc7f0_txio_pre_pad] + 1}]} {
        error "SC7F0_TX_IO_PAD_ROWS $sc7f0_txio_id: $sc7f0_txio_port had [llength $sc7f0_txio_pre_pad] exception row(s) and now has [llength $sc7f0_txio_post_pad] ([join $sc7f0_txio_post_pad { | }]); one chain must add exactly one row."
    }
    foreach sc7f0_txio_r $sc7f0_txio_post_pad {
        if {![regexp {False\s+Path} $sc7f0_txio_r] || ![regexp {\scells?(\s|$)} $sc7f0_txio_r]} {
            error "SC7F0_TX_IO_PAD_ROW_WIDE $sc7f0_txio_id: pad $sc7f0_txio_port carries an exception that is not a per-chain False Path over named cells: $sc7f0_txio_r"
        }
    }

    # --- measurement rows for the reviewer (no verdict written) ----------------
    array set sc7f0_txio_dp [sc7f0_txio_prop ASYNC_REG $sc7f0_txio_dst]
    set sc7f0_txio_dst_async [expr {$sc7f0_txio_dp(error) eq "" ? [lindex $sc7f0_txio_dp(values) 0] : {QUERY_ERROR}}]
    set sc7f0_txio_dst_clk [sc7f0_txio_clocks $sc7f0_txio_dst]
    set sc7f0_txio_down [all_fanout -flat -endpoints_only -only_cells [get_pins -quiet ${sc7f0_txio_dst_name}/Q]]
    set sc7f0_txio_down_seq [sc7f0_txio_sequential $sc7f0_txio_down]
    array set sc7f0_txio_ap [sc7f0_txio_prop ASYNC_REG $sc7f0_txio_down_seq]
    set sc7f0_txio_down_async 0
    if {$sc7f0_txio_ap(error) eq ""} {
        foreach sc7f0_txio_f $sc7f0_txio_ap(values) {
            if {[string tolower $sc7f0_txio_f] in {1 true yes}} {incr sc7f0_txio_down_async}
        }
    }
    set sc7f0_txio_down_clk [sc7f0_txio_clocks $sc7f0_txio_down_seq]
    set sc7f0_txio_pad_clocks [sc7f0_txio_clocks $sc7f0_txio_seq]
    puts "SC7F0_TX_IO_FIRST_STAGE_APPLIED $sc7f0_txio_id: set_false_path -from \[get_ports $sc7f0_txio_port\] -to \[get_cells $sc7f0_txio_dst_name\]; pad_loads_cells=[llength $sc7f0_txio_fan] sequential_loads=[llength $sc7f0_txio_seq] named_by_exceptions=[llength $sc7f0_txio_known] unclaimed=0 port_dir=$sc7f0_txio_dir port_iostd=$sc7f0_txio_iostd first_stage_clock=$sc7f0_txio_dst_clk first_stage_async_reg=$sc7f0_txio_dst_async later_stage_loads=[llength $sc7f0_txio_down_seq] later_stage_async_reg=$sc7f0_txio_down_async later_stage_clock=$sc7f0_txio_down_clk pad_first_stage_clocks=$sc7f0_txio_pad_clocks timed_path_objects=$sc7f0_txio_npaths timed_path_requirements=[join [lsort -unique $sc7f0_txio_preqs] |] pad_exception_rows_before=[llength $sc7f0_txio_pre_pad] pad_exception_rows_after=[llength $sc7f0_txio_post_pad] audit_row=$sc7f0_txio_row"
    lappend sc7f0_txio_rows $sc7f0_txio_id
    incr sc7f0_txio_applied
}

if {$sc7f0_txio_applied != 3} {
    error "SC7F0_TX_IO_INCOMPLETE: $sc7f0_txio_applied of 3 TX input chains were applied"
}

# =============================================================================
# OUTPUT direction of the same DDC pair lives in its own file
# (apply_sc7f0_tx_ddc_output_false_path.tcl) so that a read-only constraint
# preflight can source EXACTLY that block against a routed checkpoint without
# re-applying the three input exceptions above.  The block asserts the round H
# measurements before applying anything and errors out otherwise.
# =============================================================================
set sc7f0_txio_out_file [file normalize [file join [file dirname [info script]] apply_sc7f0_tx_ddc_output_false_path.tcl]]
if {![file readable $sc7f0_txio_out_file]} {
    error "SC7F0_TX_IO_OUT_MISSING: $sc7f0_txio_out_file is not readable; the TX DDC output exceptions cannot be skipped silently."
}
puts "SC7F0_TX_IO_OUT_SOURCE $sc7f0_txio_out_file"
source $sc7f0_txio_out_file

puts "SC7F0_TX_IO_FIRST_STAGE_APPLY_PASS chains=[join $sc7f0_txio_rows {, }] output_rows=[join $sc7f0_txio_out_ids {, }] exceptions_in=3 exceptions_out=2 width=port_to_named_first_D_plus_port_only policy_rows_review_required=5"

