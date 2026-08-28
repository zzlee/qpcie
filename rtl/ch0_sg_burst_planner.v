// ============================================================================
// Module: ch0_sg_burst_planner
// Selects the largest supported C2H payload that fits all active boundaries.
// Payload sizes are multiples of 4 bytes because rq_tx_encoder advertises
// payload length in DWORDs and derives byte-validity from m_axis_rq_tkeep.
// ============================================================================
`timescale 1ns / 1ps

module ch0_sg_burst_planner #(
    parameter integer DATA_WIDTH = 128,
    parameter integer MAX_BURST_BYTES = 256,
    parameter integer MIN_BURST_BYTES = 4
)(
    input  wire [31:0] segment_bytes_left,
    input  wire [31:0] frame_bytes_left,
    input  wire [11:0] page_offset,
    output reg  [15:0] burst_bytes,
    output wire [10:0] burst_dw_len,
    output wire [4:0]  burst_beats,
    output wire        valid
);
    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    wire [31:0] page_bytes_left = 32'd4096 - {20'd0, page_offset};
    wire [31:0] limit =
        (segment_bytes_left < frame_bytes_left) ?
        ((segment_bytes_left < page_bytes_left) ? segment_bytes_left : page_bytes_left) :
        ((frame_bytes_left < page_bytes_left) ? frame_bytes_left : page_bytes_left);

    always @* begin
        burst_bytes = 16'd0;
        if (limit >= 32'd256 && MAX_BURST_BYTES >= 256)
            burst_bytes = 16'd256;
        else if (limit >= 32'd128 && MAX_BURST_BYTES >= 128)
            burst_bytes = 16'd128;
        else if (limit >= 32'd64 && MAX_BURST_BYTES >= 64)
            burst_bytes = 16'd64;
        else if (limit >= 32'd32 && MAX_BURST_BYTES >= 32)
            burst_bytes = 16'd32;
        else if (limit >= 32'd16 && MAX_BURST_BYTES >= 16)
            burst_bytes = 16'd16;
        else if (limit >= MIN_BURST_BYTES)
            burst_bytes = limit[15:0] & 16'hFFFC;
    end

    assign burst_dw_len = burst_bytes[15:2];
    assign burst_beats = (burst_bytes + DATA_BYTES - 1) / DATA_BYTES;
    assign valid = (burst_bytes >= MIN_BURST_BYTES) &&
                   ((burst_bytes & 16'h0003) == 0);
endmodule
