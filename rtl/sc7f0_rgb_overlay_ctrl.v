`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_rgb_overlay_ctrl  (personality SC7F0-RGB-COMPOSITOR-2PPC)
//
// AXI4-Lite control / status window for the plan-A overlay path:
//
//   csr_clk (PS pl_clk0, 100 MHz, axi_crossbar_hdmi M09 @ 0xB00A0000)
//        |  axi_clock_converter_0  (AXI4-Lite re-timing, same idiom as
//        v                          rtl/sc7f0_display_pipeline.v)
//   pcie_user_clk (125 MHz) -> register file
//
// The register file deliberately lives in the PCIe user clock, i.e. in the
// SAME domain as rtl/sc7f0_overlay_ingress.v and the PCIe side of
// rtl/sc7f0_overlay_writer.v.  Every transfer counter, the tag-quarantine
// level and the per-slot state are therefore read exactly, with no wide
// asynchronous bus and no Gray code: the ingress makes "did this plane
// complete correctly" a question that must never be answered from a
// synchronised approximation.
//
// Only the compositor control (blend enable / alpha force-opaque / unlock and
// the Reader-B reset) belongs to the 300 MHz memory domain; each of those is a
// quasi-static LEVEL and crosses on its own xpm_cdc_single, so a plane can be
// enabled, frozen or re-locked at run time without any glitch reaching the
// blend stage.  Reader-B reset is additionally synchronised and stretched in
// mem_clk by rtl/sc7f0_reset_sync at the point of use, never here.
//
// Register map (4 KiB window, byte offsets):
//   0x00 CTRL        [0] ovl_enable          [1] ovl_go (level, arm on 0->1)
//                    [2] quiesce_req         [3] discard_pending
//                    [4] wr_enable           [5] wr_auto_advance
//                    [7:6] wr_force_slot     [10:8] wr_slot_count (1..4)
//   0x04 src_addr_lo        0x08 src_addr_hi      (host IOVA of the plane)
//   0x0C xfer_bytes         0x10 max_bytes_per_req (0 = IP default clamp)
//   0x14 wr_dst_base_lo     0x18 wr_dst_base_hi    (PS DDR, bits [48:0] used)
//   0x1C wr_slot_bytes      0x20 wr_frame_bytes    (4K RGBA32 = 33177600)
//   0x24 consume            one pulse per set bit releases that slot
//   0x30 COMP_CTRL         [0] blend_enable      [1] alpha_force_opaque
//                          [2] blend_unlock      [3] reader_b_reset
//   0x40 STATUS            [0] ovl_busy   [1] ovl_quiesced
//                          [2] tag_quarantined   [3] ext_tag_blocked
//                          [4] wr_busy    [7:5] wr_slot_ready[2:0]
//                          [8] wr_slot_ready[3] [9] blend_locked
//                          [10] blend_busy      [11] wr_irq_sticky
//                          [12] ovl_irq_sticky  [13] axis_ovf_sticky
//   0x44 STATUS2           [5:0] outstanding  [8:6] active_slot
//                          [13:9] sticky {ovl_err,unaligned,timeout,
//                                         wr_axi_err,wr_over,wr_stall,wr_misalign}
//   0x48 bytes_issued  0x4C bytes_staged  0x50 bytes_drained
//   0x54 wr_frames_done  0x58 wr_bytes_written  0x5C blend_beats
//   0x60 blend_lock_lost 0x64 blend_sat_watchdog
//   0x6C ABORT_STATUS     [0] ovl_abort_req pending   [1] wr_abort_busy
//   0x78 ID = 32'h52474231 ("RGB1") so software can prove it is talking to
//        this block and not to a decoded-but-absent aperture.
//
// ABI note (this revision): ID used to live at 0x6C, but 0x6C already had a
// case item in the same read mux (the abort status), and Verilog takes the
// FIRST matching case item, so the ID item was unreachable and software read 0
// - indistinguishable from a decoded-but-absent aperture.  0x6C keeps the
// meaning it already had (and which 0x68[2] already mirrors) and ID moves to
// the previously unused 0x78.  Both consumers (test_app/sc7f0_rgb_overlay.c and
// the device tree binding comment) were moved with it.
//
// Reset semantics required by the board contract: every control bit resets to
// 0, so after configuration the overlay data path is DISABLED and only starts
// when software writes it on.  The upgrade/programming H2C path is untouched
// by anything in here and never waits on it.
// ============================================================================

module sc7f0_rgb_overlay_ctrl (
    input  wire        csr_clk,
    input  wire        csr_rst_n,
    input  wire        pcie_clk,
    input  wire        pcie_rst_n,
    input  wire        mem_clk,
    input  wire        mem_rst_n,

    // ---- AXI4-Lite slave, csr_clk ----------------------------------------
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- overlay ingress arm / status (pcie_clk) --------------------------
    output reg         ovl_enable,
    output reg  [63:0] ovl_src_addr,
    output reg  [31:0] ovl_xfer_bytes,
    output reg  [15:0] ovl_max_bytes_per_req,
    output reg         ovl_go,
    output reg         ovl_quiesce_req,
    output reg         ovl_discard_pending,
    input  wire [31:0] ovl_bytes_issued,
    input  wire [31:0] ovl_bytes_staged,
    input  wire [31:0] ovl_bytes_drained,
    input  wire [5:0]  ovl_outstanding,
    input  wire        ovl_busy,
    input  wire        ovl_quiesced,
    input  wire        ovl_quarantined,
    input  wire        ovl_ext_tag_blocked,
    input  wire [31:0] ovl_counts,        // {.., ovf, err, unaligned, timeout}
    input  wire        ovl_done_pulse,    // one cycle per plane fully drained

    // ---- overlay plane writer (pcie_clk) ---------------------------------
    output reg         wr_enable,
    output reg  [48:0] wr_dst_base,
    output reg  [31:0] wr_slot_bytes,
    output reg  [2:0]  wr_slot_count,
    output reg  [31:0] wr_frame_bytes,
    output reg         wr_auto_advance,
    output reg  [1:0]  wr_force_slot,
    output reg  [3:0]  wr_consume,          // one-cycle pulse per write
    input  wire [3:0]  wr_slot_ready,
    input  wire        wr_busy,
    input  wire [1:0]  wr_active_slot,
    input  wire [31:0] wr_frames_done,
    input  wire [31:0] wr_bytes_written,
    input  wire [5:0]  wr_sticky,
    input  wire        wr_irq_pulse,
    // Review H1/M4: plane discard trigger, arm cross-check, and the fault counters
    // the driver needs to tell zero-data apart from suppressed-data.
    output reg         ovl_abort_req,       // one-cycle pulse, written by 0x28[0]
    input  wire        wr_abort_busy,       // writer is retiring a discarded plane
    input  wire [31:0] wr_err_frames,       // frames suppressed by a BRESP error
    input  wire        video_guard_sticky,  // H2: a legacy video arm was refused
    input  wire [31:0] video_guard_count,
    input  wire        video_poison,        // H1: abandoned tags still owed
    output reg         arm_mismatch_sticky, // 0x0C and 0x20 disagreed

    // ---- compositor control, levels on mem_clk ---------------------------
    output wire        blend_enable,
    output wire        alpha_force_opaque,
    output wire        blend_unlock,
    output wire        reader_b_reset,
    // blend status, same domain as the blend (levels)
    input  wire        blend_locked,
    input  wire        blend_busy,
    input  wire [31:0] blend_lock_lost,
    input  wire [31:0] blend_sat_watchdog,
    input  wire [31:0] blend_beats
);
    localparam [31:0] BLOCK_ID = 32'h5247_4231;   // "RGB1"

    // Control storage and synchronised status, declared up front so the
    // register file, the crossing stage and the read mux all refer to the same
    // objects.
    reg   blend_en_r, alpha_opaque_r, blend_unlock_r, reader_b_reset_r;
    reg  [3:0] consume_req;
    reg        consume_pulse;
    wire       blend_locked_c, blend_busy_c;
    // The three Gray-crossed counters must be nets, not variables: they are
    // driven by xpm_cdc_gray output ports and only ever *read* by the CSR read
    // mux below.  Declaring them `reg` (as they were) makes synthesis stop with
    // "Synth 8-685 variable 'blend_beats_c' should not be used in output port
    // connection", which is what killed the previous run.
    wire [31:0] blend_beats_c, blend_lock_lost_c, blend_sat_watchdog_c;

    // ------------------------------------------------------------------------
    // CSR crossing.  APROT is not routed by axi_crossbar_hdmi, same as every
    // other consumer of that crossbar in this design.
    // ------------------------------------------------------------------------
    wire [31:0] r_awaddr;
    wire [31:0] r_araddr;
    wire [31:0] r_wdata, r_rdata;
    wire [3:0]  r_wstrb;
    wire [1:0]  r_bresp, r_rresp;
    wire        r_awvalid, r_awready, r_wvalid, r_wready;
    wire        r_bvalid, r_bready, r_arvalid, r_arready;
    wire        r_rvalid, r_rready;

    axi_clock_converter_0 u_csr_cdc (
        .s_axi_aclk    (csr_clk),
        .s_axi_aresetn (csr_rst_n),
        .s_axi_awaddr  (s_axi_awaddr),  .s_axi_awprot (3'b000),
        .s_axi_awvalid (s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),   .s_axi_wstrb  (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),  .s_axi_wready (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),   .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),  .s_axi_arprot (3'b000),
        .s_axi_arvalid (s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),   .s_axi_rresp  (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),  .s_axi_rready (s_axi_rready),

        .m_axi_aclk    (pcie_clk),
        .m_axi_aresetn (pcie_rst_n),
        .m_axi_awaddr  (r_awaddr),  .m_axi_awprot (),
        .m_axi_awvalid (r_awvalid), .m_axi_awready(r_awready),
        .m_axi_wdata   (r_wdata),   .m_axi_wstrb  (r_wstrb),
        .m_axi_wvalid  (r_wvalid),  .m_axi_wready (r_wready),
        .m_axi_bresp   (r_bresp),   .m_axi_bvalid (r_bvalid),
        .m_axi_bready  (r_bready),
        .m_axi_araddr  (r_araddr),  .m_axi_arprot (),
        .m_axi_arvalid (r_arvalid), .m_axi_arready(r_arready),
        .m_axi_rdata   (r_rdata),   .m_axi_rresp  (r_rresp),
        .m_axi_rvalid  (r_rvalid),  .m_axi_rready (r_rready)
    );

    // ------------------------------------------------------------------------
    // Register file on pcie_clk.  AXI4-Lite write: AW and W are INDEPENDENT
    // channels and the standard imposes no ordering between them, so each is
    // latched on its own handshake and held until BOTH halves of that one
    // transaction are present; the register update then happens exactly once,
    // with the address / data / WSTRB that belong to the same transaction, and
    // BVALID is held until BREADY.  Only one write is outstanding at a time and
    // AWREADY/WREADY stay low while a half is still pending, so a back-pressured
    // lane can never be overwritten.
    //
    // This replaced `wr_strobe = awvalid && wvalid && awready && wready` over
    // `awready = ~aw_seen`, `wready = ~w_seen`, which could not work:
    //   * AW and W in the SAME cycle -> both handshakes fire, so the strobe
    //     fires too, but the register update used aw_addr_q / w_data_q, i.e. the
    //     PREVIOUS transaction's address and data, and the same strobe cleared
    //     both "seen" flags, so bvalid = aw_seen & w_seen never rose: the master
    //     waited for B forever.  On hardware this is what hung the interconnect
    //     and the debug transport on the first write ever issued to this
    //     aperture (0xB00A0030): the value landed at offset 0x00 as 0 and no B
    //     ever came back.
    //   * AW and W in DIFFERENT cycles -> both seen bits rise, so bvalid rises
    //     without any register having been written, and nothing clears the seen
    //     bits on the B handshake, so AWREADY/WREADY stay low and the NEXT write
    //     to the aperture (or to any master sharing that crossbar path) wedges.
    // Read is a simple single-beat AR/R.  No burst exists on AXI4-Lite and
    // DECERR is impossible inside the decoded window: unknown offsets read 0 and
    // write away, matching how every other aperture in this design behaves.
    // ------------------------------------------------------------------------
    reg        aw_hold, w_hold, b_pending;
    reg [31:0] aw_addr_q, w_data_q;
    reg [3:0]  w_strb_q;
    reg        r_valid_q;
    reg [31:0] r_data_q;
    reg [31:0] ctrl_new, comp_new, merge_new;  // strobe-merged write data, per commit

    // Byte-lane merge: a lane whose WSTRB bit is 0 keeps the current value of
    // that register, so a partial (or all-zero) strobe is a legal, side-effect
    // free write instead of corrupting the neighbouring bytes of the field.
    function [31:0] strb_merge;
        input [31:0] cur;      // current contents of the addressed register
        input [31:0] wdat;     // s_axi_wdata of this transaction
        input [3:0]  strb;     // s_axi_wstrb of this transaction
        strb_merge = { strb[3] ? wdat[31:24] : cur[31:24],
                       strb[2] ? wdat[23:16] : cur[23:16],
                       strb[1] ? wdat[15:8]  : cur[15:8],
                       strb[0] ? wdat[7:0]   : cur[7:0] };
    endfunction

    wire wr_strobe = aw_hold && w_hold && !b_pending;
    wire [11:0] wr_off = aw_addr_q[11:0];
    wire [11:0] rd_off = r_araddr[11:0];

    // writer irq / plane-complete levels, stretched so a read cannot miss them
    reg wr_irq_sticky, ovl_irq_sticky;

    always @(posedge pcie_clk or negedge pcie_rst_n) begin
        if (!pcie_rst_n) begin
            aw_hold <= 1'b0; w_hold <= 1'b0; b_pending <= 1'b0;
            aw_addr_q <= 32'd0; w_data_q <= 32'd0; w_strb_q <= 4'd0;
            r_valid_q <= 1'b0; r_data_q <= 32'd0;
            ovl_enable <= 1'b0; ovl_go <= 1'b0;
            ovl_abort_req <= 1'b0; arm_mismatch_sticky <= 1'b0;
            ovl_quiesce_req <= 1'b0; ovl_discard_pending <= 1'b0;
            ovl_src_addr <= 64'd0;
            ovl_xfer_bytes <= 32'd0;
            ovl_max_bytes_per_req <= 16'd0;
            wr_enable <= 1'b0; wr_auto_advance <= 1'b0;
            wr_dst_base <= 49'd0; wr_slot_bytes <= 32'd0;
            wr_slot_count <= 3'd1; wr_frame_bytes <= 32'd0;
            wr_force_slot <= 2'd0;
            blend_en_r <= 1'b0; alpha_opaque_r <= 1'b0;
            blend_unlock_r <= 1'b0; reader_b_reset_r <= 1'b0;
            consume_req <= 4'd0; consume_pulse <= 1'b1;
            wr_consume <= 4'd0;
            wr_irq_sticky <= 1'b0; ovl_irq_sticky <= 1'b0;
        end else begin
            // address / data capture: independent channels, either order, any
            // number of cycles apart; each half is held until it has been
            // committed, and its ready stays low meanwhile.
            if (r_awvalid && r_awready) begin aw_addr_q <= r_awaddr; aw_hold <= 1'b1; end
            if (r_wvalid  && r_wready ) begin w_data_q  <= r_wdata;
                                            w_strb_q    <= r_wstrb;  w_hold  <= 1'b1; end

            if (wr_strobe) begin
                aw_hold <= 1'b0; w_hold <= 1'b0; b_pending <= 1'b1;
                case (wr_off)
                    12'h000: begin
                        ctrl_new = strb_merge({21'd0, wr_slot_count, wr_force_slot,
                                               wr_auto_advance, wr_enable,
                                               ovl_discard_pending, ovl_quiesce_req,
                                               ovl_go, ovl_enable},
                                              w_data_q, w_strb_q);
                        ovl_enable          <= ctrl_new[0];
                        // M4: ovl_go may not be raised while the ingress byte count
                        // and the plane geometry disagree.  24,883,200 vs 33,177,600
                        // is not rounding: it is a plane that is truncated or that
                        // overruns the armed slot, and the only symptom used to be a
                        // wrong image.  The refusal is sticky and readable at 0x68[1];
                        // everything else stays usable, so software can rewrite
                        // 0x0C/0x20 and go again without a reset.
                        ovl_go              <= ctrl_new[1] &&
                            (ovl_go || (ovl_xfer_bytes == wr_frame_bytes));
                        if (ctrl_new[1] && !ovl_go &&
                            (ovl_xfer_bytes != wr_frame_bytes))
                            arm_mismatch_sticky <= 1'b1;
                        ovl_quiesce_req     <= ctrl_new[2];
                        ovl_discard_pending <= ctrl_new[3];
                        wr_enable           <= ctrl_new[4];
                        wr_auto_advance     <= ctrl_new[5];
                        wr_force_slot       <= ctrl_new[7:6];
                        // slot_count is documented as 1..4; the writer clamps
                        // again, but a 0 here would be meaningless, so keep 1.
                        wr_slot_count       <= (ctrl_new[10:8] == 3'd0) ? 3'd1
                                                       : ctrl_new[10:8];
                    end
                    12'h004: ovl_src_addr[31:0]  <= strb_merge(ovl_src_addr[31:0], w_data_q, w_strb_q);
                    12'h008: ovl_src_addr[63:32] <= strb_merge(ovl_src_addr[63:32], w_data_q, w_strb_q);
                    12'h00C: ovl_xfer_bytes      <= strb_merge(ovl_xfer_bytes, w_data_q, w_strb_q);
                    12'h010: begin
                        // Verilog-2001 has no part-select of a function-call
                        // result (round K attempt 1 died on exactly that in
                        // synth_verilog), so the merge lands in a temporary.
                        merge_new = strb_merge({16'd0, ovl_max_bytes_per_req},
                                               w_data_q, w_strb_q);
                        ovl_max_bytes_per_req <= merge_new[15:0];
                    end
                    12'h014: wr_dst_base[31:0]  <= strb_merge(wr_dst_base[31:0], w_data_q, w_strb_q);
                    12'h018: begin
                        merge_new = strb_merge({15'd0, wr_dst_base[48:32]},
                                               w_data_q, w_strb_q);
                        wr_dst_base[48:32] <= merge_new[16:0];
                    end
                    12'h01C: wr_slot_bytes          <= strb_merge(wr_slot_bytes, w_data_q, w_strb_q);
                    12'h020: wr_frame_bytes         <= strb_merge(wr_frame_bytes, w_data_q, w_strb_q);
                    12'h024: begin
                        // consume is in byte lane 0 only; a write with WSTRB[0]
                        // deasserted (or a no-op write) must not fire a pulse.
                        if (w_strb_q[0]) begin
                            consume_req   <= w_data_q[3:0];
                            consume_pulse <= 1'b1;
                        end
                    end
                    // Review H1: request a plane discard.  Writing 1 releases the
                    // ingress arm and tells the writer to retire the plane.  It is
                    // not stored as a permanent level (a level would refuse every
                    // later arm): it self-clears once the writer has acknowledged,
                    // and software observes retirement through CTRL 0x40[14], which
                    // mirrors ov_abort_busy - the statement that the payload FIFO,
                    // the intake counters and the upstream crossing are free of the
                    // dead plane.
                    12'h028: if (w_strb_q[0]) ovl_abort_req <= w_data_q[0];
                    12'h030: begin
                        comp_new = strb_merge({28'd0, reader_b_reset_r,
                                               blend_unlock_r, alpha_opaque_r,
                                               blend_en_r},
                                              w_data_q, w_strb_q);
                        blend_en_r       <= comp_new[0];
                        alpha_opaque_r   <= comp_new[1];
                        blend_unlock_r   <= comp_new[2];
                        reader_b_reset_r <= comp_new[3];
                    end
                    default: ;   // read-only or reserved
                endcase
            end

            // consume is a pulse, never a level: holding it would release the
            // slot every cycle and let the writer overwrite a plane the PS is
            // still compositing.
            if (consume_pulse) begin
                wr_consume    <= consume_req;
                consume_req   <= 4'd0;
                consume_pulse <= 1'b0;
            end else begin
                wr_consume <= 4'd0;
            end

            // B is held until the master takes it, and only then does the window
            // become able to commit the next write.
            if (r_bvalid && r_bready) b_pending <= 1'b0;

            if (wr_irq_pulse)       wr_irq_sticky  <= 1'b1;
            if (ovl_done_pulse)     ovl_irq_sticky <= 1'b1;
            if (ovl_abort_req && !wr_abort_busy) ovl_abort_req <= 1'b0;

            // single-beat read
            if (r_arvalid && r_arready && !r_valid_q) begin
                r_valid_q <= 1'b1;
                case (rd_off)
                    12'h000: r_data_q <= {21'd0, wr_slot_count, wr_force_slot,
                                          wr_auto_advance, wr_enable,
                                          ovl_discard_pending, ovl_quiesce_req,
                                          ovl_go, ovl_enable};
                    12'h004: r_data_q <= ovl_src_addr[31:0];
                    12'h008: r_data_q <= ovl_src_addr[63:32];
                    12'h00C: r_data_q <= ovl_xfer_bytes;
                    12'h010: r_data_q <= {16'd0, ovl_max_bytes_per_req};
                    12'h014: r_data_q <= wr_dst_base[31:0];
                    12'h018: r_data_q <= {15'd0, wr_dst_base[48:32]};
                    12'h01C: r_data_q <= wr_slot_bytes;
                    12'h020: r_data_q <= wr_frame_bytes;
                    // Review H1/H2: suppression and retirement state, deliberately
                    // kept out of 0x40/0x44 so no offset that software already reads
                    // changes meaning.  Read-only, and the stickies clear only with
                    // the block reset - there is no W1C here yet, which is the ABI
                    // decision this revision states out loud rather than freezes.
                    //   [0] video_guard_sticky : a channel-0 video descriptor that is
                    //                            not this profile's packed RGB24 (or is
                    //                            out of range / larger than the ring)
                    //                            was refused: zero C2H requests, and
                    //                            the common mailbox, programming,
                    //                            upgrade, MCU and readback paths all
                    //                            kept running
                    //   [1] arm_mismatch_sticky: 0x0C != 0x20 at a go attempt, refused
                    //   [2] wr_abort_busy      : plane retirement still in progress
                    //   [3] wr_sticky[4]       : a plane was discarded, no IRQ raised
                    //   [4] wr_sticky[5]       : a BRESP error cost a frame its publish
                    //   [5] video_poison       : abandoned overlay tags still owed;
                    //                            only their completions or a link
                    //                            barrier retire them, and arming stays
                    //                            refused until then
                    12'h024: r_data_q <= 32'd0;
                    12'h068: r_data_q <= {26'd0, video_poison, wr_sticky[5],
                                          wr_sticky[4], wr_abort_busy,
                                          arm_mismatch_sticky, video_guard_sticky};
                    // ABORT_STATUS.  This case item is the reason ID moved to
                    // 0x78: a duplicate label in one case statement is legal and
                    // the FIRST item wins, so the ID item below was dead code and
                    // software read 0.  Width is exactly 32 here (the previous
                    // 34-bit concatenation put both flags in bits 31:30).
                    12'h06C: r_data_q <= {30'd0, wr_abort_busy, ovl_abort_req};
                    12'h070: r_data_q <= video_guard_count;
                    12'h074: r_data_q <= wr_err_frames;
                    12'h030: r_data_q <= {28'd0, reader_b_reset_r, blend_unlock_r,
                                         alpha_opaque_r, blend_en_r};
                    12'h040: r_data_q <= {18'd0, ovl_irq_sticky, wr_irq_sticky,
                                          blend_busy_c, blend_locked_c,
                                          wr_slot_ready, wr_busy,
                                          ovl_ext_tag_blocked, ovl_quarantined,
                                          ovl_quiesced, ovl_busy};
                    12'h044: r_data_q <= {18'd0, ovl_counts[3:0], wr_sticky[3:0],
                                          wr_active_slot, ovl_outstanding};
                    12'h048: r_data_q <= ovl_bytes_issued;
                    12'h04C: r_data_q <= ovl_bytes_staged;
                    12'h050: r_data_q <= ovl_bytes_drained;
                    12'h054: r_data_q <= wr_frames_done;
                    12'h058: r_data_q <= wr_bytes_written;
                    12'h05C: r_data_q <= blend_beats_c;
                    12'h060: r_data_q <= blend_lock_lost_c;
                    12'h064: r_data_q <= blend_sat_watchdog_c;
                    12'h078: r_data_q <= BLOCK_ID;
                    default: r_data_q <= 32'd0;
                endcase
            end else if (r_valid_q && r_rready) begin
                r_valid_q <= 1'b0;
            end
        end
    end

    assign r_bresp  = 2'b00;
    assign r_rresp  = 2'b00;
    assign r_rdata  = r_data_q;
    assign r_rvalid = r_valid_q;
    // Ready stays low while the corresponding half of the pending transaction is
    // still held, so a second AW/W cannot overwrite it before it is committed.
    assign r_awready = ~aw_hold;
    assign r_wready  = ~w_hold;
    assign r_bvalid  = b_pending;          // accepted, no error possible
    assign r_arready = ~r_valid_q;

    // ------------------------------------------------------------------------
    // pcie_clk -> mem_clk.  All four are quasi-static control levels written
    // while the plane owner chooses the moment; each gets its own synchroniser
    // (rtl/sc7f0_reset_cdc.v documents why combining sources before a
    // synchroniser is the CDC pattern this tree was flagged for).
    // ------------------------------------------------------------------------
    wire blend_en_d,  blend_unlock_d, alpha_opaque_d, reader_b_reset_d;
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_blend_en (
        .src_clk(pcie_clk), .src_in(blend_en_r),
        .dest_clk(mem_clk), .dest_out(blend_en_d));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_blend_unlock (
        .src_clk(pcie_clk), .src_in(blend_unlock_r),
        .dest_clk(mem_clk), .dest_out(blend_unlock_d));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_alpha_opaque (
        .src_clk(pcie_clk), .src_in(alpha_opaque_r),
        .dest_clk(mem_clk), .dest_out(alpha_opaque_d));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_reader_b_reset (
        .src_clk(pcie_clk), .src_in(reader_b_reset_r),
        .dest_clk(mem_clk), .dest_out(reader_b_reset_d));

    // blend_enable must not come up asserted out of configuration: the blend
    // only ever runs because software asked for it.
    assign blend_enable       = blend_en_d;
    assign alpha_force_opaque = alpha_opaque_d;
    assign blend_unlock       = blend_unlock_d;
    assign reader_b_reset     = reader_b_reset_d;

    // ------------------------------------------------------------------------
    // mem_clk -> pcie_clk for the blend status levels, and Gray code for the
    // three blend counters so a read cannot return a torn value.
    // ------------------------------------------------------------------------
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_locked (
        .src_clk(mem_clk), .src_in(blend_locked),
        .dest_clk(pcie_clk), .dest_out(blend_locked_c));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_busy (
        .src_clk(mem_clk), .src_in(blend_busy),
        .dest_clk(pcie_clk), .dest_out(blend_busy_c));

    // The three blend counters cross as gray-encoded binary buses.
    //
    // Parameter set is taken from the shipped definition, not from memory:
    // /opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv:285 declares
    //   xpm_cdc_gray #(DEST_SYNC_FF, INIT_SYNC_FF, REG_OUTPUT, SIM_ASSERT_CHK,
    //                  SIM_LOSSLESS_GRAY_CHK, VERSION, WIDTH)
    //     (src_clk, src_in_bin, dest_clk, dest_out_bin)
    // There is NO INIT parameter (that is what failed the previous synthesis),
    // and the ports are BINARY in / BINARY out: the encode and the decode both
    // live inside the primitive.  So nothing here may pre-gray the value or
    // un-gray the result - doing so would break the one-bit-per-cycle property
    // the synchroniser relies on.  These three counters qualify: each is only
    // ever `count + 32'd1` and never reloaded or decremented
    // (rtl/sc7f0_alpha_blend_2ppc.v:296 beats_blended, :302 sat_watchdog_count,
    // :320 lock_lost_count), which is exactly the lossless +1/case, and the
    // destination copy is a read-back status value only.
    xpm_cdc_gray #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .WIDTH(32)) u_beats (
        .src_clk(mem_clk), .src_in_bin(blend_beats),
        .dest_clk(pcie_clk), .dest_out_bin(blend_beats_c));
    xpm_cdc_gray #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .WIDTH(32)) u_lost (
        .src_clk(mem_clk), .src_in_bin(blend_lock_lost),
        .dest_clk(pcie_clk), .dest_out_bin(blend_lock_lost_c));
    xpm_cdc_gray #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .WIDTH(32)) u_sat (
        .src_clk(mem_clk), .src_in_bin(blend_sat_watchdog),
        .dest_clk(pcie_clk), .dest_out_bin(blend_sat_watchdog_c));

endmodule
`default_nettype wire
