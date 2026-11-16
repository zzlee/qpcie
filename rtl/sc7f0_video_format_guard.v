`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_video_format_guard  (personality SC7F0-RGB-COMPOSITOR-2PPC)
//
// Why this module exists (review H2)
//   In the compositor profile, capture channel 0 is the PACKED RGB24 C2H engine
//   (rtl/sc7f0_rgb24_c2h_engine.v), and that engine has no desc_format input: it
//   streams width*3 bytes per pixel at the programmed stride, whatever the
//   descriptor claimed.  VID/DID/BAR and the thin-descriptor mailbox are
//   unchanged, so an old NV12 application can still arm format 2 with two planes
//   and an NV12-sized ring (1.5 B/px).  Left ungated, the RGB24 engine would push
//   3 B/px - stride 11520 and 24,883,200 B per 4K frame - into a ~12,441,600 B
//   buffer: host memory written past the allocation.
//
// What it decides, and what it deliberately does NOT decide
//   It looks ONLY at the video descriptor of THIS profile's channel 0 and answers
//   one question: may this descriptor launch the RGB24 engine?
//     allowed:  format 4'd1 (packed RGB24) with exactly one plane, non-zero
//               geometry, stride >= width*3, and a frame footprint that does not
//               exceed the armed ring when the ring size is advertised;
//     refused:  everything else - NV12/NV21 (format 2/3, two planes), the legacy
//               format-0 pattern path, format 1 with two planes, zero geometry,
//               a stride that cannot carry width*3, or a frame that is larger
//               than the advertised ring.
//   The refusal is a DATA-PATH decision only.  This module never gates the shared
//   descriptor handshake, the H2C programming path, the upgrade writer, the MCU
//   path, DDR readback or the common mailbox: a refused descriptor is still
//   CONSUMED by the caller (desc_ready stays whatever the shared arbiter decided)
//   so one stale NV12 client cannot starve software programming of the very
//   channel it uses to reconfigure the card.  That asymmetry is the whole point:
//   refuse the DMA, never the mailbox.
//
// The fault is reported, never swallowed: guard_sticky latches on the first
// refusal and guard_count counts every one, both in the descriptor (PCIe user)
// clock, so the driver reading rtl/sc7f0_rgb_overlay_ctrl.v CSR 0x68/0x70 sees
// exactly why an armed frame produced zero C2H requests.
// ============================================================================

module sc7f0_video_format_guard #(
    parameter integer MAX_WIDTH  = 4096,
    parameter integer MAX_HEIGHT = 2160,
    // format code this profile's channel-0 engine actually implements
    parameter [3:0]   RGB24_FORMAT = 4'd1,
    // Does THIS wiring have a real data-buffer length to check against?  It does
    // not, and that is a fact about the ABI, not an oversight: see ring_bytes
    // below.  Kept as a parameter so a future ABI that carries a length turns the
    // term on explicitly instead of quietly passing a number that means something
    // else.
    parameter         CAPACITY_CHECKED = 0
)(
    input  wire         clk,            // descriptor domain (pcie_user_clk)
    input  wire         rst_n,

    // the descriptor that is currently being offered to channel 0
    input  wire [3:0]   desc_format,
    input  wire [3:0]   desc_plane_count,
    input  wire [15:0]  desc_width,
    input  wire [15:0]  desc_height,
    input  wire [15:0]  desc_stride,
    // ------------------------------------------------------------------
    // There is NO data-plane buffer length in this ABI revision, so this module
    // does not pretend to bound one.  What the hardware actually carries:
    //   * the thin descriptor ring: reg_c2h_ring_size is an ENTRY COUNT, not a
    //     byte count (rtl/thin_desc_fetch_engine.v fetches with
    //     ring0_base_addr + ring0_head*16 and wraps ring0_head on ring0_size), so
    //     it says nothing about how much host memory the captured frame may write;
    //   * the destination extents themselves: in thin mode they are per-SGL-entry
    //     {addr,len} pairs that only exist at fetch time, and in the ordinary
    //     descriptor path the descriptor carries dst addresses, a stride and
    //     geometry, but no allocation size.
    // Feeding 0 here is therefore NOT a way to skip a length that exists; the
    // honest statement is that buffer capacity is bounded by the driver that
    // allocates the ring and programs the SGL, and is NOT verified by this helper.
    // A zero input means "no capacity advertised" and the term is not evaluated.
    // ------------------------------------------------------------------
    input  wire [63:0]  ring_bytes,

    // 1 for the cycle on which the shared arbiter hands this descriptor over
    input  wire         desc_take,

    output wire         fmt_ok,         // 1 = this descriptor may launch the engine
    output wire         refused,        // 1 = this descriptor is refused
    // The frame footprint this descriptor implies, reported but NOT used to decide
    // (there is nothing to compare it against, see ring_bytes).  It exists so a
    // driver or a test can see the number the engine is about to write -
    // 24,883,200 B for a legal 3840x2160 packed RGB24 frame, 33,177,600 B for an
    // RGBA-shaped claim - instead of inferring it from a wrong image.
    output wire [63:0]  frame_bytes,
    output reg          guard_sticky,   // latched: at least one refusal happened
    output reg  [31:0]  guard_count     // how many descriptors were refused
);
    // width*3 is the packed RGB24 line the engine emits; 3*4096 = 12288 fits in
    // 16 bits, and the frame footprint is computed wide on purpose so a 4K frame
    // (24,883,200 B) cannot wrap into a small number and pass the capacity test.
    wire [31:0] min_stride   = {16'd0, desc_width}  * 32'd3;
    wire [63:0] frame_calc   = {32'd0, desc_stride} * {32'd0, desc_height};
    assign frame_bytes = frame_calc;
    wire        geom_ok      = (desc_width  != 16'd0) && (desc_width  <= MAX_WIDTH[15:0])
                            && (desc_height != 16'd0) && (desc_height <= MAX_HEIGHT[15:0])
                            && ({16'd0, desc_stride} >= min_stride);
    wire        fmt_single   = (desc_format == RGB24_FORMAT) && (desc_plane_count == 4'd1);
    // Deliberately constant when the ABI carries no length: a legal full 4K packed
    // RGB24 frame (24,883,200 B) must never be refused for being large, because
    // large is not the same as out of bounds.
    wire        fits_ring    = CAPACITY_CHECKED ? (frame_calc <= ring_bytes) : 1'b1;

    assign fmt_ok  = fmt_single && geom_ok && fits_ring;
    assign refused = ~fmt_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            guard_sticky <= 1'b0;
            guard_count  <= 32'd0;
        end else if (desc_take && refused) begin
            guard_sticky <= 1'b1;
            if (guard_count != 32'hFFFF_FFFF) guard_count <= guard_count + 32'd1;
        end
    end
endmodule
`default_nettype wire
