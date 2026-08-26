// ============================================================================
// Module: video_req_cdc
// Description: Crosses the NV12 capture engine's C2H request interface from
//              the 150 MHz video clock domain to the 125 MHz PCIe requester
//              domain.  The video engine always emits fixed-size packets:
//              one 64-bit address word up front, then REQ_DWORDS/4 payload
//              beats (each beat is a 128-bit word = 4 DWs).
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
    // REQ_DWORDS is a DW count (m_req_dw_len / engine MWR_DWORDS).  The FIFO
    // and the streaming handshakes operate on 128-bit beats, so one payload
    // beat carries DATA_DWORDS DWs.
    localparam integer DATA_DWORDS   = 4;                       // 128-bit beat
    localparam integer PAYLOAD_BEATS = REQ_DWORDS / DATA_DWORDS;
    localparam integer PACKET_WORDS  = PAYLOAD_BEATS + 1;       // header + data
    localparam [11:0]  PACKET_WORDS_EXT = PACKET_WORDS;

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
    // then swallow PAYLOAD_BEATS payload beats. Ack returns to the engine
    // after the last beat lands in the FIFO.
    // ---------------------------------------------------------------------
    localparam WR_IDLE = 2'd0, WR_ADDR = 2'd1, WR_DATA = 2'd2, WR_DRAIN = 2'd3;
    reg [1:0]  wr_state;
    reg [10:0] wr_beats_left;

    // Reservation accounting: each pushed word occupies a slot; slots are
    // released only after the reader has fully drained the packet (its
    // final-word flush included), so an in-flight packet can never be
    // overwritten.  Room for a whole packet is required up front.  A push and
    // a drain pulse on the same cycle must both be applied or the counter
    // drifts upward and eventually deadlocks the pipeline.
    reg [10:0] wr_reserved = 11'd0;
    wire       wr_drain;
    wire [11:0] wr_reserved_next;
    wire wr_room_ok = ((wr_reserved + PACKET_WORDS) <= FIFO_DEPTH);

    // Reader -> writer "packet fully drained" toggle (crosses back here).
    reg        pkt_consumed_toggle = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] pkt_consumed_sync = 2'b00;
    wire pkt_consumed_pulse = pkt_consumed_sync[0] ^ pkt_consumed_sync[1];

    assign wr_drain = pkt_consumed_pulse && (wr_reserved >= PACKET_WORDS);
    assign wr_reserved_next = {1'b0, wr_reserved}
                            + (fifo_wr_en ? 12'd1 : 12'd0)
                            - (wr_drain   ? PACKET_WORDS_EXT : 12'd0);

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            pkt_consumed_sync <= 2'b00;
        else
            pkt_consumed_sync <= {pkt_consumed_sync[0], pkt_consumed_toggle};
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_reserved <= 11'd0;
        else
            wr_reserved <= wr_reserved_next[10:0];
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
                        wr_beats_left <= PAYLOAD_BEATS;
                        wr_state      <= WR_ADDR;
                    end
                end

                // Address word commits combinationally this cycle.
                WR_ADDR: begin
                    if (fifo_full) begin
                        wr_state <= WR_IDLE;           // pathological; retry
                    end else begin
                        wr_beats_left    <= PAYLOAD_BEATS;
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
                            // The ack is registered: the engine still holds
                            // s_req_valid for one more cycle.  Wait for it to
                            // drop before accepting a new request, otherwise
                            // the stale valid is mistaken for a new packet
                            // and the previous address is duplicated.
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

    assign fifo_din  = (wr_state == WR_ADDR) ? {64'd0, s_req_addr}
                                             : s_req_data;
    assign fifo_wr_en =
        (wr_state == WR_ADDR) ||
        (wr_state == WR_DATA && s_req_valid && s_req_data_ready);

    // ---------------------------------------------------------------------
    // Reader FSM: packet N may start only after N writer completions have
    // crossed, guaranteeing every word of the packet is resident.  The whole
    // packet (header + PAYLOAD_BEATS words) is first burst-read out of the
    // asynchronous FIFO into a small distributed buffer; the xpm FWFT dout
    // lags its pop by one cycle, which makes "pop and consume in the same
    // handshake" unreliable.  Replaying from the buffer is random-access,
    // so requester backpressure (m_req_data_ready gaps) is fully tolerated.
    // ---------------------------------------------------------------------
    localparam RD_HDR   = 3'd0,
               RD_BURST = 3'd1,
               RD_SERVE = 3'd2,
               RD_ACKWAIT = 3'd3;
    reg [2:0]  rd_state;

    reg [10:0] rd_rem_send;     // payload beats still to be accepted
    reg [15:0] rd_done_seen;    // completions observed in read domain
    reg [15:0] rd_started;      // packets started
    reg [4:0]  rd_burst_cnt;    // burst-pop cycle counter
    reg [4:0]  rd_serve_idx;    // next payload beat to present

    (* ram_style = "distributed" *)
    reg [127:0] rd_buf [0:PAYLOAD_BEATS-1];

    // Writer -> reader "packet fully pushed" toggle.
    reg pkt_pushed_toggle = 1'b0;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            pkt_pushed_toggle <= 1'b0;
        else if (wr_state == WR_DATA && s_req_valid &&
                 s_req_data_ready && wr_beats_left == 11'd1) begin
            pkt_pushed_toggle <= ~pkt_pushed_toggle;
            $display("[%0t] VREQ: packet pushed (toggle=%b)", $time,
                     pkt_pushed_toggle);
        end
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
            rd_rem_send  <= 11'd0;
            rd_done_seen <= 16'd0;
            rd_started   <= 16'd0;
            rd_burst_cnt <= 5'd0;
            rd_serve_idx <= 5'd0;
            m_req_valid  <= 1'b0;
            m_req_addr   <= 64'd0;
            m_req_dw_len <= 11'd0;
            m_req_data   <= 128'd0;
        end else begin
            if (pkt_pushed_pulse)
                rd_done_seen <= rd_done_seen + 1'b1;

            case (rd_state)
                // dout holds the address word of a fully resident packet.
                // Latch it and start the burst pop (header + all payload
                // words) with fifo_rd_en held high.
                RD_HDR: begin
                    m_req_valid <= 1'b0;
                    if (!fifo_empty && (rd_done_seen != rd_started)) begin
                        m_req_addr   <= fifo_dout[63:0];
                        m_req_dw_len <= REQ_DWORDS;
                        fifo_rd_en   <= 1'b1;
                        rd_started   <= rd_started + 1'b1;
                        rd_rem_send  <= PAYLOAD_BEATS;
                        rd_burst_cnt <= 5'd0;
                        rd_state     <= RD_BURST;
                    end else begin
                        fifo_rd_en <= 1'b0;
                    end
                end

                // The FWFT dout lags a pop by one read clock.  After one
                // settle cycle, dout streams the payload words; capture
                // them until PAYLOAD_BEATS words are buffered.  Exactly
                // PACKET_WORDS pops are issued (header + payload), so the
                // FIFO stays word-aligned for the next packet.
                RD_BURST: begin
                    if (rd_burst_cnt == 5'd0) begin
                        fifo_rd_en   <= 1'b1;       // hold through the burst
                        rd_burst_cnt <= 5'd1;       // dout settle cycle
                    end else if (rd_burst_cnt <= PAYLOAD_BEATS) begin
                        if (rd_burst_cnt == PAYLOAD_BEATS)
                            fifo_rd_en  <= 1'b0;    // 17th pop just issued
                        rd_buf[rd_burst_cnt - 5'd1] <= fifo_dout;
                        rd_burst_cnt <= rd_burst_cnt + 5'd1;
                    end else begin                  // one drain cycle later
                        rd_serve_idx <= 5'd1;
                        m_req_data   <= rd_buf[0];
                        m_req_valid  <= 1'b1;
                        rd_state     <= RD_SERVE;
                    end
                end

                // Random-access replay: every accepted beat advances into
                // the buffer, so requester stalls cost nothing.
                RD_SERVE: begin
                    if (m_req_valid && m_req_data_ready) begin
                        rd_rem_send <= rd_rem_send - 1'b1;
                        if (rd_rem_send == 11'd1) begin
                            rd_state            <= RD_ACKWAIT;
                            pkt_consumed_toggle <= ~pkt_consumed_toggle;
                        end else begin
                            m_req_data   <= rd_buf[rd_serve_idx[3:0]];
                            rd_serve_idx <= rd_serve_idx + 5'd1;
                        end
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
