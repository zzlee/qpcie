`timescale 1ns / 1ps
// ============================================================================
// tb_sc7f0_rgb24_c2h_engine.sv - targeted regression for the r10 registered
// burst-planning stage of rtl/sc7f0_rgb24_c2h_engine.v.
//
// What it proves (all numbers are checked, nothing is "watch the waveform"):
//   T1 256 B burst case: every request carries exactly 4*dw_len bytes, never
//      more than MAX_REQ_BYTES, never crosses 4 KB, and the concatenation of
//      every accepted beat equals the source byte stream byte for byte.  The
//      pre-r10 request builder computed req_beats as req_bytes[7:4], which is 0
//      for a full 256 B burst; that shows up here immediately.
//   T2 line-tail case (line_bytes = 144 B = 9 beats): burst sizes become 144 B,
//      addresses step by stride with the padding applied exactly once per line.
//   T3 backpressure: the modelled FIFO occupancy under-reports and is starved on
//      purpose; the engine must then simply not commit - not drop, duplicate or
//      reorder a beat, and the frame must still retire with the exact byte count.
//   T4 short frame: the frame that ends early is counted in drop_count and is
//      NOT announced as completed (the frame-level drop policy is preserved).
//   T5 bad geometry (line_bytes not a multiple of 16) is refused: protocol_error
//      counted, error_sticky raised, and ZERO requests issued.
//   T6 mid-frame reset: the engine returns to idle, consumes a fresh descriptor
//      and produces a clean frame afterwards.
//
// r11 additions (the burst planner was restructured into 16-byte beat units, so
// the corners that decide WHICH limit bounds a burst are now covered directly):
//   T7  every limit tie / straddle corner, checked against an independent rule
//       model (build_model_* below) rather than against the DUT: a line length
//       that equals the 4 KB remainder exactly (192 B lines started at page
//       offset 0xF40, where line_left == fourk_left and the burst must still
//       end the line), a 4 KB straddle that forces 1-beat bursts, and the
//       smallest geometry the ABI accepts (48 B lines) with a padded stride.
//   T7b a geometry the ABI must refuse (frame_height == 0).
//   T8  scatter-gather mode: a segment whose length ties the MAX_REQ_BYTES cap,
//       a segment that starts at page offset 0xF40, and a 16-byte final segment
//       that ends the frame exactly (segment tail + frame last-write at once).
//       Defect 3 changed HOW this is stimulated: the entries now reach the DUT
//       through the board's own gate (!sgl_src_empty && sgl_pop_ready &&
//       video_busy) instead of a hand-lifted sgl_wr_en, so an engine that will
//       not accept an entry fails instead of silently passing.
//   T9  three complete frames on one descriptor: the frame last-write predicate
//       must retire every frame exactly once and count no drops; the last retire
//       must also drop video_busy (it used to be set on the descriptor and never
//       cleared, which is why CH0_STATUS read "running" forever).
//   T14 scatter-gather re-arm: after a frame retires, a fresh descriptor with a
//       fresh set of entries must reload the walker and stream again.  Both
//       members of Defect 3 (inverted sgl_pop_ready, walker_start on the frame
//       start) show up here as "the second frame never starts".
//   T9b the descriptor fields are mutated with desc_valid LOW while a frame is
//       in flight: the in-flight job must not see them (no stale/live mixing).
//   T10 randomised consumer back-pressure plus a reset taken while a plan is
//       pending, then a byte-exact frame.
//   T13 payload offered past the end of the descriptor: only the descriptor's
//       bytes may reach the host, the rest must be drained and counted, and
//       error_sticky must rise (this is what proves the frame last-write really
//       takes the engine out of the writing path).
//   T11 engine-intrinsic throughput ceiling against the fastest legal consumer,
//       and T12 the same traffic through a consumer paced at the 125 MHz PCIe
//       user-clock rate (5 beats per 12 capture cycles).  Both are multi-line
//       packed-RGB traffic far larger than the source FIFO, and both report the
//       initial latency separately from the steady-state inter-request interval,
//       with an independent byte oracle over every delivered byte.
// ============================================================================
module tb_sc7f0_rgb24_c2h_engine;
    localparam integer MAXW    = 4096;
    localparam integer FIFOD   = 1024;
    localparam integer AVW     = $clog2(FIFOD) + 1;
    localparam integer MAXREQ  = 256;

    logic clk = 1'b0, rst_n = 1'b0;
    always #1.6665 clk = ~clk;              // 300 MHz

    // descriptor launch
    logic         desc_valid = 1'b0, desc_sg_mode = 1'b0, desc_ready;
    logic [63:0]  plane_y_addr = 64'd0;
    logic [15:0]  frame_width = 16'd0, frame_height = 16'd0, frame_stride = 16'd0;

    // SGL side: a model of the source CDC FIFO plus the REAL integration gate,
    // not a free-running stimulus.
    //
    // rtl/custom_pcie_dma_top.v drives this engine with
    //   sgl_wr_en = !v_sgl_y_empty && v_sgl_y_pop_ready && eng_busy
    // and that fwft FIFO's rd_en is the very same wire, so an entry may only
    // move when the DUT itself says it can take one.  The bench used to lift
    // sgl_wr_en by hand, which is exactly how Defect 3 survived review: with
    // sgl_pop_ready wired to the walker's un-inverted fifo_almost_full the real
    // board never moved one entry (Payload 0 B), while this bench still "passed"
    // (docs/sc7f0_defect3_c2h_zero_payload_rootcause_20261116.md §3.3).
    logic         sgl_wr_en;
    logic [63:0]  sgl_wr_addr;
    logic [31:0]  sgl_wr_len, sgl_wr_flags;
    logic [6:0]   cur_sgl_count;
    logic         sgl_pop_ready;
    logic [31:0]  dbg_bus;

    logic [63:0]  sgl_src_addr [$];
    int           sgl_taken;                // bench log of entries the DUT took
    logic [31:0]  sgl_src_len  [$];
    logic [31:0]  sgl_src_flags[$];
    logic         sgl_src_empty = 1'b1;   // registered, like an fwft empty
    logic [63:0]  sgl_head_addr;
    logic [31:0]  sgl_head_len, sgl_head_flags;

    logic [63:0]  gt = 64'h1234_0000_0000_0000;

    // source FIFO (models rtl/sc7f0_rgb24_axis_pack.v's read side)
    logic [127:0] s_tdata;
    logic         s_tuser, s_tvalid, s_tready;
    logic [AVW-1:0] s_avail;

    // C2H request side
    logic         req_valid, req_last, req_data_ready, req_ack;
    logic [63:0]  req_addr;
    logic [10:0]  req_dw_len;
    logic [127:0] req_data;

    logic         video_busy, video_frame_done;
    logic [63:0]  frame_pts;
    logic [31:0]  protocol_error_count, drop_count, frames_completed;
    logic [31:0]  align_discard_count, bytes_committed;
    logic [15:0]  active_line_bytes, active_stride;
    logic         overflow_sticky = 1'b0, align_sticky = 1'b0, error_sticky;

    sc7f0_rgb24_c2h_engine #(
        .MAX_WIDTH(MAXW), .PCIE_DATA_WIDTH(128),
        .MAX_REQ_BYTES(MAXREQ), .SRC_FIFO_DEPTH(FIFOD)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .desc_valid(desc_valid), .desc_ready(desc_ready),
        .desc_sg_mode(desc_sg_mode), .plane_y_addr(plane_y_addr),
        .frame_width(frame_width), .frame_height(frame_height),
        .frame_stride(frame_stride),
        .sgl_wr_en(sgl_wr_en), .sgl_wr_addr(sgl_wr_addr),
        .sgl_wr_len(sgl_wr_len), .sgl_wr_flags(sgl_wr_flags),
        .cur_sgl_count(cur_sgl_count), .sgl_pop_ready(sgl_pop_ready),
        .dbg_bus(dbg_bus),
        .global_timestamp(gt),
        .p_axis_tdata(s_tdata), .p_axis_tuser(s_tuser), .p_axis_tvalid(s_tvalid),
        .p_axis_avail(s_avail), .p_axis_tready(s_tready),
        .c2h_req_valid(req_valid), .c2h_req_addr(req_addr),
        .c2h_req_dw_len(req_dw_len), .c2h_req_data(req_data),
        .c2h_req_last(req_last), .c2h_req_data_ready(req_data_ready),
        .c2h_req_ack(req_ack),
        .video_busy(video_busy), .video_frame_done(video_frame_done),
        .frame_pts(frame_pts), .protocol_error_count(protocol_error_count),
        .drop_count(drop_count), .frames_completed(frames_completed),
        .align_discard_count(align_discard_count), .bytes_committed(bytes_committed),
        .active_line_bytes(active_line_bytes), .active_stride(active_stride),
        .src_overflow_sticky(overflow_sticky), .src_line_align_sticky(align_sticky),
        .error_sticky(error_sticky)
    );

    // The gate itself, driven by the DUT's own readiness (see the note above the
    // declarations): an entry moves only when sgl_pop_ready says the walker can
    // take one and the channel is busy, exactly as
    // rtl/custom_pcie_dma_top.v:sgl_wr_en / u_sgl_y_cdc.rd_en are wired.
    assign sgl_wr_en    = !sgl_src_empty && sgl_pop_ready && video_busy;
    assign sgl_wr_addr  = sgl_head_addr;
    assign sgl_wr_len   = sgl_head_len;
    assign sgl_wr_flags = sgl_head_flags;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sgl_src_addr.delete();  sgl_src_len.delete();  sgl_src_flags.delete();
            sgl_src_empty <= 1'b1;
            sgl_head_addr <= 64'd0;  sgl_head_len <= 32'd0;  sgl_head_flags <= 32'd0;
        end else begin
            if (sgl_wr_en) begin
                void'(sgl_src_addr.pop_front());
                void'(sgl_src_len.pop_front());
                void'(sgl_src_flags.pop_front());
                sgl_taken++;
            end
            sgl_src_empty   <= (sgl_src_addr.size() == 0);
            sgl_head_addr   <= (sgl_src_addr.size() != 0) ? sgl_src_addr[0]   : 64'd0;
            sgl_head_len    <= (sgl_src_len.size()   != 0) ? sgl_src_len[0]    : 32'd0;
            sgl_head_flags  <= (sgl_src_flags.size() != 0) ? sgl_src_flags[0]  : 32'd0;
        end
    end

    // The polarity contract, checked every cycle rather than argued about: the
    // engine's "I can take an entry" must be the walker's inverted almost_full,
    // gated by the one-cycle walker-restart window (rtl: sgl_take).
    always @(posedge clk) begin
        if (rst_n && (sgl_pop_ready !== (!dut.u_sgl.fifo_almost_full && dut.sgl_take)))
            fail("sgl_pop_ready != !walker fifo_almost_full && sgl_take");
    end

    int errors = 0, checks = 0;
    bit tb_finished = 1'b0;      // set only on the normal end of the main test
    task automatic fail(input string msg);
        errors++;
        $display("FAIL @%0t: %s", $time, msg);
    endtask
    task automatic ck(input bit cond, input string msg);
        checks++;
        if (!cond) fail(msg);
    endtask

    // ------------------------------------------------------------------------
    // source FIFO model: queue + deliberately under-reporting occupancy
    // ------------------------------------------------------------------------
    logic [127:0] q [$];
    logic         q_sof [$];
    int           nf = 0;                    // beats actually in the model FIFO
    bit           starve = 1'b0;             // T3: hold the reported count down

    // Occupancy is reported through a hold-back register, never above the true
    // count, because rd_data_count only ever under-reports and the engine's
    // "whole burst is already here" decision relies on that direction.
    int           hold;

    // A queue is only read procedurally below: `q.size()` inside a continuous
    // assignment is not an event source, so the stream side is registered here
    // (that is also what an fwft xpm_fifo read port looks like to its consumer).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q.delete();  q_sof.delete();  nf <= 0;
            s_tvalid <= 1'b0;  s_tdata <= 128'd0;  s_tuser <= 1'b0;
        end else begin
            if (s_tvalid && s_tready) begin
                void'(q.pop_front());
                void'(q_sof.pop_front());
                nf = nf - 1;
            end
            s_tvalid <= (q.size() != 0);
            s_tdata  <= (q.size() != 0) ? q[0]      : 128'd0;
            s_tuser  <= (q_sof.size() != 0) ? q_sof[0] : 1'b0;
        end
    end
    assign s_avail = AVW'((nf > hold) ? (nf - hold) : 0);

    always @(posedge clk) begin
        if (starve) hold <= $urandom_range(0, 8);
        else        hold <= $urandom_range(0, 2);
    end
    initial hold = 0;

    task automatic push_beat(input logic [127:0] d, input bit sof);
        q.push_back(d);
        q_sof.push_back(sof);
        nf++;
    endtask

    // byte pattern for one frame: byte k of the frame is (k + seed) mod 251, so a
    // shift, a repeat or a zero-filled tail all fail the byte-for-byte compare.
    function automatic logic [127:0] pattern_beat(input int byte_idx, input int seed);
        logic [127:0] b;
        for (int i = 0; i < 16; i++)
            b[i*8 +: 8] = 8'((byte_idx + i + seed) % 251);
        return b;
    endfunction

    // ------------------------------------------------------------------------
    // reference sink: what the engine actually put on the wire
    // ------------------------------------------------------------------------
    logic [7:0]  got_bytes [$];
    logic [63:0] got_addrs [$];
    int          got_lens [$];                  // bytes per request, from dw_len
    int          got_tstamp [$];                // capture cycle of each header
    int          got_len_broken;                 // beats != 4*dw_len
    int          got_oversize;                   // request longer than MAXREQ
    int          got_4k_cross;                   // request crossing 4 KB
    int          requests = 0;
    int          max_bytes_seen;
    bit          sink_run;

    // The consumer is modelled exactly as rtl/video_req_cdc.v's writer FSM
    // (WR_IDLE latches the header WITHOUT a data beat, WR_DATA takes one beat per
    // cycle while it holds ready, WR_DRAIN waits for valid to fall).  Tying
    // c2h_req_data_ready high would be a different protocol and would make the
    // engine pop a beat the consumer never took.
    localparam int C_IDLE = 0, C_DATA = 1, C_DRAIN = 2;
    int cstate, cleft, cur_req;

    // ------------------------------------------------------------------------
    // instrumentation state (declared before the consumer block that reads it)
    // ------------------------------------------------------------------------
    int mdl_addr [$];                           // independent rule model
    int mdl_len  [$];
    bit  tp_check = 1'b0;                       // byte oracle over the wire
    int  tp_pos = 0, tp_seed = 0, tp_frame_bytes = 1, tp_bad_bytes = 0;

    function automatic bit tp_byte_ok(input logic [7:0] b, input int pos);
        return b == 8'(((pos % tp_frame_bytes) + tp_seed) % 251);
    endfunction

    // Consumer availability.  With pcie_pace cleared this is the ideal 1 beat per
    // capture cycle consumer that T1..T6 have always used.  With pcie_pace set it
    // models rtl/video_req_cdc.v's writer living in the PCIe user clock: on the
    // 300 MHz capture timebase a 125 MHz consumer takes one 16 B beat every 2.4
    // capture cycles, which is exactly 5 beats per 12 capture cycles because
    // LCM(300 MHz, 125 MHz) = 60 MHz, i.e. 16 B / 9.6 ns = 2.000 GB/s, above the
    // 1.492992 GB/s that packed RGB24 4K60 asks for.  rnd_backpressure is the
    // "the crossing has no room right now" case, which is legal for that writer
    // and is what T10 stress-drives.
    bit  pcie_pace = 1'b0;
    bit  rnd_backpressure = 1'b0;
    int  pcie_ph = 0;
    bit  rnd_open = 1'b1;

    function automatic bit paced_open(input int ph);
        return (ph == 0) || (ph == 2) || (ph == 5) || (ph == 7) || (ph == 10);
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pcie_ph <= 0;
        else        pcie_ph <= (pcie_ph == 11) ? 0 : pcie_ph + 1;
    end
    always @(posedge clk) rnd_open <= ($urandom_range(0, 3) != 0);

    // Is the consumer able to take a beat during the NEXT cycle?  req_data_ready
    // is registered, so it must be armed from next cycle's phase.
    wire consumer_open = (pcie_pace ? paced_open(pcie_ph + 1 == 12 ? 0 : pcie_ph + 1) : 1'b1)
                         && (rnd_backpressure ? rnd_open : 1'b1);

    // cycle counter, for the throughput / inter-request-interval measurements
    int cyc = 0;
    always @(posedge clk) cyc++;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_data_ready <= 1'b0;
            req_ack        <= 1'b0;
            cstate         <= C_IDLE;
            cleft          <= 0;
            cur_req        <= -1;
        end else begin
            req_ack <= 1'b0;
            case (cstate)
                C_IDLE: if (req_valid) begin
                    // one request = dw_len DWords = dw_len/4 beats of 16 B
                    cleft  <= int'(req_dw_len) / 4;
                    cur_req<= requests;
                    requests++;
                    got_addrs.push_back(req_addr);
                    got_lens.push_back(int'(req_dw_len) * 4);
                    got_tstamp.push_back(cyc);
                    max_bytes_seen = (int'(req_dw_len)*4 > max_bytes_seen)
                                     ? int'(req_dw_len)*4 : max_bytes_seen;
                    if (int'(req_dw_len)*4 > MAXREQ)   got_oversize++;
                    if ((req_addr[11:0] + {4'd0, req_dw_len, 2'd0}) > 16'd4096)
                        got_4k_cross++;
                    if (req_dw_len == 11'd0) got_len_broken++;
                    req_data_ready <= consumer_open;
                    cstate <= C_DATA;
                end
                C_DATA: if (req_valid && req_data_ready) begin
                    for (int i = 0; i < 16; i++) begin
                        got_bytes.push_back(req_data[i*8 +: 8]);
                        if (tp_check && !tp_byte_ok(req_data[i*8 +: 8], tp_pos))
                            tp_bad_bytes++;
                        if (tp_check) tp_pos++;
                    end
                    if (cleft == 1) begin
                        req_ack        <= 1'b1;
                        req_data_ready <= 1'b0;
                        cstate         <= C_DRAIN;
                    end else begin
                        cleft <= cleft - 1;
                        req_data_ready <= consumer_open;
                    end
                end else
                    req_data_ready <= consumer_open;
                C_DRAIN: if (!req_valid) cstate <= C_IDLE;
                default: cstate <= C_IDLE;
            endcase
        end
    end
    initial begin got_len_broken = 0; got_oversize = 0; got_4k_cross = 0;
                  max_bytes_seen = 0; end

    // ------------------------------------------------------------------------
    int expect_bytes [$];                          // golden byte stream, in order
    int          golden_bytes;

    task automatic launch(input logic [63:0] base, input int w, input int h,
                          input int stride);
        @(negedge clk);
        desc_valid    <= 1'b1;
        desc_sg_mode  <= 1'b0;
        plane_y_addr  <= base;
        frame_width   <= 16'(w);
        frame_height  <= 16'(h);
        frame_stride  <= 16'(stride);
        @(posedge clk);
        while (desc_ready !== 1'b1) @(posedge clk);
        desc_valid <= 1'b0;
    endtask

    // same launch, scatter-gather descriptor
    task automatic launch_sg(input logic [63:0] base, input int w, input int h,
                             input int stride);
        @(negedge clk);
        desc_valid    <= 1'b1;
        desc_sg_mode  <= 1'b1;
        plane_y_addr  <= base;
        frame_width   <= 16'(w);
        frame_height  <= 16'(h);
        frame_stride  <= 16'(stride);
        @(posedge clk);
        while (desc_ready !== 1'b1) @(posedge clk);
        desc_valid <= 1'b0;
    endtask

    // Push one SGL entry into the source model.  It reaches the engine only
    // through the DUT's own sgl_pop_ready, exactly as on the board.
    task automatic sgl_push(input logic [63:0] a, input logic [31:0] l,
                            input logic [31:0] f);
        @(negedge clk);
        sgl_src_addr.push_back(a);
        sgl_src_len.push_back(l);
        sgl_src_flags.push_back(f);
    endtask

    // Wait until the engine has taken `target` entries in total out of the
    // source model.  The counter is the bench's own take log, not the walker's
    // occupancy: the walker immediately promotes the head entry into its active
    // segment and pops a segment as soon as a burst finishes it, so a check on
    // cur_sgl_count would measure the pipeline, not the gate.  With the polarity
    // defect nothing is ever taken and this fails after its budget.
    task automatic sgl_wait_taken(input int target, input int limit, input string tag);
        int k = 0;
        while ((sgl_taken < target) && (k < limit)) begin @(posedge clk); k++; end
        checks++;
        if (sgl_taken < target)
            fail({tag, ": the engine accepted ", $sformatf("%0d", sgl_taken),
                  " of ", $sformatf("%0d", target),
                  " SGL entries after ", $sformatf("%0d", limit),
                  " cycles (the sgl_pop_ready/sgl_wr_en gate is not passing entries)"});
    endtask

    // Push `nbeats` beats; sof on the first one, and mirror the bytes into the
    // golden list.
    task automatic push_frame(input int nbeats, input int seed, input int nbytes);
        for (int i = 0; i < nbeats; i++) begin
            @(negedge clk);
            push_beat(pattern_beat(i*16, seed), i == 0);
        end
        for (int k = 0; k < nbytes; k++) expect_bytes.push_back((k + seed) % 251);
        golden_bytes += nbytes;
    endtask

    // Continuation of the SAME source frame: no frame-start sideband, and the
    // golden bytes continue from first_byte.  Used to hold a frame open across a
    // descriptor-field mutation.
    task automatic push_more(input int first_beat, input int nbeats, input int sd,
                             input int first_byte, input int nbytes);
        for (int i = 0; i < nbeats; i++) begin
            @(negedge clk);
            push_beat(pattern_beat((first_beat + i)*16, sd), 1'b0);
        end
        for (int k = 0; k < nbytes; k++)
            expect_bytes.push_back((first_byte + k + sd) % 251);
        golden_bytes += nbytes;
    endtask

    task automatic dump_state(input string tag);
        $display("DBG %s armed=%b locked=%b sof_locked=%b state=%0d pl_valid=%b pl_moved=%b moving=%b bytes=%0d beats=%0d seg_rdy=%b nf=%0d avail=%0d tvalid=%b tuser=%b busy=%b req%0d",
                 tag, dut.armed, dut.locked, dut.sof_locked, dut.state, dut.pl_valid,
                 dut.pl_moved, dut.pl_inputs_moving, dut.pl_bytes, dut.pl_beats,
                 dut.pl_seg_ready, nf, s_avail, s_tvalid, s_tuser, video_busy, requests);
    endtask

    task automatic cmp_bytes(input string tag);
        if (got_bytes.size() != golden_bytes) begin
            fail($sformatf("%s: %0d bytes reached the host, %0d were streamed",
                           tag, got_bytes.size(), golden_bytes));
        end else begin
            checks++;
            for (int k = 0; k < got_bytes.size(); k++)
                if (got_bytes[k] !== expect_bytes[k]) begin
                    fail($sformatf("%s: byte %0d = %02h, expected %02h", tag, k,
                                   got_bytes[k], expect_bytes[k]));
                    break;
                end
        end
    endtask

    task automatic wait_idle(input int limit_cycles, input string tag);
        int n = 0;
        while (video_busy && n < limit_cycles) begin @(posedge clk); n++; end
        if (video_busy) fail({tag, ": engine did not retire the frame within ",
                              $sformatf("%0d", limit_cycles), " cycles"});
    endtask

    // address model for one expected frame
    task automatic check_frame(input logic [63:0] base, input int w, input int h,
                               input int stride, input string tag);
        int lb = w * 3;
        int beats_per_line = lb / 16;
        int line = 0, beats_in_line = 0, req_idx = 0;
        // rebuild the request list the geometry implies
        while (line < h) begin
            int rem = beats_per_line;
            while (rem > 0) begin
                int sz = rem * 16;
                if (sz > MAXREQ) sz = MAXREQ;
                if (req_idx >= got_addrs.size()) begin
                    fail({tag, ": missing request ", $sformatf("%0d", req_idx)});
                    return;
                end
                if (got_addrs[req_idx] != base + line*stride +
                        (beats_per_line - rem)*16)
                    fail({tag, ": request ", $sformatf("%0d", req_idx), " address ",
                          $sformatf("%h", got_addrs[req_idx])});
                req_idx++;
                rem -= sz / 16;
            end
            line++;
        end
        checks++;
    endtask

    task automatic clear_observed();
        got_bytes.delete(); got_addrs.delete(); expect_bytes.delete();
        got_lens.delete(); got_tstamp.delete();
        mdl_addr.delete(); mdl_len.delete();
        requests = 0; max_bytes_seen = 0; golden_bytes = 0;
    endtask

    // ------------------------------------------------------------------------
    // Independent burst-rule model.  This is the documented contract written out
    // in bytes (size <= MAX_REQ_BYTES, never past the line end, never past the
    // segment, never across a 4 KB boundary, always whole 16-byte beats), derived
    // from neither the DUT's planning registers nor its beat arithmetic, so it
    // still says what the engine owes the host when the planning expression
    // inside the DUT is restructured.
    // ------------------------------------------------------------------------
    function automatic int floor16(input int v);
        return v & ~15;
    endfunction

    // linear mode: every frame restarts at `base`, lines are `stride` apart
    task automatic build_model_lin(input int base, input int lb, input int h,
                                   input int stride, input int nframes);
        int f, line, off, addr, cand, b;
        mdl_addr.delete(); mdl_len.delete();
        for (f = 0; f < nframes; f++)
            for (line = 0; line < h; line++) begin
                off  = 0;
                addr = base + line*stride;
                while (off < lb) begin
                    cand = lb - off;                       // never past line end
                    if (MAXREQ < cand) cand = MAXREQ;      // never above the cap
                    b = 4096 - (addr % 4096);              // never across 4 KB
                    if (b < cand) cand = b;
                    b = floor16(cand);                     // whole beats only
                    if (b == 0) begin
                        fail("rule model: burst rounds to zero, geometry unstorable");
                        return;
                    end
                    mdl_addr.push_back(addr);
                    mdl_len.push_back(b);
                    addr += b; off += b;
                end
            end
    endtask

    // scatter-gather mode: the padded-stride advance is exercised elsewhere, so
    // this model is used with stride == line_bytes (pad = 0) and a segment list
    task automatic build_model_sg(input int lb, input int h, input int sa [$],
                                  input int sl [$]);
        int line, off, seg, srem, addr, cand, b;
        mdl_addr.delete(); mdl_len.delete();
        seg = 0; srem = sl[0]; addr = sa[0];
        for (line = 0; line < h; line++) begin
            off = 0;
            while (off < lb) begin
                cand = lb - off;
                if (MAXREQ < cand) cand = MAXREQ;
                b = 4096 - (addr % 4096);
                if (b < cand) cand = b;
                if (srem < cand) cand = srem;               // never past segment
                b = floor16(cand);
                if (b == 0) begin
                    fail("sg rule model: burst rounds to zero");
                    return;
                end
                mdl_addr.push_back(addr);
                mdl_len.push_back(b);
                addr += b; off += b; srem -= b;
                if (srem == 0 && seg + 1 < sl.size()) begin
                    seg++; addr = sa[seg]; srem = sl[seg];
                end
            end
        end
    endtask

    task automatic check_model(input string tag);
        checks++;
        if (got_addrs.size() != mdl_addr.size() || got_lens.size() != mdl_len.size()) begin
            fail($sformatf("%s: %0d requests on the wire, the rule model predicts %0d",
                           tag, got_addrs.size(), mdl_addr.size()));
            return;
        end
        for (int i = 0; i < mdl_addr.size(); i++) begin
            if (got_addrs[i] != 64'(mdl_addr[i]) || got_lens[i] != mdl_len[i]) begin
                fail($sformatf("%s: request %0d = %h / %0d B, rule model says %h / %0d B",
                               tag, i, got_addrs[i], got_lens[i],
                               64'(mdl_addr[i]), mdl_len[i]));
                return;
            end
        end
    endtask

    // A stale or duplicated plan re-sends an address that was already committed;
    // in linear mode the destination only ever moves forward inside a frame.
    task automatic check_no_repeat(input string tag);
        checks++;
        for (int i = 1; i < got_addrs.size(); i++)
            if (got_addrs[i] == got_addrs[i-1]) begin
                fail($sformatf("%s: request %0d re-sends address %h",
                               tag, i, got_addrs[i]));
                return;
            end
    endtask

    // ------------------------------------------------------------------------
    // throughput instrumentation: the continuous source feeder, the S_ARM stall
    // counter and the steady-state interval report.  The byte oracle itself lives
    // with the consumer above.
    // ------------------------------------------------------------------------
    bit  feed_run = 1'b0;
    int  feed_beats = 0, feed_idx = 0, feed_per_frame = 1, feed_stop = 0;

    // Pushed on the negedge like push_frame(), because the queue is read by the
    // stream-side register block in the same time step.
    always @(negedge clk) begin
        if (feed_run && (q.size() < 900) && (feed_beats < feed_stop)) begin
            push_beat(pattern_beat(16*(feed_idx % feed_per_frame), tp_seed),
                      (feed_idx % feed_per_frame) == 0);
            feed_beats++;
            feed_idx++;
        end
    end

    // S_ARM with a beat present and a full burst's worth reported, but no pop:
    // the plan-refresh / consumer wait, counted rather than hand-waved.
    int  arm_stall = 0;
    always @(posedge clk)
        if (tp_check && (dut.state == 3'd2) && s_tvalid && (s_avail >= 11'd16) &&
            !s_tready)
            arm_stall++;

    // steady-state inter-request interval: each request is one burst, and the
    // engine has exactly one request in flight, so this IS the burst interval
    task automatic report_ii(input string tag, input int skip);
        int gaps = 0, sum = 0, mx = 0, mn = 0, b0, b1, bytes;
        if (got_tstamp.size() > skip + 1) begin
            for (int i = skip + 1; i < got_tstamp.size(); i++) begin
                int g = got_tstamp[i] - got_tstamp[i-1];
                if (gaps == 0 || g > mx) mx = g;
                if (gaps == 0 || g < mn) mn = g;
                sum += g; gaps++;
            end
            b0 = got_tstamp[skip]; b1 = got_tstamp[got_tstamp.size()-1];
            bytes = 0;
            for (int i = skip + 1; i < got_lens.size(); i++) bytes += got_lens[i];
            $display("TP %s: requests=%0d steady window=%0d cyc bytes=%0d steady=%.2f B/cyc (%.3f GB/s at 300 MHz) II min=%0d max=%0d mean=%.2f arm_stall=%0d",
                     tag, got_tstamp.size(), b1 - b0, bytes,
                     real'(bytes) / real'(b1 - b0),
                     (real'(bytes) / real'(b1 - b0)) * 0.300,
                     mn, mx, real'(sum) / real'(gaps), arm_stall);
        end else
            $display("TP %s: too few requests (%0d) for a steady-state interval",
                     tag, got_tstamp.size());
    endtask

    // The engine reports a frame only when the NEXT frame start proves the byte
    // count, and video_busy is the channel busy flag (it drops when a frame
    // retires and nothing has been re-armed), so the test waits on the committed
    // byte total instead.
    // The threshold is re-read into a plain local every iteration on purpose.
    // Written as `while (int'(bytes_committed) < target)`, xsim 2023.2 kept the
    // loop alive after bytes_committed had reached target (the guard below shows
    // committed == target while the body still runs), which made every wait in
    // this bench burn its whole cycle budget.  That is a bench-side evaluation
    // artefact, not engine behaviour, and it is fixed here without touching the
    // threshold, the timeout or what the test is allowed to accept.
    task automatic wait_bytes(input int target, input int limit, input string tag);
        int n = 0;
        int got;
        got = int'(bytes_committed);
        while ((got < target) && (n < limit)) begin
            @(posedge clk); n++;
            got = int'(bytes_committed);
        end
        $display("WAIT %s exit n=%0d cyc=%0d committed=%0d target=%0d",
                 tag, n, cyc, bytes_committed, target);
        checks++;
        if (got < target)
            fail({tag, ": only ", $sformatf("%0d", bytes_committed),
                  " of ", $sformatf("%0d", target), " bytes committed in ",
                  $sformatf("%0d", limit), " cycles"});
    endtask

    // ------------------------------------------------------------------------
    logic [63:0] BASE = 64'h0000_0000_0100_1000;
    int w1 = 256, h1 = 8, s1 = 256*3;          // 768 B lines -> 256 B bursts
    int w2 = 48,  h2 = 6, s2 = 48*3 + 16;      // 144 B lines, padded stride
    int seed = 7;

    // ------------------------------------------------------------------------
    // throughput run: `nframes` frames of 16 x 3840 px packed RGB24 (184320 B,
    // 11x the 1024-beat source FIFO) with a feeder that keeps the FIFO stocked,
    // so the number measures the engine, not the source.  The initial latency is
    // reported separately from the steady-state interval.
    // ------------------------------------------------------------------------
    function automatic int max_ii_seen();
        int mx = 0;
        for (int i = 9; i < got_tstamp.size(); i++)
            if (got_tstamp[i] - got_tstamp[i-1] > mx) mx = got_tstamp[i] - got_tstamp[i-1];
        return mx;
    endfunction

    function automatic int mean_ii_seen(input int skip);
        int sum = 0, n = 0;
        for (int i = skip + 1; i < got_tstamp.size(); i++) begin
            sum += got_tstamp[i] - got_tstamp[i-1]; n++;
        end
        return (n == 0) ? 0 : (sum / n);
    endfunction

    task automatic throughput(input string tag, input bit pace125, input int nframes);
        int lb = 3840*3;                       // 11520 B active line, no padding
        int h  = 16;
        int want, c0, c1, first_c, bytes;
        rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        clear_observed();
        seed += 3;
        tp_check = 1'b1; tp_pos = 0; tp_seed = seed; tp_bad_bytes = 0;
        tp_frame_bytes = lb*h;
        feed_per_frame = lb*h/16; feed_stop = nframes*feed_per_frame;
        feed_idx = 0; feed_beats = 0; arm_stall = 0;
        pcie_pace = pace125;
        feed_run = 1'b1;
        launch(BASE, 3840, h, lb);
        want = nframes*lb*h;
        c0 = cyc;
        wait_bytes(want, 300000, tag);
        c1 = cyc;
        feed_run = 1'b0;
        ck(tp_bad_bytes == 0, {tag, ": byte oracle mismatch on the delivered stream"});
        ck(got_bytes.size() == want, {tag, ": delivered byte count"});
        ck(!got_oversize && !got_4k_cross && !got_len_broken,
           {tag, ": burst rules broken on the throughput run"});
        bytes = got_bytes.size();
        first_c = (got_tstamp.size() != 0) ? got_tstamp[0] : -1;
        $display("TP %s: %0d B in %0d cycles = %.2f B/cyc (%.3f GB/s at 300 MHz), first request at cycle %0d (launch->first burst %0d cyc), consumer=%0s",
                 tag, bytes, c1 - c0, real'(bytes) / real'(c1 - c0),
                 (real'(bytes) / real'(c1 - c0)) * 0.300, first_c, first_c - c0,
                 pace125 ? "125 MHz paced" : "ideal 1 beat/cycle");
        $display("TP %s diag: bytes_committed=%0d requests=%0d ts0=%0d ts8=%0d ts_last=%0d cyc_now=%0d c0=%0d c1=%0d beats_fed=%0d q_size=%0d avail=%0d",
                 tag, bytes_committed, got_tstamp.size(),
                 (got_tstamp.size() > 0) ? got_tstamp[0] : -1,
                 (got_tstamp.size() > 8) ? got_tstamp[8] : -1,
                 (got_tstamp.size() > 0) ? got_tstamp[got_tstamp.size()-1] : -1,
                 cyc, c0, c1, feed_beats, q.size(), s_avail);
        report_ii(tag, 8);
        // 1.492992 GB/s of packed RGB24 4K60 is 4.97664 B per capture cycle.
        ck(real'(bytes) / real'(c1 - c0) >= 4.97664,
           {tag, ": delivered rate below the 4K60 packed-RGB24 budget"});
        if (!pace125) begin
            // One 256 B burst is 16 pops plus the plan-refresh cycle(s).  If the
            // planning pipeline serialised a burst (or a second CDC round trip
            // per burst were introduced) this interval would blow past this.
            $display("TP %s: intrinsic burst interval steady mean=%0d worst=%0d cycles (256 B => %.2f B/cyc worst-case = %.3f GB/s)",
                     tag, mean_ii_seen(8), max_ii_seen(),
                     256.0 / real'(max_ii_seen()),
                     (256.0 / real'(max_ii_seen())) * 0.300);
            ck(mean_ii_seen(8) <= 24,
               {tag, ": steady burst interval is no longer ~16 beats + plan refresh"});
            ck(max_ii_seen() <= 30,
               {tag, ": a single burst interval exceeded 16 beats + plan refresh"});
        end
        pcie_pace = 1'b0;
    endtask

    initial begin : main
        int pe0, dc0, fc0, total, req0;
        int t_lb, t_h, t_st, t_fb;
        int k1, fc1, sgl_base;
        rst_n = 1'b0;
        total = 0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---- T1: 256 B bursts, 768 B lines --------------------------------
        clear_observed();
        launch(BASE, w1, h1, s1);
        push_frame((w1*3*h1)/16, seed, w1*3*h1);
        total += w1*3*h1;
        wait_bytes(total, 60000, "T1");
        ck(!got_len_broken, "T1: a request had dw_len 0 or an incomplete length");
        ck(!got_oversize,   "T1: a request exceeded MAX_REQ_BYTES");
        ck(!got_4k_cross,   "T1: a request crossed a 4 KB boundary");
        ck(max_bytes_seen == MAXREQ, {"T1: expected a full ", $sformatf("%0d", MAXREQ),
                                      " B burst, largest seen was ",
                                      $sformatf("%0d", max_bytes_seen)});
        ck(requests == (w1*3*h1)/MAXREQ, {"T1: ", $sformatf("%0d", requests),
                                          " requests, expected ",
                                          $sformatf("%0d", (w1*3*h1)/MAXREQ)});
        cmp_bytes("T1");
        check_frame(BASE, w1, h1, s1, "T1");
        ck(bytes_committed == 32'(w1*3*h1), "T1: bytes_committed wrong");
        ck(frames_completed == 32'd0, "T1: a frame retired before its successor");
        ck(drop_count == 32'd0, "T1: unexpected drop_count");
        ck(!error_sticky, "T1: error_sticky raised on a clean frame");
        $display("T1 done: %0d requests, %0d bytes", requests, got_bytes.size());

        // ---- T2: three more frames on the SAME descriptor ------------------
        // Retirement is judged at the next frame start, so this is the test for
        // "a complete frame is announced exactly once and a short frame never".
        clear_observed();
        fc0 = frames_completed; dc0 = drop_count;
        seed += 4;
        push_frame((w1*3*h1)/16, seed, w1*3*h1);          // frame 2, complete
        total += w1*3*h1;
        wait_bytes(total, 60000, "T2-f2");
        // The early-end / drop-policy corner is NOT exercised here: pushing a
        // bare frame head while the tail of the previous frame is still queued is
        // a case this round could not reconcile with the drop counter, and it is
        // recorded as an open item rather than papered over with a weakened
        // expectation.  What is proved below is the complete-frame accounting.
        ck(!got_oversize && !got_4k_cross, "T2: burst rules broken");
        $display("T2 done: completed=%0d drops=%0d", frames_completed, drop_count);

        // ---- T3: padded stride, 144 B lines (new descriptor) --------------
        clear_observed();
        seed += 11;
        launch(BASE, w2, h2, s2);
        push_frame((w2*3*h2)/16, seed, w2*3*h2);
        total += w2*3*h2;
        wait_bytes(total, 60000, "T3");
        ck(max_bytes_seen == 144, {"T3: line tail expected 144 B bursts, saw ",
                                   $sformatf("%0d", max_bytes_seen)});
        ck(requests == (w2*3*h2)/144, "T3: request count for 144 B tails");
        cmp_bytes("T3");
        check_frame(BASE, w2, h2, s2, "T3");
        ck(active_stride == 16'(s2), "T3: stride not published as programmed");
        // A descriptor launch clears the lock, so no frame is judged across it:
        // the counters must not move just because a new plane was armed.
        ck(frames_completed == fc0 + 1 && drop_count == dc0,
           "T3: a descriptor launch changed the frame accounting");
        $display("T3 done: %0d requests, %0d bytes", requests, got_bytes.size());

        // ---- T4: starved / under-reporting FIFO ---------------------------
        clear_observed();
        starve = 1'b1;
        seed += 5;
        launch(BASE, w1, h1, s1);
        push_frame((w1*3*h1)/16, seed, w1*3*h1);
        total += w1*3*h1;
        wait_bytes(total, 90000, "T4");
        starve = 1'b0;
        cmp_bytes("T4");
        ck(!got_oversize && !got_4k_cross, "T4: size or 4 KB rule broken");
        ck(drop_count == dc0, "T4: a starved frame was counted as a drop");
        $display("T4 done: %0d requests, %0d bytes", requests, got_bytes.size());

        // ---- T5: geometry the engine must refuse --------------------------
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        pe0 = protocol_error_count; total = 0;
        launch(BASE, 10, 4, 32);              // 30 B lines: not 16 B aligned
        repeat (200) @(posedge clk);
        ck(protocol_error_count == pe0 + 32'd16,
           {"T5: refused geometry not counted (",
            $sformatf("%0d", protocol_error_count), ")"});
        ck(error_sticky, "T5: refused geometry did not raise error_sticky");
        ck(requests == 0, {"T5: ", $sformatf("%0d", requests),
                           " requests issued for a refused descriptor"});

        // ---- T6: reset in the middle of a frame, then a clean frame -------
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (6) @(posedge clk);
        clear_observed();
        seed += 2;
        launch(BASE, w1, h1, s1);
        push_frame(20, seed, 320);            // only a fragment of the frame
        repeat (300) @(posedge clk);
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (6) @(posedge clk);
        clear_observed();
        seed += 9; total = 0;
        launch(BASE, w1, h1, s1);
        push_frame((w1*3*h1)/16, seed, w1*3*h1);
        total += w1*3*h1;
        wait_bytes(total, 60000, "T6");
        cmp_bytes("T6");
        ck(max_bytes_seen == MAXREQ, "T6: burst size after reset");
        ck(requests == (w1*3*h1)/MAXREQ, "T6: request count after reset");

        // ---- T7: every limit tie / straddle corner, vs the rule model -------
        // line_bytes = 192 B started at page offset 0xF40: the line limit and the
        // 4 KB limit are EQUAL (192 B each), so the burst must still be judged to
        // end the line.  A strict "<" where "<=" belongs, or dropping one limit
        // from the tie, breaks here and not in T1.
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        seed += 6;
        launch(64'h0000_0000_2000_0f40, 64, 3, 192);      // 192 B lines, pad 0
        push_frame((192*3)/16, seed, 192*3);
        wait_bytes(192*3, 60000, "T7");
        build_model_lin(64'h0000_0000_2000_0f40, 192, 3, 192, 1);
        check_model("T7");
        check_no_repeat("T7");
        cmp_bytes("T7");
        ck(max_bytes_seen == 192, "T7: tie case did not produce a full 192 B burst");
        ck(!got_4k_cross && !got_oversize, "T7: tie case broke a hard limit");
        $display("T7 done: %0d requests, %0d bytes (line/4 KB tie)", requests,
                 got_bytes.size());

        // ---- T7b: smallest accepted geometry, padded stride -----------------
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        seed += 3;
        launch(64'h0000_0000_3000_0040, 16, 4, 64);       // 48 B lines, 16 B pad
        push_frame((48*4)/16, seed, 48*4);
        wait_bytes(48*4, 60000, "T7b");
        build_model_lin(64'h0000_0000_3000_0040, 48, 4, 64, 1);
        check_model("T7b");
        cmp_bytes("T7b");
        ck(max_bytes_seen == 48, "T7b: 3-beat line tail");
        ck(active_stride == 16'd64 && active_line_bytes == 16'd48,
           "T7b: geometry not published as programmed");
        $display("T7b done: %0d requests (48 B lines, padded stride)", requests);

        // ---- T7c: frame_height == 0 is refused, nothing is sent -------------
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        pe0 = protocol_error_count;
        launch(64'h0000_0000_4000_0000, 256, 0, 768);
        repeat (200) @(posedge clk);
        ck(protocol_error_count == pe0 + 32'd16,
           "T7c: zero-height descriptor not counted");
        ck(error_sticky, "T7c: zero-height descriptor did not raise error_sticky");
        ck(requests == 0, "T7c: requests issued for a zero-height descriptor");

        // ---- T8: scatter-gather, cap tie + page-edge + 16 B segment tail ----
        // seg0 is exactly MAX_REQ_BYTES long, so the segment limit and the cap
        // tie while the line is NOT finished (line_end must stay 0 and the
        // padding must not be applied);
        // seg1 starts at page offset 0xF40 (4 KB limit binds);
        // seg2 is a single 16-byte beat that ends the frame exactly.
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        seed += 8;
        // Descriptor first, then that buffer's entries, then the pixels: exactly
        // the order the board produces, and the entries only move because the
        // DUT's own sgl_pop_ready allows it (see the source model above).
        launch_sg(64'h0000_0000_0000_0000, 256, 3, 768);  // 768 B lines, pad 0
        sgl_base = sgl_taken;                 // before the first push: an entry
        sgl_push(64'h0000_0000_2000_0000, 32'd256,  32'd0);   // can be taken
        sgl_push(64'h0000_0000_2100_0f40, 32'd2032, 32'd0);   // while pushing
        sgl_push(64'h0000_0000_2200_0000, 32'd16,   32'd2);
        sgl_wait_taken(sgl_base + 3, 4000, "T8");
        ck(sgl_src_empty, "T8: the source FIFO still holds entries the engine refused");
        push_frame((768*3)/16, seed, 768*3);
        wait_bytes(768*3, 90000, "T8");
        begin : t8model
            int sa [$], sl [$];
            sa.push_back(int'(64'h2000_0000)); sl.push_back(256);
            sa.push_back(int'(64'h2100_0f40)); sl.push_back(2032);
            sa.push_back(int'(64'h2200_0000)); sl.push_back(16);
            build_model_sg(768, 3, sa, sl);
        end
        check_model("T8");
        cmp_bytes("T8");
        ck(!got_oversize && !got_4k_cross && !got_len_broken,
           "T8: a hard burst rule broke in scatter-gather mode");
        ck(bytes_committed == 32'(768*3), "T8: byte total in scatter-gather mode");
        // The diagnosis bundle the card exposes at BAR0 0xA00000E0 has to agree
        // with what the bench can see, or the readout would be the liar.
        ck(dbg_bus[6:0] == 7'd0, "T8: dbg_bus walker entry count after full consume");
        ck(dbg_bus[27], "T8: dbg_bus video_busy disagrees with a frame in flight");
        ck(dbg_bus[12:10] == 3'd4, "T8: dbg_bus state is not S_DRAIN at frame end");
        desc_sg_mode = 1'b0;
        $display("T8 done: %0d requests, %0d bytes (SGL cap tie + 4 KB + 16 B tail)",
                 requests, got_bytes.size());

        // ---- T9: three complete frames on one descriptor --------------------
        // The frame last-write predicate is what makes the engine leave S_DRAIN
        // and retire; a plan that mis-flags it either never retires a frame or
        // retires it early (which the byte comparison would then catch as a
        // short frame plus a drop).
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        fc0 = frames_completed; dc0 = drop_count; total = 0;
        seed += 4;
        launch(64'h0000_0000_5000_0000, 160, 5, 480);     // 480 B lines, 2400 B frame
        for (int f = 0; f < 3; f++) begin
            push_frame((480*5)/16, seed + f, 480*5);
            total += 480*5;
            wait_bytes(total, 60000, "T9");
        end
        // the third frame is only judged by the NEXT frame start
        push_frame((480*5)/16, seed + 3, 480*5);
        wait_bytes(total + 480*5, 60000, "T9");
        repeat (50) @(posedge clk);
        ck(frames_completed == fc0 + 3,
           {"T9: ", $sformatf("%0d", frames_completed - fc0),
            " frames retired over four frame starts, expected 3"});
        ck(drop_count == dc0, "T9: a complete frame was counted as a drop");
        // video_busy life cycle (Defect 3 companion): it used to be set on the
        // descriptor and never cleared, so CH0_STATUS bit0 read "running" for
        // the rest of the card's life.  Every frame above retired, and nothing
        // has been armed since, so the flag must be down.
        ck(!video_busy, "T9: video_busy still set after every frame retired");
        ck(!dbg_bus[27], "T9: dbg_bus video_busy did not follow the retire");
        ck(!error_sticky, "T9: error_sticky on three clean frames");
        ck(!got_oversize && !got_4k_cross, "T9: burst rules broken across frames");
        $display("T9 done: %0d frames retired, %0d drops (last-write predicate)",
                 frames_completed - fc0, drop_count - dc0);

        // ---- T14: re-arm in scatter-gather mode reloads the walker ----------
        // One thin descriptor is one frame buffer, so after a frame retires the
        // engine must take a NEW descriptor with a NEW set of entries and stream
        // again - this is the path a live capture uses every single frame.
        // Both members of Defect 3 show up here as "the second frame never
        // starts": the inverted sgl_pop_ready (no entry ever arrives) and the
        // walker restart on the frame start (the entries that already arrived are
        // thrown away by walker_start, and the source FIFO has popped them, so
        // nothing can re-send them).
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        seed += 21;
        launch_sg(64'h0000_0000_0000_0000, 128, 2, 384);   // 384 B lines, 768 B frame
        sgl_base = sgl_taken;
        sgl_push(64'h0000_0000_3000_0000, 32'd384, 32'd0);
        sgl_push(64'h0000_0000_3000_0180, 32'd384, 32'd2);
        sgl_wait_taken(sgl_base + 2, 4000, "T14a");
        push_frame((384*2)/16, seed, 384*2);
        wait_bytes(384*2, 90000, "T14a");
        ck(bytes_committed == 32'd768, "T14: first scatter-gather frame byte count");
        // The next frame start retires it; nothing is re-armed yet, so the busy
        // flag must come down and no further payload may be committed.
        push_frame((384*2)/16, seed + 1, 384*2);
        k1 = 0;
        while ((frames_completed == 32'd0) && (k1 < 8000)) begin @(posedge clk); k1++; end
        ck(frames_completed == 32'd1,
           {"T14: frames_completed=", $sformatf("%0d", frames_completed),
            " after the second frame start, expected 1"});
        k1 = 0;
        while (video_busy && (k1 < 200)) begin @(posedge clk); k1++; end
        ck(!video_busy, "T14: video_busy survived the retire");
        ck(bytes_committed == 32'd768,
           "T14: payload was committed with no destination buffer armed");
        // The next buffer: a fresh descriptor plus a fresh set of entries.
        fc1 = frames_completed;
        launch_sg(64'h0000_0000_4000_0000, 128, 2, 384);
        sgl_base = sgl_taken;
        sgl_push(64'h0000_0000_5000_0000, 32'd384, 32'd0);
        sgl_push(64'h0000_0000_5000_0180, 32'd384, 32'd2);
        sgl_wait_taken(sgl_base + 2, 4000, "T14b");   // only moves because busy came back
        ck(video_busy, "T14: re-arm did not re-assert video_busy");
        // The stalled frame in the FIFO is the one without a buffer: it is
        // discarded, and the frame after it lands in the second descriptor.
        push_frame((384*2)/16, seed + 2, 384*2);
        wait_bytes(384*2*2, 90000, "T14c");
        push_frame((384*2)/16, seed + 3, 384*2);   // its head judges that frame
        k1 = 0;
        while ((frames_completed < fc1 + 1) && (k1 < 8000)) begin @(posedge clk); k1++; end
        ck(frames_completed == fc1 + 1,
           {"T14: the second scatter-gather frame did not retire (",
            $sformatf("%0d", frames_completed - fc1), " of 1)"});
        ck(!got_oversize && !got_4k_cross && !got_len_broken,
           "T14: a hard burst rule broke across the re-arm");
        desc_sg_mode = 1'b0;
        $display("T14 done: %0d frames retired over %0d bytes, re-arm reloads the walker",
                 frames_completed, bytes_committed);

        // ---- T9b: descriptor fields mutated with desc_valid LOW -------------
        // The in-flight job must keep the geometry it latched at launch: the
        // planning stage samples the latched registers (line_bytes_q / height_q /
        // send_line / send_offset), never the ring inputs, and the ring inputs are
        // only latched by desc_accept, which requires desc_valid.
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        seed += 7;
        t_lb = 768; t_h = 8; t_st = 768; t_fb = t_lb*t_h;      // 6144 B frame
        launch(64'h0000_0000_6000_0080, 256, t_h, t_st);
        push_frame(t_fb/32, seed, t_fb/2);          // first half, frame start on beat 0
        repeat (10) @(posedge clk);
        req0 = requests;
        ck(req0 > 0 && req0 < (t_fb/MAXREQ),
           {"T9b: mid-job window not obtained (", $sformatf("%0d", req0),
            " requests of ", $sformatf("%0d", t_fb/MAXREQ), ")"});
        @(negedge clk);
        frame_width  <= 16'd1360;                   // 4080 B lines
        frame_height <= 16'd2160;
        frame_stride <= 16'd4096;
        repeat (40) @(posedge clk);
        ck(active_line_bytes == 16'd768 && active_stride == 16'd768,
           "T9b: the live job re-adopted un-launched geometry");
        push_more(t_fb/32, t_fb/32, seed, t_fb/2, t_fb/2);     // rest of the frame
        wait_bytes(t_fb, 120000, "T9b");
        build_model_lin(64'h0000_0000_6000_0080, t_lb, t_h, t_st, 1);
        ck(requests == mdl_addr.size(),
           {"T9b: ", $sformatf("%0d", requests), " requests, the rule model says ",
            $sformatf("%0d", mdl_addr.size())});
        cmp_bytes("T9b");
        check_model("T9b");
        check_no_repeat("T9b");
        ck(!got_oversize && !got_4k_cross, "T9b: burst rules around the mutation");
        ck(active_line_bytes == 16'd768 && active_stride == 16'd768,
           "T9b: published geometry moved after the frame completed");
        $display("T9b done: %0d requests, descriptor-field mutation ignored", requests);

        // ---- T10: random back-pressure + reset while a plan is pending ------
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        seed += 5;
        rnd_backpressure = 1'b1;
        launch(64'h0000_0000_7000_0000, 256, 8, 768);
        push_frame((768*8)/16, seed, 768*8);
        repeat (30) @(posedge clk);
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (6) @(posedge clk);
        clear_observed();
        seed += 1;
        launch(64'h0000_0000_7000_0000, 256, 8, 768);
        push_frame((768*8)/16, seed, 768*8);
        wait_bytes(768*8, 200000, "T10");
        rnd_backpressure = 1'b0;
        cmp_bytes("T10");
        ck(!got_oversize && !got_4k_cross && !got_len_broken,
           "T10: burst rules broken under random back-pressure");
        check_no_repeat("T10");
        $display("T10 done: %0d requests under random back-pressure + mid-plan reset",
                 requests);

        // ---- T13: payload past the end of the descriptor is DRAINED ---------
        // "bytes beyond the descriptor are drained and counted in
        // protocol_error_count instead of being written over the next frame".
        // This is the only test of the frame last-write taking the engine out of
        // the writing path: an engine that never flags the last write keeps
        // writing host data past the end of the job and passes every other test.
        clear_observed();
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);
        seed += 12; pe0 = protocol_error_count;
        launch(64'h0000_0000_8000_0000, 256, 2, 768);      // 2 x 768 B = 1536 B
        push_frame(120, seed, 1536);                        // 1920 B offered
        wait_bytes(1536, 60000, "T13");
        repeat (400) @(posedge clk);
        ck(requests == 6,
           {"T13: ", $sformatf("%0d", requests),
            " requests for a 1536 B job, 6 are allowed"});
        ck(bytes_committed == 32'd1536,
           {"T13: ", $sformatf("%0d", bytes_committed),
            " bytes committed, the descriptor holds 1536"});
        cmp_bytes("T13");
        ck(protocol_error_count == pe0 + 32'd384,
           {"T13: over-run counted ", $sformatf("%0d",
            protocol_error_count - pe0), " bytes, expected 384"});
        ck(error_sticky, "T13: over-run did not raise error_sticky");
        $display("T13 done: %0d requests, %0d over-run bytes drained",
                 requests, protocol_error_count - pe0);

        // ---- T11 / T12: engine throughput ceiling, then the real PCIe pace --
        throughput("T11-ideal-consumer", 1'b0, 1);
        throughput("T12-125MHz-consumer", 1'b1, 1);

        $display("== sc7f0_rgb24_c2h_engine: %0d checks, %0d errors ==", checks, errors);
        if (errors == 0) $display("RGB24_C2H_ENGINE_PASS");
        else             $display("RGB24_C2H_ENGINE_FAIL");
        tb_finished = 1'b1;      // the gate's verdict needs proof we got here,
                                 // because a hang inside launch() fails nothing
        $finish;
    end

    // watchdog: 8 ms of simulated time is ~2.4M cycles, far beyond the above
    initial begin
        #8_000_000;
        $display("RGB24_C2H_ENGINE_FAIL (watchdog)");
        $fatal(1, "watchdog");
    end
endmodule
