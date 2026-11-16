`timescale 1ns / 1ps
`include "sc7f0_rx_upsize_golden.svh"
// ============================================================================
// tb/sc7f0_rx_upsize_official_oracle.v   (simulation only)
//
// The ORACLE for the RX 2 PPC -> 4 PPC seam.  It is written against AMD's
// published AXI4-Stream video convention, NOT against anything rtl/sc7f0_ppc_upsize.v
// claims, which is the whole point: the first version of this regression derived
// its expected quad from the DUT's own concatenation
// (quad[0]=word[71:48], quad[1]=word[95:72], quad[2]=word[23:0], quad[3]=word[47:24])
// and therefore could not fail while the adapter rotated every pixel group.  An
// oracle that mirrors the DUT is not evidence.
//
// THE RULE (UG934, "Encoding Multiple Pixels - Static TDATA Configuration"):
//   "pixels should be packed from least significant bit (LSB) to MSB, e.g. the
//    least significant pixel should correspond to the left-most pixel in a
//    scanline, or to the pixel captured earliest in time."
// Selected consumers publish the same table: PG231 (v_proc_ss 2.3) and PG278
// (v_frmbuf_wr 2.5) "Dual Pixels per Clock ... Mapping for RGB" = R1 B1 G1 R0 B0
// G0 with pixel 0 in the lowest DW, and PG300's UG934-compliant 4 PPC / 8 bpc
// row spells out Pixel0=[23:16/15:8/7:0] ... Pixel3=[95:88/87:80/79:72].  PG278
// additionally requires memory raster order ("top-left pixel first").
//
// SO THE CHECK IS FOUR LITERAL RANGE EQUALITIES ON EVERY PUBLISHED 96-BIT BEAT:
//     word[23:0]  == pixel(ox+0, line)      (earliest / left-most)
//     word[47:24] == pixel(ox+1, line)
//     word[71:48] == pixel(ox+2, line)
//     word[95:72] == pixel(ox+3, line)      (latest / right-most)
// with each pixel lane-ordered {R,B,G} per UG934 Table 1-5 (VF=2 RGB).  A
// component-order fault is classified SEPARATELY (cnt_lane_order_err) from a
// pixel-group-order fault, and the group-order fault has its own signature
// counter (cnt_rot2_beats: observed == expected with the two 48-bit halves
// exchanged, i.e. raster read as p2,p3,p0,p1) so a negative control proves the
// specific defect rather than "the words were not identical".
//
// Independence: ox/line are this module's OWN counters, advanced from the beats
// it actually samples; the golden function is the shared sc7f0_ug934_pix() that
// the stimulus also uses (tb/sc7f0_rx_upsize_golden.svh, one definition).  No
// DUT internal is read.  Observer counters deliberately survive the between-frame
// reset (they are observation state, not DUT state); an in-flight frame is marked
// abandoned instead of silently continuing, so a mid-frame reset can neither
// inflate nor hide pixel coverage.
// ============================================================================
module sc7f0_rx_upsize_official_oracle #(
    parameter integer HACTIVE = 3840,
    parameter integer VACTIVE = 2160
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        obs_en,        // 0 = frame tap is not sampling (blackout)

    // published 96-bit 4 PPC beat, sampled ready-less exactly like the frame tap
    input  wire [95:0] o_tdata,
    input  wire        o_tvalid,
    input  wire        o_tlast,
    input  wire        o_tuser,

    // the same seam's input side, only used for an independent conservation count
    input  wire        i_tvalid,
    input  wire        i_tready,

    output reg  [31:0] cnt_in_beats,
    output reg  [31:0] cnt_in_refused,
    output reg  [31:0] cnt_out_beats,
    output reg  [31:0] cnt_new_beats,
    output reg  [31:0] cnt_dup_beats,
    output reg  [31:0] cnt_armed_beats,
    output reg  [31:0] cnt_distinct4_beats,
    output reg  [31:0] cnt_exact_beats,
    output reg  [31:0] cnt_rot2_beats,
    output reg  [31:0] cnt_lane_order_err,
    output reg  [31:0] cnt_pix_compared,
    output reg  [31:0] cnt_pix_mismatch,
    output reg  [31:0] cnt_slot0_mismatch,
    output reg  [31:0] cnt_slot1_mismatch,
    output reg  [31:0] cnt_slot2_mismatch,
    output reg  [31:0] cnt_slot3_mismatch,
    output reg  [31:0] cnt_sof_err,
    output reg  [31:0] cnt_eol_err,
    output reg  [31:0] cnt_frames_full,
    output reg  [31:0] cnt_frames_abandoned,
    output reg  [31:0] dbg_line,
    output reg  [31:0] dbg_x
);
    integer armed;
    integer ox, oline;
    integer printed;
    reg [95:0] last_word;
    reg        have_last;

    reg [23:0] exp4 [0:3];
    reg [23:0] got4 [0:3];
    reg [23:0] got4_lane_fixed [0:3];
    integer i;
    reg exact, rot2, lane_swapped, distinct4;

    initial begin
        cnt_in_beats = 32'd0;  cnt_in_refused = 32'd0;
        cnt_out_beats = 32'd0; cnt_new_beats = 32'd0; cnt_dup_beats = 32'd0;
        cnt_armed_beats = 32'd0; cnt_distinct4_beats = 32'd0;
        cnt_exact_beats = 32'd0; cnt_rot2_beats = 32'd0;
        cnt_lane_order_err = 32'd0;
        cnt_pix_compared = 32'd0; cnt_pix_mismatch = 32'd0;
        cnt_slot0_mismatch = 32'd0; cnt_slot1_mismatch = 32'd0;
        cnt_slot2_mismatch = 32'd0; cnt_slot3_mismatch = 32'd0;
        cnt_sof_err = 32'd0; cnt_eol_err = 32'd0;
        cnt_frames_full = 32'd0; cnt_frames_abandoned = 32'd0;
        dbg_line = 32'd0; dbg_x = 32'd0;
        armed = 0; ox = 0; oline = 0; printed = 0;
        last_word = 96'd0; have_last = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            // Observation state is not DUT state: keep the counters, but a frame
            // that was in flight is abandoned and the oracle re-arms at the next SOF.
            if (armed) begin
                cnt_frames_abandoned = cnt_frames_abandoned + 32'd1;
                if (printed < 4) begin
                    $display("SEAM_OBS_RESET_ABORT line=%0d x=%0d", oline, ox);
                    printed = printed + 1;
                end
            end
            armed = 0;
        end else begin
            // ---- input side: pixel conservation, counted independently -------
            if (i_tvalid) begin
                if (i_tready) cnt_in_beats  = cnt_in_beats + 32'd1;
                else begin
                    cnt_in_refused = cnt_in_refused + 32'd1;
                    if (cnt_in_refused <= 3)
                        $display("SEAM_RX_REFUSED tready=%b", i_tready);
                end
            end

            // ---- published side: ready-less sampling, like the frame tap -----
            if (o_tvalid) begin
                cnt_out_beats = cnt_out_beats + 32'd1;
                if (have_last && last_word === o_tdata) begin
                    cnt_dup_beats = cnt_dup_beats + 32'd1;
                    if (printed < 4) begin
                        $display("SEAM_DUP cyc_word=%h line=%0d x=%0d", o_tdata, oline, ox);
                        printed = printed + 1;
                    end
                end else begin
                    cnt_new_beats = cnt_new_beats + 32'd1;
                end
                last_word = o_tdata;
                have_last = 1'b1;

                if (!obs_en) begin
                    armed = 0;             // blackout: re-arm at the next SOF
                end else begin
                    if (!armed) begin
                        if (o_tuser) begin
                            armed = 1; ox = 0; oline = 0;
                        end
                    end else if (o_tuser && !(ox == 0 && oline == 0)) begin
                        cnt_sof_err = cnt_sof_err + 32'd1;
                        if (printed < 4) begin
                            $display("SEAM_SOF repeated SOF at line=%0d x=%0d", oline, ox);
                            printed = printed + 1;
                        end
                        ox = 0; oline = 0;  // re-align so one defect cannot smear all
                    end

                    if (armed) begin
                        cnt_armed_beats = cnt_armed_beats + 32'd1;
                        dbg_line = oline; dbg_x = ox;
                        for (i = 0; i < 4; i = i + 1)
                            exp4[i] = sc7f0_ug934_pix(ox + i, oline);
                        // ------- the UG934 rule, spelled out as bit ranges -----
                        got4[0] = o_tdata[23:0];    // pixel 0 = earliest/left-most
                        got4[1] = o_tdata[47:24];   // pixel 1
                        got4[2] = o_tdata[71:48];   // pixel 2
                        got4[3] = o_tdata[95:72];   // pixel 3 = latest/right-most
                        for (i = 0; i < 4; i = i + 1)
                            got4_lane_fixed[i] = {got4[i][23:16], got4[i][7:0],
                                                  got4[i][15:8]};
                        distinct4 =
                            (exp4[0] !== exp4[1]) && (exp4[0] !== exp4[2]) &&
                            (exp4[0] !== exp4[3]) && (exp4[1] !== exp4[2]) &&
                            (exp4[1] !== exp4[3]) && (exp4[2] !== exp4[3]);
                        if (distinct4) cnt_distinct4_beats = cnt_distinct4_beats + 32'd1;

                        exact = (got4[0] === exp4[0]) && (got4[1] === exp4[1]) &&
                                (got4[2] === exp4[2]) && (got4[3] === exp4[3]);
                        // half-word exchange == raster read as p2,p3,p0,p1
                        rot2  = (got4[0] === exp4[2]) && (got4[1] === exp4[3]) &&
                                (got4[2] === exp4[0]) && (got4[3] === exp4[1]);
                        lane_swapped =
                            (got4_lane_fixed[0] === exp4[0]) &&
                            (got4_lane_fixed[1] === exp4[1]) &&
                            (got4_lane_fixed[2] === exp4[2]) &&
                            (got4_lane_fixed[3] === exp4[3]) && !exact;
                        if (exact) cnt_exact_beats      = cnt_exact_beats + 32'd1;
                        if (rot2)  cnt_rot2_beats       = cnt_rot2_beats + 32'd1;
                        if (lane_swapped) cnt_lane_order_err = cnt_lane_order_err + 32'd1;

                        for (i = 0; i < 4; i = i + 1) begin
                            cnt_pix_compared = cnt_pix_compared + 32'd1;
                            if (got4[i] !== exp4[i]) begin
                                cnt_pix_mismatch = cnt_pix_mismatch + 32'd1;
                                case (i)
                                    0: cnt_slot0_mismatch = cnt_slot0_mismatch + 32'd1;
                                    1: cnt_slot1_mismatch = cnt_slot1_mismatch + 32'd1;
                                    2: cnt_slot2_mismatch = cnt_slot2_mismatch + 32'd1;
                                    default: cnt_slot3_mismatch = cnt_slot3_mismatch + 32'd1;
                                endcase
                                if (printed < 8) begin
                                    $display("SEAM_PIX line=%0d x=%0d slot=%0d exp=%h got=%h rot2=%b lane_swapped=%b",
                                             oline, ox, i, exp4[i], got4[i], rot2, lane_swapped);
                                    printed = printed + 1;
                                end
                            end
                        end

                        ox = ox + 4;
                        if (ox == HACTIVE) begin
                            if (!o_tlast) begin
                                cnt_eol_err = cnt_eol_err + 32'd1;
                                if (printed < 8)
                                    $display("SEAM_EOL line=%0d full line published without tlast", oline);
                            end
                            ox = 0;
                            oline = oline + 1;
                            if (oline == VACTIVE) begin
                                cnt_frames_full = cnt_frames_full + 32'd1;
                                armed = 0;              // wait for the next SOF
                            end
                        end else if (o_tlast) begin
                            cnt_eol_err = cnt_eol_err + 32'd1;
                            if (printed < 8)
                                $display("SEAM_EOL line=%0d tlast at x=%0d (line ended early)", oline, ox);
                            ox = 0; oline = oline + 1;
                        end
                    end
                end
            end
        end
    end
endmodule
