# =============================================================================
# scripts/apply_sc7f0_overlay_cdc.tcl
#
# FULL-Tcl implementation pre-opt hook: it APPLIES (not merely checks) the two
# SC7F0-RGB overlay crossing constraint sets, under real guards, and then proves
# in the same run that the timing engine took them.
#
# Why the application moved out of XDC (measured, not theorised).  Round
# rgb-fullimpl-26111333-20261113T204036Z, logs/build_full26111333.log:
#
#   :3796,:3797  [Designutils 20-1307] Command 'if' is not supported in the xdc
#                constraint file            -> constraints/sc7f0_overlay_gray.xdc
#                guard block skipped (its flat set_max_delay/set_bus_skew lines
#                still applied, so the crossings were constrained but WITHOUT the
#                empty-collection protection the file claims to provide)
#   :3800-:3802  [Designutils 20-1307] 'if' and 'concat' not supported
#   :3803        [Common 17-1548] can't read "sc7f0_ovs_dst": no such variable
#                -> constraints/sc7f0_overlay_sync.xdc:104, i.e. the three
#                synchroniser max delays were NEVER applied in that round, which
#                is why its route still reports the same three tight endpoints.
#
# So the managed read_xdc reader is declarative-only: control flow and most Tcl
# commands are dropped with a CRITICAL WARNING, and a failed command degrades to
# "constraint not applied" rather than stopping the run.  An earlier revision of
# these files asserted the opposite; that claim is withdrawn and replaced by this
# measured behaviour.  A nonphysical stub that "reads" the file proves nothing
# about the real reader, which is exactly how the wrong belief survived.
#
# The rule this file follows:
#   * a managed .xdc contains only commands the restricted reader supports;
#   * object resolution, count/direction guards and any conditional application
#     live here, in full Tcl, where `error` really aborts the run;
#   * a guard failure must therefore never be able to leave an empty -from/-to
#     collection, which is the case where an exception silently becomes a
#     device-wide one.
#
# One more reader fact this file had to learn the hard way: in round
# rgb-fullimpl-26111334-20261113T212522Z the -to-only form
#   set_max_delay -datapath_only 3.333 -to <3 first-stage FFs>
# was rejected with [Constraints 18-540] "set_max_delay -datapath_only requires
# -from to be non-empty" (logs/build_full26111334.log), which stopped impl_1 at
# opt_design before any placement.  So each synchroniser bound is now declared
# from its own resolved and guarded source register(s) to its one named first
# stage, which is also the narrower object set.
#
# Numbers are unchanged from the XDC they replace (3.333 ns max delay
# -datapath_only, 3.333 ns bus skew on the Gray words); nothing is widened, no
# false path, clock group, multicycle or lowered clock is introduced, and no
# review verdict is written: scripts/gates/*.json still carries no REVIEWED_SAFE
# entry for any of these crossings.
#
# Sourced from scripts/impl_pre_opt_sc7f0.tcl, which is
# STEPS.OPT_DESIGN.TCL.PRE, i.e. after XDC import and before opt_design, so the
# exceptions are in force for placement and routing (this is not a post-hoc
# relabel of a finished route).
# =============================================================================
set sc7f0_ov_period 3.333

# Small helper: names of a cell collection, sorted, for one-line log output.
proc sc7f0_ov_names {coll} {
    set out {}
    foreach c $coll {lappend out [get_property NAME $c]}
    return $out
}

# all_fanin has NO -endpoints_only option (measured in this round's pre-flight
# probe: `ERROR: [Common 17-170] Unknown option '-endpoints_only'` on the routed
# 26111335 checkpoint; `all_fanin -help` lists -startpoints_only, -flat,
# -only_cells, -levels, -pin_levels, -trace_arcs and nothing else of that kind).
# The correct exhaustive launch query is therefore
#   all_fanin -flat -startpoints_only -only_cells -to <D pin>
# which answers with the timing startpoints (the launch cells) of the cone.
# -only_cells answers with cells, so the resolver below still handles pins for
# safety: a mapping that silently yields empty names is how a coverage loop ends
# up "covering" nothing.
# --- ASYNC_REG support procs (round H, rgb-fullimpl-261114xx) -----------------
# Round G's own routed report_cdc is the reason these exist:
#   proj_full26111402/cdc.rpt:19   CDC-2 Warning  1-bit synchronized with
#                                  missing ASYNC_REG          2
#   proj_full26111402/cdc.rpt:948  u_dma_top/u_overlay_ingress/arm_toggle_reg/C
#                                    -> u_dma_top/u_overlay_ingress/sync0_reg/D
#   proj_full26111402/cdc.rpt:956  u_dma_top/u_overlay_writer/debt_poison_epoch_reg/C
#                                    -> u_dma_top/u_overlay_writer/poison_sync_reg[0]/D
# The third synchroniser this hook names (epoch_sync_l) is already annotated in
# RTL (rtl/sc7f0_overlay_writer.v:1197 `(* ASYNC_REG = "TRUE" *) reg [2:0]
# epoch_sync_l`), so it is deliberately NOT in the target set below and nothing
# here re-writes it.  The two chains that ARE in the target set are plain
# hand-rolled two-flop level/toggle synchronisers
#   rtl/sc7f0_overlay_writer.v:466  `reg [1:0] poison_sync;`  + :1326-1330
#   rtl/sc7f0_overlay_ingress.v:950 `reg arm_toggle, sync0, sync1, ...` + :956-966
# and each has exactly two stages, so the annotation scope is exactly 4 existing
# cells.  The launch flop (arm_toggle_reg) and everything downstream of the
# second stage are NOT annotated: they are ordinary timed logic, and annotating
# a vendor DDC/HPD filter or a data-path cell to make a report row pretty is
# exactly the kind of green-manufacturing this hook exists to refuse.
#
# This is an implementation-only physical attribute (both stages get placed
# together); it changes no Verilog semantic, no requirement value and no
# exception, and it is NOT an MTBF proof - the per-stage setup/hold resolution
# still has to come back from the routed report.
set sc7f0_ov_areg_targets {poison arm}
set sc7f0_ov_areg_cell_total 0
set sc7f0_ov_areg_chain_total 0

# Family test for "this cell is a register", same vocabulary as
# scripts/check_sc7f0_overlay_sync_r2.tcl's ovs2_sequential.
proc sc7f0_ov_sequential {ref} {
    foreach fam {FD LD IDDR IDES ISERDESE} {
        if {[string match ${fam}* $ref]} {return 1}
    }
    return 0
}

# Clock name(s) reaching an object.  Asked of the CELL, not of a data pin: a
# register is captured through its clock pin and get_clocks on a D pin answers
# with nothing, which an earlier round measured as a phantom "'-' domain".
proc sc7f0_ov_clk_text {obj} {
    if {$obj eq "" || [llength $obj] == 0} {return {OBJECT_LOOKUP_FAILED}}
    if {[catch {get_clocks -quiet -of_objects $obj} cl]} {return QUERY_ERROR}
    if {$cl eq ""} {return {-}}
    if {[catch {join [lsort -unique [get_property NAME $cl]] |} t]} {return QUERY_ERROR}
    return $t
}

# Boolean property read that keeps the three outcomes apart:
#   true   -> the tool answered 1/TRUE/true/yes/on  (normalised here, so a real
#             tool answer of "1" is not rejected by a string-equal-to-"true" test)
#   false  -> the tool answered and the value is empty or 0/FALSE/off
#   bad    -> the query itself failed, the object list was empty, or the answer
#             is a token that is neither true nor false (e.g. QUERY_ERROR).
# "bad" is always fatal for the caller: an unqueryable property is not a false
# one, and treating it as false would make a broken query look like a passing
# check.
proc sc7f0_ov_bool {prop obj} {
    if {$obj eq "" || [llength $obj] == 0} {
        return [list state bad value EMPTY_OBJECT_LIST]
    }
    if {[catch {get_property $prop $obj} v]} {
        return [list state bad value "QUERY_ERROR($v)"]
    }
    set t [string tolower [string trim $v]]
    if {$t eq ""}              {return [list state false value {unset(false)}]}
    if {$t in {1 true yes on}}  {return [list state true value $v]}
    if {$t in {0 false no off}} {return [list state false value $v]}
    return [list state bad value $v]
}

# Launch objects of a fan-in list, keeping the OBJECT rather than reprinting and
# re-resolving its name (round 26111401 measured that `get_cells -hier <name>`
# fails across a linked IP boundary even one statement after the tool printed
# that name, and a failed lookup read as "no launch" is a fail-open).  Same
# discipline as scripts/check_sc7f0_overlay_sync_r2.tcl's ovs2_launch_objs.
proc sc7f0_ov_launch_objs {fan id} {
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
                error "SC7F0_OVERLAY_SYNC_ASYNC_REG_FANIN_UNRESOLVED $id: fan-in object $o is neither a pin/net with an owning cell nor a cell (REF_NAME empty)."
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

proc sc7f0_ov_launch_names {fan id} {
    set names {}
    foreach o $fan {
        if {$o eq ""} {continue}
        set c [get_cells -quiet -of $o]
        if {$c eq "" || [llength $c] == 0} {
            set ref ""
            catch {set ref [get_property REF_NAME $o]}
            if {$ref eq ""} {
                error "SC7F0_OVERLAY_SYNC_FANIN_UNRESOLVED $id: fan-in object $o is neither a pin/net with an owning cell nor a cell (REF_NAME empty); the launch set cannot be enumerated and an incomplete list must not be read as a complete one."
            }
            set c [list $o]
        }
        foreach cc $c {lappend names [get_property NAME $cc]}
    }
    return [lsort -unique $names]
}

# ---------------------------------------------------------------------------
# 1. The three Gray status counters of the overlay writer
#    (rtl/sc7f0_overlay_writer.v u_frames / u_beats / u_errf, WIDTH=32 each,
#    mem_clk 300 MHz -> pcie_user_clk 125 MHz).  Same form and size as the file
#    this replaces; 3.333 = one source period = min(source, destination).
# ---------------------------------------------------------------------------
foreach sc7f0_ov_blk {u_frames u_beats u_errf} {
    set sc7f0_ov_sre {.*u_overlay_writer/}
    append sc7f0_ov_sre $sc7f0_ov_blk {/src_gray_ff_reg\[[0-9]+\]}
    set sc7f0_ov_dre {.*u_overlay_writer/}
    append sc7f0_ov_dre $sc7f0_ov_blk {/dest_graysync_ff_reg\[0\]\[[0-9]+\]}
    set sc7f0_ov_s [get_cells -quiet -hier -regexp $sc7f0_ov_sre]
    set sc7f0_ov_d [get_cells -quiet -hier -regexp $sc7f0_ov_dre]
    if {[llength $sc7f0_ov_s] != 32 || [llength $sc7f0_ov_d] != 32} {
        error "SC7F0_OVERLAY_GRAY_MISSING $sc7f0_ov_blk: matched [llength $sc7f0_ov_s] src_gray_ff and [llength $sc7f0_ov_d] first-stage dest_graysync_ff cells, expected 32 of each. Either the RGB overlay writer is not in this build or the crossing changed shape; refusing to apply a -from/-to exception over an incomplete collection."
    }
    set sc7f0_ov_md [set_max_delay -datapath_only $sc7f0_ov_period -from $sc7f0_ov_s -to $sc7f0_ov_d]
    set sc7f0_ov_bs [set_bus_skew $sc7f0_ov_period -from $sc7f0_ov_s -to $sc7f0_ov_d]
    puts "SC7F0_OVERLAY_CDC_APPLIED gray $sc7f0_ov_blk from=[llength $sc7f0_ov_s] to=[llength $sc7f0_ov_d] objects: set_max_delay -datapath_only $sc7f0_ov_period -from <32 src_gray_ff_reg> -to <32 dest_graysync_ff_reg\[0\> / set_bus_skew $sc7f0_ov_period same objects\]"
}

# ---------------------------------------------------------------------------
# 2. The three hand-rolled 125 MHz -> 300 MHz single-bit synchronisers:
#    writer epoch_sync_l[0] (3 FF, ASYNC_REG) fed by the PCIe core's user_reset,
#    writer poison_sync[0]     fed by debt_poison_epoch_reg,
#    ingress sync0              fed by arm_toggle_reg (persistent toggle).
#    Each destination must be exactly one cell and must have its second stage,
#    and the exception is a bounded max delay, not a false path.
# ---------------------------------------------------------------------------
set sc7f0_ov_sync_dst {}
set sc7f0_ov_sync_src {}
foreach {sc7f0_ov_n sc7f0_ov_src_pat sc7f0_ov_dst_pat sc7f0_ov_next_pat} {
    epoch  {.*u_pcie_ip/inst/user_(reset|lnk_up)_reg.*} {.*u_overlay_writer/epoch_sync_l_reg\[0\]$}  {.*u_overlay_writer/epoch_sync_l_reg\[1\]$}
    poison {.*u_overlay_writer/debt_poison_epoch_reg}  {.*u_overlay_writer/poison_sync_reg\[0\]$}   {.*u_overlay_writer/poison_sync_reg\[1\]$}
    arm    {.*u_overlay_ingress/arm_toggle_reg}        {.*u_overlay_ingress/sync0_reg$}              {.*u_overlay_ingress/sync1_reg$}
} {
    set sc7f0_ov_src [get_cells -quiet -hier -regexp $sc7f0_ov_src_pat]
    set sc7f0_ov_dst [get_cells -quiet -hier -regexp $sc7f0_ov_dst_pat]
    set sc7f0_ov_nxt [get_cells -quiet -hier -regexp $sc7f0_ov_next_pat]
    if {[llength $sc7f0_ov_src] < 1} {
        error "SC7F0_OVERLAY_SYNC_NO_SOURCE $sc7f0_ov_n: $sc7f0_ov_src_pat matched no source register. An empty -from with set_max_delay -datapath_only is rejected by the tool ([Constraints 18-540], measured in rgb-fullimpl-26111334 logs/build_full26111334.log), and silently dropping it would make the exception cover every startpoint in the device instead of the named crossing."
    }
    if {[llength $sc7f0_ov_dst] != 1} {
        error "SC7F0_OVERLAY_SYNC_MISSING $sc7f0_ov_n: $sc7f0_ov_dst_pat matched [llength $sc7f0_ov_dst] cells, expected exactly 1 first-stage FF"
    }
    if {[llength $sc7f0_ov_nxt] != 1} {
        error "SC7F0_OVERLAY_SYNC_NO_SECOND_STAGE $sc7f0_ov_n: $sc7f0_ov_next_pat matched [llength $sc7f0_ov_nxt] cells, expected exactly 1; a bounded max delay in front of a lone FF is not a synchroniser"
    }
    # Named source -> named first stage, one exception per crossing.  Vivado
    # rejects set_max_delay -datapath_only without a non-empty -from, and a
    # -from <clock> form would widen the exception to every path leaving that
    # clock, so the source registers are resolved and guarded here.
    #
    # The -from set has to be the FIRST STAGE'S WHOLE ASYNC FAN-IN, not one
    # convenient launch register.  Round rgb-fullimpl-26111335 proved why: it
    # declared only u_pcie_ip/inst/user_reset_reg, and the routed design still
    # reported the worst path of the whole round from a second launch of the same
    # asynchronous condition -
    #   u_pcie_ip/inst/user_lnk_up_reg_replica/C -> u_overlay_writer/epoch_sync_l_reg[0]/D
    #   requirement 0.337 ns, data 1.439 ns (1 LUT), WNS -0.909
    #   (proj_full26111335/.../zu4ev_pcie_card_top_timing_summary_postroute_physopted.rpt:42006)
    # because rtl/zu4ev_pcie_card_top.v forms the writer epoch reset from BOTH PCIe
    # core signals (link up and user reset) and phys_opt replicates either of them.
    # So the launch set below is enumerated from the fan-in of the first stage's own
    # D pin and compared against what the pattern resolved; a launch that is not
    # covered stops the run instead of surfacing as a negative WNS an hour later.
    set sc7f0_ov_dpin [get_pins -quiet [list [get_property NAME $sc7f0_ov_dst]/D]]
    if {[llength $sc7f0_ov_dpin] != 1} {
        error "SC7F0_OVERLAY_SYNC_NO_D_PIN $sc7f0_ov_n: [list [get_property NAME $sc7f0_ov_dst]/D] resolved to [llength $sc7f0_ov_dpin] pins, expected exactly 1; without the D pin the fan-in cannot be enumerated."
    }
    if {[catch {all_fanin -flat -startpoints_only -only_cells $sc7f0_ov_dpin} sc7f0_ov_fan]} {
        error "SC7F0_OVERLAY_SYNC_FANIN_FAILED $sc7f0_ov_n: all_fanin on the first-stage D pin: $sc7f0_ov_fan"
    }
    set sc7f0_ov_launches [sc7f0_ov_launch_names $sc7f0_ov_fan $sc7f0_ov_n]
    if {[llength $sc7f0_ov_launches] == 0} {
        error "SC7F0_OVERLAY_SYNC_NO_LAUNCH $sc7f0_ov_n: all_fanin returned [llength $sc7f0_ov_fan] raw object(s) resolving to 0 launch cells. An empty launch set is not a covered first stage."
    }
    set sc7f0_ov_covered 0
    set sc7f0_ov_uncovered {}
    foreach sc7f0_ov_l $sc7f0_ov_launches {
        if {$sc7f0_ov_l eq ""} {continue}
        set sc7f0_ov_hit 0
        foreach sc7f0_ov_s $sc7f0_ov_src {
            if {[string equal $sc7f0_ov_l [get_property NAME $sc7f0_ov_s]]} {set sc7f0_ov_hit 1}
        }
        if {$sc7f0_ov_hit} {incr sc7f0_ov_covered} else {lappend sc7f0_ov_uncovered $sc7f0_ov_l}
    }
    if {[llength $sc7f0_ov_uncovered] > 0} {
        error "SC7F0_OVERLAY_SYNC_FANIN_NOT_COVERED $sc7f0_ov_n: the first stage is also launched by [join $sc7f0_ov_uncovered {, }], which $sc7f0_ov_src_pat does not resolve. Declaring the bound from one launch and reading back 3.333 ns on that one path says nothing about the other launches; either the pattern must name them or this is not the reviewed two-register asynchronous condition."
    }
    set sc7f0_ov_md3 [set_max_delay -datapath_only $sc7f0_ov_period -from $sc7f0_ov_src -to $sc7f0_ov_dst]
    puts "SC7F0_OVERLAY_CDC_APPLIED sync $sc7f0_ov_n from=[llength $sc7f0_ov_src] fanin_launches=[llength $sc7f0_ov_launches] covered=$sc7f0_ov_covered to=[llength $sc7f0_ov_dst]: set_max_delay -datapath_only $sc7f0_ov_period -from <[join [lsort [sc7f0_ov_names $sc7f0_ov_src]] {, }]> -to [get_property NAME $sc7f0_ov_dst] (second stage [get_property NAME $sc7f0_ov_nxt])"
    lappend sc7f0_ov_sync_dst $sc7f0_ov_dst
    lappend sc7f0_ov_sync_src $sc7f0_ov_src

    # ---- 2b. ASYNC_REG on the two stages of the two unannotated chains ------
    # Guards run BEFORE the property is written, and the written value is read
    # back through a normalised boolean.  Everything here fails closed: a missing
    # cell, a duplicate match, a non-register, a foreign capture domain, an
    # unqueryable property or a read-back that is not true stops the run in this
    # pre-opt hook instead of surfacing as a CDC-2 row an hour later.
    if {[lsearch -exact $sc7f0_ov_areg_targets $sc7f0_ov_n] < 0} {
        puts "SC7F0_OVERLAY_SYNC_ASYNC_REG_SCOPE_SKIP $sc7f0_ov_n: not an ASYNC_REG target of this round (epoch_sync_l is annotated in RTL and must stay untouched; only poison and arm need the attribute)"
        continue
    }
    set sc7f0_ov_areg [concat $sc7f0_ov_dst $sc7f0_ov_nxt]
    if {[llength $sc7f0_ov_areg] != 2} {
        error "SC7F0_OVERLAY_SYNC_ASYNC_REG_SCOPE $sc7f0_ov_n: first stage + second stage resolved to [llength $sc7f0_ov_areg] cells, expected exactly 2. Refusing to write ASYNC_REG over a collection that is not precisely this chain's two flops."
    }
    # The source owner: every launch enumerated from the first stage's D pin must
    # really be a register in the declared 125 MHz source domain.  Annotating a
    # flop whose data cone is not the reviewed crossing would co-locate the wrong
    # pair.
    set sc7f0_ov_src_rows {}
    foreach sc7f0_ov_l [sc7f0_ov_launch_objs $sc7f0_ov_fan $sc7f0_ov_n] {
        set sc7f0_ov_ln [get_property NAME $sc7f0_ov_l]
        if {[catch {get_property REF_NAME $sc7f0_ov_l} sc7f0_ov_lref]} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_SOURCE_UNQUERYABLE $sc7f0_ov_n: REF_NAME of launch $sc7f0_ov_ln could not be read, so the source owner of the chain cannot be verified."
        }
        if {![sc7f0_ov_sequential $sc7f0_ov_lref]} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_SOURCE_NOT_A_REGISTER $sc7f0_ov_n: launch $sc7f0_ov_ln has REF_NAME $sc7f0_ov_lref, which is not a register family."
        }
        set sc7f0_ov_lclk [sc7f0_ov_clk_text $sc7f0_ov_l]
        if {$sc7f0_ov_lclk ne "pcie_user_clk"} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_SOURCE_DOMAIN $sc7f0_ov_n: launch $sc7f0_ov_ln\[$sc7f0_ov_lref\] is captured by '$sc7f0_ov_lclk', expected pcie_user_clk (the declared 125 MHz source of this crossing)."
        }
        lappend sc7f0_ov_src_rows "$sc7f0_ov_ln\[ref=$sc7f0_ov_lref clk=$sc7f0_ov_lclk\]"
    }
    if {[llength $sc7f0_ov_src_rows] == 0} {
        error "SC7F0_OVERLAY_SYNC_ASYNC_REG_NO_SOURCE_OWNER $sc7f0_ov_n: the first stage's D pin enumerated no source register at all."
    }
    set sc7f0_ov_areg_rows {}
    foreach sc7f0_ov_c $sc7f0_ov_areg {
        set sc7f0_ov_cn [get_property NAME $sc7f0_ov_c]
        if {[catch {get_property REF_NAME $sc7f0_ov_c} sc7f0_ov_cref]} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_GUARD_FAILED $sc7f0_ov_n: REF_NAME of $sc7f0_ov_cn is unqueryable, so the cell cannot be shown to be a flip-flop before ASYNC_REG is written on it."
        }
        if {![sc7f0_ov_sequential $sc7f0_ov_cref]} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_NOT_A_FF $sc7f0_ov_n: $sc7f0_ov_cn has REF_NAME $sc7f0_ov_cref; ASYNC_REG on a non flip-flop is a fabricated annotation, not a synchroniser."
        }
        if {[catch {get_pins -quiet -of $sc7f0_ov_c -filter {NAME =~ */D}} sc7f0_ov_cd]} {set sc7f0_ov_cd ""}
        if {[llength $sc7f0_ov_cd] != 1} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_NO_D_PIN $sc7f0_ov_n: $sc7f0_ov_cn resolves to [llength $sc7f0_ov_cd] D pins, expected exactly 1, so it is not the data-capturing flop this attribute was scoped for."
        }
        if {[catch {get_pins -quiet -of $sc7f0_ov_c -filter {NAME =~ */Q}} sc7f0_ov_cq]} {set sc7f0_ov_cq ""}
        if {[llength $sc7f0_ov_cq] != 1} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_NO_Q_PIN $sc7f0_ov_n: $sc7f0_ov_cn resolves to [llength $sc7f0_ov_cq] Q pins, expected exactly 1."
        }
        set sc7f0_ov_cclk [sc7f0_ov_clk_text $sc7f0_ov_c]
        if {$sc7f0_ov_cclk ni {capture_clk_300m ovl_wr_clk_250m}} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_DEST_DOMAIN $sc7f0_ov_n: $sc7f0_ov_cn\[$sc7f0_ov_cref\] is captured by '$sc7f0_ov_cclk', expected capture_clk_300m or ovl_wr_clk_250m."
        }
        array set sc7f0_ov_before [sc7f0_ov_bool ASYNC_REG $sc7f0_ov_c]
        if {$sc7f0_ov_before(state) eq "bad"} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_PREQUERY_FAILED $sc7f0_ov_n: $sc7f0_ov_cn answered '$sc7f0_ov_before(value)' for ASYNC_REG before the write; an unqueryable property is not a writable one."
        }
        set sc7f0_ov_pre_raw $sc7f0_ov_before(value)
        if {[catch {set_property ASYNC_REG TRUE $sc7f0_ov_c} sc7f0_ov_werr]} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_WRITE_FAILED $sc7f0_ov_n: set_property on $sc7f0_ov_cn: $sc7f0_ov_werr"
        }
        array set sc7f0_ov_after [sc7f0_ov_bool ASYNC_REG $sc7f0_ov_c]
        if {$sc7f0_ov_after(state) eq "bad"} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_READBACK_UNQUERYABLE $sc7f0_ov_n: $sc7f0_ov_cn answered '$sc7f0_ov_after(value)' for ASYNC_REG after the write."
        }
        if {$sc7f0_ov_after(state) ne "true"} {
            error "SC7F0_OVERLAY_SYNC_ASYNC_REG_NOT_APPLIED $sc7f0_ov_n: $sc7f0_ov_cn reads back ASYNC_REG=$sc7f0_ov_after(value), not true."
        }
        lappend sc7f0_ov_areg_rows "$sc7f0_ov_cn\[ref=$sc7f0_ov_cref clk=$sc7f0_ov_cclk D=1 Q=1 async_reg_before=$sc7f0_ov_pre_raw async_reg_readback=$sc7f0_ov_after(value)\]"
        incr sc7f0_ov_areg_cell_total
    }
    incr sc7f0_ov_areg_chain_total
    puts "SC7F0_OVERLAY_SYNC_ASYNC_REG_APPLIED $sc7f0_ov_n cells=[llength $sc7f0_ov_areg] sources=\([join $sc7f0_ov_src_rows {; }]\]) stages=\([join $sc7f0_ov_areg_rows {; }]\])"
}

# The scope of the annotation is a closed number: two chains, two stages each.
# If opt's own netlist ever stops answering with exactly those four cells, this
# hook stops the run instead of annotating a partial set and reporting green.
if {$sc7f0_ov_areg_chain_total != 2 || $sc7f0_ov_areg_cell_total != 4} {
    error "SC7F0_OVERLAY_SYNC_ASYNC_REG_INCOMPLETE: annotated $sc7f0_ov_areg_cell_total cell(s) in $sc7f0_ov_areg_chain_total chain(s), expected 4 cells in 2 chains (poison_sync_reg\[0\], poison_sync_reg\[1\], sync0_reg, sync1_reg)."
}
puts "SC7F0_OVERLAY_SYNC_ASYNC_REG_PASS chains=$sc7f0_ov_areg_chain_total cells=$sc7f0_ov_areg_cell_total scope=poison_sync_reg\[0\],poison_sync_reg\[1\],sync0_reg,sync1_reg epoch_sync_l=untouched_already_annotated launch_and_datapath=untouched"


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 3. Prove the engine took them, before spending an hour placing - and prove it for
#    EVERY launch into each first stage, not for the one launch that was convenient
#    to name.  Measured reason (round rgb-fullimpl-26111335, same RTL, this hook
#    active, only u_pcie_ip/inst/user_reset_reg declared): the round still failed at
#    WNS -0.909 from
#      u_pcie_ip/inst/user_lnk_up_reg_replica/C -> u_overlay_writer/epoch_sync_l_reg[0]/D
#      requirement 0.337 ns, data 1.439 ns (1 LUT)
#    because rtl/zu4ev_pcie_card_top.v forms the writer epoch condition from two
#    PCIe-core signals and phys_opt replicates them.  A readback taken from a
#    selected -from cannot see an undeclared second launch; a readback over all
#    endpoints of the first stage can, so this loop asks for paths -to the first
#    stage with no -from at all.
# ---------------------------------------------------------------------------
foreach {sc7f0_ov_n sc7f0_ov_dst_pat} {
    epoch  {.*u_overlay_writer/epoch_sync_l_reg\[0\]$}
    poison {.*u_overlay_writer/poison_sync_reg\[0\]$}
    arm    {.*u_overlay_ingress/sync0_reg$}
} {
    set sc7f0_ov_d [get_cells -quiet -hier -regexp $sc7f0_ov_dst_pat]
    if {[llength $sc7f0_ov_d] != 1} {
        error "SC7F0_OVERLAY_SYNC_VERIFY_MISSING $sc7f0_ov_n: $sc7f0_ov_dst_pat matched [llength $sc7f0_ov_d] cells"
    }
    set sc7f0_ov_p [get_timing_paths -to [get_pins "[get_property NAME $sc7f0_ov_d]/D"] -delay_type max -max_paths 64 -nworst 4]
    if {[llength $sc7f0_ov_p] == 0} {
        error "SC7F0_OVERLAY_SYNC_NOT_APPLIED $sc7f0_ov_n: no timed path at all reaches [get_property NAME $sc7f0_ov_d]/D; a bounded max delay that leaves no path is a swallowed or falsely-pathed crossing."
    }
    set sc7f0_ov_bad {}
    set sc7f0_ov_launches {}
    foreach sc7f0_ov_path $sc7f0_ov_p {
        set sc7f0_ov_req [get_property REQUIREMENT $sc7f0_ov_path]
        set sc7f0_ov_sp [get_property STARTPOINT_PIN $sc7f0_ov_path]
        lappend sc7f0_ov_launches $sc7f0_ov_sp
        if {$sc7f0_ov_req eq "" || [expr {abs(double($sc7f0_ov_req) - $sc7f0_ov_period) > 0.001}]} {
            lappend sc7f0_ov_bad "$sc7f0_ov_sp req=$sc7f0_ov_req"
        }
    }
    if {[llength $sc7f0_ov_bad] > 0} {
        error "SC7F0_OVERLAY_SYNC_NOT_APPLIED $sc7f0_ov_n: [llength $sc7f0_ov_bad] of [llength $sc7f0_ov_p] launches into the first stage are not at $sc7f0_ov_period ns - [join [lsort -unique $sc7f0_ov_bad] {; }]. 0.337 means that launch was never declared; a bound measured from one launch does not cover the first stage."
    }
    puts "SC7F0_OVERLAY_SYNC_APPLIED $sc7f0_ov_n: requirement $sc7f0_ov_period ns on all [llength $sc7f0_ov_p] launches into [get_property NAME $sc7f0_ov_d]/D from [join [lsort -unique $sc7f0_ov_launches] {, }]"
}
puts "SC7F0_OVERLAY_CDC_APPLY_PASS max_delay_ns=$sc7f0_ov_period gray_crossings=3 sync_endpoints=3"
