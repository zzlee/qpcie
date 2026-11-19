`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_ovl_pull_prefetch
//
// Pull-mode H2C overlay engine for SC7F0-RGB-COMPOSITOR-2PPC:
//   Host RAM RGBA8888 -> sc7f0_overlay_ingress (PCIe MRd + tag reorder)
//     -> 129-bit x 65536 URAM Prefetch FIFO (1.0 MB = ~68 lines @ 4K, 32 URAMs)
//     -> 128->64 (2PPC) unpacker + RGBA->UG934 swizzle -> sc7f0_alpha_blend_2ppc
//
// Zero PS DDR4 bandwidth, zero HP2/HP3 usage.
//
// Frame-level behaviour:
//   - On host_ovl_go rising edge, latches pending Host IOVA & xfer_bytes and
//     arms a completion IRQ for that frame.
//   - On every base-video VBlank pulse (base_vblank_p_m from mem_clk), if
//     host_ovl_enable is high and ingress is idle, latches the latest Host
//     IOVA (double-buffered at VBlank -> tear-free) and pulses ing_ovl_go so
//     the URAM Prefetch FIFO pre-fills during the ~600 us VBlank before SOF.
//   - Static overlays stay on screen without host CPU/DMA intervention; when
//     host updates via QOVL_IOC_SUBMIT, ovl_wr_irq_pulse fires on ing_done_pulse.
// ============================================================================

module sc7f0_ovl_pull_prefetch #(
    parameter integer ACTIVE_BEATS_PER_LINE = 1920,  // 3840 px / 2 PPC
    parameter integer ACTIVE_LINES          = 2160,
    parameter integer URAM_FIFO_DEPTH       = 32768  // 32768 x 16 B = 0.5 MB (~34 lines, 16 URAMs)
)(
    // ---- PCIe user clock domain -------------------------------------------
    input  wire         pcie_clk,
    input  wire         pcie_rst_n,

    input  wire         host_ovl_enable,
    input  wire         host_ovl_go,
    input  wire [63:0]  host_src_addr,
    input  wire [31:0]  host_xfer_bytes,
    input  wire [15:0]  host_max_bytes_per_req,

    output reg          ing_ovl_enable,
    output reg          ing_ovl_go,
    output reg  [63:0]  ing_src_addr,
    output reg  [31:0]  ing_xfer_bytes,
    output reg  [15:0]  ing_max_bytes_per_req,
    input  wire         ing_busy,
    input  wire         ing_quarantined,
    input  wire         ing_done_pulse,
    input  wire         ing_abort_evt,

    output reg          ovl_wr_irq_pulse,
    output reg  [31:0]  ovl_wr_frames_done,
    output reg  [31:0]  ovl_wr_bytes_written,
    output wire         ovl_wr_busy,

    // ---- 300 MHz video/compositor clock domain ----------------------------
    input  wire         mem_clk,
    input  wire         mem_rst_n,
    input  wire         base_vblank_p_m,       // 1-cycle pulse at line 2159 EOL

    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tuser,          // 1 on first 128-bit beat of frame
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    output wire [63:0]  m_o_axis_tdata,
    output wire         m_o_axis_tvalid,
    input  wire         m_o_axis_tready,
    output wire         m_o_axis_tlast,
    output wire         m_o_axis_tuser
);

    // ------------------------------------------------------------------------
    // 1. CDC: base_vblank_p_m (mem_clk 300 MHz -> pcie_clk)
    // ------------------------------------------------------------------------
    wire base_vblank_p;
    xpm_cdc_pulse #(
        .DEST_SYNC_FF  (4),
        .INIT_SYNC_FF  (0),
        .REG_OUTPUT    (1),
        .RST_USED      (1),
        .SIM_ASSERT_CHK(0)
    ) u_vblank_cdc (
        .src_clk   (mem_clk),
        .src_rst   (!mem_rst_n),
        .src_pulse (base_vblank_p_m),
        .dest_clk  (pcie_clk),
        .dest_rst  (!pcie_rst_n),
        .dest_pulse(base_vblank_p)
    );

    // ------------------------------------------------------------------------
    // 2. PCIe domain: VBlank auto-refresh + Host QOVL_IOC_SUBMIT handshake
    // ------------------------------------------------------------------------
    localparam [1:0] P_IDLE = 2'd0,
                     P_RUN  = 2'd1;

    reg [1:0]  p_state;
    reg        host_go_q;
    reg        active_valid;
    reg [63:0] active_addr;
    reg [31:0] active_bytes;
    reg [15:0] active_max_req;
    reg        pending_irq_armed;
    reg [63:0] pending_addr;
    reg [31:0] pending_bytes;
    reg [15:0] pending_max_req;
    reg        run_irq_armed;
    reg        vblank_pending;

    assign ovl_wr_busy = (p_state != P_IDLE) || ing_busy;

    always @(posedge pcie_clk or negedge pcie_rst_n) begin
        if (!pcie_rst_n) begin
            p_state               <= P_IDLE;
            host_go_q             <= 1'b0;
            active_valid          <= 1'b0;
            active_addr           <= 64'd0;
            active_bytes          <= 32'd0;
            active_max_req        <= 16'd0;
            pending_irq_armed     <= 1'b0;
            pending_addr          <= 64'd0;
            pending_bytes         <= 32'd0;
            pending_max_req       <= 16'd0;
            run_irq_armed         <= 1'b0;
            vblank_pending        <= 1'b0;
            ing_ovl_enable        <= 1'b0;
            ing_ovl_go            <= 1'b0;
            ing_src_addr          <= 64'd0;
            ing_xfer_bytes        <= 32'd0;
            ing_max_bytes_per_req <= 16'd0;
            ovl_wr_irq_pulse      <= 1'b0;
            ovl_wr_frames_done    <= 32'd0;
            ovl_wr_bytes_written  <= 32'd0;
        end else begin
            host_go_q        <= host_ovl_go;
            ovl_wr_irq_pulse <= 1'b0;
            ing_ovl_enable   <= host_ovl_enable;

            if (!host_ovl_enable) begin
                active_valid      <= 1'b0;
                pending_irq_armed <= 1'b0;
                vblank_pending    <= 1'b0;
            end else if (host_ovl_go && !host_go_q && (host_xfer_bytes != 32'd0)) begin
                pending_addr      <= host_src_addr;
                pending_bytes     <= host_xfer_bytes;
                pending_max_req   <= host_max_bytes_per_req;
                pending_irq_armed <= 1'b1;
                active_addr       <= host_src_addr;
                active_bytes      <= host_xfer_bytes;
                active_max_req    <= host_max_bytes_per_req;
                active_valid      <= 1'b1;
            end

            if (base_vblank_p && host_ovl_enable && active_valid) begin
                vblank_pending <= 1'b1;
            end

            case (p_state)
                P_IDLE: begin
                    ing_ovl_go <= 1'b0;
                    if (host_ovl_enable && !ing_busy && !ing_quarantined &&
                        ((host_ovl_go && !host_go_q && (host_xfer_bytes != 32'd0)) ||
                         (active_valid && (base_vblank_p || vblank_pending)))) begin
                        vblank_pending <= 1'b0;
                        if (host_ovl_go && !host_go_q && (host_xfer_bytes != 32'd0)) begin
                            ing_src_addr          <= host_src_addr;
                            ing_xfer_bytes        <= host_xfer_bytes;
                            ing_max_bytes_per_req <= host_max_bytes_per_req;
                            run_irq_armed         <= 1'b1;
                            pending_irq_armed     <= 1'b0;
                        end else begin
                            ing_src_addr          <= pending_irq_armed ? pending_addr    : active_addr;
                            ing_xfer_bytes        <= pending_irq_armed ? pending_bytes   : active_bytes;
                            ing_max_bytes_per_req <= pending_irq_armed ? pending_max_req : active_max_req;
                            run_irq_armed         <= pending_irq_armed;
                            pending_irq_armed     <= 1'b0;
                        end
                        ing_ovl_go <= 1'b1;
                        p_state    <= P_RUN;
                    end
                end

                P_RUN: begin
                    if (!host_ovl_enable || ing_abort_evt) begin
                        ing_ovl_go    <= 1'b0;
                        run_irq_armed <= 1'b0;
                        p_state       <= P_IDLE;
                    end else if (ing_done_pulse) begin
                        ing_ovl_go           <= 1'b0;
                        ovl_wr_frames_done   <= ovl_wr_frames_done + 32'd1;
                        ovl_wr_bytes_written <= ovl_wr_bytes_written + ing_xfer_bytes;
                        if (run_irq_armed) begin
                            ovl_wr_irq_pulse <= 1'b1;
                        end
                        run_irq_armed        <= 1'b0;
                        p_state              <= P_IDLE;
                    end
                end

                default: p_state <= P_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // 3. mem_clk (300 MHz): 32-URAM Prefetch FIFO (129b x 65536 = 1.0 MB)
    // ------------------------------------------------------------------------
    wire [128:0] uram_dout;
    wire         uram_full, uram_empty, uram_wr_rst_busy, uram_rd_rst_busy;
    wire         uram_rd_en;

    assign s_axis_tready = !uram_full && !uram_wr_rst_busy;

    xpm_fifo_sync #(
        .CASCADE_HEIGHT     (1),
        .DOUT_RESET_VALUE   ("0"),
        .ECC_MODE           ("no_ecc"),
        .FIFO_MEMORY_TYPE   ("ultra"),
        .FIFO_READ_LATENCY  (0),
        .FIFO_WRITE_DEPTH   (URAM_FIFO_DEPTH),
        .FULL_RESET_VALUE   (0),
        .PROG_EMPTY_THRESH  (10),
        .PROG_FULL_THRESH   (10),
        .RD_DATA_COUNT_WIDTH(16),
        .READ_DATA_WIDTH    (129),
        .READ_MODE          ("fwft"),
        .SIM_ASSERT_CHK     (0),
        .USE_ADV_FEATURES   ("0000"),
        .WAKEUP_TIME        (0),
        .WRITE_DATA_WIDTH   (129),
        .WR_DATA_COUNT_WIDTH(16)
    ) u_ovl_uram_fifo (
        .sleep        (1'b0),
        .rst          (!mem_rst_n),
        .wr_clk       (mem_clk),
        .wr_en        (s_axis_tvalid && s_axis_tready),
        .din          ({s_axis_tuser, s_axis_tdata}),
        .full         (uram_full),
        .prog_full    (),
        .wr_data_count(),
        .overflow     (),
        .wr_rst_busy  (uram_wr_rst_busy),
        .almost_full  (),
        .wr_ack       (),
        .rd_en        (uram_rd_en),
        .dout         (uram_dout),
        .empty        (uram_empty),
        .prog_empty   (),
        .rd_data_count(),
        .underflow    (),
        .rd_rst_busy  (uram_rd_rst_busy),
        .almost_empty (),
        .data_valid   (),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0),
        .sbiterr      (),
        .dbiterr      ()
    );

    // ------------------------------------------------------------------------
    // 4. 128-bit -> 64-bit (2PPC) unpacker + Host RGBA8888 -> UG934 swizzle
    // ------------------------------------------------------------------------
    function automatic [31:0] swizzle_rgba_to_ug934(input [31:0] px);
        // Host little-endian RGBA8888: [31:24]=A, [23:16]=B, [15:8]=G, [7:0]=R
        // UG934 native RGB + Alpha:    [31:24]=A, [23:16]=R, [15:8]=B, [7:0]=G
        swizzle_rgba_to_ug934 = {px[31:24], px[7:0], px[23:16], px[15:8]};
    endfunction

    reg        half_sel;
    reg [11:0] col_cnt;
    reg [11:0] row_cnt;

    wire [63:0] cur_64      = half_sel ? uram_dout[127:64] : uram_dout[63:0];
    wire        beat_is_sof = uram_dout[128] && !half_sel;
    wire [11:0] eff_col     = beat_is_sof ? 12'd0 : col_cnt;

    assign m_o_axis_tvalid = !uram_empty && !uram_rd_rst_busy;
    assign m_o_axis_tdata  = {swizzle_rgba_to_ug934(cur_64[63:32]),
                              swizzle_rgba_to_ug934(cur_64[31:0])};
    assign m_o_axis_tuser  = beat_is_sof;
    assign m_o_axis_tlast  = (eff_col == (ACTIVE_BEATS_PER_LINE[11:0] - 12'd1));
    assign uram_rd_en      = m_o_axis_tvalid && m_o_axis_tready && half_sel;

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            half_sel <= 1'b0;
            col_cnt  <= 12'd0;
            row_cnt  <= 12'd0;
        end else if (m_o_axis_tvalid && m_o_axis_tready) begin
            half_sel <= ~half_sel;
            if (eff_col == (ACTIVE_BEATS_PER_LINE[11:0] - 12'd1)) begin
                col_cnt <= 12'd0;
                if (beat_is_sof) begin
                    row_cnt <= 12'd0;
                end else if (row_cnt == (ACTIVE_LINES[11:0] - 12'd1)) begin
                    row_cnt <= 12'd0;
                end else begin
                    row_cnt <= row_cnt + 12'd1;
                end
            end else begin
                col_cnt <= eff_col + 12'd1;
                if (beat_is_sof) begin
                    row_cnt <= 12'd0;
                end
            end
        end
    end

endmodule
`default_nettype wire
