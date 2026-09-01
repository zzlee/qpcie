// ============================================================================
// Module: desc_fetch_engine
// Description: Multi-Planar 2D Scatter-Gather Descriptor Fetch Engine.
//              Fetches 64-Byte (16 DW) Extended Descriptors from Host memory via RQ MRd,
//              parses multi-planar base addresses, 2D line dimensions and stride/pitch,
//              and dispatches to H2C/C2H DMA engines.
// ============================================================================

`timescale 1ns / 1ps

module desc_fetch_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Controls & Config from Register Space
    input  wire        dma_run,
    input  wire [63:0] ring_base_addr,
    input  wire [15:0] ring_size,
    input  wire [15:0] tail_ptr,
    output reg  [15:0] head_ptr,
    output wire        idle,

    // Interface to RQ TX Encoder (MRd Request)
    output reg         desc_req_valid,
    output reg  [63:0] desc_req_addr,
    output reg  [10:0] desc_req_dw_len,
    output reg  [7:0]  desc_req_tag,
    input  wire        desc_req_ack,

    // Interface from RC RX Decoder (CplD Payload - 512 bits / 64 Bytes)
    input  wire        desc_cpl_valid,
    input  wire [511:0] desc_cpl_data,
    input  wire        desc_cpl_last,

    // Dispatched Extended 2D Descriptor Output to H2C DMA Engine
    output reg         h2c_desc_valid,
    output reg  [63:0] h2c_plane0_src, h2c_plane0_dst,
    output reg  [63:0] h2c_plane1_src, h2c_plane1_dst,
    output reg  [63:0] h2c_plane2_src, h2c_plane2_dst,
    output reg  [15:0] h2c_line_width, h2c_line_count,
    output reg  [15:0] h2c_src_stride, h2c_dst_stride,
    output reg  [15:0] h2c_plane12_width, h2c_plane12_count,
    output reg  [3:0]  h2c_format, h2c_plane_count,
    output reg  [15:0] h2c_desc_ctrl,
    input  wire        h2c_desc_ready,

    // Dispatched Extended 2D Descriptor Output to C2H DMA Engine
    output reg         c2h_desc_valid,
    output reg  [63:0] c2h_plane0_src, c2h_plane0_dst,
    output reg  [63:0] c2h_plane1_src, c2h_plane1_dst,
    output reg  [63:0] c2h_plane2_src, c2h_plane2_dst,
    output reg  [15:0] c2h_line_width, c2h_line_count,
    output reg  [15:0] c2h_src_stride, c2h_dst_stride,
    output reg  [15:0] c2h_plane12_width, c2h_plane12_count,
    output reg  [3:0]  c2h_format, c2h_plane_count,
    output reg  [15:0] c2h_desc_ctrl,
    input  wire        c2h_desc_ready,

    // SG Fetch Engine Status (To synchronize multi-channel descriptor SGL prefetching)
    input  wire        sg_fetch_busy
);

    localparam IDLE           = 3'b000;
    localparam REQ_FETCH      = 3'b001;
    localparam WAIT_CPLD      = 3'b010;
    localparam DISPATCH       = 3'b011;
    localparam WAIT_SGL_FETCH = 3'b100;
    localparam INC_HEAD       = 3'b101;

    reg [2:0] state;
    assign idle = (state == IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= IDLE;
            head_ptr            <= 16'd0;
            desc_req_valid      <= 1'b0;
            desc_req_addr       <= 64'd0;
            desc_req_dw_len     <= 11'd16; // 64 Bytes (16 DWs)
            desc_req_tag        <= 8'h00;  // Tag 0 reserved for Descriptor Fetch
            h2c_desc_valid      <= 1'b0;
            h2c_plane0_src      <= 64'd0; h2c_plane0_dst <= 64'd0;
            h2c_plane1_src      <= 64'd0; h2c_plane1_dst <= 64'd0;
            h2c_plane2_src      <= 64'd0; h2c_plane2_dst <= 64'd0;
            h2c_line_width      <= 16'd0; h2c_line_count <= 16'd0;
            h2c_src_stride      <= 16'd0; h2c_dst_stride <= 16'd0;
            h2c_plane12_width   <= 16'd0; h2c_plane12_count <= 16'd0;
            h2c_format          <= 4'd0;  h2c_plane_count <= 4'd1;
            h2c_desc_ctrl       <= 16'd0;
            c2h_desc_valid      <= 1'b0;
            c2h_plane0_src      <= 64'd0; c2h_plane0_dst <= 64'd0;
            c2h_plane1_src      <= 64'd0; c2h_plane1_dst <= 64'd0;
            c2h_plane2_src      <= 64'd0; c2h_plane2_dst <= 64'd0;
            c2h_line_width      <= 16'd0; c2h_line_count <= 16'd0;
            c2h_src_stride      <= 16'd0; c2h_dst_stride <= 16'd0;
            c2h_plane12_width   <= 16'd0; c2h_plane12_count <= 16'd0;
            c2h_format          <= 4'd0;  c2h_plane_count <= 4'd1;
            c2h_desc_ctrl       <= 16'd0;
        end else begin
            case (state)
                IDLE: begin
                    desc_req_valid <= 1'b0;
                    h2c_desc_valid <= 1'b0;
                    c2h_desc_valid <= 1'b0;

                    if (dma_run && (head_ptr != tail_ptr)) begin
                        desc_req_addr  <= ring_base_addr + (head_ptr * 64);
                        desc_req_valid <= 1'b1;
                        desc_req_dw_len<= 11'd16; // 64 Bytes
                        state          <= REQ_FETCH;
                    end
                end

                REQ_FETCH: begin
                    if (desc_req_ack) begin
                        desc_req_valid <= 1'b0;
                        state          <= WAIT_CPLD;
                    end
                end

                WAIT_CPLD: begin
                    if (desc_cpl_valid) begin
                        // Check Direction bit (Bit 1 of Control Byte in DW15: desc_cpl_data[489])
                        if (desc_cpl_data[489] == 1'b0) begin // H2C DMA Descriptor
                            h2c_desc_valid      <= 1'b1;
                            h2c_plane0_src      <= desc_cpl_data[63:0];
                            h2c_plane0_dst      <= desc_cpl_data[127:64];
                            h2c_plane1_src      <= desc_cpl_data[191:128];
                            h2c_plane1_dst      <= desc_cpl_data[255:192];
                            h2c_plane2_src      <= desc_cpl_data[319:256];
                            h2c_plane2_dst      <= desc_cpl_data[383:320];
                            h2c_line_width      <= (desc_cpl_data[399:384] > 0) ? desc_cpl_data[399:384] : 16'd4096;
                            h2c_line_count      <= (desc_cpl_data[415:400] > 0) ? desc_cpl_data[415:400] : 16'd1;
                            h2c_src_stride      <= (desc_cpl_data[431:416] > 0) ? desc_cpl_data[431:416] : 16'd4096;
                            h2c_dst_stride      <= (desc_cpl_data[447:432] > 0) ? desc_cpl_data[447:432] : 16'd4096;
                            h2c_plane12_width   <= desc_cpl_data[463:448];
                            h2c_plane12_count   <= desc_cpl_data[479:464];
                            h2c_format          <= desc_cpl_data[483:480];
                            h2c_plane_count     <= (desc_cpl_data[487:484] > 0) ? desc_cpl_data[487:484] : 4'd1;
                            h2c_desc_ctrl       <= desc_cpl_data[503:488];
                        end else begin // C2H DMA Descriptor
                            c2h_desc_valid      <= 1'b1;
                            c2h_plane0_src      <= desc_cpl_data[63:0];
                            c2h_plane0_dst      <= desc_cpl_data[127:64];
                            c2h_plane1_src      <= desc_cpl_data[191:128];
                            c2h_plane1_dst      <= desc_cpl_data[255:192];
                            c2h_plane2_src      <= desc_cpl_data[319:256];
                            c2h_plane2_dst      <= desc_cpl_data[383:320];
                            c2h_line_width      <= (desc_cpl_data[399:384] > 0) ? desc_cpl_data[399:384] : 16'd4096;
                            c2h_line_count      <= (desc_cpl_data[415:400] > 0) ? desc_cpl_data[415:400] : 16'd1;
                            c2h_src_stride      <= (desc_cpl_data[431:416] > 0) ? desc_cpl_data[431:416] : 16'd4096;
                            c2h_dst_stride      <= (desc_cpl_data[447:432] > 0) ? desc_cpl_data[447:432] : 16'd4096;
                            c2h_plane12_width   <= desc_cpl_data[463:448];
                            c2h_plane12_count   <= desc_cpl_data[479:464];
                            c2h_format          <= desc_cpl_data[483:480];
                            c2h_plane_count     <= (desc_cpl_data[487:484] > 0) ? desc_cpl_data[487:484] : 4'd1;
                            c2h_desc_ctrl       <= desc_cpl_data[503:488];
                        end
                        state <= DISPATCH;
                    end
                end

                DISPATCH: begin
                    if (h2c_desc_valid && h2c_desc_ready) begin
                        h2c_desc_valid <= 1'b0;
                        if (h2c_desc_ctrl[5] || h2c_desc_ctrl[4])
                            state <= WAIT_SGL_FETCH;
                        else
                            state <= INC_HEAD;
                    end else if (c2h_desc_valid && c2h_desc_ready) begin
                        c2h_desc_valid <= 1'b0;
                        if (c2h_desc_ctrl[5] || c2h_desc_ctrl[4])
                            state <= WAIT_SGL_FETCH;
                        else
                            state <= INC_HEAD;
                    end
                end

                WAIT_SGL_FETCH: begin
                    if (!sg_fetch_busy) begin
                        state <= INC_HEAD;
                    end
                end

                INC_HEAD: begin
                    if (ring_size > 16'd0 && ((head_ptr + 1'b1) >= ring_size)) begin
                        head_ptr <= 16'd0;
                    end else begin
                        head_ptr <= head_ptr + 1'b1;
                    end
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
