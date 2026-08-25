// ============================================================================
// Module: video_req_cdc
// Description: Crosses the NV12 capture engine's C2H request interface from
//              the 150 MHz video clock domain to the 125 MHz PCIe requester
//              domain.  The video engine always emits fixed-size packets
//              (REQ_DWORDS payload beats, one 64-bit address word up front).
//
//              Determinism rules:
//                * Writer reserves FIFO room for a whole packet before
//                  accepting it, and pulses pkt_done (through the XPM FIFO's
//                  own ordering) only after the last word is pushed.
//                * Reader starts replaying packet N only after it has seen
//                  N completions, so the packet is guaranteed fully resident
//                  -- the requester never observes a mid-TLP stall.
//
//              Memory is an xpm_fifo_async (mapped to block RAM): a plain
//              dual-clock reg array would infer flip-flops and overflow the
//              device.
// ============================================================================
`timescale 1ns / 1ps

module video_req_cdc #(
    parameter integer REQ_DWORDS = 64,      // 256-byte MWr payload
    parameter integer FIFO_DEPTH = 512      // power of two, >= several packets
)(
    // Video (150 MHz) side: engine request source
    input  wire         wr_clk,
    input  wire         wr_rst_n,
    input  wire         s_req_valid,
    input  wire [63:0]  s_req_addr,
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
    input  wire         m_req_ack
);
    localparam integer PACKET_WORDS = REQ_DWORDS + 1;

    // ---------------------------------------------------------------------
    // Asynchronous FIFO (FWFT: dout always shows the current head)
    // ---------------------------------------------------------------------
    wire        fifo_empty;
    wire        fifo_full;
    wire [127:0] fifo_dout;
    wire        fifo_wr_en;
    wire [127:0] fifo_din;
    reg         fifo_rd_en;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_WRITE_DEPTH(FIFO_DEPTH),
        .WRITE_DATA_WIDTH(128),
        .READ_DATA_WIDTH(128),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES("0000")
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
        .prog_full      (),
        .wr_data_count  (),
        .almost_full    (),
        .prog_empty     (),
        .rd_data_count  (),
        .almost_empty   ()
    );

    // ---------------------------------------------------------------------
    // Writer FSM: reserve room for a whole packet, commit address word,
    // then swallow REQ_DWORDS payload beats. Ack returns to the engine
    // after the last beat lands in the FIFO.
    // ---------------------------------------------------------------------
    localparam WR_IDLE = 2'd0, WR_ADDR = 2'd1, WR_DATA = 2'd2;
    reg [1:0]  wr_state;
    reg [10:0] wr_beats_left;

    // Reservation accounting: each pushed word occupies a slot; slots are
    // released only after the reader has fully drained the packet (its
    // final-word flush included), so an in-flight packet can never be
    // overwritten. Room for a whole packet is required up front.
    reg [10:0] wr_reserved = 11'd0;
    wire wr_room_ok = ((wr_reserved + PACKET_WORDS) <= FIFO_DEPTH);

    // Reader -> writer "packet fully drained" toggle (crosses back here).
    reg        pkt_consumed_toggle = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] pkt_consumed_sync = 2'b00;
    wire pkt_consumed_pulse = pkt_consumed_sync[0] ^ pkt_consumed_sync[1];

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            pkt_consumed_sync <= 2'b00;
        else
            pkt_consumed_sync <= {pkt_consumed_sync[0], pkt_consumed_toggle};
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_reserved <= 11'd0;
        else if (fifo_wr_en)
            wr_reserved <= wr_reserved + 1'b1;
        else if (pkt_consumed_pulse && wr_reserved >= PACKET_WORDS)
            wr_reserved <= wr_reserved - PACKET_WORDS;
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_state         <= WR_IDLE;
            wr_beats_left    <= 11'd0;
            s_req_data_ready <= 1'b0;
            s_req_ack        <= 1'b0;
        end else begin
            s_req_ack <= 1'b0;

            case (wr_state)
                WR_IDLE: begin
                    if (s_req_valid && wr_room_ok && !fifo_full) begin
                        wr_beats_left <= REQ_DWORDS;
                        wr_state      <= WR_ADDR;
                    end
                end

                // Address word commits combinationally this cycle.
                WR_ADDR: begin
                    if (fifo_full) begin
                        wr_state <= WR_IDLE;           // pathological; retry
                    end else begin
                        wr_beats_left    <= REQ_DWORDS;
                        wr_state         <= WR_DATA;
                        s_req_data_ready <= 1'b1;
                    end
                end

                WR_DATA: begin
                    if (s_req_valid && s_req_data_ready) begin
                        wr_beats_left <= wr_beats_left - 1'b1;
                        if (wr_beats_left == 11'd1) begin
                            s_req_ack        <= 1'b1;
                            s_req_data_ready <= 1'b0;
                            wr_state         <= WR_IDLE;
                        end
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    assign fifo_din  = (wr_state == WR_ADDR) ? {64'd0, s_req_addr}
                                             : s_req_data;
    assign fifo_wr_en =
        (wr_state == WR_ADDR) ||
        (wr_state == WR_DATA && s_req_valid && s_req_data_ready);

    // ---------------------------------------------------------------------
    // Reader FSM: packet N may start only after N writer completions have
    // crossed, guaranteeing every word of the packet is resident. Each
    // accept reloads m_req_data from dout while issuing the pop, so
    // back-to-back PCIe handshakes always see a fresh beat.
    // ---------------------------------------------------------------------
    localparam RD_HDR = 2'd0, RD_FIRST = 2'd1, RD_RUN = 2'd2, RD_ACKWAIT = 2'd3;
    reg [1:0]  rd_state;
    reg [10:0] rd_rem_fetch;    // payload words still to prefetch
    reg [10:0] rd_rem_send;     // payload beats still to be accepted
    reg [15:0] rd_done_seen;    // completions observed in read domain
    reg [15:0] rd_started;      // packets started
    reg        rd_flush_pending;// last word of prev packet still at head

    // Writer -> reader "packet fully pushed" toggle.
    reg pkt_pushed_toggle = 1'b0;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            pkt_pushed_toggle <= 1'b0;
        else if (wr_state == WR_DATA && s_req_valid &&
                 s_req_data_ready && wr_beats_left == 11'd1)
            pkt_pushed_toggle <= ~pkt_pushed_toggle;
    end

    (* ASYNC_REG = "TRUE" *) reg [1:0] pkt_pushed_sync = 2'b00;
    always @(posedge rd_clk) begin
        if (!rd_rst_n)
            pkt_pushed_sync <= 2'b00;
        else
            pkt_pushed_sync <= {pkt_pushed_sync[0], pkt_pushed_toggle};
    end
    wire pkt_pushed_pulse = pkt_pushed_sync[0] ^ pkt_pushed_sync[1];

    // Reader -> writer "packet fully drained" toggle, pulsed once the
    // final (already-consumed) word of a packet has been flushed from the
    // FIFO. Written strictly after every pop of that packet, so the
    // writer may reuse those slots safely.

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_state     <= RD_HDR;
            rd_rem_fetch <= 11'd0;
            rd_rem_send  <= 11'd0;
            rd_done_seen <= 16'd0;
            rd_started   <= 16'd0;
            rd_flush_pending <= 1'b0;
            m_req_valid  <= 1'b0;
            m_req_addr   <= 64'd0;
            m_req_dw_len <= 11'd0;
            m_req_data   <= 128'd0;
        end else begin
            if (pkt_pushed_pulse)
                rd_done_seen <= rd_done_seen + 1'b1;

            case (rd_state)
                RD_HDR: begin
                    m_req_valid <= 1'b0;
                    if (rd_flush_pending && !fifo_empty) begin
                        // Discard the already-consumed final word of the
                        // previous packet that still sits at the head, then
                        // release its FIFO slots to the writer domain.
                        fifo_rd_en          <= 1'b1;
                        rd_flush_pending    <= 1'b0;
                        pkt_consumed_toggle <= ~pkt_consumed_toggle;
                    end else if (!fifo_empty &&
                                 (rd_done_seen != rd_started)) begin
                        // dout holds the address word of a fully resident
                        // packet. Pop it while latching.
                        m_req_addr   <= fifo_dout[63:0];
                        m_req_dw_len <= REQ_DWORDS;
                        fifo_rd_en   <= 1'b1;
                        rd_started   <= rd_started + 1'b1;
                        rd_rem_fetch <= REQ_DWORDS;
                        rd_rem_send  <= REQ_DWORDS;
                        rd_state     <= RD_FIRST;
                    end else begin
                        fifo_rd_en <= 1'b0;
                    end
                end

                // One cycle after the address-word pop, dout holds W1.
                RD_FIRST: begin
                    m_req_data   <= fifo_dout;
                    fifo_rd_en   <= 1'b1;               // prefetch W2
                    rd_rem_fetch <= rd_rem_fetch - 1'b1;
                    m_req_valid  <= 1'b1;
                    rd_state     <= RD_RUN;
                end

                RD_RUN: begin
                    if (m_req_valid && m_req_data_ready) begin
                        rd_rem_send <= rd_rem_send - 1'b1;
                        if (rd_rem_send == 11'd1) begin
                            rd_state        <= RD_ACKWAIT;
                            rd_flush_pending<= 1'b1;    // W64 still at head
                            fifo_rd_en      <= 1'b0;
                        end else begin
                            m_req_data <= fifo_dout;    // W(k+1)
                            fifo_rd_en <= 1'b1;         // prefetch W(k+2)
                        end
                    end else begin
                        fifo_rd_en <= 1'b0;
                    end
                end

                RD_ACKWAIT: begin
                    if (m_req_ack) begin
                        m_req_valid <= 1'b0;
                        rd_state    <= RD_HDR;
                    end
                end

                default: rd_state <= RD_HDR;
            endcase
        end
    end

endmodule
