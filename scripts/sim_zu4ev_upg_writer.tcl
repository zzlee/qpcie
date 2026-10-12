# vivado -mode batch -source scripts/sim_zu4ev_upg_writer.tcl
create_project qpcie_upg_writer_sim /tmp/opencode/qpcie_upg_writer_sim -part xczu4ev-fbvb900-2-e -force
add_files -fileset sim_1 ./tb/zu4ev_upg_writer_tb.sv ./rtl/h2c_ps_ddr_writer.v
set_property top zu4ev_upg_writer_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 60 us
exit
