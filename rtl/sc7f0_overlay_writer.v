`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_overlay_writer  (personality SC7F0-RGB-COMPOSITOR-2PPC)
//
// Host RGBA8888 -> overlay read stream -> PS DDR overlay slot -> read back by
// v_frmbuf_rd Reader-B into the alpha compositor.
//
//   * the AXI4 write master runs on the 300 MHz memory clock (capture_clk), not
//     on the 100 MHz HP0 clock the upgrade writer uses,
//   * data lands in one of up to four slots, and the slot that Reader-B is
//     scanning is never overwritten,
//   * a frame is never written past the end of its slot,
//   * frame completion is reported back to the PCIe domain and can raise an IRQ
//     only after the final AXI B response has landed, and the completion travels
//     as ONE bundled record {slot, event} - never as a data level plus an
//     independent event (review M10, section 3c),
//   * a BRESP error invalidates the WHOLE frame: the slot is not published, no
//     IRQ, no frames_done, the frame is counted as an error frame instead
//     (ov_err_frames / ov_err_frame_sticky) and the next frame starts clean,
//   * an explicit discard (ov_abort) retires the plane that is in flight instead
//     of leaving it half written - see ABORT CONTRACT below.
//
// ABORT CONTRACT (ov_abort, review H1/M4)
//   `ov_abort` is a pcie_clk LEVEL (or a one-cycle pulse; it is edge-latched
//   internally into a toggle so the event cannot be lost).  It means exactly one
//   thing: the plane that is in flight must never be published.  It is NOT the
//   ordinary upgrade pause - a plain `quiesce` that keeps the ingress entries
//   alive leaves this writer untouched, so a paused plane still completes.
//   The memory side then runs a four-state retirement, in this order:
//     AB_DRAIN  no NEW AW may be issued, but every burst whose AW has already
//               been presented or accepted is finished LEGALLY: AWVALID/WVALID
//               are never withdrawn under stall (AXI forbids it), the remaining
//               W beats are pushed out with the payload that was already owned,
//               and the outstanding B credits are collected.  Only when AW has
//               handshaked, W is idle and beats_b == beats_aw is the bus free of
//               this job's debt,
//     AB_FLUSH  the beats still sitting in the payload FIFO belong to the dead
//               plane, so they are popped and dropped, one at a time, with the
//               FIFO's own handshake (no reset, no pointer games),
//     AB_FENCE  the upstream crossing is drained by CONSUMING it: tready is
//               granted and every further beat is discarded, until the ingress
//               reports its read side empty and holds tvalid low.  That is state
//               owned by this receiver, not a guess about another agent,
//     then the job's bookkeeping is retired (slot leaves inflight and ready, the
//     counters reset), ov_abort_sticky is latched and the abort is ACKED back to
//     the pcie domain by a toggle plus a level (ov_abort_busy).  Only after that
//     ack may a new plane be armed; rtl/custom_pcie_dma_top.v holds the ingress
//     arm off while ov_abort_busy is high.
//   Nothing about an aborted job is ever published: no ready bit, no IRQ, no
//   frames_done, and its bytes can never be the head of the next frame because
//   the FIFO and the intake counters are empty before the ack is given.
//
// EPOCH-FORCED INVALIDATION (review M6 gap C, same contract as ov_abort)
//   A PCIe epoch boundary (epoch_rst_n, i.e. pcie_user_rst_n) with mem_rst_n HIGH and
//   work outstanding raises this SAME retirement request, because everything that gives
//   ov_write_slot meaning - the slot table, the programmed base, the epoch that armed
//   them - is behind that reset, while the AW/W/B already presented to the PS HP3
//   responder is not.  The obligation is retired exactly (AB_DRAIN waits for every owed
//   B, the ledger is cleared only with the bus free) and the frame is invalidated through
//   job_invalid, so it is never credited to whatever the new epoch programs next.  An
//   epoch boundary that finds the engine quiesced raises nothing.
//
// TERMINAL REQUESTS ARE PART OF THE PUBLICATION TEST (review MEDIUM-1)
//   epoch_inval_needed, fe_retire_needed and abort_evt are level/event requests, and
//   job_invalid is their REGISTERED form - one clock later.  A response can be taken in
//   any mem_clk cycle (m_axi_bready is tied high), so a terminal request can arrive on
//   the very cycle of the last B.  Publication therefore tests the requests themselves,
//   not only job_invalid: on that cycle the intake must take the error branch, because a
//   ready bit, a frames_done increment and above all the bundled completion record are
//   written on the same edge and the retirement that follows can retract none of them
//   (the record survives rst_n; only mem_rst_n or its own announcement ack clears it).
//   A request that arrives while the engine is quiesced still raises nothing, so this
//   costs an honest completion nothing: epoch_inval_needed requires fe_owed, and
//   fe_retire_needed / abort_evt only exist while something is owed or in flight.
//
// SHELL-ONLY RESET (review MEDIUM-2 - a contract, not a bug, and not auto-recovered)
//   .rst_n is dma_rst_n, which DMA_CTRL[1] and the BAR0 global flush can drop with
//   .epoch_rst_n (the top-level rst_n) and .mem_rst_n both HIGH
//   (rtl/custom_pcie_dma_top.v:561-564, :1862, :1876).  That split deliberately raises
//   neither retirement request: the ledger and job_open live behind the deferred
//   front-end reset precisely because the PS responder still owns those bursts, so the
//   job keeps its own AW addresses, keeps flowing the payload it already buffered, and is
//   answered normally.  The shell resets, so it publishes nothing while it is down and
//   cannot even REQUEST a discard (the abort request register is in the clk/rst_n
//   domain).  Recovery is therefore EXPLICIT and there is no third synchroniser for it:
//   ov_abort once the shell returns, or a later epoch / memory reset, both through the
//   same retirement.  Until then the job stays owed, ov_busy stays truthfully high, no
//   new frame can start and the epoch ledger stays armed - fail closed, never a quiet
//   window called quiesced.  The ingress 100 ms bounded stall is NOT recovery: it resets
//   with the same dma_rst_n (custom_pcie_dma_top.v:1803-1804) and its timeout abandons
//   only its own read tags (rtl/sc7f0_overlay_ingress.v:765-790).  Tested by tb W21.
//
// OBLIGATION RULE (review M6, closed by the deferred front-end reset)
//   This master talks to the PS S_AXI_HP3_FPD slave.  Nothing in the PL resets
//   that slave: rtl/zu4ev_pcie_card_top.v:249-253 builds mem_rst_n from the two
//   proc_sys_resets that pl_resetn0 drives, and the PS BD exports no reset pin
//   for S_AXI_HP0..HP3 at all (their only pin besides the AXI channels is
//   saxihp3_fpd_aclk = dp_mem_clk, the same 300 MHz clock this master runs on,
//   proj_bitstream_r9 .../bd/zu4ev_ps_bd/synth/zu4ev_ps_bd.v:1224-1226).  A
//   pcie_user_rst_n is equally not that boundary.  So an AW this master already
//   presented, the W beats the slave is still owed for it, and a completion the
//   slave already holds, ALL survive a logical reset of this master.
//   Clearing the master on mem_rst_n would therefore do two unspeakable things:
//     * withdraw AWVALID/WVALID under stall, which AXI forbids and which leaves
//       the PS write responder waiting for beats of a burst it accepted, and
//     * forget the obligation, so the completion that is still on its way is
//       later credited to a frame that never issued the burst it answers, which
//       publishes or falsely settles bytes that were never written.
//   So the obligation is never discarded.  mem_rst_n is only a reset REQUEST
//   (section 7b): the AXI front end - the AW/W/B master, its beat ledger, the
//   retirement FSM and the payload FIFO that still owns the committed beats -
//   is held out of reset until every AW it presented has been accepted, every
//   accepted AW has received exactly its number of W beats, and every such
//   burst has actually been answered.  That is measured on the interface, never
//   on an elapsed window.  While that is pending no new AW may be issued, no
//   frame may start, ov_busy / ov_abort_busy are truthfully asserted and the
//   interrupted plane can never be published.
//   The backstop stays as well: a completion that arrives with NO obligation
//   behind it cannot be an answer to anything this master issued, so it is
//   counted (ov_axi_err_sticky) and poisons the epoch (no publication, no
//   credit) until the PCIe epoch boundary - because a receiver that has seen an
//   unsolicited completion can no longer read any later B as proof that its own
//   write landed.  Publication also requires every W beat of the frame to have
//   been accepted, so no completion, stale or real, can publish a frame whose
//   data is still on the way.
//
// STARTUP AND RELOAD CONTRACT (what the deferred reset does NOT claim)
//   The ledger, and the deferral decision itself (section 7b), start empty at
//   configuration initialisation.  That is legitimate for a device power-on or a
//   PS-side reset, where the receiver genuinely starts with nothing outstanding.
//   It is NOT legitimate for a bare PL reload while the PS keeps running: the
//   reloaded PL cannot see the receiver's state, and the receiver may still hold
//   accepted bursts from before the reload.  Nothing here pretends to know.
//   fe_rst_r's initial value keeps the front end in reset until the logical
//   reset has been seen, so a reloaded PL issues nothing until it is enabled;
//   and if the stale receiver then answers a burst this master never asked for,
//   b_unsolicited fires and the epoch is poisoned - fail closed, not a silent
//   mis-attribution.  Retiring THAT case needs the PS-side reset, which is not a
//   PL action; the PL side can only refuse to publish, which it does.
//
// STREAMING CONTRACT (this is what the module exists to do)
//   The payload FIFO is a BURST elastic buffer, not a frame store.  The master
//   opens its AXI job when the FIRST beat of a frame is taken and issues the
//   next 256 B burst as soon as that burst is completely buffered, so intake and
//   drain run concurrently for the whole frame:
//
//     required case: 4K60 RGBA8888 = 3840 x 2160 x 4 = 33,177,600 B/frame
//                    line pitch 15,360 B, 2,073,600 beats, 129,600 bursts,
//                    1.990656 GB/s sustained on a 128-bit 300 MHz port
//                    (4.8 GB/s raw, ~2.4x headroom).
//
//   The FIFO stays at its default 1024 x 128 bit = 16 KiB = 64 bursts, which is
//   ~0.05% of a frame.  A frame is therefore NEVER required to fit in the FIFO:
//   there is deliberately no `frame_bytes <= FIFO capacity` guard here, and the
//   geometry is never silently capped.  Deepening the FIFO to hold a frame is
//   not an option either (33 MB does not exist in this device), so a bounded
//   burst FIFO plus concurrent drain is the only correct architecture.
//
//   Backpressure is honoured in both directions and is never allowed to invent
//   or lose data:
//     * s_axis_tready only ever goes high when the beat can actually be stored,
//       and a beat is only stored on tvalid && tready (never on tready alone),
//     * the master only covers a burst with an AW once all 16 of its beats are
//       in the FIFO, so it can never underflow or emit a phantom beat,
//     * AW/W/B channels are concurrent (up to OUTSTANDING_MAX bursts in flight)
//       and every AXI output stays stable while VALID is high and READY is low,
//     * a new frame is not accepted until the previous frame's final B has
//       landed, so the FIFO can only ever hold bytes that belong to one frame.
//
// Geometry rule: frame_bytes, slot_bytes and dst_base must be multiples of 256 B
// (4K60 RGBA8888 = 33,177,600 B = 256 x 129,600, so the natural case satisfies
// it) and frame_bytes must not exceed slot_bytes.  Because a 256 B-aligned burst
// of 256 B can never straddle a 4 KiB page, the same rule also guarantees the
// AXI 4 KiB boundary rule without any extra split logic.  A non-compliant
// program is latched in ov_misalign_sticky and the transfer is refused instead of
// being silently rounded.
//
// Domain split and CDC discipline (r10 restructure, streaming master)
//   The payload the ingress hands over is read out of rtl/sc7f0_overlay_ingress.v
//   in ITS memory clock, so the stream intake belongs to mem_clk too.  It used
//   to sit in the PCIe clock: the beat counter, slot select, geometry checks and
//   the job computation all consumed s_axis_tvalid/s_axis_tuser/s_axis_tready
//   and ov_* raw, which put a 125 MHz combinational cone on the ingress FIFO's
//   300 MHz read enable and a 300 MHz read-side flag on the writer's 125 MHz
//   write enable.  That is what report_cdc filed as Critical and what timed as
//     R7 -2.665 ns  u_overlay_ctrl/wr_slot_bytes_reg[1] ->
//                    u_overlay_ingress/u_xfer .../memory read enable, and
//     R7 -2.108 ns  u_overlay_ingress/u_xfer .../fifo_rd_rst_ic ->
//                    u_overlay_writer/u_data .../wrp count_value
//   over 427 failing endpoints in those two clock groups.
//
//   Now:
//   mem_clk  (capture_clk 300 MHz): stream intake, slot selection, byte
//       accounting, geometry checks, AXI4 AW/W/B master and the authoritative
//       slot bookkeeping.  Nothing here crosses a clock boundary
//       combinationally; s_axis_tready is generated in the domain of the FIFO it
//       drains and the payload FIFO is a same-clock elastic buffer.
//   pcie_clk (pcie_user_clk 125 MHz): the CSR-facing register shell.  It owns
//       the published config bundle, the release requests and every status
//       read-back.
//   Crossings, one direction and one idiom each:
//     * config bundle {enable, dst_base, slot_bytes, slot_count, frame_bytes,
//       auto_advance, force_slot}: one ordered snapshot through
//       rtl/qpcie_csr_cdc.v, which carries the bus inside an async FIFO whose
//       commit is gated by src_ready.  The destination copy cfg_m is replaced
//       only by a complete snapshot (held before use, never a torn field, never
//       sampled raw), and it resets to zero, so an un-programmed or offline
//       memory side refuses every beat.
//     * slot release: one toggle PER SLOT (a bus is never published), each
//       through its own xpm_cdc_single and edge-detected in mem_clk.
//     * slot ready, busy, the three sticky levels and axi_err: single-bit levels
//       through xpm_cdc_single.
//     * completion: ONE record {slot index, event} through a second
//       rtl/qpcie_csr_cdc.v instance (section 3c).  Slot identity and the event
//       that proves it leave in the SAME FIFO word and are re-registered in the
//       SAME destination cycle (qpcie_csr_cdc.v:129-130), so ov_write_slot can
//       never name a slot other than the one whose ready bit this completion
//       just set.  Three independent xpm_cdc_single chains (two index levels plus
//       a done toggle) gave that no guarantee at all: equal synchroniser depth is
//       not equal arrival between unrelated clocks, and the destination sampled
//       the levels only on the event edge, so a shorter event path latched the
//       PREVIOUS completion's slot and held it until the next completion.  That
//       is ABI visible: ov_write_slot -> ovl_wr_active_slot
//       (rtl/custom_pcie_dma_top.v:1881) -> BAR0 STATUS2[8:6]
//       (rtl/sc7f0_rgb_overlay_ctrl.v:46,368), i.e. an IRQ handler would clear
//       the ready bit of a plane Reader-B may be scanning and leave the plane
//       that really landed unreleased.
//     * the completion record is held in the payload domain until the CSR domain
//       has ANNOUNCED it (a one-toggle consumption ack comes back through
//       xpm_cdc_single), and while it is held no new frame may start, so at most
//       ONE record can ever be outstanding.  A destination clock that stops or a
//       PCIe-shell reset that lands while the payload side is live delays that
//       record; it cannot lose it, duplicate it or re-associate it.  A payload reset does discard it, which is the point:
//       that plane's ready bit is discarded by the same reset, so a completion
//       known to be stale can never come back as a phantom IRQ.
//     * frames_done, the delivered-beat count and the error-frame count:
//       xpm_cdc_gray, each strictly +1 per increment, which is the lossless case
//       the primitive requires.  These three are STATUS read-backs: the gray
//       destination copy of a 300 MHz counter sampled by a 125 MHz CSR may show
//       an older value for a few destination clocks and may skip intermediate
//       values.  That is legal for a monitor and is the documented meaning of
//       ov_bytes_written ("beats delivered so far, at least"); plane correctness
//       never depends on it - publication travels as the bundled completion
//       record of section 3c plus the ready_r level, which
//       are single-bit events, and a CSR reader decides "this plane is complete"
//       from ov_slot_ready + ov_frames_done having advanced, both of which are
//       monotone.  What is asserted here, and tested, is therefore monotonicity
//       and "never ahead of the bus", not instantaneous equality.
//   so no multi-bit bus crosses a clock boundary without an ordered enable, and
//   no cross-domain reset is combined in front of a synchroniser.
// ============================================================================

module sc7f0_overlay_writer #(
    parameter integer DATA_WIDTH = 128,
    parameter integer ADDR_WIDTH = 49,
    parameter integer FIFO_DEPTH = 1024,          // 1024 x 128 bit = 16 kB burst buffer
    parameter integer MAX_SLOTS  = 4,
    parameter integer OUTSTANDING_MAX = 4         // write bursts in flight, bounded
)(
    // ---- PCIe user clock domain: CSR shell --------------------------------
    input  wire                     clk,
    input  wire                     rst_n,
    // Review M6: the AXI write-response debt record lives in this epoch, not in the
    // video reset.  mem_rst_n at the card is dp_mem_rst_n = dp_mem_all_n, the
    // sc7f0_reset_sync of {sys_300m_rst_n, sys_100m_rst_n} into capture_clk
    // (rtl/zu4ev_pcie_card_top.v:249-253) - a video/system reset.  It says nothing
    // about write responses the interconnect still holds for the PS, so clearing the
    // debt record there would be exactly the "quiet window called safe" mistake in a
    // different domain.  epoch_rst_n is pcie_user_rst_n (user_lnk_up && ~user_reset),
    // the boundary at which the host's outstanding transactions are provably gone.
    input  wire                     epoch_rst_n,

    // ---- payload stream, mem_clk (the ingress FIFO's read domain) --------
    input  wire [DATA_WIDTH-1:0]    s_axis_tdata,
    input  wire                     s_axis_tvalid,
    input  wire                     s_axis_tuser,   // start of a pushed transfer
    input  wire                     s_axis_tlast,
    output wire                     s_axis_tready,

    // control, BAR0 bank 0x0A, pcie_clk levels; they cross as one snapshot
    input  wire                     ov_enable,
    input  wire [ADDR_WIDTH-1:0]    ov_dst_base,
    input  wire [31:0]              ov_slot_bytes,
    input  wire [2:0]               ov_slot_count,  // 1..MAX_SLOTS
    input  wire [31:0]              ov_frame_bytes,
    input  wire                     ov_auto_advance,
    input  wire [1:0]               ov_force_slot,
    input  wire [MAX_SLOTS-1:0]     ov_consume,     // one-pulse-per-slot release
    input  wire                     ov_abort,       // discard the plane in flight

    // status, published in pcie_clk
    output reg                      ov_busy,
    output wire [MAX_SLOTS-1:0]     ov_slot_ready,
    output reg  [1:0]               ov_write_slot,
    output reg  [31:0]              ov_frames_done,
    output reg  [31:0]              ov_bytes_written,
    output reg                      ov_stall_sticky,    // slot still in use
    output reg                      ov_over_sticky,     // stream past frame end
    output reg                      ov_axi_err_sticky,  // BRESP != OKAY
    output reg                      ov_misalign_sticky, // geometry not 256 B
    output reg                      ov_err_frame_sticky,// a frame was dropped by BRESP
    output reg                      ov_abort_sticky,    // a plane was discarded
    output reg  [31:0]              ov_err_frames,      // frames dropped, never published
    output reg                      ov_abort_busy,      // retirement in progress
    input  wire [7:0]               s_axis_avail_in,    // ingress read side, mem_clk
    output reg                      ov_irq_pulse,       // frame complete

    // ---- memory clock domain: intake + AXI4 master ------------------------
    input  wire                     mem_clk,
    input  wire                     mem_rst_n,
    input  wire [MAX_SLOTS-1:0]     ov_slot_release_m,
    output wire [MAX_SLOTS-1:0]     ov_slot_ready_m,
    output reg  [1:0]               ov_last_slot_m,
    output wire [31:0]              ov_slot_bytes_m,
    output reg  [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output reg  [7:0]               m_axi_awlen,
    output wire [2:0]               m_axi_awsize,
    output wire [1:0]               m_axi_awburst,
    output wire [3:0]               m_axi_awcache,
    output reg                      m_axi_awvalid,
    input  wire                     m_axi_awready,

    output wire [DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [(DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                     m_axi_wlast,
    output wire                     m_axi_wvalid,
    input  wire                     m_axi_wready,

    input  wire [1:0]               m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output wire                     m_axi_bready
);
    localparam integer BYTES_PER_BEAT = DATA_WIDTH/8;             // 16
    localparam integer BURST_BEATS    = 16;                       // 256 B
    localparam integer BURST_BYTES    = BYTES_PER_BEAT*BURST_BEATS;
    localparam integer OCC_W          = $clog2(FIFO_DEPTH) + 1;
    localparam [3:0] LAST_BEAT_IDX    = BURST_BEATS - 1;   // beat 15 of the burst
    localparam [7:0] AWLEN_BURST      = BURST_BEATS - 1;   // axi awlen = beats - 1

    assign m_axi_awsize  = 3'b100;                 // 16 bytes
    assign m_axi_awburst = 2'b01;                  // INCR
    assign m_axi_awcache = 4'b0011;                // bufferable, modifiable
    assign m_axi_wstrb   = {(DATA_WIDTH/8){1'b1}};
    assign m_axi_bready  = 1'b1;                   // B is always accepted

    // ------------------------------------------------------------------------
    // 1. config bundle: pcie_clk -> mem_clk, one ordered snapshot
    // ------------------------------------------------------------------------
    localparam integer W_FRC     = 2;
    localparam integer W_AUTO    = 1;
    localparam integer W_FRAMEB  = 32;
    localparam integer W_NSLOT   = 3;
    localparam integer W_SLOTB   = 32;
    localparam integer W_DST     = ADDR_WIDTH;
    localparam integer W_ENABLE  = 1;
    localparam integer I_FRC     = 0;
    localparam integer I_AUTO    = I_FRC     + W_FRC;
    localparam integer I_FRAMEB  = I_AUTO    + W_AUTO;
    localparam integer I_NSLOT   = I_FRAMEB  + W_FRAMEB;
    localparam integer I_SLOTB   = I_NSLOT   + W_NSLOT;
    localparam integer I_DST     = I_SLOTB   + W_SLOTB;
    localparam integer I_ENABLE  = I_DST     + W_DST;
    localparam integer CFG_W     = I_ENABLE  + W_ENABLE;

    wire [CFG_W-1:0] cfg_bus = {ov_enable, ov_dst_base, ov_slot_bytes,
                                ov_slot_count, ov_frame_bytes,
                                ov_auto_advance, ov_force_slot};

    // The bank (this register) is authoritative in pcie_clk and gates its own
    // commit with src_ready, exactly the contract rtl/qpcie_csr_cdc.v states:
    // src_commit is asserted on the same edge that updates the bank, so the
    // snapshot that arrives can never be a half-written bundle.
    reg  [CFG_W-1:0] cfg_bank;
    wire             cfg_ready, cfg_online;
    wire [CFG_W-1:0] cfg_m;
    wire             cfg_changed = (cfg_bus != cfg_bank);
    wire             cfg_commit  = cfg_changed && cfg_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cfg_bank <= {CFG_W{1'b0}};
        else if (cfg_commit) cfg_bank <= cfg_bus;
    end

    qpcie_csr_cdc #(.LEVEL_WIDTH(CFG_W), .EVENT_WIDTH(1)) u_cfg_cdc (
        .src_clk        (clk),
        .src_rst_n      (rst_n),
        .dest_clk       (mem_clk),
        .dest_rst_n     (mem_rst_n),
        .src_level      (cfg_bus),
        .src_event      (1'b0),
        .src_commit     (cfg_commit),
        .src_ready      (cfg_ready),
        .src_online     (cfg_online),
        .src_peer_ready (),
        .dest_peer_ready(),
        .dest_level     (cfg_m),
        .dest_event     ()
    );

    wire                    c_enable      = cfg_m[I_ENABLE];
    wire [ADDR_WIDTH-1:0]   c_dst_base    = cfg_m[I_DST    +: W_DST];
    wire [31:0]             c_slot_bytes  = cfg_m[I_SLOTB  +: W_SLOTB];
    wire [2:0]              c_slot_count  = cfg_m[I_NSLOT  +: W_NSLOT];
    wire [31:0]             c_frame_bytes = cfg_m[I_FRAMEB +: W_FRAMEB];
    wire                    c_auto_adv    = cfg_m[I_AUTO];
    wire [1:0]              c_force_slot  = cfg_m[I_FRC    +: W_FRC];

    // ------------------------------------------------------------------------
    // 2. slot release: one toggle per slot, never a published index
    // ------------------------------------------------------------------------
    // Declaration block for everything the crossings below reference: with
    // `default_nettype none an identifier may not be introduced by its port
    // connection, so the memory-domain objects are declared before the
    // synchroniser instances that name them.
    reg  [MAX_SLOTS-1:0]  ready_r;                // authoritative, mem domain
    reg  [MAX_SLOTS-1:0]  rel_tgl;                // published in pcie_clk
    // Completion record, owned by the intake process below (section 3c + 6).
    // Neither the slot index nor the event may be Gray-coded here: a one-hot slot
    // marker is not a Gray code (0001 -> 0010 flips two bits) and the index
    // sequence 0,1,2,3,0 is not one either, and neither may the two bits be
    // crossed as independent levels beside a separate event (review M10).  They
    // cross together as one qpcie_csr_cdc word, so cmpl_slot is only ever used by
    // the destination in the same cycle as the cmpl_event it belongs to.
    reg  [1:0]            cmpl_slot;              // slot this completion belongs to
    reg                   cmpl_req;               // record held until stored
    reg                   cmpl_taken;             // the crossing took the commit
    reg                   active_m;               // intake of a frame in progress
    reg                   job_open;               // a frame is open on the AXI bus
    wire                  busy_m;                 // intake or drain in progress
    wire                  frame_done;             // final B of the open frame
    reg  [31:0]           frames_m;
    reg  [31:0]           cnt_beats;              // beats delivered to AXI, since reset
    // Owned entirely by the AXI master process below (reset and increment): it is
    // the source register of xpm_cdc_gray, and driving it from two processes made
    // it a genuinely multi-driven net.  Simulation resolved that silently in the
    // counter's favour; synthesis said "constant driver preserved, other driver
    // ignored", which would have frozen ov_bytes_written in hardware.
    reg                   stall_sticky_m, over_sticky_m, misalign_sticky_m;
    reg                   axi_err_level;
    // abort / error-frame accounting.  abort_tgl is the pcie_clk event copy of
    // ov_abort (a level or a single pulse, edge-latched so it cannot be lost);
    // abort_done_tgl is the memory side's acknowledgement that the plane is
    // fully retired.  err_frames_m is +1 only, so it may ride xpm_cdc_gray.
    reg                   abort_lvl_q, abort_tgl, abort_done_tgl;
    reg                   abort_sticky_m, err_frame_sticky_m;
    reg  [31:0]           err_frames_m;
    // Declared here because the intake (section 6) must see the retirement state
    // before the master (section 7) that owns it is written: with
    // `default_nettype none an identifier may not be introduced at its use.
    reg  [2:0]            ab_state;
    reg                   discard_retire, frame_err_seen;
    reg                   abort_busy_raw;
    // Debt: a toggle out of the memory domain, a level in the PCIe epoch domain, a
    // synchroniser back in.  Set by any unsolicited write response, cleared only by
    // the epoch reset - a BAR0 flush or a video reset cannot launder it.
    //
    // This crosses as a level REQUEST with an ACK, not as a toggle.  A toggle
    // cannot be re-synchronised: the epoch reset clears the destination
    // synchroniser but never the source, so after an ODD number of events every
    // later epoch reset saw a false edge and re-poisoned the very epoch whose
    // barrier is supposed to release it (measured in this suite: one injected
    // unsolicited B left every following recovery frame unpublished, across full
    // resets).  A level handshake has no state to fall out of step.
    reg                   debt_req = 1'b0;   // payload domain, cleared only by the ack
    wire                  debt_req_c;        // epoch domain view of debt_req
    reg                   debt_ack_lvl;      // epoch domain: the request was taken
    wire                  debt_ack_c;        // payload domain view of the ack
    reg                   debt_poison_epoch;
    reg  [1:0]            poison_sync;   // 2'b11 out of mem reset: fail closed
    wire                  debt_poisoned;
    // Deferred reset of the AXI front end (section 7b).  Declared here because
    // the payload FIFO and its occupancy counter below are reset by it, not by
    // the logical mem_rst_n: the beats the slave is still owed live in that FIFO
    // and its pointers must not be wiped under a held WVALID.
    // Both carry a configuration initial value: they are the only registers that
    // survive the very reset they delay, and 0 ("in reset, owes nothing") is the
    // proven-clean power-on state.  Without the initialiser fe_rst_r would be X
    // at time zero, the async clear would never have fired and the whole front
    // end would power up as X.
    reg                   fe_rst_r = 1'b0;
    wire                  fe_rst_n;
    reg                   fe_rst_req = 1'b0;  // a logical reset is pending (seen here)
    wire                  fe_retire_needed;
    wire                  frame_err_now;
    wire                  disc_active, disc_hold, disc_bucket;
    integer               i, k;

    wire [MAX_SLOTS-1:0] rel_m;
    wire                 abort_m;
    genvar ri;
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_abort (
        .src_clk(clk), .src_in(abort_tgl), .dest_clk(mem_clk),
        .dest_out(abort_m));
    generate
        for (ri = 0; ri < MAX_SLOTS; ri = ri + 1) begin : g_rel
            xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_rel (
                .src_clk(clk), .src_in(rel_tgl[ri]), .dest_clk(mem_clk),
                .dest_out(rel_m[ri]));
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 3. crossings from mem_clk back to the CSR shell (single bits only)
    // ------------------------------------------------------------------------
    wire [MAX_SLOTS-1:0] ready_lvl;
    wire busy_lvl, err_lvl, stall_lvl, over_lvl, misalign_lvl;
    wire [31:0] frames_c, beats_c;

    generate
        for (ri = 0; ri < MAX_SLOTS; ri = ri + 1) begin : g_ready
            xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_ready (
                .src_clk(mem_clk), .src_in(ready_r[ri]), .dest_clk(clk),
                .dest_out(ready_lvl[ri]));
        end
    endgenerate
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_busy (
        .src_clk(mem_clk), .src_in(busy_m), .dest_clk(clk), .dest_out(busy_lvl));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_err (
        .src_clk(mem_clk), .src_in(axi_err_level), .dest_clk(clk), .dest_out(err_lvl));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_stall (
        .src_clk(mem_clk), .src_in(stall_sticky_m), .dest_clk(clk),
        .dest_out(stall_lvl));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_over (
        .src_clk(mem_clk), .src_in(over_sticky_m), .dest_clk(clk), .dest_out(over_lvl));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_misalign (
        .src_clk(mem_clk), .src_in(misalign_sticky_m), .dest_clk(clk),
        .dest_out(misalign_lvl));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_abort_busy (
        .src_clk(mem_clk), .src_in(abort_busy_raw), .dest_clk(clk),
        .dest_out(abort_busy_lvl));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_abort_sticky (
        .src_clk(mem_clk), .src_in(abort_sticky_m), .dest_clk(clk),
        .dest_out(abort_sticky_lvl));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_err_frame (
        .src_clk(mem_clk), .src_in(err_frame_sticky_m), .dest_clk(clk),
        .dest_out(err_frame_lvl));
    reg                   abort_done_d;
    wire                  abort_done_lvl;
    wire                  abort_busy_lvl, abort_sticky_lvl, err_frame_lvl;
    wire [31:0]           err_frames_c;
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_abort_ack (
        .src_clk(mem_clk), .src_in(abort_done_tgl), .dest_clk(clk),
        .dest_out(abort_done_lvl));
    // Both counters are strictly +1 per increment (never reloaded, never
    // decremented), which is the lossless case xpm_cdc_gray documents; the
    // destination copy is a read-back status value only.
    //
    // INIT_SYNC_FF(1), the setting the rest of this design uses (custom_pcie_dma_top.v,
    // sc7f0_hdmi_probe.v): it initialises BOTH the source gray stage and the
    // destination synchroniser chain to zero, which is exactly the value these
    // counters hold out of reset, so a CSR read cannot sample an un-synchronised
    // value during the first few destination clocks.  This is a deliberate change
    // from the candidate's INIT_SYNC_FF(0) and is not related to the multi-driven
    // problem described at cnt_beats above.
    xpm_cdc_gray #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .WIDTH(32)) u_frames (
        .src_clk(mem_clk), .src_in_bin(frames_m), .dest_clk(clk),
        .dest_out_bin(frames_c));
    xpm_cdc_gray #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .WIDTH(32)) u_beats (
        .src_clk(mem_clk), .src_in_bin(cnt_beats), .dest_clk(clk),
        .dest_out_bin(beats_c));
    xpm_cdc_gray #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .WIDTH(32)) u_errf (
        .src_clk(mem_clk), .src_in_bin(err_frames_m), .dest_clk(clk),
        .dest_out_bin(err_frames_c));

    assign ov_slot_ready   = ready_lvl;
    assign ov_slot_ready_m = ready_r;
    assign ov_slot_bytes_m = c_slot_bytes;

    // ------------------------------------------------------------------------
    // 3c. completion: ONE bundled {slot, event} record, mem_clk -> pcie_clk
    //     (review M10; replaces two index levels + a done toggle).
    //
    // Why a bundle and not three synchronisers: qpcie_csr_cdc puts
    // {src_level, src_event} into ONE async-FIFO word and re-registers both in
    // the SAME destination cycle when it reads that word
    // (rtl/qpcie_csr_cdc.v:129-130), so the destination can only ever see a slot
    // index that travelled with its own event.  There is no relative-arrival
    // assumption left to make, so no set_max_delay / set_bus_skew pair is needed
    // to justify this crossing (and none is claimed).
    //
    // Source-side ownership, stated exactly (this is the part qpcie_csr_cdc does
    // NOT do for itself):
    //   * src_event is a LEVEL (cmpl_req), not a one-cycle pulse.  The module
    //     samples src_level/src_event on the cycle AFTER a commit (its `pending`
    //     stage), so a single-cycle event would be recorded as 0.
    //   * src_commit is only asserted while src_ready AND src_online.  The
    //     module's own src_ready is high while its src clock sees the destination
    //     offline, and commits are then ignored, so gating on ready alone would
    //     silently drop the completion of a frame that really landed.
    //   * cmpl_req is released only when the module has provably stored the word
    //     (it went ready again after the commit was taken).  While it is held,
    //     start_ok refuses every new frame, so at most one record can be in
    //     flight, the queue depth (16) is never approached, and a second
    //     completion cannot overwrite a slot the host has not been told about.
    //   * a destination that stops or resets flushes the queue and re-initialises
    //     with ZERO events (qpcie_csr_cdc.v header); cmpl_req is untouched by
    //     clk/rst_n/epoch_rst_n, so the record is re-committed once the
    //     destination is online again - delayed, once, never duplicated.
    //   * mem_rst_n DOES discard the record (same reset as ready_r / inflight_m,
    //     which it belongs to).  That is what keeps a completion known to be stale
    //     from reappearing as a phantom IRQ after a video reset; the old
    //     done_d-reset / done_tgl-no-reset alias could do exactly that.
    // ------------------------------------------------------------------------
    wire cmpl_commit, cmpl_ready, cmpl_online;
    wire [1:0] cmpl_slot_c;                       // destination copy, same word
    wire       cmpl_evt;                          // destination copy, one cycle

    // The commit is taken on this cycle, so cmpl_slot/cmpl_req must be stable for
    // the WHOLE record lifetime, and they are: cmpl_slot is only written on the
    // completion edge that sets cmpl_req, and a further completion cannot start
    // because start_ok refuses a new frame while cmpl_req is up.
    assign cmpl_commit = cmpl_req && cmpl_online && cmpl_ready && !cmpl_taken;

    // Consumption ack.  The record is released when the CSR domain has ANNOUNCED
    // it, never when the crossing has merely stored it: qpcie_csr_cdc resets its own
    // FIFO whenever src_online drops (rtl/qpcie_csr_cdc.v:113), so a word that was
    // stored but not yet read is destroyed if the destination clock stops.  A
    // stored-then-flushed word is a completion that silently vanishes, which is what
    // this ack exists to prevent (measured in this suite: the record of a published
    // frame was gone and no IRQ ever followed).
    //
    // The ack is one toggle per announcement and its source register deliberately
    // carries NO reset: rst_n clearing it while the payload side still remembered the
    // old level would manufacture a false consumption edge - the same aliasing family
    // as the old done_d / done_tgl pair this change removed.  One toggle per event
    // cannot be mis-paired here, because a second record cannot exist before the
    // first one is released and the release IS this edge: start_ok blocks the whole
    // next frame while cmpl_req is up, so an arriving ack edge always belongs to the
    // record that is outstanding.
    //
    // Why this cannot duplicate an announcement either: the ack reaches the payload
    // domain in one destination clock plus DEST_SYNC_FF(4) source clocks, while
    // qpcie_csr_cdc cannot declare the destination offline in fewer than 254 source
    // clocks (its heartbeat age walks 0..0xfe, rtl/qpcie_csr_cdc.v:45-67).  A record
    // can only be re-armed on that offline transition, so the ack of a delivered
    // record always lands long before any re-commit could be issued.  That bound is a
    // property of the module, not a timeout tuned to a simulation.
    reg  cmpl_ack_tgl = 1'b0;             // pcie_clk; no reset, on purpose
    wire cmpl_ack_c;                      // payload-domain view of it
    reg  cmpl_ack_d = 1'b0;               // edge detector copy
    wire cmpl_ack_e = cmpl_ack_c ^ cmpl_ack_d;
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_cmpl_ack (
        .src_clk(clk), .src_in(cmpl_ack_tgl), .dest_clk(mem_clk),
        .dest_out(cmpl_ack_c));

    qpcie_csr_cdc #(.LEVEL_WIDTH(2), .EVENT_WIDTH(1)) u_cmpl_cdc (
        .src_clk        (mem_clk),
        .src_rst_n      (mem_rst_n),
        .dest_clk       (clk),
        .dest_rst_n     (rst_n),
        .src_level      (cmpl_slot),
        .src_event      (cmpl_req),
        .src_commit     (cmpl_commit),
        .src_ready      (cmpl_ready),
        .src_online     (cmpl_online),
        .src_peer_ready (),
        .dest_peer_ready(),
        .dest_level     (cmpl_slot_c),
        .dest_event     (cmpl_evt)
    );

    // ------------------------------------------------------------------------
    // 4. pcie_clk shell: publish release requests, register read-back status
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < MAX_SLOTS; k = k + 1) rel_tgl[k] <= 1'b0;
            abort_lvl_q        <= 1'b0;
            abort_tgl          <= 1'b0;
            abort_done_d       <= 1'b0;
            ov_busy            <= 1'b0;
            ov_write_slot      <= 2'd0;
            ov_frames_done     <= 32'd0;
            ov_bytes_written   <= 32'd0;
            ov_stall_sticky    <= 1'b0;
            ov_over_sticky     <= 1'b0;
            ov_axi_err_sticky  <= 1'b0;
            ov_misalign_sticky <= 1'b0;
            ov_err_frame_sticky<= 1'b0;
            ov_abort_sticky    <= 1'b0;
            ov_abort_busy      <= 1'b0;
            ov_err_frames      <= 32'd0;
            ov_irq_pulse       <= 1'b0;
        end else begin
            // a release is a per-slot event: flip that slot's toggle only
            if (ov_consume[0]) rel_tgl[0] <= ~rel_tgl[0];
            if (ov_consume[1]) rel_tgl[1] <= ~rel_tgl[1];
            if (ov_consume[2]) rel_tgl[2] <= ~rel_tgl[2];
            if (ov_consume[3]) rel_tgl[3] <= ~rel_tgl[3];

            ov_busy            <= busy_lvl;
            ov_axi_err_sticky  <= err_lvl;
            ov_stall_sticky    <= stall_lvl;
            ov_over_sticky     <= over_lvl;
            ov_misalign_sticky <= misalign_lvl;
            ov_err_frame_sticky<= err_frame_lvl;
            ov_abort_sticky    <= abort_sticky_lvl;
            ov_abort_busy      <= abort_busy_lvl;
            ov_frames_done     <= frames_c;
            ov_err_frames      <= err_frames_c;
            // bytes = beats * BYTES_PER_BEAT, and BYTES_PER_BEAT is 16, so the
            // read-back is the Gray-crossed beat count shifted - no second
            // counter to keep in step and no multi-bit bus to tear.
            ov_bytes_written   <= {beats_c[27:0], 4'd0};
            // one-hot from the memory domain; at most one bit is ever set by the
            // writer, so the priority decode only matters in the few synchroniser
            // cycles in which a new slot is being published.
            ov_irq_pulse <= 1'b0;
            // One bundled record: the slot and the completion event arrived in the
            // same destination cycle from the same crossing word, so the slot this
            // IRQ names is the slot whose ready bit this completion set.  There is
            // deliberately no edge detector on a separate level here any more: the
            // old `done_lvl != done_d` combined a reset cleared with a source
            // toggle it did not clear, which manufactured one IRQ with a stale
            // slot after a PCIe-side reset (review M10 / M6 LOW).
            if (cmpl_evt) begin
                ov_write_slot <= cmpl_slot_c;
                ov_irq_pulse  <= 1'b1;
                // one ack per announcement; cmpl_ack_tgl carries no reset (see its
                // declaration)
                cmpl_ack_tgl  <= ~cmpl_ack_tgl;
            end
            // ov_abort is edge-latched into a toggle: the memory side is the
            // FASTER clock here (300 vs 125 MHz), so every level change is seen,
            // and a one-cycle pcie_clk request cannot be missed by the destination
            // synchroniser.
            abort_lvl_q <= ov_abort;
            if (ov_abort && !abort_lvl_q) abort_tgl <= ~abort_tgl;
            abort_done_d <= abort_done_lvl;
        end
    end

    // ------------------------------------------------------------------------
    // 5. mem_clk payload BURST elastic buffer.
    //    Both ends are mem_clk: the buffer decouples the intake from the 256 B
    //    bursts of the AXI master, it is no longer a clock crossing (the only
    //    payload crossing in this path is inside sc7f0_overlay_ingress.v).  It
    //    holds FIFO_DEPTH beats, which is 64 bursts at the default depth and
    //    0.05% of a 4K60 RGBA frame - by design, because the master drains it
    //    while the intake fills it.
    // ------------------------------------------------------------------------
    wire [DATA_WIDTH-1:0] fifo_dout;
    wire                  fifo_wready, fifo_rvalid;
    reg                   accept;                 // this beat is being taken
    wire                  fifo_push, fifo_pop, fifo_rready;

    sc7f0_dp_fifo #(
        .WIDTH    (DATA_WIDTH),
        .DEPTH    (FIFO_DEPTH),
        .MEMORY   ("block"),
        .W_SOURCES(1),
        .R_SOURCES(1)
    ) u_data (
        .wclk  (mem_clk),
        .wrst_n({fe_rst_n}),
        .wdata (s_axis_tdata),
        .wvalid(fifo_push),
        .wready(fifo_wready),
        .rclk  (mem_clk),
        .rrst_n({fe_rst_n}),
        .rdata (fifo_dout),
        .rvalid(fifo_rvalid),
        .rready(fifo_rready)
    );

    // Occupancy, counted in the one clock both ends live in.  The primitives own
    // the storage, this only counts their handshakes, so it cannot disagree with
    // them: +1 exactly when a word is written, -1 exactly when one is popped.
    //
    // The intake is gated on THIS counter, not only on the primitive's full flag.
    // sc7f0_dp_fifo instantiates xpm_fifo_async, whose full/empty are registered
    // and derived from the read pointer after CDC_SYNC_STAGES(3) synchronisers -
    // used here with wr_clk == rd_clk, those flags are conservative rather than
    // exact.  Rather than depend on how much slack they leave, the intake stops
    // two beats early, so the stored depth is provably <= ACC_LIMIT + 1 =
    // FIFO_DEPTH - 1, i.e. inside the primitive's own memory with one beat to
    // spare.  One beat of a 1024-beat buffer costs nothing: one 256 B burst needs
    // 16.  Losslessness does not actually rest on this throttle either: a beat is
    // only taken when fifo_wready says the storage accepted it (sc7f0_dp_fifo.v
    // drives wready from !reset && !wr_busy && !full), so the occupancy gate is a
    // second, conservative bound on top of the handshake, not the only one.
    localparam [OCC_W-1:0] ACC_LIMIT = FIFO_DEPTH - 2;      // accept only up to here
    reg [OCC_W-1:0] fifo_occ;
    wire            fifo_room = (fifo_occ <= ACC_LIMIT);
    // Reset with the FIFO ITSELF (fe_rst_n), never with the logical mem_rst_n:
    // this counter is the writer's own model of the FIFO's pointers, and wiping
    // it while the storage still holds the beats an accepted AW is owed would
    // make the master under-run its own burst.
    always @(posedge mem_clk or negedge fe_rst_n) begin
        if (!fe_rst_n)
            fifo_occ <= {OCC_W{1'b0}};
        else
            fifo_occ <= fifo_occ + (fifo_push ? {{(OCC_W-1){1'b0}}, 1'b1}
                                              : {OCC_W{1'b0}})
                                   - (fifo_pop  ? {{(OCC_W-1){1'b0}}, 1'b1}
                                              : {OCC_W{1'b0}});
    end

    // ------------------------------------------------------------------------
    // 6. mem_clk intake / slot selection / per-transfer geometry
    // ------------------------------------------------------------------------
    reg  [31:0] cnt_frame;                        // bytes taken, this transfer
    reg         over_wait;                        // frame done, source still pushing
    reg  [1:0]  wslot;
    reg  [MAX_SLOTS-1:0] rel_m_d;
    reg  [MAX_SLOTS-1:0] inflight_m;              // slot holds an unfinished write
    reg  [ADDR_WIDTH-1:0] job_addr_m;
    reg  [31:0]   job_bytes_m;
    reg  [1:0]    job_slot_m;
    reg           job_start;                      // one cycle, same domain

    wire [2:0] slots_n = (c_slot_count == 3'd0) ? 3'd1 :
                         ((c_slot_count > MAX_SLOTS[2:0]) ? MAX_SLOTS[2:0]
                                                          : c_slot_count);
    wire       slot_in_use = (wslot < MAX_SLOTS[2:0]) ? ready_r[wslot] : 1'b0;

    // When auto-advancing, skip any slot still held by Reader-B (ready_r) or
    // in flight so the writer can never deadlock against the 1 slot on display.
    wire [1:0] wslot_p1 = ({1'b0, wslot} == (slots_n - 3'd1)) ? 2'd0 : (wslot + 2'd1);
    wire [1:0] wslot_p2 = ({1'b0, wslot_p1} == (slots_n - 3'd1)) ? 2'd0 : (wslot_p1 + 2'd1);
    wire [1:0] wslot_p3 = ({1'b0, wslot_p2} == (slots_n - 3'd1)) ? 2'd0 : (wslot_p2 + 2'd1);
    reg  [1:0] next_free_wslot;
    always @(*) begin
        if      (!ready_r[wslot_p1] && !inflight_m[wslot_p1]) next_free_wslot = wslot_p1;
        else if (!ready_r[wslot_p2] && !inflight_m[wslot_p2]) next_free_wslot = wslot_p2;
        else if (!ready_r[wslot_p3] && !inflight_m[wslot_p3]) next_free_wslot = wslot_p3;
        else                                                  next_free_wslot = wslot_p1;
    end

    // The payload FIFO is a burst buffer, so its depth says nothing about how
    // long a frame may be.  A frame is bounded by its SLOT and by the 256 B
    // geometry rule only; 33,177,600 B of 4K60 RGBA8888 is a legal program and
    // must stream through the 16 KiB buffer without a special case.
    localparam [31:0] FIFO_BYTES = FIFO_DEPTH * BYTES_PER_BEAT;   // 16 kB, unused here
    wire       capacity_ok = 1'b1;
    // Address bounds: a frame must fit in its own slot, otherwise the master
    // would run off the end of the image the host allocated.
    wire       fits_slot = (c_frame_bytes != 32'd0) &&
                           (c_frame_bytes <= c_slot_bytes);
    wire       aligned   = (c_frame_bytes[7:0] == 8'h00) &&
                           (c_slot_bytes[7:0]  == 8'h00) &&
                           (c_dst_base[7:0]    == 8'h00) &&
                           fits_slot && capacity_ok;

    // The LENGTH of an accepted transfer is captured when its first beat is
    // taken and held until the last burst has been acknowledged, and the address
    // and slot are frozen in job_addr_m / job_slot_m for exactly as long (both
    // are written on the start-of-frame cycle only and never touched again until
    // the final B).  A CSR write that lands half way through a frame therefore
    // cannot re-aim or re-lengthen the frame that is already being written,
    // because the host has been promised that slot image.  Later changes take
    // effect on the next transfer, which is the documented contract for this
    // bank.
    reg  [31:0]           xfer_bytes_q;           // frame length of this transfer

    wire [31:0] eff_bytes = active_m ? xfer_bytes_q : c_frame_bytes;

    // ------------------------------------------------------------------------
    //  room  (critical-path rewrite, three-cones review A)
    //
    //  The original expression `cnt_frame + BYTES_PER_BEAT <= eff_bytes` is a
    //  32-bit add plus a 32-bit compare, and it is the single trunk that feeds
    //  both payload-FIFO enable cones (14 of the 24 failing SETUP endpoints).
    //  Replaced by a registered remaining-BEAT predicate: `bleft` is loaded at
    //  the start-of-frame edge with the frame's beat count minus one, and is
    //  decremented on exactly `active_m && accept`, i.e. the same edge class as
    //  cnt_frame.  `room` then degenerates to a zero/non-zero test (OR reduce,
    //  no carry chain).
    //
    //  `cnt_frame` and the byte-domain `eof_beat` below are kept BIT-FOR-BIT
    //  unchanged, so the eof -> active_m / over_wait / wslot / slot-publish
    //  paths cannot regress; `bleft` is only an intake predicate.  `bleft` is
    //  owned by the SAME always block as cnt_frame (posedge mem_clk / negedge
    //  mem_rst_n) and is cleared by exactly the branches that clear cnt_frame
    //  (reset, discard_retire, global eof).  It is NOT the FIFO occupancy
    //  ledger and is NOT reset by fe_rst_n / epoch.
    //
    //  Exactness for the fast path requires BYTES_PER_BEAT to be a power of two
    //  that divides 256 (so `aligned`, which demands c_frame_bytes[7:0]==0,
    //  implies BYTES_PER_BEAT | eff_bytes and cnt_frame in {0,B,k*B}); then
    //      bleft == eff/B - 1 - (accepted beats so far)
    //      |bleft  <=>  cnt_frame + B <= eff
    //  for every reachable active state.  Any OTHER parameter class (odd B,
    //  B > 256) keeps the ORIGINAL expression verbatim through the generate
    //  fallback below, rather than adding a new start-up geometry restriction.
    // ------------------------------------------------------------------------
    localparam integer BPL       = $clog2(BYTES_PER_BEAT);
    localparam integer BPL_W     = 32 - BPL;                 // bleft width
    localparam integer ROOM_FAST = (((BYTES_PER_BEAT & (BYTES_PER_BEAT - 1)) == 0)
                                    && (BYTES_PER_BEAT <= 256)) ? 1 : 0;

    reg  [BPL_W-1:0] bleft;                                  // beats still owed
    wire             room;

    generate
        if (ROOM_FAST == 1) begin : g_room_beats
            assign room = |bleft;
        end else begin : g_room_bytes
            assign room = (cnt_frame + BYTES_PER_BEAT[31:0]) <= eff_bytes;
        end
    endgenerate
    // A new frame may only start once the previous one is finished on the bus:
    // the master's byte accounting, and the FIFO, describe exactly one frame.
    // It may also not start while an abort is being retired: the FIFO, the byte
    // counters and the AXI credit still describe the dead plane until the
    // retirement reaches AB_DONE, and rtl/custom_pcie_dma_top.v holds the ingress
    // arm off for exactly as long (ov_abort_busy).
    // !cmpl_req is the completion-record bound of review M10: a frame may not open
    // until the CSR domain has announced the previous one, so the one outstanding
    // record property of section 3c holds by construction, the crossing queue (16
    // words) can never be approached, and a completion can never be overtaken by the
    // frame that would reuse its slot.  Normally this costs a few destination clocks
    // (commit, read, ack); it only goes long when the CSR clock has stopped, in which
    // case the host cannot have armed anything anyway.
    wire        start_ok  = c_enable && aligned && !slot_in_use &&
                            !inflight_m[wslot] && !job_open && !disc_active &&
                            !cmpl_req;

    // AB_DRAIN / AB_FLUSH hold the source off (the dead plane owns the FIFO and
    // the AXI credit); AB_FENCE deliberately ACCEPTS and drops, because draining
    // the upstream crossing by consuming it is the only way to prove that no byte
    // of the old payload is left to become the head of the next frame.
    assign s_axis_tready = c_enable && fifo_wready && fifo_room && !disc_hold &&
                           (active_m ? (room && !s_axis_tuser)
                                     : (s_axis_tuser && start_ok));
    // A beat is taken on the handshake, not on tready alone: tready is high for
    // every cycle a transfer is active and the FIFO has room, so gating the write
    // enable on it without s_axis_tvalid stored the value the source left on the
    // bus during its own idle cycles (a duplicated beat at the head of every
    // frame) and counted bytes that were never streamed.
    //
    // A tuser beat that arrives while a frame is still open is REFUSED, not
    // absorbed (review M4): by the stream contract tuser means "first beat of a
    // new transfer", so accepting it would splice two planes into one slot with
    // no fault raised.  Holding tready is legal AXI-Stream backpressure, the
    // reason is latched in ov_over_sticky, and the state is recoverable: an
    // ov_abort retires the open frame and the next arm then starts cleanly.
    always @(*) accept = s_axis_tvalid && s_axis_tready && !disc_bucket;

    wire [ADDR_WIDTH-1:0] slot_addr =
        c_dst_base + {{(ADDR_WIDTH-2){1'b0}}, wslot} *
                     {{(ADDR_WIDTH-32){1'b0}}, c_slot_bytes};

    // sof = the frame's first beat is being taken, eof = its last one is.
    wire sof_beat = accept && !active_m;
    wire eof_beat = accept && ((cnt_frame + BYTES_PER_BEAT[31:0]) >= eff_bytes);
    // The AXI job is OPENED at sof, not at eof: from the first beat onwards the
    // master may drain every burst that is already buffered, which is exactly
    // what keeps a 33 MB frame inside a 16 KiB buffer.
    wire job_open_now = sof_beat;

    wire [MAX_SLOTS-1:0] rel_edge = rel_m ^ rel_m_d;

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            cnt_frame          <= 32'd0;
            bleft              <= {(BPL_W){1'b0}};
            over_wait          <= 1'b0;
            frames_m           <= 32'd0;
            wslot              <= 2'd0;
            cmpl_slot          <= 2'd0;
            cmpl_req           <= 1'b0;
            cmpl_taken         <= 1'b0;
            cmpl_ack_d         <= 1'b0;
            xfer_bytes_q       <= 32'd0;
            active_m           <= 1'b0;
            inflight_m         <= {MAX_SLOTS{1'b0}};
            job_addr_m         <= {ADDR_WIDTH{1'b0}};
            job_bytes_m        <= 32'd0;
            job_slot_m         <= 2'd0;
            job_start          <= 1'b0;
            rel_m_d            <= {MAX_SLOTS{1'b0}};
            ready_r            <= {MAX_SLOTS{1'b0}};
            ov_last_slot_m     <= 2'd0;
            stall_sticky_m     <= 1'b0;
            over_sticky_m      <= 1'b0;
            misalign_sticky_m  <= 1'b0;
            abort_sticky_m     <= 1'b0;
            err_frame_sticky_m <= 1'b0;
            err_frames_m       <= 32'd0;
        end else begin
            job_start <= 1'b0;
            rel_m_d   <= rel_m;

            if (c_enable && !aligned)     misalign_sticky_m <= 1'b1;

            // ---- completion record ownership (section 3c) -------------------
            // This block sits BEFORE the frame_done branch below on purpose: if a
            // new completion ever coincided with the release of the previous
            // record, the assignment in that branch is the later one and the new
            // completion wins, while the word already stored in the crossing
            // carries the older slot with it.  Nothing is lost in either order,
            // but only this order is guaranteed to keep the NEW completion.
            if (!cmpl_online) begin
                // The CSR clock is stopped, offline or in reset: the crossing
                // flushed its queue and will re-initialise with ZERO events.  Drop
                // the commit marker and KEEP the record, so the completion is
                // re-committed (once) when the destination comes back instead of
                // being declared lost.
                cmpl_taken <= 1'b0;
            end else if (cmpl_req && cmpl_ready && !cmpl_taken) begin
                cmpl_taken <= 1'b1;             // cmpl_commit is asserted now
            end
            // Released by the ANNOUNCEMENT, never by the store and never by a
            // timeout.  A destination clock that is gone for good therefore keeps the
            // record and keeps start_ok low: fail closed, no lost completion.  The
            // commit marker goes with the record, so the next frame can arm its own.
            if (cmpl_ack_e) begin
                cmpl_req   <= 1'b0;
                cmpl_taken <= 1'b0;
            end
            cmpl_ack_d <= cmpl_ack_c;

            // release is honoured in any state: the slot stops being readable
            for (i = 0; i < MAX_SLOTS; i = i + 1)
                if (rel_edge[i] || ov_slot_release_m[i]) ready_r[i] <= 1'b0;

            if (frame_done) begin
                // Published only now, and only if the frame is entitled to be:
                // the last burst has just been acknowledged, every W beat of the
                // frame was accepted, and nothing invalidates the frame - no
                // BRESP error on ANY burst of this frame (review H3), no abort
                // (H1), no unsolicited completion on the interface (M6).  A frame
                // that fails that test is dropped: the slot leaves inflight so
                // the next frame may use it, but ready_r, frames_m and the
                // completion record (the IRQ) stay untouched, because handing
                // Reader-B a plane with
                // a failed burst in it is worse than handing it nothing.
                //
                // The error term is taken combinationally from THIS cycle's B
                // (m_axi_bresp while b_fire) ORed with the per-frame history:
                // reading only the registered flag would let an error on the very
                // last B publish the frame one clock before the sticky lands.
                //
                // This assignment sits after the release loop on purpose: a
                // consume that races the completion edge is out of contract (the
                // writer had published nothing for the reader to take yet), and
                // clearing ready here would silently drop an image that has been
                // delivered in full.  Losing a release is recoverable, losing a
                // delivered frame is not.
                inflight_m[job_slot_m] <= 1'b0;
                if (frame_err_now) begin
                    ready_r[job_slot_m] <= 1'b0;   // never publish a faulted frame
                    if (frame_err_seen || (m_axi_bresp != 2'b00)) begin
                        err_frame_sticky_m <= 1'b1;
                        err_frames_m       <= err_frames_m + 32'd1;
                    end
                end else begin
                    ready_r[job_slot_m]    <= 1'b1;
                    ov_last_slot_m         <= job_slot_m;
                    frames_m               <= frames_m + 32'd1;
                    // One record for this completion: the slot it belongs to and
                    // the event that announces it leave as the same crossing word
                    // (section 3c).  A frame that fails the publication test never
                    // raises the record either, so a faulted plane cannot announce
                    // itself even one cycle later.
                    cmpl_req               <= 1'b1;
                    cmpl_slot              <= job_slot_m;
                end
            end

            // The abort retirement finished (AB_DONE: one cycle, and the intake
            // is still held off during it, so no new frame can race these
            // clears).  The dead plane leaves nothing behind: no byte count, no
            // slot marked busy or ready, no residual active flag.
            if (discard_retire) begin
                active_m               <= 1'b0;
                cnt_frame              <= 32'd0;
                if (ROOM_FAST) bleft   <= {(BPL_W){1'b0}};
                over_wait              <= 1'b0;
                inflight_m[job_slot_m] <= 1'b0;
                ready_r[job_slot_m]    <= 1'b0;
                abort_sticky_m         <= 1'b1;
            end

            if (sof_beat) begin
                active_m       <= 1'b1;
                cnt_frame      <= BYTES_PER_BEAT[31:0];
                xfer_bytes_q   <= c_frame_bytes;
                // One beat is being taken RIGHT NOW, so the register holds the
                // beats that are still owed AFTER this one: N-1, not N.  The
                // slice is exact because aligned forces the low 8 bits (hence
                // the low BPL bits) of c_frame_bytes to zero.
                if (ROOM_FAST) bleft <= c_frame_bytes[31:BPL] - 1'b1;
            end else if (active_m && accept) begin
                cnt_frame <= cnt_frame + BYTES_PER_BEAT[31:0];
                if (ROOM_FAST) bleft <= bleft - 1'b1;
            end

            if (job_open_now && aligned) begin
                // hand the job straight to the master in this same domain - no
                // quasi-static bus, no toggle, and nothing is waited for first.
                //
                // These are the FRESH combinational values, not xfer_*_q: on the
                // start-of-frame cycle the xfer latch is being written by this
                // same edge, so reading the registers here would open the job on
                // the PREVIOUS transfer's geometry (out of reset, on zeros).
                // slot_addr / c_frame_bytes / wslot are exactly what xfer_*_q
                // become at this edge, and this branch is only reachable on that
                // one cycle, so the frame keeps the address, length and slot it
                // started with no matter what the CSR bank does afterwards.
                job_addr_m  <= slot_addr;
                job_bytes_m <= c_frame_bytes;
                job_slot_m  <= wslot;
                job_start   <= 1'b1;
                inflight_m[wslot] <= 1'b1;
            end

            if (s_axis_tvalid && c_enable && s_axis_tuser && !active_m &&
                !start_ok) begin
                // a new transfer arrived while it may not start: stall and latch
                // the reason, never write into a slot Reader-B may scan
                if (!aligned || slot_in_use || inflight_m[wslot])
                    stall_sticky_m <= 1'b1;
            end

            // an over-long stream inside a live frame is refused too (belt and
            // braces: the length is latched, so room can only fail once the
            // frame's own byte count is reached), and so is a frame boundary that
            // appears in the middle of one (review M4)
            if (active_m && s_axis_tvalid &&
                ((!room && !accept) || (s_axis_tuser && !disc_active)))
                over_sticky_m <= 1'b1;

            // If the current wslot is held by Reader-B while idle, advance to a
            // free slot before the next frame arrives.
            if (c_auto_adv && !active_m && !job_open &&
                (ready_r[wslot] || inflight_m[wslot]) &&
                (!ready_r[next_free_wslot] && !inflight_m[next_free_wslot])) begin
                wslot <= next_free_wslot;
            end

            // The intake retires when the frame's last byte is taken; the master
            // keeps draining, and the slot stays protected until its final B
            // (and Reader-B release).
            if (eof_beat) begin
                active_m   <= 1'b0;
                cnt_frame  <= 32'd0;
                if (ROOM_FAST) bleft <= {(BPL_W){1'b0}};
                over_wait  <= 1'b1;      // this source transfer is now finished
                wslot      <= c_auto_adv ? next_free_wslot : c_force_slot;
            end

            // Bytes past the end of the frame.  Once a transfer's own byte count
            // has been taken, any FURTHER beat that the source presents for that
            // same transfer - which by the stream contract must be marked by
            // s_axis_tuser - is longer than the programmed frame, so it is
            // refused and the reason is latched.  Ordinary backpressure is NOT
            // mistaken for this: a beat inside a live frame that merely finds the
            // FIFO full keeps active_m set and room low, and a legitimate new
            // transfer always arrives with tuser, which clears over_wait instead
            // of setting anything.
            if (over_wait && s_axis_tvalid && !s_axis_tuser && !accept)
                over_sticky_m <= 1'b1;
            if (sof_beat) over_wait <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // 7. mem-domain streaming AXI4 write master; slot bookkeeping lives here.
    //
    //    AW, W and B are three concurrent processes over one byte-accounting
    //    triple, so a burst is acknowledged while the next one is already being
    //    streamed:
    //      beats_aw  beats covered by AWs already issued   (<= total)
    //      beats_w   W beats the interconnect has accepted (<= beats_aw)
    //      beats_b   bursts closed by B, in AW order       (<= beats_aw)
    //    The master may only cover a new burst when all BURST_BEATS of it are
    //    already in the FIFO, so it can never present a beat that does not exist.
    // ------------------------------------------------------------------------
    reg        aw_outstanding;
    reg  [31:0] beats_aw, beats_w, beats_b;
    reg  [31:0] total_beats;
    reg  [ADDR_WIDTH-1:0] addr_r;
    // ---- 7a. the reset of THIS front end is deferred, not immediate (review M6)
    //
    // mem_rst_n restarts the video path.  It does not restart the PS AXI slave
    // this master is talking to, and nothing in the PL can (see the OBLIGATION
    // RULE at the top of this file: the PS BD has no reset pin on S_AXI_HP3_FPD
    // at all, only saxihp3_fpd_aclk).  So while the interface still owes the
    // slave an answer, or the slave still owes this master a response, mem_rst_n
    // must NOT be allowed to clear this front end: it would withdraw AWVALID or
    // WVALID under stall (illegal), it would drop the payload whose beats an
    // accepted AW has a right to, and it would erase the very ledger that lets a
    // later response be recognised as the old one instead of being credited to a
    // brand new frame.
    //
    // So the logical reset is turned into the legal retirement this module
    // already has:
    //   fe_owed      an obligation exists (AW presented or accepted, W beats of
    //                it not yet delivered, bursts not yet answered, or a
    //                retirement in progress)
    //   fe_rst_req   the logical reset is asserted as seen in this clock
    //   fe_rst_n     reset actually applied to the master and its payload FIFO:
    //                the logical reset, delayed until fe_owed is false.  Held
    //                HIGH (out of reset) while anything is owed, so the AW/W/B
    //                outputs, their addresses and data, the beat ledger and the
    //                FIFO contents all keep their values, and the AB_* FSM runs
    //                the burst out and collects its B.
    // When the obligation really ends - proven by the B responses arriving, never
    // by a timeout - the front end is cleared while the logical reset is still up,
    // so the next frame starts from a proven-clean master.  Until then
    // ov_abort_busy and ov_busy stay asserted (rtl/custom_pcie_dma_top.v holds the
    // ingress arm off for exactly as long), aw_go refuses every new burst and
    // start_ok refuses every new frame, so an old response has no new job that it
    // could pay for.
    //
    // rstn_sync_l and fe_rst_r are the only registers here with no reset at all:
    // they carry the deferral decision through the very reset they are delaying,
    // and their configuration initial value (0) is the proven-clean start (PS POR
    // or a real HP3 reset, or an interface drained before the reload - see the
    // startup contract in the header).  Nothing here lets a CSR write, a PCIe
    // epoch or an elapsed quiet window declare the bus clean.
    // ---- abort retirement (review H1/M4) --------------------------------
    // One state machine owns the whole retirement, in the clock the AXI master
    // and the payload FIFO live in.  It never resets anything: it finishes what
    // the interface already committed to, then throws the dead payload away beat
    // by beat, then drains the upstream crossing by consuming it, and only then
    // acks.  AB_DONE exists so the intake-clearing pulse lands while the intake
    // is still held off, which is what keeps a brand new frame from racing the
    // retirement in the same cycle.
    localparam [2:0] AB_IDLE = 3'd0, AB_DRAIN = 3'd1, AB_FLUSH = 3'd2,
                     AB_FENCE = 3'd3, AB_DONE  = 3'd4;
    // The fence window is about THIS receiver's own pipeline, not about another
    // agent's latency: s_axis_tvalid and s_axis_avail_in are both read-side
    // signals of the ingress crossing FIFO in this same clock, so "empty and no
    // beat presented" is already the truth of the buffer; the count only covers
    // the registered read-data-count's own update lag.
    localparam [5:0] FENCE_HOLD = 6'd32;

    (* ASYNC_REG = "TRUE" *) reg [1:0] rstn_sync_l = 2'b00;
    always @(posedge mem_clk) rstn_sync_l <= {rstn_sync_l[0], mem_rst_n};
    always @(posedge mem_clk) fe_rst_req  <= ~rstn_sync_l[1];

    wire fe_owed = job_open || aw_outstanding || m_axi_awvalid || m_axi_wvalid ||
                   (beats_aw != beats_b) || (beats_w != beats_aw) ||
                   (ab_state != AB_IDLE);

    // the master comes out of reset only when the bus is free of it
    always @(posedge mem_clk) fe_rst_r <= rstn_sync_l[1] | fe_owed;
    assign fe_rst_n = fe_rst_r;
    // a logical reset that finds work outstanding is an abort request
    assign fe_retire_needed = fe_rst_req && fe_owed;

    reg  [5:0] fence_cnt;
    reg        abort_m_d, job_invalid;
    wire       abort_evt    = abort_m ^ abort_m_d;
    assign     disc_active  = (ab_state != AB_IDLE);
    assign     disc_hold    = (ab_state == AB_DRAIN) || (ab_state == AB_FLUSH);
    assign     disc_bucket  = (ab_state == AB_FENCE);
    wire       fifo_empty_l = (fifo_occ == {OCC_W{1'b0}});
    wire       flush_pop    = (ab_state == AB_FLUSH) && !fifo_empty_l && fifo_rvalid;
    wire       fence_clear  = (s_axis_avail_in == 8'd0) && !s_axis_tvalid &&
                              fifo_empty_l && !m_axi_wvalid && !m_axi_awvalid;
    wire       drain_free   = (beats_b == beats_aw) && !m_axi_wvalid &&
                              !m_axi_awvalid;

    // ---- review M6 gap C: a PCIe epoch boundary with the memory side alive -------
    // epoch_rst_n is pcie_user_rst_n (rtl/custom_pcie_dma_top.v:1876 connects it to
    // the top-level rst_n), and that same top-level reset also feeds this module's own
    // rst_n through dma_rst_n (rtl/custom_pcie_dma_top.v:562, sc7f0_reset_sync of
    // {global_reset_hold_n, ~reg_dma_ctrl[1], rst_n}), so when it falls the slot table,
    // the pool configuration and every piece of context that gives ov_write_slot any
    // meaning are on the far side of that reset.  A job still open at that moment
    // therefore must NOT be published: its completion would name a slot in a pool the
    // new epoch does not have, and a reader that has just reprogrammed a second base
    // address would credit the new pool with pixels the old job wrote.
    //
    // Its AXI debt, on the other hand, stays owed and is retired exactly, because a
    // master has no right to withdraw an AW or a W it has already presented.  So the
    // epoch edge raises the SAME logical retirement request that a front-end reset
    // raises (fe_retire_needed just above), for the same reasons: AB_DRAIN waits for
    // every B that is owed, the ledger is cleared only once the bus is genuinely free,
    // and job_invalid makes the frame unservable through frame_err_now instead of
    // quietly crediting it.  Nothing here clears the FIFO, the front end or the ledger
    // asynchronously, and an epoch boundary that finds the engine quiesced raises
    // nothing at all: no retirement, no sticky, no dropped-plane count.
    (* ASYNC_REG = "TRUE" *) reg [2:0] epoch_sync_l = 3'b111;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) epoch_sync_l <= 3'b111;   // fail high: no edge out of a reset
        else            epoch_sync_l <= {epoch_sync_l[1:0], epoch_rst_n};
    end
    wire epoch_fell         = epoch_sync_l[2] && !epoch_sync_l[1];
    wire epoch_inval_needed = epoch_fell && fe_owed;

    // bytes the master still holds back from the interconnect, plus what it has
    // already delivered: everything the FIFO can contain belongs to this frame
    wire [31:0] avail_beats   = beats_w + {{(32-OCC_W){1'b0}}, fifo_occ};
    wire [31:0] outstanding   = beats_aw - beats_b;
    wire        aw_credits    = outstanding < (OUTSTANDING_MAX*BURST_BEATS);
    wire        aw_in_frame   = (beats_aw + BURST_BEATS) <= total_beats;
    wire        aw_data_ready = (beats_aw + BURST_BEATS) <= avail_beats;
    // An abort forbids NEW bursts.  It cannot recall one that was already
    // presented: AXI gives a master no right to withdraw AWVALID or WVALID while
    // READY is low, and a half-presented burst would be a protocol violation on
    // the PS side, so everything already committed is carried out legally and is
    // then simply not published.
    wire        aw_go         = job_open && !aw_outstanding && aw_credits &&
                                aw_in_frame && aw_data_ready && !disc_active &&
                                !fe_rst_req;

    assign fifo_push = accept && fifo_wready;

    assign m_axi_wvalid = job_open && (beats_w < beats_aw) && fifo_rvalid;
    assign m_axi_wdata  = fifo_dout;
    // WLAST is derived from the delivered-beat count, which only moves on an
    // accepted beat, so it is stable for as long as WVALID is held without WREADY
    assign m_axi_wlast  = (beats_w[3:0] == LAST_BEAT_IDX);
    assign fifo_rready  = (m_axi_wvalid && m_axi_wready) || flush_pop;
    assign fifo_pop     = fifo_rvalid && fifo_rready;
    wire   w_fire       = m_axi_wvalid && m_axi_wready;

    wire   b_fire       = m_axi_bvalid && m_axi_bready && (beats_b < beats_aw);
    // A completion with no obligation behind it cannot be an answer to anything
    // this master issued (single ID, in order, every B matched to an AW it
    // presented).  Under the deferred reset above, a response to a burst this
    // master really issued is ALWAYS matched by the retained ledger, so reaching
    // this term means the receiver answered a burst nobody asked for.  It poisons
    // the epoch: from then on nothing is published, because a receiver that has
    // seen an unsolicited completion can no longer read a later B as proof that
    // its own write landed.
    //
    // What releases it is the PCIe epoch boundary (epoch_rst_n, pcie_user_rst_n
    // at the card).  Be clear about what that is and is not: it is an AGENT-SIDE
    // epoch on this side of the interface, and it is NOT a reset of the PS
    // S_AXI_HP3_FPD slave - the PS BD has no reset pin for HP0..HP3 at all, so
    // the only thing that genuinely restarts the receiver is a PS-side reset
    // (POR or a PS-initiated FPD reset), which no PL logic can generate or
    // observe.  No elapsed-time window can release the poison either: the arrival
    // of a response that is already on its way is unbounded.
    wire   b_unsolicited = m_axi_bvalid && m_axi_bready && (beats_b >= beats_aw);
    // Publication requires the last B AND every W beat of the frame accepted, so
    // no completion - stale or real - can publish a plane whose data is still on
    // the way to DDR.
    wire   w_all_done   = (beats_w >= total_beats) ||
                          (w_fire && ((beats_w + 32'd1) >= total_beats));
    assign frame_done   = b_fire &&
                          ((beats_b + BURST_BEATS[31:0]) >= total_beats) &&
                          w_all_done;
    // A frame is invalidated by an error on any of its bursts, including the one
    // being taken this very cycle (H3: reading only the registered flag would
    // publish a frame whose LAST B was a fault, one clock before the sticky).
    //
    // The three terminal retirement REQUESTS are in this expression for exactly the
    // same reason, and they are not covered by job_invalid: job_invalid is a
    // nonblocking assignment one stage later (section 8), so on the cycle where a
    // reset/abort request coincides with the LAST B, job_invalid still reads 0 and the
    // intake would take the success branch - ready bit, frames_done, and above all the
    // bundled completion record, which the later discard_retire can retract neither
    // (rtl/...:955-963 vs :975-980).  m_axi_bready is tied high, so a response can be
    // taken in any mem_clk cycle and this coincidence is not rare: with the epoch edge
    // and the final B one clock apart it is the normal case, not a corner.  A request
    // that terminal-publishes nothing is the contract; a request that arrives while the
    // engine is quiesced still raises nothing (epoch_inval_needed requires fe_owed).
    assign frame_err_now = debt_poisoned || job_invalid || frame_err_seen ||
                           epoch_inval_needed || fe_retire_needed || abort_evt ||
                           (b_fire && (m_axi_bresp != 2'b00));

    assign busy_m       = active_m || job_open || disc_active;

    // ---- debt record: memory-domain event -> PCIe-epoch level -> memory use ----
    // Set by any unsolicited write response; the ONLY thing that clears it is the
    // PCIe epoch reset. A video reset re-arms the synchroniser to the fail-closed
    // value (2'b11), so a frame that starts immediately after such a reset is still
    // treated as debt-poisoned until the epoch domain reports otherwise.
    // ---- debt record: payload-domain request -> epoch level -> payload use ----
    // An unsolicited completion raises debt_req and it stays raised until the
    // epoch domain has latched the poison and answered with debt_ack.  Only that
    // ack retires the request: no PL reset does, because the fault that raised it
    // belongs to the bus epoch, not to the video pipeline.  The epoch reset
    // clears the poison and the ack together, so a request still outstanding at
    // that moment is re-latched immediately - fail closed, never a lost fault -
    // while an epoch reset after a completed handshake genuinely releases it.
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_debt_req (
        .src_clk(mem_clk), .src_in(debt_req), .dest_clk(clk),
        .dest_out(debt_req_c));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_debt_ack (
        .src_clk(clk), .src_in(debt_ack_lvl), .dest_clk(mem_clk),
        .dest_out(debt_ack_c));

    // One process owns debt_req.  It used to be set from the AXI master process
    // as well, which synthesis reported as [Synth 8-6859] multi-driven net on
    // xpm_cdc_single's src_in - a second driver that would have been dropped in
    // hardware while simulation stayed green.
    always @(posedge mem_clk) begin
        if (b_unsolicited)   debt_req <= 1'b1;
        else if (debt_ack_c) debt_req <= 1'b0;
    end

    always @(posedge clk or negedge epoch_rst_n) begin
        if (!epoch_rst_n) begin
            debt_poison_epoch <= 1'b0;
            debt_ack_lvl      <= 1'b0;
        end else begin
            if (debt_req_c) begin
                debt_poison_epoch <= 1'b1;
                debt_ack_lvl      <= 1'b1;
            end else
                debt_ack_lvl      <= 1'b0;
        end
    end

    // The poison reaches the payload domain as a level.  A video reset re-arms
    // the synchroniser to the fail-closed value (2'b11), so a frame that starts
    // immediately after such a reset is still treated as debt-poisoned until the
    // epoch domain reports otherwise.
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) poison_sync <= 2'b11;
        else            poison_sync <= {poison_sync[0], debt_poison_epoch};
    end
    assign debt_poisoned = poison_sync[1];

    always @(posedge mem_clk or negedge fe_rst_n) begin
        if (!fe_rst_n) begin
            job_open        <= 1'b0;
            aw_outstanding  <= 1'b0;
            beats_aw        <= 32'd0;
            beats_w         <= 32'd0;
            beats_b         <= 32'd0;
            total_beats     <= 32'd0;
            cnt_beats       <= 32'd0;             // owned here, and only here
            addr_r          <= {ADDR_WIDTH{1'b0}};
            axi_err_level   <= 1'b0;
            m_axi_awaddr    <= {ADDR_WIDTH{1'b0}};
            m_axi_awlen     <= 8'd0;
            m_axi_awvalid   <= 1'b0;
            ab_state        <= AB_IDLE;
            fence_cnt       <= 6'd0;
            abort_m_d       <= 1'b0;
            discard_retire  <= 1'b0;
            job_invalid     <= 1'b0;
            frame_err_seen  <= 1'b0;
            abort_busy_raw  <= 1'b0;
        end else begin
            if (job_start) begin
                // open a frame: 256 B bursts of BURST_BYTES bytes each, starting
                // at the slot address that was latched when its first beat was
                // taken.  frame_bytes is a multiple of 256 B, so the burst count
                // is exact and there is no partial burst to special-case.
                job_open       <= 1'b1;
                total_beats    <= job_bytes_m[31:4];
                addr_r         <= job_addr_m;
                beats_aw       <= 32'd0;
                beats_w        <= 32'd0;
                beats_b        <= 32'd0;
                aw_outstanding <= 1'b0;
                frame_err_seen <= 1'b0;   // per-frame error history starts clean
            end

            // ---- AW channel: one address at a time, held until accepted ------
            if (aw_go) begin
                m_axi_awaddr  <= addr_r;
                m_axi_awlen   <= AWLEN_BURST;              // 16 beats, 256 B
                m_axi_awvalid <= 1'b1;
                aw_outstanding<= 1'b1;
                beats_aw      <= beats_aw + BURST_BEATS[31:0];
                // Address arithmetic uses the 32-bit value of BURST_BYTES
                // zero-extended by the addition context, NOT a slice of it:
                // `localparam integer` is 32 bits wide, so
                // BURST_BYTES[ADDR_WIDTH-1:0] (ADDR_WIDTH = 49) is an
                // out-of-range part select and Vivado synthesis stops with
                // [Synth 8-524] part-select [48:0] out of range of prefix
                // 'BURST_BYTES'.  Same numeric value (BYTES_PER_BEAT *
                // BURST_BEATS = 256), same wrap behaviour at 2^ADDR_WIDTH.
                addr_r        <= addr_r + BURST_BYTES[31:0];
            end else if (m_axi_awvalid && m_axi_awready) begin
                m_axi_awvalid <= 1'b0;
                aw_outstanding<= 1'b0;
            end

            // ---- W channel ---------------------------------------------------
            if (w_fire) begin
                beats_w   <= beats_w + 32'd1;
                // Delivered-beat status: strictly +1 per increment, which is the
                // lossless case xpm_cdc_gray documents.  It is incremented in this
                // process on purpose: as a standalone single-signal process Vivado's
                // gray-counter optimisation merged this register with the
                // primitive's src_gray_ff stage and reported 96 x Synth 8-6859
                // "multi-driven net on pin Q ... constant driver preserved, other
                // driver ignored" criticals, i.e. it would have dropped the real
                // driver in hardware while simulation stayed green.
                cnt_beats <= cnt_beats + 32'd1;
            end

            // ---- B channel ---------------------------------------------------
            if (b_fire) begin
                beats_b <= beats_b + BURST_BEATS[31:0];
                if (m_axi_bresp != 2'b00) begin
                    // one failed burst invalidates the WHOLE frame: the level is
                    // what frame_err_now ORs, so the slot is never published
                    axi_err_level  <= 1'b1;
                    frame_err_seen <= 1'b1;
                end
                // Review M8: the frame may be "complete" while the last AW is
                // still presented (W beats are independent of AW in AXI4).  If
                // the credit were dropped there, the NEXT frame's job_start could
                // reload m_axi_awaddr while AWVALID was still asserted, which is
                // an address changing underneath a held VALID.  So the job is
                // closed only once that AW has handshaked; nothing else can move
                // the address until then.
                if (frame_done && (!m_axi_awvalid || m_axi_awready)) begin
                    job_open       <= 1'b0;
                    aw_outstanding <= 1'b0;
                end
            end
            if (b_unsolicited) begin
                axi_err_level   <= 1'b1;   // sticky on the port, and it is not
            end                            // forgiven by any reset here

            // ---- abort retirement (runs last: it has the final word) --------
            // AB_IDLE is an explicit case item on purpose.  With only a
            // `default: ab_state <= AB_IDLE` the idle cycle would assign AB_IDLE
            // AFTER the entry assignment below it in the same statement group,
            // and the nonblocking semantics would throw the entry away: the
            // request was then visible for exactly one cycle and the retirement
            // never started (measured: abort_m/abort_evt pulse, ab_state stays
            // IDLE, no ov_abort_busy, no ack).
            abort_m_d <= abort_m;
            case (ab_state)
                AB_IDLE: begin
                    if (abort_evt || fe_retire_needed || epoch_inval_needed) begin
                        ab_state    <= AB_DRAIN;
                        fence_cnt   <= 6'd0;
                        job_invalid <= 1'b1;  // whatever is in flight dies unserved
                    end
                end
                AB_DRAIN: begin
                    // every AW this master presented is accounted for and every
                    // B for it has been collected; W is idle; nothing is left
                    // hanging on the interface
                    if (drain_free) begin
                        m_axi_awvalid  <= 1'b0;   // handshook, or never presented
                        aw_outstanding <= 1'b0;
                        job_open       <= 1'b0;
                        beats_aw       <= 32'd0;
                        beats_w        <= 32'd0;
                        beats_b        <= 32'd0;
                        total_beats    <= 32'd0;
                        addr_r         <= {ADDR_WIDTH{1'b0}};
                        fence_cnt      <= 6'd0;
                        ab_state       <= fifo_empty_l ? AB_FENCE : AB_FLUSH;
                    end
                end
                AB_FLUSH: begin
                    fence_cnt <= 6'd0;
                    if (fifo_empty_l) ab_state <= AB_FENCE;
                end
                AB_FENCE: begin
                    if (fence_clear) begin
                        if (fence_cnt >= (FENCE_HOLD - 6'd1)) begin
                            ab_state       <= AB_DONE;
                            discard_retire <= 1'b1;
                            abort_done_tgl <= ~abort_done_tgl;
                            job_invalid    <= 1'b0;
                        end else
                            fence_cnt <= fence_cnt + 6'd1;
                    end else
                        fence_cnt <= 6'd0;
                end
                AB_DONE: begin
                    discard_retire <= 1'b0;
                    ab_state       <= AB_IDLE;
                end
                default: ab_state <= AB_IDLE;
            endcase
            abort_busy_raw <= (ab_state != AB_IDLE);
        end
    end

    wire _unused = &{1'b0, s_axis_tlast, cfg_online, FIFO_BYTES[0], 1'b0};
endmodule
`default_nettype wire
