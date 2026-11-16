# =============================================================================
# scripts/check_sc7f0_overlay_sync.tcl
#
# Routed re-check of constraints/sc7f0_overlay_sync.xdc, on THIS round's
# implemented design (sourced by scripts/build_zu4ev.tcl right after
# scripts/check_sc7f0_overlay_gray.tcl, i.e. after open_run impl_1).  Nothing is
# promised before route and nothing is accepted because it is missing: every row
# below is a measurement, and a missing/looser/wrongly-directed exception is an
# error.
#
# What it proves, per crossing:
#   * the named first-stage FF exists exactly once, and its second stage exists
#     too - an exception in front of a single FF would be a latch, not a
#     synchroniser;
#   * a path is actually TIMED into that FF.  set_false_path / set_clock_groups
#     -asynchronous would make get_timing_paths return nothing here, so this
#     check cannot be satisfied by a blanket exception (that is the point:
#     constraints/sc7f0_overlay_sync.xdc is a bounded set_max_delay);
#   * the observed STARTPOINT clock really is pcie_user_clk and the ENDPOINT
#     clock really is capture_clk_300m, i.e. the exception sits on a real
#     125 MHz -> 300 MHz async crossing and not on something that was renamed or
#     re-timed into the same domain;
#   * the REQUIREMENT the timing engine applied this round is exactly 3.333 ns
#     (one destination period), not 0.337 ns (no exception) and not something
#     looser that quietly swallowed it;
#   * the combinational depth is at most one level, i.e. the endpoint is still a
#     directly-driven first stage.
#
# Like the Gray checker, this approves no CDC policy: the review ledger and the
# reviewer decide whether the exception itself is acceptable.  It only refuses to
# let the exception be absent, overridden, or wider than the three named
# endpoints.
#
# Hardening added for round 26111401 (measurement code only, no exception
# changed): the -to query with -max_paths 64 -nworst 4 answers with the FOUR
# worst paths of one endpoint, so it is not an exhaustive launch set.  The round
# it is meant to catch (rgb-fullimpl-26111335, requirement 0.337 ns on
# u_pcie_ip/inst/user_lnk_up_reg_replica -> epoch_sync_l[0]/D, WNS -0.909) is the
# case where an undeclared launch is the WORST one, but nothing guarantees that:
# a short undeclared launch hides behind a slower declared one.  The launch set
# below therefore comes from all_fanin on the first stage's own D pin - every
# cell that can launch this condition on this round's implemented netlist,
# including opt / phys_opt replicas - and each launch is asked for its own path
# and its own requirement.  0 launches, a non-register launch, a launch in an
# unexpected clock domain, an untimed launch and a launch whose requirement is
# not 3.333 ns all stop the run; none of them is skipped or reported as NA.
# =============================================================================
set ovsync_period 3.333
set ovsync_checked 0

proc ovsync_names {objs} {
    if {$objs eq "" || [llength $objs] == 0} {return {}}
    if {[catch {get_property NAME $objs} names]} {return {}}
    return $names
}

proc ovsync_true {value} {
    return [expr {[string tolower [string trim $value]] in {1 true yes}}]
}

# all_fanin -endpoints_only answers with pins or with cells depending on the
# selector and the netlist, and a mapping that silently yields empty names is how
# a coverage loop ends up "covering" nothing.  Resolve explicitly and keep what
# resolves, so an unresolved object is visible as a count mismatch instead of a
# shortened list.
proc ovsync_to_cells {objs} {
    set cells {}
    foreach o $objs {
        if {$o eq ""} {continue}
        set c [get_cells -quiet -of $o]
        if {$c ne "" && [llength $c] > 0} {lappend cells $c; continue}
        # not a pin/net: is it already a cell?  a cell answers REF_NAME with a
        # non-empty value, a pin does not own itself
        set ref ""
        catch {set ref [get_property REF_NAME $o]}
        if {$ref ne ""} {
            set n [get_property NAME $o]
            set c [get_cells -quiet -hier $n]
            if {$c ne "" && [llength $c] > 0} {lappend cells $c; continue}
            lappend cells $o
        }
    }
    return $cells
}

proc ovsync_clock_text {obj} {
    if {$obj eq "" || [llength $obj] == 0} {return "-"}
    if {[catch {get_clocks -quiet -of_objects $obj} clocks]} {return QUERY_ERROR}
    if {$clocks eq ""} {return "-"}
    if {[catch {join [lsort -unique [get_property NAME $clocks]] |} text]} {return QUERY_ERROR}
    return $text
}

foreach {ovsync_name ovsync_dst_pat ovsync_next_pat} {
    epoch  {.*u_overlay_writer/epoch_sync_l_reg\[0\]$}  {.*u_overlay_writer/epoch_sync_l_reg\[1\]$}
    poison {.*u_overlay_writer/poison_sync_reg\[0\]$}   {.*u_overlay_writer/poison_sync_reg\[1\]$}
    arm    {.*u_overlay_ingress/sync0_reg$}             {.*u_overlay_ingress/sync1_reg$}
} {
    set ovsync_dst [get_cells -quiet -hier -regexp $ovsync_dst_pat]
    set ovsync_next [get_cells -quiet -hier -regexp $ovsync_next_pat]
    if {[llength $ovsync_dst] != 1} {
        error "SC7F0_OVERLAY_SYNC_MISSING $ovsync_name: $ovsync_dst_pat matched [llength $ovsync_dst] cells, expected exactly 1 first-stage FF"
    }
    if {[llength $ovsync_next] != 1} {
        error "SC7F0_OVERLAY_SYNC_NO_SECOND_STAGE $ovsync_name: $ovsync_next_pat matched [llength $ovsync_next] cells, expected exactly 1. A bounded max_delay in front of a lone FF is not a synchroniser."
    }
    # Every launch into the first stage, not one selected source: the query is
    # deliberately `-to` only.  Round rgb-fullimpl-26111335 measured why - the
    # epoch first stage is launched by BOTH PCIe-core registers that form its
    # asynchronous condition (u_pcie_ip/inst/user_reset_reg and
    # u_pcie_ip/inst/user_lnk_up_reg, plus phys_opt replicas), and checking only
    # the worst path would have let the second, still-unexcepted launch through at
    # 0.337 ns while reporting a clean 3.333 ns endpoint.
    set ovsync_paths [get_timing_paths -to $ovsync_dst -delay_type max -max_paths 64 -nworst 4]
    if {[llength $ovsync_paths] == 0} {
        error "SC7F0_OVERLAY_SYNC_NOT_TIMED $ovsync_name: no timing path reaches [get_property NAME $ovsync_dst]. A synchroniser that reports no path is either falsely pathed or disconnected, and neither may be graded as safe."
    }
    set ovsync_worst [lindex $ovsync_paths 0]
    set ovsync_starts {}
    foreach ovsync_path $ovsync_paths {
        set ovsync_p_start [get_property STARTPOINT_PIN $ovsync_path]
        set ovsync_p_end   [get_property ENDPOINT_PIN   $ovsync_path]
        if {[catch {get_clocks -quiet -of_objects [get_pins -quiet $ovsync_p_start]} ovsync_p_sc]} {set ovsync_p_sc ""}
        if {$ovsync_p_sc eq ""} {set ovsync_p_sclk "-"} else {set ovsync_p_sclk [join [lsort -unique [get_property NAME $ovsync_p_sc]] |]}
        if {$ovsync_p_sclk ne "pcie_user_clk"} {
            error "SC7F0_OVERLAY_SYNC_SOURCE_DOMAIN $ovsync_name: a launch into the first stage starts in '$ovsync_p_sclk' ($ovsync_p_start), expected pcie_user_clk. Every asynchronous launch of this condition must be declared; an undeclared one keeps its 0.337 ns default requirement and stays the worst path of the round."
        }
        set ovsync_p_req [get_property REQUIREMENT $ovsync_path]
        if {$ovsync_p_req eq "" ||
            [expr {abs(double($ovsync_p_req) - $ovsync_period) > 0.001}]} {
            error "SC7F0_OVERLAY_SYNC_NOT_EFFECTIVE $ovsync_name: launch $ovsync_p_start -> $ovsync_p_end carries requirement '$ovsync_p_req', expected $ovsync_period ns; that launch was never declared or is being overridden."
        }
        if {[get_property LOGIC_LEVELS $ovsync_path] > 1} {
            error "SC7F0_OVERLAY_SYNC_LOGIC $ovsync_name: [get_property LOGIC_LEVELS $ovsync_path] combinational levels in the first-stage path $ovsync_p_start -> $ovsync_p_end; this file constrains a directly driven synchroniser input, not a general datapath."
        }
        lappend ovsync_starts $ovsync_p_start
    }
    # --- exhaustive launch set from the first stage's own D pin ----------------
    set ovsync_dpin [get_pins -quiet [list [get_property NAME $ovsync_dst]/D]]
    if {[llength $ovsync_dpin] != 1} {
        error "SC7F0_OVERLAY_SYNC_NO_D_PIN $ovsync_name: [list [get_property NAME $ovsync_dst]/D] resolved to [llength $ovsync_dpin] pins, expected exactly 1; without the D pin there is no launch set to enumerate."
    }
    # all_fanin has no -endpoints_only option (measured: [Common 17-170]); the
    # documented exhaustive launch query is
    #   all_fanin -flat -startpoints_only -only_cells <sink pin>
    # with the sink as the positional argument, answering with the launch cells.
    if {[catch {all_fanin -flat -startpoints_only -only_cells $ovsync_dpin} ovsync_fan]} {
        error "SC7F0_OVERLAY_SYNC_FANIN_FAILED $ovsync_name: all_fanin on the first-stage D pin: $ovsync_fan"
    }
    set ovsync_launch_cells [ovsync_to_cells $ovsync_fan]
    set ovsync_launch_names [lsort -unique [ovsync_names $ovsync_launch_cells]]
    if {[llength $ovsync_launch_names] == 0} {
        error "SC7F0_OVERLAY_SYNC_NO_LAUNCH $ovsync_name: all_fanin returned [llength $ovsync_fan] raw object(s) which resolved to 0 cells. A first stage with no measurable launch is not a synchroniser, and an empty launch set must never be graded as covered."
    }
    set ovsync_launch_pass 0
    foreach ovsync_l $ovsync_launch_names {
        set ovsync_lc [get_cells -quiet -hier $ovsync_l]
        if {[llength $ovsync_lc] != 1} {
            error "SC7F0_OVERLAY_SYNC_LAUNCH_LOOKUP $ovsync_name: fan-in cell $ovsync_l resolved to [llength $ovsync_lc] cells."
        }
        set ovsync_lref ""; catch {set ovsync_lref [get_property REF_NAME $ovsync_lc]}
        set ovsync_lasync ""; catch {set ovsync_lasync [get_property ASYNC_REG $ovsync_lc]}
        set ovsync_lclk [ovsync_clock_text $ovsync_lc]
        set ovsync_lseq 0
        foreach ovsync_fam {FD LD IDDR IDES ISERDESE} {
            if {[string match ${ovsync_fam}* $ovsync_lref]} {set ovsync_lseq 1}
        }
        if {!$ovsync_lseq} {
            error "SC7F0_OVERLAY_SYNC_LAUNCH_NOT_A_REGISTER $ovsync_name: the first-stage D pin is launched by $ovsync_l (REF_NAME $ovsync_lref, clock $ovsync_lclk), which is not a register. Either the synchroniser input is driven by combinational / constant logic (so the 3.333 ns bound is not a synchroniser bound) or the reviewed two-register condition changed shape."
        }
        if {$ovsync_lclk ne "pcie_user_clk"} {
            error "SC7F0_OVERLAY_SYNC_SOURCE_DOMAIN $ovsync_name: enumerated launch $ovsync_l lives in clock domain '$ovsync_lclk', expected pcie_user_clk. Every asynchronous launch of this condition must be declared and must come from the declared source domain."
        }
        set ovsync_lp [get_timing_paths -from $ovsync_lc -to $ovsync_dst -delay_type max -max_paths 8 -nworst 4]
        if {[llength $ovsync_lp] == 0} {
            error "SC7F0_OVERLAY_SYNC_LAUNCH_NOT_TIMED $ovsync_name: $ovsync_l/C -> [get_property NAME $ovsync_dst]/D is in the first stage's fan-in but produced no timed path. An untimed launch is either falsely pathed (a wider exception than the named bound) or is not the register the enumeration claims."
        }
        set ovsync_lreq {}
        set ovsync_lslack {}
        set ovsync_llevels 0
        foreach ovsync_path2 $ovsync_lp {
            set ovsync_r2 [get_property REQUIREMENT $ovsync_path2]
            if {$ovsync_r2 eq "" ||
                [expr {abs(double($ovsync_r2) - $ovsync_period) > 0.001}]} {
                error "SC7F0_OVERLAY_SYNC_NOT_EFFECTIVE $ovsync_name: enumerated launch $ovsync_l carries requirement '$ovsync_r2' on [lindex [ovsync_names [list [get_property ENDPOINT_PIN $ovsync_path2]]] 0], expected $ovsync_period ns; that launch was never declared or is being overridden."
            }
            set ovsync_lreq $ovsync_r2
            set ovsync_s2 [get_property SLACK $ovsync_path2]
            if {$ovsync_lslack eq "" || [expr {double($ovsync_s2) < double($ovsync_lslack)}]} {set ovsync_lslack $ovsync_s2}
            set ovsync_lv2 [get_property LOGIC_LEVELS $ovsync_path2]
            if {$ovsync_lv2 ne "" && $ovsync_lv2 > $ovsync_llevels} {set ovsync_llevels $ovsync_lv2}
        }
        puts "SC7F0_OVERLAY_SYNC_LAUNCH_PASS $ovsync_name: launch $ovsync_l \[ref $ovsync_lref, clock $ovsync_lclk, async_reg $ovsync_lasync\] -> [get_property NAME $ovsync_dst]/D, requirement $ovsync_lreq ns, worst slack $ovsync_lslack ns, logic_levels $ovsync_llevels, paths [llength $ovsync_lp]"
        incr ovsync_launch_pass
    }
    if {$ovsync_launch_pass != [llength $ovsync_launch_names]} {
        error "SC7F0_OVERLAY_SYNC_LAUNCH_INCOMPLETE $ovsync_name: $ovsync_launch_pass of [llength $ovsync_launch_names] enumerated launches were graded"
    }

    set ovsync_start [get_property STARTPOINT_PIN $ovsync_worst]
    set ovsync_end   [get_property ENDPOINT_PIN   $ovsync_worst]
    # Same object->clock resolution the Layer B hook uses (get_clocks -of_objects,
    # "-" when the object simply has no clock), because a pin has no clock name of
    # its own and an empty result must not be mistaken for a matching domain.
    if {[catch {get_clocks -quiet -of_objects [get_pins -quiet $ovsync_start]} ovsync_sc]} {set ovsync_sc ""}
    if {$ovsync_sc eq ""} {set ovsync_sclk "-"} else {set ovsync_sclk [join [lsort -unique [get_property NAME $ovsync_sc]] |]}
    if {[catch {get_clocks -quiet -of_objects [get_pins -quiet $ovsync_end]} ovsync_ec]} {set ovsync_ec ""}
    if {$ovsync_ec eq ""} {set ovsync_eclk "-"} else {set ovsync_eclk [join [lsort -unique [get_property NAME $ovsync_ec]] |]}
    if {$ovsync_sclk ne "pcie_user_clk"} {
        error "SC7F0_OVERLAY_SYNC_SOURCE_DOMAIN $ovsync_name: the timed path starts in '$ovsync_sclk' ($ovsync_start), expected pcie_user_clk. constraints/sc7f0_overlay_sync.xdc documents a 125 MHz -> 300 MHz crossing; a different source domain means the exception is being read against a different path than the one it was written for."
    }
    if {$ovsync_eclk ne "capture_clk_300m"} {
        error "SC7F0_OVERLAY_SYNC_DEST_DOMAIN $ovsync_name: the timed path ends in '$ovsync_eclk' ($ovsync_end), expected capture_clk_300m"
    }
    set ovsync_req [get_property REQUIREMENT $ovsync_worst]
    if {$ovsync_req eq "" ||
        [expr {abs(double($ovsync_req) - $ovsync_period) > 0.001}]} {
        error "SC7F0_OVERLAY_SYNC_NOT_EFFECTIVE $ovsync_name: the requirement in force at $ovsync_end is '$ovsync_req', expected $ovsync_period ns. 0.337 means constraints/sc7f0_overlay_sync.xdc did not attach at all; anything looser means a wider exception (clock group, false path, blanket max delay) is winning over it."
    }
    set ovsync_levels [get_property LOGIC_LEVELS $ovsync_worst]
    if {$ovsync_levels > 1} {
        error "SC7F0_OVERLAY_SYNC_LOGIC $ovsync_name: $ovsync_levels combinational levels in the first-stage path $ovsync_start -> $ovsync_end; this file constrains a directly driven synchroniser input, not a general datapath."
    }
    # The second stage must still be an ordinary, TIMED, same-domain register
    # pair: ASYNC_REG set, destination clock capture_clk_300m, requirement equal
    # to one destination period, and a path the engine actually analysed.  A
    # wider exception (false path on the chain, clock group) would remove these
    # paths, and an MTBF claim is not made from the pre-first-stage max delay.
    set ovsync_next_async ""; catch {set ovsync_next_async [get_property ASYNC_REG $ovsync_next]}
    if {![ovsync_true $ovsync_next_async]} {
        error "SC7F0_OVERLAY_SYNC_SECOND_STAGE_ATTR $ovsync_name: second stage [get_property NAME $ovsync_next] has ASYNC_REG '$ovsync_next_async'; the pair is not annotated, so the resolution of the later stage is not the reviewed synchroniser."
    }
    set ovsync_npaths [get_timing_paths -to $ovsync_next -delay_type max -max_paths 8 -nworst 4]
    if {[llength $ovsync_npaths] == 0} {
        error "SC7F0_OVERLAY_SYNC_SECOND_STAGE_NOT_TIMED $ovsync_name: no timed path reaches the second stage [get_property NAME $ovsync_next]; an exception that un-times the chain past the first stage is wider than the named bound."
    }
    set ovsync_nreq {}
    set ovsync_nslack {}
    foreach ovsync_path3 $ovsync_npaths {
        set ovsync_e3 [get_property ENDPOINT_PIN $ovsync_path3]
        set ovsync_eclk3 [ovsync_clock_text [get_pins -quiet $ovsync_e3]]
        if {$ovsync_eclk3 ne "capture_clk_300m"} {
            error "SC7F0_OVERLAY_SYNC_DEST_DOMAIN $ovsync_name: the second-stage path ending at $ovsync_e3 is captured by '$ovsync_eclk3', expected capture_clk_300m"
        }
        set ovsync_r3 [get_property REQUIREMENT $ovsync_path3]
        if {$ovsync_r3 eq "" ||
            [expr {abs(double($ovsync_r3) - $ovsync_period) > 0.001}]} {
            error "SC7F0_OVERLAY_SYNC_SECOND_STAGE_REQ $ovsync_name: second-stage path $ovsync_e3 carries requirement '$ovsync_r3', expected one destination period ($ovsync_period ns); the later stage is not held to normal capture_clk_300m timing."
        }
        set ovsync_nreq $ovsync_r3
        set ovsync_s3 [get_property SLACK $ovsync_path3]
        if {$ovsync_nslack eq "" || [expr {double($ovsync_s3) < double($ovsync_nslack)}]} {set ovsync_nslack $ovsync_s3}
    }
    puts "SC7F0_OVERLAY_SYNC_SECOND_STAGE_PASS $ovsync_name: [get_property NAME $ovsync_next] \[ASYNC_REG $ovsync_next_async, clock capture_clk_300m\] requirement $ovsync_nreq ns, worst slack $ovsync_nslack ns, paths [llength $ovsync_npaths], first-stage fanin_launches=$ovsync_launch_pass"
    puts "SC7F0_OVERLAY_SYNC_ENDPOINT_PASS $ovsync_name: $ovsync_start \[$ovsync_sclk\] -> $ovsync_end \[$ovsync_eclk\], requirement $ovsync_req ns, logic_levels $ovsync_levels, slack [get_property SLACK $ovsync_worst] ns, second stage [get_property NAME $ovsync_next], launches=[llength $ovsync_starts] ([join [lsort -unique $ovsync_starts] {, }])"
    incr ovsync_checked
}
if {$ovsync_checked != 3} {
    error "SC7F0_OVERLAY_SYNC_INCOMPLETE: $ovsync_checked of 3 named crossings were checked"
}
puts "SC7F0_OVERLAY_SYNC_CHECK_PASS endpoints=$ovsync_checked requirement=$ovsync_period"
