`default_nettype none
// ============================================================================
// Module: sc7f0_overlay_ingress
// Personality: SC7F0-RGB-COMPOSITOR-2PPC (instantiated only under
//              `SC7F0_RGB_COMPOSITOR`; every legacy profile elaborates the
//              untouched design).
//
// What it is
//   A real PCIe read client for the host -> overlay-slot data plane.  The host
//   lays RGBA8888 out in host memory; this engine issues Memory Reads on the same
//   RQ/RC interface the firmware upgrade path uses, reassembles the completions in
//   issue order, and hands rtl/sc7f0_overlay_writer.v a dense byte stream that it
//   lands in PS DDR for v_frmbuf_rd Reader-B.
//
// Why it exists (widths read out of the source, not out of a summary)
//   rtl/sg_dma_engine.v is the existing read client and its completion side is
//   128 bit: rtl/rc_rx_decoder.v emits at most h2c_fifo_wdata[127:0] plus a DWord
//   count, i.e. 128b x 125 MHz = 2.0 GB/s, and the writer behind it runs in the
//   100 MHz HP0 domain (128b x 100 MHz = 1.6 GB/s).  Moving only the writer to
//   300 MHz cannot recover the intake side.  Here the payload is taken natively at
//   256 bit in the 125 MHz user domain (256b x 125 MHz = 4.0 GB/s), staged in one
//   byte-enabled BRAM, drained in issue order and crossed by ONE 256-bit-write /
//   128-bit-read async FIFO into the 300 MHz memory domain (128b x 300 MHz =
//   4.8 GB/s).  No stage running at 125 MHz is narrower than the bus.
//
// Tag contract (from rtl/pcie_tag_manager.v, rtl/rc_rx_decoder.v and
// rtl/custom_pcie_dma_top.v)
//   tag 0            CH0 thin descriptor fetch
//   tag 1            SG host linked-list fetch
//   tag 32 (0x20)    CH1 64-byte descriptor fetch (hard-coded route)
//   tags 2..MAX_TAGS-1 (MAX_TAGS=64) are handed out by the shared allocator and
//   route to the H2C data FIFO.
//   This engine owns a separate bitmap over OVL_TAG_BASE..+OVL_TAG_COUNT-1
//   (default 64..127), so a descriptor, SG or upgrade tag can never appear here
//   and an overlay tag can never be handed to the legacy allocator.  Tags above 31
//   require the PCIe Extended Tag Field, which this design already depends on
//   (tag 0x20); the counters below make a root complex that rejects them visible
//   instead of silent, and the base/count are parameters so a build that must stay
//   inside 0..31 needs no logic change.
//
// Request rules
//   * address 4-byte aligned, DWord count >= 1, never past the next 4 KB
//     boundary, never above max_bytes_per_req (CSR, clamped to 4096), never past
//     the end of the armed transfer;
//   * first_be / last_be derived from the address and the byte length, so a head-
//     or tail-unaligned arm is expressed exactly rather than rounded;
//   * at most NSLOT reads outstanding, one reorder entry each;
//   * MRd issue is the LOWEST priority read in rtl/rq_tx_encoder.v, so descriptor
//     fetch, SG fetch and programming H2C reads always win over the overlay.
//
// Completion rules
//   * routed by tag from rtl/rc_rx_decoder.v's additive overlay route, which
//     delivers DWord-aligned payload natively (256-bit data + DWord count + last);
//     nothing is narrowed and nothing is padded into the byte stream;
//   * CAM match against the live entries.  A completion whose tag is not live
//     (never issued, already retired) is counted and dropped; one whose data would
//     pass the byte count it was issued for is counted and dropped.  Neither can
//     write into another request's staging space;
//   * an entry retires only when exactly its issued byte count has arrived, so a
//     read completed as several CplDs (RCB 64 B) is not mistaken for finished;
//   * staging drains strictly in issue order, so PS DDR receives the byte image
//     the host laid out regardless of completion order;
//   * bounded stall: TIMEOUT_CYCLES with something outstanding and no progress
//     aborts the transfer and reports, instead of holding the shared RC path.
//
// Quiesce (this is what protects the programming / upgrade path)
//   `quiesce` stops new MRd issue immediately but never drops outstanding
//   transactions: reads already on the wire are still consumed from RC, their data
//   is drained (or discarded when discard_pending is set) and every allocated tag
//   is freed before ovl_quiesced reports 1.  Abandoning completions the root
//   complex is still sending, or leaking tags, is exactly what would damage the
//   upgrade path.
//
// CDC discipline
//   One block-RAM async FIFO (256b write @125, 128b read @300, fwft) carries the
//   payload; everything else is a single-bit level through a two-flop
//   synchroniser.  Resets come from rtl/sc7f0_reset_cdc.v's sc7f0_reset_sync: one
//   crossing per asynchronous source per clock, combined only in-domain, as in
//   rtl/sc7f0_rgb24_axis_pack.v and rtl/sc7f0_dp_fifo.v.
//
// Trailing bytes
//   A 256-bit write word always yields two 128-bit read words, so the final word
//   of a transfer can carry bytes past the armed length.  They are never written
//   to memory: rtl/sc7f0_overlay_writer.v retires on its own ov_frame_bytes count
//   and raises ov_over_sticky on anything past the end, so the exact length is
//   enforced where it becomes a memory write.
// ============================================================================
`timescale 1ns / 1ps

module sc7f0_overlay_ingress #(
    parameter integer OVL_TAG_BASE    = 64,     // disjoint from the legacy 0..63
    parameter integer OVL_TAG_COUNT   = 64,     // live tags BASE..BASE+COUNT-1
    parameter integer NSLOT           = 8,      // reorder entries = outstanding
    parameter integer SLOT_BYTES      = 2048,   // >= host Max_Read_Request_Size
    parameter integer FIFO_DEPTH      = 64,     // 64 x 256 bit = 2 kB
    parameter [15:0] MAX_REQ_CLAMP   = 16'd4096,
    parameter [31:0]  TIMEOUT_CYCLES  = 32'd12_500_000   // ~100 ms at 125 MHz
)(
    // ---- PCIe user clock domain (125 MHz) --------------------------------
    input  wire                     clk,
    input  wire                     rst_n,
    // Review H1: the ledger's reset is NOT this block's working reset.
    // custom_pcie_dma_top builds dma_rst_n from sc7f0_reset_sync({
    // global_reset_hold_n, !reg_dma_ctrl[1], rst_n}) (rtl/custom_pcie_dma_top.v:534-
    // 569), so dma_rst_n drops on a BAR0[0x14] global flush and on clearing
    // reg_dma_ctrl[1] - both are SOFTWARE flushes that do nothing whatever to the
    // reads the root complex already has.  If the ledger shared that reset, one
    // soft flush would launder every owed tag: busy_bitmap is cleared by the same
    // reset, the next arm would re-hand those tags, and the old completions would
    // still arrive.  epoch_rst_n is the PCIe user epoch (pcie_user_rst_n at the card,
    // = user_lnk_up && ~user_reset), the only boundary at which the host's
    // outstanding requests are known to be gone.
    input  wire                     epoch_rst_n,

    // transfer arm: quasi-static registers, armed by a go transition
    input  wire                     ovl_enable,
    input  wire [63:0]              ovl_src_addr,      // host IOVA, 4 B aligned
    input  wire [31:0]              ovl_xfer_bytes,
    input  wire [15:0]              ovl_max_bytes_per_req,
    input  wire                     ovl_go,
    // pause vs discard are different: quiesce alone only stops issuing new MRd, the
    // in-flight plane still completes; discard_pending is what drops payload.
    input  wire                     quiesce,
    input  wire                     discard_pending,

    // MRd client towards rtl/rq_tx_encoder.v
    output reg                      mrd_req_valid,
    output reg  [63:0]              mrd_req_addr,
    output reg  [10:0]              mrd_req_dw_len,
    output reg  [7:0]               mrd_req_tag,
    output reg  [3:0]               mrd_req_first_be,
    output reg  [3:0]               mrd_req_last_be,
    input  wire                     mrd_req_ack,

    // native completion route from rtl/rc_rx_decoder.v
    input  wire                     ovl_cpl_valid,
    input  wire [255:0]             ovl_cpl_data,
    input  wire [3:0]               ovl_cpl_dw_count,  // 1..8 DWords this beat
    input  wire                     ovl_cpl_last,
    input  wire [7:0]               ovl_cpl_tag,

    // status, PCIe domain
    output reg  [31:0]              ovl_bytes_issued,
    output reg  [31:0]              ovl_bytes_staged,
    output reg  [31:0]              ovl_bytes_drained,
    output reg  [5:0]               ovl_outstanding,
    output reg                      ovl_busy,
    output reg                      ovl_quiesced,
    output reg  [31:0]              ovl_unexpected_count,
    output reg  [31:0]              ovl_overflow_count,
    output reg  [31:0]              ovl_split_count,
    output reg  [31:0]              ovl_abort_count,
    output reg                      ovl_timeout_sticky,
    output reg                      ovl_unaligned_sticky,
    output reg                      ovl_quarantined,   // tags owed, not reusable
    output reg                      ovl_poison_sticky, // an abort left tags owed
    output reg                      ovl_abort_evt,     // 1 cycle: plane abandoned
    output reg                      ovl_err_sticky,
    output reg                      ovl_done_pulse,

    // ---- memory clock domain (300 MHz): dense 128-bit byte stream --------
    input  wire                     mem_clk,
    input  wire                     mem_rst_n,
    output wire [127:0]             m_axis_tdata,
    output wire                     m_axis_tuser,      // first beat since an arm
    output wire                     m_axis_tvalid,
    input  wire                     m_axis_tready,
    output wire [7:0]               m_axis_avail,
    output wire                     m_axis_ovf_sticky
);
    localparam integer SLOT_WORDS = SLOT_BYTES / 32;          // 32 B words
    localparam integer SW_AW      = $clog2(SLOT_WORDS);       // words per slot
    localparam integer IDX_AW     = (NSLOT <= 1) ? 1 : $clog2(NSLOT);
    localparam integer RAM_WORDS  = NSLOT * SLOT_WORDS;
    localparam integer RAM_AW     = $clog2(RAM_WORDS);
    localparam integer WDQ        = $clog2(FIFO_DEPTH) + 1;
    localparam integer RDQ        = $clog2(FIFO_DEPTH*2) + 1;

    // ------------------------------------------------------------------------
    // resets
    // ------------------------------------------------------------------------
    wire p_all_n, m_all_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_p_reset (
        .dest_clk(clk),     .src_rst_n({mem_rst_n, rst_n}), .dest_rst_n(p_all_n));
    sc7f0_reset_sync #(.SOURCES(2)) u_m_reset (
        .dest_clk(mem_clk), .src_rst_n({rst_n, mem_rst_n}), .dest_rst_n(m_all_n));
    wire p_rst = !p_all_n;
    wire m_rst = !m_all_n;

    // ------------------------------------------------------------------------
    // FIFO ports and staging storage declared up front (default_nettype none)
    // ------------------------------------------------------------------------
    reg              fifo_wen;
    reg  [255:0]     fifo_wdata;
    wire             fifo_full, fifo_wr_busy, fifo_empty, fifo_rd_busy;
    wire             fifo_ovf;
    wire [127:0]     fifo_dout;
    wire [RDQ-1:0]   fifo_rd_count;

    // Staging store: eight INDEPENDENT 32-bit banks, one write port each.
    //
    // It used to be a single 256-bit memory with a 32-bit write enable.  That
    // shape can only ever touch ONE 32-byte row per cycle, so a completion beat
    // whose payload does not start at lane 0 had nowhere to put the DWords that
    // ran past lane 7: they fell off the end of a left-shift, and the low lanes
    // of the following row kept whatever an earlier transfer had left there.
    // Measured on hardware that is exactly the "lanes 0..3 of the row retain old
    // frame content, lanes 4..7 are displaced by one DWord" signature.
    //
    // Eight banks let the wrapped DWords land in row+1 in the SAME cycle, so no
    // back-pressure is added to the RC stream, no second wide write port and no
    // extra buffering is needed, the total storage bits are unchanged, and the
    // read side still presents one 256-bit row with the same registered
    // single-cycle latency.  The drain, the forward/room2 headroom rule, the
    // poison/discard paths and every M10 ownership rule are untouched: only the
    // physical partitioning of the write port changed.
    reg  [31:0]      stage_b0 [0:RAM_WORDS-1];
    reg  [31:0]      stage_b1 [0:RAM_WORDS-1];
    reg  [31:0]      stage_b2 [0:RAM_WORDS-1];
    reg  [31:0]      stage_b3 [0:RAM_WORDS-1];
    reg  [31:0]      stage_b4 [0:RAM_WORDS-1];
    reg  [31:0]      stage_b5 [0:RAM_WORDS-1];
    reg  [31:0]      stage_b6 [0:RAM_WORDS-1];
    reg  [31:0]      stage_b7 [0:RAM_WORDS-1];
    reg              ram_wen;
    reg  [RAM_AW:0]  ram_wrow;   // zero-extended base row of this beat
    reg  [255:0]     ram_wrot;   // rotated payload: lane b holds its own DWord
    reg  [7:0]       ram_wpl;    // lane b carries a DWord of this beat
    reg  [7:0]       ram_whi;    // lane b wrapped past lane 7, so it is row+1
    reg  [255:0]     ram_rdata;

    // reorder entries; entry index == staging slot == ring position
    reg  [IDX_AW:0]  n_live;          // entries issued and not yet drained
    reg              e_live  [0:NSLOT-1];
    reg  [7:0]       e_tag   [0:NSLOT-1];
    reg  [31:0]      e_exp   [0:NSLOT-1];
    reg  [31:0]      e_got   [0:NSLOT-1];
    reg              e_ready [0:NSLOT-1];
    reg  [OVL_TAG_COUNT-1:0] busy_bitmap;
    // ------------------------------------------------------------------------
    // Issued-flight ownership ledger (epoch domain).  Replaces two earlier designs,
    // both of which were wrong:
    //   (a) a finite quiet window that released quarantined tags after N idle cycles
    //       - elapsed time is not evidence that a completion is not coming;
    //   (b) copying e_live/e_exp/e_got into a ledger at the moment of abort.  Both
    //       the abort and the issue/drain updates live in the SAME clocked block, so
    //       at the abort edge the copy reads the PRE-UPDATE state, and a soft reset
    //       (dma_rst_n, which BAR0[0x14] or clearing reg_dma_ctrl[1] asserts) clears
    //       e_live asynchronously relative to any later copy.  Either way the debt
    //       can be lost exactly when it matters.
    // This ledger is booked at the one instant that cannot be argued about: the cycle
    // the request encoder acknowledges the MRd (accepted = mrd_req_valid &&
    // mrd_req_ack).  From then until every issued byte of that tag has come back,
    // this block owes a read, independent of the reorder slots, of the arm, and of
    // any datapath reset - the ledger is reset ONLY by epoch_rst_n, the PCIe user
    // epoch.  An abandoned transfer simply relabels its in-flight entries as debt;
    // nothing has to be copied, so nothing can be copied too late.
    // ------------------------------------------------------------------------
    localparam integer IFL = NSLOT;      // at most NSLOT requests are outstanding
    reg               ifl_live [0:IFL-1];
    reg               ifl_dead [0:IFL-1];   // owned by an abandoned transfer
    reg  [7:0]        ifl_tag  [0:IFL-1];
    reg  [31:0]       ifl_owed [0:IFL-1];
    // Tag space held by dead debt.  Kept separate from busy_bitmap because
    // busy_bitmap lives in the working reset domain (dma_rst_n) and would be wiped
    // by a soft flush; dead_busy lives with the ledger.
    reg  [OVL_TAG_COUNT-1:0] dead_busy;
    reg              ifl_found;   // loop helper inside the ledger commit branch
    reg              poison_sticky_r;
    // one-cycle events from the working domain into the ledger
    reg              commit_evt;  reg [7:0]  commit_tag;  reg [31:0] commit_bytes;
    reg              cpl_evt;     reg [7:0]  cpl_tag;     reg [31:0] cpl_bytes;
    reg              abandon_evt;
    reg [OVL_TAG_COUNT-1:0] q_tag_bmp; // ledger-held tags, skipped by the free search
    integer          li;

    // ------------------------------------------------------------------------
    // free-tag search
    // ------------------------------------------------------------------------
    // The bitmap is indexed by tag offset, whose width is $clog2(OVL_TAG_COUNT);
    // the reorder slot index is a different, usually narrower, number.  Conflating
    // them would make the search return a tag whose bitmap bit was never examined.
    localparam integer BMP_AW = (OVL_TAG_COUNT <= 1) ? 1 : $clog2(OVL_TAG_COUNT);

    // Sized copies of the integer parameters.  A part-select of an `integer`
    // parameter is not a legal constant part-select and yields X in simulation,
    // which silently propagates into the tag and length clamps.
    localparam [7:0]  TAG_BASE_W = OVL_TAG_BASE;
    localparam [15:0] SLOT_B16   = SLOT_BYTES;

    integer fi;
    reg [BMP_AW-1:0] first_free;
    reg              found_free;
    always @(*) begin
        first_free = {BMP_AW{1'b0}};
        found_free = 1'b0;
        for (fi = 0; fi < OVL_TAG_COUNT; fi = fi + 1) begin
            // busy_bitmap alone: an abandoned tag stays in it until its ledger
            // entry is retired by evidence or by the link barrier, so the search
            // cannot hand a poisoned tag to a new plane (or to a legacy request)
            // A tag is unavailable if the working bitmap holds it, or if dead debt
            // holds it.  The second term is what survives a soft flush: busy_bitmap
            // is in the dma_rst_n domain and a BAR0 flush clears it, dead_busy is not.
            if (!busy_bitmap[fi] && !dead_busy[fi] && !found_free) begin
                first_free = fi[BMP_AW-1:0];
                found_free = 1'b1;
            end
        end
    end
    wire             tag_avail = found_free && (n_live < NSLOT);
    wire [7:0]       new_tag   = TAG_BASE_W + {{(8-BMP_AW){1'b0}}, first_free};

    // ------------------------------------------------------------------------
    // completion CAM
    // ------------------------------------------------------------------------
    integer ci;
    reg [IDX_AW-1:0] cpl_idx;
    reg              cpl_hit;
    reg  [3:0]       dw_cnt;
    reg  [31:0]      cpl_new_got;
    always @(*) begin
        cpl_hit = 1'b0;
        cpl_idx = {IDX_AW{1'b0}};
        for (ci = 0; ci < NSLOT; ci = ci + 1) begin
            if (e_live[ci] && e_tag[ci] == ovl_cpl_tag) begin
                cpl_hit = 1'b1;
                cpl_idx = ci[IDX_AW-1:0];
            end
        end
        dw_cnt = (ovl_cpl_dw_count == 4'd0) ? 4'd8 : ovl_cpl_dw_count;
        cpl_new_got = e_got[cpl_idx] + {27'd0, dw_cnt, 2'b00};
    end

    // A reorder slot does not necessarily carry the tag with the same index, so
    // releasing the bitmap bit must go through the tag the entry actually owns.
    wire [BMP_AW-1:0] cpl_bmp = e_tag[cpl_idx][BMP_AW-1:0] - TAG_BASE_W[BMP_AW-1:0];

    // Range check and quarantine match for an arriving completion.  The subtraction
    // is done in 9 bits so a tag below the base cannot alias into the bitmap, and a
    // tag wholly outside the private range (a stray upgrade completion, say) is
    // simply stray rather than accidentally "quarantined".
    wire [8:0]       cpl_off    = {1'b0, ovl_cpl_tag} - {1'b0, TAG_BASE_W};
    wire             tag_in_rng = (cpl_off < OVL_TAG_COUNT[8:0]);
    wire [BMP_AW-1:0] raw_tag_bmp = ovl_cpl_tag[BMP_AW-1:0] - TAG_BASE_W[BMP_AW-1:0];
    // Does any abandoned (dead) in-flight request still owe bytes?  This - not a
    // counter, and not the reorder slots - is what keeps the block faulted, refuses a
    // new arm, and reserves the 64..127 tag space behind it.
    integer qi;
    reg              q_any;
    reg  [IDX_AW-1:0] q_idx;
    reg  [31:0]      q_new_owed;
    reg  [BMP_AW-1:0] q_bmp;
    always @(*) begin
        q_any = 1'b0;
        for (qi = 0; qi < IFL; qi = qi + 1)
            if (ifl_live[qi] && ifl_dead[qi]) q_any = 1'b1;
    end
    // Ledger CAM: a completion whose tag belongs to abandoned debt.
    reg q_hit;
    always @(*) begin
        q_hit = 1'b0;
        q_idx = {IDX_AW{1'b0}};
        for (qi = 0; qi < IFL; qi = qi + 1) begin
            if (ifl_live[qi] && ifl_dead[qi] && ifl_tag[qi] == ovl_cpl_tag) begin
                q_hit = 1'b1;
                q_idx = qi[IDX_AW-1:0];
            end
        end
        q_new_owed = ifl_owed[q_idx] - {27'd0, dw_cnt, 2'b00};
        q_bmp      = ifl_tag[q_idx][BMP_AW-1:0] - TAG_BASE_W[BMP_AW-1:0];
    end
    // Tag-space mask: while the ledger holds a tag, the free-tag search cannot hand
    // it to a new overlay request or to a legacy capture request, even after a soft
    // reset of this block cleared busy_bitmap.  That is the point: only completion
    // evidence or the link barrier returns the tag.
    always @(*) begin
        q_tag_bmp = {OVL_TAG_COUNT{1'b0}};
        for (qi = 0; qi < IFL; qi = qi + 1)
            if (ifl_live[qi] && ifl_dead[qi])
                q_tag_bmp[ifl_tag[qi][BMP_AW-1:0] - TAG_BASE_W[BMP_AW-1:0]] = 1'b1;
    end

    // Staging write: DWord-granular byte enables at the entry's running offset.
    // Completions are DWord aligned, so the lane offset is a multiple of 4.
    wire [4:0]        w_lane   = e_got[cpl_idx][4:0];       // 0..31, always x4
    wire [3:0]        w_lane_dw = w_lane[4:2];              // 0..7
    wire [RAM_AW-1:0] waddr     = cpl_idx * SLOT_WORDS +
                                  e_got[cpl_idx][SW_AW+4:5];   // byte >> 5
    // Rotate, never shift.
    //
    // Rotating the right-justified beat payload by w_lane_dw lanes keeps every
    // DWord inside the 256-bit window: lane b ends up holding the beat's DWord
    // (b - w_lane_dw) mod 8, which is the DWord whose completion byte offset is
    // e_got + ((b - w_lane_dw) mod 8)*4.  Lanes below w_lane_dw are therefore
    // the overflow that a left-shift used to destroy, and they belong to row+1.
    wire [511:0]      w_dup    = {ovl_cpl_data, ovl_cpl_data};
    // Lane b must receive payload DWord (b - w_lane_dw) mod 8, i.e. a LEFT
    // rotate of the right-justified payload by w_lane_dw DWords.  Reading the
    // doubled vector from (8 - w_lane_dw)*32 reproduces exactly that, and the
    // DWords that fall off the top of the row reappear as lanes below
    // w_lane_dw, which are the lanes tagged for row+1 by w_lane_hi.
    wire [8:0]        w_rot_sh = 9'd8 - {6'd0, w_lane_dw[2:0]};   // 8..1
    wire [8:0]        w_rot_base = {w_rot_sh[3:0], 5'd0};         // *32
    wire [255:0]      w_rot    = w_dup[w_rot_base +: 256];
    // A wrap can only ever be legal while the base row is not the last row of
    // the slot.  cpl_new_got <= e_exp[cpl_idx] (the commit gate below) together
    // with e_exp <= SLOT_BYTES already forbids it; this makes it unrepresentable
    // instead of merely unreachable, so no future parameterisation can let a
    // wrapped DWord land in the neighbouring slot.
    localparam [RAM_AW:0] RAM_LAST_ROW = RAM_WORDS - 1;
    wire [RAM_AW:0]   w_row_p1 = {1'b0, waddr} + {{RAM_AW{1'b0}}, 1'b1};
    wire              w_hi_ok  = (w_row_p1 <= RAM_LAST_ROW);
    reg  [7:0]        w_lane_pl, w_lane_hi;
    integer bi;
    always @(*) begin
        for (bi = 0; bi < 8; bi = bi + 1) begin
            w_lane_hi[bi] = (bi[2:0] <  w_lane_dw[2:0]);
            // 3-bit subtraction is already (b - start) mod 8
            w_lane_pl[bi] = ({1'b0, (bi[2:0] - w_lane_dw[2:0])} < dw_cnt) &&
                            (!w_lane_hi[bi] || w_hi_ok);
        end
    end

    // ------------------------------------------------------------------------
    // issue / drain / accounting
    // ------------------------------------------------------------------------
    reg  [63:0]      cur_addr;
    reg  [31:0]      bytes_left;
    reg  [IDX_AW-1:0] tail, head;
    reg              armed, go_q;
    reg  [31:0]      timeout_cnt;
    reg              progress;
    reg              d_active;
    reg  [SW_AW:0]   d_total;          // 32 B words in the draining entry
    reg  [SW_AW:0]   d_idx;            // next 32 B word to read out
    reg              rd_pipe;               // ram_rdata valid this cycle

    wire [15:0] cap_req =
        (ovl_max_bytes_per_req == 16'd0 || ovl_max_bytes_per_req > MAX_REQ_CLAMP)
            ? ((MAX_REQ_CLAMP < SLOT_B16) ? MAX_REQ_CLAMP : SLOT_B16)
            : ((ovl_max_bytes_per_req < SLOT_B16) ? ovl_max_bytes_per_req
                                                  : SLOT_B16);
    wire [15:0] room_4k = 16'd4096 - {4'd0, cur_addr[11:0]};
    wire [15:0] cap     = (cap_req < room_4k) ? cap_req : room_4k;
    // clamp_len = min(cap, bytes_left).  Getting these branches the wrong way
    // round makes the engine issue the whole remaining transfer as one read,
    // which then overruns the reorder slot and the 4 KB boundary.
    wire [15:0] clamp_len =
        ({16'd0, cap} >= bytes_left) ? bytes_left[15:0] : cap;

    // Arming is refused while the tag space is quarantined: an aborted transfer must
        // Arming is refused while any abandoned tag is still owed: the old plane's
    // reads must be accounted for (by their completions arriving, or by a real
    // link barrier) before this block takes new work, so a late completion can
    // never land in a new transfer's staging or meet a tag a new transfer holds.
    wire arm_ok   = ovl_go && !go_q && ovl_enable && !armed && !q_any &&
                    (ovl_xfer_bytes >= 32'd4) && (ovl_src_addr[1:0] == 2'b00);
    wire arm_bad  = ovl_go && !go_q && ovl_enable && !armed &&
                    ((ovl_xfer_bytes < 32'd4) || (ovl_src_addr[1:0] != 2'b00));
    // The MRd presentation is atomic.  Once mrd_req_valid rises, address, length,
    // byte enables and tag are frozen until the encoder acknowledges, and the tag
    // is reserved at the moment of presentation.  Recomputing that bundle from the
    // combinational free-tag search lets a retiring tag change what is on the bus
    // between presentation and acknowledgement, so the host ends up answering a tag
    // the engine never recorded, and the completion misses the reorder CAM.
    reg  [15:0] req_len_r;
    wire accepted  = mrd_req_valid && mrd_req_ack;
    wire can_start = armed && ovl_enable && !quiesce && (bytes_left != 32'd0) &&
                     !q_any && tag_avail && (clamp_len >= 16'd1);
    wire start_now = can_start && !mrd_req_valid;

    // Headroom rule for the staging read.  The read address is combinational and
    // ram_rdata is the registered BRAM output, so the latency is exactly one cycle
    // and the valid shift matches it even on bubbles (pushing only when the FIFO
    // happened to be ready at push time lost a word whenever it filled in between,
    // and registering the read address as well made the capture re-read the previous
    // word on a bubble; both were measured as a wrong 32-byte chunk).
    // Two writes are invisible to the write count when a read is being decided: the
    // push asserted during this cycle, and the push that this cycle's decision turns
    // into a fifo_wen next cycle.  wr_data_count only updates the cycle after a write
    // lands, so requiring two free slots (not one, not zero) is what makes a drop
    // impossible; the FIFO can only gain space in the interval.
    wire [WDQ-1:0] fifo_wr_count;
    wire fifo_room2 = !fifo_wr_busy && (fifo_wr_count <= (FIFO_DEPTH - 2));

    wire fifo_wr_room  = !fifo_full && !fifo_wr_busy;
    wire drain_can_read = d_active && (d_idx != d_total) && fifo_room2;
    // Retirement is gated by exactly the condition the live-entry count is
    // decremented on (drain_retire below): deferring a retire while still counting
    // it as retired drove n_live below the number of live entries, so the issue side
    // handed out more requests than there were reorder slots, overwrote a live
    // entry, and that entry's later beats missed the reorder CAM.
    wire drain_done     = d_active && (d_idx == d_total) && !rd_pipe;

    // combinational read address, registered data (true synchronous BRAM read)
    wire [RAM_AW-1:0] ram_raddr = head * SLOT_WORDS + d_idx[SW_AW-1:0];
    wire              ram_ren   = drain_can_read;

    // Words to read out of the head entry, rounded up.  A sub-32-byte read must
    // still stage one word, otherwise its bytes would never be forwarded.
    wire [31:0] head_words_full = (e_exp[head] + 32'd31) >> 5;
    wire [SW_AW:0] head_words   = head_words_full[SW_AW:0];

    // Single-delta accounting.  Issue, retirement and discard can all fire in the
    // same cycle; separate assignments in one clocked block would let the last one
    // win and quietly lose a count.
    // Retirement is keyed on the byte count the request was issued for, never on
    // ovl_cpl_last.  ovl_cpl_last marks the last beat of ONE completion, and a
    // single Memory Read may be answered by several completions (Read Completion
    // Boundary, or a bridge that splits by its own budget): treating that flag as
    // "the read is done" retires the entry in the middle of the read, the remaining
    // beats then miss the reorder CAM, are counted as stray, and their bytes are
    // silently lost from the stream (measured: 512 of 2048 bytes missing per run).
    // A read whose completions end short of the count is therefore not retired by
    // `last` at all; the bounded timeout aborts it, which is the safe direction for
    // a plane that must never corrupt the frame.
    wire        cpl_fin  = ovl_cpl_valid && cpl_hit &&
                           (cpl_new_got == e_exp[cpl_idx]);
    wire        cpl_drop     = cpl_fin && quiesce && discard_pending;

    // The retire condition, shared by the counter delta and the state update so the
    // two can never disagree.
    wire        drain_retire = drain_done && !cpl_fin;
    wire [IDX_AW:0] live_inc = accepted ? {{IDX_AW{1'b0}}, 1'b1} : {(IDX_AW+1){1'b0}};
    wire [IDX_AW:0] live_dec = (drain_retire ? {{IDX_AW{1'b0}}, 1'b1}
                                             : {(IDX_AW+1){1'b0}});
    wire [5:0]  ovl_inc      = accepted ? 6'd1 : 6'd0;
    wire [5:0]  ovl_dec      = cpl_fin ? 6'd1 : 6'd0;

    // Timeout fires once per stalled window; it also has to clear the ring, which
    // is why the counters below are written conditionally rather than as deltas.
    wire timeout_fire = ((ovl_outstanding != 6'd0) ||
                         (n_live != {(IDX_AW+1){1'b0}})) &&
                        !progress && (timeout_cnt >= TIMEOUT_CYCLES);
    // Arm withdrawn while a transfer is live: same cleanup as a timeout.
    wire abandon      = !ovl_go && armed;
    wire abort_now    = timeout_fire || abandon;
    integer ti;

    always @(posedge clk or posedge p_rst) begin
        if (p_rst) begin
            cur_addr        <= 64'd0;
            bytes_left      <= 32'd0;
            tail            <= {IDX_AW{1'b0}};
            head            <= {IDX_AW{1'b0}};
            n_live          <= {(IDX_AW+1){1'b0}};
            armed           <= 1'b0;
            go_q            <= 1'b0;
            timeout_cnt     <= 32'd0;
            progress        <= 1'b0;
            d_active        <= 1'b0;
            d_total         <= {(SW_AW+1){1'b0}};
            d_idx           <= {(SW_AW+1){1'b0}};
            rd_pipe         <= 1'b0;
            busy_bitmap     <= {OVL_TAG_COUNT{1'b0}};
            ovl_quarantined <= 1'b0;
            mrd_req_valid   <= 1'b0;
            mrd_req_addr    <= 64'd0;
            mrd_req_dw_len  <= 11'd0;
            mrd_req_tag     <= 8'd0;
            mrd_req_first_be<= 4'hF;
            mrd_req_last_be <= 4'hF;
            ram_wen         <= 1'b0;
            ram_wrow        <= {(RAM_AW+1){1'b0}};
            ram_wrot        <= 256'd0;
            ram_wpl         <= 8'd0;
            ram_whi         <= 8'd0;
            fifo_wen        <= 1'b0;
            fifo_wdata      <= 256'd0;
            ovl_bytes_issued     <= 32'd0;
            ovl_bytes_staged     <= 32'd0;
            ovl_bytes_drained    <= 32'd0;
            ovl_outstanding      <= 6'd0;
            ovl_busy             <= 1'b0;
            ovl_quiesced         <= 1'b1;
            ovl_unexpected_count <= 32'd0;
            ovl_overflow_count   <= 32'd0;
            ovl_split_count      <= 32'd0;
            ovl_abort_count      <= 32'd0;
            ovl_timeout_sticky   <= 1'b0;
            ovl_unaligned_sticky <= 1'b0;
            ovl_err_sticky       <= 1'b0;
            ovl_done_pulse       <= 1'b0;
            ovl_abort_evt        <= 1'b0;
            commit_evt           <= 1'b0;
            cpl_evt              <= 1'b0;
            abandon_evt          <= 1'b0;
        end else begin
            ram_wen        <= 1'b0;
            fifo_wen       <= 1'b0;
            progress       <= 1'b0;
            ovl_done_pulse <= 1'b0;
            // The ledger events are one-cycle pulses.  Without these defaults the
            // first commit left commit_evt asserted forever and the ledger booked the
            // same tag into every entry (observed: live=all-ones, dead=all-ones,
            // all four tags identical), which then retired on the first completion.
            commit_evt     <= 1'b0;
            cpl_evt        <= 1'b0;
            abandon_evt    <= 1'b0;
            go_q           <= ovl_go;

            // ---- arm -------------------------------------------------------
            if (arm_bad) begin
                ovl_unaligned_sticky <= 1'b1;
                ovl_err_sticky       <= 1'b1;
            end else if (arm_ok) begin
                cur_addr     <= ovl_src_addr;
                bytes_left   <= ovl_xfer_bytes;
                armed        <= 1'b1;
                ovl_busy     <= 1'b1;
                // Per-transfer byte accounting restarts here.  Leaving the previous
                // transfer's totals in place makes ovl_bytes_issued over-report (a
                // driver or testbench polling issued == ovl_xfer_bytes stops early,
                // which is exactly how this was caught), so a completed-looking
                // counter would hide an unfinished transfer.
                ovl_bytes_issued  <= 32'd0;
                ovl_bytes_staged  <= 32'd0;
                ovl_bytes_drained <= 32'd0;
                tail         <= {IDX_AW{1'b0}};
                head         <= {IDX_AW{1'b0}};
                d_active     <= 1'b0;
                d_total      <= {(SW_AW+1){1'b0}};
                d_idx        <= {(SW_AW+1){1'b0}};
                timeout_cnt  <= 32'd0;
            end
            // Withdrawing the arm in the middle of a transfer is an abort, not a
            // silent stop: the reads still owed move to the abandoned-tag ledger
            // (ledger_abandon below), the plane is declared undeliverable to the
            // writer (ovl_abort_evt), and the block stays faulted.  The tags are not
            // "released after a quiet window"; only their completions arriving with
            // the full issued byte count, or a real link barrier, retire them.
            if (abandon) begin
                armed           <= 1'b0;
                ovl_busy        <= 1'b0;
                mrd_req_valid   <= 1'b0;
                abandon_evt   <= 1'b1;      // relabel in-flight as debt (ledger)
                // busy_bitmap is deliberately NOT cleared here any more.  Clearing
                // it was the launder: it returned tags that the root complex still
                // owed to the free list.  The ledger's own dead_busy set holds that
                // space now, in the epoch domain, and is released only when the owed
                // bytes arrive.
                for (ti = 0; ti < NSLOT; ti = ti + 1) begin
                    e_live[ti]  <= 1'b0;
                    e_ready[ti] <= 1'b0;
                end
            end

            // ---- MRd presentation and commit ------------------------------
            if (!mrd_req_valid) begin
                if (start_now) begin
                    mrd_req_valid  <= 1'b1;
                    mrd_req_addr   <= cur_addr;
                    mrd_req_dw_len <= ({16'd0, clamp_len} + 16'd3) >> 2;
                    mrd_req_tag    <= new_tag;
                    req_len_r      <= clamp_len;
                    // reserved the instant it appears on the request bus
                    busy_bitmap[first_free] <= 1'b1;
                    case (cur_addr[1:0])
                        2'd0:    mrd_req_first_be <= 4'b1111;
                        2'd1:    mrd_req_first_be <= 4'b1110;
                        2'd2:    mrd_req_first_be <= 4'b1100;
                        default: mrd_req_first_be <= 4'b1000;
                    endcase
                    if (clamp_len <= 16'd4) begin
                        case (clamp_len[1:0])
                            2'd1:    mrd_req_last_be <= 4'b0001;
                            2'd2:    mrd_req_last_be <= 4'b0011;
                            2'd3:    mrd_req_last_be <= 4'b0111;
                            default: mrd_req_last_be <= 4'b1111;
                        endcase
                    end else
                        mrd_req_last_be <= 4'b1111;
                end
            end else if (mrd_req_ack) begin
                // commit exactly what was presented, not what recomputes now
                mrd_req_valid       <= 1'b0;
                mrd_req_first_be    <= 4'b1111;
                mrd_req_last_be     <= 4'b1111;
                e_live[tail]        <= 1'b1;
                e_ready[tail]       <= 1'b0;
                e_got[tail]         <= 32'd0;
                e_tag[tail]         <= mrd_req_tag;
                // Staging expects whole DWords: a completion carries a DWord count
                // and no byte enables, so a 2-byte tail read still returns 4 bytes.
                // The exact transfer length stays in the byte counters above; the
                // surplus bytes inside the final DWord are filtered by the writer's
                // own ov_frame_bytes count, exactly like the trailing word rule.
                e_exp[tail]         <= {5'd0, mrd_req_dw_len, 2'b00};
                tail                <= tail + 1'b1;
                cur_addr            <= cur_addr + {48'd0, req_len_r};
                bytes_left          <= bytes_left - {16'd0, req_len_r};
                ovl_bytes_issued    <= ovl_bytes_issued + {16'd0, req_len_r};
                // Book the debt at the instant the encoder owns the request.  This is
                // the commit point: from here on a completion is owed whether or not
                // the arm survives, and an abort in this very cycle must not be able
                // to un-book it (see the ledger process, which handles commit and
                // abandon asserted together explicitly rather than relying on the
                // order of statements).
                commit_evt          <= 1'b1;
                commit_tag          <= mrd_req_tag;
                commit_bytes        <= {16'd0, req_len_r};
                timeout_cnt         <= 32'd0;
                progress            <= 1'b1;
            end
            n_live <= abort_now ? {(IDX_AW+1){1'b0}}
                                : (n_live + live_inc - live_dec);
            ovl_outstanding <= abort_now ? 6'd0
                                         : (ovl_outstanding + ovl_inc - ovl_dec);

            // ---- completion intake ----------------------------------------
            if (ovl_cpl_valid) begin
                progress <= 1'b1;
                // Every accepted completion is reported to the ledger, whether or not
                // it matches a live reorder slot: the ledger owns the byte count of
                // what is still owed, and it is the only thing allowed to retire a
                // tag's debt.
                cpl_evt  <= 1'b1;
                cpl_tag  <= ovl_cpl_tag;
                cpl_bytes<= {27'd0, dw_cnt, 2'b00};
                if (q_hit) begin
                    // A completion for a tag this block abandoned.  Counted and
                    // dropped: never staged, never forwarded.  It retires the debt
                    // only when that owner's issued byte count has fully arrived,
                    // which the ledger does itself from cpl_evt.
                    ovl_unexpected_count <= ovl_unexpected_count + 32'd1;
                    ovl_err_sticky       <= 1'b1;
                end else if (!cpl_hit) begin
                    ovl_unexpected_count <= ovl_unexpected_count + 32'd1;
                    ovl_err_sticky       <= 1'b1;
                end else if (cpl_new_got > e_exp[cpl_idx]) begin
                    ovl_overflow_count <= ovl_overflow_count + 32'd1;
                    ovl_err_sticky     <= 1'b1;
                end else if (cpl_drop) begin
                    // Quiesce with discard: still consume the completion and free
                    // the tag, but retire the entry with zero bytes so nothing of
                    // this transfer reaches PS DDR.  The ring stays in order.
                    e_live[cpl_idx]         <= 1'b0;
                    e_exp[cpl_idx]          <= 32'd0;
                    e_ready[cpl_idx]        <= 1'b1;
                    busy_bitmap[cpl_bmp]    <= 1'b0;
                end else begin
                    ram_wen   <= 1'b1;
                    ram_wrow  <= {1'b0, waddr};
                    ram_wrot  <= w_rot;
                    ram_wpl   <= w_lane_pl;
                    ram_whi   <= w_lane_hi;
                    e_got[cpl_idx] <= cpl_new_got;
                    ovl_bytes_staged <= ovl_bytes_staged + {27'd0, dw_cnt, 2'b00};
                    if (!ovl_cpl_last)
                        ovl_split_count <= ovl_split_count + 32'd1;
                    if (cpl_fin) begin
                        e_live[cpl_idx]  <= 1'b0;
                        e_ready[cpl_idx] <= 1'b1;
                        busy_bitmap[cpl_bmp] <= 1'b0;
                    end
                end
            end

            // ---- in-order drain of staging into the crossing FIFO ----------
            // Head entry only, so PS DDR sees the host byte image in issue order.
            if (!d_active && n_live != {(IDX_AW+1){1'b0}} && e_ready[head]) begin
                d_active <= 1'b1;
                d_total  <= head_words;
                d_idx    <= {(SW_AW+1){1'b0}};
            end
            if (drain_can_read) d_idx <= d_idx + 1'b1;
            rd_pipe <= drain_can_read;
            if (rd_pipe) begin
                fifo_wen   <= 1'b1;                 // room was guaranteed at issue
                fifo_wdata <= ram_rdata;
                ovl_bytes_drained <= ovl_bytes_drained + 32'd32;
                progress          <= 1'b1;
            end
            if (drain_retire) begin
                d_active      <= 1'b0;
                e_ready[head] <= 1'b0;
                head          <= head + 1'b1;
            end

            // ---- completion / quiesce / timeout ---------------------------
            if (armed && bytes_left == 32'd0 &&
                n_live == {(IDX_AW+1){1'b0}} && !d_active) begin
                armed        <= 1'b0;
                ovl_busy     <= 1'b0;
                ovl_done_pulse <= 1'b1;
            end
            ovl_quiesced <= (ovl_outstanding == 6'd0) &&
                            (n_live == {(IDX_AW+1){1'b0}}) && !q_any && !abort_now;

            // ---- abandoned-tag ledger visibility --------------------------
            // Quarantined now means "this block still owes reads the root context
            // was given", reported from the ledger rather than from a countdown, and
            // it is the condition that refuses a new arm (arm_ok, can_start) and
            // reserves the 64..127 tag space behind it.  ovl_abort_evt is the
            // plane-discard event the plane writer retires on
            // (rtl/sc7f0_overlay_writer.v section 3b): it fires when payload is
            // dropped because software discarded the plane, and on abandon/timeout
            // through ledger_abandon.
            ovl_quarantined   <= q_any || abort_now;
            // The poison is the "an abort left ownership behind" report.  It is the
            // ledger's own sticky, so it survives every reset except the physical
            // epoch that clears the ledger itself.
            ovl_poison_sticky <= poison_sticky_r || abort_now;
            ovl_abort_evt     <= abandon_evt || cpl_drop;
            if (ovl_outstanding != 6'd0 || n_live != {(IDX_AW+1){1'b0}}) begin
                if (progress) timeout_cnt <= 32'd0;
                else if (timeout_fire) begin
                    // Give up on this transfer.  The tags still owed are NOT
                    // returned to the free list and are NOT retired by a countdown:
                    // releasing them would let the next arm hand the very same tag to
                    // a new request while the root complex is still sending the old
                    // read's completions, and those late beats would match the new
                    // entry and write the old read's bytes into a different staging
                    // slot - silent frame corruption in a plane that shares nothing
                    // with the upgrade path but must never disturb it.  They move to
                    // the ledger and are retired only by their completions or by the
                    // physical link barrier.
                    ovl_timeout_sticky <= 1'b1;
                    ovl_err_sticky     <= 1'b1;
                    ovl_abort_count    <= ovl_abort_count + 32'd1;
                    abandon_evt        <= 1'b1;
                    // see the abandon above: the tag space is held by the ledger
                    armed              <= 1'b0;
                    ovl_busy           <= 1'b0;
                    for (ti = 0; ti < NSLOT; ti = ti + 1) begin
                        e_live[ti]  <= 1'b0;
                        e_ready[ti] <= 1'b0;
                    end
                end else
                    timeout_cnt <= timeout_cnt + 32'd1;
            end else
                timeout_cnt <= 32'd0;
        end
    end

    // ------------------------------------------------------------------------
    // The abandoned-tag ledger, in its own process and reset domain.
    //
    // It is reset by rst_n (the PCIe-domain reset) and NOT by p_all_n, because the
    // set of reads the root complex still owes belongs to the LINK, not to this
    // block's staging: a video reset (mem_rst_n) or any other soft reset that
    // wipes the staging RAM and FIFO must not also wipe the record that tags 64..127
    // are still owed, or the next arm would hand those very tags out again while
    // their old completions are on the way.  The only releases are:
    //   1. evidence - the owed bytes arrived, counted against the issued length;
    //   2. a physical link barrier held for LINK_BARRIER_MIN cycles, in which case
    //      no completion can arrive at all and the host's outstanding requests are
    //      gone with the link.
    // ------------------------------------------------------------------------
    // Reset by epoch_rst_n ONLY, asynchronously and with no clock dependence: if the
    // link goes down and pcie_user_clk stops, the ledger is still held in reset, so
    // the fail-closed state does not need a clock edge to be true.  epoch_rst_n is
    // pcie_user_rst_n (user_lnk_up && ~user_reset): when it is asserted the PCIe
    // core's outstanding transactions for this function are gone by the core's own
    // reset semantics, which is a physical epoch boundary rather than a wait.
    //
    // There is deliberately NO second release mechanism.  An earlier revision also
    // counted LINK_BARRIER_MIN cycles of a held barrier, but the barrier and
    // epoch_rst_n are derived from the same signal, so the asynchronous clear already
    // dominates and the counter controlled nothing - claiming "the barrier must be
    // held 64 cycles" as a safety property would have been false.  A datapath or soft
    // reset (dma_rst_n from BAR0[0x14] or reg_dma_ctrl[1]) cannot reach this process at
    // all.
    always @(posedge clk or negedge epoch_rst_n) begin
        if (!epoch_rst_n) begin
            for (li = 0; li < IFL; li = li + 1) begin
                ifl_live[li] <= 1'b0;
                ifl_dead[li] <= 1'b0;
                ifl_tag[li]  <= 8'd0;
                ifl_owed[li] <= 32'd0;
            end
            dead_busy         <= {OVL_TAG_COUNT{1'b0}};
            poison_sticky_r   <= 1'b0;
        end else begin
            // 1. BOOK THE DEBT at the commit instant.  commit_evt is the cycle the
            //    encoder acknowledged the MRd, so the request is on its way whether or
            //    not this block survives the next cycle.
            if (commit_evt) begin
                ifl_found = 1'b0;
                for (li = 0; li < IFL; li = li + 1) begin
                    if (!ifl_live[li] && !ifl_found) begin
                        ifl_found      = 1'b1;
                        ifl_live[li] <= 1'b1;
                        // An abandon in this same cycle makes this brand-new request
                        // debt immediately.  This is stated explicitly instead of
                        // relying on the order of statements in another process: the
                        // two always blocks see the same old state, so "the issue side
                        // updated first" is not an argument.
                        ifl_dead[li] <= abandon_evt;
                        ifl_tag[li]  <= commit_tag;
                        ifl_owed[li] <= commit_bytes;
                    end
                end
                if (abandon_evt)
                    dead_busy[commit_tag[BMP_AW-1:0] - TAG_BASE_W[BMP_AW-1:0]] <= 1'b1;
            end
            // 2. ACCOUNT every completion against its owner, live or dead.  A late
            //    completion retires ONLY the entry whose tag owns it, and only when
            //    that owner's full issued byte count has arrived.
            if (cpl_evt) begin
                for (li = 0; li < IFL; li = li + 1) begin
                    if (ifl_live[li] && ifl_tag[li] == cpl_tag) begin
                        if (ifl_owed[li] <= cpl_bytes) begin
                            ifl_live[li] <= 1'b0;
                            ifl_owed[li] <= 32'd0;
                            if (ifl_dead[li])
                                dead_busy[ifl_tag[li][BMP_AW-1:0] -
                                            TAG_BASE_W[BMP_AW-1:0]] <= 1'b0;
                        end else begin
                            ifl_owed[li] <= ifl_owed[li] - cpl_bytes;
                        end
                    end
                end
            end
            // 3. RELABEL on abandon.  Nothing is copied from the reorder slots, so
            //    nothing can be copied after a reset has already cleared them.
            if (abandon_evt) begin
                poison_sticky_r <= 1'b1;
                for (li = 0; li < IFL; li = li + 1) begin
                    if (ifl_live[li]) begin
                        ifl_dead[li] <= 1'b1;
                        dead_busy[ifl_tag[li][BMP_AW-1:0] -
                                    TAG_BASE_W[BMP_AW-1:0]] <= 1'b1;
                    end
                end
            end
        end
    end

    // staging RAM (inferred simple dual port: 256b write @125, 256b read @125)
    // Staging RAM: eight banks, one write port per bank, and the read side
    // reassembles the 256-bit row from the same row address in all eight.  Same
    // registered read latency as the old single wide memory, so the drain
    // pipeline (ram_ren / rd_pipe / fifo_room2 headroom) is bit-for-bit the same
    // block of logic and still reads a retired entry only.
    always @(posedge clk) begin
        if (ram_wen) begin
            if (ram_wpl[0]) stage_b0[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[0]}] <= ram_wrot[31:0];
            if (ram_wpl[1]) stage_b1[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[1]}] <= ram_wrot[63:32];
            if (ram_wpl[2]) stage_b2[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[2]}] <= ram_wrot[95:64];
            if (ram_wpl[3]) stage_b3[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[3]}] <= ram_wrot[127:96];
            if (ram_wpl[4]) stage_b4[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[4]}] <= ram_wrot[159:128];
            if (ram_wpl[5]) stage_b5[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[5]}] <= ram_wrot[191:160];
            if (ram_wpl[6]) stage_b6[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[6]}] <= ram_wrot[223:192];
            if (ram_wpl[7]) stage_b7[ram_wrow + {{RAM_AW{1'b0}}, ram_whi[7]}] <= ram_wrot[255:224];
        end
    end
    always @(posedge clk) ram_rdata <= {stage_b7[ram_raddr], stage_b6[ram_raddr],
                                        stage_b5[ram_raddr], stage_b4[ram_raddr],
                                        stage_b3[ram_raddr], stage_b2[ram_raddr],
                                        stage_b1[ram_raddr], stage_b0[ram_raddr]};

    // ------------------------------------------------------------------------
    // payload crossing: 256 bit @125 -> 128 bit @300
    // ------------------------------------------------------------------------
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE   ("block"),
        .FIFO_WRITE_DEPTH   (FIFO_DEPTH),
        .WRITE_DATA_WIDTH   (256),
        .READ_DATA_WIDTH    (128),
        .READ_MODE          ("fwft"),
        .FIFO_READ_LATENCY  (0),
        .CDC_SYNC_STAGES    (4),
        .USE_ADV_FEATURES   ("0404"),          // wr_data_count + rd_data_count
        .WR_DATA_COUNT_WIDTH(WDQ),
        .RD_DATA_COUNT_WIDTH(RDQ),
        .SIM_ASSERT_CHK     (1)
    ) u_xfer (
        .rst           (p_rst),
        .wr_clk        (clk),
        .din           (fifo_wdata),
        .wr_en         (fifo_wen),
        .full          (fifo_full),
        .wr_rst_busy   (fifo_wr_busy),
        .rd_clk        (mem_clk),
        .dout          (fifo_dout),
        .rd_en         (m_axis_tvalid && m_axis_tready),
        .empty         (fifo_empty),
        .rd_rst_busy   (fifo_rd_busy),
        .rd_data_count (fifo_rd_count),
        .wr_data_count (fifo_wr_count),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .prog_full     (), .prog_empty(), .overflow(fifo_ovf), .underflow(),
        .almost_full   (), .almost_empty(), .wr_ack(), .data_valid(),
        .dbiterr       (), .sbiterr       ()
    );

    assign m_axis_tdata = fifo_dout;
    assign m_axis_tvalid= !fifo_empty && !fifo_rd_busy && m_all_n;
    localparam integer AVAIL_MAX = (RDQ >= 9) ? 255 : ((1 << RDQ) - 1);
    assign m_axis_avail = (fifo_rd_count > AVAIL_MAX[RDQ-1:0]) ? 8'hFF
                                                              : fifo_rd_count[7:0];

    // first-beat marker per arm + read-side overflow sticky
    reg  arm_toggle, sync0, sync1, arm_last, arm_first;
    reg  [1:0] ovf_sync;
    always @(posedge clk or posedge p_rst) begin
        if (p_rst)          arm_toggle <= 1'b0;
        else if (arm_ok)    arm_toggle <= ~arm_toggle;
    end
    always @(posedge mem_clk or posedge m_rst) begin
        if (m_rst) begin
            sync0 <= 1'b0; sync1 <= 1'b0; arm_last <= 1'b0;
            arm_first <= 1'b1; ovf_sync <= 2'b00;
        end else begin
            sync0 <= arm_toggle;
            sync1 <= sync0;
            ovf_sync <= {ovf_sync[0], fifo_ovf};
            if (sync1 != arm_last) begin
                arm_last  <= sync1;
                arm_first <= 1'b1;
            end else if (m_axis_tvalid && m_axis_tready)
                arm_first <= 1'b0;
        end
    end
    assign m_axis_tuser     = arm_first && m_axis_tvalid;
    assign m_axis_ovf_sticky= ovf_sync[1];
endmodule
`default_nettype wire
