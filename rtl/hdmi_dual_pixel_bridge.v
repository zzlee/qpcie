// ============================================================================
// Module: hdmi_dual_pixel_bridge
// Target: AMD/Xilinx Artix-7 (xc7a50t-csg325-2)
// Description:
//   HDMI Dual-Pixel Video Capture Bridge & Asynchronous CDC FIFO.
//   - Receives IT68051 60-bit Dual-Pixel Parallel Video (PCLK domain):
//       Pixel A (Even): 10-bit R/G/B (Bank 15)
//       Pixel B (Odd):  10-bit R/G/B (Bank 34)
//       Shared Sync:    DE, VS, HS
//   - Extracts 8-bit MSBs from each color component.
//   - Packs 2 dual-pixel clocks (4 pixels total) into one 128-bit beat.
//   - Aligns with standard 128-bit 4-PPC AXI4-Stream capture interface.
//   - Crosses clock domain from TM0_PCLK to video_clk (150 MHz) via XPM FIFO.
// ============================================================================

`timescale 1ns / 1ps

module hdmi_dual_pixel_bridge #(
    parameter FIFO_DEPTH = 512
)(
    // IT68051 Native Video Input Interface (TM0_PCLK domain)
    input  wire        tm0_pclk,
    input  wire        tm0_rst_n,

    input  wire        tm0_de,
    input  wire        tm0_vs,
    input  wire        tm0_hs,
    input  wire        single_pixel_mode, // Stable across capture; reset FIFO when changing
    input  wire        frame_stamp_enable, // Diagnostic: replace first 4 pixels of each line

    // Dual-Pixel Port A (Even pixels - Bank 15)
    input  wire [9:0]  tm0_a_r,
    input  wire [9:0]  tm0_a_g,
    input  wire [9:0]  tm0_a_b,

    // Dual-Pixel Port B (Odd pixels - Bank 34)
    input  wire [9:0]  tm0_b_r,
    input  wire [9:0]  tm0_b_g,
    input  wire [9:0]  tm0_b_b,

    // Video Processing Clock Domain (150 MHz)
    input  wire        video_clk,
    input  wire        video_rst_n,
    input  wire        capture_active, // video_clk domain: descriptor engine busy
    output wire [127:0] debug_gray, // PCLK-domain Gray counters; synchronize before use

    // AXI4-Stream 128-bit Video Output (video_clk domain)
    output wire [127:0] m_axis_video_tdata,
    output wire         m_axis_video_tvalid,
    output wire         m_axis_video_tlast,
    output wire [0:0]   m_axis_video_tuser,
    input  wire         m_axis_video_tready
);

    // =========================================================================
    // 1. Pixel Extraction & Dual-Beat Accumulator (TM0_PCLK domain)
    // Beat 0: Pixels 0 (A) and 1 (B) -> 64 bits
    // Beat 1: Pixels 2 (A) and 3 (B) -> 64 bits -> Emit 128-bit word
    // =========================================================================
    reg        de_q = 1'b0;
    reg        vs_q = 1'b0;
    reg [1:0]  pixel_count = 2'd0;
    reg        frame_start = 1'b0;
    reg        seen_vs = 1'b0;
    reg [31:0] source_frames = 0, source_lines = 0;
    reg [31:0] dropped_beats = 0, dropped_eols = 0;
    reg [15:0] source_row = 0;
    reg [11:0] line_words = 0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] stamp_sync = 0;
    always @(posedge tm0_pclk) stamp_sync <= {stamp_sync[0], frame_stamp_enable};
    // Four RGB24 pixels after the bridge strips alpha. Repeated on EVERY
    // line to detect missing lines, torn frames and source-frame ID gaps.
    wire [127:0] stamp_word = {
        8'hFF, 8'h5A, ~source_row[15:8], ~source_row[7:0],
        8'hFF, ~source_frames[23:16], ~source_frames[15:8], ~source_frames[7:0],
        8'hFF, source_row[15:8], source_row[7:0], source_frames[23:16],
        8'hFF, source_frames[15:8], source_frames[7:0], 8'hA5
    };
    // Register Gray codes alongside their binary counters. Do not expose
    // combinational binary-to-Gray XOR glitches to the PCIe clock domain.
    reg [31:0] frames_gray = 0, lines_gray = 0, drops_gray = 0, eols_gray = 0;
    assign debug_gray = {eols_gray, drops_gray, lines_gray, frames_gray};

    reg [127:0] pixels_q = 128'd0;
    reg [127:0] pending_data = 128'd0;
    reg         pending_valid = 1'b0;
    reg         pending_user = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] single_sync = 2'b00;
    always @(posedge tm0_pclk) single_sync <= {single_sync[0], single_pixel_mode};

    // 8-bit MSBs: Little-endian 32-bit pixel: {8'hFF, R, G, B}
    wire [31:0] p_a_dw = {8'hFF, tm0_a_r[9:2], tm0_a_g[9:2], tm0_a_b[9:2]};
    wire [31:0] p_b_dw = {8'hFF, tm0_b_r[9:2], tm0_b_g[9:2], tm0_b_b[9:2]};
    wire [63:0] current_pair = {p_b_dw, p_a_dw}; // P_odd, P_even

    reg [127:0] fifo_din_data = 128'd0;
    reg         fifo_din_last = 1'b0;
    reg         fifo_din_user = 1'b0;
    reg         fifo_wr_en    = 1'b0;
    wire fifo_full, fifo_empty;
    wire wr_rst_busy, rd_rst_busy;

    always @(posedge tm0_pclk or negedge tm0_rst_n) begin
        if (!tm0_rst_n) begin
            de_q        <= 1'b0;
            vs_q        <= 1'b0;
            pixel_count <= 2'd0;
            frame_start <= 1'b0;
            seen_vs     <= 1'b0;
            pixels_q    <= 128'd0;
            pending_data <= 128'd0;
            pending_valid <= 1'b0;
            pending_user <= 1'b0;
            fifo_din_data <= 128'd0;
            fifo_din_last <= 1'b0;
            fifo_din_user <= 1'b0;
            fifo_wr_en    <= 1'b0;
            source_frames <= 0; source_lines <= 0;
            dropped_beats <= 0; dropped_eols <= 0;
            frames_gray <= 0; lines_gray <= 0; drops_gray <= 0; eols_gray <= 0;
            source_row <= 0; line_words <= 0;
        end else begin
            de_q <= tm0_de;
            vs_q <= tm0_vs;
            fifo_wr_en <= 1'b0;
            if (fifo_wr_en && fifo_full && !wr_rst_busy) begin
                dropped_beats <= dropped_beats + 1'b1;
                drops_gray <= ((dropped_beats + 1'b1) >> 1) ^ (dropped_beats + 1'b1);
                if (fifo_din_last) begin
                    dropped_eols <= dropped_eols + 1'b1;
                    eols_gray <= ((dropped_eols + 1'b1) >> 1) ^ (dropped_eols + 1'b1);
                end
            end

            // Hold a complete word for one cycle: the DE falling edge then
            // marks TLAST on the actual final word, never on an extra beat.
            if (pending_valid) begin
                fifo_din_data <= pending_data;
                fifo_din_user <= pending_user;
                fifo_din_last <= !tm0_de;
                fifo_wr_en <= 1'b1;
                pending_valid <= 1'b0;
            end

            // Frame start detection on VS falling edge (active frame begins)
            if (vs_q && !tm0_vs) begin
                frame_start <= 1'b1;
                seen_vs     <= 1'b1;
                pixel_count <= 2'd0;
                source_frames <= source_frames + 1'b1;
                frames_gray <= ((source_frames + 1'b1) >> 1) ^ (source_frames + 1'b1);
                source_row <= 0;
                line_words <= 0;
            end

            if (tm0_de && seen_vs) begin
                if (single_sync[1]) begin
                    case (pixel_count)
                        2'd0: pixels_q[31:0] <= p_a_dw;
                        2'd1: pixels_q[63:32] <= p_a_dw;
                        2'd2: pixels_q[95:64] <= p_a_dw;
                        2'd3: begin
                            pending_data <= (stamp_sync[1] && line_words == 0) ?
                                            stamp_word : {p_a_dw, pixels_q[95:0]};
                            line_words <= line_words + 1'b1;
                            pending_valid <= 1'b1;
                            pending_user <= frame_start;
                            frame_start <= 1'b0;
                        end
                    endcase
                    pixel_count <= pixel_count + 1'b1;
                end else begin
                    if (pixel_count == 0) begin
                        pixels_q[63:0] <= current_pair;
                        pixel_count <= 2'd2;
                    end else begin
                        pending_data <= (stamp_sync[1] && line_words == 0) ?
                                        stamp_word : {current_pair, pixels_q[63:0]};
                        line_words <= line_words + 1'b1;
                        pending_valid <= 1'b1;
                        pending_user <= frame_start;
                        pixel_count <= 2'd0;
                        frame_start <= 1'b0;
                    end
                end
            end else if (de_q && !tm0_de && seen_vs) begin
                source_lines <= source_lines + 1'b1;
                lines_gray <= ((source_lines + 1'b1) >> 1) ^ (source_lines + 1'b1);
                source_row <= source_row + 1'b1;
                line_words <= 0;
                // Pad an incomplete final word (capture widths normally /4).
                if (pixel_count != 0) begin
                    case (pixel_count)
                        2'd1: fifo_din_data <= {96'd0, pixels_q[31:0]};
                        2'd2: fifo_din_data <= {64'd0, pixels_q[63:0]};
                        2'd3: fifo_din_data <= {32'd0, pixels_q[95:0]};
                    endcase
                    fifo_din_user <= frame_start;
                    fifo_din_last <= 1'b1;
                    fifo_wr_en    <= 1'b1;
                    pixel_count <= 2'd0;
                    frame_start <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // 2. Asynchronous CDC FIFO (TM0_PCLK -> video_clk 150 MHz)
    // Width: 130 bits (128-bit data + 1-bit last + 1-bit user)
    // =========================================================================
    wire fifo_rd_en;
    wire [129:0] fifo_dout;
    wire fifo_rst = (!tm0_rst_n) || (!video_rst_n);

    // A camera cannot be backpressured. Drain stale data while no descriptor
    // is active, rather than filling the FIFO before STREAMON. The engine
    // still waits for SOF after accepting a descriptor. capture_active only
    // deasserts after the descriptor completes/aborts, not during AXIS stalls.
    assign fifo_rd_en          = (!capture_active || m_axis_video_tready) && !fifo_empty && !rd_rst_busy;
    assign m_axis_video_tvalid = capture_active && !fifo_empty && !rd_rst_busy;
    assign m_axis_video_tdata  = fifo_dout[127:0];
    assign m_axis_video_tlast  = fifo_dout[128];
    assign m_axis_video_tuser  = fifo_dout[129];

    xpm_fifo_async #(
        .CDC_SYNC_STAGES     (4),
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
        .READ_DATA_WIDTH     (130),
        .READ_MODE           ("fwft"),
        .RELATED_CLOCKS      (0),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0707"),
        .WAKEUP_TIME         (0),
        .WRITE_DATA_WIDTH    (130),
        .WR_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
        .RD_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1)
    ) u_video_cdc_fifo (
        .sleep         (1'b0),
        .injectsbiterr  (1'b0),
        .injectdbiterr  (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (tm0_pclk),
        .wr_en         (fifo_wr_en && !fifo_full && !wr_rst_busy),
        .din           ({fifo_din_user, fifo_din_last, fifo_din_data}),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (wr_rst_busy),
        .almost_full   (),
        .wr_ack        (),
        .rd_clk        (video_clk),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .rd_rst_busy   (rd_rst_busy),
        .almost_empty  (),
        .data_valid    (),
        .dbiterr       (),
        .sbiterr       ()
    );

endmodule
