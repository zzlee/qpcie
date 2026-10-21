// ============================================================================
// Module: video_req_cdc
// Description: Crosses the NV12 capture engine's C2H request interface from
//              the 150 MHz video clock domain to the 125 MHz PCIe requester
//              domain.
//              Dual-FIFO architecture:
//                1. u_hdr_fifo: 76-bit async FIFO for descriptor header and
//                   frame-done (EOF) tokens.
//                2. u_data_fifo: True Dual-Port Block RAM asymmetric async FIFO
//                   (128-bit write @ 150 MHz, DATA_WIDTH-bit read @ 125 MHz).
//                   Supports 256-bit native zero-bubble streaming for UltraScale+
//                   and 128-bit native streaming for 7-series / A50T.
//
//              Determinism rules:
//                * Writer ensures FIFO room for a packet before accepting it,
//                  and advances a Gray-coded completion counter only after
//                  the entire packet is pushed.
//                * Reader starts replaying packet N only after seeing completion N,
//                  guaranteeing full residency with zero mid-TLP stalls.
// ============================================================================
`timescale 1ns / 1ps

module video_req_cdc #(
    parameter integer MAX_DWORDS     = 64,      // Max 256-byte MWr payload (64 DW)
    parameter integer FIFO_DEPTH     = 512,
    parameter integer WR_DATA_WIDTH  = 128,     // Video engine beat width
    parameter integer DATA_WIDTH     = 128      // Requester domain width (128 for A50T, 256 for ZU4EV)
)(
    // Video (150 MHz) side: engine request source
    input  wire         wr_clk,
    input  wire         wr_rst_n,
    input  wire         s_req_valid,
    input  wire [63:0]  s_req_addr,
    input  wire [10:0]  s_req_dw_len,       // 64 for 256B, 32 for 128B
    input  wire [WR_DATA_WIDTH-1:0] s_req_data,
    output reg          s_req_data_ready,
    output reg          s_req_ack,
    input  wire         s_frame_done,

    // PCIe (125 MHz) side: requester arbiter sink
    input  wire         rd_clk,
    input  wire         rd_rst_n,
    output reg          m_req_valid,
    output reg  [63:0]  m_req_addr,
    output reg  [10:0]  m_req_dw_len,
    output wire [DATA_WIDTH-1:0] m_req_data,
    input  wire         m_req_data_ready,
    input  wire         m_req_ack,
    output reg          m_frame_done,
    output wire         m_fifo_empty,
    output wire [9:0]   m_fifo_count
);
    localparam integer WR_DWORDS       = WR_DATA_WIDTH / 32; // 4 DWs per 128-bit beat
    localparam integer RD_DEPTH        = FIFO_DEPTH * WR_DATA_WIDTH / DATA_WIDTH;
    localparam integer RD_COUNT_WIDTH  = $clog2(RD_DEPTH) + 1;
    localparam integer WR_COUNT_WIDTH  = $clog2(FIFO_DEPTH) + 1;

    wire cdc_rst_n = wr_rst_n && rd_rst_n;

    // ---------------------------------------------------------------------
    // Header FIFO: carries {eof, dw_len[10:0], addr[63:0]} (76 bits)
    // ---------------------------------------------------------------------
    wire        hdr_empty;
    wire        hdr_full;
    wire [75:0] hdr_dout;
    reg         hdr_wr_en;
    reg  [75:0] hdr_din;
    reg         hdr_rd_en;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"),
        .FIFO_WRITE_DEPTH(32),
        .WRITE_DATA_WIDTH(76),
        .READ_DATA_WIDTH(76),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0)
    ) u_hdr_fifo (
        .rst            (!cdc_rst_n),
        .wr_clk         (wr_clk),
        .wr_en          (hdr_wr_en),
        .din            (hdr_din),
        .full           (hdr_full),
        .rd_clk         (rd_clk),
        .rd_en          (hdr_rd_en),
        .dout           (hdr_dout),
        .empty          (hdr_empty),
        .sleep          (1'b0),
        .injectsbiterr  (1'b0),
        .injectdbiterr  (1'b0),
        .sbiterr        (),
        .dbiterr        (),
        .wr_rst_busy    (),
        .rd_rst_busy    ()
    );

    // ---------------------------------------------------------------------
    // Data FIFO: carries pure payload data beats
    // ---------------------------------------------------------------------
    wire        data_empty;
    wire        data_full;
    wire        data_prog_full;
    wire        data_wr_rst_busy;
    wire        data_rd_rst_busy;
    wire [WR_COUNT_WIDTH-1:0] wr_data_count;
    wire [RD_COUNT_WIDTH-1:0] rd_data_count;
    wire        data_wr_en;
    wire        data_rd_en;

    assign m_fifo_empty = data_empty;
    assign m_fifo_count = (RD_COUNT_WIDTH >= 10) ? rd_data_count[9:0] : {{(10-RD_COUNT_WIDTH){1'b0}}, rd_data_count};

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_WRITE_DEPTH(FIFO_DEPTH),
        .WRITE_DATA_WIDTH(WR_DATA_WIDTH),
        .READ_DATA_WIDTH(DATA_WIDTH),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),
        .PROG_FULL_THRESH(FIFO_DEPTH - 32),
        .RD_DATA_COUNT_WIDTH(RD_COUNT_WIDTH),
        .WR_DATA_COUNT_WIDTH(WR_COUNT_WIDTH),
        .USE_ADV_FEATURES("1F1F")
    ) u_data_fifo (
        .rst            (!cdc_rst_n),
        .wr_clk         (wr_clk),
        .wr_en          (data_wr_en),
        .din            (s_req_data),
        .full           (data_full),
        .rd_clk         (rd_clk),
        .rd_en          (data_rd_en),
        .dout           (m_req_data),
        .empty          (data_empty),
        .sleep          (1'b0),
        .injectsbiterr  (1'b0),
        .injectdbiterr  (1'b0),
        .sbiterr        (),
        .dbiterr        (),
        .wr_rst_busy    (data_wr_rst_busy),
        .rd_rst_busy    (data_rd_rst_busy),
        .prog_full      (data_prog_full),
        .wr_data_count  (wr_data_count),
        .almost_full    (),
        .prog_empty     (),
        .rd_data_count  (rd_data_count),
        .almost_empty   ()
    );

    // ---------------------------------------------------------------------
    // Writer FSM: push header to u_hdr_fifo, then swallow payload to u_data_fifo
    // ---------------------------------------------------------------------
    localparam WR_IDLE  = 2'd0,
               WR_DATA  = 2'd1,
               WR_DRAIN = 2'd2;
    reg [1:0]   wr_state;
    reg [10:0]  wr_beats_left;
    reg         eof_pending;

    wire wr_room_ok = !data_wr_rst_busy && !data_prog_full && !data_full && !hdr_full;
    assign data_wr_en = (wr_state == WR_DATA) && s_req_valid && s_req_data_ready;

    reg [15:0] pkt_pushed_bin = 16'd0;
    wire [15:0] pkt_pushed_gray = (pkt_pushed_bin >> 1) ^ pkt_pushed_bin;

    always @(posedge wr_clk or negedge cdc_rst_n) begin
        if (!cdc_rst_n) begin
            wr_state         <= WR_IDLE;
            wr_beats_left    <= 11'd0;
            s_req_data_ready <= 1'b0;
            s_req_ack        <= 1'b0;
            eof_pending      <= 1'b0;
            pkt_pushed_bin   <= 16'd0;
            hdr_wr_en        <= 1'b0;
            hdr_din          <= 76'd0;
        end else if (data_wr_rst_busy) begin
            wr_state         <= WR_IDLE;
            wr_beats_left    <= 11'd0;
            s_req_data_ready <= 1'b0;
            s_req_ack        <= 1'b0;
            eof_pending      <= 1'b0;
            pkt_pushed_bin   <= 16'd0;
            hdr_wr_en        <= 1'b0;
            hdr_din          <= 76'd0;
        end else begin
            hdr_wr_en  <= 1'b0;
            s_req_ack  <= 1'b0;

            if (s_frame_done)
                eof_pending <= 1'b1;

            case (wr_state)
                WR_IDLE: begin
                    if ((eof_pending || s_frame_done) && !hdr_full) begin
                        hdr_din        <= {1'b1, 11'd0, 64'd0}; // Bit 75 = 1 (EOF)
                        hdr_wr_en      <= 1'b1;
                        eof_pending    <= 1'b0;
                        pkt_pushed_bin <= pkt_pushed_bin + 1'b1;
                    end else if (s_req_valid && wr_room_ok) begin
                        hdr_din          <= {1'b0, (s_req_dw_len != 0) ? s_req_dw_len : 11'd64, s_req_addr};
                        hdr_wr_en        <= 1'b1;
                        wr_beats_left    <= (s_req_dw_len != 0) ? (s_req_dw_len / WR_DWORDS) : (MAX_DWORDS / WR_DWORDS);
                        s_req_data_ready <= 1'b1;
                        wr_state         <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (s_req_valid && s_req_data_ready) begin
                        wr_beats_left <= wr_beats_left - 1'b1;
                        if (wr_beats_left == 11'd1) begin
                            s_req_ack        <= 1'b1;
                            s_req_data_ready <= 1'b0;
                            pkt_pushed_bin   <= pkt_pushed_bin + 1'b1;
                            wr_state         <= WR_DRAIN;
                        end
                    end
                end

                WR_DRAIN: begin
                    if (!s_req_valid)
                        wr_state <= WR_IDLE;
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Reader FSM: Direct streaming to PCIe Requester
    // ---------------------------------------------------------------------
    localparam RD_IDLE   = 2'd0,
               RD_STREAM = 2'd1,
               RD_WAIT   = 2'd2;
    reg [1:0]  rd_state;
    reg [15:0] rd_started;

    (* ASYNC_REG = "TRUE" *) reg [15:0] pkt_pushed_gray_sync1 = 16'd0;
    (* ASYNC_REG = "TRUE" *) reg [15:0] pkt_pushed_gray_sync2 = 16'd0;
    always @(posedge rd_clk or negedge cdc_rst_n) begin
        if (!cdc_rst_n || data_rd_rst_busy) begin
            pkt_pushed_gray_sync1 <= 16'd0;
            pkt_pushed_gray_sync2 <= 16'd0;
        end else begin
            pkt_pushed_gray_sync1 <= pkt_pushed_gray;
            pkt_pushed_gray_sync2 <= pkt_pushed_gray_sync1;
        end
    end

    function [15:0] gray_to_bin;
        input [15:0] gray;
        integer i;
        begin
            gray_to_bin[15] = gray[15];
            for (i = 14; i >= 0; i = i - 1)
                gray_to_bin[i] = gray_to_bin[i + 1] ^ gray[i];
        end
    endfunction

    wire [15:0] rd_completed = gray_to_bin(pkt_pushed_gray_sync2);

    assign data_rd_en = m_req_valid && m_req_data_ready;

    always @(posedge rd_clk or negedge cdc_rst_n) begin
        if (!cdc_rst_n || data_rd_rst_busy) begin
            rd_state     <= RD_IDLE;
            rd_started   <= 16'd0;
            m_req_valid  <= 1'b0;
            m_req_addr   <= 64'd0;
            m_req_dw_len <= 11'd0;
            m_frame_done <= 1'b0;
            hdr_rd_en    <= 1'b0;
        end else begin
            m_frame_done <= 1'b0;
            hdr_rd_en    <= 1'b0;

            case (rd_state)
                RD_IDLE: begin
                    if (!hdr_empty && (rd_completed != rd_started)) begin
                        if (hdr_dout[75]) begin
                            m_frame_done <= 1'b1;
                            hdr_rd_en    <= 1'b1;
                            rd_started   <= rd_started + 1'b1;
                            m_req_valid  <= 1'b0;
                            rd_state     <= RD_WAIT;
                        end else begin
                            m_req_addr   <= hdr_dout[63:0];
                            m_req_dw_len <= (hdr_dout[74:64] != 0) ? hdr_dout[74:64] : 11'd64;
                            m_req_valid  <= 1'b1;
                            rd_state     <= RD_STREAM;
                        end
                    end else begin
                        m_req_valid <= 1'b0;
                    end
                end

                RD_STREAM: begin
                    m_req_valid <= 1'b1;
                    if (m_req_ack) begin
                        hdr_rd_en   <= 1'b1;
                        rd_started  <= rd_started + 1'b1;
                        m_req_valid <= 1'b0;
                        rd_state    <= RD_WAIT;
                    end
                end

                RD_WAIT: begin
                    rd_state <= RD_IDLE;
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule
