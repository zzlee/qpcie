# SC7F0-RGB-COMPOSITOR-2PPC profile IP: 2 pixel/clock RGBA8888 framebuffer reader
#
#   source scripts/create_sc7f0_rgb_compositor_ip.tcl
#   create_sc7f0_frmbuf_rd_rgb_ip        ;# one module, TWO instances in RTL
#   create_sc7f0_hdmi_tx_ip_rgb          ;# 2PPC HDMI TX subsystem
#   create_sc7f0_hdmi_rx_ip_rgb          ;# 2PPC HDMI RX subsystem
#   create_sc7f0_vid_phy_ip_rgb          ;# 2PPC Video PHY controller
#
# Why separate module names instead of reusing sc7f0_frmbuf_rd / v_hdmi_tx_ss_0 /
# v_hdmi_rx_ss_0: the legacy personalities are frozen against those exact module
# names and geometries (4 PPC, 96-bit AXIS, AXIMM 256 + width converter).  A
# profile that changes pixels-per-clock must not be able to mutate them, so the
# new geometry gets its own generated modules and the legacy build stays
# byte-for-byte reproducible.
#
# Geometry facts this file pins down, each read back and verified:
#   * v_frmbuf_rd 2.5 has HAS_RGBA8 but NO HAS_ARGB8; any alpha format forces
#     NUM_VIDEO_COMPONENTS = 4, so the AXIS width is
#     SAMPLES_PER_CLOCK * MAX_DATA_WIDTH * NUM_VIDEO_COMPONENTS = 2*8*4 = 64 bit,
#     which is exactly the 2PPC RGBA plane width rtl/sc7f0_alpha_blend_2ppc.v
#     consumes.
#   * native AXIMM width at 2 PPC is 2*8*4*2 = 128 bit, which is already the PS
#     HP port width, so NO width converter is needed (the 4PPC reader needs one,
#     the 2PPC reader does not).
#   * v_hdmi_tx_ss at C_INPUT_PIXELS_PER_CLOCK=2 has a 2*24 = 48-bit VIDEO_IN,
#     which is what the compositor emits; sc7f0_hdmi_tx_mux.v is parameterised by
#     TDATA_WIDTH, so it is instantiated with 48 here.
#
# set_property -dict aborts on the first unknown CONFIG key, so unsupported keys
# are reported and skipped instead of breaking the build.
proc sc7f0_rgb_apply_ip_config {ip dict} {
    set supported [list_property $ip]
    set applied {}
    foreach {key value} $dict {
        if {[lsearch -exact $supported $key] >= 0} {
            lappend applied $key $value
        } else {
            puts "SC7F0_IP_CONFIG_SKIP [get_property NAME $ip] $key=$value (not published by this IP version)"
        }
    }
    if {[llength $applied]} { set_property -dict $applied $ip }
    return $applied
}

proc create_sc7f0_frmbuf_rd_rgb_ip {} {
    if {![llength [get_ips -quiet sc7f0_frmbuf_rd_rgb]]} {
        create_ip -name v_frmbuf_rd -vendor xilinx.com -library ip -version 2.5 \
            -module_name sc7f0_frmbuf_rd_rgb
    }
    # HAS_ALPHA is the master enable of the alpha video formats.  Measured on
    # 2023.2 in this repository: without it HAS_RGBA8/HAS_BGRA8 answer
    # "attempt to modify the value of disabled parameter ... ignored", while
    # HAS_ALPHA on its own fails validation with "Please select at least one
    # Alpha Video Format".  Both sides of the dependency must therefore be applied
    # in ONE set_property call; the non-alpha formats are dropped in a second call.
    sc7f0_rgb_apply_ip_config [get_ips sc7f0_frmbuf_rd_rgb] [list \
        CONFIG.SAMPLES_PER_CLOCK {2} \
        CONFIG.MAX_DATA_WIDTH {8} \
        CONFIG.HAS_ALPHA {1} \
        CONFIG.HAS_RGBA8 {1} \
        CONFIG.HAS_BGRA8 {1} \
    ]
    sc7f0_rgb_apply_ip_config [get_ips sc7f0_frmbuf_rd_rgb] [list \
        CONFIG.MAX_COLS {4096} \
        CONFIG.MAX_ROWS {2160} \
        CONFIG.AXIMM_ADDR_WIDTH {64} \
        CONFIG.AXIMM_DATA_WIDTH {128} \
        CONFIG.HAS_RGB8 {0} \
        CONFIG.HAS_BGR8 {0} \
        CONFIG.HAS_Y_UV8_420 {0} \
        CONFIG.HAS_INTERLACED {0} \
    ]
    generate_target all [get_ips sc7f0_frmbuf_rd_rgb]

    set comps [get_property CONFIG.NUM_VIDEO_COMPONENTS [get_ips sc7f0_frmbuf_rd_rgb]]
    set ppc   [get_property CONFIG.SAMPLES_PER_CLOCK [get_ips sc7f0_frmbuf_rd_rgb]]
    set bdw   [get_property CONFIG.MAX_DATA_WIDTH [get_ips sc7f0_frmbuf_rd_rgb]]
    set axw   [get_property CONFIG.AXIMM_DATA_WIDTH [get_ips sc7f0_frmbuf_rd_rgb]]
    set alpha [get_property CONFIG.HAS_ALPHA [get_ips sc7f0_frmbuf_rd_rgb]]
    set rgba  [get_property CONFIG.HAS_RGBA8 [get_ips sc7f0_frmbuf_rd_rgb]]
    set axis  [expr {$ppc * $bdw * $comps}]
    puts "SC7F0_RGB_FRMBUF_CFG ppc=$ppc bits=$bdw components=$comps axis_bits=$axis aximm_bits=$axw has_alpha=$alpha has_rgba8=$rgba"
    if {$alpha != 1 || $rgba != 1} {
        error "SC7F0_RGB_FRMBUF_NO_ALPHA_FORMAT has_alpha=$alpha has_rgba8=$rgba; RGBA8888 planes are impossible"
    }
    if {$comps != 4} {
        error "SC7F0_RGB_FRMBUF_BAD_COMPONENTS NUM_VIDEO_COMPONENTS=$comps; the compositor consumes RGBA (4 components)"
    }
    if {$axis != 64} {
        error "SC7F0_RGB_FRMBUF_BAD_AXIS_WIDTH m_axis_video_TDATA=$axis bit; rtl/sc7f0_alpha_blend_2ppc.v expects 64 (2 PPC x RGBA)"
    }
    if {$axw != 128} {
        error "SC7F0_RGB_FRMBUF_BAD_AXIMM_WIDTH AXIMM_DATA_WIDTH=$axw; 2 PPC native is 128 and the PS HP port is 128, so no width converter may be needed"
    }
    puts "SC7F0_RGB_FRMBUF_IP_OK sc7f0_frmbuf_rd_rgb (2PPC RGBA8888, native 128-bit AXIMM, no converter)"
}

# 2 PPC HDMI TX subsystem. The legacy 4PPC module keeps its own name and is never
# touched by this proc.
proc create_sc7f0_hdmi_tx_ip_rgb {} {
    if {![llength [get_ips -quiet v_hdmi_tx_ss_rgb]]} {
        create_ip -name v_hdmi_tx_ss -vendor xilinx.com -library ip -version 3.2 \
            -module_name v_hdmi_tx_ss_rgb
    }
    sc7f0_rgb_apply_ip_config [get_ips v_hdmi_tx_ss_rgb] [list \
        CONFIG.C_INCLUDE_AUDIO {1} \
        CONFIG.C_INCLUDE_DCPCOMBINER {1} \
        CONFIG.C_INCLUDE_HDCP {0} \
        CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} \
        CONFIG.C_MAX_BITS_PER_COMPONENT {8} \
        CONFIG.C_VID_INTERFACE {0} \
        CONFIG.C_HDMI_COMPATIBLE {2} \
        CONFIG.C_TMDS_VIDEO_SUPPORT {1} \
        CONFIG.C_EXDES_TX_PLL_SELECTION {6} \
        CONFIG.C_EXDES_NIDRU {true} \
        CONFIG.C_USE_ODDR_FOR_TMDS_CLKOUT {true} \
    ]
    generate_target all [get_ips v_hdmi_tx_ss_rgb]
    set ppc [get_property CONFIG.C_INPUT_PIXELS_PER_CLOCK [get_ips v_hdmi_tx_ss_rgb]]
    set bpc [get_property CONFIG.C_MAX_BITS_PER_COMPONENT [get_ips v_hdmi_tx_ss_rgb]]
    puts "SC7F0_RGB_TX_CFG v_hdmi_tx_ss_rgb ppc=$ppc bpc=$bpc video_in_bits=[expr {$ppc*24}]"
    if {$ppc != 2 || $bpc != 8} {
        error "SC7F0_RGB_TX_BAD_GEOMETRY C_INPUT_PIXELS_PER_CLOCK=$ppc C_MAX_BITS_PER_COMPONENT=$bpc; the compositor output is 2PPC/8bpc (48-bit VIDEO_IN)"
    }
    puts "SC7F0_RGB_TX_IP_OK v_hdmi_tx_ss_rgb (48-bit VIDEO_IN)"
}

# 2 PPC HDMI RX subsystem: VIDEO_OUT is 2*24 = 48 bit, which is the input of
# rtl/sc7f0_rgb24_axis_pack.v.
proc create_sc7f0_hdmi_rx_ip_rgb {} {
    if {![llength [get_ips -quiet v_hdmi_rx_ss_rgb]]} {
        create_ip -name v_hdmi_rx_ss -vendor xilinx.com -library ip -version 3.2 \
            -module_name v_hdmi_rx_ss_rgb
    }
    sc7f0_rgb_apply_ip_config [get_ips v_hdmi_rx_ss_rgb] [list \
        CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} \
        CONFIG.C_MAX_BITS_PER_COMPONENT {8} \
        CONFIG.C_VID_INTERFACE {0} \
        CONFIG.C_INCLUDE_LOW_RESO_VID {true} \
        CONFIG.C_INCLUDE_YUV420_SUP {true} \
        CONFIG.C_HDMI_FAST_SWITCH {true} \
        CONFIG.C_EXDES_TX_PLL_SELECTION {6} \
        CONFIG.C_EXDES_RX_PLL_SELECTION {0} \
        CONFIG.C_EXDES_NIDRU {true} \
    ]
    generate_target all [get_ips v_hdmi_rx_ss_rgb]
    set ppc [get_property CONFIG.C_INPUT_PIXELS_PER_CLOCK [get_ips v_hdmi_rx_ss_rgb]]
    puts "SC7F0_RGB_RX_CFG v_hdmi_rx_ss_rgb ppc=$ppc video_out_bits=[expr {$ppc*24}]"
    if {$ppc != 2} {
        error "SC7F0_RGB_RX_BAD_GEOMETRY C_INPUT_PIXELS_PER_CLOCK=$ppc; sc7f0_rgb24_axis_pack.v is instantiated at 2 PPC"
    }
    puts "SC7F0_RGB_RX_IP_OK v_hdmi_rx_ss_rgb (48-bit VIDEO_OUT)"
}

# One Video PHY controller for the pair, 2 PPC on both directions. The GT line
# rate and reference clock stay exactly as the published design (5.94 Gb/s,
# 297 MHz refclk): pixels-per-clock changes the parallel video width and the
# pixel clock (594/2 = 297 MHz at 2 PPC), never the serial rate.
proc create_sc7f0_vid_phy_ip_rgb {} {
    if {![llength [get_ips -quiet vid_phy_controller_rgb]]} {
        create_ip -name vid_phy_controller -vendor xilinx.com -library ip \
            -version 2.2 -module_name vid_phy_controller_rgb
    }
    sc7f0_rgb_apply_ip_config [get_ips vid_phy_controller_rgb] [list \
        CONFIG.Adv_Clk_Mode {true} \
        CONFIG.CHANNEL_ENABLE {X0Y12 X0Y13 X0Y14} \
        CONFIG.CHANNEL_SITE {X0Y12} \
        CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} \
        CONFIG.C_INT_HDMI_VER_CMPTBLE {3} \
        CONFIG.C_NIDRU {true} \
        CONFIG.C_NIDRU_REFCLK_SEL {3} \
        CONFIG.C_RX_PLL_SELECTION {0} \
        CONFIG.C_RX_REFCLK_SEL {1} \
        CONFIG.C_Rx_Protocol {HDMI} \
        CONFIG.C_TX_PLL_SELECTION {6} \
        CONFIG.C_TX_REFCLK_SEL {0} \
        CONFIG.C_Tx_Protocol {HDMI} \
        CONFIG.C_Clock_Control {Common} \
        CONFIG.C_Txrefclk_Rdy_Invert {true} \
        CONFIG.C_Use_Oddr_for_Tmds_Clkout {true} \
        CONFIG.Rx_GT_Line_Rate {5.94} \
        CONFIG.Rx_GT_Ref_Clock_Freq {297} \
        CONFIG.Tx_GT_Line_Rate {5.94} \
        CONFIG.Tx_GT_Ref_Clock_Freq {297} \
    ]
    generate_target all [get_ips vid_phy_controller_rgb]
    set ppc [get_property CONFIG.C_INPUT_PIXELS_PER_CLOCK [get_ips vid_phy_controller_rgb]]
    # AXIS link width per lane is PPC samples + 8 spare bits: 24 at 2 PPC,
    # 40 at 4 PPC. rtl/zu4ev_pcie_card_top.v carries 40 today.
    puts "SC7F0_RGB_VPHY_CFG vid_phy_controller_rgb ppc=$ppc link_lane_bits=[expr {$ppc*8+8}]"
    if {$ppc != 2} { error "SC7F0_RGB_VPHY_BAD_PPC $ppc" }
    puts "SC7F0_RGB_VPHY_IP_OK vid_phy_controller_rgb (2 PPC, 24-bit link lanes)"
}
