`timescale 1ns/1ps
module sc7f0_axi_read_arbiter_tb;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg v0=0,v1=0,mready=0,rv=0,rl=0,r0=1,r1=1;
    wire a0,a1,mv,rr,rv0,rv1;
    wire [48:0] ma;wire [127:0] d0,d1;reg [127:0] data=0;
    sc7f0_axi_read_arbiter dut(
        .clk(clk),.rst_n(rst_n),.s0_addr(49'h1000),.s0_len(8'd3),.s0_size(3'd4),.s0_burst(2'd1),
        .s0_valid(v0),.s0_ready(a0),.s0_data(d0),.s0_resp(),.s0_last(),.s0_rvalid(rv0),.s0_rready(r0),
        .s1_addr(49'h2000),.s1_len(8'd3),.s1_size(3'd4),.s1_burst(2'd1),
        .s1_valid(v1),.s1_ready(a1),.s1_data(d1),.s1_resp(),.s1_last(),.s1_rvalid(rv1),.s1_rready(r1),
        .m_addr(ma),.m_len(),.m_size(),.m_burst(),.m_valid(mv),.m_ready(mready),
        .m_data(data),.m_resp(2'd0),.m_last(rl),.m_rvalid(rv),.m_rready(rr));
    task automatic response(input bit owner);
        integer k;
        begin
            for(k=0;k<4;k=k+1)begin
                @(negedge clk);rv=1;rl=k==3;data=k+123;
                #1;if(rv0!=!owner||rv1!=owner||d0!==data||d1!==data)$fatal(1,"Response owner/data");
                @(posedge clk);if(!rr)$fatal(1,"Read not ready");
                if(k<3&&(a0||a1))$fatal(1,"Owner preempted");
            end
            @(negedge clk);rv=0;rl=0;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;v0=1;v1=1;
        @(posedge clk);if(!a0||a1)$fatal(1,"Initial priority");
        @(negedge clk);v0=0;
        repeat(5)begin @(posedge clk);if(!mv||ma!='h1000||a1)$fatal(1,"AR hold/nonpreemption");end
        @(negedge clk);mready=1;@(posedge clk);@(negedge clk);mready=0;
        response(0);
        @(posedge clk);if(!a1)$fatal(1,"Fairness");
        @(negedge clk);v1=0;v0=1;mready=1;
        @(posedge clk);if(!mv||ma!='h2000)$fatal(1,"Second AR");
        response(1);
        @(posedge clk);if(!a0)$fatal(1,"Refill arbitration");
        @(negedge clk);v0=0;@(posedge clk);
        response(0);
        $display("AXI_READ_ARBITER_PASS");$finish;
    end
    initial begin #10000;$fatal(1,"Arbiter timeout");end
endmodule
