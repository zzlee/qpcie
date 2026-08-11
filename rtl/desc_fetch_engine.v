// ============================================================================
// Module: desc_fetch_engine
// Description: Scatter-Gather Descriptor Fetch Engine.
//              Fetches descriptors from Host memory via RQ MRd requests,
//              parses descriptor fields, and dispatches to H2C/C2H DMA engines.
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

    // Interface to RQ TX Encoder (MRd Request)
    output reg         desc_req_valid,
    output reg  [63:0] desc_req_addr,
    output reg  [10:0] desc_req_dw_len,
    output reg  [7:0]  desc_req_tag,
    input  wire        desc_req_ack,

    // Interface from RC RX Decoder (CplD Payload)
    input  wire        desc_cpl_valid,
    input  wire [159:0] desc_cpl_data,
    input  wire        desc_cpl_last,

    // Dispatched Descriptor Output to H2C DMA Engine
    output reg         h2c_desc_valid,
    output reg  [63:0] h2c_desc_src_addr,
    output reg  [63:0] h2c_desc_dst_addr,
    output reg  [31:0] h2c_desc_len,
    output reg  [31:0] h2c_desc_ctrl,
    input  wire        h2c_desc_ready,

    // Dispatched Descriptor Output to C2H DMA Engine
    output reg         c2h_desc_valid,
    output reg  [63:0] c2h_desc_src_addr,
    output reg  [63:0] c2h_desc_dst_addr,
    output reg  [31:0] c2h_desc_len,
    output reg  [31:0] c2h_desc_ctrl,
    input  wire        c2h_desc_ready
);

    localparam IDLE       = 3'b000;
    localparam REQ_FETCH  = 3'b001;
    localparam WAIT_CPLD   = 3'b010;
    localparam DISPATCH   = 3'b011;
    localparam INC_HEAD   = 3'b100;

    reg [2:0] state;

    // Parsed Descriptor fields
    reg [63:0] desc_src;
    reg [63:0] desc_dst;
    reg [31:0] desc_len;
    reg [31:0] desc_ctrl;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            head_ptr         <= 16'd0;
            desc_req_valid   <= 1'b0;
            desc_req_addr    <= 64'd0;
            desc_req_dw_len  <= 11'd8; // 32 Bytes
            desc_req_tag     <= 8'h00; // Tag 0 for Descriptor
            h2c_desc_valid   <= 1'b0;
            h2c_desc_src_addr<= 64'd0;
            h2c_desc_dst_addr<= 64'd0;
            h2c_desc_len     <= 32'd0;
            h2c_desc_ctrl    <= 32'd0;
            c2h_desc_valid   <= 1'b0;
            c2h_desc_src_addr<= 64'd0;
            c2h_desc_dst_addr<= 64'd0;
            c2h_desc_len     <= 32'd0;
            c2h_desc_ctrl    <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    desc_req_valid <= 1'b0;
                    h2c_desc_valid <= 1'b0;
                    c2h_desc_valid <= 1'b0;

                    if (dma_run && (head_ptr != tail_ptr)) begin
                        desc_req_addr  <= ring_base_addr + (head_ptr * 32);
                        desc_req_valid <= 1'b1;
                        desc_req_dw_len<= 11'd8;
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
                        desc_src  <= desc_cpl_data[63:0];
                        desc_dst  <= desc_cpl_data[127:64];
                        desc_len  <= desc_cpl_data[159:128];
                        desc_ctrl <= 32'h0000_0001; // default control bit 0 valid
                        if (desc_cpl_data[0] == 1'b0) begin // H2C DMA Descriptor
                            h2c_desc_valid    <= 1'b1;
                            h2c_desc_src_addr <= desc_cpl_data[63:0];
                            h2c_desc_dst_addr <= desc_cpl_data[127:64];
                            h2c_desc_len      <= desc_cpl_data[159:128];
                            h2c_desc_ctrl     <= 32'h0000_0001;
                        end else begin // C2H DMA Descriptor
                            c2h_desc_valid    <= 1'b1;
                            c2h_desc_src_addr <= desc_cpl_data[63:0];
                            c2h_desc_dst_addr <= desc_cpl_data[127:64];
                            c2h_desc_len      <= desc_cpl_data[159:128];
                            c2h_desc_ctrl     <= 32'h0000_0001;
                        end
                        state <= DISPATCH;
                    end
                end

                DISPATCH: begin
                    if (h2c_desc_valid && h2c_desc_ready) begin
                        h2c_desc_valid <= 1'b0;
                        state          <= INC_HEAD;
                    end else if (c2h_desc_valid && c2h_desc_ready) begin
                        c2h_desc_valid <= 1'b0;
                        state          <= INC_HEAD;
                    end
                end

                INC_HEAD: begin
                    if (ring_size > 0) begin
                        head_ptr <= (head_ptr + 1'b1) % ring_size;
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
