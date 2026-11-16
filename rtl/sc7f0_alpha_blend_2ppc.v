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
// Frame lock
//   Both planes must present TUSER (frame start) on the same beat.  Nothing is
//   emitted before that coincidence.  TLAST is end-of-LINE, not end-of-frame, so
//   a matched TLAST pair keeps the lock (the first revision dropped the lock on
//   every matched TLAST, which is why a multi-line frame stopped being composited
//   after its first line).  A consumed pair whose sideband disagrees (one plane
//   starts or ends a line without the other) is discarded, unlocks the compositor
//   and is counted in lock_lost_count; the pair re-acquires at the next
//   simultaneous frame start.
//
//   While unlocked the compositor must not composite stale pixels, and it must
//   not deadlock either: refusing every beat simply fills both 16-deep queues,
//   back-pressures the two readers and the whole display pipeline stalls with
//   TUSER never reaching the head of the queue.  Therefore, while unlocked, every
//   beat that is *not* a frame start is discarded (one per cycle), and a frame
//   start is held at the head of its queue until its counterpart arrives.
//
//   `unlock` (the CSR re-lock, rtl/sc7f0_rgb_compositor.v blends it through
//   xpm_cdc_single) additionally discards everything held, including a pending
//   frame start, and keeps discarding until both planes present a simultaneous
//   frame start again - so a re-lock can never inherit pixels from the old frame.
// ============================================================================

module sc7f0_alpha_blend_2ppc #(
    parameter integer PPC         = 2,
    parameter integer QUEUE_DEPTH = 16            // per plane, power of two
)(
    input  wire                 clk,               // 300 MHz pipeline clock
    input  wire                 rst_n,

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
    output reg                  locked,
    // Purely combinational: it must cover ALL THREE stages, and a registered OR
    // of the stage-valids lags the first token by a cycle (and drops the last
    // one), which is a host-visible STATUS[10] defect.  Direction, width and
    // name are unchanged; only the reg->wire kind is.
    output wire                 pipeline_busy,
    output reg  [31:0]          lock_lost_count,
    output reg  [31:0]          sat_watchdog_count,
    output reg  [31:0]          beats_blended
);
    localparam integer QB    = PPC*32 + 2;         // {tuser, tlast, data}
    localparam integer NCOMP = PPC*3;              // components per beat
    localparam integer PW    = NCOMP*18;           // packed signed products
    localparam integer BW    = NCOMP*8;            // packed base components

    // ------------------------------------------------------------------------
    // input queues, one per plane
    // ------------------------------------------------------------------------
    wire [QB-1:0] b_head, o_head;
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
    sc7f0_dp_sync_fifo #(.WIDTH(QB), .DEPTH(QUEUE_DEPTH)) u_oq (
        .clk(clk), .rst_n(rst_n),
        .din({s_o_axis_tuser, s_o_axis_tlast, s_o_axis_tdata}),
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
    // frame lock / re-acquisition
    // ------------------------------------------------------------------------
    reg        drain_req;                 // `unlock` is still being honoured
    wire       both_valid = b_valid && o_valid;
    wire       pair_sof   = both_valid && b_sof && o_sof;
    // A consumed pair is only compositable when the two planes agree about where
    // they are: same frame start, same line end.
    wire       pair_ok    = (b_sof == o_sof) && (b_eol == o_eol);

    // ---- stage 0 payload (registered at the front consume handshake) --------
    localparam integer DW0 = NCOMP*10;         // packed signed d = FG-BG
    localparam integer AW0 = NCOMP*8;          // packed captured alpha (per px)

    reg               stage0_valid;
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

    // Re-acquisition drains *everything* (including a pending frame start) until
    // the beat where both planes start together, which then becomes the first
    // blended beat of the new frame.  Draining at one beat per cycle can never
    // fall behind a source that produces at most one beat per cycle, so this
    // cannot deadlock the readers.
    wire drain_now = unlock || (drain_req && !pair_sof);

    // The front stage may only take a pair when its own content can leave this
    // same cycle (or it is already empty): the chain never overwrites a token.
    assign consume = both_valid && stage0_free && !drain_now &&
                     (locked || pair_sof);
    // While simply unlocked (no re-lock requested) a beat that is not a frame
    // start can never be composited, so it is discarded; a frame start is left at
    // the head of its queue waiting for its counterpart.
    wire b_purge = !locked && !drain_now && b_valid && !b_sof && !consume;
    wire o_purge = !locked && !drain_now && o_valid && !o_sof && !consume;
    assign b_pop   = drain_now ? b_valid : (consume || b_purge);
    assign o_pop   = drain_now ? o_valid : (consume || o_purge);

    // Discarded-beat counters: observability only, deliberately not ports (the
    // wrapper rtl/sc7f0_rgb_compositor.v port list is unchanged).
    reg [31:0] purge_b_count, purge_o_count;

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
            m_axis_tdata <= {PPC*24{1'b0}};
            m_axis_tvalid<= 1'b0;
            m_axis_tlast <= 1'b0;
            m_axis_tuser <= 1'b0;
            locked           <= 1'b0;
            lock_lost_count  <= 32'd0;
            sat_watchdog_count <= 32'd0;
            beats_blended    <= 32'd0;
            drain_req        <= 1'b0;
            purge_b_count    <= 32'd0;
            purge_o_count    <= 32'd0;
        end else begin
            // ---- stage 0 load (pops both planes together) -------------------
            // A pair whose sideband disagrees is popped and thrown away, never
            // blended: compositing pixel N of one plane over pixel N of a plane
            // that is somewhere else in the frame is exactly the corruption the
            // frame lock exists to prevent.
            // Load-before-clear: when this stage is simultaneously drained and
            // reloaded the load branch wins, which is the legal same-cycle
            // forward-move + reload case of the elastic chain.
            if (consume && pair_ok) begin
                d0_r          <= d0_w;
                bg0_r         <= bg0_w;
                a0_r          <= a0_w;
                en0_r         <= blend_enable;
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
                stage1_sof   <= stage0_sof;
                stage1_eol   <= stage0_eol;
                stage1_valid <= 1'b1;
            end else if (stage1_valid && out_free) begin
                stage1_valid <= 1'b0;
            end

            // ---- stage 2 / output register ---------------------------------
            if (stage1_valid && out_free) begin
                m_axis_tdata  <= blend_w;
                m_axis_tuser  <= stage1_sof;
                m_axis_tlast  <= stage1_eol;
                m_axis_tvalid <= 1'b1;
                out_sat       <= |sat_w;
                beats_blended <= beats_blended + 32'd1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end

            if (out_sat) sat_watchdog_count <= sat_watchdog_count + 32'd1;
            if (b_pop && !consume) purge_b_count <= purge_b_count + 32'd1;
            if (o_pop && !consume) purge_o_count <= purge_o_count + 32'd1;

            // ---- re-lock drain ----------------------------------------------
            if (unlock)                     drain_req <= 1'b1;
            else if (drain_req && pair_sof) drain_req <= 1'b0;

            // ---- frame lock -------------------------------------------------
            // TLAST is end of LINE: a matched TLAST pair keeps the lock, only a
            // sideband mismatch (one plane ends or starts a line without the
            // other) or an explicit unlock loses it.
            if (unlock)
                locked <= 1'b0;
            else if (!locked && consume && pair_sof)
                locked <= 1'b1;
            else if (locked && consume && !pair_ok) begin
                locked          <= 1'b0;
                lock_lost_count <= lock_lost_count + 32'd1;
            end
        end
    end

    // Host-visible STATUS[10]: every token that is still in the compositor, in
    // whichever of the three stages it sits, keeps this asserted.
    assign pipeline_busy = stage0_valid || stage1_valid || m_axis_tvalid;
endmodule
`default_nettype wire
