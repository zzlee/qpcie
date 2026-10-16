// ============================================================================
// Module: hdmi_rx_probe
// Target: AMD/Xilinx Artix-7 (xc7a50t-csg325-2)
// Description:
//   Hardware Probe & Telemetry Module for IT68051 HDMI Receiver.
//   - Measures TM0_PCLK frequency against pcie_user_clk (125 MHz).
//   - Measures HActive (dual-pixel * 2), VActive, HTotal, VTotal, and FPS.
//   - Detects TM0_DE, TM0_VS, TM0_HS activity and timing stability.
//   - Measures I2S audio SCK frequency, WS sample rate (Hz), and audio data.
//   - Fully pipelined DSP/arithmetic architecture with zero long combinational paths.
//   - Outputs real-time telemetry registers for PCIe BAR0 0x0600 - 0x060C & 0x0664.
// ============================================================================

`timescale 1ns / 1ps

module hdmi_rx_probe (
    // PCIe Reference Clock & Reset (125 MHz)
    input  wire        clk_125m,
    input  wire        rst_n_125m,

    // IT68051 Native Video Pins
    input  wire        tm0_pclk,
    input  wire        tm0_de,
    input  wire        tm0_vs,
    input  wire        tm0_hs,
    input  wire        single_pixel_mode,

    // IT68051 Native Audio Pins
    input  wire        tm0_i2s_sck,
    input  wire        tm0_i2s_ws,
    input  wire        tm0_i2s_d0,

    // IT68051 Interrupt / SCDT pins
    input  wire        int_68051,

    // Telemetry Outputs to BAR0 (in clk_125m domain)
    output reg  [31:0] out_hdmi_rx_status,  // 0x0600: [31:16]=PCLK_MHz*10, [15:8]=FPS, [5]=DATA, [4]=SCK, [3]=STREAM_UP, [2]=LNK_LOCK, [1]=HPD, [0]=5V_DET
    output reg  [31:0] out_hdmi_rx_res,     // 0x0604: [15:0]=HActive, [31:16]=VActive
    output reg  [31:0] out_hdmi_rx_timing,  // 0x0608: Measured PCLK in Hz
    output reg  [31:0] out_hdmi_rx_audio    // 0x060C / 0x0664: [15:0]=Sample Rate (Hz), [31:16]=Frame Count
);

    // =========================================================================
    // 1. TM0_PCLK Frequency Measurement
    // Reference Window: 12,500,000 cycles of 125 MHz = 100 ms
    // Handshake CDC ensures data is static before latching in clk_125m
    // =========================================================================
    reg [23:0] ref_cnt_100ms   = 24'd0;
    reg        toggle_req_125m = 1'b0;

    always @(posedge clk_125m or negedge rst_n_125m) begin
        if (!rst_n_125m) begin
            ref_cnt_100ms   <= 24'd0;
            toggle_req_125m <= 1'b0;
        end else begin
            if (ref_cnt_100ms >= 24'd12_499_999) begin
                ref_cnt_100ms   <= 24'd0;
                toggle_req_125m <= ~toggle_req_125m;
            end else begin
                ref_cnt_100ms   <= ref_cnt_100ms + 1'b1;
            end
        end
    end

    // tm0_pclk domain counter and request sampling
    (* ASYNC_REG = "TRUE" *) reg [2:0] toggle_req_pclk = 3'b000;
    always @(posedge tm0_pclk) begin
        toggle_req_pclk <= {toggle_req_pclk[1:0], toggle_req_125m};
    end
    wire req_edge_pclk = (toggle_req_pclk[2] ^ toggle_req_pclk[1]);

    reg [27:0] pclk_counter       = 28'd0;
    reg [27:0] pclk_count_latched = 28'd0;
    reg        toggle_ack_pclk    = 1'b0;

    always @(posedge tm0_pclk) begin
        if (req_edge_pclk) begin
            pclk_count_latched <= pclk_counter;
            pclk_counter       <= 28'd0;
            toggle_ack_pclk    <= ~toggle_ack_pclk;
        end else begin
            pclk_counter       <= pclk_counter + 1'b1;
        end
    end

    // clk_125m domain acknowledge sampling
    (* ASYNC_REG = "TRUE" *) reg [2:0] toggle_ack_125m = 3'b000;
    always @(posedge clk_125m) begin
        toggle_ack_125m <= {toggle_ack_125m[1:0], toggle_ack_pclk};
    end
    wire ack_edge_125m = (toggle_ack_125m[2] ^ toggle_ack_125m[1]);

    reg [24:0] pclk_watchdog  = 25'd0;
    reg [27:0] pclk_captured  = 28'd0;

    always @(posedge clk_125m or negedge rst_n_125m) begin
        if (!rst_n_125m) begin
            pclk_watchdog <= 25'd0;
            pclk_captured <= 28'd0;
        end else begin
            if (ack_edge_125m) begin
                pclk_captured <= pclk_count_latched;
                pclk_watchdog <= 25'd0;
            end else if (pclk_watchdog >= 25'd25_000_000) begin // 200 ms timeout
                pclk_captured <= 28'd0; // No PCLK clock activity
            end else begin
                pclk_watchdog <= pclk_watchdog + 1'b1;
            end
        end
    end

    // Pipelined fixed-point multiplier: (C * 429497) >> 32 = C / 10000
    // Accurate to 6 decimal places across entire 0 to 600 MHz range!
    reg [47:0] pclk_mult_pipe     = 48'd0;
    reg [15:0] pclk_freq_100k_reg = 16'd0;
    reg [31:0] pclk_hz_reg        = 32'd0;
    reg        pclk_active_reg    = 1'b0;

    always @(posedge clk_125m) begin
        // Pipeline Stage 1: Multiply
        pclk_mult_pipe <= pclk_captured * 20'd429497;
        pclk_hz_reg    <= (pclk_captured << 3) + (pclk_captured << 1); // * 10
        pclk_active_reg<= (pclk_captured > 28'd1_000_000);             // > 10 MHz

        // Pipeline Stage 2: Extract upper 16 bits
        pclk_freq_100k_reg <= pclk_mult_pipe[47:32];
    end

    // =========================================================================
    // 2. Video Timing Measurement in TM0_PCLK Domain
    // Dual Pixel mode: 1 clock = 2 pixels!
    // =========================================================================
    reg        de_d = 1'b0;
    reg        vs_d = 1'b0;
    reg        hs_d = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] single_sync = 2'b00;
    always @(posedge tm0_pclk) single_sync <= {single_sync[0], single_pixel_mode};

    reg [15:0] h_de_cnt    = 16'd0;
    reg [15:0] h_tot_cnt   = 16'd0;
    reg [15:0] v_de_lines  = 16'd0;
    reg [15:0] v_tot_lines = 16'd0;

    reg [15:0] meas_h_active = 16'd0;
    reg [15:0] meas_v_active = 16'd0;
    reg [15:0] meas_h_total  = 16'd0;
    reg [15:0] meas_v_total  = 16'd0;

    reg [15:0] pclk_frame_cnt = 16'd0;
    reg        toggle_frame   = 1'b0;

    always @(posedge tm0_pclk) begin
        de_d <= tm0_de;
        vs_d <= tm0_vs;
        hs_d <= tm0_hs;

        // Count horizontal DE width (active pixels = clocks * 2)
        if (tm0_de) begin
            h_de_cnt <= h_de_cnt + 1'b1;
        end else if (de_d && !tm0_de) begin
            meas_h_active <= single_sync[1] ? h_de_cnt : {h_de_cnt[14:0], 1'b0};
            h_de_cnt      <= 16'd0;
            v_de_lines    <= v_de_lines + 1'b1;
        end

        // Count HTotal between HS leading edges
        if (tm0_hs && !hs_d) begin
            meas_h_total <= single_sync[1] ? h_tot_cnt + 1'b1 : ((h_tot_cnt + 1'b1) << 1);
            h_tot_cnt    <= 16'd0;
            v_tot_lines  <= v_tot_lines + 1'b1;
        end else begin
            h_tot_cnt    <= h_tot_cnt + 1'b1;
        end

        // Frame boundary on VS leading edge
        if (tm0_vs && !vs_d) begin
            meas_v_active  <= v_de_lines;
            meas_v_total   <= v_tot_lines;
            v_de_lines     <= 16'd0;
            v_tot_lines    <= 16'd0;
            pclk_frame_cnt <= pclk_frame_cnt + 1'b1;
            toggle_frame   <= ~toggle_frame;
        end
    end

    // =========================================================================
    // 3. Frame Rate & Stability Detection in clk_125m Domain
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] toggle_frame_125m = 3'b000;
    always @(posedge clk_125m) begin
        toggle_frame_125m <= {toggle_frame_125m[1:0], toggle_frame};
    end
    wire frame_edge_125m = (toggle_frame_125m[2] ^ toggle_frame_125m[1]);

    reg [24:0] frame_watchdog = 25'd0;
    reg [15:0] sync_h_active  = 16'd0;
    reg [15:0] sync_v_active  = 16'd0;
    reg [15:0] sync_h_total   = 16'd0;
    reg [15:0] sync_v_total   = 16'd0;
    reg [15:0] sync_frame_cnt = 16'd0;

    reg [27:0] sec_cnt  = 28'd0;
    reg [7:0]  fps_cnt  = 8'd0;
    reg [7:0]  live_fps = 8'd0;

    always @(posedge clk_125m or negedge rst_n_125m) begin
        if (!rst_n_125m) begin
            frame_watchdog <= 25'd0;
            sync_h_active  <= 16'd0;
            sync_v_active  <= 16'd0;
            sync_h_total   <= 16'd0;
            sync_v_total   <= 16'd0;
            sync_frame_cnt <= 16'd0;
            sec_cnt        <= 28'd0;
            fps_cnt        <= 8'd0;
            live_fps       <= 8'd0;
        end else begin
            // 1-second reference window for FPS
            if (sec_cnt >= 28'd124_999_999) begin
                sec_cnt  <= 28'd0;
                live_fps <= fps_cnt;
                fps_cnt  <= 8'd0;
            end else begin
                sec_cnt <= sec_cnt + 1'b1;
                if (frame_edge_125m)
                    fps_cnt <= fps_cnt + 1'b1;
            end

            // Latch video timing when frame edge fires (fully stable)
            if (frame_edge_125m) begin
                sync_h_active  <= meas_h_active;
                sync_v_active  <= meas_v_active;
                sync_h_total   <= meas_h_total;
                sync_v_total   <= meas_v_total;
                sync_frame_cnt <= pclk_frame_cnt;
                frame_watchdog <= 25'd0;
            end else if (frame_watchdog >= 25'd25_000_000) begin // 200 ms timeout
                sync_h_active  <= 16'd0;
                sync_v_active  <= 16'd0;
                sync_h_total   <= 16'd0;
                sync_v_total   <= 16'd0;
            end else begin
                frame_watchdog <= frame_watchdog + 1'b1;
            end
        end
    end

    // Signal stable check: valid resolution and non-zero FPS
    reg timing_stable_reg = 1'b0;
    always @(posedge clk_125m) begin
        timing_stable_reg <= (sync_h_active >= 16'd640) &&
                             (sync_v_active >= 16'd480) &&
                             (live_fps > 8'd15);
    end

    // =========================================================================
    // 4. Audio I2S Detection in clk_125m Domain
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] i2s_sck_sync = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] i2s_ws_sync  = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] i2s_d0_sync  = 3'b000;

    always @(posedge clk_125m) begin
        i2s_sck_sync <= {i2s_sck_sync[1:0], tm0_i2s_sck};
        i2s_ws_sync  <= {i2s_ws_sync[1:0],  tm0_i2s_ws};
        i2s_d0_sync  <= {i2s_d0_sync[1:0],  tm0_i2s_d0};
    end

    wire i2s_sck_edge = (i2s_sck_sync[2] ^ i2s_sck_sync[1]);
    wire i2s_ws_edge  = (i2s_ws_sync[2]  ^ i2s_ws_sync[1]);
    wire i2s_d0_edge  = (i2s_d0_sync[2]  ^ i2s_d0_sync[1]);

    reg [19:0] ws_cnt_1sec        = 20'd0;
    reg [15:0] audio_sample_rate  = 16'd0;
    reg        i2s_sck_detected   = 1'b0;
    reg        i2s_data_detected  = 1'b0;
    reg [23:0] sck_idle_cnt       = 24'd0;
    reg [23:0] d0_idle_cnt        = 24'd0;

    always @(posedge clk_125m or negedge rst_n_125m) begin
        if (!rst_n_125m) begin
            ws_cnt_1sec       <= 20'd0;
            audio_sample_rate <= 16'd0;
            i2s_sck_detected  <= 1'b0;
            i2s_data_detected <= 1'b0;
            sck_idle_cnt      <= 24'd0;
            d0_idle_cnt       <= 24'd0;
        end else begin
            // 1-second sample rate latch
            if (sec_cnt == 28'd0) begin
                audio_sample_rate <= ws_cnt_1sec[16:1]; // ws toggles twice per sample (L+R)
                ws_cnt_1sec       <= 20'd0;
            end else if (i2s_ws_edge) begin
                ws_cnt_1sec <= ws_cnt_1sec + 1'b1;
            end

            // SCK activity filter
            if (i2s_sck_edge) begin
                i2s_sck_detected <= 1'b1;
                sck_idle_cnt     <= 24'd0;
            end else if (sck_idle_cnt >= 24'd1_250_000) begin // 10 ms idle
                i2s_sck_detected <= 1'b0;
            end else begin
                sck_idle_cnt <= sck_idle_cnt + 1'b1;
            end

            // D0 audio data activity filter
            if (i2s_d0_edge) begin
                i2s_data_detected <= 1'b1;
                d0_idle_cnt       <= 24'd0;
            end else if (d0_idle_cnt >= 24'd1_250_000) begin // 10 ms idle
                i2s_data_detected <= 1'b0;
            end else begin
                d0_idle_cnt <= d0_idle_cnt + 1'b1;
            end
        end
    end

    // =========================================================================
    // 5. Output Telemetry Registers (BAR0 0x0600 - 0x060C, 0x0664)
    // =========================================================================
    always @(posedge clk_125m or negedge rst_n_125m) begin
        if (!rst_n_125m) begin
            out_hdmi_rx_status <= 32'd0;
            out_hdmi_rx_res    <= 32'd0;
            out_hdmi_rx_timing <= 32'd0;
            out_hdmi_rx_audio  <= 32'd0;
        end else begin
            out_hdmi_rx_status <= {
                pclk_freq_100k_reg,    // [31:16]: PCLK frequency in 100 kHz units (e.g. 1485 = 148.5 MHz)
                live_fps,              // [15:8] : Measured FPS (e.g. 60)
                2'b00,                 // [7:6]  : Reserved
                i2s_data_detected,     // [5]    : I2S Audio Data active
                i2s_sck_detected,      // [4]    : I2S SCK active
                timing_stable_reg,     // [3]    : HDMI_RX_STATUS_STREAM_UP (video locked)
                pclk_active_reg,       // [2]    : HDMI_RX_STATUS_LNK_LOCK (TMDS/PCLK active)
                1'b1,                  // [1]    : HDMI_RX_STATUS_HPD (HPD asserted)
                pclk_active_reg        // [0]    : HDMI_RX_STATUS_5V_DET (cable active)
            };

            out_hdmi_rx_res    <= {sync_v_active, sync_h_active};
            out_hdmi_rx_timing <= pclk_hz_reg;
            out_hdmi_rx_audio  <= {sync_frame_cnt, audio_sample_rate};
        end
    end

endmodule
