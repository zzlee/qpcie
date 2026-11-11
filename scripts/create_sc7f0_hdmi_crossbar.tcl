# Shared by the full-profile build and the register-routing regression.
# M07 (0xB0080000 + 64KiB) is the sc7f0_display_pipeline aperture
# (sc7f0_frmbuf_rd s_axi_CTRL), so it must stay outside the M02 TX aperture
# 0xB0020000-0xB003FFFF and above the M06 tap window at 0xB0070000.
proc create_sc7f0_hdmi_crossbar {} {
    create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_hdmi
    set_property -dict [list \
      CONFIG.NUM_SI {1} CONFIG.NUM_MI {8} CONFIG.PROTOCOL {AXI4LITE} \
      CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {32} \
      CONFIG.M00_A00_BASE_ADDR {0x00000000B0000000} CONFIG.M00_A00_ADDR_WIDTH {12} \
      CONFIG.M01_A00_BASE_ADDR {0x00000000B0010000} CONFIG.M01_A00_ADDR_WIDTH {16} \
      CONFIG.M02_A00_BASE_ADDR {0x00000000B0020000} CONFIG.M02_A00_ADDR_WIDTH {17} \
      CONFIG.M03_A00_BASE_ADDR {0x00000000B0040000} CONFIG.M03_A00_ADDR_WIDTH {12} \
      CONFIG.M04_A00_BASE_ADDR {0x00000000B0050000} CONFIG.M04_A00_ADDR_WIDTH {12} \
      CONFIG.M05_A00_BASE_ADDR {0x00000000B0060000} CONFIG.M05_A00_ADDR_WIDTH {16} \
      CONFIG.M06_A00_BASE_ADDR {0x00000000B0070000} CONFIG.M06_A00_ADDR_WIDTH {12} \
      CONFIG.M07_A00_BASE_ADDR {0x00000000B0080000} CONFIG.M07_A00_ADDR_WIDTH {16} \
    ] [get_ips axi_crossbar_hdmi]
    generate_target all [get_ips axi_crossbar_hdmi]
}
