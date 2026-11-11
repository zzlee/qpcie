`default_nettype none
// ============================================================================
// Module: sc7f0_hdmi_tx_mux
// Target: AMD/Xilinx Zynq UltraScale+ MPSoC (xczu4ev-fbvb900-2-e)
//
// Three-source AXI4-Stream video selector in front of v_hdmi_tx_ss_0.VIDEO_IN
// (4 PPC, 8 bpc RGB24 => 96-bit TDATA).  Single clock domain:
//   clk   = phy_tx_video_clk (vid_phy_controller_0 tx_video_clk)
//   rst_n = synchronous, active-low release in that domain
//
//   s0_axis_video  Mode 0  direct HDMI RX bypass   (sc7f0_capture/axis path)
//   s1_axis_video  Mode 1  frame buffer read / OSD (sc7f0_display_pipeline)
//   s2_axis_video  Mode 2  host PCIe H2C video     (hdmi_tx_video_bridge)
//   mux_sel        00 -> Mode 0, 01 -> Mode 1, 10 -> Mode 2, 11 -> Mode 0
//
// TEAR-FREE / GLITCH-FREE SWITCHING
// An AMD AXIS video frame starts on the beat carrying tuser (SOF); every line,
// including the last one of the frame, ends on a beat carrying tlast.  So the
// only safe vertical-blanking seam is "tlast of the last line, then the next
// tuser".  The mux therefore locks onto the frame it has started forwarding and
// never re-points the datapath inside that frame:
//
//   * request != active while locked   -> request is armed, frame keeps running
//   * locked source presents its next SOF (previous frame is complete by
//     construction) -> that SOF beat is discarded, the armed request is
//     committed, and the newly selected source is drained until it presents its
//     own SOF, which is where forwarding restarts (bounded blank, <= one frame
//     period).
//   * unlocked (idle, after reset, after a commit) -> commit is immediate and
//     forwarding starts exactly on the new source's SOF beat.  Beats before
//     that SOF are consumed and dropped, because stalling a source that has not
//     reached a frame boundary would keep it from ever reaching one.
//
// Consequence: the TX subsystem only ever sees whole frames that begin with a
// real SOF, so a source change cannot tear a frame and cannot present a
// mid-frame beat stream that would make v_hdmi_tx_ss lose frame sync.
//
// Backpressure on unselected sources:
//   DRAIN_UNSELECTED=1 (default) sinks every beat of the sources that are not
//   active.  That is required for the HDMI RX subsystem, whose video output
//   overflows if READY is ever deasserted, and it lets the next source reach a
//   fresh SOF quickly after a switch.  DRAIN_UNSELECTED=0 stalls unselected
//   sources with READY=0 instead (only safe for sources that tolerate stalls,
//   e.g. the H2C bridge FIFO).
//
// A locked source that stops presenting data for more than STALL_LIMIT cycles
// releases the lock, so a dead or reset source cannot wedge the TX forever
// (STALL_LIMIT=0 disables the watchdog).
//
// mux_sel comes from a CSR register and is quasi-static: it is 2FF
// synchronised and must hold still for SEL_STABLE_CYCLES before it is armed, so
// a multi-bit CSR update can never be sampled as an intermediate code.
// ============================================================================
`timescale 1ns / 1ps

module sc7f0_hdmi_tx_mux #(
    parameter integer TDATA_WIDTH       = 96,
    parameter integer DRAIN_UNSELECTED  = 1,
    parameter integer SEL_STABLE_CYCLES = 8,
    parameter integer STALL_LIMIT       = 1048576
)(
    input  wire clk,
    input  wire rst_n,

    // Source select (CSR, quasi-static): 00/11 Mode0, 01 Mode1, 10 Mode2
    input  wire [1:0] mux_sel,

    // Mode 0: direct HDMI RX bypass
    input  wire [TDATA_WIDTH-1:0] s0_axis_video_tdata,
    input  wire s0_axis_video_tvalid,
    output wire s0_axis_video_tready,
    input  wire s0_axis_video_tlast,
    input  wire s0_axis_video_tuser,

    // Mode 1: frame buffer read / OSD overlay
    input  wire [TDATA_WIDTH-1:0] s1_axis_video_tdata,
    input  wire s1_axis_video_tvalid,
    output wire s1_axis_video_tready,
    input  wire s1_axis_video_tlast,
    input  wire s1_axis_video_tuser,

    // Mode 2: host PCIe H2C video
    input  wire [TDATA_WIDTH-1:0] s2_axis_video_tdata,
    input  wire s2_axis_video_tvalid,
    output wire s2_axis_video_tready,
    input  wire s2_axis_video_tlast,
    input  wire s2_axis_video_tuser,

    // Straight to v_hdmi_tx_ss_0.VIDEO_IN
    output wire [TDATA_WIDTH-1:0] m_axis_video_tdata,
    output wire m_axis_video_tvalid,
    input  wire m_axis_video_tready,
    output wire m_axis_video_tlast,
    output wire m_axis_video_tuser
);

    localparam [1:0] SRC_RX    = 2'd0;
    localparam [1:0] SRC_FRMBUF = 2'd1;
    localparam [1:0] SRC_HOST  = 2'd2;

    // ------------------------------------------------------------------------
    // Quasi-static select synchronisation and decode (11 aliases Mode 0)
    // ------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [1:0] sel_meta = SRC_RX;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sel_sync = SRC_RX;
    always @(posedge clk) begin
        sel_meta <= mux_sel;
        sel_sync <= sel_meta;
    end

    function [1:0] sel_decode;
        input [1:0] code;
        begin
            case (code)
                2'b01:   sel_decode = SRC_FRMBUF;
                2'b10:   sel_decode = SRC_HOST;
                default: sel_decode = SRC_RX;   // 00 and the 11 alias
            endcase
        end
    endfunction

    wire [1:0] requested = sel_decode(sel_sync);

    reg  [1:0]  requested_d = SRC_RX;
    reg  [31:0] stable_count = 32'd0;
    wire        sel_stable = (SEL_STABLE_CYCLES == 0) ||
                             (stable_count >= SEL_STABLE_CYCLES);
    always @(posedge clk) begin
        if (!rst_n) begin
            requested_d  <= SRC_RX;
            stable_count <= 32'd0;
        end else if (requested != requested_d) begin
            requested_d  <= requested;
            stable_count <= 32'd0;
        end else if (!sel_stable) begin
            stable_count <= stable_count + 32'd1;
        end
    end

    // ------------------------------------------------------------------------
    // Selected source datapath (registered select, combinational 3:1 mux)
    // ------------------------------------------------------------------------
    reg  [1:0] active = SRC_RX;
    reg        locked = 1'b0;

    reg  [TDATA_WIDTH-1:0] cur_tdata;
    reg                    cur_tvalid;
    reg                    cur_tlast;
    reg                    cur_tuser;
    always @(*) begin
        case (active)
            SRC_FRMBUF: begin
                cur_tdata = s1_axis_video_tdata;
                cur_tvalid = s1_axis_video_tvalid;
                cur_tlast  = s1_axis_video_tlast;
                cur_tuser  = s1_axis_video_tuser;
            end
            SRC_HOST: begin
                cur_tdata = s2_axis_video_tdata;
                cur_tvalid = s2_axis_video_tvalid;
                cur_tlast  = s2_axis_video_tlast;
                cur_tuser  = s2_axis_video_tuser;
            end
            default: begin
                cur_tdata = s0_axis_video_tdata;
                cur_tvalid = s0_axis_video_tvalid;
                cur_tlast  = s0_axis_video_tlast;
                cur_tuser  = s0_axis_video_tuser;
            end
        endcase
    end

    // pending is the armed target; while the CSR code is still moving the mux
    // simply keeps the source it already has.
    wire [1:0] pending   = sel_stable ? requested_d : active;
    wire       switching = (pending != active);

    // Frame-start gate.
    //   unlocked + non-SOF beat : DISCARD (the source must be allowed to run to
    //                             its own frame boundary, otherwise it stalls on
    //                             a mid-frame beat and can never be entered)
    //   unlocked + SOF beat     : start the frame on the downstream handshake
    //   locked   + non-SOF beat : forward
    //   locked   + SOF beat     : forward, unless a switch is armed, in which
    //                             case this SOF is DISCARDED and committed
    // Discarded beats are consumed (READY high) so the source keeps moving.
    wire sof_beat   = cur_tuser;
    wire commit     = locked && cur_tvalid && sof_beat && switching;
    wire discard    = (!locked && !sof_beat) || commit;
    wire out_gate   = !discard;

    assign m_axis_video_tdata  = cur_tdata;
    assign m_axis_video_tlast  = cur_tlast;
    assign m_axis_video_tuser  = cur_tuser;
    assign m_axis_video_tvalid = cur_tvalid && out_gate;

    wire cur_accept = m_axis_video_tvalid && m_axis_video_tready;
    wire act_ready  = discard ? 1'b1 : m_axis_video_tready;
    wire drain      = (DRAIN_UNSELECTED != 0);

    assign s0_axis_video_tready = (active == SRC_RX)     ? act_ready : drain;
    assign s1_axis_video_tready = (active == SRC_FRMBUF) ? act_ready : drain;
    assign s2_axis_video_tready = (active == SRC_HOST)   ? act_ready : drain;

    // ------------------------------------------------------------------------
    // Mid-frame stall watchdog: releases the lock instead of wedging the TX
    // ------------------------------------------------------------------------
    reg  [31:0] stall_count = 32'd0;
    wire stall_expired = (STALL_LIMIT != 0) && locked && !cur_tvalid &&
                         (stall_count >= STALL_LIMIT);
    always @(posedge clk) begin
        if (!rst_n)                     stall_count <= 32'd0;
        else if (!locked || cur_tvalid) stall_count <= 32'd0;
        else if (!stall_expired)        stall_count <= stall_count + 32'd1;
    end

    // ------------------------------------------------------------------------
    // Source commitment.  Only two moments are legal:
    //   1. not locked  - no partial frame exists at the output
    //   2. locked and the active source presents its next SOF - the frame that
    //      the TX has already received is complete (its last line carried
    //      tlast), and this SOF is swallowed rather than forwarded
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= SRC_RX;
            locked <= 1'b0;
        end else if (locked) begin
            if (commit) begin
                // Every earlier beat of this frame was already accepted, so the
                // frame the TX received is complete: drop this SOF and commit.
                active <= pending;
                locked <= 1'b0;
            end else if (stall_expired) begin
                locked <= 1'b0;
            end
        end else if (switching) begin
            active <= pending;
        end else if (cur_accept && sof_beat) begin
            locked <= 1'b1;
        end
    end

endmodule
`default_nettype wire
