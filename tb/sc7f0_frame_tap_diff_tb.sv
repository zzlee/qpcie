`timescale 1ns/1ps
// ============================================================================
// tb/sc7f0_frame_tap_diff_tb.sv - DIFFERENTIAL old-vs-new regression for the
// three-cones review C change in rtl/sc7f0_frame_tap.v.
//
// C replaced the two copies of `real_word && !force_fill` (in ppop's third term
// and in `mismatch`) with one named wire
//     use_real = real_word && !filling && enable && !source_reset && (gap<GAP)
// claimed equal in EVERY state, because real_word excludes both future_word and
// (!pvalid && source_advanced).
//
// Proof style:
//
//  1. DIFFERENTIAL CYCLE EXACTNESS over the real interface.  The NEW tap and a
//     renamed byte-copy of the S-snapshot tap sit side by side, share both
//     clocks, both resets and every stimulus edge, and are compared EVERY
//     m_clk cycle on
//        m_data m_valid m_sof m_eol meta_valid meta_data started_count
//        dropped_frames ticks ticks_gray busy
//     and on the two changed internal nets `ppop` and `mismatch` themselves,
//     plus `force_fill` (which C was not allowed to change).  Genuine xpm
//     FIFOs, no invented vendor stubs.
//     Vectors: back-to-back frames, random source gaps, random m_ready and
//     meta_ready stalls, credit grant / credit_clear, enable toggled mid-frame,
//     source reset mid-frame (filler + flag bits 3/8), GAP_CYCLES overridden to
//     64 so the gap threshold is actually reached, geometry changes, and the
//     admission contract (there is deliberately NO upstream ready: an admitted
//     frame must finish even with the sink fully stopped).
//
//  2. ISOLATED PREDICATE-STATE EQUIVALENCE FIXTURE.  The 32-bit frame-ID
//     modular corners (wrap across 0, delta = 0x80000000, delta = 0x7FFFFFFF,
//     max->0, 0->max) and the 22-bit index boundary cannot be driven through the
//     interface without ~4 billion frames, so the predicate algebra is exercised
//     directly over those corners: the original S expression and the new
//     expression are both re-derived here and compared.  This is explicitly NOT
//     a claim that 4-billion-frame sequences were run on the DUT.
//
// The old tap is the scratch snapshot copy (module sc7f0_frame_tap_old).  A
// mutant of the NEW tap with any single use_real term dropped must make this
// suite FAIL, not time out.
// ============================================================================

module sc7f0_frame_tap_diff_tb;
    localparam integer FDEPTH = 32;
    localparam integer GAP    = 64;          // small on purpose: reachable gaps

    reg sc = 0, mc = 0, sn = 0, mn = 0, en = 0;
    always #3.367 sc = ~sc;
    always #3.333 mc = ~mc;

    reg  [95:0] sd = 0;
    reg         sv = 0, ss = 0, se = 0;
    reg  [15:0] width = 64, height = 64;
    reg         ready = 1, mready = 1;
    reg         credit_valid = 0, credit_clear = 0;
    reg  [15:0] credit_add = 0;

    wire [95:0]  md_n, md_o;
    wire         mv_n, mv_o, ms_n, ms_o, me_n, me_o, busy_n, busy_o;
    wire [159:0] meta_n, meta_o;
    wire         metaval_n, metaval_o;
    wire [31:0]  started_n, started_o, drops_n, drops_o;
    wire [63:0]  ticks_n, ticks_o, gray_n, gray_o;

    sc7f0_frame_tap #(.FIFO_DEPTH(FDEPTH), .GAP_CYCLES(GAP)) dut_new (
        .s_clk(sc), .s_rst_n(sn), .s_data(sd), .s_valid(sv), .s_sof(ss), .s_eol(se),
        .m_clk(mc), .m_rst_n(mn), .enable(en), .width(width), .height(height),
        .credit_valid(credit_valid), .credit_clear(credit_clear),
        .credit_add(credit_add), .started_count(started_n),
        .m_data(md_n), .m_valid(mv_n), .m_sof(ms_n), .m_eol(me_n), .m_ready(ready),
        .meta_data(meta_n), .meta_valid(metaval_n), .meta_ready(mready),
        .busy(busy_n), .dropped_frames(drops_n),
        .ticks(ticks_n), .ticks_gray(gray_n));

    sc7f0_frame_tap_old #(.FIFO_DEPTH(FDEPTH), .GAP_CYCLES(GAP)) dut_old (
        .s_clk(sc), .s_rst_n(sn), .s_data(sd), .s_valid(sv), .s_sof(ss), .s_eol(se),
        .m_clk(mc), .m_rst_n(mn), .enable(en), .width(width), .height(height),
        .credit_valid(credit_valid), .credit_clear(credit_clear),
        .credit_add(credit_add), .started_count(started_o),
        .m_data(md_o), .m_valid(mv_o), .m_sof(ms_o), .m_eol(me_o), .m_ready(ready),
        .meta_data(meta_o), .meta_valid(metaval_o), .meta_ready(mready),
        .busy(busy_o), .dropped_frames(drops_o),
        .ticks(ticks_o), .ticks_gray(gray_o));

    int  errors = 0, checks = 0;
    int  cmp_cycles = 0, ppop_cycles = 0, ppop_diff = 0;
    int  real_word_cycles = 0, use_real_cycles = 0, use_real_diff = 0;
    int  contract_diff = 0;
    int  cov_not_filling = 0, cov_enable = 0, cov_no_sreset = 0;
    int  cov_gap_ok = 0, cov_gap_bad = 0, cov_filling = 0, cov_disable = 0;
    int  metas_seen = 0;
    bit  stalled;
    logic [97:0] held;

    task automatic fail(input string m);
        errors++;
        if (errors <= 40) $display("FAIL @%0t: %s", $time, m);
    endtask
    task automatic ck(input bit c, input string m);
        checks++; if (!c) fail(m);
    endtask

    int rng = 32'hACE12345;
    function automatic [31:0] nrand;
        rng = rng * 1103515245 + 12345;
        nrand = rng ^ (rng >>> 15);
    endfunction

    // ------------------------------------------------------------------------
    // 1. cycle-exact differential
    // ------------------------------------------------------------------------
    always @(posedge mc) begin
        if (mn) begin
            cmp_cycles++;

            if (mv_n !== mv_o || md_n !== md_o || ms_n !== ms_o || me_n !== me_o)
                fail($sformatf("m_axis diverged: new {v=%b s=%b e=%b d=%h} old {v=%b s=%b e=%b d=%h}",
                               mv_n, ms_n, me_n, md_n, mv_o, ms_o, me_o, md_o));
            if (metaval_n !== metaval_o || meta_n !== meta_o)
                fail($sformatf("meta diverged: new {v=%b d=%h} old {v=%b d=%h}",
                               metaval_n, meta_n, metaval_o, meta_o));
            if (started_n !== started_o)
                fail($sformatf("started_count %0d vs %0d", started_n, started_o));
            if (drops_n !== drops_o)
                fail($sformatf("dropped_frames %0d vs %0d", drops_n, drops_o));
            if (ticks_n !== ticks_o) fail("ticks diverged");
            if (gray_n  !== gray_o)  fail("ticks_gray diverged");
            if (busy_n  !== busy_o)  fail("busy diverged");

            // the changed cone itself
            if (dut_new.ppop !== dut_old.ppop) begin
                ppop_diff++;
                if (ppop_diff <= 10)
                    $display("FAIL @%0t: ppop diverged new=%b old=%b (head id=%h idx=%0d)",
                             $time, dut_new.ppop, dut_old.ppop,
                             dut_new.pdata[150:119], dut_new.pdata[118:97]);
            end
            if (dut_new.mismatch !== dut_old.mismatch)
                fail($sformatf("mismatch diverged new=%b old=%b", dut_new.mismatch, dut_old.mismatch));
            if (dut_new.force_fill !== dut_old.force_fill)
                fail("force_fill changed, which C was not allowed to touch");

            // per-cycle equality of the new named wire with the OLD expression
            // re-derived from the untouched real_word / force_fill
            if (dut_new.real_word) real_word_cycles++;
            if (dut_new.use_real)  use_real_cycles++;
            if (dut_new.use_real !== (dut_old.real_word && !dut_old.force_fill)) begin
                use_real_diff++;
                if (use_real_diff <= 10)
                    $display("FAIL @%0t: use_real=%b but old real_word&&!force_fill=%b",
                             $time, dut_new.use_real, (dut_old.real_word && !dut_old.force_fill));
            end
            // control-term guard: every term of the declared use_real contract must
            // still be present in the RTL wire.  A mutant that drops one term makes
            // the wire differ from this reconstruction even when the interface
            // stimulus happens not to reach the divergence, so the mutant test can
            // never pass by accident.
            if (dut_new.use_real !== (dut_new.real_word && !dut_new.filling &&
                                      dut_new.enable && !dut_new.source_reset &&
                                      (dut_new.gap < GAP))) begin
                contract_diff++;
                if (contract_diff <= 10)
                    $display("FAIL @%0t: use_real wire does not match the declared contract (real_word=%b filling=%b enable=%b source_reset=%b gap=%0d)",
                             $time, dut_new.real_word, dut_new.filling, dut_new.enable,
                             dut_new.source_reset, dut_new.gap);
            end
            // coverage of each individual control term while real_word holds
            if (dut_new.real_word) begin
                if (!dut_new.filling) cov_not_filling++;
                if (dut_new.enable)   cov_enable++;
                if (!dut_new.source_reset) cov_no_sreset++;
                if (dut_new.gap < GAP)  cov_gap_ok++;
                if (dut_new.gap >= GAP) cov_gap_bad++;
                if (dut_new.filling)    cov_filling++;
                if (!dut_new.enable)    cov_disable++;
            end
            ppop_cycles++;

            // output must not move while held
            if (stalled && (!mv_n || {ms_n, me_n, md_n} !== held))
                fail("AXI-Stream output changed while m_valid && !m_ready");
            stalled <= mv_n && !ready;
            held    <= {ms_n, me_n, md_n};
            if (metaval_n && mready) metas_seen++;
        end
    end

    // ------------------------------------------------------------------------
    // stimulus
    // ------------------------------------------------------------------------
    task automatic raster(input int gap_pct, input int hold_cyc);
        int y, x, r;
        begin
            for (y = 0; y < height; y = y + 1) begin
                for (x = 0; x < width; x = x + 4) begin
                    @(negedge sc);
                    sv = 1; ss = (x == 0 && y == 0); se = (x == width-4);
                    sd = {4{24'h123456}};
                    // There is deliberately no source READY to wait for: an
                    // admitted frame must finish.
                    r = nrand();
                    if ((r % 100) < gap_pct) begin sv = 0; ss = 0; se = 0; end
                end
            end
            @(negedge sc); sv = 0; ss = 0; se = 0;
            repeat (hold_cyc) @(negedge sc);
        end
    endtask

    task automatic grant(input [15:0] n);
        begin @(negedge mc); credit_add = n; credit_valid = 1;
              @(negedge mc); credit_valid = 0; end
    endtask

    // background sink-side randomiser - the ONLY writer of ready / mready
    bit sink_off = 0;
    initial begin
        forever begin
            @(negedge mc);
            if (sink_off) begin ready = 1'b1; mready = 1'b1; end
            else begin
                ready  = (nrand() % 100) >= 25;      // 25 % m_ready stalls
                mready = (nrand() % 100) >= 20;      // 20 % meta_ready stalls
            end
        end
    end

    // ------------------------------------------------------------------------
    // 2. isolated predicate-state equivalence fixture (see header note)
    // ------------------------------------------------------------------------
    function automatic [31:0] fid_a(input int i);
        case (i)
            0,1:     fid_a = 32'h0000_0000;
            2,10:    fid_a = 32'hFFFF_FFFF;
            3,13:    fid_a = 32'h8000_0000;
            4,12:    fid_a = 32'h7FFF_FFFF;
            5:       fid_a = 32'h0000_0001;
            6:       fid_a = 32'hFFFF_FFFE;
            7:       fid_a = 32'h8000_0001;
            8:       fid_a = 32'h0000_0000;
            default: fid_a = 32'h1234_5678;
        endcase
    endfunction

    function automatic [31:0] fid_b(input int i);
        case (i)
            0,2,3,11: fid_b = 32'h0000_0000;
            1,5,10:   fid_b = 32'hFFFF_FFFF;
            4:        fid_b = 32'h7FFF_FFFF;
            6,7,8,12: fid_b = 32'h0000_0001;
            default:  fid_b = 32'h1234_5678;
        endcase
    endfunction

    function automatic [21:0] idx_v(input int i);
        case (i)
            0:       idx_v = 22'h000000;
            1:       idx_v = 22'h000001;
            2:       idx_v = 22'h3FFFFE;
            3:       idx_v = 22'h3FFFFF;   // 22-bit MSB boundary
            4:       idx_v = 22'h200000;
            default: idx_v = 22'h1FFFFF;
        endcase
    endfunction

    function automatic [31:0] gap_v(input int i);
        case (i)
            0:       gap_v = 32'd0;
            1:       gap_v = GAP - 1;
            2:       gap_v = GAP;
            default: gap_v = GAP + i;
        endcase
    endfunction

    int fx_n = 0, fx_bad = 0;

    task automatic predicate_fixture;
        for (int ia = 0; ia < 14; ia = ia + 1)
          for (int ib = 0; ib < 6; ib = ib + 1)
            for (int ie = 0; ie < 6; ie = ie + 1)
              for (int ig = 0; ig < 6; ig = ig + 1)
                for (int iv = 0; iv < 16; iv = iv + 1) begin
                    bit        pval, filling, enable_, sreset;
                    bit [31:0] pixel_id, frame_id, cur_src, id_delta, gap;
                    bit [21:0] pixel_index, expected;
                    bit        stale, real_word, future_word, src_adv;
                    bit        force_fill_ref, old_term, new_term;
                    pval        = iv[0];
                    filling     = iv[1];
                    enable_     = iv[2];
                    sreset      = iv[3];
                    pixel_id    = fid_a(ia);
                    frame_id    = fid_b(ia);
                    pixel_index = idx_v(ib);
                    expected    = idx_v(ie);
                    gap         = gap_v(ig);
                    cur_src     = frame_id + ((iv[0] ^ ib[1]) ? 32'd1 : 32'd0);
                    id_delta    = $signed(pixel_id - frame_id);
                    stale       = pval && ((id_delta < 0) ||
                                 ((id_delta == 0) && (pixel_index < expected)));
                    real_word   = pval && (id_delta == 0) && (pixel_index == expected);
                    future_word = pval && ((id_delta > 0) ||
                                 ((id_delta == 0) && (pixel_index > expected)));
                    src_adv     = $signed(cur_src - frame_id) > 0;
                    // ORIGINAL S expression, verbatim
                    force_fill_ref = filling || !enable_ || sreset || future_word ||
                                     (gap >= GAP) || (!pval && src_adv);
                    old_term = real_word && !force_fill_ref;
                    // NEW expression, verbatim
                    new_term = real_word && !filling && enable_ && !sreset && (gap < GAP);
                    fx_n++;
                    if (old_term !== new_term) begin
                        fx_bad++;
                        if (fx_bad <= 10)
                            $display("FAIL: predicate mismatch pid=%h fid=%h idx=%0d exp=%0d pv=%b fill=%b en=%b srst=%b gap=%0d -> old=%b new=%b",
                                     pixel_id, frame_id, pixel_index, expected, pval,
                                     filling, enable_, sreset, gap, old_term, new_term);
                    end
                    if ($countones({stale, real_word, future_word}) > 1) begin
                        fx_bad++;
                        $display("FAIL: stale/real/future not exclusive pid=%h fid=%h idx=%0d exp=%0d",
                                 pixel_id, frame_id, pixel_index, expected);
                    end
                end
    endtask

    // ------------------------------------------------------------------------
    initial begin
        predicate_fixture();
        checks++;
        ck(fx_bad == 0, $sformatf("predicate fixture: %0d of %0d states disagree", fx_bad, fx_n));
        ck(fx_n >= 4000, $sformatf("predicate fixture covered only %0d states", fx_n));
        $display("C predicate fixture: states=%0d disagreements=%0d (ID wrap across 0, half-range 0x80000000, 22-bit index corners)",
                 fx_n, fx_bad);

        #300;
        sn = 1; mn = 1;
        grant(8); en = 1;
        repeat (60) @(negedge mc);

        // back-to-back clean frames, no source gaps
        for (int f = 0; f < 3; f = f + 1) begin raster(0, 40); grant(4); end

        // frames with source gaps -> exercises the gap threshold and filler
        for (int f = 0; f < 4; f = f + 1) begin raster(35, 120); grant(4); end

        // long stall: the source keeps advancing while the sink is stopped
        sink_off = 1;                             // single writer: ready/mready = 1
        repeat (150) @(negedge mc);
        sink_off = 0;
        repeat (200) @(negedge mc);
        grant(6);

        // PRECONDITION for the `enable` control term: the source keeps streaming
        // into an ACTIVE frame while enable drops (no credit_clear), so
        // real_word && !filling && !enable && !source_reset && gap<GAP is reached.
        fork
            raster(0, 0);
            begin repeat (30) @(negedge mc); en = 0;
                  repeat (40) @(negedge mc); en = 1; end
        join
        repeat (200) @(negedge mc);
        grant(6);

        // PRECONDITION for the `gap` control term: the source stops for far longer
        // than GAP_CYCLES while a frame is active, then resumes.
        fork
            begin
                repeat (24) @(negedge sc); sv = 0; ss = 0; se = 0;
                repeat (400) @(negedge sc);          // gap >> GAP_CYCLES = 64
                raster(0, 0);
            end
            begin repeat (60) @(negedge mc); en = 0;
                  repeat (30) @(negedge mc); en = 1; end
        join
        repeat (250) @(negedge mc);
        grant(6);

        // credit_clear + enable drop mid-frame, then re-grant
        fork
            raster(20, 0);
            begin repeat (40) @(negedge mc); en = 0; credit_clear = 1;
                  @(negedge mc); credit_clear = 0;
                  repeat (30) @(negedge mc); en = 1; grant(4); end
        join
        repeat (200) @(negedge mc);

        // source reset in the middle of a frame (filler + flag bits 3/8)
        fork
            raster(5, 0);
            begin repeat (25) @(negedge mc); sn = 0; repeat (4) @(negedge sc);
                  sn = 1; end
        join
        repeat (200) @(negedge mc);
        grant(4);

        // geometry change between frames, then a frame with no credits at all
        width = 128; height = 64; raster(15, 150);
        credit_clear = 1; @(negedge mc); credit_clear = 0;
        raster(0, 150);                       // must be refused identically
        width = 64; height = 64; grant(6);
        for (int f = 0; f < 3; f = f + 1) raster(50, 150);

        // --------------------------------------------------------------------
        $display("C differential: cycles=%0d ppop-compare cycles=%0d ppop divergences=%0d | real_word cycles=%0d use_real cycles=%0d use_real divergences=%0d contract-term divergences=%0d | metas=%0d",
                 cmp_cycles, ppop_cycles, ppop_diff, real_word_cycles, use_real_cycles,
                 use_real_diff, contract_diff, metas_seen);
        $display("C control-term coverage while real_word: !filling=%0d filling=%0d enable=%0d !enable=%0d !source_reset=%0d gap<GAP=%0d gap>=GAP=%0d",
                 cov_not_filling, cov_filling, cov_enable, cov_disable, cov_no_sreset,
                 cov_gap_ok, cov_gap_bad);
        ck(contract_diff == 0,
           $sformatf("use_real does not match its declared contract %0d times", contract_diff));
        // Coverage REPORT (not a pass/fail gate): which control terms were reached
        // while real_word held.  A term with 0 coverage means the differential
        // harness cannot observe its removal, which is recorded in the report
        // instead of being hidden or claimed equivalent.
        if (cov_filling == 0 || cov_disable == 0 || cov_gap_bad == 0)
            $display("NOTE: use_real control term(s) not reached while real_word (filling=%0d !enable=%0d gap>=GAP=%0d): a mutant that drops only those terms is NOT observable through this interface stimulus",
                     cov_filling, cov_disable, cov_gap_bad);
        ck(cmp_cycles > 5000, $sformatf("only %0d comparison cycles", cmp_cycles));
        ck(ppop_diff == 0,    $sformatf("ppop diverged %0d times", ppop_diff));
        ck(use_real_diff == 0, $sformatf("use_real differed from real_word&&!force_fill %0d times", use_real_diff));
        ck(real_word_cycles > 100,
           $sformatf("only %0d real_word cycles: the rewritten term was barely exercised", real_word_cycles));
        ck(metas_seen > 0, "no frame metadata was ever produced");

        $display("== sc7f0_frame_tap_diff: checks=%0d errors=%0d started=%0d dropped=%0d ==",
                 checks, errors, started_n, drops_n);
        if (errors == 0) begin
            $display("FRAME_TAP_DIFF_PASS");
            $finish;
        end else begin
            $display("FRAME_TAP_DIFF_FAIL errors=%0d", errors);
            $fatal(1, "frame tap differential failed");
        end
    end

    initial begin
        #200_000_000;
        $display("FRAME_TAP_DIFF_FAIL (watchdog)");
        $fatal(1, "watchdog");
    end
endmodule
