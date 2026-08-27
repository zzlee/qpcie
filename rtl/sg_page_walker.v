// ============================================================================
// Module: sg_page_walker
// Description: Hardware Scatter-Gather Page Table Walker for Artix-7 A50T.
//              Provides zero-bubble physical address translation for video DMA.
//
// Features:
//   - Mode 0 (Linear): Seamlessly increments 64-bit address from base_addr.
//   - Mode 1 (Scatter-Gather): Automatically traverses 4KB physical pages
//     stored in the on-chip Page Table RAM.
//   - Zero-Cycle Page Switch: Page table entry for next page is fetched in advance,
//     ensuring zero-bubble back-to-back TLP streaming across 4KB page boundaries.
// ============================================================================

`timescale 1ns / 1ps

module sg_page_walker #(
    parameter integer MAX_PAGES = 2048,                 // Up to 2048 x 4KB pages = 8MB per plane (supports 4K UHD)
    parameter integer PAGE_SIZE_BYTES = 4096            // Standard 4KB Linux physical page
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Control & Mode Configuration
    input  wire                         start,          // Pulse at start of new frame
    input  wire                         sg_mode,        // 0 = Linear Contiguous, 1 = Scatter-Gather Page Table
    input  wire [63:0]                  linear_base_addr, // 64-bit base address for Mode 0

    // Host / DMA Page Table Write Interface (Port A)
    input  wire                         pt_wr_en,
    input  wire [$clog2(MAX_PAGES)-1:0] pt_wr_addr,
    input  wire [63:0]                  pt_wr_data,

    // Burst Advance Interface (from Video Capture Engine)
    input  wire                         advance_burst,  // Pulse when a burst TLP is committed
    input  wire [15:0]                  burst_bytes,    // Bytes in committed burst (e.g. 256 or 128)

    // Translated Output Physical Address to Requester
    output reg  [63:0]                  current_addr,
    output reg  [$clog2(MAX_PAGES)-1:0] current_page_idx,
    output reg  [11:0]                  current_page_offset,
    output wire                         page_boundary_next
);
    localparam integer ADDR_WIDTH = $clog2(MAX_PAGES);

    // Dual-Port Page Table RAM (Distributed / Block RAM)
    (* ram_style = "distributed" *)
    reg [63:0] page_table [0:MAX_PAGES-1];

    // Port A: Write from host / MMIO / prefetch
    always @(posedge clk) begin
        if (pt_wr_en)
            page_table[pt_wr_addr] <= pt_wr_data;
    end

    // Port B: Fast Read for Page Walker
    wire [63:0] curr_page_base = page_table[current_page_idx];
    wire [63:0] next_page_base = page_table[current_page_idx + 1'b1];

    // Page boundary warning: remaining room in current page is less than 256 bytes
    assign page_boundary_next = (current_page_offset >= (PAGE_SIZE_BYTES - 256));

    reg [63:0] linear_addr_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_addr        <= 64'd0;
            current_page_idx    <= {ADDR_WIDTH{1'b0}};
            current_page_offset <= 12'd0;
            linear_addr_q       <= 64'd0;
        end else if (start) begin
            current_page_idx    <= {ADDR_WIDTH{1'b0}};
            current_page_offset <= 12'd0;
            linear_addr_q       <= linear_base_addr;
            current_addr        <= sg_mode ? page_table[0] : linear_base_addr;
        end else if (advance_burst) begin
            if (!sg_mode) begin
                // Linear Mode: Standard contiguous increment
                linear_addr_q <= linear_addr_q + burst_bytes;
                current_addr  <= linear_addr_q + burst_bytes;
            end else begin
                // Scatter-Gather Mode: 4KB Page boundary handling
                if ((current_page_offset + burst_bytes) >= PAGE_SIZE_BYTES) begin
                    // Advance to the next 4KB physical page
                    current_page_idx    <= current_page_idx + 1'b1;
                    current_page_offset <= 12'd0;
                    current_addr        <= next_page_base;
                end else begin
                    // Stay within current 4KB page
                    current_page_offset <= current_page_offset + burst_bytes[11:0];
                    current_addr        <= curr_page_base + (current_page_offset + burst_bytes[11:0]);
                end
            end
        end
    end

endmodule
