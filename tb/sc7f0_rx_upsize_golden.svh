`ifndef SC7F0_RX_UPSIZE_GOLDEN_SVH
`define SC7F0_RX_UPSIZE_GOLDEN_SVH
// ============================================================================
// tb/sc7f0_rx_upsize_golden.svh   (simulation only, included by BOTH the
// stimulus and the oracle - one definition, so the two can never drift)
//
// Position-addressable golden pixel plus the UG934 lane packing for it.
//
// WHY THE PACKING FUNCTION EXISTS AS ITS OWN STEP.  Two different orders live
// on this bus and conflating them is exactly how the original defect hid:
//
//   * pixel chronology (which pixel of a multi-pixel beat sits in which bit
//     group) is governed by UG934, "Encoding Multiple Pixels - Static TDATA
//     Configuration": "pixels should be packed from least significant bit (LSB)
//     to MSB, e.g. the least significant pixel should correspond to the
//     left-most pixel in a scanline, or to the pixel captured earliest in
//     time".  That decides WHICH 24-bit group, and is handled by the stimulus
//     (low group = earlier pixel) and by the oracle (word[23:0] = pixel 0).
//   * component order INSIDE one 24-bit pixel is a separate rule: UG934
//     Table 1-5 "Video Format Codes and Data Representation", row VF=2 RGB,
//     prints R B G from MSB to LSB per pixel (Table 1-4 for one pixel per
//     beat).  rtl/sc7f0_rgb24_axis_pack.v:116-133 already relies on that
//     (byte0 = pix[23:16] = R, byte1 = pix[7:0] = G, byte2 = pix[15:8] = B).
//     It is NOT memory byte order: PG278 stores RGB8 address-ascending R,G,B.
//
// sc7f0_golden_rgb() therefore returns the logical pixel as {R,G,B} (easy to
// read in a failure message) and sc7f0_ug934_pix() returns the same pixel in
// the on-wire lane order {R,B,G}.  A test that used the logical order on the
// wire would pass with swapped lanes, so the two are kept apart deliberately.
// ============================================================================

// Logical golden pixel: deterministic, position-addressable, and deliberately
// strongly dependent on x so that a rotate-by-two-pixels error cannot hide
// behind locally repeated colours (r changes by +3 for every pixel, so the
// four pixels of any 4-pixel group are always mutually distinct).
function [23:0] sc7f0_golden_rgb;
    input integer x;
    input integer y;
    reg [7:0] r, g, b;
    begin
        r = ((x * 3) + y) & 8'hFF;
        g = ((x >> 2) ^ (y * 5)) & 8'hFF;
        b = (x + (y * 7)) & 8'hFF;
        sc7f0_golden_rgb = {r, g, b};          // logical {R,G,B}, human readout
    end
endfunction

// The same pixel as it must appear on an AXI4-Stream RGB video bus: one 24-bit
// pixel group, lanes ordered R(MSB) B G G(LSB) per UG934 Table 1-5 (VF=2 RGB).
function [23:0] sc7f0_ug934_pix;
    input integer x;
    input integer y;
    reg [23:0] p;
    begin
        p = sc7f0_golden_rgb(x, y);            // {R,G,B}
        sc7f0_ug934_pix = {p[23:16], p[7:0], p[15:8]};   // -> {R,B,G}
    end
endfunction
`endif
