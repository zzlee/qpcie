`timescale 1ns/1ps
module sc7f0_hdmi_bridges_tb;
    reg pclk=0, vclk=0, aclk=0;
    always #5 pclk=~pclk;
    always #7 vclk=~vclk;
    always #11 aclk=~aclk;
    reg rst_n=0;
    reg test_passed=0;
    reg [31:0] ctrl=3;
    reg [127:0] vdata=0;
    reg vv=0;
    wire vr;
    wire [95:0] vout;
    wire vov, vol, vou;
    reg vor=0;
    reg [31:0] adata=0, tdata=0;
    reg av=0, tv=0;
    wire ar, tr;
    wire [31:0] aout, tout;
    wire aov, tov;
    reg aor=0, tor=0;
    integer vn=0, an=0, tn=0;
    integer vp=0, ap=0, tp=0;
    wire [31:0] status, format;
    hdmi_tx_video_bridge video (
        .pcie_user_clk(pclk), .pcie_user_rst_n(rst_n),
        .s_axis_video_tdata(vdata), .s_axis_video_tvalid(vv), .s_axis_video_tready(vr),
        .s_axis_video_tlast(1'b1), .s_axis_video_tuser(1'b1), .tx_ctrl_reg(ctrl),
        .tx_video_clk(vclk), .tx_video_rst_n(rst_n),
        .m_axis_video_tdata(vout), .m_axis_video_tvalid(vov), .m_axis_video_tready(vor),
        .m_axis_video_tlast(vol), .m_axis_video_tuser(vou),
        .tx_hpd_in(1'b1), .tx_status_reg(status));
    hdmi_rx_audio_bridge rx_audio (
        .rx_audio_clk(aclk), .rx_audio_rst_n(rst_n),
        .s_axis_audio_tdata(adata), .s_axis_audio_tvalid(av), .s_axis_audio_tready(ar),
        .pcie_user_clk(pclk), .pcie_user_rst_n(rst_n),
        .m_axis_audio_tdata(aout), .m_axis_audio_tvalid(aov), .m_axis_audio_tready(aor),
        .m_axis_audio_tlast(), .rx_audio_reg(format));
    hdmi_tx_audio_bridge tx_audio (
        .pcie_user_clk(pclk), .pcie_user_rst_n(rst_n),
        .s_axis_audio_tdata(tdata), .s_axis_audio_tvalid(tv), .s_axis_audio_tready(tr),
        .s_axis_audio_tlast(1'b0), .tx_ctrl_reg(ctrl),
        .tx_audio_clk(aclk), .tx_audio_rst_n(rst_n),
        .m_axis_audio_tdata(tout), .m_axis_audio_tvalid(tov), .m_axis_audio_tready(tor),
        .m_axis_audio_tlast());
    always @(negedge vclk) begin vp=vp+1; vor=rst_n && (vp%5==0); end
    always @(negedge pclk) begin ap=ap+1; aor=rst_n && (ap%4==0); end
    always @(negedge aclk) begin tp=tp+1; tor=rst_n && (tp%3==0); end
    always @(posedge vclk) if (vov && vor) begin
        if (vout !== {24'hccbbaa,24'h998877,24'h665544,24'(vn)} || !vol || !vou)
            $fatal(1,"video data/sidebands/order n=%d got=%h",vn,vout);
        vn=vn+1;
    end
    always @(posedge pclk) if (aov && aor) begin
        if (aout !== 32'h12340000+an) $fatal(1,"RX audio order");
        an=an+1;
    end
    always @(posedge aclk) if (tov && tor) begin
        if (tout !== 32'habcd0000+tn) $fatal(1,"TX audio order");
        tn=tn+1;
    end
    initial begin #200000; $fatal(1,"bridge timeout"); end
    initial begin
        repeat(12) @(negedge pclk);
        if (vr || ar || tr || vov || aov || tov) $fatal(1,"handshake during reset");
        rst_n=1;
        fork
            begin
                for (integer i=0;i<24;i=i+1) begin
                    @(negedge pclk); vdata={32'hffccbbaa,32'hff998877,32'hff665544,32'(i)}; vv=1;
                    do @(posedge pclk); while (!vr);
                    @(negedge pclk); vv=0;
                end
            end
            begin
                for (integer i=0;i<24;i=i+1) begin
                    @(negedge aclk); adata=32'h12340000+i; av=1;
                    do @(posedge aclk); while (!ar);
                    @(negedge aclk); av=0;
                end
            end
            begin
                for (integer i=0;i<24;i=i+1) begin
                    @(negedge pclk); tdata=32'habcd0000+i; tv=1;
                    do @(posedge pclk); while (!tr);
                    @(negedge pclk); tv=0;
                end
            end
        join
        wait(vn==24 && an==24 && tn==24);
        @(negedge pclk); ctrl=0;
        repeat(20) @(negedge pclk);
        if (vr || tr) $fatal(1,"disabled TX accepts DMA data");
        if (format !== 0 || status[1] !== 0) $fatal(1,"fabricated format/lock status");
        $display("TB_PASS: HDMI video/audio CDC, backpressure, RGB packing, resets and disabled TX");
        test_passed=1;
        $finish;
    end
endmodule
