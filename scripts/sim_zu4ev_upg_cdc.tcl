# Vivado 2023.2 focused simulation of the 1204 upgrade-START CDC synchronizer.
# Run from the repository root with Vivado set up, e.g.:
#   vivado -mode batch -source scripts/sim_zu4ev_upg_cdc.tcl
set project_dir /tmp/opencode/qpcie_upg_cdc_sim
create_project qpcie_upg_cdc_sim $project_dir -part xczu4ev-fbvb900-2-e -force
add_files -fileset sim_1 ./tb/zu4ev_upg_cdc_tb.sv
set_property top zu4ev_upg_cdc_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 90 us
exit
