# =============================================================================
# scripts/check_sc7f0_overlay_gray_r2.tcl
#
# MEASURE-CODE revision of the routed re-check in
# scripts/check_sc7f0_overlay_gray.tcl.  It applies, widens or removes nothing and
# approves nothing.  It exists because round 26111401 - the first round whose
# implementation ever reached that check - ended the whole build on it:
#
#   build_full26111401.log:6954  (after Layer B items=43 verdict=PASS)
#     FULL_TCL_ERROR=SC7F0_OVERLAY_GRAY_MISSING u_overlay_writer/u_errf: expected
#     exactly 32 Gray source FFs, found 0        -> runner exit 1
#   logs/audit_r1.log:236  the same failure reproduced independently on the final
#     checkpoint, so it is a property of the check, not of the build log.
#
# What the round does say about the exception: pre-opt the apply hook resolved all
# three words (build_full26111401.log:3988-3990, "gray u_frames / u_beats / u_errf
# from=32 to=32"), and Layer B holds capture_gray_to_source_time /
# capture_gray_to_csr_time as Max Delay rows 229/231 with 0 ignored and 0
# scope-overridden.
#
# Ownership and direction, from RTL and measured here rather than asserted:
# u_frames, u_beats and u_errf are xpm_cdc_gray #(.DEST_SYNC_FF(4),
# .INIT_SYNC_FF(1), .WIDTH(32)) instances at rtl/sc7f0_overlay_writer.v:552-558,
# connected .src_clk(mem_clk) / .dest_clk(clk): the overlay writer's frame counter,
# beat counter and error counter status words cross the 300 MHz capture/mem side
# INTO the 125 MHz PCIe user-clock side (the same direction recorded in
# scripts/apply_sc7f0_overlay_cdc.tcl section 1).  Every row below prints the clock
# domains the tool actually reports for the source and destination cells.
#
# Why the old check reported 0.  It matched pre-opt cell spellings and required a
# hard 32-object count, and it also resolved bracketed bus-hierarchy names by
# printing and re-reading them.  Round 26111401 measured both weaknesses:
#   * `get_cells -hier <name>` over a name containing [..] (and over cells under a
#     linked IP) is not the inverse of printing that name; the first revision of
#     this script lost u_pcie_ip/inst/user_lnk_up_reg that way
#     (logs/audit_r1.log:304).  Per-bit resolution here therefore uses the
#     -regexp patterns that scripts/apply_sc7f0_overlay_cdc.tcl proved at pre-opt
#     on this same design, and objects - never re-read names - are what every
#     later query uses.
#   * opt_design / phys_opt_design may fold, merge or replicate a source bit, so a
#     name count is not evidence.  This script instead measures, per bit:
#       - the bit's physical source cells (replicas included),
#       - its first destination stage dest_graysync_ff_reg[0][bit] and how many
#         later stages exist (xpm_cdc_gray generates DEST_SYNC_FF-1 of them),
#       - the exhaustive launch set of that destination D pin
#         (all_fanin -flat -startpoints_only -only_cells, positional form, which
#         is the form that worked in this round), and whether those launches are
#         exactly this bit's own source registers,
#       - the measured source / destination clock domains of the arc,
#       - the effective requirement, slack and LOGIC_LEVELS of the arc (a Gray
#         crossing must be register-to-register: LOGIC_LEVELS 0),
#       - report_bus_skew for the word against this round's netlist, written to a
#         file and parsed for its requirement, its measured skew and its
#         violation count,
#       - and, for a bit with no sequential launch, the pin and cell that actually
#         drive its D net (direction read from the tool, not guessed), so a folded
#         or aliased bit is identified by evidence and left for the reviewer.
#
# Fail-closed, and fail-honest: the full 3 x 32 row table, the bus-skew evidence
# and every problem are printed FIRST, and the script then stops nonzero if any bit
# lacks a first stage, has a foreign or missing launch, has a source register that
# does not reach its destination bit, has combinational levels in the crossing, has
# a requirement other than 3.333 ns, sits in one clock domain, or if the bus-skew
# query fails, matches no group, parses ambiguously, shows no 3.333 bound or shows
# violations.  Nothing is NA'd, no bit is skipped, the expected width is never
# adjusted, and a failed query is never reported as an absent object.  Whether a
# folded or aliased bit is acceptable is policy for the independent reviewer.
# =============================================================================
set ov2g_period 3.333
set ov2g_bus_skew_text 3.333
set ov2g_width 32
set ov2g_blocks_checked 0
set ov2g_problems_all {}
if {![info exists ::env(SC7F0_GRAY_R2_OUT)]} {
    set ::env(SC7F0_GRAY_R2_OUT) "."
}

proc ov2g_names {objs} {
    if {$objs eq "" || [llength $objs] == 0} {return {}}
    if {[catch {get_property NAME $objs} names]} {return {}}
    return $names
}

proc ov2g_short {items limit} {
    if {$items eq ""} {return "-"}
    set items [lsort -unique $items]
    if {[llength $items] <= $limit} {return [join $items ,]}
    return "[join [lrange $items 0 [expr {$limit - 1}]] ,],...([llength $items] total)"
}

proc ov2g_prop {prop obj} {
    if {$obj eq "" || [llength $obj] == 0} {return {EMPTY_OBJECT_LIST}}
    if {[catch {get_property $prop $obj} value]} {return "QUERY_ERROR: [string range $value 0 120]"}
    if {$value eq ""} {return "unset(false)"}
    return $value
}

proc ov2g_clocks {obj} {
    if {$obj eq "" || [llength $obj] == 0} {return {OBJECT_LOOKUP_FAILED}}
    set clocks ""
    if {[catch {get_clocks -quiet -of_objects $obj} clocks]} {return QUERY_ERROR}
    if {$clocks eq "" || [llength $clocks] == 0} {return "no_clock"}
    if {[catch {join [lsort -unique [get_property NAME $clocks]] |} text]} {return QUERY_ERROR}
    return $text
}

# mirrors scripts/apply_sc7f0_overlay_cdc.tcl:sc7f0_ov_launch_names, proved on this
# design: keep the object, error on an unresolvable object, never read a partial
# list as a complete one
proc ov2g_launch_objs {fan id} {
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
                error "SC7F0_OVERLAY_GRAY_R2_FANIN_UNRESOLVED $id: fan-in object $o is neither a pin/net with an owning cell nor a cell (REF_NAME empty); the launch set cannot be enumerated and a partial list must not be read as a complete one."
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

# what really drives a net, read from the tool: pin direction, then the owning
# cell and its reference.  A query failure is reported as one, never as "no driver"
proc ov2g_net_driver {net} {
    if {$net eq "" || [llength $net] == 0} {return "no_net_object"}
    set pins ""
    if {[catch {get_pins -quiet -of $net} pins]} {return "PIN_QUERY_ERROR: [string range $pins 0 120]"}
    if {$pins eq "" || [llength $pins] == 0} {return "no_pins_on_net"}
    set out {}
    foreach p $pins {
        set dir [ov2g_prop DIRECTION $p]
        if {[string tolower $dir] ne "out"} {continue}
        set cell ""
        if {[catch {get_cells -quiet -of $p} cell]} {set cell ""}
        set cref "no_owning_cell"
        if {$cell ne "" && [llength $cell] > 0} {set cref [ov2g_prop REF_NAME $cell]}
        lappend out "[get_property NAME $p]\[dir=$dir ref=$cref cell=[ov2g_short [ov2g_names $cell] 2]\]"
    }
    if {[llength $out] == 0} {return "no_out_direction_pin_among_[llength $pins]_pins"}
    return [ov2g_short $out 3]
}

foreach ov2g_blk {u_frames u_beats u_errf} {
    set ov2g_problems {}
    # the proven spellings, taken verbatim in form from apply_sc7f0_overlay_cdc.tcl
    set ov2g_src_pat {.*u_overlay_writer/}
    append ov2g_src_pat $ov2g_blk {/src_gray_ff_reg\[[0-9]+\]}
    set ov2g_dst_pat {.*u_overlay_writer/}
    append ov2g_dst_pat $ov2g_blk {/dest_graysync_ff_reg\[0\]\[[0-9]+\]}
    set ov2g_all_pat {.*u_overlay_writer/}
    append ov2g_all_pat $ov2g_blk {/dest_graysync_ff_reg.*}
    set ov2g_src_all [get_cells -quiet -hier -regexp $ov2g_src_pat]
    set ov2g_dst0_all [get_cells -quiet -hier -regexp $ov2g_dst_pat]
    set ov2g_dst_any [get_cells -quiet -hier -regexp $ov2g_all_pat]
    puts "SC7F0_OVERLAY_GRAY_R2_RESOLVE $ov2g_blk pattern_source={$ov2g_src_pat} source_cells=[llength $ov2g_src_all] first_stage_cells=[llength $ov2g_dst0_all] destination_cells_any_stage=[llength $ov2g_dst_any] source_examples=\{[ov2g_short [ov2g_names $ov2g_src_all] 3]\} first_stage_examples=\{[ov2g_short [ov2g_names $ov2g_dst0_all] 3]\}"
    if {[llength $ov2g_dst_any] == 0} {
        lappend ov2g_problems "no dest_graysync_ff_reg cells at all under $ov2g_blk; the crossing would be absent from the netlist, which is a hardware change and is reported as one"
    }

    # group the physical cells by logical bit index, from the objects already matched
    array set ov2g_src_obj {}
    array set ov2g_dst0_obj {}
    array set ov2g_stage_count {}
    foreach ov2g_c $ov2g_src_all {
        set ov2g_n [get_property NAME $ov2g_c]
        if {![regexp {src_gray_ff_reg\[([0-9]+)\]} $ov2g_n -> ov2g_i]} {
            lappend ov2g_problems "source cell $ov2g_n matched the source pattern but carries no bit index"
            continue
        }
        lappend ov2g_src_obj($ov2g_i) $ov2g_c
    }
    foreach ov2g_c $ov2g_dst_any {
        set ov2g_n [get_property NAME $ov2g_c]
        if {[regexp {dest_graysync_ff_reg\[([0-9]+)\]\[([0-9]+)\]} $ov2g_n -> ov2g_st ov2g_i]} {
            incr ov2g_stage_count($ov2g_st,$ov2g_i)
            if {$ov2g_st == 0} {lappend ov2g_dst0_obj($ov2g_i) $ov2g_c}
            continue
        }
        puts "SC7F0_OVERLAY_GRAY_R2_UNCLASSIFIED $ov2g_blk $ov2g_n is not of the form dest_graysync_ff_reg\[stage\]\[bit\]; reported, never counted"
    }
    set ov2g_stages {}
    foreach ov2g_k [array names ov2g_stage_count] {
        lappend ov2g_stages [lindex [split $ov2g_k ,] 0]
    }
    set ov2g_stages [lsort -unique -integer $ov2g_stages]
    puts "SC7F0_OVERLAY_GRAY_R2_STAGES $ov2g_blk destination_stages=\{[join $ov2g_stages ,]\} (xpm_cdc_gray DEST_SYNC_FF(4) generates the stage chain; stage 0 is the first stage)"

    set ov2g_mapped 0
    set ov2g_no_launch 0
    set ov2g_folded 0
    set ov2g_worst_slack {}
    set ov2g_levels_max 0
    set ov2g_domain_pairs {}
    for {set ov2g_i 0} {$ov2g_i < $ov2g_width} {incr ov2g_i} {
        set ov2g_sobjs {}
        if {[info exists ov2g_src_obj($ov2g_i)]} {set ov2g_sobjs $ov2g_src_obj($ov2g_i)}
        set ov2g_dobjs {}
        if {[info exists ov2g_dst0_obj($ov2g_i)]} {set ov2g_dobjs $ov2g_dst0_obj($ov2g_i)}
        set ov2g_later 0
        foreach ov2g_st $ov2g_stages {
            if {$ov2g_st == 0} {continue}
            if {[info exists ov2g_stage_count($ov2g_st,$ov2g_i)]} {incr ov2g_later}
        }
        set ov2g_snames [ov2g_names $ov2g_sobjs]
        if {[llength $ov2g_dobjs] == 0} {
            incr ov2g_folded
            lappend ov2g_problems "bit $ov2g_i: no dest_graysync_ff_reg\[0\]\[$ov2g_i\] first stage; source cells for this bit = \{[ov2g_short $ov2g_snames 3]\}"
            puts "SC7F0_OVERLAY_GRAY_R2_BIT $ov2g_blk bit=$ov2g_i CLASS=no_first_stage source_cells=[llength $ov2g_sobjs]\{[ov2g_short $ov2g_snames 3]\}"
            continue
        }
        if {[llength $ov2g_dobjs] != 1} {
            lappend ov2g_problems "bit $ov2g_i: [llength $ov2g_dobjs] first-stage cells, expected exactly 1: \{[ov2g_short [ov2g_names $ov2g_dobjs] 4]\}"
        }
        set ov2g_dcell [lindex $ov2g_dobjs 0]
        set ov2g_dname [get_property NAME $ov2g_dcell]
        set ov2g_dpin ""
        if {[catch {get_pins -quiet -of $ov2g_dcell -filter {NAME =~ */D}} ov2g_dpin]} {set ov2g_dpin ""}
        if {[llength $ov2g_dpin] != 1} {
            lappend ov2g_problems "bit $ov2g_i: D pin of $ov2g_dname resolved from the cell object to [llength $ov2g_dpin] pins"
            continue
        }
        set ov2g_fan ""
        if {[catch {all_fanin -flat -startpoints_only -only_cells $ov2g_dpin} ov2g_fan]} {
            lappend ov2g_problems "bit $ov2g_i: all_fanin failed: [string range $ov2g_fan 0 200]"
            continue
        }
        set ov2g_lobjs [ov2g_launch_objs $ov2g_fan "$ov2g_blk bit $ov2g_i"]
        set ov2g_lnames {}
        foreach ov2g_o $ov2g_lobjs { lappend ov2g_lnames [get_property NAME $ov2g_o] }
        set ov2g_foreign {}
        foreach ov2g_ln $ov2g_lnames {
            if {[lsearch -exact $ov2g_snames $ov2g_ln] < 0} {lappend ov2g_foreign $ov2g_ln}
        }
        set ov2g_unfed {}
        foreach ov2g_sn $ov2g_snames {
            if {[lsearch -exact $ov2g_lnames $ov2g_sn] < 0} {lappend ov2g_unfed $ov2g_sn}
        }
        set ov2g_src_clock "no_source_object"
        if {[llength $ov2g_sobjs]} {set ov2g_src_clock [ov2g_clocks $ov2g_sobjs]}
        if {[llength $ov2g_lobjs]} {set ov2g_src_clock [ov2g_clocks $ov2g_lobjs]}
        set ov2g_dst_clock [ov2g_clocks $ov2g_dcell]
        lappend ov2g_domain_pairs "$ov2g_src_clock->$ov2g_dst_clock"
        set ov2g_driver "not_queried(has_launches)"
        if {[llength $ov2g_lobjs] == 0} {
            set ov2g_net ""
            if {[catch {get_nets -quiet -of $ov2g_dpin} ov2g_net]} {set ov2g_net ""}
            set ov2g_driver "net=[ov2g_short [ov2g_names $ov2g_net] 1] driver=[ov2g_net_driver $ov2g_net]"
        }
        set ov2g_req "-"; set ov2g_slack "-"; set ov2g_levels "-"; set ov2g_ntimed 0
        if {[llength $ov2g_lobjs] > 0} {
            set ov2g_paths ""
            if {[catch {get_timing_paths -from $ov2g_lobjs -to $ov2g_dpin -delay_type max -max_paths 8 -nworst 4} ov2g_paths]} {
                lappend ov2g_problems "bit $ov2g_i: get_timing_paths failed: [string range $ov2g_paths 0 200]"
                set ov2g_paths ""
            }
            set ov2g_ntimed [llength $ov2g_paths]
            foreach ov2g_p $ov2g_paths {
                set ov2g_r [get_property REQUIREMENT $ov2g_p]
                set ov2g_req $ov2g_r
                if {$ov2g_r eq "" || [expr {abs(double($ov2g_r) - $ov2g_period) > 0.001}]} {
                    lappend ov2g_problems "bit $ov2g_i: [get_property STARTPOINT_PIN $ov2g_p] -> [get_property ENDPOINT_PIN $ov2g_p] carries requirement '$ov2g_r', expected $ov2g_period ns"
                }
                set ov2g_s [get_property SLACK $ov2g_p]
                if {$ov2g_s ne "" && ($ov2g_worst_slack eq "" || [expr {double($ov2g_s) < double($ov2g_worst_slack)}])} {
                    set ov2g_worst_slack $ov2g_s
                }
                set ov2g_lv [get_property LOGIC_LEVELS $ov2g_p]
                if {$ov2g_lv ne ""} {
                    if {$ov2g_levels eq "-" || $ov2g_lv > $ov2g_levels} {set ov2g_levels $ov2g_lv}
                    if {$ov2g_lv > $ov2g_levels_max} {set ov2g_levels_max $ov2g_lv}
                    if {$ov2g_lv > 0} {
                        lappend ov2g_problems "bit $ov2g_i: $ov2g_lv combinational levels between the Gray source and its first stage; a Gray word crossing must be a direct register-to-register arc"
                    }
                }
            }
            if {$ov2g_ntimed == 0} {
                lappend ov2g_problems "bit $ov2g_i: [llength $ov2g_lobjs] launch(es) but no timed max path to $ov2g_dname/D"
            }
            if {$ov2g_src_clock eq $ov2g_dst_clock} {
                lappend ov2g_problems "bit $ov2g_i: source and first stage are in the same clock domain '$ov2g_src_clock'; this is not the mem_clk -> clk crossing the exception names"
            }
        }
        if {$ov2g_later == 0} {
            lappend ov2g_problems "bit $ov2g_i: no later synchroniser stage after $ov2g_dname (xpm_cdc_gray must continue the chain)"
        }
        set ov2g_class "mapped"
        if {[llength $ov2g_lobjs] == 0} {
            set ov2g_class "no_sequential_launch"
            incr ov2g_no_launch
            lappend ov2g_problems "bit $ov2g_i: first stage $ov2g_dname/D has no sequential launch; $ov2g_driver (this bit's source cells: [ov2g_short $ov2g_snames 3])"
        } elseif {[llength $ov2g_foreign]} {
            set ov2g_class "foreign_launch"
            lappend ov2g_problems "bit $ov2g_i: launch set contains cells that are not this bit's own Gray source: [ov2g_short $ov2g_foreign 4]"
        } elseif {[llength $ov2g_unfed]} {
            set ov2g_class "source_not_connected"
            lappend ov2g_problems "bit $ov2g_i: source cell(s) [ov2g_short $ov2g_unfed 3] do not drive $ov2g_dname/D"
        } else {
            incr ov2g_mapped
        }
        puts "SC7F0_OVERLAY_GRAY_R2_BIT $ov2g_blk bit=$ov2g_i CLASS=$ov2g_class src_cells=[llength $ov2g_sobjs]\{[ov2g_short $ov2g_snames 2]\} first_stage=$ov2g_dname later_stages=$ov2g_later launches=[llength $ov2g_lobjs]\{[ov2g_short $ov2g_lnames 2]\} src_clocks=$ov2g_src_clock dst_clocks=$ov2g_dst_clock timed_paths=$ov2g_ntimed req=$ov2g_req slack=$ov2g_slack logic_levels=$ov2g_levels $ov2g_driver"
    }

    # ---- bus skew: real report, written, read back, parsed, graded -------------
    set ov2g_skew_file [file join $::env(SC7F0_GRAY_R2_OUT) bus_skew_${ov2g_blk}.rpt]
    set ov2g_skew_verdict "not_queried"
    set ov2g_skew_detail ""
    if {[llength $ov2g_src_all] == 0 || [llength $ov2g_dst0_all] == 0} {
        set ov2g_skew_verdict "skipped_because_source_or_first_stage_is_missing"
        lappend ov2g_problems "bus skew could not be queried over [llength $ov2g_src_all] source and [llength $ov2g_dst0_all] first-stage cells"
    } else {
        set ov2g_qerr ""
        set ov2g_qform "none"
        # Round 26111401 measured that 2023.2's report_bus_skew has no -from/-to
        # (logs/audit_r2.log: "ERROR: [Common 17-170] Unknown option '-from'"), so the
        # scoped form is tried first and its error kept verbatim, then the
        # option-less form - which reports every declared bus-skew group of the
        # design - is used.  The tool's own -help text is captured once for
        # provenance; nothing here assumes a syntax that was not measured.
        if {![info exists ::ov2g_skew_help]} {
            set ::ov2g_skew_help ""
            catch {set ::ov2g_skew_help [report_bus_skew -help]}
            puts "SC7F0_OVERLAY_GRAY_R2_BUS_SKEW_HELP [string range [string map {\n { }} $::ov2g_skew_help] 0 700]"
        }
        if {![catch {report_bus_skew -from $ov2g_src_all -to $ov2g_dst0_all -file $ov2g_skew_file} ov2g_qerr]} {
            set ov2g_qform "from_to"
        } else {
            set ov2g_scope_error [string range $ov2g_qerr 0 180]
            if {[catch {report_bus_skew -quiet -file $ov2g_skew_file} ov2g_qerr]} {
                set ov2g_skew_verdict "query_error"
                set ov2g_skew_detail "scoped_form: $ov2g_scope_error ; optionless_form: [string range $ov2g_qerr 0 180]"
                lappend ov2g_problems "bus skew could not be queried in either form (scoped: $ov2g_scope_error)"
            } else {
                set ov2g_qform "optionless(scoped_form_unsupported: $ov2g_scope_error)"
            }
        }
        if {$ov2g_qform ne "none"} {
            set ov2g_txt ""
            if {[catch {set ov2g_fh [open $ov2g_skew_file r]} ov2g_fh]} {
                set ov2g_skew_verdict "report_file_unreadable"
                lappend ov2g_problems "bus skew report $ov2g_skew_file could not be opened: $ov2g_fh"
            } else {
                set ov2g_txt [read $ov2g_fh]; close $ov2g_fh
                set ov2g_viol "-"; set ov2g_reqrows 0; set ov2g_bound 0; set ov2g_group 0; set ov2g_wordrows 0
                set ov2g_first_rows {}
                foreach ov2g_line [split $ov2g_txt \n] {
                    set ov2g_t [string trim $ov2g_line]
                    if {[string length $ov2g_first_rows] < 1500} {append ov2g_first_rows "$ov2g_t | "}
                    if {[string match "*$ov2g_blk*" $ov2g_t]} {incr ov2g_wordrows}
                    if {[regexp -nocase {violation} $ov2g_t]} {
                        if {[regexp -nocase {total.*?([0-9]+).*?violation} $ov2g_t -> ov2g_n]} {set ov2g_viol $ov2g_n}
                        if {[regexp {^([0-9]+) violation} $ov2g_t -> ov2g_n]} {set ov2g_viol $ov2g_n}
                        if {[regexp -nocase {no violations} $ov2g_t]} {set ov2g_viol 0}
                        if {[string length $ov2g_skew_detail] < 400} {append ov2g_skew_detail "$ov2g_t | "}
                    }
                    if {[regexp -nocase {bus skew} $ov2g_t]} {incr ov2g_group}
                    if {[regexp {3\.33[0-9]*} $ov2g_t]} {incr ov2g_bound}
                    if {[regexp {^[0-9]+\s+[0-9.]+\s+[0-9.]+} $ov2g_t]} {incr ov2g_reqrows}
                }
                set ov2g_skew_detail [string range $ov2g_skew_detail 0 400]
                if {$ov2g_group == 0} {
                    lappend ov2g_problems "bus skew report contains no bus-skew group for this -from/-to set; the set_bus_skew constraint cannot be seen in the tool's own report"
                }
                if {$ov2g_viol eq "-"} {
                    lappend ov2g_problems "bus skew report gives no parseable violation count (rows=$ov2g_reqrows groups=$ov2g_group); an unparsed report is not a pass"
                } elseif {$ov2g_viol != 0} {
                    lappend ov2g_problems "bus skew violations=$ov2g_viol on $ov2g_blk"
                }
                if {$ov2g_bound == 0} {
                    lappend ov2g_problems "bus skew report shows no $ov2g_bus_skew_text bound; the declared 3.333 ns skew is not evidenced in the report"
                }
                if {$ov2g_wordrows == 0} {
                    lappend ov2g_problems "the bus skew report contains no line naming $ov2g_blk; the declared set_bus_skew group for this word cannot be identified in the tool's own output, which is a measurement gap and not a pass (report_form=$ov2g_qform)"
                }
                set ov2g_skew_verdict "form=$ov2g_qform violations=$ov2g_viol groups=$ov2g_group bound_rows=$ov2g_bound table_rows=$ov2g_reqrows word_rows=$ov2g_wordrows"
                if {$ov2g_viol != 0 || $ov2g_group == 0 || $ov2g_bound == 0 || $ov2g_viol eq "-" || $ov2g_wordrows == 0} {
                    lappend ov2g_problems "bus skew verdict not clean: $ov2g_skew_verdict"
                }
                puts "SC7F0_OVERLAY_GRAY_R2_BUS_SKEW_RAW $ov2g_blk file=$ov2g_skew_file head=\{[string range $ov2g_first_rows 0 900]\}"
            }
        }
    }
    # the later synchroniser stages stay normal timed logic; reported separately so
    # the -to set of the exception (first stage only) is never blurred
    set ov2g_later_rows "none"
    if {[llength $ov2g_dst_any] > [llength $ov2g_dst0_all]} {
        set ov2g_lcells {}
        foreach ov2g_c $ov2g_dst_any {
            if {[string match "*dest_graysync_ff_reg\[0\]*" [get_property NAME $ov2g_c]]} {continue}
            lappend ov2g_lcells $ov2g_c
        }
        if {[llength $ov2g_lcells]} {
            set ov2g_lp [get_timing_paths -to $ov2g_lcells -delay_type max -max_paths 4 -nworst 2 -quiet]
            set ov2g_lreq {}
            set ov2g_lslack {}
            foreach ov2g_p $ov2g_lp {
                lappend ov2g_lreq [get_property REQUIREMENT $ov2g_p]
                lappend ov2g_lslack [get_property SLACK $ov2g_p]
            }
            set ov2g_later_rows "later_stage_cells=[llength $ov2g_lcells] timed_paths=[llength $ov2g_lp] requirements=\{[join [lsort -unique $ov2g_lreq] ,]\} slacks=\{[join [lsort -unique $ov2g_lslack] ,]\}"
        }
    }
    puts "SC7F0_OVERLAY_GRAY_R2_BLOCK $ov2g_blk: width=$ov2g_width mapped=$ov2g_mapped no_sequential_launch=$ov2g_no_launch no_first_stage=$ov2g_folded physical_source_cells=[llength $ov2g_src_all] first_stage_cells=[llength $ov2g_dst0_all] destination_cells_any_stage=[llength $ov2g_dst_any] stages=\{[join $ov2g_stages ,]\} clock_pairs=\{[join [lsort -unique $ov2g_domain_pairs] ,]\} worst_crossing_slack=$ov2g_worst_slack max_logic_levels=$ov2g_levels_max requirement_expected=$ov2g_period bus_skew_file=$ov2g_skew_file bus_skew=$ov2g_skew_verdict bus_skew_detail=\{$ov2g_skew_detail\} $ov2g_later_rows problems=[llength $ov2g_problems]"
    foreach ov2g_p $ov2g_problems {
        puts "SC7F0_OVERLAY_GRAY_R2_PROBLEM $ov2g_blk $ov2g_p"
        lappend ov2g_problems_all "$ov2g_blk: $ov2g_p"
    }
    unset ov2g_src_obj
    unset ov2g_dst0_obj
    unset ov2g_stage_count
    incr ov2g_blocks_checked
}
set ov2g_bus_skew_text_ok 1
puts "SC7F0_OVERLAY_GRAY_R2_SUMMARY blocks=$ov2g_blocks_checked width=$ov2g_width requirement=$ov2g_period total_problems=[llength $ov2g_problems_all] approves_nothing=1"
if {[llength $ov2g_problems_all]} {
    error "SC7F0_OVERLAY_GRAY_R2_FAILED problems=[llength $ov2g_problems_all] first=\{[join [lrange $ov2g_problems_all 0 2] {; }]\}"
}
if {$ov2g_blocks_checked != 3} {
    error "SC7F0_OVERLAY_GRAY_R2_INCOMPLETE $ov2g_blocks_checked of 3 blocks graded"
}
puts "SC7F0_OVERLAY_GRAY_R2_CHECK_PASS blocks=$ov2g_blocks_checked requirement=$ov2g_period policy_rows_review_required=3"
