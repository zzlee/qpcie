# Elaborate the new PS control BD without touching either production project.
create_project -in_memory -part xczu4ev-fbvb900-2-e -dir /tmp/opencode/sc7f0-hdmi/bd-check
source ./scripts/create_zu4ev_ps_bd.tcl
create_zu4ev_ps_bd 1
puts "HDMI_BD_PASS: [get_bd_addr_segs zynq_ultra_ps_e_0/Data/SEG_M_AXI_HDMI_Reg]"
close_project
exit 0
