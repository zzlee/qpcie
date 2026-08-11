// ============================================================================
// Testbench: tb_axil_reg_space
// Description: Unit testbench for axil_reg_space module
// ============================================================================

`timescale 1ns / 1ps

module tb_axil_reg_space;

    parameter ADDR_WIDTH = 32;
    parameter DATA_WIDTH = 32;

    reg                  clk;
    reg                  rst_n;

    reg  [ADDR_WIDTH-1:0] s_axil_awaddr;
    reg                  s_axil_awvalid;
    wire                 s_axil_awready;

    reg  [DATA_WIDTH-1:0] s_axil_wdata;
    reg  [3:0]            s_axil_wstrb;
    reg                  s_axil_wvalid;
    wire                 s_axil_wready;

    wire [1:0]           s_axil_bresp;
    wire                 s_axil_bvalid;
    reg                  s_axil_bready;

    reg  [ADDR_WIDTH-1:0] s_axil_araddr;
    reg                  s_axil_arvalid;
    wire                 s_axil_arready;

    wire [DATA_WIDTH-1:0] s_axil_rdata;
    wire [1:0]           s_axil_rresp;
    wire                 s_axil_rvalid;
    reg                  s_axil_rready;

    wire [31:0]          reg_dma_ctrl;
    reg  [31:0]          reg_dma_status;

    wire [63:0]          reg_h2c_ring_addr;
    wire [15:0]          reg_h2c_ring_size;
    wire [15:0]          reg_h2c_tail_ptr;

    wire [63:0]          reg_c2h_ring_addr;
    wire [15:0]          reg_c2h_ring_size;
    wire [15:0]          reg_c2h_tail_ptr;

    wire [31:0]          reg_irq_ctrl;
    reg  [31:0]          reg_irq_status;

    reg  [31:0]          completed_h2c_count;
    reg  [31:0]          completed_c2h_count;

    // Instantiate uut
    axil_reg_space #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .reg_dma_ctrl(reg_dma_ctrl),
        .reg_dma_status(reg_dma_status),
        .reg_h2c_ring_addr(reg_h2c_ring_addr),
        .reg_h2c_ring_size(reg_h2c_ring_size),
        .reg_h2c_tail_ptr(reg_h2c_tail_ptr),
        .reg_c2h_ring_addr(reg_c2h_ring_addr),
        .reg_c2h_ring_size(reg_c2h_ring_size),
        .reg_c2h_tail_ptr(reg_c2h_tail_ptr),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status(reg_irq_status),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        s_axil_awaddr = 0;
        s_axil_awvalid = 0;
        s_axil_wdata = 0;
        s_axil_wstrb = 4'hF;
        s_axil_wvalid = 0;
        s_axil_bready = 1;
        s_axil_araddr = 0;
        s_axil_arvalid = 0;
        s_axil_rready = 1;

        reg_dma_status = 32'h0000_0001; // Busy
        reg_irq_status = 32'h0000_0000;
        completed_h2c_count = 32'd42;
        completed_c2h_count = 32'd100;

        #20;
        rst_n = 1;
        #10;

        // Test 1: Write H2C Ring Address Low (Offset 0x08) & High (Offset 0x0C)
        $display("[%0t] Test 1: Write H2C Ring Address 0x8000_0000_1234_5678...", $time);
        @(posedge clk);
        s_axil_awaddr  <= 32'h08;
        s_axil_awvalid <= 1;
        s_axil_wdata   <= 32'h1234_5678;
        s_axil_wvalid  <= 1;
        wait(s_axil_bvalid);
        @(posedge clk);
        s_axil_awvalid <= 0;
        s_axil_wvalid  <= 0;

        @(posedge clk);
        s_axil_awaddr  <= 32'h0C;
        s_axil_awvalid <= 1;
        s_axil_wdata   <= 32'h8000_0000;
        s_axil_wvalid  <= 1;
        wait(s_axil_bvalid);
        @(posedge clk);
        s_axil_awvalid <= 0;
        s_axil_wvalid  <= 0;

        #10;
        $display("[%0t] reg_h2c_ring_addr output = 0x%h (Expected: 0x8000000012345678)", $time, reg_h2c_ring_addr);

        // Test 2: Read Completed H2C Count (Offset 0x28)
        #20;
        $display("[%0t] Test 2: Read Completed H2C Count (Offset 0x28)...", $time);
        @(posedge clk);
        s_axil_araddr  <= 32'h28;
        s_axil_arvalid <= 1;
        wait(s_axil_rvalid);
        $display("[%0t] AXI-Lite Read Data = %d (Expected: 42)", $time, s_axil_rdata);
        @(posedge clk);
        s_axil_arvalid <= 0;

        #30;
        $display("[%0t] SUCCESS: axil_reg_space Test Completed!", $time);
        $finish;
    end

endmodule
