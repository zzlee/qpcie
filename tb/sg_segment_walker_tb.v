`timescale 1ns / 1ps
module sg_segment_walker_tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0, start = 0, sg_mode = 1, sgl_wr_en = 0;
    reg [63:0] sgl_wr_addr = 0; reg [31:0] sgl_wr_len = 0, sgl_wr_flags = 0;
    reg advance_burst = 0; reg [15:0] burst_bytes = 0;
    wire [63:0] current_addr; wire [31:0] seg_bytes_left; wire seg_valid;
    wire [6:0] fifo_count; wire fifo_almost_full, fifo_empty;
    sg_segment_walker #(.FIFO_DEPTH(8), .MIN_BURST_BYTES(128)) dut (
      .clk(clk), .rst_n(rst_n), .start(start), .sg_mode(sg_mode), .linear_base_addr(64'd0),
      .sgl_wr_en(sgl_wr_en), .sgl_wr_addr(sgl_wr_addr), .sgl_wr_len(sgl_wr_len),
      .sgl_wr_flags(sgl_wr_flags), .advance_burst(advance_burst), .burst_bytes(burst_bytes),
      .current_addr(current_addr), .seg_bytes_left(seg_bytes_left), .seg_valid(seg_valid),
      .fifo_count(fifo_count), .fifo_almost_full(fifo_almost_full), .fifo_empty(fifo_empty));
    task push_seg(input [63:0] addr, input [31:0] len);
      begin @(negedge clk); sgl_wr_en=1; sgl_wr_addr=addr; sgl_wr_len=len;
            @(negedge clk); sgl_wr_en=0; end
    endtask
    task commit_burst(input [15:0] bytes);
      begin @(negedge clk); burst_bytes=bytes; advance_burst=1;
            @(negedge clk); advance_burst=0; burst_bytes=0; end
    endtask
    initial begin
      repeat(2) @(negedge clk); rst_n=1;
      start=1; @(negedge clk); start=0;
      push_seg(64'h100000,256); repeat(2) @(negedge clk);
      if(!seg_valid || current_addr!==64'h100000 || seg_bytes_left!==256) $fatal(1,"load");
      commit_burst(128);
      if(!seg_valid || current_addr!==64'h100080 || seg_bytes_left!==128) $fatal(1,"advance");
      commit_burst(128);
      push_seg(64'h200000,64); repeat(2) @(negedge clk);
      if(seg_valid) $fatal(1,"short segment advertised");
      push_seg(64'h300F80,256); repeat(2) @(negedge clk);
      if(seg_valid) $fatal(1,"4KiB crossing advertised");
      start=1; @(negedge clk); start=0;
      push_seg(64'h400000,128); repeat(2) @(negedge clk);
      if(!seg_valid) $fatal(1,"valid segment missing");
      commit_burst(256);
      if(seg_valid) $fatal(1,"burst overrun not blocked");
      $display("PASS: sg_segment_walker boundary/overrun checks"); $finish;
    end
endmodule
