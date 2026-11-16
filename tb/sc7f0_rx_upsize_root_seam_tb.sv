`timescale 1ns / 1ps
// ============================================================================
// tb/sc7f0_rx_upsize_root_seam_tb.sv   (NEW/rewritten, simulation-only)
//
// Root-seam regression for the SC7F0-RGB RX 2 PPC -> 4 PPC adapter, run three
// times from three separate compilations against ONE oracle:
//
//   OBS_SEL=0 EXPECT=0  P_POSITIVE  : repaired root READY + fixed adapter must
//                                     be pixel-exact under the UG934 oracle.
//   OBS_SEL=0 EXPECT=1  N_ORDER     : repaired root READY + the FROZEN round-H
//                                     adapter must fail as a counted rotate-by-two
//                                     pixel-group fault while flow/conservation/
//                                     geometry stay clean.  This is the
//                                     load-bearing negative: the old testbench,
//                                     which read the quad back out of the DUT's
//                                     own concatenation, could not see it.
//   OBS_SEL=1 EXPECT=2  N_READY     : round-H root (READY net undriven) + the
//                                     FROZEN round-H adapter must fail as a stale/
//                                     duplicated beat with a repeated SOF.
//
// WHY THE ORACLE IS A SEPARATE MODULE (tb/sc7f0_rx_upsize_official_oracle.v).
// It implements AMD's published rule (UG934 "Encoding Multiple Pixels": LSB
// group = left-most / earliest pixel, so word[23:0]=pixel0 ... word[95:72]=pixel3,
// each group lane-ordered {R,B,G} per UG934 Table 1-5) from its OWN raster
// counters.  It never reads a DUT internal, and the same compiled oracle scores
// all three variants, so a negative control cannot be produced by an expectation
// that was tuned to the defect.  Pixel order and component (lane) order are
// counted separately, and the group-order defect has its own signature counter.
//
// WHAT EACH RUN PROVES BEYOND PIXEL VALUES:
//   * conservation  : oracle's own input-handshake counter vs. published beats
//                     (in_beats == 2 * out_beats, i.e. in_beats*2 == out_beats*4 pixels);
//   * one beat per completed pair, never refused: the adapter's s_axis_tready is
//                     probed inside the fixture every clock (the source is an
//                     unpausable scan);
//   * SOF / EOL placement, duplicate-beat and stale-beat detection;
//   * full-frame coverage: 3840x2160 with a mid-frame-0 observer blackout that
//                     re-arms before the next SOF, so frame 0 is PARTIAL and at
//                     least one FULL frame is reported - the numbers never claim
//                     two full oracle frames;
//   * LINE_GAP=4 is a high-duty 4K geometry stress model, not the real 4K60
//                     blanking and not a board frame-rate proof.
//
// Failure semantics are counted, not assumed: every negative run must reach
// $finish with a finite count and its explicit marker.  The watchdog prints
// SC7F0_RX_UPSIZE_CYCLE_GUARD and the runner treats that (or a missing marker, or
// a non-zero tool rc) as FAIL, never as evidence.
// ============================================================================
module sc7f0_rx_upsize_root_seam_tb;

    localparam integer HACTIVE  = 3840;
    localparam integer VACTIVE  = 2160;
    localparam integer FRAMES   = 2;
    localparam integer LINE_GAP = 4;
    localparam integer PAUSE_LINE = 1000;
    localparam integer BEATS_PER_LINE = HACTIVE/2;
    localparam integer MAX_CYC = FRAMES*(VACTIVE*(BEATS_PER_LINE+LINE_GAP)+64) + 20000;

    // ------------------------------------------------------------- variants ---
    // Selected at COMPILE time with xvlog -d (xelab in 2023.2 has no -g for Verilog
    // parameters; the first revision of this runner passed -gOBS_SEL and xelab
    // answered "[XSIM 43-3985] unrecognised option", which the runner caught as a
    // tool failure rather than as a pass).
    //   OBS_SEL 0 = observe the repaired root seam (rx_ss_video_up_tready assigned 1)
    //   OBS_SEL 1 = observe the round H root seam (that assignment absent -> Z/undriven)
    //   EXPECT  0 = expect a clean pass
    //   EXPECT  1 = expect the UG934 rotate-by-two pixel-group fault
    //   EXPECT  2 = expect the stale/duplicated-beat seam fault
`ifndef SC7F0_SEAM_OBS_SEL
    `define SC7F0_SEAM_OBS_SEL 0
`endif
`ifndef SC7F0_SEAM_EXPECT
    `define SC7F0_SEAM_EXPECT 0
`endif
    localparam integer OBS_SEL = `SC7F0_SEAM_OBS_SEL;
    localparam integer EXPECT  = `SC7F0_SEAM_EXPECT;

    reg [127:0] VARIANT;
    initial begin
        if (EXPECT == 0)      VARIANT = "P_POSITIVE";
        else if (EXPECT == 1) VARIANT = "N_ORDER";
        else                  VARIANT = "N_READY";
    end

    // ---------------------------------------------------------------- clock ---
    reg clk = 1'b0;
    always #1.6835 clk = ~clk;                 // 297 MHz pixel clock at 2 PPC
    integer cyc = 0;

    // -------------------------------------------------------------- source ----
    wire        rst;
    wire [47:0] s_tdata;
    wire        s_tvalid, s_tlast, s_tuser, obs_en;
    wire [31:0] pairs_fed, frames_driven;
    wire        run_done;

    sc7f0_rx_upsize_ug934_source #(
        .HACTIVE(HACTIVE), .VACTIVE(VACTIVE), .FRAMES(FRAMES),
        .LINE_GAP(LINE_GAP), .PAUSE_LINE(PAUSE_LINE)) u_src (
        .clk(clk), .rst(rst), .tdata(s_tdata), .tvalid(s_tvalid),
        .tlast(s_tlast), .tuser(s_tuser), .obs_en(obs_en),
        .pairs_fed(pairs_fed), .frames_driven(frames_driven), .run_done(run_done));

    // ------------------------------------------------------- fixture / DUT ----
    // Both production seam variants are compiled (they are the two root
    // wirings); OBS_SEL chooses which one is scored, so no pixel expectation is
    // ever shared between a good and a bad wiring.
    sc7f0_rx_upsize_root_seam_pos u_pos (
        .phy_rx_video_clk(clk), .rx_video_rst(rst),
        .rx_ss_video_tdata(s_tdata), .rx_ss_video_tvalid(s_tvalid),
        .rx_ss_video_tlast(s_tlast), .rx_ss_video_tuser(s_tuser));
    sc7f0_rx_upsize_root_seam_h u_base (
        .phy_rx_video_clk(clk), .rx_video_rst(rst),
        .rx_ss_video_tdata(s_tdata), .rx_ss_video_tvalid(s_tvalid),
        .rx_ss_video_tlast(s_tlast), .rx_ss_video_tuser(s_tuser));

    wire [95:0] p_tdata = u_pos.rx_ss_video_up_tdata;
    wire        p_tvalid = u_pos.rx_ss_video_up_tvalid;
    wire        p_tlast  = u_pos.rx_ss_video_up_tlast;
    wire        p_tuser  = u_pos.rx_ss_video_up_tuser;
    wire        p_rready = u_pos.rx_ss_video_tready;
    wire [31:0] p_stall  = u_pos.rx_up_out_stall_count;
    wire [31:0] p_odd    = u_pos.rx_up_odd_line_count;
    wire [95:0] h_tdata = u_base.rx_ss_video_up_tdata;
    wire        h_tvalid = u_base.rx_ss_video_up_tvalid;
    wire        h_tlast  = u_base.rx_ss_video_up_tlast;
    wire        h_tuser  = u_base.rx_ss_video_up_tuser;
    wire        h_rready = u_base.rx_ss_video_tready;
    wire [31:0] h_stall  = u_base.rx_up_out_stall_count;
    wire [31:0] h_odd    = u_base.rx_up_odd_line_count;

    // --------------------------------------------------------------- oracles --
    wire [31:0] po_in_beats, po_in_refused, po_out_beats, po_new, po_dup;
    wire [31:0] po_armed, po_distinct4, po_exact, po_rot2, po_lane_err;
    wire [31:0] po_pixcmp, po_pixerr, po_s0, po_s1, po_s2, po_s3;
    wire [31:0] po_sof, po_eol, po_ffull, po_aband, po_line, po_x;
    wire [31:0] ho_in_beats, ho_in_refused, ho_out_beats, ho_new, ho_dup;
    wire [31:0] ho_armed, ho_distinct4, ho_exact, ho_rot2, ho_lane_err;
    wire [31:0] ho_pixcmp, ho_pixerr, ho_s0, ho_s1, ho_s2, ho_s3;
    wire [31:0] ho_sof, ho_eol, ho_ffull, ho_aband, ho_line, ho_x;

    sc7f0_rx_upsize_official_oracle #(.HACTIVE(HACTIVE), .VACTIVE(VACTIVE)) u_orc_pos (
        .clk(clk), .rst_n(!rst), .obs_en(obs_en),
        .o_tdata(p_tdata), .o_tvalid(p_tvalid), .o_tlast(p_tlast), .o_tuser(p_tuser),
        .i_tvalid(s_tvalid), .i_tready(p_rready),
        .cnt_in_beats(po_in_beats), .cnt_in_refused(po_in_refused),
        .cnt_out_beats(po_out_beats), .cnt_new_beats(po_new), .cnt_dup_beats(po_dup),
        .cnt_armed_beats(po_armed), .cnt_distinct4_beats(po_distinct4),
        .cnt_exact_beats(po_exact), .cnt_rot2_beats(po_rot2),
        .cnt_lane_order_err(po_lane_err), .cnt_pix_compared(po_pixcmp),
        .cnt_pix_mismatch(po_pixerr), .cnt_slot0_mismatch(po_s0),
        .cnt_slot1_mismatch(po_s1), .cnt_slot2_mismatch(po_s2),
        .cnt_slot3_mismatch(po_s3), .cnt_sof_err(po_sof), .cnt_eol_err(po_eol),
        .cnt_frames_full(po_ffull), .cnt_frames_abandoned(po_aband),
        .dbg_line(po_line), .dbg_x(po_x));

    sc7f0_rx_upsize_official_oracle #(.HACTIVE(HACTIVE), .VACTIVE(VACTIVE)) u_orc_base (
        .clk(clk), .rst_n(!rst), .obs_en(obs_en),
        .o_tdata(h_tdata), .o_tvalid(h_tvalid), .o_tlast(h_tlast), .o_tuser(h_tuser),
        .i_tvalid(s_tvalid), .i_tready(h_rready),
        .cnt_in_beats(ho_in_beats), .cnt_in_refused(ho_in_refused),
        .cnt_out_beats(ho_out_beats), .cnt_new_beats(ho_new), .cnt_dup_beats(ho_dup),
        .cnt_armed_beats(ho_armed), .cnt_distinct4_beats(ho_distinct4),
        .cnt_exact_beats(ho_exact), .cnt_rot2_beats(ho_rot2),
        .cnt_lane_order_err(ho_lane_err), .cnt_pix_compared(ho_pixcmp),
        .cnt_pix_mismatch(ho_pixerr), .cnt_slot0_mismatch(ho_s0),
        .cnt_slot1_mismatch(ho_s1), .cnt_slot2_mismatch(ho_s2),
        .cnt_slot3_mismatch(ho_s3), .cnt_sof_err(ho_sof), .cnt_eol_err(ho_eol),
        .cnt_frames_full(ho_ffull), .cnt_frames_abandoned(ho_aband),
        .dbg_line(ho_line), .dbg_x(ho_x));

    // the adapter must never refuse the unpausable scan source
    integer rdy_viol_pos = 0, rdy_viol_base = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (p_rready !== 1'b1) begin
                rdy_viol_pos = rdy_viol_pos + 1;
                if (rdy_viol_pos <= 3) $display("SEAM_RX_STALLED dut=repaired rready=%b", p_rready);
            end
            if (h_rready !== 1'b1 && h_rready !== 1'bz) begin
                rdy_viol_base = rdy_viol_base + 1;
            end
            cyc = cyc + 1;
            if (cyc > MAX_CYC) begin
                $display("SC7F0_RX_UPSIZE_CYCLE_GUARD cyc=%0d run_did_not_finish_normally", cyc);
                finish_run(1'b0);
            end
        end
    end

    always @(posedge run_done) finish_run(1'b0);

    // ------------------------------------------------------------- reporting --
    task report;
        input integer        sel;      // which DUT this line describes
        input [255:0]        name;
        input [31:0]         in_beats, in_refused, out_beats, new_b, dup_b;
        input [31:0]         armed, distinct4, exact, rot2, lane_err;
        input [31:0]         pixcmp, pixerr, s0, s1, s2, s3;
        input [31:0]         sof, eol, ffull, aband;
        input [31:0]         stall, odd, rdy_viol;
        input                rready;
        begin
            $display("SEAM_RESULT variant=%0s dut=%0s sel=%0d in_beats=%0d in_refused=%0d out_beats=%0d new_beats=%0d dup_beats=%0d armed_beats=%0d distinct4_beats=%0d exact_beats=%0d rot2_beats=%0d lane_order_err=%0d pix_compared=%0d pix_mismatch=%0d slot_mismatch=%0d/%0d/%0d/%0d sof_err=%0d eol_err=%0d frames_full=%0d frames_abandoned=%0d adapter_stall_count=%0d adapter_odd_count=%0d adapter_s_tready_not_1_cycles=%0d adapter_s_tready=%b",
                     VARIANT, name, sel, in_beats, in_refused, out_beats, new_b, dup_b,
                     armed, distinct4, exact, rot2, lane_err, pixcmp, pixerr,
                     s0, s1, s2, s3, sof, eol, ffull, aband, stall, odd, rdy_viol, rready);
            $display("SEAM_CONSERVATION dut=%0s pixels_in=%0d pixels_out=%0d in_beats_eq_2x_out_beats=%0d",
                     name, in_beats*2, out_beats*4, (in_beats == out_beats*2));
        end
    endtask

    reg gate_pass = 1'b0;
    reg timed_out = 1'b0;
    reg finished  = 1'b0;

    task finish_run;
        input did_timeout;
        integer ob_in_beats, ob_out_beats;
        begin
            if (finished) begin
                $display("SC7F0_RX_UPSIZE_FINISH_REENTER ignored");
                $finish;
            end
            finished = 1'b1;
            timed_out = did_timeout;
            $display("SEAM_CFG variant=%0s OBS_SEL=%0d EXPECT=%0d HACTIVE=%0d VACTIVE=%0d FRAMES=%0d LINE_GAP=%0d PAUSE_LINE=%0d",
                     VARIANT, OBS_SEL, EXPECT, HACTIVE, VACTIVE, FRAMES, LINE_GAP, PAUSE_LINE);
            $display("SEAM_SOURCE pairs_fed=%0d frames_driven=%0d run_done=%b cyc=%0d",
                     pairs_fed, frames_driven, run_done, cyc);
            report(0, "repaired_root_ready", po_in_beats, po_in_refused, po_out_beats,
                   po_new, po_dup, po_armed, po_distinct4, po_exact, po_rot2, po_lane_err,
                   po_pixcmp, po_pixerr, po_s0, po_s1, po_s2, po_s3, po_sof, po_eol,
                   po_ffull, po_aband, p_stall, p_odd, rdy_viol_pos, p_rready);
            report(1, "roundH_root_ready_absent", ho_in_beats, ho_in_refused, ho_out_beats,
                   ho_new, ho_dup, ho_armed, ho_distinct4, ho_exact, ho_rot2, ho_lane_err,
                   ho_pixcmp, ho_pixerr, ho_s0, ho_s1, ho_s2, ho_s3, ho_sof, ho_eol,
                   ho_ffull, ho_aband, h_stall, h_odd, rdy_viol_base, h_rready);

            if (did_timeout) begin
                $display("SC7F0_RX_UPSIZE_ROOT_SEAM_FAIL reason=watchdog");
                $display("SEAM_GATE_PASS=0");
                $finish;
            end

            ob_in_beats  = OBS_SEL ? ho_in_beats  : po_in_beats;
            ob_out_beats = OBS_SEL ? ho_out_beats : po_out_beats;

            if (EXPECT == 0) begin
                // repaired seam + fixed adapter: everything exact, nothing reused
                gate_pass =
                    (OBS_SEL == 0) &&
                    (po_in_refused == 0) && (rdy_viol_pos == 0) &&
                    (po_dup == 0) && (po_sof == 0) && (po_eol == 0) &&
                    (po_pixerr == 0) && (po_rot2 == 0) && (po_lane_err == 0) &&
                    (po_exact == po_armed) && (po_armed == po_distinct4) &&
                    (po_armed > 0) &&
                    (po_in_beats == po_out_beats*2) &&
                    (po_out_beats == pairs_fed) &&
                    (po_ffull >= 1) && (po_pixcmp >= (HACTIVE*VACTIVE)) &&
                    (p_stall == 32'd0) && (p_odd == 32'd0) &&
                    (frames_driven == FRAMES) && (p_rready === 1'b1);
                if (gate_pass)
                    $display("SC7F0_RX_UPSIZE_UG934_ORDER_PASS pixels=%0d beats=%0d frames_full=%0d (frame0 is a deliberate partial observation, so full frames reported = %0d, not %0d)",
                             po_pixcmp, po_out_beats, po_ffull, po_ffull, FRAMES);
            end else if (EXPECT == 1) begin
                // frozen round-H adapter behind the REPAIRED root: the flow is
                // perfect and the pixel-group order is not.  Every slot of every
                // scored beat must be wrong, in the exact half-word-exchange
                // pattern, and the run must still be finite and non-stalling.
                gate_pass =
                    (OBS_SEL == 0) &&
                    (po_in_refused == 0) && (rdy_viol_pos == 0) &&
                    (p_stall == 32'd0) && (p_odd == 32'd0) &&
                    (po_dup == 0) && (po_sof == 0) && (po_eol == 0) &&
                    (po_in_beats == po_out_beats*2) &&
                    (po_out_beats == pairs_fed) &&
                    (po_armed > 0) && (po_armed == po_distinct4) &&
                    (po_rot2 == po_armed) && (po_exact == 0) &&
                    (po_lane_err == 0) &&
                    (po_pixerr == po_armed*4) &&
                    (po_s0 == po_armed) && (po_s1 == po_armed) &&
                    (po_s2 == po_armed) && (po_s3 == po_armed) &&
                    (po_ffull >= 1) && (po_pixcmp >= (HACTIVE*VACTIVE));
                if (gate_pass)
                    $display("SC7F0_RX_UPSIZE_ORDER_ROT2_CAUGHT rot2_beats=%0d armed_beats=%0d pix_mismatch=%0d slots=%0d/%0d/%0d/%0d exact_beats=%0d signature=half_word_exchange_p2_p3_p0_p1 flow_errors=0",
                             po_rot2, po_armed, po_pixerr, po_s0, po_s1, po_s2, po_s3, po_exact);
            end else begin
                // round-H root: the published beat never retires, so the observer
                // re-samples one stale word and one SOF is re-published.  That is a
                // DIFFERENT signature from the order defect (dup + stale + SOF), and
                // it is scored as such; any co-existing order error is reported but
                // is not what this gate requires.
                gate_pass =
                    (OBS_SEL == 1) &&
                    (ho_dup > 0) && (ho_out_beats > 0) &&
                    (ho_dup*10 >= ho_out_beats*9) &&          // >=90% of samples stale
                    (ho_new <= 8) &&
                    (ho_sof > 0) &&
                    (ho_in_beats != ho_out_beats*2) &&        // flow is broken here
                    (ho_ffull == 0) &&
                    (po_dup == 0);                            // repaired seam unaffected
                if (gate_pass)
                    $display("SC7F0_RX_UPSIZE_STALE_SEAM_CAUGHT dup_beats=%0d out_beats=%0d new_beats=%0d sof_err=%0d frames_full=%0d coexisting_rot2_beats=%0d exact_beats=%0d classification=stale_and_repeated_sof (not pixel-order)",
                             ho_dup, ho_out_beats, ho_new, ho_sof, ho_ffull, ho_rot2, ho_exact);
            end

            if (gate_pass) $display("SC7F0_RX_UPSIZE_NEG_GATE_PASS variant=%0s cyc=%0d", VARIANT, cyc);
            else           $display("SC7F0_RX_UPSIZE_ROOT_SEAM_FAIL variant=%0s cyc=%0d", VARIANT, cyc);
            $display("SEAM_GATE_PASS=%0d", gate_pass);
            $finish;
        end
    endtask
endmodule
