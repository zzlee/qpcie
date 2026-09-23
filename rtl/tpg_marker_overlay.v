// ============================================================================
// Module: tpg_marker_overlay
// Description: Dynamic diagnostic marker and watermark overlay engine for
//              real-time end-to-end PCIe DMA data integrity verification.
//              - Dynamically enabled/disabled via overlay_en (0 = bit-exact bypass).
//              - Full AXI4-Stream Registered Skid Buffer: 0 combinational output delay.
//              - Pre-registered resolution thresholds: 0 subtraction delay in pixel path.
//              - Markers:
//                  * Top-Left:     Red     (0xFF, 0x00, 0x00)
//                  * Top-Right:    Green   (0x00, 0xFF, 0x00)
//                  * Bottom-Left:  Blue    (0x00, 0x00, 0xFF)
//                  * Bottom-Right: Yellow  (0xFF, 0xFF, 0x00)
//                  * Center:       Magenta (0xFF, 0x00, 0xFF)
//                  * Watermark (8, 0): Magic byte 0xA5 + 16-bit frame counter.
// ============================================================================

`timescale 1ns / 1ps

module tpg_marker_overlay #(
    parameter integer FRAME_WIDTH  = 4096,
    parameter integer FRAME_HEIGHT = 2160
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         overlay_en,
    input  wire [15:0]  frame_width,
    input  wire [15:0]  frame_height,
    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,
    output wire         s_axis_tready,
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    output wire         m_axis_tlast,
    output wire         m_axis_tuser,
    input  wire         m_axis_tready
);
    wire [12:0] act_w = (frame_width > 16'd4) ? frame_width[12:0] : FRAME_WIDTH[12:0];
    wire [11:0] act_h = (frame_height > 16'd4) ? frame_height[11:0] : FRAME_HEIGHT[11:0];

    // Pre-registered coordinate thresholds to eliminate arithmetic levels in pixel path
    reg [12:0] act_w_minus_4;
    reg [11:0] act_h_minus_4;
    reg [12:0] center_x_lo, center_x_hi;
    reg [11:0] center_y_lo, center_y_hi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_w_minus_4 <= 13'd1916;
            act_h_minus_4 <= 12'd1076;
            center_x_lo   <= 13'd958;
            center_x_hi   <= 13'd962;
            center_y_lo   <= 12'd538;
            center_y_hi   <= 12'd542;
        end else begin
            act_w_minus_4 <= act_w - 13'd4;
            act_h_minus_4 <= act_h - 12'd4;
            center_x_lo   <= (act_w >> 1) - 13'd2;
            center_x_hi   <= (act_w >> 1) + 13'd2;
            center_y_lo   <= (act_h >> 1) - 12'd2;
            center_y_hi   <= (act_h >> 1) + 12'd2;
        end
    end

    reg [12:0] x_pos;
    reg [11:0] y_pos;
    reg [15:0] frame_number;
    wire [12:0] pixel_x = s_axis_tuser ? 13'd0 : x_pos;
    wire [11:0] pixel_y = s_axis_tuser ? 12'd0 : y_pos;
    wire        in_transfer = s_axis_tvalid && s_axis_tready;

    function [23:0] marker_pixel;
        input [12:0] x;
        input [11:0] y;
        input [23:0] pixel;
        begin
            if (!overlay_en)
                marker_pixel = pixel;
            else if (x < 13'd4 && y < 12'd4)
                marker_pixel = 24'h0000FF; // Top-left: red in host RGB24
            else if (x >= 13'd8 && x < 13'd9 && y == 12'd0)
                // Host RGB24 reads this stream-endian value as A5, low, high.
                marker_pixel = {frame_number[15:8], frame_number[7:0], 8'hA5};
            else if (x >= act_w_minus_4 && y < 12'd4)
                marker_pixel = 24'h00FF00; // Top-right: green
            else if (x < 13'd4 && y >= act_h_minus_4)
                marker_pixel = 24'hFF0000; // Bottom-left: blue in host RGB24
            else if (x >= act_w_minus_4 && y >= act_h_minus_4)
                marker_pixel = 24'h00FFFF; // Bottom-right: yellow in host RGB24
            else if (x >= center_x_lo && x < center_x_hi &&
                     y >= center_y_lo && y < center_y_hi)
                marker_pixel = 24'hFF00FF; // Center: magenta
            else
                marker_pixel = pixel;
        end
    endfunction

    wire [23:0] marker_pix0 = marker_pixel(pixel_x, pixel_y, s_axis_tdata[23:0]);
    wire [23:0] marker_pix1 = marker_pixel(pixel_x + 13'd1, pixel_y, s_axis_tdata[55:32]);
    wire [23:0] marker_pix2 = marker_pixel(pixel_x + 13'd2, pixel_y, s_axis_tdata[87:64]);
    wire [23:0] marker_pix3 = marker_pixel(pixel_x + 13'd3, pixel_y, s_axis_tdata[119:96]);

    wire [127:0] marked_payload = overlay_en ?
                                  {s_axis_tdata[127:120], marker_pix3,
                                   s_axis_tdata[95:88],   marker_pix2,
                                   s_axis_tdata[63:56],   marker_pix1,
                                   s_axis_tdata[31:24],   marker_pix0} :
                                  s_axis_tdata;

    // Track stream coordinates based on accepted input beats
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pos        <= 13'd0;
            y_pos        <= 12'd0;
            frame_number <= 16'd0;
        end else if (in_transfer) begin
            if (s_axis_tlast) begin
                x_pos <= 13'd0;
                if (s_axis_tuser || y_pos >= act_h - 1'b1)
                    y_pos <= 12'd0;
                else
                    y_pos <= y_pos + 1'b1;
            end else if (s_axis_tuser) begin
                x_pos <= 13'd4;
                y_pos <= 12'd0;
                frame_number <= frame_number + 1'b1;
            end else begin
                x_pos <= x_pos + 13'd4;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Stream Registered Skid Buffer Output Stage
    // Guarantees that m_axis_* signals are driven directly from flip-flops,
    // providing a clean clock-boundary register slice that cuts all combinational
    // paths into downstream capture logic while preserving full line-rate throughput.
    // -------------------------------------------------------------------------
    reg [129:0] reg_data; // {tuser, tlast, tdata[127:0]}
    reg         reg_valid;
    reg [129:0] skid_data;
    reg         skid_valid;

    assign s_axis_tready = !skid_valid;

    wire [129:0] in_packet = {s_axis_tuser, s_axis_tlast, marked_payload};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_valid  <= 1'b0;
            reg_data   <= 130'd0;
            skid_valid <= 1'b0;
            skid_data  <= 130'd0;
        end else begin
            if (m_axis_tready) begin
                if (skid_valid) begin
                    reg_valid  <= 1'b1;
                    reg_data   <= skid_data;
                    skid_valid <= 1'b0;
                end else if (s_axis_tvalid) begin
                    reg_valid  <= 1'b1;
                    reg_data   <= in_packet;
                end else begin
                    reg_valid  <= 1'b0;
                end
            end else begin
                if (s_axis_tvalid && s_axis_tready) begin
                    if (reg_valid) begin
                        skid_valid <= 1'b1;
                        skid_data  <= in_packet;
                    end else begin
                        reg_valid  <= 1'b1;
                        reg_data   <= in_packet;
                    end
                end
            end
        end
    end

    assign m_axis_tvalid = reg_valid;
    assign m_axis_tuser  = reg_data[129];
    assign m_axis_tlast  = reg_data[128];
    assign m_axis_tdata  = reg_data[127:0];

endmodule
