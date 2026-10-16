set project_dir /tmp/opencode/qpcie_hdmi_pixel_sim
create_project qpcie_hdmi_pixel_sim $project_dir -part xc7a50tcsg325-2 -force
set_property XPM_LIBRARIES {XPM_FIFO} [current_project]
add_files ./rtl/hdmi_dual_pixel_bridge.v
add_files ./rtl/hdmi_parallel_input.v
add_files -fileset sim_1 ./tb/hdmi_pixel_bridge_tb.sv
set_property top hdmi_pixel_bridge_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 300 us
exit
