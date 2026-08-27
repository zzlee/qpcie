// ============================================================================
// Module: nv12_capture_engine
// Description: Pipelined single-channel YUV444 4-PPC to NV12M capture engine.
//              - Input byte order per 32-bit pixel: Y, Cb, Cr, X
//              - Rounded 2x2 Cb/Cr box filter, one input beat per clock
//              - Independent Y and UV burst FIFOs decouple video from PCIe
//              - Default PCIe MWr payload is 128 bytes (32 DW / 8 beats)
// ============================================================================
`timescale 1ns / 1ps

module nv12_capture_engine #(
    parameter integer MAX_WIDTH = 3840,
    parameter integer PCIE_DATA_WIDTH = 128,
    parameter integer FIFO_DEPTH = 128,
    parameter integer MWR_PAYLOAD_BYTES = 128
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
    output wire                         s_axis_tready,

    output reg                          c2h_req_valid,
    output reg  [63:0]                  c2h_req_addr,
    output reg  [10:0]                  c2h_req_dw_len,
    output reg  [PCIE_DATA_WIDTH-1:0]   c2h_req_data,
    output reg                          c2h_req_last,
    input  wire                         c2h_req_data_ready,
    input  wire                         c2h_req_ack,

    output reg                          video_busy,
    output reg                          video_frame_done,
    output reg  [63:0]                  frame_pts,
    output reg  [31:0]                  protocol_error_count
);
    localparam integer CHROMA_WORDS = MAX_WIDTH / 4;
    localparam integer CHROMA_ADDR_WIDTH = $clog2(CHROMA_WORDS);
    localparam integer FIFO_PTR_WIDTH = $clog2(FIFO_DEPTH);
    localparam integer FIFO_COUNT_WIDTH = FIFO_PTR_WIDTH + 1;
    localparam integer DATA_BYTES = PCIE_DATA_WIDTH / 8;
    localparam integer DATA_DWORDS = PCIE_DATA_WIDTH / 32;
    localparam integer BURST_BEATS = MWR_PAYLOAD_BYTES / DATA_BYTES;
    localparam [10:0] MWR_DWORDS = MWR_PAYLOAD_BYTES / 4;

    reg [15:0] width_q, height_q, stride_q;
    reg [15:0] line_idx, beat_col;
    reg [63:0] y_send_addr, uv_send_addr;
    reg [63:0] y_line_start_addr, uv_line_start_addr;
    reg [15:0] y_send_offset, uv_send_offset;
    reg [15:0] y_send_line, uv_send_line;
    reg [127:0] y_pack, uv_pack;
    reg sof_seen;
    reg capture_enable;
    reg frontend_done;
    reg pacing;
    reg [31:0] frame_clk_count;

    // Odd-row chroma processing is one cycle behind AXI input so the block-RAM
    // read from the matching even row can remain synchronous.
    reg odd_valid;
    reg [127:0] odd_data;
    reg [15:0] odd_col;
    reg odd_frame_end;
    reg [35:0] chroma_even_q;

    (* ram_style = "block" *) reg [35:0] chroma_line [0:CHROMA_WORDS-1];

    // Two small asynchronous-read distributed FIFOs hold complete 16-byte
    // output beats.  A request starts only when all eight beats of a 128-byte
    // payload are resident, so PCIe never observes FIFO underflow.
    (* ram_style = "distributed" *) reg [127:0] y_fifo [0:FIFO_DEPTH-1];
    (* ram_style = "distributed" *) reg [127:0] uv_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_WIDTH-1:0] y_wr_ptr, y_rd_ptr, uv_wr_ptr, uv_rd_ptr;
    reg [FIFO_COUNT_WIDTH-1:0] y_fifo_count, uv_fifo_count;

    reg request_is_uv;
    reg prefer_uv;
    reg [4:0] payload_beats_to_load;
    reg [15:0] active_req_bytes;

    wire [15:0] y_rem_bytes  = width_q - y_send_offset;
    wire [15:0] uv_rem_bytes = width_q - uv_send_offset;

    wire y_is_256  = (y_rem_bytes >= 16'd256);
    wire [10:0] y_next_dw_len = y_is_256 ? 11'd64 : 11'd32;
    wire [4:0]  y_next_beats  = y_is_256 ? 5'd16  : 5'd8;
    wire [15:0] y_next_bytes  = y_is_256 ? 16'd256: 16'd128;
    wire y_ready_to_send = (y_fifo_count >= y_next_beats);

    wire uv_is_256 = (uv_rem_bytes >= 16'd256);
    wire [10:0] uv_next_dw_len = uv_is_256 ? 11'd64 : 11'd32;
    wire [4:0]  uv_next_beats  = uv_is_256 ? 5'd16  : 5'd8;
    wire [15:0] uv_next_bytes  = uv_is_256 ? 16'd256: 16'd128;
    wire uv_ready_to_send = (uv_fifo_count >= uv_next_beats);

    function [31:0] pack_y4;
        input [127:0] d;
        begin
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
            pack_nv12_uv4 = {v23, u23, v01, u01};
        end
    endfunction

    wire descriptor_accept = desc_valid && !video_busy;
    wire fifo_space_available =
        (y_fifo_count <= FIFO_DEPTH-2) &&
        (uv_fifo_count <= FIFO_DEPTH-2);
    assign s_axis_tready = video_busy && capture_enable && fifo_space_available;

    wire input_transfer = s_axis_tvalid && s_axis_tready;
    wire pixel_accept = input_transfer && (sof_seen || s_axis_tuser);
    wire y_fifo_push = pixel_accept && (beat_col[1:0] == 2'b11);
    wire [127:0] y_fifo_push_data = {pack_y4(s_axis_tdata), y_pack[95:0]};
    wire uv_fifo_push = odd_valid && (odd_col[1:0] == 2'b11);
    wire [127:0] uv_fifo_push_data =
        {pack_nv12_uv4(odd_data, chroma_even_q), uv_pack[95:0]};

    wire y_fifo_pop = c2h_req_data_ready && c2h_req_valid && !request_is_uv;
    wire uv_fifo_pop = c2h_req_data_ready && c2h_req_valid && request_is_uv;

    // Simple-dual-port chroma line RAM.  beat_col is sampled before its input
    // transfer update, aligning chroma_even_q with odd_data one clock later.
    always @(posedge clk) begin
        if (pixel_accept && !line_idx[0])
            chroma_line[beat_col[CHROMA_ADDR_WIDTH-1:0]] <=
                horizontal_chroma_sums(s_axis_tdata);
        chroma_even_q <= chroma_line[beat_col[CHROMA_ADDR_WIDTH-1:0]];
    end

    // Y and UV beat FIFOs each have one producer and one PCIe consumer.
    always @(posedge clk) begin
        if (!rst_n || descriptor_accept) begin
            y_wr_ptr <= 0;
            y_rd_ptr <= 0;
            uv_wr_ptr <= 0;
            uv_rd_ptr <= 0;
            y_fifo_count <= 0;
            uv_fifo_count <= 0;
        end else begin
            if (y_fifo_push) begin
                y_fifo[y_wr_ptr] <= y_fifo_push_data;
                y_wr_ptr <= y_wr_ptr + 1'b1;
            end
            if (y_fifo_pop)
                y_rd_ptr <= y_rd_ptr + 1'b1;
            case ({y_fifo_push, y_fifo_pop})
                2'b10: y_fifo_count <= y_fifo_count + 1'b1;
                2'b01: y_fifo_count <= y_fifo_count - 1'b1;
                default: y_fifo_count <= y_fifo_count;
            endcase

            if (uv_fifo_push) begin
                uv_fifo[uv_wr_ptr] <= uv_fifo_push_data;
                uv_wr_ptr <= uv_wr_ptr + 1'b1;
            end
            if (uv_fifo_pop)
                uv_rd_ptr <= uv_rd_ptr + 1'b1;
            case ({uv_fifo_push, uv_fifo_pop})
                2'b10: uv_fifo_count <= uv_fifo_count + 1'b1;
                2'b01: uv_fifo_count <= uv_fifo_count - 1'b1;
                default: uv_fifo_count <= uv_fifo_count;
            endcase
        end
    end

    // One-input-beat-per-clock conversion frontend.
    always @(posedge clk) begin
        if (!rst_n) begin
            width_q <= 0;
            height_q <= 0;
            stride_q <= 0;
            line_idx <= 0;
            beat_col <= 0;
            y_pack <= 0;
            uv_pack <= 0;
            sof_seen <= 0;
            capture_enable <= 0;
            frontend_done <= 0;
            odd_valid <= 0;
            odd_data <= 0;
            odd_col <= 0;
            odd_frame_end <= 0;
            frame_pts <= 0;
            protocol_error_count <= 0;
        end else begin
            if (descriptor_accept) begin
                width_q <= frame_width;
                height_q <= frame_height;
                stride_q <= frame_stride;
                line_idx <= 0;
                beat_col <= 0;
                y_pack <= 0;
                uv_pack <= 0;
                sof_seen <= 0;
                capture_enable <= 1;
                frontend_done <= 0;
                odd_valid <= 0;
                odd_frame_end <= 0;
                if (frame_width > MAX_WIDTH || frame_width[6:0] != 0 ||
                    frame_height[0] || frame_stride < frame_width ||
                    (MWR_PAYLOAD_BYTES != 128 && MWR_PAYLOAD_BYTES != 256) ||
                    PCIE_DATA_WIDTH != 128)
                    protocol_error_count <= protocol_error_count + 1'b1;
            end else begin
                odd_valid <= pixel_accept && line_idx[0];
                if (pixel_accept && line_idx[0]) begin
                    odd_data <= s_axis_tdata;
                    odd_col <= beat_col;
                    odd_frame_end <= s_axis_tlast &&
                                     (line_idx + 1'b1 >= height_q);
                end

                if (odd_valid) begin
                    if (odd_col[1:0] == 2'b11)
                        uv_pack <= 0;
                    else
                        uv_pack[(odd_col[1:0]*32) +: 32] <=
                            pack_nv12_uv4(odd_data, chroma_even_q);
                    if (odd_frame_end) begin
                        frontend_done <= 1;
                        capture_enable <= 0;
                    end
                end

                if (pixel_accept) begin
                    if (!sof_seen) begin
                        sof_seen <= 1;
                        frame_pts <= global_timestamp;
                    end else if (s_axis_tuser) begin
                        protocol_error_count <= protocol_error_count + 1'b1;
                    end

                    if (beat_col[1:0] == 2'b11)
                        y_pack <= 0;
                    else
                        y_pack[(beat_col[1:0]*32) +: 32] <= pack_y4(s_axis_tdata);

                    if (s_axis_tlast !=
                        (beat_col == ((width_q >> 2) - 1'b1)))
                        protocol_error_count <= protocol_error_count + 1'b1;

                    if (s_axis_tlast) begin
                        beat_col <= 0;
                        line_idx <= line_idx + 1'b1;
                        if (line_idx + 1'b1 >= height_q) begin
                            capture_enable <= 0;
                            if (!line_idx[0])
                                frontend_done <= 1;
                        end
                    end else begin
                        beat_col <= beat_col + 1'b1;
                    end
                end
            end
        end
    end

    // 128-byte burst packetizer.  Y/UV requests are selected round-robin when
    // both FIFOs are ready; address generators preserve independent strides.
    always @(posedge clk) begin
        if (!rst_n) begin
            c2h_req_valid <= 0;
            c2h_req_addr <= 0;
            c2h_req_dw_len <= MWR_DWORDS;
            c2h_req_data <= 0;
            c2h_req_last <= 1;
            request_is_uv <= 0;
            prefer_uv <= 0;
            payload_beats_to_load <= 0;
            active_req_bytes <= 0;
            y_send_addr <= 0;
            uv_send_addr <= 0;
            y_line_start_addr <= 0;
            uv_line_start_addr <= 0;
            y_send_offset <= 0;
            uv_send_offset <= 0;
            y_send_line <= 0;
            uv_send_line <= 0;
        end else if (descriptor_accept) begin
            c2h_req_valid <= 0;
            c2h_req_addr <= 0;
            c2h_req_dw_len <= 11'd64;
            c2h_req_data <= 0;
            c2h_req_last <= 1;
            request_is_uv <= 0;
            prefer_uv <= 0;
            payload_beats_to_load <= 0;
            active_req_bytes <= 0;
            y_send_addr <= plane_y_addr;
            uv_send_addr <= plane_uv_addr;
            y_line_start_addr <= plane_y_addr;
            uv_line_start_addr <= plane_uv_addr;
            y_send_offset <= 0;
            uv_send_offset <= 0;
            y_send_line <= 0;
            uv_send_line <= 0;
        end else begin
            if (!c2h_req_valid) begin
                if (uv_ready_to_send && (prefer_uv || !y_ready_to_send)) begin
                    request_is_uv         <= 1'b1;
                    c2h_req_addr          <= uv_send_addr;
                    c2h_req_dw_len        <= uv_next_dw_len;
                    c2h_req_data          <= uv_fifo[uv_rd_ptr];
                    c2h_req_last          <= 1'b1;
                    payload_beats_to_load <= uv_next_beats;
                    active_req_bytes      <= uv_next_bytes;
                    c2h_req_valid         <= 1'b1;
                    prefer_uv             <= 1'b0;
                end else if (y_ready_to_send) begin
                    request_is_uv         <= 1'b0;
                    c2h_req_addr          <= y_send_addr;
                    c2h_req_dw_len        <= y_next_dw_len;
                    c2h_req_data          <= y_fifo[y_rd_ptr];
                    c2h_req_last          <= 1'b1;
                    payload_beats_to_load <= y_next_beats;
                    active_req_bytes      <= y_next_bytes;
                    c2h_req_valid         <= 1'b1;
                    prefer_uv             <= 1'b1;
                end
            end

            if (c2h_req_data_ready && c2h_req_valid) begin
                payload_beats_to_load <= payload_beats_to_load - 1'b1;
                if (payload_beats_to_load > 1) begin
                    if (request_is_uv)
                        c2h_req_data <= uv_fifo[uv_rd_ptr + 1'b1];
                    else
                        c2h_req_data <= y_fifo[y_rd_ptr + 1'b1];
                end
            end

            if (c2h_req_ack && c2h_req_valid) begin
                c2h_req_valid <= 0;
                if (request_is_uv) begin
                    if (uv_send_offset + active_req_bytes >= width_q) begin
                        uv_send_offset     <= 16'd0;
                        uv_send_line       <= uv_send_line + 1'b1;
                        uv_line_start_addr <= uv_line_start_addr + stride_q;
                        uv_send_addr       <= uv_line_start_addr + stride_q;
                    end else begin
                        uv_send_offset <= uv_send_offset + active_req_bytes;
                        uv_send_addr   <= uv_send_addr + active_req_bytes;
                    end
                end else begin
                    if (y_send_offset + active_req_bytes >= width_q) begin
                        y_send_offset     <= 16'd0;
                        y_send_line       <= y_send_line + 1'b1;
                        y_line_start_addr <= y_line_start_addr + stride_q;
                        y_send_addr       <= y_line_start_addr + stride_q;
                    end else begin
                        y_send_offset <= y_send_offset + active_req_bytes;
                        y_send_addr   <= y_send_addr + active_req_bytes;
                    end
                end
            end
        end
    end

    // Descriptor completion and 60-FPS pacing control.
    always @(posedge clk) begin
        if (!rst_n) begin
            desc_ready <= 0;
            video_busy <= 0;
            video_frame_done <= 0;
            pacing <= 0;
            frame_clk_count <= 0;
        end else begin
            desc_ready <= 0;
            video_frame_done <= 0;

            if (video_busy)
                frame_clk_count <= frame_clk_count + 1'b1;
            else
                frame_clk_count <= 0;

            if (descriptor_accept) begin
                desc_ready <= 1;
                video_busy <= 1;
                pacing <= 0;
                frame_clk_count <= 0;
            end else if (video_busy && !pacing && frontend_done &&
                         y_fifo_count == 0 && uv_fifo_count == 0 &&
                         !c2h_req_valid) begin
                video_frame_done <= 1;
                if (pacer_enable && frame_interval_clks != 0 &&
                    frame_clk_count < frame_interval_clks)
                    pacing <= 1;
                else
                    video_busy <= 0;
            end else if (pacing &&
                         (!pacer_enable || frame_clk_count >= frame_interval_clks)) begin
                pacing <= 0;
                video_busy <= 0;
            end
        end
    end

endmodule
