`timescale 1ns / 1ps
// ============================================================================
// tb_sc7f0_video_launch_arbiter  (review H2, both channel-0 launch entries)
//
// Binds the modules the card actually ships:
//   rtl/sc7f0_video_launch_arbiter.v   BOTH launch entries + 3 guard instances +
//                                      the 245-bit crossing - this is the module
//                                      custom_pcie_dma_top.v instantiates as
//                                      u_ch0_arbiter, so nothing here is a parallel
//                                      implementation of the shipped decision
//   rtl/thin_desc_fetch_engine.v       the real thin walker, parameterised exactly
//                                      as dma_top parameterises it for this
//                                      personality (WIDTH_FIELD_PIXELS=1)
//   rtl/sc7f0_video_format_guard.v     instantiated inside the arbiter, not here
//   rtl/sc7f0_rgb24_c2h_engine.v       the real consumer, wired and decoded exactly
//                                      as dma_top decodes the crossed bus
//                                      (eng_width = bus[143:128], eng_stride =
//                                      bus[175:160]) so the GEOMETRY the engine acts
//                                      on is measured, not asserted from a predicate
//
// What is checked
//   H2a/H2a2 ordinary legacy NV12      refused, still CONSUMED, nothing launched,
//                                      no owner, one counted refusal per refused
//                                      descriptor, sticky readable
//   H2b  ordinary legal 4K RGB24       launched, bus fields exact, engine latches
//                                      11520 active bytes at an 11520 pitch, owner
//                                      retired on frame_done, no refusal added
//   H2b2 ordinary padded stride 12288  engine active_line_bytes 11520 with
//                                      active_stride 12288: padding stays padding
//   H2c0 episode accounting            an unsafe thin profile is reported ONCE per
//                                      unsafe episode - on the arm, on an unsafe
//                                      reprogram, on a disarm+rearm - never per
//                                      clock, and the report survives a CSR edge that
//                                      lands in the same timestep as a clock edge
//                                      (the version that lost that race reported 0)
//   H2c  thin legacy NV12              walker never enabled even with a descriptor
//                                      DOORBELLED, zero descriptor reads, zero SGL
//                                      pushes, hardware head unmoved, exactly ONE
//                                      counted refusal for a profile merely armed
//                                      (that refusal cannot depend on a launch
//                                      request, because the gated walker never
//                                      raises one), and the ordinary entry still
//                                      launches while the thin profile is refused
//                                      (the shared programming path is not blocked)
//   H2d  thin legal RGB24, stride0=0   walker derives 3840*3 = 11520, bus carries
//                                      PIXELS 3840, launch crosses, acked on the real
//                                      hs_src_rcv, owner taken, zero refusals, the
//                                      SGL entries carry the descriptor's own
//                                      addr/len (byte maths unaffected by the fix),
//                                      the WHOLE frame's bytes are delivered before
//                                      the engine's frame_done is claimed, and the
//                                      walker PROVES retirement (busy drops,
//                                      frame_count advances by exactly one)
//   H2e  thin padded stride0=12288     bus width still 3840 (NOT 12288/3, NOT 4096),
//                                      engine active_line_bytes 11520 at pitch 12288,
//                                      second frame retires the same way
//   H2f  refused thin launch           a launch the guard refuses is acked, aborted,
//                                      counted in the walker's own drop_count, never
//                                      launched, leaves the ring entry UNCONSUMED so a
//                                      corrected profile resumes the same ring, and
//                                      the frame that follows it still crosses
//   H2g  snapshot mismatch             a bus whose geometry is legal but is NOT the
//                                      armed profile's own pitch is refused by the
//                                      cross-check alone (the bus guard alone would
//                                      accept it), counted once per refused request
//                                      rather than once per clock
//   H2h  NEGATIVE CONTROL ENABLED=0    the pre-guard crossing MUST launch the same
//                                      unsafe NV12 descriptor and report nothing;
//                                      without this, H2a would measure nothing
//   H2i  UNITS, at the real engine     a 640x480 RGB24 thin frame must reach the
//                                      engine as 640 px / 1920 B.  With the old byte
//                                      semantics the width field was 1920 and the
//                                      engine's own rgb_line_bytes() shim computed
//                                      1920*3 = 5760 B - a 3x row overrun that 4K
//                                      happens to hide.  Checked against the engine's
//                                      active_line_bytes output.  This is also the
//                                      third consecutive thin frame: a fixture that
//                                      claimed frame_done before the walker had
//                                      delivered the frame's bytes left frame_active
//                                      set and no further launch was possible, so
//                                      every thin case here retires through
//                                      thin_frame_finish.
//
// Host-side modelling, stated rather than hidden
//   * the ring is driven as a driver drives it: the entry is written at tail and the
//     doorbell (tail) is advanced only when the ring has room, the walker's own
//     hardware head is observed on ring_head, and no case ever forces has_work or
//     bypasses the walker;
//   * frame_done (pcie_frame_done) is the signal the ENGINE produces after it has
//     committed a frame, so the fixture may only claim it once the frame's own bytes
//     have arrived in the SGL stream it consumes - thin_frame_finish waits on the
//     walker's real sgl_y pushes, then pulses frame_done, then requires the walker to
//     go idle.  Nothing is cleared or forced to make a case reach PASS;
//   * the engine has no video source here, so its own video_frame_done is never
//     produced and the frame_done pulse stands in for the PCIe-side EOF, exactly as
//     in the previous version of this fixture;
//   * every wait in this fixture is bounded and its failure is a named check, so a
//     guard that blocks the shared mailbox shows up as FAIL lines instead of a hang
//     (consume_desc proves a REFUSED descriptor is still consumed, which is what
//     keeps the programming path alive behind a bad video profile);
//   * thin_bus_sub is the only fixture-level liberty: a wire selection that lets H2f/
//     H2g present a launch bus the walker did not produce.  It copies no predicate.
//   * stimulus is driven and sampled away from the clock edge (negedge) so no check
//     depends on which always block wins a same-delta race.
// ============================================================================
module tb_sc7f0_video_launch_arbiter;
    localparam integer MAXW = 4096, MAXH = 2160;
    localparam integer RING = 8;
    // One 32 MiB descriptor covers the largest frame this fixture arms
    // (3840x2160 at a 12288 B pitch = 26,542,080 B).  Real drivers segment a frame
    // over several entries; the walker only accumulates until its byte target, so the
    // segment count is not what these cases exercise - the byte maths is.
    localparam [31:0] DESC_LEN = 32'h0200_0000;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    // ---- thin profile CSRs, as axil_reg_space presents them --------------
    reg          thin_active = 1'b0;
    reg  [3:0]   thin_fmt    = 4'd0;
    reg  [15:0]  w = 1920, h = 1080, s0 = 3840;
    reg  [63:0]  ts = 64'hD00D;

    // ---- ordinary descriptor stimulus ------------------------------------
    reg          desc_valid = 1'b0, desc_select = 1'b1;
    reg  [3:0]   desc_format = 4'd0, desc_planes = 4'd2;
    reg  [15:0]  desc_w = 1920, desc_h = 1080, desc_s = 3840;
    reg  [63:0]  desc_y = 64'h1000_0000, desc_uv = 64'h2000_0000;
    reg          desc_sg = 1'b0;

    // ---- engine-side crossing --------------------------------------------
    reg          hs_src_rcv = 1'b0;
    reg          frame_done = 1'b0;
    reg          force_clear = 1'b0;

    // ---- walker <-> arbiter ----------------------------------------------
    wire         thin_enable, thin_ack, thin_abort, thin_profile_ok;
    wire         thin_req;
    wire [244:0] thin_bus;
    reg          thin_bus_sub = 1'b0;
    reg  [244:0] thin_bus_alt = 245'd0;
    wire [244:0] arb_bus = thin_bus_sub ? thin_bus_alt : thin_bus;

    // The host doorbell model: the driver writes the entry, then advances tail.  The
    // walker's hardware head is observed, never forced.
    reg [15:0]   ring_tail = 16'd0;
    wire [15:0]  ring_head;

    wire         mrd_valid;  wire [63:0] mrd_addr;  wire [10:0] mrd_dw;
    wire [7:0]   mrd_tag;
    reg          mrd_ack = 1'b0;
    reg          cpl_valid = 1'b0;  reg [127:0] cpl_data = 128'd0;
    reg  [7:0]   cpl_tag = 8'd0;
    wire         sgl_y_wr;  wire [63:0] sgl_y_addr;  wire [31:0] sgl_y_len;
    wire         sgl_uv_wr;
    wire [31:0]  frame_count, drop_count;
    wire         thin_busy;

    // ---- arbiter outputs --------------------------------------------------
    wire         desc_ready, desc_fmt_ok, desc_refused;
    wire         hs_send, owner_busy, guard_sticky;
    wire [244:0] hs_bus;
    wire [31:0]  guard_count;
    wire [63:0]  desc_bytes, thin_bytes;

    // The walker's descriptor store: {flags, len, addr} per 16-byte entry.
    reg [127:0] desc [0:RING-1];

    // ---- DUT 1: the module custom_pcie_dma_top instantiates --------------
    sc7f0_video_launch_arbiter #(.MAX_WIDTH(MAXW), .MAX_HEIGHT(MAXH),
                                 .ENABLED(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .desc_valid(desc_valid), .desc_select(desc_select),
        .desc_format(desc_format), .desc_plane_count(desc_planes),
        .desc_width(desc_w), .desc_height(desc_h), .desc_stride(desc_s),
        .desc_y_addr(desc_y), .desc_uv_addr(desc_uv), .desc_sg_mode(desc_sg),
        .timestamp(ts), .desc_ready(desc_ready),
        .thin_active(thin_active), .thin_format(thin_fmt),
        .thin_width(w), .thin_height(h), .thin_stride0(s0),
        .thin_enable(thin_enable),
        .thin_launch_req(thin_req), .thin_launch_bus(arb_bus),
        .thin_launch_ack(thin_ack), .thin_frame_abort(thin_abort),
        .force_clear(force_clear),
        .hs_src_rcv(hs_src_rcv), .owner_release(frame_done),
        .hs_send_q(hs_send), .hs_bus_q(hs_bus), .ch0_owner_busy(owner_busy),
        .desc_fmt_ok(desc_fmt_ok), .desc_refused(desc_refused),
        .thin_profile_ok(thin_profile_ok),
        .guard_sticky(guard_sticky), .guard_count(guard_count),
        .desc_frame_bytes(desc_bytes), .thin_frame_bytes(thin_bytes));

    // ---- DUT 2: ENABLED=0, the pre-guard crossing (negative control) ------
    wire         off_send, off_owner, off_sticky, off_fmt_ok, off_profile_ok;
    wire [31:0]  off_count;
    wire [244:0] off_bus;
    sc7f0_video_launch_arbiter #(.MAX_WIDTH(MAXW), .MAX_HEIGHT(MAXH),
                                 .ENABLED(0)) dut_off (
        .clk(clk), .rst_n(rst_n),
        .desc_valid(desc_valid), .desc_select(desc_select),
        .desc_format(desc_format), .desc_plane_count(desc_planes),
        .desc_width(desc_w), .desc_height(desc_h), .desc_stride(desc_s),
        .desc_y_addr(desc_y), .desc_uv_addr(desc_uv), .desc_sg_mode(desc_sg),
        .timestamp(ts), .desc_ready(),
        .thin_active(1'b0), .thin_format(thin_fmt),
        .thin_width(w), .thin_height(h), .thin_stride0(s0),
        .thin_enable(),
        .thin_launch_req(1'b0), .thin_launch_bus(245'd0),
        .thin_launch_ack(), .thin_frame_abort(),
        .force_clear(1'b0),
        .hs_src_rcv(hs_src_rcv), .owner_release(frame_done),
        .hs_send_q(off_send), .hs_bus_q(off_bus), .ch0_owner_busy(off_owner),
        .desc_fmt_ok(off_fmt_ok), .desc_refused(), .thin_profile_ok(off_profile_ok),
        .guard_sticky(off_sticky), .guard_count(off_count),
        .desc_frame_bytes(), .thin_frame_bytes());

    // ---- the real thin walker, as dma_top parameterises it ---------------
    thin_desc_fetch_engine #(.DATA_WIDTH(128), .WIDTH_FIELD_PIXELS(1)) u_walker (
        .clk(clk), .rst_n(rst_n),
        .enable(thin_enable), .format(thin_fmt),
        .frame_width(w), .frame_height(h),
        .frame_stride0(s0), .frame_stride1(16'd0),
        .global_timestamp(ts),
        .ring0_base_addr(64'h1000), .ring0_size(16'd8), .ring0_tail(ring_tail),
        .ring0_head(ring_head),
        .ring1_base_addr(64'h2000), .ring1_size(16'd8), .ring1_tail(16'd0),
        .ring1_head(),
        .frame_done_in(frame_done), .frame_abort(thin_abort),
        .capture_engine_busy(owner_busy),
        .frame_count(frame_count), .drop_count(drop_count), .busy(thin_busy),
        .mrd_req_valid(mrd_valid), .mrd_req_addr(mrd_addr), .mrd_req_dw_len(mrd_dw),
        .mrd_req_tag(mrd_tag), .mrd_req_ack(mrd_ack),
        .cpld_valid(cpl_valid), .cpld_data(cpl_data), .cpld_last(1'b1),
        .cpld_tag(cpl_tag),
        .sgl_y_wr_en(sgl_y_wr), .sgl_y_wr_addr(sgl_y_addr), .sgl_y_wr_len(sgl_y_len),
        .sgl_y_wr_flags(), .sgl_y_almost_full(1'b0),
        .sgl_uv_wr_en(sgl_uv_wr), .sgl_uv_wr_addr(), .sgl_uv_wr_len(),
        .sgl_uv_wr_flags(), .sgl_uv_almost_full(1'b0),
        .frame_launch_req(thin_req), .frame_launch_bus(thin_bus),
        .frame_launch_ack(thin_ack));

    // ---- the real consumer, decoded exactly as custom_pcie_dma_top does ---
    reg          eng_desc_valid = 1'b0;
    wire         eng_desc_ready;
    wire [63:0]  eng_y   = hs_bus[63:0];
    wire         eng_sg  = hs_bus[240];
    wire [63:0]  eng_ts  = hs_bus[239:176];
    reg  [15:0]  eng_width, eng_height, eng_stride;
    reg  [15:0]  eng_line_latched, eng_pitch_latched;
    reg  [3:0]   eng_format;
    wire         eng_busy, eng_done;
    wire         eng_req_valid, eng_req_last, eng_req_ack;
    reg          eng_data_ready = 1'b1;
    wire [63:0]  eng_req_addr;
    wire [10:0]  eng_req_dw;
    wire [127:0] eng_req_data;
    wire [127:0] axis_data = 128'h0;
    wire         eng_line_unused;
    wire [6:0]   sgl_cnt;
    wire         sgl_pop;
    wire [15:0]  eng_active_line_bytes, eng_active_stride;
    wire [31:0]  eng_err, eng_drop, eng_frames, eng_align, eng_bytes;

    sc7f0_rgb24_c2h_engine #(.MAX_WIDTH(MAXW), .PCIE_DATA_WIDTH(128),
                             .MAX_REQ_BYTES(256), .SRC_FIFO_DEPTH(1024)) u_eng (
        .clk(clk), .rst_n(rst_n),
        .desc_valid(eng_desc_valid), .desc_ready(eng_desc_ready),
        .desc_sg_mode(eng_sg), .plane_y_addr(eng_y),
        .frame_width(eng_width), .frame_height(eng_height),
        .frame_stride(eng_stride),
        .sgl_wr_en(1'b0), .sgl_wr_addr(64'd0), .sgl_wr_len(32'd0),
        .sgl_wr_flags(32'd0),
        .cur_sgl_count(sgl_cnt), .sgl_pop_ready(sgl_pop), .dbg_bus(),
        .global_timestamp(eng_ts),
        .p_axis_tdata(axis_data), .p_axis_tuser(1'b0), .p_axis_tvalid(1'b0),
        .p_axis_avail(11'd0), .p_axis_tready(eng_line_unused),
        .c2h_req_valid(eng_req_valid), .c2h_req_addr(eng_req_addr),
        .c2h_req_dw_len(eng_req_dw), .c2h_req_data(eng_req_data),
        .c2h_req_last(eng_req_last),
        .c2h_req_data_ready(eng_data_ready), .c2h_req_ack(eng_req_ack),
        .video_busy(eng_busy), .video_frame_done(eng_done),
        .frame_pts(), .protocol_error_count(eng_err), .drop_count(eng_drop),
        .frames_completed(eng_frames), .align_discard_count(eng_align),
        .bytes_committed(eng_bytes),
        .active_line_bytes(eng_active_line_bytes),
        .active_stride(eng_active_stride),
        .src_overflow_sticky(1'b0), .src_line_align_sticky(1'b0),
        .error_sticky());

    // Engine's c2h_req_ack, and the crossing's hs_src_rcv producer, both modelled
    // as the RC/video side would: accept what is offered.
    assign eng_req_ack = eng_req_valid && eng_data_ready;

    integer errors = 0, checks = 0;

    // -----------------------------------------------------------------------
    // Passively observed counters, all sampled on the phase where every registered
    // signal is stable for a full cycle, so no check depends on process ordering.
    // These are the fixture's copy of what a driver would see: how many descriptor
    // reads happened, how many SGL bytes the walker delivered, how many refusals the
    // profile guard actually issued, how many launches were aborted.
    // -----------------------------------------------------------------------
    integer mrd_reads = 0, sgl_pushes = 0, prof_events = 0, abort_events = 0,
            ack_events = 0, launch_events = 0;
    reg [63:0] sgl_bytes_y = 64'd0;
    reg [31:0] sgl_len_first = 32'd0, sgl_len_last = 32'd0;
    reg [63:0] sgl_addr_first = 64'd0;
    reg        hs_send_prev   = 1'b0;

    always @(negedge clk) begin
        if (rst_n) begin
            if (mrd_valid && mrd_ack)              mrd_reads = mrd_reads + 1;
            if (sgl_y_wr) begin
                if (sgl_pushes == 0) begin          // first push of the whole run
                    sgl_len_first  = sgl_y_len;
                    sgl_addr_first = sgl_y_addr;
                end
                sgl_pushes     = sgl_pushes + 1;
                sgl_bytes_y    = sgl_bytes_y + {32'd0, sgl_y_len};
                sgl_len_last   = sgl_y_len;
            end
            if (dut.thin_prof_take)                prof_events  = prof_events + 1;
            if (thin_abort)                        abort_events = abort_events + 1;
            if (thin_ack)                          ack_events   = ack_events + 1;
            if (hs_send && !hs_send_prev)          launch_events = launch_events + 1;
            hs_send_prev <= hs_send;
        end else begin
            hs_send_prev <= 1'b0;
        end
    end

    task check(input [8*58:1] nm, input cond);
        begin
            checks = checks + 1;
            if (!cond) begin errors = errors + 1; $display("ARB_TB FAIL %s", nm); end
        end
    endtask
    task check_eq(input [8*58:1] nm, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ARB_TB FAIL %s got=%0d exp=%0d", nm, got, exp);
            end
        end
    endtask
    task check_bytes(input [8*58:1] nm, input [63:0] got, input [63:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ARB_TB FAIL %s got=%0d exp=%0d", nm, got, exp);
            end
        end
    endtask

    integer i, k, cnt_before, prof_before, mrd_before, sgl_before, abort_before;
    integer frames_before, drop_before;
    reg     saw_send, saw_owner;
    reg     [15:0] head_before, head_now;
    reg     [63:0] bytes_before;
    reg     cpl_pend = 1'b0;  reg [127:0] cpl_dat = 128'd0;  reg [7:0] cpl_tg = 8'd0;

    // The walker's completion side: ack the read, answer it from the store.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mrd_ack <= 1'b0; cpl_valid <= 1'b0; cpl_pend <= 1'b0;
        end else begin
            mrd_ack   <= mrd_valid;
            cpl_valid <= cpl_pend;
            if (cpl_pend) begin
                cpl_data <= cpl_dat; cpl_tag <= cpl_tg; cpl_pend <= 1'b0;
            end
            if (mrd_valid && mrd_ack) begin
                cpl_pend <= 1'b1;
                cpl_dat  <= desc[mrd_addr[7:4]];
                cpl_tg   <= mrd_tag;
            end
        end
    end

    // Hand the engine whatever the arbiter crossed, with the dma_top decode.  The
    // engine's desc_ready is a one-cycle accept pulse, so acceptance is PROVEN here
    // rather than assumed, and the geometry is captured after the accept.
    task engine_take(input [8*40:1] tag);
        integer n;
        reg     took;
        begin
            eng_desc_valid = 1'b0;
            // Take the crossing that is actually being offered, not whatever the
            // previous frame left on the bus: wait for a pending crossing first.
            n = 0;
            while (!hs_send && n < 40) begin @(negedge clk); n = n + 1; end
            check({tag, ": a crossing is pending for the engine"}, hs_send);
            @(negedge clk);
            // custom_pcie_dma_top.v presents the crossed bus to the engine together
            // with desc_valid, so the geometry fields are applied BEFORE the accept
            // edge.  Only then are the engine's own latched active_line_bytes and
            // active_stride really this frame's, which is the point of measuring them.
            eng_width  = hs_bus[143:128];
            eng_height = hs_bus[159:144];
            eng_stride = hs_bus[175:160];
            eng_format = hs_bus[244:241];
            @(negedge clk);
            eng_desc_valid = 1'b1;
            n = 0; took = 1'b0;
            while (!took && n < 20) begin
                @(negedge clk);
                took = (eng_desc_ready === 1'b1);
                n = n + 1;
            end
            eng_desc_valid = 1'b0;
            check({tag, ": engine accepted the crossed launch"}, took);
            eng_line_latched  = eng_active_line_bytes;
            eng_pitch_latched = eng_active_stride;
            $display("ARB_TB %s engine latched width=%0d height=%0d stride=%0d line=%0d pitch=%0d",
                     tag, eng_width, eng_height, eng_stride,
                     eng_active_line_bytes, eng_active_stride);
        end
    endtask

    // Release the crossing the way the video domain does.
    task release_crossing;
        begin
            @(negedge clk); hs_src_rcv = 1'b1;
            @(negedge clk); hs_src_rcv = 1'b0;
        end
    endtask

    // Complete an ORDINARY launch: the engine accepts, the crossing releases, the
    // descriptor owner retires on the PCIe-side EOF.  No walker frame is involved.
    task ordinary_launch_finish(input [8*40:1] tag);
        begin
            engine_take(tag);
            release_crossing;
            @(negedge clk); frame_done = 1'b1;
            @(negedge clk); frame_done = 1'b0;
            k = 0;
            while (owner_busy && k < 20) begin @(negedge clk); k = k + 1; end
            check({tag, ": ordinary owner retired on frame_done"}, !owner_busy);
            @(negedge clk);
        end
    endtask

    // Complete a THIN launch the way the hardware does.  The engine cannot report a
    // finished frame before the frame's own bytes reached the SGL stream it consumes,
    // so the fixture waits for the walker's real pushes first; only then does it play
    // pcie_frame_done, and it then requires the walker to retire the frame.  A
    // frame_done claimed earlier is exactly what made the walker hold frame_active
    // forever, which is how the third thin frame stopped launching in this fixture.
    task thin_frame_finish(input [8*40:1] tag, input integer want_bytes);
        integer n;
        reg [63:0] base;
        begin
            base = sgl_bytes_y;
            engine_take(tag);
            release_crossing;
            n = 0;
            while (((sgl_bytes_y - base) < want_bytes) && n < 4000) begin
                @(negedge clk); n = n + 1;
            end
            check({tag, ": whole frame delivered to the SGL"},
                  (sgl_bytes_y - base) >= want_bytes);
            @(negedge clk); frame_done = 1'b1;
            @(negedge clk); frame_done = 1'b0;
            n = 0;
            while (thin_busy && n < 50) begin @(negedge clk); n = n + 1; end
            check({tag, ": walker retired the frame"}, !thin_busy);
            n = 0;
            while (owner_busy && n < 50) begin @(negedge clk); n = n + 1; end
            check({tag, ": owner retired on frame_done"}, !owner_busy);
            @(negedge clk);
        end
    endtask

    // Driver side of the descriptor ring: write the entry at tail, then ring the
    // doorbell.  The ABI has no full flag (tail == head means empty), so a driver
    // waits for room; this waits too instead of corrupting the ring.
    task post_desc(input [8*30:1] why);
        integer nt, guard;
        begin
            nt = ring_tail + 1;
            if (nt >= RING) nt = 0;
            guard = 0;
            @(negedge clk);
            while ((nt[15:0] === ring_head) && guard < 2000) begin
                @(negedge clk); guard = guard + 1;
            end
            check({why, ": ring had room for a new entry"}, guard < 2000);
            desc[ring_tail[2:0]] = {32'hC0FFEE00 + {14'd0, ring_tail}, DESC_LEN,
                                    64'h4000_0000 + {48'd0, ring_tail} * 64'h1000};
            @(negedge clk);
            ring_tail = nt[15:0];                       // doorbell
            repeat (2) @(negedge clk);
        end
    endtask

    // Wait for the walker to put a launch on the bus (it only does that when the
    // armed profile is legal, so a timeout here is a real finding).
    task wait_thin_req(input [8*40:1] nm, input integer limit);
        begin
            i = 0;
            while (!thin_req && i < limit) begin @(negedge clk); i = i + 1; end
            check(nm, thin_req);
        end
    endtask

    // Offer an ordinary descriptor and require the shared mailbox to TAKE it.  A
    // refused descriptor is still CONSUMED, so this wait is bounded and its failure is
    // a named check: a guard that blocks the mailbox, or a crossing that wedges the
    // owner, is then a reported fault instead of a hung fixture.
    task consume_desc(input [8*46:1] nm);
        begin
            @(negedge clk); desc_valid = 1'b1;   // offer mid-cycle
            @(negedge clk);                       // sample it in the offered cycle
            i = 0;
            while (!desc_ready && i < 200) begin @(negedge clk); i = i + 1; end
            check(nm, desc_ready);
            desc_valid = 1'b0;                    // exactly one offer cycle
        end
    endtask

    initial begin
        for (k = 0; k < RING; k = k + 1) desc[k] = 128'd0;
        repeat (4) @(posedge clk); rst_n = 1'b1; repeat (4) @(posedge clk);

        // ---- H2a ordinary legacy NV12 ------------------------------------
        desc_format = 4'd0; desc_planes = 4'd2;
        consume_desc("H2a refused descriptor is still consumed");
        saw_send = 0; saw_owner = 0;
        for (i = 0; i < 50; i = i + 1) begin
            @(negedge clk);
            if (hs_send)    saw_send = 1;
            if (owner_busy) saw_owner = 1;
            if (off_send)   ;
        end
        check("H2a refused descriptor launches nothing", !saw_send);
        check("H2a refused descriptor takes no owner",   !saw_owner);
        check("H2a guard sticky readable",               guard_sticky);
        check_eq("H2a one counted refusal",              guard_count, 1);

        // ---- H2a2 a second refusal counts exactly one more ---------------
        consume_desc("H2a2 second descriptor is still consumed");
        repeat (50) @(negedge clk);
        check_eq("H2a2 refusals count per descriptor",   guard_count, 2);

        // ---- H2b ordinary legal 4K RGB24 ---------------------------------
        desc_format = 4'd1; desc_planes = 4'd1;
        desc_w = 3840; desc_h = 2160; desc_s = 11520;
        cnt_before = guard_count;
        @(negedge clk); desc_valid = 1'b1; i = 0;
        while (!hs_send && i < 20) begin @(negedge clk); i = i + 1; end
        check("H2b legal descriptor launched",            hs_send);
        desc_valid = 1'b0;
        check_eq("H2b bus format",                       hs_bus[244:241], 1);
        check_eq("H2b bus width pixels",                 hs_bus[143:128], 3840);
        check_eq("H2b bus height",                       hs_bus[159:144], 2160);
        check_eq("H2b bus stride bytes",                 hs_bus[175:160], 11520);
        check_bytes("H2b frame byte product",              desc_bytes, 64'd24883200);
        ordinary_launch_finish("launch");
        // The engine's OWN line computation on the geometry it was handed
        // (rtl/sc7f0_rgb24_c2h_engine.v desc_line_bytes = rgb_line_bytes(frame_width)).
        check_eq("H2b engine sees width 3840",           eng_width, 3840);
        check_eq("H2b engine line bytes 11520",          u_eng.desc_line_bytes, 11520);
        check_eq("H2b engine pitch 11520",               eng_stride, 11520);
        check_eq("H2b legal frame adds no refusal",      guard_count - cnt_before, 0);

        // ---- H2b2 padded stride: padding must stay padding --------------
        desc_s = 12288;
        @(negedge clk); desc_valid = 1'b1; i = 0;
        while (!hs_send && i < 20) begin @(negedge clk); i = i + 1; end
        check("H2b2 padded stride still launches",        hs_send);
        desc_valid = 1'b0;
        check_eq("H2b2 bus width is pixels, not pitch",  hs_bus[143:128], 3840);
        check_eq("H2b2 bus stride is the pad",           hs_bus[175:160], 12288);
        ordinary_launch_finish("H2b2");
        check_eq("H2b2 engine active line stays 11520",
                 u_eng.desc_line_bytes, 11520);
        check_eq("H2b2 engine pitch keeps the pad",      eng_stride, 12288);

        // ---- H2c0 thin profile episode accounting -------------------------
        // The refusal a driver must be able to read for a profile that was only ever
        // ARMED: exactly one event per unsafe episode, and it must not matter whether
        // the CSR write lands in the same timestep as a clock edge.
        cnt_before   = guard_count;
        prof_before  = prof_events;
        @(posedge clk);                                  // drive ON the edge: the case
        thin_active = 1'b1; thin_fmt = 4'd0;             // that used to report zero
        repeat (10) @(negedge clk);
        check_eq("H2c0 edge-timed unsafe arm counts ONE",     guard_count - cnt_before, 1);
        check_eq("H2c0 edge-timed unsafe arm issues ONE event",
                 prof_events - prof_before, 1);
        // Held unsafe: a level would count every clock.
        cnt_before = guard_count;
        repeat (40) @(negedge clk);
        check_eq("H2c0 held unsafe adds nothing",          guard_count - cnt_before, 0);
        // Made safe: reports nothing, and re-arms the episode flag.
        @(negedge clk); thin_fmt = 4'd1; w = 1920; s0 = 5760;   // 5760 carries 1920 px
        repeat (10) @(negedge clk);
        check("H2c0 safe profile reports ok",               thin_profile_ok);
        cnt_before = guard_count;
        @(negedge clk); thin_fmt = 4'd0; s0 = 3840;             // unsafe reprogram
        repeat (10) @(negedge clk);
        check_eq("H2c0 unsafe reprogram counts ONE",       guard_count - cnt_before, 1);
        @(negedge clk); thin_active = 0;                          // disarm
        repeat (6) @(negedge clk);
        cnt_before = guard_count;
        @(negedge clk); thin_fmt = 4'd0; w = 1920; h = 1080; s0 = 3840;
        @(negedge clk); thin_active = 1;                          // re-arm unsafe
        repeat (10) @(negedge clk);
        check_eq("H2c0 disarm then rearm counts ONE",      guard_count - cnt_before, 1);
        check("H2c0 refused profile never enables the walker", !thin_enable);

        // ---- H2c thin legacy NV12, with the doorbell already rung ---------
        // A descriptor is pending, so "the walker never fetched" can only be the
        // profile gate: an empty ring would make the same statement vacuous.
        @(negedge clk); thin_active = 1'b0;             // close the H2c0 episode
        repeat (4) @(negedge clk);
        post_desc("H2c doorbell");
        check("H2c ring entry is pending while refused",  ring_head !== ring_tail);
        cnt_before = guard_count; prof_before = prof_events;
        mrd_before = mrd_reads; sgl_before = sgl_pushes;
        head_before = ring_head;
        @(negedge clk); thin_fmt = 4'd0; w = 1920; h = 1080; s0 = 3840;
        @(negedge clk); thin_active = 1'b1;             // fresh unsafe episode
        for (i = 0; i < 500; i = i + 1) @(negedge clk);
        check("H2c walker never enabled",                 !thin_enable);
        check("H2c profile guard reports unsafe",         !thin_profile_ok);
        check_eq("H2c zero descriptor reads",             mrd_reads - mrd_before, 0);
        check_eq("H2c zero SGL pushes",                   sgl_pushes - sgl_before, 0);
        check_eq("H2c hardware head unmoved",             ring_head, head_before);
        check_eq("H2c arming an unsafe profile counts ONE refusal",
                 guard_count - cnt_before, 1);
        check_eq("H2c one event per unsafe episode",
                 prof_events - prof_before, 1);
        // The refused thin profile must not block the shared/ordinary path: a legal
        // descriptor still launches while thin_active is armed and refused.
        desc_format = 4'd1; desc_planes = 4'd1;
        desc_w = 3840; desc_h = 2160; desc_s = 11520;
        @(negedge clk); desc_valid = 1'b1; i = 0;
        while (!hs_send && i < 20) begin @(negedge clk); i = i + 1; end
        check("H2c ordinary path advances while thin refused", hs_send);
        desc_valid = 1'b0;
        ordinary_launch_finish("H2c-ord");

        // ---- H2d thin legal RGB24, stride0 = 0 (derive width*3) ----------
        // Resumes the ring that the refused profile left untouched.
        thin_fmt = 4'd1; w = 3840; h = 2160; s0 = 16'd0;
        cnt_before = guard_count; abort_before = abort_events;
        frames_before = frame_count;
        @(negedge clk);
        check("H2d safe profile re-enables the walker",    thin_enable);
        check("H2d ring entry survived the refusal",       ring_head !== ring_tail);
        wait_thin_req("H2d walker raised a launch", 6000);
        check_eq("H2d bus format",                        hs_bus[244:241], 1);
        check_eq("H2d no refusal for a safe profile",      guard_count - cnt_before, 0);
        check_eq("H2d no abort for a safe profile",        abort_events - abort_before, 0);
        for (i = 0; i < 8; i = i + 1) @(negedge clk);
        check("H2d launch crossed to the engine",          hs_send);
        check_eq("H2d bus carries PIXELS",                hs_bus[143:128], 3840);
        check_eq("H2d bus stride derived width*3",         hs_bus[175:160], 11520);
        check_eq("H2d bus height",                        hs_bus[159:144], 2160);
        check("H2d owner taken",                          owner_busy);
        // Accept it, then let the walker fetch its descriptors: byte maths is
        // computed from stride*height and must be unaffected by the width field.
        sgl_before = sgl_pushes; mrd_before = mrd_reads;
        thin_frame_finish("H2d", 11520 * 2160);
        check("H2d walker fetched descriptors after launch",
              mrd_reads > mrd_before);
        check("H2d walker pushed the descriptor's own SGL",
              sgl_pushes > sgl_before);
        check_eq("H2d SGL length is the descriptor's own", sgl_len_first, DESC_LEN);
        check_bytes("H2d SGL address is the descriptor's own", sgl_addr_first,
                    64'h4000_0000);
        check_eq("H2d one frame retired",                  frame_count - frames_before, 1);

        // ---- H2e thin padded stride --------------------------------------
        s0 = 16'd12288;
        frames_before = frame_count;
        post_desc("H2e doorbell");
        wait_thin_req("H2e padded thin profile launches", 6000);
        check_eq("H2e bus width stays 3840 (not 12288, not 4096)",
                 hs_bus[143:128], 3840);
        check_eq("H2e bus stride keeps the pad",           hs_bus[175:160], 12288);
        thin_frame_finish("H2e", 12288 * 2160);
        check_eq("H2e engine active line 11520",           u_eng.desc_line_bytes, 11520);
        check_eq("H2e engine pitch 12288",                 eng_stride, 12288);
        check_eq("H2e second thin frame retired",          frame_count - frames_before, 1);

        // ---- H2i UNITS at the real engine: 640x480 RGB24 -----------------
        // The case the 4K frame hides: with the old byte semantics the width field
        // was 1920 B and the engine computed 1920*3 = 5760 B per row.  It is also the
        // THIRD consecutive thin frame, so it only runs if retirement really works.
        s0 = 16'd0; w = 640; h = 480;
        frames_before = frame_count;
        post_desc("H2i doorbell");
        wait_thin_req("H2i 640x480 thin launch raised", 6000);
        check_eq("H2i bus width is 640 px",                hs_bus[143:128], 640);
        check_eq("H2i bus stride is 1920 B",               hs_bus[175:160], 1920);
        thin_frame_finish("H2i", 1920 * 480);
        check_eq("H2i engine sees 640 px",                 eng_width, 640);
        check_eq("H2i engine line is 1920, not 5760",      u_eng.desc_line_bytes, 1920);
        check_eq("H2i engine pitch 1920",                  eng_stride, 1920);
        check_eq("H2i third thin frame retired",           frame_count - frames_before, 1);

        // ---- H2f a thin launch the guard refuses --------------------------
        // Reachable refusal protocol, as the design must behave: with the profile
        // legal the crossing latches in the same cycle the request appears, so what
        // can really be refused is the snapshot the walker presents.  A refused
        // request is acked, aborted, dropped in the walker's own counter, launched
        // never, and leaves the ring entry unconsumed.
        w = 1920; h = 1080; s0 = 16'd11520; thin_fmt = 4'd1;
        thin_bus_sub = 1'b1;
        thin_bus_alt = {4'd1, 1'b1, ts, 16'd1920, 16'd1080, 16'd1920,
                        64'd0, 64'h200};   // 1920 B cannot carry 1920 px of RGB24
        cnt_before = guard_count; abort_before = abort_events;
        drop_before = drop_count; head_before = ring_head; saw_send = 0;
        frames_before = frame_count;
        post_desc("H2f doorbell");
        wait_thin_req("H2f a request is up to be refused", 6000);
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge clk);
            if (hs_send) saw_send = 1;
        end
        check_eq("H2f refused request never launched",     saw_send, 0);
        check("H2f the bus guard itself refuses",         !dut.thin_bus_ok_w);
        check("H2f refused request was acked",            abort_events > abort_before);
        // The guard counter and the walker's drop_count update on the edge AFTER the
        // refusal cycle, so the totals are only comparable from a cycle in which no
        // refusal is in flight; comparing mid-cycle is what made them read one short.
        k = 0;
        while (thin_abort && k < 20) begin @(negedge clk); k = k + 1; end
        head_now = ring_head;
        check("H2f refused request aborted the frame",     drop_count > drop_before);
        check_eq("H2f every refused request counted",
                 guard_count - cnt_before, abort_events - abort_before);
        check_eq("H2f every refusal counted one walker drop",
                 drop_count - drop_before, abort_events - abort_before);
        check_eq("H2f the refused frame consumed no descriptor", head_now, head_before);
        check("H2f the ring entry is still queued",       head_now !== ring_tail);
        // Remove the fault: the SAME ring entry must now launch and complete, which
        // is the proof that a refusal leaves nothing behind to corrupt the next frame.
        thin_bus_sub = 1'b0;
        thin_frame_finish("H2f-recover", 11520 * 1080);
        check("H2f walker returned to idle",             !thin_busy);
        check_eq("H2f frame after a refusal retired",     frame_count - frames_before, 1);
        // The frame that a refusal must not have corrupted is the armed profile's own:
        // 1920 px of RGB24 is 5760 active bytes at the armed 11520 pitch.
        check_eq("H2f recovery frame is the armed geometry",
                 eng_line_latched, 5760);
        check_eq("H2f recovery pitch is the armed pitch",
                 eng_pitch_latched, 11520);

        // ---- H2g snapshot mismatch (bus is not the armed profile) ---------
        // Here the bus geometry is perfectly legal on its own: only the cross-check
        // against the armed profile refuses it, which is the "guard judged one
        // snapshot, the engine would DMA another" failure this closes.
        thin_fmt = 4'd1; w = 3840; h = 2160; s0 = 16'd11520;
        frames_before = frame_count;
        thin_bus_sub = 1'b1;
        thin_bus_alt = {4'd1, 1'b1, ts, 16'd12288, 16'd2160, 16'd3840,
                        64'd0, 64'h200};   // legal, but not the armed 11520 pitch
        cnt_before = guard_count; abort_before = abort_events; saw_send = 0;
        head_before = ring_head;
        desc_valid = 1'b0;
        post_desc("H2g doorbell");
        wait_thin_req("H2g walker raised a launch to judge", 6000);
        for (i = 0; i < 30; i = i + 1) begin
            @(negedge clk);
            if (hs_send) saw_send = 1;
        end
        check_eq("H2g mismatched snapshot never launched",  saw_send, 0);
        check("H2g bus guard alone would have accepted",   dut.thin_bus_ok_w);
        check("H2g mismatched snapshot consumed (acked)",
              abort_events > abort_before);
        k = 0;
        while (thin_abort && k < 20) begin @(negedge clk); k = k + 1; end
        check_eq("H2g one refusal per refused request, not per clock",
                 guard_count - cnt_before, abort_events - abort_before);
        head_now = ring_head;
        check_eq("H2g the mismatched frame consumed no descriptor",
                 head_now, head_before);
        // Same recovery: clear the fault and let the armed profile's own frame cross.
        thin_bus_sub = 1'b0;
        thin_frame_finish("H2g-recover", 11520 * 2160);
        check_eq("H2g geometry after the mismatch is the armed one",
                 hs_bus[175:160], 11520);
        check_eq("H2g engine width after the mismatch is pixels",
                 eng_line_latched, 11520);
        check_eq("H2g engine pitch after the mismatch", eng_pitch_latched, 11520);
        check_eq("H2g frame after a mismatch retired",     frame_count - frames_before, 1);

        // ---- H2h NEGATIVE CONTROL: guard compiled out --------------------
        thin_active = 1'b0;
        @(negedge clk);
        desc_format = 4'd0; desc_planes = 4'd2;
        desc_w = 1920; desc_h = 1080; desc_s = 3840;
        desc_valid = 1'b1; i = 0;
        while (!off_send && i < 20) begin @(negedge clk); i = i + 1; end
        check("H2h ungated arbiter LAUNCHES the unsafe descriptor", off_send);
        check_eq("H2h ungated bus carries the legacy format", off_bus[244:241], 0);
        check_eq("H2h ungated bus carries the legacy width",  off_bus[143:128], 1920);
        check("H2h ungated arbiter reports no sticky",    !off_sticky);
        check_eq("H2h ungated refusal counter stays zero",  off_count, 0);
        check("H2h ungated guard reports format ok",       off_fmt_ok);
        check("H2h guarded arbiter refuses the same descriptor", !hs_send);
        @(negedge clk); desc_valid = 1'b0;
        release_crossing;
        @(negedge clk); frame_done = 1'b1;
        @(negedge clk); frame_done = 1'b0;

        $display("ARB_TB checks=%0d errors=%0d guard_count=%0d launches=%0d frames=%0d drops=%0d",
                 checks, errors, guard_count, launch_events, frame_count, drop_count);
        if (errors == 0) $display("SC7F0_VIDEO_LAUNCH_ARB_PASS");
        else             $display("SC7F0_VIDEO_LAUNCH_ARB_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #4_000_000;
        $display("ARB_TB TIMEOUT errors=%0d checks=%0d", errors, checks);
        $display("SC7F0_VIDEO_LAUNCH_ARB_FAIL timeout");
        $finish;
    end
endmodule
