// ============================================================================
// xpm_fifo_async_sim.v
//
// Behavioral (simulation-only) replacement for the Xilinx XPM xpm_fifo_async
// primitive. Written in plain Verilog-2001 so it compiles under Icarus
// Verilog. Implements the standard gray-code dual-clock FIFO architecture:
//   * write/read pointers as binary + gray, synchronized across domains with
//     CDC_SYNC_STAGES 2-ff synchronizers
//   * full / empty via the gray-code MSB compare conditions
//   * fwft read mode (dout combinational from the read pointer)
//   * wr_data_count / rd_data_count, almost_full / almost_empty,
//     prog_full / prog_empty
//
// NOT SYNTHESIZABLE - use the real XPM library for implementation.
//
// Port set matches every xpm_fifo_async instance in custom_pcie_dma_top.v and
// video_req_cdc.v (FIFO_WRITE_DEPTH 64/512, 128/130-bit, fwft).
// ============================================================================

module xpm_fifo_async #(
    parameter string      FIFO_MEMORY_TYPE   = "auto",
    parameter integer     ECC_MODE           = "no_ecc",
    parameter integer     FIFO_WRITE_DEPTH   = 512,
    parameter integer     WRITE_DATA_WIDTH   = 32,
    parameter integer     WR_DATA_COUNT_WIDTH = 0,
    parameter integer     PROG_FULL_THRESH   = 10,
    parameter integer     FULL_RESET_VALUE   = 0,
    parameter string      USE_ADV_FEATURES   = "0000",
    parameter string      READ_MODE          = "std",
    parameter integer     FIFO_READ_LATENCY  = 0,
    parameter integer     READ_DATA_WIDTH    = 32,
    parameter integer     RD_DATA_COUNT_WIDTH = 0,
    parameter integer     PROG_EMPTY_THRESH  = 10,
    parameter string      DOUT_RESET_VALUE   = "0",
    parameter integer     CDC_SYNC_STAGES    = 2,
    parameter integer     WAKEUP_TIME        = 0
)(
    input  wire                             rst,
    input  wire                             wr_clk,
    input  wire                             wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0]      din,
    output wire                             full,
    output wire                             wr_rst_busy,
    input  wire                             rd_clk,
    input  wire                             rd_en,
    output wire [READ_DATA_WIDTH-1:0]       dout,
    output wire                             empty,
    output wire                             rd_rst_busy,
    input  wire                             sleep,
    input  wire                             injectsbiterr,
    input  wire                             injectdbiterr,
    output wire                             sbiterr,
    output wire                             dbiterr,
    output wire                             almost_full,
    output wire                             prog_full,
    output wire [WDCW-1:0]                  wr_data_count,
    output wire                             almost_empty,
    output wire                             prog_empty,
    output wire [RDCW-1:0]                  rd_data_count
);

    function integer clog2;
        input integer n;
        integer i;
        begin
            clog2 = 0;
            for (i = n - 1; i > 0; i = i >> 1)
                clog2 = clog2 + 1;
        end
    endfunction

    function [PTR_W-1:0] g2b;   // gray -> binary
        input [PTR_W-1:0] g;
        integer i;
        begin
            g2b = g;
            for (i = PTR_W - 2; i >= 0; i = i - 1)
                g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    localparam integer DEPTH_BITS = clog2(FIFO_WRITE_DEPTH);
    localparam integer PTR_W      = DEPTH_BITS + 1;
    localparam integer WDCW       = (WR_DATA_COUNT_WIDTH > 0) ? WR_DATA_COUNT_WIDTH : PTR_W;
    localparam integer RDCW       = (RD_DATA_COUNT_WIDTH > 0) ? RD_DATA_COUNT_WIDTH : PTR_W;

    reg [PTR_W-1:0]            wq;             // binary write pointer
    reg [PTR_W-1:0]            rq;             // binary read pointer
    reg [PTR_W-1:0]            wg_sync [0:CDC_SYNC_STAGES-1];  // gray wr ptr synced into rd domain
    reg [PTR_W-1:0]            rg_sync [0:CDC_SYNC_STAGES-1];  // gray rd ptr synced into wr domain
    reg [READ_DATA_WIDTH-1:0]  mem [0:FIFO_WRITE_DEPTH-1];

    wire [PTR_W-1:0] wg = wq ^ (wq >> 1);
    wire [PTR_W-1:0] rg = rq ^ (rq >> 1);
    wire [PTR_W-1:0] wg_s = wg_sync[CDC_SYNC_STAGES-1];
    wire [PTR_W-1:0] rg_s = rg_sync[CDC_SYNC_STAGES-1];

    // full / empty are derived from the hypothetical next pointers so the
    // write/read increment gating (wr_en && !full, rd_en && !empty) does not
    // create combinational loops.
    wire [PTR_W-1:0] wq1      = wq + 1'b1;
    wire [PTR_W-1:0] wq1_gray = wq1 ^ (wq1 >> 1);
    assign full  = (wq1_gray == {~rg_s[PTR_W-1:PTR_W-2], rg_s[PTR_W-3:0]});
    assign empty = (rg == wg_s);

    wire [PTR_W-1:0] wnext_bin = wq + ((wr_en && !full) ? 1'b1 : 1'b0);
    wire [PTR_W-1:0] rnext_bin = rq + ((rd_en && !empty) ? 1'b1 : 1'b0);

    always @(posedge wr_clk or posedge rst) begin
        if (rst)          wq <= {PTR_W{1'b0}};
        else              wq <= wnext_bin;
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst)          rq <= {PTR_W{1'b0}};
        else              rq <= rnext_bin;
    end

    genvar gi;
    generate
        for (gi = 0; gi < CDC_SYNC_STAGES; gi = gi + 1) begin : wg_syncu
            if (gi == 0)
                always @(posedge rd_clk or posedge rst)
                    if (rst) wg_sync[0] <= {PTR_W{1'b0}};
                    else     wg_sync[0] <= wg;
            else
                always @(posedge rd_clk or posedge rst)
                    if (rst) wg_sync[gi] <= {PTR_W{1'b0}};
                    else     wg_sync[gi] <= wg_sync[gi-1];
        end
        for (gi = 0; gi < CDC_SYNC_STAGES; gi = gi + 1) begin : rg_syncu
            if (gi == 0)
                always @(posedge wr_clk or posedge rst)
                    if (rst) rg_sync[0] <= {PTR_W{1'b0}};
                    else     rg_sync[0] <= rg;
            else
                always @(posedge wr_clk or posedge rst)
                    if (rst) rg_sync[gi] <= {PTR_W{1'b0}};
                    else     rg_sync[gi] <= rg_sync[gi-1];
        end
    endgenerate

    always @(posedge wr_clk)
        if (wr_en && !full)
            mem[wq[DEPTH_BITS-1:0]] <= din;

    wire [PTR_W-1:0] wr_count = wq - g2b(rg_s);
    wire [PTR_W-1:0] rd_count = g2b(wg_s) - rq;

    assign dout         = empty ? {READ_DATA_WIDTH{1'b0}} : mem[rq[DEPTH_BITS-1:0]];
    assign wr_rst_busy  = 1'b0;
    assign rd_rst_busy  = 1'b0;
    assign sbiterr      = 1'b0;
    assign dbiterr      = 1'b0;
    assign almost_full  = (wr_count >= FIFO_WRITE_DEPTH - 1);
    assign prog_full    = (wr_count >= PROG_FULL_THRESH);
    assign almost_empty = (rd_count <= 1);
    assign prog_empty   = (rd_count <= PROG_EMPTY_THRESH);
    assign wr_data_count = wr_count[WDCW-1:0];
    assign rd_data_count = rd_count[RDCW-1:0];

endmodule