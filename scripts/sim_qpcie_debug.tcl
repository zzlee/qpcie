# Run from repo root. Real production crossbar IP, no full PCIe/PS model.
create_project qpcie_debug_sim /tmp/qpcie_debug_aperture_sim -part xczu4ev-fbvb900-2-e -force
source ./scripts/create_bar0_crossbar.tcl
create_qpcie_bar0_crossbar
add_files ./rtl/qpcie_debug_mailbox.v
add_files -fileset sim_1 ./tb/qpcie_debug_aperture_tb.sv
set_property top qpcie_debug_aperture_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 1ms [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
exit
