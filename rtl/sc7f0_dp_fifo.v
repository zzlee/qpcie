`default_nettype none
// Small ordered queues for the dual-path extension. All reset assertions flush
// both ends; release/busy is handled by XPM, not by sampling a raw cross-clock bus.
`timescale 1ns/1ps
module sc7f0_dp_fifo #(
    parameter WIDTH=256, DEPTH=16, MEMORY="distributed"
)(
    input wire wclk, wrst_n, input wire [WIDTH-1:0] wdata,
    input wire wvalid, output wire wready,
    input wire rclk, rrst_n, output wire [WIDTH-1:0] rdata,
    output wire rvalid, input wire rready
);
    wire reset, read_reset, full, empty, wb, rb;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.RST_ACTIVE_HIGH(1)) u_reset(
        .src_arst(!wrst_n || !rrst_n),.dest_clk(wclk),.dest_arst(reset));
    // rrst_n may contain PCIe link state even when rclk is the PS CSR clock.
    // Never feed that asynchronous release directly into the read CE/VALID.
    // Flush on either reset; assert asynchronously and release in each domain.
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.RST_ACTIVE_HIGH(1)) u_read_reset(
        .src_arst(!wrst_n || !rrst_n),.dest_clk(rclk),.dest_arst(read_reset));
    assign wready=!reset && !wb && !full;
    assign rvalid=!read_reset && !rb && !empty;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE(MEMORY),.FIFO_WRITE_DEPTH(DEPTH),
        .WRITE_DATA_WIDTH(WIDTH),.READ_DATA_WIDTH(WIDTH),
        .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(4),
        .USE_ADV_FEATURES("0000"),.SIM_ASSERT_CHK(1),
        .WR_DATA_COUNT_WIDTH($clog2(DEPTH)+1),.RD_DATA_COUNT_WIDTH($clog2(DEPTH)+1)
    ) u_fifo(
        .rst(reset),.wr_clk(wclk),.din(wdata),.wr_en(wvalid&&wready),
        .full(full),.wr_rst_busy(wb),.rd_clk(rclk),.dout(rdata),
        .rd_en(rvalid&&rready),.empty(empty),.rd_rst_busy(rb),
        .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .prog_full(),.prog_empty(),.wr_data_count(),.rd_data_count(),
        .overflow(),.underflow(),.almost_full(),.almost_empty(),.wr_ack(),
        .data_valid(),.dbiterr(),.sbiterr());
endmodule

module sc7f0_dp_sync_fifo #(parameter WIDTH=177, DEPTH=512)(
    input wire clk, rst_n, input wire [WIDTH-1:0] din, input wire push,
    output wire full, output wire [WIDTH-1:0] dout, input wire pop,
    output wire empty, output wire [$clog2(DEPTH):0] count
);
    wire wb,rb,ff,ee;
    assign full=ff||wb||!rst_n;
    assign empty=ee||rb||!rst_n;
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(DEPTH),
        .WRITE_DATA_WIDTH(WIDTH),.READ_DATA_WIDTH(WIDTH),
        .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),.USE_ADV_FEATURES("0404"),
        .WR_DATA_COUNT_WIDTH($clog2(DEPTH)+1),.RD_DATA_COUNT_WIDTH($clog2(DEPTH)+1),
        .SIM_ASSERT_CHK(1)
    ) u_fifo(
        .rst(!rst_n),.wr_clk(clk),.din(din),.wr_en(push&&!full),
        .full(ff),.wr_rst_busy(wb),.dout(dout),.rd_en(pop&&!empty),
        .empty(ee),.rd_rst_busy(rb),.rd_data_count(count),.wr_data_count(),
        .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .prog_full(),.prog_empty(),.overflow(),.underflow(),
        .almost_full(),.almost_empty(),.wr_ack(),.data_valid(),.dbiterr(),.sbiterr());
endmodule
`default_nettype wire
