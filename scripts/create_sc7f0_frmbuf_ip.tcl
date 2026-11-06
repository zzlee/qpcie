# Official 2023.2 framebuffer writer for the PS V4L2 capture branch.
# Deliberately NV12-only; input must already be compatible YUV420 AXIS Video.
# This IP is not a CSC or a guarantee of raw/DDR branch isolation.
proc create_sc7f0_frmbuf_ip {} {
    create_ip -name v_frmbuf_wr -vendor xilinx.com -library ip -version 2.5 \
        -module_name sc7f0_frmbuf_wr
    set_property -dict [list \
        CONFIG.SAMPLES_PER_CLOCK {4} \
        CONFIG.MAX_COLS {4096} CONFIG.MAX_ROWS {2160} \
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
