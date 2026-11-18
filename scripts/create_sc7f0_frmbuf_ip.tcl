# Official 2023.2 framebuffer writers for the PS V4L2 capture branch.
#
# TWO generated modules, one per memory format, because a personality must not be
# able to mutate the shape another personality shipped against:
#
#   sc7f0_frmbuf_wr        NV12-only (HAS_Y_UV8_420).  The published capture
#                          branch: its consumer was the VCU encoder.  Frozen.
#   sc7f0_frmbuf_wr_rgbx   32-bit RGBX (HAS_BGRX8), instantiated only under
#                          `SC7F0_RGB_COMPOSITOR` by
#                          rtl/sc7f0_ps_frmbuf_writer.v.  Its consumer is the
#                          compositor's AB24 base plane reader.
#
# Neither module is a CSC or a guarantee of raw/DDR branch isolation; the input
# must already be compatible AXI-Stream Video of the matching format.
proc sc7f0_frmbuf_apply_ip_config {ip dict} {
    # set_property -dict aborts on the first unknown CONFIG key, so unsupported
    # keys are reported and skipped instead of breaking the build (same rule as
    # sc7f0_rgb_apply_ip_config in scripts/create_sc7f0_rgb_compositor_ip.tcl).
    set supported [list_property $ip]
    set applied {}
    set skipped {}
    foreach {key value} $dict {
        if {[lsearch -exact $supported $key] >= 0} {
            lappend applied $key $value
        } else {
            lappend skipped "$key=$value"
        }
    }
    if {[llength $skipped]} {
        puts "SC7F0_IP_CONFIG_SKIP [get_property NAME $ip] $skipped (not published by this IP version)"
    }
    if {[llength $applied]} { set_property -dict $applied $ip }
    return $applied
}

proc create_sc7f0_frmbuf_ip {} {
    create_ip -name v_frmbuf_wr -vendor xilinx.com -library ip -version 2.5 \
        -module_name sc7f0_frmbuf_wr
    set_property -dict [list \
        CONFIG.SAMPLES_PER_CLOCK {4} CONFIG.MAX_COLS {4096} CONFIG.MAX_ROWS {2160} \
        CONFIG.MAX_DATA_WIDTH {8} \
        CONFIG.AXIMM_ADDR_WIDTH {64} CONFIG.AXIMM_DATA_WIDTH {256} \
        CONFIG.HAS_RGB8 {0} CONFIG.HAS_Y_UV8_420 {1} \
        CONFIG.HAS_INTERLACED {0} \
    ] [get_ips sc7f0_frmbuf_wr]
    generate_target all [get_ips sc7f0_frmbuf_wr]
    # Official GUI rule is SAMPLES_PER_CLOCK * 32 * 2. Forcing FB128 at
    # 4PPC reproduced overflow even with ideal DDR. Keep the actual HP1 at128
    # using the AXI converter, including real response/retirement ordering.
    create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
        -version 2.1 -module_name sc7f0_capture_width
    set_property -dict [list CONFIG.SI_DATA_WIDTH {256} \
        CONFIG.MI_DATA_WIDTH {128} CONFIG.ADDR_WIDTH {64} \
        CONFIG.SI_ID_WIDTH {1} CONFIG.PROTOCOL {AXI4}] [get_ips sc7f0_capture_width]
    generate_target all [get_ips sc7f0_capture_width]
}

# ---------------------------------------------------------------------------
# A1: the RGB-compositor capture personality (round 26111602).
#
# HAS_RGBX8, not HAS_BGRX8.  These are two distinct parameters of this IP and they mean
# two distinct memory layouts, and the pairing is consistent all the way down the stack:
#   IP HAS_RGBX8 -> DTG "xbgr8888" -> xilinx_frmbuf.c XILINX_FRMBUF_FMT_RGBX8 ->
#                   DRM_FORMAT_XBGR8888, i.e. memory bytes R,G,B,X
#   IP HAS_BGRX8 -> DTG "xrgb8888" -> XILINX_FRMBUF_FMT_BGRX8 -> DRM_FORMAT_XRGB8888,
#                   i.e. memory bytes B,G,R,X
# Plane A of the compositor is DRM_FORMAT_ABGR8888 (AB24), whose memory bytes are R,G,B,A,
# so only HAS_RGBX8 is byte-compatible with the buffer the capture writes.  HAS_BGRX8
# would reach the HDMI output with red and blue exchanged; this round's first attempt asked
# for exactly that, which is why this note exists.
#
# No repack in the fabric.  This IP's video input carries three bytes per pixel per 8-bit
# component width (component.xml: s_axis_video_TDATA left=47 at the default two pixels per
# clock, 2 x 3 bytes) and the writer itself expands each pixel into the four memory bytes
# of the packed-32 format.  A 32-bit-per-pixel stream into that input would misalign every
# pixel after the first, so the CSC's RGB stream goes in exactly as it is.
# ---------------------------------------------------------------------------
proc create_sc7f0_frmbuf_wr_rgbx_ip {} {
    # Same house style as create_sc7f0_frmbuf_ip above: module name without a "_0"
    # suffix (rtl/sc7f0_ps_frmbuf_writer.v instantiates exactly this name), the 2.5
    # parameter names, and the skip-unsupported-keys helper.
    create_ip -name v_frmbuf_wr -vendor xilinx.com -library ip -version 2.5 \
        -module_name sc7f0_frmbuf_wr_rgbx
    sc7f0_frmbuf_apply_ip_config [get_ips sc7f0_frmbuf_wr_rgbx] [list \
        CONFIG.SAMPLES_PER_CLOCK {4} CONFIG.MAX_COLS {4096} CONFIG.MAX_ROWS {2160} \
        CONFIG.MAX_DATA_WIDTH {8} \
        CONFIG.AXIMM_ADDR_WIDTH {64} CONFIG.AXIMM_DATA_WIDTH {256} \
        CONFIG.HAS_RGBX8 {1} CONFIG.HAS_BGRX8 {0} CONFIG.HAS_RGB8 {0} \
        CONFIG.HAS_BGR8 {0} CONFIG.HAS_Y_UV8_420 {0} CONFIG.HAS_Y_UV8 {0} \
        CONFIG.HAS_Y8 {0} CONFIG.HAS_INTERLACED {0}]
    set ip [get_ips sc7f0_frmbuf_wr_rgbx]
    # The helper above deliberately skips keys this IP version does not publish, so the
    # readback is the only evidence that the shape was applied.  A missing HAS_RGBX8
    # would silently produce a writer with no format at all, and an extra format would
    # give the driver two formats to negotiate on a node meant to have one.
    puts "SC7F0_RGBX_FRMBUF_CFG ppc=[get_property CONFIG.SAMPLES_PER_CLOCK $ip] aximm=[get_property CONFIG.AXIMM_DATA_WIDTH $ip] rgbx8=[get_property CONFIG.HAS_RGBX8 $ip] bgrx8=[get_property CONFIG.HAS_BGRX8 $ip] rgb8=[get_property CONFIG.HAS_RGB8 $ip] nv12=[get_property CONFIG.HAS_Y_UV8_420 $ip]"
    if {[get_property CONFIG.HAS_RGBX8 $ip] != 1} {
        error "SC7F0_RGBX_FRMBUF_NO_FORMAT HAS_RGBX8 did not stick; the writer would have no RGBX format"
    }
    foreach off {HAS_BGRX8 HAS_RGB8 HAS_Y_UV8_420} {
        if {[get_property CONFIG.$off $ip] != 0} {
            error "SC7F0_RGBX_FRMBUF_EXTRA_FORMAT $off is set; the driver must see exactly one format"
        }
    }
    if {[get_property CONFIG.SAMPLES_PER_CLOCK $ip] != 4} {
        error "SC7F0_RGBX_FRMBUF_BAD_PPC SAMPLES_PER_CLOCK is not 4; the capture pipeline is 4 pixels per clock"
    }
    if {[get_property CONFIG.AXIMM_DATA_WIDTH $ip] != 256} {
        error "SC7F0_RGBX_FRMBUF_BAD_AXIMM AXIMM_DATA_WIDTH is not 256; sc7f0_capture_width converts 256 -> 128 onto HP1"
    }
    generate_target all [get_ips sc7f0_frmbuf_wr_rgbx]
    puts "SC7F0_RGBX_FRMBUF_IP_OK sc7f0_frmbuf_wr_rgbx (4PPC RGBX8: memory R,G,B/X, which is the AB24 Plane-A layout; three bytes per pixel on the video input, native 256-bit AXIMM)"
}
