`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_ps_frmbuf_writer  (PS capture branch, memory-format personality switch)
//
// One framebuffer writer for rtl/sc7f0_capture_pipeline.v, chosen at elaboration
// from the personality define, so the capture pipeline itself has exactly one
// writer instance (u_ps_capture/u_writer, the name every existing constraint and
// check script already uses) in every personality:
//
//   default (SC7F0_RGB_COMPOSITOR undefined)
//       sc7f0_frmbuf_wr        4 PPC, NV12 (HAS_Y_UV8_420), native AXIMM 256.
//       This is the frozen published shape: the consumer of those bytes was the
//       VCU encoder, and scripts/create_sc7f0_frmbuf_ip.tcl documents the
//       deliberately NV12-only configuration.  Nothing about this branch changes.
//
//   SC7F0_RGB_COMPOSITOR
//       sc7f0_frmbuf_wr_rgbx
//       4 PPC, 24-bit RGB in, one RGBX plane in PS DDR, native AXIMM 256.
//       The consumer is the compositor's Reader-A base plane, a 32-bit alpha RGB
//       format (AB24 / "abgr8888" in the device tree, memory bytes R,G,B,A), so RX
//       -> PS DDR has to be 32-bit RGB bytes rather than NV12.  The IP is configured
//       HAS_RGBX8, whose memory bytes are R,G,B,X (scripts/create_sc7f0_frmbuf_ip.tcl
//       derives the chain: HAS_RGBX8 -> DTG "xbgr8888" -> XILINX_FRMBUF_FMT_RGBX8 ->
//       DRM_FORMAT_XBGR8888).  HAS_BGRX8 is the other flag and gives B,G,R,X, which
//       would reach the HDMI output with red and blue exchanged - what this round's
//       first attempt asked for.
//
//       No fabric repack in this branch: the writer's video input is three bytes per
//       pixel and the IP pads to the 32-bit memory word itself.  The host C2H RGB24
//       path is a different engine (sc7f0_rgb24_c2h_engine) and is untouched.
//
// What is deliberately NOT switched
//   * Port list, widths, clock and reset: identical in both branches.  The
//     wrapper adds no stage that the legacy branch does not already have, and no
//     geometry, so the frame tap / CSC / CSR / width-converter contract
//     (sc7f0_capture_width, 256 -> 128 onto PS S_AXI_HP1_FPD at 300 MHz) is
//     untouched.
//   * The 2 -> 4 pixel adapter in front of this stage and the CSC behind it: both
//     stay.  Under SC7F0_RGB_COMPOSITOR the CSC runs as an RGB -> RGB pass-through
//     (device tree port@1 xlnx,video-format = 2 instead of 3), which is what keeps
//     the /dev/media graph and its reset-gpios topology identical to the shipped
//     persona.
// ============================================================================

module sc7f0_ps_frmbuf_writer (
    input  wire                ap_clk,
    input  wire                ap_rst_n,
    output wire                interrupt,

    // CSC output: PPC=4 native RGB8, 96 bit data, 12 bit keep/strobe.
    input  wire  [95:0]        s_axis_video_TDATA,
    input  wire                s_axis_video_TVALID,
    output wire                s_axis_video_TREADY,
    input  wire                s_axis_video_TUSER,
    input  wire                s_axis_video_TLAST,
    input  wire  [11:0]        s_axis_video_TKEEP,
    input  wire  [11:0]        s_axis_video_TSTRB,
    input  wire                s_axis_video_TID,
    input  wire                s_axis_video_TDEST,

    input  wire  [6:0]         s_axi_CTRL_AWADDR,
    input  wire                s_axi_CTRL_AWVALID,
    output wire                s_axi_CTRL_AWREADY,
    input  wire  [31:0]        s_axi_CTRL_WDATA,
    input  wire  [3:0]         s_axi_CTRL_WSTRB,
    input  wire                s_axi_CTRL_WVALID,
    output wire                s_axi_CTRL_WREADY,
    output wire [1:0]          s_axi_CTRL_BRESP,
    output wire                s_axi_CTRL_BVALID,
    input  wire                s_axi_CTRL_BREADY,
    input  wire  [6:0]         s_axi_CTRL_ARADDR,
    input  wire                s_axi_CTRL_ARVALID,
    output wire                s_axi_CTRL_ARREADY,
    output wire [31:0]         s_axi_CTRL_RDATA,
    output wire [1:0]          s_axi_CTRL_RRESP,
    output wire                s_axi_CTRL_RVALID,
    input  wire                s_axi_CTRL_RREADY,

    output wire [63:0]         m_axi_mm_video_AWADDR,
    output wire [7:0]          m_axi_mm_video_AWLEN,
    output wire [2:0]          m_axi_mm_video_AWSIZE,
    output wire [1:0]          m_axi_mm_video_AWBURST,
    output wire                m_axi_mm_video_AWVALID,
    input  wire                m_axi_mm_video_AWREADY,
    output wire [255:0]        m_axi_mm_video_WDATA,
    output wire [31:0]         m_axi_mm_video_WSTRB,
    output wire                m_axi_mm_video_WLAST,
    output wire                m_axi_mm_video_WVALID,
    input  wire                m_axi_mm_video_WREADY,
    input  wire [1:0]          m_axi_mm_video_BRESP,
    input  wire                m_axi_mm_video_BVALID,
    output wire                m_axi_mm_video_BREADY,
    output wire [63:0]         m_axi_mm_video_ARADDR,
    output wire [7:0]          m_axi_mm_video_ARLEN,
    output wire [2:0]          m_axi_mm_video_ARSIZE,
    output wire [1:0]          m_axi_mm_video_ARBURST,
    output wire                m_axi_mm_video_ARVALID,
    input  wire                m_axi_mm_video_ARREADY,
    input  wire [255:0]        m_axi_mm_video_RDATA,
    input  wire [1:0]          m_axi_mm_video_RRESP,
    input  wire                m_axi_mm_video_RLAST,
    input  wire                m_axi_mm_video_RVALID,
    output wire                m_axi_mm_video_RREADY
);
`ifdef SC7F0_RGB_COMPOSITOR
    // The CSC's 24-bit RGB stream goes straight into the RGBX writer: this IP's video
    // input carries three bytes per pixel and the writer pads each pixel to the 32-bit
    // memory word itself.  A fabric repack to 32 bits per pixel was this round's first
    // attempt and would have misaligned every pixel after the first.
    //
    sc7f0_frmbuf_wr_rgbx u_frmbuf_wr_rgbx (
        .ap_clk              (ap_clk),
        .ap_rst_n            (ap_rst_n),
        .interrupt           (interrupt),
        .s_axis_video_TDATA  (s_axis_video_TDATA),
        .s_axis_video_TVALID (s_axis_video_TVALID),
        .s_axis_video_TREADY (s_axis_video_TREADY),
        .s_axis_video_TUSER  (s_axis_video_TUSER),
        .s_axis_video_TLAST  (s_axis_video_TLAST),
        .s_axis_video_TKEEP  (s_axis_video_TKEEP),
        .s_axis_video_TSTRB  (s_axis_video_TSTRB),
        .s_axis_video_TID    (s_axis_video_TID),
        .s_axis_video_TDEST  (s_axis_video_TDEST),
        .s_axi_CTRL_AWADDR   (s_axi_CTRL_AWADDR),
        .s_axi_CTRL_AWVALID  (s_axi_CTRL_AWVALID),
        .s_axi_CTRL_AWREADY  (s_axi_CTRL_AWREADY),
        .s_axi_CTRL_WDATA    (s_axi_CTRL_WDATA),
        .s_axi_CTRL_WSTRB    (s_axi_CTRL_WSTRB),
        .s_axi_CTRL_WVALID   (s_axi_CTRL_WVALID),
        .s_axi_CTRL_WREADY   (s_axi_CTRL_WREADY),
        .s_axi_CTRL_BRESP    (s_axi_CTRL_BRESP),
        .s_axi_CTRL_BVALID   (s_axi_CTRL_BVALID),
        .s_axi_CTRL_BREADY   (s_axi_CTRL_BREADY),
        .s_axi_CTRL_ARADDR   (s_axi_CTRL_ARADDR),
        .s_axi_CTRL_ARVALID  (s_axi_CTRL_ARVALID),
        .s_axi_CTRL_ARREADY  (s_axi_CTRL_ARREADY),
        .s_axi_CTRL_RDATA    (s_axi_CTRL_RDATA),
        .s_axi_CTRL_RRESP    (s_axi_CTRL_RRESP),
        .s_axi_CTRL_RVALID   (s_axi_CTRL_RVALID),
        .s_axi_CTRL_RREADY   (s_axi_CTRL_RREADY),
        .m_axi_mm_video_AWADDR  (m_axi_mm_video_AWADDR),
        .m_axi_mm_video_AWLEN   (m_axi_mm_video_AWLEN),
        .m_axi_mm_video_AWSIZE  (m_axi_mm_video_AWSIZE),
        .m_axi_mm_video_AWBURST (m_axi_mm_video_AWBURST),
        .m_axi_mm_video_AWVALID (m_axi_mm_video_AWVALID),
        .m_axi_mm_video_AWREADY (m_axi_mm_video_AWREADY),
        .m_axi_mm_video_WDATA   (m_axi_mm_video_WDATA),
        .m_axi_mm_video_WSTRB   (m_axi_mm_video_WSTRB),
        .m_axi_mm_video_WLAST   (m_axi_mm_video_WLAST),
        .m_axi_mm_video_WVALID  (m_axi_mm_video_WVALID),
        .m_axi_mm_video_WREADY  (m_axi_mm_video_WREADY),
        .m_axi_mm_video_BRESP   (m_axi_mm_video_BRESP),
        .m_axi_mm_video_BVALID  (m_axi_mm_video_BVALID),
        .m_axi_mm_video_BREADY  (m_axi_mm_video_BREADY),
        .m_axi_mm_video_ARADDR  (m_axi_mm_video_ARADDR),
        .m_axi_mm_video_ARLEN   (m_axi_mm_video_ARLEN),
        .m_axi_mm_video_ARSIZE  (m_axi_mm_video_ARSIZE),
        .m_axi_mm_video_ARBURST (m_axi_mm_video_ARBURST),
        .m_axi_mm_video_ARVALID (m_axi_mm_video_ARVALID),
        .m_axi_mm_video_ARREADY (m_axi_mm_video_ARREADY),
        .m_axi_mm_video_RDATA   (m_axi_mm_video_RDATA),
        .m_axi_mm_video_RRESP   (m_axi_mm_video_RRESP),
        .m_axi_mm_video_RLAST   (m_axi_mm_video_RLAST),
        .m_axi_mm_video_RVALID  (m_axi_mm_video_RVALID),
        .m_axi_mm_video_RREADY  (m_axi_mm_video_RREADY)
    );

    wire _unused = &{1'b0, s_axis_video_TID, s_axis_video_TDEST, 1'b0};
`else
    sc7f0_frmbuf_wr u_frmbuf_wr (
        .ap_clk              (ap_clk),
        .ap_rst_n            (ap_rst_n),
        .interrupt           (interrupt),
        .s_axis_video_TDATA  (s_axis_video_TDATA),
        .s_axis_video_TVALID (s_axis_video_TVALID),
        .s_axis_video_TREADY (s_axis_video_TREADY),
        .s_axis_video_TUSER  (s_axis_video_TUSER),
        .s_axis_video_TLAST  (s_axis_video_TLAST),
        .s_axis_video_TKEEP  (s_axis_video_TKEEP),
        .s_axis_video_TSTRB  (s_axis_video_TSTRB),
        .s_axis_video_TID    (s_axis_video_TID),
        .s_axis_video_TDEST  (s_axis_video_TDEST),
        .s_axi_CTRL_AWADDR   (s_axi_CTRL_AWADDR),
        .s_axi_CTRL_AWVALID  (s_axi_CTRL_AWVALID),
        .s_axi_CTRL_AWREADY  (s_axi_CTRL_AWREADY),
        .s_axi_CTRL_WDATA    (s_axi_CTRL_WDATA),
        .s_axi_CTRL_WSTRB    (s_axi_CTRL_WSTRB),
        .s_axi_CTRL_WVALID   (s_axi_CTRL_WVALID),
        .s_axi_CTRL_WREADY   (s_axi_CTRL_WREADY),
        .s_axi_CTRL_BRESP    (s_axi_CTRL_BRESP),
        .s_axi_CTRL_BVALID   (s_axi_CTRL_BVALID),
        .s_axi_CTRL_BREADY   (s_axi_CTRL_BREADY),
        .s_axi_CTRL_ARADDR   (s_axi_CTRL_ARADDR),
        .s_axi_CTRL_ARVALID  (s_axi_CTRL_ARVALID),
        .s_axi_CTRL_ARREADY  (s_axi_CTRL_ARREADY),
        .s_axi_CTRL_RDATA    (s_axi_CTRL_RDATA),
        .s_axi_CTRL_RRESP    (s_axi_CTRL_RRESP),
        .s_axi_CTRL_RVALID   (s_axi_CTRL_RVALID),
        .s_axi_CTRL_RREADY   (s_axi_CTRL_RREADY),
        .m_axi_mm_video_AWADDR  (m_axi_mm_video_AWADDR),
        .m_axi_mm_video_AWLEN   (m_axi_mm_video_AWLEN),
        .m_axi_mm_video_AWSIZE  (m_axi_mm_video_AWSIZE),
        .m_axi_mm_video_AWBURST (m_axi_mm_video_AWBURST),
        .m_axi_mm_video_AWVALID (m_axi_mm_video_AWVALID),
        .m_axi_mm_video_AWREADY (m_axi_mm_video_AWREADY),
        .m_axi_mm_video_WDATA   (m_axi_mm_video_WDATA),
        .m_axi_mm_video_WSTRB   (m_axi_mm_video_WSTRB),
        .m_axi_mm_video_WLAST   (m_axi_mm_video_WLAST),
        .m_axi_mm_video_WVALID  (m_axi_mm_video_WVALID),
        .m_axi_mm_video_WREADY  (m_axi_mm_video_WREADY),
        .m_axi_mm_video_BRESP   (m_axi_mm_video_BRESP),
        .m_axi_mm_video_BVALID  (m_axi_mm_video_BVALID),
        .m_axi_mm_video_BREADY  (m_axi_mm_video_BREADY),
        .m_axi_mm_video_ARADDR  (m_axi_mm_video_ARADDR),
        .m_axi_mm_video_ARLEN   (m_axi_mm_video_ARLEN),
        .m_axi_mm_video_ARSIZE  (m_axi_mm_video_ARSIZE),
        .m_axi_mm_video_ARBURST (m_axi_mm_video_ARBURST),
        .m_axi_mm_video_ARVALID (m_axi_mm_video_ARVALID),
        .m_axi_mm_video_ARREADY (m_axi_mm_video_ARREADY),
        .m_axi_mm_video_RDATA   (m_axi_mm_video_RDATA),
        .m_axi_mm_video_RRESP   (m_axi_mm_video_RRESP),
        .m_axi_mm_video_RLAST   (m_axi_mm_video_RLAST),
        .m_axi_mm_video_RVALID  (m_axi_mm_video_RVALID),
        .m_axi_mm_video_RREADY  (m_axi_mm_video_RREADY)
    );

    wire _unused = &{1'b0, s_axis_video_TID, s_axis_video_TDEST, 1'b0};
`endif
endmodule
`default_nettype wire
