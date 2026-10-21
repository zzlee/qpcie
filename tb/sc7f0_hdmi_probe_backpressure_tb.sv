`timescale 1ns / 1ps

// Regression for accepted AXI video beats, NOT a physical HDMI validation.
// Unmodified probe 0x26102001 is expected to fail: it counts TVALID while stalled.
module sc7f0_hdmi_probe_backpressure_tb;
    reg clk = 0;
    reg video_clk = 0;
    reg rst_n = 0;
    reg valid = 0;
    reg ready = 0;
    reg sof = 0;
    reg eol = 0;
    always #5 clk = ~clk;
    always #7 video_clk = ~video_clk;

    sc7f0_hdmi_probe dut (
        .clk(clk), .rst_n(rst_n),
        .clk_rx_mgtref(1'b0), .clk_dru_ref(1'b0), .clk_rxout(1'b0),
        .clk_rx_video(video_clk), .clk_tx_mgtref(1'b0),
        .clk_txout(1'b0), .clk_tx_video(1'b0),
        .hdmi_rx_5v_det(1'b0), .hdmi_rx_hpd_out(1'b0),
        .rx_ddc_scl_i(1'b1), .rx_ddc_scl_o(1'b1), .rx_ddc_scl_t(1'b1),
        .rx_ddc_sda_i(1'b1), .rx_ddc_sda_o(1'b1), .rx_ddc_sda_t(1'b1),
        .hdmi_tx_hpd_in(1'b0), .hdmi_tx_refclk_rdy(1'b0),
        .tx_ddc_scl_i(1'b1), .tx_ddc_sda_i(1'b1),
        .hdmi_phy_irq(1'b0), .hdmi_rx_irq(1'b0),
        .phy_status_sb_rx_tdata(8'b0), .phy_status_sb_rx_tvalid(1'b0),
        .phy_rx_axi4s_ch0_tvalid(1'b0), .phy_rx_axi4s_ch1_tvalid(1'b0),
        .phy_rx_axi4s_ch2_tvalid(1'b0),
        .rx_ss_video_tvalid(valid), .rx_ss_video_tready(ready),
        .rx_ss_video_tuser(sof), .rx_ss_video_tlast(eol), .probe_ctrl(32'b0)
    );

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge video_clk);
        valid = 1;
        sof = 1;
        eol = 1;
        // One beat held for eight video clocks with no accepted transfer.
        repeat (8) @(negedge video_clk);
        // Inspect source-domain counters directly; the 1-second CDC snapshot
        // and frequency meter are deliberately outside this focused test.
        if (dut.vid_sof_cnt !== 0 || dut.vid_eol_cnt !== 0 || dut.vid_pix_cnt !== 0)
            $fatal(1, "BACKPRESSURE_FAIL: no transfer but SOF=%0d EOL=%0d VALID_COUNT=%0d",
                   dut.vid_sof_cnt, dut.vid_eol_cnt, dut.vid_pix_cnt);
        ready = 1;
        @(negedge video_clk);
        valid = 0;
        ready = 0;
        sof = 0;
        eol = 0;
        if (dut.vid_sof_cnt !== 1 || dut.vid_eol_cnt !== 1 || dut.vid_pix_cnt !== 1)
            $fatal(1, "BACKPRESSURE_FAIL: one accepted beat must be counted exactly once");
        $display("BACKPRESSURE_PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "BACKPRESSURE_FAIL: simulation timeout");
    end
endmodule
