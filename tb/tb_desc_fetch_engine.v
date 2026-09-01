// ============================================================================
// Testbench: tb_desc_fetch_engine
// Description: Unit testbench for desc_fetch_engine module with 64-Byte 2D descriptors
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
    wire idle;

    wire        desc_req_valid;
    wire [63:0] desc_req_addr;
    wire [10:0] desc_req_dw_len;
    wire [7:0]  desc_req_tag;
    reg         desc_req_ack;

    reg         desc_cpl_valid;
    reg [511:0] desc_cpl_data;
    reg         desc_cpl_last;

    wire        h2c_desc_valid;
    wire [63:0] h2c_plane0_src, h2c_plane0_dst;
    wire [63:0] h2c_plane1_src, h2c_plane1_dst;
    wire [63:0] h2c_plane2_src, h2c_plane2_dst;
    wire [15:0] h2c_line_width, h2c_line_count;
    wire [15:0] h2c_src_stride, h2c_dst_stride;
    wire [15:0] h2c_plane12_width, h2c_plane12_count;
    wire [3:0]  h2c_format, h2c_plane_count;
    wire [15:0] h2c_desc_ctrl;
    reg         h2c_desc_ready;

    wire        c2h_desc_valid;
    wire [63:0] c2h_plane0_src, c2h_plane0_dst;
    wire [63:0] c2h_plane1_src, c2h_plane1_dst;
    wire [63:0] c2h_plane2_src, c2h_plane2_dst;
    wire [15:0] c2h_line_width, c2h_line_count;
    wire [15:0] c2h_src_stride, c2h_dst_stride;
    wire [15:0] c2h_plane12_width, c2h_plane12_count;
    wire [3:0]  c2h_format, c2h_plane_count;
    wire [15:0] c2h_desc_ctrl;
    reg         c2h_desc_ready;
    reg         sg_fetch_busy;

    // Instantiate uut
    desc_fetch_engine uut (
        .clk(clk),
        .rst_n(rst_n),
        .dma_run(dma_run),
        .ring_base_addr(ring_base_addr),
        .ring_size(ring_size),
        .tail_ptr(tail_ptr),
        .head_ptr(head_ptr),
        .idle(idle),
        .desc_req_valid(desc_req_valid),
        .desc_req_addr(desc_req_addr),
        .desc_req_dw_len(desc_req_dw_len),
        .desc_req_tag(desc_req_tag),
        .desc_req_ack(desc_req_ack),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_plane0_src(h2c_plane0_src), .h2c_plane0_dst(h2c_plane0_dst),
        .h2c_plane1_src(h2c_plane1_src), .h2c_plane1_dst(h2c_plane1_dst),
        .h2c_plane2_src(h2c_plane2_src), .h2c_plane2_dst(h2c_plane2_dst),
        .h2c_line_width(h2c_line_width), .h2c_line_count(h2c_line_count),
        .h2c_src_stride(h2c_src_stride), .h2c_dst_stride(h2c_dst_stride),
        .h2c_plane12_width(h2c_plane12_width), .h2c_plane12_count(h2c_plane12_count),
        .h2c_format(h2c_format), .h2c_plane_count(h2c_plane_count),
        .h2c_desc_ctrl(h2c_desc_ctrl),
        .h2c_desc_ready(h2c_desc_ready),
        .c2h_desc_valid(c2h_desc_valid),
        .c2h_plane0_src(c2h_plane0_src), .c2h_plane0_dst(c2h_plane0_dst),
        .c2h_plane1_src(c2h_plane1_src), .c2h_plane1_dst(c2h_plane1_dst),
        .c2h_plane2_src(c2h_plane2_src), .c2h_plane2_dst(c2h_plane2_dst),
        .c2h_line_width(c2h_line_width), .c2h_line_count(c2h_line_count),
        .c2h_src_stride(c2h_src_stride), .c2h_dst_stride(c2h_dst_stride),
        .c2h_plane12_width(c2h_plane12_width), .c2h_plane12_count(c2h_plane12_count),
        .c2h_format(c2h_format), .c2h_plane_count(c2h_plane_count),
        .c2h_desc_ctrl(c2h_desc_ctrl),
        .c2h_desc_ready(c2h_desc_ready),
        .sg_fetch_busy(sg_fetch_busy)
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
        sg_fetch_busy = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Update Tail Pointer to 1, trigger 64-Byte Extended Descriptor Fetch...", $time);
        @(posedge clk);
        dma_run  <= 1;
        tail_ptr <= 16'd1;

        wait(desc_req_valid);
        $display("[%0t] Desc Fetch Engine requested MRd Addr: 0x%h DW Len: %d", $time, desc_req_addr, desc_req_dw_len);

        @(posedge clk);
        desc_req_ack <= 1;
        @(posedge clk);
        desc_req_ack <= 0;

        #20;
        $display("[%0t] Return CplD 64-Byte 2D Multi-Planar YUV420P Descriptor payload...", $time);
        @(posedge clk);
        desc_cpl_valid <= 1;
        desc_cpl_last  <= 1;
        desc_cpl_data[63:0]    <= 64'h0000_1000; // Plane 0 Src (Y)
        desc_cpl_data[127:64]  <= 64'h0000_4000; // Plane 0 Dst (Y)
        desc_cpl_data[191:128] <= 64'h0000_2000; // Plane 1 Src (U)
        desc_cpl_data[255:192] <= 64'h0000_5000; // Plane 1 Dst (U)
        desc_cpl_data[319:256] <= 64'h0000_3000; // Plane 2 Src (V)
        desc_cpl_data[383:320] <= 64'h0000_6000; // Plane 2 Dst (V)
        desc_cpl_data[399:384] <= 16'd1920;      // Line Width = 1920 Bytes
        desc_cpl_data[415:400] <= 16'd1080;      // Line Count = 1080 Lines
        desc_cpl_data[431:416] <= 16'd2048;      // Src Stride = 2048 Bytes
        desc_cpl_data[447:432] <= 16'd1920;      // Dst Stride = 1920 Bytes
        desc_cpl_data[483:480] <= 4'h3;          // Format = 0x3 (YUV420P)
        desc_cpl_data[487:484] <= 4'h3;          // Plane Count = 3
        desc_cpl_data[495:488] <= 8'h01;         // Control: Valid=1, Dir=0 (H2C)

        @(posedge clk);
        desc_cpl_valid <= 0;

        wait(h2c_desc_valid);
        $display("[%0t] Extended 2D Descriptor dispatched to H2C Engine!", $time);
        $display("       Plane 0 Y Src=0x%h, Dst=0x%h Width=%d Height=%d Stride=%d Format=%d Planes=%d",
                 h2c_plane0_src, h2c_plane0_dst, h2c_line_width, h2c_line_count, h2c_src_stride, h2c_format, h2c_plane_count);
        
        @(posedge clk);
        h2c_desc_ready <= 1;
        @(posedge clk);
        h2c_desc_ready <= 0;

        #30;
        $display("[%0t] Head Pointer updated to: %d", $time, head_ptr);
        if (head_ptr !== 16'd1)
            $fatal(1, "FAIL: First descriptor did not advance head to 1");

        $display("[%0t] Test 2: Queue two C2H SG descriptors...", $time);
        tail_ptr <= 16'd3;

        wait(desc_req_valid);
        if (desc_req_addr !== ring_base_addr + 64)
            $fatal(1, "FAIL: SG descriptor 1 address mismatch: %h", desc_req_addr);
        @(posedge clk);
        desc_req_ack <= 1;
        @(posedge clk);
        desc_req_ack <= 0;

        @(posedge clk);
        desc_cpl_data <= 512'd0;
        desc_cpl_data[127:64]  <= 64'h0000_0002_0000_0000;
        desc_cpl_data[255:192] <= 64'h0000_0002_0000_1000;
        desc_cpl_data[399:384] <= 16'd1920;
        desc_cpl_data[415:400] <= 16'd1080;
        desc_cpl_data[447:432] <= 16'd1920;
        desc_cpl_data[483:480] <= 4'd2;
        desc_cpl_data[487:484] <= 4'd2;
        desc_cpl_data[503:488] <= 16'h002B;
        desc_cpl_valid <= 1;
        desc_cpl_last  <= 1;
        @(posedge clk);
        desc_cpl_valid <= 0;

        wait(c2h_desc_valid);
        sg_fetch_busy <= 1;
        c2h_desc_ready <= 1;
        @(posedge clk);
        c2h_desc_ready <= 0;
        repeat (5) @(posedge clk);
        if (head_ptr !== 16'd1)
            $fatal(1, "FAIL: Head advanced while descriptor 1 SGL fetch was busy");
        sg_fetch_busy <= 0;
        wait(head_ptr == 16'd2);

        wait(desc_req_valid);
        if (desc_req_addr !== ring_base_addr + 128)
            $fatal(1, "FAIL: SG descriptor 2 address mismatch: %h", desc_req_addr);
        @(posedge clk);
        desc_req_ack <= 1;
        @(posedge clk);
        desc_req_ack <= 0;

        @(posedge clk);
        desc_cpl_data[127:64]  <= 64'h0000_0003_0000_0000;
        desc_cpl_data[255:192] <= 64'h0000_0003_0000_1000;
        desc_cpl_valid <= 1;
        @(posedge clk);
        desc_cpl_valid <= 0;

        wait(c2h_desc_valid);
        if (c2h_plane0_dst !== 64'h0000_0003_0000_0000)
            $fatal(1, "FAIL: SG descriptor 2 payload mismatch: %h", c2h_plane0_dst);
        sg_fetch_busy <= 1;
        c2h_desc_ready <= 1;
        @(posedge clk);
        c2h_desc_ready <= 0;
        repeat (5) @(posedge clk);
        if (head_ptr !== 16'd2)
            $fatal(1, "FAIL: Head advanced while descriptor 2 SGL fetch was busy");
        sg_fetch_busy <= 0;
        wait(head_ptr == 16'd3);

        $display("[%0t] SUCCESS: Two queued C2H SG descriptors completed in order!", $time);
        $finish;
    end

endmodule
