# Throw-away probe: what does the VCU AXI side actually require, and which
# lightweight interconnect IPs / parameters does 2023.2 offer?  Read-only;
# in-memory project only.
#
#   vivado -mode batch -notrace -source scripts/probe_sc7f0_vcu_ic.tcl
set root [file normalize [file join [file dirname [file dirname [info script]]] ..]]
set root [file normalize [file join [file dirname [info script]] ..]]
file mkdir /tmp/opencode/sc7f0-vcu/probe
cd /tmp/opencode/sc7f0-vcu/probe
create_project -in_memory -part xczu4ev-fbvb900-2-e

proc dump_intf {ref} {
    if {![llength [get_bd_intf_pins -quiet $ref]]} { puts "INTF_MISSING $ref"; return }
    set p [get_bd_intf_pins $ref]
    puts "INTF $ref ([get_property MODE $p] [get_property VLNV $p])"
    foreach k [lsort [list_property $p]] {
        if {![string match "CONFIG.*" $k]} { continue }
        set v ""
        catch {set v [get_property $k $p]}
        if {$v eq "" || $v eq "<>"} { continue }
        puts "  $k = $v"
    }
}

proc dump_cfg {cell} {
    if {![llength [get_bd_cells -quiet $cell]]} { puts "CELL_MISSING $cell"; return }
    set c [get_bd_cells $cell]
    puts "CELL $cell ([get_property VLNV $c])"
    foreach k [lsort [list_property $c]] {
        if {![string match "CONFIG.*" $k]} { continue }
        set v ""
        catch {set v [get_property $k $c]}
        puts "  $k = $v"
    }
}


proc dump_intf {ref} {
    if {![llength [get_bd_intf_pins -quiet $ref]]} { puts "INTF_MISSING $ref"; return }
    set p [get_bd_intf_pins $ref]
    puts "INTF $ref ([get_property MODE $p] [get_property VLNV $p])"
    foreach k [lsort [list_property $p]] {
        if {![string match "CONFIG.*" $k]} { continue }
        set v ""
        catch {set v [get_property $k $p]}
        if {$v eq "" || $v eq "<>"} { continue }
        puts "  $k = $v"
    }
}
proc dump_cfg {cell} {
    if {![llength [get_bd_cells -quiet $cell]]} { puts "CELL_MISSING $cell"; return }
    set c [get_bd_cells $cell]
    puts "CELL $cell ([get_property VLNV $c])"
    foreach k [lsort [list_property $c]] {
        if {![string match "CONFIG.*" $k]} { continue }
        set v ""
        catch {set v [get_property $k $c]}
        puts "  $k = $v"
    }
}
create_bd_design probe2
set xbc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_crossbar:2.1 xb_probe]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $xbc
dump_cfg xb_probe
dump_intf xb_probe/S00_AXI
dump_intf xb_probe/S01_AXI
dump_intf xb_probe/M00_AXI
set xbc2 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_crossbar:2.1 xb_probe2]
dump_cfg xb_probe2
set dwc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 dw_probe]
dump_cfg dw_probe
dump_intf dw_probe/S_AXI
dump_intf dw_probe/M_AXI
set dwc2 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 dw_probe2]
catch {set_property -dict [list CONFIG.S_AXI_DATA_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {128}
                    CONFIG.S_AXI_ADDR_WIDTH {44} CONFIG.M_AXI_ADDR_WIDTH {44}] $dwc2} e
dump_cfg dw_probe2
set pic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 pc_probe]
dump_cfg pc_probe

close_project
exit 0
