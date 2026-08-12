// ============================================================================
// Testbench: tb_h2c_dma_engine
// Description: Unit testbench for h2c_dma_engine module with 2D Multi-Planar & Stride
// ============================================================================

`timescale 1ns / 1ps

module tb_h2c_dma_engine;

    parameter AXI_DATA_WIDTH = 256;
    parameter AXI_ADDR_WIDTH = 64;

    reg                      clk;
    reg                      rst_n;

    reg                      h2c_desc_valid;
    reg [63:0]               h2c_plane0_src, h2c_plane0_dst;
    reg [63:0]               h2c_plane1_src, h2c_plane1_dst;
    reg [63:0]               h2c_plane2_src, h2c_plane2_dst;
    reg [15:0]               h2c_line_width, h2c_line_count;
    reg [15:0]               h2c_src_stride, h2c_dst_stride;
    reg [15:0]               h2c_plane12_width, h2c_plane12_count;
    reg [3:0]                h2c_format, h2c_plane_count;
    reg [15:0]               h2c_desc_ctrl;
    wire                     h2c_desc_ready;

    wire                     tag_alloc_req;
    reg [7:0]                tag_alloc_tag;
    reg                      tag_alloc_valid;

    wire                     h2c_req_valid;
    wire [63:0]              h2c_req_addr;
    wire [10:0]              h2c_req_dw_len;
    wire [7:0]               h2c_req_tag;
    reg                      h2c_req_ack;

    reg                      h2c_fifo_wvalid;
    reg [AXI_DATA_WIDTH-1:0] h2c_fifo_wdata;
    reg                      h2c_fifo_wlast;

    wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    wire [7:0]               m_axi_awlen;
    wire [2:0]               m_axi_awsize;
    wire [1:0]               m_axi_awburst;
    wire                     m_axi_awvalid;
    reg                      m_axi_awready;

    wire [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    wire                     m_axi_wlast;
    wire                     m_axi_wvalid;
    reg                      m_axi_wready;

    reg [1:0]                m_axi_bresp;
    reg                      m_axi_bvalid;
    wire                     m_axi_bready;

    wire                     h2c_busy;
    wire                     h2c_done;
    wire                     h2c_count_inc;

    // Instantiate uut
    h2c_dma_engine #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
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
        .tag_alloc_req(tag_alloc_req),
        .tag_alloc_tag(tag_alloc_tag),
        .tag_alloc_valid(tag_alloc_valid),
        .h2c_req_valid(h2c_req_valid),
        .h2c_req_addr(h2c_req_addr),
        .h2c_req_dw_len(h2c_req_dw_len),
        .h2c_req_tag(h2c_req_tag),
        .h2c_req_ack(h2c_req_ack),
        .h2c_fifo_wvalid(h2c_fifo_wvalid),
        .h2c_fifo_wdata(h2c_fifo_wdata),
        .h2c_fifo_wlast(h2c_fifo_wlast),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .h2c_busy(h2c_busy),
        .h2c_done(h2c_done),
        .h2c_count_inc(h2c_count_inc)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        h2c_desc_valid = 0;
        h2c_plane0_src = 0; h2c_plane0_dst = 0;
        h2c_plane1_src = 0; h2c_plane1_dst = 0;
        h2c_plane2_src = 0; h2c_plane2_dst = 0;
        h2c_line_width = 32; h2c_line_count = 2;
        h2c_src_stride = 64; h2c_dst_stride = 32;
        h2c_plane12_width = 0; h2c_plane12_count = 0;
        h2c_format = 1; h2c_plane_count = 1;
        h2c_desc_ctrl = 0;
        tag_alloc_tag = 8'h02;
        tag_alloc_valid = 0;
        h2c_req_ack = 0;
        h2c_fifo_wvalid = 0;
        h2c_fifo_wdata = 0;
        h2c_fifo_wlast = 0;
        m_axi_awready = 1;
        m_axi_wready = 1;
        m_axi_bresp = 0;
        m_axi_bvalid = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Dispatch H2C 2D Descriptor (Host Src=0x1000, FPGA Dst=0x4000, Width=32, Lines=2, Stride=64)...", $time);
        @(posedge clk);
        h2c_desc_valid <= 1;
        h2c_plane0_src <= 64'h0000_1000;
        h2c_plane0_dst <= 64'h0000_4000;
        h2c_line_width <= 16'd32;
        h2c_line_count <= 16'd2;
        h2c_src_stride <= 16'd64;
        h2c_dst_stride <= 16'd32;

        wait(tag_alloc_req);
        $display("[%0t] H2C Engine requested Tag allocation for Line 0...", $time);
        @(posedge clk);
        tag_alloc_valid <= 1;
        @(posedge clk);
        tag_alloc_valid <= 0;
        h2c_desc_valid  <= 0;

        wait(h2c_req_valid);
        $display("[%0t] H2C Engine requested MRd Line 0 Addr: 0x%h DW Len: %d", $time, h2c_req_addr, h2c_req_dw_len);
        @(posedge clk);
        h2c_req_ack <= 1;
        @(posedge clk);
        h2c_req_ack <= 0;

        #20;
        $display("[%0t] Simulate Host returning Line 0 CplD data...", $time);
        @(posedge clk);
        h2c_fifo_wvalid <= 1;
        h2c_fifo_wdata  <= 256'h11223344_55667788_99AABBCC_DDEEFF00_12345678_87654321_00112233_44556677;
        h2c_fifo_wlast  <= 1;
        @(posedge clk);
        h2c_fifo_wvalid <= 0;

        wait(m_axi_awvalid && m_axi_wvalid);
        $display("[%0t] H2C Engine driving AXI4 Write Line 0! Addr: 0x%h", $time, m_axi_awaddr);

        @(posedge clk);
        m_axi_bvalid <= 1;
        @(posedge clk);
        m_axi_bvalid <= 0;

        #20;
        wait(tag_alloc_req);
        $display("[%0t] H2C Engine requested Tag allocation for Line 1...", $time);
        @(posedge clk);
        tag_alloc_valid <= 1;
        @(posedge clk);
        tag_alloc_valid <= 0;

        wait(h2c_req_valid);
        $display("[%0t] H2C Engine requested MRd Line 1 Addr: 0x%h (Expect 0x1040)", $time, h2c_req_addr);
        @(posedge clk);
        h2c_req_ack <= 1;
        @(posedge clk);
        h2c_req_ack <= 0;

        #20;
        @(posedge clk);
        h2c_fifo_wvalid <= 1;
        h2c_fifo_wdata  <= 256'hA1B2C3D4_E5F67890_11223344_55667788_99AABBCC_DDEEFF00_DEADBEEF_CAFEBABE;
        h2c_fifo_wlast  <= 1;
        @(posedge clk);
        h2c_fifo_wvalid <= 0;

        wait(m_axi_awvalid && m_axi_wvalid);
        $display("[%0t] H2C Engine driving AXI4 Write Line 1! Addr: 0x%h (Expect 0x4020)", $time, m_axi_awaddr);

        @(posedge clk);
        m_axi_bvalid <= 1;
        @(posedge clk);
        m_axi_bvalid <= 0;

        wait(h2c_done);
        $display("[%0t] 2D Multi-Scanline H2C Transfer Complete!", $time);

        #30;
        $display("[%0t] SUCCESS: h2c_dma_engine 2D Test Completed!", $time);
        $finish;
    end

endmodule
