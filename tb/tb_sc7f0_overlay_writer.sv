`timescale 1ns / 1ps
// ============================================================================
// tb_sc7f0_overlay_writer - regression for rtl/sc7f0_overlay_writer.v
//
//   W1  geometry the writer must refuse (frame_bytes not 256 B aligned)
//   W2  one whole frame: AW address, awlen, burst shape, every W byte in order,
//       frames_done / bytes_written / write_slot / irq all exact
//   W3  ordered config snapshot: a second config change issued one cycle after
//       the first must arrive too (no lost update, no torn bundle), proved by
//       where the NEXT frame lands in PS DDR
//   W4  slot protection: a frame aimed at a slot Reader-B still owns is stalled,
//       not written
//   W5  release through ov_consume re-opens the slot and auto-advance moves on
//   W6  over-long stream is refused past the frame end
//   W7  reset in the middle of a frame, then a clean frame
//   W8  geometry rewritten while a frame is in flight: the frame keeps its own
//       address, length and slot; the new geometry only takes effect next time
//   W9  STREAMING, POSITIVE: one frame 4x the payload FIFO (64 KiB vs 16 KiB).
//       The master must open its AXI job and be writing buffered bursts LONG
//       BEFORE the last input beat, must deliver every byte in order, must
//       publish the slot and pulse the IRQ only after the final B, and must
//       never accumulate more accepted-but-undelivered beats than the FIFO.
//       The rejected r10 candidate refused this geometry AND buffered whole
//       frames, and fails here either way.  4K60 RGBA8888 is 33,177,600 B,
//       2025x the FIFO (33,177,600 / 16,384 = 2025), so this is the
//       required-function case, not a stretch.
//   W12 ABORT: a plane is discarded at 40 % of a frame while AW is stalled, W is
//       stalled and Bs are pending, with gaps on the source.  The already
//       committed AXI work may finish (AXI forbids withdrawing a held VALID), but
//       nothing further may be accepted for the dead plane, and nothing may be
//       published: no ready bit, no IRQ, no frames_done, no bytes credited to a
//       frame that will never complete.  After the abort is ACKED the next clean
//       frame must be byte exact.
//   W13 a tuser (new-transfer) beat inside a live frame is REFUSED and latched,
//       never spliced into the open slot
//   W14 a stale B response that survives a reset is detected as unsolicited,
//       poisons the epoch (no publication at all) and only the physical reset
//       barrier releases it
//   W10 the REQUIRED frame: 3840x2160 RGBA8888 = 33,177,600 B, 15,360 B line
//       pitch, 2,073,600 beats, 129,600 bursts; byte-exact against a reference
//       captured on accepted tvalid && tready, with address-bound, 4 KiB,
//       strobe, no-zero-beat and exact count checks.  One frame, one slot
//       publication, one IRQ.  (skipped with +NO4K)
//   W11 forced W and AW stalls (AXI outputs must stay stable) plus a SLVERR /
//       DECERR BRESP, which invalidates the WHOLE frame: the slot must NOT be
//       published, no IRQ, no frames_done, the error frame is counted instead,
//       and the next clean frame publishes normally.
//   W17 (M6 gap B) reset with an ACCEPTED AW and only PARTIAL W delivered: WVALID
//       is held with WREADY low when the logical reset arrives.  The slave keeps
//       the debt, the held payload/strb/WLAST must not move across the reset or a
//       4 us dead payload clock, the slave must then be given EXACTLY the beats it
//       owed (byte exact from the retained queue), nothing may be published, and
//       the next frame must be byte exact.
//   W18 (M6 gap C) a PCIe-ONLY epoch reset with mem_rst_n HIGH and the slave still
//       withholding the old Bs, which then arrive after a new frame has been
//       offered: the epoch boundary may not clear the retained ledger (no false
//       quiesce), may not create or credit a new job, and may not announce any
//       completion of its own; the old answers pay their own retained ledger and
//       the interface is usable afterwards.
//   W19 (M10) the completion record for EVERY published frame over four slots with
//       auto-advance (0,1,2,3,0,1, so the 1->2 and 3->0 two-bit transitions are
//       covered), the expected slot taken from the AXI address the bursts really
//       went to, plus the ready-bit association, an asynchronous phase variation,
//       a stopped CSR clock with the record parked, a PCIe-shell reset while the
//       memory side stays live (no phantom IRQ), and a faulted frame that must not
//       raise a record at all.
//
// White-box signals are only observed (job open, stall reason) - every verdict
// is taken on ports and bus traffic.  Nothing is sampled out, no prefix is
// skipped and no checksum stands in for the bytes.
// ============================================================================
module tb_sc7f0_overlay_writer;
    localparam integer DW = 128, AW = 49, SLOTS = 4;
    localparam integer FDEPTH = 1024;             // payload burst buffer

    logic clk = 1'b0, rst_n = 1'b0;         // 125 MHz CSR shell
    // The writer is driven by THREE physical resets, and the card can assert them in
    // any of the combinations that its own reset tree produces:
    //   .rst_n       = dma_rst_n = sc7f0_reset_sync({..., reg_dma_ctrl[1],
    //                    global_reset_hold_n, ..., rst_n})  custom_pcie_dma_top.v:561-564
    //   .epoch_rst_n = the top-level rst_n itself            custom_pcie_dma_top.v:1876
    //   .mem_rst_n   = the video/system reset                zu4ev_pcie_card_top.v:249-253
    // `dma_soft_rst` models the split the card produces and an earlier revision of this
    // fixture could not express at all: DMA_CTRL[1] or the BAR0 global flush drops the
    // shell with the epoch and the memory side both HIGH (review MEDIUM-2, exercised by
    // phase W21).  `epoch_hold` is the OPPOSITE split - epoch low with the shell alive -
    // which the reset tree does NOT produce (the top rst_n feeds both), so it is kept
    // only as an isolation knob for the debt record and no phase claims it as card
    // behaviour; the epoch boundary itself is tested physically, by dropping rst_n
    // (W18/W20), because that is what a link event really does.
    logic       epoch_hold = 1'b0;
    logic       dma_soft_rst = 1'b0;
    wire        epoch_rst_n = rst_n & ~epoch_hold;
    wire        dma_rst_n   = rst_n & ~dma_soft_rst;
    logic mem_clk = 1'b0, mem_rst_n = 1'b0; // 300 MHz intake + AXI master
    // Review M6: the payload clock can be stopped while the interface still owes
    // a burst (a source that loses its clock mid-frame is the normal way a video
    // path is reset).  The retirement then simply cannot advance until the clock
    // returns - which is the honest behaviour, and nothing may be published in
    // between.
    bit   clk_run = 1;
    // W19: the CSR clock can be stopped too.  That is the destination of the
    // bundled completion record, so "the record cannot be lost by backpressure or
    // a stopped destination clock" has to be exercised, not asserted in a comment.
    bit   csr_clk_run = 1;
    always #4     clk     = csr_clk_run && ~clk;
    always #(1.6665) mem_clk = clk_run && ~mem_clk;

    // A stopped clock plus a wait on THAT clock is a deadlock, and a unit fixture must
    // not be able to spend the runner's whole timeout on one (measured: a W19 sub-case
    // that held the destination clock and then waited for a posedge of it never
    // returned, and the run had to be classified NO_MARKER).  Both clocks are allowed
    // to stop - that is what W17, W19b and W19-block test - but never for long.  The
    // guard is polled on simulated TIME, so it cannot itself be trapped behind the
    // clock it is watching.
    // W20 (review MEDIUM-1): did the TERMINAL publication cycle ever coincide with a
    // terminal retirement request, and did the intake then take the success branch?
    // frame_err_now originally read only the registered job_invalid, so a reset/abort
    // request arriving on the cycle of the last B lost the race by one clock: ready bit,
    // frames_done and above all the bundled completion record, none of which the discard
    // one clock later can retract.  These counters are read by the fixture so the
    // coincidence cannot silently degrade into "the B came one cycle later", and
    // coin_publish must stay 0 over the whole suite.
    int coin_epoch = 0, coin_fe = 0, coin_abort = 0, coin_publish = 0;
    always @(posedge mem_clk) begin
        if (dut.frame_done)
            $display("FRAMEDONE@%0t: err_now=%b invalid=%b seen=%b epoch=%b fe=%b abort=%b bresp=%b poisoned=%b -> %0s",
                     $time, dut.frame_err_now, dut.job_invalid, dut.frame_err_seen,
                     dut.epoch_inval_needed, dut.fe_retire_needed, dut.abort_evt,
                     dut.m_axi_bresp, dut.debt_poisoned,
                     dut.frame_err_now ? "discard" : "PUBLISH");
        if (dut.frame_done && dut.epoch_inval_needed) coin_epoch++;
        if (dut.frame_done && dut.fe_retire_needed)   coin_fe++;
        if (dut.frame_done && dut.abort_evt)          coin_abort++;
        if (dut.frame_done && !dut.frame_err_now &&
            (dut.epoch_inval_needed || dut.fe_retire_needed || dut.abort_evt)) begin
            coin_publish++;
            $display("PUBLISH@%0t: frame_done taken while a terminal request was active (epoch=%b fe=%b abort=%b)",
                     $time, dut.epoch_inval_needed, dut.fe_retire_needed, dut.abort_evt);
        end
    end

    initial begin : clock_stall_guard
        time t0 = 0;
        forever begin
            #1000;                                   // 1 us poll
            if (!csr_clk_run || !clk_run) begin
                if (t0 == 0) t0 = $time;
                if (($time - t0) > 50000) begin
                    $display("DEADLOCK@%0t: csr_clk_run=%b clk_run=%b stopped since %0t - a wait on that clock cannot return",
                             $time, csr_clk_run, clk_run, t0);
                    $fatal(1, "clock stall guard");
                end
            end else begin
                t0 = 0;
            end
        end
    end

    // config (pcie_clk levels, exactly what sc7f0_rgb_overlay_ctrl drives)
    logic          ov_enable = 1'b0;
    logic [AW-1:0] ov_dst_base = '0;
    logic [31:0]   ov_slot_bytes = 32'd0;
    logic [2:0]    ov_slot_count = 3'd1;
    logic [31:0]   ov_frame_bytes = 32'd0;
    logic          ov_auto_advance = 1'b0;
    logic [1:0]    ov_force_slot = 2'd0;
    logic [3:0]    ov_consume = 4'd0;

    // stream (mem_clk)
    logic [DW-1:0] s_axis_tdata = '0;
    logic          s_axis_tvalid = 1'b0, s_axis_tuser = 1'b0, s_axis_tlast = 1'b0;
    logic          s_axis_tready;

    logic          ov_busy;
    logic [3:0]    ov_slot_ready;
    logic [1:0]    ov_write_slot;
    logic [31:0]   ov_frames_done, ov_bytes_written;
    logic          ov_stall_sticky, ov_over_sticky, ov_axi_err_sticky;
    logic          ov_misalign_sticky, ov_irq_pulse;
    logic          ov_abort = 1'b0;
    logic          ov_abort_busy, ov_abort_sticky, ov_err_frame_sticky;
    logic [31:0]   ov_err_frames;
    logic [7:0]    axis_avail = 8'd0;        // models the ingress read side

    // AXI4 write slave
    logic [AW-1:0] awaddr; logic [7:0] awlen; logic [2:0] awsize; logic [1:0] awburst;
    logic [3:0]    awcache;
    logic          awvalid, awready = 1'b0;
    logic [DW-1:0] wdata;  logic [15:0] wstrb; logic wlast, wvalid, wready = 1'b0;
    logic [1:0]    bresp = 2'b00; logic bvalid = 1'b0;
    logic          bready = 1'b1;

    sc7f0_overlay_writer #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .FIFO_DEPTH(FDEPTH),
                           .MAX_SLOTS(SLOTS)) dut (
        .clk(clk), .rst_n(dma_rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tuser(s_axis_tuser), .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .ov_enable(ov_enable), .ov_dst_base(ov_dst_base),
        .ov_slot_bytes(ov_slot_bytes), .ov_slot_count(ov_slot_count),
        .ov_frame_bytes(ov_frame_bytes), .ov_auto_advance(ov_auto_advance),
        .ov_force_slot(ov_force_slot), .ov_consume(ov_consume),
        .ov_abort(ov_abort),
        .ov_busy(ov_busy), .ov_slot_ready(ov_slot_ready),
        .ov_write_slot(ov_write_slot), .ov_frames_done(ov_frames_done),
        .ov_bytes_written(ov_bytes_written), .ov_stall_sticky(ov_stall_sticky),
        .ov_over_sticky(ov_over_sticky), .ov_axi_err_sticky(ov_axi_err_sticky),
        .ov_misalign_sticky(ov_misalign_sticky), .ov_irq_pulse(ov_irq_pulse),
        .ov_err_frame_sticky(ov_err_frame_sticky),
        .ov_abort_sticky(ov_abort_sticky), .ov_err_frames(ov_err_frames),
        .ov_abort_busy(ov_abort_busy), .s_axis_avail_in(axis_avail),
        .mem_clk(mem_clk), .mem_rst_n(mem_rst_n), .epoch_rst_n(epoch_rst_n),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awcache(awcache),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    int errors = 0, checks = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 60) $display("FAIL @%0t: %s", $time, msg);
    endtask
    task automatic ck(input bit c, input string msg);
        checks++;  if (!c) fail(msg);
    endtask

    // ------------------------------------------------------------------------
    // Reference pattern: byte k of a frame is (k + seed) % 253, so a beat is a
    // pure function of its index in the frame.  The check never trusts the
    // driver - it re-derives what the bus has to be carrying.
    // ------------------------------------------------------------------------
    function automatic logic [DW-1:0] pat_beat(input longint idx, input int seed);
        logic [DW-1:0] v;
        v = '0;
        for (int i = 0; i < 16; i++) v[i*8 +: 8] = 8'((idx*16 + i + seed) % 253);
        return v;
    endfunction

    // ------------------------------------------------------------------------
    // observation state
    // ------------------------------------------------------------------------
    logic [AW-1:0] aw_list [$];
    logic [7:0]    alen_list [$];
    logic [DW-1:0] w_beat_q [$];              // accepted, waiting to be delivered
    logic [7:0]    w_byte_q [$];              // same, byte level (small frames)
    longint        w_beats, accepted_beats, bursts_written, b_count;
    longint        w_beats_all = 0;   // never cleared: mirrors cnt_beats, since reset
    int            last_beats, wlast_count, aw_total;
    logic [1:0]    bresp_seen;
    longint        max_undelivered, dut_occ_max;
    int            b_err_seen = 0;
    logic [7:0]    got_b, exp_b;
    // Hardware capacity of the intake path, not a tuned threshold.  The writer
    // gates its own intake on its own occupancy counter at ACC_LIMIT =
    // FIFO_DEPTH-2, so at most FIFO_DEPTH-1 beats can be stored; one further beat
    // may sit in the accept/pop handshake in the same cycle.  Both halves are
    // checked separately below: the DUT's own counter against FIFO_DEPTH-1, and
    // this queue against FIFO_DEPTH.
    localparam int   HW_CAP = FDEPTH;
    localparam int   OCC_LIMIT_HW = FDEPTH - 1;
    time           first_aw_t, last_accept_t, first_w_t, last_b_t;
    int            aw_at_last_accept;
    int            zero_beats, strb_bad, size_bad, burst_bad, aw4k_bad, wlast_bad;
    longint        acc_idx;                   // beats accepted, this frame
    int            acc_seed, pat_bad;
    bit            check_pat = 1;             // reference pattern on the stream
    bit            byte_log  = 0;             // also queue every byte
    int            irq_count = 0, irq_before = 0;
    int            stall_rises = 0, job_opens = 0, stalls_before = 0;
    bit            stall_prev = 0;
    // streaming guard window: while one frame is being fed, nothing about that
    // frame may be published early
    bit            guard_window = 0, early_done = 0, early_ready = 0, early_irq = 0;
    int            guard_slot = 0, frames_at_start = 0, fbase = 0;

    always @(posedge clk) if (ov_irq_pulse) irq_count++;

    // ------------------------------------------------------------------------
    // M5: the two Gray-crossed status counters are read-backs, so the honest
    // contract is "monotone and never ahead of the bus", not "instantaneous
    // equality with a 300 MHz event".  Sampled every destination clock while a
    // frame streams, which is the window in which a naive equality check would
    // have complained.
    // ------------------------------------------------------------------------
    bit            rb_window = 0, rb_skip_prev = 0;
    logic [31:0]   rb_bytes_last = 32'd0, rb_frames_last = 32'd0;
    int            rb_regress = 0, rb_ahead = 0, rb_samples = 0, rb_skip = 0;
    always @(posedge clk) begin
        // The window is entered right after a clear/reset, when the crossed copy
        // is still draining its previous value: those settling clocks are not
        // part of the invariant.  Everything inside the settled window is.
        if (rb_window && !rb_skip_prev) rb_skip = 64;
        rb_skip_prev <= rb_window;
        if (rb_skip != 0) rb_skip = rb_skip - 1;
        else if (rb_window && rst_n) begin
            rb_samples++;
            if (ov_bytes_written < rb_bytes_last || ov_frames_done < rb_frames_last)
                rb_regress++;
            // never ahead: bytes cannot exceed what the DUT delivered on W.  The
            // comparison uses the CUMULATIVE delivered count, because
            // ov_bytes_written mirrors cnt_beats, which is "beats delivered since
            // reset" and is deliberately not cleared between tests; comparing it
            // against a per-test counter that clear_obs() zeroes would report the
            // test boundary as a violation of the DUT.
            if (longint'(ov_bytes_written) > w_beats_all*16) rb_ahead++;
        end
        rb_bytes_last  <= ov_bytes_written;
        rb_frames_last <= ov_frames_done;
    end

    // ------------------------------------------------------------------------
    // M10: the completion now travels as ONE bundled {slot, event} word, so the
    // honest requirement is no longer "the two index levels happened to be far
    // enough apart from the event edge" (that argument is withdrawn: equal
    // synchroniser depth is not equal arrival between unrelated clocks).  It is:
    // for EVERY published completion, ov_write_slot names the slot this frame's
    // bursts were actually written to, and that slot's ready bit is the one that
    // moved.  The expectation is derived from the AXI address on the bus divided
    // by the slot pitch the test itself programmed, so it never reads the
    // writer's slot register, its crossing or any copy of them, and it cannot
    // agree with a wrong value by construction.
    // ------------------------------------------------------------------------
    logic [AW-1:0] cur_base = '0;         // what prog_cfg last programmed
    longint        cur_pitch = 0;
    // A frame keeps the geometry it started with (the writer freezes job_addr_m and
    // job_bytes_m for exactly as long), so the expectation is frozen the same way,
    // on the same job-open edge.  Decoding every burst against the LIVE program
    // would mis-read W8, which rewrites the geometry mid-frame on purpose.
    logic [AW-1:0] frame_base = '0;
    longint        frame_pitch = 0;
    int            exp_slot_q [$];        // expected slot per published frame, -1 = unknown
    int            frame_slot = -1;       // slot the CURRENT frame's bursts land in
    int            slot_mismatch = 0, slot_checked = 0, slot_unknown = 0;
    int            slot_span_bad = 0;
    bit            slot_strict = 0;       // W19: an unknown expectation is a failure
    logic          irq_d = 1'b0;
    longint        aw_slot_off;
    int            aw_slot_idx, irq_exp;

    always @(posedge mem_clk) begin
        if (dut.job_start) begin
            // a job just opened: freeze the program it was armed with, and start a
            // fresh per-frame slot expectation
            frame_base  = cur_base;
            frame_pitch = cur_pitch;
            frame_slot  = -1;
        end
        if (mem_rst_n && dut.frame_done && !dut.frame_err_now) begin
            // the same edge on which the writer raises its completion record; the
            // entry is the address-derived slot of the frame that just closed
            exp_slot_q.push_back(frame_slot);
            frame_slot = -1;
        end
    end

    // The shell writes ov_write_slot and raises ov_irq_pulse with nonblocking
    // assignments in the SAME clock, so the index the completion produced is only
    // observable from the following clock: sampling it on the IRQ cycle reads the
    // previous completion's slot and would report every slot change as a crossing
    // failure.  Sample one clock later, which is what the reader in software sees.
    always @(posedge clk) begin
        irq_d <= ov_irq_pulse;
        if (irq_d) begin
            slot_checked++;
            // an IRQ with no recorded completion behind it is a phantom, by
            // definition: the record and the IRQ are the same crossing word now
            irq_exp = (exp_slot_q.size() != 0) ? exp_slot_q[0] : -2;
            if (exp_slot_q.size() != 0) void'(exp_slot_q.pop_front());
            if (irq_exp == -2) begin
                slot_mismatch++;
                $display("M10FAIL@%0t: an IRQ appeared with no completion behind it (phantom), naming slot %0d",
                         $time, ov_write_slot);
            end else if (irq_exp == -1) begin
                slot_unknown++;
                // Named, because "no expectation" must never become a silent pass:
                // it means no AW of this frame was booked while its job was open, so
                // the address evidence for it is missing and the IRQ went unchecked.
                $display("M10NOADDR@%0t: slot %0d announced without address evidence (job_open=%b frame_pitch=%0d)",
                         $time, ov_write_slot, dut.job_open, frame_pitch);
                if (slot_strict) begin
                    slot_mismatch++;
                    $display("M10FAIL@%0t: strict mode, but this frame's bursts carry no address-derived slot", $time);
                end
            end else if (ov_write_slot !== 2'(irq_exp)) begin
                slot_mismatch++;
                if (slot_mismatch <= 5)
                    $display("M10FAIL@%0t: IRQ names slot %0d, the bursts of that frame went to slot %0d",
                             $time, ov_write_slot, irq_exp);
            end
        end
    end

    // W19 only: the ready-bit association.  ready_r crosses as its own level, so
    // this is sampled a fixed number of destination clocks AFTER the IRQ, never on
    // it, and W19 consumes every slot before arming the next frame so exactly one
    // bit may be set.
    bit            ready_assoc = 0;
    int            assoc_wait = 0;
    logic [1:0]    assoc_slot = 2'd0;
    always @(posedge clk) begin
        if (assoc_wait != 0) begin
            assoc_wait = assoc_wait - 1;
            if (assoc_wait == 0) begin
                checks++;
                if (ov_slot_ready !== (4'd1 << assoc_slot))
                    fail($sformatf("M10: the completion that named slot %0d left ov_slot_ready=%b, expected only that bit set",
                                   assoc_slot, ov_slot_ready));
            end
        end else if (irq_d && ready_assoc) begin
            assoc_slot = ov_write_slot;
            assoc_wait = 16;
        end
    end

    // slave model knobs (declared before the model that uses them)
    int  aw_stall_cnt = 0, w_stall_cnt = 0;
    bit  inject_bresp = 0;
    // Inject on ONE numbered burst instead of the whole frame: -1 = off.  This is
    // what turns the BRESP test from "the sticky gets set" into "a fault anywhere
    // in the frame forbids publication", including on the very last burst.
    int  inject_at    = -1;
    int  err_kind     = 2'b10;               // 2'b10 SLVERR, 2'b11 DECERR
    // hold every B back (a slave that has accepted AW/W but has not answered):
    // this is how a reset with real outstanding debt is reached at all
    bit  hold_b       = 0;
    // Review M6: a slave that will not take the address at all, so a burst sits
    // presented-but-unaccepted across a reset, and counters that are NEVER
    // cleared, which is the only way to tell "the old debt was retired" apart
    // from "a new AW was issued on top of it".
    bit  hold_aw      = 0;
    // W17: the same for W - a slave that has taken the address and then stops
    // taking beats mid-burst, so a reset can be found with beats_owed > 0.
    bit  hold_w       = 0;
    // A slave that answers a burst it was never given.  This is how the
    // unsolicited-response backstop is still reachable once real debt is retired
    // against its own ledger instead of being laundered by a reset.
    bit  spurious_b   = 0;
    longint s_aw_all = 0, s_w_all = 0, s_b_all = 0;
    // never-cleared ledger snapshots, taken at the reset instant
    longint aw_at_r = 0, w_at_r = 0, b_at_r = 0;
    // How many AW offers were ALREADY presented when a reset window opened.  The
    // ownership rule in the slave monitor (see the reset-window block above) says such
    // an offer may legally handshake while the reset is held; a cumulative-count check
    // that ignores it is stricter than AXI and would report legal behaviour as a fault.
    int     aw_owned_at_r = 0;
    logic [AW-1:0] hold_aw_addr = '0;
    logic [DW-1:0] hold_w_dat   = '0;
    logic          hold_w_last  = 1'b0;   // W17: WLAST held across the reset
    logic          hold_aw_val  = 1'b0, hold_w_val = 1'b0;
    // byte-exact delivery comparison can be turned off for a window in which the
    // reference queue was deliberately cleared by the test
    bit  del_check    = 1;
    int  b_latency_max = 6;
    longint b_sent = 0;
    int  b_wait = 0;

    always @(posedge mem_clk) if (mem_rst_n && s_axis_tvalid && s_axis_tready) begin
        accepted_beats++;
        last_accept_t = $time;
        aw_at_last_accept = aw_total;
        if (guard_window) begin
            if (int'(ov_frames_done) != frames_at_start) early_done  = 1;
            if (ov_slot_ready[guard_slot])               early_ready = 1;
            if (irq_count != irq_before)                 early_irq   = 1;
        end
        if (check_pat && (s_axis_tdata !== pat_beat(acc_idx, acc_seed))) begin
            pat_bad++;
            if (pat_bad <= 8)
                fail($sformatf("stream beat %0d = %h, reference %h (phantom or duplicated beat)",
                               acc_idx, s_axis_tdata, pat_beat(acc_idx, acc_seed)));
        end
        acc_idx++;
        w_beat_q.push_back(s_axis_tdata);
        if (byte_log)
            for (int i = 0; i < 16; i++) w_byte_q.push_back(s_axis_tdata[i*8 +: 8]);
        if (w_beat_q.size() > (HW_CAP + 2)) begin
            // one FIFO of accepted-but-undelivered data is the whole point of a
            // streaming master; twice that means it is hoarding a frame
            fail($sformatf("%0d accepted beats still undelivered (payload FIFO is %0d beats)",
                           w_beat_q.size(), FDEPTH));
            void'(w_beat_q.pop_front());
            if (byte_log) for (int i = 0; i < 16; i++) void'(w_byte_q.pop_front());
        end
        if (w_beat_q.size() > max_undelivered) max_undelivered = w_beat_q.size();
    end

    // delivered-vs-accepted, compared as it happens: byte exact, bounded memory.
    // Not gated on mem_rst_n: under the obligation rule the beats a reset found
    // owed are delivered AFTER the reset, and they still have to be the bytes
    // that were accepted before it.
    always @(posedge mem_clk) if (wvalid && wready) begin
        w_beats++;
        w_beats_all++;
        s_w_all++;
        if (first_w_t == 0) first_w_t = $time;
        if (!del_check) begin
            // the reference queue was cleared by the test itself; only the
            // never-cleared ledger applies in this window
            if (w_beat_q.size() != 0) void'(w_beat_q.pop_front());
            if (byte_log && w_byte_q.size() != 0) void'(w_byte_q.pop_front());
        end
        else if (w_beat_q.size() == 0)
            fail($sformatf("AXI delivered beat %0d that was never accepted (phantom write)",
                           w_beats));
        else begin
            if (wdata !== w_beat_q[0] && errors < 40)
                fail($sformatf("delivered beat %0d = %h, but the accepted beat was %h",
                               w_beats, wdata, w_beat_q[0]));
            void'(w_beat_q.pop_front());
        end
        if (byte_log) begin
            // Compare through fixed-width temporaries: case equality (!==) does
            // not size-extend, and a queue element select is not guaranteed to
            // present the same width as a part select, which would report two
            // identical bytes as different.
            for (int i = 0; i < 16; i++) begin
                if (w_byte_q.size() == 0) break;
                got_b = wdata[i*8 +: 8];
                exp_b = w_byte_q[0];
                if (got_b !== exp_b && errors < 40)
                    fail($sformatf("delivered byte %0d = %02h, but the accepted byte was %02h",
                                   (w_beats-1)*16 + i, got_b, exp_b));
                void'(w_byte_q.pop_front());
            end
        end
        if (wstrb !== 16'hffff) strb_bad++;
        if (wdata === '0)       zero_beats++;
        if (wlast) begin wlast_count++; bursts_written++; end
        last_beats++;
        if (wlast != (last_beats == 16)) wlast_bad++;
        if (last_beats == 16) last_beats = 0;
    end

    always @(posedge mem_clk) begin
        // white-box observation of the real storage bound
        if (mem_rst_n && longint'(dut.fifo_occ) > dut_occ_max)
            dut_occ_max = longint'(dut.fifo_occ);
        // Review M6 MEDIUM-1: there is deliberately NO mem_rst_n mask here.  The
        // PS HP3 slave has no reset pin, so an AW that was already presented before
        // the writer's logical reset stays presented and may LEGALLY be accepted
        // while that reset is still held low.  Masking the counter hid exactly the
        // recognition window the deferred reset has to be judged on, so every real
        // handshake is booked now and the invariant lives in the aw_win monitor
        // below: presentation and ownership, not a handshake count.
        if (awvalid && awready) begin
            aw_total++;
            s_aw_all++;
            aw_list.push_back(awaddr);  alen_list.push_back(awlen);
            if (first_aw_t == 0) first_aw_t = $time;
            if (awsize !== 3'd4)   size_bad++;
            if (awburst !== 2'b01) burst_bad++;
            if ({1'b0, awaddr[11:0]} + 13'd256 > 13'd4096) aw4k_bad++;  // 4 KiB rule
            // M10: which slot does this burst actually land in?  Derived from the
            // bus address and the pitch this frame was armed with, never from the
            // DUT's slot register, its crossing or a copy of either.
            if (frame_pitch != 0) begin
                aw_slot_off = longint'(awaddr) - longint'(frame_base);
                aw_slot_idx = int'(aw_slot_off / frame_pitch);
                if (frame_slot < 0) frame_slot = aw_slot_idx;
                else if (frame_slot != aw_slot_idx) begin
                    slot_span_bad++;
                    if (slot_span_bad <= 4)
                        fail($sformatf("M10: bursts of one frame land in two slots (%0d and %0d) at %h",
                                       frame_slot, aw_slot_idx, awaddr));
                end
            end
        end
        if (bvalid && bready) begin
            b_count++;
            s_b_all++;
            if (bresp != 2'b00) b_err_seen++;   // proof the fault reached the bus
            bresp_seen <= bresp;  last_b_t = $time;
        end
    end

    // AXI stability: an output must not move while VALID is up and READY is down.
    // NOT gated on mem_rst_n - the logical video reset is not the slave's reset,
    // so withdrawing AWVALID/WVALID or moving the payload across it is a protocol
    // violation here even though the DUT's own reset is asserted (review M6).
    logic [DW-1:0]   hold_wdata; logic [AW-1:0] hold_awaddr;
    logic hold_wlast;
    always @(posedge mem_clk) begin
        if (wvalid && !wready && $past(wvalid && !wready)) begin
            if (wdata !== hold_wdata || wlast !== hold_wlast)
                fail("W channel changed while WVALID was high and WREADY low");
            if (wstrb !== 16'hffff) fail("WSTRB moved while stalled");
        end
        if ($past(wvalid && !wready) && !wvalid)
            fail("WVALID was withdrawn before WREADY (reset pulled the payload out)");
        hold_wdata <= wdata; hold_wlast <= wlast;
        if (awvalid && !awready && $past(awvalid && !awready))
            if (awaddr !== hold_awaddr)
                fail("AW channel changed while AWVALID was high and AWREADY low");
        if ($past(awvalid && !awready) && !awvalid)
            fail("AWVALID was withdrawn before AWREADY (reset pulled the address out)");
        hold_awaddr <= awaddr;
    end

    // ------------------------------------------------------------------------
    // Review M6 MEDIUM-1 (corrected form).  While the writer's logical reset is
    // held and its front end still owes the slave, the invariant is about
    // PRESENTATION and OWNERSHIP, not about how many handshakes happened:
    //   (a) an AW that was already VALID when the reset arrived must STAY valid and
    //       may be accepted by the slave at any time in the window.  That is legal
    //       and is not an error here; forcing awready low, or accepting a design
    //       that withdraws a held VALID just to make a counter read zero, would be
    //       the bug (the W16 fixture depends on this freedom);
    //   (b) no NEW AW may be PRESENTED in the window: no rising AWVALID;
    //   (c) every AW handed over in the window must be the offer the front end
    //       already owned at the snapshot, with its address unchanged, and an AW
    //       nobody owned may not be accepted at all.
    // (b) is the presentation rule proper: no rising AWVALID once the writer has
    // recognised the reset.  Measured scope of this check: it fires on a design that
    // opens a new obligation after recognition, but the specific !fe_rst_req term in
    // aw_go turned out to be redundant in every window exercised here - removing it
    // (scratch mutant G_aw_during_reset) PASSED, because aw_go also requires job_open
    // and !disc_active, and a reset that finds work outstanding raises a retirement.
    // The term is therefore kept as defensive depth, and this comment no longer claims
    // more observability than was measured.
    // ------------------------------------------------------------------------
    bit            aw_win = 0;                // armed by the test at the reset instant
    int            aw_win_owned = 0;          // offers already presented at the snapshot
    logic [AW-1:0] aw_win_addr = '0;          // the address that offer holds
    always @(posedge mem_clk) begin
        if (aw_win) begin
            // The presentation rule starts on the cycle the writer has actually
            // recognised the reset.  fe_rst_req is a two-flop synchronised view of
            // mem_rst_n (rtl/sc7f0_overlay_writer.v:1110-1112), and gating an AXI
            // presentation directly off the asynchronous pin is the runt-pulse failure
            // the card documents for the same class of mistake
            // (rtl/custom_pcie_dma_top.v:532-545, CDC-10).  So a presentation inside
            // that detection latency is legal and is reported, not failed; anything
            // presented once the request is visible is the bug this check exists for, and
            // a design with !fe_rst_req removed from aw_go produces exactly that.
            if ($rose(awvalid) && dut.fe_rst_req)
                fail("a new AW was PRESENTED after the writer had recognised the reset");
            else if ($rose(awvalid))
                $display("AWPRESENT@%0t: one offer in the reset detection window (fe_rst_req not yet visible), addr %h",
                         $time, awaddr);
            if (awvalid && awready) begin
                if (aw_win_owned <= 0)
                    fail($sformatf("an AW nobody owned handshaked inside the held-reset window (addr %h)",
                                   awaddr));
                else if (awaddr !== aw_win_addr)
                    fail($sformatf("the AW handed over inside the window is %h, the owned offer was %h",
                                   awaddr, aw_win_addr));
                else
                    aw_win_owned--;
            end
        end
    end

    // ------------------------------------------------------------------------
    // AXI4 slave model, independent of the DUT's internals.  AW and W are
    // accepted at a throttled rate; B is returned in order only after that
    // burst's WLAST landed and after a bounded delay, so several write bursts
    // really are outstanding at once.
    // ------------------------------------------------------------------------
    always @(posedge mem_clk) begin
        if (aw_stall_cnt) aw_stall_cnt--;
        if (w_stall_cnt)  w_stall_cnt--;
        awready <= !hold_aw && (aw_stall_cnt == 0) && ($urandom_range(0, 1) != 0);
        wready  <= !hold_w && (w_stall_cnt == 0) && ($urandom_range(0, 2) != 0);
        // b_wait is a real countdown.  It used to be loaded at WLAST and cleared
        // ONLY by a B handshake, so a slave that was told to hold its answers
        // (hold_b) could never release them again: the owed completions sat
        // behind a b_wait that nothing decremented, and the "stale B after a
        // reset" fixture then silently never delivered the stale B it claims to
        // test (measured: b_sent 16, bursts_written 20, b_wait stuck at 5, bvalid
        // never rose).  The latency is still bounded by b_latency_max, so several
        // write bursts really are outstanding at once.
        //
        // Review M6: nothing here is gated on mem_rst_n any more.  saxihp3_fpd_aclk
        // is capture_clk and the PS BD has no HP3 reset pin, so the real slave
        // does not restart when the video path does; a slave that went quiet
        // during a logical reset would hide the hazard instead of testing it.
        if (b_wait != 0) b_wait <= b_wait - 1;
        if (wvalid && wready && wlast)
            b_wait <= $urandom_range(1, b_latency_max);
        if (!hold_b && !bvalid && b_sent < bursts_written && b_wait == 0) begin
            bvalid <= 1'b1;
            bresp  <= (inject_bresp || (inject_at >= 0 && b_sent == inject_at))
                          ? 2'(err_kind) : 2'b00;
            b_sent++;
        end else if (bvalid && bready) begin
            bvalid <= 1'b0;
        end
        // last write wins: a spurious answer is emitted even with nothing owed
        if (spurious_b && !bvalid) begin
            bvalid     <= 1'b1;
            bresp      <= 2'b00;
            spurious_b <= 1'b0;
        end
    end

    task automatic stall_w(input int cycles);  w_stall_cnt = cycles; endtask
    task automatic stall_aw(input int cycles); aw_stall_cnt = cycles; endtask

    // ------------------------------------------------------------------------
    // stream driver: push beats of the reference pattern, with optional gaps.
    // axis_avail models rtl/sc7f0_overlay_ingress.v's read-side count: the beats
    // of this transfer that the crossing FIFO still holds.  abort_kill models the
    // ingress withdrawing the plane (arm dropped / payload discarded), which is
    // the only way a real upstream stops feeding an aborted plane.
    // ------------------------------------------------------------------------
    bit stream_short;
    bit abort_kill = 0, abort_req = 0;
    task automatic stream_at(input longint start, input longint nbeats,
                             input int seed, input int gap_max);
        longint b;
        int w;
        stream_short = 1'b0;
        acc_seed = seed;
        for (b = 0; b < nbeats; b++) begin
            if (abort_kill && abort_req) break;      // upstream abandoned the plane
            @(negedge mem_clk);
            if (gap_max && ($urandom_range(0, gap_max) == 0)) begin
                s_axis_tvalid <= 1'b0;
                b--;                            // a gap is not a beat
                continue;
            end
            axis_avail      <= (nbeats - b > 255) ? 8'hFF : 8'((nbeats - b) - 1);
            s_axis_tvalid <= 1'b1;
            s_axis_tuser  <= ((start + b) == 0);
            s_axis_tdata  <= pat_beat(start + b, seed);
            w = 0;
            @(posedge mem_clk);
            while (!(s_axis_tvalid && s_axis_tready) && w < 40000) begin
                @(posedge mem_clk); w++;
            end
            if (w >= 40000) begin               // refused: stop presenting
                stream_short = 1'b1;
                if ($test$plusargs("DBG"))
                    $display("REFUSED@%0t en=%b al=%b slot_use=%b inflight=%b job_open=%b disc=%b ab=%0d active=%b room=%b tuser=%b fw=%b froom=%b occ=%0d fe_rst_n=%b fe_owed=%b fe_req=%b sync=%b retire=%b busy=%b",
                             $time, dut.c_enable, dut.aligned, dut.slot_in_use,
                             dut.inflight_m[dut.wslot], dut.job_open, dut.disc_active,
                             dut.ab_state, dut.active_m, dut.room, s_axis_tuser,
                             dut.fifo_wready, dut.fifo_room, dut.fifo_occ,
                             dut.fe_rst_n, dut.fe_owed, dut.fe_rst_req,
                             dut.rstn_sync_l, dut.fe_retire_needed, ov_busy);
                b = nbeats;
            end
        end
        @(negedge mem_clk);
        s_axis_tvalid <= 1'b0;
        s_axis_tuser  <= 1'b0;
        axis_avail    <= 8'd0;
    endtask
    task automatic stream(input longint nbeats, input int seed, input int gap_max);
        stream_at(0, nbeats, seed, gap_max);
    endtask

    // trace of every job open and every new stall: the sequence of slots and
    // lengths is what these tests are about, and the status ports are
    // synchronised copies that lag the payload domain by several cycles
    always @(posedge mem_clk) begin
        if (dut.job_start) begin
            job_opens++;
            if (job_opens <= 12)
                $display("JOB@%0t addr=%h bytes=%0d slot=%0d frames_m=%0d c_frame_bytes=%0d c_slot_bytes=%0d",
                         $time, dut.job_addr_m, dut.job_bytes_m, dut.job_slot_m,
                         dut.frames_m + 32'd1, dut.c_frame_bytes, dut.c_slot_bytes);
        end
        if (dut.stall_sticky_m && !stall_prev) begin
            stall_rises++;
            $display("STALL@%0t tvalid=%b tuser=%b active_m=%b aligned=%b slot_in_use=%b wslot=%0d ready=%b cnt_frame=%0d xfer_bytes=%0d frames=%0d",
                     $time, s_axis_tvalid, s_axis_tuser, dut.active_m, dut.aligned,
                     dut.slot_in_use, dut.wslot, dut.ready_r, dut.cnt_frame,
                     dut.xfer_bytes_q, ov_frames_done);
        end
        stall_prev <= dut.stall_sticky_m;
    end

    task automatic clear_obs();
        // M10: a reset or a test boundary discards any completion record the
        // writer had parked, so its expectation goes with it
        exp_slot_q.delete(); frame_slot = -1;
        aw_list.delete(); alen_list.delete(); w_beat_q.delete(); w_byte_q.delete();
        w_beats = 0; accepted_beats = 0; bursts_written = 0; b_count = 0;
        b_sent = 0; b_wait = 0; aw_total = 0; wlast_count = 0; last_beats = 0;
        bresp_seen = 2'b00; b_err_seen = 0;
        first_aw_t = 0; last_accept_t = 0; first_w_t = 0; last_b_t = 0;
        aw_at_last_accept = 0; acc_idx = 0; max_undelivered = 0;
        zero_beats = 0; strb_bad = 0; size_bad = 0; burst_bad = 0;
        aw4k_bad = 0; wlast_bad = 0; pat_bad = 0;
        dut_occ_max = 0;
        irq_before = irq_count;
    endtask

    // Same, but the slave's OUTSTANDING debt is left exactly as it is: a reset
    // test that zeroes b_sent/bursts_written has quietly removed the stale B it
    // claims to be testing (that is what made the old W7 mislabelled).
    task automatic clear_soft();
        exp_slot_q.delete(); frame_slot = -1;
        aw_list.delete(); alen_list.delete(); w_beat_q.delete(); w_byte_q.delete();
        w_beats = 0; accepted_beats = 0; b_count = 0;
        aw_total = 0; wlast_count = 0; last_beats = 0;
        bresp_seen = 2'b00; b_err_seen = 0;
        first_aw_t = 0; last_accept_t = 0; first_w_t = 0; last_b_t = 0;
        aw_at_last_accept = 0; acc_idx = 0; max_undelivered = 0;
        zero_beats = 0; strb_bad = 0; size_bad = 0; burst_bad = 0;
        aw4k_bad = 0; wlast_bad = 0; pat_bad = 0;
        dut_occ_max = 0;
        irq_before = irq_count;
    endtask

    // Reset-boundary bookkeeping that KEEPS the reference queue: under the
    // obligation rule the beats a reset found owed are still owed, so the bytes
    // accepted before the reset must be the bytes delivered after it.  Clearing
    // the queue here would delete the only evidence of that.
    task automatic clear_soft_keep_q();
        exp_slot_q.delete(); frame_slot = -1;
        aw_list.delete(); alen_list.delete();
        w_beats = 0; accepted_beats = 0; b_count = 0;
        aw_total = 0; wlast_count = 0; last_beats = 0;
        bresp_seen = 2'b00; b_err_seen = 0;
        first_aw_t = 0; last_accept_t = 0; first_w_t = 0; last_b_t = 0;
        aw_at_last_accept = 0; max_undelivered = 0;
        zero_beats = 0; strb_bad = 0; size_bad = 0; burst_bad = 0;
        aw4k_bad = 0; wlast_bad = 0; pat_bad = 0;
        dut_occ_max = 0;
        irq_before = irq_count;
    endtask

    // Ask for the plane to be discarded and wait for the memory side to say it
    // is done: the ack is a level that rises during retirement and falls when
    // AB_DONE has cleared the intake, so "busy fell" is the real end of the
    // abort, not an elapsed guess.
    bit abort_busy_watch = 0, abort_busy_seen = 0;
    always @(posedge clk) if (abort_busy_watch && ov_abort_busy) abort_busy_seen = 1;

    task automatic request_abort(input string tag);
        int n = 0;
        abort_req        = 1'b1;            // the upstream abandons the plane
        abort_busy_watch = 1;
        @(negedge clk); ov_abort <= 1'b1;
        @(negedge clk); ov_abort <= 1'b0;   // a one-cycle request must not be lost
        while (!ov_abort_busy && n < 500) begin @(posedge clk); n++; end
        ck(ov_abort_busy, {tag, ": ov_abort_busy never rose for the discard"});
        while ((ov_abort_busy || dut.ab_state !== 2'd0) && n < 8000) begin
            @(posedge clk); n++;
        end
        ck(n < 8000, {tag, ": the discard was never acknowledged (not settled)"});
        ck(ov_abort_sticky, {tag, ": a discarded plane was not latched"});
        abort_busy_watch = 0;
    endtask

    // Present the first beats of a NEW frame for a bounded window and report how
    // many were taken.  Used to PROVE that a frame cannot be armed on top of an
    // unretired obligation: the honest answer is zero, and the source keeps
    // presenting until the receiver is genuinely free.
    int armed_accepts;
    task automatic arm_attempt(input int cycles, input int seed_v);
        int k;
        armed_accepts = 0;
        @(negedge mem_clk);
        s_axis_tvalid <= 1'b1;
        s_axis_tuser  <= 1'b1;
        s_axis_tdata  <= pat_beat(0, seed_v);
        axis_avail    <= 8'hFF;
        for (k = 0; k < cycles; k++) begin
            @(posedge mem_clk);
            if (s_axis_tvalid && s_axis_tready) begin
                armed_accepts++;
                s_axis_tuser <= 1'b0;         // the rest of that frame would follow
            end
        end
        @(negedge mem_clk);
        s_axis_tvalid <= 1'b0;
        s_axis_tuser  <= 1'b0;
        axis_avail    <= 8'd0;
    endtask

    // Wait for a retirement to be ACKED.  The end is ov_abort_busy falling, which
    // the design derives from its own state machine, never from elapsed time.
    task automatic wait_retire(input string tag, input int limit);
        int n = 0;
        while (!ov_abort_busy && n < 200) begin @(posedge clk); n++; end
        ck(ov_abort_busy, {tag, ": the writer never reported a retirement in progress"});
        while (ov_abort_busy && n < limit) begin @(posedge clk); n++; end
        ck(!ov_abort_busy, {tag, ": the retirement was never acknowledged"});
    endtask

    task automatic guard_begin(input int slot);
        guard_window      = 1;
        guard_slot        = slot;
        early_done        = 0;
        early_ready       = 0;
        early_irq         = 0;
        frames_at_start   = int'(ov_frames_done);
    endtask
    task automatic guard_end();   guard_window = 0; endtask

    // publish-time ordering proof: the slot may only become ready, the frame
    // count may only move and the IRQ may only pulse once the last B landed
    task automatic guard_verdict(input string tag);
        checks++;
        if (early_done)
            fail({tag, ": frames_done moved before the frame finished streaming"});
        if (early_ready)
            fail({tag, ": the slot was published before the frame finished streaming"});
        if (early_irq)
            fail({tag, ": the IRQ fired before the frame finished streaming"});
        guard_window = 0;
    endtask

    task automatic prog_cfg(input logic [AW-1:0] base, input longint slot_bytes,
                            input longint frame_bytes, input bit en, input bit auto_adv,
                            input int force_slot, input int nslots);
        @(negedge clk);
        ov_dst_base     <= base;
        ov_slot_bytes   <= 32'(slot_bytes);
        ov_frame_bytes  <= 32'(frame_bytes);
        ov_enable       <= en;
        ov_auto_advance <= auto_adv;
        ov_force_slot   <= 2'(force_slot);
        ov_slot_count   <= 3'(nslots);
        // M10 expectation bookkeeping: the address-derived slot is only used after
        // cfg_live() has proved this program is live in the payload domain, so a
        // blocking update here is the right side of the snapshot boundary.
        cur_base  = base;
        cur_pitch = slot_bytes;
    endtask

    task automatic consume(input int slot);
        @(negedge clk);
        ov_consume <= 4'(1 << slot);
        @(negedge clk);
        ov_consume <= 4'd0;
    endtask

    // Wait until the bus is quiet.  frames_done is only published after the
    // final B, so a check that only watched the byte counter could read the bus
    // mid-transfer.
    int b_prev = 0;
    task automatic settle(input longint limit);
        longint n = 0; int prev = -1, still = 0;
        while (n < limit && still < 400) begin
            @(posedge clk);
            n++;
            if (w_beats == prev && int'(b_count) == b_prev) still++;
            else begin still = 0; prev = int'(w_beats); b_prev = int'(b_count); end
        end
    endtask

    task automatic wait_frames(input int want, input longint limit, input string tag);
        longint n = 0;
        while (int'(ov_frames_done) != want && n < limit) begin @(posedge clk); n++; end
        ck(int'(ov_frames_done) == want,
           {tag, ": frames_done ", $sformatf("%0d", ov_frames_done), ", expected ",
            $sformatf("%0d", want)});
    endtask

    // The config bank crosses to the payload domain as one ordered snapshot, so
    // a frame started in the same cycle as prog_cfg would legitimately capture
    // the PREVIOUS geometry.  Waiting for the snapshot to be live is a white-box
    // check of that contract, and it is also what detects a swallowed config
    // write (the defect this bank existed to fix) instead of hiding it.
    task automatic cfg_live(input logic [AW-1:0] base, input longint slot_bytes,
                            input longint frame_bytes, input bit en, input bit auto_adv,
                            input int force_slot, input int nslots, input string tag);
        int n = 0, stable = 0;
        logic [31:0] w_sb, w_fb;
        logic [2:0]  w_nsl;
        logic [1:0]  w_frc;
        bit          live;
        // Compare with case equality into one 2-state flag: a plain == inside a
        // compound while() can evaluate to X and silently end the wait, which
        // would let a frame start on the PREVIOUS geometry.
        w_sb = 32'(slot_bytes);
        w_fb = 32'(frame_bytes);
        w_nsl = 3'(nslots);
        w_frc = 2'(force_slot);
        while (n < 400 && stable < 2) begin
            live = (dut.c_dst_base === base)   &&
                   (dut.c_slot_bytes === w_sb) &&
                   (dut.c_frame_bytes === w_fb) &&
                   (dut.c_enable === en)       &&
                   (dut.c_auto_adv === auto_adv) &&
                   (dut.c_force_slot === w_frc) &&
                   (dut.c_slot_count === w_nsl);
            if (live) stable++;
            else      stable = 0;
            @(posedge clk);
            n++;
        end
        ck(stable >= 2, {tag, ": config snapshot never reached the payload domain"});
        if (stable < 2)
            $display("CFGSTUCK %s want fb=%0d sb=%0d nsl=%0d | got fb=%0d sb=%0d nsl=%0d base=%h/%h ready=%b changed=%b commit=%b",
                     tag, w_fb, w_sb, w_nsl, dut.c_frame_bytes, dut.c_slot_bytes,
                     dut.c_slot_count, dut.c_dst_base, base, dut.cfg_ready,
                     dut.cfg_changed, dut.cfg_commit);
    endtask

    // CSR commit accounting: the crossing must take one commit per change and
    // must never lose one.  Quiescence (cfg_bank == cfg_bus, and the destination
    // copy == the bank) is asserted by cfg_live above.
    int cfg_commits = 0, cfg_changes = 0;
    logic [119:0] cfg_bus_prev = '0;   // CFG_W of the writer's config bundle
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.cfg_bus !== cfg_bus_prev) cfg_changes++;
            if (dut.cfg_commit)               cfg_commits++;
        end
        cfg_bus_prev <= dut.cfg_bus;
    end

    task automatic slot_free(input int idx, input string tag);
        int n = 0;
        while (n < 400 && ov_slot_ready[idx] !== 1'b0) begin @(posedge clk); n++; end
        ck(n < 400, {tag, ": ov_consume[", $sformatf("%0d", idx),
                     "] never released the slot"});
    endtask

    // ---- W20 helpers ------------------------------------------------------
    // Fixture for the terminal-cycle race: one 256 B burst, already paid in full on W,
    // with exactly one write response owed by the slave - i.e. the completion of a real
    // owned job, held back.  b_latency_max = 1 makes the slave's countdown
    // deterministic: b_wait is loaded with 1 at the last WLAST and decrements every cycle
    // even while hold_b is high (tb:642), so b_wait is 0 long before the release.
    task automatic w20_setup(input logic [AW-1:0] base, input longint slot_bytes,
                             input longint frame_bytes, input longint sd, input string tag);
        rst_n = 1'b0; dma_soft_rst = 1'b0; mem_rst_n = 1'b0; epoch_hold = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft();
        b_latency_max = 1;
        hold_b = 1'b1; hold_w = 1'b0; hold_aw = 1'b0; aw_win = 1'b0;
        prog_cfg(base, slot_bytes, frame_bytes, 1'b1, 1'b0, 0, 1);
        cfg_live(base, slot_bytes, frame_bytes, 1'b1, 1'b0, 0, 1, tag);
        stream(frame_bytes/16, sd, 0);
        settle(3000);
        ck(b_count == 0 && dut.beats_aw == 32'(frame_bytes/16) &&
           dut.beats_w == 32'(frame_bytes/16) &&
           dut.beats_b == 32'd0 && dut.total_beats == 32'(frame_bytes/16) &&
           dut.job_open === 1'b1 && dut.fe_owed === 1'b1 && dut.job_invalid === 1'b0 &&
           dut.cmpl_req === 1'b0,
           $sformatf("W20%s: the fixture did not leave exactly one owed, already-paid terminal burst (aw=%0d w=%0d b=%0d total=%0d open=%b owed=%b invalid=%b)",
                     tag, dut.beats_aw, dut.beats_w, dut.beats_b, dut.total_beats,
                     dut.job_open, dut.fe_owed, dut.job_invalid));
    endtask

    // Release the owed terminal response and, in the same step, drop a physical reset,
    // so that the response is TAKEN on the cycle the resulting request first reaches the
    // intake.  Nothing is forced here: the alignment comes from the two synchroniser
    // depths (epoch 3 FF at rtl/sc7f0_overlay_writer.v:1167-1173; the front-end reset is
    // 2 FF + 1 register at :1124-1132; both are high on the cycle that posedge n+2
    // samples, n being the first posedge that already sees the input low) plus the
    // slave's registered bvalid (tb:645), which m_axi_bready ties high, so that response
    // is taken exactly one posedge after it is registered.  Stimulus moves on negedges so
    // the next posedge sees it.
    task automatic w20_release(input int which);
        @(negedge mem_clk);
        if (which == 0) rst_n     = 1'b0;      // PCIe epoch: the reset a link event takes
        else            mem_rst_n = 1'b0;      // memory side (kept for the counter only)
        @(negedge mem_clk); hold_b = 1'b0;     // bvalid registers at the next posedge
        @(posedge mem_clk);
        @(posedge mem_clk);                     // b_fire and the request share this edge
    endtask

    // ------------------------------------------------------------------------
    // per-frame verdict: counts, geometry, ordering, strobes and the reference
    // ------------------------------------------------------------------------
    task automatic frame_verdict(input string tag, input longint nbytes,
                                 input logic [AW-1:0] ebase);
        checks++;
        if (stream_short) fail({tag, ": the stream was refused mid-frame"});
        if (aw_total != int'(nbytes/256))
            fail($sformatf("%s: %0d write bursts, expected %0d", tag, aw_total,
                           nbytes/256));
        if (wlast_count != int'(nbytes/256))
            fail($sformatf("%s: %0d WLAST, expected one per burst", tag, wlast_count));
        if (w_beats != nbytes/16)
            fail($sformatf("%s: %0d W beats delivered, expected %0d", tag,
                           w_beats, nbytes/16));
        if (accepted_beats != nbytes/16)
            fail($sformatf("%s: %0d beats accepted, expected %0d", tag,
                           accepted_beats, nbytes/16));
        if (b_count != nbytes/256)
            fail($sformatf("%s: %0d B responses, expected one per burst", tag,
                           b_count, nbytes/256));
        if (w_beat_q.size() != 0)
            fail($sformatf("%s: %0d accepted beats never reached AXI", tag,
                           w_beat_q.size()));
        if (byte_log && w_byte_q.size() != 0)
            fail($sformatf("%s: %0d accepted bytes never reached AXI", tag,
                           w_byte_q.size()));
        checks++;
        for (int i = 0; i < aw_total && i < aw_list.size(); i++)
            if (aw_list[i] != ebase + i*256) begin
                fail($sformatf("%s: burst %0d at %h, expected %h", tag, i,
                               aw_list[i], ebase + i*256));
                break;
            end
        for (int i = 0; i < alen_list.size(); i++)
            if (alen_list[i] != 8'd15) begin
                fail($sformatf("%s: AWLEN %0d is not 15 (16 beats)", tag, alen_list[i]));
                break;
            end
        if (strb_bad)   fail($sformatf("%s: %0d partial write strobes", tag, strb_bad));
        if (size_bad)   fail($sformatf("%s: %0d AWSIZE != 16 B", tag, size_bad));
        if (burst_bad)  fail($sformatf("%s: %0d AWBURST != INCR", tag, burst_bad));
        if (aw4k_bad)   fail($sformatf("%s: %0d bursts cross a 4 KiB boundary", tag, aw4k_bad));
        if (wlast_bad)  fail($sformatf("%s: %0d WLAST placements wrong", tag, wlast_bad));
        if (zero_beats) fail($sformatf("%s: %0d all-zero beats written", tag, zero_beats));
        if (pat_bad)    fail($sformatf("%s: %0d accepted beats broke the reference pattern",
                                       tag, pat_bad));
        if (irq_count != irq_before + 1)
            fail($sformatf("%s: %0d irq pulses, expected exactly one more", tag,
                           irq_count - irq_before));
    endtask

    localparam longint FB   = 4096;               // 16 bursts of 256 B
    localparam longint SB   = 8192;               // slot pitch
    localparam longint FCAP = FDEPTH*16;          // payload burst buffer, 16 kB
    localparam longint F64K = 64*1024;            // 4x the buffer: must stream
    localparam longint S64K = 128*1024;
    // required product case: 3840 x 2160 RGBA8888, line pitch 15,360 B
    localparam longint F4K  = 3840*2160*4;        // 33,177,600 B
    localparam longint S4K  = 3840*2160*4;        // one slot per frame
    localparam longint B4K  = F4K/16;             // 2,073,600 beats
    localparam longint U4K  = F4K/256;            // 129,600 bursts
    logic [AW-1:0] BASE = 49'h0_0080_0000;
    logic [AW-1:0] BASE2 = 49'h0_0090_0000;   // second fixture base, W15/W16
    logic [AW-1:0] BASE4K = 49'h0_1000_0000;
    int seed = 3;
    bit no4k = 0;

    initial begin : main
        longint n;
        longint owed17, led_aw_r, led_b_r;
        // W18: an independent record of what the job that survives the PCIe reset
        // actually did, kept across the reset and across the reprogramming.
        int       old_aw_n;
        longint   old_aw_min, old_aw_max, old_aw_sum, old_w_beats;
        int     n17w, n18, n19;
        no4k = $test$plusargs("NO4K");
        rst_n = 1'b0; mem_rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge mem_clk);
        mem_rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ---- W1: refused geometry -----------------------------------------
        byte_log = 1;
        clear_obs();
        prog_cfg(BASE, SB, 4000, 1'b1, 1'b0, 0, 1);      // 4000 % 256 != 0
        cfg_live(BASE, SB, 4000, 1'b1, 1'b0, 0, 1, "cfg0");
        stream(FB/16, seed, 2);
        ck(stream_short, "W1: a misaligned frame was accepted off the stream");
        settle(4000);
        ck(ov_misalign_sticky, "W1: misaligned geometry not latched");
        ck(aw_total == 0, "W1: AXI activity for a refused geometry");
        ck(w_beats == 0, "W1: bytes written for a refused geometry");
        ck(accepted_beats == 0, "W1: bytes accepted for a refused geometry");
        prog_cfg(BASE, SB, 4000, 1'b0, 1'b0, 0, 1);      // disable again
        cfg_live(BASE, SB, 4000, 1'b0, 1'b0, 0, 1, "cfg1");
        repeat (40) @(posedge clk);

        // ---- W2: one clean frame ------------------------------------------
        rst_n = 1'b0; mem_rst_n = 1'b0; repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (10) @(posedge clk);
        clear_obs();
        prog_cfg(BASE, SB, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB, FB, 1'b1, 1'b0, 0, 1, "cfg2");
        stream(FB/16, seed, 2);
        ck(!stream_short, "W2: a legal frame was refused");
        settle(40000);
        wait_frames(1, 40000, "W2");
        settle(2000);
        ck(ov_bytes_written == 32'(FB), {"W2: bytes_written ",
            $sformatf("%0d", ov_bytes_written), " != ", $sformatf("%0d", FB)});
        frame_verdict("W2", FB, BASE);
        ck(ov_write_slot == 2'd0, "W2: write_slot is not slot 0");
        ck(ov_slot_ready[0] == 1'b1, "W2: slot 0 not published as ready");
        ck(bresp_seen == 2'b00 && !ov_axi_err_sticky, "W2: spurious AXI error");
        $display("W2 done: %0d bursts, %0d beats, irq=%0d undelivered_max=%0d",
                 aw_total, w_beats, irq_count, max_undelivered);

        // ---- W4: the same slot is still owned -----------------------------
        clear_obs();
        prog_cfg(BASE, SB, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB, FB, 1'b1, 1'b0, 0, 1, "cfg3");
        stream(FB/16, seed + 5, 3);
        ck(stream_short, "W4: a busy slot was accepted");
        settle(20000);
        ck(ov_stall_sticky, "W4: writing a busy slot did not latch stall_sticky");
        ck(aw_total == 0, "W4: a busy slot was overwritten anyway");
        ck(w_beats == 0, "W4: a busy slot received writes");

        // ---- W3 + W5: ordered config update, then release and advance -----
        consume(0);
        slot_free(0, "W5");
        ck(ov_slot_ready[0] == 1'b0, "W5: consume did not release slot 0");
        // Two config writes back to back, the second one changing the slot pitch.
        // The pitch decides where a frame lands, so this pair is the test that the
        // snapshot handshake does not swallow the second write.
        prog_cfg(BASE, SB,   FB, 1'b1, 1'b1, 1, 2);      // pitch SB
        cfg_live(BASE, SB,   FB, 1'b1, 1'b1, 1, 2, "cfg4");
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b1, 1, 2);      // pitch SB*2, next cycle
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b1, 1, 2, "cfg5");
        clear_obs();
        stream(FB/16, seed + 9, 3);
        settle(40000);
        wait_frames(2, 40000, "W5");
        settle(2000);
        frame_verdict("W5", FB, BASE);
        ck(ov_bytes_written == 32'(2*FB), {"W5: cumulative bytes ",
            $sformatf("%0d", ov_bytes_written)});
        ck(ov_write_slot == 2'd0, {"W5: write_slot ",
            $sformatf("%0d", ov_write_slot), " != 0"});

        // frame 3 goes to slot 1, which only exists at the NEW pitch: reaching it
        // proves the second config write reached the address computation
        consume(0);
        slot_free(0, "W5-f3");
        clear_obs();
        stream(FB/16, seed + 29, 3);
        settle(40000);
        wait_frames(3, 40000, "W5-f3");
        settle(2000);
        frame_verdict("W5-f3", FB, BASE + SB*2);
        ck(ov_write_slot == 2'd1, {"W5: write_slot ",
            $sformatf("%0d", ov_write_slot), " != 1"});
        $display("W3/W5 done: f2 at %h, f3 at %h, bytes=%0d slot=%0d",
                 BASE, aw_list.size() ? aw_list[0] : '0, ov_bytes_written, ov_write_slot);

        // ---- W8: geometry rewritten while a frame is in flight ------------
        // Contract being proved: the transfer that was already accepted keeps the
        // slot address, byte length and pitch it started with, and the new
        // geometry only takes effect on the next frame.  A snapshot that re-aimed
        // or re-lengthened an in-flight frame would overwrite a slot image the
        // host has been promised, or leave it half written.
        clear_obs();
        stalls_before = stall_rises;
        consume(0); slot_free(0, "W8");
        stream(FB/64, seed + 41, 1);                       // first quarter
        prog_cfg(BASE + 32'h0040_0000, SB*4, FB*2, 1'b1, 1'b1, 1, 2);
        cfg_live(BASE + 32'h0040_0000, SB*4, FB*2, 1'b1, 1'b1, 1, 2, "W8");
        stream_at(FB/64, (FB/16) - (FB/64), seed + 41, 1); // rest of the frame
        ck(!stream_short, "W8: the in-flight frame was refused by a legal update");
        settle(60000);
        wait_frames(4, 60000, "W8");
        frame_verdict("W8", FB, BASE);
        ck(stall_rises == stalls_before,
           "W8: a legal mid-frame update raised a new stall");

        // the next frame must see the new geometry: the update was not lost
        consume(1);
        slot_free(1, "W8-follow");
        clear_obs();
        stream(FB*2/16, seed + 77, 2);
        settle(80000);
        wait_frames(5, 80000, "W8-follow");
        frame_verdict("W8-follow", FB*2, BASE + 32'h0040_0000 + SB*4);
        $display("W8 done: in-flight kept %0d bursts, follow-up %0d bursts",
                 FB/256, aw_total);

        // ---- W6: stream longer than the frame -----------------------------
        consume(1); slot_free(1, "W6a");
        consume(0); slot_free(0, "W6b");
        clear_obs();
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfg6");
        stream((FB/16) + 32, seed + 17, 3);     // 32 beats too many
        settle(60000);
        ck(ov_over_sticky, "W6: an over-long stream did not latch over_sticky");
        ck(w_beats <= (3*FB)/16, {"W6: ", $sformatf("%0d", w_beats),
                                  " beats written, the stream was not bounded"});

        // ---- W7: reset mid-frame, then a clean frame ----------------------
        rst_n = 1'b0; mem_rst_n = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        ck(!ov_busy, "W7: busy stuck after reset");
        clear_obs();
        seed += 23;
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfg7");
        stream(FB/16, seed, 2);
        settle(40000);
        wait_frames(1, 40000, "W7");        // the reset above cleared frames_done
        frame_verdict("W7", FB, BASE);

        // ---- W9: POSITIVE streaming, a frame larger than the payload FIFO --
        // The required product frame is 33,177,600 B and the payload FIFO is
        // 16 KiB, so "the frame must fit in the FIFO" is not a hardware limit, it
        // is a broken contract.  This is the direct acceptance test for the
        // streaming master: 4x the buffer, one frame, one slot publication.
        rst_n = 1'b0; mem_rst_n = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_obs();
        byte_log = 0;                           // streaming compare, no big copy
        prog_cfg(BASE, S64K, F64K, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, S64K, F64K, 1'b1, 1'b0, 0, 1, "cfgW9");
        fbase = int'(ov_frames_done);
        guard_begin(0);
        rb_window = 1'b1;                 // M5: sample the crossed counters live
        stream(F64K/16, seed + 101, 1);
        rb_window = 1'b0;
        ck(rb_regress == 0 && rb_ahead == 0, $sformatf("M5: read-back regressed %0d times and ran ahead of the bus %0d times over %0d destination samples",
                     rb_samples, rb_regress, rb_ahead));
        ck(!stream_short, "W9: a 64 kB frame (4x the payload FIFO) was refused");
        // the assertions that only a streaming master can satisfy:
        ck(first_aw_t != 0 && first_aw_t < last_accept_t,
           "W9: the master did not open its AXI job before the last input beat");
        ck(first_w_t != 0 && first_w_t < last_accept_t,
           "W9: no W beat was written before the last input beat");
        ck(aw_at_last_accept > int'(FCAP/256),
           $sformatf("W9: only %0d bursts were issued while the frame was still streaming; a whole-frame buffer cannot exceed the %0d it holds",
                     aw_at_last_accept, FCAP/256));
        ck(max_undelivered <= HW_CAP,
           $sformatf("W9: %0d accepted beats were buffered undelivered; the intake holds %0d beats plus one in-flight slot",
                     max_undelivered, FDEPTH));
        ck(dut_occ_max <= OCC_LIMIT_HW,
           $sformatf("W9: the payload FIFO itself held %0d beats; the writer's own intake gate limits it to %0d",
                     dut_occ_max, OCC_LIMIT_HW));
        guard_verdict("W9");
        settle(400000);
        wait_frames(fbase + 1, 400000, "W9");
        frame_verdict("W9", F64K, BASE);
        ck(!ov_misalign_sticky, "W9: a legal long frame was refused as a geometry");
        ck(!ov_over_sticky, "W9: a legal frame length latched over_sticky");
        ck(ov_bytes_written == 32'(F64K), {"W9: bytes_written ",
            $sformatf("%0d", ov_bytes_written)});
        ck(ov_slot_ready[0] == 1'b1, "W9: slot not published after the final burst");
        $display("W9 streaming done: %0d bursts %0d beats, undelivered_max=%0d, irq=%0d",
                 aw_total, w_beats, max_undelivered, irq_count);

        // ---- W11: forced W and AW stalls plus an error response -----------
        clear_obs();
        // the previous frame still owns slot 0: a frame is never written into a
        // slot Reader-B has not released, so this test must consume it first
        consume(0); slot_free(0, "W11a");
        clear_obs();
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW11");
        fbase = int'(ov_frames_done);
        guard_begin(0);
        fork
            stream(FB/16, seed + 55, 0);
            begin
                repeat (20) @(posedge mem_clk); stall_w(60);   // DDR write stall
                repeat (10) @(posedge mem_clk); stall_aw(40);  // AW stall
                repeat (10) @(posedge mem_clk); stall_w(60);
            end
        join
        guard_verdict("W11");
        settle(80000);
        wait_frames(fbase + 1, 80000, "W11");
        frame_verdict("W11", FB, BASE);
        // ---- W11b: ONE bad burst invalidates the WHOLE frame ---------------
        // The slot must not be published, no success IRQ, no frames_done credit;
        // the frame is counted as an error frame instead, and the following clean
        // frame still publishes.  Injected on the FIRST, a MIDDLE and the LAST
        // burst, because the last one is where reading the registered error flag
        // instead of this cycle's BRESP used to publish a faulted image.
        consume(0); slot_free(0, "W11b");
        begin
            int pos [3];
            int fb11;
            pos[0] = 0;  pos[1] = int'(FB/256)/2;  pos[2] = int'(FB/256) - 1;
            for (int p = 0; p < 3; p++) begin
                clear_obs();
                fb11 = int'(ov_frames_done);
                inject_at = pos[p];
                err_kind  = (p == 2) ? 2'b11 : 2'b10;   // DECERR on the last burst
                stream(FB/16, seed + 59 + p, 1);
                // The arm stays up until the frame's LAST completion has been
                // answered: the last burst's WLAST - and therefore its B - happens
                // after the intake finished, and disarming here is what made the
                // injection silently miss the very burst under test (proved on the
                // bus: every B carried bresp=00, so the DUT was never given a
                // last-burst fault to react to at all).
                settle(80000);
                inject_at = -1;
                ck(b_err_seen == 1,
                   $sformatf("W11b[%0d]: %0d error completions actually reached the bus; the injected fault never appeared on BVALID, so this check would be vacuous",
                             p, b_err_seen));
                ck(!ov_slot_ready[0],
                   $sformatf("W11b[%0d]: a frame with a failed burst (B #%0d) was published",
                             p, pos[p]));
                ck(dut.ready_r[0] === 1'b0,
                   $sformatf("W11b[%0d]: the memory-side ready bit is set for a faulted frame", p));
                ck(int'(ov_frames_done) == fb11,
                   $sformatf("W11b[%0d]: frames_done credited a faulted frame (%0d)",
                             p, ov_frames_done));
                ck(irq_count == irq_before,
                   $sformatf("W11b[%0d]: a success IRQ fired for a faulted frame", p));
                ck(ov_axi_err_sticky, "W11b: the BRESP was not latched as an AXI error");
                ck(ov_err_frame_sticky,
                   "W11b: the dropped frame was not latched in ov_err_frame_sticky");
                ck(int'(ov_err_frames) == p + 1,
                   $sformatf("W11b: ov_err_frames %0d, expected %0d", ov_err_frames, p+1));
                ck(w_beat_q.size() == 0,
                   $sformatf("W11b[%0d]: %0d accepted beats never reached AXI",
                             p, w_beat_q.size()));
            end
            // and a clean frame afterwards still works, byte for byte
            clear_obs();
            fbase = int'(ov_frames_done);
            stream(FB/16, seed + 71, 1);
            settle(80000);
            wait_frames(fbase + 1, 80000, "W11c");
            frame_verdict("W11c", FB, BASE);
            ck(ov_slot_ready[0] == 1'b1, "W11c: the clean frame after the faults did not publish");
            $display("W11b done: 3 faulted frames suppressed, err_frames=%0d, clean frame published",
                     ov_err_frames);
        end

        // ---- W12: discard a plane at 40 %, with real committed AXI work ------
        // AW stalled, W stalled, Bs pending and gaps on the source, so the abort
        // lands while bursts are presented, in flight and unacknowledged.  The
        // committed work must be finished legally (AXI gives no right to take an
        // AW or a W beat back), nothing further may be accepted for the dead
        // plane, and nothing may be published.  After the ack the next clean
        // frame must be byte exact from its first beat.
        consume(0); slot_free(0, "W12");
        clear_obs();
        fbase = int'(ov_frames_done);
        abort_kill = 1'b1; abort_req = 1'b0;
        rb_window  = 1'b1;
        fork
            stream(FB/16, seed + 83, 2);
            begin
                repeat ((FB/16)*2/5) @(posedge mem_clk);   // 40 percent in
                stall_w(150); stall_aw(90);                       // work in flight
                request_abort("W12");
            end
        join
        rb_window = 1'b0;
        settle(40000);
        ck(!ov_slot_ready[0], "W12: the discarded plane was published");
        ck(int'(ov_frames_done) == fbase,
           "W12: frames_done moved for a discarded plane");
        ck(irq_count == irq_before,
           "W12: the discarded plane raised a completion IRQ");
        ck(!ov_busy, "W12: ov_busy stuck after the discard was acked");
        ck(dut.inflight_m[0] === 1'b0 && dut.active_m === 1'b0 &&
           dut.cnt_frame === 32'd0 && dut.fifo_occ === '0 && dut.job_open === 1'b0,
           "W12: the discarded plane left residue in the slot table, intake or FIFO");
        // no write may appear after the retirement was acked
        begin
            longint w_at_ack;
            w_at_ack = w_beats;
            repeat (300) @(posedge mem_clk);
            ck(w_beats == w_at_ack,
               $sformatf("W12: %0d further W beats after the abort was acknowledged",
                         w_beats - w_at_ack));
        end
        ck(accepted_beats < FB/16, "W12: the whole aborted frame was accepted anyway");
        // the next clean plane: from here any byte of the dead plane reaching the
        // bus is a phantom write / pattern mismatch, because the reference queues
        // are restarted
        w_beat_q.delete(); w_byte_q.delete(); acc_idx = 0;
        clear_obs();
        abort_kill = 1'b0; abort_req = 1'b0;
        fbase = int'(ov_frames_done);
        stream(FB/16, seed + 89, 2);
        settle(60000);
        wait_frames(fbase + 1, 60000, "W12-follow");
        frame_verdict("W12-follow", FB, BASE);
        ck(ov_slot_ready[0] == 1'b1, "W12-follow: the frame after a discard did not publish");
        $display("W12 done: aborted at 40 percent of the frame, acked, recovery frame %0d bursts, err_frames=%0d",
                 aw_total, ov_err_frames);

        // ---- W13: a new-transfer marker inside a live frame is refused ------
        consume(0); slot_free(0, "W13");
        clear_obs();
        abort_kill = 1'b0; abort_req = 1'b0;
        stream_at(0, FB/32, seed + 97, 0);        // half a frame, complete
        ck(!stream_short, "W13: the first half of a legal frame was refused");
        begin
            int n13, acc13;
            n13 = 0; acc13 = 0;
            @(negedge mem_clk);
            s_axis_tvalid <= 1'b1; s_axis_tuser <= 1'b1;
            s_axis_tdata  <= pat_beat(0, seed + 99);
            @(posedge mem_clk);
            while (n13 < 60) begin
                if (s_axis_tvalid && s_axis_tready) acc13++;
                @(posedge mem_clk); n13++;
            end
            s_axis_tvalid <= 1'b0; s_axis_tuser <= 1'b0;
            ck(acc13 == 0, $sformatf("W13: %0d start-of-frame beats were spliced into a live frame", acc13));
        end
        settle(20000);
        ck(ov_over_sticky, "W13: a mid-frame start-of-frame was not latched");
        // recovery: the open frame is discarded and the next arm works
        clear_obs();
        fbase = int'(ov_frames_done);
        request_abort("W13");
        w_beat_q.delete(); w_byte_q.delete(); acc_idx = 0;
        clear_obs();
        stream(FB/16, seed + 103, 1);
        settle(60000);
        wait_frames(fbase + 1, 60000, "W13-follow");
        frame_verdict("W13-follow", FB, BASE);
        $display("W13 done: mid-frame SOF refused and recovered");

        // ---- W14: a completion with nothing behind it cannot be read as proof ----
        // Under the obligation rule (review M6) an answer to a burst this master
        // really presented pays its OWN ledger, even when it arrives after a
        // video reset; W15 proves that.  What must never be swallowed is a
        // completion for a burst nobody issued: with the ledger empty, a B is not
        // evidence that anything the writer cares about reached DDR, so the epoch
        // is poisoned and NOTHING is published until the epoch barrier the PL can
        // actually generate (see the note below the report check).
        rst_n = 1'b0; mem_rst_n = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft();
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW14");
        fbase = int'(ov_frames_done);
        ck(dut.beats_aw == 32'd0 && dut.beats_b == 32'd0 && !dut.job_open,
           "W14: the fixture did not start from an empty ledger");
        spurious_b = 1'b1;                    // one B, for nothing
        repeat (200) @(posedge clk);
        spurious_b = 1'b0;
        ck(aw_total == 0 && w_beats == 0,
           "W14: an injected completion was answered with traffic nobody asked for");
        ck(ov_axi_err_sticky,
           "W14: a B response with no burst outstanding was not reported");
        // fail closed: even a perfectly clean frame is not published in a poisoned
        // epoch, because a B can no longer be read as proof that a write landed.
        // The release below is the AGENT-SIDE boundary this PL can actually
        // generate (epoch_rst_n with rst_n, i.e. the writer's own epoch plus its
        // own reset).  It is NOT a PS S_AXI_HP3_FPD reset: the PS BD has no such
        // pin, so a receiver that answers bursts nobody issued can only truly be
        // retired by a PS-side reset.  What this test proves is the PL half:
        // poison, refuse-to-publish, and release on the epoch - nothing more.
        clear_soft();
        stream(FB/16, seed + 113, 0);
        settle(80000);
        ck(aw_total == int'(FB/256) && w_beats == FB/16 && w_beat_q.size() == 0,
           "W14: the poisoned epoch did not still carry the frame out on the bus");
        ck(!ov_slot_ready[0] && dut.ready_r[0] === 1'b0,
           "W14: a frame was published in a poisoned epoch");
        ck(int'(ov_frames_done) == fbase && irq_count == irq_before,
           "W14: the poisoned epoch credited or announced a frame");
        // the writer's own epoch/reset is the only release the PL can generate
        rst_n = 1'b0; mem_rst_n = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft();
        hold_b = 1'b0;
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW14c");
        fbase = int'(ov_frames_done);
        stream(FB/16, seed + 127, 0);
        settle(80000);
        wait_frames(fbase + 1, 80000, "W14-recover");
        ck(ov_slot_ready[0] == 1'b1, "W14-recover: the epoch barrier did not release the poison");
        $display("W14 done: unsolicited completion reported, epoch poisoned, PL epoch barrier recovered");

        // ---- W15 (M6): a VIDEO reset may not launder write-response debt ----
        // At the card the writer's mem_rst_n is dp_mem_rst_n, the sc7f0_reset_sync
        // of {sys_300m_rst_n, sys_100m_rst_n} into capture_clk
        // (rtl/zu4ev_pcie_card_top.v:249-253).  That is a video/system reset.  The
        // PS HP3 slave has no reset pin at all and is clocked by capture_clk
        // (saxihp3_fpd_aclk), so it does NOT restart: every burst it accepted is
        // still live and every answer it owes is still coming.
        //
        // The obligation rule this test owns: the front end is NOT cleared under
        // debt.  It keeps its ledger, retires the dead job legally, refuses every
        // new burst, and only then admits a new frame - so an old answer can only
        // ever pay the job that is already dead, never a brand new one, because
        // while the debt lives there IS no new one.
        rst_n = 1'b0; mem_rst_n = 1'b0; epoch_hold = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft();
        hold_b = 1'b1;
        // The dead job is programmed to the size that is actually streamed, so its
        // ledger DOES reach completion: every byte of it is on the bus and the
        // four withheld answers WOULD settle it.  That is the only way to test
        // whether an interrupted job is really refused publication, instead of
        // quietly passing because a truncated fixture could never finish anyway.
        prog_cfg(BASE, SB*2, FB/4, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB/4, 1'b1, 1'b0, 0, 1, "cfgW15a");
        stream(FB/4/16, seed + 211, 0);        // 4 bursts presented, none answered
        settle(2000);
        ck(aw_total == 4 && b_count == 0,
           "W15: the fixture did not leave real debt on the interface");
        ck(dut.total_beats == 32'd64 && dut.beats_aw == 32'd64 && dut.beats_w == 32'd64,
           $sformatf("W15: the dead job is not a complete-but-unanswered transfer (%0d/%0d/%0d of %0d)",
                     dut.beats_b, dut.beats_w, dut.beats_aw, dut.total_beats));
        ck(w_beats == 64 && w_beat_q.size() == 0,
           "W15: the debt bursts' own payload did not reach the slave before the reset");
        ck(!ov_slot_ready[0] && int'(ov_frames_done) == 0,
           "W15: an unanswered frame was published");
        aw_at_r = s_aw_all; w_at_r = s_w_all; b_at_r = s_b_all;
        // every AW of this job was already accepted, so the front end owns NO
        // outstanding offer: from here any AW handshake at all is unowned (the
        // aw_win monitor above; the counter itself is no longer masked by mem_rst_n)
        aw_win_owned = (awvalid === 1'b1) ? 1 : 0;
        aw_win_addr  = awaddr;
        aw_win       = 1'b1;
        // video-only reset: mem_rst_n falls, the PCIe epoch does not
        mem_rst_n = 1'b0;
        repeat (6) @(posedge mem_clk);
        ck(dut.fe_owed === 1'b1 && dut.fe_rst_n === 1'b1,
           "W15: the logical reset cleared an AXI front end that still owed the slave");
        ck(dut.ab_state != 3'd0,
           "W15: the deferred reset did not become a legal retirement");
        mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft_keep_q();
        // Re-programme somewhere else and ATTEMPT a new frame while the four old
        // answers are still withheld.  The attempt is the point of the test: the
        // old B must arrive after it, and it must still not be able to pay it.
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW15b");
        fbase = int'(ov_frames_done);
        irq_before = irq_count;
        arm_attempt(4000, seed + 213);
        ck(ov_abort_busy && ov_busy,
           "W15: a writer holding unretired debt did not report it on ov_abort_busy/ov_busy");
        ck(armed_accepts == 0,
           $sformatf("W15: %0d beats of a new frame were armed on top of unretired debt",
                     armed_accepts));
        ck(s_aw_all == aw_at_r && s_w_all == w_at_r,
           $sformatf("W15: %0d new AWs and %0d new W beats were issued before the old debt was retired",
                     s_aw_all - aw_at_r, s_w_all - w_at_r));
        ck(int'(ov_frames_done) == fbase && irq_count == irq_before &&
           !ov_slot_ready[0] && !ov_slot_ready[1],
           "W15: something was published while the old debt was still outstanding");
        // and only NOW do the four old answers arrive: after the new arm attempt
        hold_b = 1'b0;
        wait_retire("W15", 8000);
        ck(b_count == 4 && s_b_all == b_at_r + 4,
           $sformatf("W15: %0d old answers arrived, expected 4", b_count));
        aw_win = 1'b0;
        ck(!ov_axi_err_sticky,
           "W15: an answer that paid its own retained ledger was reported as unsolicited");
        // This is the sharp end: those four answers complete the dead job's own
        // ledger, so a design that publishes on a completed ledger would credit a
        // frame whose slot ownership was already wiped by the video reset
        // (job_slot_m resets to slot 0 with the intake, so the publication would
        // not even name the slot that was written).
        ck(int'(ov_frames_done) == fbase && irq_count == irq_before &&
           !ov_slot_ready[0] && dut.ready_r[0] === 1'b0,
           "W15: an old completion credited, published or announced a frame");
        // recovery: the next clean frame is byte exact and published exactly once
        clear_soft();
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW15c");
        fbase = int'(ov_frames_done);
        guard_begin(0);
        stream(FB/16, seed + 217, 0);
        settle(80000);
        guard_verdict("W15-recover");
        wait_frames(fbase + 1, 80000, "W15-recover");
        frame_verdict("W15-recover", FB, BASE2);
        ck(ov_slot_ready[0] == 1'b1,
           "W15: the retirement did not leave the interface usable again");
        $display("W15 done: debt retired across a video reset, no new AW on top of it, recovery byte exact");

        // ---- W16: an AW the slave has not taken is NOT withdrawn by a reset ----
        // Same obligation, the harder corner: the address is standing on the
        // interface with AWREADY low when the video reset arrives, the payload
        // clock then stops for good measure, and the geometry is re-programmed to
        // a DIFFERENT base while the AW is still held.  A front end that was
        // cleared and restarted would hand over the new base; a front end that
        // kept its obligation must hand over the address it was already holding.
        rst_n = 1'b0; mem_rst_n = 1'b0; epoch_hold = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft();
        hold_b = 1'b1;  hold_aw = 1'b1;        // the slave takes no address at all
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW16a");
        stream(FB/4/16, seed + 307, 0);        // 4 bursts' worth of payload offered
        settle(2000);
        ck(awvalid === 1'b1 && awready === 1'b0,
           "W16: no AW was left presented-but-unaccepted for the reset to find");
        hold_aw_addr = awaddr; hold_aw_val = awvalid;
        ck(aw_total == 0, "W16: the slave accepted an address it was told to hold");
        // the reset arrives with AWVALID up and AWREADY down.  The front end owns
        // exactly one offer, at this address: it may legally be handed over at any
        // time in the window (the slave is free to come back for it), but nothing
        // else may be, and no new AW may be presented at all.
        mem_rst_n = 1'b0;
        aw_win_owned = (awvalid === 1'b1) ? 1 : 0;
        aw_win_addr  = awaddr;
        aw_win       = 1'b1;
        ck(aw_win_owned == 1 && aw_win_addr === hold_aw_addr,
           "W16: the snapshot did not record the owned AW offer at the reset instant");
        repeat (8) @(posedge mem_clk);
        ck(awvalid === 1'b1 && awaddr === hold_aw_addr,
           "W16: the reset withdrew or moved an AW the slave had not taken");
        // and the payload clock stops with the obligation still outstanding
        clk_run = 1'b0;
        #(4000);                               // 4 us of dead payload clock
        clk_run = 1'b1;
        repeat (20) @(posedge mem_clk);
        ck(awvalid === 1'b1 && awaddr === hold_aw_addr,
           "W16: a stopped and restarted clock lost the held address");
        mem_rst_n = 1'b1;                      // logical reset away, debt still owed
        repeat (20) @(posedge clk);
        clear_soft_keep_q();
        // re-programme a DIFFERENT destination while the AW is held, then try to
        // arm a new frame on top of it
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW16b");
        fbase = int'(ov_frames_done);
        irq_before = irq_count;
        arm_attempt(2000, seed + 311);
        ck(armed_accepts == 0 && ov_abort_busy,
           "W16: a new frame was armed while an unaccepted AW was still held");
        // the slave comes back for the address it had been refusing
        aw_at_r = s_aw_all;
        hold_aw = 1'b0;
        repeat (200) @(posedge mem_clk);
        ck(aw_total == 1 && aw_list.size() == 1 && aw_list[0] === hold_aw_addr,
           $sformatf("W16: the held AW was not handed over unchanged (%0d AWs, first=%h, held=%h)",
                     aw_total, aw_list.size() ? aw_list[0] : '0, hold_aw_addr));
        ck(s_w_all >= w_at_r && !ov_slot_ready[0] && !ov_slot_ready[1],
           "W16: the retired burst published something or the clock restart invented data");
        hold_b = 1'b0;
        wait_retire("W16", 8000);
        aw_win = 1'b0;
        ck(!ov_axi_err_sticky,
           "W16: retiring a held AW and its own answers was reported as an AXI fault");
        ck(int'(ov_frames_done) == fbase && irq_count == irq_before,
           "W16: the retired obligation credited or announced a frame");
        clear_soft();
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW16c");
        fbase = int'(ov_frames_done);
        guard_begin(0);
        stream(FB/16, seed + 313, 0);
        settle(80000);
        guard_verdict("W16-recover");
        wait_frames(fbase + 1, 80000, "W16-recover");
        frame_verdict("W16-recover", FB, BASE2);
        $display("W16 done: held AW carried through reset + dead clock, address preserved, recovery byte exact");

        // ---- W17 (M6 gap B): reset with an ACCEPTED AW and only PARTIAL W ------
        // W15 covers a job whose W is complete, W16 covers an AW the slave never
        // took.  This is the third corner, the one a real DDR stall produces: the
        // slave took the address, took some but not all of its beats, and WVALID
        // stands held with WREADY low when the video reset arrives.  What is owed is
        // then "the remaining beats of a burst the slave committed to", so the front
        // end must keep the FIFO contents and the held payload, the slave must be
        // given EXACTLY those beats when it returns, and the interrupted plane must
        // still publish nothing.  The slave keeps noticing everything: its model is
        // not gated on mem_rst_n.
        rst_n = 1'b0; mem_rst_n = 1'b0; epoch_hold = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft();
        hold_b = 1'b1; hold_w = 1'b0; hold_aw = 1'b0; aw_win = 1'b0;
        prog_cfg(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW17a");
        fbase = int'(ov_frames_done);
        irq_before = irq_count;
        fork : w17_partial
            stream(FB/16, seed + 401, 0);        // 256 beats: fits in the burst FIFO
            begin : w17_drive
                int n17;
                n17 = 0;
                // reach a state where an AW covers the frame and W is mid-burst
                while (!(dut.beats_aw >= 32'd32 && dut.beats_w[3:0] != 4'd0 &&
                         dut.beats_w < dut.beats_aw) && n17 < 60000) begin
                    @(posedge mem_clk); n17++;
                end
                hold_w = 1'b1;                   // the slave stops taking W
                n17 = 0;
                while (!(wvalid === 1'b1 && wready === 1'b0) && n17 < 6000) begin
                    @(posedge mem_clk); n17++;
                end
                ck(wvalid === 1'b1 && wready === 1'b0,
                   "W17: the fixture never left WVALID held with WREADY low");
                ck(dut.beats_w !== dut.beats_aw,
                   "W17: W was complete, so this is not a partial-W reset");
                owed17 = longint'(dut.beats_aw) - longint'(dut.beats_w);
                ck(owed17 > 0, $sformatf("W17: the reset found %0d beats owed", owed17));
                hold_w_dat = wdata; hold_w_last = wlast;
                aw_at_r = s_aw_all; w_at_r = s_w_all; b_at_r = s_b_all;
                // the ONLY AW offer the front end may legally hand over from here on
                aw_win_owned = (awvalid === 1'b1) ? 1 : 0;
                aw_owned_at_r = aw_win_owned;
                aw_win_addr  = awaddr;
                aw_win       = 1'b1;
                mem_rst_n    = 1'b0;             // the video reset finds it mid-burst
                repeat (12) @(posedge mem_clk);
                ck(dut.fe_owed === 1'b1 && dut.fe_rst_n === 1'b1,
                   "W17: the logical reset cleared a front end with W beats still owed");
                ck(wvalid === 1'b1 && wdata === hold_w_dat && wlast === hold_w_last,
                   "W17: the reset withdrew or moved the held W payload of an accepted burst");
                ck(dut.ab_state != 3'd0,
                   "W17: the deferred reset did not become a legal retirement");
                // the payload clock dies with the beats still owed, then comes back
                clk_run = 1'b0;
                #(4000);
                clk_run = 1'b1;
                repeat (20) @(posedge mem_clk);
                ck(wvalid === 1'b1 && wdata === hold_w_dat && wlast === hold_w_last,
                   "W17: a stopped and restarted payload clock lost the owed beats");
                ck(s_w_all == w_at_r, "W17: beats were delivered while the clock was stopped");
                mem_rst_n = 1'b1;                // logical reset away, debt still owed
                repeat (20) @(posedge clk);
            end
        join
        clear_soft_keep_q();                     // KEEPS the reference queue
        // re-aim the writer somewhere else while it still owes the beats
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW17b");
        arm_attempt(1500, seed + 403);
        ck(armed_accepts == 0 && ov_abort_busy && ov_busy,
           "W17: a new frame was armed while W beats of an accepted burst were owed");
        ck(s_aw_all == aw_at_r + aw_owned_at_r,
           $sformatf("W17: %0d new AWs were issued on top of the owed beats, beyond the %0d offer that was already presented when the reset was applied",
                     s_aw_all - aw_at_r - aw_owned_at_r, aw_owned_at_r));
        ck(int'(ov_frames_done) == fbase && irq_count == irq_before &&
           ov_slot_ready == 4'd0,
           "W17: something was published while the owed beats were still outstanding");
        // the slave comes back: it must be given EXACTLY the beats it owed, byte
        // exact out of the queue the reset did not touch (del_check is still on)
        hold_w = 1'b0;
        n17w = 0;
        while (s_w_all < w_at_r + owed17 && n17w < 40000) begin @(posedge mem_clk); n17w++; end
        ck(s_w_all == w_at_r + owed17,
           $sformatf("W17: the slave took %0d W beats after returning, it was owed %0d",
                     s_w_all - w_at_r, owed17));
        hold_b = 1'b0;
        wait_retire("W17", 12000);
        aw_win = 1'b0;
        ck(!ov_axi_err_sticky,
           "W17: retiring the owed beats and their answers was reported as an AXI fault");
        ck(int'(ov_frames_done) == fbase && irq_count == irq_before &&
           ov_slot_ready == 4'd0 && dut.ready_r === 4'd0,
           "W17: the interrupted partial frame published, credited or announced a plane");
        // recovery: byte exact and published exactly once
        w_beat_q.delete(); w_byte_q.delete(); acc_idx = 0;
        clear_soft();
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW17c");
        fbase = int'(ov_frames_done);
        guard_begin(0);
        stream(FB/16, seed + 409, 0);
        settle(80000);
        guard_verdict("W17-recover");
        wait_frames(fbase + 1, 80000, "W17-recover");
        frame_verdict("W17-recover", FB, BASE2);
        ck(ov_slot_ready[0] == 1'b1, "W17: the interface was not usable again");
        $display("W17 done: %0d owed W beats carried across reset + dead clock, nothing published, recovery byte exact",
                 owed17);

        // ---- W18 (M6 gap C): a PCIe-ONLY logical reset with the memory side alive ---
        // The contract is asymmetric on purpose, and the asymmetry is the whole test.
        //   * The AXI debt is real traffic the PS HP3 responder already accepted, on a
        //     boundary (mem_rst_n = dp_mem_rst_n, rtl/zu4ev_pcie_card_top.v:3023/:3073)
        //     that a PCIe reset does not touch.  So nothing may be forgotten: no AW, W
        //     or B is dropped, no held VALID is withdrawn, the withheld answers are
        //     still legal when they arrive (not unsolicited), and the ledger is cleared
        //     only after all of them have been paid.
        //   * The JOB is invalidated and never published.  ov_write_slot is only
        //     meaningful together with the slot table, the programmed base address and
        //     the epoch that armed them, and all three are behind the reset that just
        //     fell.  Crediting the new epoch with the old job's - true - write to the
        //     old base would be worse than reporting nothing, so the retirement sequencer
        //     (job_invalid, AB_DRAIN..AB_FENCE) retires the obligation exactly and the
        //     frame is unservable: no ready bit, no IRQ, no frame count.
        //   * Only after that retirement may the epoch-era program, programmed at a
        //     different base, open a job; its first frame then publishes exactly once and
        //     byte exact.
        // The withheld answers are released only AFTER the new base has been installed
        // and a new frame has been offered, so they cannot be paid to anything armed
        // after the reset.
        rst_n = 1'b0; mem_rst_n = 1'b0; epoch_hold = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_soft();
        hold_b = 1'b1; hold_w = 1'b0; hold_aw = 1'b0; aw_win = 1'b0;
        prog_cfg(BASE, SB*2, FB/4, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE, SB*2, FB/4, 1'b1, 1'b0, 0, 1, "cfgW18a");
        stream(FB/4/16, seed + 419, 0);          // 4 bursts presented, none answered
        settle(2000);
        ck(aw_total == 4 && b_count == 0 && dut.beats_aw == 32'd64 &&
           dut.beats_b == 32'd0 && dut.job_open,
           "W18: the fixture did not leave real debt across the reset boundary");
        // Snapshot the OLD job's own evidence now.  clear_soft_keep_q() and prog_cfg
        // both throw aw_list away, and a test that has forgotten the accepted addresses
        // cannot distinguish "the old bursts really went to the old base" from "nothing
        // happened" - which is how a completion can end up counted with no address
        // evidence behind it.  Everything below re-checks this snapshot instead.
        old_aw_n   = aw_list.size();
        old_aw_min = aw_list[0]; old_aw_max = aw_list[0]; old_aw_sum = 0;
        foreach (aw_list[i]) begin
            if (aw_list[i] < old_aw_min) old_aw_min = aw_list[i];
            if (aw_list[i] > old_aw_max) old_aw_max = aw_list[i];
            old_aw_sum += longint'(aw_list[i]);
        end
        old_w_beats = -1;                        // taken below, after the observation clear
        aw_at_r = s_aw_all; w_at_r = s_w_all; b_at_r = s_b_all;
        led_aw_r = longint'(dut.beats_aw); led_b_r = longint'(dut.beats_b);
        fbase = int'(ov_frames_done);
        irq_before = irq_count;
        // ---- the production PCIe boundary -------------------------------------------
        // rst_n is what the card really drops.  u_overlay_writer.epoch_rst_n is the
        // top-level rst_n (rtl/custom_pcie_dma_top.v:1876) and u_overlay_writer.rst_n
        // is dma_rst_n, which that same rst_n feeds through sc7f0_reset_sync (:562,
        // {global_reset_hold_n, ~reg_dma_ctrl[1], rst_n}).  A PCIe-side reset therefore
        // takes BOTH PCIe-domain resets of this module down, dma_rst_n a few clk cycles
        // after the epoch edge, while mem_rst_n (= dp_mem_rst_n,
        // rtl/zu4ev_pcie_card_top.v:3023/:3073) stays up and says nothing about the
        // bursts the PS HP3 responder has already accepted.  epoch_hold is deliberately
        // NOT used here any more: holding epoch_rst_n low while rst_n stays high is only
        // the release latency of that synchroniser, and building the test on it would be
        // exercising a port combination the card cannot hold still.
        rst_n = 1'b0;                            // epoch AND CSR shell; memory stays live
        repeat (40) @(posedge clk);
        ck(longint'(dut.beats_aw) === led_aw_r && longint'(dut.beats_b) === led_b_r,
           "W18: the PCIe reset cleared an AXI ledger it does not own (false quiesce)");
        ck(dut.beats_aw != dut.beats_b,
           "W18: the debt was cancelled instead of staying owed");
        ck(dut.job_invalid === 1'b1 && dut.ab_state != 2'd0,
           "W18: a PCIe reset that found an open job did not invalidate it through the retirement sequencer");
        ck(s_aw_all == aw_at_r && s_w_all == w_at_r,
           "W18: the PCIe reset issued new traffic");
        rst_n = 1'b1;                            // the shell returns; the debt does not
        repeat (20) @(posedge clk);
        ck(ov_busy, "W18: a writer with live debt went quiet through the reset");
        // Everything that gives ov_write_slot any meaning lives behind the reset that
        // just fell, so the CSR view legitimately starts at zero.  What must not happen
        // is a completion of the old job reappearing inside the new epoch.
        ck(ov_frames_done == 32'd0 && ov_slot_ready == 4'd0 && irq_count == irq_before,
           $sformatf("W18: the epoch-era view is not clean (frames_done=%0d ready=%b irq+%0d)",
                     ov_frames_done, ov_slot_ready, irq_count - irq_before));
        repeat (20) @(posedge clk);
        clear_soft_keep_q();
        old_w_beats = accepted_beats;            // cleared to zero here; any later accept is new
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW18b");
        fbase = int'(ov_frames_done);
        irq_before = irq_count;
        arm_attempt(3000, seed + 421);
        ck(armed_accepts == 0 && ov_busy,
           "W18: a new frame was armed on top of the job that survived the reset");
        ck(s_aw_all == aw_at_r && s_w_all == w_at_r,
           "W18: new AWs or W beats were issued on top of the retained obligation");
        ck(irq_count == irq_before && ov_slot_ready == 4'd0,
           $sformatf("W18: the old job's bytes were credited or announced to the epoch-era program (ready=%b irq+%0d)",
                     ov_slot_ready, irq_count - irq_before));
        // The old job's own evidence still says BASE, four consecutive 256 B bursts, and
        // still says the same number of accepted beats: reprogramming BASE2 underneath a
        // retired job neither moved those writes nor invented new ones.
        ck(old_aw_n == 4 && old_aw_min == longint'(BASE) &&
           old_aw_max == longint'(BASE) + 768,
           $sformatf("W18: the accepted AWs of the surviving job are not the four bursts at BASE (n=%0d, %h..%h)",
                     old_aw_n, old_aw_min, old_aw_max));
        ck(accepted_beats == old_w_beats && s_w_all == w_at_r,
           $sformatf("W18: %0d W beats moved after the reset on a job that is retired, not restarted (was %0d)",
                     accepted_beats - old_w_beats, old_w_beats));
        // Only NOW the withheld answers arrive.  They can pay exactly one thing: the
        // ledger that was retained across the reset.  They cannot complete anything for
        // the epoch-era program, which never opened a job, and they cannot resurrect the
        // publication right of a job the reset invalidated.
        hold_b = 1'b0;
        n18 = 0;
        while (s_b_all < b_at_r + 4 && n18 < 20000) begin @(posedge mem_clk); n18++; end
        ck(b_count == 4 && s_b_all == b_at_r + 4,
           $sformatf("W18: %0d of the withheld answers arrived, expected 4", s_b_all - b_at_r));
        ck(!ov_axi_err_sticky,
           "W18: an answer that paid its own retained ledger was reported as unsolicited");
        // The retirement, not the answers, is what ends the job: the ledger is cleared
        // only once the bus is free, the sequencer acknowledges, and the plane is
        // accounted as discarded.  ov_err_frames is reported rather than pinned here:
        // whether a discarded plane also counts as an error frame is a policy the
        // existing W12 discard already answers (it does not), and inventing a number to
        // make this line pass is exactly the thing under review.
        n18 = 0;
        while ((ov_abort_busy || dut.ab_state != 2'd0) && n18 < 8000) begin
            @(posedge clk); n18++;
        end
        settle(20000);
        ck(n18 < 8000, "W18: the epoch-forced retirement never acknowledged");
        ck(dut.beats_aw == 32'd0 && dut.beats_b == 32'd0 && !dut.job_open &&
           !dut.job_invalid,
           $sformatf("W18: the retirement left a ledger behind (aw=%0d b=%0d open=%b invalid=%b)",
                     dut.beats_aw, dut.beats_b, dut.job_open, dut.job_invalid));
        ck(ov_abort_sticky,
           "W18: a plane discarded by the PCIe reset was not accounted as discarded");
        // THE point of this test: the invalidated job publishes nothing, ever.  Its
        // pixels really are in PS DDR at the old base, and that is precisely why its
        // completion may not name a slot of the pool the new epoch programmed.
        ck(irq_count == irq_before && ov_slot_ready == 4'd0 && ov_frames_done == 32'd0,
           $sformatf("W18: the invalidated job published a completion (irq+%0d, ready=%b, frames_done=%0d)",
                     irq_count - irq_before, ov_slot_ready, ov_frames_done));
        // Recovery: only now may the epoch-era program open a job, and its first frame
        // is published exactly once, byte exact, into the pool it actually programmed.
        clear_soft();
        prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1);
        cfg_live(BASE2, SB*2, FB, 1'b1, 1'b0, 0, 1, "cfgW18c");
        fbase = int'(ov_frames_done);
        irq_before = irq_count;
        guard_begin(0);
        stream(FB/16, seed + 431, 0);
        settle(80000);
        guard_verdict("W18-recover");
        wait_frames(fbase + 1, 80000, "W18-recover");
        frame_verdict("W18-recover", FB, BASE2);
        ck(irq_count == irq_before + 1 && ov_write_slot == 2'd0 && ov_slot_ready == 4'd1,
           $sformatf("W18-recover: the first frame of the new epoch announced itself as irq+%0d slot=%0d ready=%b",
                     irq_count - irq_before, ov_write_slot, ov_slot_ready));
        consume(0); slot_free(0, "W18-recover");
        $display("W18 done: PCIe-only reset kept the debt and invalidated the job without publishing it (no ready bit, no IRQ, no frame count), the withheld answers paid the retained ledger legally, and the epoch-era frame published exactly once byte exact");

        // ---- W19 (M10): the bundled completion record, every published frame -----
        // Four slots with auto-advance, so the index really walks 0,1,2,3,0,1: the
        // 1->2 and 3->0 transitions change BOTH bits, which is exactly what two
        // independent level synchronisers plus a separate event edge could not
        // guarantee.  The expected slot comes from the AXI address the bursts went to
        // (see the monitor above), never from a copy of the writer's own crossing, and
        // the ready-bit association is checked separately because ready_r crosses as
        // its own level.
        rst_n = 1'b0; mem_rst_n = 1'b0; epoch_hold = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
        repeat (20) @(posedge clk);
        clear_obs();
        slot_strict = 1'b1;                      // no IRQ without an address-derived slot
        ready_assoc = 1'b1;                      // and exactly its own ready bit
        prog_cfg(BASE, SB, FB, 1'b1, 1'b1, 0, 4);   // 4 slots, auto-advance
        cfg_live(BASE, SB, FB, 1'b1, 1'b1, 0, 4, "cfgW19");
        for (int f19s = 0; f19s < 6; f19s++) begin : w19_walk
            int want19, f19, gap19;
            longint fb19;
            clear_obs();
            want19 = f19s % 4;
            f19    = int'(ov_frames_done);
            gap19  = (f19s % 3) + 1;
            // Alternate the programmed frame length (both 256 B aligned and both
            // inside the slot) and the source gaps, so the completion lands at a
            // different phase of the 125 MHz CSR clock every single time.  The
            // length has to be RE-PROGRAMMED, not just cut short in the stream: the
            // writer ends a frame at its programmed length, nothing else.
            fb19 = (f19s % 2 == 0) ? FB : (FB/2);
            prog_cfg(BASE, SB, fb19, 1'b1, 1'b1, 0, 4);
            cfg_live(BASE, SB, fb19, 1'b1, 1'b1, 0, 4,
                     $sformatf("cfgW19f%0d", f19s));
            stream(fb19/16, seed + 500 + f19s, gap19);
            settle(40000);
            wait_frames(f19 + 1, 40000, $sformatf("W19-f%0d", f19s));
            settle(50);
            ck(irq_count == irq_before + 1,
               $sformatf("W19-f%0d: %0d IRQs, expected exactly one", f19s, irq_count - irq_before));
            ck(ov_write_slot == 2'(want19),
               $sformatf("W19-f%0d: the completion named slot %0d, the bursts went to slot %0d",
                         f19s, ov_write_slot, want19));
            ck(ov_slot_ready == (4'd1 << want19),
               $sformatf("W19-f%0d: ov_slot_ready=%b, expected only slot %0d ready",
                         f19s, ov_slot_ready, want19));
            consume(want19);
            slot_free(want19, $sformatf("W19-f%0d", f19s));
        end

        // (b) the destination clock stops while the record is on its way: it must be
        // delayed, never lost, never duplicated, and never re-labelled.
        begin
            int f19b, irq19b;
            clear_obs();
            // the walk above left the LAST programmed length in the bank; put the
            // full length back so this sub-case is a whole, well-defined frame
            prog_cfg(BASE, SB, FB, 1'b1, 1'b1, 0, 4);
            cfg_live(BASE, SB, FB, 1'b1, 1'b1, 0, 4, "cfgW19b");
            f19b = int'(ov_frames_done); irq19b = irq_count;
            csr_clk_run = 1'b0;                  // stop the CSR clock mid-frame
            stream(FB/16, seed + 533, 0);        // the memory side keeps going
            n19 = 0;
            while (dut.cmpl_req !== 1'b1 && n19 < 20000) begin @(posedge mem_clk); n19++; end
            ck(dut.cmpl_req === 1'b1,
               "W19-csrpause: the completion record was not retained with the CSR clock stopped");
            #(6000);                             // far beyond the offline detection
            ck(dut.cmpl_online === 1'b0,
               "W19-csrpause: the crossing did not notice the stopped destination clock");
            ck(dut.cmpl_req === 1'b1,
               "W19-csrpause: the offline crossing threw the record away");
            ck(irq_count == irq19b && int'(ov_frames_done) == f19b,
               "W19-csrpause: something was announced while the destination clock was stopped");
            csr_clk_run = 1'b1;
            repeat (60) @(posedge clk);
            ck(dut.cmpl_req === 1'b0,
               "W19-csrpause: the parked record was never handed over after the clock returned");
            settle(40000);
            wait_frames(f19b + 1, 40000, "W19-csrpause");
            ck(irq_count == irq19b + 1,
               $sformatf("W19-csrpause: %0d IRQs after the clock returned, expected exactly 1",
                         irq_count - irq19b));
            ck(ov_slot_ready[2] == 1'b1 && ov_write_slot == 2'd2,
               $sformatf("W19-csrpause: the parked record came back as slot %0d ready=%b",
                         ov_write_slot, ov_slot_ready));
            consume(2); slot_free(2, "W19-csrpause");
        end

        // (e) while a record is outstanding the intake stays shut.  start_ok carries
        // !cmpl_req for exactly this: a second frame may not be armed into a slot
        // table whose first completion has not been announced, because that record is
        // the only thing that tells the two frames apart.  This sub-case exists because
        // of mutation testing, not because a run failed: deleting !cmpl_req from
        // start_ok (one token, mutant A_no_cmpl_bound) left the whole suite green, so
        // nothing here was watching the bound it claims to enforce.  Four slots with
        // auto-advance are REQUIRED for this to mean anything: with one slot the next
        // slot is simply busy, and a refusal would prove nothing about cmpl_req.
        begin
            int f19e, irq19e, aw19e, w19e, exp19e;
            clear_obs();
            prog_cfg(BASE, SB, FB, 1'b1, 1'b1, 0, 4);
            cfg_live(BASE, SB, FB, 1'b1, 1'b1, 0, 4, "cfgW19e");
            f19e = int'(ov_frames_done); irq19e = irq_count;
            csr_clk_run = 1'b0;                  // nothing can be announced right now
            stream(FB/16, seed + 557, 0);        // the frame completes into the void
            n19 = 0;
            while (dut.cmpl_req !== 1'b1 && n19 < 20000) begin @(posedge mem_clk); n19++; end
            ck(dut.cmpl_req === 1'b1,
               "W19-block: the completion record never formed with the CSR clock stopped");
            ck(dut.job_open === 1'b0,
               "W19-block: the frame that completed left job_open set");
            aw19e = s_aw_all; w19e = s_w_all;
            arm_attempt(4000, seed + 563);       // a second frame knocks on the door
            ck(armed_accepts == 0,
               $sformatf("W19-block: %0d beats of a SECOND frame were armed while a completion record was still outstanding; start_ok no longer bounds the record",
                         armed_accepts));
            ck(dut.job_open === 1'b0 && dut.cmpl_req === 1'b1,
               "W19-block: the intake opened a job on top of an unannounced completion");
            ck(s_aw_all == aw19e && s_w_all == w19e,
               $sformatf("W19-block: %0d AWs and %0d W beats went out for a frame that was never armed",
                         s_aw_all - aw19e, s_w_all - w19e));
            // ov_frames_done is the CSR-VISIBLE copy, so with the destination clock
            // stopped it must not have moved: same nothing-was-announced statement,
            // seen from the side software actually reads.
            ck(int'(ov_frames_done) == f19e && irq_count == irq19e &&
               ov_slot_ready == 4'd0,
               $sformatf("W19-block: something was announced with the destination clock stopped: frames_done %0d->%0d, irq+%0d, ready=%b",
                         f19e, ov_frames_done, irq_count - irq19e, ov_slot_ready));
            // the parked record comes back exactly once, and only then does the
            // intake reopen: the bound above is a delay, not a deadlock
            csr_clk_run = 1'b1;
            repeat (60) @(posedge clk);
            settle(40000);
            wait_frames(f19e + 1, 40000, "W19-block");
            exp19e = (aw_list.size() != 0)
                         ? int'((longint'(aw_list[0]) - longint'(BASE)) / longint'(SB)) : -1;
            ck(exp19e >= 0, "W19-block: no address evidence for the parked frame");
            ck(irq_count == irq19e + 1 && ov_write_slot == 2'(exp19e) &&
               ov_slot_ready == (4'd1 << exp19e),
               $sformatf("W19-block: the parked record announced as slot %0d ready=%b with irq+%0d, but its bursts went to slot %0d",
                         ov_write_slot, ov_slot_ready, irq_count - irq19e, exp19e));
            consume(exp19e); slot_free(exp19e, "W19-block");
            // and now a new frame IS admitted, byte exact, into the next slot
            clear_obs();
            f19e = int'(ov_frames_done);
            guard_begin((exp19e + 1) % 4);
            stream(FB/16, seed + 569, 0);
            settle(60000);
            guard_verdict("W19-block-recover");
            wait_frames(f19e + 1, 60000, "W19-block-recover");
            frame_verdict("W19-block-recover", FB, BASE);
            consume((exp19e + 1) % 4); slot_free((exp19e + 1) % 4, "W19-block-recover");
        end

        // (c) a PCIe-shell reset with the memory side live may not invent a
        // completion: the record and the IRQ are the same crossing word now, and the
        // destination holds no edge detector that a reset can leave behind.
        begin
            int f19c, irq19c, exp19c;
            clear_obs();
            prog_cfg(BASE, SB, FB, 1'b1, 1'b1, 0, 4);
            cfg_live(BASE, SB, FB, 1'b1, 1'b1, 0, 4, "cfgW19pre");
            f19c = int'(ov_frames_done); irq19c = irq_count;
            // Let the frame COMPLETE first, with the destination clock stopped, so its
            // bundled record is parked in the crossing, and only then drop the PCIe
            // shell.  A frame that is still OPEN when the shell goes down is W18's case
            // and is governed by W18's rule: it is invalidated and must not be published.
            // What is under test here is a completion that already exists: a shell reset
            // may not lose it, duplicate it, or re-label it, and the destination holds no
            // edge detector whose artefact a reset could survive.
            csr_clk_run = 1'b0;
            $display("W19c-phase park @%0t: streaming with the destination clock stopped", $time);
            stream(FB/16, seed + 541, 1);
            n19 = 0;
            while (dut.cmpl_req !== 1'b1 && n19 < 20000) begin @(posedge mem_clk); n19++; end
            ck(dut.cmpl_req === 1'b1,
               "W19-shellreset: the frame never completed, so there was no record to carry across the reset");
            // The reset is held and released on a TIME bound, not on posedge clk: clk IS
            // the destination clock (tb:94, always #4 clk = csr_clk_run && ~clk), so a
            // wait on it while the destination is stopped cannot return - see the clock
            // stall guard above.  Releasing with the clock still stopped is also the
            // ordering the card produces: the PCIe reset release is asynchronous and is
            // only sampled by the destination once that clock is running again.
            $display("W19c-phase shell-reset @%0t: rst_n low, mem_clk alive, record parked", $time);
            rst_n = 1'b0;                        // the whole PCIe shell resets, mem does not
            #(160);                              // 20 destination periods of reset
            rst_n = 1'b1;
            #(80);
            ck(irq_count == irq19c && ov_slot_ready == 4'd0,
               $sformatf("W19-shellreset: %0d IRQs and ready=%b with the destination clock stopped",
                         irq_count - irq19c, ov_slot_ready));
            csr_clk_run = 1'b1;
            $display("W19c-phase announce @%0t: destination clock returned", $time);
            repeat (60) @(posedge clk);          // safe now: the clock is running again
            cfg_live(BASE, SB, FB, 1'b1, 1'b1, 0, 4, "cfgW19c");
            settle(60000);
            // no wait_frames() here on purpose: ov_frames_done is the Gray-crossed CSR
            // view of a memory-side count that moved before this reset, so waiting on it
            // would be testing the synchroniser rather than the completion.
            settle(50);
            exp19c = (aw_list.size() != 0)
                         ? int'((longint'(aw_list[0]) - longint'(BASE)) / longint'(SB)) : -1;
            ck(exp19c >= 0, "W19-shellreset: no address evidence for this frame");
            ck(irq_count == irq19c + 1,
               $sformatf("W19-shellreset: %0d IRQs across a shell reset for one frame, expected exactly 1 (a stale completion reappearing as a phantom is the M10 LOW this closes)",
                         irq_count - irq19c));
            ck(ov_write_slot == 2'(exp19c),
               $sformatf("W19-shellreset: after the reset the completion named slot %0d, its bursts went to slot %0d",
                         ov_write_slot, exp19c));
            ck(ov_slot_ready == (4'd1 << exp19c),
               $sformatf("W19-shellreset: ov_slot_ready=%b after the reset, expected only slot %0d",
                         ov_slot_ready, exp19c));
            consume(exp19c); slot_free(exp19c, "W19-shellreset");
        end

        // (d) a faulted frame raises NO record at all: no IRQ now, none later.
        begin
            int irq19d;
            clear_obs();
            irq19d = irq_count;
            inject_at = 3; err_kind = 2'b10;
            stream(FB/16, seed + 547, 1);
            settle(60000);
            inject_at = -1;
            ck(b_err_seen == 1,
               $sformatf("W19-fault: %0d error completions reached the bus; the injected fault never appeared, so this check would be vacuous", b_err_seen));
            ck(irq_count == irq19d,
               $sformatf("W19-fault: a frame with a failed burst announced itself (%0d IRQs)",
                         irq_count - irq19d));
            ck(dut.cmpl_req === 1'b0 && dut.cmpl_taken === 1'b0,
               "W19-fault: a faulted completion raised a bundled record anyway");
            ck(ov_slot_ready === 4'd0,
               $sformatf("W19-fault: a faulted frame set a ready bit: %b", ov_slot_ready));
        end
        $display("W19 done: 10 completions over four slots checked against the AXI address (0,1,2,3,0,1 + pause/block/reset/fault corners), %0d wrong of %0d checked",
                 slot_mismatch, slot_checked);

        // ---- W20 (review MEDIUM-1): a terminal response taken on the SAME clock as a
        // terminal retirement request ------------------------------------
        // frame_err_now read only the registered job_invalid, but job_invalid is a
        // nonblocking assignment one stage later (rtl/sc7f0_overlay_writer.v:1397), so on
        // the cycle where epoch_fell coincided with the LAST B the intake took the
        // success branch: ready bit at :955, frames_m++ at :956, and the bundled
        // completion record at :962-963.  The discard one clock later clears the ready bit
        // (:975-980) and can retract neither the frame count nor the record - and the
        // record survives rst_n (only mem_rst_n or the announcement ack clears it), so the
        // NEW epoch would be announced a slot and an IRQ for a job this module itself
        // invalidated.  m_axi_bready is tied high (:311), so a response can be taken in
        // any mem_clk cycle: with a link event and the last response one clock apart this
        // is the normal case, not a corner.
        begin : g20
            int coin0, e20, f20, errf20, b20, awd20, wd20, rc20, try20, inv20, req20, tkn20;
            bit hit20;

            // ---- W20a: the epoch edge lands on the terminal-B cycle ----
            w20_setup(BASE, SB*2, 256, seed + 601, "-epoch");
            coin0 = coin_epoch; e20 = irq_count; f20 = int'(ov_frames_done);
            errf20 = int'(ov_err_frames); b20 = s_b_all;
            w20_release(0);
            @(negedge mem_clk);
            ck(coin_epoch > coin0,
               "W20-epoch: the epoch invalidation and the terminal B never shared a mem_clk cycle, so this sub-case would be vacuous");
            ck(dut.job_invalid === 1'b1,
               "W20-epoch: the job that owned that response was not invalidated");
            ck(dut.cmpl_req === 1'b0 && dut.cmpl_taken === 1'b0,
               "W20-epoch: the invalidated job armed a completion record; ready, frames_done and the record publish on the same edge and a later discard cannot retract them");
            rst_n = 1'b1;                       // the shell returns; the debt is still owed
            repeat (20) @(posedge clk);
            rc20 = 0;
            while ((dut.ab_state != 2'd0 || (ov_abort_busy && dut.job_open)) && rc20 < 8000) begin
                @(posedge clk); rc20++;
            end
            ck(rc20 < 8000,
               $sformatf("W20-epoch: the retirement never acknowledged (ab_state=%0d busy=%b open=%b)",
                         dut.ab_state, ov_abort_busy, dut.job_open));
            ck(b_count == 1 && s_b_all == b20 + 1,
               $sformatf("W20-epoch: the coincident response did not pay the ledger it belonged to (%0d new of 1 owed)",
                         s_b_all - b20));
            ck(!ov_axi_err_sticky,
               "W20-epoch: a completion that paid its own ledger was called unsolicited");
            ck(ov_abort_sticky === 1'b1,
               "W20-epoch: the invalidated plane was not accounted as discarded");
            ck(int'(ov_err_frames) == errf20,
               $sformatf("W20-epoch: an OKAY-discard inflated ov_err_frames by %0d (only a real BRESP fault or a poisoned epoch may be charged as a bad frame)",
                         int'(ov_err_frames) - errf20));
            ck(irq_count == e20 && ov_slot_ready === 4'd0 && ov_frames_done === 32'd0,
               $sformatf("W20-epoch: a job invalidated on its own final cycle published (+%0d IRQ, ready=%b, +%0d frames)",
                         irq_count - e20, ov_slot_ready, int'(ov_frames_done) - f20));
            // The new epoch's own program must still land, exactly once.
            clear_soft();
            prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b1, 0, 2);
            cfg_live(BASE2, SB*2, FB, 1'b1, 1'b1, 0, 2, "cfgW20a-rec");
            fbase = int'(ov_frames_done); irq_before = irq_count;
            guard_begin(0);
            stream(FB/16, seed + 431, 0);
            settle(80000);
            guard_verdict("W20a-recover");
            wait_frames(fbase + 1, 80000, "W20a-recover");
            frame_verdict("W20a-recover", FB, BASE2);
            ck(irq_count == irq_before + 1 && ov_write_slot == 2'd0 && ov_slot_ready == 4'd1,
               $sformatf("W20a-recover: the new epoch's first frame announced IRQ +%0d slot %0d ready %b, expected 1/0/0001",
                         irq_count - irq_before, ov_write_slot, ov_slot_ready));
            consume(0);
            slot_free(0, "W20a-recover");
            $display("W20a done: terminal B coincident with the epoch invalidation published nothing (%0d such cycles, %0d of them published)",
                     coin_epoch, coin_publish);

            // ---- W20b: the explicit discard event lands on that same cycle ----
            // The abort request is edge-latched in the clk domain and crosses, so its
            // pulse arrives a few cycles after the write - and that latency depends on
            // the free-running phase between clk and mem_clk.  Rather than assume it, the
            // fixture sweeps the offset, and it REFUSES to pass unless the overlap was
            // actually reached: an unhit sweep would be an empty test.
            hit20 = 1'b0;
            for (try20 = 0; try20 < 14 && !hit20; try20++) begin
                w20_setup(BASE, SB*2, 256, seed + 700 + try20, "-abort");
                coin0 = coin_abort; e20 = irq_count; f20 = int'(ov_frames_done);
                errf20 = int'(ov_err_frames); b20 = s_b_all;
                ov_abort = 1'b1;
                @(posedge clk);
                ov_abort = 1'b0;                // the request itself is edge-latched
                repeat (try20) @(posedge mem_clk);
                @(negedge mem_clk); hold_b = 1'b0;
                @(posedge mem_clk); @(posedge mem_clk);
                @(negedge mem_clk);
                if (coin_abort > coin0) begin
                    hit20 = 1'b1;
                    // Sampled NOW, before the retirement has run: job_invalid is cleared
                    // when the retirement finishes, so asking for it later would only
                    // prove that the sequencer completed.
                    inv20 = int'(dut.job_invalid);  req20 = int'(dut.cmpl_req);
                    tkn20 = int'(dut.cmpl_taken);
                    rc20 = 0;
                    while ((dut.ab_state != 2'd0 || (ov_abort_busy && dut.job_open)) &&
                           rc20 < 8000) begin @(posedge clk); rc20++; end
                    ck(rc20 < 8000, "W20-abort: the retirement after the coincident discard never acknowledged");
                    ck(inv20 == 1 && req20 == 0 && tkn20 == 0,
                       $sformatf("W20-abort: on the cycle its discard arrived the job was not invalidated or did reach a completion record (invalid=%0d req=%0d taken=%0d)",
                                 inv20, req20, tkn20));
                    ck(b_count == 1 && s_b_all == b20 + 1 && !ov_axi_err_sticky,
                       "W20-abort: the coincident response did not legally pay the ledger it belonged to");
                    ck(int'(ov_err_frames) == errf20 && irq_count == e20 &&
                       ov_slot_ready === 4'd0 && ov_frames_done === 32'd0,
                       $sformatf("W20-abort: a job discarded on its own final cycle published (+%0d IRQ, ready=%b, +%0d frames, +%0d err frames)",
                                 irq_count - e20, ov_slot_ready,
                                 int'(ov_frames_done) - f20, int'(ov_err_frames) - errf20));
                    // and the module must still be usable afterwards
                    clear_soft();
                    prog_cfg(BASE, SB*2, FB, 1'b1, 1'b1, 0, 2);
                    cfg_live(BASE, SB*2, FB, 1'b1, 1'b1, 0, 2, "cfgW20b-rec");
                    fbase = int'(ov_frames_done); irq_before = irq_count;
                    guard_begin(0);
                    stream(FB/16, seed + 433, 0);
                    settle(80000);
                    guard_verdict("W20b-recover");
                    wait_frames(fbase + 1, 80000, "W20b-recover");
                    frame_verdict("W20b-recover", FB, BASE);
                    ck(irq_count == irq_before + 1 && ov_write_slot == 2'd0 &&
                       ov_slot_ready == 4'd1,
                       "W20b-recover: the frame after the coincident discard did not announce exactly once");
                    consume(0);
                    slot_free(0, "W20b-recover");
                    $display("W20b done: terminal B coincident with the discard event at offset %0d published nothing (%0d such cycles, %0d of them published)",
                             try20, coin_abort, coin_publish);
                end else begin
                    // No overlap on this offset: the response was taken either before the
                    // request arrived (a legitimate completion of a job that was still
                    // owned) or after job_invalid was already registered (covered by
                    // W18).  Retire cleanly and try the next offset.
                    rc20 = 0;
                    while ((dut.ab_state != 2'd0 || (ov_abort_busy && dut.job_open)) &&
                           rc20 < 8000) begin @(posedge clk); rc20++; end
                    if (ov_slot_ready !== 4'd0) begin consume(0); slot_free(0, "W20b-sweep"); end
                end
            end
            ck(hit20,
               "W20-abort: fourteen offsets never put the discard event and the terminal B on the same mem_clk cycle; this sub-case would be vacuous");
            ck(coin_publish == 0,
               $sformatf("W20: %0d terminal publication cycles were taken while a retirement request was active", coin_publish));
            $display("W20 done: epoch/fe/abort coincidences counted %0d/%0d/%0d, cycles published anyway %0d (the memory-side case cannot publish because its frame accounting is reset by the same edge, so only the epoch and discard cases are asserted)",
                     coin_epoch, coin_fe, coin_abort, coin_publish);
        end

        // ---- W21 (review MEDIUM-2): the reset split the card produces and this
        // fixture could not build: DMA_CTRL[1] / the BAR0 global flush drop
        // u_overlay_writer.rst_n = dma_rst_n while epoch_rst_n = rst_n and mem_rst_n
        // stay HIGH (rtl/custom_pcie_dma_top.v:561-564, :1862, :1876).  Nothing raises
        // epoch_inval_needed or fe_retire_needed for that split, and nothing should: the
        // AXI ledger and job_open belong to fe_rst_n (:1302-1320) precisely because the
        // interconnect still owns those bursts.  What is pinned down here is the honest
        // contract, including the recovery, which is EXPLICIT:
        //   * the shell resets, so it publishes nothing and cannot even REQUEST a discard
        //     (the abort request register is in the clk/rst_n domain, :1112-1118),
        //   * the front end keeps flowing the payload it already owns and keeps its own
        //     responses: no unowned address, no withdrawn VALID, no lost beat,
        //   * nothing announces while the shell is down and nothing announces later for
        //     a frame that never completed,
        //   * recovery is ov_abort once the shell returns, or a later epoch / memory
        //     reset; the job stays owed and the epoch ledger stays armed until then, so
        //     the module is fail-closed rather than quietly "quiesced".
        // The ingress 100 ms bounded stall is NOT a recovery path for this module: it is
        // reset by the same dma_rst_n (rtl/custom_pcie_dma_top.v:1803-1804) and its
        // timeout abandons only its own read tags (rtl/sc7f0_overlay_ingress.v:765-790).
        // That module is not instantiated here, so the claim is not tested, only cited.
        begin : g21
            int awd21, wd21, b21, e21, f21, rc21, nb21;
            longint amin21, amax21;

            rst_n = 1'b0; dma_soft_rst = 1'b0; mem_rst_n = 1'b0; epoch_hold = 1'b0;
            repeat (6) @(posedge clk);
            rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
            repeat (20) @(posedge clk);
            clear_soft();
            b_latency_max = 4;
            // The payload is pushed into the burst buffer while the slave refuses the W
            // channel, so at the moment the shell drops there is REAL work outstanding in
            // both directions: AWs accepted, beats owed, completions owed.  Without that
            // there is nothing left to flow and the phase would prove nothing.
            hold_b = 1'b1; hold_w = 1'b1; hold_aw = 1'b0; aw_win = 1'b0;
            prog_cfg(BASE, SB*2, FB, 1'b1, 1'b1, 0, 2);
            cfg_live(BASE, SB*2, FB, 1'b1, 1'b1, 0, 2, "cfgW21");
            stream(FB/16/4, seed + 811, 0);      // a QUARTER frame: it cannot complete
            settle(4000);
            ck(dut.job_open === 1'b1 && dut.fe_owed === 1'b1 &&
               dut.beats_aw == 32'(FB/4/16) && dut.beats_w == 32'd0 && b_count == 0,
               $sformatf("W21: the fixture did not leave a partial frame with real debt (open=%b aw=%0d w=%0d bcount=%0d)",
                         dut.job_open, dut.beats_aw, dut.beats_w, b_count));
            awd21 = s_aw_all; wd21 = s_w_all; b21 = s_b_all;
            e21 = irq_count; f21 = int'(ov_frames_done);

            // ---- the shell-only reset, with the epoch and memory side both live ----
            @(negedge clk); dma_soft_rst = 1'b1;
            repeat (200) @(posedge clk);
            ck(dma_rst_n === 1'b0 && epoch_rst_n === 1'b1 && mem_rst_n === 1'b1,
               $sformatf("W21: the fixture did not build the split (dma_rst_n=%b epoch_rst_n=%b mem_rst_n=%b)",
                         dma_rst_n, epoch_rst_n, mem_rst_n));
            // The interconnect does not stop answering because a shell went down, and the
            // job this module still owns keeps the payload it had already buffered: the
            // beats come out and the completions come back, to the same frozen frame.
            hold_w = 1'b0; hold_b = 1'b0;
            settle(20000);
            nb21 = int'(FB/4/256);                // bursts this quarter-frame owns
            ck(dut.beats_aw == dut.beats_w && dut.beats_b == dut.beats_w &&
               dut.beats_w == 32'(FB/4/16),
               $sformatf("W21: the still-owned job lost or gained beats across the shell reset (aw=%0d w=%0d b=%0d of %0d)",
                         dut.beats_aw, dut.beats_w, dut.beats_b, FB/4/16));
            // Ownership is proven by the addresses the slave actually accepted, not by a
            // pointer inside the DUT: addr_r legitimately advances through the frame.
            amin21 = aw_list[0]; amax21 = aw_list[0];
            foreach (aw_list[i]) begin
                if (aw_list[i] < amin21) amin21 = aw_list[i];
                if (aw_list[i] > amax21) amax21 = aw_list[i];
            end
            ck(aw_list.size() == nb21 && amin21 == longint'(BASE) &&
               amax21 + 256 <= longint'(BASE) + FB,
               $sformatf("W21: traffic after the shell reset left the frozen job (%0d AW, %x..%x, expected %0d inside %0x..%0x)",
                         aw_list.size(), amin21, amax21, nb21, BASE, longint'(BASE) + FB));
            ck(awd21 == s_aw_all && wd21 + int'(FB/4/16) == s_w_all &&
               b21 + nb21 == s_b_all,
               $sformatf("W21: interface totals do not add up (aw %0d->%0d want +%0d, w %0d->%0d want +%0d, b %0d->%0d want +%0d)",
                         awd21, s_aw_all, 0, wd21, s_w_all, int'(FB/4/16), b21, s_b_all, nb21));
            ck(irq_count == e21 && int'(ov_frames_done) == f21,
               $sformatf("W21: a shell-only reset made the module publish (+%0d IRQ, +%0d frames)",
                         irq_count - e21, int'(ov_frames_done) - f21));

            // ---- the shell returns; the job is still owned, still owed, still silent --
            dma_soft_rst = 1'b0;
            repeat (40) @(posedge clk);
            ck(dut.job_open === 1'b1 && dut.fe_owed === 1'b1 && dut.start_ok === 1'b0,
               $sformatf("W21: after the shell reset the ledger was neither kept nor honestly held open (open=%b owed=%b start_ok=%b)",
                         dut.job_open, dut.fe_owed, dut.start_ok));
            ck(ov_busy === 1'b1 && ov_slot_ready === 4'd0 && irq_count == e21 &&
               ov_frames_done === 32'd0 && dut.cmpl_req === 1'b0,
               $sformatf("W21: an abandoned partial frame published or hid its state (busy=%b ready=%b IRQ +%0d frames %0d record=%b)",
                         ov_busy, ov_slot_ready, irq_count - e21, ov_frames_done, dut.cmpl_req));
            // Nothing recovers on its own: prove the module is fail-closed BEFORE the
            // explicit request, then make the request and require an honest retirement.
            rc21 = 0;
            while (ov_abort_busy === 1'b0 && dut.job_open === 1'b1 && rc21 < 2000) begin
                @(posedge clk); rc21++;
            end
            ck(rc21 >= 2000 && dut.job_open === 1'b1,
               "W21: the module retired or republished an abandoned job without being asked to");
            b21 = s_b_all; awd21 = s_aw_all; wd21 = s_w_all;
            ov_abort = 1'b1; @(posedge clk); ov_abort = 1'b0;
            rc21 = 0;
            while ((dut.job_open === 1'b1 || dut.ab_state != 2'd0 ||
                    (ov_abort_busy && dut.job_open)) && rc21 < 20000) begin
                @(posedge clk); rc21++;
            end
            ck(rc21 < 20000,
               $sformatf("W21: the explicit discard never retired the abandoned job (open=%b ab_state=%0d busy=%b)",
                         dut.job_open, dut.ab_state, ov_abort_busy));
            settle(200);
            ck(dut.job_open === 1'b0 && dut.beats_aw == 32'd0 && dut.beats_b == 32'd0 &&
               dut.fe_owed === 1'b0,
               $sformatf("W21: the ledger did not end empty (open=%b aw=%0d b=%0d owed=%b)",
                         dut.job_open, dut.beats_aw, dut.beats_b, dut.fe_owed));
            ck(s_b_all == b21 && s_aw_all == awd21 && s_w_all == wd21,
               $sformatf("W21: a job that had already paid its ledger issued %0d AW, %0d W and %0d B during retirement",
                         s_aw_all - awd21, s_w_all - wd21, s_b_all - b21));
            ck(ov_abort_sticky === 1'b1 && irq_count == e21 && ov_slot_ready === 4'd0 &&
               ov_frames_done === 32'd0 && int'(ov_err_frames) == 0,
               $sformatf("W21: the discard was not accounted as a discard (sticky=%b IRQ +%0d ready=%b frames %0d err %0d)",
                         ov_abort_sticky, irq_count - e21, ov_slot_ready, ov_frames_done,
                         ov_err_frames));
            ck(!ov_axi_err_sticky, "W21: an abandoned job made the module claim an unsolicited completion");
            // legal recovery: the pool is free again and the next frame is byte exact
            clear_soft();
            prog_cfg(BASE2, SB*2, FB, 1'b1, 1'b1, 0, 2);
            cfg_live(BASE2, SB*2, FB, 1'b1, 1'b1, 0, 2, "cfgW21-rec");
            fbase = int'(ov_frames_done); irq_before = irq_count;
            guard_begin(0);
            stream(FB/16, seed + 823, 0);
            settle(80000);
            guard_verdict("W21-recover");
            wait_frames(fbase + 1, 80000, "W21-recover");
            frame_verdict("W21-recover", FB, BASE2);
            ck(irq_count == irq_before + 1 && ov_write_slot == 2'd0 && ov_slot_ready == 4'd1,
               "W21-recover: the frame after an explicit discard did not announce exactly once");
            consume(0);
            slot_free(0, "W21-recover");
            $display("W21 done: shell-only reset (rst_n=0, epoch_rst_n=1, mem_rst_n=1) with a partial frame in flight published nothing, kept the ledger and the armed epoch, and recovered only on an explicit discard");
        end


        // ---- W10: the REQUIRED frame, 3840x2160 RGBA8888 ------------------
        // 33,177,600 B = 2,073,600 beats = 129,600 bursts of 256 B, line pitch
        // 15,360 B, into PS DDR at 300 MHz / 128 b.  Every byte is compared
        // against the reference captured on accepted tvalid && tready; nothing is
        // sampled out, no prefix is skipped, no checksum stands in.  This proves
        // the logic, the byte/burst/address accounting and the streaming shape;
        // it is NOT a board bandwidth measurement.
        if (!no4k) begin : g4k
            rst_n = 1'b0; mem_rst_n = 1'b0;
            repeat (6) @(posedge clk);
            rst_n = 1'b1; repeat (6) @(posedge mem_clk); mem_rst_n = 1'b1;
            repeat (20) @(posedge clk);
            clear_obs();
            b_latency_max = 3;
            prog_cfg(BASE4K, S4K, F4K, 1'b1, 1'b0, 0, 1);
            cfg_live(BASE4K, S4K, F4K, 1'b1, 1'b0, 0, 1, "cfgW10");
            fbase = int'(ov_frames_done);
            guard_begin(0);
            rb_window = 1'b1;
            $display("W10 start @%0t: %0d bytes, %0d beats, %0d bursts",
                     $time, F4K, B4K, U4K);
            stream(B4K, seed + 211, 0);
            rb_window = 1'b0;
            ck(rb_regress == 0 && rb_ahead == 0,
               $sformatf("W10: the Gray-crossed read-back regressed %0d times or ran ahead %0d times over the 4K frame",
                         rb_regress, rb_ahead));
            guard_verdict("W10");
            ck(!stream_short, "W10: the 4K60 RGBA8888 frame was refused");
            ck(first_aw_t != 0 && first_aw_t < last_accept_t,
               "W10: the master did not start writing before the frame ended");
            ck(aw_at_last_accept > int'(FCAP/256),
               $sformatf("W10: %0d bursts issued while the frame was still streaming",
                         aw_at_last_accept));
            ck(max_undelivered <= HW_CAP,
               $sformatf("W10: %0d accepted beats were buffered undelivered; the intake holds %0d beats plus one in-flight slot",
                         max_undelivered, FDEPTH));
            ck(dut_occ_max <= OCC_LIMIT_HW,
               $sformatf("W10: the payload FIFO itself held %0d beats; the writer's own intake gate limits it to %0d",
                         dut_occ_max, OCC_LIMIT_HW));
            $display("W10 streamed @%0t: accepted=%0d delivered=%0d aw=%0d undelivered_max=%0d fifo_occ_max=%0d",
                     $time, accepted_beats, w_beats, aw_total, max_undelivered, dut_occ_max);
            settle(40_000_000);
            wait_frames(fbase + 1, 40_000_000, "W10");
            frame_verdict("W10", F4K, BASE4K);
            // one frame -> one slot publication, one IRQ, after the last B
            ck(ov_slot_ready[0] == 1'b1, "W10: 4K frame did not publish its slot");
            ck(ov_write_slot == 2'd0, "W10: write_slot wrong for the 4K frame");
            ck(last_b_t != 0, "W10: no B response observed");
            ck(!ov_stall_sticky && !ov_over_sticky && !ov_axi_err_sticky,
               "W10: a clean 4K frame raised a sticky fault");
            $display("W10 done @%0t: bursts=%0d beats=%0d undelivered_max=%0d irq=%0d errors=%0d",
                     $time, aw_total, w_beats, max_undelivered, irq_count, errors);
        end else
            $display("W10 (full 4K60 frame) SKIPPED by +NO4K");

        $display("== sc7f0_overlay_writer: %0d checks, %0d errors, accepted=%0d delivered=%0d, csr_changes=%0d csr_commits=%0d ==",
                 checks, errors, accepted_beats, w_beats, cfg_changes, cfg_commits);
        // M10: the completion is ONE bundled crossing word now, so the verdict is the
        // per-completion identity check above (address-derived expected slot).  The
        // inter-completion gap measurement is gone: it only ever justified the
        // withdrawn two-level scheme, and no gap makes independent levels and an
        // independent event arrive together.
        ck(exp_slot_q.size() == 0,
           $sformatf("M10: %0d published completions never produced an IRQ (lost record)",
                     exp_slot_q.size()));
        $display("M5/M10: read-back samples=%0d regress=%0d ahead=%0d, completions checked=%0d (wrong %0d, no address evidence %0d), slot-span faults=%0d",
                 rb_samples, rb_regress, rb_ahead, slot_checked, slot_mismatch,
                 slot_unknown, slot_span_bad);
        ck(slot_mismatch == 0,
           $sformatf("M10: %0d of %0d completions named the wrong slot, announced a completion with no frame behind it, or (strict mode) had no address-derived expectation",
                     slot_mismatch, slot_checked));
        if (errors == 0) begin
            $display("OVERLAY_WRITER_PASS");
            $finish;
        end else begin
            // A failing regression must be a NON-ZERO process exit, not a line of
            // text that a caller can throw away with a pipe.
            $display("OVERLAY_WRITER_FAIL errors=%0d", errors);
            $fatal(1, "sc7f0_overlay_writer regression failed");
        end
    end

    initial begin
        // bounded watchdog: enough sim time for the full 4K60 frame + slack
        #400_000_000;
        $display("OVERLAY_WRITER_FAIL (watchdog)");
        $fatal(1, "watchdog");
    end
endmodule
