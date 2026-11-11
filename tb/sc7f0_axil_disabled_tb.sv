`timescale 1ns/1ps
module sc7f0_axil_disabled_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,aw=0,w=0,br=0,ar=0,rr=0;
  wire awr,wr,bv,arr,rv; wire [1:0] bp,rp; wire [31:0] rd;
  sc7f0_axil_disabled dut(.clk(clk),.rst_n(rst_n),
    .s_axil_awaddr(32'hb0020000),.s_axil_awvalid(aw),.s_axil_awready(awr),
    .s_axil_wdata(32'h1234),.s_axil_wstrb(4'hf),.s_axil_wvalid(w),.s_axil_wready(wr),
    .s_axil_bresp(bp),.s_axil_bvalid(bv),.s_axil_bready(br),
    .s_axil_araddr(32'hb0020010),.s_axil_arvalid(ar),.s_axil_arready(arr),
    .s_axil_rdata(rd),.s_axil_rresp(rp),.s_axil_rvalid(rv),.s_axil_rready(rr));
  task step; begin @(posedge clk); #1; end endtask
  task write_order(input integer order);
    integer i;
    begin
      @(negedge clk); aw=(order!=1); w=(order!=0);
      step(); @(negedge clk); aw=0; w=0;
      if(order!=2) begin
        for(i=0;i<7;i=i+1) begin step(); if(bv!==0) $fatal(1,"early/unknown B before AW and W"); end
        @(negedge clk); aw=(order==1); w=(order==0);
        step(); @(negedge clk); aw=0; w=0;
      end
      step(); if(bv!==1 || bp!==2'b11) $fatal(1,"missing DECERR B");
      repeat(5) begin step(); if(bv!==1 || awr!==0 || wr!==0) $fatal(1,"unstable backpressured B"); end
      // Read completion is independent of the stalled write response.
      @(negedge clk); ar=1; step(); @(negedge clk); ar=0;
      repeat(4) begin step(); if(rv!==1 || rp!==2'b11 || rd!==32'hdead_ec00 || arr!==0) $fatal(1,"read response lost"); end
      @(negedge clk); br=1; rr=1; step();
      if(bv!==0 || rv!==0) $fatal(1,"response not retired");
      @(negedge clk); br=0; rr=0; step();
    end
  endtask
  initial begin
    repeat(3) step(); @(negedge clk); rst_n=1; step();
    write_order(0); write_order(1); write_order(2);
    @(negedge clk); aw=1; step(); @(negedge clk); aw=0; rst_n=0;
    step(); if(bv!==0 || rv!==0 || awr!==0 || wr!==0 || arr!==0) $fatal(1,"reset ownership");
    @(negedge clk); rst_n=1; step(); write_order(1);
    $display("SC7F0_DISABLED_AXI_PASS"); $finish;
  end
  initial begin #20000; $fatal(1,"timeout"); end
endmodule
