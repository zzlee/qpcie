`timescale 1ns/1ps
module sc7f0_hdmi_trace_tb;
    reg clk=0; always #4 clk=~clk;
    reg rst_n=0, enable=0, valid=0, ready=0, check_output=1;
    reg [31:0] data=0;
    reg [7:0] tid=0;
    wire [31:0] out, frames, rate, errors, mask, cs;
    wire ov, pv;
    reg test_passed=0;
    integer head=0, tail=0, cycles=0, baseline;
    reg [31:0] expected[0:4095];
    hdmi_rx_pcm_converter #(.CLOCK_HZ(1000)) dut(
        .clk(clk),.rst_n(rst_n),.capture_enable(enable),.diagnostic_raw(1'b1),
        .s_axis_audio_tdata(data),.s_axis_audio_tid(tid),.s_axis_audio_tvalid(valid),
        .s_axis_audio_tready(),.m_axis_pcm_tdata(out),.m_axis_pcm_tvalid(pv),
        .m_axis_pcm_tready(ready),.overflow(ov),.frame_count(frames),
        .measured_rate(rate),.error_count(errors),.channel_mask(mask),.channel_status(cs));
    reg held=0; reg [31:0] held_data;
    always @(posedge clk) begin
        cycles=cycles+1;
        if (rst_n && enable && check_output) begin
            if (valid && dut.active && !dut.fifo_full) begin
                expected[tail]=data;
                expected[tail+1]={8'hA5,tid,dut.trace_cycle};
                tail=tail+2;
            end
            if (held && (!pv || out !== held_data)) $fatal(1,"trace changed under stall");
            if (pv && ready) begin
                if (head>=tail || out !== expected[head])
                    $fatal(1,"trace mismatch at %0d got=%h expected=%h",head,out,expected[head]);
                head=head+1;
            end
        end
        held <= rst_n && enable && check_output && pv && !ready;
        held_data <= out;
    end
    task beat(input integer n);
        begin
            @(negedge clk); tid=n%8; data=32'hf1234560|(n%4); valid=1;
            @(negedge clk); valid=0;
        end
    endtask
    initial begin
        repeat(10) @(negedge clk); rst_n=1;
        beat(1); repeat(10) @(negedge clk);
        if(pv) $fatal(1,"idle trace leaked");
        enable=1; repeat(15) @(negedge clk);
        fork
            begin for(integer i=0;i<200;i=i+1) begin beat(i); repeat(6) @(negedge clk); end end
            begin repeat(1800) begin @(negedge clk); ready=(cycles%5!=0 && cycles%11!=0); end end
        join
        ready=1; repeat(100) @(negedge clk);
        if(head!=tail || tail!=400 || errors!=0 || mask!=255)
            $fatal(1,"trace accounting head=%0d tail=%0d errors=%0d mask=%h",head,tail,errors,mask);
        // V=1 words were preserved above, not converted into silence.
        check_output=0; ready=0; baseline=errors;
        for(integer i=0;i<100;i=i+1) beat(i);
        repeat(10) @(negedge clk);
        if(errors<=baseline) $fatal(1,"trace overflow not counted");
        enable=0; repeat(20) @(negedge clk);
        head=0; tail=0; held=0; check_output=1; ready=1; enable=1;
        repeat(15) @(negedge clk);
        beat(5); beat(6); repeat(30) @(negedge clk);
        if(head!=tail || tail!=4) $fatal(1,"trace restart retained stale words");
        test_passed=1;
        $display("TB_PASS: RXA1 original IEC words + TID/cycle metadata, stalls/overflow/idle/restart");
        $finish;
    end
    initial begin #200000; $fatal(1,"trace timeout"); end
endmodule
