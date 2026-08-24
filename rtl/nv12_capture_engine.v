// ============================================================================
// Module: nv12_capture_engine
// Description: Single-channel YUV444 4-PPC to NV12M PCIe capture engine.
//              - Input byte order per 32-bit pixel: Y, Cb, Cr, X
//              - Y is copied without a color-space matrix
//              - Cb/Cr use a rounded 2x2 box filter for 4:2:0 subsampling
//              - Every PCIe MWr contains one aligned 16-byte payload
// ============================================================================
`timescale 1ns / 1ps

module nv12_capture_engine #(
    parameter integer MAX_WIDTH = 1920,
    parameter integer PCIE_DATA_WIDTH = 128
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         desc_valid,
    output reg                          desc_ready,
    input  wire [63:0]                  plane_y_addr,
    input  wire [63:0]                  plane_uv_addr,
    input  wire [15:0]                  frame_width,
    input  wire [15:0]                  frame_height,
    input  wire [15:0]                  frame_stride,

    input  wire                         pacer_enable,
    input  wire [31:0]                  frame_interval_clks,
    input  wire [63:0]                  global_timestamp,

    input  wire [127:0]                 s_axis_tdata,
    input  wire                         s_axis_tvalid,
    input  wire                         s_axis_tlast,
    input  wire                         s_axis_tuser,
    output reg                          s_axis_tready,

    output reg                          c2h_req_valid,
    output reg  [63:0]                  c2h_req_addr,
    output reg  [10:0]                  c2h_req_dw_len,
    output reg  [PCIE_DATA_WIDTH-1:0]   c2h_req_data,
    output reg                          c2h_req_last,
    input  wire                         c2h_req_ack,

    output reg                          video_busy,
    output reg                          video_frame_done,
    output reg  [63:0]                  frame_pts,
    output reg  [31:0]                  protocol_error_count
);

    localparam integer CHROMA_WORDS = MAX_WIDTH / 4;
    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_CAPTURE     = 3'd1;
    localparam [2:0] ST_ODD_PROCESS = 3'd2;
    localparam [2:0] ST_SEND_Y      = 3'd3;
    localparam [2:0] ST_SEND_UV     = 3'd4;
    localparam [2:0] ST_PACE        = 3'd5;

    reg [2:0] state;
    reg [15:0] width_q, height_q, stride_q;
    reg [15:0] line_idx;
    reg [15:0] beat_col;
    reg [63:0] y_line_addr, uv_line_addr;
    reg [127:0] y_pack, uv_pack;
    reg [127:0] pending_data;
    reg         pending_last;
    reg [35:0]  chroma_even_q;
    reg         chroma_we;
    reg [15:0]  chroma_wr_addr;
    reg [35:0]  chroma_wr_data;
    reg [127:0] uv_req_data_q;
    reg [63:0]  uv_req_addr_q;
    reg         uv_pending_q;
    reg         req_eol_q;
    reg         req_frame_end_q;
    reg         sof_seen;
    reg [31:0]  frame_clk_count;

    // One 480x36 memory stores horizontal Cb/Cr sums for the even row.
    // A synchronous read on odd rows permits inference into one RAMB18.
    (* ram_style = "block" *) reg [35:0] chroma_line [0:CHROMA_WORDS-1];

    // Keep RAM accesses out of the asynchronously-reset state process. This
    // is the canonical simple-dual-port template needed for RAMB18 inference.
    always @(posedge clk) begin
        if (chroma_we)
            chroma_line[chroma_wr_addr] <= chroma_wr_data;
        chroma_even_q <= chroma_line[beat_col];
    end

    function [31:0] pack_y4;
        input [127:0] d;
        begin
            // Numeric bits [7:0] become the first byte in host memory.
            pack_y4 = {d[103:96], d[71:64], d[39:32], d[7:0]};
        end
    endfunction

    function [35:0] horizontal_chroma_sums;
        input [127:0] d;
        reg [8:0] u01, v01, u23, v23;
        begin
            u01 = {1'b0, d[15:8]}   + {1'b0, d[47:40]};
            v01 = {1'b0, d[23:16]}  + {1'b0, d[55:48]};
            u23 = {1'b0, d[79:72]}  + {1'b0, d[111:104]};
            v23 = {1'b0, d[87:80]}  + {1'b0, d[119:112]};
            horizontal_chroma_sums = {v23, u23, v01, u01};
        end
    endfunction

    function [31:0] pack_nv12_uv4;
        input [127:0] odd_d;
        input [35:0] even_sums;
        reg [10:0] u01_total, v01_total, u23_total, v23_total;
        reg [7:0] u01, v01, u23, v23;
        begin
            u01_total = {2'b0, even_sums[8:0]} +
                        {3'b0, odd_d[15:8]} + {3'b0, odd_d[47:40]} + 11'd2;
            v01_total = {2'b0, even_sums[17:9]} +
                        {3'b0, odd_d[23:16]} + {3'b0, odd_d[55:48]} + 11'd2;
            u23_total = {2'b0, even_sums[26:18]} +
                        {3'b0, odd_d[79:72]} + {3'b0, odd_d[111:104]} + 11'd2;
            v23_total = {2'b0, even_sums[35:27]} +
                        {3'b0, odd_d[87:80]} + {3'b0, odd_d[119:112]} + 11'd2;
            u01 = u01_total[9:2];
            v01 = v01_total[9:2];
            u23 = u23_total[9:2];
            v23 = v23_total[9:2];
            // Host byte order: Cb0, Cr0, Cb1, Cr1.
            pack_nv12_uv4 = {v23, u23, v01, u01};
        end
    endfunction

    wire [63:0] group_byte_offset = {46'd0, beat_col[15:2], 4'b0000};
    wire [15:0] expected_last_beat = (width_q >> 2) - 1'b1;
    wire        group_complete = (beat_col[1:0] == 2'b11);

    // Synchronous reset keeps all BRAM address/enable drivers synchronous;
    // Artix-7 RAMB18 control paths must not be driven by async-reset flops.
    always @(posedge clk) begin
        if (!rst_n) begin
            state                <= ST_IDLE;
            desc_ready           <= 1'b0;
            s_axis_tready        <= 1'b0;
            c2h_req_valid        <= 1'b0;
            c2h_req_addr         <= 64'd0;
            c2h_req_dw_len       <= 11'd4;
            c2h_req_data         <= {PCIE_DATA_WIDTH{1'b0}};
            c2h_req_last         <= 1'b1;
            video_busy           <= 1'b0;
            video_frame_done     <= 1'b0;
            frame_pts            <= 64'd0;
            protocol_error_count <= 32'd0;
            width_q              <= 16'd0;
            height_q             <= 16'd0;
            stride_q             <= 16'd0;
            line_idx             <= 16'd0;
            beat_col             <= 16'd0;
            y_line_addr          <= 64'd0;
            uv_line_addr         <= 64'd0;
            y_pack               <= 128'd0;
            uv_pack              <= 128'd0;
            pending_data         <= 128'd0;
            pending_last         <= 1'b0;
            chroma_we            <= 1'b0;
            chroma_wr_addr       <= 16'd0;
            chroma_wr_data       <= 36'd0;
            uv_req_data_q        <= 128'd0;
            uv_req_addr_q        <= 64'd0;
            uv_pending_q         <= 1'b0;
            req_eol_q            <= 1'b0;
            req_frame_end_q      <= 1'b0;
            sof_seen             <= 1'b0;
            frame_clk_count      <= 32'd0;
        end else begin
            desc_ready       <= 1'b0;
            video_frame_done <= 1'b0;
            chroma_we        <= 1'b0;

            if (video_busy)
                frame_clk_count <= frame_clk_count + 1'b1;
            else
                frame_clk_count <= 32'd0;

            case (state)
                ST_IDLE: begin
                    s_axis_tready <= 1'b0;
                    c2h_req_valid <= 1'b0;
                    video_busy    <= 1'b0;
                    if (desc_valid) begin
                        desc_ready      <= 1'b1;
                        video_busy      <= 1'b1;
                        width_q         <= frame_width;
                        height_q        <= frame_height;
                        stride_q        <= frame_stride;
                        line_idx        <= 16'd0;
                        beat_col        <= 16'd0;
                        y_line_addr     <= plane_y_addr;
                        uv_line_addr    <= plane_uv_addr;
                        y_pack          <= 128'd0;
                        uv_pack         <= 128'd0;
                        sof_seen        <= 1'b0;
                        frame_clk_count <= 32'd0;
                        s_axis_tready   <= 1'b1;
                        state           <= ST_CAPTURE;
                        if ((frame_width[3:0] != 4'd0) || frame_height[0] ||
                            frame_stride < frame_width)
                            protocol_error_count <= protocol_error_count + 1'b1;
                    end
                end

                ST_CAPTURE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (!sof_seen && !s_axis_tuser) begin
                            // STREAMOFF/restart can leave TPG mid-frame. Drain
                            // until the next real start-of-frame marker.
                        end else begin
                            if (!sof_seen) begin
                                sof_seen <= 1'b1;
                                frame_pts <= global_timestamp;
                            end

                            if (line_idx[0]) begin
                                pending_data  <= s_axis_tdata;
                                pending_last  <= s_axis_tlast;
                                s_axis_tready <= 1'b0;
                                state         <= ST_ODD_PROCESS;
                            end else begin
                                chroma_we      <= 1'b1;
                                chroma_wr_addr <= beat_col;
                                chroma_wr_data <= horizontal_chroma_sums(s_axis_tdata);
                                if (group_complete) begin
                                    c2h_req_addr   <= y_line_addr + group_byte_offset;
                                    c2h_req_dw_len <= 11'd4;
                                    c2h_req_data   <= {pack_y4(s_axis_tdata), y_pack[95:0]};
                                    c2h_req_last   <= 1'b1;
                                    c2h_req_valid  <= 1'b1;
                                    uv_pending_q   <= 1'b0;
                                    req_eol_q      <= s_axis_tlast;
                                    req_frame_end_q<= s_axis_tlast &&
                                                       (line_idx + 1'b1 >= height_q);
                                    if (s_axis_tlast != (beat_col == expected_last_beat))
                                        protocol_error_count <= protocol_error_count + 1'b1;
                                    s_axis_tready <= 1'b0;
                                    state <= ST_SEND_Y;
                                end else begin
                                    y_pack[(beat_col[1:0]*32) +: 32] <= pack_y4(s_axis_tdata);
                                    beat_col <= beat_col + 1'b1;
                                end
                            end
                        end
                    end
                end

                ST_ODD_PROCESS: begin
                    if (group_complete) begin
                        c2h_req_addr   <= y_line_addr + group_byte_offset;
                        c2h_req_dw_len <= 11'd4;
                        c2h_req_data   <= {pack_y4(pending_data), y_pack[95:0]};
                        c2h_req_last   <= 1'b1;
                        c2h_req_valid  <= 1'b1;
                        uv_req_addr_q  <= uv_line_addr + group_byte_offset;
                        uv_req_data_q  <= {pack_nv12_uv4(pending_data, chroma_even_q),
                                           uv_pack[95:0]};
                        uv_pending_q   <= 1'b1;
                        req_eol_q      <= pending_last;
                        req_frame_end_q<= pending_last &&
                                           (line_idx + 1'b1 >= height_q);
                        if (pending_last != (beat_col == expected_last_beat))
                            protocol_error_count <= protocol_error_count + 1'b1;
                        state <= ST_SEND_Y;
                    end else begin
                        y_pack[(beat_col[1:0]*32) +: 32] <= pack_y4(pending_data);
                        uv_pack[(beat_col[1:0]*32) +: 32] <=
                            pack_nv12_uv4(pending_data, chroma_even_q);
                        beat_col <= beat_col + 1'b1;
                        s_axis_tready <= 1'b1;
                        state <= ST_CAPTURE;
                    end
                end

                ST_SEND_Y: begin
                    if (c2h_req_ack) begin
                        c2h_req_valid <= 1'b0;
                        if (uv_pending_q) begin
                            c2h_req_addr   <= uv_req_addr_q;
                            c2h_req_dw_len <= 11'd4;
                            c2h_req_data   <= uv_req_data_q;
                            c2h_req_last   <= 1'b1;
                            c2h_req_valid  <= 1'b1;
                            state          <= ST_SEND_UV;
                        end else if (req_eol_q) begin
                            if (req_frame_end_q) begin
                                video_frame_done <= 1'b1;
                                if (pacer_enable && frame_interval_clks != 0 &&
                                    frame_clk_count < frame_interval_clks)
                                    state <= ST_PACE;
                                else begin
                                    video_busy <= 1'b0;
                                    state <= ST_IDLE;
                                end
                            end else begin
                                line_idx     <= line_idx + 1'b1;
                                beat_col     <= 16'd0;
                                y_line_addr  <= y_line_addr + stride_q;
                                y_pack       <= 128'd0;
                                uv_pack      <= 128'd0;
                                s_axis_tready<= 1'b1;
                                state        <= ST_CAPTURE;
                            end
                        end else begin
                            beat_col      <= beat_col + 1'b1;
                            s_axis_tready <= 1'b1;
                            state         <= ST_CAPTURE;
                        end
                    end
                end

                ST_SEND_UV: begin
                    if (c2h_req_ack) begin
                        c2h_req_valid <= 1'b0;
                        uv_pending_q  <= 1'b0;
                        if (req_eol_q) begin
                            if (req_frame_end_q) begin
                                video_frame_done <= 1'b1;
                                if (pacer_enable && frame_interval_clks != 0 &&
                                    frame_clk_count < frame_interval_clks)
                                    state <= ST_PACE;
                                else begin
                                    video_busy <= 1'b0;
                                    state <= ST_IDLE;
                                end
                            end else begin
                                line_idx      <= line_idx + 1'b1;
                                beat_col      <= 16'd0;
                                y_line_addr   <= y_line_addr + stride_q;
                                uv_line_addr  <= uv_line_addr + stride_q;
                                y_pack        <= 128'd0;
                                uv_pack       <= 128'd0;
                                s_axis_tready <= 1'b1;
                                state         <= ST_CAPTURE;
                            end
                        end else begin
                            beat_col      <= beat_col + 1'b1;
                            s_axis_tready <= 1'b1;
                            state         <= ST_CAPTURE;
                        end
                    end
                end

                ST_PACE: begin
                    s_axis_tready <= 1'b0;
                    if (!pacer_enable || frame_clk_count >= frame_interval_clks) begin
                        video_busy <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
