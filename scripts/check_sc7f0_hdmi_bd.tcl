# Elaborate without touching either production project. In-memory BD files
# still land under cwd/.srcs, so change directory before creating the project.
set root [file normalize [file join [file dirname [info script]] ..]]
set hdmi_control 1
if {$argc > 0 && [lindex $argv 0] eq "debug"} {set hdmi_control 0}
set scratch /tmp/opencode/sc7f0-hdmi/bd-check-$hdmi_control
file mkdir $scratch
cd $scratch
create_project -in_memory -part xczu4ev-fbvb900-2-e
source $root/scripts/create_zu4ev_ps_bd.tcl
create_zu4ev_ps_bd $hdmi_control
set irq_width [expr {$hdmi_control ? 3 : 1}]
if {[get_property CONFIG.PSU__NUM_F2P0__INTR__INPUTS [get_bd_cells zynq_ultra_ps_e_0]] != $irq_width ||
    [get_property LEFT [get_bd_ports pl_ps_irq0]] != $irq_width - 1 ||
    [get_property RIGHT [get_bd_ports pl_ps_irq0]] != 0} {
    error "Incorrect PS IRQ width ($irq_width required)"
}
if {$hdmi_control} {
    puts "HDMI_BD_PASS: [get_bd_addr_segs zynq_ultra_ps_e_0/Data/SEG_M_AXI_HPM1_FPD_Reg]"
    puts "M_AXI_HPM1_FPD DATA_WIDTH: [get_property CONFIG.DATA_WIDTH [get_bd_intf_ports M_AXI_HPM1_FPD]]"
} else {
    puts "DEBUG_BD_PASS: original 1-bit PS notification preserved"
}
close_project
exit 0
