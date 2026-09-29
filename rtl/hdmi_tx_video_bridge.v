// ============================================================================
// Module: hdmi_tx_video_bridge
// Target: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
// Description:
//   HDMI TX Video Bridge & Clock Domain Crossing (CDC).
//   - Receives 128-bit packed Little-Endian AXI-Stream Video from PCIe DMA H2C (Channel 1).
//   - Unpacks into native 4 PPC (Pixels Per Clock) AXI4-Stream Video (96-bit RGB24):
//       P0 = {R, G, B}, P1 = {R, G, B}, P2 = {R, G, B}, P3 = {R, G, B}
//   - Crosses from pcie_user_clk (250 MHz) to tx_video_clk via xpm_fifo_async.
//   - Connects to Xilinx HDMI TX Subsystem (v_hdmi_tx_ss).
// ============================================================================

`timescale 1ns / 1ps

module hdmi_tx_video_bridge #(
    parameter FIFO_DEPTH = 1024
)(
    // PCIe DMA User Clock Domain (250 MHz)
    input  wire                                             pcie_user_clk,
    input  wire                                             pcie_user_rst_n,

    // 128-bit AXI4-Stream Video Input from PCIe DMA H2C (Channel 1)
    input  wire [127:0]                                     s_axis_video_tdata,
    input  wire                                             s_axis_video_tvalid,
    output wire                                             s_axis_video_tready,
    input  wire                                             s_axis_video_tlast,
    input  wire                                             s_axis_video_tuser,

    // Control from BAR0 0x0610
    input  wire [31:0]                                      tx_ctrl_reg,

    // Native HDMI TX Video Clock & Reset
    input  wire                                             tx_video_clk,
    input  wire                                             tx_video_rst_n,

    // AXI4-Stream Video Output to v_hdmi_tx_ss (4 PPC Native: 96-bit RGB24)
    output wire [95:0]                                      m_axis_video_tdata,
    output wire                                             m_axis_video_tvalid,
    input  wire                                             m_axis_video_tready,
    output wire                                             m_axis_video_tlast,
    output wire                                             m_axis_video_tuser,

    // Status to BAR0 0x0620
    input  wire                                             tx_hpd_in,
    output reg  [31:0]                                      tx_status_reg
);

    wire fifo_full;
    wire fifo_empty;
    wire [129:0] fifo_dout;
    wire fifo_rd_en;

    assign s_axis_video_tready = !fifo_full;
    assign fifo_rd_en          = m_axis_video_tready && !fifo_empty;

    wire fifo_rst = (!pcie_user_rst_n) || (!tx_video_rst_n) || (!tx_ctrl_reg[0]); // [0]=TX Output Enable

    // Write packed 128-bit stream + tlast + tuser into async FIFO
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
    ) u_tx_video_cdc (
        .sleep         (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (pcie_user_clk),
        .wr_en         (s_axis_video_tvalid && !fifo_full),
        .din           ({s_axis_video_tuser, s_axis_video_tlast, s_axis_video_tdata}),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (),
        .almost_full   (),
        .wr_ack        (),
        .rd_clk        (tx_video_clk),
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

    wire [127:0] raw_packed = fifo_dout[127:0];

    // Unpack 128-bit Little-Endian RGB into 4 PPC 96-bit native format:
    // P0: raw_packed[23:0]   -> m_axis[23:0]
    // P1: raw_packed[55:32]  -> m_axis[47:24]
    // P2: raw_packed[87:64]  -> m_axis[71:48]
    // P3: raw_packed[119:96] -> m_axis[95:72]
    assign m_axis_video_tdata = {
        raw_packed[119:96],
        raw_packed[87:64],
        raw_packed[55:32],
        raw_packed[23:0]
    };
    assign m_axis_video_tvalid = !fifo_empty;
    assign m_axis_video_tlast  = fifo_dout[128];
    assign m_axis_video_tuser  = fifo_dout[129];

    // Status Register (pcie_user_clk domain)
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_hpd;
    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n) begin
            sync_hpd      <= 2'b00;
            tx_status_reg <= 32'd0;
        end else begin
            sync_hpd      <= {sync_hpd[0], tx_hpd_in};
            // [0]=Sink Connected (HPD), [1]=TX PLL Locked, [2]=Stream Active
            tx_status_reg <= {29'd0, (!fifo_empty), 1'b1, sync_hpd[1]};
        end
    end

endmodule
