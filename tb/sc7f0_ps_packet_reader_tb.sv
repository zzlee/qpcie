`timescale 1ns/1ps
// =============================================================================
// tb/sc7f0_ps_packet_reader_tb.sv
//
// Unit testbench for rtl/sc7f0_ps_packet_reader.v  (u_dualpath/u_reader, the
// capture_clk_300m same-domain group whose routed WNS holder in round 26111202
// was remaining_reg[10] -> tx_last_be_reg[2], -0.225 ns, 12 logic levels).
//
// This TB was written BEFORE the critical-cone edit and the unedited RTL was
// run against it first, so the pre-edit run is the A/B reference.  The checker
// is an independent model of the packet-DMA contract (chunking, 4 KiB
// non-crossing, first_be/last_be, per-byte payload, completion record,
// ready/valid stability and backpressure), not a copy of the RTL arithmetic.
//
// Enabled-byte rule comes from the real consumer (rtl/rq_tx_encoder.v):
// last_be is ignored when dw_len == 1; DW0 uses first_be, the last DW uses
// last_be, middle DWs are fully enabled.  tb/sc7f0_dualpath_tb.sv uses the
// same rule, so byte-level agreement here also implies agreement downstream
// (that TB additionally checks SOP/EOP/tkeep/tlast and host RAM contents).
//
// Deterministic: xorshift32 with a fixed seed, printed as TB_SEED (0x13579BDF
// unless overridden with +SEED=<hex>).  No $random/$urandom, no time seeds.
//
// Run:
//   iverilog -g2012 -s sc7f0_ps_packet_reader_tb -o /tmp/reader.vvp \
//       rtl/sc7f0_ps_packet_reader.v tb/sc7f0_ps_packet_reader_tb.sv
//   vvp /tmp/reader.vvp          # +NOBIG shortens the >=4 MiB frame jobs
// =============================================================================
module sc7f0_ps_packet_reader_tb;
    localparam integer MEM_BYTES  = 16*1024*1024;   // PS DDR model
    localparam integer HOST_BYTES = 16*1024*1024;   // host RAM model

    // ------------------------------------------------------------------ clock
    reg clk = 0;
    always #1.6665 clk = ~clk;      // 3.333 ns = the 300.03 MHz requirement
    reg rst_n = 0;

    // --------------------------------------------------------------------- DUT
    reg  [767:0] cmd_data = 0;
    reg          cmd_valid = 0;
    wire         cmd_ready;
    wire [511:0] done_data;
    wire         done_valid;
    reg          done_ready = 0;
    wire         busy;
    wire [39:0]  araddr;
    wire [7:0]   arlen;
    wire [2:0]   arsize;
    wire [1:0]   arburst;
    wire         arvalid;
    reg          arready = 0;
    reg  [127:0] rdata = 0;
    reg  [1:0]   rresp = 0;
    reg          rlast = 0;
    reg          rvalid = 0;
    wire         rready;
    wire         tx_valid;
    reg          tx_ready = 0;
    wire [63:0]  tx_addr;
    wire [10:0]  tx_dw_len;
    wire [3:0]   tx_first_be, tx_last_be;
    wire [2047:0] tx_payload;
    reg          tx_done = 0;
    wire         packet_done_pulse;
    wire         packet_err_pulse;
    wire [31:0]  packet_last_len;
    wire [63:0]  packet_last_pts;
    wire [7:0]   packet_fsm_state;

    sc7f0_ps_packet_reader dut(
        .clk(clk), .rst_n(rst_n),
        .cmd_data(cmd_data), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .done_data(done_data), .done_valid(done_valid), .done_ready(done_ready),
        .busy(busy),
        .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx_addr(tx_addr), .tx_dw_len(tx_dw_len),
        .tx_first_be(tx_first_be), .tx_last_be(tx_last_be),
        .tx_payload(tx_payload), .tx_done(tx_done),
        .packet_done_pulse(packet_done_pulse), .packet_err_pulse(packet_err_pulse),
        .packet_last_len(packet_last_len), .packet_last_pts(packet_last_pts),
        .packet_fsm_state(packet_fsm_state));

    // ------------------------------------------------------------------ memory
    byte unsigned ps_mem[0:MEM_BYTES-1];
    byte unsigned host_mem[0:HOST_BYTES-1];

    function automatic [7:0] pat(input integer a);
        pat = ((a*7) + ((a>>8)*13) + ((a>>4)*5) + 32'h5A) & 8'hff;
    endfunction

    // ------------------------------------------------------------- rng / knobs
    int unsigned rng = 32'h13579BDF;
    function automatic int unsigned rnd;
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            rnd = rng;
        end
    endfunction

    integer bp_mode      = 0;   // 0 eager ready, 1 random backpressure
    integer stall_tx     = 0;   // force tx_ready low (long-stall test)
    integer stall_pop    = 0;   // force done_ready low (completion full test)
    integer slave_gaps   = 0;   // 1 = random AR/R gaps
    integer dbg        = 0;   // +DBG prints one line per AR/R event
    integer nobig        = 0;   // +NOBIG shortens the frame-sized jobs
    integer fastfail     = 0;   // +FASTFAIL stops at the first mismatch
    integer expect_quiet = 0;   // no tx traffic allowed while set
    integer job_aborted  = 0;   // reset struck in the middle of run_job

    // ------------------------------------------------------- job/model context
    integer m_phase = 0;        // 1 data expected, 2 record expected,
                                // 3 no packet expected, 0 nothing running
    integer m_valid_cmd = 0;
    integer m_rem = 0, m_transferred = 0, m_err = 0;
    integer m_len = 0;
    reg [39:0] m_src = 0, m_dst = 0;
    reg [63:0] m_comp = 0, m_pts = 0;
    reg [63:0] m_j320 = 0, m_j384 = 0, m_j448 = 0;
    reg [31:0] m_flags = 0, m_j544 = 0, m_j576 = 0, m_j608 = 0, m_j640 = 0;
    integer m_inject = 0;       // one-shot injection for this job
    integer inj_now  = 0;       // injection armed on the current read burst
    integer m_chunks = 0, m_job_data_pkts = 0, m_job_bytes = 0;

    // at most one chunk is in flight (the FSM is strictly sequential)
    integer   a_chunk = 0, a_pending = 0, a_record_after = 0;
    reg [39:0] a_src = 0, a_dst = 0;

    // -------------------------------------------------------------- statistics
    integer n_jobs = 0, n_reject = 0, n_err_jobs = 0, n_aborted = 0;
    integer n_data_pkts = 0, n_rec_pkts = 0, n_enabled = 0;
    integer n_ar = 0, n_beats = 0, n_resets = 0, n_done = 0;
    integer n_err_pulses = 0, n_done_pulses = 0, n_stable_checks = 0;
    integer max_chunk = 0, min_chunk = 1000000;
    reg [15:0] seen_first_be = 0, seen_last_be = 0;
    integer errors = 0;

    task automatic fail(input [255:0] msg);
        begin
            errors = errors + 1;
            $display("READER_TB_FAIL %0s @%0t fsm=%h busy=%b phase=%0d",
                     msg, $time, packet_fsm_state, busy, m_phase);
            if (fastfail) begin
                $display("READER_TB_RESULT FAIL errors=%0d (FASTFAIL) seed=%h", errors, rng);
                $fatal(1, "sc7f0_ps_packet_reader_tb first failure");
            end
        end
    endtask

    // Failure isolation: a model/RTL disagreement must not be allowed to
    // desync the following cases.  Reset the DUT and re-arm the checkers.
    task automatic isolate;
        begin
            rst_n = 0;
            n_resets = n_resets + 1;
            repeat (8) @(negedge clk);
            rst_n = 1;
            repeat (4) @(negedge clk);
            m_phase = 0; a_pending = 0; a_record_after = 0; m_valid_cmd = 0;
            m_inject = 0; inj_now = 0; rd_left = 0; rvalid = 0; rlast = 0; arready = 0;
            rresp = 0; stall_tx = 0; stall_pop = 0; cmd_valid = 0; tx_valid_q = 0;
            expect_quiet = 0;
            repeat (4) @(negedge clk);
        end
    endtask

    // ---------------------------------------------------- contract-level model
    // chunk = min(remaining, 256, 4096-src_off, 4096-dst_off)
    function automatic integer m_chunk(input [39:0] s, input [39:0] d, input integer rem);
        integer a, b, c;
        begin
            a = rem;               if (a > 256) a = 256;
            b = 4096 - s[11:0];    if (b > 256) b = 256;
            c = 4096 - d[11:0];    if (c > 256) c = 256;
            if (b < a) a = b;
            if (c < a) a = c;
            m_chunk = a;
        end
    endfunction

    function automatic [3:0] m_first_be(input integer chunk);
        m_first_be = (chunk < 4) ? ((4'h1 << chunk[1:0]) - 4'h1) : 4'hf;
    endfunction
    function automatic [3:0] m_last_be(input integer chunk);
        m_last_be = (chunk <= 4) ? 4'h0
                  : (chunk[1:0] == 2'b00) ? 4'hf
                  : ((4'h1 << chunk[1:0]) - 4'h1);
    endfunction
    function automatic bit low_mask(input [3:0] m);
        low_mask = (m === 4'h0) || (m === 4'h1) || (m === 4'h3) ||
                   (m === 4'h7) || (m === 4'hf);
    endfunction
    function automatic integer pop4(input [3:0] m);
        integer i, n;
        begin n = 0; for (i = 0; i < 4; i = i+1) if (m[i]) n = n+1; pop4 = n; end
    endfunction
    // exactly the rule used by rtl/rq_tx_encoder.v for c2h requests
    function automatic integer enabled_bytes(input [10:0] dw, input [3:0] fb, input [3:0] lb);
        integer k, n;
        begin
            n = 0;
            for (k = 0; k < dw; k = k+1)
                n = n + pop4(k == 0 ? fb : (k == dw-1 ? lb : 4'hf));
            enabled_bytes = n;
        end
    endfunction

    // job acceptance contract: exactly the documented job ABI (same predicates
    // the reader's cmd_ok uses: 16 byte alignment, 40 bit source space, 4 KiB
    // addressable host window rules, length vs capacity, 8 MiB cap, and the
    // EOS flag requirement for a zero-length job).
    function automatic bit m_cmd_ok(input [63:0] s, input [63:0] d, input [63:0] c,
                                    input [31:0] len, input [31:0] cap, input [31:0] fl);
        reg [64:0] se, de, ce;
        bit ok;
        begin
            se = {1'b0, s} + {25'd0, len};
            de = {1'b0, d} + {25'd0, len};
            ce = {1'b0, c} + 65'd64;
            ok = 1'b1;
            if (s[63:40] != 0)        ok = 1'b0;
            if (s[3:0]   != 0)        ok = 1'b0;
            if (d[3:0]   != 0)        ok = 1'b0;
            if (c[3:0]   != 0)        ok = 1'b0;
            if (c == 0)               ok = 1'b0;
            if (len > cap)            ok = 1'b0;
            if (len > 32'h00800000)   ok = 1'b0;
            if (se >= 65'h10000000000) ok = 1'b0;
            if (de[64])               ok = 1'b0;
            if (ce[64])               ok = 1'b0;
            if (len == 0 && fl[6] == 0) ok = 1'b0;   // zero length needs EOS
            m_cmd_ok = ok;
        end
    endfunction

    function automatic [767:0] build_cmd(input [63:0] s, input [63:0] d, input [63:0] c,
                                         input [31:0] len, input [31:0] cap, input [63:0] pts,
                                         input [31:0] fl);
        reg [767:0] w;
        begin
            w = 0;
            w[63:0]    = s;
            w[127:64]  = d;
            w[159:128] = len;
            w[191:160] = cap;
            w[255:192] = c;
            w[319:256] = pts;
            w[383:320] = m_j320;
            w[447:384] = m_j384;
            w[511:448] = m_j448;
            w[543:512] = fl;
            w[575:544] = m_j544;
            w[607:576] = m_j576;
            w[639:608] = m_j608;
            w[671:640] = m_j640;
            build_cmd = w;
        end
    endfunction

    // expected completion record: 512 bit little-endian DWORD stream
    task automatic model_completion(input [31:0] err, input [31:0] xferred,
                                    output [511:0] rec);
        begin
            rec = 0;
            rec[31:0]    = 32'h44504331;         // "DPC1"
            rec[63:32]   = err;
            rec[127:64]  = m_j384;
            rec[191:128] = m_j448;
            rec[255:192] = m_pts;
            rec[319:256] = m_j320;
            rec[351:320] = xferred;
            rec[383:352] = m_flags;
            rec[415:384] = m_j544;
            rec[447:416] = m_j576;
            rec[479:448] = m_j608;
            rec[511:480] = m_j640;
        end
    endtask

    // ------------------------------------------------------------- AXI read VIP
    integer rd_left = 0, rd_gap = 0;
    reg [39:0] rd_addr = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            arready <= 0; rvalid <= 0; rlast <= 0; rresp <= 0;
            rd_left <= 0; rd_addr <= 0; rd_gap <= 0; inj_now <= 0;
        end else begin
            arready <= 0;
            if (arvalid && !arready && rd_left == 0 && !rvalid) begin
                if (slave_gaps && (rnd() % 4) == 0) begin
                    if (dbg) $display("EV %0t AR_HOLD arlen=%0d araddr=%h", $time, arlen, araddr);
                end else ar_accept;
            end
            if (rvalid && rready) begin
                if (dbg) $display("EV %0t R_ACC rd_left=%0d rlast=%b addr=%h",
                                  $time, rd_left, rlast, rd_addr);
                rvalid <= 0; rlast <= 0;
                rd_addr <= rd_addr + 16;
                rd_left <= rd_left - 1;
                if (rlast) inj_now <= 0;
            end
            if (!rvalid && rd_left != 0) begin
                if (rd_gap != 0) rd_gap <= rd_gap - 1;
                else begin
                    if (dbg) $display("EV %0t R_DRV rd_left=%0d addr=%h",
                                      $time, rd_left, rd_addr);
                    drive_rdata;
                    rvalid <= 1;
                    rlast  <= (rd_left == 1);
                    // rd_left counts beats still to be PRESENTED; it is only
                    // decremented when the beat is accepted (see above).
                    rresp  <= (inj_now == 1) ? 2'b10 : 2'b00;
                    rd_gap <= slave_gaps ? (rnd() % 3) : 0;
                end
            end
        end
    end

    task automatic drive_rdata;
        integer k, a;
        begin
            a = rd_addr;
            for (k = 0; k < 16; k = k+1) rdata[k*8 +: 8] <= ps_mem[a + k];
            n_beats = n_beats + 1;
        end
    endtask

    // AR acceptance plus every read-side contract check
    task automatic ar_accept;
        integer ch, beats, span;
        begin
            n_ar = n_ar + 1;
            arready <= 1;
            if (expect_quiet) fail("AR during quiet window");
            if (!m_valid_cmd) fail("AR issued for a rejected command");
            if (m_phase == 0) fail("AR issued with no job");
            if (arsize !== 3'd4)   fail("arsize != 4 (16 byte beat)");
            if (arburst !== 2'b01) fail("arburst != INCR");
            if (araddr[3:0] !== 4'd0) fail("araddr not 16 byte aligned");
            if (arvalid && arready) fail("duplicate AR acceptance");
            ch    = m_chunk(m_src, m_dst, m_rem);
            beats = (ch + 15) / 16;
            if (araddr !== m_src) fail("araddr != current chunk source");
            if ({1'b0, araddr} + 64'd16*beats > MEM_BYTES)
                fail("read burst runs past the PS memory model");
            a_chunk = ch; a_src = m_src; a_dst = m_dst;
            rd_addr <= araddr;
            rresp   <= 2'b00;
            inj_now <= m_inject;
            if (m_inject != 0) begin
                // drive the wrong number of beats / a failing RRESP
                rd_left <= (m_inject == 2) ? (beats - 1)
                         : (m_inject == 3) ? (beats + 1) : beats;
                if (m_inject == 1) m_err = m_err | 2;
                else               m_err = m_err | 4;
                m_inject = 0;
                a_pending = 0;         // a bad chunk must never reach the host
                a_record_after = 0;
                m_phase = 2;           // completion record is next
            end else begin
                rd_left <= beats;
                a_pending = 1;
                m_rem = m_rem - ch;
                m_transferred = m_transferred + ch;
                m_src = m_src + ch;
                m_dst = m_dst + ch;
                m_chunks = m_chunks + 1;
                if (ch > max_chunk) max_chunk = ch;
                if (ch < min_chunk) min_chunk = ch;
                a_record_after = (m_rem == 0);
            end
            span = 16 * (arlen + 1);
            if (span != 16*beats)   fail("arlen inconsistent with beats");
            if (span < ch)          fail("read burst shorter than payload");
            if (span - 16 >= ch)    fail("read burst longer than needed");
            if ({1'b0, araddr[11:0]} + span > 65'd4096) fail("read burst crosses 4 KiB");
        end
    endtask

    // ------------------------------------------------------------- tx packet VIP
    integer ack_wait = 0;
    reg ack_pend = 0, tx_valid_q = 0, tx_ready_q = 0, holding = 0;
    reg [63:0]   hold_addr = 0;
    reg [10:0]   hold_dw = 0;
    reg [3:0]    hold_fb = 0, hold_lb = 0;
    reg [2047:0] hold_pay = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_ready <= 0; tx_done <= 0; ack_pend <= 0; ack_wait <= 0;
            tx_valid_q <= 0; tx_ready_q <= 0; holding <= 0;
        end else begin
            tx_valid_q <= tx_valid;
            tx_ready_q <= tx_ready;
            tx_done <= 0;
            // ready is never generated from valid
            if (stall_tx)                     tx_ready <= 0;
            else if (bp_mode == 0)            tx_ready <= 1;
            else                              tx_ready <= (rnd() % 100) < 55;
            // accept -> completion ack some cycles later
            if (tx_valid && tx_ready) begin
                ack_pend <= 1;
                ack_wait <= (bp_mode == 1) ? (1 + (rnd() % 9)) : 2;
            end else if (ack_pend) begin
                if (ack_wait <= 1) begin tx_done <= 1; ack_pend <= 0; end
                else ack_wait <= ack_wait - 1;
            end
            // valid+payload must be frozen while ready is low, and may only drop
            // after a handshake (no retraction, no implicit resend)
            if (tx_valid && !tx_valid_q && !holding) begin
                hold_addr <= tx_addr; hold_dw <= tx_dw_len;
                hold_fb <= tx_first_be; hold_lb <= tx_last_be;
                hold_pay <= tx_payload; holding <= 1;
            end else if (tx_valid && holding && !tx_ready_q) begin
                n_stable_checks = n_stable_checks + 1;
                if (tx_addr !== hold_addr || tx_dw_len !== hold_dw ||
                    tx_first_be !== hold_fb || tx_last_be !== hold_lb ||
                    tx_payload !== hold_pay)
                    fail("tx payload/header changed while valid && !ready");
            end
            if (tx_valid_q && !tx_valid && !tx_ready_q)
                fail("tx_valid withdrew without a handshake");
            if (tx_valid && tx_ready)          holding <= 0;
            else if (!tx_valid && holding)     holding <= 0;
        end
    end

    always @(posedge clk) if (rst_n && tx_valid && tx_ready) check_packet;

    task automatic check_packet;
        integer exp_en, k, z, n, cnt;
        reg [3:0] mask, efb, elb;
        reg [10:0] edw;
        reg [511:0] erec;
        begin
            if (expect_quiet) fail("tx packet during quiet window");
            if (a_pending) begin
                // --------------------------- data packet -------------------
                if (m_phase != 1) fail("unexpected data packet");
                a_pending = 0;
                efb = m_first_be(a_chunk);
                elb = m_last_be(a_chunk);
                edw = (a_chunk + 3) / 4;
                if (tx_addr !== a_dst)   fail("data packet address != expected dst");
                if (tx_dw_len !== edw)   fail("data packet dw_len wrong");
                if (tx_first_be !== efb) fail("first_be wrong");
                if (tx_last_be !== elb)  fail("last_be wrong");
                if (!low_mask(tx_first_be) || !low_mask(tx_last_be))
                    fail("byte enable is not a contiguous low mask");
                if (tx_addr[3:0] !== 4'd0) fail("host packet not 16 byte aligned");
                if ({1'b0, tx_addr[11:0]} + a_chunk > 65'd4096)
                    fail("host packet crosses 4 KiB boundary");
                exp_en = enabled_bytes(tx_dw_len, tx_first_be, tx_last_be);
                if (exp_en != a_chunk) fail("enabled byte count != chunk size");
                cnt = 0;
                for (k = 0; k < tx_dw_len; k = k+1) begin
                    mask = (k == 0) ? tx_first_be
                                    : ((k == tx_dw_len-1) ? tx_last_be : 4'hf);
                    for (z = 0; z < 4; z = z+1) if (mask[z]) begin
                        n = k*4 + z;
                        if (n >= a_chunk) fail("byte enable beyond payload");
                        if (tx_payload[n*8 +: 8] !== ps_mem[a_src + n])
                            fail("payload byte mismatch");
                        if (a_dst + n >= HOST_BYTES) fail("host write outside model");
                        else host_mem[a_dst + n] = tx_payload[n*8 +: 8];
                        cnt = cnt + 1;
                    end
                end
                if (cnt != a_chunk) fail("walked byte count mismatch");
                n_data_pkts = n_data_pkts + 1;                n_enabled   = n_enabled + cnt;
                m_job_data_pkts = m_job_data_pkts + 1;
                m_job_bytes = m_job_bytes + cnt;
                seen_first_be[tx_first_be] = 1'b1;
                seen_last_be[tx_last_be]   = 1'b1;
                if (a_record_after) m_phase = 2;
            end else if (m_phase == 2) begin
                // ------------------------ completion record ----------------
                if (tx_dw_len !== 11'd16) fail("record dw_len != 16");
                if (tx_first_be !== 4'hf || tx_last_be !== 4'hf) fail("record be != f");
                if (tx_addr !== m_comp) fail("record address != completion address");
                model_completion(m_err[31:0], m_transferred[31:0], erec);
                for (n = 0; n < 64; n = n+1) begin
                    if (tx_payload[n*8 +: 8] !== erec[n*8 +: 8])
                        fail("completion record byte mismatch");
                    if (tx_addr + n >= HOST_BYTES) fail("record write outside model");
                    else host_mem[tx_addr + n] = tx_payload[n*8 +: 8];
                end
                n_rec_pkts = n_rec_pkts + 1;
                seen_first_be[4'hf] = 1'b1;
                seen_last_be[4'hf]  = 1'b1;
                m_phase = 3;
            end else fail("tx packet not expected by the model");
        end
    endtask

    // ------------------------------------------------------- completion/report
    reg done_hs = 0, done_pulse_q = 0, err_pulse_q = 0;
    reg [511:0] done_hold = 0;
    reg done_holding = 0, done_ready_q = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            done_hs <= 0; done_holding <= 0; done_pulse_q <= 0; err_pulse_q <= 0;
            done_ready_q <= 0;
        end else begin
            done_ready_q <= done_ready;
            done_hs  <= done_valid && done_ready;
            done_pulse_q <= packet_done_pulse;
            err_pulse_q  <= packet_err_pulse;
            if (packet_done_pulse && !done_pulse_q) n_done_pulses = n_done_pulses + 1;
            if (packet_err_pulse  && !err_pulse_q)  n_err_pulses  = n_err_pulses + 1;
            // report must stay stable while the CSR side is not ready
            if (done_valid && !done_holding) begin
                done_hold <= done_data; done_holding <= 1;
            end else if (done_valid && done_holding && !done_ready_q) begin
                n_stable_checks = n_stable_checks + 1;
                if (done_data !== done_hold)
                    fail("done_data changed while done_valid && !done_ready");
            end
            if (done_hs)                        done_holding <= 0;
            else if (!done_valid && done_holding) done_holding <= 0;
        end
    end

    // completion FIFO: pop unless the test is deliberately holding it full
    always @(posedge clk) begin
        if (!rst_n)                             done_ready <= 0;
        else if (stall_pop)                     done_ready <= 0;
        else if (bp_mode == 1)                  done_ready <= (rnd() % 100) < 60;
        else                                    done_ready <= 1;
    end

    always @(posedge clk) if (rst_n && done_valid && done_ready) check_report;

    task automatic check_report;
        reg [511:0] exp_rec;
        begin
            n_done = n_done + 1;
            model_completion(m_err[31:0], m_transferred[31:0], exp_rec);
            if (done_data !== exp_rec) begin
                $display("  done_data[63:0]=%h exp %h xferred=%0d err=%0d",
                         done_data[63:0], exp_rec[63:0], m_transferred, m_err);
                fail("completion report content mismatch");
            end
            if (packet_last_len !== m_transferred[31:0]) fail("packet_last_len mismatch");
            if (packet_last_pts !== m_pts)              fail("packet_last_pts mismatch");
            if (m_valid_cmd && m_err == 0 && m_phase != 3)
                fail("report raised before the completion record packet");
            if (!m_valid_cmd && (m_job_data_pkts != 0 || m_job_bytes != 0))
                fail("rejected job produced data");
        end
    endtask

    // --------------------------------------------------------------- command in
    reg cmd_hs = 0;
    always @(posedge clk) cmd_hs <= cmd_valid && cmd_ready;

    task automatic issue(input [767:0] c);
        integer g;
        begin
            g = 0;
            @(negedge clk);
            cmd_data = c; cmd_valid = 1;
            while (cmd_hs !== 1'b1 && g < 2000) begin
                @(negedge clk);
                g = g + 1;
            end
            if (cmd_hs !== 1'b1 && !job_aborted) fail("cmd never accepted");
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    // ----------------------------------------------------------------- main job
    // Window guard: a job that is legal per the ABI but outside the simulated
    // RAM windows is skipped rather than guessed at.
    task automatic run_job(input [63:0] s, input [63:0] d, input [63:0] c,
                           input [31:0] len, input [31:0] cap, input [63:0] pts,
                           input [31:0] fl, input integer inject,
                           input [255:0] label);
        begin
            if (m_cmd_ok(s, d, c, len, cap, fl) &&
                (s >= MEM_BYTES || s + len > MEM_BYTES ||
                 d >= HOST_BYTES || d + len > HOST_BYTES || c + 64 > HOST_BYTES))
                $display("JOB %0s SKIPPED out of model window src=%h dst=%h len=%0d",
                         label, s, d, len);
            else
                run_job_core(s, d, c, len, cap, pts, fl, inject, label);
        end
    endtask

    task automatic run_job_core(input [63:0] s, input [63:0] d, input [63:0] c,
                           input [31:0] len, input [31:0] cap, input [63:0] pts,
                           input [31:0] fl, input integer inject,
                           input [255:0] label);
        integer i, sa, da, ca, limit, done_before;
        bit ok_exp;
        reg [767:0] cw;
        begin
            n_jobs = n_jobs + 1;
            ok_exp = m_cmd_ok(s, d, c, len, cap, fl);
            sa = s; da = d; ca = c;
            if (ok_exp) begin
                for (i = 0; i < len; i = i+1) ps_mem[sa + i] = pat(sa + i);
                for (i = -16; i < len + 16; i = i+1)
                    if (da + i >= 0 && da + i < HOST_BYTES) host_mem[da + i] = 8'hA5;
                for (i = 0; i < 64; i = i+1) host_mem[ca + i] = 8'hA5;
            end
            errors_at_start = errors;
            // ---- job model (a rejected job reports error bit 0)
            m_valid_cmd = ok_exp;
            m_src = s[39:0]; m_dst = d[39:0]; m_comp = c; m_pts = pts;
            m_flags = fl; m_len = len;
            m_rem = len; m_transferred = 0;
            m_err = ok_exp ? 0 : 1;
            m_inject = inject;
            m_chunks = 0; m_job_data_pkts = 0; m_job_bytes = 0;
            a_pending = 0; a_record_after = 0;
            m_phase = ok_exp ? ((len == 0) ? 2 : 1) : 3;
            if (!ok_exp)  n_reject   = n_reject + 1;
            if (inject != 0) n_err_jobs = n_err_jobs + 1;
            done_before = n_done;
            cw = build_cmd(s, d, c, len, cap, pts, fl);
            issue(cw);
            // Cycle watchdog: worst case is ~90 cycles per 16 byte chunk when
            // AR gaps, R gaps and random tx backpressure all align.
            limit = 20000 + (len*3)/8;
            while (n_done == done_before && !job_aborted && limit > 0) begin
                @(negedge clk);
                limit = limit - 1;
            end
            if (limit == 0 && !job_aborted) begin dump_stall; fail("job timeout"); end
            if (job_aborted) m_phase = 0;
            if (!job_aborted) repeat (40) @(negedge clk);  // let stragglers land            if (!job_aborted && busy !== 1'b0) fail("busy did not return to 0");
            if (!job_aborted && a_pending != 0) fail("a read chunk never produced a packet");
            if (m_valid_cmd && m_err == 0 && !job_aborted) begin
                if (m_transferred != len)      fail("transfer total != length");
                if (m_job_bytes   != len)      fail("DMA'd byte total != length");
                if (len != 0 && m_chunks == 0) fail("no chunk for a non-empty job");
                if (m_phase != 3)              fail("no completion record packet");
            end
            if (m_valid_cmd && m_err != 0 && m_transferred >= len && !job_aborted)
                fail("injected error did not truncate the job");
            if (!m_valid_cmd && !job_aborted) begin
                if (m_job_bytes != 0 || m_job_data_pkts != 0 || n_rec_pkts < 0)
                    fail("rejected job produced data");
                if (m_phase != 3) fail("rejected job produced a record");
            end
            if (job_aborted)
                $display("JOB %0s ABORTED_BY_RESET chunks=%0d bytes=%0d",
                         label, m_chunks, m_job_bytes);
            else
                $display("JOB %0s len=%0d src=%h dst=%h ok=%0b chunks=%0d bytes=%0d pkts=%0d err=%0d",
                         label, len, s, d, ok_exp, m_chunks, m_job_bytes,
                         m_job_data_pkts, m_err);
            // ---- keep one bad case from polluting the next one
            if (!job_aborted && errors != errors_at_start) begin
                $display("JOB_ISOLATION_RESET after failure in %0s (errors=%0d)",
                         label, errors);
                isolate;
            end
        end
    endtask

    // Stall diagnostics for a job that did not finish: dump both sides.
    task automatic dump_stall;
        begin
            $display("STALL arvalid=%b arready=%b rvalid=%b rready=%b rlast=%b rresp=%b rd_left=%0d rd_gap=%0d rd_addr=%h inj_now=%0d dut_state=%h arlen=%0d araddr=%h tx_valid=%b tx_ready=%b ack_pend=%b",
                     arvalid, arready, rvalid, rready, rlast, rresp,
                     rd_left, rd_gap, rd_addr, inj_now,
                     dut.state, arlen, araddr, tx_valid, tx_ready, ack_pend);
            $display("STALL model rem=%0d transferred=%0d chunk=%0d src=%h dst=%h pending=%b phase=%0d",
                     m_rem, m_transferred, a_chunk, m_src, m_dst, a_pending, m_phase);
        end
    endtask

    // ------------------------------------------------------------- test sequence
    integer base, L, i, done_before, errors_at_start, ar_before;

    initial begin
        if ($test$plusargs("NOBIG")) nobig = 1;
        if ($test$plusargs("DBG")) dbg = 1;
        if ($test$plusargs("FASTFAIL")) fastfail = 1;
        if ($value$plusargs("SEED=%h", rng)) ;
        for (i = 0; i < HOST_BYTES; i = i+1) host_mem[i] = 8'h00;
        m_j320 = 64'h0123456789abcdef;
        m_j384 = 64'hf0f0f0f00f0f0f0f;
        m_j448 = 64'h00ff00ee00dd00cc;
        m_j544 = 32'h5a5a5a5a; m_j576 = 32'h1234abcd;
        m_j608 = 32'hdeadbeef; m_j640 = 32'h0000c0de;
        $display("TB_SEED=%h NOBIG=%0d", rng, nobig);
        $display("TB_START clk_period_ns=3.333 (300.03MHz, unchanged)");
        #100;
        rst_n = 1;
        repeat (10) @(negedge clk);

        // ================= 1. rejected commands (negative, must stay empty)
        expect_quiet = 1;
        run_job(64'h00100001, 64'h00200000, 64'h00300000, 32'd64, 32'd4096,
                64'h1111222233334444, 32'd0, 0, "reject_src_unaligned");
        run_job(64'h00100000, 64'h00200004, 64'h00300000, 32'd64, 32'd4096,
                64'h1111222233334444, 32'd0, 0, "reject_dst_unaligned");
        run_job(64'h00100000, 64'h00200000, 64'h00300004, 32'd64, 32'd4096,
                64'h1111222233334444, 32'd0, 0, "reject_comp_unaligned");
        run_job(64'h00100000, 64'h00200000, 64'h00000000, 32'd64, 32'd4096,
                64'h1111222233334444, 32'd0, 0, "reject_comp_zero");
        run_job(64'h00100000, 64'h00200000, 64'h00300000, 32'd4096, 32'd4095,
                64'h1111222233334444, 32'd0, 0, "reject_len_gt_cap");
        run_job(64'h00100000, 64'h00200000, 64'h00300000, 32'h00800001, 32'hFFFFFFFF,
                64'h1111222233334444, 32'd0, 0, "reject_len_gt_8M");
        run_job(64'h00100000, 64'h00200000, 64'h00300000, 32'd0, 32'd4096,
                64'h1111222233334444, 32'd0, 0, "reject_len0_no_eos");
        run_job(64'h0000010000000000, 64'h00200000, 64'h00300000, 32'd1024, 32'hFFFFFFFF,
                64'h1111222233334444, 32'd0, 0, "reject_src_above_40b");
        run_job(64'h00100000, 64'hfffffffffffffff0, 64'h00300000, 32'd128, 32'hFFFFFFFF,
                64'h1111222233334444, 32'd0, 0, "reject_dst_end_over_64b");
        run_job(64'h00100000, 64'h00200000, 64'hffffffffffffffc0, 32'd64, 32'hFFFFFFFF,
                64'h1111222233334444, 32'd0, 0, "reject_comp_end_over_64b");
        expect_quiet = 0;
        run_job(64'h00100000, 64'h00200000, 64'h00300000, 32'd1024, 32'd4096,
                64'h1111222233334444, 32'd0, 0, "accept_after_reject");

        // ================= 2. zero length contract (EOS): record only
        run_job(64'h00100000, 64'h00200000, 64'h00300000, 32'd0, 32'd4096,
                64'h5566778811223344, 32'h00000040, 0, "len0_eos_record_only");

        // ================= 3. every length 1..64 (all first_be/last_be masks)
        for (L = 1; L <= 64; L = L+1)
            run_job(64'h00100000, 64'h00200000, 64'h00300000, L, 32'hFFFFFFFF,
                    64'h0BADF00D00000000 + L, 32'd0, 0, "len_small_aligned");

        // ================= 4. 1..20 with a 16-byte-rotated source/destination
        for (L = 1; L <= 20; L = L+1)
            run_job(64'h00120000 + 16*L, 64'h00410000 + 16*L, 64'h00300000,
                    L, 32'hFFFFFFFF, 64'h0BADF00D10000000 + L, 32'd0, 0,
                    "len_small_offset");

        // ================= 5. beat / chunk / 4 KiB boundary lengths
        for (i = 0; i < 24; i = i+1) begin
            case (i)
                0:  L = 63;    1:  L = 64;    2:  L = 65;
                3:  L = 127;   4:  L = 128;   5:  L = 129;
                6:  L = 255;   7:  L = 256;   8:  L = 257;
                9:  L = 271;   10: L = 272;   11: L = 273;
                12: L = 511;   13: L = 512;   14: L = 513;
                15: L = 1023;  16: L = 1024;  17: L = 1025;
                18: L = 4095;  19: L = 4096;  20: L = 4097;
                21: L = 4111;  22: L = 4224;  23: L = 4225;
                default: L = 1;
            endcase
            run_job(64'h00500000, 64'h00600000, 64'h00300000, L, 32'hFFFFFFFF,
                    64'h0BADF00D20000000 + L, 32'd0, 0, "boundary_len_aligned");
        end

        // ================= 6. 4 KiB boundary stress on both ends
        run_job(64'h00500FF0, 64'h00600F00, 64'h00300000, 32'd1000, 32'hFFFFFFFF,
                64'h0BADF00D30000001, 32'd0, 0, "4k_both_near_edge");
        run_job(64'h00500FF0, 64'h00610000, 64'h00300000, 32'd4096, 32'hFFFFFFFF,
                64'h0BADF00D30000002, 32'd0, 0, "4k_src_edge");
        run_job(64'h00510000, 64'h00600FF0, 64'h00300000, 32'd4096, 32'hFFFFFFFF,
                64'h0BADF00D30000003, 32'd0, 0, "4k_dst_edge");
        run_job(64'h00500FF0, 64'h00600FF0, 64'h00300000, 32'd16, 32'hFFFFFFFF,
                64'h0BADF00D30000004, 32'd0, 0, "4k_16B_at_edge");
        run_job(64'h00500FF0, 64'h00600FF0, 64'h00300000, 32'd17, 32'hFFFFFFFF,
                64'h0BADF00D30000005, 32'd0, 0, "4k_17B_at_edge");
        run_job(64'h00500800, 64'h00600F00, 64'h00300000, 32'd65536, 32'hFFFFFFFF,
                64'h0BADF00D30000006, 32'd0, 0, "4k_mixed_offsets_64k");

        // ================= 7. error injections (negative, non-empty packets)
        run_job(64'h00700000, 64'h00800000, 64'h00300000, 32'd4096, 32'hFFFFFFFF,
                64'h0BADF00D40000001, 32'd0, 1, "inject_rresp");
        run_job(64'h00700000, 64'h00800000, 64'h00300000, 32'd4096, 32'hFFFFFFFF,
                64'h0BADF00D40000002, 32'd0, 2, "inject_short_burst");
        run_job(64'h00700000, 64'h00800000, 64'h00300000, 32'd4096, 32'hFFFFFFFF,
                64'h0BADF00D40000003, 32'd0, 3, "inject_long_burst");
        run_job(64'h00700000, 64'h00800000, 64'h00300000, 32'd1024, 32'hFFFFFFFF,
                64'h0BADF00D40000004, 32'd0, 0, "accept_after_error");

        // ================= 8. random jobs under random backpressure
        bp_mode = 1; slave_gaps = 1;
        for (i = 0; i < 90; i = i+1) begin
            L = 1 + (rnd() % 40000);
            run_job(64'h00100000 + 16*(rnd() % 256), 64'h00200000 + 16*(rnd() % 256),
                    64'h00F00000, L, 32'hFFFFFFFF,
                    64'hC0DEC0DEC0DE0000 + i, 32'd0, 0, "random_bp");
        end
        bp_mode = 0; slave_gaps = 0;

        // ================= 9. long stalls (output must stay frozen)
        fork
            run_job(64'h00300000, 64'h00400000, 64'h00F00000, 32'd40000, 32'hFFFFFFFF,
                    64'h57A1000000000001, 32'd0, 0, "long_stall_tx");
            begin
                repeat (60) @(negedge clk);
                stall_tx = 1;
                repeat (1200) @(negedge clk);
                stall_tx = 0;
            end
        join
        done_before = n_done;
        L = 0;
        fork
            run_job(64'h00300000, 64'h00400000, 64'h00F00000, 32'd20000, 32'hFFFFFFFF,
                    64'h57A1000000000002, 32'd0, 0, "long_stall_report");
            begin
                // Completion FIFO held full: the report must rise and stay put.
                stall_pop = 1;
                while (!done_valid && L < 60000) begin
                    @(negedge clk);
                    L = L + 1;
                end
                if (L >= 60000) fail("report never raised with done_ready held");
                else n_stable_checks = n_stable_checks + 1;
                repeat (20) @(negedge clk);
                stall_pop = 0;
            end
        join

        // ================= 10. reset mid job, then accept a new command.
        // Driven inline (no fork) so the killed job has no expectations at all:
        // it must produce no report, the bus must go silent after the reset, and
        // the next command must be accepted and verified byte-exactly.
        m_valid_cmd = 1; m_src = 40'h00300000; m_dst = 40'h00400000;
        m_comp = 64'h00F00000; m_pts = 64'hA5A5000000000001; m_flags = 0;
        m_len = 4000000; m_rem = 4000000; m_transferred = 0; m_err = 0;
        m_inject = 0; m_chunks = 0; m_job_data_pkts = 0; m_job_bytes = 0;
        a_pending = 0; a_record_after = 0; m_phase = 1;
        for (i = 0; i < 40000; i = i+1) ps_mem['h00300000 + i] = pat('h00300000 + i);
        ar_before = n_ar; done_before = n_done;
        L = 0;
        issue(build_cmd(64'h00300000, 64'h00400000, 64'h00F00000, 32'd4000000,
                        32'hFFFFFFFF, 64'hA5A5000000000001, 32'd0));
        while (n_ar < ar_before + 3 && L < 40000) begin @(negedge clk); L = L+1; end
        if (L >= 40000) fail("abort test never started streaming");
        if (cmd_valid !== 1'b0) fail("cmd_valid still asserted at abort");
        $display("ABORT_POINT ar=%0d chunks=%0d state=%h",
                 n_ar - ar_before, m_chunks, dut.state);
        expect_quiet = 1;                      // silence from here on
        rst_n = 0; n_resets = n_resets + 1;
        repeat (12) @(negedge clk);
        // clear both checker models before the DUT comes back
        a_pending = 0; a_record_after = 0; m_phase = 0; m_valid_cmd = 0;
        m_inject = 0; inj_now = 0; rd_left = 0; rd_gap = 0;
        rvalid = 0; rlast = 0; arready = 0; rresp = 0;
        ack_pend = 0; ack_wait = 0; holding = 0; tx_valid_q = 0;
        stall_tx = 0; stall_pop = 0; cmd_valid = 0;
        rst_n = 1;
        repeat (6) @(negedge clk);
        repeat (300) @(negedge clk);           // quiet window, nothing may move
        expect_quiet = 0;
        if (n_done != done_before) fail("aborted job produced a completion report");
        if (busy !== 1'b0) fail("busy stuck after reset");
        $display("JOB aborted_by_reset KILLED chunks=%0d reports=%0d (expected 0)",
                 m_chunks, n_done - done_before);
        run_job(64'h00300000, 64'h00400000, 64'h00F00000, 32'd9000, 32'hFFFFFFFF,
                64'hA5A5000000000002, 32'd0, 0, "reaccept_after_reset");

        // ================= 11. 4K60 real plane sizes and the maximum legal job
        if (!nobig) begin
            run_job(64'h00200000, 64'h00400000, 64'h00F00000, 32'd8294400,
                    32'hFFFFFFFF, 64'h4B60000000000001, 32'd0, 0,
                    "nv12_4k60_y_plane_3840x2160");
            run_job(64'h00200000, 64'h00400000, 64'h00F00000, 32'd4147200,
                    32'hFFFFFFFF, 64'h4B60000000000002, 32'd0, 0,
                    "nv12_4k60_uv_plane_3840x1080");
            run_job(64'h00200000, 64'h00400000, 64'h00F00000, 32'h00800000,
                    32'hFFFFFFFF, 64'h4B60000000000003, 32'd0, 0,
                    "max_legal_len_0x800000");
        end else begin
            run_job(64'h00200000, 64'h00400000, 64'h00F00000, 32'd829440,
                    32'hFFFFFFFF, 64'h4B60000000000011, 32'd0, 0,
                    "nv12_4k60_y_plane_short");
            run_job(64'h00200000, 64'h00400000, 64'h00F00000, 32'd414720,
                    32'hFFFFFFFF, 64'h4B60000000000012, 32'd0, 0,
                    "nv12_4k60_uv_plane_short");
        end

        // ================= 12. back-to-back jobs, no idle gap
        for (i = 0; i < 12; i = i+1)
            run_job(64'h00600000, 64'h00700000, 64'h00F00000, 32'd300 + i,
                    32'hFFFFFFFF, 64'hBE5A000000000000 + i, 32'd0, 0, "back_to_back");

        // ---------------------------------------------------------- epilogue
        repeat (300) @(negedge clk);
        $display("TB_STATS jobs=%0d rejected=%0d injected=%0d aborted=%0d resets=%0d",
                 n_jobs, n_reject, n_err_jobs, n_aborted, n_resets);
        $display("TB_STATS ar=%0d beats=%0d data_pkts=%0d records=%0d reports=%0d enabled_bytes=%0d",
                 n_ar, n_beats, n_data_pkts, n_rec_pkts, n_done, n_enabled);
        $display("TB_STATS chunk_min=%0d chunk_max=%0d done_pulses=%0d err_pulses=%0d stable_checks=%0d",
                 min_chunk, max_chunk, n_done_pulses, n_err_pulses, n_stable_checks);
        $display("TB_COVER first_be_seen=%h last_be_seen=%h", seen_first_be, seen_last_be);

        if (n_data_pkts == 0)                     fail("no data packet was produced");
        if (n_rec_pkts == 0)                      fail("no completion record was produced");
        if (n_enabled == 0)                       fail("no payload byte was verified");
        // last_be is (1<<chunk[1:0])-1 or 0/f, so the reachable set is
        // {0,1,3,7,15} -> bits 0,1,3,7,15 = 16'h808B.
        if ((seen_last_be  & 16'h808B) !== 16'h808B) fail("last_be coverage gap 0,1,3,7,f");
        if ((seen_first_be & 16'h808A) !== 16'h808A) fail("first_be coverage gap 1,3,7,f");
        if (n_stable_checks < 100)                fail("output-stability checker barely ran");
        if (max_chunk > 256)                      fail("a chunk exceeded 256 bytes");
        if (n_done != n_jobs - n_aborted)         fail("one report per job violated");
        if (errors != 0) begin
            $display("READER_TB_RESULT FAIL errors=%0d seed=%h", errors, rng);
            $fatal(1, "sc7f0_ps_packet_reader_tb failed");
        end
        $display("READER_TB_PASS jobs=%0d data_pkts=%0d records=%0d enabled_bytes=%0d seed=%h",
                 n_jobs, n_data_pkts, n_rec_pkts, n_enabled, 32'h13579BDF);
        $finish;
    end

    initial #60_000_000 begin
        $display("READER_TB_RESULT FAIL global timeout errors=%0d", errors);
        $fatal(1, "global timeout");
    end

endmodule
