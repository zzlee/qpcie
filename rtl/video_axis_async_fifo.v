// AXI4-Stream video CDC. SOF and EOL cross with their associated pixel beat.
`timescale 1ns / 1ps
module video_axis_async_fifo #(
    parameter integer DEPTH = 1024,
    parameter MEMORY_TYPE = "block"
)(
    input wire s_clk, s_rst_n,
    input wire [127:0] s_data,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    input wire m_clk, m_rst_n,
    output wire [127:0] m_data,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready
);
    wire fifo_rst, full, empty, wr_busy, rd_busy;
    wire [129:0] dout;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_reset (
        .src_arst(!s_rst_n || !m_rst_n), .dest_clk(s_clk), .dest_arst(fifo_rst));
    assign s_ready = !full && !wr_busy && !fifo_rst;
    assign m_valid = !empty && !rd_busy && m_rst_n;
    assign {m_sof, m_eol, m_data} = dout;
    xpm_fifo_async #(
        .CDC_SYNC_STAGES(4), .DOUT_RESET_VALUE("0"), .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE(MEMORY_TYPE), .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(DEPTH), .READ_DATA_WIDTH(130), .READ_MODE("fwft"),
        .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(1), .USE_ADV_FEATURES("0000"),
        .WAKEUP_TIME(0), .WRITE_DATA_WIDTH(130),
        .WR_DATA_COUNT_WIDTH($clog2(DEPTH)+1), .RD_DATA_COUNT_WIDTH($clog2(DEPTH)+1)
    ) u_fifo (
        .rst(fifo_rst), .wr_clk(s_clk), .wr_en(s_valid && s_ready),
        .din({s_sof, s_eol, s_data}), .full(full), .wr_rst_busy(wr_busy),
        .rd_clk(m_clk), .rd_en(m_valid && m_ready), .dout(dout),
        .empty(empty), .rd_rst_busy(rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .prog_full(), .wr_data_count(), .overflow(), .almost_full(), .wr_ack(),
        .prog_empty(), .rd_data_count(), .underflow(), .almost_empty(),
        .data_valid(), .dbiterr(), .sbiterr()
    );
endmodule
