// ============================================================================
// Module: sc7f0_hdmi_probe
// Description: Hardware Probing and Frequency Meter Module for SC7F0 HDMI RX/TX.
//              Measures physical clocks, monitors pin levels, counts edges/pulses,
//              and tracks GTH/Video stream activity with zero fabric guessing.
//
// Clocks measured (via 1.000s gate against PS pl_clk0 99.990005 MHz):
//   1. rx_mgtrefclk1_odiv2_bufg (HDMI RX Clock from IT6663 P1TX, pins B10/B9)
//   2. dru_gtnorthrefclk1_odiv2_bufg (DRU Reference Clock, pins F10/F9)
//   3. phy_rxoutclk (GTH RX recovered clock)
//   4. phy_rx_video_clk (VPHY RX video pixel clock)
//   5. tx_mgtrefclk0_odiv2_bufg (HDMI TX Reference Clock, pins D10/D9)
//   6. phy_txoutclk (GTH TX clock)
//   7. phy_tx_video_clk (VPHY TX video clock)
//
// Signals monitored:
//   - 5V detect, HPD out, DDC SCL/SDA input and output/tri-state controls
//   - Video PHY sideband status, IRQs, AXI4-Stream valid beats, Video SOF/EOL
// ============================================================================

`timescale 1ns / 1ps

module sc7f0_freq_meter #(
    parameter [31:0] TIMEOUT_CYCLES = 32'd120_000_000
)(
    input  wire        ref_clk,          // 100MHz nominal (pl_clk0)
    input  wire        ref_rst_n,
    input  wire        sample_req_pulse, // 1-second pulse in ref_clk domain
    input  wire        test_clk,         // Asynchronous test clock to measure
    output reg  [31:0] measured_freq_hz, // Measured frequency in Hz
    output reg  [31:0] raw_cycle_count,  // Latest snapshot of raw cycle count
    output reg         clock_alive       // 1 if clock is running, 0 if stopped
);

    // Test clock domain prescaler & counter
    // 4-bit prescaler allows timing closure up to >600 MHz in UltraScale+
    reg [3:0]  prescale = 4'd0;
    reg [27:0] cnt_div16 = 28'd0;
    always @(posedge test_clk) begin
        prescale <= prescale + 1'b1;
        if (prescale == 4'b1111) begin
            cnt_div16 <= cnt_div16 + 1'b1;
        end
    end
    wire [31:0] test_full_cnt = {cnt_div16, prescale};

    // Toggle handshake between ref_clk and test_clk
    reg req_toggle = 1'b0;
    always @(posedge ref_clk or negedge ref_rst_n) begin
        if (!ref_rst_n) req_toggle <= 1'b0;
        else if (sample_req_pulse) req_toggle <= ~req_toggle;
    end

    // The snapshot bus is held until the next one-second request.
    wire req_sync;
    reg req_seen = 1'b0;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1)) u_req_cdc (
        .src_clk(ref_clk), .src_in(req_toggle),
        .dest_clk(test_clk), .dest_out(req_sync));
    always @(posedge test_clk) req_seen <= req_sync;
    wire req_event = req_sync ^ req_seen;

    reg [31:0] snapshot_test = 32'd0;
    reg ack_toggle = 1'b0;
    always @(posedge test_clk) begin
        if (req_event) begin
            snapshot_test <= test_full_cnt;
            ack_toggle <= ~ack_toggle;
        end
    end

    wire ack_sync;
    reg ack_seen = 1'b0;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1)) u_ack_cdc (
        .src_clk(test_clk), .src_in(ack_toggle),
        .dest_clk(ref_clk), .dest_out(ack_sync));
    always @(posedge ref_clk or negedge ref_rst_n) begin
        if (!ref_rst_n) ack_seen <= 1'b0;
        else ack_seen <= ack_sync;
    end
    wire ack_event = ack_sync ^ ack_seen;

    reg [31:0] prev_snapshot = 32'd0;
    reg [31:0] watchdog = 32'd0;

    always @(posedge ref_clk or negedge ref_rst_n) begin
        if (!ref_rst_n) begin
            measured_freq_hz <= 32'd0;
            raw_cycle_count  <= 32'd0;
            clock_alive      <= 1'b0;
            prev_snapshot    <= 32'd0;
            watchdog         <= 32'd0;
        end else begin
            if (watchdog < TIMEOUT_CYCLES)
                watchdog <= watchdog + 1'b1;

            if (ack_event) begin
                measured_freq_hz <= snapshot_test - prev_snapshot;
                raw_cycle_count  <= snapshot_test;
                prev_snapshot    <= snapshot_test;
                clock_alive      <= 1'b1;
                watchdog         <= 32'd0;
            end else if (watchdog >= TIMEOUT_CYCLES) begin
                measured_freq_hz <= 32'd0;
                clock_alive      <= 1'b0;
            end
        end
    end

endmodule


module sc7f0_hdmi_probe (
    input  wire        clk,                 // PS pl_clk0 (~100 MHz, exactly 99.990005 MHz)
    input  wire        rst_n,               // System reset active-low (sys_100m_rst_n)

    // Clocks to measure
    input  wire        clk_rx_mgtref,       // rx_mgtrefclk1_odiv2_bufg (Bank 226 MGTREFCLK1, pins B10/B9)
    input  wire        clk_dru_ref,         // dru_gtnorthrefclk1_odiv2_bufg (Bank 225 MGTREFCLK1, pins F10/F9)
    input  wire        clk_rxout,           // phy_rxoutclk (GTH RX recovered clock)
    input  wire        clk_rx_video,        // phy_rx_video_clk (VPHY RX video clock)
    input  wire        clk_tx_mgtref,       // tx_mgtrefclk0_odiv2_bufg (Bank 226 MGTREFCLK0, pins D10/D9)
    input  wire        clk_txout,           // phy_txoutclk (GTH TX clock)
    input  wire        clk_tx_video,        // phy_tx_video_clk (VPHY TX video clock)

    // Physical Signals to monitor
    input  wire        hdmi_rx_5v_det,      // Pin A12 (Cable 5V Detect)
    input  wire        hdmi_rx_hpd_out,     // Pin B12 (HPD Assert to Source)
    input  wire        rx_ddc_scl_i,        // Pin D14 (DDC SCL pad input)
    input  wire        rx_ddc_scl_o,        // DDC SCL output from RX SS
    input  wire        rx_ddc_scl_t,        // DDC SCL tri-state from RX SS (1=tristate/pullup, 0=drive low)
    input  wire        rx_ddc_sda_i,        // Pin C13 (DDC SDA pad input)
    input  wire        rx_ddc_sda_o,        // DDC SDA output from RX SS
    input  wire        rx_ddc_sda_t,        // DDC SDA tri-state from RX SS (1=tristate/pullup, 0=drive low)

    input  wire        hdmi_tx_hpd_in,      // Pin G14 (Sink HPD Input)
    input  wire        hdmi_tx_refclk_rdy,  // Pin G13 (X0_5319_LOL)
    input  wire        tx_ddc_scl_i,        // Pin F12
    input  wire        tx_ddc_sda_i,        // Pin E12

    input  wire        hdmi_phy_irq,        // VPHY IRQ to PS
    input  wire        hdmi_rx_irq,         // HDMI RX SS IRQ to PS

    // Video PHY and Subsystem sideband / stream activity
    input  wire [7:0]  phy_status_sb_rx_tdata,
    input  wire        phy_status_sb_rx_tvalid,
    input  wire        phy_rx_axi4s_ch0_tvalid,
    input  wire        phy_rx_axi4s_ch1_tvalid,
    input  wire        phy_rx_axi4s_ch2_tvalid,

    input  wire        rx_ss_video_tvalid,
    input  wire        rx_ss_video_tuser,
    input  wire        rx_ss_video_tlast,
    input  wire        rx_ss_video_tready,

    // Control from AXI-Lite
    input  wire [31:0] probe_ctrl,

    // Register Outputs to AXI-Lite space (BAR0 0x0680 - 0x06DC)
    output wire [31:0] reg_probe_version,
    output wire [31:0] reg_probe_rx_clk_freq,
    output wire [31:0] reg_probe_dru_clk_freq,
    output wire [31:0] reg_probe_rxoutclk_freq,
    output wire [31:0] reg_probe_rx_video_clk_freq,
    output wire [31:0] reg_probe_tx_clk_freq,
    output wire [31:0] reg_probe_txoutclk_freq,
    output wire [31:0] reg_probe_tx_video_clk_freq,
    output wire [31:0] reg_probe_pins,
    output wire [31:0] reg_probe_pulse_cnt1,
    output wire [31:0] reg_probe_ddc_cnt,
    output wire [31:0] reg_probe_irq_cnt,
    output reg  [31:0] reg_probe_ch0_beats,
    output reg  [31:0] reg_probe_ch1_beats,
    output reg  [31:0] reg_probe_ch2_beats,
    output reg  [31:0] reg_probe_rx_video_sof,
    output reg  [31:0] reg_probe_rx_video_eol,
    output reg  [31:0] reg_probe_rx_video_pix,
    output wire [31:0] reg_probe_raw_rx_clk,
    output wire [31:0] reg_probe_raw_dru_clk,
    output wire [31:0] reg_probe_raw_rxoutclk,
    output wire [31:0] reg_probe_raw_rx_video_clk,
    output reg  [31:0] reg_probe_raw_refclk100
);

    // Transfer-gated counters and synchronized diagnostic readout.
    assign reg_probe_version = 32'h2610_2201;

    // -------------------------------------------------------------------------
    // 1-Second Gate Generator (based on 99,990,005 Hz pl_clk0)
    // -------------------------------------------------------------------------
    localparam [26:0] REF_1S_CYCLES = 27'd99_990_005;
    reg [26:0] ref_gate_cnt = 27'd0;
    reg        sample_req_1s = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_gate_cnt  <= 27'd0;
            sample_req_1s <= 1'b0;
            reg_probe_raw_refclk100 <= 32'd0;
        end else begin
            reg_probe_raw_refclk100 <= reg_probe_raw_refclk100 + 1'b1;
            if (ref_gate_cnt >= (REF_1S_CYCLES - 1'b1)) begin
                ref_gate_cnt  <= 27'd0;
                sample_req_1s <= 1'b1;
            end else begin
                ref_gate_cnt  <= ref_gate_cnt + 1'b1;
                sample_req_1s <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Frequency Meters for all 7 physical and recovered clocks
    // -------------------------------------------------------------------------
    wire rx_clk_alive, dru_clk_alive, rxout_alive, rxvid_alive;
    wire tx_clk_alive, txout_alive, txvid_alive;

    // 1. HDMI RX Clock (Bank 226 MGTREFCLK1, B10/B9)
    sc7f0_freq_meter u_meter_rx_clk (
        .ref_clk(clk), .ref_rst_n(rst_n), .sample_req_pulse(sample_req_1s),
        .test_clk(clk_rx_mgtref),
        .measured_freq_hz(reg_probe_rx_clk_freq),
        .raw_cycle_count(reg_probe_raw_rx_clk),
        .clock_alive(rx_clk_alive)
    );

    // 2. DRU Reference Clock (Bank 225 MGTREFCLK1, F10/F9)
    sc7f0_freq_meter u_meter_dru_clk (
        .ref_clk(clk), .ref_rst_n(rst_n), .sample_req_pulse(sample_req_1s),
        .test_clk(clk_dru_ref),
        .measured_freq_hz(reg_probe_dru_clk_freq),
        .raw_cycle_count(reg_probe_raw_dru_clk),
        .clock_alive(dru_clk_alive)
    );

    // 3. GTH RX recovered clock (phy_rxoutclk)
    sc7f0_freq_meter u_meter_rxoutclk (
        .ref_clk(clk), .ref_rst_n(rst_n), .sample_req_pulse(sample_req_1s),
        .test_clk(clk_rxout),
        .measured_freq_hz(reg_probe_rxoutclk_freq),
        .raw_cycle_count(reg_probe_raw_rxoutclk),
        .clock_alive(rxout_alive)
    );

    // 4. Video PHY RX Video Clock (phy_rx_video_clk)
    sc7f0_freq_meter u_meter_rx_video_clk (
        .ref_clk(clk), .ref_rst_n(rst_n), .sample_req_pulse(sample_req_1s),
        .test_clk(clk_rx_video),
        .measured_freq_hz(reg_probe_rx_video_clk_freq),
        .raw_cycle_count(reg_probe_raw_rx_video_clk),
        .clock_alive(rxvid_alive)
    );

    // 5. HDMI TX Reference Clock (Bank 226 MGTREFCLK0, D10/D9)
    sc7f0_freq_meter u_meter_tx_clk (
        .ref_clk(clk), .ref_rst_n(rst_n), .sample_req_pulse(sample_req_1s),
        .test_clk(clk_tx_mgtref),
        .measured_freq_hz(reg_probe_tx_clk_freq),
        .raw_cycle_count(),
        .clock_alive(tx_clk_alive)
    );

    // 6. GTH TX clock (phy_txoutclk)
    sc7f0_freq_meter u_meter_txoutclk (
        .ref_clk(clk), .ref_rst_n(rst_n), .sample_req_pulse(sample_req_1s),
        .test_clk(clk_txout),
        .measured_freq_hz(reg_probe_txoutclk_freq),
        .raw_cycle_count(),
        .clock_alive(txout_alive)
    );

    // 7. Video PHY TX Video Clock (phy_tx_video_clk)
    sc7f0_freq_meter u_meter_tx_video_clk (
        .ref_clk(clk), .ref_rst_n(rst_n), .sample_req_pulse(sample_req_1s),
        .test_clk(clk_tx_video),
        .measured_freq_hz(reg_probe_tx_video_clk_freq),
        .raw_cycle_count(),
        .clock_alive(txvid_alive)
    );

    // -------------------------------------------------------------------------
    // Signal Synchronizers and Edge Counters (in clk / pl_clk0 domain)
    // -------------------------------------------------------------------------
    wire clear_counters = probe_ctrl[0];

    (* ASYNC_REG = "TRUE" *) reg [2:0] det5v_sync = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] hpd_sync   = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] scl_sync   = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] sda_sync   = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_hpd_sync = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_rdy_sync = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_scl_sync = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_sda_sync = 3'b000;

    reg [1:0] phy_irq_sync = 2'b00;
    reg [1:0] rx_irq_sync  = 2'b00;

    reg [15:0] det5v_edge_cnt = 16'd0;
    reg [15:0] hpd_edge_cnt   = 16'd0;
    reg [15:0] scl_fall_cnt   = 16'd0;
    reg [15:0] sda_edge_cnt   = 16'd0;
    reg [15:0] phy_irq_cnt    = 16'd0;
    reg [15:0] rx_irq_cnt     = 16'd0;

    reg [7:0]  latched_sb_rx_data = 8'd0;
    reg        latched_sb_rx_valid = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            det5v_sync  <= 3'b000;
            hpd_sync    <= 3'b000;
            scl_sync    <= 3'b000;
            sda_sync    <= 3'b000;
            tx_hpd_sync <= 3'b000;
            tx_rdy_sync <= 3'b000;
            tx_scl_sync <= 3'b000;
            tx_sda_sync <= 3'b000;
            phy_irq_sync <= 2'b00;
            rx_irq_sync  <= 2'b00;
            det5v_edge_cnt <= 16'd0;
            hpd_edge_cnt   <= 16'd0;
            scl_fall_cnt   <= 16'd0;
            sda_edge_cnt   <= 16'd0;
            phy_irq_cnt    <= 16'd0;
            rx_irq_cnt     <= 16'd0;
            latched_sb_rx_data <= 8'd0;
            latched_sb_rx_valid <= 1'b0;
        end else begin
            det5v_sync  <= {det5v_sync[1:0], hdmi_rx_5v_det};
            hpd_sync    <= {hpd_sync[1:0], hdmi_rx_hpd_out};
            scl_sync    <= {scl_sync[1:0], rx_ddc_scl_i};
            sda_sync    <= {sda_sync[1:0], rx_ddc_sda_i};
            tx_hpd_sync <= {tx_hpd_sync[1:0], hdmi_tx_hpd_in};
            tx_rdy_sync <= {tx_rdy_sync[1:0], hdmi_tx_refclk_rdy};
            tx_scl_sync <= {tx_scl_sync[1:0], tx_ddc_scl_i};
            tx_sda_sync <= {tx_sda_sync[1:0], tx_ddc_sda_i};
            phy_irq_sync <= {phy_irq_sync[0], hdmi_phy_irq};
            rx_irq_sync  <= {rx_irq_sync[0], hdmi_rx_irq};

            if (phy_status_sb_rx_tvalid) begin
                latched_sb_rx_data  <= phy_status_sb_rx_tdata;
                latched_sb_rx_valid <= 1'b1;
            end

            if (clear_counters) begin
                det5v_edge_cnt <= 16'd0;
                hpd_edge_cnt   <= 16'd0;
                scl_fall_cnt   <= 16'd0;
                sda_edge_cnt   <= 16'd0;
                phy_irq_cnt    <= 16'd0;
                rx_irq_cnt     <= 16'd0;
            end else begin
                if (det5v_sync[2] ^ det5v_sync[1]) det5v_edge_cnt <= det5v_edge_cnt + 1'b1;
                if (hpd_sync[2]   ^ hpd_sync[1])   hpd_edge_cnt   <= hpd_edge_cnt   + 1'b1;
                if (scl_sync[2] && !scl_sync[1])   scl_fall_cnt   <= scl_fall_cnt   + 1'b1;
                if (sda_sync[2]   ^ sda_sync[1])   sda_edge_cnt   <= sda_edge_cnt   + 1'b1;
                if (!phy_irq_sync[1] && phy_irq_sync[0]) phy_irq_cnt <= phy_irq_cnt + 1'b1;
                if (!rx_irq_sync[1]  && rx_irq_sync[0])  rx_irq_cnt  <= rx_irq_cnt  + 1'b1;
            end
        end
    end

    // Pin Level Register mapping
    // Independent diagnostic levels, not an atomic multi-signal snapshot.
    wire [31:0] raw_probe_pins = {
        rx_ss_video_tlast,          // [31]
        rx_ss_video_tuser,          // [30]
        rx_ss_video_tready,         // [29]
        rx_ss_video_tvalid,         // [28]
        phy_rx_axi4s_ch2_tvalid,    // [27]
        phy_rx_axi4s_ch1_tvalid,    // [26]
        phy_rx_axi4s_ch0_tvalid,    // [25]
        latched_sb_rx_valid,        // [24]
        latched_sb_rx_data,         // [23:16]
        dru_clk_alive,              // [15]
        rx_clk_alive,               // [14]
        tx_sda_sync[1],             // [13]
        tx_scl_sync[1],             // [12]
        tx_rdy_sync[1],             // [11]
        tx_hpd_sync[1],             // [10]
        rx_irq_sync[0],             // [9]
        phy_irq_sync[0],            // [8]
        rx_ddc_sda_t,               // [7]
        rx_ddc_sda_o,               // [6]
        rx_ddc_scl_t,               // [5]
        rx_ddc_scl_o,               // [4]
        sda_sync[1],                // [3]
        scl_sync[1],                // [2]
        hpd_sync[1],                // [1]
        det5v_sync[1]               // [0]
    };

    xpm_cdc_array_single #(.WIDTH(32), .DEST_SYNC_FF(3), .SRC_INPUT_REG(0),
                           .INIT_SYNC_FF(1)) u_pin_levels_cdc (
        .src_clk(clk), .src_in(raw_probe_pins),
        .dest_clk(clk), .dest_out(reg_probe_pins));

    assign reg_probe_pulse_cnt1 = {hpd_edge_cnt, det5v_edge_cnt};
    assign reg_probe_ddc_cnt    = {sda_edge_cnt, scl_fall_cnt};
    assign reg_probe_irq_cnt    = {rx_irq_cnt,   phy_irq_cnt};

    // -------------------------------------------------------------------------
    // GTH Channel Valid Beat Counters (clocked by clk_rxout)
    // -------------------------------------------------------------------------
    reg [31:0] beat_ch0_cnt = 32'd0;
    reg [31:0] beat_ch1_cnt = 32'd0;
    reg [31:0] beat_ch2_cnt = 32'd0;

    always @(posedge clk_rxout) begin
        if (phy_rx_axi4s_ch0_tvalid) beat_ch0_cnt <= beat_ch0_cnt + 1'b1;
        if (phy_rx_axi4s_ch1_tvalid) beat_ch1_cnt <= beat_ch1_cnt + 1'b1;
        if (phy_rx_axi4s_ch2_tvalid) beat_ch2_cnt <= beat_ch2_cnt + 1'b1;
    end

    // -------------------------------------------------------------------------
    // Video Subsystem Pixel & Frame Counters (clocked by clk_rx_video)
    // -------------------------------------------------------------------------
    reg [31:0] vid_sof_cnt = 32'd0;
    reg [31:0] vid_eol_cnt = 32'd0;
    reg [31:0] vid_pix_cnt = 32'd0;

    always @(posedge clk_rx_video) begin
        if (rx_ss_video_tvalid && rx_ss_video_tready && rx_ss_video_tuser) vid_sof_cnt <= vid_sof_cnt + 1'b1;
        if (rx_ss_video_tvalid && rx_ss_video_tready && rx_ss_video_tlast) vid_eol_cnt <= vid_eol_cnt + 1'b1;
        if (rx_ss_video_tvalid && rx_ss_video_tready) vid_pix_cnt <= vid_pix_cnt + 1'b1;
    end

    // Each counter crosses independently; the six values are not atomic.
    wire [31:0] beats0_sync, beats1_sync, beats2_sync;
    wire [31:0] sof_sync, eol_sync, pixels_sync;
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_beats0_cdc (
        .src_clk(clk_rxout), .src_in_bin(beat_ch0_cnt), .dest_clk(clk), .dest_out_bin(beats0_sync));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_beats1_cdc (
        .src_clk(clk_rxout), .src_in_bin(beat_ch1_cnt), .dest_clk(clk), .dest_out_bin(beats1_sync));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_beats2_cdc (
        .src_clk(clk_rxout), .src_in_bin(beat_ch2_cnt), .dest_clk(clk), .dest_out_bin(beats2_sync));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_sof_cdc (
        .src_clk(clk_rx_video), .src_in_bin(vid_sof_cnt), .dest_clk(clk), .dest_out_bin(sof_sync));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_eol_cdc (
        .src_clk(clk_rx_video), .src_in_bin(vid_eol_cnt), .dest_clk(clk), .dest_out_bin(eol_sync));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_pixels_cdc (
        .src_clk(clk_rx_video), .src_in_bin(vid_pix_cnt), .dest_clk(clk), .dest_out_bin(pixels_sync));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_probe_ch0_beats    <= 32'd0;
            reg_probe_ch1_beats    <= 32'd0;
            reg_probe_ch2_beats    <= 32'd0;
            reg_probe_rx_video_sof <= 32'd0;
            reg_probe_rx_video_eol <= 32'd0;
            reg_probe_rx_video_pix <= 32'd0;
        end else if (sample_req_1s) begin
            reg_probe_ch0_beats    <= beats0_sync;
            reg_probe_ch1_beats    <= beats1_sync;
            reg_probe_ch2_beats    <= beats2_sync;
            reg_probe_rx_video_sof <= sof_sync;
            reg_probe_rx_video_eol <= eol_sync;
            reg_probe_rx_video_pix <= pixels_sync;
        end
    end

endmodule
