// Coherent, continuous telemetry snapshots. Samples may be skipped; never use
// this transport for pulses or commands. Convert pulse telemetry to counters
// in the source domain before packing it into src_status.
`timescale 1ns / 1ps
module qpcie_status_cdc #(
    parameter integer WIDTH = 32
)(
    input wire src_clk, src_rst_n,
    input wire dest_clk, dest_rst_n, dest_online,
    input wire [WIDTH-1:0] src_status,
    output reg [WIDTH-1:0] dest_status,
    output reg dest_valid
);
    wire full, empty, wr_busy, rd_busy;
    wire [WIDTH-1:0] fifo_data;
    wire dest_ready_src;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(3), .RST_ACTIVE_HIGH(0)) u_fifo_reset (
        .src_arst(dest_rst_n), .dest_clk(src_clk), .dest_arst(dest_ready_src)
    );
    // XPM FIFO reset is synchronous to its write clock on release. Do not
    // combine two clock domains before the reset synchronizer.
    wire fifo_reset = !dest_ready_src || !src_rst_n;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(16),
        .WRITE_DATA_WIDTH(WIDTH), .READ_DATA_WIDTH(WIDTH),
        .CDC_SYNC_STAGES(3), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES("0000"), .SIM_ASSERT_CHK(1)
    ) u_fifo (
        .rst(fifo_reset),
        .wr_clk(src_clk), .wr_en(!fifo_reset && !wr_busy && !full), .din(src_status),
        .full(full), .wr_rst_busy(wr_busy),
        .rd_clk(dest_clk), .rd_en(dest_rst_n && dest_online && !rd_busy && !empty), .dout(fifo_data),
        .empty(empty), .rd_rst_busy(rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );
    always @(posedge dest_clk or negedge dest_rst_n) begin
        if (!dest_rst_n) begin
            dest_status <= {WIDTH{1'b0}};
            dest_valid <= 1'b0;
        end else if (!dest_online) begin
            dest_status <= {WIDTH{1'b0}};
            dest_valid <= 1'b0;
        end else if (!rd_busy && !empty) begin
            dest_status <= fifo_data;
            dest_valid <= 1'b1;
        end
    end
endmodule
