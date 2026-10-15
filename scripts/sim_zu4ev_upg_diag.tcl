# Run with Vivado 2023.2 from repository root.
create_project qpcie_upg_diag_sim /tmp/opencode/qpcie_upg_diag_sim -part xczu4ev-fbvb900-2-e -force
set_property XPM_LIBRARIES {XPM_CDC} [current_project]
add_files -fileset sim_1 ./rtl/zu4ev_upg_diag.v ./tb/zu4ev_upg_diag_tb.sv
set_property top zu4ev_upg_diag_tb [get_filesets sim_1]
# launch_simulation otherwise runs 1000ns, already passing $finish, and a
# subsequent run can resume into the watchdog and falsely report a failure.
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all
if {[get_value /zu4ev_upg_diag_tb/test_passed] != 1} {error "Upgrade diagnostic CDC regression did not pass"}
exit
