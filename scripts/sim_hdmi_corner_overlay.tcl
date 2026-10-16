create_project hdmi_corner_overlay /tmp/opencode/hdmi_corner_overlay -part xc7a50tcsg325-2 -force
add_files {./rtl/hdmi_dual_pixel_bridge.v ./rtl/tpg_marker_overlay.v}
add_files -fileset sim_1 ./tb/hdmi_corner_overlay_tb.sv
set_property top hdmi_corner_overlay_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run 100 us
exit
