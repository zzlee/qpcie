`timescale 1ns / 1ps
// ============================================================================
// tb/sc7f0_alpha_blend_genlock_tb.sv - B1 gate: the SOF genlock state machine
// of rtl/sc7f0_alpha_blend_2ppc.v.
//
// The companion tb/sc7f0_alpha_blend_2ppc_tb.sv scores the compositing maths and
// the elastic pipeline.  This one scores only the genlock contract, which is the
// thing that decides whether the on-screen overlay is aligned at all:
//
//   G1 plane A is never back-pressured while the compositor is not locked.  The
//      background source runs continuously for two whole frames with NO overlay
//      present at all, and b_axis_tready is required to stay high on every cycle.
//      (This is the defect the state machine exists to remove: the previous
//      revision held a background frame start while it waited for the overlay,
//      filled its own 16-deep queue in 16 beats, and stalled the base reader -
//      坑 16 of the reference project's pitfall list.)
//   G2 nothing is ever COMPOSITED before the coincidence.  Everything that comes
//      out while the compositor is seeking is the background, bit-exact.
//   G3 an overlay that starts mid-frame is drained, then held at its own frame
//      start, and the compositor locks on the cycle the BACKGROUND presents its
//      frame start - GL_SEEK_OVL -> GL_WAIT_VSOF -> GL_LOCKED, one state per
//      observed event, and lock on the same beat with 0 phase difference.
//   G4 the blended content from the locking beat on is the real composite (the
//      scoreboard computes golden(BG,FG,A) from the two queue heads on the DUT's
//      own paired-pop edge and compares it against the emitted word).
//   G5 an overlay that dies mid-frame cannot starve the TX: after
//      OVERLAY_STARVE_LIMIT cycles of "background waiting, overlay absent" the
//      compositor falls back to GL_SEEK_OVL with drop_reason=2, lock_lost_count
//      advances, and the background stream never stops.
//   G6 `unlock` (the COMP_CTRL bit) parks the machine in GL_SEEK_OVL with
//      drop_reason=3, drains the overlay queue, keeps forwarding the background,
//      and a fresh simultaneous frame start re-locks.
//
// The starve limit is overridden to 32 here so G5 costs microseconds; the
// production default (1024) is what rtl/sc7f0_alpha_blend_2ppc.v ships.
// ============================================================================
module sc7f0_alpha_blend_genlock_tb;
    localparam integer PPC   = 2;
    localparam integer LINES = 4;              // lines per frame
    localparam integer BPL   = 8;              // beats per line
    localparam integer BF    = LINES * BPL;    // beats per frame
    localparam integer STARVE = 32;

    reg clk = 0, rst_n = 0;

    // ---- DUT ------------------------------------------------------------
    reg  [PPC*32-1:0] bd = 0, od = 0;
    reg               bv = 0, ov = 0, bl = 0, ol = 0, bu = 0, ou = 0;
    reg               b_en = 0, o_en = 0;        // source running
    wire              bready, oready;
    wire [PPC*24-1:0] mtdata;
    wire              mtvalid, mtlast, mtuser, locked, busy;
    wire [1:0]        gl_state;
    wire [2:0]        gl_reason;
    wire [31:0]       lock_lost, sat_cnt, beats, locks, passthru;
    reg               mready = 1;
    reg               blend_en = 1, force_opaque = 0, unlock = 0;

    sc7f0_alpha_blend_2ppc #(.PPC(PPC), .QUEUE_DEPTH(16),
                             .OVERLAY_STARVE_LIMIT(STARVE)) dut (
        .clk(clk), .rst_n(rst_n),
        .blend_enable(blend_en), .alpha_force_opaque(force_opaque), .unlock(unlock),
        .s_b_axis_tdata(bd), .s_b_axis_tvalid(bv), .s_b_axis_tready(bready),
        .s_b_axis_tlast(bl), .s_b_axis_tuser(bu),
        .s_o_axis_tdata(od), .s_o_axis_tvalid(ov), .s_o_axis_tready(oready),
        .s_o_axis_tlast(ol), .s_o_axis_tuser(ou),
        .m_axis_tdata(mtdata), .m_axis_tvalid(mtvalid), .m_axis_tready(mready),
        .m_axis_tlast(mtlast), .m_axis_tuser(mtuser),
        .locked(locked), .pipeline_busy(busy),
        .gl_state(gl_state), .gl_drop_reason(gl_reason), .gl_lock_count(locks),
        .lock_lost_count(lock_lost), .sat_watchdog_count(sat_cnt),
        .beats_blended(beats), .base_passthru_beats(passthru)
    );

    localparam [1:0] SEEK = 2'd0, WAIT_VSOF = 2'd1, LOCKED_ST = 2'd2;

    integer errors = 0;
    reg gate_pass = 1'b0;
    // Set once the sequence has reached its verdict.  A batch gate may resume a
    // testbed whose $finish already ran (see scripts/sim_sc7f0_rgb_compositor.tcl),
    // and a watchdog must then stay silent rather than overrule a finished test.
    reg tb_finished = 1'b0;

    initial begin : clk_gen
        // Stopping the clock at the verdict is what makes this testbed
        // re-runnable: a batch gate may issue a second `run` after the test
        // already called $finish, and with a free-running clock the scoreboards
        // keep observing beats no stimulus ever drove (that is how a passing
        // repack testbed once came out of the gate with gate_pass=0).
        while (!tb_finished) begin
            #1.667 clk = ~clk;
        end
    end
    task automatic fail(input [255:0] why);
        begin errors = errors + 1; $display("GENLOCK_TB FAIL %0s", why); end
    endtask

    // ------------------------------------------------------------------------
    // frame sources.  Beat payload carries its own index, so the scoreboard can
    // prove order and detect a drop or a duplicate:
    //     word = {A, 8'hR0+idx, 8'hB0+idx, 8'hG0+idx} per pixel
    // ------------------------------------------------------------------------
    reg [PPC*32-1:0] b_src [0:4*BF-1];
    reg [PPC*32-1:0] o_src [0:4*BF-1];
    integer bi = 0, bn = 0;              // base index currently presented / total
    integer oi = 0, on = 0;              // overlay
    // The overlay's own frame start sits `o_phase` beats into its stream, so an
    // overlay armed in the middle of a background frame is o_phase <= BF/2 and a
    // simultaneously started pair is o_phase = 0.  Both streams stay strictly
    // periodic with period BF, which is what two readers of one geometry are.
    integer o_phase = 0;

    function [PPC*32-1:0] px_of;
        input integer idx;               // global beat index
        input [7:0] a;
        integer p;
        reg [7:0] r8, b8, g8;
        begin
            px_of = {PPC*32{1'b0}};
            for (p = 0; p < PPC; p = p + 1) begin
                r8 = 8'h10 + idx[7:0] + p[7:0]*8'd2;
                b8 = 8'h40 + idx[7:0] + p[7:0]*8'd1;
                g8 = 8'h70 + idx[7:0] + p[7:0]*8'd3;
                px_of[p*32 +: 32] = {a, r8, b8, g8};
            end
        end
    endfunction

    // base: two back-to-back frames, continuous, no gaps
    integer k, ln, bt;
    initial begin
        bn = 0;
        for (k = 0; k < 2*BF; k = k + 1) begin
            b_src[k] = px_of(k, 8'h00);
            bn = bn + 1;
        end
        on = 0;
        for (k = 0; k < 2*BF; k = k + 1) begin
            o_src[k] = px_of(k, 8'h80);          // half alpha
            on = on + 1;
        end
    end

    // Base source: presents one beat per cycle, never inserts a gap (that is the
    // worst case for the "never back-pressured" claim), and WRAPS so the
    // background is a free-running reader: a scenario in which the base ran out
    // would score "no starve watchdog" for the wrong reason.
    //
    // `bi` is the index PRESENTED, so a beat the queue takes must advance the
    // presentation pointer in the same breath.  Assigning the payload from the
    // pre-edge index while also advancing it re-presents the beat that was just
    // accepted and duplicates it; the first revision of this file did exactly
    // that, and the duplicated background beats looked like a genlock bug rather
    // than a stimulus bug.
    integer bnx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bv <= 1'b0; bu <= 1'b0; bl <= 1'b0; bd <= {PPC*32{1'b0}}; bi <= 0;
        end else if (b_en) begin
            bnx = (bv && bready) ? ((bi + 1) % bn) : bi;
            if (bv && bready) bi <= bnx;
            bd <= b_src[bnx];
            bu <= (bnx % BF) == 0;
            bl <= (bnx % BPL) == (BPL-1);
            bv <= 1'b1;
        end else begin
            bv <= 1'b0; bu <= 1'b0; bl <= 1'b0;
        end
    end

    // Overlay source: may insert gaps (a real reader is bursty), and its own
    // frame start sits `o_phase` beats into the stream rather than on beat 0, so an
    // overlay armed in the middle of a background frame actually looks like one.
    integer o_gap = 0, onx, orelx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ov <= 1'b0; ou <= 1'b0; ol <= 1'b0; od <= {PPC*32{1'b0}}; oi <= 0;
            o_gap <= 0;
        end else if (o_en) begin
            onx = (ov && oready) ? ((oi + 1) % on) : oi;
            if (ov && oready) oi <= onx;
            orelx = (onx + o_phase) % BF;
            od <= o_src[onx];
            ou <= orelx == 0;
            ol <= (orelx % BPL) == (BPL-1);
            o_gap <= o_gap + 1;
            ov   <= (o_gap % 3) != 0;              // one cycle in three idle
        end else begin
            ov <= 1'b0; ou <= 1'b0; ol <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // scoreboard: what each popped beat must become.
    //   paired pop  -> golden(BG, FG, A)          (composited)
    //   base-only   -> the background beat itself (passthrough, bit-exact)
    // The classification is taken from the DUT's own front handshake, so the
    // scoreboard never has to guess the lock timing; the lock timing is scored
    // separately below.
    // ------------------------------------------------------------------------
    function [7:0] gold_comp;
        input [7:0] a, fg, bg;
        integer acc;
        begin
            acc = ((255 - a) * bg + a * fg + 127) / 255;
            gold_comp = acc[7:0];
        end
    endfunction

    function [PPC*24-1:0] gold_word;
        input [PPC*32-1:0] base, over;
        integer p;
        reg [7:0] a;
        begin
            gold_word = {PPC*24{1'b0}};
            for (p = 0; p < PPC; p = p + 1) begin
                a = over[p*32+31 -: 8];
                gold_word[p*24+23 -: 8] = gold_comp(a, over[p*32+23 -: 8],
                                                       base[p*32+23 -: 8]);
                gold_word[p*24+15 -: 8] = gold_comp(a, over[p*32+15 -: 8],
                                                       base[p*32+15 -: 8]);
                gold_word[p*24+7  -: 8] = gold_comp(a, over[p*32+7  -: 8],
                                                       base[p*32+7   -: 8]);
            end
        end
    endfunction

    // The background is free-running, so this scoreboard is a real FIFO sized for
    // the whole run, not for one frame.
    reg [PPC*24-1:0] exp_q [0:32767];
    reg              exp_u [0:32767], exp_l [0:32767];
    integer eq_tail = 0, eq_head = 0;

    integer book, bp;
    always @(posedge clk) begin
        if (rst_n && dut.b_pop) begin
            book = 0;
            // A pair whose sideband disagrees is popped and DISCARDED, so nothing
            // is emitted and nothing may be booked.
            if (dut.paired && dut.pair_ok) begin
                exp_q[eq_tail] = gold_word(dut.b_head[PPC*32-1:0],
                                           dut.o_head[PPC*32-1:0]);
                book = 1;
            end else if (dut.base_only) begin
                // Passthrough: the emitted RGB word is the base pixel's colour
                // slice, component for component (the alpha byte is not part of
                // the compositor's output stream).
                for (bp = 0; bp < PPC; bp = bp + 1)
                    exp_q[eq_tail][bp*24 +: 24] =
                        dut.b_head[bp*32 +: 24];
                book = 1;
            end
            if (book) begin
                exp_u[eq_tail] = dut.b_head[PPC*32+1];       // {tuser, tlast, data}
                exp_l[eq_tail] = dut.b_head[PPC*32];
                eq_tail = eq_tail + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && mtvalid && mready) begin
            if (eq_head >= eq_tail) begin
                fail("emitted a beat that was never popped from plane A");
            end else begin
                if (mtdata !== exp_q[eq_head]) begin
                    $display("  beat %0d got %h want %h (gl=%0d locked=%b)",
                             eq_head, mtdata, exp_q[eq_head], gl_state, locked);
                    fail("emitted pixel content is wrong");
                end
                if (mtuser !== exp_u[eq_head] || mtlast !== exp_l[eq_head])
                    fail("SOF/EOL sideband did not travel with its beat");
                eq_head = eq_head + 1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // contract monitors
    // ------------------------------------------------------------------------
    integer b_stalled_with_data = 0;   // plane A had a beat and was refused
    integer bad_lock_beats = 0;        // locked on anything but a dual SOF
    integer saw_wait_state = 0, saw_locked_state = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            // G1: plane A may only ever be refused by the pipeline itself, i.e.
            // by a downstream stall.  mready is held at 1 for the whole test, so
            // the correct answer is: never refuse.
            if (!mready) ; else if (bv && !bready) b_stalled_with_data <= b_stalled_with_data + 1;
            // Lock may only be taken on a cycle where BOTH plane heads present a
            // frame start (that is the whole point of the state machine).
            if (dut.lock_fire && !(dut.b_sof && dut.o_sof)) bad_lock_beats <= bad_lock_beats + 1;
            if (gl_state == WAIT_VSOF) saw_wait_state = 1;
            if (gl_state == LOCKED_ST) saw_locked_state = 1;
        end
    end

    // ------------------------------------------------------------------------
            initial begin : watchdog
        #400_000;
        if (!tb_finished) begin
            $display("GENLOCK_TB_WATCHDOG gl=%0d eq_head=%0d eq_tail=%0d errors=%0d",
            gl_state, eq_head, eq_tail, errors);
            gate_pass = 1'b0; $display("GENLOCK_TB_FAIL"); $finish;
        end
    end

    integer pt0, bl0, pl0, locks0, lost0, purge0;
    initial begin
        #50; rst_n = 1;
        repeat (5) @(posedge clk);

        // ================================================================
        // G1 + G2: two full background frames, overlay never armed.
        // ================================================================
        b_en <= 1; o_en <= 0; blend_en <= 1;
        repeat (BF * 2 + 40) @(posedge clk);
        if (gl_state !== SEEK) begin
            $display("  G1 gl_state=%0d with no overlay at all, want GL_SEEK_OVL", gl_state);
            fail("G1 state is not SEEK_OVL without an overlay");
        end
        if (locked) fail("G1 compositor claims lock with no overlay");
        if (beats != 0) begin
            $display("  G1 composited %0d beats with no overlay present", beats);
            fail("G1 composited without an overlay");
        end
        if (b_stalled_with_data != 0) begin
            $display("  G1 plane A was back-pressured on %0d cycles while seeking",
                     b_stalled_with_data);
            fail("G1 plane A was back-pressured while seeking for the overlay");
        end
        if (passthru < 2*BF) begin
            $display("  G1 forwarded %0d background beats, expected >= %0d",
                     passthru, 2*BF);
            fail("G1 background beats were dropped instead of forwarded");
        end else
            $display("SC7F0_GENLOCK G1 two_frames_no_overlay forwarded=%0d backpressure_cycles=0 gl=%0d",
                     passthru, gl_state);

        // ================================================================
        // G3 + G4: overlay armed mid-background-frame.  Drain, hold, lock on the
        // background's own next frame start, then composite for real.
        // ================================================================
        // Stop the base, park both streams at a frame boundary so the arithmetic
        // below is exact, then re-run: base from a frame start, overlay starting
        // half a frame later.
        unlock <= 1; repeat (3) @(posedge clk); unlock <= 0;
        repeat (3) @(posedge clk);
        b_en <= 0; o_en <= 0;
        repeat (10) @(posedge clk);
        // restart both streams from index 0, but the overlay's frame start sits
        // half a frame in, so the machine must seek, wait, and only then lock.
        bi <= 0; oi <= 0; o_gap <= 0;
        o_phase <= BF/2;
        pt0 = passthru; bl0 = beats; locks0 = locks;
        b_en <= 1; o_en <= 1;
        // Wait for the lock (bounded).
        k = 0;
        while (gl_state !== LOCKED_ST && k < BF*8) begin @(posedge clk); k = k + 1; end
        if (gl_state !== LOCKED_ST) begin
            $display("  G3 never locked after %0d cycles (gl=%0d reason=%0d)", k, gl_state, gl_reason);
            fail("G3 the compositor never genlocked");
        end
        if (!saw_wait_state) fail("G3 GL_WAIT_VSOF was never entered");
        if (locks != locks0 + 1) begin
            $display("  G3 gl_lock_count %0d -> %0d, expected exactly one lock", locks0, locks);
            fail("G3 lock count moved by more than one");
        end
        if (bad_lock_beats != 0) fail("G3 the machine locked without a dual frame start");
        if (passthru <= pt0) fail("G3 nothing was forwarded while seeking");
        $display("SC7F0_GENLOCK G3 locked after %0d cycles, forwarded_while_seeking=%0d, waited_state=1, dual_sof_lock=1",
                 k, passthru - pt0);

        // ---- G4: composite for a while, both readers running ----
        repeat (BF + 60) @(posedge clk);
        if (beats <= bl0) begin
            $display("  G4 composited %0d beats after locking (delta %0d)", beats, beats - bl0);
            fail("G4 nothing was composited after the lock");
        end

        // ================================================================
        // G5: the overlay reader dies MID-FRAME while the background keeps
        // scanning.  The compositor must give up the lock within
        // OVERLAY_STARVE_LIMIT cycles and must not stop forwarding plane A.
        // ================================================================
        lost0 = lock_lost;
        pt0 = passthru;
        o_en <= 0;                       // the overlay reader stops dead
        k = 0;
        while (gl_state !== SEEK && k < STARVE*20) begin @(posedge clk); k = k + 1; end
        if (gl_state !== SEEK) begin
            $display("  G5 still in gl_state=%0d %0d cycles after the overlay stopped", gl_state, k);
            fail("G5 a stopped overlay held the compositor forever");
        end
        if (k > STARVE + 8) begin
            $display("  G5 fell back after %0d cycles, the starve limit is %0d", k, STARVE);
            fail("G5 the fallback took longer than OVERLAY_STARVE_LIMIT");
        end
        if (gl_reason !== 3'd2) begin
            $display("  G5 drop_reason=%0d after overlay starvation, want 2", gl_reason);
            fail("G5 drop_reason is not 'overlay starved'");
        end
        if (lock_lost <= lost0) fail("G5 lock_lost_count did not advance");
        // And from the fallback on, plane A runs free again: no back-pressure and
        // a continuing passthrough stream is what keeps the TX fed.  The queue is
        // measured after it has drained: the locked phase ran the overlay at two
        // thirds of the background rate, so the queue saturated and the first
        // cycle or two of recovery legitimately holds plane A while a slot frees.
        repeat (20) @(posedge clk);
        pl0 = b_stalled_with_data; pt0 = passthru;
        repeat (40) @(posedge clk);
        if (b_stalled_with_data != pl0) begin
            $display("  G5 plane A was back-pressured on %0d cycles after the fallback",
                     b_stalled_with_data - pl0);
            fail("G5 plane A was back-pressured after falling back to seek");
        end
        if (passthru <= pt0) begin
            $display("  G5 no background beat was forwarded after the overlay died");
            fail("G5 the TX was starved when the overlay died mid-frame");
        end
        $display("SC7F0_GENLOCK G5 overlay_death fell_back_after=%0d cycles (limit %0d) reason=%0d lock_lost=%0d",
                 k, STARVE, gl_reason, lock_lost);

        // To ask "did every beat that went in come out" the producers have to
        // stop first: with a free-running background the scoreboard's tail is by
        // construction always the pipeline depth ahead of its head.
        b_en <= 0;
        repeat (20) @(posedge clk);
        k = 0;
        while (eq_head < eq_tail && k < 5000) begin @(posedge clk); k = k + 1; end
        if (eq_head != eq_tail) begin
            $display("  G4/G5 %0d popped beat(s) never came out", eq_tail - eq_head);
            fail("output stream lost a beat across the locked and fallback phases");
        end
        $display("SC7F0_GENLOCK G4 composited_after_lock=%0d content=golden(BG,FG,A) mismatches=0",
                 beats - bl0);

        // ================================================================
        // G6: unlock parks the machine, re-lock on a simultaneous start.
        // ================================================================
        unlock = 1; repeat (4) @(posedge clk);
        if (gl_state !== SEEK) fail("G6 unlock did not park the machine in SEEK_OVL");
        if (gl_reason !== 3'd3) begin
            $display("  G6 drop_reason=%0d while blend_unlock is set, want 3", gl_reason);
            fail("G6 drop_reason is not 'unlock'");
        end
        unlock = 0;
        // restart both planes together from index 0: the very first beat pair is a
        // simultaneous frame start, so the lock must be taken immediately.
        bi <= 0; oi <= 0; o_phase <= 0; o_gap <= 0;
        purge0 = dut.purge_o_count; pl0 = passthru; locks0 = locks;
        b_en <= 1; o_en <= 1;
        k = 0;
        while (gl_state !== LOCKED_ST && k < BF*4) begin @(posedge clk); k = k + 1; end
        if (gl_state !== LOCKED_ST) fail("G6 re-lock on a simultaneous frame start failed");
        if (locks != locks0 + 1) fail("G6 re-lock did not count exactly one lock");
        b_en <= 0; o_en <= 0;
        repeat (80) @(posedge clk);
        repeat (20) @(posedge clk);
        k = 0;
        while (eq_head < eq_tail && k < 5000) begin @(posedge clk); k = k + 1; end
        if (eq_head != eq_tail) fail("G6 output stream lost a beat");
        $display("SC7F0_GENLOCK G6 unlock_relock ok locks=%0d purge_o=%0d sat=%0d",
                 locks, dut.purge_o_count - purge0, sat_cnt);

        if (sat_cnt != 0) begin
            $display("  G6 sat_watchdog_count=%0d, expected 0 (results stayed in [0,255])", sat_cnt);
            fail("saturation watchdog fired");
        end

        tb_finished = 1'b1;
        tb_finished = 1'b1;   // the verdict below is final; a resumed run must not overrule it
        gate_pass = (errors == 0);
        if (gate_pass)
            $display("SC7F0_ALPHA_BLEND_GENLOCK_PASS forwarded=%0d composited=%0d locks=%0d lock_lost=%0d",
                     passthru, beats, locks, lock_lost);
        else
            $display("GENLOCK_TB_FAIL errors=%0d", errors);
        $display("SC7F0_GENLOCK_TB errors=%0d gate_pass=%b", errors, gate_pass);
        $finish;
    end
endmodule
