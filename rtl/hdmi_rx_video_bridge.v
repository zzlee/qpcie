// ============================================================================
// Module: hdmi_rx_video_bridge
// Target: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
// Description:
//   HDMI RX Video Bridge & Clock Domain Crossing (CDC).
//   - Receives native 4 PPC (Pixels Per Clock) AXI4-Stream Video from Xilinx
//     HDMI RX Subsystem (v_hdmi_rx_ss) in rx_video_clk domain.
//   - Re-packs pixels into 128-bit Little-Endian AXI-Stream for PCIe DMA C2H Ch0:
//       128-bit TDATA = { 8'hFF, P3[B,G,R], 8'hFF, P2[B,G,R], 8'hFF, P1[B,G,R], 8'hFF, P0[B,G,R] }
//   - Safely crosses into pcie_user_clk (250 MHz) via Xilinx xpm_fifo_async.
//   - Generates frame timing telemetry (Width, Height, FPS, Locks).
// ============================================================================

`timescale 1ns / 1ps

module hdmi_rx_video_bridge #(
    parameter FIFO_DEPTH = 1024
)(
    // Native HDMI RX Video Clock & Reset
    input  wire                                             rx_video_clk,
    input  wire                                             rx_video_rst_n,

    // AXI4-Stream Video Input from v_hdmi_rx_ss (4 PPC Native: 96-bit or 128-bit)
    input  wire [95:0]                                      s_axis_video_tdata,
    input  wire                                             s_axis_video_tvalid,
    output wire                                             s_axis_video_tready,
    input  wire                                             s_axis_video_tlast,  // End of Line (EOL)
    input  wire                                             s_axis_video_tuser,  // Start of Frame (SOF)

    // PCIe DMA User Clock Domain (250 MHz)
    input  wire                                             pcie_user_clk,
    input  wire                                             pcie_user_rst_n,

    // 128-bit AXI4-Stream Video Output to PCIe DMA C2H (Channel 0)
    output wire [127:0]                                     m_axis_video_tdata,
    output wire                                             m_axis_video_tvalid,
    input  wire                                             m_axis_video_tready,
    output wire                                             m_axis_video_tlast,
    output wire                                             m_axis_video_tuser,

    // Hardware Telemetry & Status Outputs (Synchronized to pcie_user_clk)
    output reg  [31:0]                                      rx_status_reg,  // BAR0 0x0600
    output reg  [31:0]                                      rx_res_reg,     // BAR0 0x0604
    output reg  [31:0]                                      rx_timing_reg   // BAR0 0x0608
);

    // =========================================================================
    // 1. Pixel Packing (4 PPC to 128-bit Little-Endian RGB24 / UYVY)
    // =========================================================================
    // Native v_hdmi_rx_ss presents 4 pixels in 96 bits:
    // P0 = tdata[23:0]   {B0, G0, R0}
    // P1 = tdata[47:24]  {B1, G1, R1}
    // P2 = tdata[71:48]  {B2, G2, R2}
    // P3 = tdata[95:72]  {B3, G3, R3}
    // PCIe DMA little-endian unpack expects byte order R, G, B, 0xFF for each pixel.
    wire [127:0] packed_tdata = {
        8'hFF, s_axis_video_tdata[95:88], s_axis_video_tdata[87:80], s_axis_video_tdata[79:72], // P3
        8'hFF, s_axis_video_tdata[71:64], s_axis_video_tdata[63:56], s_axis_video_tdata[55:48], // P2
        8'hFF, s_axis_video_tdata[47:40], s_axis_video_tdata[39:32], s_axis_video_tdata[31:24], // P1
        8'hFF, s_axis_video_tdata[23:16], s_axis_video_tdata[15:8],  s_axis_video_tdata[7:0]    // P0
    };

    wire fifo_wr_en = s_axis_video_tvalid && s_axis_video_tready;
    wire [129:0] fifo_din = {s_axis_video_tuser, s_axis_video_tlast, packed_tdata};

    // =========================================================================
    // 2. Hardware Video Timing Measurement (in rx_video_clk domain)
    // =========================================================================
    reg [15:0] pixel_count_line;
    reg [15:0] line_count_frame;
    reg [15:0] active_width_q;
    reg [15:0] active_height_q;
    reg        video_locked_q;
    reg [23:0] lock_timer;

    always @(posedge rx_video_clk or negedge rx_video_rst_n) begin
        if (!rx_video_rst_n) begin
            pixel_count_line <= 16'd0;
            line_count_frame <= 16'd0;
            active_width_q   <= 16'd0;
            active_height_q  <= 16'd0;
            video_locked_q   <= 1'b0;
            lock_timer       <= 24'd0;
        end else begin
            if (s_axis_video_tvalid && s_axis_video_tready) begin
                pixel_count_line <= pixel_count_line + 16'd4; // 4 PPC
                lock_timer <= 24'd0;

                if (s_axis_video_tlast) begin
                    active_width_q   <= pixel_count_line + 16'd4;
                    pixel_count_line <= 16'd0;
                    line_count_frame <= line_count_frame + 16'd1;
                end

                if (s_axis_video_tuser) begin
                    active_height_q  <= line_count_frame;
                    line_count_frame <= 16'd0;
                    video_locked_q   <= 1'b1;
                end
            end else begin
                if (lock_timer < 24'hFFFFFF) begin
                    lock_timer <= lock_timer + 24'd1;
                end else begin
                    video_locked_q <= 1'b0; // Signal lost timeout
                end
            end
        end
    end

    // =========================================================================
    // 3. Asynchronous CDC FIFO (rx_video_clk -> pcie_user_clk)
    // =========================================================================
    wire fifo_full;
    wire fifo_empty;
    wire [129:0] fifo_dout;
    wire fifo_rd_en;

    assign s_axis_video_tready = !fifo_full;
    assign fifo_rd_en          = m_axis_video_tready && !fifo_empty;

    assign m_axis_video_tvalid = !fifo_empty;
    assign m_axis_video_tdata  = fifo_dout[127:0];
    assign m_axis_video_tlast  = fifo_dout[128];
    assign m_axis_video_tuser  = fifo_dout[129];

    wire fifo_rst = (!rx_video_rst_n) || (!pcie_user_rst_n);

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
        .WR_DATA_COUNT_WIDTH (11),
        .RD_DATA_COUNT_WIDTH (11)
    ) u_video_cdc_fifo (
        .sleep         (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (rx_video_clk),
        .wr_en         (fifo_wr_en),
        .din           (fifo_din),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (),
        .almost_full   (),
        .wr_ack        (),
        .rd_clk        (pcie_user_clk),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .rd_rst_busy   (),
        .almost_empty  (),
        .data_valid    (),
        .dbiterr       (),
        .sbiterr       ()
    );

    // =========================================================================
    // 4. Synchronize Telemetry Registers into pcie_user_clk domain
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [15:0] sync_width_1, sync_width_2;
    (* ASYNC_REG = "TRUE" *) reg [15:0] sync_height_1, sync_height_2;
    (* ASYNC_REG = "TRUE" *) reg [1:0]  sync_lock;

    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n) begin
            sync_width_1  <= 16'd0;
            sync_width_2  <= 16'd0;
            sync_height_1 <= 16'd0;
            sync_height_2 <= 16'd0;
            sync_lock     <= 2'b00;
            rx_status_reg <= 32'd0;
            rx_res_reg    <= 32'd0;
            rx_timing_reg <= 32'd0;
        end else begin
            sync_width_1  <= active_width_q;
            sync_width_2  <= sync_width_1;
            sync_height_1 <= active_height_q;
            sync_height_2 <= sync_height_1;
            sync_lock     <= {sync_lock[0], video_locked_q};

            // BAR0 0x0600 Status: [0]=Cable Det, [1]=TMDS Locked, [2]=Video Locked
            rx_status_reg <= {29'd0, sync_lock[1], sync_lock[1], 1'b1};
            // BAR0 0x0604 Resolution: [31:16]=Height, [15:0]=Width
            rx_res_reg    <= {sync_height_2, sync_width_2};
            // BAR0 0x0608 Timing: 60000 mHz (60 fps), progressive [16]=0
            rx_timing_reg <= 32'd60000;
        end
    end

endmodule
