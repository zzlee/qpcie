`default_nettype none
// Small ordered queues for the dual-path extension. All reset assertions flush
// both ends; release/busy is handled by XPM, not by sampling a raw cross-clock
// bus.
//
// Reset contract (fixes CDC-10/CDC-12, see rtl/sc7f0_reset_cdc.v):
//   * wrst_n / rrst_n are VECTORS of independent asynchronous reset sources.
//     The caller must NOT pre-AND them: combining two cross-domain resets before
//     a synchronizer is exactly what the tool flagged as "multi-clock fan-in to
//     synchronizer" (e.g. u_packet_commands.u_reset reached 3 different source
//     clocks: clk_pl_0, capture_clk_300m and pcie_user_clk).
//   * EVERY source is synchronised on its own into BOTH wclk (drives the FIFO's
//     single global flush) and rclk (drives the read-side valid gate); only then
//     are they combined.  A reset at either end therefore flushes both ends, as
//     the header has always promised, and no stale word survives a peer restart.
`timescale 1ns/1ps
module sc7f0_dp_fifo #(
    parameter WIDTH=256, DEPTH=16, MEMORY="distributed",
    parameter integer W_SOURCES=1, parameter integer R_SOURCES=1
)(
    input wire wclk, input wire [W_SOURCES-1:0] wrst_n, input wire [WIDTH-1:0] wdata,
    input wire wvalid, output wire wready,
    input wire rclk, input wire [R_SOURCES-1:0] rrst_n, output wire [WIDTH-1:0] rdata,
    output wire rvalid, input wire rready
);
    wire reset, read_reset, w_all_n, r_all_n, full, empty, wb, rb;
    // xpm_fifo_async has ONE global flush input; the vendor model synchronises it
    // into both clocks internally and flushes both ends.  So *every* source must
    // reach both of the local synchronizers here - that is exactly the behaviour
    // this module had at HEAD (`!wrst_n || !rrst_n` on both u_reset and
    // u_read_reset), where losing it silently allowed a word written before a
    // read-side restart to be replayed afterwards (proved by tb/
    // sc7f0_reset_cdc_tb.sv S6, which failed against the vector-per-side form).
    // What changed is only the STRUCTURE: each source crosses into wclk (and,
    // separately, into rclk) through its own xpm_cdc_async_rst, and the AND is
    // formed strictly between already-in-domain flops, so no cross-domain gate
    // ever sits in front of an asynchronous preset (rtl/sc7f0_reset_cdc.v).
    // Assert stays asynchronous in both domains, which is what makes the flush
    // and the VALID inhibition immediate without waiting for a clock edge.
    sc7f0_reset_sync #(.SOURCES(W_SOURCES+R_SOURCES)) u_reset(
        .dest_clk(wclk),.src_rst_n({rrst_n,wrst_n}),.dest_rst_n(w_all_n));
    // rrst_n may contain PCIe link state even when rclk is the PS CSR clock.
    // Never feed that asynchronous release directly into the read CE/VALID.
    sc7f0_reset_sync #(.SOURCES(W_SOURCES+R_SOURCES)) u_read_reset(
        .dest_clk(rclk),.src_rst_n({wrst_n,rrst_n}),.dest_rst_n(r_all_n));
    assign reset=!w_all_n;
    assign read_reset=!r_all_n;
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
