# Focused sim: sg_dma_engine + real submodules with the 1204 upgrade descriptor.
#   vivado -mode batch -source scripts/sim_zu4ev_upg_h2c_engine.tcl
set project_dir /tmp/opencode/qpcie_upg_h2c_sim
create_project qpcie_upg_h2c_sim $project_dir -part xczu4ev-fbvb900-2-e -force
add_files -fileset sim_1 ./tb/zu4ev_upg_h2c_engine_tb.sv
add_files -fileset sim_1 ./rtl/sg_dma_engine.v ./rtl/h2c_reorder_buffer.v ./rtl/sg_segment_walker.v
set_property top zu4ev_upg_h2c_engine_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 60 us
exit
