# =============================================================================
# scripts/tests/fixtures/overlay_gray_stub.tcl
#
# NONPHYSICAL fixture: run scripts/check_sc7f0_overlay_gray.tcl against a stubbed
# Vivado object resolver, under tclsh, with no project, no design and no route.
#
#   usage: tclsh scripts/tests/fixtures/overlay_gray_stub.tcl <mode> <check-script>
#
# A PASS from this file is NOT routed coverage and must never be presented as such.
# Its whole purpose is the negative direction: the routed check must refuse to pass
# when the named exception is absent, when a looser exception (the vendor's 1000 ns
# fallback) is what is really in force, when the sampling path is not a direct FF to
# FF, when an endpoint is not timed, when the bit mapping is not one to one, or when
# report_bus_skew has no row for the constraint.  Those are the ways a real named
# constraint quietly stops meaning anything.
# =============================================================================
if {$argc < 2} {
    puts "usage: overlay_gray_stub.tcl <mode> <check-script>"
    exit 2
}
set mode [lindex $argv 0]
set check [lindex $argv 1]

proc get_cells {args} {
    set pat ""
    foreach a $args { if {$a eq "-regexp"} {set nxt 1; continue}
                      if {[info exists nxt]} {set pat $a; unset nxt} }
    if {![regexp {u_overlay_writer/(u_[a-z]+)/(src_gray_ff|dest_graysync_ff)} $pat -> inst kind]} {
        return {}
    }
    set n 32
    if {$::mode eq {missing_src} && $inst eq {u_beats}} { set n 31 }
    if {$::mode eq {missing_dst} && $inst eq {u_errf} && $kind ne {src_gray_ff}} { set n 31 }
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        if {$kind eq {src_gray_ff}} {
            lappend out "u_top/u_overlay_writer/$inst/src_gray_ff_reg\[$i\]"
        } else {
            lappend out "u_top/u_overlay_writer/$inst/dest_graysync_ff_reg\[0\]\[$i\]"
        }
    }
    return $out
}

proc get_timing_paths {args} {
    set from {}
    set want 32
    for {set i 0} {$i < [llength $args]} {incr i} {
        switch -- [lindex $args $i] {
            -from  { set from [lindex $args [expr {$i + 1}]] }
            -max_paths { set want [lindex $args [expr {$i + 1}]] }
        }
    }
    if {[llength $from] == 0} { return {} }
    if {$::mode eq {not_timed}} { set want 31 }
    set out {}
    for {set i 0} {$i < $want} {incr i} { lappend out "path:$i" }
    return $out
}

proc get_property {prop obj} {
    switch -- $prop {
        STARTPOINT_PIN {
            set bit [string range $obj 5 end]
            return "u_top/u_overlay_writer/u_frames/src_gray_ff_reg\[$bit\]/C"
        }
        ENDPOINT_PIN {
            set bit [string range $obj 5 end]
            if {$::mode eq {swapped}} { set bit [expr {($bit + 1) % 32}] }
            return "u_top/u_overlay_writer/u_frames/dest_graysync_ff_reg\[0\]\[$bit\]/D"
        }
        LOGIC_LEVELS { return [expr {$::mode eq {logic} ? 2 : 0}] }
        REQUIREMENT  {
            if {$::mode eq {fallback_req}} { return 1000.000 }
            return 3.333
        }
    }
    return ""
}

proc report_bus_skew {args} {
    if {$::mode eq {no_skew_row}} {
        return "Bus Skew Report\n  no constraints matched\n"
    }
    set t ""
    append t "Bus Skew Report\n"
    foreach inst {u_frames u_beats u_errf} {
        append t "  Fast Skew Path  u_top/u_overlay_writer/$inst/src_gray_ff_reg\[0\]/C  u_top/u_overlay_writer/$inst/dest_graysync_ff_reg\[0\]\[0\]/D  0.412  0.118  2.921\n"
    }
    if {$::mode eq {skew_violated}} {
        append t "  VIOLATED  u_top/u_overlay_writer/u_errf/src_gray_ff_reg\[7\]/C  met 0.000\n"
    }
    return $t
}

# a stub that could not fail is not a test: assert the fixture is wired at all
if {[catch {source $check} msg]} {
    puts "STUB_VERDICT=ERRORED mode=$mode msg=$msg"
    exit 0
}
puts "STUB_VERDICT=PASS mode=$mode"
