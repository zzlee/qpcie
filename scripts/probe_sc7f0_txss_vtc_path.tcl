# Probe the DEPLOYED netlist of 26111602 for the HDMI TX VTC control path.
#
# Purpose: settle, on the netlist that is actually in the flashed bitstream,
# which level of
#   PS HPM1 -> u_hdmi_control (axi_crossbar_hdmi, M10 = 0xB0030000/16b)
#            -> u_hdmi_tx_ctl_merge (sc7f0_axil_merge_2to1, S1)
#            -> u_hdmi_tx_ss/S_AXI_CPU_IN (17-bit, bit16 = slice index)
#            -> inst/axi_crossbar -> inst/v_tc
# refuses the access that takes a synchronous external abort on silicon.
#
# Usage:
#   vivado -mode batch -nojournal -log <out>.log -source \
#       scripts/probe_sc7f0_txss_vtc_path.tcl -- -dcp <routed.dcp> -out <dir>
#
# Names are looked up by regex because opt_design/phys_opt absorb the crossbar's
# `inst` level and rename nets; every lookup prints NO_CELL/NO_PIN/NO_NET
# instead of aborting, so an absent connection is visible as its own row.

proc arg_of {name default} {
    global argv
    if {![info exists argv]} { return $default }
    set i [lsearch -exact $argv $name]
    if {$i >= 0 && [expr {$i + 1}] < [llength $argv]} { return [lindex $argv [expr {$i + 1}]] }
    return $default
}

set dcp [arg_of -dcp ""]
set out [arg_of -out .]
if {$dcp eq ""} { error "give -dcp <dcp>" }
file mkdir $out
set rpt [open [file join $out vtc-path-probe.txt] w]

proc say {msg} { global rpt; puts $msg; flush $rpt; puts $rpt $msg; flush $rpt }

say "== probe of $dcp"
open_checkpoint $dcp

proc cell_names {re} {
    set c [get_cells -quiet -hier -regexp $re]
    if {$c eq ""} { return {} }
    return [get_property NAME $c]
}

# For <cell>/<port>, print the connected net, and the other endpoints of that
# net, so a missing connection shows up as NO_NET (the 26111601 write-channel
# defect had exactly that signature).
proc who {pin {label ""} {max 6}} {
    set p [get_pins -quiet $pin]
    if {$p eq ""} { say [format "  %-52s NO_PIN   %s" $pin $label]; return }
    set n [get_nets -quiet -of $p]
    if {$n eq ""} { say [format "  %-52s NO_NET   %s" $pin $label]; return }
    set others {}
    foreach q [get_pins -quiet -of $n] { if {$q ne $p} { lappend others $q } }
    say [format "  %-52s net=%-26s ends=%-3d %s" $pin $n [llength $others] [join [lrange $others 0 [expr {$max - 1}]] { | }]]
    if {[llength $others] >= $max} { say [format "  %-52s    ... %d more" "" [expr {[llength $others] - $max}]] }
}

say "== candidate cells"
foreach re {^u_hdmi_control$ ^u_hdmi_tx_ctl_merge$ axil_merge ^u_hdmi_tx_ss$
            ^u_hdmi_tx_ss/inst/axi_crossbar.* ^u_hdmi_tx_ss/inst/v_tc.*} {
    set c [cell_names $re]
    if {[llength $c] == 0} {
        say [format "  %-42s NO_CELL" $re]
    } else {
        say [format "  %-42s %s" $re [join [lrange $c 0 4] {, }]]
    }
}

set merge ""
foreach n [cell_names {^u_hdmi_tx_ctl_merge$}] { set merge $n; break }
if {$merge eq ""} { foreach n [cell_names {hdmi_tx_ctl_merge}] { set merge $n; break } }
if {$merge eq ""} { foreach n [cell_names {axil_merge}] { set merge $n; break } }
if {$merge eq ""} { set merge NONE }
say "== merge cell resolved: $merge"

if {$merge ne ""} {
    say "== merge $merge : S1 = the 0xB0030000 half (toward the crossbar)"
    foreach {port label} {
        s1_axil_araddr  "S1 araddr  (M10 field bits 15:0)"
        s1_axil_arvalid "S1 arvalid"
        s1_axil_arready "S1 arready"
        s1_axil_awaddr  "S1 awaddr"
        s1_axil_awvalid "S1 awvalid"
        s1_axil_rresp   "S1 rresp   (DECERR lands here)"
        s1_axil_rvalid  "S1 rvalid"
        s0_axil_arvalid "S0 arvalid (0xB0020000 half)"
    } { who "$merge/$port" $label }

    say "== merge $merge : merged M port (toward the subsystem)"
    foreach {port label} {
        m_axil_araddr  "M araddr, 17-bit: bit16 = slice index"
        m_axil_arvalid "M arvalid"
        m_axil_arready "M arready"
        m_axil_awaddr  "M awaddr"
        m_axil_awvalid "M awvalid"
        m_axil_rresp   "M rresp (from the subsystem)"
    } { who "$merge/$port" $label }

    say "== merge $merge : every port, for completeness"
    foreach p [get_pins -quiet -of [get_cells -quiet $merge]] {
        who "$p" "" 3
    }
}

say "== outer crossbar flattened M address fields"
foreach k {320 321 335 64 67 80} { who "u_hdmi_control/m_axi_araddr\[$k\]" "araddr bit $k (M10:320-351 M02:64-95)" }
foreach k {2 10} {
    who "u_hdmi_control/m_axi_arvalid\[$k\]" "M\[$k\] arvalid"
    who "u_hdmi_control/m_axi_arready\[$k\]" "M\[$k\] arready"
    who "u_hdmi_control/m_axi_rresp\[$k\]"   "M\[$k\] rresp (whole field if flat)"
}

say "== subsystem control port"
foreach k {0 8 15 16} {
    who "u_hdmi_tx_ss/S_AXI_CPU_IN_araddr\[$k\]" "tx ss araddr\[$k\]"
    who "u_hdmi_tx_ss/S_AXI_CPU_IN_awaddr\[$k\]" "tx ss awaddr\[$k\]"
}
foreach p {S_AXI_CPU_IN_arvalid S_AXI_CPU_IN_arready S_AXI_CPU_IN_rvalid S_AXI_CPU_IN_rresp} {
    who "u_hdmi_tx_ss/$p" "tx ss $p"
}

say "== inside the subsystem"
set inner ""
foreach n [cell_names {^u_hdmi_tx_ss/inst/axi_crossbar}] { set inner $n; break }
if {$inner eq ""} { set inner NONE }
say "  inner crossbar cell: $inner"
if {$inner ne ""} {
    foreach k {0 8 16} { who "$inner/s_axi_araddr\[$k\]" "inner s_axi_araddr\[$k\]" 8 }
    who "$inner/m_axi_arvalid" "inner m_axi_arvalid" 8
    who "$inner/m_axi_rresp"   "inner m_axi_rresp"   8
}
set vtc ""
foreach n [cell_names {^u_hdmi_tx_ss/inst/v_tc}] { set vtc $n; break }
if {$vtc eq ""} { set vtc NONE }
say "  v_tc cell: $vtc"
if {$vtc ne ""} {
    foreach k {0 8} { who "$vtc/s_axi_araddr\[$k\]" "v_tc araddr\[$k\]" 8 }
    foreach p {s_axi_arvalid s_axi_arready s_axi_rvalid s_axi_rresp s_axi_awvalid} {
        who "$vtc/$p" "v_tc $p" 8
    }
}

close $rpt
say "SC7F0_VTC_PATH_PROBE_DONE"
puts "SC7F0_VTC_PATH_PROBE_DONE"
