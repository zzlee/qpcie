`timescale 1ns / 1ps

module sc7f0_hdmi_probe_tb;

    reg clk = 0;
    always #5 clk = ~clk; // 100 MHz reference clock

    reg rst_n = 0;

    // Test clocks
    reg clk_rx_mgtref = 0; // Simulate 148.5 MHz clock
    always #3.367 clk_rx_mgtref = ~clk_rx_mgtref;

    reg clk_dru_ref = 0;   // Simulate 156.25 MHz clock
    always #3.200 clk_dru_ref = ~clk_dru_ref;

    reg clk_dead = 0;      // 0 Hz stopped clock

    // Signals
    reg hdmi_rx_5v_det = 0;
    reg hdmi_rx_hpd_out = 0;
    reg rx_ddc_scl_i = 1;
    reg rx_ddc_scl_o = 1;
    reg rx_ddc_scl_t = 1;
    reg rx_ddc_sda_i = 1;
    reg rx_ddc_sda_o = 1;
    reg rx_ddc_sda_t = 1;

    reg [31:0] probe_ctrl = 0;

    wire [31:0] reg_probe_version;
    wire [31:0] reg_probe_rx_clk_freq;
    wire [31:0] reg_probe_dru_clk_freq;
    wire [31:0] reg_probe_rxoutclk_freq;
    wire [31:0] reg_probe_pins;
    wire [31:0] reg_probe_ddc_cnt;

    // We can override REF_1S_CYCLES for fast simulation (e.g. 1000 cycles = 10 us)
    sc7f0_hdmi_probe u_probe (
        .clk(clk),
        .rst_n(rst_n),
        .clk_rx_mgtref(clk_rx_mgtref),
        .clk_dru_ref(clk_dru_ref),
        .clk_rxout(clk_dead),
        .clk_rx_video(clk_dead),
        .clk_tx_mgtref(clk_dead),
        .clk_txout(clk_dead),
        .clk_tx_video(clk_dead),

        .hdmi_rx_5v_det(hdmi_rx_5v_det),
        .hdmi_rx_hpd_out(hdmi_rx_hpd_out),
        .rx_ddc_scl_i(rx_ddc_scl_i),
        .rx_ddc_scl_o(rx_ddc_scl_o),
        .rx_ddc_scl_t(rx_ddc_scl_t),
        .rx_ddc_sda_i(rx_ddc_sda_i),
        .rx_ddc_sda_o(rx_ddc_sda_o),
        .rx_ddc_sda_t(rx_ddc_sda_t),

        .hdmi_tx_hpd_in(1'b0),
        .hdmi_tx_refclk_rdy(1'b0),
        .tx_ddc_scl_i(1'b1),
        .tx_ddc_sda_i(1'b1),

        .hdmi_phy_irq(1'b0),
        .hdmi_rx_irq(1'b0),

        .phy_status_sb_rx_tdata(8'hA5),
        .phy_status_sb_rx_tvalid(1'b1),
        .phy_rx_axi4s_ch0_tvalid(1'b0),
        .phy_rx_axi4s_ch1_tvalid(1'b0),
        .phy_rx_axi4s_ch2_tvalid(1'b0),

        .rx_ss_video_tvalid(1'b0),
        .rx_ss_video_tuser(1'b0),
        .rx_ss_video_tlast(1'b0),
        .rx_ss_video_tready(1'b1),

        .probe_ctrl(probe_ctrl),

        .reg_probe_version(reg_probe_version),
        .reg_probe_rx_clk_freq(reg_probe_rx_clk_freq),
        .reg_probe_dru_clk_freq(reg_probe_dru_clk_freq),
        .reg_probe_rxoutclk_freq(reg_probe_rxoutclk_freq),
        .reg_probe_rx_video_clk_freq(),
        .reg_probe_tx_clk_freq(),
        .reg_probe_txoutclk_freq(),
        .reg_probe_tx_video_clk_freq(),
        .reg_probe_pins(reg_probe_pins),
        .reg_probe_pulse_cnt1(),
        .reg_probe_ddc_cnt(reg_probe_ddc_cnt),
        .reg_probe_irq_cnt(),
        .reg_probe_ch0_beats(),
        .reg_probe_ch1_beats(),
        .reg_probe_ch2_beats(),
        .reg_probe_rx_video_sof(),
        .reg_probe_rx_video_eol(),
        .reg_probe_rx_video_pix(),
        .reg_probe_raw_rx_clk(),
        .reg_probe_raw_dru_clk(),
        .reg_probe_raw_rxoutclk(),
        .reg_probe_raw_rx_video_clk(),
        .reg_probe_raw_refclk100()
    );

    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
        #100;

        // Verify version
        if (reg_probe_version !== 32'h2610_2001) begin
            $display("ERROR: Invalid probe version 0x%08x", reg_probe_version);
            $finish(1);
        end

        // Test DDC pulses
        #200;
        rx_ddc_scl_i = 0; #500; rx_ddc_scl_i = 1; #500;
        rx_ddc_scl_i = 0; #500; rx_ddc_scl_i = 1; #500;
        rx_ddc_scl_i = 0; #500; rx_ddc_scl_i = 1; #500;
        #200;

        // Check DDC falling edge count
        if (reg_probe_ddc_cnt[15:0] !== 16'd3) begin
            $display("ERROR: Expected 3 DDC SCL edges, got %d", reg_probe_ddc_cnt[15:0]);
            $finish(1);
        end

        // Check pin monitoring (5V, HPD, DDC)
        hdmi_rx_5v_det = 1;
        hdmi_rx_hpd_out = 1;
        #100;
        if (reg_probe_pins[0] !== 1'b1 || reg_probe_pins[1] !== 1'b1) begin
            $display("ERROR: Pin status mismatch 0x%08x", reg_probe_pins);
            $finish(1);
        end

        $display("PROBE_TEST_PASS: Logic and monitoring verified successfully!");
        $finish(0);
    end

endmodule
