`timescale 1ns/1ps
// ============================================================================
// tb/sc7f0_alpha_blend_exact_tb.sv - EXACT-maths + 3-stage-elastic regression
// for rtl/sc7f0_alpha_blend_2ppc.v (three-cones review B).
//
// This suite is deliberately INDEPENDENT of the DUT's own formula.  The golden
// is an unsigned wide integer expression
//
//     out_c = ((255 - A) * BG_c + A * FG_c + 127) / 255
//
// which is exactly round(BG + A*(FG-BG)/255) and shares no arithmetic with the
// 257/65536 + sign-selected-bias form the RTL uses.  The historical
// `BG + ((257p + 32767) >>> 16)` mirror of the DUT is NOT used anywhere here:
// it was one LSB wrong on both signs and would have hidden the very defect this
// suite exists to catch.
//
//   Q1  EXHAUSTIVE: every signed p in [-65025, 65025] (131051 values) through
//       the production function sc7f0_alpha_blend_2ppc.quant_round255, against
//       sign-round(|p|/255).
//   Q2  the two review witnesses through that same production function.
//   T1  all 256 alphas x BG/FG corner grid, per component, both pixels
//   T2  random (A,BG,FG) triples with randomised mready stalls
//   T3  the two witnesses SIMULTANEOUSLY in one beat (pixel 0 positive, pixel 1
//       negative) - a one-sided quantizer cannot survive it
//   T4  blend_enable = 0 passthrough, alpha_force_opaque = 1
//   T6  steady II = 1 with every ready held, plus exact counter equality
//   T7  pipeline_busy covers ALL THREE stages, and the stage-0-only cycle class
//       (which a registered stage1||mvalid busy reports as idle) is exercised
//   T8  SOF/EOL sideband mismatch -> discard + lock_lost_count; `unlock`
//       re-lock; mid-pipeline reset + resync
//   T9  output stable while m_axis_tvalid && !m_axis_tready (output monitor)
//
// Every wait is bounded; a watchdog turns a stuck wait into a reported FAIL.
//
// Pre-fix baseline (the S snapshot, module renamed): compile it and add
//   -d PRE_FIX -d ALPHA_DUT=sc7f0_alpha_blend_2ppc_old
// Q1 / Q2 / T7 are skipped because that code does not exist pre-fix; the
// numeric tests then produce a FINITE FUNCTIONAL FAIL, which is the point.
// ============================================================================
`ifndef ALPHA_DUT
  `define ALPHA_DUT sc7f0_alpha_blend_2ppc
`endif

module sc7f0_alpha_blend_exact_tb;
    localparam integer PPC  = 2;
    localparam integer NEXP = 20000;              // scoreboard capacity

    reg clk = 0, rst_n = 0;
    always #3.3 clk = ~clk;

    reg  [PPC*32-1:0] bd = 0, od = 0;
    reg               bv = 0, ov = 0, bl = 0, ol = 0, bu = 0, ou = 0;
    wire              bready, oready;
    wire [PPC*24-1:0] mtdata;
    wire              mtvalid, mtlast, mtuser, busy;
    reg               mready = 1;
    reg               blend_en = 1, force_opaque = 0, unlock = 0;
    wire              locked;
    wire [31:0]       lock_lost, sat_cnt, beats;

    `ALPHA_DUT #(.PPC(PPC), .QUEUE_DEPTH(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .blend_enable(blend_en), .alpha_force_opaque(force_opaque),
        .unlock(unlock),
        .s_b_axis_tdata(bd), .s_b_axis_tvalid(bv), .s_b_axis_tready(bready),
        .s_b_axis_tlast(bl),  .s_b_axis_tuser(bu),
        .s_o_axis_tdata(od), .s_o_axis_tvalid(ov), .s_o_axis_tready(oready),
        .s_o_axis_tlast(ol),  .s_o_axis_tuser(ou),
        .m_axis_tdata(mtdata), .m_axis_tvalid(mtvalid), .m_axis_tready(mready),
        .m_axis_tlast(mtlast), .m_axis_tuser(mtuser),
        .locked(locked), .pipeline_busy(busy),
        .lock_lost_count(lock_lost), .sat_watchdog_count(sat_cnt),
        .beats_blended(beats));

    int errors = 0, checks = 0, booked = 0, outidx = 0;
    task automatic fail(input string m);
        errors++;
        if (errors <= 40) $display("FAIL @%0t: %s", $time, m);
    endtask
    task automatic ck(input bit c, input string m);
        checks++; if (!c) fail(m);
    endtask

    // ------------------------------------------------------------------------
    // independent golden.  pixel packing: [31:24] A, [23:16] R, [15:8] B, [7:0] G
    // output pixel packing:                [23:16] R, [15:8]  B, [7:0]  G
    // ------------------------------------------------------------------------
    function automatic [23:0] golden_rgb(input [31:0] bp, input [31:0] op);
        int           a;
        int           bgc, fgc;
        logic [23:0]  acc;
        acc = 24'h0;
        a   = op[31:24];
        for (int c = 0; c < 3; c = c + 1) begin
            case (c)
                0:       begin bgc = bp[23:16]; fgc = op[23:16]; end
                1:       begin bgc = bp[15:8];  fgc = op[15:8];  end
                default: begin bgc = bp[7:0];   fgc = op[7:0];   end
            endcase
            acc[(2-c)*8 +: 8] = 8'((((255 - a) * bgc + a * fgc + 127) / 255) & 32'hFF);
        end
        golden_rgb = acc;
    endfunction

    function automatic [31:0] px(input [7:0] a, input [7:0] r,
                                 input [7:0] b, input [7:0] g);
        px = {a, r, b, g};
    endfunction

    // ------------------------------------------------------------------------
    // expected stream
    // ------------------------------------------------------------------------
    logic [PPC*24-1:0] exp_word [0:NEXP-1];
    bit          exp_sof  [0:NEXP-1];
    bit          exp_eol  [0:NEXP-1];

    // ------------------------------------------------------------------------
    // output scoreboard (preponed sampling; never numerically compensated) plus
    // the T9 stability rule and the T6 interleave measurement
    // ------------------------------------------------------------------------
    longint cyc = 0;
    int     outs_since_reset = 0;      // monotone within a reset epoch
    int     consumes_seen = 0;         // front-stage consume count (diagnostic)
    int     sent_total = 0;            // pairs presented, discarded ones included
    longint mark_cyc_first = -1, mark_cyc_last = -1;
    int     mark_idx = 0;
    bit [PPC*24-1:0] held_data;
    bit              held_sof, held_eol, stalled;

    always @(posedge clk) begin
        cyc++;
        if (rst_n) begin
`ifndef PRE_FIX
            if (dut.consume) consumes_seen++;
`endif
            if (stalled && (!mtvalid || mtdata !== held_data ||
                            mtuser !== held_sof || mtlast !== held_eol))
                fail("T9: output changed or dropped while tvalid && !tready");
            stalled    <= mtvalid && !mready;
            held_data  <= mtdata;
            held_sof   <= mtuser;
            held_eol   <= mtlast;
            if (mtvalid && mready) begin
                if (outidx >= booked) begin
                    fail($sformatf("output %0d appeared with nothing booked", outidx));
                end
                else begin
                    if (outidx < NEXP) begin
                        if (mtdata !== exp_word[outidx])
                            fail($sformatf("out[%0d]=%h expected %h (independent golden)",
                                           outidx, mtdata, exp_word[outidx]));
                        if (mtuser !== exp_sof[outidx])
                            fail($sformatf("out[%0d] TUSER=%b expected %b",
                                           outidx, mtuser, exp_sof[outidx]));
                        if (mtlast !== exp_eol[outidx])
                            fail($sformatf("out[%0d] TLAST=%b expected %b",
                                           outidx, mtlast, exp_eol[outidx]));
                    end
                    if (outidx >= mark_idx) begin
                        if (mark_cyc_first < 0) mark_cyc_first = cyc;
                        mark_cyc_last = cyc;
                    end
                    outs_since_reset++;
                    outidx++;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // T7: pipeline_busy must cover all three stages, combinationally
    // ------------------------------------------------------------------------
`ifndef PRE_FIX
    int busy_checks = 0, busy_bad = 0, s0_only = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            busy_checks++;
            if (busy !== (dut.stage0_valid || dut.stage1_valid || dut.m_axis_tvalid)) begin
                busy_bad++;
                if (busy_bad <= 5)
                    $display("FAIL @%0t: pipeline_busy=%b but s0=%b s1=%b m=%b",
                             $time, busy, dut.stage0_valid, dut.stage1_valid, dut.m_axis_tvalid);
            end
            if (dut.stage0_valid && !dut.stage1_valid && !dut.m_axis_tvalid) begin
                s0_only++;
                if (!busy) begin
                    busy_bad++;
                    $display("FAIL @%0t: busy idle while a token sits in stage 0 only", $time);
                end
            end
        end
    end
`endif

    // ------------------------------------------------------------------------
    // drivers
    // ------------------------------------------------------------------------
    task automatic clear_inputs;
        bv <= 1'b0; ov <= 1'b0; bu <= 1'b0; ou <= 1'b0; bl <= 1'b0; ol <= 1'b0;
    endtask

    // One frame start is required before the compositor will emit anything;
    // `need_sof` makes the first pair after any (re-)lock carry it.
    bit need_sof = 1;

    // Core pair driver.  The two planes are INDEPENDENT AXI-Stream interfaces:
    // each one takes the beat as soon as its own queue has room, so a driver that
    // holds tvalid until "both ready" would re-submit the beat to the plane that
    // already took it (a duplicated base pixel, and the two planes then drift).
    // Each plane is therefore masked off individually once it has accepted.
    task automatic send_raw(input [PPC*32-1:0] bp, input [PPC*32-1:0] op,
                            input bit b_sof_v, input bit o_sof_v,
                            input bit b_eol_v, input bit o_eol_v,
                            input bit expect_out);
        bit b_acc, o_acc;
        if (expect_out && booked < NEXP) begin
            for (int p = 0; p < PPC; p = p + 1) begin
                exp_word[booked][p*24 +: 24] =
                    blend_en ? golden_rgb(bp[p*32 +: 32], op[p*32 +: 32])
                             : bp[p*32 +: 24];
                if (force_opaque && blend_en)
                    exp_word[booked][p*24 +: 24] = op[p*32 +: 24];
            end
            exp_sof[booked] = b_sof_v;
            exp_eol[booked] = b_eol_v;
            booked++;
        end
        sent_total++;
        bd <= bp; od <= op; bu <= b_sof_v; ou <= o_sof_v;
        bl <= b_eol_v; ol <= o_eol_v; bv <= 1'b1; ov <= 1'b1;
        b_acc = 0; o_acc = 0;
        forever begin
            @(posedge clk);                 // reads below are PREPONED values
            if (!b_acc && bready) b_acc = 1'b1;
            if (!o_acc && oready) o_acc = 1'b1;
            if (b_acc && o_acc) break;
            bv <= !b_acc;                   // stop re-offering to the plane that took it
            ov <= !o_acc;
        end
    endtask

    task automatic send_pair(input [PPC*32-1:0] bp, input [PPC*32-1:0] op,
                             input bit eol, input bit expect_out);
        bit sof;
        sof = need_sof;
        need_sof = 0;
        send_raw(bp, op, sof, sof, eol, eol, expect_out);
    endtask

    task automatic relock;
        clear_inputs();
        @(posedge clk);
        unlock <= 1'b1; @(posedge clk); unlock <= 1'b0;
        repeat (2) @(posedge clk);
        need_sof = 1;
    endtask

    task automatic wait_drain(input int maxcyc);
        int n;
        n = 0;
        // The driver holds tvalid asserted after the LAST accepted pair (that is
        // how a back-to-back stream works), so a drain phase MUST drop it first;
        // leaving it high re-submits the last pair and invents extra outputs.
        clear_inputs();
        @(posedge clk);
        while (outidx < booked && n < maxcyc) begin @(posedge clk); n++; end
        repeat (6) @(posedge clk);
    endtask

    int rng = 32'h13579BDF;
    function automatic [31:0] nrand;
        rng = rng * 1103515245 + 12345;
        nrand = rng ^ (rng >>> 15);
    endfunction

    function automatic [7:0] corner(input int i);
        case (i)
            0: corner = 8'd0;   1: corner = 8'd1;   2: corner = 8'd127;
            3: corner = 8'd128; 4: corner = 8'd191; 5: corner = 8'd254;
            default: corner = 8'd255;
        endcase
    endfunction

    // ========================================================================
    initial begin
        int  qbad, qn, gvi;
        int  b0, n_before, n_after, span;
        bit [PPC*24-1:0] got_word;
        logic signed [17:0] qmin18, qmax18, qzero18, wpos18, wneg18;

        qmin18  = -18'sd65025;
        qmax18  =  18'sd65025;
        qzero18 =   18'sd0;
        wpos18  =  18'sd48323;
        wneg18  = -18'sd48323;

        // --------------------------------------------------------------------
        // Q1 + Q2 : exhaustive check of the ACTUAL production quantiser
        // --------------------------------------------------------------------
`ifndef PRE_FIX
        begin
            logic signed [17:0] pv18;
            int got;
            qbad = 0; qn = 0;
            for (int pv = -65025; pv <= 65025; pv = pv + 1) begin
                pv18 = 18'(pv);
                got  = dut.quant_round255(pv18);
                if (pv >= 0) gvi = (pv + 127) / 255;
                else         gvi = -((((-pv) + 127) / 255));
                qn++;
                if (got !== gvi) begin
                    qbad++;
                    if (qbad <= 10)
                        $display("FAIL: quant_round255(%0d) = %0d, independent round(p/255) = %0d",
                                 pv, got, gvi);
                end
            end
            checks++;
            ck(qn == 130051, $sformatf("Q1 covered %0d values, expected 130051 (= 2*65025+1)", qn));
            ck(qbad == 0, $sformatf("Q1 %0d of %0d values disagree with the independent golden",
                                    qbad, qn));
            $display("Q1 exhaustive quant_round255: n=%0d bad=%0d endpoints [%0d..%0d]",
                     qn, qbad, dut.quant_round255(qmin18), dut.quant_round255(qmax18));
            ck(dut.quant_round255(qmin18) == -255, "Q1 min endpoint not exact");
            ck(dut.quant_round255(qmax18) ==  255, "Q1 max endpoint not exact");
            ck(dut.quant_round255(qzero18) ==  0,  "Q1 zero not exact");

            // Q2 the two review witnesses, through the same function
            ck(dut.quant_round255(wpos18) ==  190,
               $sformatf("Q2 witness p=+48323 -> %0d, exact 190 (pre-fix RTL gave 189)",
                         dut.quant_round255(wpos18)));
            ck(dut.quant_round255(wneg18) == -190,
               $sformatf("Q2 witness p=-48323 -> %0d, exact -190 (pre-fix RTL gave -189)",
                         dut.quant_round255(wneg18)));
            $display("Q2 witnesses via production function: +48323 -> %0d, -48323 -> %0d",
                     dut.quant_round255(wpos18), dut.quant_round255(wneg18));
        end
`endif

        // --------------------------------------------------------------------
        rst_n <= 1'b0; clear_inputs(); blend_en <= 1'b1; force_opaque <= 1'b0; unlock <= 1'b0;
        mready <= 1'b1;
        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        repeat (3) @(posedge clk);

        // --------------------------------------------------------------------
        // T1 : 256 alphas x corner grid, both pixels of the beat
        // --------------------------------------------------------------------
        for (int a = 0; a < 256; a = a + 1) begin
            for (int i = 0; i < 7; i = i + 1) begin
                for (int j = 0; j < 7; j = j + 1) begin
                    bit [PPC*32-1:0] bp, op;
                    bp = {px(8'd77,    corner((i+3)%7), corner((j+2)%7), corner((i+j)%7)),
                          px(8'(a),    corner(i),       corner(j),       corner(i)+corner(j))};
                    op = {px(8'(255-a),corner((j+5)%7), corner((i+1)%7), corner((i+4)%7)),
                          px(8'(a),    corner(j),       corner(i),       corner(i)^corner(j))};
                    send_pair(bp, op, 1'b0, 1'b1);
                end
            end
        end
        wait_drain(5000);

        // --------------------------------------------------------------------
        // T2 : random triples, both signs of d, randomised mready stalls
        // --------------------------------------------------------------------
        for (int k = 0; k < 1200; k = k + 1) begin
            bit [31:0] r;
            bit [PPC*32-1:0] bp, op;
            r  = nrand();
            bp = {px(8'(r[31:24]), 8'(r[23:16]), 8'(r[15:8]), 8'(r[7:0])),
                  px(8'hC0,        8'(r[7:0]),   8'(r[31:24]), 8'(r[15:8]))};
            op = {px(8'(r[15:8]),  8'(~r[23:16]), 8'(r[7:0]),  8'(r[31:24])),
                  px(8'(r[31:24]), 8'(r[7:0]),    8'(~r[31:24]), 8'(r[23:16]))};
            mready <= ((k * 7) % 5) != 0;                   // ~40 % stalls
            send_pair(bp, op, (k % 37) == 36, 1'b1);
        end
        mready <= 1'b1;
        wait_drain(5000);

        // --------------------------------------------------------------
        // T5 : one-sided line end (only plane B asserts TLAST)
        // --------------------------------------------------------------
        send_raw({PPC*32{1'b0}}, {PPC*32{1'b0}}, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
        repeat (6) @(posedge clk);
        ck(lock_lost > 0, "T5: a one-sided TLAST did not lose the frame lock");

        // --------------------------------------------------------------------
        // T6 : steady II = 1 with every ready held
        // --------------------------------------------------------------------
        relock();
        // first pair of the frame is also a real test vector
        send_pair(px(8'd100, 8'd200, 8'd100, 8'd50), px(8'd100, 8'd10, 8'd20, 8'd30), 1'b0, 1'b1);
        wait_drain(400);
        n_before      = outidx;
        mark_idx      = outidx;
        mark_cyc_first = -1;
        mark_cyc_last  = -1;
        for (int k = 0; k < 400; k = k + 1) begin
            bit [31:0] r;
            r = nrand();
            send_pair({px(8'h40, r[31:24], r[23:16], r[15:8]), px(8'h41, r[7:0], r[31:24], r[23:16])},
                      {px(8'hA5, ~r[23:16], r[7:0], r[31:24]), px(8'hA6, r[15:8], r[7:0], ~r[31:24])},
                      1'b0, 1'b1);
        end
        wait_drain(4000);
        n_after = outidx - n_before;
        span  = int'((mark_cyc_last - mark_cyc_first + 1));
        $display("T6 steady-state: outputs=%0d span=%0d cycles (all readies held)", n_after, span);
        ck(n_after >= 400, $sformatf("T6 only %0d outputs observed", n_after));
        ck(span <= n_after + 8,
           $sformatf("T6 II>1: %0d outputs spanned %0d cycles with every ready held", n_after, span));

        // --------------------------------------------------------------------
        // T4 : blend_enable = 0 passthrough, then alpha_force_opaque
        // --------------------------------------------------------------------
        relock();
        blend_en <= 1'b0;
        send_pair({px(8'd255, 8'd9, 8'd8, 8'd7), px(8'd0, 8'd1, 8'd2, 8'd3)},
                  {px(8'd0,   8'd250, 8'd240, 8'd230), px(8'd200, 8'd1, 8'd2, 8'd3)}, 1'b0, 1'b1);
        send_pair({px(8'd17, 8'd3, 8'd2, 8'd1), px(8'd255, 8'd7, 8'd8, 8'd9)},
                  {px(8'd0, 8'd11, 8'd12, 8'd13), px(8'd1, 8'd14, 8'd15, 8'd16)}, 1'b0, 1'b1);
        blend_en <= 1'b1; force_opaque <= 1'b1;
        send_pair({px(8'd11, 8'd40, 8'd50, 8'd60), px(8'd3, 8'd1, 8'd2, 8'd3)},
                  {px(8'd0,  8'd20, 8'd30, 8'd40), px(8'd0, 8'd255, 8'd0, 255)}, 1'b0, 1'b1);
        force_opaque <= 1'b0;
        wait_drain(1000);
        ck(sat_cnt == 32'd0, $sformatf("T4 sat_watchdog_count=%0d, must stay 0", sat_cnt));

        // --------------------------------------------------------------------
        // T8a : sideband mismatch -> discard, unlock, lock_lost_count
        // --------------------------------------------------------------------
        begin
            int lo0;
            relock();
            send_pair(px(8'd0, 8'd5, 8'd6, 8'd7), px(8'd128, 8'd90, 8'd91, 8'd92), 1'b0, 1'b1);
            wait_drain(600);
            ck(locked, "T8a: compositor did not lock on a matched frame start");
            lo0 = lock_lost;
            // one plane ends the line, the other does not: pair is REFUSED
            send_raw({PPC*32{1'b0}}, {PPC*32{1'b0}}, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
            repeat (4) @(posedge clk);
            ck(lock_lost > lo0, "T8a: sideband mismatch did not increment lock_lost_count");
            ck(!locked, "T8a: sideband mismatch did not drop the lock");
            ck(outidx == booked, "T8a: a discarded pair produced an output");
        end

        // --------------------------------------------------------------------
        // T8b : reset in the middle of an elastic chain, then resync
        // --------------------------------------------------------------------
        relock();
        bd <= px(8'd0, 8'd11, 8'd12, 8'd13); od <= px(8'd90, 8'd200, 8'd201, 8'd202);
        bv <= 1'b1; ov <= 1'b1; bu <= 1'b1; ou <= 1'b1; bl <= 1'b0; ol <= 1'b0;
        @(posedge clk);
        rst_n <= 1'b0;
        outs_since_reset = 0;            // the DUT zeroes beats_blended here
        repeat (4) @(posedge clk);
        clear_inputs();
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);
        ck(!locked, "T8b: reset left the compositor locked");
        ck(!busy,   "T8b: pipeline_busy stuck after reset");
        outidx = booked;                       // nothing may have come out
        send_pair(px(8'd0, 8'd30, 8'd31, 8'd32), px(8'd250, 8'd100, 8'd101, 8'd102), 1'b0, 1'b1);
        wait_drain(800);
        ck(outidx == booked, "T8b: post-reset stream did not produce exactly one output");

        // --------------------------------------------------------------------
        // T3 : the two witnesses in ONE beat, pixel 0 positive / pixel 1 negative
        // --------------------------------------------------------------------
        relock();
        begin
            bit [PPC*32-1:0] bp, op;
            // pixel0: BG=0   FG=191 A=253 -> 190   (pre-fix RTL: 189)
            // pixel1: BG=191 FG=0   A=253 ->   1   (pre-fix RTL:   2)
            bp = {px(8'd0,   8'd191, 8'd191, 8'd191), px(8'd0, 8'd0, 8'd0, 8'd0)};
            op = {px(8'd253, 8'd0,   8'd0,   8'd0),   px(8'd253, 8'd191, 8'd191, 8'd191)};
            b0 = booked;
            send_pair(bp, op, 1'b0, 1'b1);
            wait_drain(600);
            got_word = (b0 < NEXP) ? exp_word[b0] : {PPC*24{1'bx}};
            $display("T3 witness beat: booked golden=%h (pixel0=190 each, pixel1=1 each)", got_word);
            ck(booked == b0 + 1, "T3 witness beat was not booked");
            ck(outidx  == booked, "T3 witness beat never reached the output");
        end

        // --------------------------------------------------------------------
        // verdict
        // --------------------------------------------------------------------
        $display("DIAG front consumes=%0d sent=%0d (booked+discarded) outputs=%0d",
                 consumes_seen, sent_total, outidx);
`ifndef PRE_FIX
        ck(consumes_seen == sent_total,
           $sformatf("DUT consumed %0d pairs but the driver presented %0d",
                     consumes_seen, sent_total));
`endif
        ck(sat_cnt == 32'd0, $sformatf("sat_watchdog_count=%0d at end", sat_cnt));
        ck(int'(beats) == outs_since_reset,
           $sformatf("beats_blended=%0d but the scoreboard booked %0d outputs in this reset epoch",
                     beats, outs_since_reset));
`ifndef PRE_FIX
        ck(busy_bad == 0, $sformatf("pipeline_busy mismatched the three stage-valids %0d times", busy_bad));
        ck(s0_only > 0, "T7 never exercised a stage-0-only cycle (property vacuous)");
        $display("T7 busy: checks=%0d bad=%0d stage0-only-cycles=%0d", busy_checks, busy_bad, s0_only);
`endif
        $display("== sc7f0_alpha_blend_exact: checks=%0d errors=%0d booked=%0d outputs=%0d lock_lost=%0d beats_blended=%0d ==",
                 checks, errors, booked, outidx, lock_lost, beats);
        if (errors == 0) begin
            $display("ALPHA_BLEND_EXACT_PASS");
            $finish;
        end else begin
            $display("ALPHA_BLEND_EXACT_FAIL errors=%0d", errors);
            $fatal(1, "alpha blend exact regression failed");
        end
    end

    initial begin
        // 2_000_000_000 ns: stays inside a 32-bit signed delay literal.  A larger
        // value (4e9) overflows int32, is reported by xelab as a negative delay
        // and turns the watchdog into an immediate time-0 abort.
        #2_000_000_000;
        $display("ALPHA_BLEND_EXACT_FAIL (watchdog)");
        $fatal(1, "watchdog");
    end
endmodule
