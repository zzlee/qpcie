`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_alpha_blend_2ppc  (personality SC7F0-RGB-COMPOSITOR-2PPC)
//
// Two independent 2 pixel/clock RGBA8888 AXI-Stream planes are composited into
// one 2 pixel/clock RGB888 stream at 300 MHz:
//
//   plane B (base)    : PS DDR -> v_frmbuf_rd Reader-A -> s_b_axis_*
//   plane O (overlay) : host RGBA -> PCIe H2C -> PS DDR slot -> v_frmbuf_rd
//                       Reader-B                          -> s_o_axis_*
//   out               : HDMI TX VIDEO_IN (UG934 native RGB), 2 PPC = 48 bit
//
// The planes come from two SEPARATE v_frmbuf_rd IP instances; one reader is
// never reused as two planes.
//
// Pixel word layout (UG934; the RX side decodes the same native order, see
// rtl/hdmi_rx_pixel_pack.v which takes R=[23:16], B=[15:8], G=[7:0]):
//   RGBA stream pixel : [31:24] A, [23:16] R, [15:8] B, [7:0] G
//   RGB  stream pixel : [23:16] R, [15:8]  B, [7:0]  G
// Host memory for both planes is ordinary little-endian RGBA8888 (ascending
// bytes R,G,B,A); v_frmbuf_rd performs the memory -> stream remap, so no extra
// byte-swap stage is inserted here.
//
// Compositing maths - straight (not premultiplied) 8-bit alpha, "over":
//
//     out = BG + round( A * (FG - BG) / 255 )
//
// evaluated as
//
//     d    = FG - BG                       signed, -255..255
//     p    = A * d                         |p| <= 65025, one DSP48 (8 x 10)
//     out  = BG + round(p / 255)           EXACT round-to-nearest
//
// round(p/255) is computed in the 2^16 domain as  floor((257*p + C)/65536) with
// a SIGN-SELECTED bias (dual constants, quant_round255 below):
//
//     C = Cpos = 32896          for p >= 0
//     C = Cneg = 32639          for p <  0     (= 65535 - Cpos)
//
// Why two constants and not one.  Write p = 255q + r with 0 <= r < 255; then
// 257p = 65535q + 257r, so floor((257p + C)/65536) = q + [257r + C >= 65536].
// The positive case therefore needs 255 <= C <= 32896 (upper bound tight at
// r = 127, where 257r = 32639), and - reflecting through the arithmetic shift,
// which is a floor - the negative case needs 32639 <= C <= 32641.  The two
// windows are disjoint, so NO single constant can be exact on both sides: the
// historical +32767 was one LSB wrong on both.  Witnesses:
//   A=253 BG=0   FG=191 -> p=+48323: old ((257p+32767)>>>16) = 189, exact = 190
//   A=253 BG=191 FG=0   -> p=-48323: old ((257p+32767)>>>16) = 2,   exact = 1
// With Cpos = 32896 / Cneg = 32639 = 65535 - Cpos the identity
//   floor((-257a + Cneg)/65536) = -floor((257a + Cpos)/65536)
// holds for every a, so the negative half is the exact mirror of the positive
// half.  Endpoints are exact:
//   A=0   -> out = BG           (overlay fully transparent)
//   A=255 -> out = BG + d = FG  (overlay opaque)
//   A=128, BG=0, FG=255 -> round(32640/255) = 128
// With A <= 255 the result provably lies in [0,255] (d>=0: BG+A*d/255 <= FG;
// d<0: BG+A*d/255 >= FG), so no clamp is inserted - but the range is *checked*
// on every component of every beat and any residue outside [0,255] is counted in
// sat_watchdog_count, so a maths regression cannot hide behind a truncated slice.
//
// Pipeline at 300 MHz (PPC = 2 => 6 multiplies per beat, 6 DSP48)
//   stage 0: d = FG-BG per component, the base component, the per-pixel alpha
//            and ONE sample of blend_enable / alpha_force_opaque, registered.
//            Everything is sampled from the queue heads on the front-stage
//            `consume` handshake, so a mode toggle is applied to the beat it
//            was presented with, never retro-applied at a later stage;
//   stage 1: p = A*d (the registered stage-0 values only), plus the matching
//            base component and the sof/eol sidebands, registered - the
//            multiplier result and its background travel together, so a stall
//            cannot pair a new product with an old background;
//   stage 2: 257*p + C(sign) (shift + add, no second multiplier), >>>16, +BG,
//            registered into the output AXI-Stream registers.
//   The three stages form an ELASTIC chain, not a shift register: consume is
//   allowed only when stage 0 can be loaded, which requires stage 0's own
//   content to move into stage 1, which requires stage 1's content to move into
//   stage 2, which requires the output register to be free.  A downstream stall
//   therefore propagates back to both readers instead of dropping a beat, and a
//   same-cycle forward-move plus reload is legal, so steady state stays at one
//   pixel pair per cycle (II = 1).  One extra pipeline cycle of output latency
//   is the only cost; ordering, metadata, formats and geometry are unchanged.
//   Lock / drain / purge accounting (and lock_lost_count) stay on the FRONT
//   consume handshake, not on the delayed product.
//
// Frame lock: HARDWARE SOF GENLOCK (GL_SEEK_OVL / GL_WAIT_VSOF / GL_LOCKED)
//   Both planes must present TUSER (frame start) on the SAME beat.  Nothing is
//   ever composited before that coincidence, because a foreground beat paired
//   with a background beat from anywhere else in the frame lays one overlay line
//   across two background scan lines: horizontal tearing whose offset changes on
//   every restart.  This is the failure recorded as 坑 16 of
//   ~/docker/sc6f0-sdi-alphablending/docs/DEVELOPMENT_PITFALLS_AND_LESSONS.md,
//   whose three-state machine this implements (same state names, same lock
//   condition, same overlay-side drain), adapted to this compositor's per-plane
//   input queues and elastic pipeline instead of a direct stream join:
//
//     GL_SEEK_OVL   the overlay plane is not synchronised.  Every overlay beat
//                   that is not a frame start is discarded, one per cycle, so the
//                   overlay reader can never fill the queue and stall behind
//                   pixels of an old frame.  A beat that IS a frame start is left
//                   at the head of the queue, un popped.
//     GL_WAIT_VSOF  the overlay sits held at its frame start.  The BACKGROUND
//                   plane keeps flowing - see the rule below - until the cycle on
//                   which it presents its own frame start.
//     GL_LOCKED     the two frame starts coincided on one beat and that beat was
//                   blended; from here the pair is consumed beat for beat.  A
//                   consumed pair whose sideband disagrees (one plane starts or
//                   ends a line without the other) is discarded and unlocks; so
//                   does the overlay starving for OVERLAY_STARVE_LIMIT cycles,
//                   because plane B dying mid-frame must not be able to hold
//                   plane A - and therefore the TX - forever.
//
//   The rule that makes this safe for the display, and the reason the previous
//   revision was wrong: **while the compositor is not locked, plane A is never
//   back-pressured and never discarded.**  The earlier machine held a plane-A
//   frame start at the head of its queue while it waited for the overlay, so the
//   16-deep queue filled in 16 beats, Reader-A's AXI-Stream stalled, and the base
//   plane underran - i.e. exactly the TX starvation 坑 16 warns about, caused by
//   the code that was meant to prevent it.  Here every un locked background beat
//   is *forwarded* instead: it enters the pipeline with the blend folded off
//   (en0 = 0 => product 0 => out = background, bit-exact), so the stream in front
//   of the TX CDC keeps its pixels, its line ends and its frame starts, and the
//   only thing withheld while seeking is compositing.  Plane A is then
//   back-pressured only by the pipeline itself (stage0_full), exactly as the
//   reference design back-pressures it with ~pipe_en, and 16 beats of queue sit
//   in front of that.
//
//   `unlock` (rtl/sc7f0_rgb_overlay_ctrl.v COMP_CTRL[2], crossed by its own
//   xpm_cdc_single) forces GL_SEEK_OVL and discards everything the overlay was
//   holding, including a pending frame start, so a re-lock can never inherit
//   pixels from the old frame.  It never purges plane A either.
// ============================================================================

module sc7f0_alpha_blend_2ppc #(
    parameter integer PPC         = 2,
    parameter integer QUEUE_DEPTH = 16,           // per plane, power of two
    // Consecutive cycles in GL_LOCKED during which plane A has a beat and the
    // overlay has none, before the compositor gives the frame up and returns to
    // GL_SEEK_OVL.  A 4K60 line is 1920 beats at 2 PPC, so 1024 cycles is about
    // half a line: far beyond any legitimate DDR burst latency in front of a
    // 300 MHz reader, and still fast enough that the recovery re-locks inside
    // the next frame instead of strobing.
    parameter integer OVERLAY_STARVE_LIMIT = 1024
)(
    input  wire                 clk,               // 300 MHz pipeline clock
    input  wire                 rst_n,

    input wire [31:0]           ovl_cookie,
    output reg [31:0]           out_cookie,
    input  wire                 blend_enable,      // 0 = base plane passthrough
    input  wire                 alpha_force_opaque,// drive A to 255 (bring-up aid)
    input  wire                 unlock,            // re-acquire the frame lock

    // plane B: base framebuffer, RGBA8888, PPC pixels per beat
    input  wire  [PPC*32-1:0]   s_b_axis_tdata,
    input  wire                 s_b_axis_tvalid,
    output wire                 s_b_axis_tready,
    input  wire                 s_b_axis_tlast,    // end of line
    input  wire                 s_b_axis_tuser,    // start of frame

    // plane O: overlay plane, same geometry
    input  wire  [PPC*32-1:0]   s_o_axis_tdata,
    input  wire                 s_o_axis_tvalid,
    output wire                 s_o_axis_tready,
    input  wire                 s_o_axis_tlast,
    input  wire                 s_o_axis_tuser,

    // composited RGB, UG934 native order, PPC pixels per beat
    output reg   [PPC*24-1:0]   m_axis_tdata,
    output reg                  m_axis_tvalid,
    input  wire                 m_axis_tready,
    output reg                  m_axis_tlast,
    output reg                  m_axis_tuser,

    // status levels, this clock domain
    // `locked` is GL_LOCKED and nothing else: it is the host-visible STATUS[9]
    // (rtl/sc7f0_rgb_overlay_ctrl.v COMP STATUS bit 9), so it must mean exactly
    // "the two planes are genlocked and beats are being composited".
    output wire                 locked,
    // Full genlock state, for the host: 0 GL_SEEK_OVL, 1 GL_WAIT_VSOF, 2
    // GL_LOCKED.  Distinguishing "waiting for the overlay to start at all" from
    // "waiting for the background frame start" is what makes an on-card OSD
    // offset reportable instead of guessable.
    output wire [1:0]           gl_state,
    // Why the lock was last lost: 0 none/first lock, 1 sideband mismatch, 2
    // overlay starved mid-frame, 3 explicit COMP_CTRL blend_unlock.
    output reg  [2:0]           gl_drop_reason,
    output reg  [31:0]          gl_lock_count,
    // Purely combinational: it must cover ALL THREE stages, and a registered OR
    // of the stage-valids lags the first token by a cycle (and drops the last
    // one), which is a host-visible STATUS[10] defect.  Direction, width and
    // name are unchanged; only the reg->wire kind is.
    output wire                 pipeline_busy,
    output reg  [31:0]          lock_lost_count,
    output reg  [31:0]          sat_watchdog_count,
    output reg  [31:0]          beats_blended,
    // Beats that left the compositor as un-blended background passthrough, i.e.
    // everything emitted while not genlocked.  Non-zero while the overlay plane
    // is intentionally off is normal; growing while the overlay is armed means the
    // two planes never coincided.
    output reg  [31:0]          base_passthru_beats
);
    localparam integer QB    = PPC*32 + 2;         // {tuser, tlast, data}
    localparam integer NCOMP = PPC*3;              // components per beat
    localparam integer PW    = NCOMP*18;           // packed signed products
    localparam integer BW    = NCOMP*8;            // packed base components

    // ------------------------------------------------------------------------
    // input queues, one per plane
    // ------------------------------------------------------------------------
    wire [QB-1:0] b_head;
    wire [QB+31:0] o_head;
    reg [31:0] cookie0, cookie1;
    wire          b_empty, o_empty, b_full, o_full;
    // Forward declarations: the pop side is driven from the frame-lock block
    // below (blend pop, re-alignment purge and re-lock drain).
    wire          consume, b_pop, o_pop;

    sc7f0_dp_sync_fifo #(.WIDTH(QB), .DEPTH(QUEUE_DEPTH)) u_bq (
        .clk(clk), .rst_n(rst_n),
        .din({s_b_axis_tuser, s_b_axis_tlast, s_b_axis_tdata}),
        .push(s_b_axis_tvalid && !b_full),
        .full(b_full),
        .dout(b_head), .pop(b_pop), .empty(b_empty), .count());
    sc7f0_dp_sync_fifo #(.WIDTH(QB+32), .DEPTH(QUEUE_DEPTH)) u_oq (
        .clk(clk), .rst_n(rst_n),
        .din({ovl_cookie,s_o_axis_tuser, s_o_axis_tlast, s_o_axis_tdata}),
        .push(s_o_axis_tvalid && !o_full),
        .full(o_full),
        .dout(o_head), .pop(o_pop), .empty(o_empty), .count());

    assign s_b_axis_tready = !b_full;
    assign s_o_axis_tready = !o_full;

    wire b_valid = !b_empty;
    wire o_valid = !o_empty;
    wire b_sof   = b_head[QB-1];
    wire b_eol   = b_head[QB-2];
    wire o_sof   = o_head[QB-1];
    wire o_eol   = o_head[QB-2];

    // ------------------------------------------------------------------------
    // frame lock / re-acquisition  (the state machine itself sits below, after
    // the pipeline's own stage-free conditions, because locking is only allowed
    // on a beat the front stage can actually take)
    // ------------------------------------------------------------------------
    wire       both_valid = b_valid && o_valid;
    wire       pair_sof   = both_valid && b_sof && o_sof;
    // A consumed pair is only compositable when the two planes agree about where
    // they are: same frame start, same line end.  TLAST is end-of-LINE, not
    // end-of-frame, so a matched TLAST pair keeps the lock (the first revision
    // dropped the lock on every matched TLAST, which is why a multi-line frame
    // stopped being composited after its first line).
    wire       pair_ok    = (b_sof == o_sof) && (b_eol == o_eol);

    // ---- stage 0 payload (registered at the front consume handshake) --------
    localparam integer DW0 = NCOMP*10;         // packed signed d = FG-BG
    localparam integer AW0 = NCOMP*8;          // packed captured alpha (per px)

    reg               stage0_valid;
    reg               pthru0_r;                   // this stage-0 beat is passthrough
    reg               pthru1_r;
    reg  [DW0-1:0]    d0_r;                    // PPC*3 signed 10-bit FG-BG
    reg  [BW-1:0]     bg0_r;                   // PPC*3 base components
    reg  [AW0-1:0]    a0_r;                    // PPC captured 8-bit alpha
    reg               en0_r;                   // captured blend_enable
    reg               stage0_sof, stage0_eol;

    reg               stage1_valid;
    reg  [PW-1:0]     prod_r;                 // PPC*3 signed 18-bit A*d
    reg  [BW-1:0]     bg_r;                   // PPC*3 base components
    reg               stage1_sof, stage1_eol;
    reg               out_sat;
    wire              out_free    = !m_axis_tvalid || m_axis_tready;
    wire              stage1_free = !stage1_valid || out_free;
    wire              stage0_free = !stage0_valid  || stage1_free;

    // ------------------------------------------------------------------------
    // SOF genlock state machine
    // ------------------------------------------------------------------------
    localparam [1:0] GL_SEEK_OVL  = 2'd0;   // overlay not synchronised
    localparam [1:0] GL_WAIT_VSOF = 2'd1;   // overlay held at its frame start
    localparam [1:0] GL_LOCKED    = 2'd2;   // both frame starts coincided

    reg  [1:0] gl_state_q;
    assign gl_state = gl_state_q;
    assign locked   = (gl_state_q == GL_LOCKED);
    wire   is_locked = (gl_state_q == GL_LOCKED);

    // Locking, like compositing, is only allowed on a beat the front stage can
    // take this same cycle; a coincidence while the chain is full simply waits,
    // with neither plane popped, so no beat can be lost by waiting.
    wire pair_ready  = both_valid && stage0_free;
    wire lock_fire   = pair_sof && pair_ready && !is_locked;
    // A pair is popped together when we are locked, or on the locking beat.
    wire paired      = (is_locked || lock_fire) && pair_ready;
    wire paired_ok   = paired && pair_ok;      // composited
    wire pair_bad    = paired && !pair_ok;     // popped, discarded, unlocks

    // The background plane's independent path: while not genlocked, every plane-A
    // beat is forwarded as an un-blended passthrough beat.  It is never discarded
    // and never held back by the overlay, which is the whole point of the
    // state machine (see the header).  `lock_fire` excludes the coincidence beat
    // from the passthrough path because that beat goes out blended instead.
    wire base_only   = ((!is_locked && !lock_fire) && b_valid && stage0_free) || pair_bad;

    // Overlay side: stale beats are drained while seeking, a frame start is held
    // un-popped until the background's own frame start arrives.
    wire ovl_at_sof  = o_valid && o_sof;
    wire ovl_drain   = (gl_state_q == GL_SEEK_OVL) && o_valid && !o_sof;

    assign consume   = paired_ok;
    assign b_pop     = paired || base_only;
    assign o_pop     = paired || ovl_drain;

    // Mid-frame overlay starvation guard: plane B may be stopped, reset or simply
    // never armed, and plane A must not be held hostage by it.  Counting only
    // cycles in which the front stage was ready to take a pair and the overlay had
    // nothing means a legitimate DDR burst never feeds the counter.
    wire  ovl_starve = is_locked && b_valid && !o_valid && stage0_free;
    reg  [15:0] ovl_starve_cnt;
    wire  ovl_giveup = ovl_starve && (ovl_starve_cnt >= OVERLAY_STARVE_LIMIT-1);

    // Observability.  purge_o_count counts overlay beats thrown away while the
    // compositor was not synchronised (normal during seek).  base_stall_cycles
    // counts cycles in which plane A had a beat the pipeline could not take: the
    // ONLY reason plane A is ever back-pressured here, and the number to look at
    // before blaming the genlock for a base-plane underrun.
    reg [31:0] purge_o_count;
    reg [31:0] base_stall_cycles;


    // ------------------------------------------------------------------------
    // pipeline tokens
    // ------------------------------------------------------------------------

    // ------------------------------------------------------------------------
    // stage 1 combinational: d and A*d per component
    // ------------------------------------------------------------------------
    wire [PPC*32-1:0] b_data = b_head[PPC*32-1:0];
    wire [PPC*32-1:0] o_data = o_head[PPC*32-1:0];
    wire [DW0-1:0]    d0_w;
    wire [BW-1:0]     bg0_w;
    wire [AW0-1:0]    a0_w;
    wire [PW-1:0]     prod_w;

    genvar g;
    generate
        // ---- stage 0 combinational: the difference, the base, the alpha ----
        // All of it is sampled on the front `consume` edge, which is the same
        // point in time as the old input handshake, so blend_enable and
        // alpha_force_opaque are captured with the beat they belong to.
        for (g = 0; g < NCOMP; g = g + 1) begin : g_stage0
            // component c of pixel p sits at bit p*32 + 23 - 8*c (R,B,G order)
            wire [7:0] fgi  = o_data[(g/3)*32 + (23-8*(g%3)) -: 8];
            wire [7:0] bgi  = b_data[(g/3)*32 + (23-8*(g%3)) -: 8];
            wire signed [9:0] d_s = $signed({2'b00, fgi}) - $signed({2'b00, bgi});
            assign d0_w [g*10 +: 10] = d_s;
            assign bg0_w[g*8  +: 8 ] = bgi;      // base is always the backdrop
        end
        for (g = 0; g < PPC; g = g + 1) begin : g_stage0a
            // the alpha byte of pixel g, with the force-opaque aid folded in
            assign a0_w[g*8 +: 8] = alpha_force_opaque ? 8'hFF
                                                       : o_data[g*32 + 31 -: 8];
        end
        // ---- stage 1 combinational: p = A*d, from stage 0 registers only ----
        // The registered mode bit, never the live input, selects the path.
        for (g = 0; g < NCOMP; g = g + 1) begin : g_stage1
            wire signed [17:0] p_s =
                en0_r ? ($signed({1'b0, a0_r[(g/3)*8 +: 8]}) *
                         $signed(d0_r[g*10 +: 10]))
                      : 18'sd0;
            assign prod_w[g*18 +: 18] = p_s;
        end
    endgenerate

    // ------------------------------------------------------------------------
    // exact round-to-nearest of p/255, |p| <= 65025, as floor((257p + C)/65536)
    // with C = 32896 for p >= 0 and C = 32639 = 65535 - 32896 for p < 0.
    //
    // 257*p = (p <<< 8) + p.  Adding (p <<< 1) instead - as the first revision
    // did - evaluates 258*p, which is up to one LSB high.  26 bits is enough for
    // the whole range: |257*p| + 32896 <= 16,744,321 < 2**25.
    //
    // It is a function (not a port, not an external module) so the unit test can
    // exercise THIS production code over the entire signed domain; synthesis
    // inlines it per component exactly as the previous flat expression did.
    // ------------------------------------------------------------------------
    localparam signed [25:0] QUANT_CPOS = 26'sd32896;
    localparam signed [25:0] QUANT_CNEG = 26'sd32639;   // 65535 - QUANT_CPOS

    function signed [11:0] quant_round255;
        input signed [17:0] p;
        reg signed [25:0] p25;
        reg signed [25:0] scaled;
        begin
            p25    = {{8{p[17]}}, p};                     // widen first
            scaled = (p25 <<< 8) + p25 +
                     (p[17] ? QUANT_CNEG : QUANT_CPOS);   // sign-selected bias
            quant_round255 = scaled >>> 16;               // arithmetic = floor
        end
    endfunction

    // ------------------------------------------------------------------------
    // stage 2 combinational: 257*p + C(sign) >>> 16 + BG
    //
    // Stage 1 packs component g at storage index g (a flat 0..NCOMP-1 vector),
    // but the *output* word is a pixel-structured AXI-Stream word: component c of
    // pixel p belongs to m_axis_tdata[p*24 + 23 - 8*c].  Writing it at blend_w[g*8]
    // reversed every pixel (the first revision emitted {G,B,R} per pixel, so an
    // A=0 passthrough of R=0x20,B=0x40,G=0x60 came out as R=0x60,B=0x40,G=0x20).
    // ------------------------------------------------------------------------
    wire [PPC*24-1:0] blend_w;
    wire [NCOMP-1:0]  sat_w;
    generate
        for (g = 0; g < NCOMP; g = g + 1) begin : g_stage2
            wire signed [17:0] p       = $signed(prod_r[g*18 +: 18]);
            wire signed [11:0] rounded = quant_round255(p);        // -257..256
            wire signed [11:0] total   = rounded + $signed({4'd0, bg_r[g*8 +: 8]});
            assign blend_w[(g/3)*24 + (23-8*(g%3)) -: 8] = total[7:0];
            assign sat_w[g] = (total < 12'sd0) || (total > 12'sd255);
        end
    endgenerate

    // ------------------------------------------------------------------------
    // sequential
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage0_valid <= 1'b0;
            d0_r         <= {DW0{1'b0}};
            bg0_r        <= {BW{1'b0}};
            a0_r         <= {AW0{1'b0}};
            en0_r        <= 1'b0;
            stage0_sof   <= 1'b0;
            stage0_eol   <= 1'b0;
            stage1_valid <= 1'b0;
            prod_r       <= {PW{1'b0}};
            bg_r         <= {BW{1'b0}};
            stage1_sof   <= 1'b0;
            stage1_eol   <= 1'b0;
            out_sat      <= 1'b0;
            pthru0_r     <= 1'b0;
            pthru1_r     <= 1'b0;
            m_axis_tdata <= {PPC*24{1'b0}};
            m_axis_tvalid<= 1'b0;
            m_axis_tlast <= 1'b0;
            m_axis_tuser <= 1'b0;
            gl_state_q       <= GL_SEEK_OVL;
            gl_drop_reason   <= 3'd0;
            gl_lock_count    <= 32'd0;
            lock_lost_count  <= 32'd0;
            sat_watchdog_count <= 32'd0;
            beats_blended    <= 32'd0;
            base_passthru_beats <= 32'd0;
            ovl_starve_cnt   <= 16'd0;
            purge_o_count    <= 32'd0;
            base_stall_cycles<= 32'd0;
        end else begin
            // ---- stage 0 load -------------------------------------------------
            // Two kinds of beat enter the pipeline:
            //   paired_ok  both planes popped, this beat is composited;
            //   base_only  plane A alone while the compositor is not genlocked,
            //              emitted un-blended (en0_r = 0 => product 0 => out = BG,
            //              bit-exact, and sat_w cannot fire on it).
            // A pair whose sideband disagrees is popped and thrown away, never
            // blended: compositing pixel N of one plane over pixel N of a plane
            // that is somewhere else in the frame is exactly the corruption the
            // frame lock exists to prevent.
            // Load-before-clear: when this stage is simultaneously drained and
            // reloaded the load branch wins, which is the legal same-cycle
            // forward-move + reload case of the elastic chain.
            if (paired_ok || base_only) begin
                d0_r          <= d0_w;
                bg0_r         <= bg0_w;
                a0_r          <= a0_w;
                en0_r         <= blend_enable && paired_ok;
                pthru0_r      <= base_only;
                cookie0       <= blend_enable && paired_ok ? o_head[QB+:32] : 0;
                stage0_sof    <= b_sof;
                stage0_eol    <= b_eol;
                stage0_valid  <= 1'b1;
            end else if (stage0_valid && stage1_free) begin
                stage0_valid  <= 1'b0;
            end

            // ---- stage 1 load (from stage 0 registers only) ------------------
            if (stage0_valid && stage1_free) begin
                prod_r       <= prod_w;
                bg_r         <= bg0_r;
                cookie1      <= cookie0;
                stage1_sof   <= stage0_sof;
                stage1_eol   <= stage0_eol;
                pthru1_r     <= pthru0_r;
                stage1_valid <= 1'b1;
            end else if (stage1_valid && out_free) begin
                stage1_valid <= 1'b0;
            end

            // ---- stage 2 / output register ---------------------------------
            if (stage1_valid && out_free) begin
                m_axis_tdata  <= blend_w;
                out_cookie    <= cookie1;
                m_axis_tuser  <= stage1_sof;
                m_axis_tlast  <= stage1_eol;
                m_axis_tvalid <= 1'b1;
                out_sat       <= |sat_w;
                if (pthru1_r) base_passthru_beats <= base_passthru_beats + 32'd1;
                else          beats_blended       <= beats_blended + 32'd1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end

            if (out_sat) sat_watchdog_count <= sat_watchdog_count + 32'd1;
            if (o_pop && !paired) purge_o_count <= purge_o_count + 32'd1;
            if (b_valid && !stage0_free) base_stall_cycles <= base_stall_cycles + 32'd1;

            // ---- overlay mid-frame starvation watchdog ----------------------
            if (!is_locked || ovl_giveup)      ovl_starve_cnt <= 16'd0;
            else if (ovl_starve)               ovl_starve_cnt <= ovl_starve_cnt + 16'd1;
            else                               ovl_starve_cnt <= 16'd0;

            // ---- SOF genlock state machine ----------------------------------
            // `unlock` (COMP_CTRL[2], held as a level by software) parks the
            // compositor in GL_SEEK_OVL: plane A keeps passing through, the
            // overlay queue is drained, and no lock can be taken while the bit
            // stays set.  It never discards a background beat.
            if (unlock) begin
                gl_state_q     <= GL_SEEK_OVL;
                gl_drop_reason <= 3'd3;
            end else case (gl_state_q)
                // Seeking: drop overlay beats until one is a frame start, and
                // lock immediately if the background is at its frame start too
                // (the coincidence-on-arrival case).
                GL_SEEK_OVL: begin
                    if (lock_fire) begin
                        gl_state_q     <= GL_LOCKED;
                        gl_lock_count  <= gl_lock_count + 32'd1;
                        gl_drop_reason <= 3'd0;
                    end else if (ovl_at_sof)
                        gl_state_q     <= GL_WAIT_VSOF;
                end
                // The overlay is held at pixel 0 of its frame; the background is
                // free-running and locks the compositor on its own next frame
                // start.  If the overlay stops presenting beats at all (reader
                // reset, plane never armed) fall back and seek again.
                GL_WAIT_VSOF: begin
                    if (lock_fire) begin
                        gl_state_q     <= GL_LOCKED;
                        gl_lock_count  <= gl_lock_count + 32'd1;
                        gl_drop_reason <= 3'd0;
                    end else if (!o_valid) begin
                        gl_state_q     <= GL_SEEK_OVL;
                        gl_drop_reason <= 3'd2;
                    end
                end
                // Locked.  TLAST is end of LINE, so a matched TLAST pair keeps the
                // lock; only a sideband mismatch or a starved overlay gives it up,
                // and both fall back to seeking rather than holding plane A.
                GL_LOCKED: begin
                    if (pair_bad) begin
                        gl_state_q      <= GL_SEEK_OVL;
                        gl_drop_reason  <= 3'd1;
                        lock_lost_count <= lock_lost_count + 32'd1;
                    end else if (ovl_giveup) begin
                        gl_state_q      <= GL_SEEK_OVL;
                        gl_drop_reason  <= 3'd2;
                        lock_lost_count <= lock_lost_count + 32'd1;
                    end
                end
                default: gl_state_q <= GL_SEEK_OVL;
            endcase
        end
    end

    // Host-visible STATUS[10]: every token that is still in the compositor, in
    // whichever of the three stages it sits, keeps this asserted.
    assign pipeline_busy = stage0_valid || stage1_valid || m_axis_tvalid;
endmodule
`default_nettype wire
