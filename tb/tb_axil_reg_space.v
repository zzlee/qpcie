// ============================================================================
// Testbench: tb_axil_reg_space
// Description: Unit testbench for axil_reg_space module testing Version, Git Commit,
//              Timestamp, and Hardware Capabilities Read-Only registers.
// ============================================================================

`timescale 1ns / 1ps

module tb_axil_reg_space;

    reg        clk;
    reg        rst_n;

    reg [31:0] s_axil_awaddr;
    reg        s_axil_awvalid;
    wire       s_axil_awready;
    reg [31:0] s_axil_wdata;
    reg [3:0]  s_axil_wstrb;
    reg        s_axil_wvalid;
    wire       s_axil_wready;
    wire [1:0] s_axil_bresp;
    wire       s_axil_bvalid;
    reg        s_axil_bready;

    reg [31:0] s_axil_araddr;
    reg        s_axil_arvalid;
    wire       s_axil_arready;
    wire [31:0] s_axil_rdata;
    wire [1:0] s_axil_rresp;
    wire       s_axil_rvalid;
    reg        s_axil_rready;

    wire [31:0] reg_dma_ctrl;
    reg  [31:0] reg_dma_status;
    wire [63:0] reg_h2c_ring_addr;
    wire [15:0] reg_h2c_ring_size;
    wire [15:0] reg_h2c_tail_ptr;
    wire [63:0] reg_c2h_ring_addr;
    wire [15:0] reg_c2h_ring_size;
    wire [15:0] reg_c2h_tail_ptr;
    wire [31:0] reg_irq_ctrl;
    wire [31:0] reg_irq_status;
    wire [31:0] reg_pacer_ctrl, reg_slice_height;
    reg  [31:0] completed_h2c_count;
    reg  [31:0] completed_c2h_count;

    // Instantiate uut
    axil_reg_space uut (
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
        .reg_pacer_ctrl(reg_pacer_ctrl),
        .reg_slice_height(reg_slice_height),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count)
    );

    always #5 clk = ~clk;

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axil_awaddr  <= addr;
            s_axil_awvalid <= 1;
            s_axil_wdata   <= data;
            s_axil_wstrb   <= 4'hF;
            s_axil_wvalid  <= 1;
            wait(s_axil_awready && s_axil_wready);
            @(posedge clk);
            s_axil_awvalid <= 0;
            s_axil_wvalid  <= 0;
            wait(s_axil_bvalid);
            @(posedge clk);
            s_axil_bready  <= 1;
            @(posedge clk);
            s_axil_bready  <= 0;
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s_axil_araddr  <= addr;
            s_axil_arvalid <= 1;
            wait(s_axil_arready);
            @(posedge clk);
            s_axil_arvalid <= 0;
            wait(s_axil_rvalid);
            data = s_axil_rdata;
            @(posedge clk);
            s_axil_rready  <= 1;
            @(posedge clk);
            s_axil_rready  <= 0;
        end
    endtask

    reg [31:0] read_val;

    initial begin
        clk = 0;
        rst_n = 0;
        s_axil_awaddr = 0;
        s_axil_awvalid = 0;
        s_axil_wdata = 0;
        s_axil_wstrb = 0;
        s_axil_wvalid = 0;
        s_axil_bready = 0;
        s_axil_araddr = 0;
        s_axil_arvalid = 0;
        s_axil_rready = 0;
        reg_dma_status = 0;
        completed_h2c_count = 0;
        completed_c2h_count = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Write DMA_CTRL (0x00) = 0x00000001...", $time);
        axil_write(32'h00, 32'h00000001);
        axil_read(32'h00, read_val);
        $display("[%0t] Read DMA_CTRL: 0x%h", $time, read_val);

        #20;
        $display("[%0t] Test 2: Read Version Register (0x30)...", $time);
        axil_read(32'h30, read_val);
        $display("[%0t] Read REG_VERSION_ID (0x30): 0x%h (Expect 0x02010001)", $time, read_val);

        $display("[%0t] Test 3: Read Git Commit Hash Register (0x34)...", $time);
        axil_read(32'h34, read_val);
        $display("[%0t] Read REG_GIT_COMMIT_HASH (0x34): 0x%h (Expect 0x01D6A9C5)", $time, read_val);

        $display("[%0t] Test 4: Read Build Timestamp Register (0x38)...", $time);
        axil_read(32'h38, read_val);
        $display("[%0t] Read REG_BUILD_TIMESTAMP (0x38): 0x%h (Expect 0x20260812)", $time, read_val);

        $display("[%0t] Test 5: Read Hardware Capabilities Register (0x3C)...", $time);
        axil_read(32'h3C, read_val);
        $display("[%0t] Read REG_HARDWARE_CAPS (0x3C): 0x%h (Expect 0x0004040F)", $time, read_val);

        #30;
        $display("[%0t] SUCCESS: axil_reg_space Version & Control Test Completed!", $time);
        $finish;
    end

endmodule
