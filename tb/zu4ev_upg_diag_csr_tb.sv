`timescale 1ns / 1ps
module zu4ev_upg_diag_csr_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] awaddr = 0, araddr = 0, wdata = 0;
    reg awvalid = 0, wvalid = 0, arvalid = 0, ack = 0;
    wire awready, wready, bvalid, arready, rvalid, toggle;
    wire [31:0] rdata;
    axil_reg_space dut (
        .clk(clk), .rst_n(rst_n), .in_requester_id(16'd0),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(4'hF),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(), .s_axil_bvalid(bvalid), .s_axil_bready(1'b1),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(),
        .s_axil_rvalid(rvalid), .s_axil_rready(1'b1),
        .in_dma_upg_diag_pcie(32'h00000123),
        .in_dma_upg_diag_writer(32'h00000245),
        .in_dma_upg_diag_clear_ack(ack),
        .out_dma_upg_diag_clear_toggle(toggle)
    );
    task automatic rd(input [31:0] addr, input [31:0] expected);
        @(negedge clk); araddr = addr; arvalid = 1;
        wait (rvalid);
        if (rdata !== expected)
            $fatal(1, "CSR %h: got %h, expected %h", addr, rdata, expected);
        @(negedge clk); arvalid = 0;
        repeat (2) @(negedge clk);
    endtask
    task automatic clear;
        @(negedge clk); awaddr = 32'h7B8; wdata = 1; awvalid = 1; wvalid = 1;
        wait (bvalid);
        @(negedge clk); awvalid = 0; wvalid = 0;
        repeat (2) @(negedge clk);
    endtask
    initial begin
        repeat (5) @(negedge clk); rst_n = 1;
        rd(32'h7B0, 32'h123);
        rd(32'h7B4, 32'h245);
        rd(32'h7B8, 32'h0);
        clear();
        if (toggle !== 1) $fatal(1, "clear toggle did not change");
        ack = 1;
        rd(32'h7B8, 32'h3);
        clear();
        if (toggle !== 0) $fatal(1, "second toggle did not change");
        ack = 0;
        rd(32'h7B8, 32'h0);
        $display("TB_PASS: BAR0 diagnostic read-only stages and W1 toggle/ACK");
        $finish;
    end
    initial begin #20000; $fatal(1, "watchdog"); end
endmodule
