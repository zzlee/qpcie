create_project hdmi_fifo_policy /tmp/opencode/hdmi_fifo_policy -part xc7a50tcsg325-2 -force
add_files ./rtl/hdmi_dual_pixel_bridge.v
add_files -fileset sim_1 ./tb/hdmi_fifo_policy_tb.sv
set_property top hdmi_fifo_policy_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run 100 us
exit
