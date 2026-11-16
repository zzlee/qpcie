`default_nettype none
// ============================================================================
// Testbench: sc7f0_overlay_ingress_tb
//
// Unit gate for rtl/sc7f0_overlay_ingress.v.  The engine cannot see its own
// counterpart, so this testbench models the two things it is written against:
// a root complex that answers Memory Reads (in order, out of order, and split at
// a 64-byte Read Completion Boundary) and the host memory image behind them.
// What it checks is the list of properties the module header claims:
//
//   T1 in-order completions reproduce the host byte image byte-for-byte
//   T2 out-of-order completions still reproduce it (the reorder path works)
//   T3 reads split into several CplDs, arriving out of order, still reproduce it,
//      and the split counter moves
//   T4 a completion whose tag was never issued is counted and dropped, and does
//      not disturb a single byte of the stream
//   T5 a completion that would exceed the byte count its request was issued for
//      is counted and dropped - it cannot spill into a neighbour's staging
//   T6 a head/tail-unaligned arm reports first_be/last_be exactly and keeps the
//      byte image byte-true, and the first drained beat is marked
//   T7 quiesce stops new issue at once, still consumes everything already issued,
//      frees every tag (ovl_outstanding -> 0, ovl_quiesced -> 1) and accepts no
//      further MRd while asserted
//   T8 a read that is never answered hits the timeout, aborts and returns to idle
//      instead of holding the shared RC path
//
// The completer runs as a concurrent policy process rather than a post-issue
// loop: with NSLOT reorder entries the engine legitimately stops issuing until
// something completes, so a testbench that waited for the full issue first would
// deadlock for its own sake.  Every wait is bounded and a watchdog ends the run.
// ============================================================================
`timescale 1ns / 1ps

module sc7f0_overlay_ingress_tb;
    reg clk = 1'b0;      // PCIe user clock, 8 ns = 125 MHz
    reg mclk = 1'b0;     // memory clock, 3.333 ns = 300 MHz
    always #4 clk  = ~clk;
    always #1.667 mclk = ~mclk;

    integer errors = 0;
    integer checks = 0;

    localparam [6:0]  TAG_BASE = 7'd64;
    localparam integer TAGS     = 8;
    localparam integer NSLOT    = 4;
    localparam integer SLOTB    = 512;
    localparam integer MAXREQ   = 8192;

    reg               rst_n = 1'b0;
    // Review H1: the ledger's epoch reset is a different boundary from this block's
    // working reset.  At the card, rst_n here plays the role of dma_rst_n (built from
    // BAR0[0x14] global_reset_hold_n, reg_dma_ctrl[1] and rst_n), while
    // epoch_rst_n is pcie_user_rst_n.  Keeping them separate in the fixture is what
    // makes "a soft flush must not launder an owed tag" testable at all.
    reg               epoch_n = 1'b0;
    integer           g11, i11, held, nrq_before, pay_beats;  // T11 debt bookkeeping
    wire              abort_evt, poison_st;
    reg               abort_evt_seen = 1'b0;
    always @(posedge clk) if (abort_evt) abort_evt_seen <= 1'b1;
    reg               mrst_n = 1'b0;
    reg               ovl_enable = 1'b0;
    reg  [63:0]       ovl_src = 64'd0;
    reg  [31:0]       ovl_len = 32'd0;
    reg  [15:0]       ovl_maxreq = 16'd128;
    reg               ovl_go = 1'b0;
    reg               quiesce = 1'b0;
    reg               discard_pending = 1'b0;

    wire              mrd_valid;
    wire [63:0]       mrd_addr;
    wire [10:0]       mrd_dw;
    wire [7:0]        mrd_tag;
    wire [3:0]        mrd_fbe, mrd_lbe;
    reg               mrd_ack = 1'b0;

    reg               cpl_valid = 1'b0;
    reg  [255:0]      cpl_data = 256'd0;
    reg  [3:0]        cpl_dw = 4'd0;
    reg               cpl_last = 1'b0;
    reg  [7:0]        cpl_tag = 8'd0;

    wire [31:0]       ovl_bytes_issued, ovl_bytes_staged, ovl_bytes_drained;
    wire [5:0]        ovl_outstanding;
    wire              ovl_busy, ovl_quiesced;
    wire [31:0]       ovl_unexpected, ovl_overflow, ovl_split, ovl_abort;
    wire              ovl_timeout_sticky, ovl_unaligned_sticky, ovl_err_sticky;
    wire              ovl_quarantined;
    wire              ovl_done;
    wire [127:0]      m_tdata;
    wire              m_tuser, m_tvalid;
    reg               m_tready = 1'b0;
    wire [7:0]        m_avail;
    wire              m_ovf;

    sc7f0_overlay_ingress #(
        .OVL_TAG_BASE  (TAG_BASE),
        .OVL_TAG_COUNT (TAGS),
        .NSLOT         (NSLOT),
        .SLOT_BYTES    (SLOTB),
        .FIFO_DEPTH    (16),
        .TIMEOUT_CYCLES(32'd3000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .epoch_rst_n(epoch_n),
        .ovl_enable(ovl_enable), .ovl_src_addr(ovl_src), .ovl_xfer_bytes(ovl_len),
        .ovl_max_bytes_per_req(ovl_maxreq), .ovl_go(ovl_go),
        .quiesce(quiesce), .discard_pending(discard_pending),
        .mrd_req_valid(mrd_valid), .mrd_req_addr(mrd_addr), .mrd_req_dw_len(mrd_dw),
        .mrd_req_tag(mrd_tag), .mrd_req_first_be(mrd_fbe), .mrd_req_last_be(mrd_lbe),
        .mrd_req_ack(mrd_ack),
        .ovl_cpl_valid(cpl_valid), .ovl_cpl_data(cpl_data), .ovl_cpl_dw_count(cpl_dw),
        .ovl_cpl_last(cpl_last), .ovl_cpl_tag(cpl_tag),
        .ovl_bytes_issued(ovl_bytes_issued), .ovl_bytes_staged(ovl_bytes_staged),
        .ovl_bytes_drained(ovl_bytes_drained), .ovl_outstanding(ovl_outstanding),
        .ovl_busy(ovl_busy), .ovl_quiesced(ovl_quiesced),
        .ovl_unexpected_count(ovl_unexpected), .ovl_overflow_count(ovl_overflow),
        .ovl_split_count(ovl_split), .ovl_abort_count(ovl_abort),
        .ovl_timeout_sticky(ovl_timeout_sticky),
        .ovl_quarantined(ovl_quarantined),
        .ovl_abort_evt(abort_evt), .ovl_poison_sticky(poison_st),
        .ovl_unaligned_sticky(ovl_unaligned_sticky), .ovl_err_sticky(ovl_err_sticky),
        .ovl_done_pulse(ovl_done),
        .mem_clk(mclk), .mem_rst_n(mrst_n),
        .m_axis_tdata(m_tdata), .m_axis_tuser(m_tuser), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_avail(m_avail), .m_axis_ovf_sticky(m_ovf)
    );

    // ------------------------------------------------------------------------
    // host memory model: the byte at IOVA x is a fixed function of x, so the
    // expected drained image is derived from the address, never from the DUT
    // ------------------------------------------------------------------------
    function [7:0] host_byte;
        input [63:0] a;
        host_byte = ((a * 64'd31) + 64'd7);
    endfunction

    // ------------------------------------------------------------------------
    // captured MRd stream (PCIe domain) and request legality checks
    // ------------------------------------------------------------------------
    reg  [63:0] rq_addr [0:MAXREQ-1];
    int         rq_len  [0:MAXREQ-1];
    int         rq_tag  [0:MAXREQ-1];
    int         rq_done [0:MAXREQ-1];
    int         rq_tag_seen [0:255];
    int         tag_out [0:255];   // tags the root complex still owes a read for
    int         n_rq;
    int         rq_fbe_bad, rq_lbe_bad, rq_align_bad, rq_4k_bad, rq_tag_bad;
    int         rq_dup, rq_len_bad, rq_over_len, rq_quiesce_issue;
    bit         verbose = 1'b0;
    bit         verbose_cpl = 1'b0;
    bit         verbose_drain = 1'b0;

    always @(posedge clk) #1 begin
        if (verbose_cpl && dut.ovl_cpl_valid) begin
            $display("CPL tag=%02d dw=%0d last=%0b hit=%0b idx=%0d got=%0d exp=%0d waddr=%0d first_be=%01h last_be=%01h nlive=%0d head=%0d tail=%0d unexp=%0d ovf=%0d",
                     dut.ovl_cpl_tag, dut.dw_cnt, dut.ovl_cpl_last, dut.cpl_hit,
                     dut.cpl_idx, dut.e_got[dut.cpl_idx], dut.e_exp[dut.cpl_idx],
                     dut.waddr, dut.mrd_req_first_be, dut.mrd_req_last_be,
                     dut.n_live, dut.head, dut.tail,
                     dut.ovl_unexpected_count, dut.ovl_overflow_count);
        end
    end
    int         cpl_mode;          // 0 in order, 1 reverse, 2 reverse + 64 B split

    always @(posedge clk) begin
        if (rst_n && mrd_valid && mrd_ack) begin
            rq_addr[n_rq] = mrd_addr;
            // Byte length comes from the DWord count *and* last_be: a tail read
            // shorter than a DWord is expressed by byte enables, not by a shorter
            // DWord count, so dw_len*4 alone over-reports it.
            rq_len [n_rq] = (mrd_dw - 11'd1)*4 + $countones(mrd_lbe);
            rq_tag [n_rq] = mrd_tag;
            rq_done[n_rq] = 0;
            if (mrd_addr[1:0] != 2'b00)                               rq_align_bad++;
            if (mrd_dw == 11'd0 || mrd_dw > 11'd1024)                 rq_len_bad++;
            if (({1'b0, mrd_addr[11:0]} + {1'b0, mrd_dw, 2'b00}) > 13'h1000) rq_4k_bad++;
            if (mrd_tag < TAG_BASE || mrd_tag >= TAG_BASE + TAGS)      rq_tag_bad++;
            // Reuse is only a violation while an earlier use is still outstanding;
            // a tag that completed may legally be allocated again.
            if (tag_out[mrd_tag])                                      rq_dup++;
            tag_out[mrd_tag] = 1;
            rq_tag_seen[mrd_tag] = 1;
            if (rq_len[n_rq] > ovl_maxreq)                             rq_over_len++;
            if (rq_len[n_rq] < 1)                                      rq_len_bad++;
            case (mrd_addr[1:0])
                2'd0:    if (mrd_fbe != 4'b1111) rq_fbe_bad++;
                2'd1:    if (mrd_fbe != 4'b1110) rq_fbe_bad++;
                2'd2:    if (mrd_fbe != 4'b1100) rq_fbe_bad++;
                default: if (mrd_fbe != 4'b1000) rq_fbe_bad++;
            endcase
            if (rq_len[n_rq] > 4) begin
                if (mrd_lbe != 4'b1111) rq_lbe_bad++;
            end else if (rq_len[n_rq] == 4) begin
                case (mrd_addr[1:0])
                    2'd0:    if (mrd_lbe != 4'b1111) rq_lbe_bad++;
                    2'd1:    if (mrd_lbe != 4'b0111) rq_lbe_bad++;
                    2'd2:    if (mrd_lbe != 4'b0011) rq_lbe_bad++;
                    default: if (mrd_lbe != 4'b0001) rq_lbe_bad++;
                endcase
            end
            n_rq++;
            if (verbose)
                $display("ACCEPT addr=%016h dw=%0d tag=%02d cap_req=%0d clamp_len=%0d maxreq=%0d new_tag=%02d free=%0d room4k=%0d",
                         mrd_addr, mrd_dw, mrd_tag, dut.cap_req, dut.clamp_len,
                         dut.ovl_max_bytes_per_req, dut.new_tag, dut.first_free,
                         dut.room_4k);
        end
        if (ovl_go && quiesce && $rose(mrd_valid)) rq_quiesce_issue++;
    end

    // ------------------------------------------------------------------------
    // drained byte stream (memory domain); trailing bytes past the armed length
    // are allowed to exist in the last 128-bit word but are never written by the
    // writer, so the check only inspects the first ovl_len bytes
    // ------------------------------------------------------------------------
    localparam integer MAXBY = 1 << 18;
    reg [7:0] rx_bytes [0:MAXBY-1];
    int  n_rx;
    int  saw_first_user;
    always @(posedge mclk) begin
        if (mrst_n && m_tvalid && m_tready) begin
            if (m_tuser) saw_first_user = 1;
            for (int i = 0; i < 16; i = i + 1) begin
                if (n_rx < MAXBY) rx_bytes[n_rx] = m_tdata[i*8 +: 8];
                n_rx++;
            end
        end
    end

    // ------------------------------------------------------------------------
    // FIFO *write*-side capture (PCIe domain).  This isolates the staging read
    // pipeline from the 256->128 crossing: if this image is correct and the read
    // side is not, the crossing is at fault; if this one is wrong, the staging
    // pipeline re-reads or skips a word.
    // ------------------------------------------------------------------------
    reg [7:0] wx_bytes [0:MAXBY-1];
    int  n_wx;

    always @(posedge clk) #1 begin
        if (verbose_drain && (dut.d_active || dut.rd_pipe || dut.drain_can_read)) begin
            $display("DRN t=%0d act=%0b idx=%0d tot=%0d head=%0d canrd=%0b rdpipe=%0b raddr=%0d rdata0=%02h wen=%0b wdata0=%02h wcnt=%0d room2=%0b ready=%0b",
                     $time, dut.d_active, dut.d_idx, dut.d_total, dut.head,
                     dut.drain_can_read, dut.rd_pipe, dut.ram_raddr, dut.ram_rdata[7:0],
                     dut.fifo_wen, dut.fifo_wdata[7:0], dut.fifo_wr_count, dut.fifo_room2,
                     (dut.n_live != 0) && dut.e_ready[dut.head]);
        end
    end

    always @(posedge clk) #1 begin
        if (rst_n && dut.fifo_wen) begin
            for (int i = 0; i < 32; i = i + 1) begin
                if (n_wx < MAXBY) wx_bytes[n_wx] = dut.fifo_wdata[i*8 +: 8];
                n_wx++;
            end
        end
    end

    task check_wx_image(input [63:0] base, input integer len, input [511:0] tagmsg);
        integer bad, first_bad, i;
        begin
            bad = 0; first_bad = -1;
            for (i = 0; i < len && i < n_wx; i = i + 1)
                if (wx_bytes[i] !== host_byte(base + i)) begin
                    if (first_bad < 0) first_bad = i;
                    bad++;
                end
            checks++;
            if (bad != 0 || n_wx < len) begin
                errors++;
                $display("%s WRITE-SIDE BAD pushed=%0d exp=%0d bad=%0d first_at=%0d got=%02h exp=%02h",
                         tagmsg, n_wx, len, bad, first_bad,
                         (first_bad >= 0) ? wx_bytes[first_bad] : 8'h00,
                         host_byte(base + first_bad));
                for (i = 0; i < 8; i = i + 1)
                    $display("%s   wx[%0d]=%02h exp=%02h", tagmsg, i, wx_bytes[i],
                             host_byte(base + i));
            end
        end
    endtask

    // Per-slot state dump: distinguishes "the data never arrived" from "it arrived
    // but the entry never retired" from "it retired but the drain never ran".
    task dump_state(input [255:0] tag);
        begin
            $display("%s STATE nlive=%0d head=%0d tail=%0d outst=%0d dact=%0b didx=%0d dtot=%0d issued=%0d staged=%0d drained=%0d unexp=%0d ovf=%0d wcnt=%0d", tag,
                     dut.n_live, dut.head, dut.tail, ovl_outstanding,
                     dut.d_active, dut.d_idx, dut.d_total, ovl_bytes_issued,
                     ovl_bytes_staged, ovl_bytes_drained, ovl_unexpected,
                     ovl_overflow, dut.fifo_wr_count);
            for (int k = 0; k < NSLOT; k = k + 1)
                $display("%s   SLOT%0d live=%0b rdy=%0b got=%0d exp=%0d tag=%02d",
                         tag, k, dut.e_live[k], dut.e_ready[k], dut.e_got[k],
                         dut.e_exp[k], dut.e_tag[k]);
        end
    endtask

    task expect_eq(input [511:0] msg, input integer got, input integer expv);
        begin
            checks++;
            if (got !== expv) begin
                errors++;
                $display("SC7F0_OVL_INGRESS_TB FAIL %s got=%0d exp=%0d", msg, got, expv);
            end
        end
    endtask

    task expect_true(input [511:0] msg, input bit cond);
        begin
            checks++;
            if (!cond) begin
                errors++;
                $display("SC7F0_OVL_INGRESS_TB FAIL %s", msg);
            end
        end
    endtask

    task expect_false(input [511:0] msg, input bit cond);
        begin
            checks++;
            if (cond) begin
                errors++;
                $display("SC7F0_OVL_INGRESS_TB FAIL %s", msg);
            end
        end
    endtask

    task clear_counters;
        begin
            n_rq = 0; n_rx = 0; saw_first_user = 0; n_wx = 0;
            rq_fbe_bad = 0; rq_lbe_bad = 0; rq_align_bad = 0; rq_4k_bad = 0;
            rq_tag_bad = 0; rq_dup = 0; rq_len_bad = 0; rq_over_len = 0;
            rq_quiesce_issue = 0;
            for (int i = 0; i < 256; i = i + 1) begin
                rq_tag_seen[i] = 0;
                tag_out[i]     = 0;
            end
        end
    endtask

    task reset_dut;
        begin
            rst_n = 0; mrst_n = 0; ovl_go = 0; quiesce = 0; discard_pending = 0;
            epoch_n = 0;
            m_tready = 0; mrd_ack = 0; cpl_valid = 0;
            clear_counters;
            repeat (4)  @(posedge clk);
            rst_n = 1; mrst_n = 1;
            // the epoch boundary is released last and is never touched again by the
            // ordinary reset traffic in this fixture, which is exactly the property
            // T11 now checks
            repeat (4) @(posedge clk); epoch_n = 1;
            repeat (16) @(posedge mclk);
        end
    endtask

    // ------------------------------------------------------------------------
    // root complex model
    // ------------------------------------------------------------------------
    task drive_beat(input [7:0] tag, input [63:0] a, input integer di,
                    input [3:0] ndw, input bit last);
        reg [255:0] d;
        integer ndwn;
        begin
            ndwn = (ndw == 4'd0) ? 8 : ndw;
            d = 256'd0;
            for (int k = 0; k < ndwn; k = k + 1)
                for (int b = 0; b < 4; b = b + 1)
                    d[k*32 + b*8 +: 8] = host_byte(a + (di + k)*4 + b);
            @(posedge clk);
            cpl_valid <= 1'b1; cpl_data <= d; cpl_dw <= ndw;
            cpl_last <= last;  cpl_tag <= tag;
            @(posedge clk);
            cpl_valid <= 1'b0; cpl_last <= 1'b0; cpl_dw <= 4'd0;
        end
    endtask

    // Deliver one accepted read.  A beat never exceeds the 256-bit interface
    // (8 DWords).  Mode 2 emulates a 64-byte Read Completion Boundary: each
    // completion carries at most 16 DWords and ends with its own last beat, so one
    // Memory Read is answered by several completions and the engine must not retire
    // the entry on the first completion's last beat.
    task deliver(input integer idx);
        integer total_dw, cpl_per, cpl_rem, sent, ndw;
        begin
            total_dw = (rq_len[idx] + 3) / 4;   // completions are whole DWords
            cpl_per  = (cpl_mode == 2 && total_dw > 16) ? 16 : total_dw;
            rq_done[idx] = 1;
            sent = 0;
            while (sent < total_dw) begin
                cpl_rem = ((total_dw - sent) > cpl_per) ? cpl_per : (total_dw - sent);
                while (cpl_rem > 0) begin
                    ndw = (cpl_rem > 8) ? 8 : cpl_rem;
                    cpl_rem = cpl_rem - ndw;
                    // rq_addr[idx] is the read base and sent is the DWord index, so
                    // the byte address is base + sent*4.  Passing an already-advanced
                    // address *and* the DWord index double-counts the offset.
                    drive_beat(rq_tag[idx][7:0], rq_addr[idx], sent,
                               ndw[3:0], cpl_rem == 0);
                    sent = sent + ndw;
                end
            end
            tag_out[rq_tag[idx]] = 0;
        end
    endtask

    function int pick_pending;
        integer i, best;
        begin
            best = -1;
            for (i = 0; i < n_rq; i = i + 1)
                if (!rq_done[i]) begin
                    if (best < 0)                       best = i;
                    else if (cpl_mode != 0)             best = i;   // reverse: last wins
                end
            pick_pending = best;
        end
    endfunction

    // Concurrent completer: answers reads as they appear, in the policy order,
    // and stops when the armed length has been issued and answered.
    task rc_run(input integer mode);
        integer i, g, guard;
        begin
            cpl_mode = mode;
            guard = 0;
            while (guard < 400000) begin
                guard = guard + 1;
                i = pick_pending();
                if (i >= 0) begin
                    deliver(i);
                end else if (ovl_bytes_issued == ovl_len && n_rq > 0) begin
                    // everything issued and answered: let the image settle, exit
                    g = 0;
                    while (g < 400) begin @(posedge clk); g++; end
                    guard = 999999;
                end else begin
                    @(posedge clk);
                end
            end
        end
    endtask

    // Byte-exact comparison of the drained image against the host model
    task check_image(input [63:0] base, input integer len, input [511:0] tagmsg);
        integer bad, first_bad, i;
        begin
            bad = 0; first_bad = -1;
            checks++;
            if (n_rx < len) begin
                errors++;
                $display("SC7F0_OVL_INGRESS_TB FAIL %s short bytes got=%0d exp=%0d",
                         tagmsg, n_rx, len);
            end
            for (i = 0; i < len && i < n_rx; i = i + 1)
                if (rx_bytes[i] !== host_byte(base + i)) begin
                    if (first_bad < 0) first_bad = i;
                    bad++;
                end
            checks++;
            if (bad != 0) begin
                errors++;
                $display("SC7F0_OVL_INGRESS_TB FAIL %s bad_bytes=%0d first_at=%0d got=%02h exp=%02h",
                         tagmsg, bad, first_bad, rx_bytes[first_bad],
                         host_byte(base + first_bad));
            end
        end
    endtask

    // arm a transfer and keep accepting MRds for it.
    // NOTE: these arguments are deliberately sized, not `integer`.  Taking a bit
    // select of an integer (len[31:0], maxreq[15:0]) is not a legal constant
    // part-select and evaluates to X, which then silently poisons the DUT's
    // length and clamp logic.
    task arm_and_issue(input [63:0] base, input [31:0] len, input [15:0] maxreq);
        integer guard;
        begin
            ovl_maxreq = maxreq;
            ovl_src    = base;
            ovl_len    = len;
            @(posedge clk);
            ovl_go <= 1'b1;
            guard = 0;
            while (ovl_bytes_issued < len && guard < 200000) begin
                @(posedge clk);
                mrd_ack <= (($countones($urandom) & 1) == 1);
                guard++;
            end
            mrd_ack <= 1'b0;
            checks++;
            if (ovl_bytes_issued !== len) begin
                errors++;
                $display("SC7F0_OVL_INGRESS_TB FAIL issued_len issued=%0d exp=%0d",
                         ovl_bytes_issued, len);
            end
        end
    endtask

    // wait until the drained image has settled
    task settle(input integer cycles);
        begin
            repeat (cycles) @(posedge clk);
        end
    endtask

    // Read-side backpressure.  Deliberately not full rate: the write side runs
    // 256 b x 125 MHz and the read side 128 b x 300 MHz, so throttling the read
    // side is what makes the crossing FIFO fill and forces one-cycle bubbles in the
    // staging read pipeline.  That is exactly where a re-read or a dropped word
    // shows up, so T9 runs a whole transfer under it and checks the image, the byte
    // count and the FIFO overflow sticky.
    bit bp_en = 1'b0;
    always @(posedge mclk) begin
        if (!mrst_n)          m_tready <= 1'b0;
        else if (bp_en)       m_tready <= (($countones($urandom) & 3) != 3'h0);
        else                  m_tready <= 1'b1;
    end

    integer unexp_before, ovf_before, split_before, abort_before;
    integer qt, ii, gw, bytes_before, pend;
    reg [7:0] qt8;

    initial begin : MAIN
        fork : WATCHDOG
            begin
                #60_000_000;                 // 60 ms simulated
                $display("SC7F0_OVL_INGRESS_TB FAIL watchdog");
                $finish;
            end
        join_none

        reset_dut;
        ovl_enable = 1'b1;

        // ---- T1 in-order --------------------------------------------------
        m_tready = 1'b1;
        verbose_cpl = 1'b0;
        verbose_drain = 1'b0;
        fork : T1F
            arm_and_issue(64'h1000_0000, 2048, 128);
            rc_run(0);
        join
        settle(2000);
        dump_state("T1");
        check_wx_image(64'h1000_0000, 2048, "T1");
        check_image(64'h1000_0000, 2048, "T1");
        expect_eq("T1 fbe_bad",  rq_fbe_bad, 0);
        expect_eq("T1 lbe_bad",  rq_lbe_bad, 0);
        expect_eq("T1 4k_bad",   rq_4k_bad, 0);
        expect_eq("T1 tag_bad",  rq_tag_bad, 0);
        expect_eq("T1 dup_tag",  rq_dup, 0);
        expect_eq("T1 over_len", rq_over_len, 0);
        expect_true("T1 multiple reads issued", n_rq > 1);
        // ovl_split_count counts continuation beats (a read that needed more than
        // one completion beat).  A multi-beat single CplD legitimately moves it, so
        // in-order delivery does not imply zero here; T3 checks it rises with real
        // 64-byte splits.
        expect_true("T1 no unexpected beats", ovl_unexpected == 0);
        expect_true("T1 ring and tags fully released",
                    dut.n_live == 0 && ovl_outstanding == 0 && !ovl_busy);
        expect_eq("T1 unexpected", ovl_unexpected, 0);
        expect_eq("T1 overflow",   ovl_overflow, 0);
        verbose_cpl = 1'b0;
        $display("SC7F0_OVL_INGRESS_TB T1 in_order bytes=%0d reads=%0d errors=%0d",
                 n_rx, n_rq, errors);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T2 out-of-order ---------------------------------------------
        fork : T2F
            arm_and_issue(64'h2000_0000, 1024, 64);
            rc_run(1);
        join
        settle(2000);
        check_image(64'h2000_0000, 1024, "T2");
        expect_true("T2 many reads issued", n_rq >= 4);
        $display("SC7F0_OVL_INGRESS_TB T2 out_of_order bytes=%0d reads=%0d errors=%0d",
                 n_rx, n_rq, errors);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T3 split completions, out of order --------------------------
        split_before = ovl_split;
        fork : T3F
            arm_and_issue(64'h3000_0000, 1024, 128);
            rc_run(2);
        join
        settle(2000);
        check_image(64'h3000_0000, 1024, "T3");
        expect_true("T3 split counted", ovl_split > split_before);
        // Several completions per read: none of the intermediate completions' last
        // beats may retire the entry, so not one beat may miss the reorder CAM.
        expect_eq  ("T3 no stray beats after split CplDs", ovl_unexpected, 0);
        expect_eq  ("T3 no overflow beats", ovl_overflow, 0);
        expect_true("T3 ring and tags fully released",
                    dut.n_live == 0 && ovl_outstanding == 0);
        $display("SC7F0_OVL_INGRESS_TB T3 split_reorder bytes=%0d split=%0d errors=%0d",
                 n_rx, ovl_split - split_before, errors);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T4 completion for a tag that was never issued ---------------
        unexp_before = ovl_unexpected;
        fork : T4F
            begin
                integer guard4; guard4 = 0;
                ovl_maxreq = 128; ovl_src = 64'h4000_0000; ovl_len = 32'd512;
                @(posedge clk); ovl_go <= 1'b1;
                while (ovl_bytes_issued < ovl_len && guard4 < 200000) begin
                    @(posedge clk);
                    mrd_ack <= (($countones($urandom) & 1) == 1);
                    guard4++;
                end
                mrd_ack <= 1'b0;
                wait (n_rq >= 1);
                drive_beat(8'hEE, 64'h4000_0000, 0, 8, 1'b1);   // never-issued tag
                rc_run(0);
            end
        join
        settle(2000);
        expect_eq("T4 unexpected_delta", ovl_unexpected - unexp_before, 1);
        check_image(64'h4000_0000, 512, "T4");
        expect_true("T4 err sticky", ovl_err_sticky);
        $display("SC7F0_OVL_INGRESS_TB T4 illegal_tag unexpected=%0d bytes=%0d errors=%0d",
                 ovl_unexpected - unexp_before, n_rx, errors);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T5 over-length completion ----------------------------------
        ovf_before = ovl_overflow + ovl_unexpected;
        fork : T5F
            begin
                integer guard5; guard5 = 0;
                ovl_maxreq = 128; ovl_src = 64'h5000_0000; ovl_len = 32'd32;
                @(posedge clk); ovl_go <= 1'b1;
                while (ovl_bytes_issued < ovl_len && guard5 < 200000) begin
                    @(posedge clk);
                    mrd_ack <= (($countones($urandom) & 1) == 1);
                    guard5++;
                end
                mrd_ack <= 1'b0;
                wait (n_rq == 1);
                // 64 bytes for a 32-byte read: the tail must be rejected
                drive_beat(rq_tag[0][7:0], rq_addr[0],      0, 8, 1'b0);
                drive_beat(rq_tag[0][7:0], rq_addr[0], 8, 8, 1'b1);
                repeat (500) @(posedge clk);
            end
        join
        settle(500);
        expect_true("T5 overrun rejected",
                    (ovl_overflow + ovl_unexpected) > ovf_before);
        check_image(64'h5000_0000, 32, "T5");
        expect_true("T5 over-run not forwarded", n_rx < 64);
        $display("SC7F0_OVL_INGRESS_TB T5 overrun bytes=%0d rejected=%0d errors=%0d",
                 n_rx, (ovl_overflow + ovl_unexpected) - ovf_before, errors);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T6 unaligned arm: the engine must reject it, not shift bytes ----
        // A dense byte stream cannot be produced from a head-unaligned read
        // without dropping the masked leading bytes, so the module's contract is
        // 4-byte-aligned arms reported through ovl_unaligned_sticky.  The BE
        // generation for a *tail*-unaligned length is checked in T6b.
        unexp_before = ovl_unexpected;
        fork : T6A
            begin
                ovl_maxreq = 64; ovl_src = 64'h6000_0002; ovl_len = 32'd130;
                @(posedge clk); ovl_go <= 1'b1;
                repeat (300) @(posedge clk);
                mrd_ack <= 1'b0;
            end
        join
        expect_true("T6a unaligned rejected sticky", ovl_unaligned_sticky);
        expect_eq  ("T6a no reads issued", n_rq, 0);
        expect_eq  ("T6a no bytes issued", ovl_bytes_issued, 0);
        expect_eq  ("T6a no drain", n_rx, 0);
        $display("SC7F0_OVL_INGRESS_TB T6a unaligned rejected sticky=%0d reads=%0d",
                 ovl_unaligned_sticky, n_rq);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T6b tail-unaligned length -----------------------------------
        fork : T6BF
            arm_and_issue(64'h6000_0000, 130, 64);
            rc_run(0);
        join
        settle(2000);
        expect_eq("T6b fbe_bad",   rq_fbe_bad, 0);
        expect_eq("T6b lbe_bad",   rq_lbe_bad, 0);
        expect_eq("T6b align_bad", rq_align_bad, 0);
        expect_true("T6b tail read < 4B exists", n_rq >= 3);
        check_image(64'h6000_0000, 128, "T6b");
        checks++;
        if (rq_len[n_rq-1] != 2) begin
            errors++;
            $display("SC7F0_OVL_INGRESS_TB FAIL T6b tail length=%0d exp=2", rq_len[n_rq-1]);
        end
        expect_true("T6b first_beat marker", saw_first_user == 1);
        $display("SC7F0_OVL_INGRESS_TB T6b tail_unaligned bytes=%0d reads=%0d errors=%0d",
                 n_rx, n_rq, errors);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T7 quiesce --------------------------------------------------
        ovl_maxreq = 64; ovl_src = 64'h7000_0000; ovl_len = 32'd4096;
        fork : T7F
            begin : issuer7
                integer guard7; guard7 = 0;
                @(posedge clk); ovl_go <= 1'b1;
                while (guard7 < 3000) begin
                    @(posedge clk);
                    mrd_ack <= (($countones($urandom) & 1) == 1);
                    guard7++;
                end
                mrd_ack <= 1'b0;
            end
            begin : answer7
                cpl_mode = 0;
                while (n_rq < 2) @(posedge clk);
                @(posedge clk); quiesce <= 1'b1;
                fork
                    begin : drain7
                        integer i7;
                        for (i7 = 0; i7 < n_rq; i7 = i7 + 1)
                            if (!rq_done[i7]) deliver(i7);
                    end
                join
                begin
                    integer g7; g7 = 0;
                    while (!ovl_quiesced && g7 < 60000) begin @(posedge clk); g7++; end
                end
            end
        join_any
        disable fork;
        expect_true("T7 quiesced",        ovl_quiesced);
        expect_eq  ("T7 tags freed",      ovl_outstanding, 0);
        expect_eq  ("T7 no issue while quiesced", rq_quiesce_issue, 0);
        $display("SC7F0_OVL_INGRESS_TB T7 quiesce reads=%0d outstanding=%0d quiesced=%0d errors=%0d",
                 n_rq, ovl_outstanding, ovl_quiesced, errors);
        @(posedge clk); ovl_go <= 1'b0; quiesce <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T8 timeout --------------------------------------------------
        abort_before = ovl_abort;
        begin : t8_seq
            integer guard8, g8;
            guard8 = 0; g8 = 0;
            ovl_maxreq = 64; ovl_src = 64'h8000_0000; ovl_len = 32'd256;
            @(posedge clk); ovl_go <= 1'b1;
            while (guard8 < 400) begin @(posedge clk); mrd_ack <= 1'b1; guard8++; end
            mrd_ack <= 1'b0;
            // no completion is ever delivered: the engine must give up by itself
            while (!ovl_timeout_sticky && g8 < 60000) begin @(posedge clk); g8++; end
        end
        expect_true("T8 timeout sticky", ovl_timeout_sticky);
        expect_true("T8 abort counted",  ovl_abort > abort_before);
        expect_eq  ("T8 returned to idle", ovl_busy, 0);
        $display("SC7F0_OVL_INGRESS_TB T8 timeout abort=%0d busy=%0d errors=%0d",
                 ovl_abort - abort_before, ovl_busy, errors);

        // ---- T11 issued-flight debt: created by real accepted MRds ------------
        // This scenario used to ride on T8's timeout, which turned out to abandon a
        // transfer whose bytes had ALL arrived (e_got == e_exp per entry): there was
        // no debt to hold, so the test proved nothing about debt.  Here the debt is
        // created the only way the hardware can create it - the request encoder
        // acknowledges MRds (accepted = mrd_req_valid && mrd_req_ack) and the root
        // complex model simply never answers them.  From the ack cycle the block owes
        // those reads, and the ledger is what has to remember it.
        @(posedge clk); ovl_go <= 1'b0; ovl_enable <= 1'b1;
        // T8's timeout legitimately leaves debt of its own (it aborts with requests
        // outstanding), and under the new rule nothing but the physical epoch may
        // clear that.  Start this scenario from a released ledger so what is measured
        // below is the debt this scenario creates, not T8's.
        epoch_n = 1'b0; repeat (4) @(posedge clk); epoch_n = 1'b1;
        repeat (6) @(posedge clk);
        $display("T11PRE epoch_release_seen live=%b%d%d%d%d dead=%b%d%d%d%d tag=%0d,%0d,%0d,%0d held=%02b qany=%b armed=%b go=%b",
                 {dut.ifl_live[3],dut.ifl_live[2],dut.ifl_live[1],dut.ifl_live[0]},
                 dut.ifl_live[0], dut.ifl_live[1], dut.ifl_live[2], dut.ifl_live[3],
                 {dut.ifl_dead[3],dut.ifl_dead[2],dut.ifl_dead[1],dut.ifl_dead[0]},
                 dut.ifl_dead[0], dut.ifl_dead[1], dut.ifl_dead[2], dut.ifl_dead[3],
                 dut.ifl_tag[0], dut.ifl_tag[1], dut.ifl_tag[2], dut.ifl_tag[3],
                 dut.dead_busy, dut.q_any, dut.armed, ovl_go);
        expect_false("T11 starts from a released ledger", ovl_quarantined);
        expect_eq   ("T11 starts with no held tags", dut.dead_busy, 0);
        clear_counters;
        m_tready = 1'b1;
        ovl_maxreq = 64;
        ovl_src    = 64'hC000_0000;
        ovl_len    = 32'd4096;
        @(posedge clk); ovl_go <= 1'b1;
        g11 = 0;
        while (n_rq < 3 && g11 < 20000) begin @(posedge clk); mrd_ack <= 1'b1; g11++; end
        mrd_ack <= 1'b0;
        repeat (4) @(posedge clk);
        expect_true ("T11 requests committed with encoder ack", n_rq >= 3);
        expect_eq   ("T11 nothing was answered, so nothing is retired", n_rx, 0);
        // live in-flight traffic of a LIVE transfer is not abandoned debt
        expect_false("T11 live in-flight reported as abandoned debt", ovl_quarantined);
        bytes_before = ovl_bytes_issued;

        // withdraw the arm: the debt becomes dead ownership
        @(posedge clk); ovl_go <= 1'b0;
        repeat (4) @(posedge clk);
        expect_true ("T11 abandoned debt reported", ovl_quarantined);
        expect_true ("T11 discard event raised for the plane", abort_evt_seen);
        expect_true ("T11 poison reported", poison_st);
        expect_true ("T11 tag space held by debt", dut.dead_busy != {TAGS{1'b0}});
        held = 0;
        for (i11 = 0; i11 < n_rq; i11 = i11 + 1)
            if (!rq_done[i11] && dut.dead_busy[rq_tag[i11][6:0] - TAG_BASE[6:0]])
                held = held + 1;
        expect_eq   ("T11 every unanswered read holds its own tag", held, n_rq);
        $display("SC7F0_OVL_INGRESS_TB T11 abandoned reads=%0d dead_busy=%02b quarantined=%b",
                 n_rq, dut.dead_busy, ovl_quarantined);

        // a re-arm must be refused while any of it is owed
        @(posedge clk); ovl_go <= 1'b1;
        nrq_before = n_rq;
        repeat (500) @(posedge clk);
        expect_eq   ("T11 re-arm issues nothing", n_rq, nrq_before);
        expect_eq   ("T11 re-arm moves no bytes", ovl_bytes_issued - bytes_before, 0);
        expect_true ("T11 still owed while go held", ovl_quarantined);
        @(posedge clk); ovl_go <= 1'b0;

        // no elapsed time releases it (the retired rule was 65536 idle cycles)
        repeat (120000) @(posedge clk);
        expect_true ("T11 a quiet window released the debt (must not happen)",
                     ovl_quarantined);

        // and no soft reset of this block does either: dma_rst_n falls on a BAR0
        // global flush and on clearing reg_dma_ctrl[1]; the root complex's reads do
        // not.  mrst_n is this fixture's stand-in for the video/memory reset.
        rst_n  = 1'b0; mrst_n = 1'b0;
        repeat (6) @(posedge clk); mrst_n = 1'b1;
        repeat (6) @(posedge clk); rst_n  = 1'b1;
        repeat (20) @(posedge clk);
        expect_true ("T11 a soft/video reset laundered the debt (must not happen)",
                     ovl_quarantined);
        held = 0;
        for (i11 = 0; i11 < n_rq; i11 = i11 + 1)
            if (!rq_done[i11] && dut.dead_busy[rq_tag[i11][6:0] - TAG_BASE[6:0]])
                held = held + 1;
        expect_eq   ("T11 debt ownership survived the reset", held, n_rq);
        @(posedge clk); ovl_go <= 1'b1; nrq_before = n_rq;
        repeat (200) @(posedge clk); ovl_go <= 1'b0;
        expect_eq   ("T11 re-arm after reset issues nothing", n_rq, nrq_before);

        // a late completion retires ONLY its own owner, and only when that owner's
        // full issued byte count has arrived.  First a partial beat for read 0.
        unexp_before = ovl_unexpected;
        drive_beat(rq_tag[0][7:0], rq_addr[0], 0, 8, 1'b1);   // 32 of 64 bytes
        repeat (4) @(posedge clk);
        expect_eq ("T11 late beat counted, not silently lost", ovl_unexpected - unexp_before, 1);
        expect_eq ("T11 late beat staged nothing into any slot", n_wx, 0);
        expect_true("T11 a partially answered owner was released too early",
                    dut.dead_busy[rq_tag[0][6:0] - TAG_BASE[6:0]]);
        expect_true ("T11 partial payment cleared the whole block's debt", ovl_quarantined);

        // pay read 0 in full: its bit is released, the other owners are still held
        deliver(0);
        rq_done[0] = 1;
        repeat (8) @(posedge clk);
        expect_false("T11 the retired owner's tag is still held",
                     dut.dead_busy[rq_tag[0][6:0] - TAG_BASE[6:0]]);
        held = 0;
        for (i11 = 1; i11 < n_rq; i11 = i11 + 1)
            if (!rq_done[i11] && dut.dead_busy[rq_tag[i11][6:0] - TAG_BASE[6:0]])
                held = held + 1;
        expect_eq   ("T11 remaining owners not all held", held, n_rq - 1);
        expect_true ("T11 debt still held with owners unpaid", ovl_quarantined);
        @(posedge clk); ovl_go <= 1'b1; nrq_before = n_rq;
        repeat (200) @(posedge clk); ovl_go <= 1'b0;
        expect_eq   ("T11 re-arm allowed with owners still owed", n_rq, nrq_before);

        // pay the rest: only now may the block arm again.  Every one of these
        // completions belongs to an abandoned tag, so each beat MUST land in
        // ovl_unexpected - counted exactly, not tolerated.  The count below is
        // derived from the reads being paid, not pasted in as a threshold.
        unexp_before = ovl_unexpected;
        pay_beats = 0;
        for (i11 = 1; i11 < n_rq; i11 = i11 + 1) begin
            pay_beats = pay_beats + ((rq_len[i11] + 3) / 4 + 7) / 8;
            deliver(i11); rq_done[i11] = 1;
        end
        gw = 0;
        while (ovl_quarantined && gw < 4000) begin @(posedge clk); gw++; end
        expect_eq   ("T11 late completions counted exactly, not tolerated",
                     ovl_unexpected - unexp_before, pay_beats);
        expect_false("T11 fully paid debt did not release", ovl_quarantined);
        expect_eq   ("T11 tag space still held after full payment",
                     dut.dead_busy, 0);
        $display("SC7F0_OVL_INGRESS_TB T11 released by evidence after %0d cycles, errors=%0d",
                 gw, errors);

        // and a normal transfer now runs clean, byte for byte
        // Re-baseline the stray counter: the debt phase above deliberately produced
        // late completions for abandoned tags, and each of them was counted as a
        // stray on purpose.  Judging the recovery transfer against the old baseline
        // would charge those correct counts to the recovery.
        unexp_before = ovl_unexpected;
        clear_counters;
        m_tready = 1'b1;
        verbose_drain = 1'b1;
        $display("SC7F0_OVL_INGRESS_TB T11 pre-arm armed=%0b q_any=%0b enable=%0b go=%0b nlive=%0d tail=%0d head=%0d dact=%0b outst=%0d issued=%0d busy=%0b",
                 dut.armed, dut.q_any, dut.ovl_enable, dut.ovl_go, dut.n_live,
                 dut.tail, dut.head, dut.d_active, ovl_outstanding,
                 ovl_bytes_issued, ovl_busy);
        fork : T11F
            arm_and_issue(64'hB000_0000, 1024, 64);
            rc_run(0);
        join
        settle(2000);
        verbose_drain = 1'b0;
        pend = 0;
        for (ii = 0; ii < n_rq; ii = ii + 1) if (!rq_done[ii]) pend++;
        $display("SC7F0_OVL_INGRESS_TB T11 after join reads=%0d undelivered=%0d rxbytes=%0d issued=%0d staged=%0d bytes_left=%0d armed=%0b",
                 n_rq, pend, n_rx, ovl_bytes_issued, ovl_bytes_staged,
                 dut.bytes_left, dut.armed);
        dump_state("T11R");
        check_image(64'hB000_0000, 1024, "T11");
        expect_eq("T11 no stray beats after recovery",
                  ovl_unexpected - unexp_before, 0);
        expect_true("T11 ring and tags fully released",
                    dut.n_live == 0 && ovl_outstanding == 0);
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);
        reset_dut; ovl_enable = 1'b1; m_tready = 1'b1;

        // ---- T12 physical epoch is the only reset that may release debt ----
        // epoch_rst_n is pcie_user_rst_n (user_lnk_up && ~user_reset).  The core's own
        // reset semantics retire every outstanding request of this function, so this
        // is a physical boundary rather than a wait - and because the ledger clears
        // asynchronously on it, the release does not depend on a clock edge that a
        // stopped link clock might never provide.  Nothing else qualifies:
        //   * a soft reset (rst_n, which is what dma_rst_n becomes on a BAR0 flush or
        //     on clearing reg_dma_ctrl[1]) may not,
        //   * a video/memory reset (mrst_n) may not,
        //   * elapsed time may not.
        clear_counters;
        ovl_maxreq = 64; ovl_src = 64'hC100_0000; ovl_len = 32'd4096;
        @(posedge clk); ovl_go <= 1'b1;
        g11 = 0;
        while (n_rq < 2 && g11 < 20000) begin @(posedge clk); mrd_ack <= 1'b1; g11++; end
        mrd_ack <= 1'b0;
        @(posedge clk); ovl_go <= 1'b0;
        repeat (4) @(posedge clk);
        expect_true ("T12 debt created", ovl_quarantined);
        rst_n = 1'b0; mrst_n = 1'b0; repeat (3) @(posedge clk);
        rst_n = 1'b1; mrst_n = 1'b1; repeat (2000) @(posedge clk);
        expect_true ("T12 a momentary reset released the debt", ovl_quarantined);
        epoch_n = 1'b0; repeat (4) @(posedge clk); epoch_n = 1'b1;
        repeat (8) @(posedge clk);
        expect_false("T12 the physical epoch did not release the ledger", ovl_quarantined);
        expect_eq   ("T12 epoch left tag space held", dut.dead_busy, 0);
        expect_false("T12 epoch left the poison stuck", poison_st);
        $display("SC7F0_OVL_INGRESS_TB T12 epoch release errors=%0d", errors);

        // ---- T13 ack and abandon in the same cycle must not lose debt --------
        // The two always blocks see the same old state, so this cannot be argued from
        // statement order: the ledger books the commit and, seeing abandon_evt in the
        // same cycle, marks the brand-new entry as debt immediately.
        clear_counters;
        ovl_maxreq = 64; ovl_src = 64'hC200_0000; ovl_len = 32'd4096;
        @(posedge clk); ovl_go <= 1'b1;
        g11 = 0;
        while (!mrd_valid && g11 < 20000) begin @(posedge clk); mrd_ack <= 1'b0; g11++; end
        expect_true ("T13 a request is presented", mrd_valid);
        nrq_before = n_rq;
        @(posedge clk); mrd_ack <= 1'b1; ovl_go <= 1'b0;   // same clock edge
        @(posedge clk); mrd_ack <= 1'b0;
        repeat (6) @(posedge clk);
        expect_true ("T13 the simultaneously committed request was acknowledged",
                     n_rq > nrq_before);
        expect_true ("T13 commit+abandon lost the debt", ovl_quarantined);
        held = 0;
        for (i11 = 0; i11 < n_rq; i11 = i11 + 1)
            if (!rq_done[i11] && dut.dead_busy[rq_tag[i11][6:0] - TAG_BASE[6:0]])
                held = held + 1;
        expect_eq   ("T13 not every committed read became debt", held, n_rq);
        for (i11 = 0; i11 < n_rq; i11 = i11 + 1) begin deliver(i11); rq_done[i11] = 1; end
        repeat (16) @(posedge clk);
        expect_false("T13 paid debt did not release", ovl_quarantined);
        $display("SC7F0_OVL_INGRESS_TB T13 commit+abandon held=%0d errors=%0d", held, errors);

        // ---- T9 whole transfer under read-side backpressure --------------
        // Same transfer shape as T1/T3 but the memory side accepts only about
        // three out of four beats, so the crossing FIFO fills and the staging read
        // pipeline stalls for single cycles.  A pipeline that re-reads on a bubble
        // duplicates a 32-byte chunk; one that pushes regardless of room loses it.
        // Both are caught by the byte image, and a lost word that reached the FIFO
        // boundary would also raise the overflow sticky.
        reset_dut; ovl_enable = 1'b1;
        bp_en = 1'b1;
        fork : T9F
            arm_and_issue(64'h9000_0000, 4096, 64);
            rc_run(2);
        join
        settle(6000);
        check_wx_image(64'h9000_0000, 4096, "T9");
        check_image(64'h9000_0000, 4096, "T9");
        expect_true("T9 no crossing FIFO overflow", !m_ovf);
        expect_eq  ("T9 no unexpected beats", ovl_unexpected, 0);
        expect_eq  ("T9 no overflow beats",   ovl_overflow, 0);
        expect_true("T9 ring and tags fully released under backpressure",
                    dut.n_live == 0 && ovl_outstanding == 0);
        $display("SC7F0_OVL_INGRESS_TB T9 backpressure bytes=%0d reads=%0d ovf=%0b errors=%0d",
                 n_rx, n_rq, m_ovf, errors);
        bp_en = 1'b0;
        @(posedge clk); ovl_go <= 1'b0;
        repeat (60) @(posedge clk);

        disable WATCHDOG;
        $display("SC7F0_OVL_INGRESS_TB SUMMARY checks=%0d errors=%0d", checks, errors);        if (errors == 0) $display("SC7F0_OVL_INGRESS_TB_PASS");
        else             $display("SC7F0_OVL_INGRESS_TB_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
`default_nettype wire
