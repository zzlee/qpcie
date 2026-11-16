`default_nettype none
// ============================================================================
// zu4ev_rgb_compositor_capacity_top
//
// SC7F0-RGB-COMPOSITOR-2PPC data plane, fully connected, at the real device and
// the real IP geometry. This is a CAPACITY/ELABORATION vehicle, not the shipping
// card top: the PCIe hardcore + DMA requester, the management MCU bridge, the
// firmware-upgrade path and the PS block design are deliberately outside it, so
// their published routed areas are added arithmetically rather than resynthesised
// here. Everything inside IS real: official v_hdmi_rx_ss / v_hdmi_tx_ss at
// 2 pixels-per-clock, two independent official v_frmbuf_rd readers, the packed
// RGB24 byte gearbox, the RGB24 C2H engine, the video request clock crossing, the
// overlay H2C->PS-DDR slot writer, the 2 PPC alpha compositor and the mem->tx
// video crossing. Nothing is black-boxed, stubbed or left unconnected inside.
//
// Boundary (all real interfaces of the card top that this block talks to):
//   hdmi_ctl_*          : AXI-Lite master vector from the PS HPM1 crossbar
//                         (slice 1 = RX SS, slice 2 = TX SS, slice 7 = Reader-A
//                         ctrl at 0xB0080000 as today, slice 8 = Reader-B ctrl)
//   c2h_req_*           : the channel-0 C2H MWr request interface, the same
//                         {valid, addr, dw_len, data, data_ready, ack} contract
//                         the NV12 engine drives today, widened to the card's
//                         256-bit requester width by rtl/video_req_cdc.v
//   h2c_*               : the H2C loopback stream the sg_dma_engine produces
//   hp1_*, hp2_*        : AXI4 read channels to PS DDR (HP1 = Reader-A + the
//                         overlay writer's write channels, HP2 = Reader-B)
//   ovl_*, blend_*      : BAR0 bank 0x0A control levels / status levels
// ============================================================================
`timescale 1ns / 1ps

module zu4ev_rgb_compositor_capacity_top #(
    parameter integer PCIE_DATA_WIDTH = 256,
    parameter integer NATIVE_PPC      = 2
)(
    input  wire                 phy_rx_video_clk,
    input  wire                 phy_tx_video_clk,
    input  wire                 capture_clk,          // 300 MHz
    input  wire                 pcie_user_clk,        // 125 MHz
    input  wire                 pl_clk0,              // ~100 MHz PS/PL control
    input  wire                 capture_rst_n,
    input  wire                 pcie_user_rst_n,
    input  wire                 sys_100m_rst_n,
    input  wire                 rx_video_rst,         // active high, from VPHY
    input  wire                 tx_video_rst,

    // ---- AXI-Lite control vector (PS HPM1 -> axi_crossbar_hdmi) ----------
    input  wire [287:0]         hdmi_ctl_awaddr,
    input  wire [8:0]           hdmi_ctl_awvalid,
    output wire [8:0]           hdmi_ctl_awready,
    input  wire [287:0]         hdmi_ctl_wdata,
    input  wire [35:0]          hdmi_ctl_wstrb,
    input  wire [8:0]           hdmi_ctl_wvalid,
    output wire [8:0]           hdmi_ctl_wready,
    output wire [17:0]          hdmi_ctl_bresp,
    output wire [8:0]           hdmi_ctl_bvalid,
    input  wire [8:0]           hdmi_ctl_bready,
    input  wire [287:0]         hdmi_ctl_araddr,
    input  wire [8:0]           hdmi_ctl_arvalid,
    output wire [8:0]           hdmi_ctl_arready,
    output wire [287:0]         hdmi_ctl_rdata,
    output wire [17:0]          hdmi_ctl_rresp,
    output wire [8:0]           hdmi_ctl_rvalid,
    input  wire [8:0]           hdmi_ctl_rready,

    // ---- C2H MWr request interface towards rq_tx_encoder -----------------
    output wire                 c2h_req_valid,
    output wire [63:0]          c2h_req_addr,
    output wire [10:0]          c2h_req_dw_len,
    output wire [PCIE_DATA_WIDTH-1:0] c2h_req_data,
    input  wire                 c2h_req_data_ready,
    input  wire                 c2h_req_ack,

    // thin descriptor launch (the same fields the NV12 engine consumed)
    input  wire                 desc_valid,
    output wire                 desc_ready,
    input  wire                 desc_sg_mode,
    input  wire [63:0]          plane_y_addr,
    input  wire [15:0]          frame_width,
    input  wire [15:0]          frame_height,
    input  wire [15:0]          frame_stride,
    input  wire [63:0]          global_timestamp,

    // ---- H2C stream from sg_dma_engine ----------------------------------
    input  wire [127:0]         h2c_tdata,
    input  wire                 h2c_tvalid,
    input  wire                 h2c_tuser,
    input  wire                 h2c_tlast,
    output wire                 h2c_tready,

    // ---- AXI4 to PS DDR -------------------------------------------------
    output wire [63:0]          hp1_araddr,
    output wire [7:0]           hp1_arlen,
    output wire [2:0]           hp1_arsize,
    output wire [1:0]           hp1_arburst,
    output wire                 hp1_arvalid,
    input  wire                 hp1_arready,
    input  wire [127:0]         hp1_rdata,
    input  wire [1:0]           hp1_rresp,
    input  wire                 hp1_rlast,
    input  wire                 hp1_rvalid,
    output wire                 hp1_rready,

    output wire [48:0]          hp1_awaddr,
    output wire [7:0]           hp1_awlen,
    output wire [2:0]           hp1_awsize,
    output wire [1:0]           hp1_awburst,
    output wire                 hp1_awvalid,
    input  wire                 hp1_awready,
    output wire [127:0]         hp1_wdata,
    output wire [15:0]          hp1_wstrb,
    output wire                 hp1_wlast,
    output wire                 hp1_wvalid,
    input  wire                 hp1_wready,
    input  wire [1:0]           hp1_bresp,
    input  wire                 hp1_bvalid,
    output wire                 hp1_bready,

    output wire [63:0]          hp2_araddr,
    output wire [7:0]           hp2_arlen,
    output wire [2:0]           hp2_arsize,
    output wire [1:0]           hp2_arburst,
    output wire                 hp2_arvalid,
    input  wire                 hp2_arready,
    input  wire [127:0]         hp2_rdata,
    input  wire [1:0]           hp2_rresp,
    input  wire                 hp2_rlast,
    input  wire                 hp2_rvalid,
    output wire                 hp2_rready,

    // ---- BAR0 bank 0x0A control levels and status ------------------------
    input  wire                 ov_enable,
    input  wire [48:0]          ov_dst_base,
    input  wire [31:0]          ov_slot_bytes,
    input  wire [2:0]           ov_slot_count,
    input  wire [31:0]          ov_frame_bytes,
    input  wire                 ov_auto_advance,
    input  wire [1:0]           ov_force_slot,
    input  wire [3:0]           ov_consume,
    input  wire                 blend_enable,
    input  wire                 alpha_force_opaque,
    input  wire                 blend_unlock,
    input  wire                 reader_a_rst_n,
    input  wire                 reader_b_rst_n,

    output wire                 ov_busy,
    output wire [3:0]           ov_slot_ready,
    output wire                 ov_irq,
    output wire                 blend_locked,
    output wire                 blend_busy,
    output wire                 irq_a,
    output wire                 irq_b,

    // ---- capture status -------------------------------------------------
    output wire                 video_busy,
    output wire                 video_frame_done
);
    localparam integer OB = NATIVE_PPC*24;         // 48
    localparam integer RB = NATIVE_PPC*32;         // 64

    // ========================================================================
    // HDMI RX subsystem, 2 pixels/clock
    // ========================================================================
    wire [OB-1:0] rx_ss_video_tdata;
    wire          rx_ss_video_tvalid, rx_ss_video_tready_unused, rx_ss_video_tlast;
    wire          rx_ss_video_tuser;

    v_hdmi_rx_ss_rgb u_hdmi_rx_ss (
        .s_axi_cpu_aclk        (pl_clk0),
        .s_axi_cpu_aresetn     (sys_100m_rst_n),
        .cable_detect          (1'b1),
        .link_clk              (phy_rx_video_clk),
        .s_axis_audio_aclk     (pcie_user_clk),
        .s_axis_audio_aresetn  (pcie_user_rst_n),
        .acr_cts               (), .acr_n(), .acr_valid(),
        .hpd                   (),
        .irq                   (),
        .video_clk             (phy_rx_video_clk),
        .fid                   (),
        .s_axis_video_aresetn  (sys_100m_rst_n),
        .s_axis_video_aclk     (phy_rx_video_clk),
        // GT-side link streams belong to the Video PHY, which is outside this
        // capacity vehicle; the RX pixel path below is complete.
        .LINK_DATA0_IN_tdata   ({24{1'b0}}),
        .LINK_DATA0_IN_tvalid  (1'b0),
        .LINK_DATA1_IN_tdata   ({24{1'b0}}),
        .LINK_DATA1_IN_tvalid  (1'b0),
        .LINK_DATA2_IN_tdata   ({24{1'b0}}),
        .LINK_DATA2_IN_tvalid  (1'b0),
        .SB_STATUS_IN_tdata    (8'd0),
        .SB_STATUS_IN_tvalid   (1'b0),
        .S_AXI_CPU_IN_araddr   (hdmi_ctl_araddr[47:32]),
        .S_AXI_CPU_IN_arprot   (3'd0),
        .S_AXI_CPU_IN_arready  (hdmi_ctl_arready[1]),
        .S_AXI_CPU_IN_arvalid  (hdmi_ctl_arvalid[1]),
        .S_AXI_CPU_IN_awaddr   (hdmi_ctl_awaddr[47:32]),
        .S_AXI_CPU_IN_awprot   (3'd0),
        .S_AXI_CPU_IN_awready  (hdmi_ctl_awready[1]),
        .S_AXI_CPU_IN_awvalid  (hdmi_ctl_awvalid[1]),
        .S_AXI_CPU_IN_bready   (hdmi_ctl_bready[1]),
        .S_AXI_CPU_IN_bresp    (hdmi_ctl_bresp[3:2]),
        .S_AXI_CPU_IN_bvalid   (hdmi_ctl_bvalid[1]),
        .S_AXI_CPU_IN_rdata    (hdmi_ctl_rdata[63:32]),
        .S_AXI_CPU_IN_rready   (hdmi_ctl_rready[1]),
        .S_AXI_CPU_IN_rresp    (hdmi_ctl_rresp[3:2]),
        .S_AXI_CPU_IN_rvalid   (hdmi_ctl_rvalid[1]),
        .S_AXI_CPU_IN_wdata    (hdmi_ctl_wdata[63:32]),
        .S_AXI_CPU_IN_wready   (hdmi_ctl_wready[1]),
        .S_AXI_CPU_IN_wstrb    (hdmi_ctl_wstrb[7:4]),
        .S_AXI_CPU_IN_wvalid   (hdmi_ctl_wvalid[1]),
        .DDC_OUT_scl_i         (1'b1), .DDC_OUT_scl_o (), .DDC_OUT_scl_t (),
        .DDC_OUT_sda_i         (1'b1), .DDC_OUT_sda_o (), .DDC_OUT_sda_t (),
        .AUDIO_OUT_tdata       (), .AUDIO_OUT_tid(), .AUDIO_OUT_tready(1'b1),
        .AUDIO_OUT_tvalid      (),
        .VIDEO_OUT_tdata       (rx_ss_video_tdata),
        .VIDEO_OUT_tlast       (rx_ss_video_tlast),
        .VIDEO_OUT_tready      (rx_ss_video_tready_unused),
        .VIDEO_OUT_tuser       (rx_ss_video_tuser),
        .VIDEO_OUT_tvalid      (rx_ss_video_tvalid)
    );

    // ========================================================================
    // packed RGB24 byte gearbox + crossing into the PCIe/capture domain
    // ========================================================================
    wire [127:0] pay_tdata;
    wire         pay_tuser, pay_tvalid, pay_tready;
    wire [10:0]  pay_avail;
    wire         pay_ovf, pay_eol_err;

    sc7f0_rgb24_axis_pack #(
        .NATIVE_PPC (NATIVE_PPC),
        .FIFO_DEPTH (1024)
    ) u_rgb24_pack (
        .s_clk              (phy_rx_video_clk),
        .s_rst_n            (!rx_video_rst),
        .s_axis_tdata       (rx_ss_video_tdata),
        .s_axis_tvalid      (rx_ss_video_tvalid),
        .s_axis_tlast       (rx_ss_video_tlast),
        .s_axis_tuser       (rx_ss_video_tuser),
        .s_axis_tready      (),                    // VIDEO_OUT is never stalled
        .m_clk              (capture_clk),
        .m_rst_n            (capture_rst_n),
        .m_axis_tdata       (pay_tdata),
        .m_axis_tuser       (pay_tuser),
        .m_axis_tvalid      (pay_tvalid),
        .m_axis_tready      (pay_tready),
        .m_axis_avail       (pay_avail),
        .overflow_sticky    (pay_ovf),
        .line_align_sticky  (pay_eol_err)
    );

    // ========================================================================
    // packed RGB24 C2H engine (channel 0 owner)
    // ========================================================================
    wire         eng_req_valid, eng_req_last;
    wire [63:0]  eng_req_addr;
    wire [10:0]  eng_req_dw;
    wire [127:0] eng_req_data;
    wire         eng_req_ready, eng_req_ack;

    sc7f0_rgb24_c2h_engine #(
        .MAX_WIDTH       (4096),
        .PCIE_DATA_WIDTH (128),
        .MAX_REQ_BYTES   (256),
        .SRC_FIFO_DEPTH  (1024)
    ) u_rgb24_c2h (
        .clk                 (capture_clk),
        .rst_n               (capture_rst_n),
        .desc_valid          (desc_valid),
        .desc_ready          (desc_ready),
        .desc_sg_mode        (desc_sg_mode),
        .plane_y_addr        (plane_y_addr),
        .frame_width         (frame_width),
        .frame_height        (frame_height),
        .frame_stride        (frame_stride),
        .sgl_wr_en           (1'b0),
        .sgl_wr_addr         (64'd0),
        .sgl_wr_len          (32'd0),
        .sgl_wr_flags        (32'd0),
        .cur_sgl_count       (),
        .sgl_pop_ready       (),
        .dbg_bus             (),
        .global_timestamp    (global_timestamp),
        .p_axis_tdata        (pay_tdata),
        .p_axis_tuser        (pay_tuser),
        .p_axis_tvalid       (pay_tvalid),
        .p_axis_avail        (pay_avail),
        .p_axis_tready       (pay_tready),
        .c2h_req_valid       (eng_req_valid),
        .c2h_req_addr        (eng_req_addr),
        .c2h_req_dw_len      (eng_req_dw),
        .c2h_req_data        (eng_req_data),
        .c2h_req_last        (eng_req_last),
        .c2h_req_data_ready  (eng_req_ready),
        .c2h_req_ack         (eng_req_ack),
        .video_busy          (video_busy),
        .video_frame_done    (video_frame_done),
        .frame_pts           (),
        .protocol_error_count(),
        .drop_count          (),
        .frames_completed    (),
        .align_discard_count (),
        .bytes_committed     (),
        .active_line_bytes   (),
        .active_stride       (),
        .src_overflow_sticky (pay_ovf),
        .src_line_align_sticky(pay_eol_err),
        .error_sticky        ()
    );

    // 128-bit engine request -> the card's 256-bit requester domain
    video_req_cdc #(
        .MAX_DWORDS    (64),
        .FIFO_DEPTH    (512),
        .WR_DATA_WIDTH (128),
        .DATA_WIDTH    (PCIE_DATA_WIDTH)
    ) u_req_cdc (
        .wr_clk          (capture_clk),
        .wr_rst_n        (capture_rst_n),
        .s_req_valid     (eng_req_valid),
        .s_req_addr      (eng_req_addr),
        .s_req_dw_len    (eng_req_dw),
        .s_req_data      (eng_req_data),
        .s_req_data_ready(eng_req_ready),
        .s_req_ack       (eng_req_ack),
        .s_frame_done    (video_frame_done),
        .rd_clk          (pcie_user_clk),
        .rd_rst_n        (pcie_user_rst_n),
        .m_req_valid     (c2h_req_valid),
        .m_req_addr      (c2h_req_addr),
        .m_req_dw_len    (c2h_req_dw_len),
        .m_req_data      (c2h_req_data),
        .m_req_data_ready(c2h_req_data_ready),
        .m_req_ack       (c2h_req_ack),
        .m_frame_done    (),
        .m_fifo_empty    (),
        .m_fifo_count    ()
    );

    // ========================================================================
    // overlay H2C -> PS DDR slot writer (HP1 write channels)
    // ========================================================================
    sc7f0_overlay_writer #(
        .DATA_WIDTH (128),
        .ADDR_WIDTH (49),
        .FIFO_DEPTH (1024),
        .MAX_SLOTS  (4)
    ) u_overlay (
        .clk               (pcie_user_clk),
        .rst_n             (pcie_user_rst_n),
        .s_axis_tdata      (h2c_tdata),
        .s_axis_tvalid     (h2c_tvalid),
        .s_axis_tuser      (h2c_tuser),
        .s_axis_tlast      (h2c_tlast),
        .s_axis_tready     (h2c_tready),
        .ov_enable         (ov_enable),
        .ov_dst_base       (ov_dst_base),
        .ov_slot_bytes     (ov_slot_bytes),
        .ov_slot_count     (ov_slot_count),
        .ov_frame_bytes    (ov_frame_bytes),
        .ov_auto_advance   (ov_auto_advance),
        .ov_force_slot     (ov_force_slot),
        .ov_consume        (ov_consume),
        .ov_busy           (ov_busy),
        .ov_slot_ready     (ov_slot_ready),
        .ov_write_slot     (),
        .ov_frames_done    (),
        .ov_bytes_written  (),
        .ov_stall_sticky   (),
        .ov_over_sticky    (),
        .ov_axi_err_sticky (),
        .ov_misalign_sticky(),
        .ov_irq_pulse      (ov_irq),
        .mem_clk           (capture_clk),
        .mem_rst_n         (capture_rst_n),
        .m_axi_awaddr      (hp1_awaddr),
        .m_axi_awlen       (hp1_awlen),
        .m_axi_awsize      (hp1_awsize),
        .m_axi_awburst     (hp1_awburst),
        .m_axi_awcache     (),
        .m_axi_awvalid     (hp1_awvalid),
        .m_axi_awready     (hp1_awready),
        .m_axi_wdata       (hp1_wdata),
        .m_axi_wstrb       (hp1_wstrb),
        .m_axi_wlast       (hp1_wlast),
        .m_axi_wvalid      (hp1_wvalid),
        .m_axi_wready      (hp1_wready),
        .m_axi_bresp       (hp1_bresp),
        .m_axi_bvalid      (hp1_bvalid),
        .m_axi_bready      (hp1_bready)
    );

    // ========================================================================
    // two independent readers + 2 PPC alpha compositor + tx crossing
    // ========================================================================
    wire [OB-1:0] comp_tdata;
    wire          comp_tvalid, comp_tready, comp_tlast, comp_tuser;
    sc7f0_rgb_compositor #(
        .PPC (NATIVE_PPC)
    ) u_compositor (
        .csr_clk             (pl_clk0),
        .csr_rst_n           (sys_100m_rst_n),
        .mem_clk             (capture_clk),
        .mem_rst_n           (capture_rst_n),
        .reader_a_rst_n      (reader_a_rst_n),
        .reader_b_rst_n      (reader_b_rst_n),
        .tx_clk              (phy_tx_video_clk),
        .tx_rst_n            (!tx_video_rst),
        // Reader-A control keeps today's aperture: slice 7, 0xB0080000.
        .s_axi_a_awaddr      (hdmi_ctl_awaddr[255:224]),
        .s_axi_a_awvalid     (hdmi_ctl_awvalid[7]),
        .s_axi_a_awready     (hdmi_ctl_awready[7]),
        .s_axi_a_wdata       (hdmi_ctl_wdata[255:224]),
        .s_axi_a_wstrb       (hdmi_ctl_wstrb[31:28]),
        .s_axi_a_wvalid      (hdmi_ctl_wvalid[7]),
        .s_axi_a_wready      (hdmi_ctl_wready[7]),
        .s_axi_a_bresp       (hdmi_ctl_bresp[15:14]),
        .s_axi_a_bvalid      (hdmi_ctl_bvalid[7]),
        .s_axi_a_bready      (hdmi_ctl_bready[7]),
        .s_axi_a_araddr      (hdmi_ctl_araddr[255:224]),
        .s_axi_a_arvalid     (hdmi_ctl_arvalid[7]),
        .s_axi_a_arready     (hdmi_ctl_arready[7]),
        .s_axi_a_rdata       (hdmi_ctl_rdata[255:224]),
        .s_axi_a_rresp       (hdmi_ctl_rresp[15:14]),
        .s_axi_a_rvalid      (hdmi_ctl_rvalid[7]),
        .s_axi_a_rready      (hdmi_ctl_rready[7]),
        // Reader-B control, new slice 8 at 0xB0090000.
        .s_axi_b_awaddr      (hdmi_ctl_awaddr[287:256]),
        .s_axi_b_awvalid     (hdmi_ctl_awvalid[8]),
        .s_axi_b_awready     (hdmi_ctl_awready[8]),
        .s_axi_b_wdata       (hdmi_ctl_wdata[287:256]),
        .s_axi_b_wstrb       (hdmi_ctl_wstrb[35:32]),
        .s_axi_b_wvalid      (hdmi_ctl_wvalid[8]),
        .s_axi_b_wready      (hdmi_ctl_wready[8]),
        .s_axi_b_bresp       (hdmi_ctl_bresp[17:16]),
        .s_axi_b_bvalid      (hdmi_ctl_bvalid[8]),
        .s_axi_b_bready      (hdmi_ctl_bready[8]),
        .s_axi_b_araddr      (hdmi_ctl_araddr[287:256]),
        .s_axi_b_arvalid     (hdmi_ctl_arvalid[8]),
        .s_axi_b_arready     (hdmi_ctl_arready[8]),
        .s_axi_b_rdata       (hdmi_ctl_rdata[287:256]),
        .s_axi_b_rresp       (hdmi_ctl_rresp[17:16]),
        .s_axi_b_rvalid      (hdmi_ctl_rvalid[8]),
        .s_axi_b_rready      (hdmi_ctl_rready[8]),
        .a_araddr            (hp1_araddr),
        .a_arlen             (hp1_arlen),
        .a_arsize            (hp1_arsize),
        .a_arburst           (hp1_arburst),
        .a_arvalid           (hp1_arvalid),
        .a_arready           (hp1_arready),
        .a_rdata             (hp1_rdata),
        .a_rresp             (hp1_rresp),
        .a_rlast             (hp1_rlast),
        .a_rvalid            (hp1_rvalid),
        .a_rready            (hp1_rready),
        .b_araddr            (hp2_araddr),
        .b_arlen             (hp2_arlen),
        .b_arsize            (hp2_arsize),
        .b_arburst           (hp2_arburst),
        .b_arvalid           (hp2_arvalid),
        .b_arready           (hp2_arready),
        .b_rdata             (hp2_rdata),
        .b_rresp             (hp2_rresp),
        .b_rlast             (hp2_rlast),
        .b_rvalid            (hp2_rvalid),
        .b_rready            (hp2_rready),
        .blend_enable        (blend_enable),
        .alpha_force_opaque  (alpha_force_opaque),
        .blend_unlock        (blend_unlock),
        .m_axis_video_tdata  (comp_tdata),
        .m_axis_video_tvalid (comp_tvalid),
        .m_axis_video_tready (comp_tready),
        .m_axis_video_tlast  (comp_tlast),
        .m_axis_video_tuser  (comp_tuser),
        .irq_a               (irq_a),
        .irq_b               (irq_b),
        .blend_locked        (blend_locked),
        .blend_busy          (blend_busy),
        .lock_lost_count     (),
        .sat_watchdog_count  (),
        .beats_blended       ()
    );

    // ========================================================================
    // HDMI TX subsystem, 2 pixels/clock
    // ========================================================================
    wire [OB-1:0] tx_ss_video_tdata;
    wire          tx_ss_video_tvalid, tx_ss_video_tready, tx_ss_video_tlast;
    wire          tx_ss_video_tuser;

    sc7f0_hdmi_tx_mux #(
        .TDATA_WIDTH      (OB),
        .DRAIN_UNSELECTED (0),
        .SEL_STABLE_CYCLES(8),
        .STALL_LIMIT      (1048576)
    ) u_hdmi_tx_mux (
        .clk                 (phy_tx_video_clk),
        .rst_n               (!tx_video_rst),
        .mux_sel             (2'b01),
        .s0_axis_video_tdata ({OB{1'b0}}),
        .s0_axis_video_tvalid(1'b0),
        .s0_axis_video_tready(),
        .s0_axis_video_tlast (1'b0),
        .s0_axis_video_tuser (1'b0),
        .s1_axis_video_tdata (comp_tdata),
        .s1_axis_video_tvalid(comp_tvalid),
        .s1_axis_video_tready(comp_tready),
        .s1_axis_video_tlast (comp_tlast),
        .s1_axis_video_tuser (comp_tuser),
        .s2_axis_video_tdata ({OB{1'b0}}),
        .s2_axis_video_tvalid(1'b0),
        .s2_axis_video_tready(),
        .s2_axis_video_tlast (1'b0),
        .s2_axis_video_tuser (1'b0),
        .m_axis_video_tdata  (tx_ss_video_tdata),
        .m_axis_video_tvalid (tx_ss_video_tvalid),
        .m_axis_video_tready (tx_ss_video_tready),
        .m_axis_video_tlast  (tx_ss_video_tlast),
        .m_axis_video_tuser  (tx_ss_video_tuser)
    );

    v_hdmi_tx_ss_rgb u_hdmi_tx_ss (
        .s_axi_cpu_aclk        (pl_clk0),
        .s_axi_cpu_aresetn     (sys_100m_rst_n),
        .link_clk              (phy_tx_video_clk),
        .s_axis_audio_aclk     (pcie_user_clk),
        .s_axis_audio_aresetn  (pcie_user_rst_n),
        .acr_cts               (20'd148500),
        .acr_n                 (20'd6144),
        .acr_valid             (1'b0),
        .hpd                   (1'b1),
        .irq                   (),
        .video_clk             (phy_tx_video_clk),
        .fid                   (1'b0),
        .locked                (),
        .s_axis_video_aclk     (phy_tx_video_clk),
        .s_axis_video_aresetn  (!tx_video_rst),
        .VIDEO_IN_tdata        (tx_ss_video_tdata),
        .VIDEO_IN_tlast        (tx_ss_video_tlast),
        .VIDEO_IN_tready       (tx_ss_video_tready),
        .VIDEO_IN_tuser        (tx_ss_video_tuser),
        .VIDEO_IN_tvalid       (tx_ss_video_tvalid),
        .SB_STATUS_IN_tdata    (8'd0),
        .SB_STATUS_IN_tvalid   (1'b0),
        .AUDIO_IN_tdata        (32'd0),
        .AUDIO_IN_tid          (8'd0),
        .AUDIO_IN_tready       (),
        .AUDIO_IN_tvalid       (1'b0),
        .S_AXI_CPU_IN_araddr   (hdmi_ctl_araddr[80:64]),
        .S_AXI_CPU_IN_arprot   (3'd0),
        .S_AXI_CPU_IN_arready  (hdmi_ctl_arready[2]),
        .S_AXI_CPU_IN_arvalid  (hdmi_ctl_arvalid[2]),
        .S_AXI_CPU_IN_awaddr   (hdmi_ctl_awaddr[80:64]),
        .S_AXI_CPU_IN_awprot   (3'd0),
        .S_AXI_CPU_IN_awready  (hdmi_ctl_awready[2]),
        .S_AXI_CPU_IN_awvalid  (hdmi_ctl_awvalid[2]),
        .S_AXI_CPU_IN_bready   (hdmi_ctl_bready[2]),
        .S_AXI_CPU_IN_bresp    (hdmi_ctl_bresp[5:4]),
        .S_AXI_CPU_IN_bvalid   (hdmi_ctl_bvalid[2]),
        .S_AXI_CPU_IN_rdata    (hdmi_ctl_rdata[95:64]),
        .S_AXI_CPU_IN_rready   (hdmi_ctl_rready[2]),
        .S_AXI_CPU_IN_rresp    (hdmi_ctl_rresp[5:4]),
        .S_AXI_CPU_IN_rvalid   (hdmi_ctl_rvalid[2]),
        .S_AXI_CPU_IN_wdata    (hdmi_ctl_wdata[95:64]),
        .S_AXI_CPU_IN_wready   (hdmi_ctl_wready[2]),
        .S_AXI_CPU_IN_wstrb    (hdmi_ctl_wstrb[11:8]),
        .S_AXI_CPU_IN_wvalid   (hdmi_ctl_wvalid[2]),
        .DDC_OUT_scl_i         (1'b1), .DDC_OUT_scl_o (), .DDC_OUT_scl_t (),
        .DDC_OUT_sda_i         (1'b1), .DDC_OUT_sda_o (), .DDC_OUT_sda_t (),
        .LINK_DATA0_OUT_tdata  (), .LINK_DATA0_OUT_tvalid(),
        .LINK_DATA1_OUT_tdata  (), .LINK_DATA1_OUT_tvalid(),
        .LINK_DATA2_OUT_tdata  (), .LINK_DATA2_OUT_tvalid()
    );

    // Unused control slices answer with a bounded DECERR instead of hanging the
    // PS: slice 0 (TPG era), 3 (retired VCU packet CSR at 0xB0040000), 4, 5 and
    // 6 (PS V4L2 capture branch, a legacy-personality function).
    genvar s;
    generate
        for (s = 0; s < 9; s = s + 1) begin : g_ctl_idle
            if (s == 1 || s == 2 || s == 7 || s == 8) begin : g_used
                // driven by the subsystems above
            end else begin : g_idle
                sc7f0_axil_disabled #(.ADDR_WIDTH(32)) u_idle_slice (
                    .clk           (pl_clk0),
                    .rst_n         (sys_100m_rst_n),
                    .s_axil_awaddr (hdmi_ctl_awaddr[s*32 +: 32]),
                    .s_axil_awvalid(hdmi_ctl_awvalid[s]),
                    .s_axil_awready(hdmi_ctl_awready[s]),
                    .s_axil_wdata  (hdmi_ctl_wdata[s*32 +: 32]),
                    .s_axil_wstrb  (hdmi_ctl_wstrb[s*4 +: 4]),
                    .s_axil_wvalid (hdmi_ctl_wvalid[s]),
                    .s_axil_wready (hdmi_ctl_wready[s]),
                    .s_axil_bresp  (hdmi_ctl_bresp[s*2 +: 2]),
                    .s_axil_bvalid (hdmi_ctl_bvalid[s]),
                    .s_axil_bready (hdmi_ctl_bready[s]),
                    .s_axil_araddr (hdmi_ctl_araddr[s*32 +: 32]),
                    .s_axil_arvalid(hdmi_ctl_arvalid[s]),
                    .s_axil_arready(hdmi_ctl_arready[s]),
                    .s_axil_rdata  (hdmi_ctl_rdata[s*32 +: 32]),
                    .s_axil_rresp  (hdmi_ctl_rresp[s*2 +: 2]),
                    .s_axil_rvalid (hdmi_ctl_rvalid[s]),
                    .s_axil_rready (hdmi_ctl_rready[s])
                );
            end
        end
    endgenerate
endmodule
`default_nettype wire
