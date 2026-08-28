// ============================================================================
// Module: sg_dma_engine
// Description: Multi-Page Scatter-Gather (SG) DMA Execution Engine for Artix-7 A50T.
//              Executes H2C Host->FPGA MRd transfers and C2H FPGA->Host MWr transfers
//              for SG descriptor chains, tracking real-time completion counters.
// ============================================================================

`timescale 1ns / 1ps

module sg_dma_engine #(
    parameter PCIE_DATA_WIDTH = 128
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // Interface from Descriptor Fetch Engine (H2C Descriptor Channel)
    input  wire                          h2c_desc_valid,
    input  wire [63:0]                   h2c_plane0_src,
    input  wire [63:0]                   h2c_plane1_src,
    input  wire [15:0]                   h2c_line_width,
    input  wire [15:0]                   h2c_line_count,
    input  wire [15:0]                   h2c_plane12_width,
    input  wire [15:0]                   h2c_plane12_count,
    input  wire [3:0]                    h2c_plane_count,
    input  wire [15:0]                   h2c_desc_ctrl,
    output reg                           h2c_desc_ready,

    // SGL Segment Push Ports for H2C (from sg_host_fetch_engine)
    input  wire                          sgl_h2c_y_wr_en,
    input  wire [63:0]                   sgl_h2c_y_wr_addr,
    input  wire [31:0]                   sgl_h2c_y_wr_len,
    input  wire [31:0]                   sgl_h2c_y_wr_flags,
    input  wire                          sgl_h2c_uv_wr_en,
    input  wire [63:0]                   sgl_h2c_uv_wr_addr,
    input  wire [31:0]                   sgl_h2c_uv_wr_len,
    input  wire [31:0]                   sgl_h2c_uv_wr_flags,

    // Interface from Descriptor Fetch Engine (C2H Descriptor Channel)
    input  wire                          c2h_desc_valid,
    input  wire [63:0]                   c2h_plane0_dst,
    input  wire [15:0]                   c2h_line_width,
    input  wire [15:0]                   c2h_line_count,
    input  wire [15:0]                   c2h_plane12_width,
    input  wire [15:0]                   c2h_plane12_count,
    input  wire [3:0]                    c2h_plane_count,
    output reg                           c2h_desc_ready,

    // Interface to RQ TX Encoder (H2C MRd Channel)
    output reg                           h2c_req_valid,
    output reg  [63:0]                   h2c_req_addr,
    output reg  [10:0]                   h2c_req_dw_len,
    output reg  [7:0]                    h2c_req_tag,
    input  wire                          h2c_req_ack,

    // Interface to RQ TX Encoder (C2H MWr Channel)
    output reg                           c2h_req_valid,
    output reg  [63:0]                   c2h_req_addr,
    output reg  [10:0]                   c2h_req_dw_len,
    output reg  [PCIE_DATA_WIDTH-1:0]    c2h_req_data,
    output reg                           c2h_req_last,
    input  wire                          c2h_req_data_ready,
    input  wire                          c2h_req_ack,

    // Interface from RC RX Decoder (H2C CplD Stream Consumer)
    input  wire                          h2c_cpl_valid,
    input  wire [PCIE_DATA_WIDTH-1:0]    h2c_cpl_data,
    input  wire                          h2c_cpl_last,

    // Flow Control Backpressure to SG Host Fetch Engine
    output wire                          h2c_y_almost_full,
    output wire                          h2c_uv_almost_full,

    // Loopback Stream Interface (For Multi-Channel Video Loopback)
    output wire [PCIE_DATA_WIDTH-1:0]    m_axis_loopback_tdata,
    output wire                          m_axis_loopback_tvalid,
    output wire                          m_axis_loopback_tlast,
    output wire                          m_axis_loopback_tuser,
    input  wire                          m_axis_loopback_tready,

    // Status & Error Counters
    output wire                          h2c_busy,
    output wire                          c2h_busy,
    output reg  [31:0]                   completed_h2c_count,
    output reg  [31:0]                   completed_c2h_count,
    output reg  [31:0]                   h2c_bytes_transferred,
    output reg  [31:0]                   c2h_bytes_transferred,
    output reg  [31:0]                   dma_error_count
);

    assign m_axis_loopback_tdata  = h2c_cpl_data;
    assign m_axis_loopback_tvalid = h2c_cpl_valid;
    assign m_axis_loopback_tlast  = h2c_cpl_last && (h2c_rem_bytes == 0);
    assign m_axis_loopback_tuser  = (h2c_burst_recv_dw == 0) && (h2c_bytes_transferred == 0);

    // =========================================================================
    // H2C (Host -> FPGA) DMA Execution State Machine
    // =========================================================================
    localparam H2C_IDLE       = 3'd0;
    localparam H2C_PRECALC    = 3'd1;
    localparam H2C_ISSUE_MRD  = 3'd2;
    localparam H2C_WAIT_ACK   = 3'd3;
    localparam H2C_WAIT_CPLD  = 3'd4;

    reg [2:0]  h2c_state;
    reg [63:0] h2c_cur_addr;
    reg [31:0] h2c_rem_bytes;
    reg [31:0] h2c_p0_bytes_q;
    reg [31:0] h2c_p1_bytes_q;
    reg [3:0]  h2c_plane_cnt_q;
    reg [15:0] h2c_desc_ctrl_q;
    reg        h2c_is_uv;
    reg [10:0] h2c_burst_dw;
    reg [10:0] h2c_burst_recv_dw;
    reg        h2c_cpl_in_packet;
    wire [10:0] h2c_cpl_step_dw = !h2c_cpl_in_packet ? 11'd1 :
        ((h2c_burst_dw - h2c_burst_recv_dw) < (PCIE_DATA_WIDTH/32)) ?
        (h2c_burst_dw - h2c_burst_recv_dw) : (PCIE_DATA_WIDTH/32);

    wire h2c_sg_mode = h2c_desc_ctrl_q[5] || h2c_desc_ctrl_q[4];

    wire [63:0] h2c_y_walker_addr;
    wire [31:0] h2c_y_walker_bytes_left;
    wire        h2c_y_seg_valid;
    wire [6:0]  h2c_y_sgl_count;

    sg_segment_walker #(
        .FIFO_DEPTH(64)
    ) u_h2c_y_walker (
        .clk(clk),
        .rst_n(rst_n),
        .start(h2c_state == H2C_IDLE && h2c_desc_valid),
        .sg_mode(h2c_desc_ctrl[5] || h2c_desc_ctrl[4]),
        .linear_base_addr(h2c_plane0_src),
        .sgl_wr_en(sgl_h2c_y_wr_en),
        .sgl_wr_addr(sgl_h2c_y_wr_addr),
        .sgl_wr_len(sgl_h2c_y_wr_len),
        .sgl_wr_flags(sgl_h2c_y_wr_flags),
        .advance_burst(h2c_req_valid && h2c_req_ack && !h2c_is_uv),
        .burst_bytes({h2c_burst_dw, 2'b00}),
        .current_addr(h2c_y_walker_addr),
        .seg_bytes_left(h2c_y_walker_bytes_left),
        .seg_valid(h2c_y_seg_valid),
        .fifo_count(h2c_y_sgl_count),
        .fifo_almost_full(h2c_y_almost_full),
        .fifo_empty()
    );

    wire [63:0] h2c_uv_walker_addr;
    wire [31:0] h2c_uv_walker_bytes_left;
    wire        h2c_uv_seg_valid;
    wire [6:0]  h2c_uv_sgl_count;

    sg_segment_walker #(
        .FIFO_DEPTH(64)
    ) u_h2c_uv_walker (
        .clk(clk),
        .rst_n(rst_n),
        .start(h2c_state == H2C_IDLE && h2c_desc_valid),
        .sg_mode(h2c_desc_ctrl[5] || h2c_desc_ctrl[4]),
        .linear_base_addr(h2c_plane1_src),
        .sgl_wr_en(sgl_h2c_uv_wr_en),
        .sgl_wr_addr(sgl_h2c_uv_wr_addr),
        .sgl_wr_len(sgl_h2c_uv_wr_len),
        .sgl_wr_flags(sgl_h2c_uv_wr_flags),
        .advance_burst(h2c_req_valid && h2c_req_ack && h2c_is_uv),
        .burst_bytes({h2c_burst_dw, 2'b00}),
        .current_addr(h2c_uv_walker_addr),
        .seg_bytes_left(h2c_uv_walker_bytes_left),
        .seg_valid(h2c_uv_seg_valid),
        .fifo_count(h2c_uv_sgl_count),
        .fifo_almost_full(h2c_uv_almost_full),
        .fifo_empty()
    );

    wire [63:0] h2c_target_addr = (h2c_sg_mode) ? (!h2c_is_uv ? h2c_y_walker_addr : h2c_uv_walker_addr) : h2c_cur_addr;
    wire [12:0] h2c_bytes_to_4k = 13'd4096 - {1'b0, h2c_target_addr[11:0]};
    wire [31:0] h2c_avail_bytes = (h2c_sg_mode) ? (!h2c_is_uv ? h2c_y_walker_bytes_left : h2c_uv_walker_bytes_left) : {19'd0, h2c_bytes_to_4k};
    wire [15:0] h2c_limit_bytes = (h2c_rem_bytes < 32'd256) ? h2c_rem_bytes[15:0] : 16'd256;
    wire [15:0] h2c_burst_bytes = (h2c_limit_bytes < h2c_avail_bytes[15:0]) ? h2c_limit_bytes : h2c_avail_bytes[15:0];

    wire h2c_walker_ready = !h2c_sg_mode || (!h2c_is_uv ? (h2c_y_seg_valid && h2c_y_walker_bytes_left > 0) : (h2c_uv_seg_valid && h2c_uv_walker_bytes_left > 0));

    assign h2c_busy = (h2c_state != H2C_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h2c_state             <= H2C_IDLE;
            h2c_desc_ready        <= 1'b0;
            h2c_req_valid         <= 1'b0;
            h2c_req_addr          <= 64'd0;
            h2c_req_dw_len        <= 11'd0;
            h2c_req_tag           <= 8'h02;
            completed_h2c_count   <= 32'd0;
            h2c_bytes_transferred <= 32'd0;
            h2c_cur_addr          <= 64'd0;
            h2c_rem_bytes         <= 32'd0;
            h2c_p0_bytes_q        <= 32'd0;
            h2c_p1_bytes_q        <= 32'd0;
            h2c_plane_cnt_q       <= 4'd0;
            h2c_desc_ctrl_q       <= 16'd0;
            h2c_is_uv             <= 1'b0;
            h2c_burst_dw          <= 11'd0;
            h2c_burst_recv_dw     <= 11'd0;
            h2c_cpl_in_packet     <= 1'b0;
        end else begin
            case (h2c_state)
                H2C_IDLE: begin
                    h2c_desc_ready <= 1'b0;
                    h2c_req_valid  <= 1'b0;
                    h2c_is_uv      <= 1'b0;
                    if (h2c_desc_valid) begin
                        h2c_cur_addr      <= h2c_plane0_src;
                        h2c_p0_bytes_q    <= (h2c_line_width > 0 ? h2c_line_width : 16'd4096) * (h2c_line_count > 0 ? h2c_line_count : 16'd1);
                        h2c_p1_bytes_q    <= (h2c_plane12_width > 0 ? h2c_plane12_width : 16'd0) * (h2c_plane12_count > 0 ? h2c_plane12_count : 16'd0);
                        h2c_plane_cnt_q   <= h2c_plane_count;
                        h2c_desc_ctrl_q   <= h2c_desc_ctrl;
                        h2c_burst_recv_dw <= 11'd0;
                        h2c_cpl_in_packet <= 1'b0;
                        h2c_state         <= H2C_PRECALC;
                    end
                end

                H2C_PRECALC: begin
                    h2c_desc_ready <= 1'b1;
                    h2c_rem_bytes  <= (h2c_plane_cnt_q >= 4'd2) ? (h2c_p0_bytes_q + h2c_p1_bytes_q) : h2c_p0_bytes_q;
                    h2c_is_uv      <= (h2c_p0_bytes_q == 0) && (h2c_plane_cnt_q >= 4'd2);
                    h2c_state      <= H2C_ISSUE_MRD;
                end

                H2C_ISSUE_MRD: begin
                    h2c_desc_ready <= 1'b0;
                    if (h2c_rem_bytes > 32'd0 && h2c_walker_ready && h2c_burst_bytes > 0) begin
                        h2c_burst_dw   <= h2c_burst_bytes[12:2];
                        h2c_req_dw_len <= h2c_burst_bytes[12:2];
                        h2c_req_addr   <= h2c_target_addr;
                        h2c_req_tag    <= 8'h02;
                        h2c_req_valid  <= 1'b1;
                        h2c_state      <= H2C_WAIT_ACK;
                    end else if (h2c_rem_bytes == 32'd0) begin
                        completed_h2c_count <= completed_h2c_count + 1'b1;
                        h2c_desc_ready      <= 1'b1;
                        h2c_state           <= H2C_IDLE;
                    end
                end

                H2C_WAIT_ACK: begin
                    if (h2c_req_ack) begin
                        h2c_req_valid     <= 1'b0;
                        h2c_cur_addr      <= h2c_cur_addr + (h2c_burst_dw << 2);
                        h2c_rem_bytes     <= h2c_rem_bytes - (h2c_burst_dw << 2);
                        h2c_is_uv         <= ((h2c_rem_bytes - (h2c_burst_dw << 2)) <= h2c_p1_bytes_q) && (h2c_plane_cnt_q >= 4'd2);
                        h2c_burst_recv_dw <= 11'd0;
                        h2c_cpl_in_packet <= 1'b0;
                        h2c_state         <= H2C_WAIT_CPLD;
                    end
                end

                H2C_WAIT_CPLD: begin
                    if (h2c_cpl_valid) begin
                        h2c_cpl_in_packet <= !h2c_cpl_last;
                        if ((h2c_burst_recv_dw + h2c_cpl_step_dw) >= h2c_burst_dw) begin
                            h2c_burst_recv_dw     <= 11'd0;
                            h2c_cpl_in_packet     <= 1'b0;
                            h2c_bytes_transferred <= h2c_bytes_transferred + (h2c_burst_dw << 2);
                            if (h2c_rem_bytes == 32'd0) begin
                                completed_h2c_count <= completed_h2c_count + 1'b1;
                                h2c_desc_ready      <= 1'b1;
                                h2c_state           <= H2C_IDLE;
                            end else begin
                                h2c_state           <= H2C_ISSUE_MRD;
                            end
                        end else begin
                            h2c_burst_recv_dw <= h2c_burst_recv_dw + h2c_cpl_step_dw;
                        end
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // C2H (FPGA -> Host) DMA Execution State Machine
    // =========================================================================
    // Diagnostic traffic uses 256-byte MWr payloads by default, matching the
    // video engine and a host MPS of at least 256 bytes. Bursts are shortened
    // at the descriptor end and may never cross a 4-KiB boundary.
    localparam C2H_IDLE       = 2'd0;
    localparam C2H_ISSUE_MWR  = 2'd1;
    localparam C2H_WAIT_ACK   = 2'd2;
    localparam C2H_COMPLETE   = 2'd3;
    localparam [15:0] C2H_MAX_BURST_BYTES = 16'd256;

    reg [1:0]  c2h_state;
    reg [63:0] c2h_cur_addr;
    reg [15:0] c2h_rem_bytes;
    reg [15:0] c2h_word_idx;
    reg [15:0] c2h_burst_bytes;
    reg [5:0]  c2h_payload_beats_to_load;

    wire [12:0] c2h_bytes_to_4k = 13'd4096 - {1'b0, c2h_cur_addr[11:0]};
    wire [15:0] c2h_desc_limited_bytes =
        (c2h_rem_bytes < C2H_MAX_BURST_BYTES) ?
        c2h_rem_bytes : C2H_MAX_BURST_BYTES;
    wire [15:0] c2h_next_burst_bytes =
        (c2h_desc_limited_bytes < c2h_bytes_to_4k) ?
        c2h_desc_limited_bytes : c2h_bytes_to_4k;
    wire [10:0] c2h_next_burst_dw = c2h_next_burst_bytes >> 2;
    wire [5:0] c2h_next_payload_beats =
        (c2h_next_burst_dw + (PCIE_DATA_WIDTH/32) - 1) /
        (PCIE_DATA_WIDTH/32);

    assign c2h_busy = (c2h_state != C2H_IDLE);

    function [31:0] c2h_pattern_dw;
        input [15:0] word_index;
        begin
            c2h_pattern_dw = 32'hC200_0000 |
                             (completed_c2h_count[7:0] << 16) |
                             word_index;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c2h_state                 <= C2H_IDLE;
            c2h_desc_ready            <= 1'b0;
            c2h_req_valid             <= 1'b0;
            c2h_req_addr              <= 64'd0;
            c2h_req_dw_len            <= 11'd0;
            c2h_req_data              <= {PCIE_DATA_WIDTH{1'b0}};
            c2h_req_last              <= 1'b0;
            completed_c2h_count       <= 32'd0;
            c2h_bytes_transferred     <= 32'd0;
            c2h_cur_addr              <= 64'd0;
            c2h_rem_bytes             <= 16'd0;
            c2h_word_idx              <= 16'd0;
            c2h_burst_bytes           <= 16'd0;
            c2h_payload_beats_to_load <= 6'd0;
        end else begin
            case (c2h_state)
                C2H_IDLE: begin
                    c2h_desc_ready <= 1'b0;
                    c2h_req_valid  <= 1'b0;
                    if (c2h_desc_valid) begin
                        c2h_desc_ready <= 1'b1;
                        c2h_cur_addr   <= c2h_plane0_dst;
                        c2h_rem_bytes  <= (c2h_line_width > 16'd0) ?
                                          c2h_line_width : 16'd4096;
                        c2h_word_idx   <= 16'd0;
                        c2h_state      <= C2H_ISSUE_MWR;
                    end
                end

                C2H_ISSUE_MWR: begin
                    c2h_desc_ready <= 1'b0;
                    if (c2h_rem_bytes > 16'd0) begin
                        c2h_req_addr      <= c2h_cur_addr;
                        c2h_req_dw_len    <= c2h_next_burst_dw;
                        c2h_req_data      <= {
                            c2h_pattern_dw(c2h_word_idx + 16'd3),
                            c2h_pattern_dw(c2h_word_idx + 16'd2),
                            c2h_pattern_dw(c2h_word_idx + 16'd1),
                            c2h_pattern_dw(c2h_word_idx)
                        };
                        c2h_req_last      <=
                            (c2h_rem_bytes <= c2h_next_burst_bytes);
                        c2h_burst_bytes   <= c2h_next_burst_bytes;
                        c2h_payload_beats_to_load <= c2h_next_payload_beats;
                        c2h_req_valid     <= 1'b1;
                        c2h_state         <= C2H_WAIT_ACK;
                    end else begin
                        c2h_state <= C2H_COMPLETE;
                    end
                end

                C2H_WAIT_ACK: begin
                    if (c2h_req_data_ready) begin
                        c2h_word_idx <= c2h_word_idx + (PCIE_DATA_WIDTH/32);
                        c2h_payload_beats_to_load <=
                            c2h_payload_beats_to_load - 1'b1;
                        if (c2h_payload_beats_to_load > 1) begin
                            c2h_req_data <= {
                                c2h_pattern_dw(c2h_word_idx + 16'd7),
                                c2h_pattern_dw(c2h_word_idx + 16'd6),
                                c2h_pattern_dw(c2h_word_idx + 16'd5),
                                c2h_pattern_dw(c2h_word_idx + 16'd4)
                            };
                        end
                    end
                    if (c2h_req_ack) begin
                        c2h_req_valid         <= 1'b0;
                        c2h_cur_addr          <= c2h_cur_addr + c2h_burst_bytes;
                        c2h_rem_bytes         <= c2h_rem_bytes - c2h_burst_bytes;
                        c2h_bytes_transferred <= c2h_bytes_transferred +
                                                  c2h_burst_bytes;
                        if (c2h_rem_bytes == c2h_burst_bytes)
                            c2h_state <= C2H_COMPLETE;
                        else
                            c2h_state <= C2H_ISSUE_MWR;
                    end
                end

                C2H_COMPLETE: begin
                    completed_c2h_count <= completed_c2h_count + 1'b1;
                    c2h_desc_ready      <= 1'b1;
                    c2h_state           <= C2H_IDLE;
                end

                default: c2h_state <= C2H_IDLE;
            endcase
        end
    end

endmodule
