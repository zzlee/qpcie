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
    input  wire [15:0]                   h2c_line_width,
    output reg                           h2c_desc_ready,

    // Interface from Descriptor Fetch Engine (C2H Descriptor Channel)
    input  wire                          c2h_desc_valid,
    input  wire [63:0]                   c2h_plane0_dst,
    input  wire [15:0]                   c2h_line_width,
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
    input  wire                          c2h_req_ack,

    // Interface from RC RX Decoder (H2C CplD Stream Consumer)
    input  wire                          h2c_cpl_valid,
    input  wire [PCIE_DATA_WIDTH-1:0]    h2c_cpl_data,
    input  wire                          h2c_cpl_last,

    // Real-time DMA Status & Counters
    output reg  [31:0]                   completed_h2c_count,
    output reg  [31:0]                   completed_c2h_count,
    output reg  [31:0]                   h2c_bytes_transferred,
    output reg  [31:0]                   c2h_bytes_transferred,
    output wire                          h2c_busy,
    output wire                          c2h_busy
);

    // =========================================================================
    // H2C (Host -> FPGA) DMA Execution State Machine
    // =========================================================================
    localparam H2C_IDLE       = 2'd0;
    localparam H2C_ISSUE_MRD  = 2'd1;
    localparam H2C_WAIT_ACK   = 2'd2;
    localparam H2C_WAIT_CPLD  = 2'd3;

    reg [1:0]  h2c_state;
    reg [63:0] h2c_cur_addr;
    reg [15:0] h2c_rem_bytes;
    reg [10:0] h2c_burst_dw;
    reg [10:0] h2c_burst_recv_dw;
    reg        h2c_cpl_in_packet;
    wire [10:0] h2c_cpl_step_dw = !h2c_cpl_in_packet ? 11'd1 :
        ((h2c_burst_dw - h2c_burst_recv_dw) < (PCIE_DATA_WIDTH/32)) ?
        (h2c_burst_dw - h2c_burst_recv_dw) : (PCIE_DATA_WIDTH/32);

    assign h2c_busy = (h2c_state != H2C_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h2c_state             <= H2C_IDLE;
            h2c_desc_ready        <= 1'b0;
            h2c_req_valid         <= 1'b0;
            h2c_req_addr          <= 64'd0;
            h2c_req_dw_len        <= 11'd0;
            h2c_req_tag           <= 8'h01;
            completed_h2c_count   <= 32'd0;
            h2c_bytes_transferred <= 32'd0;
            h2c_cur_addr          <= 64'd0;
            h2c_rem_bytes         <= 16'd0;
            h2c_burst_dw          <= 11'd0;
            h2c_burst_recv_dw     <= 11'd0;
            h2c_cpl_in_packet     <= 1'b0;
        end else begin
            case (h2c_state)
                H2C_IDLE: begin
                    h2c_desc_ready <= 1'b0;
                    h2c_req_valid  <= 1'b0;
                    if (h2c_desc_valid) begin
                        h2c_desc_ready   <= 1'b1;
                        h2c_cur_addr     <= h2c_plane0_src;
                        h2c_rem_bytes    <= (h2c_line_width > 16'd0) ? h2c_line_width : 16'd4096;
                        h2c_burst_recv_dw <= 11'd0;
                        h2c_cpl_in_packet <= 1'b0;
                        h2c_state        <= H2C_ISSUE_MRD;
                    end
                end

                H2C_ISSUE_MRD: begin
                    h2c_desc_ready <= 1'b0;
                    if (h2c_rem_bytes > 16'd0) begin
                        if (h2c_rem_bytes >= 16'd128) begin
                            h2c_burst_dw   <= 11'd32;
                            h2c_req_dw_len <= 11'd32;
                        end else begin
                            h2c_burst_dw   <= h2c_rem_bytes[12:2];
                            h2c_req_dw_len <= h2c_rem_bytes[12:2];
                        end
                        h2c_req_addr  <= h2c_cur_addr;
                        h2c_req_tag   <= 8'h01;
                        h2c_req_valid <= 1'b1;
                        h2c_state     <= H2C_WAIT_ACK;
                    end else begin
                        completed_h2c_count <= completed_h2c_count + 1'b1;
                        h2c_desc_ready <= 1'b1;
                        h2c_state <= H2C_IDLE;
                    end
                end

                H2C_WAIT_ACK: begin
                    if (h2c_req_ack) begin
                        h2c_req_valid   <= 1'b0;
                        h2c_cur_addr        <= h2c_cur_addr + (h2c_burst_dw << 2);
                        h2c_rem_bytes       <= h2c_rem_bytes - (h2c_burst_dw << 2);
                        h2c_burst_recv_dw   <= 11'd0;
                        h2c_cpl_in_packet   <= 1'b0;
                        // Serialize tag 1: issue the next MRd only after every
                        // payload DWORD for this request has arrived.
                        h2c_state           <= H2C_WAIT_CPLD;
                    end
                end

                H2C_WAIT_CPLD: begin
                    if (h2c_cpl_valid) begin
                        h2c_cpl_in_packet <= !h2c_cpl_last;
                        if ((h2c_burst_recv_dw + h2c_cpl_step_dw) >= h2c_burst_dw) begin
                            h2c_burst_recv_dw <= 11'd0;
                            h2c_cpl_in_packet <= 1'b0;
                            h2c_bytes_transferred <= h2c_bytes_transferred + (h2c_burst_dw << 2);
                            if (h2c_rem_bytes == 16'd0) begin
                                completed_h2c_count <= completed_h2c_count + 1'b1;
                                h2c_desc_ready <= 1'b1;
                                h2c_state <= H2C_IDLE;
                            end else begin
                                h2c_state <= H2C_ISSUE_MRD;
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
    localparam C2H_IDLE     = 2'd0;
    localparam C2H_SEND_BEAT= 2'd1;
    localparam C2H_WAIT_ACK = 2'd2;
    localparam C2H_COMPLETE = 2'd3;

    reg [1:0]  c2h_state;
    reg [63:0] c2h_cur_addr;
    reg [15:0] c2h_rem_bytes;
    reg [15:0] c2h_word_idx;

    assign c2h_busy = (c2h_state != C2H_IDLE);

    // Identifiable Test Pattern Generator for 128-bit Beats (4 DWs per beat)
    wire [31:0] p_dw0 = 32'hC200_0000 | (completed_c2h_count[7:0] << 16) | c2h_word_idx;
    wire [31:0] p_dw1 = 32'hC200_0000 | (completed_c2h_count[7:0] << 16) | (c2h_word_idx + 16'd1);
    wire [31:0] p_dw2 = 32'hC200_0000 | (completed_c2h_count[7:0] << 16) | (c2h_word_idx + 16'd2);
    wire [31:0] p_dw3 = 32'hC200_0000 | (completed_c2h_count[7:0] << 16) | (c2h_word_idx + 16'd3);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c2h_state             <= C2H_IDLE;
            c2h_desc_ready        <= 1'b0;
            c2h_req_valid         <= 1'b0;
            c2h_req_addr          <= 64'd0;
            c2h_req_dw_len        <= 11'd0;
            c2h_req_data          <= {PCIE_DATA_WIDTH{1'b0}};
            c2h_req_last          <= 1'b0;
            completed_c2h_count   <= 32'd0;
            c2h_bytes_transferred <= 32'd0;
            c2h_cur_addr          <= 64'd0;
            c2h_rem_bytes         <= 16'd0;
            c2h_word_idx          <= 16'd0;
        end else begin
            case (c2h_state)
                C2H_IDLE: begin
                    c2h_desc_ready <= 1'b0;
                    c2h_req_valid  <= 1'b0;
                    if (c2h_desc_valid) begin
                        c2h_desc_ready <= 1'b1;
                        c2h_cur_addr   <= c2h_plane0_dst;
                        c2h_rem_bytes  <= (c2h_line_width > 16'd0) ? c2h_line_width : 16'd4096;
                        c2h_word_idx   <= 16'd0;
                        c2h_state      <= C2H_SEND_BEAT;
                    end
                end

                C2H_SEND_BEAT: begin
                    c2h_desc_ready <= 1'b0;
                    if (c2h_rem_bytes > 16'd0) begin
                        c2h_req_addr   <= c2h_cur_addr;
                        c2h_req_dw_len <= 11'd4; // 4 DWs = 16 Bytes (1 128-bit beat)
                        c2h_req_data   <= {p_dw3, p_dw2, p_dw1, p_dw0};
                        c2h_req_last   <= (c2h_rem_bytes <= 16'd16);
                        c2h_req_valid  <= 1'b1;
                        c2h_state      <= C2H_WAIT_ACK;
                    end else begin
                        c2h_state <= C2H_COMPLETE;
                    end
                end

                C2H_WAIT_ACK: begin
                    if (c2h_req_ack) begin
                        c2h_req_valid         <= 1'b0;
                        c2h_cur_addr          <= c2h_cur_addr + 64'd16;
                        c2h_rem_bytes         <= c2h_rem_bytes - 16'd16;
                        c2h_word_idx          <= c2h_word_idx + 16'd4;
                        c2h_bytes_transferred <= c2h_bytes_transferred + 32'd16;
                        c2h_state             <= C2H_SEND_BEAT;
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
