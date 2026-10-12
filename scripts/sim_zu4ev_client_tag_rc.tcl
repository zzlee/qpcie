create_project qpcie_client_tag_rc_sim /tmp/opencode/qpcie_client_tag_rc_sim -part xczu4ev-fbvb900-2-e -force
add_files -fileset sim_1 ./rtl/rq_tx_encoder.v ./rtl/rc_rx_decoder.v ./tb/zu4ev_client_tag_rc_tb.sv
set_property top zu4ev_client_tag_rc_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 5 us
exit
