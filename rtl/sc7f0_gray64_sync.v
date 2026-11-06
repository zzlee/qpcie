`default_nettype none
`timescale 1ns/1ps
// Input MUST be a source-registered Gray counter (at most one bit changes per
// source cycle). Board XDC must constrain its source -> stage0 delay and skew.
module sc7f0_gray64_sync(
    input wire clk,rst_n,input wire [63:0] gray,output wire [63:0] binary
);
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [63:0] stage0,stage1,stage2,stage3;
    always @(posedge clk)begin
        if(!rst_n)begin stage0<=0;stage1<=0;stage2<=0;stage3<=0;end
        else begin stage0<=gray;stage1<=stage0;stage2<=stage1;stage3<=stage2;end
    end
    genvar k;
    generate for(k=0;k<64;k=k+1)begin:decode
        assign binary[k]=^(stage3>>k);
    end endgenerate
endmodule
`default_nettype wire
