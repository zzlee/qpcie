`timescale 1ns/1ps
module sc7f0_frame_tap_tb;
    reg sc=0,mc=0,sn=0,mn=0,en=0;
    always #3.367 sc=~sc;
    always #3.333 mc=~mc;
    reg [95:0] sd=0;reg sv=0,ss=0,se=0;
    reg [15:0] width=64,height=64;
    wire [95:0] md;wire mv,ms,me,busy;
    reg ready=1,credit_valid=0,credit_clear=0;
    reg [15:0] credit_add=0;
    wire [31:0] started_count;
    wire [159:0] meta;wire metaval;
    wire [31:0] drops;wire [63:0] ticks;
    reg test_pass=0;
    sc7f0_frame_tap #(.FIFO_DEPTH(32),.GAP_CYCLES(64)) dut(
        .s_clk(sc),.s_rst_n(sn),.s_data(sd),.s_valid(sv),.s_sof(ss),.s_eol(se),
        .m_clk(mc),.m_rst_n(mn),.enable(en),.width(width),.height(height),
        .credit_valid(credit_valid),.credit_clear(credit_clear),.credit_add(credit_add),.started_count(started_count),
        .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(ready),
        .meta_data(meta),.meta_valid(metaval),.meta_ready(1'b1),
        .busy(busy),.dropped_frames(drops),.ticks(ticks));
    integer words=0,metas=0,expected_id=1;
    reg [63:0] last_timestamp=0;
    reg expect_bad=0;
    reg stalled=0;
    reg [97:0] held;
    always @(posedge mc)begin
        if(mn)begin
            if(stalled&&({ms,me,md}!==held||!mv))$fatal(1,"AXIS changed under stall");
            stalled<=mv&&!ready;held<={ms,me,md};
            if(mv&&ready)begin
                if(ms!=(words==0))$fatal(1,"Wrong SOF");
                if(me!=(words%(width/4)==width/4-1))$fatal(1,"Wrong EOL");
                if(!expect_bad&&md!=={4{24'h123456}})$fatal(1,"Good frame corrupted");
                words=words+1;
            end
            if(metaval)begin
                if(words!=width*height/4)$fatal(1,"Truncated/oversized frame %d",words);
                if(meta[127:96]==0&&expect_bad)$fatal(1,"Lost error status");
                if(meta[127:96]!=0&&!expect_bad)$fatal(1,"Unexpected error %h",meta[127:96]);
                if(meta[143:128]!=width||meta[159:144]!=height||meta[63:0]==0)$fatal(1,"Bad metadata");
                if(meta[95:64]!=expected_id||meta[63:0]<=last_timestamp)$fatal(1,"Source ID/time ordering");
                last_timestamp=meta[63:0];metas=metas+1;words=0;
                $display("TAP_FRAME_PASS seq=%d flags=%h %dx%d",meta[95:64],meta[127:96],width,height);
            end
        end
    end
    task automatic raster;
        integer y,x;
        begin
            for(y=0;y<height;y=y+1)for(x=0;x<width;x=x+4)begin
                @(negedge sc);sv=1;ss=(x==0&&y==0);se=x==width-4;sd={4{24'h123456}};
                // There is deliberately no source READY to wait for.
            end
            @(negedge sc);sv=0;ss=0;se=0;
        end
    endtask
    task automatic grant(input [15:0] n);
        begin @(negedge mc);credit_add=n;credit_valid=1;@(negedge mc);credit_valid=0;end
    endtask
    initial begin
        #300;sn=1;mn=1;grant(4);en=1;repeat(50)@(negedge mc);
        raster();wait(metas==1);repeat(60)@(negedge mc);
        expected_id=2;expect_bad=1;ready=0;
        raster(); // Must finish at source even with sink fully stopped.
        repeat(80)@(negedge mc);ready=1;
        wait(metas==2);repeat(80)@(negedge mc);
        expected_id=3;expect_bad=0;raster();wait(metas==3);repeat(80)@(negedge mc);
        expected_id=4;expect_bad=1;
        fork
            raster();
            begin wait(words>100);@(negedge mc);en=0;credit_clear=1;@(negedge mc);credit_clear=0;end
        join
        wait(metas==4);repeat(80)@(negedge mc);
        expected_id=5;expect_bad=0;grant(2);en=1;repeat(50)@(negedge mc);
        raster();wait(metas==5);repeat(80)@(negedge mc);
        expected_id=6;width=4096;height=2160;
        raster();wait(metas==6);repeat(80)@(negedge mc);
        width=64;height=64;raster();repeat(80)@(negedge mc);
        if(metas!=6||words!=0||busy)$fatal(1,"Captured without buffer credit");
        expected_id=8;grant(1);repeat(80)@(negedge mc);raster();wait(metas==7);
        if(started_count!=7)$fatal(1,"Wrong started-frame ownership count");
        if(drops==0)$fatal(1,"Overflow not counted");
        test_pass=1;$display("FRAME_TAP_SIM_PASS (including max geometry, stall, stop/restart)");$finish;
    end
    initial begin #60000000;$fatal(1,"Tap timeout");end
endmodule
