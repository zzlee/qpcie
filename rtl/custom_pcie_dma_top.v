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
    parameter PCIE_DATA_WIDTH  = 128,
    parameter PCIE_KEEP_WIDTH  = PCIE_DATA_WIDTH / 8,
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

    // 150 MHz NV12 capture domain (channel 0). The engine runs here and its
    // C2H requests cross back through video_req_cdc.
    input  wire                                             video_clk,
    input  wire                                             video_rst_n,
    input  wire [127:0]                                     video_ch0_tdata,
    input  wire                                             video_ch0_tvalid,
    input  wire                                             video_ch0_tlast,
    input  wire                                             video_ch0_tuser,
    output wire                                             video_ch0_tready,

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

    // Video pipeline control exported to the board-level clock/CDC logic.
    output wire                                             video_pipeline_reset,
    output wire                                             video_tpg_reset,
    output wire                                             video_engine_reset,

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
    wire        dma_rst_n = rst_n && !reg_dma_ctrl[1];
    wire [31:0] reg_irq_status_w1c;
    wire [31:0] reg_slice_height;
    wire [31:0] reg_video_ctrl;
    assign video_pipeline_reset = reg_video_ctrl[0];

    // Fine-grained sub-domain reset requests (BAR0 0x84). The board top
    // synchronizes these into the 150 MHz domain and gates only the targeted
    // reset, so software can realign the TPG (or the NV12 engine) without
    // tearing down the whole pipeline.
    wire [31:0] reg_video_sub_reset;
    wire [31:0] reg_sof_count;
    wire [31:0] reg_eol_count;
    wire [31:0] reg_beat_count;
    assign video_tpg_reset    = reg_video_sub_reset[0];
    assign video_engine_reset = reg_video_sub_reset[1];

    // ------------------------------------------------------------------
    // Free-running stream counters (video domain, gray-coded):
    //   sof_count   - TUSER pulses (frame starts)
    //   eol_count   - TLAST pulses (line ends)
    //   beat_count  - valid data beats
    // Crossed to the PCI domain for BAR0 readout; comparing the three
    // rates characterizes exactly how the TPG drives the stream.
    // ------------------------------------------------------------------
    wire       sof_pulse  = video_ch0_tvalid && video_ch0_tuser;
    wire       eol_pulse  = video_ch0_tvalid && video_ch0_tlast;

    function [31:0] gray_to_bin;
        input [31:0] g;
        integer i;
        reg [31:0] b;
        begin
            b[31] = g[31];
            for (i = 30; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            gray_to_bin = b;
        end
    endfunction

    reg [31:0] sof_gray_v  = 32'd0;
    reg [31:0] eol_gray_v  = 32'd0;
    reg [31:0] beat_gray_v = 32'd0;
    reg [31:0] sof_bin_v   = 32'd0;
    reg [31:0] eol_bin_v   = 32'd0;
    reg [31:0] beat_bin_v  = 32'd0;

    wire [31:0] sof_bin_next  = sof_bin_v + 32'd1;
    wire [31:0] eol_bin_next  = eol_bin_v + 32'd1;
    wire [31:0] beat_bin_next = beat_bin_v + 32'd1;

    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            sof_gray_v  <= 32'd0;
            eol_gray_v  <= 32'd0;
            beat_gray_v <= 32'd0;
            sof_bin_v   <= 32'd0;
            eol_bin_v   <= 32'd0;
            beat_bin_v  <= 32'd0;
        end else begin
            if (sof_pulse) begin
                sof_bin_v   <= sof_bin_next;
                sof_gray_v  <= (sof_bin_next >> 1) ^ sof_bin_next;
            end
            if (eol_pulse) begin
                eol_bin_v   <= eol_bin_next;
                eol_gray_v  <= (eol_bin_next >> 1) ^ eol_bin_next;
            end
            if (video_ch0_tvalid) begin
                beat_bin_v  <= beat_bin_next;
                beat_gray_v <= (beat_bin_next >> 1) ^ beat_bin_next;
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [31:0] sof_gray_sync1 = 32'd0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] sof_gray_sync2 = 32'd0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] eol_gray_sync1 = 32'd0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] eol_gray_sync2 = 32'd0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] beat_gray_sync1 = 32'd0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] beat_gray_sync2 = 32'd0;
    always @(posedge clk) begin
        sof_gray_sync1  <= sof_gray_v;
        sof_gray_sync2  <= sof_gray_sync1;
        eol_gray_sync1  <= eol_gray_v;
        eol_gray_sync2  <= eol_gray_sync1;
        beat_gray_sync1 <= beat_gray_v;
        beat_gray_sync2 <= beat_gray_sync1;
    end
    wire [63:0] reg_h2c_ring_addr, reg_c2h_ring_addr;
    wire [15:0] reg_h2c_ring_size, reg_h2c_tail_ptr, reg_h2c_head_ptr;
    wire [15:0] reg_c2h_ring_size, reg_c2h_tail_ptr, reg_c2h_head_ptr;
    wire [31:0] completed_h2c_count, completed_c2h_count;
    reg  [31:0] completed_h2c_count_q, completed_c2h_count_q;
    wire sg_h2c_done_irq = (completed_h2c_count != completed_h2c_count_q);
    wire sg_c2h_done_irq = (completed_c2h_count != completed_c2h_count_q);

    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            completed_h2c_count_q <= 32'd0;
            completed_c2h_count_q <= 32'd0;
        end else begin
            completed_h2c_count_q <= completed_h2c_count;
            completed_c2h_count_q <= completed_c2h_count;
        end
    end

    wire        tag_alloc_req, tag_alloc_valid, tag_full;
    wire [7:0]  tag_alloc_tag, tag_free_val;
    wire        tag_free_req;

    wire        desc_req_valid, desc_req_ack;
    wire        desc_fetch_idle;
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
    wire [NUM_VIDEO_CH-1:0]                    v_c2h_req_data_ready;
    wire [NUM_VIDEO_CH-1:0]                    v_busy, v_done;
    wire        video_cdc_fifo_empty;
    wire [9:0]  video_cdc_fifo_count;

    wire [NUM_AUDIO_CH-1:0]                    a_c2h_req_valid;
    wire [(NUM_AUDIO_CH*64)-1:0]               a_c2h_req_addr;
    wire [(NUM_AUDIO_CH*11)-1:0]               a_c2h_req_dw_len;
    wire [(NUM_AUDIO_CH*PCIE_DATA_WIDTH)-1:0]   a_c2h_req_data;
    wire [NUM_AUDIO_CH-1:0]                    a_c2h_req_last;
    wire [NUM_AUDIO_CH-1:0]                    a_busy, a_done;

    // SG DMA Engine Wires
    wire        sg_h2c_desc_ready, sg_c2h_desc_ready;
    wire        nv12_desc_ready;
    wire        nv12_ch1_desc_ready;
    wire        sg_c2h_desc_select = (c2h_format == 4'd0);
    wire        nv12_desc_select   = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd0);
    wire        nv12_ch1_desc_sel  = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd1);
    assign c2h_desc_ready = nv12_desc_select ? nv12_desc_ready :
                            nv12_ch1_desc_sel ? nv12_ch1_desc_ready :
                            sg_c2h_desc_select ? sg_c2h_desc_ready : 1'b0;
    wire        sg_h2c_req_valid, sg_h2c_req_ack;
    wire [63:0] sg_h2c_req_addr;
    wire [10:0] sg_h2c_req_dw_len;
    wire [7:0]  sg_h2c_req_tag;
    wire        sg_c2h_req_valid, sg_c2h_req_ack, sg_c2h_req_last;
    wire        sg_c2h_req_data_ready;
    wire [63:0] sg_c2h_req_addr;
    wire [10:0] sg_c2h_req_dw_len;
    wire [PCIE_DATA_WIDTH-1:0] sg_c2h_req_data;
    wire [31:0] sg_h2c_bytes, sg_c2h_bytes;
    wire        sg_h2c_busy, sg_c2h_busy;
    wire [PCIE_DATA_WIDTH-1:0] lb_tdata;
    wire        lb_tvalid, lb_tlast, lb_tuser;

    // Multiplexed C2H Request Signals
    reg                        c2h_req_valid_mux;
    reg  [63:0]                c2h_req_addr_mux;
    reg  [10:0]                c2h_req_dw_len_mux;
    reg  [PCIE_DATA_WIDTH-1:0] c2h_req_data_mux;
    reg                        c2h_req_last_mux;
    wire                       c2h_req_data_ready_mux;
    wire                       c2h_req_ack_mux;
    reg [7:0]                  c2h_owner;
    reg [7:0]                  c2h_selected;
    wire [NUM_VIDEO_CH-1:0]    v_c2h_req_ack;
    wire [NUM_AUDIO_CH-1:0]    a_c2h_req_ack;
    integer i_arb;
    reg c2h_arb_found;

    always @(*) begin
        c2h_req_valid_mux = 1'b0; c2h_req_addr_mux = 64'd0;
        c2h_req_dw_len_mux = 11'd0;
        c2h_req_data_mux = {PCIE_DATA_WIDTH{1'b0}};
        c2h_req_last_mux = 1'b0; c2h_arb_found = 1'b0;
        c2h_selected = c2h_owner;

        if ((c2h_owner == 8'd1) || ((c2h_owner == 0) && sg_c2h_req_valid)) begin
            c2h_req_valid_mux = sg_c2h_req_valid; c2h_req_addr_mux = sg_c2h_req_addr;
            c2h_req_dw_len_mux = sg_c2h_req_dw_len; c2h_req_data_mux = sg_c2h_req_data;
            c2h_req_last_mux = sg_c2h_req_last; c2h_arb_found = 1'b1;
            c2h_selected = 8'd1;
        end
        for (i_arb = 0; i_arb < NUM_VIDEO_CH; i_arb = i_arb + 1) begin
            if (((c2h_owner == (8'd2+i_arb)) ||
                 ((c2h_owner == 0) && !c2h_arb_found && v_c2h_req_valid[i_arb]))) begin
                c2h_req_valid_mux = v_c2h_req_valid[i_arb];
                c2h_req_addr_mux = v_c2h_req_addr[(i_arb*64)+:64];
                c2h_req_dw_len_mux = v_c2h_req_dw_len[(i_arb*11)+:11];
                c2h_req_data_mux = v_c2h_req_data[(i_arb*PCIE_DATA_WIDTH)+:PCIE_DATA_WIDTH];
                c2h_req_last_mux = v_c2h_req_last[i_arb]; c2h_arb_found = 1'b1;
                c2h_selected = 8'd2+i_arb;
            end
        end
        for (i_arb = 0; i_arb < NUM_AUDIO_CH; i_arb = i_arb + 1) begin
            if (((c2h_owner == (8'd2+NUM_VIDEO_CH+i_arb)) ||
                 ((c2h_owner == 0) && !c2h_arb_found && a_c2h_req_valid[i_arb]))) begin
                c2h_req_valid_mux = a_c2h_req_valid[i_arb];
                c2h_req_addr_mux = a_c2h_req_addr[(i_arb*64)+:64];
                c2h_req_dw_len_mux = a_c2h_req_dw_len[(i_arb*11)+:11];
                c2h_req_data_mux = a_c2h_req_data[(i_arb*PCIE_DATA_WIDTH)+:PCIE_DATA_WIDTH];
                c2h_req_last_mux = a_c2h_req_last[i_arb]; c2h_arb_found = 1'b1;
                c2h_selected = 8'd2+NUM_VIDEO_CH+i_arb;
            end
        end
    end

    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) c2h_owner <= 8'd0;
        else if (c2h_owner == 0 && c2h_req_valid_mux) c2h_owner <= c2h_selected;
        else if (c2h_owner != 0 && c2h_req_ack_mux) c2h_owner <= 8'd0;
    end

    assign sg_c2h_req_data_ready =
        (c2h_owner == 8'd1) && c2h_req_data_ready_mux;
    assign sg_c2h_req_ack = (c2h_owner == 8'd1) && c2h_req_ack_mux;
    genvar v_ack_i, a_ack_i;
    generate
        for (v_ack_i=0; v_ack_i<NUM_VIDEO_CH; v_ack_i=v_ack_i+1) begin : gen_v_ack
            assign v_c2h_req_data_ready[v_ack_i] =
                (c2h_owner == (8'd2+v_ack_i)) && c2h_req_data_ready_mux;
            assign v_c2h_req_ack[v_ack_i] =
                (c2h_owner == (8'd2+v_ack_i)) && c2h_req_ack_mux;
        end
        for (a_ack_i=0; a_ack_i<NUM_AUDIO_CH; a_ack_i=a_ack_i+1) begin : gen_a_ack
            assign a_c2h_req_ack[a_ack_i] = (c2h_owner == (8'd2+NUM_VIDEO_CH+a_ack_i)) && c2h_req_ack_mux;
        end
    endgenerate

    wire video_tx_idle = video_cdc_fifo_empty && !v_c2h_req_valid[0] &&
                         (c2h_owner != 8'd2);
    assign reg_dma_status = {20'd0, sg_c2h_busy, sg_h2c_busy,
                             desc_fetch_idle, video_tx_idle, 4'd0,
                             a_done[0], v_done[0], a_busy[0], v_busy[0]};

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

    // Performance Monitor Signals (RTL Bandwidth & Bottleneck Attribution)
    wire        perf_enable;
    wire        perf_reset;
    wire [63:0] reg_perf_cycles;
    wire [31:0] reg_perf_tlp_count;
    wire [63:0] reg_perf_payload_bytes;
    wire [31:0] reg_perf_tx_active_cycles;
    wire [31:0] reg_perf_tx_idle_cycles;
    wire [31:0] reg_perf_tready_stall_cycles;
    wire [31:0] reg_perf_inter_tlp_gap;
    wire [31:0] reg_perf_tlp_128b_count;
    wire [31:0] reg_perf_tlp_256b_count;
    wire [31:0] reg_perf_split_4k_count;
    wire [15:0] reg_perf_max_queue_depth;
    wire [31:0] reg_perf_idle_cdc_empty;
    wire [31:0] reg_perf_idle_no_req;

    wire        perf_tlp_start = m_axis_rq_tvalid && m_axis_rq_tready && m_axis_rq_tuser[0];
    wire        perf_split_4k_event = (c2h_req_valid_mux && c2h_req_ack_mux &&
                                       (c2h_req_dw_len_mux == 11'd32) &&
                                       (c2h_req_addr_mux[11:7] == 5'b11111));

    // Scatter-Gather Page Table Wires
    wire        pt_y_wr_en, pt_uv_wr_en;
    wire [10:0] pt_y_wr_addr, pt_uv_wr_addr;
    wire [63:0] pt_y_wr_data, pt_uv_wr_data;
    wire [10:0] cur_y_page_idx, cur_uv_page_idx;

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
        .reg_irq_status_w1c(reg_irq_status_w1c),
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
        .reg_slice_height(reg_slice_height),
        .reg_video_ctrl(reg_video_ctrl),
        .reg_video_sub_reset(reg_video_sub_reset),
        .reg_sof_count(gray_to_bin(sof_gray_sync2)),
        .reg_eol_count(gray_to_bin(eol_gray_sync2)),
        .reg_beat_count(gray_to_bin(beat_gray_sync2)),

        // Hardware Performance Monitor Ports
        .perf_enable(perf_enable),
        .perf_reset(perf_reset),
        .reg_perf_cycles(reg_perf_cycles),
        .reg_perf_tlp_count(reg_perf_tlp_count),
        .reg_perf_payload_bytes(reg_perf_payload_bytes),
        .reg_perf_tx_active_cycles(reg_perf_tx_active_cycles),
        .reg_perf_tx_idle_cycles(reg_perf_tx_idle_cycles),
        .reg_perf_tready_stall_cycles(reg_perf_tready_stall_cycles),
        .reg_perf_inter_tlp_gap(reg_perf_inter_tlp_gap),
        .reg_perf_tlp_128b_count(reg_perf_tlp_128b_count),
        .reg_perf_tlp_256b_count(reg_perf_tlp_256b_count),
        .reg_perf_split_4k_count(reg_perf_split_4k_count),
        .reg_perf_max_queue_depth(reg_perf_max_queue_depth),
        .reg_perf_idle_cdc_empty(reg_perf_idle_cdc_empty),
        .reg_perf_idle_no_req(reg_perf_idle_no_req),
        .pt_y_wr_en(pt_y_wr_en),
        .pt_y_wr_addr(pt_y_wr_addr),
        .pt_y_wr_data(pt_y_wr_data),
        .pt_uv_wr_en(pt_uv_wr_en),
        .pt_uv_wr_addr(pt_uv_wr_addr),
        .pt_uv_wr_data(pt_uv_wr_data),
        .cur_y_page_idx(cur_y_page_idx),
        .cur_uv_page_idx(cur_uv_page_idx)
    );

    // 3.1 Hardware Performance Monitor Instance
    qpcie_perfmon u_qpcie_perfmon (
        .clk(clk),
        .rst_n(rst_n),
        .perf_enable(perf_enable),
        .perf_reset(perf_reset),
        .tx_tvalid(m_axis_rq_tvalid),
        .tx_tready(m_axis_rq_tready),
        .tx_tlast(m_axis_rq_tlast),
        .tx_dw_len(c2h_req_dw_len_mux),
        .tlp_start(perf_tlp_start),
        .req_valid(c2h_req_valid_mux),
        .req_ack(c2h_req_ack_mux),
        .fifo_empty(video_cdc_fifo_empty),
        .fifo_count(video_cdc_fifo_count),
        .split_4k_event(perf_split_4k_event),
        .reg_perf_cycles(reg_perf_cycles),
        .reg_perf_tlp_count(reg_perf_tlp_count),
        .reg_perf_payload_bytes(reg_perf_payload_bytes),
        .reg_perf_tx_active_cycles(reg_perf_tx_active_cycles),
        .reg_perf_tx_idle_cycles(reg_perf_tx_idle_cycles),
        .reg_perf_tready_stall_cycles(reg_perf_tready_stall_cycles),
        .reg_perf_inter_tlp_gap(reg_perf_inter_tlp_gap),
        .reg_perf_tlp_128b_count(reg_perf_tlp_128b_count),
        .reg_perf_tlp_256b_count(reg_perf_tlp_256b_count),
        .reg_perf_split_4k_count(reg_perf_split_4k_count),
        .reg_perf_max_queue_depth(reg_perf_max_queue_depth),
        .reg_perf_idle_cdc_empty(reg_perf_idle_cdc_empty),
        .reg_perf_idle_no_req(reg_perf_idle_no_req)
    );

    // 3.2 Hardware AV Sync Global Precision Timestamp Generator (64-bit @ 125MHz, 8ns resolution)
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

    // 3.3 Real-time Hardware Telemetry & Profiler (Throughput Bps & ACK Latency ns)
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
        .rst_n(dma_rst_n),
        .alloc_req(tag_alloc_req),
        .alloc_valid(tag_alloc_valid),
        .alloc_tag(tag_alloc_tag),
        .tag_full(tag_full),
        .free_req(tag_free_req),
        .free_tag(tag_free_val),
        .active_count()
    );

    wire        sg_req_valid, sg_req_ack;
    wire [63:0] sg_req_addr;
    wire [10:0] sg_req_dw_len;
    wire [7:0]  sg_req_tag;

    wire        sg_cpl_valid, sg_cpl_last;
    wire [PCIE_DATA_WIDTH-1:0] sg_cpl_data;
    wire [7:0]  sg_cpl_tag;

    wire        sgl_y_wr_en, sgl_uv_wr_en;
    wire [63:0] sgl_y_wr_addr, sgl_uv_wr_addr;
    wire [31:0] sgl_y_wr_len, sgl_uv_wr_len;
    wire [31:0] sgl_y_wr_flags, sgl_uv_wr_flags;
    wire        sg_fetch_busy, sg_fetch_done;

    // 5. RQ TX Encoder
    rq_tx_encoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_rq_tx_encoder (
        .clk(clk),
        .rst_n(dma_rst_n),
        .m_axis_rq_tdata(m_axis_rq_tdata),
        .m_axis_rq_tvalid(m_axis_rq_tvalid),
        .m_axis_rq_tlast(m_axis_rq_tlast),
        .m_axis_rq_tuser(m_axis_rq_tuser),
        .m_axis_rq_tkeep(m_axis_rq_tkeep),
        .m_axis_rq_tready(m_axis_rq_tready),
        // MSI is delivered through the 7-series cfg_interrupt interface.
        .irq_req_valid(1'b0),
        .irq_req_code(8'd0),
        .irq_req_ack(irq_req_ack),
        .desc_req_valid(desc_req_valid),
        .desc_req_addr(desc_req_addr),
        .desc_req_dw_len(desc_req_dw_len),
        .desc_req_tag(desc_req_tag),
        .desc_req_ack(desc_req_ack),
        .sg_req_valid(sg_req_valid),
        .sg_req_addr(sg_req_addr),
        .sg_req_dw_len(sg_req_dw_len),
        .sg_req_tag(sg_req_tag),
        .sg_req_ack(sg_req_ack),
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
        .c2h_req_data_ready(c2h_req_data_ready_mux),
        .c2h_req_ack(c2h_req_ack_mux)
    );

    // 6. RC RX Decoder
    rc_rx_decoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_rc_rx_decoder (
        .clk(clk),
        .rst_n(dma_rst_n),
        .s_axis_rc_tdata(s_axis_rc_tdata),
        .s_axis_rc_tvalid(s_axis_rc_tvalid),
        .s_axis_rc_tlast(s_axis_rc_tlast),
        .s_axis_rc_tuser(s_axis_rc_tuser),
        .s_axis_rc_tkeep(s_axis_rc_tkeep),
        .s_axis_rc_tready(s_axis_rc_tready),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .sg_cpl_valid(sg_cpl_valid),
        .sg_cpl_data(sg_cpl_data),
        .sg_cpl_last(sg_cpl_last),
        .sg_cpl_tag(sg_cpl_tag),
        .h2c_fifo_wvalid(h2c_fifo_wvalid),
        .h2c_fifo_wdata(h2c_fifo_wdata),
        .h2c_fifo_wlast(h2c_fifo_wlast),
        .tag_free_req(tag_free_req),
        .tag_free_val(tag_free_val)
    );

    // 6.1 SG Host Variable-Length SGL Fetch Engine
    wire [2:0]  sgl_channel;
    wire        sgl_h2c_y_wr_en  = sgl_y_wr_en  && (sgl_channel == 3'd4);
    wire        sgl_h2c_uv_wr_en = sgl_uv_wr_en && (sgl_channel == 3'd4);

    wire        sgl_ch0_y_wr_en  = sgl_y_wr_en  && (sgl_channel == 3'd0);
    wire        sgl_ch0_uv_wr_en = sgl_uv_wr_en && (sgl_channel == 3'd0);

    wire        sgl_ch1_y_wr_en  = sgl_y_wr_en  && (sgl_channel == 3'd1);
    wire        sgl_ch1_uv_wr_en = sgl_uv_wr_en && (sgl_channel == 3'd1);

    wire        sgl_ch2_y_wr_en  = sgl_y_wr_en  && (sgl_channel == 3'd2);
    wire        sgl_ch2_uv_wr_en = sgl_uv_wr_en && (sgl_channel == 3'd2);

    wire        sgl_ch3_y_wr_en  = sgl_y_wr_en  && (sgl_channel == 3'd3);
    wire        sgl_ch3_uv_wr_en = sgl_uv_wr_en && (sgl_channel == 3'd3);

    wire        h2c_y_almost_full, h2c_uv_almost_full;
    wire        ch0_sgl_y_almost_full, ch0_sgl_uv_almost_full;
    wire        ch1_sgl_y_almost_full, ch1_sgl_uv_almost_full;
    wire        ch2_sgl_y_almost_full, ch2_sgl_uv_almost_full;
    wire        ch3_sgl_y_almost_full, ch3_sgl_uv_almost_full;

    wire [4:0]  channel_y_almost_full  = {h2c_y_almost_full, ch3_sgl_y_almost_full, ch2_sgl_y_almost_full, ch1_sgl_y_almost_full, ch0_sgl_y_almost_full};
    wire [4:0]  channel_uv_almost_full = {h2c_uv_almost_full, ch3_sgl_uv_almost_full, ch2_sgl_uv_almost_full, ch1_sgl_uv_almost_full, ch0_sgl_uv_almost_full};

    sg_host_fetch_engine #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_sg_host_fetch_engine (
        .clk(clk),
        .rst_n(dma_rst_n),
        .fetch_start((h2c_desc_valid && h2c_desc_ready && (h2c_desc_ctrl[4] || h2c_desc_ctrl[5])) ||
                     (c2h_desc_valid && c2h_desc_ready && (c2h_desc_ctrl[4] || c2h_desc_ctrl[5]))),
        .fetch_channel(h2c_desc_valid ? 3'd4 : {1'b0, c2h_desc_ctrl[7:6]}),
        .plane0_slot_addr(h2c_desc_valid ? h2c_plane0_src : c2h_plane0_dst),
        .plane1_slot_addr(h2c_desc_valid ? h2c_plane1_src : c2h_plane1_dst),
        .plane0_pages_req(16'd2025),
        .plane1_pages_req(16'd1013),
        .fetch_busy(sg_fetch_busy),
        .fetch_done(sg_fetch_done),
        .mrd_req_valid(sg_req_valid),
        .mrd_req_addr(sg_req_addr),
        .mrd_req_dw_len(sg_req_dw_len),
        .mrd_req_tag(sg_req_tag),
        .mrd_req_ack(sg_req_ack),
        .cpld_valid(sg_cpl_valid),
        .cpld_data(sg_cpl_data),
        .cpld_last(sg_cpl_last),
        .cpld_tag(sg_cpl_tag),
        .sgl_channel(sgl_channel),
        .sgl_y_wr_en(sgl_y_wr_en),
        .sgl_y_wr_addr(sgl_y_wr_addr),
        .sgl_y_wr_len(sgl_y_wr_len),
        .sgl_y_wr_flags(sgl_y_wr_flags),
        .sgl_uv_wr_en(sgl_uv_wr_en),
        .sgl_uv_wr_addr(sgl_uv_wr_addr),
        .sgl_uv_wr_len(sgl_uv_wr_len),
        .sgl_uv_wr_flags(sgl_uv_wr_flags),
        .channel_y_almost_full(channel_y_almost_full),
        .channel_uv_almost_full(channel_uv_almost_full)
    );

    // 7. Descriptor Fetch Engine
    desc_fetch_engine u_desc_fetch_engine (
        .clk(clk),
        .rst_n(dma_rst_n),
        .dma_run(reg_dma_ctrl[0]),
        .ring_base_addr(reg_h2c_ring_addr),
        .ring_size(reg_h2c_ring_size),
        .tail_ptr(reg_h2c_tail_ptr),
        .head_ptr(reg_h2c_head_ptr),
        .idle(desc_fetch_idle),
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
        .c2h_desc_ready(c2h_desc_ready),
        .sg_fetch_busy(sg_fetch_busy)
    );

    // 7.1 Scatter-Gather (SG) DMA Engine (H2C MRd Stream Consumer & C2H MWr Pattern Generator)
    sg_dma_engine #(
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_sg_dma_engine (
        .clk(clk),
        .rst_n(dma_rst_n),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_plane0_src(h2c_plane0_src),
        .h2c_plane1_src(h2c_plane1_src),
        .h2c_line_width(h2c_line_width),
        .h2c_line_count(h2c_line_count),
        .h2c_plane12_width(h2c_plane12_width),
        .h2c_plane12_count(h2c_plane12_count),
        .h2c_plane_count(h2c_plane_count),
        .h2c_desc_ctrl(h2c_desc_ctrl),
        .h2c_desc_ready(sg_h2c_desc_ready),
        .sgl_h2c_y_wr_en(sgl_h2c_y_wr_en),
        .sgl_h2c_y_wr_addr(sgl_y_wr_addr),
        .sgl_h2c_y_wr_len(sgl_y_wr_len),
        .sgl_h2c_y_wr_flags(sgl_y_wr_flags),
        .sgl_h2c_uv_wr_en(sgl_h2c_uv_wr_en),
        .sgl_h2c_uv_wr_addr(sgl_uv_wr_addr),
        .sgl_h2c_uv_wr_len(sgl_uv_wr_len),
        .sgl_h2c_uv_wr_flags(sgl_uv_wr_flags),
        .c2h_desc_valid(c2h_desc_valid && sg_c2h_desc_select),
        .c2h_plane0_dst(c2h_plane0_dst),
        .c2h_line_width(c2h_line_width),
        .c2h_line_count(c2h_line_count),
        .c2h_plane12_width(c2h_plane12_width),
        .c2h_plane12_count(c2h_plane12_count),
        .c2h_plane_count(c2h_plane_count),
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
        .c2h_req_data_ready(sg_c2h_req_data_ready),
        .c2h_req_ack(sg_c2h_req_ack),
        .h2c_cpl_valid(h2c_fifo_wvalid),
        .h2c_cpl_data(h2c_fifo_wdata),
        .h2c_cpl_last(h2c_fifo_wlast),
        .h2c_y_almost_full(h2c_y_almost_full),
        .h2c_uv_almost_full(h2c_uv_almost_full),
        .m_axis_loopback_tdata(lb_tdata),
        .m_axis_loopback_tvalid(lb_tvalid),
        .m_axis_loopback_tlast(lb_tlast),
        .m_axis_loopback_tuser(lb_tuser),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count),
        .h2c_bytes_transferred(sg_h2c_bytes),
        .c2h_bytes_transferred(sg_c2h_bytes),
        .dma_error_count(),
        .h2c_busy(sg_h2c_busy),
        .c2h_busy(sg_c2h_busy)
    );

    // 8. Channel-0 YUV444 -> NV12M Capture Engine (150 MHz video domain)
    // Descriptor format 0 remains reserved for the SG diagnostic engine;
    // format 2 with two planes is accepted only by this video engine.
    localparam integer NUM_V_CH = NUM_VIDEO_CH;
    localparam integer NUM_A_CH = NUM_AUDIO_CH;

    // ---- Signal declarations (before any use) ----------------------------
    reg         hs_send_q;
    reg [240:0] hs_bus_q;
    wire        hs_src_rcv, hs_dest_req;
    wire [240:0] hs_dest_bus;
    reg          hs_dest_ack;
    reg          eng_desc_valid;
    reg          eng_desc_sg_mode;
    reg [63:0]   eng_y_addr, eng_uv_addr, eng_ts;
    reg [15:0]   eng_width, eng_height, eng_stride;
    wire         nv12_desc_ready_v;

    // Pacer enable crosses as a quasi-static level (BAR0 write, rare).
    (* ASYNC_REG = "TRUE" *) reg [1:0] pacer_sync = 2'b01;

    wire        eng_frame_done, eng_busy;
    wire [31:0] eng_err_count;
    wire [63:0] eng_frame_pts;
    wire        eng_req_valid, eng_req_ready, eng_req_ack;
    wire [63:0] eng_req_addr;
    wire [PCIE_DATA_WIDTH-1:0] eng_req_data;

    (* ASYNC_REG = "TRUE" *) reg [1:0] v_busy_sync = 2'b00;
    wire pcie_frame_done;

    wire        tel_dest_req;
    wire [95:0] tel_dest_out;
    wire        tel_dest_ack_unused;
    reg [31:0] v_err_sync_q = 32'd0;
    reg [63:0] v_pts_sync_q = 64'd0;

    // ---- Descriptor crossing: 125 MHz fetch -> 150 MHz engine ------------
    // Bus layout: {desc_ctrl[4]|desc_ctrl[5], timestamp[63:0], stride[15:0], height[15:0], width[15:0],
    //              uv_addr[63:0], y_addr[63:0]}
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            hs_send_q <= 1'b0;
            hs_bus_q  <= 241'd0;
        end else if (reg_video_ctrl[0]) begin
            hs_send_q <= 1'b0;
            hs_bus_q  <= 241'd0;
        end else if (!hs_send_q && !hs_src_rcv && c2h_desc_valid && nv12_desc_select) begin
            hs_bus_q  <= {(c2h_desc_ctrl[4] | c2h_desc_ctrl[5]),
                          global_timestamp, c2h_dst_stride,
                          c2h_line_count, c2h_line_width,
                          c2h_plane1_dst, c2h_plane0_dst};
            hs_send_q <= 1'b1;
        end else if (hs_send_q && hs_src_rcv) begin
            hs_send_q <= 1'b0;
        end
    end

    // One descriptor owns the channel-0 walkers until its frame completes.
    // Accepting the next descriptor earlier would mix its SGL into this frame.
    assign nv12_desc_ready = c2h_desc_valid && nv12_desc_select &&
                              !hs_send_q && !hs_src_rcv && !v_busy_sync[1];

    xpm_cdc_handshake #(
        .WIDTH(241),
        .DEST_EXT_HSK(1)
    ) u_desc_cdc (
        .src_clk    (clk),
        .src_send   (hs_send_q),
        .src_rcv    (hs_src_rcv),
        .src_in     (hs_bus_q),
        .dest_clk   (video_clk),
        .dest_req   (hs_dest_req),
        .dest_out   (hs_dest_bus),
        .dest_ack   (hs_dest_ack)
    );

    localparam DEST_IDLE         = 2'd0,
               DEST_WAIT_ENG     = 2'd1,
               DEST_WAIT_REQ_LOW = 2'd2;
    reg [1:0]  dest_state;

    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            dest_state       <= DEST_IDLE;
            eng_desc_valid   <= 1'b0;
            eng_desc_sg_mode <= 1'b0;
            hs_dest_ack      <= 1'b0;
            eng_y_addr       <= 64'd0;
            eng_uv_addr      <= 64'd0;
            eng_width        <= 16'd0;
            eng_height       <= 16'd0;
            eng_stride       <= 16'd0;
            eng_ts           <= 64'd0;
        end else begin
            case (dest_state)
                DEST_IDLE: begin
                    hs_dest_ack <= 1'b0;
                    if (hs_dest_req) begin
                        eng_y_addr       <= hs_dest_bus[63:0];
                        eng_uv_addr      <= hs_dest_bus[127:64];
                        eng_width        <= hs_dest_bus[143:128];
                        eng_height       <= hs_dest_bus[159:144];
                        eng_stride       <= hs_dest_bus[175:160];
                        eng_ts           <= hs_dest_bus[239:176];
                        eng_desc_sg_mode <= hs_dest_bus[240];
                        eng_desc_valid   <= 1'b1;
                        dest_state       <= DEST_WAIT_ENG;
                    end
                end

                DEST_WAIT_ENG: begin
                    if (eng_desc_valid && nv12_desc_ready_v) begin
                        eng_desc_valid <= 1'b0;
                        hs_dest_ack    <= 1'b1;
                        dest_state     <= DEST_WAIT_REQ_LOW;
                    end
                end

                DEST_WAIT_REQ_LOW: begin
                    if (!hs_dest_req) begin
                        hs_dest_ack <= 1'b0;
                        dest_state  <= DEST_IDLE;
                    end
                end

                default: dest_state <= DEST_IDLE;
            endcase
        end
    end

    always @(posedge video_clk) pacer_sync <= {pacer_sync[0], reg_pacer_ctrl[0]};

    // Busy crosses back as a level; completion is ordered through the request FIFO.
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            v_busy_sync <= 2'b00;
        end else begin
            v_busy_sync[0] <= eng_busy;
            v_busy_sync[1] <= v_busy_sync[0];
        end
    end

    // Telemetry handshake: {protocol_error_count, frame_pts} per frame done.
    xpm_cdc_handshake #(
        .WIDTH(96),
        .DEST_EXT_HSK(0)
    ) u_tel_cdc (
        .src_clk    (video_clk),
        .src_send   (eng_frame_done),
        .src_rcv    (),
        .src_in     ({eng_err_count, eng_frame_pts}),
        .dest_clk   (clk),
        .dest_req   (tel_dest_req),
        .dest_out   (tel_dest_out),
        .dest_ack   (tel_dest_ack_unused)
    );

    assign tel_dest_ack_unused = tel_dest_req;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_err_sync_q <= 32'd0;
            v_pts_sync_q <= 64'd0;
        end else if (tel_dest_req) begin
            v_err_sync_q <= tel_dest_out[95:64];
            v_pts_sync_q <= tel_dest_out[63:0];
        end
    end

    // Channel-0 status/telemetry now come from the synchronized copies.
    assign v_done[0]     = pcie_frame_done;
    assign v_busy[0]     = v_busy_sync[1] || !video_cdc_fifo_empty || v_c2h_req_valid[0];
    assign v_pts[0]      = v_pts_sync_q;
    assign v_drop_cnt[0] = v_err_sync_q;
    assign s_axis_video_tready[0] = 1'b0;

    // ---- Request crossing: engine @150 MHz -> RQ arbiter @125 MHz --------
    wire [10:0] eng_req_dw_len;

    video_req_cdc #(
        .MAX_DWORDS(64),
        .FIFO_DEPTH(512)
    ) u_video_req_cdc (
        .wr_clk           (video_clk),
        .wr_rst_n         (video_rst_n),
        .s_req_valid      (eng_req_valid),
        .s_req_addr       (eng_req_addr),
        .s_req_dw_len     (eng_req_dw_len),
        .s_req_data       (eng_req_data),
        .s_req_data_ready (eng_req_ready),
        .s_req_ack        (eng_req_ack),
        .s_frame_done     (eng_frame_done),
        .rd_clk           (clk),
        .rd_rst_n         (dma_rst_n),
        .m_req_valid      (v_c2h_req_valid[0]),
        .m_req_addr       (v_c2h_req_addr[63:0]),
        .m_req_dw_len     (v_c2h_req_dw_len[10:0]),
        .m_req_data       (v_c2h_req_data[PCIE_DATA_WIDTH-1:0]),
        .m_req_data_ready (v_c2h_req_data_ready[0]),
        .m_req_ack        (v_c2h_req_ack[0]),
        .m_frame_done     (pcie_frame_done),
        .m_fifo_empty     (video_cdc_fifo_empty),
        .m_fifo_count     (video_cdc_fifo_count)
    );

    // SGL Y CDC FIFO for Channel 0 (125 MHz clk -> 150 MHz video_clk)
    wire [127:0] v_sgl_y_dout;
    wire        v_sgl_y_empty;
    wire        v_sgl_y_full;
    wire        v_sgl_y_pop_ready;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"),
        .FIFO_WRITE_DEPTH(64),
        .WRITE_DATA_WIDTH(128),
        .READ_DATA_WIDTH(128),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),
        .PROG_FULL_THRESH(48),
        .USE_ADV_FEATURES("0002")
    ) u_sgl_y_cdc (
        .rst(!rst_n || !video_rst_n),
        .wr_clk(clk),
        .wr_en(sgl_ch0_y_wr_en && !v_sgl_y_full),
        .din({sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}),
        .prog_full(ch0_sgl_y_almost_full),
        .full(v_sgl_y_full),
        .rd_clk(video_clk),
        .rd_en(!v_sgl_y_empty && v_sgl_y_pop_ready && eng_busy),
        .dout(v_sgl_y_dout),
        .empty(v_sgl_y_empty),
        .sleep(1'b0),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0),
        .sbiterr(),
        .dbiterr(),
        .wr_rst_busy(),
        .rd_rst_busy()
    );

    // SGL UV CDC FIFO for Channel 0 (125 MHz clk -> 150 MHz video_clk)
    wire [127:0] v_sgl_uv_dout;
    wire        v_sgl_uv_empty;
    wire        v_sgl_uv_full;
    wire        v_sgl_uv_pop_ready;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"),
        .FIFO_WRITE_DEPTH(64),
        .WRITE_DATA_WIDTH(128),
        .READ_DATA_WIDTH(128),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),
        .PROG_FULL_THRESH(48),
        .USE_ADV_FEATURES("0002")
    ) u_sgl_uv_cdc (
        .rst(!rst_n || !video_rst_n),
        .wr_clk(clk),
        .wr_en(sgl_ch0_uv_wr_en && !v_sgl_uv_full),
        .din({sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}),
        .prog_full(ch0_sgl_uv_almost_full),
        .full(v_sgl_uv_full),
        .rd_clk(video_clk),
        .rd_en(!v_sgl_uv_empty && v_sgl_uv_pop_ready && eng_busy),
        .dout(v_sgl_uv_dout),
        .empty(v_sgl_uv_empty),
        .sleep(1'b0),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0),
        .sbiterr(),
        .dbiterr(),
        .wr_rst_busy(),
        .rd_rst_busy()
    );

    // ---- The Channel 0 capture engine itself -----------------------------
    nv12_capture_engine #(
        .MAX_WIDTH(3840),
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH),
        .FIFO_DEPTH(32),
        .MWR_PAYLOAD_BYTES(256)
    ) u_nv12_capture_engine (
        .clk(video_clk),
        .rst_n(video_rst_n),
        .desc_valid(eng_desc_valid),
        .desc_ready(nv12_desc_ready_v),
        .desc_sg_mode(eng_desc_sg_mode),
        .plane_y_addr(eng_y_addr),
        .plane_uv_addr(eng_uv_addr),
        .frame_width(eng_width),
        .frame_height(eng_height),
        .frame_stride(eng_stride),
        .sgl_y_wr_en(!v_sgl_y_empty && v_sgl_y_pop_ready && eng_busy),
        .sgl_y_wr_addr(v_sgl_y_dout[63:0]),
        .sgl_y_wr_len(v_sgl_y_dout[95:64]),
        .sgl_y_wr_flags(v_sgl_y_dout[127:96]),
        .sgl_uv_wr_en(!v_sgl_uv_empty && v_sgl_uv_pop_ready && eng_busy),
        .sgl_uv_wr_addr(v_sgl_uv_dout[63:0]),
        .sgl_uv_wr_len(v_sgl_uv_dout[95:64]),
        .sgl_uv_wr_flags(v_sgl_uv_dout[127:96]),
        .cur_y_sgl_count(),
        .cur_uv_sgl_count(),
        .sgl_y_pop_ready(v_sgl_y_pop_ready),
        .sgl_uv_pop_ready(v_sgl_uv_pop_ready),
        .pacer_enable(1'b0),   /* Hardware pacer disabled; Linux driver pacer drives 60 FPS */
        .frame_interval_clks(32'd2500000),   // 60 FPS @ 150 MHz
        .global_timestamp(eng_ts),
        .s_axis_tdata(video_ch0_tdata),
        .s_axis_tvalid(video_ch0_tvalid),
        .s_axis_tlast(video_ch0_tlast),
        .s_axis_tuser(video_ch0_tuser),
        .s_axis_tready(video_ch0_tready),
        .c2h_req_valid(eng_req_valid),
        .c2h_req_addr(eng_req_addr),
        .c2h_req_dw_len(eng_req_dw_len),
        .c2h_req_data(eng_req_data),
        .c2h_req_last(),
        .c2h_req_data_ready(eng_req_ready),
        .c2h_req_ack(eng_req_ack),
        .video_busy(eng_busy),
        .video_frame_done(eng_frame_done),
        .frame_pts(eng_frame_pts),
        .protocol_error_count(eng_err_count)
    );

    // =========================================================================
    // Loopback & Capture Engines for Channels 1, 2, and 3
    // =========================================================================
    // ---------------------- CHANNEL 1 ----------------------------------------
    wire [127:0] ch1_sgl_y_dout, ch1_sgl_uv_dout;
    wire        ch1_sgl_y_empty, ch1_sgl_uv_empty;
    wire        ch1_sgl_y_pop_ready, ch1_sgl_uv_pop_ready;
    wire        ch1_sgl_y_rd_en, ch1_sgl_uv_rd_en;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch1_sgl_y_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(sgl_ch1_y_wr_en), .din({sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}), .prog_full(ch1_sgl_y_almost_full), .full(), .rd_clk(video_clk), .rd_en(ch1_sgl_y_rd_en), .dout(ch1_sgl_y_dout), .empty(ch1_sgl_y_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch1_sgl_uv_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(sgl_ch1_uv_wr_en), .din({sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}), .prog_full(ch1_sgl_uv_almost_full), .full(), .rd_clk(video_clk), .rd_en(ch1_sgl_uv_rd_en), .dout(ch1_sgl_uv_dout), .empty(ch1_sgl_uv_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());

    wire [129:0] ch1_fifo_dout;
    wire        ch1_fifo_empty, ch1_tready;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(130), .READ_DATA_WIDTH(130), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000"))
    u_ch1_loopback_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(lb_tvalid && (h2c_desc_ctrl[7:6] == 2'd1 || h2c_desc_ctrl[7:6] == 2'd0)), .din({lb_tuser, lb_tlast, lb_tdata}), .full(), .rd_clk(video_clk), .rd_en(!ch1_fifo_empty && ch1_tready), .dout(ch1_fifo_dout), .empty(ch1_fifo_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    wire [127:0] ch1_tdata = ch1_fifo_dout[127:0]; wire ch1_tlast = ch1_fifo_dout[128]; wire ch1_tuser = ch1_fifo_dout[129]; wire ch1_tvalid = !ch1_fifo_empty;

    reg hs1_send_q; reg [240:0] hs1_bus_q; wire hs1_src_rcv, hs1_dest_req; wire [240:0] hs1_dest_bus; reg hs1_dest_ack; reg eng1_desc_valid, eng1_desc_sg_mode; reg [63:0] eng1_y_addr, eng1_uv_addr, eng1_ts; reg [15:0] eng1_width, eng1_height, eng1_stride; wire nv12_ch1_desc_ready_v;
    wire pcie_frame_done_ch1;
    reg ch1_owner_busy;
    wire nv12_ch1_desc_select = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd1);
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin hs1_send_q <= 1'b0; hs1_bus_q <= 241'd0; end
        else if (!hs1_send_q && !hs1_src_rcv && c2h_desc_valid && nv12_ch1_desc_select) begin hs1_bus_q <= {(c2h_desc_ctrl[4] | c2h_desc_ctrl[5]), global_timestamp, c2h_dst_stride, c2h_line_count, c2h_line_width, c2h_plane1_dst, c2h_plane0_dst}; hs1_send_q <= 1'b1; end
        else if (hs1_send_q && hs1_src_rcv) begin hs1_send_q <= 1'b0; end
    end
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n)
            ch1_owner_busy <= 1'b0;
        else if (pcie_frame_done_ch1)
            ch1_owner_busy <= 1'b0;
        else if (c2h_desc_valid && nv12_ch1_desc_select &&
                 !hs1_send_q && !hs1_src_rcv && !ch1_owner_busy)
            ch1_owner_busy <= 1'b1;
    end
    assign nv12_ch1_desc_ready = c2h_desc_valid && nv12_ch1_desc_select &&
                                  !hs1_send_q && !hs1_src_rcv && !ch1_owner_busy;
    xpm_cdc_handshake #(.WIDTH(241), .DEST_EXT_HSK(1)) u_desc_cdc_ch1 (.src_clk(clk), .src_send(hs1_send_q), .src_rcv(hs1_src_rcv), .src_in(hs1_bus_q), .dest_clk(video_clk), .dest_req(hs1_dest_req), .dest_out(hs1_dest_bus), .dest_ack(hs1_dest_ack));
    reg [1:0] dest1_state;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin dest1_state <= DEST_IDLE; eng1_desc_valid <= 1'b0; eng1_desc_sg_mode <= 1'b0; hs1_dest_ack <= 1'b0; eng1_y_addr <= 64'd0; eng1_uv_addr <= 64'd0; eng1_width <= 16'd0; eng1_height <= 16'd0; eng1_stride <= 16'd0; eng1_ts <= 64'd0; end
        else case (dest1_state)
            DEST_IDLE: begin hs1_dest_ack <= 1'b0; if (hs1_dest_req) begin eng1_y_addr <= hs1_dest_bus[63:0]; eng1_uv_addr <= hs1_dest_bus[127:64]; eng1_width <= hs1_dest_bus[143:128]; eng1_height <= hs1_dest_bus[159:144]; eng1_stride <= hs1_dest_bus[175:160]; eng1_ts <= hs1_dest_bus[239:176]; eng1_desc_sg_mode <= hs1_dest_bus[240]; eng1_desc_valid <= 1'b1; dest1_state <= DEST_WAIT_ENG; end end
            DEST_WAIT_ENG: begin if (eng1_desc_valid && nv12_ch1_desc_ready_v) begin eng1_desc_valid <= 1'b0; hs1_dest_ack <= 1'b1; dest1_state <= DEST_WAIT_REQ_LOW; end end
            DEST_WAIT_REQ_LOW: begin if (!hs1_dest_req) begin hs1_dest_ack <= 1'b0; dest1_state <= DEST_IDLE; end end
            default: dest1_state <= DEST_IDLE;
        endcase
    end
    wire eng1_req_valid, eng1_req_ready, eng1_req_ack; wire [63:0] eng1_req_addr; wire [10:0] eng1_req_dw_len; wire [PCIE_DATA_WIDTH-1:0] eng1_req_data; wire eng1_frame_done;
    assign ch1_sgl_y_rd_en = !ch1_sgl_y_empty && ch1_sgl_y_pop_ready && v_busy[1];
    assign ch1_sgl_uv_rd_en = !ch1_sgl_uv_empty && ch1_sgl_uv_pop_ready && v_busy[1];
    nv12_capture_engine #(.MAX_WIDTH(3840), .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH), .FIFO_DEPTH(32), .MWR_PAYLOAD_BYTES(256), .RAW_INPUT(1))
    u_nv12_capture_engine_ch1 (.clk(video_clk), .rst_n(video_rst_n), .desc_valid(eng1_desc_valid), .desc_ready(nv12_ch1_desc_ready_v), .desc_sg_mode(eng1_desc_sg_mode), .plane_y_addr(eng1_y_addr), .plane_uv_addr(eng1_uv_addr), .frame_width(eng1_width), .frame_height(eng1_height), .frame_stride(eng1_stride),
        .sgl_y_wr_en(ch1_sgl_y_rd_en), .sgl_y_wr_addr(ch1_sgl_y_dout[63:0]), .sgl_y_wr_len(ch1_sgl_y_dout[95:64]), .sgl_y_wr_flags(ch1_sgl_y_dout[127:96]),
        .sgl_uv_wr_en(ch1_sgl_uv_rd_en), .sgl_uv_wr_addr(ch1_sgl_uv_dout[63:0]), .sgl_uv_wr_len(ch1_sgl_uv_dout[95:64]), .sgl_uv_wr_flags(ch1_sgl_uv_dout[127:96]),
        .cur_y_sgl_count(), .cur_uv_sgl_count(), .sgl_y_pop_ready(ch1_sgl_y_pop_ready), .sgl_uv_pop_ready(ch1_sgl_uv_pop_ready), .pacer_enable(1'b0), .frame_interval_clks(32'd2500000), .global_timestamp(eng1_ts), .s_axis_tdata(ch1_tdata), .s_axis_tvalid(ch1_tvalid), .s_axis_tlast(ch1_tlast), .s_axis_tuser(ch1_tuser), .s_axis_tready(ch1_tready),
        .c2h_req_valid(eng1_req_valid), .c2h_req_addr(eng1_req_addr), .c2h_req_dw_len(eng1_req_dw_len), .c2h_req_data(eng1_req_data), .c2h_req_last(), .c2h_req_data_ready(eng1_req_ready), .c2h_req_ack(eng1_req_ack), .video_busy(v_busy[1]), .video_frame_done(eng1_frame_done), .frame_pts(v_pts[1]), .protocol_error_count(v_drop_cnt[1]));
    assign v_done[1] = pcie_frame_done_ch1;
    video_req_cdc #(.MAX_DWORDS(64), .FIFO_DEPTH(512)) u_video_req_cdc_ch1 (.wr_clk(video_clk), .wr_rst_n(video_rst_n), .s_req_valid(eng1_req_valid), .s_req_addr(eng1_req_addr), .s_req_dw_len(eng1_req_dw_len), .s_req_data(eng1_req_data), .s_req_data_ready(eng1_req_ready), .s_req_ack(eng1_req_ack), .s_frame_done(eng1_frame_done), .rd_clk(clk), .rd_rst_n(dma_rst_n), .m_req_valid(v_c2h_req_valid[1]), .m_req_addr(v_c2h_req_addr[127:64]), .m_req_dw_len(v_c2h_req_dw_len[21:11]), .m_req_data(v_c2h_req_data[(1*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]), .m_req_data_ready(v_c2h_req_data_ready[1]), .m_req_ack(v_c2h_req_ack[1]), .m_frame_done(pcie_frame_done_ch1), .m_fifo_empty(), .m_fifo_count());

    // ---------------------- CHANNEL 2 ----------------------------------------
    wire [127:0] ch2_sgl_y_dout, ch2_sgl_uv_dout;
    wire        ch2_sgl_y_empty, ch2_sgl_uv_empty;
    wire        ch2_sgl_y_pop_ready, ch2_sgl_uv_pop_ready;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch2_sgl_y_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(sgl_ch2_y_wr_en), .din({sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}), .prog_full(ch2_sgl_y_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch2_sgl_y_empty && ch2_sgl_y_pop_ready), .dout(ch2_sgl_y_dout), .empty(ch2_sgl_y_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch2_sgl_uv_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(sgl_ch2_uv_wr_en), .din({sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}), .prog_full(ch2_sgl_uv_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch2_sgl_uv_empty && ch2_sgl_uv_pop_ready), .dout(ch2_sgl_uv_dout), .empty(ch2_sgl_uv_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());

    wire [129:0] ch2_fifo_dout;
    wire        ch2_fifo_empty, ch2_tready;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(130), .READ_DATA_WIDTH(130), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000"))
    u_ch2_loopback_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(lb_tvalid && (h2c_desc_ctrl[7:6] == 2'd2)), .din({lb_tuser, lb_tlast, lb_tdata}), .full(), .rd_clk(video_clk), .rd_en(!ch2_fifo_empty && ch2_tready), .dout(ch2_fifo_dout), .empty(ch2_fifo_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    wire [127:0] ch2_tdata = ch2_fifo_dout[127:0]; wire ch2_tlast = ch2_fifo_dout[128]; wire ch2_tuser = ch2_fifo_dout[129]; wire ch2_tvalid = !ch2_fifo_empty;

    reg hs2_send_q; reg [240:0] hs2_bus_q; wire hs2_src_rcv, hs2_dest_req; wire [240:0] hs2_dest_bus; reg hs2_dest_ack; reg eng2_desc_valid, eng2_desc_sg_mode; reg [63:0] eng2_y_addr, eng2_uv_addr, eng2_ts; reg [15:0] eng2_width, eng2_height, eng2_stride; wire nv12_ch2_desc_ready_v;
    wire pcie_frame_done_ch2;
    reg ch2_owner_busy;
    wire nv12_ch2_desc_select = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd2);
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin hs2_send_q <= 1'b0; hs2_bus_q <= 241'd0; end
        else if (!hs2_send_q && !hs2_src_rcv && c2h_desc_valid && nv12_ch2_desc_select) begin hs2_bus_q <= {(c2h_desc_ctrl[4] | c2h_desc_ctrl[5]), global_timestamp, c2h_dst_stride, c2h_line_count, c2h_line_width, c2h_plane1_dst, c2h_plane0_dst}; hs2_send_q <= 1'b1; end
        else if (hs2_send_q && hs2_src_rcv) begin hs2_send_q <= 1'b0; end
    end
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n)
            ch2_owner_busy <= 1'b0;
        else if (pcie_frame_done_ch2)
            ch2_owner_busy <= 1'b0;
        else if (c2h_desc_valid && nv12_ch2_desc_select &&
                 !hs2_send_q && !hs2_src_rcv && !ch2_owner_busy)
            ch2_owner_busy <= 1'b1;
    end
    wire nv12_ch2_desc_ready = c2h_desc_valid && nv12_ch2_desc_select &&
                               !hs2_send_q && !hs2_src_rcv && !ch2_owner_busy;
    xpm_cdc_handshake #(.WIDTH(241), .DEST_EXT_HSK(1)) u_desc_cdc_ch2 (.src_clk(clk), .src_send(hs2_send_q), .src_rcv(hs2_src_rcv), .src_in(hs2_bus_q), .dest_clk(video_clk), .dest_req(hs2_dest_req), .dest_out(hs2_dest_bus), .dest_ack(hs2_dest_ack));
    reg [1:0] dest2_state;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin dest2_state <= DEST_IDLE; eng2_desc_valid <= 1'b0; eng2_desc_sg_mode <= 1'b0; hs2_dest_ack <= 1'b0; eng2_y_addr <= 64'd0; eng2_uv_addr <= 64'd0; eng2_width <= 16'd0; eng2_height <= 16'd0; eng2_stride <= 16'd0; eng2_ts <= 64'd0; end
        else case (dest2_state)
            DEST_IDLE: begin hs2_dest_ack <= 1'b0; if (hs2_dest_req) begin eng2_y_addr <= hs2_dest_bus[63:0]; eng2_uv_addr <= hs2_dest_bus[127:64]; eng2_width <= hs2_dest_bus[143:128]; eng2_height <= hs2_dest_bus[159:144]; eng2_stride <= hs2_dest_bus[175:160]; eng2_ts <= hs2_dest_bus[239:176]; eng2_desc_sg_mode <= hs2_dest_bus[240]; eng2_desc_valid <= 1'b1; dest2_state <= DEST_WAIT_ENG; end end
            DEST_WAIT_ENG: begin if (eng2_desc_valid && nv12_ch2_desc_ready_v) begin eng2_desc_valid <= 1'b0; hs2_dest_ack <= 1'b1; dest2_state <= DEST_WAIT_REQ_LOW; end end
            DEST_WAIT_REQ_LOW: begin if (!hs2_dest_req) begin hs2_dest_ack <= 1'b0; dest2_state <= DEST_IDLE; end end
            default: dest2_state <= DEST_IDLE;
        endcase
    end
    wire eng2_req_valid, eng2_req_ready, eng2_req_ack; wire [63:0] eng2_req_addr; wire [10:0] eng2_req_dw_len; wire [PCIE_DATA_WIDTH-1:0] eng2_req_data; wire eng2_frame_done;
    nv12_capture_engine #(.MAX_WIDTH(3840), .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH), .FIFO_DEPTH(32), .MWR_PAYLOAD_BYTES(256), .RAW_INPUT(1))
    u_nv12_capture_engine_ch2 (.clk(video_clk), .rst_n(video_rst_n), .desc_valid(eng2_desc_valid), .desc_ready(nv12_ch2_desc_ready_v), .desc_sg_mode(eng2_desc_sg_mode), .plane_y_addr(eng2_y_addr), .plane_uv_addr(eng2_uv_addr), .frame_width(eng2_width), .frame_height(eng2_height), .frame_stride(eng2_stride),
        .sgl_y_wr_en(!ch2_sgl_y_empty && ch2_sgl_y_pop_ready), .sgl_y_wr_addr(ch2_sgl_y_dout[63:0]), .sgl_y_wr_len(ch2_sgl_y_dout[95:64]), .sgl_y_wr_flags(ch2_sgl_y_dout[127:96]),
        .sgl_uv_wr_en(!ch2_sgl_uv_empty && ch2_sgl_uv_pop_ready), .sgl_uv_wr_addr(ch2_sgl_uv_dout[63:0]), .sgl_uv_wr_len(ch2_sgl_uv_dout[95:64]), .sgl_uv_wr_flags(ch2_sgl_uv_dout[127:96]),
        .cur_y_sgl_count(), .cur_uv_sgl_count(), .sgl_y_pop_ready(ch2_sgl_y_pop_ready), .sgl_uv_pop_ready(ch2_sgl_uv_pop_ready), .pacer_enable(1'b0), .frame_interval_clks(32'd2500000), .global_timestamp(eng2_ts), .s_axis_tdata(ch2_tdata), .s_axis_tvalid(ch2_tvalid), .s_axis_tlast(ch2_tlast), .s_axis_tuser(ch2_tuser), .s_axis_tready(ch2_tready),
        .c2h_req_valid(eng2_req_valid), .c2h_req_addr(eng2_req_addr), .c2h_req_dw_len(eng2_req_dw_len), .c2h_req_data(eng2_req_data), .c2h_req_last(), .c2h_req_data_ready(eng2_req_ready), .c2h_req_ack(eng2_req_ack), .video_busy(v_busy[2]), .video_frame_done(eng2_frame_done), .frame_pts(v_pts[2]), .protocol_error_count(v_drop_cnt[2]));
    assign v_done[2] = pcie_frame_done_ch2;
    video_req_cdc #(.MAX_DWORDS(64), .FIFO_DEPTH(512)) u_video_req_cdc_ch2 (.wr_clk(video_clk), .wr_rst_n(video_rst_n), .s_req_valid(eng2_req_valid), .s_req_addr(eng2_req_addr), .s_req_dw_len(eng2_req_dw_len), .s_req_data(eng2_req_data), .s_req_data_ready(eng2_req_ready), .s_req_ack(eng2_req_ack), .s_frame_done(eng2_frame_done), .rd_clk(clk), .rd_rst_n(dma_rst_n), .m_req_valid(v_c2h_req_valid[2]), .m_req_addr(v_c2h_req_addr[191:128]), .m_req_dw_len(v_c2h_req_dw_len[32:22]), .m_req_data(v_c2h_req_data[(2*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]), .m_req_data_ready(v_c2h_req_data_ready[2]), .m_req_ack(v_c2h_req_ack[2]), .m_frame_done(pcie_frame_done_ch2), .m_fifo_empty(), .m_fifo_count());

    // ---------------------- CHANNEL 3 ----------------------------------------
    wire [127:0] ch3_sgl_y_dout, ch3_sgl_uv_dout;
    wire        ch3_sgl_y_empty, ch3_sgl_uv_empty;
    wire        ch3_sgl_y_pop_ready, ch3_sgl_uv_pop_ready;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch3_sgl_y_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(sgl_ch3_y_wr_en), .din({sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}), .prog_full(ch3_sgl_y_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch3_sgl_y_empty && ch3_sgl_y_pop_ready), .dout(ch3_sgl_y_dout), .empty(ch3_sgl_y_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch3_sgl_uv_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(sgl_ch3_uv_wr_en), .din({sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}), .prog_full(ch3_sgl_uv_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch3_sgl_uv_empty && ch3_sgl_uv_pop_ready), .dout(ch3_sgl_uv_dout), .empty(ch3_sgl_uv_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());

    wire [129:0] ch3_fifo_dout;
    wire        ch3_fifo_empty, ch3_tready;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(130), .READ_DATA_WIDTH(130), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000"))
    u_ch3_loopback_cdc (.rst(!rst_n || !video_rst_n), .wr_clk(clk), .wr_en(lb_tvalid && (h2c_desc_ctrl[7:6] == 2'd3)), .din({lb_tuser, lb_tlast, lb_tdata}), .full(), .rd_clk(video_clk), .rd_en(!ch3_fifo_empty && ch3_tready), .dout(ch3_fifo_dout), .empty(ch3_fifo_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    wire [127:0] ch3_tdata = ch3_fifo_dout[127:0]; wire ch3_tlast = ch3_fifo_dout[128]; wire ch3_tuser = ch3_fifo_dout[129]; wire ch3_tvalid = !ch3_fifo_empty;

    reg hs3_send_q; reg [240:0] hs3_bus_q; wire hs3_src_rcv, hs3_dest_req; wire [240:0] hs3_dest_bus; reg hs3_dest_ack; reg eng3_desc_valid, eng3_desc_sg_mode; reg [63:0] eng3_y_addr, eng3_uv_addr, eng3_ts; reg [15:0] eng3_width, eng3_height, eng3_stride; wire nv12_ch3_desc_ready_v;
    wire pcie_frame_done_ch3;
    reg ch3_owner_busy;
    wire nv12_ch3_desc_select = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd3);
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin hs3_send_q <= 1'b0; hs3_bus_q <= 241'd0; end
        else if (!hs3_send_q && !hs3_src_rcv && c2h_desc_valid && nv12_ch3_desc_select) begin hs3_bus_q <= {(c2h_desc_ctrl[4] | c2h_desc_ctrl[5]), global_timestamp, c2h_dst_stride, c2h_line_count, c2h_line_width, c2h_plane1_dst, c2h_plane0_dst}; hs3_send_q <= 1'b1; end
        else if (hs3_send_q && hs3_src_rcv) begin hs3_send_q <= 1'b0; end
    end
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n)
            ch3_owner_busy <= 1'b0;
        else if (pcie_frame_done_ch3)
            ch3_owner_busy <= 1'b0;
        else if (c2h_desc_valid && nv12_ch3_desc_select &&
                 !hs3_send_q && !hs3_src_rcv && !ch3_owner_busy)
            ch3_owner_busy <= 1'b1;
    end
    wire nv12_ch3_desc_ready = c2h_desc_valid && nv12_ch3_desc_select &&
                               !hs3_send_q && !hs3_src_rcv && !ch3_owner_busy;
    xpm_cdc_handshake #(.WIDTH(241), .DEST_EXT_HSK(1)) u_desc_cdc_ch3 (.src_clk(clk), .src_send(hs3_send_q), .src_rcv(hs3_src_rcv), .src_in(hs3_bus_q), .dest_clk(video_clk), .dest_req(hs3_dest_req), .dest_out(hs3_dest_bus), .dest_ack(hs3_dest_ack));
    reg [1:0] dest3_state;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin dest3_state <= DEST_IDLE; eng3_desc_valid <= 1'b0; eng3_desc_sg_mode <= 1'b0; hs3_dest_ack <= 1'b0; eng3_y_addr <= 64'd0; eng3_uv_addr <= 64'd0; eng3_width <= 16'd0; eng3_height <= 16'd0; eng3_stride <= 16'd0; eng3_ts <= 64'd0; end
        else case (dest3_state)
            DEST_IDLE: begin hs3_dest_ack <= 1'b0; if (hs3_dest_req) begin eng3_y_addr <= hs3_dest_bus[63:0]; eng3_uv_addr <= hs3_dest_bus[127:64]; eng3_width <= hs3_dest_bus[143:128]; eng3_height <= hs3_dest_bus[159:144]; eng3_stride <= hs3_dest_bus[175:160]; eng3_ts <= hs3_dest_bus[239:176]; eng3_desc_sg_mode <= hs3_dest_bus[240]; eng3_desc_valid <= 1'b1; dest3_state <= DEST_WAIT_ENG; end end
            DEST_WAIT_ENG: begin if (eng3_desc_valid && nv12_ch3_desc_ready_v) begin eng3_desc_valid <= 1'b0; hs3_dest_ack <= 1'b1; dest3_state <= DEST_WAIT_REQ_LOW; end end
            DEST_WAIT_REQ_LOW: begin if (!hs3_dest_req) begin hs3_dest_ack <= 1'b0; dest3_state <= DEST_IDLE; end end
            default: dest3_state <= DEST_IDLE;
        endcase
    end
    wire eng3_req_valid, eng3_req_ready, eng3_req_ack; wire [63:0] eng3_req_addr; wire [10:0] eng3_req_dw_len; wire [PCIE_DATA_WIDTH-1:0] eng3_req_data; wire eng3_frame_done;
    nv12_capture_engine #(.MAX_WIDTH(3840), .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH), .FIFO_DEPTH(32), .MWR_PAYLOAD_BYTES(256), .RAW_INPUT(1))
    u_nv12_capture_engine_ch3 (.clk(video_clk), .rst_n(video_rst_n), .desc_valid(eng3_desc_valid), .desc_ready(nv12_ch3_desc_ready_v), .desc_sg_mode(eng3_desc_sg_mode), .plane_y_addr(eng3_y_addr), .plane_uv_addr(eng3_uv_addr), .frame_width(eng3_width), .frame_height(eng3_height), .frame_stride(eng3_stride),
        .sgl_y_wr_en(!ch3_sgl_y_empty && ch3_sgl_y_pop_ready), .sgl_y_wr_addr(ch3_sgl_y_dout[63:0]), .sgl_y_wr_len(ch3_sgl_y_dout[95:64]), .sgl_y_wr_flags(ch3_sgl_y_dout[127:96]),
        .sgl_uv_wr_en(!ch3_sgl_uv_empty && ch3_sgl_uv_pop_ready), .sgl_uv_wr_addr(ch3_sgl_uv_dout[63:0]), .sgl_uv_wr_len(ch3_sgl_uv_dout[95:64]), .sgl_uv_wr_flags(ch3_sgl_uv_dout[127:96]),
        .cur_y_sgl_count(), .cur_uv_sgl_count(), .sgl_y_pop_ready(ch3_sgl_y_pop_ready), .sgl_uv_pop_ready(ch3_sgl_uv_pop_ready), .pacer_enable(1'b0), .frame_interval_clks(32'd2500000), .global_timestamp(eng3_ts), .s_axis_tdata(ch3_tdata), .s_axis_tvalid(ch3_tvalid), .s_axis_tlast(ch3_tlast), .s_axis_tuser(ch3_tuser), .s_axis_tready(ch3_tready),
        .c2h_req_valid(eng3_req_valid), .c2h_req_addr(eng3_req_addr), .c2h_req_dw_len(eng3_req_dw_len), .c2h_req_data(eng3_req_data), .c2h_req_last(), .c2h_req_data_ready(eng3_req_ready), .c2h_req_ack(eng3_req_ack), .video_busy(v_busy[3]), .video_frame_done(eng3_frame_done), .frame_pts(v_pts[3]), .protocol_error_count(v_drop_cnt[3]));
    assign v_done[3] = pcie_frame_done_ch3;
    video_req_cdc #(.MAX_DWORDS(64), .FIFO_DEPTH(512)) u_video_req_cdc_ch3 (.wr_clk(video_clk), .wr_rst_n(video_rst_n), .s_req_valid(eng3_req_valid), .s_req_addr(eng3_req_addr), .s_req_dw_len(eng3_req_dw_len), .s_req_data(eng3_req_data), .s_req_data_ready(eng3_req_ready), .s_req_ack(eng3_req_ack), .s_frame_done(eng3_frame_done), .rd_clk(clk), .rd_rst_n(dma_rst_n), .m_req_valid(v_c2h_req_valid[3]), .m_req_addr(v_c2h_req_addr[255:192]), .m_req_dw_len(v_c2h_req_dw_len[43:33]), .m_req_data(v_c2h_req_data[(3*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]), .m_req_data_ready(v_c2h_req_data_ready[3]), .m_req_ack(v_c2h_req_ack[3]), .m_frame_done(pcie_frame_done_ch3), .m_fifo_empty(), .m_fifo_count());

    assign m_axis_video_tdata[VIDEO_DATA_WIDTH-1:0] = {VIDEO_DATA_WIDTH{1'b0}};
    assign m_axis_video_tvalid[0] = 1'b0;
    assign m_axis_video_tlast[0] = 1'b0;
    assign m_axis_video_tuser[0] = 1'b0;

    // 9. Multi-Channel AES3 Audio Stream Engines (Parameterized Generator)
    genvar a_idx;
    generate
        for (a_idx = 0; a_idx < NUM_A_CH; a_idx = a_idx + 1) begin : gen_audio_ch
            wire a_start;
            assign a_start = (a_idx == 0) ? reg_dma_ctrl[2] : 1'b0;

            audio_stream_engine #(
                .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH),
                .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH)
            ) u_audio_stream_engine (
                .clk(clk),
                .rst_n(dma_rst_n),
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
                .c2h_req_ack(a_c2h_req_ack[a_idx]),
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
        .rst_n(dma_rst_n),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status_w1c(reg_irq_status_w1c),
        .reg_irq_status(reg_irq_status),
        .h2c_done(sg_h2c_done_irq),
        .c2h_done(v_done[0] | v_done[1] | v_done[2] | v_done[3] | sg_c2h_done_irq | a_done[0] | a_done[1] | a_done[2] | a_done[3]),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

endmodule
