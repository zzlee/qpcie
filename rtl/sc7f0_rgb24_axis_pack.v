`default_nettype none
// ============================================================================
// Module: sc7f0_rgb24_axis_pack
// Personality: SC7F0-RGB-COMPOSITOR-2PPC (instantiated only under
//              `SC7F0_RGB_COMPOSITOR`, so every legacy profile elaborates the
//              untouched design).
//
// Function
//   HDMI RX subsystem VIDEO_OUT at NATIVE_PPC = 2 pixels/clock, 8 bit/component
//   RGB, converted into a *packed RGB24 byte stream* (one byte per component,
//   memory order R,G,B - no alpha, no padding, no truncation) and crossed into
//   the PCIe user clock as 16-byte (128-bit) payload beats.
//
//     native beat = PPC*3 = 6 bytes = 2 pixels      (phy_rx_video_clk, 297 MHz)
//     DMA beat    = 16 bytes                        (pcie_user_clk,   125 MHz)
//     48 bytes    = 8 native beats = 3 DMA beats     (LCM(6,16) = 48)
//
//   6 versus 16 is not an integer ratio, so the byte position is an explicit
//   shift register plus a byte count; nothing is re-aligned to 32-bit pixels and
//   no fake alpha byte is inserted.  4K60 packed RGB24 is 3840*3 = 11,520 bytes
//   per line = 720 DMA beats exactly, so a DMA beat never straddles two lines.
//
// Framing
//   One sideband bit travels with the first DMA beat of a frame.  Line and frame
//   addressing is derived by the consumer from the descriptor geometry
//   (rtl/sc7f0_rgb24_c2h_engine.v), so this stage keeps no second copy of the
//   geometry and cannot disagree with the descriptor.
//
// Backpressure contract
//   v_hdmi_rx_ss VIDEO_OUT is a free-running TMDS source: TREADY must never gate
//   it.  This stage therefore never stalls the source.  When the crossing FIFO
//   refuses a beat - because it is full *or* because it is still inside its own
//   reset - the frame in progress is abandoned (beats stop being queued until the
//   next SOF) and a sticky overflow level is raised; the consumer sees the frame
//   end early and counts it as a drop.  A frame that *starts* while the crossing
//   is unavailable is discarded in its entirety rather than being entered
//   half-way through, because the bytes that arrived while the crossing was busy
//   are gone for good.
//
//   Both refusals used to differ: only "full" abandoned the frame, while a
//   refusal caused by the crossing still being in reset consumed the beat out of
//   the byte gearbox without queueing it.  Every later byte of the frame was then
//   shifted by 16 bytes, which is exactly the failure the unit gate caught (1434
//   beats out of 1440, ovf_busy_cnt = 6, 22 822 mismatching bytes).
//
// Why the FIFO is instantiated directly instead of through sc7f0_dp_fifo
//   The C2H request builder must know how many whole 16-byte beats it can commit
//   to a TLP before it raises c2h_req_valid, because c2h_req_data_ready in
//   rtl/custom_pcie_dma_top.v is documented as *irreversible*: the encoder latches
//   the head beat and cannot give it back.  sc7f0_dp_fifo hides rd_data_count, and
//   widening it would change every legacy queue, so this module owns its own
//   xpm_fifo_async with the read-count advanced feature enabled.  The reset
//   structure is copied verbatim from rtl/sc7f0_dp_fifo.v: every reset source is
//   synchronised into BOTH clocks by its own xpm_cdc_async_rst (through
//   sc7f0_reset_sync) and only then combined, so a reset at either end flushes
//   both ends and no cross-domain gate sits in front of an asynchronous preset.
//
// CDC discipline
//   Only single-bit sticky levels cross out of this module besides the FIFO
//   itself, each through a two-flop synchroniser, so no new multi-bit Gray
//   endpoint (and therefore no new named timing constraint) is created.
//   rd_data_count is produced natively in the read (PCIe) clock domain.
// ============================================================================
`timescale 1ns / 1ps

module sc7f0_rgb24_axis_pack #(
    parameter integer NATIVE_PPC = 2,
    parameter integer FIFO_DEPTH = 1024            // 1024 x 129 bit ~ 16.5 kB
)(
    // source: RX video domain
    input  wire                     s_clk,
    input  wire                     s_rst_n,
    input  wire [NATIVE_PPC*24-1:0] s_axis_tdata,
    input  wire                     s_axis_tvalid,
    input  wire                     s_axis_tlast,    // end of line (observation)
    input  wire                     s_axis_tuser,    // start of frame
    output wire                     s_axis_tready,

    // drain: PCIe user clock domain
    input  wire                     m_clk,
    input  wire                     m_rst_n,
    output wire [127:0]             m_axis_tdata,
    output wire                     m_axis_tuser,    // 1 on a frame's first beat
    output wire                     m_axis_tvalid,
    input  wire                     m_axis_tready,
    // whole beats already resident in the FIFO, read clock domain
    output wire [$clog2(FIFO_DEPTH):0] m_axis_avail,

    // diagnostics: single-bit sticky levels, published in the drain domain
    output wire                     overflow_sticky, // FIFO refused a beat
    output wire                     line_align_sticky// line ended mid DMA beat
);
    localparam integer BYTES_PER_BEAT = NATIVE_PPC * 3;          // 6 at 2 PPC
    localparam integer ACC_BYTES      = 32;                      // 16 held + 6 in
    localparam integer CNT_W          = $clog2(FIFO_DEPTH) + 1;

    // ------------------------------------------------------------------------
    // source-side byte gearbox
    // ------------------------------------------------------------------------
    reg  [ACC_BYTES*8-1:0] acc;
    reg  [5:0]             acc_bytes;
    reg                    in_frame;
    reg                    sof_pending;
    reg                    abandon;            // this frame is being discarded
    reg                    ovf_sticky_s;
    reg                    eol_sticky_s;

    wire merge = s_axis_tvalid && in_frame && !abandon;
    // A frame boundary restarts the byte alignment.  Residual bytes from a
    // previous frame that did not end on a 16-byte boundary are an error.
    wire flush   = s_axis_tvalid && s_axis_tuser;
    wire publish = in_frame && !abandon &&
                   ((acc_bytes + (merge ? 6'd6 : 6'd0)) >= 6'd16);
    wire [5:0] merged_bytes = acc_bytes + (merge ? 6'd6 : 6'd0);

    // Memory image is byte-ascending R,G,B per pixel: byte 0 of a published beat
    // is bit [7:0] and lands at the lowest host address of that 16-byte group.
    //
    // The source fields are UG934 native RGB, which is R:B:G MSB->LSB - see
    // rtl/hdmi_rx_pixel_pack.v:1 and the proven host formatter in that file,
    //   dma_data[p*32+:32] = {8'hff, c[15:8], c[7:0], c[23:16]}
    // which puts R at the lowest memory byte, then the [7:0] field and then the
    // [15:8] field.  So for packed RGB24: byte0 = pix[23:16] (R), byte1 =
    // pix[7:0] (G), byte2 = pix[15:8] (B).  Wiring pix[15:8] into byte 1 (as the
    // first revision of this file did, under the wrong comment "[15:8]G") put
    // blue and green in each other's place in every captured frame.
    wire [BYTES_PER_BEAT*8-1:0] merge_bytes;
    genvar p;
    generate
        for (p = 0; p < NATIVE_PPC; p = p + 1) begin : g_pack
            wire [23:0] pix = s_axis_tdata[p*24 +: 24];      // [23:16]R [15:8]B [7:0]G
            assign merge_bytes[(p*3+0)*8 +: 8] = pix[23:16];
            assign merge_bytes[(p*3+1)*8 +: 8] = pix[7:0];
            assign merge_bytes[(p*3+2)*8 +: 8] = pix[15:8];
        end
    endgenerate

    wire [ACC_BYTES*8-1:0] acc_merged =
        merge ? (acc | ({{(ACC_BYTES-BYTES_PER_BEAT){1'b0}}, merge_bytes}
                        << (acc_bytes*8)))
              : acc;

    // ------------------------------------------------------------------------
    // crossing FIFO: {sof, 16-byte payload}, with read-side occupancy
    // ------------------------------------------------------------------------
    wire         fifo_full, fifo_wr_busy, fifo_empty, fifo_rd_busy;
    wire [128:0] fifo_dout;
    wire [CNT_W-1:0] fifo_rd_count;

    // Reset: both sources synchronised into the write clock (drives the single
    // global flush) and separately into the read clock (inhibits read VALID).
    wire w_all_n, r_all_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_reset(
        .dest_clk(s_clk), .src_rst_n({m_rst_n, s_rst_n}), .dest_rst_n(w_all_n));
    sc7f0_reset_sync #(.SOURCES(2)) u_read_reset(
        .dest_clk(m_clk), .src_rst_n({s_rst_n, m_rst_n}), .dest_rst_n(r_all_n));

    // The crossing may only accept a published beat once it is out of its own
    // reset.  A refusal while it is ready is a genuine overrun; a refusal while
    // it is still in reset is a *startup* event.  They are counted separately
    // because they mean different things to the operator, but they are treated
    // identically by the framing logic: either one abandons the whole frame.
    wire fifo_ready  = w_all_n && !fifo_wr_busy;
    // The published beat is the *merged* word: acc on its own only holds the
    // bytes that were already sitting there, so pushing acc left the bytes that
    // this very beat contributed (up to 6 of them, i.e. the top of the 16-byte
    // group) at zero.  Simulation caught it as "bytes 10..15 of a beat read 00".
    wire push        = publish && fifo_ready && !fifo_full;
    wire ovf_evt     = publish && fifo_ready && fifo_full;
    wire not_rdy_evt = publish && !fifo_ready;
    wire refuse_evt  = ovf_evt || not_rdy_evt;
    reg  [15:0] ovf_full_cnt;
    reg  [15:0] ovf_busy_cnt;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE ("block"),
        .FIFO_WRITE_DEPTH (FIFO_DEPTH),
        .WRITE_DATA_WIDTH (129),
        .READ_DATA_WIDTH  (129),
        .READ_MODE        ("fwft"),
        .FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES  (4),
        // USE_ADV_FEATURES bit order is decoded in
        // /opt/Xilinx/Vivado/2023.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv:206-216:
        //   [2]=wr_data_count, [10]=rd_data_count, [11]=almost_empty.
        // "0804" enabled almost_empty + wr_data_count and left rd_data_count
        // DISABLED, so rd_data_count read as a constant 0 and the C2H request
        // builder would never have seen any data (found by simulation, see
        // docs session report).  "0404" is the encoding already proven in
        // rtl/sc7f0_dp_fifo.v:79 for exactly this use.
        .USE_ADV_FEATURES ("0404"),        // wr_data_count + rd_data_count
        .WR_DATA_COUNT_WIDTH(CNT_W),
        .RD_DATA_COUNT_WIDTH(CNT_W),
        .SIM_ASSERT_CHK   (1)
    ) u_cross (
        .rst           (!w_all_n),
        .wr_clk        (s_clk),        .din           ({sof_pending, acc_merged[127:0]}),
        .wr_en         (push),
        .full          (fifo_full),
        .wr_rst_busy   (fifo_wr_busy),
        .rd_clk        (m_clk),
        .dout          (fifo_dout),
        .rd_en         (m_axis_tvalid && m_axis_tready),
        .empty         (fifo_empty),
        .rd_rst_busy   (fifo_rd_busy),
        .rd_data_count (fifo_rd_count),
        .wr_data_count (),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .prog_full     (), .prog_empty(), .overflow(), .underflow(),
        .almost_full   (), .almost_empty(), .wr_ack(), .data_valid(),
        .dbiterr       (), .sbiterr       ()
    );

    assign m_axis_tdata  = fifo_dout[127:0];
    assign m_axis_tuser  = fifo_dout[128];
    assign m_axis_tvalid = !fifo_empty && !fifo_rd_busy && r_all_n;
    assign m_axis_avail  = fifo_rd_count;
    // The source is never stalled: readiness is asserted whenever the RX
    // subsystem drives the bus, which is the hardware contract for VIDEO_OUT.
    assign s_axis_tready = 1'b1;

    always @(posedge s_clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            acc          <= {ACC_BYTES*8{1'b0}};
            acc_bytes    <= 6'd0;
            in_frame     <= 1'b0;
            sof_pending  <= 1'b0;
            abandon      <= 1'b0;
            ovf_sticky_s <= 1'b0;
            eol_sticky_s <= 1'b0;
            ovf_full_cnt <= 16'd0;
            ovf_busy_cnt <= 16'd0;
        end else begin
            if (flush) begin
                // Start of a new frame: the byte alignment restarts here.  If
                // the crossing cannot take data on this very beat (its reset has
                // not finished, or the drain side is frozen) the frame is thrown
                // away whole and the stage re-arms on the next SOF; entering a
                // frame mid-way would publish a frame that is missing its head
                // bytes, which is worse than dropping it.
                in_frame    <= 1'b1;
                abandon     <= !fifo_ready;
                sof_pending <= 1'b1;
                acc_bytes   <= BYTES_PER_BEAT[5:0];
                acc         <= {{(ACC_BYTES*8-BYTES_PER_BEAT*8){1'b0}}, merge_bytes};
                if (!fifo_ready) begin
                    ovf_sticky_s <= 1'b1;
                    ovf_busy_cnt <= ovf_busy_cnt + 16'd1;
                end
                // Leftover bytes at a frame boundary mean the previous frame was
                // not a whole number of DMA beats: the C2H side would drift.  A
                // frame that was discarded (still in reset, or overrun) is not a
                // geometry violation and its partial accumulator is meaningless.
                if (acc_bytes != 6'd0 && !abandon)
                    eol_sticky_s <= 1'b1;
            end else if (in_frame) begin
                if (refuse_evt) begin
                    // The beat was taken out of the gearbox but not queued, so
                    // every following byte would shift by 16 B: stop queueing the
                    // rest of this frame and wait for the next SOF.
                    abandon      <= 1'b1;
                    ovf_sticky_s <= 1'b1;
                    if (ovf_evt) ovf_full_cnt <= ovf_full_cnt + 16'd1;
                    else         ovf_busy_cnt <= ovf_busy_cnt + 16'd1;
                end else if (merge) begin
                    acc <= acc_merged;
                    if (publish) begin
                        acc         <= acc_merged >> 128;
                        acc_bytes   <= merged_bytes - 6'd16;
                        sof_pending <= 1'b0;
                    end else
                        acc_bytes   <= merged_bytes;
                end
                // An end of line with a partially filled DMA beat means
                // line_bytes is not a multiple of 16; the C2H side would drift.
                if (merge && s_axis_tlast && ((merged_bytes % 6'd16) != 6'd0))
                    eol_sticky_s <= 1'b1;
            end
        end
    end

    // Two-flop level synchronisers (single-bit crossings only).
    reg [1:0] sync_ovf, sync_eol;
    always @(posedge m_clk or negedge m_rst_n) begin
        if (!m_rst_n) begin
            sync_ovf <= 2'b00;
            sync_eol <= 2'b00;
        end else begin
            sync_ovf <= {sync_ovf[0], ovf_sticky_s};
            sync_eol <= {sync_eol[0], eol_sticky_s};
        end
    end
    assign overflow_sticky   = sync_ovf[1];
    assign line_align_sticky = sync_eol[1];
endmodule
`default_nettype wire
