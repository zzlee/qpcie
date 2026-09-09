// Inserts fixed RGB24 marker blocks after the TPG for end-to-end DMA checks.
module tpg_marker_overlay #(
    parameter integer FRAME_WIDTH  = 4096,
    parameter integer FRAME_HEIGHT = 2160
)(
    input  wire         clk,
    input  wire         rst_n,
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
    reg [12:0] x_pos;
    reg [11:0] y_pos;
    wire [12:0] pixel_x = s_axis_tuser ? 13'd0 : x_pos;
    wire [11:0] pixel_y = s_axis_tuser ? 12'd0 : y_pos;
    wire         transfer = s_axis_tvalid && m_axis_tready;

    function [23:0] marker_pixel;
        input [12:0] x;
        input [11:0] y;
        input [23:0] pixel;
        begin
            if (x < 13'd4 && y < 12'd4)
                marker_pixel = 24'h0000FF; // Top-left: red in host RGB24
            else if (x >= FRAME_WIDTH - 4 && y < 12'd4)
                marker_pixel = 24'h00FF00; // Top-right: green
            else if (x < 13'd4 && y >= FRAME_HEIGHT - 4)
                marker_pixel = 24'hFF0000; // Bottom-left: blue in host RGB24
            else if (x >= FRAME_WIDTH - 4 && y >= FRAME_HEIGHT - 4)
                marker_pixel = 24'h00FFFF; // Bottom-right: yellow in host RGB24
            else if (x >= (FRAME_WIDTH / 2) - 2 && x < (FRAME_WIDTH / 2) + 2 &&
                     y >= (FRAME_HEIGHT / 2) - 2 && y < (FRAME_HEIGHT / 2) + 2)
                marker_pixel = 24'hFF00FF; // Center: magenta
            else
                marker_pixel = pixel;
        end
    endfunction

    wire [23:0] marker_pix0 = marker_pixel(pixel_x, pixel_y, s_axis_tdata[23:0]);
    wire [23:0] marker_pix1 = marker_pixel(pixel_x + 13'd1, pixel_y, s_axis_tdata[55:32]);
    wire [23:0] marker_pix2 = marker_pixel(pixel_x + 13'd2, pixel_y, s_axis_tdata[87:64]);
    wire [23:0] marker_pix3 = marker_pixel(pixel_x + 13'd3, pixel_y, s_axis_tdata[119:96]);

    assign s_axis_tready = m_axis_tready;
    assign m_axis_tvalid = s_axis_tvalid;
    assign m_axis_tlast  = s_axis_tlast;
    assign m_axis_tuser  = s_axis_tuser;
    assign m_axis_tdata  = {s_axis_tdata[127:120], marker_pix3,
                            s_axis_tdata[95:88],   marker_pix2,
                            s_axis_tdata[63:56],   marker_pix1,
                            s_axis_tdata[31:24],   marker_pix0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pos <= 13'd0;
            y_pos <= 12'd0;
        end else if (transfer) begin
            if (s_axis_tlast) begin
                x_pos <= 13'd0;
                if (y_pos >= FRAME_HEIGHT - 1)
                    y_pos <= 12'd0;
                else
                    y_pos <= y_pos + 1'b1;
            end else if (s_axis_tuser) begin
                x_pos <= 13'd4;
                y_pos <= 12'd0;
            end else begin
                x_pos <= x_pos + 13'd4;
            end
        end
    end
endmodule
