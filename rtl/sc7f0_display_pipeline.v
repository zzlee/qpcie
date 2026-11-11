`default_nettype none
// ============================================================================
// Module: sc7f0_display_pipeline
// Target: AMD/Xilinx Zynq UltraScale+ MPSoC (xczu4ev-fbvb900-2-e)
//
// SC7F0 display branch: PS DDR -> v_frmbuf_rd -> AXIS video -> HDMI TX.
//
//   sc7f0_frmbuf_rd      official v_frmbuf_rd 2.5, 4 PPC, native AXIMM 256-bit
//   sc7f0_display_width  axi_dwidth_converter 2.1, 256 -> 128-bit (PS HP port)
//   axi_clock_converter_0 AXI-Lite CSR crossing csr_clk -> mem_clk
//   xpm_fifo_async       98-bit {tuser,tlast,tdata} video CDC mem_clk -> tx_clk
//
// Clocks
//   csr_clk  ~100 MHz PS/PL control clock  (axi_crossbar_hdmi M07 @ 0xB0080000)
//   mem_clk  300 MHz memory/capture clock (frmbuf_rd + AXI read port)
//   tx_clk   phy_tx_video_clk (vid_phy_controller_0), feeds sc7f0_hdmi_tx_mux
//   All three resets are active-low and are the proc_sys_reset outputs of
//   their own domain; nothing samples a raw cross-domain reset bus.
//
// Control path: the AXI-Lite slave is the crossbar M07 window
// (0xB008_0000 .. 0xB008_FFFF, 64 KiB, 4 KiB actually decoded by the IP).  The
// clock converter re-times AW/W/AR/B/R into mem_clk before s_axi_CTRL, so the
// CSR can be touched while the video clock is running or stopped.
//
// Memory path: frmbuf_rd keeps the vendor-recommended native FB256 for 4 PPC;
// the width converter narrows to 128-bit with real burst/response ordering, so
// the PS HP port only ever sees 128-bit INCR bursts.  Only AR/R is exported
// (frmbuf_rd is read-only); the converter's write channels are idle.
//
// Video path: frmbuf_rd free-runs as soon as it is enabled, while the HDMI TX
// consumes at the link rate and backpressures VIDEO_IN with tready.  The async
// FIFO absorbs the difference and the resulting backpressure stalls frmbuf_rd;
// software must therefore restart/pace the reader per frame (frmbuf_rd CTRL
// enable + interrupt) or accept frame jitter.  This module intentionally does
// not fabricate frame timing: irq is exported so the driver can see
// frmbuf_rd completion/overflow instead of silent corruption.
// ============================================================================
`timescale 1ns / 1ps

module sc7f0_display_pipeline (
    // ---- clocks / resets -------------------------------------------------
    input  wire csr_clk,
    input  wire csr_rst_n,
    input  wire mem_clk,
    input  wire mem_rst_n,
    input  wire tx_clk,
    input  wire tx_rst_n,

    // ---- AXI-Lite CSR slave (axi_crossbar_hdmi M07, 0xB0080000) ----------
    input  wire [31:0] s_axi_ctrl_awaddr,
    input  wire        s_axi_ctrl_awvalid,
    output wire        s_axi_ctrl_awready,
    input  wire [31:0] s_axi_ctrl_wdata,
    input  wire [3:0]  s_axi_ctrl_wstrb,
    input  wire        s_axi_ctrl_wvalid,
    output wire        s_axi_ctrl_wready,
    output wire [1:0]  s_axi_ctrl_bresp,
    output wire        s_axi_ctrl_bvalid,
    input  wire        s_axi_ctrl_bready,
    input  wire [31:0] s_axi_ctrl_araddr,
    input  wire        s_axi_ctrl_arvalid,
    output wire        s_axi_ctrl_arready,
    output wire [31:0] s_axi_ctrl_rdata,
    output wire [1:0]  s_axi_ctrl_rresp,
    output wire        s_axi_ctrl_rvalid,
    input  wire        s_axi_ctrl_rready,

    // ---- AXI4 read-only memory port, 128-bit, mem_clk (PS HP) ------------
    output wire [63:0] araddr,
    output wire [7:0]  arlen,
    output wire [2:0]  arsize,
    output wire [1:0]  arburst,
    output wire        arvalid,
    input  wire        arready,
    input  wire [127:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,

    // ---- AXIS video out on tx_clk, 4 PPC RGB24, straight to the mux ------
    output wire [95:0] m_axis_video_tdata,
    output wire        m_axis_video_tvalid,
    input  wire        m_axis_video_tready,
    output wire        m_axis_video_tlast,
    output wire        m_axis_video_tuser,

    // ---- frmbuf_rd interrupt (level, mem_clk) ----------------------------
    output wire        irq
);

    localparam integer VIDEO_FIFO_WIDTH = 96 + 2;   // {tuser, tlast, tdata}
    localparam integer VIDEO_FIFO_DEPTH = 1024;

    // ------------------------------------------------------------------------
    // CSR: csr_clk -> mem_clk, then into sc7f0_frmbuf_rd.s_axi_CTRL.  The
    // converter carries the configured 32-bit control address; the framebuffer
    // only publishes 7 bits (4 KiB bank), so its address is sliced exactly like
    // the capture branch does.  APROT is not routed by the HDMI crossbar.
    // ------------------------------------------------------------------------
    wire [31:0] ctrl_awaddr;
    wire [31:0] ctrl_araddr;
    wire [31:0] ctrl_wdata, ctrl_rdata;
    wire [3:0]  ctrl_wstrb;
    wire [1:0]  ctrl_bresp, ctrl_rresp;
    wire        ctrl_awvalid, ctrl_awready, ctrl_wvalid, ctrl_wready;
    wire        ctrl_bvalid, ctrl_bready, ctrl_arvalid, ctrl_arready;
    wire        ctrl_rvalid, ctrl_rready;

    axi_clock_converter_0 u_ctrl_cdc (
        .s_axi_aclk     (csr_clk),
        .s_axi_aresetn  (csr_rst_n),
        .s_axi_awaddr   (s_axi_ctrl_awaddr),
        .s_axi_awprot   (3'b000),
        .s_axi_awvalid  (s_axi_ctrl_awvalid),
        .s_axi_awready  (s_axi_ctrl_awready),
        .s_axi_wdata    (s_axi_ctrl_wdata),
        .s_axi_wstrb    (s_axi_ctrl_wstrb),
        .s_axi_wvalid   (s_axi_ctrl_wvalid),
        .s_axi_wready   (s_axi_ctrl_wready),
        .s_axi_bresp    (s_axi_ctrl_bresp),
        .s_axi_bvalid   (s_axi_ctrl_bvalid),
        .s_axi_bready   (s_axi_ctrl_bready),
        .s_axi_araddr   (s_axi_ctrl_araddr),
        .s_axi_arprot   (3'b000),
        .s_axi_arvalid  (s_axi_ctrl_arvalid),
        .s_axi_arready  (s_axi_ctrl_arready),
        .s_axi_rdata    (s_axi_ctrl_rdata),
        .s_axi_rresp    (s_axi_ctrl_rresp),
        .s_axi_rvalid   (s_axi_ctrl_rvalid),
        .s_axi_rready   (s_axi_ctrl_rready),

        .m_axi_aclk     (mem_clk),
        .m_axi_aresetn  (mem_rst_n),
        .m_axi_awaddr   (ctrl_awaddr),
        .m_axi_awprot   (),
        .m_axi_awvalid  (ctrl_awvalid),
        .m_axi_awready  (ctrl_awready),
        .m_axi_wdata    (ctrl_wdata),
        .m_axi_wstrb    (ctrl_wstrb),
        .m_axi_wvalid   (ctrl_wvalid),
        .m_axi_wready   (ctrl_wready),
        .m_axi_bresp    (ctrl_bresp),
        .m_axi_bvalid   (ctrl_bvalid),
        .m_axi_bready   (ctrl_bready),
        .m_axi_araddr   (ctrl_araddr),
        .m_axi_arprot   (),
        .m_axi_arvalid  (ctrl_arvalid),
        .m_axi_arready  (ctrl_arready),
        .m_axi_rdata    (ctrl_rdata),
        .m_axi_rresp    (ctrl_rresp),
        .m_axi_rvalid   (ctrl_rvalid),
        .m_axi_rready   (ctrl_rready)
    );

    // ------------------------------------------------------------------------
    // Framebuffer reader (mem_clk).  Native 256-bit AXIMM, 96-bit 4 PPC AXIS
    // video with 1-bit SOF tuser.  Write channels of the read-only master are
    // terminated locally.  This IP build publishes no AXIMM ID ports
    // (C_M_AXI_MM_VIDEO_ENABLE_ID_PORTS = false), so the width converter's SI ID
    // is tied to the single ID the reader can ever use.
    // ------------------------------------------------------------------------
    wire [63:0] fb_araddr;
    wire [7:0]  fb_arlen;
    wire [2:0]  fb_arsize;
    wire [1:0]  fb_arburst;
    wire        fb_arvalid, fb_arready, fb_rvalid, fb_rready, fb_rlast;
    wire [255:0] fb_rdata;
    wire [1:0]  fb_rresp;

    wire [95:0] fb_tdata;
    wire        fb_tvalid, fb_tready, fb_tlast, fb_tuser;

    sc7f0_frmbuf_rd u_frmbuf_rd (
        .ap_clk                   (mem_clk),
        .ap_rst_n                 (mem_rst_n),
        .interrupt                (irq),

        .m_axis_video_TDATA       (fb_tdata),
        .m_axis_video_TVALID      (fb_tvalid),
        .m_axis_video_TREADY      (fb_tready),
        .m_axis_video_TLAST       (fb_tlast),
        .m_axis_video_TUSER       (fb_tuser),
        .m_axis_video_TKEEP       (),
        .m_axis_video_TSTRB       (),
        .m_axis_video_TID         (),
        .m_axis_video_TDEST       (),

        .s_axi_CTRL_AWADDR        (ctrl_awaddr[6:0]),
        .s_axi_CTRL_AWVALID       (ctrl_awvalid),
        .s_axi_CTRL_AWREADY       (ctrl_awready),
        .s_axi_CTRL_WDATA         (ctrl_wdata),
        .s_axi_CTRL_WSTRB         (ctrl_wstrb),
        .s_axi_CTRL_WVALID        (ctrl_wvalid),
        .s_axi_CTRL_WREADY        (ctrl_wready),
        .s_axi_CTRL_BRESP         (ctrl_bresp),
        .s_axi_CTRL_BVALID        (ctrl_bvalid),
        .s_axi_CTRL_BREADY        (ctrl_bready),
        .s_axi_CTRL_ARADDR        (ctrl_araddr[6:0]),
        .s_axi_CTRL_ARVALID       (ctrl_arvalid),
        .s_axi_CTRL_ARREADY       (ctrl_arready),
        .s_axi_CTRL_RDATA         (ctrl_rdata),
        .s_axi_CTRL_RRESP         (ctrl_rresp),
        .s_axi_CTRL_RVALID        (ctrl_rvalid),
        .s_axi_CTRL_RREADY        (ctrl_rready),

        // Read-only master: AW/W/B inputs terminated, outputs left open.
        .m_axi_mm_video_AWADDR    (),
        .m_axi_mm_video_AWLEN     (),
        .m_axi_mm_video_AWSIZE    (),
        .m_axi_mm_video_AWBURST   (),
        .m_axi_mm_video_AWLOCK    (),
        .m_axi_mm_video_AWCACHE   (),
        .m_axi_mm_video_AWPROT    (),
        .m_axi_mm_video_AWQOS     (),
        .m_axi_mm_video_AWREGION  (),
        .m_axi_mm_video_AWVALID   (),
        .m_axi_mm_video_AWREADY   (1'b0),
        .m_axi_mm_video_WDATA     (),
        .m_axi_mm_video_WSTRB     (),
        .m_axi_mm_video_WLAST     (),
        .m_axi_mm_video_WVALID    (),
        .m_axi_mm_video_WREADY    (1'b0),
        .m_axi_mm_video_BRESP     (2'b00),
        .m_axi_mm_video_BVALID    (1'b0),
        .m_axi_mm_video_BREADY    (),

        .m_axi_mm_video_ARADDR    (fb_araddr),
        .m_axi_mm_video_ARLEN     (fb_arlen),
        .m_axi_mm_video_ARSIZE    (fb_arsize),
        .m_axi_mm_video_ARBURST   (fb_arburst),
        .m_axi_mm_video_ARLOCK    (),
        .m_axi_mm_video_ARCACHE   (),
        .m_axi_mm_video_ARPROT    (),
        .m_axi_mm_video_ARQOS     (),
        .m_axi_mm_video_ARREGION  (),
        .m_axi_mm_video_ARVALID   (fb_arvalid),
        .m_axi_mm_video_ARREADY   (fb_arready),
        .m_axi_mm_video_RDATA     (fb_rdata),
        .m_axi_mm_video_RRESP     (fb_rresp),
        .m_axi_mm_video_RLAST     (fb_rlast),
        .m_axi_mm_video_RVALID    (fb_rvalid),
        .m_axi_mm_video_RREADY    (fb_rready)
    );

    // ------------------------------------------------------------------------
    // 256 -> 128-bit memory width conversion on mem_clk.  Same FB256 -> HP128
    // rule the capture branch uses, so 4K60 does not reproduce the 128-bit
    // native-frame-buffer overflow.
    // ------------------------------------------------------------------------
    sc7f0_display_width u_memory_width (
        .s_axi_aclk     (mem_clk),
        .s_axi_aresetn  (mem_rst_n),

        // SI write channel: this master never writes.
        .s_axi_awid     (1'b0),
        .s_axi_awaddr   (64'd0),
        .s_axi_awlen    (8'd0),
        .s_axi_awsize   (3'd0),
        .s_axi_awburst  (2'b01),
        .s_axi_awlock   (1'b0),
        .s_axi_awcache  (4'b0011),
        .s_axi_awprot   (3'b000),
        .s_axi_awregion (4'b0),
        .s_axi_awqos    (4'b0),
        .s_axi_awvalid  (1'b0),
        .s_axi_awready  (),
        .s_axi_wdata    (256'd0),
        .s_axi_wstrb    (32'd0),
        .s_axi_wlast    (1'b0),
        .s_axi_wvalid   (1'b0),
        .s_axi_wready   (),
        .s_axi_bid      (),
        .s_axi_bresp    (),
        .s_axi_bvalid   (),
        .s_axi_bready   (1'b0),

        // SI read channel: straight from sc7f0_frmbuf_rd.
        .s_axi_arid     (1'b0),
        .s_axi_araddr   (fb_araddr),
        .s_axi_arlen    (fb_arlen),
        .s_axi_arsize   (fb_arsize),
        .s_axi_arburst  (fb_arburst),
        .s_axi_arlock   (1'b0),
        .s_axi_arcache  (4'b0011),
        .s_axi_arprot   (3'b000),
        .s_axi_arregion (4'b0),
        .s_axi_arqos    (4'b0),
        .s_axi_arvalid  (fb_arvalid),
        .s_axi_arready  (fb_arready),
        .s_axi_rid      (),
        .s_axi_rdata    (fb_rdata),
        .s_axi_rresp    (fb_rresp),
        .s_axi_rlast    (fb_rlast),
        .s_axi_rvalid   (fb_rvalid),
        .s_axi_rready   (fb_rready),

        // MI write channel: idle, terminated.
        .m_axi_awaddr   (),
        .m_axi_awlen    (),
        .m_axi_awsize   (),
        .m_axi_awburst  (),
        .m_axi_awlock   (),
        .m_axi_awcache  (),
        .m_axi_awprot   (),
        .m_axi_awregion (),
        .m_axi_awqos    (),
        .m_axi_awvalid  (),
        .m_axi_awready  (1'b0),
        .m_axi_wdata    (),
        .m_axi_wstrb    (),
        .m_axi_wlast    (),
        .m_axi_wvalid   (),
        .m_axi_wready   (1'b0),
        .m_axi_bresp    (2'b00),
        .m_axi_bvalid   (1'b0),
        .m_axi_bready   (),

        // MI read channel: 128-bit AXI4 to the PS HP port.
        .m_axi_araddr   (araddr),
        .m_axi_arlen    (arlen),
        .m_axi_arsize   (arsize),
        .m_axi_arburst  (arburst),
        .m_axi_arlock   (),
        .m_axi_arcache  (),
        .m_axi_arprot   (),
        .m_axi_arregion (),
        .m_axi_arqos    (),
        .m_axi_arvalid  (arvalid),
        .m_axi_arready  (arready),
        .m_axi_rdata    (rdata),
        .m_axi_rresp    (rresp),
        .m_axi_rlast    (rlast),
        .m_axi_rvalid   (rvalid),
        .m_axi_rready   (rready)
    );

    // ------------------------------------------------------------------------
    // Video CDC mem_clk -> tx_clk.  Payload is {tuser, tlast, tdata} so SOF and
    // EOL travel with the pixel beat they belong to; the mux downstream needs a
    // clean frame boundary.  One reset assertion flushes both ends through XPM,
    // and neither side trusts a raw cross-domain reset release.
    // ------------------------------------------------------------------------
    wire [VIDEO_FIFO_WIDTH-1:0] fifo_dout;
    wire fifo_full, fifo_empty, wr_rst_busy, rd_rst_busy, fifo_rst;

    xpm_cdc_async_rst #(
        .DEST_SYNC_FF   (4),
        .RST_ACTIVE_HIGH(1)
    ) u_video_fifo_rst (
        .src_arst (!mem_rst_n || !tx_rst_n),
        .dest_clk (mem_clk),
        .dest_arst(fifo_rst)
    );

    // mem_clk producer side
    wire fb_accept = fb_tvalid && fb_tready;
    assign fb_tready = !fifo_full && !wr_rst_busy && !fifo_rst;

    // tx_clk consumer side (fwft: dout is valid while !empty)
    wire tx_rd_en = m_axis_video_tvalid && m_axis_video_tready;

    xpm_fifo_async #(
        .CDC_SYNC_STAGES    (4),
        .DOUT_RESET_VALUE   ("0"),
        .ECC_MODE           ("no_ecc"),
        .FIFO_MEMORY_TYPE   ("block"),
        .FIFO_READ_LATENCY  (0),
        .FIFO_WRITE_DEPTH   (VIDEO_FIFO_DEPTH),
        .READ_DATA_WIDTH    (VIDEO_FIFO_WIDTH),
        .READ_MODE          ("fwft"),
        .RELATED_CLOCKS     (0),
        .SIM_ASSERT_CHK     (0),
        .USE_ADV_FEATURES   ("0000"),
        .WAKEUP_TIME        (0),
        .WRITE_DATA_WIDTH   (VIDEO_FIFO_WIDTH),
        .WR_DATA_COUNT_WIDTH($clog2(VIDEO_FIFO_DEPTH) + 1),
        .RD_DATA_COUNT_WIDTH($clog2(VIDEO_FIFO_DEPTH) + 1)
    ) u_video_cdc (
        .rst           (fifo_rst),
        .wr_clk        (mem_clk),
        .wr_en         (fb_accept),
        .din           ({fb_tuser, fb_tlast, fb_tdata}),
        .full          (fifo_full),
        .wr_rst_busy   (wr_rst_busy),
        .rd_clk        (tx_clk),
        .rd_en         (tx_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .rd_rst_busy   (rd_rst_busy),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .almost_full   (),
        .wr_ack        (),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .almost_empty  (),
        .data_valid    (),
        .dbiterr       (),
        .sbiterr       ()
    );

    wire video_tx_rst_n = tx_rst_n && !rd_rst_busy;
    assign m_axis_video_tvalid = !fifo_empty && video_tx_rst_n;
    assign m_axis_video_tdata  = fifo_dout[95:0];
    assign m_axis_video_tlast  = fifo_dout[96];
    assign m_axis_video_tuser  = fifo_dout[97];

endmodule
`default_nettype wire
