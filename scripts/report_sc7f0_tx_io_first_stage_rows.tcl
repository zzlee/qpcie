# =============================================================================
# scripts/report_sc7f0_tx_io_first_stage_rows.tcl
#
# READ-ONLY measurement producer for the three HDMI TX input first stages that
# scripts/apply_sc7f0_tx_io_first_stage.tcl names.  It applies nothing; it is the
# post-implementation counterpart of that hook, meant to be sourced on this
# round's implemented design so the reviewer gets rows instead of a log line:
#
#   * the pad object, its direction and IOSTANDARD as the tool reports them
#     (hdmi_tx_hpd_in is IN, the two DDC pads are INOUT - measured, not assumed);
#   * the named first-stage cell, its D pin, its clock domain and its ASYNC_REG,
#     with "unset" separated from "query failed" (the vendor DDC filter carries
#     no ASYNC_REG, the XPM HPD chain does; both facts are the reviewer's, and a
#     tool answer of "empty" is not a tool error);
#   * the pad's full sequential consumer set, measured with all_fanout, and
#     whether each of them is named by an exception the tool actually holds
#     (report_exceptions -coverage, which is the only way to enumerate exceptions
#     in 2023.2 - there is no get_exceptions and no -name on set_false_path);
#   * the LATER stages of each chain: their reference, clock domain, ASYNC_REG,
#     and the requirement of the paths that reach them, which is the resolution
#     evidence - only pad -> first stage is excepted, everything after it must
#     still be timed normally;
#   * the paths that end at the first stage split by endpoint pin, because
#     `get_timing_paths -to <cell>` also returns the recovery / removal paths of
#     the cell's asynchronous set/reset pins.  Those are not data launches and
#     must not be classified as such.
#
# It writes no file and approves nothing.  Every row is review_required material.
# =============================================================================
proc txrows_prop {prop obj} {
    if {$obj eq "" || [llength $obj] == 0} {return {EMPTY_OBJECT_LIST}}
    if {[catch {get_property $prop $obj} value]} {return "QUERY_ERROR: $value"}
    if {$value eq ""} {return "unset(false)"}
    return $value
}

proc txrows_clocks {obj} {
    if {$obj eq "" || [llength $obj] == 0} {return "-"}
    if {[catch {get_clocks -quiet -of_objects $obj} clocks]} {return QUERY_ERROR}
    if {$clocks eq ""} {return "-"}
    if {[catch {join [lsort -unique [get_property NAME $clocks]] |} text]} {return QUERY_ERROR}
    return $text
}

proc txrows_exc {sel} {
    if {[catch {report_exceptions -coverage {*}$sel -quiet -return_string} txt]} {
        return [list "QUERY_ERROR"]
    }
    set rows {}
    set seen 0
    foreach line [split $txt \n] {
        set t [string trim $line]
        if {[string match "Position*" $t]} {set seen 1; continue}
        if {!$seen} {continue}
        if {[regexp {^[0-9]+} $t]} {lappend rows [string range $t 0 140]}
    }
    return $rows
}

proc txrows_seq {cells} {
    set out {}
    if {$cells eq "" || [llength $cells] == 0} {return $out}
    if {[catch {get_property REF_NAME $cells} refs]} {return $out}
    set i 0
    foreach c $cells {
        set ref [lindex $refs $i]
        foreach fam {FD LD IDDR IDES ISERDESE} {
            if {[string match ${fam}* $ref]} {lappend out $c; break}
        }
        incr i
    }
    return $out
}

set txrows_checked 0
foreach {txrows_id txrows_port txrows_txpat txrows_probe_pat} {
    async_in_hdmi_tx_hpd_in_txss hdmi_tx_hpd_in
    {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/HPD_INST/HPD_CAP_INST/XPM_INST/syncstages_ff_reg\[0\]$}
    {.*u_hdmi_probe/tx_hpd_sync_reg\[0\]$}
    async_in_hdmi_tx_ddc_scl_filter hdmi_tx_ddc_scl
    {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/GEN_DDC.DDC_INST/clk_scl_flt_reg\[0\]$}
    {.*u_hdmi_probe/tx_scl_sync_reg\[0\]$}
    async_in_hdmi_tx_ddc_sda_filter hdmi_tx_ddc_sda
    {.*u_hdmi_tx_ss/inst/v_hdmi_tx/inst/SYS_INST/GEN_DDC.DDC_INST/clk_sda_flt_reg\[0\]$}
    {.*u_hdmi_probe/tx_sda_sync_reg\[0\]$}
} {
    set txrows_pobj [get_ports -quiet $txrows_port]
    set txrows_dst [get_cells -quiet -hier -regexp $txrows_txpat]
    set txrows_prb [get_cells -quiet -hier -regexp $txrows_probe_pat]
    if {[llength $txrows_pobj] != 1} {error "SC7F0_TX_IO_ROWS_PORT $txrows_id: [llength $txrows_pobj] port objects"}
    if {[llength $txrows_dst] != 1} {error "SC7F0_TX_IO_ROWS_FIRST_STAGE $txrows_id: [llength $txrows_dst] objects for $txrows_txpat"}
    if {[llength $txrows_prb] != 1} {error "SC7F0_TX_IO_ROWS_PROBE $txrows_id: [llength $txrows_prb] objects for $txrows_probe_pat"}
    set txrows_dn [get_property NAME $txrows_dst]
    set txrows_dpin [get_pins -quiet ${txrows_dn}/D]
    set txrows_loads [all_fanout -flat -endpoints_only -only_cells $txrows_pobj]
    set txrows_seq [txrows_seq $txrows_loads]
    set txrows_seq_names [lsort -unique [get_property NAME $txrows_seq]]
    set txrows_named [lsort -unique [list [get_property NAME $txrows_dst] [get_property NAME $txrows_prb]]]
    set txrows_un {}
    foreach txrows_c $txrows_seq_names {
        if {[lsearch -exact $txrows_named $txrows_c] < 0} {lappend txrows_un $txrows_c}
    }
    # exceptions the tool really holds, per chain and per pad
    set txrows_exc_pair [txrows_exc [list -from $txrows_pobj -to $txrows_dst]]
    set txrows_exc_probe [txrows_exc [list -from $txrows_pobj -to $txrows_prb]]
    set txrows_exc_pad [txrows_exc [list -from $txrows_pobj]]
    # data paths that really end at the D pin, and the paths that end at the
    # cell's other (asynchronous control) pins, kept apart
    set txrows_dp [get_timing_paths -from $txrows_pobj -to $txrows_dpin -delay_type max -max_paths 8 -nworst 4]
    set txrows_dreqs {}
    foreach txrows_q $txrows_dp {
        set txrows_r [get_property REQUIREMENT $txrows_q]
        if {$txrows_r eq ""} {set txrows_r "no-requirement(not-timed)"}
        lappend txrows_dreqs $txrows_r
    }
    set txrows_cell [get_timing_paths -to $txrows_dst -delay_type max -max_paths 32 -nworst 4]
    set txrows_ctrl {}
    set txrows_dcount 0
    foreach txrows_q $txrows_cell {
        set txrows_ep [get_property ENDPOINT_PIN $txrows_q]
        set txrows_sp [get_property STARTPOINT_PIN $txrows_q]
        set txrows_r [get_property REQUIREMENT $txrows_q]
        if {$txrows_r eq ""} {set txrows_r "no-requirement(not-timed)"}
        if {$txrows_ep eq "${txrows_dn}/D"} {incr txrows_dcount; continue}
        lappend txrows_ctrl "$txrows_sp[[txrows_clocks [get_pins -quiet $txrows_sp]]] -> $txrows_ep[[txrows_clocks [get_pins -quiet $txrows_ep]]] req=$txrows_r"
    }
    # the later stages of this chain: still timed, at the real destination period
    set txrows_down [all_fanout -flat -endpoints_only -only_cells [get_pins -quiet ${txrows_dn}/Q]]
    set txrows_dseq [txrows_seq $txrows_down]
    set txrows_down_rows {}
    foreach txrows_c $txrows_dseq {
        set txrows_cn [get_property NAME $txrows_c]
        set txrows_cp [get_pins -quiet ${txrows_cn}/D]
        set txrows_cps [get_timing_paths -to $txrows_cp -delay_type max -max_paths 4 -nworst 4]
        set txrows_creq ""
        foreach txrows_q $txrows_cps {
            set txrows_r [get_property REQUIREMENT $txrows_q]
            if {$txrows_r ne ""} {set txrows_creq $txrows_r; break}
        }
        if {$txrows_creq eq ""} {set txrows_creq "none-timed"}
        lappend txrows_down_rows "$txrows_cn\[ref=[txrows_prop REF_NAME $txrows_c] clk=[txrows_clocks $txrows_c] ASYNC_REG=[txrows_prop ASYNC_REG $txrows_c] paths=[llength $txrows_cps] req=$txrows_creq\]"
    }
    puts "SC7F0_TX_IO_ROWS $txrows_id: port=$txrows_port direction=[txrows_prop DIRECTION $txrows_pobj] iostandard=[txrows_prop IOSTANDARD $txrows_pobj] first_stage=$txrows_dn d_pins=[llength $txrows_dpin] first_stage_clock=[txrows_clocks $txrows_dst] first_stage_ASYNC_REG=[txrows_prop ASYNC_REG $txrows_dst] pad_load_cells=[llength $txrows_loads] pad_sequential_loads=[llength $txrows_seq] named_by_exceptions=[llength $txrows_named] unclaimed=[llength $txrows_un]([join $txrows_un {|}]) exception_rows_this_chain=[llength $txrows_exc_pair]([join $txrows_exc_pair { | }]) exception_rows_probe_chain=[llength $txrows_exc_probe] exception_rows_this_pad=[llength $txrows_exc_pad] data_paths_pad_to_D=[llength $txrows_dp] data_requirements=[join [lsort -unique $txrows_dreqs] |] paths_ending_at_first_stage_cell=[llength $txrows_cell] ending_at_D=$txrows_dcount control_paths=[join $txrows_ctrl {; }] later_stages=[join $txrows_down_rows {; }]"
    incr txrows_checked
}
if {$txrows_checked != 3} {
    error "SC7F0_TX_IO_ROWS_INCOMPLETE $txrows_checked of 3"
}
puts "SC7F0_TX_IO_ROWS_COMPLETE chains=$txrows_checked policy_rows_review_required=3 approves_nothing=1"
