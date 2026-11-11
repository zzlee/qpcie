# Read-only post-route evidence for R7. No constraints/waivers/bit/XSA changes.
# argv: checkpoint, NEW output directory, reset-target pin list.
if {$argc != 3} {error "checkpoint output targets required"}
lassign $argv checkpoint out targets_file
if {[file exists $out]} {error "Refusing existing evidence output"}
file mkdir $out
open_checkpoint $checkpoint
report_drc -file $out/drc.rpt
set f [open $targets_file r];set targets [split [read $f] \n];close $f
set report [open $out/netlist.tsv w]
puts $report [join [list CHECKPOINT [file normalize $checkpoint] [lindex [exec sha256sum $checkpoint] 0]] \t]
set visited [dict create]
proc physical_net {pin} {
    set nets [get_nets -quiet -segments -of_objects [get_pins -quiet $pin]]
    if {![llength $nets]} {error "No net on $pin"}
    return [lindex [lsort [get_property NAME $nets]] 0]
}
proc export_net {net} {
    global report visited
    if {[dict exists $visited $net]} {return}
    dict set visited $net 1
    set segments [get_nets -quiet -segments $net]
    set pins [get_pins -quiet -of_objects $segments -filter {DIRECTION == OUT}]
    set drivers {}
    foreach p $pins {
        set owner [get_cells -quiet -of_objects $p]
        if {[llength $owner] && [get_property IS_PRIMITIVE $owner]} {lappend drivers $p}
    }
    set drivers [lsort -unique $drivers]
    if {[llength $drivers] != 1} {error "Expected one primitive driver of $net: $drivers"}
    set pin [lindex $drivers 0]
    set cell [get_cells -of_objects [get_pins $pin]]
    set ref [get_property REF_NAME $cell]
    if {$ref eq "GND" || $ref eq "VCC"} {
        puts $report [join [list CONST $net $ref] \t]
    } elseif {[regexp {^LUT([1-6])$} $ref unused width]} {
        set inputs {}
        for {set i 0} {$i < $width} {incr i} {lappend inputs [physical_net $cell/I$i]}
        puts $report [join [concat [list LUT $net $ref [get_property INIT $cell]] $inputs] \t]
        foreach input $inputs {export_net $input}
    } elseif {$ref in {FDRE FDPE FDCE FDSE}} {
        puts $report [join [list TERM $net $pin $ref] \t]
    } else {error "Unreviewed reset logic primitive: $pin $ref"}
}
set count 0
foreach target $targets {
    if {$target eq ""} {continue}
    set prefix [file dirname [file dirname $target]]
    set preset [physical_net $target]
    set clock [physical_net $prefix/arststages_ff_reg\[0\]/C]
    if {[llength [get_cells -quiet ${prefix}/arststages_ff_reg*]] != 4} {error "Not four stages: $prefix"}
    puts $report [join [list RESET $target $preset $clock] \t]
    for {set bit 0} {$bit < 4} {incr bit} {
        set name [format {%s/arststages_ff_reg[%d]} $prefix $bit]
        set cell [get_cells -quiet $name]
        if {[llength $cell] != 1} {error "Missing reset stage $name"}
        set async [get_property ASYNC_REG $cell]
        if {[get_property REF_NAME $cell] ne "FDPE" || ![string is boolean -strict $async] || !$async} {error "Bad synchronizer stage $name"}
        if {[physical_net $name/PRE] ne $preset || [physical_net $name/C] ne $clock} {error "Mixed preset/clock $name"}
        set d [physical_net $name/D];set ce [physical_net $name/CE]
        export_net $d;export_net $ce
        if {$bit > 0 && $d ne [physical_net [format {%s/arststages_ff_reg[%d]/Q} $prefix [expr {$bit-1}]]]} {error "Non-direct release $name"}
        puts $report [join [list STAGE $target $bit $d $ce] \t]
    }
    export_net $preset
    incr count
}
# Diagnostic pin levels may reach CSR readback only, never a DMA/control FSM.
for {set bit 25} {$bit <= 31} {incr bit} {
    for {set stage 0} {$stage < 3} {incr stage} {
        set name [format {u_hdmi_probe/u_pin_levels_cdc/syncstages_ff_reg[%d][%d]} $stage $bit]
        set cell [get_cells -quiet $name]
        set async [get_property ASYNC_REG $cell]
        if {[llength $cell] != 1 || [get_property REF_NAME $cell] ne "FDRE" || ![string is boolean -strict $async] || !$async} {error "Missing diagnostic sync $name"}
        if {$stage > 0 && [physical_net $name/D] ne [physical_net [format {u_hdmi_probe/u_pin_levels_cdc/syncstages_ff_reg[%d][%d]/Q} [expr {$stage-1}] $bit]]} {error "Diagnostic sync not direct $name"}
    }
    set q [format {u_hdmi_probe/u_pin_levels_cdc/syncstages_ff_reg[2][%d]/Q} $bit]
    set endpoints [all_fanout -flat -endpoints_only -from [get_pins $q]]
    if {![llength $endpoints]} {error "Missing diagnostic readback fanout $bit"}
    foreach endpoint $endpoints {puts $report [join [list PROBE $bit $endpoint] \t]}
}
foreach name {hdmi_rx_5v_det hdmi_rx_ddc_scl hdmi_rx_ddc_sda hdmi_tx_ddc_scl hdmi_tx_ddc_sda hdmi_tx_hpd_in hdmi_tx_refclk_rdy hdmi_rx_hpd_out hdmi_tx_tmds_clk_p user_led_dma_active user_led_pcie_link_up} {
    set port [get_ports -quiet $name]
    if {[llength $port] != 1} {error "Missing reviewed physical port $name"}
    puts $report [join [list PORT $name [get_property DIRECTION $port] [get_property PACKAGE_PIN $port] [get_property IOSTANDARD $port]] \t]
}
puts $report "END\t$count"
close $report
puts "SC7F0_R7_FULL_EVIDENCE_EXPORTED $count reset roots; no signoff/waiver/export"
close_design
exit 0
