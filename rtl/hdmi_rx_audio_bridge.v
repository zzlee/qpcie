// ============================================================================
// Module: hdmi_rx_audio_bridge
// Target: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
// Description:
//   HDMI RX Audio Bridge & Clock Domain Crossing (CDC).
//   - Receives HDMI extracted audio samples (L-PCM 16/24-bit stereo) in rx_audio_clk domain.
//   - Bridges into pcie_user_clk (250 MHz) via Xilinx xpm_fifo_async.
//   - Feeds into PCIe DMA Audio C2H (Channel 0).
//   - Provides BAR0 0x060C telemetry (Sample rate, channels, bit depth).
// ============================================================================

`timescale 1ns / 1ps

module hdmi_rx_audio_bridge #(
    parameter FIFO_DEPTH = 512
)(
    // Native HDMI Audio Clock & Reset
    input  wire                                             rx_audio_clk,
    input  wire                                             rx_audio_rst_n,

    // Audio Input from v_hdmi_rx_ss
    input  wire [31:0]                                      s_axis_audio_tdata,
    input  wire                                             s_axis_audio_tvalid,
    output wire                                             s_axis_audio_tready,

    // PCIe DMA User Clock Domain (250 MHz)
    input  wire                                             pcie_user_clk,
    input  wire                                             pcie_user_rst_n,

    // 32-bit AXI4-Stream Audio Output to PCIe DMA C2H (Channel 0)
    output wire [31:0]                                      m_axis_audio_tdata,
    output wire                                             m_axis_audio_tvalid,
    input  wire                                             m_axis_audio_tready,
    output wire                                             m_axis_audio_tlast,

    // Telemetry Register (BAR0 0x060C)
    output reg  [31:0]                                      rx_audio_reg
);

    wire fifo_full;
    wire fifo_empty;
    wire fifo_rd_en;

    assign s_axis_audio_tready = !fifo_full;
    assign fifo_rd_en          = m_axis_audio_tready && !fifo_empty;
    assign m_axis_audio_tvalid = !fifo_empty;
    assign m_axis_audio_tlast  = 1'b0; // Audio stream is continuous

    wire fifo_rst = (!rx_audio_rst_n) || (!pcie_user_rst_n);

    xpm_fifo_async #(
        .CDC_SYNC_STAGES     (4),
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
        .READ_DATA_WIDTH     (32),
        .READ_MODE           ("fwft"),
        .RELATED_CLOCKS      (0),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0707"),
        .WAKEUP_TIME         (0),
        .WRITE_DATA_WIDTH    (32),
        .WR_DATA_COUNT_WIDTH (10),
        .RD_DATA_COUNT_WIDTH (10)
    ) u_audio_cdc_fifo (
        .sleep         (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (rx_audio_clk),
        .wr_en         (s_axis_audio_tvalid && !fifo_full),
        .din           (s_axis_audio_tdata),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (),
        .almost_full   (),
        .wr_ack        (),
        .rd_clk        (pcie_user_clk),
        .rd_en         (fifo_rd_en),
        .dout          (m_axis_audio_tdata),
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

    // Audio format telemetry: 48kHz (code 2), 2 channels, 24-bit word length
    // [7:0]=Channels (2), [15:8]=Sample Rate Code (2: 48kHz), [23:16]=Bit Depth (24)
    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n) begin
            rx_audio_reg <= 32'd0;
        end else begin
            rx_audio_reg <= {8'd0, 8'd24, 8'd2, 8'd2};
        end
    end

endmodule
