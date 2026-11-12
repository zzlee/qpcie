`timescale 1ns / 1ps
// ============================================================================
// sc7f0_hdmi_probe diagnostic-level testbench (the CDC-10 fix for bits [31:25]).
//
// Run:  vivado -mode batch -notrace -nojournal -source scripts/sim_sc7f0_reset_cdc.tcl
// (xsim, so the REAL xpm_cdc_array_single model is elaborated)
//
// WHY A SEPARATE TB
//   rtl/sc7f0_hdmi_probe.v used to push seven foreign-domain stream qualifiers
//   (rx_ss_video_tlast/tuser/tready/tvalid from the RX-SS video clock, and
//   phy_rx_axi4s_ch{0,1,2}_tvalid from phy_rxoutclk) into the single
//   xpm_cdc_array_single that carries the pl_clk0 bits, declared with
//   .src_clk(clk) and .SRC_INPUT_REG(0).  report_cdc produced six CDC-10 rows for
//   it.  They are now seven independent ASYNC_REG chains clocked by pl_clk0, and
//   u_pin_levels_cdc only re-registers bits that are already in that domain with
//   SRC_INPUT_REG(1).  tb/sc7f0_hdmi_probe_tb.sv predates the register map (it
//   still expects version 0x2610_2001, i.e. it cannot even pass today) and is
//   wired into no runner, so it cannot guard this.
//
// WHAT THIS PROVES (behavioural, falsifiable)
//   P1 mapping: each of the seven bits lands on the documented position of
//      reg_probe_pins, walked one at a time (a swap/reorder regression fails here).
//   P2 clock-timed: no bit of reg_probe_pins may change at a time that is not
//      caused by a pl_clk0 rising edge, although the sources come from two
//      unrelated clocks at arbitrary phase.  A raw bypass would change off-edge.
//   P3 no unknown value ever reaches reg_probe_pins while the sources toggle
//      faster than pl_clk0, and a level left stable is always reached again
//      (convergence, no stuck bit).
//   P4 bounded pipeline: a stable source change shows up within a bounded number
//      of pl_clk0 cycles, and never before the documented pipeline depth
//      (3 chain stages + 4 array_single stages = 7 edges), so it really is
//      registered and it really is taken from the third stage.
//   P5 recovery: stopping a producer clock and restarting it, and cycling the
//      probe's own reset, both recover the correct levels; the DDC edge counter
//      still counts afterwards (the read path is alive, not wedged).
//   P7 expected model: the documented pipeline is re-implemented in this file from
//      its specification (one 3FF chain per level, new sample enters [0] so the
//      reported tap is [2], then SRC_INPUT_REG(1) + DEST_SYNC_FF(3) = 4 more
//      edges), driven only by the TB's own input wires - never by reading the
//      design's own state.  reg_probe_pins[31:25] is compared with it on every
//      pl_clk0 cycle for the whole run.
//   P8 cycle-exact latency: when the source is flipped between pl_clk0 edges, the
//      level must reach the register on exactly the 7th edge and never earlier
//      (the first and second sample edges cannot possibly report the third
//      stage), and a level held for exactly one pl_clk0 cycle must arrive delayed
//      by 7 edges and one cycle wide.  A three-flop synchroniser is a DELAY LINE,
//      not a pulse filter, so the opposite claim is deliberately not made here.
//   P6 structural anchor + tap position, with its own non-vacuity counter: the
//      seven chain registers are referenced hierarchically (delete or rename one
//      and this file fails to elaborate), their contents must match the model, and
//      every chain must have been observed with its stages disagreeing, so the tap
//      check cannot be satisfied by a settled pipeline in which all stages happen
//      to read the same value.
//
// RETRACTED (kept for the record)
//   The first revision of this file claimed that P6 proved "each reported bit is
//   the third stage of its own ASYNC_REG chain".  It did not: it compared
//   u_probe.<chain>_sync[0] with reg_probe_pins[bit], i.e. the design against
//   itself, which is satisfied by whichever stage the RTL happens to tap.  That is
//   how rtl/sc7f0_hdmi_probe.v could tap the FIRST stage (`chain[0]`, the newest
//   sample) while this TB, the RTL comment and the release notes all said "third
//   stage", and still report a green PROBE_LEVEL_SIM_GATE_PASS.  The recorded PASS
//   is not evidence about the tap position.  See
//   docs/sc7f0_full_package_rebuild_20261111.md section 14.
//
// ROUND 26111202: THE SOURCE-DOMAIN CAPTURE STAGE (P9, and the restatements)
//   report_cdc of build/vcu-release-26111202-r1 still filed six Critical CDC-10
//   rows here, with Exception = None, and the same six endpoints were that round's
//   WNS holders (-2.760 / -1.631 ns at a 0.002 ns requirement).  The destination
//   chain was correct; what was missing was a register in the SOURCE domain: the
//   launch points are vendor content (u_hdmi_rx_ss v_vid_in_axi4s coupler / drop
//   logic on clkout2, u_vid_phy_controller xpm_array_single_DRU_CTRL_in_sync on
//   phy_rxoutclk) whose last element before the net is combinational.  rtl/
//   sc7f0_hdmi_probe.v now captures each level on its own source clock
//   (clk_rx_video = clkout2, clk_rxout = phy_rxoutclk) before the pl_clk0 chain.
//
//   That changes two statements this file used to make, and they are restated
//   rather than quietly kept:
//     * "a level is reported on exactly the 7th pl_clk0 edge after the stimulus"
//       was only exact because the pl_clk0 chain was the first register.  There is
//       now one capture in the producer clock before it, so the stimulus-to-register
//       latency is 7 or 8 pl_clk0 edges (P4 window, P8a window).  The CYCLE-EXACT
//       claim did not disappear, it moved: reg_probe_pins[31:25] must equal the
//       expected model on every pl_clk0 cycle (P7), and P9 proves the DUT's source
//       register is the model's m_cap, so "exactly PIPE_MIN pl_clk0 edges from the
//       source-domain capture edge" is measured, not asserted.
//     * "a one-pl_clk0-cycle pulse arrives, one cycle wide" (P8b) is no longer
//       true and is not claimed.  The producer clock re-times the level, so a level
//       that lasts one pl_clk0 cycle reaches the destination only when a pl_clk0
//       sampling edge falls inside the window the producer held it; otherwise it is
//       legitimately dropped.  P8b therefore sweeps one, two and three held cycles
//       and requires the DUT to agree with the model's own prediction in every case
//       (same first edge, same width), never to report before PIPE_MIN, and never
//       wider than the pipeline explains.  That is acceptable here because
//       reg_probe_pins is a LEVEL tap: the quantities that may not lose a beat are
//       counted in the producer domain and cross as Gray buses.
//   P9 additionally proves the new stage really is clock-timed: it may only change
//   at a posedge of its own producer clock, and with that clock stopped it must not
//   change while its input toggles (a raw bypass would follow the input off-clock).
//
// WHAT IT CANNOT PROVE (deliberately not over-claimed)
//   A Verilog simulator resolves every clocked capture to a definite value: it
//   cannot exhibit metastability, cannot report a recovery/removal violation, and
//   cannot show a first-stage flop going unresolved.  The metastability protection
//   here is a *structural* claim - one first-stage flop per signal, clocked by
//   pl_clk0, (* ASYNC_REG = "TRUE" *) on the chain, one independent chain per
//   signal, no cross-bit atomicity claimed - and it is only closed by that
//   attribute surviving into the netlist plus report_cdc showing no CDC-10/CDC-12
//   row into u_hdmi_probe.  That needs a real implementation run, which is out of
//   scope for this local gate.
// ============================================================================

module sc7f0_hdmi_probe_async_levels_tb;

    localparam [31:0] EXPECT_VERSION = 32'h2610_2201;
    // Documented pipeline depth, from the contract rather than from the RTL:
    //   3 stages: rxss_*_sync / phy_ch*_tvalid_sync are [2:0], new sample enters [0]
    //   4 stages: u_pin_levels_cdc SRC_INPUT_REG(1) + DEST_SYNC_FF(3)
    // = 7 pl_clk0 edges from the capturing edge to reg_probe_pins.
    localparam integer CHAIN_STAGES  = 3;
    localparam integer CDC_STAGES    = 4;
    localparam integer PIPE_MIN      = CHAIN_STAGES + CDC_STAGES;
    // One extra pl_clk0 edge may be consumed before the chain sees a level, because
    // the level is now first captured by its own (faster, unrelated-phase) source
    // clock.  Measured from the source-domain capture edge the pipeline is still
    // exactly PIPE_MIN; measured from the stimulus it is PIPE_MIN or PIPE_MIN+1.
    localparam integer PIPE_SRC      = 1;
    // With the asynchronous drive the producer clock may push the capture one
    // pl_clk0 edge later, and restarting a stopped producer clock adds another
    // half period (P5a).  The cycle-EXACT statement is made with the synchronous
    // drive in P8; here the bound is only a sanity window, and the discriminating
    // part is the lower bound PIPE_MIN: a first-stage tap would report 5 edges
    // after the capture, a second-stage tap 6.
    localparam integer PIPE_SLACK    = 3;
    localparam integer LATENCY_LIMIT = PIPE_MIN + PIPE_SLACK;

    integer failures = 0;
    integer checks = 0;
    task automatic chk(input integer cond, input [8*104:1] name);
        begin
            checks = checks + 1;
            if (!cond) begin
                failures = failures + 1;
                $display("PROBE_LEVEL_CHECK_FAIL: %s", name);
            end else begin
                $display("PROBE_LEVEL_CHECK_PASS: %s", name);
            end
        end
    endtask

    // ---- pl_clk0: the declared source AND destination clock of the CDC ------
    reg clk = 0;
    always #5.0 clk = ~clk;
    reg rst_n = 0;
    time clk_last_posedge = 0;
    always @(posedge clk) clk_last_posedge = $time;

    // ---- the two real source domains of bits [31:25] -----------------------
    reg rxvid = 0, rxout = 0;
    reg rxvid_run = 1'b1, rxout_run = 1'b1;
    always begin #3.367 if (rxvid_run) rxvid = ~rxvid; end   // 148.5 MHz video
    always begin #1.687 if (rxout_run) rxout = ~rxout; end   // 297 MHz recovered

    // Timestamps of the last REAL rising edge of each producer clock, used by P9 to
    // prove that the new source-domain register moves only on its own clock.  When
    // rx*_run is 0 the generator does not toggle, so no edge is recorded and the
    // reference clock genuinely stood still.
    // The time of the last posedge of each producer clock.  `real`, not `time`:
    // these clocks have fractional periods (6.734 / 3.374 ns), and an integer
    // `time` rounds the edge instant, which made the off-edge check below report a
    // capture as "0.44 ns away from a posedge" when it was exactly on one.
    real rxvid_last_posedge = -1.0;
    real rxout_last_posedge = -1.0;
    always @(posedge rxvid) if (rxvid_run) rxvid_last_posedge = $realtime;
    always @(posedge rxout) if (rxout_run) rxout_last_posedge = $realtime;

    // Levels produced in those domains, registered on their own clock so every
    // transition lands at an arbitrary phase of pl_clk0 - the situation the probe
    // has to survive.
    reg lvl_tlast = 0, lvl_tuser = 0, lvl_tready = 0, lvl_tvalid = 0;
    reg lvl_ch2 = 0,   lvl_ch1 = 0,   lvl_ch0 = 0;
    reg d_tlast = 0, d_tuser = 0, d_tready = 0, d_tvalid = 0;
    reg d_ch2 = 0, d_ch1 = 0, d_ch0 = 0;
    always @(posedge rxvid) begin
        d_tlast  <= lvl_tlast;
        d_tuser  <= lvl_tuser;
        d_tready <= lvl_tready;
        d_tvalid <= lvl_tvalid;
    end
    always @(posedge rxout) begin
        d_ch2 <= lvl_ch2;
        d_ch1 <= lvl_ch1;
        d_ch0 <= lvl_ch0;
    end

    // ---- drive mux: two ways to stimulate the same seven levels ------------
    //   async (use_sync = 0): the level is captured by its own producer clock, so
    //     every transition lands at an arbitrary phase of pl_clk0 (P1..P5).
    //   sync  (use_sync = 1): the level only changes at a negedge of pl_clk0, so it
    //     is settled across exactly one posedge and the pipeline delay becomes
    //     cycle-exact (P8).  use_sync is only ever flipped at a negedge, and only
    //     while both drive sets already hold the same value, so the mux itself can
    //     neither race nor glitch a pl_clk0 edge.
    reg use_sync = 1'b0;
    reg [6:0] s_levels = 7'h00;        // {tlast,tuser,tready,tvalid,ch2,ch1,ch0}

    wire dri_tlast  = use_sync ? s_levels[6] : d_tlast;
    wire dri_tuser  = use_sync ? s_levels[5] : d_tuser;
    wire dri_tready = use_sync ? s_levels[4] : d_tready;
    wire dri_tvalid = use_sync ? s_levels[3] : d_tvalid;
    wire dri_ch2    = use_sync ? s_levels[2] : d_ch2;
    wire dri_ch1    = use_sync ? s_levels[1] : d_ch1;
    wire dri_ch0    = use_sync ? s_levels[0] : d_ch0;
    wire [6:0] dri_levels = {dri_tlast, dri_tuser, dri_tready, dri_tvalid,
                             dri_ch2, dri_ch1, dri_ch0};

    wire [31:0] reg_probe_pins;
    wire [31:0] reg_probe_version;
    wire [31:0] reg_probe_ddc_cnt;
    wire [6:0] pins7 = reg_probe_pins[31:25];

    reg hdmi_rx_5v_det = 0, hdmi_rx_hpd_out = 0;
    reg rx_ddc_scl_i = 1, rx_ddc_sda_i = 1;
    reg clk_rx_mgtref = 0, clk_dru_ref = 0;
    always #3.2 clk_rx_mgtref = ~clk_rx_mgtref;
    always #3.2 clk_dru_ref   = ~clk_dru_ref;

    sc7f0_hdmi_probe u_probe (
        .clk(clk),
        .rst_n(rst_n),

        .clk_rx_mgtref(clk_rx_mgtref),
        .clk_dru_ref(clk_dru_ref),
        .clk_rxout(rxout),
        .clk_rx_video(rxvid),
        .clk_tx_mgtref(1'b0),
        .clk_txout(1'b0),
        .clk_tx_video(1'b0),

        .hdmi_rx_5v_det(hdmi_rx_5v_det),
        .hdmi_rx_hpd_out(hdmi_rx_hpd_out),
        .rx_ddc_scl_i(rx_ddc_scl_i),
        .rx_ddc_scl_o(1'b1),
        .rx_ddc_scl_t(1'b1),
        .rx_ddc_sda_i(rx_ddc_sda_i),
        .rx_ddc_sda_o(1'b1),
        .rx_ddc_sda_t(1'b1),

        .hdmi_tx_hpd_in(1'b0),
        .hdmi_tx_refclk_rdy(1'b0),
        .tx_ddc_scl_i(1'b1),
        .tx_ddc_sda_i(1'b1),

        .hdmi_phy_irq(1'b0),
        .hdmi_rx_irq(1'b0),

        .phy_status_sb_rx_tdata(8'h0),
        .phy_status_sb_rx_tvalid(1'b0),
        .phy_rx_axi4s_ch0_tvalid(dri_ch0),
        .phy_rx_axi4s_ch1_tvalid(dri_ch1),
        .phy_rx_axi4s_ch2_tvalid(dri_ch2),

        .rx_ss_video_tvalid(dri_tvalid),
        .rx_ss_video_tuser(dri_tuser),
        .rx_ss_video_tlast(dri_tlast),
        .rx_ss_video_tready(dri_tready),

        .probe_ctrl(32'h0),

        .reg_probe_version(reg_probe_version),
        .reg_probe_rx_clk_freq(),
        .reg_probe_dru_clk_freq(),
        .reg_probe_rxoutclk_freq(),
        .reg_probe_rx_video_clk_freq(),
        .reg_probe_tx_clk_freq(),
        .reg_probe_txoutclk_freq(),
        .reg_probe_tx_video_clk_freq(),
        .reg_probe_pins(reg_probe_pins),
        .reg_probe_pulse_cnt1(),
        .reg_probe_ddc_cnt(reg_probe_ddc_cnt),
        .reg_probe_irq_cnt(),
        .reg_probe_ch0_beats(),
        .reg_probe_ch1_beats(),
        .reg_probe_ch2_beats(),
        .reg_probe_rx_video_sof(),
        .reg_probe_rx_video_eol(),
        .reg_probe_rx_video_pix(),
        .reg_probe_raw_rx_clk(),
        .reg_probe_raw_dru_clk(),
        .reg_probe_raw_rxoutclk(),
        .reg_probe_raw_rx_video_clk(),
        .reg_probe_raw_refclk100()
    );

    // ---- P7: independent expected model of the documented pipeline ----------
    // Written from the contract, NOT from the RTL, and fed only by the TB's own
    // drive wires (dri_levels), never by any state inside the DUT:
    //   * one 3FF chain per level, `chain <= {chain[1:0], src}` puts the new sample
    //     in [0], so the value the register must report is the THIRD stage [2];
    //   * u_pin_levels_cdc: SRC_INPUT_REG(1) + DEST_SYNC_FF(3) = 4 more edges, and
    //     it has no reset port, so its stages only drain (INIT_SYNC_FF(1) leaves
    //     them at 0, which is where this model starts too);
    //   * the chain itself does clear with the probe reset.
    // A tap on the first stage would therefore report 5 edges after the capture,
    // a tap on the second 6: both disagree with this model on the very first cycle
    // in which they differ from the correct stage, which is precisely what the old
    // self-referential P6 could not see.
    reg [2:0] m_chain [0:6];              // mirrors one three-stage chain
    reg [3:0] m_cdc   [0:6];              // mirrors the array_single drain
    reg [6:0] m_cap   = 7'h00;            // mirrors the source-domain capture stage
    // The DUT's own source registers, addressed hierarchically (renaming or
    // deleting one makes this file fail to elaborate) and reassembled in the
    // m_cap / dri_levels bit order.  Bit 4 (rx_ss_video_tready) is a don't-care:
    // that level is fed to its chain without a source stage, because its only
    // board-level driver is a constant (rtl/zu4ev_pcie_card_top.v:1053) and
    // report_cdc produced no crossing for it.
    wire [6:0] dut_cap = {u_probe.rxss_tlast_src,  u_probe.rxss_tuser_src,
                          1'b0,                    u_probe.rxss_tvalid_src,
                          u_probe.phy_ch2_tvalid_src, u_probe.phy_ch1_tvalid_src,
                          u_probe.phy_ch0_tvalid_src};
    wire [2:0] dut_cap_rxvid = {u_probe.rxss_tlast_src, u_probe.rxss_tuser_src,
                                u_probe.rxss_tvalid_src};
    wire [2:0] dut_cap_rxout = {u_probe.phy_ch2_tvalid_src,
                                u_probe.phy_ch1_tvalid_src,
                                u_probe.phy_ch0_tvalid_src};
    wire [20:0] dut_chains;              // hierarchical anchor, see P6
    wire [6:0] m_expected;
    integer mi;

    // chain k of {tlast,tuser,tready,tvalid,ch2,ch1,ch0} is dut_chains[3*(6-k) +: 3]
    assign dut_chains = {u_probe.rxss_tlast_sync,     u_probe.rxss_tuser_sync,
                         u_probe.rxss_tready_sync,    u_probe.rxss_tvalid_sync,
                         u_probe.phy_ch2_tvalid_sync, u_probe.phy_ch1_tvalid_sync,
                         u_probe.phy_ch0_tvalid_sync};
    assign m_expected = {m_cdc[0][CDC_STAGES-1], m_cdc[1][CDC_STAGES-1],
                         m_cdc[2][CDC_STAGES-1], m_cdc[3][CDC_STAGES-1],
                         m_cdc[4][CDC_STAGES-1], m_cdc[5][CDC_STAGES-1],
                         m_cdc[6][CDC_STAGES-1]};

    always @(posedge clk or negedge rst_n) begin
        // Faithful to the RTL flop: the chain is an asynchronous-reset register, so
        // it clears the moment rst_n falls, even when that coincides with a pl_clk0
        // edge.  A model that watched only posedge clk ended up one edge behind the
        // DUT in exactly that situation (caught by the first run of this TB).
        if (!rst_n) begin
            for (mi = 0; mi < 7; mi = mi + 1) m_chain[mi] <= 3'b000;
        end else begin
            // The chain is fed by the model's source-domain capture (m_cap), not by
            // the raw drive, for the six levels that have one.  Feeding the model
            // with dri_levels again would describe the pre-26111202 structure and
            // would then disagree with the design on every cycle in which a level
            // changed inside one producer period - which is exactly the disagreement
            // that makes this a check rather than a tautology.
            for (mi = 0; mi < 7; mi = mi + 1)
                m_chain[mi] <= {m_chain[mi][CHAIN_STAGES-2:0],
                                (mi == 2) ? dri_levels[4] : m_cap[6-mi]};
        end
    end

    // ---- P9 model of the source-domain capture stage -----------------------
    // Same producer clock, same input the DUT sees, written from the contract
    // ("one capture in the source clock, then the pl_clk0 chain"), never read back
    // from the design.  Indexing follows dri_levels: 6 tlast, 5 tuser, 4 tready,
    // 3 tvalid, 2 ch2, 1 ch1, 0 ch0.
    always @(posedge rxvid) begin
        m_cap[6] <= dri_levels[6];
        m_cap[5] <= dri_levels[5];
        m_cap[3] <= dri_levels[3];
    end
    always @(posedge rxout) begin
        m_cap[2] <= dri_levels[2];
        m_cap[1] <= dri_levels[1];
        m_cap[0] <= dri_levels[0];
    end

    always @(posedge clk) begin
        // The array_single has no reset port: it only keeps shifting, which is why a
        // probe reset visibly *drains* the register over 4 edges instead of clearing
        // it.  Both right-hand sides read pre-edge values, exactly as the netlist
        // does: array_single samples chain[2] as it stood before the edge.
        for (mi = 0; mi < 7; mi = mi + 1)
            m_cdc[mi] <= {m_cdc[mi][CDC_STAGES-2:0], m_chain[mi][CHAIN_STAGES-1]};
    end

    reg     model_on = 1'b0;
    integer model_checks = 0;          // pl_clk0 cycles the model was compared
    integer model_mismatches = 0;      // reg_probe_pins[31:25] != model
    integer chain_mismatches = 0;      // DUT chain contents != model chain
    integer cap_checks = 0;            // pl_clk0 cycles the capture stage was compared
    integer cap_mismatches = 0;        // DUT source register != model m_cap
    integer cap_changed [0:6];         // times each source register was seen to move
    integer src_off_edge = 0;          // a source register changed off its own clock
    integer src_stalled_changes = 0;   // it moved while its producer clock was stopped
    integer early_arrivals = 0;        // a level reported before PIPE_MIN edges
    integer stage_discriminated [0:6]; // cycles where [0] or [1] != [2]
    reg [2:0] dut_c;

    always @(negedge clk) begin
        if (model_on) begin
            model_checks = model_checks + 1;
            if (pins7 !== m_expected) begin
                model_mismatches = model_mismatches + 1;
                if (model_mismatches <= 5)
                    $display("BAD probe level tap: reg_probe_pins[31:25]=%b expected=%b (PIPE_MIN=%0d) at %0t",
                             pins7, m_expected, PIPE_MIN, $time);
            end
            for (mi = 0; mi < 7; mi = mi + 1) begin
                if (mi != 2) begin
                    // P9 identity: the DUT's source-domain register must hold what
                    // the model's capture of the same level on the same clock holds.
                    // This is what ties the cycle-exact statement to the new stage.
                    cap_checks = cap_checks + 1;
                    if (dut_cap[6-mi] !== m_cap[6-mi]) begin
                        cap_mismatches = cap_mismatches + 1;
                        if (cap_mismatches <= 5)
                            $display("BAD source capture %0d: DUT=%b model=%b at %0t",
                                     6-mi, dut_cap[6-mi], m_cap[6-mi], $time);
                    end
                end
                dut_c = dut_chains[3*(6-mi) +: 3];
                if (dut_c !== m_chain[mi]) begin
                    chain_mismatches = chain_mismatches + 1;
                    if (chain_mismatches <= 5)
                        $display("BAD chain %0d: DUT=%b model=%b at %0t",
                                 mi, dut_c, m_chain[mi], $time);
                end
                // Non-vacuity of the tap check: count the cycles in which a tap on
                // stage [0] or [1] would have reported something different from
                // [2].  A tap check that never sees the stages disagree proves
                // nothing about which stage is wired out.
                if (dut_c[0] !== dut_c[CHAIN_STAGES-1] ||
                    dut_c[1] !== dut_c[CHAIN_STAGES-1])
                    stage_discriminated[mi] = stage_discriminated[mi] + 1;
            end
        end
    end

    // ---- P2: the destination must only ever be clock-timed ------------------
    reg monitor_on = 1'b0;
    integer bad_off_edge = 0;
    real dt;
    always @(reg_probe_pins) begin
        if (monitor_on) begin
            dt = ($realtime - clk_last_posedge);
            // A legitimate update is a register update, i.e. simultaneous with a
            // posedge (same time step).  Anything in the middle of the cycle came
            // through an unregistered path.
            if (dt > 0.5 && dt < 9.5) begin
                bad_off_edge = bad_off_edge + 1;
                $display("BAD reg_probe_pins changed %0.3f ns away from a pl_clk0 edge: 0x%08x at %0t",
                         dt, reg_probe_pins, $realtime);
            end
        end
    end

    // ---- P9a: the source register may only move on its own producer clock ----
    reg [2:0] dut_cap_prev_rxvid = 3'b000;
    reg [2:0] dut_cap_prev_rxout = 3'b000;

    always @(dut_cap_rxvid) begin
        if (model_on && rxvid_last_posedge >= 0.0 &&
            (($realtime - rxvid_last_posedge) > 1e-9 ||
             ($realtime - rxvid_last_posedge) < -1e-9)) begin
            src_off_edge = src_off_edge + 1;
            $display("BAD clkout2 capture changed %0.3f ns away from a clk_rx_video posedge: %b at %0t", $realtime - rxvid_last_posedge, dut_cap_rxvid, $realtime);
        end
        if (model_on && rxvid_run) begin
            if (dut_cap_rxvid[2] !== dut_cap_prev_rxvid[2]) cap_changed[6] = cap_changed[6] + 1;
            if (dut_cap_rxvid[1] !== dut_cap_prev_rxvid[1]) cap_changed[5] = cap_changed[5] + 1;
            if (dut_cap_rxvid[0] !== dut_cap_prev_rxvid[0]) cap_changed[3] = cap_changed[3] + 1;
        end
        if (dut_cap_rxvid !== dut_cap_prev_rxvid && !rxvid_run) begin
            src_stalled_changes = src_stalled_changes + 1;
            $display("BAD clkout2 capture moved while clk_rx_video stood still: %b -> %b",
                     dut_cap_prev_rxvid, dut_cap_rxvid);
        end
        dut_cap_prev_rxvid = dut_cap_rxvid;
    end
    always @(dut_cap_rxout) begin
        if (model_on && rxout_last_posedge >= 0.0 &&
            (($realtime - rxout_last_posedge) > 1e-9 ||
             ($realtime - rxout_last_posedge) < -1e-9)) begin
            src_off_edge = src_off_edge + 1;
            $display("BAD phy_rxoutclk capture changed %0.3f ns away from a clk_rxout posedge: %b at %0t", $realtime - rxout_last_posedge, dut_cap_rxout, $realtime);
        end
        if (model_on && rxout_run) begin
            if (dut_cap_rxout[2] !== dut_cap_prev_rxout[2]) cap_changed[2] = cap_changed[2] + 1;
            if (dut_cap_rxout[1] !== dut_cap_prev_rxout[1]) cap_changed[1] = cap_changed[1] + 1;
            if (dut_cap_rxout[0] !== dut_cap_prev_rxout[0]) cap_changed[0] = cap_changed[0] + 1;
        end
        if (dut_cap_rxout !== dut_cap_prev_rxout && !rxout_run) begin
            src_stalled_changes = src_stalled_changes + 1;
            $display("BAD phy_rxoutclk capture moved while clk_rxout stood still: %b -> %b",
                     dut_cap_prev_rxout, dut_cap_rxout);
        end
        dut_cap_prev_rxout = dut_cap_rxout;
    end

    // ---- P3: never propagate an unknown value ------------------------------
    integer bad_x = 0;
    integer xb_i, xbit;
    always @(negedge clk) begin
        if (monitor_on) begin
            xbit = 0;
            for (xb_i = 0; xb_i < 32; xb_i = xb_i + 1)
                if (reg_probe_pins[xb_i] !== 1'b0 && reg_probe_pins[xb_i] !== 1'b1) xbit = 1;
            if (xbit) begin
                bad_x = bad_x + 1;
                $display("BAD reg_probe_pins holds an unknown value: %b at %0t",
                         reg_probe_pins, $time);
            end
        end
    end

    task automatic set_levels(input [6:0] v);
        begin
            // Move off the pl_clk0 edge grid first.  Two independent sampling
            // processes (the DUT chain and the expected model) that read a signal
            // changed in the Active region of the very same posedge can resolve it
            // differently - that is a stimulus race, not a design property, and the
            // first run of this TB hit exactly that.  All stimulus times are on a
            // 100 ps grid, so a 1 ps offset puts every change provably between two
            // pl_clk0 edges.
            #0.001;
            // v = {tlast,tuser,tready,tvalid,ch2,ch1,ch0} == reg_probe_pins[31:25]
            lvl_tlast  = v[6];
            lvl_tuser  = v[5];
            lvl_tready = v[4];
            lvl_tvalid = v[3];
            lvl_ch2    = v[2];
            lvl_ch1    = v[1];
            lvl_ch0    = v[0];
        end
    endtask

    integer lat;
    // Wait for the destination to converge.  `lat` counts pl_clk0 rising edges
    // starting with the first edge after the stimulus was applied, and that edge
    // is stage 1 of the chain, so the documented pipeline predicts exactly
    // PIPE_MIN (=7), or PIPE_MIN+1 if the producer clock pushes the capture one
    // pl_clk0 edge later.  Anything earlier means the reported level did not come
    // from the third stage.
    task automatic converge(input [6:0] exp);
        integer n;
        begin
            lat = -1;
            for (n = 1; n <= LATENCY_LIMIT && lat < 0; n = n + 1) begin
                @(posedge clk);
                if (pins7 === exp) lat = n;
            end
            $display("PROBE_LEVEL_LATENCY target=%b measured_pl_clk0_edges=%0d expected=%0d..%0d",
                     exp, lat, PIPE_MIN, PIPE_MIN + PIPE_SLACK);
        end
    endtask

    integer i, onehot;
    integer pn, first_edge, pulse_edges, pulse_first, pulse_last;
    integer pw, pe, p8b_arrivals, p8b_drops, m_width;
    reg [6:0] prev_levels = 7'h00;
    reg [6:0] cap_before_stall = 7'h00;
    reg [6:0] pins_before_stall = 7'h00;

    // Probe target for scripts/sim_sc7f0_reset_cdc.tcl.
    reg gate_pass = 1'b0;

    initial begin
        for (mi = 0; mi < 7; mi = mi + 1) begin  // integer arrays do not self-zero
            stage_discriminated[mi] = 0;
            cap_changed[mi] = 0;
        end

        // ---- P0: level changes while the probe itself is in reset -----------
        set_levels(7'h7F);
        #120;
        chk(reg_probe_pins[31:16] === 16'h0000,
            "P0 no diagnostic level reaches the register while probe rst is asserted");

        // ---- P1/P4: release, then walk every bit position ------------------
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        chk(reg_probe_version === EXPECT_VERSION, "P0 probe register map version");
        monitor_on = 1'b1;
        model_on   = 1'b1;      // GSR has long released; both pipelines hold 0

        // Levels have been 7'h7F since before the reset release, so the capturing
        // edge is older than the reference point of converge(); only convergence
        // and agreement with the model are meaningful here.  The cycle-exact depth
        // is asserted with a synchronous stimulus in P8.
        converge(7'h7F);
        chk(pins7 === 7'h7F && lat >= 1 && lat <= LATENCY_LIMIT,
            "P4 the seven levels are captured once the probe reset is released");
        set_levels(7'h00);
        converge(7'h00);
        chk(pins7 === 7'h00 && lat >= PIPE_MIN && lat <= PIPE_MIN + PIPE_SLACK,
            "P1/P4 all levels low is reached on exactly the 3+4 stage delay");

        for (i = 0; i < 7; i = i + 1) begin
            onehot = (7'b1 << i);
            set_levels(onehot[6:0]);
            converge(onehot[6:0]);
            chk(pins7 === onehot[6:0] && lat >= PIPE_MIN && lat <= PIPE_MIN + PIPE_SLACK,
                "P1/P4/P7 one-hot level reaches its documented bit on the documented cycle");
        end

        set_levels(7'h7F);
        converge(7'h7F);
        chk(pins7 === 7'h7F, "P1 all seven levels high");
        set_levels(7'h5A);
        converge(7'h5A);
        chk(pins7 === 7'h5A, "P1 alternating level");

        // ---- P3: sources toggle faster than pl_clk0 ------------------------
        for (i = 0; i < 60; i = i + 1) begin
            #1.7 set_levels(7'h5A);
            #1.3 set_levels(7'h25);   // 7-bit complement of 7'h5A
        end
        set_levels(7'h00);
        converge(7'h00);
        chk(pins7 === 7'h00, "P3 converges back to a stable level after fast toggling");
        chk(bad_x == 0, "P3 no unknown value ever reached the pin register");
        chk(bad_off_edge == 0, "P2 pin register only ever changes on a pl_clk0 edge");

        // ---- P5a: producer clocks stop, then restart -----------------------
        set_levels(7'h7F);
        #20;
        rxvid_run = 1'b0;                 // RX-SS video clock stops mid-level
        rxout_run = 1'b0;                 // recovered clock stops too
        #200;
        chk(pins7 === 7'h7F,
            "P5a held levels survive a stopped producer clock");
        rxvid_run = 1'b1;
        rxout_run = 1'b1;                 // peer restart
        set_levels(7'h2C);
        converge(7'h2C);
        chk(pins7 === 7'h2C, "P5a levels update again after the producer clock restarts");

        // ---- P5b: cycle the probe's own reset and prove the path is alive --
        // Both reset transitions are applied at a negedge: releasing an asynchronous
        // reset in the Active region of a posedge lets the DUT and an independent
        // model of it disagree about which edge is the first capture.
        @(negedge clk);
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        chk(pins7 === 7'h00, "P5b chains clear when the probe reset asserts");
        @(negedge clk);
        rst_n = 1'b1;
        converge(7'h2C);
        chk(pins7 === 7'h2C && lat >= PIPE_MIN && lat <= PIPE_MIN + PIPE_SLACK,
            "P5b levels recover after the probe reset releases, on the 3+4 stage delay");
        for (i = 0; i < 3; i = i + 1) begin
            #60 rx_ddc_scl_i = 1'b0;      // one falling SCL edge each
            #60 rx_ddc_scl_i = 1'b1;
        end
        #60;
        chk(reg_probe_ddc_cnt[15:0] === 16'd3,
            "P5b DDC SCL falling-edge counter runs again after the reset cycle");

        // ---- P9: the source-domain capture stage ---------------------------
        // (a) identity with the model is checked every pl_clk0 cycle (cap_checks /
        //     cap_mismatches below), (b) it may only move on its own clock
        //     (src_off_edge), and (c) with that clock stopped it must not follow a
        //     toggling input at all, then it must work again after the restart.
        // (c) is the property a raw wire cannot fake: the level is sampled by the
        // producer clock, so nothing reaches the chain while that clock stands
        // still, and the following restart is the peer-restart case.
        set_levels(7'h00);
        converge(7'h00);
        repeat (LATENCY_LIMIT + 2) @(posedge clk);
        rxvid_run = 1'b0;                 // stop the clkout2 producer clock
        rxout_run = 1'b0;                 // and the phy_rxoutclk one
        #20;
        cap_before_stall = dut_cap;
        pins_before_stall = pins7;
        for (i = 0; i < 8; i = i + 1) begin
            #7 set_levels(i[2:0] & 7'h07);
            #5 set_levels(~i[2:0] & 7'h7F);
        end
        #40;
        chk(dut_cap === cap_before_stall,
            "P9 no source-domain capture follows its input while its clock is stopped");
        chk(pins7 === pins_before_stall,
            "P9 the pin register is frozen while both producer clocks are stopped");
        chk(src_stalled_changes == 0, "P9 internal stalled-change counter is clean");
        rxvid_run = 1'b1;                 // peer restart
        rxout_run = 1'b1;
        set_levels(7'h15);
        converge(7'h15);
        chk(pins7 === 7'h15 && dut_cap === m_cap &&
            m_cap[2] === 1'b1 && m_cap[0] === 1'b1 && m_cap[6] === 1'b0,
            "P9 the source stage and the chain both resume after the clock restarts");
        set_levels(7'h00);
        converge(7'h00);

        // ---- P8: cycle-exact pipeline, source flipped between pl_clk0 edges --
        // Hand the drive over to the deterministic source.  Both drive sets are
        // 7'h00 at the switch and the switch happens at a negedge, so neither the
        // mux nor the model can see a race.
        set_levels(7'h00);
        converge(7'h00);
        repeat (LATENCY_LIMIT + 2) @(posedge clk);
        @(negedge clk);
        s_levels = 7'h00;
        use_sync = 1'b1;
        repeat (LATENCY_LIMIT + 2) @(posedge clk);
        chk(pins7 === 7'h00 && m_expected === 7'h00 && model_mismatches == 0,
            "P8 deterministic drive takes over with the pipeline settled low");

        // P8a: a level must not be reported before the third stage plus the
        // array_single drain have both run out, i.e. never on the first or the
        // second sampling edge; with the source-domain capture in front of the
        // chain it appears on edge PIPE_MIN, or one edge later when the producer
        // clock captures the level after that pl_clk0 edge.  The cycle-EXACT part of
        // the claim is carried by P7 (every pl_clk0 cycle against the model) and by
        // P9a (that register is the model's capture), not by a single number here.
        prev_levels = 7'h00;
        for (i = 0; i < 7; i = i + 1) begin
            onehot = (7'b1 << i);
            @(negedge clk);
            s_levels = onehot[6:0];
            first_edge = -1;
            for (pn = 1; pn <= PIPE_MIN + 3; pn = pn + 1) begin
                @(posedge clk);
                #1;                        // sample the settled, post-edge value
                if (first_edge < 0 && pins7 === onehot[6:0]) first_edge = pn;
                if (pn < PIPE_MIN && pins7 !== prev_levels)
                    early_arrivals = early_arrivals + 1;
            end
            $display("PROBE_P8A bit=%0d level=%b first_reporting_edge=%0d expected=%0d..%0d",
                     25 + i, onehot[6:0], first_edge, PIPE_MIN, PIPE_MIN + PIPE_SRC);
            chk(first_edge == PIPE_MIN || first_edge == PIPE_MIN + PIPE_SRC,
                "P8a the level is reported on the 7th or 8th pl_clk0 edge, never earlier");
            prev_levels = onehot[6:0];
        end
        chk(early_arrivals == 0,
            "P8a no level is reported before 3 chain stages + 4 array_single stages");

        // P8b: a level held for one, two and three pl_clk0 cycles.
        //
        // This is the behaviour the crossing fix changed, so it is spelled out
        // instead of quietly kept as a passing slogan.  With a source-domain
        // capture in front of the chain, a short level is RE-TIMED by the producer
        // clock: it reaches the destination when a pl_clk0 sampling edge falls
        // inside the window the producer held it, and is legitimately DROPPED when
        // none does.  reg_probe_pins is a LEVEL tap; the quantities that must not
        // lose anything (beat / SOF / pixel counters) are counted in the producer
        // domain itself in rtl/sc7f0_hdmi_probe.v and cross in as Gray buses.
        // What may never happen is an early report, a report the model does not
        // predict, or a width the pipeline cannot explain.  Sweeping the width
        // makes both outcomes observable, so this cannot pass by vacuity.
        p8b_arrivals = 0;
        p8b_drops = 0;
        for (pw = 1; pw <= 3; pw = pw + 1) begin
            @(negedge clk);
            s_levels = 7'h08;                 // rx_ss_video_tvalid only
            pulse_edges = 0;
            pulse_first = -1;
            pulse_last = -1;
            first_edge = -1;                  // the model's own prediction
            m_width = 0;
            // Same anchor as P8a: pn counts pl_clk0 sampling edges from the moment
            // the stimulus was applied, so "never before PIPE_MIN" means the same
            // thing in both checks.  Clearing the drive at the negedge after the
            // pw-th sampling edge holds it for exactly pw pl_clk0 cycles.
            for (pn = 1; pn <= PIPE_MIN + 5; pn = pn + 1) begin
                @(posedge clk);
                if (pn == pw) begin
                    @(negedge clk);
                    s_levels = 7'h00;
                end
                #1;
                if (pins7 === 7'h08) begin
                    pulse_edges = pulse_edges + 1;
                    if (pulse_first < 0) pulse_first = pn;
                    pulse_last = pn;
                end
                if (m_expected === 7'h08) begin
                    m_width = m_width + 1;
                    if (first_edge < 0) first_edge = pn;
                end
            end
            $display("PROBE_P8B held_cycles=%0d dut_first=%0d dut_width=%0d model_first=%0d model_width=%0d allowed_first=%0d..%0d",
                     pw, pulse_first, pulse_edges, first_edge, m_width, PIPE_MIN,
                     PIPE_MIN + PIPE_SRC);
            chk(pulse_first == first_edge && pulse_edges == m_width,
                "P8b a short level is reported exactly when, and exactly as long, as the source-capture model says (never a phantom, never a loss the model did not predict)");
            chk((pulse_first < 0 || pulse_first >= PIPE_MIN) &&
                pulse_edges <= pw + PIPE_SRC,
                "P8b a short level is never reported before the chain depth, and never wider than the time it was held plus one re-timing cycle");
            if (pulse_first < 0) p8b_drops = p8b_drops + 1;
            else p8b_arrivals = p8b_arrivals + 1;
            repeat (LATENCY_LIMIT + 2) @(posedge clk);
        end
        chk(p8b_arrivals + p8b_drops == 3 && p8b_arrivals >= 1,
            "P8b the width sweep actually observed the pipeline (non-vacuity)");

        // ---- P6: structural anchor + tap position, and its own non-vacuity --
        // The previous P6 read `u_probe.rxss_tlast_sync[0] === reg_probe_pins[31]`,
        // i.e. the design against itself: any tap satisfied it, which is how a
        // first-stage tap passed while the check was named "third stage".  Three
        // independent obligations replace it:
        //   (a) the seven chains are referenced hierarchically, so renaming or
        //       deleting one makes this file fail to elaborate;
        //   (b) their contents must equal the independent model every cycle, and
        //       reg_probe_pins[31:25] must equal the model's 3+4 edge drain;
        //   (c) every chain must have been observed in a state where a tap on [0]
        //       or [1] would have reported a different value, so (b) cannot be
        //       bought with a settled pipeline.
        repeat (20) @(posedge clk);
        $display("PROBE_CHAIN_STAGES tlast=%b tuser=%b tready=%b tvalid=%b ch2=%b ch1=%b ch0=%b",
                 u_probe.rxss_tlast_sync,  u_probe.rxss_tuser_sync,
                 u_probe.rxss_tready_sync, u_probe.rxss_tvalid_sync,
                 u_probe.phy_ch2_tvalid_sync, u_probe.phy_ch1_tvalid_sync,
                 u_probe.phy_ch0_tvalid_sync);
        $display("PROBE_TAP_DISCRIMINATION cycles_with_stages_disagreeing tlast=%0d tuser=%0d tready=%0d tvalid=%0d ch2=%0d ch1=%0d ch0=%0d",
                 stage_discriminated[0], stage_discriminated[1], stage_discriminated[2],
                 stage_discriminated[3], stage_discriminated[4], stage_discriminated[5],
                 stage_discriminated[6]);
        chk(model_checks > 200 && model_mismatches == 0,
            "P6/P7 reg_probe_pins[31:25] equals the expected model on every pl_clk0 cycle");
        chk(chain_mismatches == 0,
            "P6 each chain holds what the expected model says it holds");
        chk(stage_discriminated[0] > 0 && stage_discriminated[1] > 0 &&
            stage_discriminated[2] > 0 && stage_discriminated[3] > 0 &&
            stage_discriminated[4] > 0 && stage_discriminated[5] > 0 &&
            stage_discriminated[6] > 0,
            "P6 every chain was seen with its stages disagreeing, so the tap is observable");

        // ---- P9 verdict part: the source-domain capture stage ---------------
        // cap_changed is only demanded for the six levels that have a source
        // register: rx_ss_video_tready has none on purpose (constant driver at the
        // top level, no CDC row), so index 2 is excluded instead of being padded
        // out with a stage that would be optimised away.
        $display("PROBE_SOURCE_CHANGES tlast=%0d tuser=%0d tvalid=%0d ch2=%0d ch1=%0d ch0=%0d",
                 cap_changed[6], cap_changed[5], cap_changed[3],
                 cap_changed[2], cap_changed[1], cap_changed[0]);
        $display("PROBE_SOURCE_CAPTURE dut=%b model=%b", dut_cap, m_cap);
        chk(cap_checks > 200 && cap_mismatches == 0,
            "P9 the source-domain registers equal the model on every pl_clk0 cycle");
        chk(src_off_edge == 0,
            "P9 every source register moved only at a posedge of its own clock");
        chk(cap_changed[6] > 0 && cap_changed[5] > 0 && cap_changed[3] > 0 &&
            cap_changed[2] > 0 && cap_changed[1] > 0 && cap_changed[0] > 0,
            "P9 every source register was actually seen capturing (non-vacuity)");

        // ---- verdict -------------------------------------------------------
        $display("PROBE_LEVEL_SUMMARY checks=%0d failures=%0d bad_off_edge=%0d bad_x=%0d model_checks=%0d model_mismatches=%0d chain_mismatches=%0d early_arrivals=%0d cap_checks=%0d cap_mismatches=%0d src_off_edge=%0d src_stalled_changes=%0d",
                 checks, failures, bad_off_edge, bad_x, model_checks,
                 model_mismatches, chain_mismatches, early_arrivals,
                 cap_checks, cap_mismatches, src_off_edge, src_stalled_changes);
        if (failures == 0 && bad_off_edge == 0 && bad_x == 0 &&
            model_mismatches == 0 && chain_mismatches == 0 && early_arrivals == 0 &&
            cap_mismatches == 0 && src_off_edge == 0 && src_stalled_changes == 0 &&
            model_checks > 200 && cap_checks > 200 &&
            cap_changed[6] > 0 && cap_changed[5] > 0 && cap_changed[3] > 0 &&
            cap_changed[2] > 0 && cap_changed[1] > 0 && cap_changed[0] > 0 &&
            stage_discriminated[0] > 0 && stage_discriminated[1] > 0 &&
            stage_discriminated[2] > 0 && stage_discriminated[3] > 0 &&
            stage_discriminated[4] > 0 && stage_discriminated[5] > 0 &&
            stage_discriminated[6] > 0) begin
            $display("PROBE_LEVEL_SIM_GATE_PASS");
            gate_pass = 1'b1;
        end else begin
            $display("PROBE_LEVEL_SIM_GATE_FAIL");
            gate_pass = 1'b0;
        end
        #1;
        $finish;
    end

    initial begin
        #2000000;
        $display("PROBE_LEVEL_TB_FAIL global timeout");
        $fatal(1, "PROBE_LEVEL_TB_FAIL global timeout");
    end
endmodule
