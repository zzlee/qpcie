`default_nettype none
// ============================================================================
// Module: sc7f0_rgb24_c2h_engine
// Personality: SC7F0-RGB-COMPOSITOR-2PPC.  Inside `SC7F0_RGB_COMPOSITOR` it
//              takes ownership of capture channel 0 in place of
//              rtl/nv12_capture_engine.v (rtl/custom_pcie_dma_top.v); every
//              legacy profile keeps the untouched NV12/NV16 engine.
//
// Why a dedicated engine
//   Packed RGB24 is 3 bytes per pixel.  nv12_capture_engine addresses a Y plane
//   plus a semiplanar UV plane at 1 or 2 bytes per pixel per plane, so it cannot
//   express a 3-byte pixel pitch without padding to 4 bytes (XRGB, which is not
//   RGB24) or inventing a second plane.  This engine walks line_bytes = width*3
//   with an independent stride, which is what the host descriptor already means.
//
// Request interface (programming ABI unchanged)
//   Exactly the interface the NV12 engine drove on channel 0:
//     {req_valid, req_addr[63:0], req_dw_len, req_data[127:0], req_data_ready,
//      req_ack} -> the same rtl/video_req_cdc.v instance.
//   So rq_tx_encoder, the thin descriptor ring, the SGL fetch path, the
//   byte-length semantics and the host driver/ioctls are unchanged.  req_dw_len
//   is a DWord count that is a multiple of WR_DWORDS (4), which is what
//   video_req_cdc divides by, and req_valid is held until req_ack and dropped
//   afterwards, because video_req_cdc's writer leaves WR_DRAIN only when valid
//   falls.  Data is presented from a register, and a beat is popped from the
//   source FIFO on the same cycle the encoder latches the previous one, so a beat
//   is never skipped and never sent twice.
//
// Geometry (identical derivation to the NV12 RGB mode)
//   line_bytes  = (frame_width <= MAX_WIDTH) ? frame_width*3 : frame_width
//   stride      = max(frame_stride, line_bytes)
//   frame_bytes = line_bytes * frame_height
//
// Frame locking
//   The packer marks the first 16-byte beat of each source frame.  On that beat
//   the engine re-locks the line/column counters to the frame base address,
//   re-arms the SGL walker and stamps frame_pts.  Before the first re-lock after
//   arming, payload is discarded (the FIFO can only hold a mid-frame fragment).
//   A frame that ends early is counted in drop_count and is NOT announced as
//   completed; bytes beyond the descriptor are drained and counted in
//   protocol_error_count instead of being written over the next frame.
//
// Burst rules
//   size <= MAX_REQ_BYTES (256 B, as published for NV12), never past the line
//   end, never past the current SGL segment, never across a 4 KB boundary, always
//   a whole number of 16-byte beats.  A burst is committed only when the packer
//   FIFO already holds all of its beats: video_req_cdc raises s_req_data_ready as
//   soon as it has the header and cannot wait for data that has not arrived.
//
// No pacer by design: a free-running scan source is paced by its own timing, and
// pausing this engine would only overflow the crossing FIFO.  The NV12 software
// pacer is therefore absent here rather than silently ignored.
// ============================================================================
`timescale 1ns / 1ps

module sc7f0_rgb24_c2h_engine #(
    parameter integer MAX_WIDTH       = 4096,
    parameter integer PCIE_DATA_WIDTH = 128,
    parameter integer MAX_REQ_BYTES   = 256,
    parameter integer SRC_FIFO_DEPTH  = 1024
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // thin descriptor launch (the fields the NV12 engine consumed on ch0)
    input  wire                     desc_valid,
    output reg                      desc_ready,
    input  wire                     desc_sg_mode,
    input  wire [63:0]              plane_y_addr,
    input  wire [15:0]              frame_width,
    input  wire [15:0]              frame_height,
    input  wire [15:0]              frame_stride,

    // SGL segment push (sg_host_fetch_engine), single plane
    input  wire                     sgl_wr_en,
    input  wire [63:0]              sgl_wr_addr,
    input  wire [31:0]              sgl_wr_len,
    input  wire [31:0]              sgl_wr_flags,
    output wire [6:0]               cur_sgl_count,
    output wire                     sgl_pop_ready,

    // Read-only diagnosis bundle.  Bit positions are the BAR0 ABI (GLOBAL
    // 0x0E0, rtl/axil_reg_space.v) and are listed at the assign below; they are
    // never renumbered, only extended into still-zero bits.
    output wire [31:0]              dbg_bus,

    input  wire [63:0]              global_timestamp,

    // packed RGB24 payload, already in this clock domain
    input  wire [127:0]             p_axis_tdata,
    input  wire                     p_axis_tuser,   // first beat of a source frame
    input  wire                     p_axis_tvalid,
    input  wire [$clog2(SRC_FIFO_DEPTH):0] p_axis_avail,
    output wire                     p_axis_tready,

    // C2H MWr request interface towards video_req_cdc
    output reg                      c2h_req_valid,
    output reg  [63:0]              c2h_req_addr,
    output reg  [10:0]              c2h_req_dw_len,
    output wire [PCIE_DATA_WIDTH-1:0] c2h_req_data,
    output reg                      c2h_req_last,
    input  wire                     c2h_req_data_ready,
    input  wire                     c2h_req_ack,

    output reg                      video_busy,
    output reg                      video_frame_done,
    output reg  [63:0]              frame_pts,
    output reg  [31:0]              protocol_error_count,
    output reg  [31:0]              drop_count,
    output reg  [31:0]              frames_completed,
    output reg  [31:0]              align_discard_count,
    output reg  [31:0]              bytes_committed,
    output reg  [15:0]              active_line_bytes,
    output reg  [15:0]              active_stride,
    input  wire                     src_overflow_sticky,
    input  wire                     src_line_align_sticky,
    output reg                      error_sticky
);
    localparam integer BEAT_BYTES = 16;                        // 128-bit payload beat
    localparam integer S_IDLE  = 0, S_ALIGN = 1, S_ARM = 2,
                       S_REQ   = 3, S_DRAIN = 4;

    // ------------------------------------------------------------------------
    // geometry latched from the descriptor
    // ------------------------------------------------------------------------
    function [15:0] rgb_line_bytes;
        input [15:0] w;
        rgb_line_bytes = (w <= MAX_WIDTH[15:0]) ? (w * 16'd3) : w;
    endfunction

    wire [15:0] desc_line_bytes = rgb_line_bytes(frame_width);
    wire [15:0] desc_stride = (frame_stride >= desc_line_bytes) ? frame_stride
                                                                : desc_line_bytes;
    wire        desc_ok     = (frame_height != 16'd0) && (desc_line_bytes != 16'd0) &&
                              (desc_line_bytes[3:0] == 4'd0);

    reg  [2:0]  state;
    reg         armed;
    reg         locked;              // a frame start observed since arming
    reg  [15:0] height_q, stride_q, line_bytes_q;
    reg  [31:0] frame_bytes_q;
    reg  [63:0] frame_base_q;

    // destination counters, advanced once per accepted burst
    reg  [63:0] dst_addr;
    reg  [15:0] send_line, send_offset;
    reg  [31:0] bytes_frame;

    // burst registers
    reg  [127:0] data_reg;
    reg  [4:0]   beats_left;         // beats still queued after data_reg
    reg  [15:0]  req_len_q;
    reg          line_end_q;         // the in-flight burst ends a line
    reg          last_writes_q;      // the in-flight burst completes the frame

    // ------------------------------------------------------------------------
    // SGL walker (same role as the NV12 Y walker: padded linear image)
    // ------------------------------------------------------------------------
    reg          walker_start;
    reg          walker_start_pend;
    reg          sgl_take;             // walker restarted for the live descriptor
    reg          adv_pulse;
    reg  [15:0]  adv_bytes;
    wire         walker_sgl_almost_full;
    wire         walker_sgl_empty;
    wire [63:0]  seg_addr;
    wire [31:0]  seg_bytes_left;
    wire         seg_valid;
    wire [15:0]  pad_bytes = (stride_q > line_bytes_q) ? (stride_q - line_bytes_q) : 16'd0;

    sg_segment_walker #(.FIFO_DEPTH(64)) u_sgl (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (walker_start),
        .sg_mode         (desc_sg_mode),
        .linear_base_addr(frame_base_q),
        .sgl_wr_en       (sgl_wr_en),
        .sgl_wr_addr     (sgl_wr_addr),
        .sgl_wr_len      (sgl_wr_len),
        .sgl_wr_flags    (sgl_wr_flags),
        .advance_burst   (adv_pulse),
        .burst_bytes     (adv_bytes),
        .current_addr    (seg_addr),
        .seg_bytes_left  (seg_bytes_left),
        .seg_valid       (seg_valid),
        .fifo_count      (cur_sgl_count),
        .fifo_almost_full(walker_sgl_almost_full),
        .fifo_empty      (walker_sgl_empty)
    );

    // ★ Defect 3 root-cause fix (docs/sc7f0_defect3_c2h_zero_payload_rootcause_20261116.md §5.1).
    //
    // sg_segment_walker's fifo_almost_full is an ACTIVE-HIGH "I am about to
    // overflow" flag (rtl/sg_segment_walker.v:57, count >= FIFO_DEPTH-20), while
    // this module's sgl_pop_ready is an "I can accept another entry" contract:
    // rtl/custom_pcie_dma_top.v feeds it straight into the SGL source FIFO's
    // rd_en and into sgl_wr_en (`!v_sgl_y_empty && v_sgl_y_pop_ready && eng_busy`).
    // Wiring the flag through un-inverted therefore made the engine announce
    // "ready" exactly when the walker was FULL, i.e. forever low while the walker
    // was empty, which is a self-locking loop: count = 0 => almost_full = 0 =>
    // sgl_wr_en = 0 => count stays 0, so seg_valid never rose, pl_seg_ready never
    // rose, burst_start never fired and not one C2H MWr was ever issued
    // (Payload 0 B / frames 0 / drops 0, thin ring frozen at head=12).
    //
    // The polarity is inverted exactly as the legacy engine that does stream
    // does it: rtl/nv12_capture_engine.v:165 and :194.
    assign sgl_pop_ready = !walker_sgl_almost_full && sgl_take;

    wire [63:0] target_addr = desc_sg_mode ? seg_addr : dst_addr;

    // ------------------------------------------------------------------------
    // burst sizing: whole 16-byte beats bounded by line end, 4 KB and segment.
    //
    // Registered planning stage (r10).  The sizing function reads only
    // registers (line_bytes_q, send_offset, dst_addr / walker seg_addr,
    // height_q, desc_sg_mode) and its result used to be ANDed straight into
    // p_axis_tready.  That put four cascaded 16-bit subtract/compare carry
    // chains and two more comparisons in front of the crossing FIFO's read
    // enable: measured 18 logic levels / 5 CARRY8 and 4.952 ns end to end at
    // 300 MHz (R7: -2.029 ns to u_rgb24_pack/u_cross read enable and to
    // last_writes_q, 1941 failing endpoints on capture_clk_300m).  It is a real
    // same-domain path, not a false path, so it is fixed structurally.
    //
    // The sizing inputs are sampled into pl_* and the sizing is then formed
    // combinationally from those registers, i.e. it is available one cycle
    // later.  pl_valid says whether that registered sizing still describes the
    // counters that are live *now*: it is only allowed to rise when no sizing
    // input changed at this edge (pl_moved) and the engine is parked in S_ARM
    // in both the sampled and the current cycle.  Every signal that can move a
    // sizing input is listed in pl_inputs_moving, so the check is structural
    // rather than "it will not change in practice"; a stale plan can never be
    // committed.  Because inputs move at exactly the ack / re-lock / descriptor
    // / walker-advance edges, the price is one idle pop cycle per burst, not
    // per beat: 16 beats + 1 cycle keeps the payload ceiling at 16 B * 300 MHz
    // * 16/17 = 4.52 GB/s against 1.59 GB/s of packed-RGB24 4K60, so no beat
    // is ever dropped for timing reasons and no geometry or byte order moves.
    // ------------------------------------------------------------------------
    // r11: the plan is computed in 16-byte BEAT units, not in bytes.
    //
    // The byte-unit form was measured on the full board (E26111335, post-route
    // phys_opt) as the worst capture_clk_300m -> capture_clk_300m path:
    //   pl_line_left_reg[14]/C -> pl_last_write_reg/D
    //   slack -0.736 ns, data 3.968 ns (1.349 logic / 2.619 route),
    //   11 logic levels = 4xCARRY8 + 2xLUT4 + 1xLUT5 + 4xLUT6,
    //   258 failing endpoints / TNS -22.148 ns in that group; the sibling
    //   endpoints pl_line_end_reg and pl_beats_reg[3:0] sit at -0.504 .. -0.314
    //   ns on the same cone.
    // Reading that cone back: p_lim_a -> p_lim_b -> p_lim_c is three *serial*
    // 16-bit magnitude compares, then a 16-bit add (pl_off + p_bytes_w), then a
    // 16-bit equality, then the AND with the height compare: one serial
    // carry-chain cascade in front of every plan register.
    //
    // Two structural facts about this plan kill most of that cascade:
    //
    //   (1) line_bytes_q has its low four bits zero (desc_ok) and send_offset
    //       only ever moves by a whole burst length, so the offset and the line
    //       length are always multiples of BEAT_BYTES.  A limit only ever
    //       matters through floor16(min(...)), and floor16() is monotonic, so
    //       floor16(min(S)) == min(floor16(S)).  The min can therefore be taken
    //       on value/16 (12 bits) instead of on bytes (16 bits) with no rounding
    //       change, and the burst length is that quotient shifted back by 4.
    //
    //   (2) pl_line_end was (pl_off + bytes) >= pl_lbq and pl_last_write used
    //       (pl_off + bytes) == pl_lbq.  bytes = floor16(min) is itself clamped
    //       by the line limit, so bytes <= pl_lbq - pl_off always, which makes
    //       ">= pl_lbq" and "== pl_lbq" the SAME predicate, and both are just
    //       "the line limit is what bound the min", i.e. line_beats <= every
    //       other sampled limit.  That is a set of independent compares against
    //       the sampled line budget: no adder, no equality against the min
    //       result, and the height test is sampled in stage 1 (pl_last_line), so
    //       the EOP / line / last-frame-write control is no longer stacked
    //       behind the sizing carry chain at all.
    //
    // Resulting cones, both entirely inside this clock (no CDC, no timing
    // exception, no multicycle, still the same two register stages so the plan
    // still describes the counters that are live when pl_valid is high):
    //   stage 1: one operator per live register - s_line_beats is a 12-bit
    //            subtract (was 16-bit), s_fourk_beats a 12-bit subtract, and
    //            s_seg_beats / s_seg_ready / s_last_line / pl_line_le_cap are
    //            muxes, OR-reduces or a constant compare (no carry chain).
    //   stage 2: a balanced 2-deep min tree for pl_bytes / pl_beats, and two
    //            parallel 12-bit compares ANDed with two stage-1 flags for
    //            pl_line_end / pl_last_write, which are now ~3 levels deep and
    //            fully independent of the min tree.
    // Burst sizes, addresses, byte order, reserve-before-commit rule, the
    // one-idle-cycle-per-burst initiation interval and the programming ABI are
    // unchanged.
    // ------------------------------------------------------------------------

    // Burst budget expressed in beats.  pl_beats and beats_left are 5 bits, so a
    // plan can never describe more than 31 beats; clamping the budget here keeps
    // bytes == 16*beats true for any MAX_REQ_BYTES the parameter is ever given
    // (the old saturating slice disagreed with itself above 256 B), and is inert
    // for the published and instantiated MAX_REQ_BYTES = 256 = 16 beats.
    localparam integer REQ_BEAT_MAX = MAX_REQ_BYTES / BEAT_BYTES;         // 16
    localparam [4:0]   REQ_BEAT_CAP = (REQ_BEAT_MAX > 31) ? 5'd31
                                                          : REQ_BEAT_MAX[4:0];
    localparam [11:0]  BEAT_CAP_W   = {7'd0, REQ_BEAT_CAP};

    reg  [11:0] pl_line_beats, pl_fourk_beats, pl_seg_beats;
    reg  [15:0] pl_bytes;
    reg  [4:0]  pl_beats;
    reg  [63:0] pl_addr;
    reg         pl_last_line, pl_line_le_cap;
    reg         pl_line_end, pl_last_write, pl_seg_ready;
    reg  [2:0]  pl_state;
    reg         pl_moved, pl_valid;
    reg         sof_locked;   // the marked head at the FIFO head is re-locked

    // stage 1: sample the sizing inputs, already normalised to whole beats.
    //
    //   s_line_beats  = (line_bytes_q - send_offset) / 16: exact, because both
    //                   operands are multiples of 16, and one carry bit shorter
    //                   than the byte-unit subtract it replaces.
    //   s_fourk_beats = floor16(4096 - addr[11:0]) / 16: the [12:4] slice *is*
    //                   that floor16, so a non-16-aligned tail still cannot be
    //                   rounded across the 4 KB edge.
    //   s_seg_beats   = floor16(p_seg_left16) / 16 clamped to REQ_BEAT_CAP: the
    //                   0x10000 saturation and the non-SGL 0xFFFF both become
    //                   0xFFF beats exactly as the byte form did, and moving the
    //                   parameter clamp here leaves the min tree two levels deep
    //                   (min(a,b,min(c,cap)) == min(a,b,c,cap)).
    //   s_seg_ready   = (seg_bytes_left >= 16) as an OR-reduce instead of a
    //                   32-bit magnitude compare: same truth, no carry chain.
    //   s_last_line   = height_q != 0 && send_line == height_q-1, sampled here so
    //                   the height compare is not stacked behind the sizing.
    wire [11:0] s_line_beats  = line_bytes_q[15:4] - send_offset[15:4];
    wire [12:0] s_fourk_left  = 13'd4096 - {1'b0, target_addr[11:0]};
    wire [11:0] s_seg_raw     = desc_sg_mode
                            ? ((|seg_bytes_left[31:16]) ? 12'hFFF : seg_bytes_left[15:4])
                            : 12'hFFF;
    wire        s_seg_ready   = !desc_sg_mode || (seg_valid && (|seg_bytes_left[31:4]));
    wire        s_last_line   = (height_q != 16'd0) &&
                                (send_line == (height_q - 16'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pl_line_beats  <= 12'd0;   pl_fourk_beats <= 12'd0;
            pl_seg_beats   <= 12'd0;   pl_addr        <= 64'd0;
            pl_last_line   <= 1'b0;    pl_line_le_cap <= 1'b0;
            pl_seg_ready   <= 1'b0;    pl_state       <= S_IDLE;
        end else begin
            pl_line_beats  <= s_line_beats;
            pl_fourk_beats <= s_fourk_left[12:4];
            pl_seg_beats   <= (s_seg_raw < BEAT_CAP_W) ? s_seg_raw : BEAT_CAP_W;
            pl_addr        <= target_addr;
            pl_last_line   <= s_last_line;
            pl_line_le_cap <= (s_line_beats <= BEAT_CAP_W);
            pl_seg_ready   <= s_seg_ready;
            pl_state       <= state;
        end
    end

    // stage 2: a 2-deep min tree over the sampled beat budgets, plus the line /
    // frame-end predicates taken straight from the sampled line budget.
    wire [11:0] p_min_af = (pl_line_beats < pl_fourk_beats) ? pl_line_beats
                                                            : pl_fourk_beats;
    wire [11:0] p_min    = (p_min_af < pl_seg_beats) ? p_min_af : pl_seg_beats;
    // "the line limit is what bound this burst".  Equal to the old
    // (pl_off + bytes) >= pl_lbq and to (pl_off + bytes) == pl_lbq; see (2).
    wire        p_line_end = pl_line_le_cap &&
                             (pl_line_beats <= pl_fourk_beats) &&
                             (pl_line_beats <= pl_seg_beats);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pl_bytes      <= 16'd0;
            pl_beats      <= 5'd0;
            pl_line_end   <= 1'b0;
            pl_last_write <= 1'b0;
        end else begin
            // p_min <= REQ_BEAT_CAP by construction, so {p_min[4:0],4'd0} is the
            // exact byte length and 16*pl_beats == pl_bytes holds by inspection.
            pl_bytes      <= {p_min[4:0], 4'd0};
            pl_beats      <= p_min[4:0];
            pl_line_end   <= p_line_end;
            pl_last_write <= p_line_end && pl_last_line;
        end
    end

    // Any input of the sizing function that is being written at this edge makes
    // the registered plan describing the *previous* counters useless for the
    // next cycle.  These are the only writers of send_offset / dst_addr /
    // line_bytes_q / height_q / frame_base_q / seg_addr / seg_bytes_left.
    wire ack_now  = c2h_req_valid && c2h_req_ack;
    // desc_valid is used as the level, not the accept: the descriptor fields
    // (desc_sg_mode above all) belong to the ring and may change any cycle the
    // ring is presenting a new descriptor, and desc_sg_mode selects which
    // address the plan was formed from.
    wire desc_now = desc_valid;
    wire lock_now = armed && (p_axis_tvalid && p_axis_tuser) && !sof_locked &&
                    !c2h_req_valid &&
                    ((state == S_ALIGN) || (state == S_ARM) || (state == S_DRAIN));
    wire seg_now  = adv_pulse || walker_start || sgl_wr_en;
    wire pl_inputs_moving = ack_now || desc_now || lock_now || seg_now;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pl_moved <= 1'b1;
            pl_valid <= 1'b0;
        end else begin
            pl_moved <= pl_inputs_moving;
            // pl_valid(t) == "the plan registers at t were formed from the
            // counter values that are live at t": stage 1/2 sampled cycle t-1
            // and nothing moved at the t-1 -> t edge.
            pl_valid <= !pl_inputs_moving && !pl_moved && (state == S_ARM) &&
                        (pl_state == S_ARM) && armed && locked;
        end
    end

    // rd_data_count of an asynchronous FIFO is formed from the WRITE pointer
    // synchronised into the read clock, so it LAGS the truth and can never exceed
    // it: requiring exactly the beats that are about to be committed is therefore
    // safe.  It is also the only rule that terminates.  The packer stops
    // publishing at the end of a frame, so two extra beats could never appear for
    // the last burst of a frame and the engine hung in S_ARM exactly one burst
    // short of frame_bytes - every frame would then be judged short, counted as a
    // drop, and no frame would ever retire.
    localparam integer AVW = $clog2(SRC_FIFO_DEPTH) + 1;   // p_axis_avail width
    wire [AVW:0] avail_ext = {1'b0, p_axis_avail};
    wire [AVW:0] need_ext  = {{(AVW-5){1'b0}}, {1'b0, pl_beats}};
    wire        have_all   = (avail_ext >= need_ext);

    // ------------------------------------------------------------------------
    // hand-shake
    // ------------------------------------------------------------------------
    wire head_beat   = p_axis_tvalid;
    wire head_is_sof = p_axis_tvalid && p_axis_tuser;
    // The beat that carries the sideband frame-start bit IS the frame's first
    // payload beat (rtl/sc7f0_rgb24_axis_pack.v publishes sof together with the
    // first whole 16-byte group, it is not a marker beat).  Two rules follow and
    // both are needed, or the head of every frame disappears:
    //   * it must not be swept by the discard path (pop_discard below), because
    //     that is where the pre-frame fragment goes, not the frame;
    //   * the re-lock must fire exactly once for it, so the same cycle may not
    //     also be the cycle that commits a burst against the previous frame's
    //     address.  sof_locked is that "this head is already re-locked" mark and
    //     burst_start waits for it instead of refusing sof heads outright.
    // The old pair of rules discarded the sof beat and required !head_is_sof to
    // commit, so 16 B of every frame were thrown away and the frame then looked
    // short: bytes_committed stopped at frame_bytes-16, the next frame start
    // counted a drop and latched error_sticky, and no frame ever retired.
    wire sof_needs_lock = head_is_sof && !sof_locked;
    // pl_bytes is 16*pl_beats by construction, so the non-zero test is taken on
    // the 5-bit plan count: fewer inputs on the term that drives the crossing
    // FIFO read enable (the other reported capture_clk_300m endpoint group).
    wire burst_start = (state == S_ARM) && armed && locked && head_beat &&
                       !sof_needs_lock &&
                       pl_valid && pl_seg_ready && (pl_beats != 5'd0) && have_all;
    wire consuming   = c2h_req_valid && c2h_req_data_ready;
    wire pop_stream  = consuming && (beats_left != 5'd0);
    wire pop_discard = ((state == S_ALIGN) || (state == S_DRAIN)) && head_beat &&
                       !head_is_sof;

    assign p_axis_tready = burst_start || pop_stream || pop_discard;
    assign c2h_req_data  = {{(PCIE_DATA_WIDTH-128){1'b0}}, data_reg};

    // The engine may accept one descriptor per handshake.  desc_ready is a
    // registered output, so without this gate a ring that holds desc_valid for two
    // cycles gets a second accept: a refused geometry is then counted twice, and
    // an accepted one re-latches the geometry registers under a frame that is
    // already running.
    reg  desc_launched;              // one accept per desc_valid assertion
    wire desc_accept = desc_valid && !desc_launched && !c2h_req_valid &&
                       (state != S_REQ);

    // ------------------------------------------------------------------------
    // When the walker is re-started (Defect 3 companion, same root-cause family).
    //
    // walker_start used to pulse at every frame start.  In scatter-gather mode
    // that alone is a second zero-payload path, even with the polarity fixed:
    //   1. desc_accept raises video_busy, so the SGL source CDC FIFO starts
    //      draining its entries into the walker immediately (one per cycle);
    //   2. the frame start is milliseconds later, by which time every entry of
    //      this buffer already sits in the walker and is GONE from the source
    //      FIFO (an entry is popped on the way in);
    //   3. walker_start then resets wr_ptr/rd_ptr/count
    //      (rtl/sg_segment_walker.v:83-86), discarding exactly those entries,
    //      and nothing upstream is left to re-send them;
    //   4. seg_valid stays 0 => pl_seg_ready 0 => burst_start never fires =>
    //      again Payload 0 B, for a completely different reason than §5.1.
    // The legacy engine that does stream restarts the walker on the descriptor,
    // not on the frame: rtl/nv12_capture_engine.v:170 `.start(descriptor_accept)`.
    // One thin descriptor IS one frame buffer, so that is also the only
    // semantics that can work at all: a buffer's SGL entries are delivered once.
    //
    // It is deferred by one cycle rather than pulsed on the accept edge itself,
    // because frame_base_q (the walker's linear_base_addr) is written by that
    // same accept edge and would otherwise be read as the previous frame's base.
    // sgl_take holds sgl_pop_ready (hence sgl_wr_en) low from the accept until
    // the reset has landed, so the start edge can never collide with a push -
    // a collision would drop one entry (sg_segment_walker takes `start` ahead of
    // the write-pointer update) and punch a hole in the destination address map.
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            walker_start_pend <= 1'b0;
            sgl_take          <= 1'b0;
        end else begin
            // Exactly one cycle of delay, so exactly one walker_start pulse.
            walker_start_pend <= desc_accept && desc_ok;
            if (desc_accept && desc_ok) sgl_take <= 1'b0;  // block pushes now
            else if (walker_start)      sgl_take <= 1'b1;  // open after the reset
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            armed                <= 1'b0;
            locked               <= 1'b0;
            sof_locked           <= 1'b0;
            height_q             <= 16'd0;
            stride_q             <= 16'd0;
            line_bytes_q         <= 16'd0;
            frame_bytes_q        <= 32'd0;
            frame_base_q         <= 64'd0;
            dst_addr             <= 64'd0;
            send_line            <= 16'd0;
            send_offset          <= 16'd0;
            bytes_frame          <= 32'd0;
            data_reg             <= 128'd0;
            beats_left           <= 5'd0;
            req_len_q            <= 16'd0;
            line_end_q           <= 1'b0;
            last_writes_q        <= 1'b0;
            walker_start         <= 1'b0;
            adv_pulse            <= 1'b0;
            adv_bytes            <= 16'd0;
            c2h_req_valid        <= 1'b0;
            c2h_req_addr         <= 64'd0;
            c2h_req_dw_len       <= 11'd0;
            c2h_req_last         <= 1'b1;
            desc_ready           <= 1'b0;
            desc_launched        <= 1'b0;
            video_busy           <= 1'b0;
            video_frame_done     <= 1'b0;
            frame_pts            <= 64'd0;
            protocol_error_count <= 32'd0;
            drop_count           <= 32'd0;
            frames_completed     <= 32'd0;
            align_discard_count  <= 32'd0;
            bytes_committed      <= 32'd0;
            active_line_bytes    <= 16'd0;
            active_stride        <= 16'd0;
            error_sticky         <= 1'b0;
        end else begin
            desc_ready       <= 1'b0;
            if (!desc_valid) desc_launched <= 1'b0;
            video_frame_done <= 1'b0;
            // One descriptor = one walker restart (see the block above the main
            // FSM); it used to be pulsed on the frame start, which in SGL mode
            // threw away the entries the source FIFO had already delivered.
            walker_start     <= walker_start_pend;
            adv_pulse        <= 1'b0;
            if (src_overflow_sticky || src_line_align_sticky) error_sticky <= 1'b1;

            // ---- descriptor launch ----------------------------------------
            if (desc_accept) begin
                desc_ready    <= 1'b1;
                desc_launched <= 1'b1;
                if (desc_ok) begin
                    height_q          <= frame_height;
                    stride_q          <= desc_stride;
                    line_bytes_q      <= desc_line_bytes;
                    frame_bytes_q     <= {16'd0, desc_line_bytes} * {16'd0, frame_height};
                    frame_base_q      <= plane_y_addr;
                    active_line_bytes <= desc_line_bytes;
                    active_stride     <= desc_stride;
                    armed             <= 1'b1;
                    locked            <= 1'b0;
                    sof_locked        <= 1'b0;
                    video_busy        <= 1'b1;
                    bytes_frame       <= 32'd0;
                    state             <= S_ALIGN;      // wait for a real frame start
                end else begin
                    // Reported and still consumed: the host's arm cannot hang.
                    protocol_error_count <= protocol_error_count + 32'd16;
                    error_sticky         <= 1'b1;
                end
            end

            // ---- frame start: re-lock (first time) or settle + re-lock ------
            if (armed && head_is_sof && !sof_locked && !c2h_req_valid &&
                (state == S_ALIGN || state == S_ARM || state == S_DRAIN)) begin
                if (locked && (bytes_frame != frame_bytes_q)) begin
                    drop_count   <= drop_count + 32'd1;
                    error_sticky <= 1'b1;
                    // Defect 3 companion fix (§5.2): an aborted frame owns no
                    // retired buffer, so the channel is no longer busy.  The
                    // guard keeps a descriptor launched in this very cycle from
                    // having its busy flag stolen, which would otherwise strand
                    // the channel with no SGL flow and no way to ever retire.
                    if (!desc_accept) video_busy <= 1'b0;
                end else if (locked && (bytes_frame == frame_bytes_q)) begin
                    frames_completed <= frames_completed + 32'd1;
                    video_frame_done <= 1'b1;
                    // The frame retired: release the busy flag so ch0_status bit0
                    // means "a frame is in flight" instead of "the engine has
                    // ever seen one descriptor".  Before this, video_busy was
                    // only ever set (reset :469, desc_accept :503, no clear), so
                    // CH0_STATUS read running=1 while idle (0x201) and every
                    // drained=/overflow judgement built on it was meaningless.
                    // ch0_owner_busy still releases on pcie_frame_done, so the
                    // launch ABI is unchanged (nv12_capture_engine.v:643/647
                    // has the same retire/abort life cycle).
                    if (!desc_accept) video_busy <= 1'b0;
                end
                locked       <= 1'b1;
                sof_locked   <= 1'b1;   // this head is re-locked; it may now be sent
                dst_addr     <= frame_base_q;
                send_line    <= 16'd0;
                send_offset  <= 16'd0;
                bytes_frame  <= 32'd0;
                frame_pts    <= global_timestamp;
                state        <= S_ARM;
            end

            // ---- alignment / over-run discard ------------------------------
            // Re-arming for the next frame happens the moment the marked head
            // leaves the FIFO, whichever path took it out.
            if (p_axis_tready && head_is_sof) sof_locked <= 1'b0;

            if (pop_discard) begin
                if (state == S_ALIGN)
                    align_discard_count <= align_discard_count + 32'd16;
                else begin
                    // past the end of the written frame: never stored
                    protocol_error_count <= protocol_error_count + 32'd16;
                    error_sticky         <= 1'b1;
                end
            end

            // ---- commit a burst --------------------------------------------
            if (burst_start) begin
                data_reg      <= p_axis_tdata;                 // pop beat 0
                beats_left    <= pl_beats - 5'd1;
                req_len_q     <= pl_bytes;
                line_end_q    <= pl_line_end;
                last_writes_q <= pl_last_write;
                c2h_req_addr  <= pl_addr;                      // == target_addr, see pl_valid
                c2h_req_dw_len<= {6'd0, pl_bytes[15:2]};       // bytes/4 DWords
                c2h_req_last  <= 1'b1;
                c2h_req_valid <= 1'b1;
                state         <= S_REQ;
            end

            // ---- stream the remaining beats --------------------------------
            if (pop_stream)
                data_reg <= p_axis_tdata;                      // pop next beat
            if (consuming && (beats_left != 5'd0))
                beats_left <= beats_left - 5'd1;

            if (c2h_req_valid && c2h_req_ack) begin
                c2h_req_valid   <= 1'b0;
                bytes_committed <= bytes_committed + {16'd0, req_len_q};
                bytes_frame     <= bytes_frame + {16'd0, req_len_q};
                adv_pulse       <= 1'b1;
                adv_bytes       <= req_len_q + (line_end_q ? pad_bytes : 16'd0);
                if (line_end_q) begin
                    send_offset <= 16'd0;
                    send_line   <= send_line + 16'd1;
                    dst_addr    <= dst_addr + {16'd0, req_len_q} + {16'd0, pad_bytes};
                end else begin
                    send_offset <= send_offset + req_len_q;
                    dst_addr    <= dst_addr + {16'd0, req_len_q};
                end
                state <= last_writes_q ? S_DRAIN : S_ARM;
            end

            if (!armed && (state != S_IDLE)) state <= S_IDLE;
        end
    end

    // ------------------------------------------------------------------------
    // Diagnosis bundle (BAR0 GLOBAL 0x0E0, see
    // docs/sc7f0_defect3_c2h_zero_payload_rootcause_20261116.md §5.3).
    //
    //   [6:0]   walker SGL entries held      (u_sgl.fifo_count)
    //   [7]     walker SGL FIFO empty
    //   [8]     pl_seg_ready                  (registered s_seg_ready)
    //   [9]     seg_valid                     (walker has an active segment)
    //   [12:10] engine state
    //   [15:13] pl_state  (the state the burst plan was sampled in)
    //   [16]    pl_valid  (that plan still describes the live counters)
    //   [17]    armed
    //   [18]    locked
    //   [19]    sof_locked
    //   [24:20] pl_beats
    //   [25]    have_all   (source FIFO really holds pl_beats)
    //   [26]    burst_start
    //   [27]    video_busy
    //   [31:28] 0
    //
    // Read before the fix and during a stalled capture this was
    // {entries=0, empty=1, seg_valid=0, pl_seg_ready=0, state=2}; after it the
    // same read shows entries>0, seg_valid=1, pl_seg_ready=1 and state cycling
    // 2 -> 3 -> 2 while payload commits.
    // ------------------------------------------------------------------------
    assign dbg_bus = {4'd0, video_busy, burst_start, have_all, pl_beats,
                      sof_locked, locked, armed, pl_valid, pl_state, state,
                      seg_valid, pl_seg_ready, walker_sgl_empty, cur_sgl_count};
endmodule
`default_nettype wire
