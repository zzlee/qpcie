# Shared by the production ZU4EV build and focused aperture regression.
proc create_qpcie_bar0_crossbar {} {
    create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_1
    set_property -dict [list \
      CONFIG.NUM_SI {2} \
      CONFIG.NUM_MI {3} \
      CONFIG.PROTOCOL {AXI4LITE} \
      CONFIG.DATA_WIDTH {32} \
      CONFIG.ADDR_WIDTH {32} \
      CONFIG.M00_A00_BASE_ADDR {0x0000000000000000} \
      CONFIG.M00_A00_ADDR_WIDTH {12} \
      CONFIG.M01_A00_BASE_ADDR {0x0000000000001000} \
      CONFIG.M01_A00_ADDR_WIDTH {12} \
      CONFIG.M02_A00_BASE_ADDR {0x0000000000002000} \
      CONFIG.M02_A00_ADDR_WIDTH {13} \
    ] [get_ips axi_crossbar_1]
    generate_target all [get_ips axi_crossbar_1]
}
