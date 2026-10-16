create_project sc7f0_hdmi_control /tmp/opencode/sc7f0_hdmi_control -part xczu4ev-fbvb900-2-e -force
source ./scripts/create_sc7f0_hdmi_crossbar.tcl
create_sc7f0_hdmi_crossbar
add_files ./rtl/qpcie_debug_mailbox.v
add_files -fileset sim_1 ./tb/sc7f0_hdmi_control_tb.sv
set_property top sc7f0_hdmi_control_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 200us [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
if {[get_value -radix unsigned /sc7f0_hdmi_control_tb/test_passed] ne "1"} {
    error "HDMI control TB did not reach PASS"
}
exit 0
