// ============================================================================
// Module: sg_segment_walker
// Description: Hardware Scatter-Gather Segment Walker for Artix-7 A50T.
//              Provides zero-bubble physical address translation for
//              variable-length contiguous memory blocks (Variable SGL).
//
// Features:
//   - Mode 0 (Linear): Seamlessly increments 64-bit address from linear_base_addr.
//   - Mode 1 (Variable SGL): Dynamically tracks physical segment address
//     and remaining segment bytes from a stream of 128-bit SGL entries.
//   - Zero BRAM overhead: Uses a small 64-entry Distributed RAM / LUTRAM FIFO
//     instead of large static Page Table BRAMs, saving 6x RAMB36 on Artix-7.
// ============================================================================

`timescale 1ns / 1ps

module sg_segment_walker #(
    parameter integer FIFO_DEPTH = 16
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Control & Mode Configuration
    input  wire                         start,            // Pulse at start of new frame
    input  wire                         sg_mode,          // 0 = Linear Contiguous, 1 = Variable SGL
    input  wire [63:0]                  linear_base_addr, // 64-bit base address for Mode 0

    // SGL Push Interface (from sg_host_fetch_engine)
    input  wire                         sgl_wr_en,
    input  wire [63:0]                  sgl_wr_addr,      // Segment physical address
    input  wire [31:0]                  sgl_wr_len,       // Segment length in bytes
    input  wire [31:0]                  sgl_wr_flags,     // Segment flags (bit 0: chain, bit 1: last)

    // Burst Advance Interface (from Video Capture Engine)
    input  wire                         advance_burst,    // Pulse when a burst TLP is committed
    input  wire [15:0]                  burst_bytes,      // Bytes in committed burst (e.g. 256, 128)

    // Translated Output Physical Address & Segment Status
    output reg  [63:0]                  current_addr,
    output reg  [31:0]                  seg_bytes_left,
    output wire [5:0]                   fifo_count,
    output wire                         fifo_almost_full,
    output wire                         fifo_empty
);

    localparam ADDR_W = $clog2(FIFO_DEPTH);

    // 64-Entry SGL Segment FIFO (128 bits per entry: addr[63:0], len[31:0], flags[31:0])
    (* ram_style = "distributed" *) reg [127:0] sgl_fifo [0:FIFO_DEPTH-1];
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W-1:0] rd_ptr;
    reg [ADDR_W:0]   count;

    assign fifo_count       = count;
    assign fifo_empty       = (count == 0);
    assign fifo_almost_full = (count >= (FIFO_DEPTH - 4));

    wire [127:0] cur_fifo_entry = sgl_fifo[rd_ptr];
    wire [63:0]  cur_entry_addr  = cur_fifo_entry[63:0];
    wire [31:0]  cur_entry_len   = cur_fifo_entry[95:64];

    // Distributed LUTRAM Write (Synchronous Write, No Reset on RAM Array)
    always @(posedge clk) begin
        if (sgl_wr_en) begin
            sgl_fifo[wr_ptr] <= {sgl_wr_flags, sgl_wr_len, sgl_wr_addr};
        end
    end

    // FIFO Write Pointer Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {ADDR_W{1'b0}};
        end else if (sgl_wr_en) begin
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // FIFO Pop & Address Tracking Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr         <= {ADDR_W{1'b0}};
            count          <= {(ADDR_W+1){1'b0}};
            current_addr   <= 64'd0;
            seg_bytes_left <= 32'd0;
        end else begin
            // Count tracking
            if (sgl_wr_en && (advance_burst && sg_mode && (seg_bytes_left <= burst_bytes) && (count > 1))) begin
                count <= count; // Simultaneous push and pop
            end else if (sgl_wr_en) begin
                count <= count + 1'b1;
            end else if (advance_burst && sg_mode && (seg_bytes_left <= burst_bytes) && (count > 0)) begin
                count <= count - 1'b1;
            end

            if (start) begin
                if (!sg_mode) begin
                    // Linear Mode
                    current_addr   <= linear_base_addr;
                    seg_bytes_left <= 32'hFFFFFFFF;
                end else begin
                    // Variable SGL Mode: Load first segment
                    if (count > 0 || sgl_wr_en) begin
                        current_addr   <= (count > 0) ? cur_entry_addr : sgl_wr_addr;
                        seg_bytes_left <= (count > 0) ? cur_entry_len  : sgl_wr_len;
                        if (count > 0) begin
                            rd_ptr <= rd_ptr + 1'b1;
                            count  <= count - 1'b1;
                        end
                    end
                end
            end else if (advance_burst) begin
                if (!sg_mode) begin
                    // Linear contiguous increment
                    current_addr <= current_addr + burst_bytes;
                end else begin
                    // Variable SGL: Check if current segment completes
                    if (seg_bytes_left > burst_bytes) begin
                        // Stay within current segment
                        current_addr   <= current_addr + burst_bytes;
                        seg_bytes_left <= seg_bytes_left - burst_bytes;
                    end else begin
                        // Advance to next segment in FIFO
                        rd_ptr         <= rd_ptr + 1'b1;
                        current_addr   <= cur_entry_addr;
                        seg_bytes_left <= cur_entry_len;
                    end
                end
            end
        end
    end

endmodule
