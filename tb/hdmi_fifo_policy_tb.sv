`timescale 1ns/1ps
module hdmi_fifo_policy_tb;
    reg pclk=0, vclk=0, rst_n=0, de=0, vs=0, active=0, ready=0;
    always #1.6835 pclk=~pclk;
    always #3.333 vclk=~vclk;
    wire valid, last;
    wire [127:0] gray;
    hdmi_dual_pixel_bridge #(.FIFO_DEPTH(16)) dut (
        .tm0_pclk(pclk), .tm0_rst_n(rst_n), .tm0_de(de), .tm0_vs(vs), .tm0_hs(1'b0),
        .single_pixel_mode(1'b0), .frame_stamp_enable(1'b0),
        .tm0_a_r(10'd0), .tm0_a_g(10'd0), .tm0_a_b(10'd0),
        .tm0_b_r(10'd0), .tm0_b_g(10'd0), .tm0_b_b(10'd0),
        .video_clk(vclk), .video_rst_n(rst_n), .capture_active(active), .debug_gray(gray),
        .m_axis_video_tdata(), .m_axis_video_tvalid(valid), .m_axis_video_tlast(last),
        .m_axis_video_tuser(), .m_axis_video_tready(ready)
    );
    function automatic [31:0] decode(input [31:0] g);
        decode[31]=g[31];
        for(integer i=30;i>=0;i--) decode[i]=decode[i+1]^g[i];
    endfunction
    always @(posedge vclk) if (!active && valid) $fatal(1,"Idle bridge offered data");
    task automatic frame;
        @(negedge pclk);vs=1;
        repeat(8)@(negedge pclk);vs=0;
        repeat(32)@(negedge pclk);
        repeat(20)begin
            de=1;repeat(32)@(negedge pclk);de=0;
            repeat(32)@(negedge pclk);
        end
        repeat(100)@(negedge pclk);
    endtask
    reg [31:0] drops;
    initial begin
        repeat(20)@(negedge pclk);rst_n=1;
        repeat(100)@(negedge pclk);
        frame();
        if(decode(gray[31:0])!=1 || decode(gray[63:32])!=20 ||
           decode(gray[95:64])!=0 || decode(gray[127:96])!=0)
            $fatal(1,"Idle drain/counters failed: %h",gray);
        @(negedge vclk);active=1;
        frame();
        if(decode(gray[95:64])==0 || decode(gray[127:96])==0)
            $fatal(1,"FIFO losses were not reported");
        drops=decode(gray[95:64]);
        @(negedge vclk);ready=1;
        repeat(100)@(negedge vclk);
        @(negedge vclk);active=0;ready=0;
        frame();
        if(decode(gray[95:64])!=drops || decode(gray[31:0])!=3 || decode(gray[63:32])!=60)
            $fatal(1,"Drain after stall failed");
        $display("TB_PASS: idle drain, 297 MHz live source, explicit beat/EOL loss counters, restart drain");
        $finish;
    end
    initial begin #100000;$fatal(1,"Timeout");end
endmodule
