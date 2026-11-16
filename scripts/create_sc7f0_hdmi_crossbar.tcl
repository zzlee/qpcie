# Shared by the full-profile build and the register-routing regression.
# M07 (0xB0080000 + 64KiB) is the sc7f0_display_pipeline aperture
# (sc7f0_frmbuf_rd s_axi_CTRL), so it must stay outside the M02 TX aperture
# 0xB0020000-0xB003FFFF and above the M06 tap window at 0xB0070000.
#
# create_sc7f0_hdmi_crossbar      ;# 8 slices, exactly as published
# create_sc7f0_hdmi_crossbar 2    ;# 10 slices for SC7F0_RGB_COMPOSITOR:
#   M08 = 0xB0090000  compositor Reader-B (overlay plane) v_frmbuf_rd s_axi_CTRL
#   M09 = 0xB00A0000  overlay ingress / overlay writer / compositor control
#                     (rtl/sc7f0_rgb_overlay_ctrl.v)
# Both windows are 4 KiB and both sit above every existing window, so no already
# published aperture moves by one byte.
proc create_sc7f0_hdmi_crossbar {{extra 0}} {
    set mi [expr {8 + $extra}]
    create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_hdmi
    set props [list \
      CONFIG.NUM_SI {1} CONFIG.NUM_MI $mi CONFIG.PROTOCOL {AXI4LITE} \
      CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {32} \
      CONFIG.M00_A00_BASE_ADDR {0x00000000B0000000} CONFIG.M00_A00_ADDR_WIDTH {12} \
      CONFIG.M01_A00_BASE_ADDR {0x00000000B0010000} CONFIG.M01_A00_ADDR_WIDTH {16} \
      CONFIG.M02_A00_BASE_ADDR {0x00000000B0020000} CONFIG.M02_A00_ADDR_WIDTH {17} \
      CONFIG.M03_A00_BASE_ADDR {0x00000000B0040000} CONFIG.M03_A00_ADDR_WIDTH {12} \
      CONFIG.M04_A00_BASE_ADDR {0x00000000B0050000} CONFIG.M04_A00_ADDR_WIDTH {12} \
      CONFIG.M05_A00_BASE_ADDR {0x00000000B0060000} CONFIG.M05_A00_ADDR_WIDTH {16} \
      CONFIG.M06_A00_BASE_ADDR {0x00000000B0070000} CONFIG.M06_A00_ADDR_WIDTH {12} \
      CONFIG.M07_A00_BASE_ADDR {0x00000000B0080000} CONFIG.M07_A00_ADDR_WIDTH {16}]
    if {$extra >= 1} {
        lappend props \
          CONFIG.M08_A00_BASE_ADDR {0x00000000B0090000} CONFIG.M08_A00_ADDR_WIDTH {12}
    }
    if {$extra >= 2} {
        lappend props \
          CONFIG.M09_A00_BASE_ADDR {0x00000000B00A0000} CONFIG.M09_A00_ADDR_WIDTH {12}
    }
    set_property -dict $props [get_ips axi_crossbar_hdmi]
    generate_target all [get_ips axi_crossbar_hdmi]
    puts "SC7F0_HDMI_XBAR slices=$mi extra=$extra M08=0xB0090000 M09=0xB00A0000"
}
