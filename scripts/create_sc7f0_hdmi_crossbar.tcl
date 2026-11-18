# Shared by the full-profile build and the register-routing regression.
# M07 (0xB0080000 + 64KiB) is the sc7f0_display_pipeline aperture
# (sc7f0_frmbuf_rd s_axi_CTRL), so it must stay outside the M02 TX aperture
# 0xB0020000-0xB003FFFF and above the M06 tap window at 0xB0070000.
#
# M02/M10 split of the HDMI TX subsystem (2026-11-16, G8):
#   v_hdmi_tx_ss keeps its VTC at +0x10000, so its natural aperture is 128 KiB
#   (0xB0020000..0xB003FFFF) and the driver derives the VTC address as
#   base+0x10000 from one contiguous reg.  Publishing that as one 17-bit slice
#   did NOT work on hardware: in 26111601 every access with address bit 16 set
#   took a synchronous external abort (SIGBUS/DECERR) while the TX core aliased
#   every 2 KiB.  The deployed routed design shows why a crossbar-carried bit 16
#   cannot be trusted here: the read channel bit is connected
#   (u_hdmi_control/m_axi_araddr[80] -> u_hdmi_tx_ss/S_AXI_CPU_IN_araddr[16] ->
#   inner crossbar -> inst/v_tc/s_axi_araddr[0]) but the WRITE channel bit has no
#   net at all at the subsystem boundary (m_axi_awaddr[80] / awaddr[16] both
#   report no net), so a VTC write could never select the VTC segment.
#   Evidence: build/g6g8-20261116T110140Z/tx-ss-slice2-readprobe.txt plus the
#   routed-DCP and IP-DCP pin/net probes and the gate-level crossbar decode sim
#   in tb/tb_sc7f0_hdmi_xbar_addr_map.v.
#   Fix: decode two 64 KiB slices (the window class proven good on this card) and
#   re-merge them in rtl/zu4ev_pcie_card_top.v with rtl/sc7f0_axil_merge_2to1.v,
#   which drives subsystem address bit 16 from the slice index in fabric.
#   Software still sees one contiguous 128 KiB aperture, so the driver contract
#   (TX core at +0x00000, VTC at +0x10000) is unchanged.
#
# create_sc7f0_hdmi_crossbar      ;# 8 slices, exactly as published
# create_sc7f0_hdmi_crossbar 2    ;# 10 slices for SC7F0_RGB_COMPOSITOR:
#   M08 = 0xB0090000  compositor Reader-B (overlay plane) v_frmbuf_rd s_axi_CTRL
#   M09 = 0xB00A0000  overlay ingress / overlay writer / compositor control
#                     (rtl/sc7f0_rgb_overlay_ctrl.v)
#   M10 = 0xB0030000  HDMI TX subsystem VTC half (see note above)
proc create_sc7f0_hdmi_crossbar {{extra 0}} {
    set mi [expr {8 + $extra}]
    create_ip -name axi_crossbar -vendor xilinx.com -library ip -version 2.1 -module_name axi_crossbar_hdmi
    set props [list \
      CONFIG.NUM_SI {1} CONFIG.NUM_MI $mi CONFIG.PROTOCOL {AXI4LITE} \
      CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {32} \
      CONFIG.M00_A00_BASE_ADDR {0x00000000B0000000} CONFIG.M00_A00_ADDR_WIDTH {12} \
      CONFIG.M01_A00_BASE_ADDR {0x00000000B0010000} CONFIG.M01_A00_ADDR_WIDTH {16} \
      CONFIG.M02_A00_BASE_ADDR {0x00000000B0020000} CONFIG.M02_A00_ADDR_WIDTH [expr {$extra >= 3 ? 16 : 17}] \
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
    if {$extra >= 3} {
        # M10: upper half of the HDMI TX subsystem aperture (VTC at tx_ss+0x10000).
        lappend props \
          CONFIG.M10_A00_BASE_ADDR {0x00000000B0030000} CONFIG.M10_A00_ADDR_WIDTH {16}
    }
    set_property -dict $props [get_ips axi_crossbar_hdmi]
    generate_target all [get_ips axi_crossbar_hdmi]
    puts "SC7F0_HDMI_XBAR slices=$mi extra=$extra M08=0xB0090000 M09=0xB00A0000 M10=0xB0030000"
}
