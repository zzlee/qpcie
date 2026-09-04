// ============================================================================
// Module: audio_h2c_fifo
// Description: Synchronous Block RAM FIFO for Audio Playback (H2C MMIO to Audio Stream).
//              Utilizes Xilinx XPM_FIFO_SYNC primitive configured for Block RAM (RAMB18)
//              with First-Word Fall-Through (FWFT) mode to minimize Slice LUT utilization.
// ============================================================================

`timescale 1ns / 1ps

module audio_h2c_fifo #(
    parameter DEPTH = 512
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,

    // MMIO Write Interface
    input  wire [31:0] wr_data,
    input  wire        wr_en,
    output wire        full,
    output wire [7:0]  count,
    output wire        empty,

    // AXI4-Stream Master Interface
    input  wire        rd_en,
    output wire [31:0] rd_data,
    output wire        rd_valid
);

    wire [9:0] wr_data_count;
    wire       fifo_rst = (!rst_n) || flush;
    wire       fifo_empty;
    wire       fifo_full;

    assign full     = fifo_full;
    assign empty    = fifo_empty;
    assign rd_valid = !fifo_empty;
    assign count    = (wr_data_count > 10'd255) ? 8'd255 : wr_data_count[7:0];

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_WRITE_DEPTH    (512),
        .WRITE_DATA_WIDTH    (32),
        .READ_DATA_WIDTH     (32),
        .READ_MODE           ("fwft"),
        .FIFO_READ_LATENCY   (0),
        .WR_DATA_COUNT_WIDTH (10),
        .RD_DATA_COUNT_WIDTH (10),
        .USE_ADV_FEATURES    ("0707")
    ) u_fifo (
        .sleep         (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (clk),
        .wr_en         (wr_en && !fifo_full),
        .din           (wr_data),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (wr_data_count),
        .overflow      (),
        .wr_rst_busy   (),
        .almost_full   (),
        .wr_ack        (),

        .rd_en         (rd_en && !fifo_empty),
        .dout          (rd_data),
        .empty         (fifo_empty),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .rd_rst_busy   (),
        .almost_empty  (),
        .data_valid    (),

        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .sbiterr       (),
        .dbiterr       ()
    );

endmodule
