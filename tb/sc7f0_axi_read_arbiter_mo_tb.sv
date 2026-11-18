`timescale 1ns/1ps
module sc7f0_axi_read_arbiter_mo_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [48:0] s0_addr = 0, s1_addr = 0;
    reg [7:0]  s0_len = 8'd3, s1_len = 8'd3;
    reg        s0_valid = 0, s1_valid = 0;
    wire       s0_ready, s1_ready;
    wire [127:0] s0_data, s1_data;
    wire       s0_last, s1_last, s0_rvalid, s1_rvalid;
    reg        s0_rready = 1, s1_rready = 1;

    wire [48:0] m_addr;
    wire [7:0]  m_len;
    wire [5:0]  m_arid;
    wire        m_valid;
    reg         m_ready = 1;
    reg [127:0] m_data = 0;
    reg [5:0]   m_rid = 0;
    reg         m_last = 0, m_rvalid = 0;
    wire        m_rready;

    sc7f0_axi_read_arbiter_mo #(.AW(49), .IW(6), .ID_BIT(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .s0_addr(s0_addr), .s0_len(s0_len), .s0_size(3'd4), .s0_burst(2'd1),
        .s0_arid(6'd1), .s0_valid(s0_valid), .s0_ready(s0_ready),
        .s0_data(s0_data), .s0_resp(), .s0_rid(), .s0_last(s0_last),
        .s0_rvalid(s0_rvalid), .s0_rready(s0_rready),
        .s1_addr(s1_addr), .s1_len(s1_len), .s1_size(3'd4), .s1_burst(2'd1),
        .s1_arid(6'd0), .s1_valid(s1_valid), .s1_ready(s1_ready),
        .s1_data(s1_data), .s1_resp(), .s1_rid(), .s1_last(s1_last),
        .s1_rvalid(s1_rvalid), .s1_rready(s1_rready),
        .m_addr(m_addr), .m_len(m_len), .m_size(), .m_burst(),
        .m_arid(m_arid), .m_valid(m_valid), .m_ready(m_ready),
        .m_data(m_data), .m_resp(2'd0), .m_rid(m_rid),
        .m_last(m_last), .m_rvalid(m_rvalid), .m_rready(m_rready)
    );

    integer ar_count = 0;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        // 1. Both masters issue 4 back-to-back ARs without waiting for RLAST
        s0_addr = 49'h1000; s1_addr = 49'h2000;
        s0_valid = 1; s1_valid = 1;
        repeat (8) begin
            @(posedge clk);
            if (m_valid && m_ready) ar_count = ar_count + 1;
        end
        @(negedge clk);
        s0_valid = 0; s1_valid = 0;
        @(posedge clk);
        if (m_valid && m_ready) ar_count = ar_count + 1;
        if (ar_count < 8) $fatal(1, "Expected pipelined ARs without waiting for R, got %0d", ar_count);

        // 2. Interleaved R responses routed by m_rid[1]
        @(negedge clk);
        m_rvalid = 1; m_rid = 6'd1; m_data = 128'hAAAA; m_last = 0;
        #1; if (!s0_rvalid || s1_rvalid || s0_data !== 128'hAAAA) $fatal(1, "R route s0 failed");
        @(posedge clk);

        @(negedge clk);
        m_rvalid = 1; m_rid = 6'd2; m_data = 128'hBBBB; m_last = 1;
        #1; if (s0_rvalid || !s1_rvalid || s1_data !== 128'hBBBB || !s1_last) $fatal(1, "R route s1 failed");
        @(posedge clk);

        // 3. Backpressure on s1_rready does not stall s0
        @(negedge clk);
        s1_rready = 0; m_rid = 6'd2;
        #1; if (m_rready !== 1'b0) $fatal(1, "m_rready should reflect s1_rready=0");
        m_rid = 6'd1;
        #1; if (m_rready !== 1'b1) $fatal(1, "m_rready should reflect s0_rready=1");

        $display("AXI_READ_ARBITER_MO_PASS ar_count=%0d", ar_count);
        $finish;
    end
endmodule
