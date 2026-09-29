// ============================================================================
// Module: hdmi_tx_audio_bridge
// Target: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
// Description:
//   HDMI TX Audio Bridge & Clock Domain Crossing (CDC).
//   - Receives 32-bit AXI4-Stream Audio samples from PCIe DMA H2C (Channel 1).
//   - Crosses from pcie_user_clk (250 MHz) to tx_audio_clk via xpm_fifo_async.
//   - Connects to Xilinx HDMI TX Subsystem (v_hdmi_tx_ss) audio input.
// ============================================================================

`timescale 1ns / 1ps

module hdmi_tx_audio_bridge #(
    parameter FIFO_DEPTH = 512
)(
    // PCIe DMA User Clock Domain (250 MHz)
    input  wire                                             pcie_user_clk,
    input  wire                                             pcie_user_rst_n,

    // 32-bit AXI4-Stream Audio Input from PCIe DMA H2C (Channel 1)
    input  wire [31:0]                                      s_axis_audio_tdata,
    input  wire                                             s_axis_audio_tvalid,
    output wire                                             s_axis_audio_tready,
    input  wire                                             s_axis_audio_tlast,

    // Control from BAR0 0x0610 [1]=Audio Output Enable
    input  wire [31:0]                                      tx_ctrl_reg,

    // Native HDMI TX Audio Clock & Reset
    input  wire                                             tx_audio_clk,
    input  wire                                             tx_audio_rst_n,

    // 32-bit Audio Output to v_hdmi_tx_ss
    output wire [31:0]                                      m_axis_audio_tdata,
    output wire                                             m_axis_audio_tvalid,
    input  wire                                             m_axis_audio_tready,
    output wire                                             m_axis_audio_tlast
);

    wire fifo_full;
    wire fifo_empty;
    wire fifo_rd_en;

    assign s_axis_audio_tready = !fifo_full;
    assign fifo_rd_en          = m_axis_audio_tready && !fifo_empty;
    assign m_axis_audio_tvalid = !fifo_empty;
    assign m_axis_audio_tlast  = 1'b0;

    wire fifo_rst = (!pcie_user_rst_n) || (!tx_audio_rst_n) || (!tx_ctrl_reg[1]);

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
    ) u_tx_audio_cdc (
        .sleep         (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (pcie_user_clk),
        .wr_en         (s_axis_audio_tvalid && !fifo_full),
        .din           (s_axis_audio_tdata),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (),
        .almost_full   (),
        .wr_ack        (),
        .rd_clk        (tx_audio_clk),
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

endmodule
