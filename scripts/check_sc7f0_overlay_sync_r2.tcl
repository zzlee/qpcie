# =============================================================================
# scripts/check_sc7f0_overlay_sync_r2.tcl
#
# Routed re-check of the three overlay 125 MHz -> 300 MHz synchroniser
# exceptions, precision revision of scripts/check_sc7f0_overlay_sync.tcl.  It is
# a MEASUREMENT-CODE revision only: nothing here applies, widens or removes a
# constraint, and it changes no hardware.  Round 26111401 (candidate F) is the
# evidence for why the revision is needed, and F itself consumed the earlier
# revision, so this file does not replace it in place.
#
# What the earlier revision gets wrong, measured in this round's own log:
#
#   * `get_timing_paths -to <cell>` does NOT answer with "the paths into the
#     synchroniser's D pin".  It answers with every path that ends at that cell,
#     which includes the recovery / removal paths of its asynchronous set and
#     reset pins.  Round 26111401's pre-opt readback printed exactly that:
#       SC7F0_OVERLAY_SYNC_APPLIED epoch: requirement 3.333 ns on all 6 launches
#         into u_dma_top/u_overlay_writer/epoch_sync_l_reg[0]/D from
#         u_pcie_ip/inst/user_lnk_up_reg/C, u_pcie_ip/inst/user_reset_reg/C,
#         u_dp_mem_reset/u_final/arststages_ff_reg[3]/C
#     the third startpoint is a 300 MHz reset-synchroniser leg arriving at the
#     FF's clear pin, whose 3.333 ns requirement is its own same-domain recovery
#     requirement.  The old revision's rule "every returned startpoint must be
#     pcie_user_clk" would therefore fail closed on a legitimate path - and a
#     check that fails on valid hardware is as useless as one that passes on
#     broken hardware.
#
# This revision separates the two classes and reports BOTH:
#
#   class 1  data launches.  Enumerated from the D pin's own fan-in
#            (all_fanin -flat -startpoints_only -only_cells <cell>/D), which is
#            the exhaustive launch set including opt / phys_opt replicas.  Each
#            launch must be a register in pcie_user_clk, must produce a timed
#            path whose ENDPOINT_PIN is the D pin, and must carry requirement
#            3.333 ns.  A missing launch, a non-register launch, a foreign clock
#            domain, an untimed launch or a wrong requirement stops the run.
#            This is what catches an undeclared second data launch such as
#            round 26111335's user_lnk_up_reg_replica (requirement 0.337, WNS
#            -0.909).
#   class 2  control / reset paths that also end at this cell (R, SR, PRE, S,
#            and any other pin).  They are reported by name with their real
#            clock and requirement and must remain TIMED (an exception that
#            swallowed them would be wider than the named bound).  They are
#            never called data launches and never graded against pcie_user_clk.
#
# Nothing is approved here: scripts/gates/*.json is untouched and every row is
# review_required material for the reviewer.
# =============================================================================
set ovs2_period 3.333
set ovs2_checked 0
set ovs2_areg_rows {}
set ovs2_areg_gaps 0
set ovs2_areg_annotated 0

proc ovs2_names {objs} {
    if {$objs eq "" || [llength $objs] == 0} {return {}}
    if {[catch {get_property NAME $objs} names]} {return {}}
    return $names
}

proc ovs2_true {value} {
    return [expr {[string tolower [string trim $value]] in {1 true yes}}]
}

# Property read that distinguishes "the tool answered and the value is empty"
# (a property that is simply not set - a legitimate measurement) from "the query
# itself failed".  Conflating the two is what made round 26111401 report the DDC
# vendor filter's ASYNC_REG as QUERY_ERROR when the answer is "not set".
proc ovs2_prop {prop obj} {
    if {$obj eq "" || [llength $obj] == 0} {return {EMPTY_OBJECT_LIST}}
    if {[catch {get_property $prop $obj} value]} {return "QUERY_ERROR: $value"}
    if {$value eq ""} {return "unset(false)"}
    return $value
}

# Same three-way split as ovs2_prop, but normalised for ASSERTION: a real tool
# answer of 1, TRUE, true, yes or on is "true" (a string-equal-to-"true" test
# would reject the numeric 1 that the tool actually prints), an empty or 0/FALSE
# answer is "false", and anything else - including a failed query or an empty
# object list - is "bad" and is never read as either.
proc ovs2_bool {prop obj} {
    if {$obj eq "" || [llength $obj] == 0} {
        return [list state bad value EMPTY_OBJECT_LIST]
    }
    if {[catch {get_property $prop $obj} value]} {
        return [list state bad value "QUERY_ERROR($value)"]
    }
    set t [string tolower [string trim $value]]
    if {$t eq ""}              {return [list state false value {unset(false)}]}
    if {$t in {1 true yes on}}  {return [list state true value $value]}
    if {$t in {0 false no off}} {return [list state false value $value]}
    return [list state bad value $value]
}

# Assert one stage's ASYNC_REG and return the raw token that was read, so the
# PASS line quotes the tool rather than the verdict.  An unqueryable answer and a
# genuinely-false answer are different failures and say different things, so they
# get different messages; neither is allowed to look like a pass.
proc ovs2_assert_areg {id stage obj} {
    array set rec [ovs2_bool ASYNC_REG $obj]
    if {$rec(state) eq "bad"} {
        error "SC7F0_OVERLAY_SYNC_R2_ASYNC_REG_UNQUERYABLE $id: the $stage-stage cell answered '$rec(value)' for ASYNC_REG, which is neither a true nor a false answer; the property could not be measured."
    }
    if {$rec(state) ne "true"} {
        error "SC7F0_OVERLAY_SYNC_R2_ASYNC_REG_MISSING $id: the $stage-stage cell has ASYNC_REG=$rec(value). Round H applies this attribute in scripts/apply_sc7f0_overlay_cdc.tcl, so an unannotated $id stage on the routed netlist means the pre-opt annotation did not happen or was optimised away."
    }
    return $rec(value)
}

proc ovs2_clock_text {obj} {
    if {$obj eq "" || [llength $obj] == 0} {return {OBJECT_LOOKUP_FAILED}}
    if {[catch {get_clocks -quiet -of_objects $obj} clocks]} {return QUERY_ERROR}
    if {$clocks eq ""} {return {-}}
    if {[catch {join [lsort -unique [get_property NAME $clocks]] |} text]} {return QUERY_ERROR}
    return $text
}

# A timing path reports its startpoint / endpoint by NAME.  Turning that name back
# into an object can legitimately fail (linked or encrypted IP internals print a
# name they will not resolve), and a failed lookup is NOT "no clock": it is
# reported as such so a row is never read as clean because a query came back empty.
proc ovs2_pin_clock {pinname} {
    if {$pinname eq ""} {return {NO_PIN_NAME}}
    set p ""
    if {[catch {get_pins -quiet $pinname} p]} {return "PIN_QUERY_ERROR"}
    if {$p eq "" || [llength $p] == 0} {return "PIN_LOOKUP_FAILED"}
    return [ovs2_clock_text $p]
}

# Launch resolution that keeps the OBJECT, not just its name.
#
# Round 26111401's first r2 revision converted fan-in objects to names and then
# looked the names up again with `get_cells -hier <name>`, which failed on
# u_pcie_ip/inst/user_lnk_up_reg (`LAUNCH_LOOKUP ... resolved to 0 cells`) even
# though the object and its name came from the tool one statement earlier: name
# lookup over a linked/encrypted IP boundary is not the inverse of name printing.
# A failed lookup that is read as "no launch" is a fail-open, so an object that
# resolves neither to a cell nor to something with a REF_NAME is an error here,
# exactly as in scripts/apply_sc7f0_overlay_cdc.tcl's sc7f0_ov_launch_names, which
# this mirrors.  The object list is what subsequent timing queries use.
proc ovs2_launch_objs {fan id} {
    set objs {}
    set seen {}
    foreach o $fan {
        if {$o eq ""} {continue}
        set c ""
        if {[catch {get_cells -quiet -of $o} c]} {set c ""}
        if {$c eq "" || [llength $c] == 0} {
            set ref ""
            catch {set ref [get_property REF_NAME $o]}
            if {$ref eq ""} {
                error "SC7F0_OVERLAY_SYNC_R2_FANIN_UNRESOLVED $id: fan-in object $o is neither a pin/net with an owning cell nor a cell (REF_NAME empty). The launch set cannot be enumerated and a partial list must not be read as a complete one."
            }
            set c [list $o]
        }
        foreach cc $c {
            set n [get_property NAME $cc]
            if {[lsearch -exact $seen $n] >= 0} {continue}
            lappend seen $n
            lappend objs $cc
        }
    }
    return $objs
}

proc ovs2_sequential {ref} {
    foreach fam {FD LD IDDR IDES ISERDESE} {
        if {[string match ${fam}* $ref]} {return 1}
    }
    return 0
}

foreach {ovs2_name ovs2_dst_pat ovs2_next_pat} {
    epoch  {.*u_overlay_writer/epoch_sync_l_reg\[0\]$}  {.*u_overlay_writer/epoch_sync_l_reg\[1\]$}
    poison {.*u_overlay_writer/poison_sync_reg\[0\]$}   {.*u_overlay_writer/poison_sync_reg\[1\]$}
    arm    {.*u_overlay_ingress/sync0_reg$}             {.*u_overlay_ingress/sync1_reg$}
} {
    set ovs2_dst [get_cells -quiet -hier -regexp $ovs2_dst_pat]
    set ovs2_next [get_cells -quiet -hier -regexp $ovs2_next_pat]
    if {[llength $ovs2_dst] != 1} {
        error "SC7F0_OVERLAY_SYNC_R2_MISSING $ovs2_name: $ovs2_dst_pat matched [llength $ovs2_dst] cells, expected exactly 1 first-stage FF"
    }
    if {[llength $ovs2_next] != 1} {
        error "SC7F0_OVERLAY_SYNC_R2_NO_SECOND_STAGE $ovs2_name: $ovs2_next_pat matched [llength $ovs2_next] cells, expected exactly 1"
    }
    set ovs2_dn [get_property NAME $ovs2_dst]
    # the D pin is taken from the CELL OBJECT, not by re-reading its printed name
    if {[catch {get_pins -quiet -of $ovs2_dst -filter {NAME =~ */D}} ovs2_dpin]} {set ovs2_dpin ""}
    if {[llength $ovs2_dpin] != 1} {
        error "SC7F0_OVERLAY_SYNC_R2_NO_D_PIN $ovs2_name: ${ovs2_dn}/D resolved to [llength $ovs2_dpin] pins (queried from the cell object)"
    }

    # ---- class 1: the D pin's own exhaustive launch set ----------------------
    if {[catch {all_fanin -flat -startpoints_only -only_cells $ovs2_dpin} ovs2_fan]} {
        error "SC7F0_OVERLAY_SYNC_R2_FANIN_FAILED $ovs2_name: $ovs2_fan"
    }
    set ovs2_launch_objs [ovs2_launch_objs $ovs2_fan $ovs2_name]
    set ovs2_launches {}
    foreach ovs2_o $ovs2_launch_objs { lappend ovs2_launches [get_property NAME $ovs2_o] }
    if {[llength $ovs2_launches] == 0} {
        error "SC7F0_OVERLAY_SYNC_R2_NO_LAUNCH $ovs2_name: [llength $ovs2_fan] raw fan-in object(s) resolved to 0 launch cells. An empty launch set is not a covered first stage."
    }
    set ovs2_pass 0
    set ovs2_launch_rows {}
    foreach ovs2_lc $ovs2_launch_objs {
        set ovs2_l [get_property NAME $ovs2_lc]
        set ovs2_ref [ovs2_prop REF_NAME $ovs2_lc]
        set ovs2_clk [ovs2_clock_text $ovs2_lc]
        set ovs2_areg [ovs2_prop ASYNC_REG $ovs2_lc]
        if {![ovs2_sequential $ovs2_ref]} {
            error "SC7F0_OVERLAY_SYNC_R2_LAUNCH_NOT_A_REGISTER $ovs2_name: $ovs2_l (REF_NAME $ovs2_ref, clock $ovs2_clk) drives the first stage's D pin but is not a register."
        }
        if {$ovs2_clk ne "pcie_user_clk"} {
            error "SC7F0_OVERLAY_SYNC_R2_SOURCE_DOMAIN $ovs2_name: data launch $ovs2_l is in clock domain '$ovs2_clk', expected pcie_user_clk"
        }
        set ovs2_paths [get_timing_paths -from $ovs2_lc -to $ovs2_dpin -delay_type max -max_paths 8 -nworst 4]
        if {[llength $ovs2_paths] == 0} {
            error "SC7F0_OVERLAY_SYNC_R2_LAUNCH_NOT_TIMED $ovs2_name: $ovs2_l -> ${ovs2_dn}/D is in the D-pin fan-in but has no timed max path."
        }
        set ovs2_req {}
        set ovs2_slack {}
        set ovs2_levels 0
        foreach ovs2_p $ovs2_paths {
            set ovs2_ep [get_property ENDPOINT_PIN $ovs2_p]
            if {$ovs2_ep ne "${ovs2_dn}/D"} {
                error "SC7F0_OVERLAY_SYNC_R2_ENDPOINT_MISMATCH $ovs2_name: the path from $ovs2_l ends at $ovs2_ep, not at ${ovs2_dn}/D"
            }
            set ovs2_r [get_property REQUIREMENT $ovs2_p]
            if {$ovs2_r eq "" || [expr {abs(double($ovs2_r) - $ovs2_period) > 0.001}]} {
                error "SC7F0_OVERLAY_SYNC_R2_NOT_EFFECTIVE $ovs2_name: launch $ovs2_l -> $ovs2_ep carries requirement '$ovs2_r', expected $ovs2_period ns; that launch was never declared or is overridden."
            }
            set ovs2_req $ovs2_r
            set ovs2_s [get_property SLACK $ovs2_p]
            if {$ovs2_slack eq "" || [expr {double($ovs2_s) < double($ovs2_slack)}]} {set ovs2_slack $ovs2_s}
            set ovs2_lv [get_property LOGIC_LEVELS $ovs2_p]
            if {$ovs2_lv ne "" && $ovs2_lv > $ovs2_levels} {set ovs2_levels $ovs2_lv}
        }
        lappend ovs2_launch_rows "$ovs2_l\[ref=$ovs2_ref clk=$ovs2_clk async_reg=$ovs2_areg req=$ovs2_req slack=$ovs2_slack levels=$ovs2_levels\]"
        incr ovs2_pass
    }
    if {$ovs2_pass != [llength $ovs2_launches]} {
        error "SC7F0_OVERLAY_SYNC_R2_LAUNCH_INCOMPLETE $ovs2_name"
    }

    # ---- class 2: control / reset paths that also end at this cell ----------
    # Reported in full, never folded into class 1.  They are not graded against
    # pcie_user_clk: a recovery / removal path to an asynchronous set or reset pin
    # belongs to whatever domain resets this flop, and round 26111401 showed the
    # earlier revision calling such a path a missing PCIe-domain data launch. An
    # async reset deassertion that is intentionally not timed is a design property
    # for the reviewer to see, so it is listed with its real requirement (or its
    # absence) instead of either failing the run or being dropped.
    set ovs2_ctrl {}
    set ovs2_ctrl_untimed 0
    set ovs2_all [get_timing_paths -to $ovs2_dst -delay_type max -max_paths 64 -nworst 4]
    foreach ovs2_p $ovs2_all {
        set ovs2_ep [get_property ENDPOINT_PIN $ovs2_p]
        if {$ovs2_ep eq "${ovs2_dn}/D"} {continue}
        set ovs2_sp [get_property STARTPOINT_PIN $ovs2_p]
        set ovs2_sclk [ovs2_pin_clock $ovs2_sp]
        set ovs2_eclk [ovs2_pin_clock $ovs2_ep]
        set ovs2_r [get_property REQUIREMENT $ovs2_p]
        if {$ovs2_r eq ""} {
            lappend ovs2_ctrl "$ovs2_sp\[$ovs2_sclk\] -> $ovs2_ep\[$ovs2_eclk\] req=none(untimed)"
            incr ovs2_ctrl_untimed
            continue
        }
        lappend ovs2_ctrl "$ovs2_sp\[$ovs2_sclk\] -> $ovs2_ep\[$ovs2_eclk\] req=$ovs2_r slack=[get_property SLACK $ovs2_p]"
    }
    set ovs2_dst_areg [ovs2_prop ASYNC_REG $ovs2_dst]
    # ---- second stage: measured, and ASYNC_REG is now ASSERTED --------------
    # The timing assertions below stay fail-closed.  The annotation attribute used
    # to be REPORTED only, because two of these three chains genuinely did not
    # carry it: round G's own routed report_cdc answered
    #   proj_full26111402/cdc.rpt:19  CDC-2 "1-bit synchronized with missing
    #   ASYNC_REG" = 2  (arm_toggle_reg -> sync0_reg, and
    #                     debt_poison_epoch_reg -> poison_sync_reg[0])
    # scripts/apply_sc7f0_overlay_cdc.tcl now writes ASYNC_REG on exactly those
    # four flops (poison_sync_reg[0], poison_sync_reg[1], sync0_reg, sync1_reg)
    # under its own pre-opt guards and read-back, so this re-check asserts the
    # value on the netlist that actually got routed instead of deferring it.
    # epoch_sync_l is annotated in RTL (rtl/sc7f0_overlay_writer.v:1197) and is
    # asserted here too: 3 chains x 2 stages = 6 assertions over the 5 annotated
    # flops, and the launch flop (arm_toggle_reg) is deliberately NOT among them.
    set ovs2_dst_areg [ovs2_assert_areg $ovs2_name first $ovs2_dst]
    set ovs2_next_areg [ovs2_assert_areg $ovs2_name second $ovs2_next]
    incr ovs2_areg_annotated
    # Same separation as class 1 / class 2 above: the assertions are made on the
    # second stage's D pin.  `get_timing_paths -to <cell>` also answers with the
    # recovery / removal arcs of its asynchronous preset and clear pins, and an
    # endpoint pin such as PRE carries no clock at all; round 26111401 measured
    # exactly that (logs/audit_r2.log: "second-stage path ending at
    # .../epoch_sync_l_reg[1]/PRE is captured by '-'").  Those arcs are reported
    # below, never graded as data capture.
    set ovs2_next_dn [get_property NAME $ovs2_next]
    # The capture domain of a flop is read from the CELL (a clock reaches a register
    # through its clock pin), not from the data pin: `get_clocks -of_objects` on a D
    # pin answers with nothing, which round 26111401 measured as
    # "second-stage data path ending at .../epoch_sync_l_reg[1]/D is captured by '-'".
    set ovs2_next_clk [ovs2_clock_text $ovs2_next]
    if {$ovs2_next_clk ne "capture_clk_300m"} {
        error "SC7F0_OVERLAY_SYNC_R2_SECOND_STAGE_DOMAIN $ovs2_name: second-stage cell $ovs2_next_dn is clocked by '$ovs2_next_clk', expected capture_clk_300m"
    }
    set ovs2_ndpin ""
    if {[catch {get_pins -quiet -of $ovs2_next -filter {NAME =~ */D}} ovs2_ndpin]} {set ovs2_ndpin ""}
    if {[llength $ovs2_ndpin] != 1} {
        error "SC7F0_OVERLAY_SYNC_R2_NO_SECOND_STAGE_D_PIN $ovs2_name: D pin of $ovs2_next_dn resolved to [llength $ovs2_ndpin] pins from the cell object"
    }
    set ovs2_npaths [get_timing_paths -to $ovs2_ndpin -delay_type max -max_paths 16 -nworst 4]
    if {[llength $ovs2_npaths] == 0} {
        error "SC7F0_OVERLAY_SYNC_R2_SECOND_STAGE_NOT_TIMED $ovs2_name: no timed max path reaches $ovs2_next_dn/D"
    }
    set ovs2_nslack {}
    foreach ovs2_p $ovs2_npaths {
        set ovs2_ep [get_property ENDPOINT_PIN $ovs2_p]
        set ovs2_eclk $ovs2_next_clk
        set ovs2_r [get_property REQUIREMENT $ovs2_p]
        if {$ovs2_eclk ne "capture_clk_300m"} {
            error "SC7F0_OVERLAY_SYNC_R2_DEST_DOMAIN $ovs2_name: second-stage data path ending at $ovs2_ep is captured by '$ovs2_eclk', expected capture_clk_300m"
        }
        set ovs2_dest_period [get_property PERIOD [get_clocks capture_clk_300m]]
        if {$ovs2_r eq "" || [expr {abs(double($ovs2_r) - double($ovs2_dest_period)) > 0.002}]} {
            error "SC7F0_OVERLAY_SYNC_R2_SECOND_STAGE_REQ $ovs2_name: $ovs2_ep carries requirement '$ovs2_r', expected one destination period ($ovs2_dest_period ns)"
        }
        set ovs2_s [get_property SLACK $ovs2_p]
        if {$ovs2_nslack eq "" || [expr {double($ovs2_s) < double($ovs2_nslack)}]} {set ovs2_nslack $ovs2_s}
    }
    set ovs2_nctrl {}
    foreach ovs2_p [get_timing_paths -to $ovs2_next -delay_type max -max_paths 64 -nworst 4] {
        set ovs2_ep [get_property ENDPOINT_PIN $ovs2_p]
        if {$ovs2_ep eq "$ovs2_next_dn/D"} {continue}
        set ovs2_sp [get_property STARTPOINT_PIN $ovs2_p]
        set ovs2_r [get_property REQUIREMENT $ovs2_p]
        if {$ovs2_r eq ""} {set ovs2_r "none(untimed)"}
        set ovs2_nsc [ovs2_pin_clock $ovs2_sp]
        set ovs2_nec [ovs2_pin_clock $ovs2_ep]
        # The brackets around the clock names are literal text.  Written as
        # "$ovs2_sp[[ovs2_pin_clock $ovs2_sp]]" Tcl reads `$var[...]` as an ARRAY
        # element and executes the index as a script, which is how this file
        # aborted with `invalid command name "capture_clk_300m"` (measured in this
        # round's pre-flight, logs/preflight3.log:368-384).  Values are resolved
        # into variables first, exactly as the first-stage control rows above do.
        lappend ovs2_nctrl "$ovs2_sp\[$ovs2_nsc\] -> $ovs2_ep\[$ovs2_nec\] req=$ovs2_r"
    }
    puts "SC7F0_OVERLAY_SYNC_R2_PASS $ovs2_name: data_launches=$ovs2_pass D_pin=${ovs2_dn}/D data_requirement=$ovs2_req ns worst_data_slack=$ovs2_slack ns levels=$ovs2_levels launches=\([join $ovs2_launch_rows {; }]\]) second_stage=${ovs2_next_dn}/D\[capture_clk_300m, worst_slack $ovs2_nslack ns\] async_reg_first_stage=$ovs2_dst_areg async_reg_second_stage=$ovs2_next_areg control_path_endpoints=[llength $ovs2_ctrl] untimed_control_paths=$ovs2_ctrl_untimed ([join $ovs2_ctrl {; }]) second_stage_control_paths=[llength $ovs2_nctrl] ([join $ovs2_nctrl {; }])"
    lappend ovs2_areg_rows "$ovs2_name\[first=$ovs2_dst_areg second=$ovs2_next_areg\]"
    if {![ovs2_true $ovs2_dst_areg] || ![ovs2_true $ovs2_next_areg]} {incr ovs2_areg_gaps}
    incr ovs2_checked
}
if {$ovs2_checked != 3} {
    error "SC7F0_OVERLAY_SYNC_R2_INCOMPLETE: $ovs2_checked of 3 crossings graded"
}
if {$ovs2_areg_annotated != 3 || $ovs2_areg_gaps != 0} {
    error "SC7F0_OVERLAY_SYNC_R2_ASYNC_REG_INCOMPLETE: $ovs2_areg_annotated of 3 chains have both stages annotated (gaps=$ovs2_areg_gaps); rows=([join $ovs2_areg_rows {; }])"
}
puts "SC7F0_OVERLAY_SYNC_R2_ASYNC_REG_PASS chains=$ovs2_areg_annotated stage_assertions=6 both_stages_true=1 rows=([join $ovs2_areg_rows {; }]) scope=poison_sync_reg\[0\],poison_sync_reg\[1\],sync0_reg,sync1_reg written_pre-opt + epoch_sync_l_reg\[0\],\[1\] annotated_in_rtl vendor_ddc_hpd=not_touched"

# ---------------------------------------------------------------------------
# Bus skew of the writer's three 32-bit Gray words, read out of the tool's own
# whole-design report.
#
# Why this lives here now: `report_bus_skew` has NO -from/-to in 2023.2, so the
# per-word numbers cannot be asked for directly (the same fact that made an
# earlier revision catch "Unknown option '-from'" and report bus_skew_violated=0
# for a measurement that never ran).  The supported signature reports the whole
# design once, and the row for a word is located by the -from / -to expression
# the constraint was created with, which the report prints verbatim
# (round G's proj_full26111402/bus-skew.rpt: Id 148/149/150 at lines 2921-2931
# and the per-constraint blocks, e.g. line 21821 for u_errf).  A printed
# "3.333 ns" next to a cell name is a claim; the Requirement / Actual / Slack /
# MET-VIOLATED quadruple taken from the report is a measurement, so all four are
# extracted here and a word with no row, a wrong bound, a wrong endpoint count or
# a VIOLATED verdict stops the run.
# ---------------------------------------------------------------------------
proc ovs2_skew_report {} {
    # Preferred signature: the plain whole-design report, the one
    # scripts/check_sc7f0_overlay_gray.tcl already runs on this design.
    if {![catch {report_bus_skew -return_string} text]} {
        return [list source {report_bus_skew -return_string} text $text error {}]
    }
    # Second supported signature (same one
    # scripts/check_sc7f0_named_constraints.tcl uses after `help report_bus_skew`
    # was read in 2023.2), kept so a report-size problem is not silently a gap.
    if {![catch {report_bus_skew -delay_type max -max_paths 1 -nworst 1 -sort_by_slack \
                     -quiet -return_string} text]} {
        return [list source {report_bus_skew -delay_type max -max_paths 1 -nworst 1 -sort_by_slack -return_string} text $text error {}]
    }
    # Read-only fallback: this round's own bus-skew.rpt, written by
    # scripts/report_sc7f0_implementation_evidence.tcl before this hook runs.
    set dir ""
    if {[info exists ::env(SC7F0_REPORT_DIR)]} {set dir $::env(SC7F0_REPORT_DIR)}
    set path [file join $dir bus-skew.rpt]
    if {$dir eq "" || ![file exists $path]} {
        return [list source {} text {} error "no supported report_bus_skew signature returned a string and $path does not exist"]
    }
    set fh [open $path r]
    set text [read $fh]
    close $fh
    return [list source "this round's $path" text $text error {}]
}

proc ovs2_skew_rows {text} {
    set rows {}
    set have 0
    array set cur {}
    foreach line [split $text \n] {
        if {[regexp {^Id:\s*([0-9]+)\s*$} $line unused id]} {
            if {$have} {lappend rows [array get cur]}
            catch {array unset cur}
            array set cur {constraint_id {} from_expr {} to_expr {} requirement {}
                           endpoints {} actual {} slack {} violated 0 corner_rows 0}
            set cur(constraint_id) $id
            set have 1
            continue
        }
        if {!$have} continue
        if {[regexp {^set_bus_skew\s.*-from\s+(.+)\s+-to\s+(.+?)\s+([0-9.]+)\s*$} \
                $line unused from_expr to_expr requirement]} {
            set cur(from_expr) $from_expr
            set cur(to_expr) $to_expr
            if {$cur(requirement) eq ""} {set cur(requirement) $requirement}
        } elseif {[regexp {^Requirement:\s*([0-9.]+)ns} $line unused value]} {
            set cur(requirement) $value
        } elseif {[regexp {^\s*Endpoints:\s*([0-9]+)} $line unused count]} {
            set cur(endpoints) $count
        } elseif {[regexp {^\s*Actual Bus Skew:\s*([0-9.]+)ns} $line unused value]} {
            if {$cur(actual) eq "" || [expr {double($value) > double($cur(actual))}]} {
                set cur(actual) $value
            }
        } elseif {[regexp {^\s*(Slow|Fast)\s+([0-9.]+)\s+(-?[0-9.]+)\s*$} \
                      $line unused corner act slk]} {
            # per-endpoint corner line of this constraint's own table; keep the
            # worst actual and the worst slack seen in the block
            if {$cur(actual) eq "" || [expr {double($act) > double($cur(actual))}]} {
                set cur(actual) $act
            }
            if {$cur(slack) eq "" || [expr {double($slk) < double($cur(slack))}]} {
                set cur(slack) $slk
            }
            incr cur(corner_rows)
        } elseif {[regexp {^\s*Slack \((MET|VIOLATED)\)\s*:\s*(-?[0-9.]+)ns} \
                      $line unused verdict value]} {
            set cur(slack) $value
            if {$verdict eq {VIOLATED}} {set cur(violated) 1}
        }
    }
    if {$have} {lappend rows [array get cur]}
    return $rows
}

array set ovs2_skew_rep [ovs2_skew_report]
if {$ovs2_skew_rep(error) ne ""} {
    error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_UNMEASURED: $ovs2_skew_rep(error); the Gray words' skew would be unmeasured, which is not a pass."
}
set ovs2_skew_rows [ovs2_skew_rows $ovs2_skew_rep(text)]
set ovs2_skew_summary {}
foreach ovs2_blk {u_frames u_beats u_errf} {
    set ovs2_from_root "u_overlay_writer/$ovs2_blk/src_gray_ff_reg"
    set ovs2_to_root "u_overlay_writer/$ovs2_blk/dest_graysync_ff_reg"
    set ovs2_hits {}
    foreach ovs2_row $ovs2_skew_rows {
        array unset ovs2_rec
        array set ovs2_rec $ovs2_row
        if {[string first $ovs2_from_root $ovs2_rec(from_expr)] < 0} {continue}
        if {[string first $ovs2_to_root $ovs2_rec(to_expr)] < 0} {continue}
        lappend ovs2_hits $ovs2_row
    }
    if {[llength $ovs2_hits] == 0} {
        error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_NO_ROW $ovs2_blk: none of [llength $ovs2_skew_rows] set_bus_skew constraints in $ovs2_skew_rep(source) names $ovs2_from_root -> $ovs2_to_root; the $ovs2_blk skew was NOT measured (a constraint that never applied produces no row)."
    }
    if {[llength $ovs2_hits] > 1} {
        error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_AMBIGUOUS $ovs2_blk: [llength $ovs2_hits] set_bus_skew constraints match $ovs2_from_root -> $ovs2_to_root; refusing to guess which one to grade."
    }
    array unset ovs2_rec
    array set ovs2_rec [lindex $ovs2_hits 0]
    if {$ovs2_rec(requirement) eq "" ||
        [expr {abs(double($ovs2_rec(requirement)) - $ovs2_period) > 0.001}]} {
        error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_BOUND $ovs2_blk: the matched constraint (Id $ovs2_rec(constraint_id)) carries requirement '$ovs2_rec(requirement)', expected $ovs2_period ns."
    }
    if {$ovs2_rec(endpoints) ne "32"} {
        error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_ENDPOINTS $ovs2_blk: constraint Id $ovs2_rec(constraint_id) reports $ovs2_rec(endpoints) endpoints, expected 32 (one per Gray bit)."
    }
    if {$ovs2_rec(actual) eq "" || $ovs2_rec(slack) eq ""} {
        error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_UNPARSED $ovs2_blk: constraint Id $ovs2_rec(constraint_id) yielded no actual/skew numbers ($ovs2_rec(corner_rows) corner rows seen); the report form changed."
    }
    if {$ovs2_rec(violated) eq "1" || [expr {double($ovs2_rec(slack)) < 0}]} {
        error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_VIOLATED $ovs2_blk: constraint Id $ovs2_rec(constraint_id) actual $ovs2_rec(actual) ns, slack $ovs2_rec(slack) ns."
    }
    puts "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW $ovs2_blk: constraint_id=$ovs2_rec(constraint_id) bound=$ovs2_rec(requirement) ns endpoints=$ovs2_rec(endpoints) actual_skew=$ovs2_rec(actual) ns slack=$ovs2_rec(slack) ns violated=$ovs2_rec(violated) corner_rows=$ovs2_rec(corner_rows) report=$ovs2_skew_rep(source)"
    lappend ovs2_skew_summary "$ovs2_blk\[id=$ovs2_rec(constraint_id) bound=$ovs2_rec(requirement) actual=$ovs2_rec(actual) slack=$ovs2_rec(slack) violated=$ovs2_rec(violated)\]"
}
if {[llength $ovs2_skew_summary] != 3} {
    error "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_INCOMPLETE: [llength $ovs2_skew_summary] of 3 Gray words graded"
}
puts "SC7F0_OVERLAY_SYNC_R2_BUS_SKEW_PASS words=[llength $ovs2_skew_summary] constraint_rows_total=[llength $ovs2_skew_rows] report=$ovs2_skew_rep(source) rows=([join $ovs2_skew_summary {; }])"
puts "SC7F0_OVERLAY_SYNC_R2_CHECK_PASS endpoints=$ovs2_checked requirement=$ovs2_period async_reg_annotated=$ovs2_areg_annotated async_reg_gaps=$ovs2_areg_gaps bus_skew_words=3 review_required=clock_domain_and_reset_class_rows"

