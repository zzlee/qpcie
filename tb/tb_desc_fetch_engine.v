// ============================================================================
// Testbench: tb_desc_fetch_engine
// Description: Unit testbench for desc_fetch_engine module
// ============================================================================

`timescale 1ns / 1ps

module tb_desc_fetch_engine;

    reg        clk;
    reg        rst_n;

    reg        dma_run;
    reg [63:0] ring_base_addr;
    reg [15:0] ring_size;
    reg [15:0] tail_ptr;
    wire [15:0] head_ptr;

    wire        desc_req_valid;
    wire [63:0] desc_req_addr;
    wire [10:0] desc_req_dw_len;
    wire [7:0]  desc_req_tag;
    reg         desc_req_ack;

    reg         desc_cpl_valid;
    reg [159:0] desc_cpl_data;
    reg         desc_cpl_last;

    wire        h2c_desc_valid;
    wire [63:0] h2c_desc_src_addr;
    wire [63:0] h2c_desc_dst_addr;
    wire [31:0] h2c_desc_len;
    wire [31:0] h2c_desc_ctrl;
    reg         h2c_desc_ready;

    wire        c2h_desc_valid;
    wire [63:0] c2h_desc_src_addr;
    wire [63:0] c2h_desc_dst_addr;
    wire [31:0] c2h_desc_len;
    wire [31:0] c2h_desc_ctrl;
    reg         c2h_desc_ready;

    // Instantiate uut
    desc_fetch_engine uut (
        .clk(clk),
        .rst_n(rst_n),
        .dma_run(dma_run),
        .ring_base_addr(ring_base_addr),
        .ring_size(ring_size),
        .tail_ptr(tail_ptr),
        .head_ptr(head_ptr),
        .desc_req_valid(desc_req_valid),
        .desc_req_addr(desc_req_addr),
        .desc_req_dw_len(desc_req_dw_len),
        .desc_req_tag(desc_req_tag),
        .desc_req_ack(desc_req_ack),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_desc_src_addr(h2c_desc_src_addr),
        .h2c_desc_dst_addr(h2c_desc_dst_addr),
        .h2c_desc_len(h2c_desc_len),
        .h2c_desc_ctrl(h2c_desc_ctrl),
        .h2c_desc_ready(h2c_desc_ready),
        .c2h_desc_valid(c2h_desc_valid),
        .c2h_desc_src_addr(c2h_desc_src_addr),
        .c2h_desc_dst_addr(c2h_desc_dst_addr),
        .c2h_desc_len(c2h_desc_len),
        .c2h_desc_ctrl(c2h_desc_ctrl),
        .c2h_desc_ready(c2h_desc_ready)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        dma_run = 0;
        ring_base_addr = 64'h8000_0000;
        ring_size = 16'd4;
        tail_ptr = 16'd0;
        desc_req_ack = 0;
        desc_cpl_valid = 0;
        desc_cpl_data = 0;
        desc_cpl_last = 0;
        h2c_desc_ready = 0;
        c2h_desc_ready = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Update Tail Pointer to 1, trigger Descriptor Fetch...", $time);
        @(posedge clk);
        dma_run  <= 1;
        tail_ptr <= 16'd1;

        wait(desc_req_valid);
        $display("[%0t] Desc Fetch Engine requested MRd Addr: 0x%h", $time, desc_req_addr);

        @(posedge clk);
        desc_req_ack <= 1;
        @(posedge clk);
        desc_req_ack <= 0;

        #20;
        $display("[%0t] Return CplD Descriptor payload (Host Src=0x1000, FPGA Dst=0x4000, Len=1024)...", $time);
        @(posedge clk);
        desc_cpl_valid <= 1;
        desc_cpl_last  <= 1;
        // Src=0x1000 (even -> H2C), Dst=0x4000, Len=1024
        desc_cpl_data[63:0]    <= 64'h0000_1000;
        desc_cpl_data[127:64]  <= 64'h0000_4000;
        desc_cpl_data[159:128] <= 32'd1024;

        @(posedge clk);
        desc_cpl_valid <= 0;

        wait(h2c_desc_valid);
        $display("[%0t] Descriptor successfully dispatched to H2C Engine! Src=0x%h, Dst=0x%h, Len=%d",
                 $time, h2c_desc_src_addr, h2c_desc_dst_addr, h2c_desc_len);
        @(posedge clk);
        h2c_desc_ready <= 1;
        @(posedge clk);
        h2c_desc_ready <= 0;

        #30;
        $display("[%0t] Head Pointer updated to: %d", $time, head_ptr);
        $display("[%0t] SUCCESS: desc_fetch_engine Test Completed!", $time);
        $finish;
    end

endmodule
