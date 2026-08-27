// ============================================================================
// Module: video_req_cdc
// Description: Crosses the NV12 capture engine's C2H request interface from
//              the 150 MHz video clock domain to the 125 MHz PCIe requester
//              domain. Supports dynamic packet lengths (e.g. 256B / 64 DW or
//              128B / 32 DW):
//              - One 128-bit header word carrying {53'd0, dw_len[10:0], addr[63:0]}
//              - Followed by (dw_len/4) 128-bit payload data beats.
//
//              Determinism rules:
//                * Writer ensures FIFO room for a packet before accepting it,
//                  and pulses pkt_pushed_toggle only after the last word is pushed.
//                * Reader starts replaying packet N only after seeing completion N,
//                  guaranteeing full residency with zero mid-TLP stalls.
// ============================================================================
`timescale 1ns / 1ps

module video_req_cdc #(
    parameter integer MAX_DWORDS = 64,      // Max 256-byte MWr payload (64 DW)
    parameter integer FIFO_DEPTH = 512      // power of two, >= several packets
)(
    // Video (150 MHz) side: engine request source
    input  wire         wr_clk,
    input  wire         wr_rst_n,
    input  wire         s_req_valid,
    input  wire [63:0]  s_req_addr,
    input  wire [10:0]  s_req_dw_len,       // 64 for 256B, 32 for 128B
    input  wire [127:0] s_req_data,
    output reg          s_req_data_ready,
    output reg          s_req_ack,

    // PCIe (125 MHz) side: requester arbiter sink
    input  wire         rd_clk,
    input  wire         rd_rst_n,
    output reg          m_req_valid,
    output reg  [63:0]  m_req_addr,
    output reg  [10:0]  m_req_dw_len,
    output reg  [127:0] m_req_data,
    input  wire         m_req_data_ready,
    input  wire         m_req_ack,
    output wire         m_fifo_empty,
    output wire [9:0]   m_fifo_count
);
    localparam integer DATA_DWORDS        = 4;                       // 128-bit beat = 4 DWs
    localparam integer MAX_PAYLOAD_BEATS  = MAX_DWORDS / DATA_DWORDS; // 16 beats
    localparam integer FIFO_COUNT_WIDTH   = $clog2(FIFO_DEPTH) + 1;

    // ---------------------------------------------------------------------
    // Asynchronous FIFO (FWFT: dout always shows the current head)
    // ---------------------------------------------------------------------
    wire        fifo_empty;
    wire        fifo_full;
    wire [127:0] fifo_dout;
    wire        fifo_wr_en;
    wire [127:0] fifo_din;
    reg         fifo_rd_en;
    wire        fifo_prog_full;
    wire [FIFO_COUNT_WIDTH-1:0] wr_data_count;
    wire [FIFO_COUNT_WIDTH-1:0] rd_data_count;

    assign m_fifo_empty = fifo_empty;
    assign m_fifo_count = rd_data_count[9:0];

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_WRITE_DEPTH(FIFO_DEPTH),
        .WRITE_DATA_WIDTH(128),
        .READ_DATA_WIDTH(128),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),
        .PROG_FULL_THRESH(FIFO_DEPTH - 32),
        .USE_ADV_FEATURES("1F1F")
    ) u_fifo (
        .rst            (!wr_rst_n || !rd_rst_n),
        .wr_clk         (wr_clk),
        .wr_en          (fifo_wr_en),
        .din            (fifo_din),
        .full           (fifo_full),
        .rd_clk         (rd_clk),
        .rd_en          (fifo_rd_en),
        .dout           (fifo_dout),
        .empty          (fifo_empty),
        .sleep          (1'b0),
        .injectsbiterr  (1'b0),
        .injectdbiterr  (1'b0),
        .sbiterr        (),
        .dbiterr        (),
        .wr_rst_busy    (),
        .rd_rst_busy    (),
        .prog_full      (fifo_prog_full),
        .wr_data_count  (wr_data_count),
        .almost_full    (),
        .prog_empty     (),
        .rd_data_count  (rd_data_count),
        .almost_empty   ()
    );

    // ---------------------------------------------------------------------
    // Writer FSM: reserve room for a whole packet, commit header word,
    // then swallow (s_req_dw_len/4) payload beats.
    // ---------------------------------------------------------------------
    localparam WR_IDLE = 2'd0, WR_ADDR = 2'd1, WR_DATA = 2'd2, WR_DRAIN = 2'd3;
    reg [1:0]   wr_state;
    reg [10:0]  wr_beats_left;
    reg [63:0]  s_req_addr_reg;
    reg [10:0]  s_req_dw_len_reg;

    wire wr_room_ok = !fifo_prog_full && !fifo_full;

    // Writer -> reader "packet fully pushed" toggle.
    reg pkt_pushed_toggle = 1'b0;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_state          <= WR_IDLE;
            wr_beats_left     <= 11'd0;
            s_req_addr_reg    <= 64'd0;
            s_req_dw_len_reg  <= 11'd0;
            s_req_data_ready  <= 1'b0;
            s_req_ack         <= 1'b0;
            pkt_pushed_toggle <= 1'b0;
        end else begin
            s_req_ack <= 1'b0;

            case (wr_state)
                WR_IDLE: begin
                    if (s_req_valid && wr_room_ok && !fifo_full) begin
                        s_req_addr_reg   <= s_req_addr;
                        s_req_dw_len_reg <= (s_req_dw_len != 0) ? s_req_dw_len : 11'd64;
                        wr_beats_left    <= (s_req_dw_len != 0) ? s_req_dw_len[10:2] : 11'd16;
                        wr_state         <= WR_ADDR;
                    end
                end

                WR_ADDR: begin
                    if (fifo_full) begin
                        wr_state <= WR_IDLE; // retry
                    end else begin
                        wr_state         <= WR_DATA;
                        s_req_data_ready <= 1'b1;
                    end
                end

                WR_DATA: begin
                    if (s_req_valid && s_req_data_ready) begin
                        wr_beats_left <= wr_beats_left - 1'b1;
                        if (wr_beats_left == 11'd1) begin
                            s_req_ack         <= 1'b1;
                            s_req_data_ready  <= 1'b0;
                            pkt_pushed_toggle <= ~pkt_pushed_toggle;
                            wr_state          <= WR_DRAIN;
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

    // Header format: DW0/DW1 = Addr[63:0], DW2 = dw_len[10:0], DW3 = 0
    assign fifo_din = (wr_state == WR_ADDR) ? {53'd0, s_req_dw_len_reg, s_req_addr_reg}
                                            : s_req_data;
    assign fifo_wr_en = (wr_state == WR_ADDR) ||
                        (wr_state == WR_DATA && s_req_valid && s_req_data_ready);

    // ---------------------------------------------------------------------
    // Reader FSM: Cut-Through FWFT direct streaming to PCIe Requiter.
    // Zero-bubble cut-through eliminates store-and-forward serialization.
    // ---------------------------------------------------------------------
    localparam RD_IDLE   = 1'b0,
               RD_STREAM = 1'b1;
    reg        rd_state;
    reg [15:0] rd_done_seen;     // completions observed in read domain
    reg [15:0] rd_started;       // packets started

    (* ASYNC_REG = "TRUE" *) reg [1:0] pkt_pushed_sync = 2'b00;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            pkt_pushed_sync <= 2'b00;
        else
            pkt_pushed_sync <= {pkt_pushed_sync[0], pkt_pushed_toggle};
    end
    wire pkt_pushed_pulse = pkt_pushed_sync[0] ^ pkt_pushed_sync[1];

    assign m_req_data = fifo_dout;

    wire fifo_pop_hdr = (rd_state == RD_IDLE) && !fifo_empty && (rd_done_seen != rd_started);
    wire fifo_pop_next_hdr = (rd_state == RD_STREAM) && m_req_ack && !fifo_empty &&
                             (rd_done_seen != (rd_started + (pkt_pushed_pulse ? 1'b1 : 1'b0)));
    wire fifo_pop_data = (rd_state == RD_STREAM) && m_req_data_ready && !m_req_ack;

    assign fifo_rd_en = fifo_pop_hdr || fifo_pop_next_hdr || fifo_pop_data;

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_state     <= RD_IDLE;
            rd_done_seen <= 16'd0;
            rd_started   <= 16'd0;
            m_req_valid  <= 1'b0;
            m_req_addr   <= 64'd0;
            m_req_dw_len <= 11'd0;
        end else begin
            if (pkt_pushed_pulse)
                rd_done_seen <= rd_done_seen + 1'b1;

            case (rd_state)
                RD_IDLE: begin
                    if (!fifo_empty && (rd_done_seen != rd_started)) begin
                        m_req_addr   <= fifo_dout[63:0];
                        m_req_dw_len <= (fifo_dout[74:64] != 0) ? fifo_dout[74:64] : 11'd64;
                        rd_started   <= rd_started + 1'b1;
                        rd_state     <= RD_STREAM;
                    end else begin
                        m_req_valid  <= 1'b0;
                    end
                end

                RD_STREAM: begin
                    m_req_valid <= 1'b1;
                    if (m_req_ack) begin
                        if (!fifo_empty && (rd_done_seen != (rd_started + (pkt_pushed_pulse ? 1'b1 : 1'b0)))) begin
                            m_req_addr   <= fifo_dout[63:0];
                            m_req_dw_len <= (fifo_dout[74:64] != 0) ? fifo_dout[74:64] : 11'd64;
                            rd_started   <= rd_started + 1'b1;
                            rd_state     <= RD_STREAM;
                        end else begin
                            m_req_valid  <= 1'b0;
                            rd_state     <= RD_IDLE;
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule
