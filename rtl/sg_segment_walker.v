// ============================================================================
// Module: sg_segment_walker
// Description: Hardware Scatter-Gather Segment Walker for Artix-7 A50T.
// ============================================================================
`timescale 1ns / 1ps

module sg_segment_walker #(
    parameter integer FIFO_DEPTH = 64,
    parameter integer MIN_BURST_BYTES = 128
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    input  wire                         sg_mode,
    input  wire [63:0]                  linear_base_addr,
    input  wire                         sgl_wr_en,
    input  wire [63:0]                  sgl_wr_addr,
    input  wire [31:0]                  sgl_wr_len,
    input  wire [31:0]                  sgl_wr_flags,
    input  wire                         advance_burst,
    input  wire [15:0]                  burst_bytes,
    output reg  [63:0]                  current_addr,
    output reg  [31:0]                  seg_bytes_left,
    output reg                          seg_valid,
    output wire [6:0]                   fifo_count,
    output wire                         fifo_almost_full,
    output wire                         fifo_empty
);
    localparam ADDR_W = $clog2(FIFO_DEPTH);

    (* ram_style = "distributed" *) reg [127:0] sgl_fifo [0:FIFO_DEPTH-1];
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W-1:0] rd_ptr;
    reg [ADDR_W:0]   count;

    wire [127:0] cur_fifo_entry = sgl_fifo[rd_ptr];
    wire [63:0]  cur_entry_addr = cur_fifo_entry[63:0];
    wire [31:0]  cur_entry_len  = cur_fifo_entry[95:64];

    assign fifo_count       = count;
    assign fifo_empty       = (count == 0);
    assign fifo_almost_full = (count >= (FIFO_DEPTH - 20));

    // The C2H packetizer uses a minimum 128-byte payload. Never advertise an
    // SGL segment that cannot contain one complete payload or a payload whose
    // current physical address is too close to a 4-KiB boundary.
    wire page_has_min_burst = (current_addr[11:0] <= (12'h1000 - MIN_BURST_BYTES));
    wire segment_has_min_burst = (seg_bytes_left >= MIN_BURST_BYTES);
    wire burst_contract_ok = !advance_burst ||
                             ((burst_bytes != 0) &&
                              (burst_bytes <= seg_bytes_left) &&
                              (({52'd0,current_addr[11:0]} + burst_bytes) <= 12'h1000));

    always @(posedge clk) begin
        if (sgl_wr_en)
            sgl_fifo[wr_ptr] <= {sgl_wr_flags, sgl_wr_len, sgl_wr_addr};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr         <= {ADDR_W{1'b0}};
            rd_ptr         <= {ADDR_W{1'b0}};
            count          <= {(ADDR_W+1){1'b0}};
            current_addr   <= 64'd0;
            seg_bytes_left <= 32'd0;
            seg_valid      <= 1'b0;
        end else if (start) begin
            wr_ptr <= {ADDR_W{1'b0}};
            rd_ptr <= {ADDR_W{1'b0}};
            count  <= {(ADDR_W+1){1'b0}};
            if (!sg_mode) begin
                current_addr   <= linear_base_addr;
                seg_bytes_left <= 32'hFFFFFFFF;
                seg_valid      <= 1'b1;
            end else begin
                current_addr   <= 64'd0;
                seg_bytes_left <= 32'd0;
                seg_valid      <= 1'b0;
            end
        end else if (!sg_mode) begin
            if (advance_burst && burst_contract_ok)
                current_addr <= current_addr + burst_bytes;
        end else begin
            if (sgl_wr_en)
                wr_ptr <= wr_ptr + 1'b1;

            if (!seg_valid || seg_bytes_left == 0) begin
                if (count > 0) begin
                    current_addr   <= cur_entry_addr;
                    seg_bytes_left <= cur_entry_len;
                    rd_ptr         <= rd_ptr + 1'b1;
                    count          <= sgl_wr_en ? count : (count - 1'b1);
                    seg_valid      <= (cur_entry_len >= MIN_BURST_BYTES) &&
                                      (cur_entry_addr[11:0] <= (12'h1000 - MIN_BURST_BYTES));
                end else if (sgl_wr_en) begin
                    current_addr   <= sgl_wr_addr;
                    seg_bytes_left <= sgl_wr_len;
                    seg_valid      <= (sgl_wr_len >= MIN_BURST_BYTES) &&
                                      (sgl_wr_addr[11:0] <= (12'h1000 - MIN_BURST_BYTES));
                end else begin
                    seg_valid <= 1'b0;
                end
            end else if (advance_burst) begin
                // A committed request must never consume beyond either the
                // physical SGL segment or the PCIe 4-KiB address boundary.
                if (burst_contract_ok) begin
                    if (seg_bytes_left > burst_bytes) begin
                        current_addr   <= current_addr + burst_bytes;
                        seg_bytes_left <= seg_bytes_left - burst_bytes;
                        count          <= sgl_wr_en ? (count + 1'b1) : count;
                        seg_valid      <= (seg_bytes_left - burst_bytes >= MIN_BURST_BYTES) &&
                                          ((current_addr[11:0] + burst_bytes) <= (12'h1000 - MIN_BURST_BYTES));
                    end else if (count > 0) begin
                        current_addr   <= cur_entry_addr;
                        seg_bytes_left <= cur_entry_len;
                        rd_ptr         <= rd_ptr + 1'b1;
                        count          <= sgl_wr_en ? count : (count - 1'b1);
                        seg_valid      <= (cur_entry_len >= MIN_BURST_BYTES) &&
                                          (cur_entry_addr[11:0] <= (12'h1000 - MIN_BURST_BYTES));
                    end else if (sgl_wr_en) begin
                        current_addr   <= sgl_wr_addr;
                        seg_bytes_left <= sgl_wr_len;
                        seg_valid      <= (sgl_wr_len >= MIN_BURST_BYTES) &&
                                          (sgl_wr_addr[11:0] <= (12'h1000 - MIN_BURST_BYTES));
                    end else begin
                        current_addr   <= 64'd0;
                        seg_bytes_left <= 32'd0;
                        seg_valid      <= 1'b0;
                    end
                end else begin
                    // Fail closed. Do not silently skip the remainder of an
                    // SGL segment when the packetizer violates the contract.
                    seg_valid <= 1'b0;
                end
            end else begin
                count <= sgl_wr_en ? (count + 1'b1) : count;
                if (!segment_has_min_burst || !page_has_min_burst)
                    seg_valid <= 1'b0;
            end
        end
    end
endmodule
