`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_rgb_compositor  (personality SC7F0-RGB-COMPOSITOR-2PPC)
//
// PS DDR  --Reader-A--> base RGBA --\
//                                     +--> sc7f0_alpha_blend_2ppc --> CDC --> HDMI TX
// PS DDR  --Reader-B--> overlay RGBA-/
//
// Two INDEPENDENT official v_frmbuf_rd instances (module sc7f0_frmbuf_rd_rgb,
// 2 pixel/clock, HAS_RGBA8, native AXIMM 128-bit at 300 MHz) - one per plane.
// Reader-A is read-only on the existing HP1 read channel and shares that port
// with the overlay write master (AXI has independent read and write channels, so
// no arbiter is needed between them); Reader-B owns the new HP2 port, which is
// what keeps 4K60 base (1.99 GB/s) + 4K60 overlay (1.99 GB/s) inside two 128-bit
// 300 MHz ports (4.8 GB/s each) instead of squeezing both through one.
//
// Clocks
//   csr_clk  ~100 MHz  PS/PL control clock; each reader's s_axi_CTRL is reached
//            through its own axi_clock_converter_0 (csr_clk -> mem_clk), so the
//            frame base/stride/format registers can be rewritten while video runs.
//   mem_clk  300 MHz capture_clk; readers, blend and slot read-back.  The three
//            compositor control levels (blend_enable / alpha_force_opaque /
//            blend_unlock) are ALREADY mem_clk levels here: their one crossing
//            belongs to rtl/sc7f0_rgb_overlay_ctrl.v, which is the only driver
//            of them in this personality.
//   tx_clk   phy_tx_video_clk (297 MHz at 4K60) for the HDMI TX subsystem.
//   All resets are active-low proc_sys_reset outputs of their own domain; the
//   mem->tx crossing uses rtl/sc7f0_dp_fifo.v, which synchronises every reset
//   source into both clocks before combining them.
//
// Per-reader reset (reader_a_rst_n / reader_b_rst_n) is the only controllable
// reset the official v_frmbuf_rd exposes and is what the in-tree xilinx_frmbuf
// driver requires as reset-gpios; it resets the reader only, never the CDC or the
// AXI ports, so it can never truncate a burst the interconnect is tracking.
//
// Interrupts: irq_a and irq_b are the two readers' own level outputs.  They are
// routed to two separate pl_ps_irq inputs (see scripts/create_zu4ev_ps_bd.tcl);
// software distinguishes them by reading each reader's own ISR in its 4 KiB
// window, the same procedure the official driver uses.
// ============================================================================

module sc7f0_rgb_compositor #(
    parameter integer PPC = 2
)(
    input  wire                 csr_clk,
    input  wire                 csr_rst_n,
    input  wire                 mem_clk,
    input  wire                 mem_rst_n,
    input  wire                 reader_a_rst_n,
    input  wire                 reader_b_rst_n,
    input  wire                 tx_clk,
    input  wire                 tx_rst_n,

    // ---- plane A control: AXI-Lite slave on csr_clk ----------------------
    input  wire [31:0]          s_axi_a_awaddr,
    input  wire                 s_axi_a_awvalid,
    output wire                 s_axi_a_awready,
    input  wire [31:0]          s_axi_a_wdata,
    input  wire [3:0]           s_axi_a_wstrb,
    input  wire                 s_axi_a_wvalid,
    output wire                 s_axi_a_wready,
    output wire [1:0]           s_axi_a_bresp,
    output wire                 s_axi_a_bvalid,
    input  wire                 s_axi_a_bready,
    input  wire [31:0]          s_axi_a_araddr,
    input  wire                 s_axi_a_arvalid,
    output wire                 s_axi_a_arready,
    output wire [31:0]          s_axi_a_rdata,
    output wire [1:0]           s_axi_a_rresp,
    output wire                 s_axi_a_rvalid,
    input  wire                 s_axi_a_rready,

    // ---- plane B control -------------------------------------------------
    input  wire [31:0]          s_axi_b_awaddr,
    input  wire                 s_axi_b_awvalid,
    output wire                 s_axi_b_awready,
    input  wire [31:0]          s_axi_b_wdata,
    input  wire [3:0]           s_axi_b_wstrb,
    input  wire                 s_axi_b_wvalid,
    output wire                 s_axi_b_wready,
    output wire [1:0]           s_axi_b_bresp,
    output wire                 s_axi_b_bvalid,
    input  wire                 s_axi_b_bready,
    input  wire [31:0]          s_axi_b_araddr,
    input  wire                 s_axi_b_arvalid,
    output wire                 s_axi_b_arready,
    output wire [31:0]          s_axi_b_rdata,
    output wire [1:0]           s_axi_b_rresp,
    output wire                 s_axi_b_rvalid,
    input  wire                 s_axi_b_rready,

    // ---- plane A AXI4 read master, 128-bit, mem_clk (PS HP1) -------------
    output wire [63:0]          a_araddr,
    output wire [7:0]           a_arlen,
    output wire [2:0]           a_arsize,
    output wire [1:0]           a_arburst,
    output wire                 a_arvalid,
    input  wire                 a_arready,
    input  wire [127:0]         a_rdata,
    input  wire [1:0]           a_rresp,
    input  wire                 a_rlast,
    input  wire                 a_rvalid,
    output wire                 a_rready,

    // ---- plane B AXI4 read master, 128-bit, mem_clk (PS HP2) -------------
    output wire [63:0]          b_araddr,
    output wire [7:0]           b_arlen,
    output wire [2:0]           b_arsize,
    output wire [1:0]           b_arburst,
    output wire                 b_arvalid,
    input  wire                 b_arready,
    input  wire [127:0]         b_rdata,
    input  wire [1:0]           b_rresp,
    input  wire                 b_rlast,
    input  wire                 b_rvalid,
    output wire                 b_rready,

    // ---- compositor control: mem_clk levels, already synchronised by owner ---
    // rtl/sc7f0_rgb_overlay_ctrl.v owns the pcie_user_clk(125) -> mem_clk(300)
    // crossing of exactly these three quasi-static levels (its u_blend_en,
    // u_alpha_opaque and u_blend_unlock xpm_cdc_single instances).  They must
    // not be re-synchronised here: an earlier revision declared them as csr_clk
    // sources and re-crossed them, which put a 300 MHz XPM output register in
    // front of a synchroniser whose src_clk was pl_clk0 - a genuinely
    // unsynchronised 300 -> 100 hop (R7: u_overlay_ctrl/u_alpha_opaque/
    // syncstages_ff_reg[3] -> u_rgb_compositor/u_ao/src_ff_reg, -1.346 ns, plus
    // the two siblings) followed by a needless 100 -> 300 hop back.
    input  wire                 blend_enable,
    input  wire                 alpha_force_opaque,
    input  wire                 blend_unlock,

    // ---- hardware tear-free Reader-B slot auto-advance (mem_clk) ---------
    input  wire [3:0]           ovl_slot_ready_m,
    input  wire [1:0]           ovl_last_slot_m,
    input  wire [31:0]          ovl_slot_bytes_m,
    input  wire                 ovl_hw_auto_slot,
    output reg  [3:0]           ovl_slot_release_m,

    // ---- composited video, tx_clk, PPC pixels of native RGB ---------------
    output wire [PPC*24-1:0]    m_axis_video_tdata,
    output wire                 m_axis_video_tvalid,
    input  wire                 m_axis_video_tready,
    output wire                 m_axis_video_tlast,
    output wire                 m_axis_video_tuser,

    // ---- status / interrupts ---------------------------------------------
    output wire                 irq_a,
    output wire                 irq_b,
    output wire                 blend_locked,
    output wire                 blend_busy,
    output wire [31:0]          blend_lock_lost,
    output wire [31:0]          blend_sat_watchdog,
    output wire [31:0]          blend_beats,
    // SOF genlock observability (rtl/sc7f0_alpha_blend_2ppc.v).  blend_locked is
    // only "GL_LOCKED"; these say what the compositor is doing when it is NOT
    // locked and why it last lost the lock, which is the difference between an
    // overlay that was never armed, one that is armed but off by half a frame, and
    // one that fell out of lock mid-frame.
    output wire [1:0]           blend_gl_state,
    output wire [2:0]           blend_drop_reason,
    output wire [31:0]          blend_lock_count,
    output wire [31:0]          blend_base_passthru
);
    localparam integer RB = PPC*32;               // RGBA beat
    localparam integer OB = PPC*24;               // RGB beat

    // ------------------------------------------------------------------------
    // control path CDC, one per reader (AXI4-Lite, 32-bit, ID 0)
    // ------------------------------------------------------------------------
    wire [31:0] ca_awaddr, ca_wdata, ca_araddr, ca_rdata;
    wire [3:0]  ca_wstrb;
    wire [1:0]  ca_bresp, ca_rresp;
    wire        ca_awvalid, ca_awready, ca_wvalid, ca_wready, ca_bvalid, ca_bready;
    wire        ca_arvalid, ca_arready, ca_rvalid, ca_rready;
    wire [31:0] cb_awaddr, cb_wdata, cb_araddr, cb_rdata;
    wire [3:0]  cb_wstrb;
    wire [1:0]  cb_bresp, cb_rresp;
    wire        cb_awvalid, cb_awready, cb_wvalid, cb_wready, cb_bvalid, cb_bready;
    wire        cb_arvalid, cb_arready, cb_rvalid, cb_rready;

    axi_clock_converter_0 u_ctrl_a (
        .s_axi_aclk    (csr_clk),  .s_axi_aresetn (csr_rst_n),
        .s_axi_awaddr  (s_axi_a_awaddr),  .s_axi_awprot (3'b000),
        .s_axi_awvalid (s_axi_a_awvalid), .s_axi_awready(s_axi_a_awready),
        .s_axi_wdata   (s_axi_a_wdata),   .s_axi_wstrb  (s_axi_a_wstrb),
        .s_axi_wvalid  (s_axi_a_wvalid),  .s_axi_wready (s_axi_a_wready),
        .s_axi_bresp   (s_axi_a_bresp),   .s_axi_bvalid (s_axi_a_bvalid),
        .s_axi_bready  (s_axi_a_bready),
        .s_axi_araddr  (s_axi_a_araddr),  .s_axi_arprot (3'b000),
        .s_axi_arvalid (s_axi_a_arvalid), .s_axi_arready(s_axi_a_arready),
        .s_axi_rdata   (s_axi_a_rdata),   .s_axi_rresp  (s_axi_a_rresp),
        .s_axi_rvalid  (s_axi_a_rvalid),  .s_axi_rready (s_axi_a_rready),
        .m_axi_aclk    (mem_clk),  .m_axi_aresetn (mem_rst_n),
        .m_axi_awaddr  (ca_awaddr),  .m_axi_awprot (),
        .m_axi_awvalid (ca_awvalid), .m_axi_awready(ca_awready),
        .m_axi_wdata   (ca_wdata),   .m_axi_wstrb  (ca_wstrb),
        .m_axi_wvalid  (ca_wvalid),  .m_axi_wready (ca_wready),
        .m_axi_bresp   (ca_bresp),   .m_axi_bvalid (ca_bvalid),
        .m_axi_bready  (ca_bready),
        .m_axi_araddr  (ca_araddr),  .m_axi_arprot (),
        .m_axi_arvalid (ca_arvalid), .m_axi_arready(ca_arready),
        .m_axi_rdata   (ca_rdata),   .m_axi_rresp  (ca_rresp),
        .m_axi_rvalid  (ca_rvalid),  .m_axi_rready (ca_rready)
    );

    axi_clock_converter_0 u_ctrl_b (
        .s_axi_aclk    (csr_clk),  .s_axi_aresetn (csr_rst_n),
        .s_axi_awaddr  (s_axi_b_awaddr),  .s_axi_awprot (3'b000),
        .s_axi_awvalid (s_axi_b_awvalid), .s_axi_awready(s_axi_b_awready),
        .s_axi_wdata   (s_axi_b_wdata),   .s_axi_wstrb  (s_axi_b_wstrb),
        .s_axi_wvalid  (s_axi_b_wvalid),  .s_axi_wready (s_axi_b_wready),
        .s_axi_bresp   (s_axi_b_bresp),   .s_axi_bvalid (s_axi_b_bvalid),
        .s_axi_bready  (s_axi_b_bready),
        .s_axi_araddr  (s_axi_b_araddr),  .s_axi_arprot (3'b000),
        .s_axi_arvalid (s_axi_b_arvalid), .s_axi_arready(s_axi_b_arready),
        .s_axi_rdata   (s_axi_b_rdata),   .s_axi_rresp  (s_axi_b_rresp),
        .s_axi_rvalid  (s_axi_b_rvalid),  .s_axi_rready (s_axi_b_rready),
        .m_axi_aclk    (mem_clk),  .m_axi_aresetn (mem_rst_n),
        .m_axi_awaddr  (cb_awaddr),  .m_axi_awprot (),
        .m_axi_awvalid (cb_awvalid), .m_axi_awready(cb_awready),
        .m_axi_wdata   (cb_wdata),   .m_axi_wstrb  (cb_wstrb),
        .m_axi_wvalid  (cb_wvalid),  .m_axi_wready (cb_wready),
        .m_axi_bresp   (cb_bresp),   .m_axi_bvalid (cb_bvalid),
        .m_axi_bready  (cb_bready),
        .m_axi_araddr  (cb_araddr),  .m_axi_arprot (),
        .m_axi_arvalid (cb_arvalid), .m_axi_arready(cb_arready),
        .m_axi_rdata   (cb_rdata),   .m_axi_rresp  (cb_rresp),
        .m_axi_rvalid  (cb_rvalid),  .m_axi_rready (cb_rready)
    );

    // ------------------------------------------------------------------------
    // Reader-A: base plane
    // ------------------------------------------------------------------------
    wire [RB-1:0] a_vid_tdata;
    wire          a_vid_tvalid, a_vid_tready, a_vid_tlast, a_vid_tuser;
    sc7f0_frmbuf_rd_rgb u_frmbuf_rd_a (
        .ap_clk              (mem_clk),
        .ap_rst_n            (reader_a_rst_n),
        .interrupt           (irq_a),
        .m_axis_video_TDATA  (a_vid_tdata),
        .m_axis_video_TVALID (a_vid_tvalid),
        .m_axis_video_TREADY (a_vid_tready),
        .m_axis_video_TLAST  (a_vid_tlast),
        .m_axis_video_TUSER  (a_vid_tuser),
        .m_axis_video_TKEEP  (), .m_axis_video_TSTRB (),
        .m_axis_video_TID    (), .m_axis_video_TDEST (),
        .s_axi_CTRL_AWADDR   (ca_awaddr[6:0]),
        .s_axi_CTRL_AWVALID  (ca_awvalid), .s_axi_CTRL_AWREADY (ca_awready),
        .s_axi_CTRL_WDATA    (ca_wdata),   .s_axi_CTRL_WSTRB   (ca_wstrb),
        .s_axi_CTRL_WVALID   (ca_wvalid),  .s_axi_CTRL_WREADY  (ca_wready),
        .s_axi_CTRL_BRESP    (ca_bresp),   .s_axi_CTRL_BVALID  (ca_bvalid),
        .s_axi_CTRL_BREADY   (ca_bready),
        .s_axi_CTRL_ARADDR   (ca_araddr[6:0]),
        .s_axi_CTRL_ARVALID  (ca_arvalid), .s_axi_CTRL_ARREADY (ca_arready),
        .s_axi_CTRL_RDATA    (ca_rdata),   .s_axi_CTRL_RRESP   (ca_rresp),
        .s_axi_CTRL_RVALID   (ca_rvalid),  .s_axi_CTRL_RREADY  (ca_rready),
        // read-only master: write channels terminated
        .m_axi_mm_video_AWADDR (), .m_axi_mm_video_AWLEN  (),
        .m_axi_mm_video_AWSIZE (), .m_axi_mm_video_AWBURST(),
        .m_axi_mm_video_AWLOCK (), .m_axi_mm_video_AWCACHE(),
        .m_axi_mm_video_AWPROT (), .m_axi_mm_video_AWQOS  (),
        .m_axi_mm_video_AWREGION(),.m_axi_mm_video_AWVALID(),
        .m_axi_mm_video_AWREADY(1'b0),
        .m_axi_mm_video_WDATA  (), .m_axi_mm_video_WSTRB (),
        .m_axi_mm_video_WLAST  (), .m_axi_mm_video_WVALID(),
        .m_axi_mm_video_WREADY (1'b0),
        .m_axi_mm_video_BRESP  (2'b00), .m_axi_mm_video_BVALID(1'b0),
        .m_axi_mm_video_BREADY (),
        .m_axi_mm_video_ARADDR (a_araddr),  .m_axi_mm_video_ARLEN (a_arlen),
        .m_axi_mm_video_ARSIZE (a_arsize),  .m_axi_mm_video_ARBURST(a_arburst),
        .m_axi_mm_video_ARLOCK (), .m_axi_mm_video_ARCACHE(),
        .m_axi_mm_video_ARPROT (), .m_axi_mm_video_ARQOS  (),
        .m_axi_mm_video_ARREGION(),.m_axi_mm_video_ARVALID(a_arvalid),
        .m_axi_mm_video_ARREADY(a_arready),
        .m_axi_mm_video_RDATA  (a_rdata),   .m_axi_mm_video_RRESP (a_rresp),
        .m_axi_mm_video_RLAST  (a_rlast),   .m_axi_mm_video_RVALID(a_rvalid),
        .m_axi_mm_video_RREADY (a_rready)
    );

    // ------------------------------------------------------------------------
    // Reader-B: overlay plane (separate IP instance, separate HP port)
    // ------------------------------------------------------------------------
    wire [RB-1:0] b_vid_tdata;
    wire          b_vid_tvalid, b_vid_tready, b_vid_tlast, b_vid_tuser;
    wire [63:0]   b_araddr_raw;
    sc7f0_frmbuf_rd_rgb u_frmbuf_rd_b (
        .ap_clk              (mem_clk),
        .ap_rst_n            (reader_b_rst_n),
        .interrupt           (irq_b),
        .m_axis_video_TDATA  (b_vid_tdata),
        .m_axis_video_TVALID (b_vid_tvalid),
        .m_axis_video_TREADY (b_vid_tready),
        .m_axis_video_TLAST  (b_vid_tlast),
        .m_axis_video_TUSER  (b_vid_tuser),
        .m_axis_video_TKEEP  (), .m_axis_video_TSTRB (),
        .m_axis_video_TID    (), .m_axis_video_TDEST (),
        .s_axi_CTRL_AWADDR   (cb_awaddr[6:0]),
        .s_axi_CTRL_AWVALID  (cb_awvalid), .s_axi_CTRL_AWREADY (cb_awready),
        .s_axi_CTRL_WDATA    (cb_wdata),   .s_axi_CTRL_WSTRB   (cb_wstrb),
        .s_axi_CTRL_WVALID   (cb_wvalid),  .s_axi_CTRL_WREADY  (cb_wready),
        .s_axi_CTRL_BRESP    (cb_bresp),   .s_axi_CTRL_BVALID  (cb_bvalid),
        .s_axi_CTRL_BREADY   (cb_bready),
        .s_axi_CTRL_ARADDR   (cb_araddr[6:0]),
        .s_axi_CTRL_ARVALID  (cb_arvalid), .s_axi_CTRL_ARREADY (cb_arready),
        .s_axi_CTRL_RDATA    (cb_rdata),   .s_axi_CTRL_RRESP   (cb_rresp),
        .s_axi_CTRL_RVALID   (cb_rvalid),  .s_axi_CTRL_RREADY  (cb_rready),
        .m_axi_mm_video_AWADDR (), .m_axi_mm_video_AWLEN  (),
        .m_axi_mm_video_AWSIZE (), .m_axi_mm_video_AWBURST(),
        .m_axi_mm_video_AWLOCK (), .m_axi_mm_video_AWCACHE(),
        .m_axi_mm_video_AWPROT (), .m_axi_mm_video_AWQOS  (),
        .m_axi_mm_video_AWREGION(),.m_axi_mm_video_AWVALID(),
        .m_axi_mm_video_AWREADY(1'b0),
        .m_axi_mm_video_WDATA  (), .m_axi_mm_video_WSTRB (),
        .m_axi_mm_video_WLAST  (), .m_axi_mm_video_WVALID(),
        .m_axi_mm_video_WREADY (1'b0),
        .m_axi_mm_video_BRESP  (2'b00), .m_axi_mm_video_BVALID(1'b0),
        .m_axi_mm_video_BREADY (),
        .m_axi_mm_video_ARADDR (b_araddr_raw),  .m_axi_mm_video_ARLEN (b_arlen),
        .m_axi_mm_video_ARSIZE (b_arsize),  .m_axi_mm_video_ARBURST(b_arburst),
        .m_axi_mm_video_ARLOCK (), .m_axi_mm_video_ARCACHE(),
        .m_axi_mm_video_ARPROT (), .m_axi_mm_video_ARQOS  (),
        .m_axi_mm_video_ARREGION(),.m_axi_mm_video_ARVALID(b_arvalid),
        .m_axi_mm_video_ARREADY(b_arready),
        .m_axi_mm_video_RDATA  (b_rdata),   .m_axi_mm_video_RRESP (b_rresp),
        .m_axi_mm_video_RLAST  (b_rlast),   .m_axi_mm_video_RVALID(b_rvalid),
        .m_axi_mm_video_RREADY (b_rready)
    );

    // ------------------------------------------------------------------------
    // Hardware tear-free Reader-B slot selector (mem_clk, zero PS/CPU loop)
    // ------------------------------------------------------------------------
    reg  [1:0]  disp_slot;
    reg  [11:0] b_line_cnt;
    reg  [11:0] b_lines_per_frame;
    reg         b_switch_pending;
    wire        b_sof = b_vid_tvalid && b_vid_tready && b_vid_tuser;
    wire        b_eol = b_vid_tvalid && b_vid_tready && b_vid_tlast;
    wire        b_eof = b_eol && (b_lines_per_frame != 12'd0) &&
                        (b_line_cnt == (b_lines_per_frame - 12'd1));
    wire        b_init_switch = !b_arvalid && !ovl_slot_ready_m[disp_slot] && (|ovl_slot_ready_m);

    reg [1:0] next_disp_slot;
    always @(*) begin
        if (ovl_slot_ready_m[ovl_last_slot_m])
            next_disp_slot = ovl_last_slot_m;
        else if (ovl_slot_ready_m[2'd0]) next_disp_slot = 2'd0;
        else if (ovl_slot_ready_m[2'd1]) next_disp_slot = 2'd1;
        else if (ovl_slot_ready_m[2'd2]) next_disp_slot = 2'd2;
        else                             next_disp_slot = 2'd3;
    end

    always @(posedge mem_clk) begin
        if (!mem_rst_n) begin
            disp_slot          <= 2'd0;
            b_line_cnt         <= 12'd0;
            b_lines_per_frame  <= 12'd0;
            b_switch_pending   <= 1'b0;
            ovl_slot_release_m <= 4'b0000;
        end else begin
            ovl_slot_release_m <= 4'b0000;
            if (b_sof) begin
                if (b_line_cnt != 12'd0)
                    b_lines_per_frame <= b_line_cnt;
                b_line_cnt <= 12'd0;
            end else if (b_eol) begin
                b_line_cnt <= b_line_cnt + 12'd1;
            end

            if (!ovl_hw_auto_slot) begin
                disp_slot        <= 2'd0;
                b_switch_pending <= 1'b0;
            end else begin
                if (b_eof)
                    b_switch_pending <= 1'b1;

                if ((b_switch_pending || b_eof || b_init_switch) && !b_arvalid) begin
                    b_switch_pending <= 1'b0;
                    if (|ovl_slot_ready_m) begin
                        if (next_disp_slot != disp_slot) begin
                            disp_slot          <= next_disp_slot;
                            ovl_slot_release_m <= ovl_slot_ready_m & ~(4'b0001 << next_disp_slot);
                        end else if ((ovl_slot_ready_m & ~(4'b0001 << disp_slot)) != 4'b0000) begin
                            ovl_slot_release_m <= ovl_slot_ready_m & ~(4'b0001 << disp_slot);
                        end
                    end
                end
            end
        end
    end

    reg [33:0] disp_slot_offset;
    always @(*) begin
        case (disp_slot)
            2'd0: disp_slot_offset = 34'd0;
            2'd1: disp_slot_offset = {2'b00, ovl_slot_bytes_m};
            2'd2: disp_slot_offset = {1'b0, ovl_slot_bytes_m, 1'b0};
            2'd3: disp_slot_offset = {2'b00, ovl_slot_bytes_m} + {1'b0, ovl_slot_bytes_m, 1'b0};
        endcase
    end
    assign b_araddr = ovl_hw_auto_slot ? (b_araddr_raw + {30'd0, disp_slot_offset}) : b_araddr_raw;

    // ------------------------------------------------------------------------
    // control levels into the mem-domain compositor
    //
    // No synchroniser here.  blend_enable / alpha_force_opaque / blend_unlock
    // arrive as mem_clk levels from their owner (see the port comment above),
    // and the blend consumes them in this same domain, so the crossing happens
    // exactly once and in the right direction.
    // ------------------------------------------------------------------------
    wire blend_en_m      = blend_enable;
    wire alpha_opaque_m  = alpha_force_opaque;
    wire unlock_m        = blend_unlock;

    // ------------------------------------------------------------------------
    // 2 PPC alpha compositor
    // ------------------------------------------------------------------------
    wire [OB-1:0] bl_tdata;
    wire          bl_tvalid, bl_tready, bl_tlast, bl_tuser;

    sc7f0_alpha_blend_2ppc #(.PPC(PPC), .QUEUE_DEPTH(16)) u_blend (
        .clk                (mem_clk),
        .rst_n              (mem_rst_n),
        .blend_enable       (blend_en_m),
        .alpha_force_opaque (alpha_opaque_m),
        .unlock             (unlock_m),
        .s_b_axis_tdata     (a_vid_tdata),
        .s_b_axis_tvalid    (a_vid_tvalid),
        .s_b_axis_tready    (a_vid_tready),
        .s_b_axis_tlast     (a_vid_tlast),
        .s_b_axis_tuser     (a_vid_tuser),
        .s_o_axis_tdata     (b_vid_tdata),
        .s_o_axis_tvalid    (b_vid_tvalid),
        .s_o_axis_tready    (b_vid_tready),
        .s_o_axis_tlast     (b_vid_tlast),
        .s_o_axis_tuser     (b_vid_tuser),
        .m_axis_tdata       (bl_tdata),
        .m_axis_tvalid      (bl_tvalid),
        .m_axis_tready      (bl_tready),
        .m_axis_tlast       (bl_tlast),
        .m_axis_tuser       (bl_tuser),
        .locked             (blend_locked),
        .pipeline_busy      (blend_busy),
        .gl_state           (blend_gl_state),
        .gl_drop_reason     (blend_drop_reason),
        .gl_lock_count      (blend_lock_count),
        .lock_lost_count    (blend_lock_lost),
        .sat_watchdog_count (blend_sat_watchdog),
        .beats_blended      (blend_beats),
        .base_passthru_beats(blend_base_passthru)
    );

    // ------------------------------------------------------------------------
    // mem_clk -> tx_clk video crossing (sc7f0_dp_fifo owns the reset contract)
    // ------------------------------------------------------------------------
    wire [OB+1:0] tx_head;
    wire          tx_rvalid, tx_empty;

    sc7f0_dp_fifo #(
        .WIDTH    (OB+2),
        .DEPTH    (4096),
        .MEMORY   ("block"),
        .W_SOURCES(1),
        .R_SOURCES(1)
    ) u_video_cdc (
        .wclk  (mem_clk),
        .wrst_n({mem_rst_n}),
        .wdata ({bl_tuser, bl_tlast, bl_tdata}),
        .wvalid(bl_tvalid),
        .wready(bl_tready),
        .rclk  (tx_clk),
        .rrst_n({tx_rst_n}),
        .rdata (tx_head),
        .rvalid(tx_rvalid),
        .rready(m_axis_video_tready)
    );

    assign m_axis_video_tdata  = tx_head[OB-1:0];
    assign m_axis_video_tlast  = tx_head[OB];
    assign m_axis_video_tuser  = tx_head[OB+1];
    assign m_axis_video_tvalid = tx_rvalid;

    wire _unused = &{1'b0, tx_empty, 1'b0};
endmodule
`default_nettype wire
