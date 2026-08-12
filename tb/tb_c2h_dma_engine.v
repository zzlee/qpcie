// ============================================================================
// Testbench: tb_c2h_dma_engine
// Description: Unit testbench for c2h_dma_engine module with 2D Multi-Planar & Stride
// ============================================================================

`timescale 1ns / 1ps

module tb_c2h_dma_engine;

    parameter AXI_DATA_WIDTH = 256;
    parameter AXI_ADDR_WIDTH = 64;

    reg                      clk;
    reg                      rst_n;

    reg                      c2h_desc_valid;
    reg [63:0]               c2h_plane0_src, c2h_plane0_dst;
    reg [63:0]               c2h_plane1_src, c2h_plane1_dst;
    reg [63:0]               c2h_plane2_src, c2h_plane2_dst;
    reg [15:0]               c2h_line_width, c2h_line_count;
    reg [15:0]               c2h_src_stride, c2h_dst_stride;
    reg [15:0]               c2h_plane12_width, c2h_plane12_count;
    reg [3:0]                c2h_format, c2h_plane_count;
    reg [15:0]               c2h_desc_ctrl;
    wire                     c2h_desc_ready;

    wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    wire [7:0]               m_axi_arlen;
    wire [2:0]               m_axi_arsize;
    wire [1:0]               m_axi_arburst;
    wire                     m_axi_arvalid;
    reg                      m_axi_arready;

    reg [AXI_DATA_WIDTH-1:0] m_axi_rdata;
    reg [1:0]                m_axi_rresp;
    reg                      m_axi_rlast;
    reg                      m_axi_rvalid;
    wire                     m_axi_rready;

    wire                     c2h_req_valid;
    wire [63:0]              c2h_req_addr;
    wire [10:0]              c2h_req_dw_len;
    wire [AXI_DATA_WIDTH-1:0] c2h_req_data;
    wire                     c2h_req_last;
    reg                      c2h_req_ack;

    wire                     c2h_busy;
    wire                     c2h_done;
    wire                     c2h_count_inc;

    // Instantiate uut
    c2h_dma_engine #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
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
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .c2h_req_valid(c2h_req_valid),
        .c2h_req_addr(c2h_req_addr),
        .c2h_req_dw_len(c2h_req_dw_len),
        .c2h_req_data(c2h_req_data),
        .c2h_req_last(c2h_req_last),
        .c2h_req_ack(c2h_req_ack),
        .c2h_busy(c2h_busy),
        .c2h_done(c2h_done),
        .c2h_count_inc(c2h_count_inc)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        c2h_desc_valid = 0;
        c2h_plane0_src = 0; c2h_plane0_dst = 0;
        c2h_plane1_src = 0; c2h_plane1_dst = 0;
        c2h_plane2_src = 0; c2h_plane2_dst = 0;
        c2h_line_width = 32; c2h_line_count = 1;
        c2h_src_stride = 32; c2h_dst_stride = 64;
        c2h_plane12_width = 0; c2h_plane12_count = 0;
        c2h_format = 1; c2h_plane_count = 1;
        c2h_desc_ctrl = 0;
        m_axi_arready = 1;
        m_axi_rdata = 0;
        m_axi_rresp = 0;
        m_axi_rlast = 0;
        m_axi_rvalid = 0;
        c2h_req_ack = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Dispatch C2H 2D Descriptor (FPGA Src=0x5000, Host Dst=0x9000, Width=32, Dst Stride=64)...", $time);
        @(posedge clk);
        c2h_desc_valid <= 1;
        c2h_plane0_src <= 64'h0000_5000;
        c2h_plane0_dst <= 64'h0000_9000;
        c2h_line_width <= 16'd32;
        c2h_line_count <= 16'd1;
        c2h_src_stride <= 16'd32;
        c2h_dst_stride <= 16'd64;

        wait(m_axi_arvalid);
        $display("[%0t] C2H Engine issued AXI4 Read Addr: 0x%h", $time, m_axi_araddr);

        @(posedge clk);
        c2h_desc_valid <= 0;

        #20;
        $display("[%0t] Simulate FPGA Memory returning Read Data...", $time);
        @(posedge clk);
        m_axi_rvalid <= 1;
        m_axi_rdata  <= 256'hFFEEDDCC_BBAA9988_77665544_33221100_A1B2C3D4_E5F67890_12345678_9ABCDEF0;
        m_axi_rlast  <= 1;
        @(posedge clk);
        m_axi_rvalid <= 0;

        wait(c2h_req_valid);
        $display("[%0t] C2H Engine requested Host MWr Addr: 0x%h Data: 0x%h", $time, c2h_req_addr, c2h_req_data);

        @(posedge clk);
        c2h_req_ack <= 1;
        @(posedge clk);
        c2h_req_ack <= 0;

        wait(c2h_done);
        $display("[%0t] C2H Transfer Complete!", $time);

        #30;
        $display("[%0t] SUCCESS: c2h_dma_engine Test Completed!", $time);
        $finish;
    end

endmodule
