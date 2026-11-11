# Official HDMI TX subsystem (xilinx.com:ip:v_hdmi_tx_ss:3.2) for the SC7F0
# display branch, 4 pixels/clock, 8 bits/component, RGB video interface.
#
# Clocking mirrors v_hdmi_rx_ss_0 exactly (shared GT quad 226 / VPHY:
# TX PLL selection 6, RX PLL selection 0, NIDRU reference clock) so one
# vid_phy_controller_0 can serve both directions.  The module name is fixed to
# v_hdmi_tx_ss_0 because that is the instance name already used by
# rtl/zu4ev_pcie_card_top.v.
#
#   source scripts/create_sc7f0_hdmi_tx_ip.tcl
#   create_sc7f0_hdmi_tx_ip
#
# VIDEO_IN is 96-bit native AXIS video (4 PPC x 3 components x 8 bpc) on
# video_clk; feed it through rtl/sc7f0_hdmi_tx_mux.v.
proc create_sc7f0_hdmi_tx_ip {} {
    create_ip -name v_hdmi_tx_ss -vendor xilinx.com -library ip -version 3.2 \
        -module_name v_hdmi_tx_ss_0

    set_property -dict [list \
        CONFIG.C_INPUT_PIXELS_PER_CLOCK {4} \
        CONFIG.C_MAX_BITS_PER_COMPONENT {8} \
        CONFIG.C_VID_INTERFACE {0} \
        CONFIG.C_INCLUDE_LOW_RESO_VID {true} \
        CONFIG.C_INCLUDE_YUV420_SUP {true} \
        CONFIG.C_HDMI_FAST_SWITCH {true} \
        CONFIG.C_EXDES_TX_PLL_SELECTION {6} \
        CONFIG.C_EXDES_RX_PLL_SELECTION {0} \
        CONFIG.C_EXDES_NIDRU {true} \
    ] [get_ips v_hdmi_tx_ss_0]

    generate_target all [get_ips v_hdmi_tx_ss_0]

    # Fail closed on the interface the RTL is written against: 4 PPC x 8 bpc
    # RGB24 must give a 96-bit VIDEO_IN, never a 192-bit 16 bpc variant.
    set bpc [get_property CONFIG.C_MAX_BITS_PER_COMPONENT [get_ips v_hdmi_tx_ss_0]]
    set ppc [get_property CONFIG.C_INPUT_PIXELS_PER_CLOCK [get_ips v_hdmi_tx_ss_0]]
    if {$bpc != 8 || $ppc != 4} {
        error "SC7F0_HDMI_TX_IP_BAD_GEOMETRY C_INPUT_PIXELS_PER_CLOCK=$ppc C_MAX_BITS_PER_COMPONENT=$bpc (rtl/sc7f0_hdmi_tx_mux.v is 96-bit 4PPC/8bpc)"
    }
    puts "SC7F0_HDMI_TX_IP_OK v_hdmi_tx_ss_0 ppc=$ppc bpc=$bpc VIDEO_IN=$ppc*3*bpc bit"
}
