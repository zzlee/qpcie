`timescale 1ns/1ps
// The existing TPG overlay can also consume the HDMI bridge's AXIS stream.
module hdmi_corner_overlay_tb;
    localparam W=128, H=16;
    reg pclk=0, vclk=0, rst_n=0, de=0, vs=0, overlay=0, ready=0;
    reg flush=0, force_stall=0;
    always #1.6835 pclk=~pclk;
    always #3.333 vclk=~vclk;
    wire [127:0] in_data,out_data;
    wire in_valid,in_last,in_user,in_ready,out_valid,out_last,out_user;
    integer received=0,tick=0,phase;
    hdmi_dual_pixel_bridge #(.FIFO_DEPTH(2048)) bridge (
        .tm0_pclk(pclk), .tm0_rst_n(rst_n), .tm0_de(de), .tm0_vs(vs), .tm0_hs(1'b0),
        .single_pixel_mode(1'b0), .frame_stamp_enable(1'b0), .capture_active(!flush), .debug_gray(),
        .tm0_a_r(10'h158), .tm0_a_g(10'h0D0), .tm0_a_b(10'h048),
        .tm0_b_r(10'h158), .tm0_b_g(10'h0D0), .tm0_b_b(10'h048),
        .video_clk(vclk), .video_rst_n(rst_n),
        .m_axis_video_tdata(in_data), .m_axis_video_tvalid(in_valid),
        .m_axis_video_tlast(in_last), .m_axis_video_tuser(in_user), .m_axis_video_tready(in_ready)
    );
    tpg_marker_overlay #(.FLUSH_ENABLE(1)) dut (
        .clk(vclk), .rst_n(rst_n), .overlay_en(overlay), .frame_width(16'(W)), .frame_height(16'(H)),
        .flush(flush),
        .s_axis_tdata(in_data), .s_axis_tvalid(in_valid), .s_axis_tlast(in_last),
        .s_axis_tuser(in_user), .s_axis_tready(in_ready),
        .m_axis_tdata(out_data), .m_axis_tvalid(out_valid), .m_axis_tlast(out_last),
        .m_axis_tuser(out_user), .m_axis_tready(ready)
    );
    function automatic [23:0] expected(input integer x,y,f);
        expected=24'h563412;
        if(overlay)begin
            if(x<4&&y<4)expected=24'h0000FF;
            else if(x==8&&y==0)expected={8'(f>>8),8'(f),8'hA5};
            else if(x>=W-4&&y<4)expected=24'h00FF00;
            else if(x<4&&y>=H-4)expected=24'hFF0000;
            else if(x>=W-4&&y>=H-4)expected=24'h00FFFF;
            else if(x>=W/2-2&&x<W/2+2&&y>=H/2-2&&y<H/2+2)expected=24'hFF00FF;
        end
    endfunction
    reg stalled=0;
    reg [129:0] held;
    integer x,y,f;
    always @(posedge vclk) begin
        if(!rst_n)begin ready<=0;tick<=0;stalled<=0;end
        else begin
            tick<=tick+1;ready<=!force_stall&&(tick%3!=0);
            if(stalled&&!flush&&(!out_valid||{out_user,out_last,out_data}!==held))$fatal(1,"Overlay AXIS stall violation");
            stalled<=out_valid&&!ready&&!flush;held<={out_user,out_last,out_data};
            if(out_valid&&ready)begin
                x=(received%(W/4))*4;y=(received/(W/4))%H;f=received/(W*H/4)+1;
                if(out_last!==(x==W-4)||out_user!==((x==0)&&(y==0)))$fatal(1,"Overlay metadata mismatch");
                for(integer p=0;p<4;p++)
                    if(out_data[p*32+:32]!=={8'hFF,expected(x+p,y,f)})$fatal(1,"Corner/watermark/bypass mismatch x=%0d y=%0d",x+p,y);
                received=received+1;
            end
        end
    end
    task automatic frame;
        @(negedge pclk);vs=1;repeat(8)@(negedge pclk);vs=0;repeat(32)@(negedge pclk);
        repeat(H)begin
            de=1;repeat(W/2)@(negedge pclk);de=0;repeat(32)@(negedge pclk);
        end
    endtask
    initial begin
        for(phase=0;phase<2;phase++)begin
            rst_n=0;de=0;vs=0;overlay=phase;received=0;flush=0;force_stall=0;
            repeat(30)@(negedge pclk);rst_n=1;repeat(100)@(negedge pclk);
            frame();frame();repeat(1000)@(negedge vclk);
            if(received!=2*W*H/4)$fatal(1,"Overlay lost beats: %0d",received);
            @(negedge vclk);force_stall=1;
            repeat(3)@(negedge vclk);
            frame();repeat(20)@(negedge vclk);
            if(!out_valid||dut.frame_number!=3)$fatal(1,"Expected buffered third frame before abort");
            flush=1;repeat(50)@(negedge vclk);
            if(out_valid||dut.skid_valid||dut.frame_number!=3)$fatal(1,"Flush must discard stale data but preserve frame count");
        end
        $display("TB_PASS: live HDMI + corner overlay, RGB markers, watermark, exact bypass, AXIS stalls and idle flush preserving IDs");$finish;
    end
    initial begin #100000;$fatal(1,"Timeout");end
endmodule
