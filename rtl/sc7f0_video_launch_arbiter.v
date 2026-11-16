`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_video_launch_arbiter  (personality SC7F0-RGB-COMPOSITOR-2PPC)
//
// Channel 0 of the RGB compositor profile has two ways to hand a frame to the
// packed RGB24 capture engine and both used to be ungated in
// rtl/custom_pcie_dma_top.v:
//   1. the ordinary descriptor path (c2h_desc_valid && nv12_desc_select), and
//   2. the thin walker path (thin_active && thin_frame_launch_req), which builds the
//      same 245-bit launch bus itself in rtl/thin_desc_fetch_engine.v.
// This module is BOTH entries plus the shared crossing, instantiated by
// custom_pcie_dma_top.v, so the arbiter a fixture exercises is the arbiter the card
// ships.  The two always blocks below were MOVED out of custom_pcie_dma_top.v and
// keep its branch structure and its expressions, including:
//   * the branch selector `thin_active && thin_fmt_ok`, so an ordinary descriptor can
//     still be launched while an unsafe thin profile is armed and refused (the
//     programming path is never blocked by a refused video profile), and
//   * nv12_desc_ready, which is the pre-guard expression unchanged: a refused
//     descriptor is still CONSUMED from the shared mailbox.
//   * force_clear (reg_video_ctrl[0]) clearing a pending crossing.
//
// Three guard levels
//   * ordinary entry: the descriptor as offered (format, plane count, width in
//     PIXELS, height, stride in BYTES).
//   * thin profile level: what the walker is CONFIGURED to capture (vch0_ctrl[7:4],
//     vch0_width_w, vch0_height_w, vch0_stride0_w).  Refusing here gates the
//     walker's enable, so it never fetches a descriptor, never pushes an SGL entry
//     and never raises a launch: nothing is queued, so refusal leaves no residue.
//   * thin snapshot level: what the walker is about to put ON THE BUS, which is what
//     the engine consumes.  The bus is decoded here and judged directly - after the
//     producer-side units fix (rtl/thin_desc_fetch_engine.v WIDTH_FIELD_PIXELS) the
//     bus width field is PIXELS on this personality, so no arithmetic on the stride
//     is needed and none is done: the active width is never reverse-derived from a
//     row pitch, because a padded stride (3840 px at 12288 B) and an active stride
//     (3840 px at 11520 B) must both be legal and must not be confused.
//     bus_matches_profile additionally cross-validates that the snapshot the guard
//     judged is the snapshot the engine will consume (format and height agree with
//     the armed profile, and the bus pitch is the profile's when the profile arms
//     one); a mismatch is refused rather than launching "one geometry guarded,
//     another geometry DMA'd".
//
// Refusal protocol
//   * ordinary: still consumed (desc_ready), never launched, no owner taken.
//   * thin: the request is ACKED (thin_launch_ack) and the walker's frame is RETIRED
//     (thin_frame_abort), otherwise the walker would hold frame_launch_req waiting
//     for a crossing that never happens, or hold frame_active waiting for a
//     frame_done that a refused engine never sends.
//   * an unsafe thin profile is counted per arm attempt / per unsafe reprogram, not
//     per clock, and it does not depend on the walker producing a request - with the
//     enable gated there is no request to count, which is exactly the case that has
//     to be visible to software.  The report is REGISTERED (see prof_take_r1): an
//     unregistered one lost the episode whenever the CSR moved in the same timestep
//     as a clock edge, which is what a register file does on a write.
//   * every refused launch is reported, by whichever predicate refused it, including
//     a snapshot that is legal on its own but is not the armed profile's frame.
// Timing note that bounds what "refused under a live request" can mean: a legal thin
//   request is latched by the crossing in the same cycle it appears (and the walker
//   only raises one while it is enabled and the owner is free), so what this module
//   can refuse is the snapshot as presented.  A profile reprogrammed to unsafe after
//   that edge cannot re-judge a frame that was armed as RGB24; it stops the NEXT
//   frame, and the reprogram itself is the counted unsafe episode.  A snapshot that
//   stays wrong is retried by the walker, so the refusal counter advances once per
//   refused request and saturates rather than wrapping.
//
// What is NOT claimed
//   No data-plane allocation length exists in this ABI (reg_c2h_ring_size is an
//   ENTRY COUNT; destination extents are per-SGL {addr,len} pairs known only at
//   fetch time), so this module bounds FORMAT and GEOMETRY, never buffer capacity:
//   see sc7f0_video_format_guard.v and its CAPACITY_CHECKED parameter.
// ============================================================================

module sc7f0_video_launch_arbiter #(
    parameter integer MAX_WIDTH  = 4096,
    parameter integer MAX_HEIGHT = 2160,
    // 0 = the pre-guard crossing: same branch structure, same handshake, no refusal
    // and no reporting.  Build-time constant, not a runtime bypass; this is what a
    // profile whose channel-0 engine is already format-aware gets.
    parameter ENABLED = 1
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- entry 1: ordinary capture descriptor ----------------------------
    input  wire         desc_valid,
    input  wire         desc_select,
    input  wire [3:0]   desc_format,
    input  wire [3:0]   desc_plane_count,
    input  wire [15:0]  desc_width,      // PIXELS, as the descriptor programs it
    input  wire [15:0]  desc_height,
    input  wire [15:0]  desc_stride,     // BYTES per row (may be padded)
    input  wire [63:0]  desc_y_addr,
    input  wire [63:0]  desc_uv_addr,
    input  wire         desc_sg_mode,
    input  wire [63:0]  timestamp,
    output wire         desc_ready,      // consumed whether or not it is launched

    // ---- entry 2: thin walker -------------------------------------------
    input  wire         thin_active,
    input  wire [3:0]   thin_format,     // vch0_ctrl[7:4]
    input  wire [15:0]  thin_width,      // vch0_width_w, pixels
    input  wire [15:0]  thin_height,     // vch0_height_w
    input  wire [15:0]  thin_stride0,    // vch0_stride0_w, 0 = derive width*3
    output wire         thin_enable,     // unsafe profile = never fetch
    input  wire         thin_launch_req,
    input  wire [244:0] thin_launch_bus,
    output wire         thin_launch_ack,
    output wire         thin_frame_abort,

    // ---- shared engine crossing -----------------------------------------
    input  wire         force_clear,     // reg_video_ctrl[0]
    input  wire         hs_src_rcv,
    input  wire         owner_release,   // pcie_frame_done
    output reg          hs_send_q,
    output reg  [244:0] hs_bus_q,
    output reg          ch0_owner_busy,

    // ---- reporting -------------------------------------------------------
    output wire         desc_fmt_ok,
    output wire         desc_refused,
    output wire         thin_profile_ok,   // armed thin profile may drive the engine
    output wire         guard_sticky,
    output wire [31:0]  guard_count,
    output wire [63:0]  desc_frame_bytes,
    output wire [63:0]  thin_frame_bytes
);
    // 245-bit launch bus: {format[3:0], sg_mode, timestamp[63:0], stride[15:0],
    //                      height[15:0], width[15:0], uv_addr[63:0], y_addr[63:0]}
    localparam integer F_OFS = 241, ST_HI = 175, ST_LO = 160,
                     H_HI  = 159, H_LO  = 144, W_HI = 143, W_LO = 128;

    wire        desc_ok_w, thin_prof_ok_w, thin_bus_ok_w;
    wire        desc_g_sticky, thin_prof_sticky;
    wire [31:0] desc_g_count, thin_prof_count;
    wire [63:0] desc_frame_bytes_w, thin_prof_bytes, thin_bus_bytes;

    // ---- entry 1: the descriptor as offered ------------------------------
    // rgb_desc_take, verbatim from custom_pcie_dma_top.v
    wire rgb_desc_take = desc_valid && desc_select && !hs_send_q && !hs_src_rcv &&
                         !ch0_owner_busy;
    assign desc_ready = rgb_desc_take;   // unchanged by the guard: CONSUMED either way
    sc7f0_video_format_guard #(.MAX_WIDTH(MAX_WIDTH), .MAX_HEIGHT(MAX_HEIGHT),
                               .CAPACITY_CHECKED(0)) u_desc_guard (
        .clk(clk), .rst_n(rst_n),
        .desc_format(desc_format), .desc_plane_count(desc_plane_count),
        .desc_width(desc_width), .desc_height(desc_height), .desc_stride(desc_stride),
        .ring_bytes(64'd0), .desc_take(rgb_desc_take && ENABLED),
        .fmt_ok(desc_ok_w), .refused(desc_refused),
        .frame_bytes(desc_frame_bytes_w),
        .guard_sticky(desc_g_sticky), .guard_count(desc_g_count));

    // ---- entry 2, profile level ------------------------------------------
    // Count the ARM attempt and any later unsafe reprogram.  This cannot be derived
    // from a launch request: with the enable gated below the walker never raises one,
    // and "software armed an NV12 profile against an RGB24 engine" is precisely the
    // event that has to be countable.
    // One refusal per UNSAFE EPISODE: arming an unsafe profile, or reprogramming a
    // running profile into an unsafe one.  A level would count every clock.
    //
    // Why the report is REGISTERED instead of combinational.  The first version
    // ANDed eligibility with a flag that was set from that same combinational
    // condition, so the flag could close the window in the very delta that opened
    // it: whenever thin_active/thin_format moved in the same timestep as a clock edge
    // (exactly what a register file does when a write lands on that edge), the flag
    // was already 1 before the guard's counter ever sampled desc_take, and the
    // episode counted ZERO.  Measured: arming an NV12 profile with a drive that lands
    // on the edge gave delta 0, the identical change one delta later gave delta 1 -
    // the report depended on process ordering rather than on the hardware contract.
    // Now eligibility is sampled into prof_take_r1, so desc_take is guaranteed to be
    // held across exactly one clock edge no matter which delta the CSR moved in, and
    // only an actually issued report marks the episode counted.  The flag clears when
    // the profile is disarmed or made safe again, so every later unsafe reprogram
    // reports once more.
    reg  prof_take_r1    = 1'b0;
    reg  unsafe_reported = 1'b0;
    wire thin_prof_eligible = thin_active && ENABLED && !thin_prof_ok_w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prof_take_r1    <= 1'b0;
            unsafe_reported <= 1'b0;
        end else begin
            prof_take_r1 <= thin_prof_eligible && !unsafe_reported && !prof_take_r1;
            if (prof_take_r1)
                unsafe_reported <= 1'b1;              // this episode is reported
            else if (!thin_active || thin_prof_ok_w)
                unsafe_reported <= 1'b0;              // disarmed/made safe: re-arm
        end
    end
    wire thin_prof_take = prof_take_r1;
    // The walker's own row-pitch derivation (rtl/thin_desc_fetch_engine.v
    // effective_stride0): an armed stride of 0 means "derive it", RGB24 as width*3
    // and the legacy path as width.  Judging anything else would let the guard see a
    // pitch the walker never uses.
    wire [15:0] thin_stride_eff = (thin_stride0 != 16'd0) ? thin_stride0
                                : (thin_format == 4'd1 ? (thin_width * 16'd3)
                                                       : thin_width);
    sc7f0_video_format_guard #(.MAX_WIDTH(MAX_WIDTH), .MAX_HEIGHT(MAX_HEIGHT),
                               .CAPACITY_CHECKED(0)) u_thin_prof_guard (
        .clk(clk), .rst_n(rst_n),
        .desc_format(thin_format),
        // The thin ABI carries no plane-count field: the walker's second plane is
        // itself derived from format != RGB24, so the format term is the load-bearing
        // one here and the plane term only restates it.
        .desc_plane_count(4'd1),
        .desc_width(thin_width), .desc_height(thin_height),
        .desc_stride(thin_stride_eff),
        .ring_bytes(64'd0), .desc_take(thin_prof_take),
        .fmt_ok(thin_prof_ok_w), .refused(), .frame_bytes(thin_prof_bytes),
        .guard_sticky(thin_prof_sticky), .guard_count(thin_prof_count));

    // ---- entry 2, snapshot level (the bus the engine will consume) --------
    wire [3:0]  bus_fmt    = thin_launch_bus[F_OFS+3:F_OFS];
    wire [15:0] bus_width  = thin_launch_bus[W_HI:W_LO];   // pixels on this personality
    wire [15:0] bus_height = thin_launch_bus[H_HI:H_LO];
    wire [15:0] bus_stride = thin_launch_bus[ST_HI:ST_LO]; // bytes per row
    // The snapshot must be the armed profile's own frame, and its pitch must be able
    // to carry it.  Comparing the bus against the live profile is not "judging the
    // CSR instead of the bus": BOTH are judged, and disagreement is a refusal.
    wire bus_matches_profile = (bus_fmt == thin_format) &&
                               (bus_height == thin_height) &&
                               ((thin_stride0 == 16'd0) || (bus_stride == thin_stride0));
    wire thin_launch_take = thin_active && thin_launch_req && !hs_send_q &&
                            !hs_src_rcv && !ch0_owner_busy;
    sc7f0_video_format_guard #(.MAX_WIDTH(MAX_WIDTH), .MAX_HEIGHT(MAX_HEIGHT),
                               .CAPACITY_CHECKED(0)) u_thin_bus_guard (
        .clk(clk), .rst_n(rst_n),
        .desc_format(bus_fmt), .desc_plane_count(4'd1),
        .desc_width(bus_width), .desc_height(bus_height), .desc_stride(bus_stride),
        .ring_bytes(64'd0), .desc_take(thin_launch_take && ENABLED),
        .fmt_ok(thin_bus_ok_w), .refused(), .frame_bytes(thin_bus_bytes),
        .guard_sticky(), .guard_count());

    wire desc_fmt_ok_e      = ENABLED ? desc_ok_w      : 1'b1;
    wire thin_prof_ok       = ENABLED ? thin_prof_ok_w : 1'b1;
    wire thin_launch_ok     = (ENABLED ? thin_bus_ok_w : 1'b1) && bus_matches_profile;
    assign desc_fmt_ok      = desc_fmt_ok_e;
    assign thin_profile_ok  = thin_prof_ok;

    // Exactly the pre-guard enable expression, now ANDed with the profile guard.
    assign thin_enable = thin_active && thin_prof_ok;
    // A refused launch is still consumed and the walker's frame retired.
    wire   thin_launch_refused = thin_launch_take &&
                                 (!thin_prof_ok || !thin_bus_ok_w ||
                                  !bus_matches_profile);
    assign thin_launch_ack   = hs_src_rcv | thin_launch_refused;
    assign thin_frame_abort  = thin_launch_refused;

    // Every refused launch is reported, whichever of the three predicates refused it.
    // Counting only inside the snapshot guard would hide the cross-check term: a bus
    // that is legal on its own but is not the armed profile's own frame is refused here
    // and would be reported nowhere, so a driver reading the guard CSR would see "no
    // refusal" for a frame it never got.  The refusal retires the walker's request in
    // the same cycle, so this is one event per refused request and cannot run away per
    // clock; the counter still saturates instead of wrapping.
    reg         snap_sticky_q = 1'b0;
    reg  [31:0] snap_count_q  = 32'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snap_sticky_q <= 1'b0;
            snap_count_q  <= 32'd0;
        end else if (thin_launch_refused) begin
            snap_sticky_q <= 1'b1;
            if (snap_count_q != 32'hFFFF_FFFF) snap_count_q <= snap_count_q + 32'd1;
        end
    end

    assign guard_sticky = ENABLED ? (desc_g_sticky | thin_prof_sticky |
                                     snap_sticky_q) : 1'b0;
    assign guard_count  = ENABLED ? (desc_g_count + thin_prof_count + snap_count_q)
                                  : 32'd0;
    assign desc_frame_bytes = desc_frame_bytes_w;
    assign thin_frame_bytes = thin_bus_bytes;

    // ---- the crossing (branch structure preserved from custom_pcie_dma_top.v) --
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_send_q <= 1'b0;
            hs_bus_q  <= 245'd0;
        end else if (force_clear) begin
            hs_send_q <= 1'b0;
            hs_bus_q  <= 245'd0;
        end else if (thin_active && thin_prof_ok && thin_launch_ok) begin
            if (!hs_send_q && !hs_src_rcv && thin_launch_req && !ch0_owner_busy) begin
                hs_bus_q  <= thin_launch_bus;
                hs_send_q <= 1'b1;
            end else if (hs_send_q && hs_src_rcv) begin
                hs_send_q <= 1'b0;
            end
        end else if (!hs_send_q && !hs_src_rcv && !ch0_owner_busy &&
                     desc_valid && desc_select && desc_fmt_ok_e) begin
            hs_bus_q  <= {desc_format, desc_sg_mode, timestamp, desc_stride,
                          desc_height, desc_width, desc_uv_addr, desc_y_addr};
            hs_send_q <= 1'b1;
        end else if (hs_send_q && hs_src_rcv) begin
            hs_send_q <= 1'b0;
        end
    end

    // The descriptor owner is held until the PCIe-side EOF retires it: eng_busy drops
    // once the video FIFO drains into the CDC, before the final MWr is sent, and
    // accepting another descriptor then would mix frame addresses.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ch0_owner_busy <= 1'b0;
        else if (owner_release)
            ch0_owner_busy <= 1'b0;
        else if (thin_active && thin_prof_ok && thin_launch_ok) begin
            if (thin_launch_req && !hs_send_q && !hs_src_rcv && !ch0_owner_busy)
                ch0_owner_busy <= 1'b1;
        end else if (desc_valid && desc_select && desc_fmt_ok_e && !hs_send_q &&
                     !hs_src_rcv && !ch0_owner_busy)
            ch0_owner_busy <= 1'b1;
    end
endmodule
`default_nettype wire
