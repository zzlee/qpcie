`timescale 1ns / 1ps
module zu4ev_ddr_readback_tb;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg request=0, dma=0, arready=0, rvalid=0, rlast=1;
    reg [31:0] offset=0;
    reg [127:0] rdata=128'hfedcba98_76543210_11223344_55667788;
    reg [1:0] rresp=0;
    reg [5:0] rid=0;
    wire [31:0] status, seq;
    wire [127:0] data;
    wire [48:0] addr;
    wire arvalid, rready;
    zu4ev_ddr_readback #(.TIMEOUT_CYCLES(12)) dut (
        .clk(clk), .rst_n(rst_n), .request(request), .offset(offset),
        .dma_active(dma), .status(status), .sequence_id(seq), .data(data),
        .araddr(addr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rid(rid), .rlast(rlast), .rvalid(rvalid), .rready(rready)
    );
    task automatic start(input [31:0] off);
        @(negedge clk); offset=off; request=1;
        @(negedge clk); request=0;
    endtask
    task automatic accept_ar;
        @(negedge clk); arready=1;
        @(negedge clk); arready=0;
    endtask
    task automatic reply;
        @(negedge clk); rvalid=1;
        @(negedge clk); rvalid=0;
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        start(0);
        repeat(3) @(negedge clk);
        if (!arvalid || addr!==49'h30000000 || seq!==1) $fatal(1,"AR stability");
        start(16); // ignored while busy, address/sequence must remain unchanged
        if (seq!==1 || addr!==49'h30000000) $fatal(1,"busy request accepted");
        accept_ar(); reply();
        if (status!==2 || data!==rdata) $fatal(1,"read data");
        start(32'hff0); accept_ar(); rresp=2; reply(); rresp=0;
        if (status!==6 || addr!==49'h30000ff0) $fatal(1,"RRESP/boundary");
        start(32'h1000);
        if (status!==32'h16 || arvalid) $fatal(1,"range rejection");
        start(1);
        if (status!==32'h16 || arvalid) $fatal(1,"alignment rejection");
        dma=1; start(0); dma=0;
        if (status!==32'h16 || arvalid) $fatal(1,"DMA interlock");
        start(0);
        repeat(16) @(negedge clk);
        if (status!==9 || !arvalid) $fatal(1,"timeout cancelled AR");
        accept_ar(); reply();
        if (status!==10) $fatal(1,"late response not drained");
        start(0); accept_ar();
        repeat(16) @(negedge clk);
        if (status!==9 || !rready || arvalid) $fatal(1,"R timeout lost pending transaction");
        reply();
        if (status!==10) $fatal(1,"late R timeout response");
        start(16); accept_ar(); rid=1; reply(); rid=0;
        if (status!==6) $fatal(1,"RID check");
        start(32); accept_ar(); rlast=0; reply();
        if (!status[0] || !status[2] || !rready) $fatal(1,"missing RLAST");
        rlast=1; reply();
        if (status!==6) $fatal(1,"malformed response drain");
        $display("TB_PASS: DDR readback bounds, busy, data, RRESP/RID/RLAST, timeout and late drain");
        $finish;
    end
    initial begin #10000; $fatal(1,"watchdog"); end
endmodule
