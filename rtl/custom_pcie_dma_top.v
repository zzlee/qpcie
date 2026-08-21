// ============================================================================
// Module: custom_pcie_dma_top
// Description: Multi-Channel 2D Video & Audio PCIe DMA Controller (AXI4-Stream Native).
//              Uses Verilog parameter & generator loops to configure arbitrary channels:
//              - NUM_VIDEO_CH: AXI4-Stream Video Interfaces (s_axis_video / m_axis_video)
//              - NUM_AUDIO_CH: AXI4-Stream AES3 Audio Interfaces (s_axis_audio / m_axis_audio)
//              - Dual-BAR: BAR0 (DMA Control), BAR1 (User IP Cores Interconnect)
//              - Direct Streaming Architecture: Completely replaces AXI MM with native streams.
// ============================================================================

`timescale 1ns / 1ps

module custom_pcie_dma_top #(
    parameter PCIE_DATA_WIDTH  = 256,
    parameter PCIE_KEEP_WIDTH  = PCIE_DATA_WIDTH / 32,
    parameter NUM_VIDEO_CH     = 4,
    parameter NUM_AUDIO_CH     = 4,
    parameter VIDEO_DATA_WIDTH = 32,
    parameter AUDIO_DATA_WIDTH = 32
)(
    input  wire                                             clk,
    input  wire                                             rst_n,

    // PCIe CQ Interface (PCIe IP -> DMA Top)
    input  wire [PCIE_DATA_WIDTH-1:0]                       s_axis_cq_tdata,
    input  wire                                             s_axis_cq_tvalid,
    input  wire                                             s_axis_cq_tlast,
    input  wire [87:0]                                      s_axis_cq_tuser,
    input  wire [PCIE_KEEP_WIDTH-1:0]                       s_axis_cq_tkeep,
    output wire                                             s_axis_cq_tready,

    // PCIe CC Interface (DMA Top -> PCIe IP)
    output wire [PCIE_DATA_WIDTH-1:0]                       m_axis_cc_tdata,
    output wire                                             m_axis_cc_tvalid,
    output wire                                             m_axis_cc_tlast,
    output wire [32:0]                                      m_axis_cc_tuser,
    output wire [PCIE_KEEP_WIDTH-1:0]                       m_axis_cc_tkeep,
    input  wire                                             m_axis_cc_tready,

    // PCIe RQ Interface (DMA Top -> PCIe IP)
    output wire [PCIE_DATA_WIDTH-1:0]                       m_axis_rq_tdata,
    output wire                                             m_axis_rq_tvalid,
    output wire                                             m_axis_rq_tlast,
    output wire [61:0]                                      m_axis_rq_tuser,
    output wire [PCIE_KEEP_WIDTH-1:0]                       m_axis_rq_tkeep,
    input  wire                                             m_axis_rq_tready,

    // PCIe RC Interface (PCIe IP -> DMA Top)
    input  wire [PCIE_DATA_WIDTH-1:0]                       s_axis_rc_tdata,
    input  wire                                             s_axis_rc_tvalid,
    input  wire                                             s_axis_rc_tlast,
    input  wire [74:0]                                      s_axis_rc_tuser,
    input  wire [PCIE_KEEP_WIDTH-1:0]                       s_axis_rc_tkeep,
    output wire                                             s_axis_rc_tready,

    // BAR1 AXI4-Lite Master Interface (Connects to Interconnect for User IP Cores: I2C, UART, etc.)
    output wire [31:0]                                      m_axil_bar1_awaddr,
    output wire                                             m_axil_bar1_awvalid,
    input  wire                                             m_axil_bar1_awready,
    output wire [31:0]                                      m_axil_bar1_wdata,
    output wire [3:0]                                       m_axil_bar1_wstrb,
    output wire                                             m_axil_bar1_wvalid,
    input  wire                                             m_axil_bar1_wready,
    input  wire [1:0]                                       m_axil_bar1_bresp,
    input  wire                                             m_axil_bar1_bvalid,
    output wire                                             m_axil_bar1_bready,

    output wire [31:0]                                      m_axil_bar1_araddr,
    output wire                                             m_axil_bar1_arvalid,
    input  wire                                             m_axil_bar1_arready,
    input  wire [31:0]                                      m_axil_bar1_rdata,
    input  wire [1:0]                                       m_axil_bar1_rresp,
    input  wire                                             m_axil_bar1_rvalid,
    output wire                                             m_axil_bar1_rready,

    // Multi-Channel AXI4-Stream Video Interfaces (s_axis_video: C2H In, m_axis_video: H2C Out)
    input  wire [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0]       s_axis_video_tdata,
    input  wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tvalid,
    input  wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tlast,
    input  wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tuser, // tuser[0] = SOF
    output wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tready,

    output wire [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0]       m_axis_video_tdata,
    output wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tvalid,
    output wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tlast,
    output wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tuser,
    input  wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tready,

    // Multi-Channel AXI4-Stream Audio Interfaces (AES3 Subframes)
    input  wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0]       s_axis_audio_tdata,
    input  wire [NUM_AUDIO_CH-1:0]                          s_axis_audio_tvalid,
    input  wire [NUM_AUDIO_CH-1:0]                          s_axis_audio_tlast,
    output wire [NUM_AUDIO_CH-1:0]                          s_axis_audio_tready,

    output wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0]       m_axis_audio_tdata,
    output wire [NUM_AUDIO_CH-1:0]                          m_axis_audio_tvalid,
    output wire [NUM_AUDIO_CH-1:0]                          m_axis_audio_tlast,
    input  wire [NUM_AUDIO_CH-1:0]                          m_axis_audio_tready,

    // Interrupt Pins
    output wire                                             usr_irq_req,
    input  wire                                             usr_irq_ack
);

    // Internal Wires for BAR0 Inter-module Connection
    wire [31:0] bar0_axil_awaddr, bar0_axil_wdata, bar0_axil_araddr, bar0_axil_rdata;
    wire [3:0]  bar0_axil_wstrb;
    wire [1:0]  bar0_axil_bresp, bar0_axil_rresp;
    wire        bar0_axil_awvalid, bar0_axil_awready, bar0_axil_wvalid, bar0_axil_wready;
    wire        bar0_axil_bvalid, bar0_axil_bready, bar0_axil_arvalid, bar0_axil_arready;
    wire        bar0_axil_rvalid, bar0_axil_rready;

    wire        read_req_valid, read_req_ack, read_req_bar_sel;
    wire [7:0]  read_req_tag;
    wire [15:0] read_req_id;
    wire [6:0]  read_req_lower_addr;
    wire [10:0] read_req_tc;

    wire [31:0] reg_dma_ctrl, reg_dma_status, reg_irq_ctrl, reg_irq_status;
    wire [31:0] reg_slice_height;
    wire [63:0] reg_h2c_ring_addr, reg_c2h_ring_addr;
    wire [15:0] reg_h2c_ring_size, reg_h2c_tail_ptr, reg_h2c_head_ptr;
    wire [15:0] reg_c2h_ring_size, reg_c2h_tail_ptr, reg_c2h_head_ptr;
    wire [31:0] completed_h2c_count, completed_c2h_count;

    wire        tag_alloc_req, tag_alloc_valid, tag_full;
    wire [7:0]  tag_alloc_tag, tag_free_val;
    wire        tag_free_req;

    wire        desc_req_valid, desc_req_ack;
    wire [63:0] desc_req_addr;
    wire [10:0] desc_req_dw_len;
    wire [7:0]  desc_req_tag;

    wire        desc_cpl_valid, desc_cpl_last;
    wire [511:0] desc_cpl_data;

    wire        h2c_desc_valid, h2c_desc_ready;
    wire [63:0] h2c_plane0_src, h2c_plane0_dst;
    wire [63:0] h2c_plane1_src, h2c_plane1_dst;
    wire [63:0] h2c_plane2_src, h2c_plane2_dst;
    wire [15:0] h2c_line_width, h2c_line_count;
    wire [15:0] h2c_src_stride, h2c_dst_stride;
    wire [15:0] h2c_plane12_width, h2c_plane12_count;
    wire [3:0]  h2c_format, h2c_plane_count;
    wire [15:0] h2c_desc_ctrl;

    wire        c2h_desc_valid, c2h_desc_ready;
    wire [63:0] c2h_plane0_src, c2h_plane0_dst;
    wire [63:0] c2h_plane1_src, c2h_plane1_dst;
    wire [63:0] c2h_plane2_src, c2h_plane2_dst;
    wire [15:0] c2h_line_width, c2h_line_count;
    wire [15:0] c2h_src_stride, c2h_dst_stride;
    wire [15:0] c2h_plane12_width, c2h_plane12_count;
    wire [3:0]  c2h_format, c2h_plane_count;
    wire [15:0] c2h_desc_ctrl;

    wire        h2c_req_valid, h2c_req_ack;
    wire [63:0] h2c_req_addr;
    wire [10:0] h2c_req_dw_len;
    wire [7:0]  h2c_req_tag;

    wire        h2c_fifo_wvalid, h2c_fifo_wlast;
    wire [PCIE_DATA_WIDTH-1:0] h2c_fifo_wdata;

    wire        irq_req_valid, irq_req_ack;
    wire [7:0]  irq_req_code;

    // Stream Engine Channel Wires (Flat Packed Vectors for Verilog Standard Compatibility)
    wire [NUM_VIDEO_CH-1:0]                    v_c2h_req_valid;
    wire [(NUM_VIDEO_CH*64)-1:0]               v_c2h_req_addr;
    wire [(NUM_VIDEO_CH*11)-1:0]               v_c2h_req_dw_len;
    wire [(NUM_VIDEO_CH*PCIE_DATA_WIDTH)-1:0]   v_c2h_req_data;
    wire [NUM_VIDEO_CH-1:0]                    v_c2h_req_last;
    wire [NUM_VIDEO_CH-1:0]                    v_busy, v_done;

    wire [NUM_AUDIO_CH-1:0]                    a_c2h_req_valid;
    wire [(NUM_AUDIO_CH*64)-1:0]               a_c2h_req_addr;
    wire [(NUM_AUDIO_CH*11)-1:0]               a_c2h_req_dw_len;
    wire [(NUM_AUDIO_CH*PCIE_DATA_WIDTH)-1:0]   a_c2h_req_data;
    wire [NUM_AUDIO_CH-1:0]                    a_c2h_req_last;
    wire [NUM_AUDIO_CH-1:0]                    a_busy, a_done;

    // SG DMA Engine Wires
    wire        sg_h2c_desc_ready, sg_c2h_desc_ready;
    wire        sg_h2c_req_valid, sg_h2c_req_ack;
    wire [63:0] sg_h2c_req_addr;
    wire [10:0] sg_h2c_req_dw_len;
    wire [7:0]  sg_h2c_req_tag;
    wire        sg_c2h_req_valid, sg_c2h_req_ack, sg_c2h_req_last;
    wire [63:0] sg_c2h_req_addr;
    wire [10:0] sg_c2h_req_dw_len;
    wire [PCIE_DATA_WIDTH-1:0] sg_c2h_req_data;
    wire [31:0] sg_h2c_bytes, sg_c2h_bytes;
    wire        sg_h2c_busy, sg_c2h_busy;

    // Multiplexed C2H Request Signals
    reg                        c2h_req_valid_mux;
    reg  [63:0]                c2h_req_addr_mux;
    reg  [10:0]                c2h_req_dw_len_mux;
    reg  [PCIE_DATA_WIDTH-1:0] c2h_req_data_mux;
    reg                        c2h_req_last_mux;
    wire                       c2h_req_ack_mux;

    integer i_arb;
    reg     c2h_arb_found;

    always @(*) begin
        c2h_req_valid_mux  = 1'b0;
        c2h_req_addr_mux   = 64'd0;
        c2h_req_dw_len_mux = 11'd0;
        c2h_req_data_mux   = {PCIE_DATA_WIDTH{1'b0}};
        c2h_req_last_mux   = 1'b0;
        c2h_arb_found      = 1'b0;

        // Priority 1: SG DMA Engine
        if (sg_c2h_req_valid) begin
            c2h_req_valid_mux  = 1'b1;
            c2h_req_addr_mux   = sg_c2h_req_addr;
            c2h_req_dw_len_mux = sg_c2h_req_dw_len;
            c2h_req_data_mux   = sg_c2h_req_data;
            c2h_req_last_mux   = sg_c2h_req_last;
            c2h_arb_found      = 1'b1;
        end

        for (i_arb = 0; i_arb < NUM_VIDEO_CH; i_arb = i_arb + 1) begin
            if (!c2h_arb_found && v_c2h_req_valid[i_arb]) begin
                c2h_req_valid_mux = 1'b1;
                c2h_req_addr_mux   = v_c2h_req_addr[(i_arb*64) +: 64];
                c2h_req_dw_len_mux = v_c2h_req_dw_len[(i_arb*11) +: 11];
                c2h_req_data_mux   = v_c2h_req_data[(i_arb*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH];
                c2h_req_last_mux   = v_c2h_req_last[i_arb];
                c2h_arb_found      = 1'b1;
            end
        end

        for (i_arb = 0; i_arb < NUM_AUDIO_CH; i_arb = i_arb + 1) begin
            if (!c2h_arb_found && a_c2h_req_valid[i_arb]) begin
                c2h_req_valid_mux = 1'b1;
                c2h_req_addr_mux   = a_c2h_req_addr[(i_arb*64) +: 64];
                c2h_req_dw_len_mux = a_c2h_req_dw_len[(i_arb*11) +: 11];
                c2h_req_data_mux   = a_c2h_req_data[(i_arb*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH];
                c2h_req_last_mux   = a_c2h_req_last[i_arb];
                c2h_arb_found      = 1'b1;
            end
        end
    end

    assign sg_c2h_req_ack = sg_c2h_req_valid ? c2h_req_ack_mux : 1'b0;

    assign reg_dma_status = {16'd0, sg_c2h_busy, sg_h2c_busy, 6'd0, a_done[0], v_done[0], a_busy[0], v_busy[0]};

    // 1. CQ RX Decoder
    cq_rx_decoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_cq_rx_decoder (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_cq_tdata(s_axis_cq_tdata),
        .s_axis_cq_tvalid(s_axis_cq_tvalid),
        .s_axis_cq_tlast(s_axis_cq_tlast),
        .s_axis_cq_tuser(s_axis_cq_tuser),
        .s_axis_cq_tkeep(s_axis_cq_tkeep),
        .s_axis_cq_tready(s_axis_cq_tready),
        .m_axil_bar0_awaddr(bar0_axil_awaddr),
        .m_axil_bar0_awvalid(bar0_axil_awvalid),
        .m_axil_bar0_awready(bar0_axil_awready),
        .m_axil_bar0_wdata(bar0_axil_wdata),
        .m_axil_bar0_wstrb(bar0_axil_wstrb),
        .m_axil_bar0_wvalid(bar0_axil_wvalid),
        .m_axil_bar0_wready(bar0_axil_wready),
        .m_axil_bar0_bresp(bar0_axil_bresp),
        .m_axil_bar0_bvalid(bar0_axil_bvalid),
        .m_axil_bar0_bready(bar0_axil_bready),
        .m_axil_bar0_araddr(bar0_axil_araddr),
        .m_axil_bar0_arvalid(bar0_axil_arvalid),
        .m_axil_bar0_arready(bar0_axil_arready),
        .m_axil_bar0_rdata(bar0_axil_rdata),
        .m_axil_bar0_rresp(bar0_axil_rresp),
        .m_axil_bar0_rvalid(bar0_axil_rvalid),
        .m_axil_bar0_rready(bar0_axil_rready),
        .m_axil_bar1_awaddr(m_axil_bar1_awaddr),
        .m_axil_bar1_awvalid(m_axil_bar1_awvalid),
        .m_axil_bar1_awready(m_axil_bar1_awready),
        .m_axil_bar1_wdata(m_axil_bar1_wdata),
        .m_axil_bar1_wstrb(m_axil_bar1_wstrb),
        .m_axil_bar1_wvalid(m_axil_bar1_wvalid),
        .m_axil_bar1_wready(m_axil_bar1_wready),
        .m_axil_bar1_bresp(m_axil_bar1_bresp),
        .m_axil_bar1_bvalid(m_axil_bar1_bvalid),
        .m_axil_bar1_bready(m_axil_bar1_bready),
        .m_axil_bar1_araddr(m_axil_bar1_araddr),
        .m_axil_bar1_arvalid(m_axil_bar1_arvalid),
        .m_axil_bar1_arready(m_axil_bar1_arready),
        .m_axil_bar1_rdata(m_axil_bar1_rdata),
        .m_axil_bar1_rresp(m_axil_bar1_rresp),
        .m_axil_bar1_rvalid(m_axil_bar1_rvalid),
        .m_axil_bar1_rready(m_axil_bar1_rready),
        .read_req_valid(read_req_valid),
        .read_req_tag(read_req_tag),
        .read_req_id(read_req_id),
        .read_req_lower_addr(read_req_lower_addr),
        .read_req_tc(read_req_tc),
        .read_req_bar_sel(read_req_bar_sel),
        .read_req_ack(read_req_ack)
    );

    // 2. CC TX Encoder
    cc_tx_encoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_cc_tx_encoder (
        .clk(clk),
        .rst_n(rst_n),
        .m_axis_cc_tdata(m_axis_cc_tdata),
        .m_axis_cc_tvalid(m_axis_cc_tvalid),
        .m_axis_cc_tlast(m_axis_cc_tlast),
        .m_axis_cc_tuser(m_axis_cc_tuser),
        .m_axis_cc_tkeep(m_axis_cc_tkeep),
        .m_axis_cc_tready(m_axis_cc_tready),
        .read_req_valid(read_req_valid),
        .read_req_tag(read_req_tag),
        .read_req_id(read_req_id),
        .read_req_lower_addr(read_req_lower_addr),
        .read_req_tc(read_req_tc),
        .read_req_bar_sel(read_req_bar_sel),
        .read_req_ack(read_req_ack),
        .bar0_axil_rdata(bar0_axil_rdata),
        .bar0_axil_rresp(bar0_axil_rresp),
        .bar0_axil_rvalid(bar0_axil_rvalid),
        .bar0_axil_rready(bar0_axil_rready),
        .bar1_axil_rdata(m_axil_bar1_rdata),
        .bar1_axil_rresp(m_axil_bar1_rresp),
        .bar1_axil_rvalid(m_axil_bar1_rvalid),
        .bar1_axil_rready(m_axil_bar1_rready)
    );

    // Hardware AV Sync Global Precision Timestamp Wires & Telemetry
    wire [63:0] global_timestamp;
    wire [63:0] timestamp_90khz;
    wire [63:0] v_pts[NUM_VIDEO_CH-1:0];
    wire [63:0] a_pts[NUM_AUDIO_CH-1:0];
    wire [31:0] v_drop_cnt[NUM_VIDEO_CH-1:0];
    wire [31:0] reg_bandwidth_bps;
    wire [31:0] reg_latency_max_ns;
    wire [31:0] reg_pacer_ctrl;

    // 3. BAR0 AXI4-Lite Register Space
    axil_reg_space u_axil_reg_space (
        .clk(clk),
        .rst_n(rst_n),
        .s_axil_awaddr(bar0_axil_awaddr),
        .s_axil_awvalid(bar0_axil_awvalid),
        .s_axil_awready(bar0_axil_awready),
        .s_axil_wdata(bar0_axil_wdata),
        .s_axil_wstrb(bar0_axil_wstrb),
        .s_axil_wvalid(bar0_axil_wvalid),
        .s_axil_wready(bar0_axil_wready),
        .s_axil_bresp(bar0_axil_bresp),
        .s_axil_bvalid(bar0_axil_bvalid),
        .s_axil_bready(bar0_axil_bready),
        .s_axil_araddr(bar0_axil_araddr),
        .s_axil_arvalid(bar0_axil_arvalid),
        .s_axil_arready(bar0_axil_arready),
        .s_axil_rdata(bar0_axil_rdata),
        .s_axil_rresp(bar0_axil_rresp),
        .s_axil_rvalid(bar0_axil_rvalid),
        .s_axil_rready(bar0_axil_rready),
        .reg_dma_ctrl(reg_dma_ctrl),
        .reg_dma_status(reg_dma_status),
        .reg_h2c_ring_addr(reg_h2c_ring_addr),
        .reg_h2c_ring_size(reg_h2c_ring_size),
        .reg_h2c_tail_ptr(reg_h2c_tail_ptr),
        .reg_c2h_ring_addr(reg_c2h_ring_addr),
        .reg_c2h_ring_size(reg_c2h_ring_size),
        .reg_c2h_tail_ptr(reg_c2h_tail_ptr),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status(reg_irq_status),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count),
        .reg_h2c_head_ptr(reg_h2c_head_ptr),
        .reg_c2h_head_ptr(reg_c2h_head_ptr),
        .reg_global_timestamp(global_timestamp),
        .reg_last_video_pts(v_pts[0]),
        .reg_last_audio_pts(a_pts[0]),
        .reg_frame_drop_count(v_drop_cnt[0]),
        .reg_bandwidth_bps(reg_bandwidth_bps),
        .reg_latency_max_ns(reg_latency_max_ns),
        .reg_pacer_ctrl(reg_pacer_ctrl),
        .reg_slice_height(reg_slice_height)
    );

    // 3.1 Hardware AV Sync Global Precision Timestamp Generator (64-bit @ 125MHz, 8ns resolution)
    global_timer u_global_timer (
        .clk(clk),
        .rst_n(rst_n),
        .timer_clear(1'b0),
        .timer_enable(1'b1),
        .timer_preset(64'd0),
        .timer_load(1'b0),
        .global_timestamp(global_timestamp),
        .timestamp_90khz(timestamp_90khz)
    );

    // 3.2 Real-time Hardware Telemetry & Profiler (Throughput Bps & ACK Latency ns)
    dma_telemetry u_dma_telemetry (
        .clk(clk),
        .rst_n(rst_n),
        .c2h_req_valid(c2h_req_valid_mux),
        .c2h_req_dw_len(c2h_req_dw_len_mux),
        .c2h_req_ack(c2h_req_ack_mux),
        .reg_bandwidth_bps(reg_bandwidth_bps),
        .reg_latency_max_ns(reg_latency_max_ns)
    );

    // 4. PCIe Tag Manager
    pcie_tag_manager #(
        .MAX_TAGS(64)
    ) u_tag_manager (
        .clk(clk),
        .rst_n(rst_n),
        .alloc_req(tag_alloc_req),
        .alloc_valid(tag_alloc_valid),
        .alloc_tag(tag_alloc_tag),
        .tag_full(tag_full),
        .free_req(tag_free_req),
        .free_tag(tag_free_val),
        .active_count()
    );

    // 5. RQ TX Encoder
    rq_tx_encoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_rq_tx_encoder (
        .clk(clk),
        .rst_n(rst_n),
        .m_axis_rq_tdata(m_axis_rq_tdata),
        .m_axis_rq_tvalid(m_axis_rq_tvalid),
        .m_axis_rq_tlast(m_axis_rq_tlast),
        .m_axis_rq_tuser(m_axis_rq_tuser),
        .m_axis_rq_tkeep(m_axis_rq_tkeep),
        .m_axis_rq_tready(m_axis_rq_tready),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .desc_req_valid(desc_req_valid),
        .desc_req_addr(desc_req_addr),
        .desc_req_dw_len(desc_req_dw_len),
        .desc_req_tag(desc_req_tag),
        .desc_req_ack(desc_req_ack),
        .h2c_req_valid(sg_h2c_req_valid),
        .h2c_req_addr(sg_h2c_req_addr),
        .h2c_req_dw_len(sg_h2c_req_dw_len),
        .h2c_req_tag(sg_h2c_req_tag),
        .h2c_req_ack(sg_h2c_req_ack),
        .c2h_req_valid(c2h_req_valid_mux),
        .c2h_req_addr(c2h_req_addr_mux),
        .c2h_req_dw_len(c2h_req_dw_len_mux),
        .c2h_req_data(c2h_req_data_mux),
        .c2h_req_last(c2h_req_last_mux),
        .c2h_req_ack(c2h_req_ack_mux)
    );

    // 6. RC RX Decoder
    rc_rx_decoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_rc_rx_decoder (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_rc_tdata(s_axis_rc_tdata),
        .s_axis_rc_tvalid(s_axis_rc_tvalid),
        .s_axis_rc_tlast(s_axis_rc_tlast),
        .s_axis_rc_tuser(s_axis_rc_tuser),
        .s_axis_rc_tkeep(s_axis_rc_tkeep),
        .s_axis_rc_tready(s_axis_rc_tready),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .h2c_fifo_wvalid(h2c_fifo_wvalid),
        .h2c_fifo_wdata(h2c_fifo_wdata),
        .h2c_fifo_wlast(h2c_fifo_wlast),
        .tag_free_req(tag_free_req),
        .tag_free_val(tag_free_val)
    );

    // 7. Descriptor Fetch Engine
    desc_fetch_engine u_desc_fetch_engine (
        .clk(clk),
        .rst_n(rst_n),
        .dma_run(reg_dma_ctrl[0]),
        .ring_base_addr(reg_h2c_ring_addr),
        .ring_size(reg_h2c_ring_size),
        .tail_ptr(reg_h2c_tail_ptr),
        .head_ptr(reg_h2c_head_ptr),
        .desc_req_valid(desc_req_valid),
        .desc_req_addr(desc_req_addr),
        .desc_req_dw_len(desc_req_dw_len),
        .desc_req_tag(desc_req_tag),
        .desc_req_ack(desc_req_ack),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_plane0_src(h2c_plane0_src), .h2c_plane0_dst(h2c_plane0_dst),
        .h2c_plane1_src(h2c_plane1_src), .h2c_plane1_dst(h2c_plane1_dst),
        .h2c_plane2_src(h2c_plane2_src), .h2c_plane2_dst(h2c_plane2_dst),
        .h2c_line_width(h2c_line_width), .h2c_line_count(h2c_line_count),
        .h2c_src_stride(h2c_src_stride), .h2c_dst_stride(h2c_dst_stride),
        .h2c_plane12_width(h2c_plane12_width), .h2c_plane12_count(h2c_plane12_count),
        .h2c_format(h2c_format), .h2c_plane_count(h2c_plane_count),
        .h2c_desc_ctrl(h2c_desc_ctrl),
        .h2c_desc_ready(sg_h2c_desc_ready),
        .c2h_desc_valid(c2h_desc_valid),
        .c2h_plane0_src(c2h_plane0_src), .c2h_plane0_dst(c2h_plane0_dst),
        .c2h_plane1_src(c2h_plane1_src), .c2h_plane1_dst(c2h_plane1_dst),
        .c2h_plane2_src(c2h_plane2_src), .c2h_plane2_dst(c2h_plane2_dst),
        .c2h_line_width(c2h_line_width), .c2h_line_count(c2h_line_count),
        .c2h_src_stride(c2h_src_stride), .c2h_dst_stride(c2h_dst_stride),
        .c2h_plane12_width(c2h_plane12_width), .c2h_plane12_count(c2h_plane12_count),
        .c2h_format(c2h_format), .c2h_plane_count(c2h_plane_count),
        .c2h_desc_ctrl(c2h_desc_ctrl),
        .c2h_desc_ready(sg_c2h_desc_ready)
    );

    // 7.1 Scatter-Gather (SG) DMA Engine (H2C MRd Stream Consumer & C2H MWr Pattern Generator)
    sg_dma_engine #(
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_sg_dma_engine (
        .clk(clk),
        .rst_n(rst_n),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_plane0_src(h2c_plane0_src),
        .h2c_line_width(h2c_line_width),
        .h2c_desc_ready(sg_h2c_desc_ready),
        .c2h_desc_valid(c2h_desc_valid),
        .c2h_plane0_dst(c2h_plane0_dst),
        .c2h_line_width(c2h_line_width),
        .c2h_desc_ready(sg_c2h_desc_ready),
        .h2c_req_valid(sg_h2c_req_valid),
        .h2c_req_addr(sg_h2c_req_addr),
        .h2c_req_dw_len(sg_h2c_req_dw_len),
        .h2c_req_tag(sg_h2c_req_tag),
        .h2c_req_ack(sg_h2c_req_ack),
        .c2h_req_valid(sg_c2h_req_valid),
        .c2h_req_addr(sg_c2h_req_addr),
        .c2h_req_dw_len(sg_c2h_req_dw_len),
        .c2h_req_data(sg_c2h_req_data),
        .c2h_req_last(sg_c2h_req_last),
        .c2h_req_ack(sg_c2h_req_ack),
        .h2c_cpl_valid(h2c_fifo_wvalid),
        .h2c_cpl_data(h2c_fifo_wdata),
        .h2c_cpl_last(h2c_fifo_wlast),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count),
        .h2c_bytes_transferred(sg_h2c_bytes),
        .c2h_bytes_transferred(sg_c2h_bytes),
        .h2c_busy(sg_h2c_busy),
        .c2h_busy(sg_c2h_busy)
    );

    // 8. Multi-Channel Video Stream Engines (Parameterized Generator)
    localparam integer NUM_V_CH = NUM_VIDEO_CH;
    localparam integer NUM_A_CH = NUM_AUDIO_CH;

    genvar v_idx;
    generate
        for (v_idx = 0; v_idx < NUM_V_CH; v_idx = v_idx + 1) begin : gen_video_ch
            localparam integer v_idx_int = v_idx;
            wire v_start;
            assign v_start = (v_idx_int == 0) ? reg_dma_ctrl[0] : 1'b0;

            video_stream_engine #(
                .VIDEO_DATA_WIDTH(VIDEO_DATA_WIDTH),
                .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH)
            ) u_video_stream_engine (
                .clk(clk),
                .rst_n(rst_n),
                .video_start(v_start),
                .host_frame_addr(h2c_plane0_src),
                .line_width_bytes(h2c_line_width),
                .line_count(h2c_line_count),
                .line_stride_bytes(h2c_src_stride),
                .is_c2h(c2h_desc_valid),
                .pacer_enable(reg_pacer_ctrl[0]),
                .frame_interval_clks(32'd2083333), // 60.00 FPS Pacer @ 125MHz
                .slice_height(reg_slice_height[15:0]),
                .global_timestamp(global_timestamp),
                .ring_full(!c2h_desc_valid),
                .s_axis_video_tdata(s_axis_video_tdata[(v_idx*VIDEO_DATA_WIDTH) +: VIDEO_DATA_WIDTH]),
                .s_axis_video_tvalid(s_axis_video_tvalid[v_idx]),
                .s_axis_video_tlast(s_axis_video_tlast[v_idx]),
                .s_axis_video_tuser(s_axis_video_tuser[v_idx]),
                .s_axis_video_tready(s_axis_video_tready[v_idx]),
                .m_axis_video_tdata(m_axis_video_tdata[(v_idx*VIDEO_DATA_WIDTH) +: VIDEO_DATA_WIDTH]),
                .m_axis_video_tvalid(m_axis_video_tvalid[v_idx]),
                .m_axis_video_tlast(m_axis_video_tlast[v_idx]),
                .m_axis_video_tuser(m_axis_video_tuser[v_idx]),
                .m_axis_video_tready(m_axis_video_tready[v_idx]),
                .c2h_req_valid(v_c2h_req_valid[v_idx]),
                .c2h_req_addr(v_c2h_req_addr[(v_idx*64) +: 64]),
                .c2h_req_dw_len(v_c2h_req_dw_len[(v_idx*11) +: 11]),
                .c2h_req_data(v_c2h_req_data[(v_idx*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]),
                .c2h_req_last(v_c2h_req_last[v_idx]),
                .c2h_req_ack(c2h_req_ack_mux),
                .h2c_fifo_wvalid(h2c_fifo_wvalid),
                .h2c_fifo_wdata(h2c_fifo_wdata),
                .h2c_fifo_wlast(h2c_fifo_wlast),
                .video_busy(v_busy[v_idx]),
                .video_frame_done(v_done[v_idx]),
                .frame_pts(v_pts[v_idx]),
                .frame_drop_count(v_drop_cnt[v_idx])
            );
        end
    endgenerate

    // 9. Multi-Channel AES3 Audio Stream Engines (Parameterized Generator)
    genvar a_idx;
    generate
        for (a_idx = 0; a_idx < NUM_A_CH; a_idx = a_idx + 1) begin : gen_audio_ch
            wire a_start;
            assign a_start = (a_idx == 0) ? reg_dma_ctrl[1] : 1'b0;

            audio_stream_engine #(
                .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH),
                .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH)
            ) u_audio_stream_engine (
                .clk(clk),
                .rst_n(rst_n),
                .audio_start(a_start),
                .host_buffer_addr(h2c_plane0_src),
                .sample_block_size(16'd32),
                .is_c2h(c2h_desc_valid),
                .global_timestamp(global_timestamp),
                .s_axis_audio_tdata(s_axis_audio_tdata[(a_idx*AUDIO_DATA_WIDTH) +: AUDIO_DATA_WIDTH]),
                .s_axis_audio_tvalid(s_axis_audio_tvalid[a_idx]),
                .s_axis_audio_tlast(s_axis_audio_tlast[a_idx]),
                .s_axis_audio_tready(s_axis_audio_tready[a_idx]),
                .m_axis_audio_tdata(m_axis_audio_tdata[(a_idx*AUDIO_DATA_WIDTH) +: AUDIO_DATA_WIDTH]),
                .m_axis_audio_tvalid(m_axis_audio_tvalid[a_idx]),
                .m_axis_audio_tlast(m_axis_audio_tlast[a_idx]),
                .m_axis_audio_tready(m_axis_audio_tready[a_idx]),
                .c2h_req_valid(a_c2h_req_valid[a_idx]),
                .c2h_req_addr(a_c2h_req_addr[(a_idx*64) +: 64]),
                .c2h_req_dw_len(a_c2h_req_dw_len[(a_idx*11) +: 11]),
                .c2h_req_data(a_c2h_req_data[(a_idx*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]),
                .c2h_req_last(a_c2h_req_last[a_idx]),
                .c2h_req_ack(c2h_req_ack_mux),
                .h2c_fifo_wvalid(h2c_fifo_wvalid),
                .h2c_fifo_wdata(h2c_fifo_wdata),
                .h2c_fifo_wlast(h2c_fifo_wlast),
                .audio_busy(a_busy[a_idx]),
                .audio_block_done(a_done[a_idx]),
                .audio_pts(a_pts[a_idx])
            );
        end
    endgenerate

    // 10. Interrupt Controller
    interrupt_ctrl u_interrupt_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status(reg_irq_status),
        .h2c_done(v_done[0]),
        .c2h_done(a_done[0]),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

endmodule
