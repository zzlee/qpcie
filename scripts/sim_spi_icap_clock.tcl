create_project qpcie_spi_icap_sim /tmp/opencode/qpcie_spi_icap_sim -part xc7a50tcsg325-2 -force
add_files ./rtl/spi_flash_controller.v
add_files -fileset sim_1 ./tb/spi_icap_clock_tb.sv
set_property top spi_icap_clock_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 5 us
exit
