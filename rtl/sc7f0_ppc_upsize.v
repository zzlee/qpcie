`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_ppc_upsize  (SC7F0-RGB-COMPOSITOR-2PPC only)
//
// Pixel-beat width adapter: PPC_IN pixels/beat -> PPC_OUT pixels/beat, in ONE
// clock domain, no pixel lost and none invented.
//
// Why this exists.  The RGB-compositor personality fixes the video path at
// 2 pixels/clock (rtl/sc7f0_rgb_compositor.v, rtl/sc7f0_alpha_blend_2ppc.v and
// the 2 PPC v_hdmi_rx_ss / v_hdmi_tx_ss / vid_phy_controller IP all agree, and
// 4K60 at 2 PPC is the 297 MHz pixel clock the PHY recovers).  The official PS
// V4L2 capture branch this personality must keep - frame tap -> v_proc_ss CSC
// -> v_frmbuf_wr - is published and validated at 4 PPC, and its geometry is
// not a knob to move as a side effect of a capacity build.  So the geometries
// are joined here: two consecutive 48-bit RX beats become one 96-bit beat for
// the capture chain.
//
// Geometry adaptation, not reduction: the beat rate halves while the width
// doubles, so pixel throughput is unchanged.  The arithmetic, stated honestly:
//   * active 4K60 raster  = 3840 * 2160 * 60 = 497.664 Mpixel/s, i.e. 124.416
//     Mbeat/s at 4 PPC (497.664 / 4);
//   * this module's own ceiling at its 297 MHz RX video clock = 297 * 2 =
//     594 Mpixel/s in, i.e. 148.5 Mbeat/s out at 4 PPC (one 96-bit beat is
//     published every TWO input clocks).
// The raster therefore fits inside the ceiling, which is a geometry/capacity
// statement about these numbers only: it is NOT a claim that this module runs at
// 4 x 297 MHz, and it is not a measured throughput or blanking proof on hardware.
//
// Pixel-group order (this is the normative part, not a style choice).
// UG934 (AXI4-Stream Video IP and System Design Guide), "Encoding Multiple
// Pixels - Static TDATA Configuration": "pixels should be packed from least
// significant bit (LSB) to MSB, e.g. the least significant pixel should
// correspond to the left-most pixel in a scanline, or to the pixel captured
// earliest in time".  Both ends of this seam follow that rule and neither one
// re-orders for us:
//   * producer v_hdmi_rx_ss 3.2 VIDEO_OUT (PG236: "the data representation must
//     be compliant with the protocol defined in ... (UG934)") puts the EARLIER
//     2-pixel pair in the LOW 48 bits of s_axis_tdata and the LATER pair in the
//     HIGH 48 bits;
//   * consumers v_proc_ss 2.3 (CSC) and v_frmbuf_wr 2.5 publish the same table
//     (PG231/PG278 "Dual Pixels per Clock ... Mapping for RGB": R1 B1 G1 R0 B0
//     G0, pixel 0 in the lowest DW; PG300's UG934-compliant 4 PPC / 8 bpc row
//     gives Pixel 0 = [23:0] ... Pixel 3 = [95:72]) and write memory in raster
//     order, lowest bit-field first.
// So the beat this module publishes must carry the pair it received FIRST in
// the LOW half and the pair it received SECOND in the HIGH half:
//   m_axis_tdata = {later pair, earlier pair} = {s_axis_tdata, accum}.
// Inside one 24-bit pixel lane the component order is R,B,G MSB->LSB (UG934
// Table 1-5, VF=2 RGB); that is orthogonal to pixel chronology and is passed
// through untouched.
//
// Regression that pins this: tb/sc7f0_rx_upsize_official_oracle.v checks the
// published word with four literal UG934 range equalities (word[23:0] = pixel 0
// ... word[95:72] = pixel 3) from its own raster counters; the pre-fix
// concatenation was caught as a counted rotate-by-two-pixels fault
// (SC7F0_RX_UPSIZE_ORDER_ROT2_CAUGHT) by that oracle.
//
// Rules
//   * The input is never stalled.  v_hdmi_rx_ss VIDEO_OUT is a physical scan
//     source; refusing a beat would corrupt the raster.  A completed beat that
//     the consumer has not taken is therefore held and the colliding input beat
//     is counted in output_stall_count / output_stall_sticky rather than
//     silently folded in.  The capture chain is only fed while it is enabled,
//     so this is expected to stay zero.
//   * SOF is published with the first COMPLETE beat of the frame.  A half beat
//     is never published, so an active width that is odd cannot smear into the
//     next line; the ragged half is dropped and counted in odd_line_count.
//     Every supported capture mode has an even active width (3840/1920/1280/
//     720/640), so that counter is expected to stay zero - observable rather
//     than assumed.
// ============================================================================

module sc7f0_ppc_upsize #(
    parameter integer PPC_IN  = 2,
    parameter integer PPC_OUT = 4
)(
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire [PPC_IN*24-1:0]      s_axis_tdata,
    input  wire                      s_axis_tvalid,
    input  wire                      s_axis_tlast,   // end of line
    input  wire                      s_axis_tuser,   // start of frame
    output wire                      s_axis_tready,  // always 1: never stall RX

    output reg  [PPC_OUT*24-1:0]     m_axis_tdata,
    output reg                       m_axis_tvalid,
    input  wire                      m_axis_tready,
    output reg                       m_axis_tlast,
    output reg                       m_axis_tuser,

    output reg                       odd_line_sticky,
    output reg  [31:0]               odd_line_count,
    output reg                       output_stall_sticky,
    output reg  [31:0]               output_stall_count
);
    localparam integer RATIO = PPC_OUT / PPC_IN;
    localparam integer HALF  = PPC_IN * 24;

    // Only the 2 -> 4 case is instantiated.  Writing the unsupported case as a
    // zero-width instantiation makes elaboration fail loudly instead of
    // passing pixels through a path that was never written.
    generate
    if (RATIO != 2) begin : gen_unsupported_geometry
        sc7f0_ppc_upsize_ratio_must_be_two_is_not_supported_error u_error ();
    end else begin : gen_upsize
        reg [PPC_OUT*24-1:0] accum;
        reg                  have_half;
        reg                  pending_sof;

        assign s_axis_tready = 1'b1;              // unpausable scan source
        wire handshake = m_axis_tvalid && m_axis_tready;
        wire out_room  = !m_axis_tvalid || m_axis_tready;

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                accum               <= {PPC_OUT*24{1'b0}};
                have_half           <= 1'b0;
                pending_sof         <= 1'b0;
                m_axis_tvalid       <= 1'b0;
                m_axis_tdata        <= {PPC_OUT*24{1'b0}};
                m_axis_tlast        <= 1'b0;
                m_axis_tuser        <= 1'b0;
                odd_line_sticky     <= 1'b0;
                odd_line_count      <= 32'd0;
                output_stall_sticky <= 1'b0;
                output_stall_count  <= 32'd0;
            end else begin
                if (handshake) begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tuser  <= 1'b0;
                end

                if (s_axis_tvalid) begin
                    if (!have_half) begin
                        accum     <= {{HALF{1'b0}}, s_axis_tdata};
                        have_half <= 1'b1;
                        // A frame that starts and ends inside one half beat is
                        // an odd-width line of one pixel; nothing to publish.
                        if (s_axis_tuser) pending_sof <= 1'b1;
                        if (s_axis_tlast) begin
                            have_half       <= 1'b0;
                            pending_sof     <= 1'b0;
                            odd_line_sticky <= 1'b1;
                            odd_line_count  <= odd_line_count + 32'd1;
                        end
                    end else if (out_room) begin
                        // UG934 low-group-first: the pair that arrived FIRST is
                        // held in accum and must be published in the LOW half of
                        // the 96-bit word; the pair arriving on THIS clock is the
                        // LATER pair and goes in the HIGH half.  Publishing
                        // {earlier, later} instead (the pre-fix spelling) makes
                        // v_proc_ss/v_frmbuf_wr read the raster as p2,p3,p0,p1 -
                        // a rotate-by-two-pixels corruption of every group, and
                        // it also pairs 4:2:0 chroma with the wrong luma pair.
                        m_axis_tdata  <= {s_axis_tdata, accum[HALF-1:0]};
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= s_axis_tlast;
                        m_axis_tuser  <= pending_sof;
                        pending_sof   <= s_axis_tuser;   // new frame right here
                        have_half     <= 1'b0;
                        if (s_axis_tlast) odd_line_sticky <= odd_line_sticky;
                    end else begin
                        // Consumer stalled at the moment a beat completed: the
                        // input beat cannot be taken, so it is lost and counted.
                        have_half           <= 1'b0;
                        pending_sof         <= 1'b0;
                        output_stall_sticky <= 1'b1;
                        output_stall_count  <= output_stall_count + 32'd1;
                    end
                end
            end
        end

        // An odd line that ended on the second half is normal (even width);
        // the only odd-line events are the two paths above that clear have_half
        // on a line end while a half beat is still held.
    end
    endgenerate
endmodule
`default_nettype wire
