// ============================================================================
// Module: sg_host_fetch_engine
// Description: Autonomous PCIe MRd Host Variable-Length SGL Fetch Engine.
//              Fetches 128-bit SGL segment descriptors ({phys_addr[63:0],
//              seg_len_bytes[31:0], flags[31:0]}) from Host Coherent Memory
//              via aligned PCIe MRd 64-byte bursts, follows Chained Slot
//              Pointers, and pushes segment descriptors into on-chip Segment
//              Walker FIFOs.
//
//  Direction-decoupled table buffering:
//  --------------------------------
//  The descriptor pipeline (desc_fetch_engine) blocks until a descriptor's
//  whole SGL table is fetched (WAIT_SGL_FETCH), but a consumer whose walker
//  FIFO is almost-full can only drain once its *paired* engine runs (the H2C
//  engine drains only as fast as the loopback FIFO, which drains only when the
//  capture engine is armed).  If the fetch stalled on consumer backpressure,
//  the descriptor pipeline would never advance and the whole channel would
//  deadlock with zero completions.
//
//  To break that circular dependency, this engine buffers each direction's
//  complete Y/UV table into internal block-RAM FIFOs (one pair per direction,
//  sized for a full 4K NV12M frame: Y 2025 entries, UV 1013 entries).  The
//  fetch completes as soon as the table is resident on-chip, so sg_fetch_busy
//  deasserts and the descriptor pipeline advances.  A background drain then
//  trickles the buffered entries into the destination walker FIFOs as
//  consumer backpressure allows.
//
//  A new fetch for the same direction can only be triggered by the descriptor
//  pipeline after the previous descriptor's DMA completed, by which time the
//  previous table has been fully drained and consumed, so the internal FIFOs
//  are always empty when a new table starts to buffer.
// ============================================================================

`timescale 1ns / 1ps

module sg_host_fetch_engine #(
    parameter DATA_WIDTH = 128,
    parameter integer Y_FIFO_DEPTH  = 2048, // 4K Y plane table = 2025 entries
    parameter integer UV_FIFO_DEPTH = 1024  // 4K UV plane table = 1013 entries
)(
    input  wire        clk,
    input  wire        rst_n,

    // Trigger from Descriptor Dispatch (H2C or C2H Video Channel)
    input  wire        fetch_start,
    input  wire [2:0]  fetch_channel, // 0..3 = C2H Ch0..Ch3, 4 = H2C
    input  wire [63:0] plane0_slot_addr,
    input  wire [63:0] plane1_slot_addr,
    input  wire [15:0] plane0_pages_req,
    input  wire [15:0] plane1_pages_req,
    output reg         fetch_busy,
    output reg         fetch_done,

    // PCIe MRd Requester Interface (To RQ TX Encoder)
    output reg         mrd_req_valid,
    output reg  [63:0] mrd_req_addr,
    output reg  [10:0] mrd_req_dw_len, // 16 DWs = 64 Bytes
    output reg  [7:0]  mrd_req_tag,    // Tag 8'h01 reserved for SG Fetch
    input  wire        mrd_req_ack,

    // PCIe CplD Completion Interface (From RC RX Decoder)
    input  wire        cpld_valid,
    input  wire [DATA_WIDTH-1:0] cpld_data,
    input  wire        cpld_last,
    input  wire [7:0]  cpld_tag,

    // SGL Segment Push Ports (To sg_segment_walker)
    // sgl_*_channel selects the destination: 4 = H2C, 0..3 = C2H Ch0..Ch3
    output reg  [2:0]  sgl_y_channel,
    output reg         sgl_y_wr_en,
    output reg  [63:0] sgl_y_wr_addr,
    output reg  [31:0] sgl_y_wr_len,
    output reg  [31:0] sgl_y_wr_flags,

    output reg  [2:0]  sgl_uv_channel,
    output reg         sgl_uv_wr_en,
    output reg  [63:0] sgl_uv_wr_addr,
    output reg  [31:0] sgl_uv_wr_len,
    output reg  [31:0] sgl_uv_wr_flags,

    // Flow Control Backpressure (Bit 4: H2C, Bit 0..3: C2H Channel 0..3)
    input  wire [4:0]  channel_y_almost_full,
    input  wire [4:0]  channel_uv_almost_full
);

    localparam S_IDLE       = 3'd0;
    localparam S_REQ_BURST  = 3'd1;
    localparam S_WAIT_CPLD  = 3'd2;
    localparam S_PUSH_SGL   = 3'd3;
    localparam S_NEXT_BURST = 3'd4;
    localparam S_SWITCH_UV  = 3'd5;
    localparam S_DONE       = 3'd6;

    reg [2:0]  state;
    reg [2:0]  curr_channel;
    reg        curr_plane; // 0 = Y Plane, 1 = UV Plane
    reg [63:0] curr_slot_base;
    reg [63:0] curr_plane1_slot_addr;

    reg [11:0] curr_slot_offset; // 0 .. 4095
    reg [63:0] next_slot_ptr;
    reg        curr_plane_last_seen;

    // A 64-byte read contains four 128-bit SGL descriptors. Keeping requests
    // within one 64-byte RCB avoids split completions with repeated headers.
    reg [63:0] buf_addr  [0:15];
    reg [31:0] buf_len   [0:15];
    reg [31:0] buf_flags [0:15];
    reg [3:0]  buf_wr_idx;
    reg [4:0]  buf_rd_idx;
    reg [31:0] dw_hold;
    reg [4:0]  cpld_beat_cnt;

    // C2H channel latched at fetch time; used by the C2H drains.  Requests are
    // serialized and the C2H FIFOs are always drained before the next C2H
    // descriptor is dispatched, so a single register suffices.
    reg [2:0] c2h_channel;

    // ------------------------------------------------------------------------
    // Internal per-direction, per-plane table buffers (block RAM)
    // ------------------------------------------------------------------------
    reg         h2c_y_wr_en,  c2h_y_wr_en,  h2c_uv_wr_en,  c2h_uv_wr_en;
    reg  [127:0] h2c_y_din,   c2h_y_din,   h2c_uv_din,   c2h_uv_din;
    reg         h2c_y_rd_en,  c2h_y_rd_en,  h2c_uv_rd_en,  c2h_uv_rd_en;
    wire [127:0] h2c_y_dout,  c2h_y_dout,  h2c_uv_dout,  c2h_uv_dout;
    wire        h2c_y_empty,  c2h_y_empty,  h2c_uv_empty,  c2h_uv_empty;
    wire        h2c_y_full,   c2h_y_full,   h2c_uv_full,   c2h_uv_full;

    // True while the current S_PUSH_SGL entry must be held because its target
    // internal buffer is full.  Only reachable with an oversized table (the
    // driver enforces slot/entry limits); a stall is preferable to silently
    // dropping entries.
    wire sgl_write_blocked =
        (curr_plane == 1'b0) ? ((curr_channel == 3'd4) ? h2c_y_full : c2h_y_full)
                             : ((curr_channel == 3'd4) ? h2c_uv_full : c2h_uv_full);

    sgl_buf_fifo #(.DEPTH(Y_FIFO_DEPTH)) u_h2c_y_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(h2c_y_wr_en), .din(h2c_y_din),
        .rd_en(h2c_y_rd_en), .dout(h2c_y_dout),
        .empty(h2c_y_empty), .full(h2c_y_full)
    );
    sgl_buf_fifo #(.DEPTH(UV_FIFO_DEPTH)) u_h2c_uv_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(h2c_uv_wr_en), .din(h2c_uv_din),
        .rd_en(h2c_uv_rd_en), .dout(h2c_uv_dout),
        .empty(h2c_uv_empty), .full(h2c_uv_full)
    );
    sgl_buf_fifo #(.DEPTH(Y_FIFO_DEPTH)) u_c2h_y_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(c2h_y_wr_en), .din(c2h_y_din),
        .rd_en(c2h_y_rd_en), .dout(c2h_y_dout),
        .empty(c2h_y_empty), .full(c2h_y_full)
    );
    sgl_buf_fifo #(.DEPTH(UV_FIFO_DEPTH)) u_c2h_uv_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(c2h_uv_wr_en), .din(c2h_uv_din),
        .rd_en(c2h_uv_rd_en), .dout(c2h_uv_dout),
        .empty(c2h_uv_empty), .full(c2h_uv_full)
    );

    // CplD Beat unpacker into 16-entry 128-bit SGL buffer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dw_hold       <= 32'd0;
            cpld_beat_cnt <= 5'd0;
            buf_wr_idx    <= 4'd0;
        end else if (state == S_IDLE || state == S_REQ_BURST) begin
            dw_hold       <= 32'd0;
            cpld_beat_cnt <= 5'd0;
            buf_wr_idx    <= 4'd0;
        end else if (cpld_valid && (cpld_tag == 8'h01)) begin
            cpld_beat_cnt <= cpld_beat_cnt + 1'b1;
            if (cpld_beat_cnt == 5'd0) begin
                // Beat 0: Header in [95:0], DW0 payload in [127:96]
                dw_hold <= cpld_data[127:96];
            end else begin
                // Beat 1..16: Store one 128-bit SGL Entry
                buf_addr[buf_wr_idx]  <= {cpld_data[31:0], dw_hold};
                buf_len[buf_wr_idx]   <= cpld_data[63:32];
                buf_flags[buf_wr_idx] <= cpld_data[95:64];
                dw_hold               <= cpld_data[127:96];
                buf_wr_idx            <= buf_wr_idx + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Main Control State Machine: fetch + buffer the current descriptor's table
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            fetch_busy           <= 1'b0;
            fetch_done           <= 1'b0;
            mrd_req_valid        <= 1'b0;
            mrd_req_addr         <= 64'd0;
            mrd_req_dw_len       <= 11'd16; // 64 Bytes (16 DWs)
            mrd_req_tag          <= 8'h01;
            h2c_y_wr_en          <= 1'b0;
            c2h_y_wr_en          <= 1'b0;
            h2c_uv_wr_en         <= 1'b0;
            c2h_uv_wr_en         <= 1'b0;
            h2c_y_din            <= 128'd0;
            c2h_y_din            <= 128'd0;
            h2c_uv_din           <= 128'd0;
            c2h_uv_din           <= 128'd0;
            curr_channel         <= 3'd0;
            c2h_channel          <= 3'd0;
            curr_plane           <= 1'b0;
            curr_slot_base       <= 64'd0;
            curr_plane1_slot_addr<= 64'd0;
            curr_slot_offset     <= 12'd0;
            next_slot_ptr        <= 64'd0;
            curr_plane_last_seen <= 1'b0;
            buf_rd_idx           <= 5'd0;
        end else begin
            h2c_y_wr_en  <= 1'b0;
            c2h_y_wr_en  <= 1'b0;
            h2c_uv_wr_en <= 1'b0;
            c2h_uv_wr_en <= 1'b0;
            fetch_done   <= 1'b0;

            case (state)
                S_IDLE: begin
                    fetch_busy    <= 1'b0;
                    mrd_req_valid <= 1'b0;
                    buf_rd_idx    <= 5'd0;
                    if (fetch_start) begin
                        fetch_busy           <= 1'b1;
                        curr_channel         <= fetch_channel;
                        curr_plane           <= 1'b0; // Start with Y Plane
                        curr_slot_base       <= plane0_slot_addr;
                        curr_plane1_slot_addr<= plane1_slot_addr;
                        curr_slot_offset     <= 12'd0;
                        curr_plane_last_seen <= 1'b0;
                        if (fetch_channel != 3'd4)
                            c2h_channel      <= fetch_channel;
                        state                <= S_REQ_BURST;
                    end
                end

                S_REQ_BURST: begin
                    // Fetch is decoupled from consumer backpressure: the whole
                    // table is buffered internally before fetch completes.
                    mrd_req_valid  <= 1'b1;
                    mrd_req_addr   <= curr_slot_base + curr_slot_offset;
                    mrd_req_dw_len <= 11'd16; // 64 Bytes (4 entries)
                    mrd_req_tag    <= 8'h01;
                    buf_rd_idx     <= 5'd0;

                    if (mrd_req_valid && mrd_req_ack) begin
                        mrd_req_valid <= 1'b0;
                        state         <= S_WAIT_CPLD;
                    end
                end

                S_WAIT_CPLD: begin
                    if (cpld_valid && (cpld_tag == 8'h01) && cpld_last) begin
                        state <= S_PUSH_SGL;
                    end
                end

                S_PUSH_SGL: begin
                    if (buf_rd_idx < 5'd4) begin
                        if (!curr_plane_last_seen) begin
                            // Check if entry has chain pointer flag (Bit 0)
                            if (buf_flags[buf_rd_idx[3:0]][0]) begin
                                next_slot_ptr <= buf_addr[buf_rd_idx[3:0]];
                                buf_rd_idx    <= buf_rd_idx + 1'b1;
                            end else if (buf_len[buf_rd_idx[3:0]] > 0) begin
                                if (sgl_write_blocked) begin
                                    // Hold: target internal buffer full.
                                end else begin
                                    // Buffer valid segment into the direction/plane FIFO
                                    if (curr_plane == 1'b0) begin
                                        if (curr_channel == 3'd4) begin
                                            h2c_y_wr_en <= 1'b1;
                                            h2c_y_din   <= {buf_flags[buf_rd_idx[3:0]],
                                                            buf_len[buf_rd_idx[3:0]],
                                                            buf_addr[buf_rd_idx[3:0]]};
                                        end else begin
                                            c2h_y_wr_en <= 1'b1;
                                            c2h_y_din   <= {buf_flags[buf_rd_idx[3:0]],
                                                            buf_len[buf_rd_idx[3:0]],
                                                            buf_addr[buf_rd_idx[3:0]]};
                                        end
                                    end else begin
                                        if (curr_channel == 3'd4) begin
                                            h2c_uv_wr_en <= 1'b1;
                                            h2c_uv_din   <= {buf_flags[buf_rd_idx[3:0]],
                                                             buf_len[buf_rd_idx[3:0]],
                                                             buf_addr[buf_rd_idx[3:0]]};
                                        end else begin
                                            c2h_uv_wr_en <= 1'b1;
                                            c2h_uv_din   <= {buf_flags[buf_rd_idx[3:0]],
                                                             buf_len[buf_rd_idx[3:0]],
                                                             buf_addr[buf_rd_idx[3:0]]};
                                        end
                                    end

                                    // Check if last segment in plane (Bit 1)
                                    if (buf_flags[buf_rd_idx[3:0]][1])
                                        curr_plane_last_seen <= 1'b1;
                                    buf_rd_idx <= buf_rd_idx + 1'b1;
                                end
                            end else begin
                                buf_rd_idx <= buf_rd_idx + 1'b1;
                            end
                        end else begin
                            buf_rd_idx <= buf_rd_idx + 1'b1;
                        end
                    end else begin
                        state <= S_NEXT_BURST;
                    end
                end

                S_NEXT_BURST: begin
                    if (curr_plane_last_seen) begin
                        // Current plane is finished
                        if (curr_plane == 1'b0 && curr_plane1_slot_addr != 64'd0) begin
                            state <= S_SWITCH_UV;
                        end else begin
                            state <= S_DONE;
                        end
                    end else if (curr_slot_offset >= 12'hFC0) begin
                        // End of 4KB slot reached, follow chained link pointer!
                        if (next_slot_ptr != 64'd0) begin
                            curr_slot_base   <= next_slot_ptr;
                            curr_slot_offset <= 12'd0;
                            state            <= S_REQ_BURST;
                        end else begin
                            if (curr_plane == 1'b0 && curr_plane1_slot_addr != 64'd0) begin
                                state <= S_SWITCH_UV;
                            end else begin
                                state <= S_DONE;
                            end
                        end
                    end else begin
                        // Advance to next 64B burst within current 4KB slot
                        curr_slot_offset <= curr_slot_offset + 12'd64;
                        state            <= S_REQ_BURST;
                    end
                end

                S_SWITCH_UV: begin
                    curr_plane           <= 1'b1; // Switch to UV Plane
                    curr_slot_base       <= curr_plane1_slot_addr;
                    curr_slot_offset     <= 12'd0;
                    curr_plane_last_seen <= 1'b0;
                    next_slot_ptr        <= 64'd0;
                    state                <= S_REQ_BURST;
                end

                S_DONE: begin
                    fetch_busy <= 1'b0;
                    fetch_done <= 1'b1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Background drains: pop the buffered tables and push to the destination
    // walker FIFOs as consumer backpressure allows.  The internal FIFO's
    // registered read makes the popped entry visible on dout two cycles after
    // the pop is issued, so a push is qualified with y/uv_pop_ready one cycle
    // after y/uv_pop_pending.  The almost-full threshold leaves enough margin
    // for that in-flight entry.  Y and UV drains run independently.
    // ------------------------------------------------------------------------
    reg y_pop_pending, y_pop_ready, y_pop_h2c;
    reg uv_pop_pending, uv_pop_ready, uv_pop_h2c;
    reg y_arb, uv_arb;

    wire h2c_y_can_pop = !h2c_y_empty && !channel_y_almost_full[4];
    wire c2h_y_can_pop = !c2h_y_empty && !channel_y_almost_full[c2h_channel];
    wire h2c_uv_can_pop = !h2c_uv_empty && !channel_uv_almost_full[4];
    wire c2h_uv_can_pop = !c2h_uv_empty && !channel_uv_almost_full[c2h_channel];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_pop_pending <= 1'b0;
            y_pop_ready   <= 1'b0;
            y_pop_h2c     <= 1'b1;
            y_arb         <= 1'b0;
            sgl_y_channel <= 3'd0;
            sgl_y_wr_en   <= 1'b0;
            sgl_y_wr_addr <= 64'd0;
            sgl_y_wr_len  <= 32'd0;
            sgl_y_wr_flags<= 32'd0;
        end else begin
            h2c_y_rd_en <= 1'b0;
            c2h_y_rd_en <= 1'b0;
            sgl_y_wr_en <= 1'b0;

            if (y_pop_pending && y_pop_ready) begin
                // Push the entry whose registered read has now landed
                sgl_y_wr_en    <= 1'b1;
                sgl_y_channel  <= y_pop_h2c ? 3'd4 : c2h_channel;
                sgl_y_wr_addr  <= y_pop_h2c ? h2c_y_dout[63:0]   : c2h_y_dout[63:0];
                sgl_y_wr_len   <= y_pop_h2c ? h2c_y_dout[95:64]  : c2h_y_dout[95:64];
                sgl_y_wr_flags <= y_pop_h2c ? h2c_y_dout[127:96] : c2h_y_dout[127:96];
                y_pop_pending  <= 1'b0;
                y_pop_ready    <= 1'b0;
                y_arb          <= ~y_arb;
            end else if (y_pop_pending) begin
                // One cycle after the pop: the registered read lands next cycle
                y_pop_ready <= 1'b1;
            end else begin
                if ((y_arb == 1'b0 && h2c_y_can_pop) ||
                    (y_arb == 1'b1 && !c2h_y_can_pop && h2c_y_can_pop)) begin
                    h2c_y_rd_en  <= 1'b1;
                    y_pop_pending <= 1'b1;
                    y_pop_h2c     <= 1'b1;
                end else if ((y_arb == 1'b1 && c2h_y_can_pop) ||
                             (y_arb == 1'b0 && !h2c_y_can_pop && c2h_y_can_pop)) begin
                    c2h_y_rd_en  <= 1'b1;
                    y_pop_pending <= 1'b1;
                    y_pop_h2c     <= 1'b0;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uv_pop_pending <= 1'b0;
            uv_pop_ready   <= 1'b0;
            uv_pop_h2c     <= 1'b1;
            uv_arb         <= 1'b0;
            sgl_uv_channel <= 3'd0;
            sgl_uv_wr_en   <= 1'b0;
            sgl_uv_wr_addr <= 64'd0;
            sgl_uv_wr_len  <= 32'd0;
            sgl_uv_wr_flags<= 32'd0;
        end else begin
            h2c_uv_rd_en <= 1'b0;
            c2h_uv_rd_en <= 1'b0;
            sgl_uv_wr_en <= 1'b0;

            if (uv_pop_pending && uv_pop_ready) begin
                // Push the entry whose registered read has now landed
                sgl_uv_wr_en    <= 1'b1;
                sgl_uv_channel  <= uv_pop_h2c ? 3'd4 : c2h_channel;
                sgl_uv_wr_addr  <= uv_pop_h2c ? h2c_uv_dout[63:0]   : c2h_uv_dout[63:0];
                sgl_uv_wr_len   <= uv_pop_h2c ? h2c_uv_dout[95:64]  : c2h_uv_dout[95:64];
                sgl_uv_wr_flags <= uv_pop_h2c ? h2c_uv_dout[127:96] : c2h_uv_dout[127:96];
                uv_pop_pending  <= 1'b0;
                uv_pop_ready    <= 1'b0;
                uv_arb          <= ~uv_arb;
            end else if (uv_pop_pending) begin
                // One cycle after the pop: the registered read lands next cycle
                uv_pop_ready <= 1'b1;
            end else begin
                if ((uv_arb == 1'b0 && h2c_uv_can_pop) ||
                    (uv_arb == 1'b1 && !c2h_uv_can_pop && h2c_uv_can_pop)) begin
                    h2c_uv_rd_en <= 1'b1;
                    uv_pop_pending <= 1'b1;
                    uv_pop_h2c     <= 1'b1;
                end else if ((uv_arb == 1'b1 && c2h_uv_can_pop) ||
                             (uv_arb == 1'b0 && !h2c_uv_can_pop && c2h_uv_can_pop)) begin
                    c2h_uv_rd_en <= 1'b1;
                    uv_pop_pending <= 1'b1;
                    uv_pop_h2c     <= 1'b0;
                end
            end
        end
    end

endmodule

// ============================================================================
// Module: sgl_buf_fifo
// Description: Synchronous block-RAM FIFO used to buffer one SGL table.
//              Standard synchronous read: rd_en at cycle N makes dout valid
//              at cycle N+1.  DEPTH must exceed the largest buffered table.
// ============================================================================
module sgl_buf_fifo #(
    parameter integer DEPTH = 2048,
    parameter integer WIDTH = 128
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  wr_en,
    input  wire [WIDTH-1:0]      din,
    input  wire                  rd_en,
    output reg  [WIDTH-1:0]      dout,
    output wire                  empty,
    output wire                  full
);
    localparam AW = $clog2(DEPTH);

    (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0] wr_ptr;
    reg [AW-1:0] rd_ptr;
    reg [AW:0]   count;

    assign empty = (count == {(AW+1){1'b0}});
    assign full  = (count == DEPTH[AW:0]);

    // Simple-dual-port inference: write block without reset, read block
    // registered.  Kept in separate always blocks so block RAM is inferred.
    always @(posedge clk) begin
        if (wr_en)
            mem[wr_ptr] <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {AW{1'b0}};
            rd_ptr <= {AW{1'b0}};
            count  <= {(AW+1){1'b0}};
            dout   <= {WIDTH{1'b0}};
        end else begin
            if (rd_en)
                dout <= mem[rd_ptr];

            if (wr_en && rd_en) begin
                wr_ptr <= wr_ptr + 1'b1;
                rd_ptr <= rd_ptr + 1'b1;
            end else if (wr_en) begin
                wr_ptr <= wr_ptr + 1'b1;
                count  <= count + 1'b1;
            end else if (rd_en) begin
                rd_ptr <= rd_ptr + 1'b1;
                count  <= count - 1'b1;
            end
        end
    end

endmodule