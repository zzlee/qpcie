# Official 2023.2 framebuffer READER for the SC7F0 display branch
# (PS DDR -> AXI read -> AXIS video -> HDMI TX) plus the memory width
# converter that keeps the PS HP port at 128 bits.
#
#   source scripts/create_sc7f0_frmbuf_rd_ip.tcl
#   create_sc7f0_frmbuf_rd_ip              ;# RGB8 + Y_UV8_420, 96-bit AXIS
#   create_sc7f0_frmbuf_rd_ip 1            ;# also request the 32-bit alpha formats
#
# Format selection and AXIS width are coupled inside the IP:
#   NUM_VIDEO_COMPONENTS = 4 whenever an alpha format (HAS_RGBA8/HAS_BGRA8/
#   HAS_YUVA8) is enabled, so m_axis_video_TDATA becomes
#   SAMPLES_PER_CLOCK * MAX_DATA_WIDTH * NUM_VIDEO_COMPONENTS
#   = 4 * 8 * 4 = 128 bit, which does NOT fit the 96-bit RGB24 VIDEO_IN of
#   v_hdmi_tx_ss_0 nor rtl/sc7f0_hdmi_tx_mux.v.  Alpha formats are therefore
#   requested only when the caller explicitly asks for them (alpha=1); the
#   requested HAS_ARGB8 does not exist at all in v_frmbuf_rd 2.5 (see
#   sc7f0_apply_ip_config) and 32-bit packed pixels are only reachable through
#   HAS_RGBA8.
#   With alpha=1 this proc logs SC7F0_FRMBUF_RD_ALPHA_WIDTH so the build log
#   records that a 128->96 pixel packer becomes mandatory.

# set_property -dict aborts on the first unknown CONFIG key, which would break
# the whole build for a parameter this IP version simply does not publish
# (CONFIG.HAS_ARGB8 on v_frmbuf_rd 2.5).  Unsupported keys are reported and
# skipped instead; everything else is applied verbatim.
proc sc7f0_apply_ip_config {ip dict} {
    set supported [list_property $ip]
    set applied {}
    foreach {key value} $dict {
        if {[lsearch -exact $supported $key] >= 0} {
            lappend applied $key $value
        } else {
            puts "SC7F0_IP_CONFIG_SKIP [get_property NAME $ip] $key=$value (not published by this IP version)"
        }
    }
    if {[llength $applied]} {
        set_property -dict $applied $ip
    }
    return $applied
}

proc create_sc7f0_frmbuf_rd_ip {{alpha 0}} {
    # Re-running the IP stage of an existing project must not fail on the
    # duplicate module name; the configuration below is idempotent.
    if {![llength [get_ips -quiet sc7f0_frmbuf_rd]]} {
        create_ip -name v_frmbuf_rd -vendor xilinx.com -library ip -version 2.5 \
            -module_name sc7f0_frmbuf_rd
    }

    sc7f0_apply_ip_config [get_ips sc7f0_frmbuf_rd] [list \
        CONFIG.SAMPLES_PER_CLOCK {4} \
        CONFIG.MAX_COLS {4096} \
        CONFIG.MAX_ROWS {2160} \
        CONFIG.MAX_DATA_WIDTH {8} \
        CONFIG.AXIMM_ADDR_WIDTH {64} \
        CONFIG.AXIMM_DATA_WIDTH {256} \
        CONFIG.HAS_RGB8 {1} \
        CONFIG.HAS_RGBA8 [expr {$alpha ? 1 : 0}] \
        CONFIG.HAS_ARGB8 [expr {$alpha ? 1 : 0}] \
        CONFIG.HAS_Y_UV8_420 {1} \
        CONFIG.HAS_INTERLACED {0} \
    ]
    generate_target all [get_ips sc7f0_frmbuf_rd]

    # AXIS width actually implied by the accepted format set.  3 components =>
    # 96-bit VIDEO_IN path, 4 components => 128-bit and an external packer.
    set comps "?"
    catch {set comps [get_property CONFIG.NUM_VIDEO_COMPONENTS [get_ips sc7f0_frmbuf_rd]]}
    set ppc [get_property CONFIG.SAMPLES_PER_CLOCK [get_ips sc7f0_frmbuf_rd]]
    set bdw [get_property CONFIG.MAX_DATA_WIDTH [get_ips sc7f0_frmbuf_rd]]
    puts "SC7F0_FRMBUF_RD_CFG sc7f0_frmbuf_rd ppc=$ppc bits=$bdw components=$comps alpha=$alpha"
    if {$comps eq "4"} {
        puts "SC7F0_FRMBUF_RD_ALPHA_WIDTH WARNING m_axis_video_TDATA is $ppc*32 = 128 bit with alpha enabled; v_hdmi_tx_ss_0.VIDEO_IN and sc7f0_hdmi_tx_mux.v are 96 bit, so a 128->96 packer (or alpha=0) is required."
    }
    if {[get_property CONFIG.AXIMM_DATA_WIDTH [get_ips sc7f0_frmbuf_rd]] != 256} {
        error "SC7F0_FRMBUF_RD_BAD_WIDTH native AXIMM_DATA_WIDTH must stay 256 (4PPC FB256); narrowing it reproduced AXI overflow at 4K60"
    }

    # Vendor-recommended native FB256 for 4PPC; PS HP1 stays 128-bit and keeps
    # real response/retirement ordering through the converter.
    if {![llength [get_ips -quiet sc7f0_display_width]]} {
        create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
            -version 2.1 -module_name sc7f0_display_width
    }
    set_property -dict [list \
        CONFIG.SI_DATA_WIDTH {256} \
        CONFIG.MI_DATA_WIDTH {128} \
        CONFIG.ADDR_WIDTH {64} \
        CONFIG.SI_ID_WIDTH {1} \
        CONFIG.PROTOCOL {AXI4} \
    ] [get_ips sc7f0_display_width]
    generate_target all [get_ips sc7f0_display_width]

    puts "SC7F0_FRMBUF_RD_IP_OK sc7f0_frmbuf_rd(256->128 via sc7f0_display_width)"
}
