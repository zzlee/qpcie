# Shared by the full-profile build and the register-routing regression.
proc create_sc7f0_hdmi_crossbar {} {
    create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_hdmi
    set_property -dict [list \
      CONFIG.NUM_SI {1} CONFIG.NUM_MI {3} CONFIG.PROTOCOL {AXI4LITE} \
      CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {32} \
      CONFIG.M00_A00_BASE_ADDR {0x00000000B0000000} CONFIG.M00_A00_ADDR_WIDTH {12} \
      CONFIG.M01_A00_BASE_ADDR {0x00000000B0010000} CONFIG.M01_A00_ADDR_WIDTH {16} \
      CONFIG.M02_A00_BASE_ADDR {0x00000000B0020000} CONFIG.M02_A00_ADDR_WIDTH {17} \
    ] [get_ips axi_crossbar_hdmi]
    generate_target all [get_ips axi_crossbar_hdmi]
}
