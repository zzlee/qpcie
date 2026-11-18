`timescale 1ns/1ps
// ============================================================================
// tb/sc7f0_alpha_blend_2ppc_tb.sv - SC7F0-RGB-COMPOSITOR-2PPC compositor maths
//
//   T1 endpoints   : A=0 reproduces the base pixel exactly, A=255 reproduces the
//                    overlay pixel exactly, for every component and pixel.
//   T2 rounding    : random (A, FG, BG) triples are compared against the
//                    reference out = BG + round(A*(FG-BG)/255) within the
//                    half-LSB bound the 257/65536 + 32767 form guarantees, and
//                    every result stays inside [0,255] (sat_watchdog stays 0).
//   T3 blend_enable=0 : the base plane passes through untouched (the overlay is
//                    still consumed, so the two readers cannot drift).
//   T4 flow control: randomised downstream stalls must neither duplicate nor drop
//                    a beat; beats_blended must equal the number of consumed beat
//                    pairs, and the output sequence must equal the reference.
//   T5 frame lock  : nothing is emitted before the two planes present TUSER on the
//                    same beat; a pair whose sideband disagrees (one plane ends a
//                    line without the other) is discarded, unlocks the compositor
//                    and is counted in lock_lost_count.  A *matched* TLAST pair is
//                    end-of-line and must NOT lose the lock, otherwise a multi-line
//                    frame stops being composited after its first line.
//   T6 re-lock     : after such an unlock the compositor discards everything until
//                    both planes present a frame start again, and the first beat
//                    out of the re-lock is the first beat of the new frame.
//
// Scoring rules used here (the first revision broke all three and that is how the
// gate lost 31 errors and then hung an xsimk):
//   * stimulus is changed on a clock edge with non-blocking assignments, and a
//     beat is held until the DUT actually pops it - tready only says the input
//     queue has room, it does not say the beat was composited;
//   * the scoreboard books an output on the clock edge where tvalid && tready are
//     both true;
//   * every wait is bounded, and a global watchdog turns any unreachable wait
//     into a reported FAIL instead of a runaway simulator process.
// ============================================================================
module sc7f0_alpha_blend_2ppc_tb;
    localparam integer PPC = 2;

    reg clk = 0, rst_n = 0;

    reg  [PPC*32-1:0] bd = 0, od = 0;
    reg               bv = 0, ov = 0, bl = 0, ol = 0, bu = 0, ou = 0;
    wire              bready, oready;
    wire [PPC*24-1:0] mtdata;
    wire              mtvalid, mtlast, mtuser;
    reg               mready = 1;
    reg               blend_en = 1, force_opaque = 0, unlock = 0;
    wire              locked, busy;
    wire [1:0]        gl_state;
    wire [2:0]        gl_reason;
    wire [31:0]       lock_lost, sat_cnt, beats, lock_count, passthru;

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
            #3.3 clk = ~clk;
        end
    end

    sc7f0_alpha_blend_2ppc #(.PPC(PPC), .QUEUE_DEPTH(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .blend_enable(blend_en), .alpha_force_opaque(force_opaque), .unlock(unlock),
        .s_b_axis_tdata(bd), .s_b_axis_tvalid(bv), .s_b_axis_tready(bready),
        .s_b_axis_tlast(bl), .s_b_axis_tuser(bu),
        .s_o_axis_tdata(od), .s_o_axis_tvalid(ov), .s_o_axis_tready(oready),
        .s_o_axis_tlast(ol), .s_o_axis_tuser(ou),
        .m_axis_tdata(mtdata), .m_axis_tvalid(mtvalid), .m_axis_tready(mready),
        .m_axis_tlast(mtlast), .m_axis_tuser(mtuser),
        .locked(locked), .pipeline_busy(busy),
        .gl_state(gl_state), .gl_drop_reason(gl_reason),
        .gl_lock_count(lock_count),
        .lock_lost_count(lock_lost), .sat_watchdog_count(sat_cnt),
        .beats_blended(beats), .base_passthru_beats(passthru)
    );

    // reference model -------------------------------------------------------
    function [7:0] ref_comp;
        input [7:0] a, fg, bg;
        integer d, p, r;
        begin
            d = fg - bg;
            p = a * d;
            r = bg + ((257*p + 32767) >> 16);
            ref_comp = r[7:0];
        end
    endfunction

    // Expected output queue.  The expectations used to be booked by the stimulus
    // tasks, which cannot work any more: since B1 the compositor itself decides
    // whether a pair is composited, forwarded un-blended, or DISCARDED (a pair
    // whose sideband disagrees), so a task-side scoreboard either books a beat
    // that never comes out or misses one that does - and the mismatch then
    // cascades into every later beat.  Booking is therefore taken from the DUT's
    // own front-pop edge, exactly mirroring rtl/sc7f0_alpha_blend_2ppc.v:
    //
    //   paired && pair_ok -> a composited beat (base, or the blend, according to
    //                        the mode the beat is captured with)
    //   base_only         -> the background beat, bit-exact
    //   paired && !pair_ok-> popped and discarded, nothing emitted, nothing booked
    //
    // exp_b / exp_o are kept only so a mismatch prints the pair that produced it.
    reg [PPC*24-1:0] exp_q [0:4095];
    reg [PPC*32-1:0] exp_b [0:4095], exp_o [0:4095];   // the beat that produced it
    integer eq_tail = 0, eq_head = 0;
    integer book, bkp;
    reg [7:0] bka;

    always @(posedge clk) begin
        if (rst_n && dut.b_pop) begin
            book = 0;
            if (dut.paired && dut.pair_ok) begin
                for (bkp = 0; bkp < PPC; bkp = bkp + 1) begin
                    // alpha_force_opaque is folded into the beat at stage 0, and
                    // blend_enable is captured as en0_r on the same edge, so the
                    // live inputs are the right thing to read here.
                    bka = force_opaque ? 8'hFF : dut.o_head[bkp*32+31 -: 8];
                    if (!blend_en) begin
                        exp_q[eq_tail][bkp*24+23 -: 8] = dut.b_head[bkp*32+23 -: 8];
                        exp_q[eq_tail][bkp*24+15 -: 8] = dut.b_head[bkp*32+15 -: 8];
                        exp_q[eq_tail][bkp*24+7  -: 8] = dut.b_head[bkp*32+7   -: 8];
                    end else begin
                        exp_q[eq_tail][bkp*24+23 -: 8] =
                            ref_comp(bka, dut.o_head[bkp*32+23 -: 8],
                                         dut.b_head[bkp*32+23 -: 8]);
                        exp_q[eq_tail][bkp*24+15 -: 8] =
                            ref_comp(bka, dut.o_head[bkp*32+15 -: 8],
                                         dut.b_head[bkp*32+15 -: 8]);
                        exp_q[eq_tail][bkp*24+7  -: 8] =
                            ref_comp(bka, dut.o_head[bkp*32+7  -: 8],
                                         dut.b_head[bkp*32+7   -: 8]);
                    end
                end
                exp_b[eq_tail] = dut.b_head[PPC*32-1:0];
                exp_o[eq_tail] = dut.o_head[PPC*32-1:0];
                book = 1;
            end else if (dut.base_only) begin
                for (bkp = 0; bkp < PPC; bkp = bkp + 1)
                    exp_q[eq_tail][bkp*24 +: 24] = dut.b_head[bkp*32 +: 24];
                exp_b[eq_tail] = dut.b_head[PPC*32-1:0];
                exp_o[eq_tail] = {PPC*32{1'b0}};
                book = 1;
            end
            if (book) eq_tail = eq_tail + 1;
            else if (dut.paired && !dut.pair_ok) discarded = discarded + 1;
        end
    end

    // Watchdog: an unreachable wait must fail loudly, not spin the simulator.
            initial begin : watchdog
        #300_000;
        if (!tb_finished) begin
            // ~90k cycles; the suite needs a few hundred
            $display("TB_WATCHDOG_TIMEOUT sc7f0_alpha_blend_2ppc_tb: no $finish within 300 us (errors=%0d beats=%0d expected=%0d)",
            errors, beats, eq_tail);
            gate_pass = 1'b0;
            $display("ALPHA_BLEND_TB_FAIL");
            $finish;
        end
    end

    // Actual pop accounting, taken from the DUT: `consume` is the beat the
    // compositor really blended, b_pop/o_pop also include the re-alignment
    // purge and the re-lock drain.  They are only read by the display lines
    // below; the stimulus waits on dut.consume / dut.o_pop directly (see
    // wait_pop) so that a beat is never offered for one cycle too many.
    integer pop_cnt = 0, bpop_cnt = 0, opop_cnt = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.consume) pop_cnt  = pop_cnt  + 1;
            if (dut.b_pop)   bpop_cnt = bpop_cnt + 1;
            if (dut.o_pop)   opop_cnt = opop_cnt + 1;
        end
    end

    task automatic wait_accept(input integer limit);
        integer k;
        begin
            // AXI-Stream master rule: hold the beat, unchanged, until the edge
            // where tvalid && tready are both sampled true, and change/deassert
            // on the very next edge.  `tready` here is the compositor's input
            // queue (rtl/sc7f0_alpha_blend_2ppc.v: tready = !queue_full), NOT the
            // blend pop: waiting for the pop instead keeps tvalid asserted for a
            // cycle that was already accounted for, the queue then takes the same
            // beat a second time and every later beat is duplicated (that is how
            // T1 produced 6 beats for 3 pixel pairs).
            //
            // bready/oready are read on the clock edge itself, so they are the
            // value the DUT sampled: the registers behind them only change later,
            // in the non-blocking region of the same edge.
            k = 0;
            @(posedge clk);
            while (!(bready && oready) && k < limit) begin @(posedge clk); k = k + 1; end
            if (!(bready && oready)) begin
                errors = errors + 1;
                $display("TB FAIL queues never accepted the beat within %0d cycles (locked=%b gl=%0d bfull=%b ofull=%b mvalid=%b mready=%b)",
                         limit, locked, gl_state, dut.b_full, dut.o_full,
                         mtvalid, mready);
            end
        end
    endtask

    // Driven base beats are counted here, and every pop the DUT makes is counted
    // in the booking block above, so the two must agree:
    //
    //     driven_total == eq_tail + discarded
    //
    // i.e. every background beat the test offered either became an emitted beat
    // or was one of the pairs the compositor is required to discard (a sideband
    // mismatch, T5c).  Nothing else is allowed to consume plane A, and that is the
    // whole "flow control must neither drop nor duplicate" claim of T4 stated as
    // one invariant instead of a per-test guess.
    integer driven_total = 0, discarded = 0;

    task automatic drain_all(input integer limit);
        integer k, target;
        begin
            target = driven_total - discarded;
            k = 0;
            while (eq_tail < target && k < limit) begin @(posedge clk); k = k + 1; end
            if (eq_tail < target) begin
                errors = errors + 1;
                $display("TB FAIL %0d of %0d driven background beat(s) were never popped from plane A",
                         target - eq_tail, driven_total);
            end
            k = 0;
            while (eq_head < eq_tail && k < limit) begin @(posedge clk); k = k + 1; end
            if (eq_head < eq_tail) begin
                errors = errors + 1;
                $display("TB FAIL %0d booked beat(s) never came out of the compositor",
                         eq_tail - eq_head);
            end
            if (driven_total != eq_tail + discarded) begin
                errors = errors + 1;
                $display("TB FAIL accounting: driven=%0d emitted=%0d discarded=%0d",
                         driven_total, eq_tail, discarded);
            end
        end
    endtask

    // One protocol-legal beat on each plane while the compositor is unlocked.
    // Under the SOF genlock (B1) that pair does two things: the overlay beat is
    // discarded (it belongs to no synchronised frame), and the background beat is
    // FORWARDED un-blended - never composited, never dropped, because plane A is
    // the stream the TX is scanning.  The scoreboard books that automatically from
    // the pop edge; this task only checks the counters it is about.
    task automatic drive_ignored_pair(input [PPC*32-1:0] b, input [PPC*32-1:0] o);
        integer b0, o0, bt, pt0;
        begin
            b0 = bpop_cnt; o0 = opop_cnt; bt = beats; pt0 = passthru;
            bd <= b; od <= o; bv <= 1'b1; ov <= 1'b1;
            bl <= 1'b0; ol <= 1'b0; bu <= 1'b0; ou <= 1'b0;
            wait_accept(20000);
            driven_total = driven_total + 1;
            bv <= 0; ov <= 0;
            repeat (20) @(posedge clk);
            if (bpop_cnt == b0 || opop_cnt == o0) begin
                errors = errors + 1;
                $display("TB FAIL an unlocked mid-frame beat was neither blended nor discarded (locked=%b bfull=%b ofull=%b gl=%0d pops %0d->%0d / %0d->%0d)",
                         locked, dut.b_full, dut.o_full, gl_state,
                         b0, bpop_cnt, o0, opop_cnt);
            end
            if (beats != bt) begin
                errors = errors + 1;
                $display("TB FAIL compositor COMPOSITED a beat while it was not frame-locked");
            end
            if (passthru != pt0 + 1) begin
                errors = errors + 1;
                $display("TB FAIL the background beat of an unlocked pair was not forwarded (passthru %0d -> %0d)",
                         pt0, passthru);
            end
        end
    endtask

    integer oi;
    always @(posedge clk) begin
        if (rst_n && mtvalid && mready) begin
            if (eq_head >= eq_tail) begin
                errors = errors + 1;
                $display("T4 FAIL output beat with nothing expected");
            end else begin
                if (mtdata !== exp_q[eq_head]) begin
                    errors = errors + 1;
                    $display("T1/T2/T4 FAIL beat %0d got %h want %h  (base=%h overlay=%h)",
                             eq_head, mtdata, exp_q[eq_head],
                             exp_b[eq_head], exp_o[eq_head]);
                    for (oi = 0; oi < PPC; oi = oi + 1)
                        $display("   pix%0d got R=%02h B=%02h G=%02h | want R=%02h B=%02h G=%02h | A=%02h FG=%h BG=%h",
                            oi, mtdata[oi*24+23-:8], mtdata[oi*24+15-:8], mtdata[oi*24+7-:8],
                            exp_q[eq_head][oi*24+23-:8], exp_q[eq_head][oi*24+15-:8],
                            exp_q[eq_head][oi*24+7-:8],
                            exp_o[eq_head][oi*32+31 -: 8],
                            exp_o[eq_head][oi*32+23 -: 24],
                            exp_b[eq_head][oi*32+23 -: 24]);
                end
                eq_head = eq_head + 1;
            end
        end
    end

    // drive one beat pair ---------------------------------------------------
    // `en` records the mode the test is exercising; the scoreboard no longer uses
    // it (it reads the live blend_enable on the pop edge), so the argument is now
    // a self-check that the test says what it does.
    task automatic drive_pair(input [PPC*32-1:0] b, input [PPC*32-1:0] o,
                              input integer eol, input integer sof,
                              input integer en);
        begin
            if ((en != 0) != (blend_en != 0)) begin
                errors = errors + 1;
                $display("TB FAIL the test drove a pair with en=%0d while blend_enable=%b",
                         en, blend_en);
            end
            // Hold the pair, unchanged, until the queues accept it, then drop it
            // on the next edge (exactly one take per beat).
            bd <= b; od <= o; bv <= 1'b1; ov <= 1'b1;
            bl <= eol[0]; ol <= eol[0]; bu <= sof[0]; ou <= sof[0];
            wait_accept(20000);
            bd <= 0; od <= 0; bv <= 1'b0; ov <= 1'b0;
            bl <= 0; ol <= 0; bu <= 0; ou <= 0;
            driven_total = driven_total + 1;
        end
    endtask

    integer l, p, seed, k;
    integer beats0, lost0;
    reg [PPC*32-1:0] b, o;
    initial begin
        integer i;
        #100; rst_n = 1;
        repeat (10) @(posedge clk);

        // ---- T1 endpoints -------------------------------------------------
        // alpha = 0 -> base, alpha = 255 -> overlay
        for (l = 0; l < 2; l = l + 1) begin
            seed = l ? 8'hff : 8'h00;         // alpha fill
            for (p = 0; p < PPC; p = p + 1) begin
                b[p*32+31 -: 8] = 8'h00;
                b[p*32+23 -: 8] = 8'h20 + p*8 + (l*3);
                b[p*32+15 -: 8] = 8'h40 + p*8 + (l*5);
                b[p*32+7  -: 8] = 8'h60 + p*8 + (l*7);
                o[p*32+31 -: 8] = seed;
                o[p*32+23 -: 8] = 8'hc0 + p*4 + (l*2);
                o[p*32+15 -: 8] = 8'hd0 + p*4 + (l*6);
                o[p*32+7  -: 8] = 8'he0 + p*4 + (l*9);
            end
            drive_pair(b, o, 0, (l==0) ? 1 : 0, 1);
        end
        // a closing EOL pair so the frame can close cleanly
        drive_pair(b, o, 1, 0, 1);
        repeat (30) @(posedge clk);
        $display("SC7F0_BLEND T1 done errors=%0d locked=%b beats=%0d", errors, locked, beats);

        // ---- T2 random maths + T4 random stalls ---------------------------
        // re-acquire the lock with a fresh simultaneous frame start
        unlock <= 1; repeat (4) @(posedge clk); unlock <= 0; repeat (4) @(posedge clk);
        mready = 1;
        for (l = 0; l < 24; l = l + 1) begin
            for (p = 0; p < PPC; p = p + 1) begin
                b[p*32+31 -: 8] = 8'hff;                       // base alpha unused
                b[p*32+23 -: 8] = $random;
                b[p*32+15 -: 8] = $random;
                b[p*32+7  -: 8] = $random;
                o[p*32+31 -: 8] = $random;                     // random alpha
                o[p*32+23 -: 8] = $random;
                o[p*32+15 -: 8] = $random;
                o[p*32+7  -: 8] = $random;
            end
            fork begin : drv drive_pair(b, o, (l==23) ? 1 : 0, (l==0) ? 1 : 0, 1); end
                 begin repeat (($random & 32'h7fff) % 7) @(posedge clk);
                      mready <= ($random & 1);      // non-blocking: no sampling race
                      repeat (($random & 32'h7fff) % 3) @(posedge clk);
                      mready <= 1; end join
        end
        drain_all(6000);
        if (sat_cnt != 0) begin
            errors = errors + 1;
            $display("T2 FAIL sat_watchdog_count=%0d; the blend maths left [0,255]", sat_cnt);
        end
        $display("SC7F0_BLEND T2/T4 random maths with stalls done errors=%0d beats=%0d expected=%0d", errors, beats, eq_tail);

        // ---- T3 blend_enable = 0 ------------------------------------------
        unlock <= 1; repeat (4) @(posedge clk); unlock <= 0; repeat (4) @(posedge clk);
        blend_en = 0;
        for (l = 0; l < 4; l = l + 1) begin
            for (p = 0; p < PPC; p = p + 1) begin
                b[p*32+31 -: 8] = 8'h00;
                b[p*32+23 -: 8] = 8'h11 + l + p;
                b[p*32+15 -: 8] = 8'h22 + l + p;
                b[p*32+7  -: 8] = 8'h33 + l + p;
                o[p*32+31 -: 8] = 8'hff;                       // opaque overlay
                o[p*32+23 -: 8] = 8'ha0;
                o[p*32+15 -: 8] = 8'hb0;
                o[p*32+7  -: 8] = 8'hc0;
            end
            drive_pair(b, o, (l==3) ? 1 : 0, (l==0) ? 1 : 0, 0);
        end
        repeat (40) @(posedge clk);
        blend_en = 1;
        $display("SC7F0_BLEND T3 passthrough done errors=%0d", errors);

        // ---- T5a frame lock: an unpaired frame start must composite nothing --
        // It must, however, still FORWARD the background beat: plane A is what the
        // TX scans, and holding it is exactly the 坑 16 failure this revision fixes.
        unlock <= 1; repeat (4) @(posedge clk); unlock <= 0; repeat (4) @(posedge clk);
        beats0 = beats;
        bd <= 32'h1234_5678; bv <= 1'b1; bu <= 1'b1; bl <= 1'b0;
        od <= 32'h9abc_def0; ov <= 1'b1; ou <= 1'b0; ol <= 1'b0;
        wait_accept(20000);                     // one take per plane, then drop
        driven_total = driven_total + 1;
        bv <= 1'b0; ov <= 1'b0; bu <= 1'b0; ou <= 1'b0;
        repeat (20) @(posedge clk);             // the stale overlay beat is purged
        repeat (30) @(posedge clk);
        if (locked) begin
            errors = errors + 1;
            $display("T5 FAIL compositor locked without an aligned frame start on both planes");
        end
        if (gl_state !== 2'd0) begin
            errors = errors + 1;
            $display("T5a FAIL genlock state %0d after an unpaired SOF, want GL_SEEK_OVL(0)", gl_state);
        end
        if (beats != beats0) begin
            errors = errors + 1;
            $display("T5 FAIL %0d beat(s) COMPOSITED without an aligned frame start", beats - beats0);
        end
        if (passthru == 0) begin
            errors = errors + 1;
            $display("T5a FAIL the background frame start was not forwarded (base_passthru_beats=0)");
        end
        if (dut.purge_o_count == 0) begin
            errors = errors + 1;
            $display("T5 FAIL the unpaired overlay beat was not discarded (purge_o_count=0)");
        end else
            $display("SC7F0_BLEND T5a unpaired_sof not composited but forwarded, purge o=%0d passthru=%0d",
                     dut.purge_o_count, passthru);

        // ---- T5b matched TLAST is end of LINE: the lock must survive ---------
        // 3 lines of 3 beats; TLAST on the last beat of every line, on BOTH
        // planes. A frame must be composited line after line, not only up to the
        // first TLAST pair.
        unlock <= 1; repeat (4) @(posedge clk); unlock <= 0; repeat (4) @(posedge clk);
        beats0 = beats;
        for (l = 0; l < 9; l = l + 1) begin
            for (p = 0; p < PPC; p = p + 1) begin
                b[p*32+31 -: 8] = 8'h00;
                b[p*32+23 -: 8] = 8'h30 + l*7 + p;
                b[p*32+15 -: 8] = 8'h40 + l*5 + p;
                b[p*32+7  -: 8] = 8'h50 + l*3 + p;
                o[p*32+31 -: 8] = 8'h80 + l;                 // mid-range alpha
                o[p*32+23 -: 8] = 8'h90 + l*2 + p;
                o[p*32+15 -: 8] = 8'ha0 + l*2 + p;
                o[p*32+7  -: 8] = 8'hb0 + l*2 + p;
            end
            drive_pair(b, o, (l % 3 == 2) ? 1 : 0, (l == 0) ? 1 : 0, 1);
        end
        drain_all(4000);
        if (beats != beats0 + 9) begin
            errors = errors + 1;
            $display("T5b FAIL composited %0d beats over 3 lines of 3 beats, want 9 (locked=%b)",
                     beats - beats0, locked);
        end
        if (!locked) begin
            errors = errors + 1;
            $display("T5b FAIL lock dropped on a matched TLAST; TLAST is end-of-LINE, not end-of-frame");
        end else
            $display("SC7F0_BLEND T5b three_lines_composited=%0d lock_held_across_matched_tlast=1",
                     beats - beats0);

        // ---- T5c one plane closes a line alone: discard pair, unlock, count ---
        lost0 = lock_lost;
        beats0 = beats;
        bd <= 64'h1122_3344_5566_7788; bv <= 1'b1; bl <= 1'b1; bu <= 1'b0;
        od <= 64'h99aa_bbcc_ddee_ff00; ov <= 1'b1; ol <= 1'b0; ou <= 1'b0;
        wait_accept(20000);                     // both queues take the pair
        driven_total = driven_total + 1;        // ... and it is required to discard it
        bv <= 1'b0; ov <= 1'b0; bl <= 1'b0; ol <= 1'b0;
        repeat (20) @(posedge clk);
        if (locked) begin
            errors = errors + 1;
            $display("T5c FAIL compositor stayed locked after a one-sided line end");
        end
        if (lock_lost <= lost0) begin
            errors = errors + 1;
            $display("T5c FAIL lock_lost_count did not advance (%0d -> %0d)", lost0, lock_lost);
        end
        if (beats != beats0) begin
            errors = errors + 1;
            $display("T5c FAIL the sideband-mismatched pair was composited (%0d -> %0d)",
                     beats0, beats);
        end else
            $display("SC7F0_BLEND T5c lock_lost %0d -> %0d, mismatched pair discarded", lost0, lock_lost);

        // ---- T6 re-lock: skip everything until both planes start together -----
        drive_ignored_pair(64'h0f0f_0f0f_1111_2222, 64'h3333_4444_5555_6666);
        drive_ignored_pair(64'h0e0e_0e0e_1212_2323, 64'h3434_4545_5656_6767);
        beats0 = beats;
        for (p = 0; p < PPC; p = p + 1) begin
            b[p*32+31 -: 8] = 8'h00;
            b[p*32+23 -: 8] = 8'h11 + p;
            b[p*32+15 -: 8] = 8'h22 + p;
            b[p*32+7  -: 8] = 8'h33 + p;
            o[p*32+31 -: 8] = 8'h00;                       // A=0 -> pure base
            o[p*32+23 -: 8] = 8'hee;
            o[p*32+15 -: 8] = 8'hdd;
            o[p*32+7  -: 8] = 8'hcc;
        end
        drive_pair(b, o, 0, 1, 1);           // fresh simultaneous frame start
        drain_all(2000);
        if (beats != beats0 + 1 || !locked) begin
            errors = errors + 1;
            $display("T6 FAIL re-lock did not produce exactly one composited beat (beats %0d -> %0d, locked=%b)",
                     beats0, beats, locked);
        end else begin
            // A=0 must reproduce the base pixel, in native R,B,G field order:
            // pixel0 = R 0x11, B 0x22, G 0x33 and pixel1 = R 0x12, B 0x23, G 0x34.
            if (mtdata !== {8'h12, 8'h23, 8'h34, 8'h11, 8'h22, 8'h33}) begin
                errors = errors + 1;
                $display("T6 FAIL A=0 passthrough after re-lock got %h want 12_23_34_11_22_33", mtdata);
            end else
                $display("SC7F0_BLEND T6 relock_ok=1 first_beat=%h (A=0 -> base)", mtdata);
        end

        // ---- closing accounting ------------------------------------------
        drain_all(4000);
        if (beats + passthru != eq_head) begin
            errors = errors + 1;
            $display("T4 FAIL blended=%0d + passthru=%0d but %0d beat(s) were popped and booked",
                     beats, passthru, eq_head);
        end
        $display("SC7F0_ALPHA_BLEND_STATS errors=%0d blended=%0d passthru=%0d offered=%0d lock_lost=%0d locks=%0d reason=%0d sat=%0d purge_o=%0d base_stall=%0d",
                 errors, beats, passthru, eq_tail, lock_lost, lock_count, gl_reason,
                 sat_cnt, dut.purge_o_count, dut.base_stall_cycles);

        tb_finished = 1'b1;   // the verdict below is final; a resumed run must not overrule it
        gate_pass = (errors == 0);
        $display("SC7F0_ALPHA_BLEND_TB errors=%0d beats=%0d sat=%0d gate_pass=%b",
                 errors, beats, sat_cnt, gate_pass);
        if (errors == 0) $display("ALPHA_BLEND_TB_PASS");
        else             $display("ALPHA_BLEND_TB_FAIL");
        $finish;
    end
endmodule
