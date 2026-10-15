create_project sc7f0_csr_cdc_sim /tmp/opencode/sc7f0_csr_cdc_sim -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files -fileset sim_1 [list ./rtl/axil_reg_space.v ./rtl/qpcie_csr_cdc.v ./rtl/qpcie_status_cdc.v ./rtl/qpcie_csr_reg_space.v ./tb/sc7f0_csr_cdc_tb.sv]
set_property top sc7f0_csr_cdc_tb [get_filesets sim_1]
set_property verilog_define {SC7F0_DEBUG_ONLY=1} [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all
if {[get_value /sc7f0_csr_cdc_tb/test_passed] != 1} { error "CSR CDC regression did not pass" }
exit
