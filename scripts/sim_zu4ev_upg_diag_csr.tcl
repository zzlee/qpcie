create_project qpcie_upg_diag_csr_sim /tmp/opencode/qpcie_upg_diag_csr_sim -part xczu4ev-fbvb900-2-e -force
add_files -fileset sim_1 ./rtl/axil_reg_space.v ./tb/zu4ev_upg_diag_csr_tb.sv
set_property top zu4ev_upg_diag_csr_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 5 us
exit
