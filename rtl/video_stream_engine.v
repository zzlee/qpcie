// ============================================================================
// Module: video_stream_engine
// Description: Multi-Channel 2D Video Stream Engine with:
//              - Hardware Frame Rate Pacer (frame_interval_clks)
//              - Hardware AV Sync PTS Timestamp Latching
//              - Hardware Automatic Frame Dropper & Ring Overflow Protection
// ============================================================================

`timescale 1ns / 1ps

module video_stream_engine #(
    parameter VIDEO_DATA_WIDTH = 128,
    parameter PCIE_DATA_WIDTH  = 128
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // 2D Descriptor Controls for current video frame
    input  wire                          video_start,
    input  wire [63:0]                   host_frame_addr,
    input  wire [15:0]                   line_width_bytes,
    input  wire [15:0]                   line_count,
    input  wire [15:0]                   line_stride_bytes,
    input  wire                          is_c2h, // 0: H2C (Host->Video Out), 1: C2H (Video In->Host)
    input  wire                          pacer_enable,        // 1: Enable Fixed Clock Pacer, 0: Disable (External Live Signal Mode)
    input  wire [31:0]                   frame_interval_clks, // Hardware Frame Pacer Clocks (e.g. 2083333 for 60.00 FPS @ 125MHz)
    input  wire [15:0]                   slice_height,        // Sub-Frame Slice Height in Lines (0=Disabled)
    input  wire [63:0]                   global_timestamp,    // Hardware AV Sync Master Timestamp (ns)
    input  wire                          ring_full,           // Host DMA Ring Full Indicator

    // C2H Input Video Stream (External Video Source -> PCIe Engine)
    input  wire [VIDEO_DATA_WIDTH-1:0]   s_axis_video_tdata,
    input  wire                          s_axis_video_tvalid,
    input  wire                          s_axis_video_tlast, // EOL (End of Line)
    input  wire                          s_axis_video_tuser, // tuser = SOF (Start of Frame)
    output reg                           s_axis_video_tready,

    // H2C Output Video Stream (PCIe Engine -> External Video Sink)
    output reg  [VIDEO_DATA_WIDTH-1:0]   m_axis_video_tdata,
    output reg                           m_axis_video_tvalid,
    output reg                           m_axis_video_tlast, // EOL
    output reg                           m_axis_video_tuser, // SOF
    input  wire                          m_axis_video_tready,

    // Interface to RQ Encoder (C2H MWr Request)
    output reg                           c2h_req_valid,
    output reg  [63:0]                   c2h_req_addr,
    output reg  [10:0]                   c2h_req_dw_len,
    output reg  [PCIE_DATA_WIDTH-1:0]    c2h_req_data,
    output reg                           c2h_req_last,
    input  wire                          c2h_req_ack,

    // Interface to RC Decoder / H2C FIFO (H2C CplD Data Input)
    input  wire                          h2c_fifo_wvalid,
    input  wire [PCIE_DATA_WIDTH-1:0]    h2c_fifo_wdata,
    input  wire                          h2c_fifo_wlast,

    // Status, PTS & Frame Drop Telemetry Signals
    output reg                           video_busy,
    output reg                           video_frame_done,
    output reg  [63:0]                   frame_pts,           // Latched SOF PTS Timestamp (ns)
    output reg  [31:0]                   frame_drop_count     // Hardware Frame Drop Counter
);

    localparam IDLE      = 3'b000;
    localparam C2H_LINE  = 3'b001;
    localparam C2H_SEND  = 3'b010;
    localparam C2H_PACE  = 3'b011;
    localparam C2H_DROP  = 3'b100;
    localparam H2C_OUT   = 3'b101;

    reg [2:0]  state;
    reg [15:0] curr_line;
    reg [PCIE_DATA_WIDTH-1:0] line_buffer;
    reg [31:0] pacer_clk_cnt;
    reg [15:0] slice_line_count;

    // Hardware Frame Pacer Timer (Resets on frame start, counts up every clock)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pacer_clk_cnt <= 32'd0;
        end else begin
            if (state == IDLE && video_start) begin
                pacer_clk_cnt <= 32'd0;
            end else if (state != IDLE) begin
                pacer_clk_cnt <= pacer_clk_cnt + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= IDLE;
            s_axis_video_tready <= 1'b0;
            m_axis_video_tdata  <= {VIDEO_DATA_WIDTH{1'b0}};
            m_axis_video_tvalid <= 1'b0;
            m_axis_video_tlast  <= 1'b0;
            m_axis_video_tuser  <= 1'b0;
            c2h_req_valid       <= 1'b0;
            c2h_req_addr        <= 64'd0;
            c2h_req_dw_len      <= 11'd0;
            c2h_req_data        <= {PCIE_DATA_WIDTH{1'b0}};
            c2h_req_last        <= 1'b0;
            video_busy          <= 1'b0;
            video_frame_done    <= 1'b0;
            curr_line           <= 16'd0;
            line_buffer         <= {PCIE_DATA_WIDTH{1'b0}};
            frame_pts           <= 64'd0;
            frame_drop_count    <= 32'd0;
            slice_line_count    <= 16'd0;
        end else begin
            case (state)
                IDLE: begin
                    video_frame_done    <= 1'b0;
                    s_axis_video_tready <= 1'b0;
                    m_axis_video_tvalid <= 1'b0;

                    if (video_start) begin
                        video_busy <= 1'b1;
                        curr_line  <= 16'd0;
                        slice_line_count <= 16'd0;
                        if (is_c2h) begin
                            if (ring_full) begin
                                // Ring Full Overflow Protection: Drop frame silently and count
                                frame_drop_count    <= frame_drop_count + 1'b1;
                                s_axis_video_tready <= 1'b1;
                                state               <= C2H_DROP;
                            end else begin
                                s_axis_video_tready <= 1'b1;
                                state               <= C2H_LINE;
                            end
                        end else begin
                            state               <= H2C_OUT;
                        end
                    end
                end

                // C2H: Collect AXI4-Stream Video input line and issue PCIe MWr TLP
                C2H_LINE: begin
                    if (s_axis_video_tvalid && s_axis_video_tready) begin
                        // Latch Frame PTS on Start of Frame (SOF)
                        if (s_axis_video_tuser || curr_line == 0) begin
                            frame_pts <= global_timestamp;
                        end

                        if (PCIE_DATA_WIDTH > VIDEO_DATA_WIDTH) begin
                            line_buffer <= {s_axis_video_tdata, line_buffer[PCIE_DATA_WIDTH-1:VIDEO_DATA_WIDTH]};
                        end else begin
                            line_buffer <= s_axis_video_tdata;
                        end

                        if (s_axis_video_tlast) begin // EOL (End of Line)
                            s_axis_video_tready <= 1'b0;
                            c2h_req_addr   <= host_frame_addr + (curr_line * line_stride_bytes);
                            c2h_req_dw_len <= (line_width_bytes > 16'd0) ? line_width_bytes[12:2] : 11'd8;
                            if (PCIE_DATA_WIDTH > VIDEO_DATA_WIDTH) begin
                                c2h_req_data <= {s_axis_video_tdata, line_buffer[PCIE_DATA_WIDTH-1:VIDEO_DATA_WIDTH]};
                            end else begin
                                c2h_req_data <= s_axis_video_tdata;
                            end
                            c2h_req_last   <= 1'b1;
                            c2h_req_valid  <= 1'b1;
                            state          <= C2H_SEND;
                        end
                    end
                end

                C2H_SEND: begin
                    if (c2h_req_ack) begin
                        c2h_req_valid <= 1'b0;

                        // Incremental slice counter avoids a variable modulo/divider
                        // in the 125 MHz completion path.
                        if (slice_height > 16'd0 && (slice_line_count + 1'b1 >= slice_height)) begin
                            video_frame_done <= 1'b1;
                            slice_line_count <= 16'd0;
                        end else begin
                            video_frame_done <= 1'b0;
                            slice_line_count <= slice_line_count + 1'b1;
                        end

                        if (curr_line + 1'b1 < line_count) begin
                            curr_line           <= curr_line + 1'b1;
                            s_axis_video_tready <= 1'b1;
                            state               <= C2H_LINE;
                        end else begin
                            // Check Frame Pacer: Wait for target clocks if pacer is enabled
                            if (pacer_enable && frame_interval_clks > 32'd0 && pacer_clk_cnt < frame_interval_clks) begin
                                state <= C2H_PACE;
                            end else begin
                                video_busy       <= 1'b0;
                                video_frame_done <= 1'b1;
                                state            <= IDLE;
                            end
                        end
                    end else begin
                        video_frame_done <= 1'b0;
                    end
                end

                // C2H_DROP: Drain stream when Host Ring Buffer is FULL (Overflow Protection)
                C2H_DROP: begin
                    if (s_axis_video_tvalid && s_axis_video_tready) begin
                        if (s_axis_video_tlast) begin
                            if (curr_line + 1'b1 < line_count) begin
                                curr_line <= curr_line + 1'b1;
                            end else begin
                                s_axis_video_tready <= 1'b0;
                                video_busy          <= 1'b0;
                                video_frame_done    <= 1'b1;
                                state               <= IDLE;
                            end
                        end
                    end
                end

                // C2H_PACE: Internal Pacer Wait State (Bypassed if pacer_enable == 0)
                C2H_PACE: begin
                    if (!pacer_enable || pacer_clk_cnt >= frame_interval_clks) begin
                        video_busy       <= 1'b0;
                        video_frame_done <= 1'b1;
                        state            <= IDLE;
                    end
                end

                // H2C: Stream PCIe CplD data out to AXI4-Stream Video interface
                H2C_OUT: begin
                    if (h2c_fifo_wvalid) begin
                        m_axis_video_tdata  <= h2c_fifo_wdata[VIDEO_DATA_WIDTH-1:0];
                        m_axis_video_tvalid <= 1'b1;
                        m_axis_video_tuser  <= (curr_line == 0) ? 1'b1 : 1'b0; // SOF on 1st line
                        m_axis_video_tlast  <= 1'b1; // EOL on beat end
                        if (m_axis_video_tready) begin
                            if (curr_line + 1'b1 < line_count) begin
                                curr_line <= curr_line + 1'b1;
                            end else begin
                                video_busy       <= 1'b0;
                                video_frame_done <= 1'b1;
                                state            <= IDLE;
                            end
                        end
                    end else begin
                        m_axis_video_tvalid <= 1'b0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
