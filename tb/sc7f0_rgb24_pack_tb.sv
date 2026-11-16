`timescale 1ns/1ps
// ============================================================================
// tb/sc7f0_rgb24_pack_tb.sv  -  SC7F0-RGB-COMPOSITOR-2PPC packed RGB24 gearbox
//
// Proves, against the real DUT and the real XPM FIFO:
//   T0 startup policy  : a frame whose SOF arrives while the crossing FIFO is
//                        still inside its own reset is discarded IN ITS
//                        ENTIRETY (zero beats published), the stage re-arms on
//                        the next SOF and publishes the following frame
//                        byte-exactly.  A partial frame with a 96-byte hole is
//                        the failure this test exists to catch.
//   T1 byte order      : a 2 PPC RGB888 beat (UG934 native R=[23:16],
//                        B=[15:8], G=[7:0]) becomes memory-order bytes R,G,B
//                        ascending inside the 16-byte DMA beat; no alpha byte is
//                        inserted and nothing is truncated.  The golden bytes
//                        come from the pixel field semantics of
//                        rtl/hdmi_rx_pixel_pack.v (R at the lowest address, then
//                        the [7:0] field, then the [15:8] field), never from the
//                        DUT wiring, so a swapped pair of fields cannot be
//                        agreed with by construction.
//   T2 beat ratio      : 8 native beats (48 B) produce exactly 3 DMA beats
//                        (48 B) for the 4K60 geometry, and 720 DMA beats per
//                        3840-pixel line (11,520 B), i.e. a DMA beat never
//                        straddles two lines.
//   T3 frame sideband  : exactly one DMA beat per frame carries tuser=1 and it is
//                        the beat holding byte 0 of the frame.
//   T4 no source stall : s_axis_tready is constant 1 (a live TMDS source can
//                        never be back-pressured).
//   T5 overrun policy  : when the crossing FIFO cannot absorb a frame the stage
//                        abandons the frame, raises overflow_sticky and stops
//                        queueing; the stream is never partially published after
//                        that point, and exactly one refusal is charged per
//                        abandoned frame.
// ============================================================================
module sc7f0_rgb24_pack_tb;
    localparam integer PPC = 2;

    reg s_clk = 0, m_clk = 0;
    reg s_rst_n = 0, m_rst_n = 0;
    always #1.7 s_clk = ~s_clk;      // ~294 MHz (video side)
    always #4.0 m_clk = ~m_clk;      // 125 MHz  (PCIe side)

    reg  [PPC*24-1:0] tdata = 0;
    reg               tvalid = 0, tlast = 0, tuser = 0;
    wire              tready;
    wire [127:0]      m_tdata;
    wire              m_tuser, m_tvalid;
    reg               m_tready = 1;
    wire [6:0]        m_avail;          // [$clog2(FIFO_DEPTH):0] with FIFO_DEPTH=64
    wire              ovf_sticky, eol_sticky;

    integer errors = 0;
    reg gate_pass = 1'b0;

    sc7f0_rgb24_axis_pack #(.NATIVE_PPC(PPC), .FIFO_DEPTH(64)) dut (
        .s_clk(s_clk), .s_rst_n(s_rst_n),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid),
        .s_axis_tlast(tlast), .s_axis_tuser(tuser), .s_axis_tready(tready),
        .m_clk(m_clk), .m_rst_n(m_rst_n),
        .m_axis_tdata(m_tdata), .m_axis_tuser(m_tuser),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_avail(m_avail),
        .overflow_sticky(ovf_sticky), .line_align_sticky(eol_sticky)
    );

    // ------------------------------------------------------------------------
    // golden byte queue: everything the source pushes is appended in memory
    // order; every published DMA beat is compared against the front of the queue.
    // ------------------------------------------------------------------------
    reg [7:0] gold [0:262143];
    integer gp = 0, ghead = 0;         // produced / consumed
    integer beats_seen = 0, sof_beats = 0;
    integer sof_index = -1;            // beat index that carried tuser
    integer ready_low_cycles = 0;
    // Frames that are expected to be dropped are driven but not recorded.
    reg rec = 1'b1;
    reg [23:0] fp0 = 24'hxxxxxx, fp1 = 24'hxxxxxx;   // first two native pixels
    reg [127:0] first_beat;
    reg first_beat_saved = 1'b0;

    // Every wait loop below is bounded; the watchdog makes an unreachable
    // condition a reported FAIL instead of an xsimk that spins for 30 minutes.
    initial begin : watchdog
        #2_000_000;                       // whole suite needs ~200 us of sim time
        $display("TB_WATCHDOG_TIMEOUT sc7f0_rgb24_pack_tb: no $finish within 2 ms (beats=%0d produced=%0d published=%0d)",
                 beats_seen, gp, ghead);
        gate_pass = 1'b0;
        $display("RGB24_PACK_TB_FAIL");
        $finish;
    end

    always @(posedge s_clk) if (!tready && s_rst_n) ready_low_cycles <= ready_low_cycles + 1;

    integer bi;
    always @(posedge m_clk) begin
        if (m_rst_n && m_tvalid && m_tready) begin
            beats_seen = beats_seen + 1;
            if (!first_beat_saved) begin
                first_beat      = m_tdata;
                first_beat_saved = 1'b1;
            end
            if (m_tuser) begin
                sof_beats = sof_beats + 1;
                if (sof_index < 0) sof_index = beats_seen - 1;
            end
            for (bi = 0; bi < 16; bi = bi + 1) begin
                if (ghead + bi < gp) begin
                    if (m_tdata[bi*8 +: 8] !== gold[ghead + bi]) begin
                        errors = errors + 1;
                        $display("T1/T2 FAIL beat %0d byte %0d got %02h want %02h",
                                 beats_seen, bi, m_tdata[bi*8 +: 8], gold[ghead+bi]);
                    end
                end else begin
                    errors = errors + 1;
                    $display("T2 FAIL beat %0d byte %0d published beyond produced stream", beats_seen, bi);
                end
            end
            ghead = ghead + 16;
        end
    end

    // ------------------------------------------------------------------------
    // Golden byte order is derived from the UG934 native fields exactly as the
    // proven host formatter rtl/hdmi_rx_pixel_pack.v does it: R is the lowest
    // memory byte, then the native G field [7:0], then the native B field
    // [15:8].  It is deliberately not derived from the DUT's wiring.
    task automatic pixel_bytes(input [23:0] pix);
        begin
            if (rec) begin
                gold[gp]   = pix[23:16];       // R
                gold[gp+1] = pix[7:0];         // G
                gold[gp+2] = pix[15:8];        // B
                gp = gp + 3;
            end
        end
    endtask

    // Drive one frame: H lines of W pixels, 2 pixels per beat.
    task automatic drive_frame(input integer w, input integer h, input integer seed);
        integer ln, px;
        reg [23:0] p0, p1;
        begin
            for (ln = 0; ln < h; ln = ln + 1) begin
                for (px = 0; px < w/2; px = px + 1) begin
                    p0 = {8'd0, 8'd0, 8'd0};
                    p0[23:16] = (ln*37 + px*3 + seed) & 8'hff;          // R
                    p0[15:8]  = (ln*11 + px*5 + 2*seed) & 8'hff;        // B
                    p0[7:0]   = (ln*29 + px*7 + 3*seed) & 8'hff;        // G
                    p1[23:16] = p0[23:16] ^ 8'h5a;
                    p1[15:8]  = p0[15:8]  ^ 8'h3c;
                    p1[7:0]   = p0[7:0]   ^ 8'h69;
                    @(posedge s_clk);
                    tdata  <= {p1, p0};
                    tvalid <= 1'b1;
                    tuser  <= (ln == 0 && px == 0);
                    tlast  <= (px == w/2 - 1);
                    if (rec && ln == 0 && px == 0) begin
                        fp0 = p0; fp1 = p1;
                    end
                    pixel_bytes(p0);
                    pixel_bytes(p1);
                end
            end
            @(posedge s_clk);
            tvalid <= 1'b0; tuser <= 1'b0; tlast <= 1'b0;
        end
    endtask

    integer w, h;
    integer total_bytes, exp_beats, before_cnt;
    integer full0, busy0, k;
    initial begin
        // T4: readiness must never drop while the source is live
        #200;
        s_rst_n = 1; m_rst_n = 1;

        // ---- T0: SOF arrives while the crossing is still in reset ----------
        // A live TMDS source does not wait for the crossing, so this is ordinary
        // stimulus, not an illegal one: the DUT must throw that frame away whole
        // and lock onto the next one.  One s_clk after rst_n went high the reset
        // chain (two xpm_cdc_async_rst stages of DEST_SYNC_FF=4) cannot possibly
        // have released the write domain, so the window is deterministic.
        @(posedge s_clk);
        if (dut.fifo_ready !== 1'b0) begin
            errors = errors + 1;
            $display("T0 SETUP FAIL crossing already ready 1 s_clk after reset release (w_all_n=%b wr_busy=%b); cannot exercise the startup drop",
                     dut.w_all_n, dut.fifo_wr_busy);
        end
        rec = 1'b0;
        drive_frame(64, 8, 8'h55);              // 1,536 B = 96 DMA beats
        rec = 1'b1;
        repeat (200) @(posedge m_clk);
        if (beats_seen != 0) begin
            errors = errors + 1;
            $display("T0 FAIL published %0d beats for a frame that started while the crossing was in reset (want 0: discard the whole frame)",
                     beats_seen);
        end
        if (dut.ovf_busy_cnt == 0) begin
            errors = errors + 1;
            $display("T0 FAIL a crossing refusal was not counted (ovf_busy_cnt=0)");
        end
        if (ovf_sticky !== 1'b1) begin
            errors = errors + 1;
            $display("T0 FAIL overflow_sticky not raised by the startup refusal");
        end
        if (eol_sticky === 1'b1) begin
            errors = errors + 1;
            $display("T0 FAIL discarded frame reported as a line-alignment violation");
        end
        k = 0;
        while (dut.fifo_ready !== 1'b1 && k < 4000) begin
            @(posedge s_clk); k = k + 1;
        end
        if (dut.fifo_ready !== 1'b1) begin
            errors = errors + 1;
            $display("T0 FAIL crossing never became ready (%0d s_clk waited)", k);
        end
        $display("SC7F0_RGB24_PACK T0 startup_frame_discarded_whole=1 ready_after=%0d_s_clk beats=%0d ovf_busy_cnt=%0d",
                 k, beats_seen, dut.ovf_busy_cnt);

        // ---- T1/T2/T3: 1920x4 RGB24 = 23,040 B = 1,440 DMA beats ----------
        // The crossing is now legally out of reset: this is the frame whose
        // bytes must come out bit-exact.
        w = 1920; h = 4;
        total_bytes = w*3*h;
        exp_beats   = total_bytes/16;
        full0 = dut.ovf_full_cnt;
        busy0 = dut.ovf_busy_cnt;
        drive_frame(1920, 4, 8'h11);
        // drain, bounded
        k = 0;
        while (ghead < gp && k < 40000) begin
            @(posedge m_clk); k = k + 1;
        end
        if (ghead != gp) begin
            errors = errors + 1;
            $display("T2 FAIL stream stalled: produced %0d bytes, published %0d", gp, ghead);
        end
        if (beats_seen != exp_beats) begin
            errors = errors + 1;
            $display("T2 FAIL beat count %0d, want %0d (bytes/16)", beats_seen, exp_beats);
        end
        if (sof_beats != 1 || sof_index != 0) begin
            errors = errors + 1;
            $display("T3 FAIL sof_beats=%0d first_sof_beat_index=%0d (want exactly one, at beat 1)",
                     sof_beats, sof_index);
        end
        if (dut.ovf_full_cnt != full0 || dut.ovf_busy_cnt != busy0) begin
            errors = errors + 1;
            $display("T3 FAIL the crossing refused a beat on a drainable frame (full %0d->%0d, not-ready %0d->%0d)",
                     full0, dut.ovf_full_cnt, busy0, dut.ovf_busy_cnt);
        end
        if (eol_sticky === 1'b1) begin
            errors = errors + 1;
            $display("T3 FAIL line_align_sticky raised: a 5,760 B line is a whole number of 16 B beats");
        end
        // Directed byte-position check, independent of the golden queue walk.
        if (first_beat[7:0]  !== fp0[23:16] ||
            first_beat[15:8] !== fp0[7:0]   ||
            first_beat[23:16]!== fp0[15:8]  ||
            first_beat[31:24]!== fp1[23:16] ||
            first_beat[39:32]!== fp1[7:0]   ||
            first_beat[47:40]!== fp1[15:8]) begin
            errors = errors + 1;
            $display("T1 FAIL byte order beat0=%h2 %h2 %h2 %h2 %h2 %h2 want %h2 %h2 %h2 %h2 %h2 %h2 (native pix %h / %h)",
                     first_beat[7:0], first_beat[15:8], first_beat[23:16],
                     first_beat[31:24], first_beat[39:32], first_beat[47:40],
                     fp0[23:16], fp0[7:0], fp0[15:8],
                     fp1[23:16], fp1[7:0], fp1[15:8], fp0, fp1);
        end else
            $display("SC7F0_RGB24_PACK T1 byte0..5=%h2 %h2 %h2 %h2 %h2 %h2 == R,G,B,R,G,B of pixels %h,%h",
                     first_beat[7:0], first_beat[15:8], first_beat[23:16],
                     first_beat[31:24], first_beat[39:32], first_beat[47:40], fp0, fp1);
        $display("SC7F0_RGB24_PACK T1-T3 bytes=%0d beats=%0d errors=%0d", gp, beats_seen, errors);

        // ---- T4: tready never low while not in reset -----------------------
        if (ready_low_cycles != 0) begin
            errors = errors + 1;
            $display("T4 FAIL s_axis_tready low for %0d cycles; VIDEO_OUT must never be stalled",
                     ready_low_cycles);
        end else
            $display("SC7F0_RGB24_PACK T4 tready_never_low=1");

        // ---- T5: overrun abandons, never truncates silently ----------------
        m_tready = 1'b0;                     // freeze the drain side
        full0 = dut.ovf_full_cnt;
        drive_frame(3840, 8, 8'h77);         // 92,160 B into a 64-beat FIFO
        repeat (40) @(posedge m_clk);
        if (ovf_sticky !== 1'b1) begin
            errors = errors + 1;
            $display("T5 FAIL overflow_sticky did not latch on an unfetchable frame");
        end
        if (dut.ovf_full_cnt != full0 + 1) begin
            errors = errors + 1;
            $display("T5 FAIL refusal count %0d, want exactly %0d: after a frame is abandoned no further beat of it may be offered",
                     dut.ovf_full_cnt, full0 + 1);
        end
        // published bytes must still be a whole prefix of the golden stream and
        // must not have advanced after the abandon point
        begin
            before_cnt = ghead;
            repeat (200) @(posedge m_clk);
            if (ghead != before_cnt) begin
                errors = errors + 1;
                $display("T5 FAIL bytes still being published after the frame was abandoned");
            end
        end
        $display("SC7F0_RGB24_PACK T5 overflow_sticky=1 ovf_full_cnt=%0d published_bytes=%0d (frame abandoned, not silently truncated)",
                 dut.ovf_full_cnt, ghead);

        gate_pass = (errors == 0);
        $display("SC7F0_RGB24_PACK_TB errors=%0d gate_pass=%b", errors, gate_pass);
        if (errors == 0) $display("RGB24_PACK_TB_PASS");
        else             $display("RGB24_PACK_TB_FAIL");
        $finish;
    end
endmodule
