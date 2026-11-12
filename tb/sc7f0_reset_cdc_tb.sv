`timescale 1ns / 1ps
// ============================================================================
// Local simulation gate for the reset-domain rework (rtl/sc7f0_reset_cdc.v).
//
// Run:  vivado -mode batch -notrace -nojournal -source scripts/sim_sc7f0_reset_cdc.tcl
// (xsim, so the REAL xpm_cdc / xpm_fifo models are elaborated)
//
// WHAT THIS PROVES
//   S1 release order: the combined reset releases only on a destination clock
//      edge, for both release orders and for a simultaneous release.
//   S2 near-simultaneous cross event (one source re-asserts around the moment the
//      other releases): the combined reset never releases while a source is
//      asserted, and - the important half - the pre-fix structure is shown by a
//      negative control to produce a runt on the asynchronous preset, so the
//      positive checks are not vacuous.
//   S3 a single-cycle cross-domain CSR event becomes a reset level of provable
//      minimum width, with a visible "captured" pending flag (never lost).
//   S3b the event clock stops in the middle of the hold: the level stays asserted,
//      the hold resumes on restart, the request is neither lost nor replayed, and
//      a later event still gets its full width.
//   S3c the hard reset of the event source arrives while a hold is pending: the
//      level releases a defined number of cycles after the hard reset instead of
//      deadlocking the domain it resets (the DMA global-flush case).
//   S4 destination clock stopped while asserting: reset is held, no release
//      happens without clock edges, and it releases correctly on peer restart.
//   S5 peer restart of one source only recovers cleanly.
//   S6 an async FIFO flush (write side or read side) inhibits VALID immediately
//      and never replays a word written before the reset.
//   S7 the consumer domain restarts while its clock is stopped: after the restart
//      the old word is still gone and new data is accepted.
//   Consumer bank check: flops clocked by dest with the combined reset as their
//      async preset leave reset together (no residual half-reset) and keep taking
//      new data - so a passing run is not the vacuous "never left reset" case.
//
// WHAT IT CANNOT PROVE (stated so the result is not over-claimed)
//   Simulators do not model sub-window resolution, recovery/removal violation or
//   partial capture across the copies of a reset net, so this cannot prove the
//   absence of metastability.  The asynchronous assert path, the minimum pulse
//   width requirement and the placement argument are reviewed structurally; the
//   numbers below are behavioural evidence about the described synchronizer
//   chains only.  Two things in this TB are deliberately instrumentation rather
//   than proof, and are reported as evidence lines so a reviewer can see them:
//     * the pre-fix negative control models the two source clk->q/routing delays
//       as fixed 1 ns / 3 ns delays.  It proves the *shape* of the failure (the
//       OR can momentarily release the preset), not the real delay values, which
//       only post-route timing on the actual reset net can give.
//     * the runt limit (9 ns) and the clock phases are chosen so the race is
//       reachable; a real design can land on a worse coincidence, which is why
//       sc7f0_reset_sync keeps the extra re-synchronizer stage instead of relying
//       on the stimulus never lining up.
// ============================================================================

module sc7f0_reset_cdc_tb;

    localparam real RUNT_LIMIT = 9.0;   // shorter than one 10 ns dest clock period

    reg dest = 0, dest_run = 1'b1;
    always begin #5.0; if (dest_run) dest = ~dest; end

    time dest_last_posedge = 0;
    always @(posedge dest) dest_last_posedge = $time;

    integer failures = 0;
    integer checks = 0;
    task automatic chk(input integer cond, input [8*96:1] name);
        begin
            checks = checks + 1;
            if (!cond) begin
                failures = failures + 1;
                $display("RESET_CDC_CHECK_FAIL: %s", name);
            end else begin
                $display("RESET_CDC_CHECK_PASS: %s", name);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // A: two independent asynchronous sources combined by the fixed structure.
    // ------------------------------------------------------------------------
    reg src_a_n = 1'b0, src_b_n = 1'b0;
    wire comb_rst_n;
    sc7f0_reset_sync #(.SOURCES(2), .DEST_SYNC_FF(4)) u_comb (
        .dest_clk   (dest),
        .src_rst_n  ({src_b_n, src_a_n}),
        .dest_rst_n (comb_rst_n)
    );
    // Hierarchical probe of the gate inside sc7f0_reset_sync: this is the node
    // that would carry a runt release if the AND of the per-source synchronizer
    // outputs could momentarily release.
    wire fixed_combined = u_comb.combined_n;

    integer releases = 0;
    integer ignored_time_zero = 0;
    integer bad_release_off_edge = 0;
    integer bad_release_while_asserted = 0;
    // The XPM chains power up with dest_arst at its *released* value and are then
    // asynchronously cleared in the same time step, so the first output edge the
    // simulator reports is a spurious rise at time 0 while both sources are still
    // asserted.  It is not a release, and counting it would both inflate the
    // counter and mislabel the reset as "released while asserted".  A release is
    // only meaningful once the output has actually been seen asserted.
    reg saw_asserted = 1'b0;
    always @(negedge comb_rst_n) saw_asserted = 1'b1;
    always @(posedge comb_rst_n) begin
        if ($time == 0 || !saw_asserted) begin
            // Pre-assertion artifact of the XPM power-up value, not a release.
            ignored_time_zero = ignored_time_zero + 1;
            $display("IGNORED reset-output rise at %0t (pre-assertion, sources a=%b b=%b)",
                     $time, src_a_n, src_b_n);
        end else begin
            releases = releases + 1;
            saw_asserted = 1'b0;
            if (($time - dest_last_posedge) > 0.2) begin
                bad_release_off_edge = bad_release_off_edge + 1;
                $display("BAD release off destination edge at %0t (last posedge %0t)",
                         $time, dest_last_posedge);
            end
            if (!src_a_n || !src_b_n) begin
                bad_release_while_asserted = bad_release_while_asserted + 1;
                $display("BAD release while a source is asserted a=%b b=%b at %0t",
                         src_a_n, src_b_n, $time);
            end
        end
    end

    // Consumer bank: flops in dest_clk that use comb_rst_n as their asynchronous
    // preset.  A premature (runt) release of that preset net is exactly what makes
    // *some* of these flops leave reset while their neighbours stay cleared, so
    // this is the direct "no half-reset / new data really is accepted" check that
    // a mere "no runt seen on one node" probe cannot give.
    //
    // A zero-delay simulator cannot order "the async preset releases" against
    // "the same dest_clk edge" when both happen in one time step, so the first
    // consumer update after a release is indeterminate in simulation (it is the
    // recovery-time case, which real silicon resolves by timing closure and which
    // only a gate-level/SDF run can show).  cons_grace skips exactly that first
    // negedge; from the second cycle on, a flop still sitting in reset is a real
    // residual half-reset, and a bank that keeps updating is proof the destination
    // really left reset rather than being filtered into never leaving it.
    reg [7:0] cons = 8'h00;
    always @(posedge dest or negedge comb_rst_n) begin
        if (!comb_rst_n) cons <= 8'h00;
        else           cons <= 8'hFF;
    end
    integer cons_grace = 0;
    integer cons_half_reset = 0;
    integer cons_moving = 0;
    always @(posedge comb_rst_n) cons_grace = 2;
    always @(negedge dest) begin
        if (cons_grace > 0) cons_grace = cons_grace - 1;
        else if (comb_rst_n === 1'b1) begin
            if (cons !== 8'hFF) begin
                cons_half_reset = cons_half_reset + 1;
                $display("BAD half-reset: preset released but consumer=%b at %0t", cons, $time);
            end
            cons_moving = cons_moving + 1;
        end
    end

    // ------------------------------------------------------------------------
    // A': the pre-fix wiring.  Two source flops in unrelated domains drive the
    // old `!a || !b` expression, with different clk->q delays standing in for
    // different placement/routing.  This is the negative control: if the runt
    // detectors below could not see this, every positive check would be vacuous.
    // ------------------------------------------------------------------------
    reg a_q = 1'b0, b_q = 1'b1;        // 1 = released
    // The two delay models are driven from an `always @(a_q)` block, which does not
    // fire for a declaration initial value.  Without explicit initialisation a_d/b_d
    // stayed X for the whole run, old_arst stayed X, and the runt detector could
    // never see the pre-fix race at all - which is how this negative control
    // silently reported 0 runts and made every positive runt check vacuous.
    reg a_d = 1'b0, b_d = 1'b1;
    always @(a_q) a_d <= #1.0 a_q;     // clk->q stand-in, placement A
    always @(b_q) b_d <= #3.0 b_q;     // clk->q stand-in, placement B
    wire old_arst = (~a_d) | (~b_d);   // exactly the old src_arst expression

    integer old_runts = 0;
    integer comb_runts = 0;
    real old_low_since = -1.0;
    real comb_low_since = -1.0;

    always @(old_arst) begin
        if (old_arst === 1'b0) old_low_since = $realtime;
        else begin
            if (old_low_since >= 0.0 && (($realtime - old_low_since) < RUNT_LIMIT)) begin
                old_runts = old_runts + 1;
                $display("RUNT on the pre-fix src_arst: released %0.3f ns at %0t",
                         ($realtime - old_low_since), $time);
            end
            old_low_since = -1.0;
        end
    end

    always @(fixed_combined) begin
        if (fixed_combined === 1'b0) comb_low_since = $realtime;
        else begin
            if (comb_low_since >= 0.0 && (($realtime - comb_low_since) < RUNT_LIMIT)) begin
                comb_runts = comb_runts + 1;
                $display("RUNT on the fixed combined node: released %0.3f ns at %0t",
                         ($realtime - comb_low_since), $time);
            end
            comb_low_since = -1.0;
        end
    end

    // ------------------------------------------------------------------------
    // B: single-cycle event -> provably wide reset level.
    // ------------------------------------------------------------------------
    reg evt = 1'b0, evt_rst_n = 1'b0;
    wire evt_rst_out, evt_pending;
    sc7f0_event_reset #(.WIDTH(1), .HOLD_CYCLES(32)) u_evt (
        .evt_clk  (dest),
        .evt_rst_n(evt_rst_n),
        .evt      (evt),
        .rst_n    (evt_rst_out),
        .pending  (evt_pending)
    );
    integer evt_low_cycles = 0;
    always @(posedge dest) if (!evt_rst_out) evt_low_cycles = evt_low_cycles + 1;

    // ------------------------------------------------------------------------
    // C: FIFO flush semantics (150 MHz write, 200 MHz read, independent resets).
    // ------------------------------------------------------------------------
    reg wc = 0, rc = 0, wn = 0, rn = 0, wv = 0;
    reg wc_run = 1'b1, rc_run = 1'b1;
    reg [31:0] wd = 0;
    wire ready, valid;
    wire [31:0] data;
    always begin #3.333 if (wc_run) wc = ~wc; end
    always begin #5.0   if (rc_run) rc = ~rc;  end
    sc7f0_dp_fifo #(.WIDTH(32)) q (
        .wclk(wc), .wrst_n(wn), .wdata(wd), .wvalid(wv), .wready(ready),
        .rclk(rc), .rrst_n(rn), .rdata(data), .rvalid(valid), .rready(1'b0)
    );
    time read_last_posedge = 0;
    integer bad_valid_edge = 0;
    always @(posedge rc) read_last_posedge = $time;
    always @(posedge valid)
        if (($time - read_last_posedge) > 0.2) begin
            bad_valid_edge = bad_valid_edge + 1;
            $display("BAD VALID rose outside the read clock edge at %0t", $time);
        end

    // Probe target for scripts/sim_sc7f0_reset_cdc.tcl.
    reg gate_pass = 1'b0;

    // ------------------------------------------------------------------------
    initial begin
        // ---- S0 ------------------------------------------------------------
        src_a_n = 1'b0; src_b_n = 1'b0;
        #60;
        chk(comb_rst_n === 1'b0, "S0 combined reset asserted while sources asserted");

        // ---- S1a: B releases first, then A ---------------------------------
        src_b_n = 1'b1;
        repeat (14) @(negedge dest);
        chk(comb_rst_n === 1'b0, "S1a still in reset with A asserted");
        src_a_n = 1'b1;
        repeat (20) @(negedge dest);
        chk(comb_rst_n === 1'b1, "S1a released once both sources released");

        // ---- S1b: opposite order ------------------------------------------
        src_a_n = 1'b0; src_b_n = 1'b0;
        repeat (10) @(negedge dest);
        src_b_n = 1'b1;
        repeat (14) @(negedge dest);
        chk(comb_rst_n === 1'b0, "S1b still in reset with A asserted");
        src_a_n = 1'b1;
        repeat (20) @(negedge dest);
        chk(comb_rst_n === 1'b1, "S1b released in the opposite order");

        // ---- S1c: simultaneous release ------------------------------------
        src_a_n = 1'b0; src_b_n = 1'b0;
        repeat (10) @(negedge dest);
        src_a_n = 1'b1; src_b_n = 1'b1;
        repeat (20) @(negedge dest);
        chk(comb_rst_n === 1'b1, "S1c released with both sources released together");
        chk(releases >= 3, "S1 at least three clean releases observed");
        chk(bad_release_off_edge == 0, "S1 every release on a destination clock edge");
        chk(bad_release_while_asserted == 0,
            "S1 no release while a source is still asserted");
        // The over-clam behaviour to watch for is a filter so deep that the
        // destination never actually leaves reset; these two checks are the
        // counter-weight: the consumer bank really does leave reset, all eight
        // flops of it, and really does keep updating afterwards.
        chk(cons_half_reset == 0, "S1 consumer bank is never left half-reset");
        chk(cons_moving > 0, "S1 consumer accepts new data once released");

        // ---- S2: one source re-asserts around the other one's release -----
        src_b_n = 1'b0;
        @(negedge dest);
        src_a_n = 1'b1;                     // A already released: stays released
        repeat (30) @(negedge dest);
        chk(comb_rst_n === 1'b0,
            "S2 combined reset stays asserted while B is asserted");
        chk(bad_release_while_asserted == 0,
            "S2 new structure never releases while a source is asserted");

        // Negative control on the pre-fix expression, the same kind of race:
        // A releases on a destination edge while B asserts 1.2 ns later.  The
        // pre-state (A asserted, B released) is established for far longer than
        // RUNT_LIMIT first, so the only short window that can be attributed is the
        // one the race itself opens on the asynchronous preset.
        a_q = 1'b0; b_q = 1'b1;
        #40;                                   // 1 ns / 3 ns delay models settled
        chk(old_runts == 0,
            "S2 negative control starts from a clean, long asserted window");
        fork
            begin @(posedge dest); a_q = 1'b1; end             // A releases
            begin @(posedge dest); #1.2; b_q = 1'b0; end       // B asserts just after
        join
        repeat (16) @(posedge dest);
        chk(old_runts > 0,
            "S2 negative control detects the runt of the pre-synchronizer OR");
        chk(comb_runts == 0,
            "S2 no runt on the combined node of the fixed structure");

        // ---- S3: one-cycle event becomes a wide level ---------------------
        evt_rst_n = 1'b1;
        repeat (10) @(negedge dest);
        evt_low_cycles = 0;
        @(negedge dest); evt = 1'b1;
        @(negedge dest); evt = 1'b0;                      // exactly one cycle
        chk(evt_pending === 1'b1, "S3 event captured (pending visible)");
        chk(evt_rst_out === 1'b0, "S3 destination held in reset during the hold");
        wait (evt_rst_out === 1'b1);
        chk(evt_low_cycles >= 32,
            "S3 reset level is wide enough for any slower destination clock");
        chk(evt_pending === 1'b0, "S3 pending cleared once the hold finished");

        // ---- S3b: the event/clock stops in the middle of the hold -----------
        // A reset request that was captured must not be lost and must not be
        // replayed: the hold simply resumes, and the next event still gets its
        // full width.
        @(negedge dest); evt = 1'b1;
        @(negedge dest); evt = 1'b0;
        repeat (4) @(negedge dest);            // part-way through the hold window
        dest_run = 1'b0;
        #3000;
        chk(evt_rst_out === 1'b0, "S3b hold survives a stopped clock (stays asserted)");
        chk(evt_pending === 1'b1, "S3b pending stays visible while the clock is stopped");
        dest_run = 1'b1;
        wait (evt_rst_out === 1'b1);
        chk(evt_pending === 1'b0, "S3b pending clears after restart (event not lost)");
        evt_low_cycles = 0;
        @(negedge dest); evt = 1'b1;
        @(negedge dest); evt = 1'b0;
        chk(evt_pending === 1'b1, "S3b a later event is still honoured");
        wait (evt_rst_out === 1'b1);
        chk(evt_low_cycles >= 32, "S3b the later event keeps the full hold width");

        // ---- S3c: hard reset arrives while a hold is pending ----------------
        // This is the DMA case: the flush level is one of the sources of the
        // domain reset while the hard reset is the event module's own evt_rst_n.
        // If the hold counter could not be cleared by evt_rst_n, the domain would
        // sit in reset forever (deadlock).  It must release a defined number of
        // cycles after the hard reset goes away, without re-asserting.
        @(negedge dest); evt = 1'b1;
        @(negedge dest); evt = 1'b0;
        repeat (4) @(negedge dest);
        evt_rst_n = 1'b0;                      // hard reset arrives mid-hold
        repeat (6) @(negedge dest);
        chk(evt_rst_out === 1'b0, "S3c flush level is held during the hard reset");
        evt_rst_n = 1'b1;                      // hard reset released
        repeat (6) @(negedge dest);
        chk(evt_rst_out === 1'b1, "S3c no deadlock: level releases after hard reset");
        chk(evt_pending === 1'b0, "S3c pending does not stick after the hard reset");

        // ---- S4: destination clock stopped while asserting ----------------
        #1;
        src_a_n = 1'b0; src_b_n = 1'b0;
        repeat (6) @(negedge dest);
        dest_run = 1'b0;                                  // clock stops
        #4000;
        chk(comb_rst_n === 1'b0,
            "S4 reset held asserted while the destination clock is stopped");
        src_a_n = 1'b1; src_b_n = 1'b1;                   // peer restart request
        #4000;
        chk(comb_rst_n === 1'b0, "S4 still held with no destination clock edges");
        dest_run = 1'b1;                                  // clock restarts
        repeat (25) @(negedge dest);
        chk(comb_rst_n === 1'b1, "S4 releases correctly once the clock runs again");

        // ---- S5: one source restarts on its own ---------------------------
        @(negedge dest); src_a_n = 1'b0;
        repeat (6) @(negedge dest);
        @(negedge dest); src_a_n = 1'b1;
        repeat (20) @(negedge dest);
        chk(comb_rst_n === 1'b1, "S5 peer restart of one source recovers");
        chk(bad_release_off_edge == 0, "S5 every release still on a clock edge");

        // ---- S6: FIFO must not replay pre-reset data ----------------------
        wn = 1'b1; rn = 1'b1;
        repeat (60) @(posedge rc);
        @(negedge wc); wd = 32'hA5A5_5A5A; wv = 1'b1;
        do @(posedge wc); while (!ready);
        @(negedge wc); wv = 1'b0;
        wait (valid === 1'b1); #1;
        chk(data === 32'hA5A5_5A5A, "S6 FIFO delivered the written word");

        rn = 1'b0; #1;
        chk(valid === 1'b0, "S6 read-side reset inhibits VALID immediately");
        // XPM contract: RST must be held for at least 3 wr_clk and 3 rd_clk
        // cycles.  A shorter pulse would be testing undefined behaviour rather
        // than the flush, so the assertion is widened before the release.
        #60;
        rn = 1'b1; #1;
        chk(valid === 1'b0, "S6 asynchronous release does not leak VALID");
        repeat (80) @(posedge rc); #1;
        chk(valid === 1'b0, "S6 pre-reset word did not survive the flush");

        @(negedge wc); wd = 32'h1357_9BDF; wv = 1'b1;
        do @(posedge wc); while (!ready);
        @(negedge wc); wv = 1'b0;
        wait (valid === 1'b1); #1;
        chk(data === 32'h1357_9BDF, "S6 FIFO reusable after the flush");

        wn = 1'b0; #1;
        chk(valid === 1'b0, "S6 write-side flush also inhibits VALID");
        #60;
        wn = 1'b1; rn = 1'b1;
        repeat (80) @(posedge rc); #1;
        chk(valid === 1'b0, "S6 no stale word after a write-side flush either");

        // ---- S7: consumer domain restarts while its clock is stopped --------
        wn = 1'b1; rn = 1'b1;
        repeat (60) @(posedge rc);
        @(negedge wc); wd = 32'hDEAD_BEEF; wv = 1'b1;
        do @(posedge wc); while (!ready);
        @(negedge wc); wv = 1'b0;
        wait (valid === 1'b1); #1;
        chk(data === 32'hDEAD_BEEF, "S7 word visible before the peer restart");
        rc_run = 1'b0;                         // consumer clock stops
        #20;
        rn = 1'b0;                             // its reset asserts while stopped
        #60;
        rn = 1'b1;
        #3000;                                 // stays stopped
        chk(valid === 1'b0, "S7 VALID stays down while the read clock is stopped");
        rc_run = 1'b1;                         // peer restart
        repeat (120) @(posedge rc); #1;
        chk(valid === 1'b0, "S7 pre-restart word is not replayed after peer restart");
        @(negedge wc); wd = 32'h0F1E_2D3C; wv = 1'b1;
        do @(posedge wc); while (!ready);
        @(negedge wc); wv = 1'b0;
        wait (valid === 1'b1); #1;
        chk(data === 32'h0F1E_2D3C, "S7 FIFO accepts new data after the peer restart");
        rc_run = 1'b1; wc_run = 1'b1;

        // ---- verdict ------------------------------------------------------
        $display("RESET_CDC_TB_SUMMARY checks=%0d failures=%0d releases=%0d bad_valid_edge=%0d",
                 checks, failures, releases, bad_valid_edge);
        $display("RESET_CDC_TB_EVIDENCE fixed_structure_runts=%0d prefix_wiring_runts=%0d",
                 comb_runts, old_runts);
        $display("RESET_CDC_TB_EVIDENCE2 ignored_time_zero=%0d cons_half_reset=%0d cons_moving=%0d",
                 ignored_time_zero, cons_half_reset, cons_moving);
        if (failures == 0 && comb_runts == 0 && old_runts > 0 &&
            bad_release_off_edge == 0 && bad_release_while_asserted == 0 &&
            cons_half_reset == 0 && cons_moving > 0 && releases >= 3 &&
            bad_valid_edge == 0) begin
            $display("RESET_CDC_SIM_GATE_PASS");
            gate_pass = 1'b1;
        end else begin
            $display("RESET_CDC_SIM_GATE_FAIL");
            gate_pass = 1'b0;
        end
        #1;
        $finish;
    end

    initial begin
        #3000000;
        $display("RESET_CDC_TB_FAIL global timeout");
        $fatal(1, "RESET_CDC_TB_FAIL global timeout");
    end
endmodule
