`timescale 1ns / 1ps
`include "sc7f0_rx_upsize_golden.svh"
// ============================================================================
// tb/sc7f0_rx_upsize_ug934_source.v   (simulation only)
//
// The RX side of the seam: an UNPAUSABLE 48-bit / 2 PPC video source that
// behaves like v_hdmi_rx_ss VIDEO_OUT, per PG236 ("the data representation must
// be compliant with the protocol defined in ... UG934"):
//
//   * one new pixel pair per clock, never back-pressured, no gap longer than the
//     declared blanking model;
//   * tuser (SOF) on the FIRST beat of a frame, tlast (EOL) on the LAST beat of
//     a line;
//   * pixel group order = UG934: the EARLIER pixel of the pair is the LOW
//     24-bit group, the LATER pixel is the HIGH group, and each group is
//     lane-ordered {R,B,G} (see tb/sc7f0_rx_upsize_golden.svh for both rules and
//     their citations).
//
// The beat CONTENT is not "whatever the DUT would like": it is the position
// golden function of the pixel's own (x,y), so anything downstream that re-orders
// groups, drops beats, duplicates beats or re-times SOF shows up as a counted
// mismatch in tb/sc7f0_rx_upsize_official_oracle.v, which re-derives the same
// expectation from ITS OWN raster counters.
//
// Geometry: 3840 x 2160, FRAMES frames, LINE_GAP idle cycles per line.  That gap
// is a HIGH-DUTY 4K-geometry stress model, not the real 4K60 blanking and not a
// board-level 60 fps proof; it is declared here so nobody reads this run as a
// frame-rate measurement.
//
// The module also owns the two events the seam test needs from the source side:
// a mid-frame-0 observer blackout (the frame tap losing a frame) that re-arms
// before the next SOF, and a real reset between frames (what RX re-lock does to
// this adapter).
// ============================================================================
module sc7f0_rx_upsize_ug934_source #(
    parameter integer HACTIVE  = 3840,
    parameter integer VACTIVE  = 2160,
    parameter integer FRAMES   = 2,
    parameter integer LINE_GAP = 4,          // idle cycles per line (see header)
    parameter integer PAUSE_LINE = 1000      // frame 0 observer blackout starts here
)(
    input  wire        clk,
    output reg         rst,
    output reg  [47:0] tdata,
    output reg         tvalid,
    output reg         tlast,     // end of line
    output reg         tuser,     // start of frame
    output reg         obs_en,    // observer may check pixels while 1
    output reg  [31:0] pairs_fed, // completed input pixel pairs presented
    output reg  [31:0] frames_driven,
    output reg         run_done
);
    localparam integer BEATS_PER_LINE = HACTIVE / 2;

    integer f, ln, xb;

    initial begin
        rst = 1'b1; tdata = 48'd0; tvalid = 1'b0; tlast = 1'b0; tuser = 1'b0;
        obs_en = 1'b1; pairs_fed = 32'd0; frames_driven = 32'd0; run_done = 1'b0;
    end

    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;                            // reset released before the first beat
        repeat (4) @(posedge clk);

        for (f = 0; f < FRAMES; f = f + 1) begin
            for (ln = 0; ln < VACTIVE; ln = ln + 1) begin
                if (f == 0 && ln == PAUSE_LINE) obs_en = 1'b0;   // blackout mid-frame
                for (xb = 0; xb < BEATS_PER_LINE; xb = xb + 1) begin
                    @(negedge clk);
                    tvalid = 1'b1;
                    // UG934: earlier pixel (2*xb) in the LOW group, later (2*xb+1)
                    // in the HIGH group; each group lane-ordered {R,B,G}.
                    tdata  = {sc7f0_ug934_pix(2*xb + 1, ln),
                              sc7f0_ug934_pix(2*xb,     ln)};
                    tuser  = (ln == 0 && xb == 0);
                    tlast  = (xb == BEATS_PER_LINE - 1);
                    if (xb % 2 == 1) pairs_fed = pairs_fed + 32'd1;
                end
                @(negedge clk);
                tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
                repeat (LINE_GAP) @(negedge clk);   // blanking, no back-pressure
            end
            frames_driven = frames_driven + 32'd1;
            if (f != FRAMES - 1) begin
                // Between frames: the observer comes back BEFORE the next SOF and
                // the adapter sees a real reset, as it does when RX re-locks.
                rst = 1'b1;
                repeat (6) @(posedge clk);
                rst = 1'b0;
                obs_en = 1'b1;
                repeat (10) @(posedge clk);
            end
        end
        repeat (32) @(posedge clk);
        run_done = 1'b1;
    end
endmodule
