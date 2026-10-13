create_project qpcie_ddr_readback_sim /tmp/opencode/qpcie_ddr_readback_sim -part xczu4ev-fbvb900-2-e -force
add_files -fileset sim_1 ./rtl/zu4ev_ddr_readback.v ./tb/zu4ev_ddr_readback_tb.sv
set_property top zu4ev_ddr_readback_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 5 us
exit
