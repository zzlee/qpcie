# NONPHYSICAL fixture.  It drives constraints/sc7f0_overlay_gray.xdc through a stub
# Vivado object resolver so the file's preflight guard can be exercised without any
# implementation run.  A PASS here is explicitly NOT routed coverage and must never be
# presented as a named-exception result: it only shows that the XDC applies its
# exception when, and only when, the named endpoints exist.
#
# What the guard is for: an empty -from/-to collection is not an absent constraint, it
# is the exception applied over EVERY endpoint of the device.  The modes below are
# therefore about refusing to apply, not about timing.
proc usage {} {
    puts stderr "usage: tclsh overlay_gray_xdc_stub.tcl <good|empty|short|union_only> <xdc>"
    exit 2
}
if {[llength $argv] < 2} usage
set mode [lindex $argv 0]
set xdc  [lindex $argv 1]

array set ::cnt {}
proc count_for {pat} {
    if {[string match "*u\_(frames|beats|errf)*" $pat]} {set key union} else {set key block}
    if {[string match "*src_gray_ff_reg*" $pat]} {append key _src} else {append key _dst}
    if {![info exists ::cnt($key)]} {error "unexpected get_cells query: $pat"}
    set out {}
    for {set i 0} {$i < $::cnt($key)} {incr i} {lappend out cell_${key}_$i}
    return $out
}
proc get_cells {args} {
    set pat {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        if {[lindex $args $i] eq {-regexp}} {set pat [lindex $args [expr {$i + 1}]]}
    }
    if {$pat eq {}} {error "get_cells without -regexp is not modelled here"}
    return [count_for $pat]
}
set ::applied {}
proc set_max_delay {args} {lappend ::applied [concat [list set_max_delay] $args]}
proc set_bus_skew  {args} {lappend ::applied [concat [list set_bus_skew]  $args]}

switch -- $mode {
    good       {array set ::cnt {block_src 32 block_dst 32 union_src 96 union_dst 96}}
    empty      {array set ::cnt {block_src 0  block_dst 0  union_src 0  union_dst 0}}
    short      {array set ::cnt {block_src 31 block_dst 32 union_src 93 union_dst 96}}
    union_only {array set ::cnt {block_src 32 block_dst 32 union_src 96 union_dst 95}}
    default    usage
}

if {[catch {source $xdc} err]} {
    puts "STUB_ERROR: $err"
    puts "APPLIED [llength $::applied]"
    exit 1
}
puts "APPLIED [llength $::applied]"
foreach a $::applied {
    set kind [lindex $a 0]
    set n_from 0
    set n_to 0
    set value {}
    for {set i 1} {$i < [llength $a]} {incr i} {
        switch -- [lindex $a $i] {
            -from {set n_from [llength [lindex $a [expr {$i + 1}]]]; incr i}
            -to   {set n_to   [llength [lindex $a [expr {$i + 1}]]]; incr i}
            default {if {[string match {*[0-9]} [lindex $a $i]]} {set value [lindex $a $i]}}
        }
    }
    puts "  $kind value=$value from=$n_from to=$n_to"
}
