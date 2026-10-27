`timescale 1ns/1ps
module sc7f0_hdmi_pcm_tb;
    reg clk=0; always #4 clk=~clk;
    reg rst_n=0, enable=0, valid=0, ready=0;
    reg [31:0] data=0; reg [7:0] tid=0;
    wire [31:0] pcm, frames, rate, errors, channels, cs;
    wire pv, overflow;
    reg test_passed=0, check_output=1;
    reg [31:0] expected[0:4095];
    integer tail=0, head=0, cycles=0, old_errors;
    hdmi_rx_pcm_converter #(.CLOCK_HZ(1000)) dut (
        .clk(clk),.rst_n(rst_n),.capture_enable(enable),.diagnostic_raw(1'b0),
        .s_axis_audio_tdata(data),.s_axis_audio_tid(tid),.s_axis_audio_tvalid(valid),
        .s_axis_audio_tready(),.m_axis_pcm_tdata(pcm),.m_axis_pcm_tvalid(pv),
        .m_axis_pcm_tready(ready),.overflow(overflow),.frame_count(frames),
        .measured_rate(rate),.error_count(errors),.channel_mask(channels),.channel_status(cs));
    reg held=0; reg [31:0] held_data;
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (rst_n && enable && check_output) begin
            if (held && (!pv || pcm !== held_data)) $fatal(1,"PCM changed under stall");
            if (pv && ready) begin
                if (head>=tail || pcm !== expected[head])
                    $fatal(1,"PCM mismatch index=%0d got=%h want=%h",head,pcm,expected[head]);
                head=head+1;
            end
        end
        held <= rst_n && enable && check_output && pv && !ready;
        held_data <= pcm;
    end
    task sample(input [7:0] ch,input [3:0] pre,input [23:0] value,input inv,input cbit);
        begin
            @(negedge clk); tid=ch; data={1'b0,cbit,1'b0,inv,value,pre}; valid=1;
            @(negedge clk); valid=0;
        end
    endtask
    task pair(input integer n);
        reg [23:0] l,r;
        begin
            l=(n%3==0)?24'h800000:((n%3==1)?24'h7fffff:n);
            r=24'hffffff-n;
            expected[tail]={l,8'd0}; expected[tail+1]=(n%7==0)?0:{r,8'd0}; tail=tail+2;
            sample(0,(n%192==0)?1:2,l,0,0);
            sample(1,3,r,n%7==0,0);
            sample(2,2,24'hbadbad,0,0); sample(3,3,24'hdeadbe,0,0);
            for(integer ch=4;ch<8;ch=ch+1)
                sample(ch,ch[0]?3:2,24'hfed000+ch,0,0);
        end
    endtask
    initial begin
        repeat(10) @(negedge clk); rst_n=1;
        sample(0,1,24'h123456,0,0); sample(1,3,24'h654321,0,0);
        repeat(15) @(negedge clk); if(pv) $fatal(1,"idle was not drained");
        enable=1; repeat(15) @(negedge clk);
        sample(1,3,24'hbadbad,0,0); // Start mid-frame: silently acquire next L, no false XRUN.
        fork
            begin for(integer i=0;i<200;i=i+1) pair(i); end
            begin repeat(3400) begin @(negedge clk); ready=(cycles%5!=0 && cycles%11!=0); end end
        join
        ready=1; repeat(100) @(negedge clk);
        if(head!=tail || errors!=0 || channels!=255 || frames!=201)
            $fatal(1,"normal capture head=%d tail=%d errors=%d mask=%h frames=%d",head,tail,errors,channels,frames);
        check_output=0; ready=0; old_errors=errors;
        for(integer i=0;i<80;i=i+1) begin sample(0,2,i,0,0);sample(1,3,i,0,0);end
        repeat(5) @(negedge clk);
        if(errors<=old_errors) $fatal(1,"overflow not counted");
        enable=0; repeat(20) @(negedge clk); enable=1;
        head=0;tail=0;check_output=1;held=0;ready=1;
        repeat(15) @(negedge clk);
        for(integer i=210;i<214;i=i+1) pair(i);
        repeat(50) @(negedge clk);
        if(head!=tail) $fatal(1,"restart did not deliver fresh samples");
        test_passed=1;
        $display("TB_PASS: HDMI TID/preamble PCM sign/validity/stalls/overflow/idle/restart");
        $finish;
    end
    initial begin #200000; $fatal(1,"PCM timeout"); end
endmodule
