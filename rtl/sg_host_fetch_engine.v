// ============================================================================
// Module: sg_host_fetch_engine
// Description: Autonomous PCIe MRd Host Variable-Length SGL Fetch Engine.
//              Fetches 128-bit SGL segment descriptors ({phys_addr[63:0],
//              seg_len_bytes[31:0], flags[31:0]}) from Host Coherent Memory
//              via PCIe MRd 256-byte bursts, pushes segment descriptors into
//              on-chip Segment Walker FIFOs, and follows Chained Slot Pointers.
// ============================================================================

`timescale 1ns / 1ps

module sg_host_fetch_engine #(
    parameter DATA_WIDTH = 128
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
    output reg  [10:0] mrd_req_dw_len, // 64 DWs = 256 Bytes
    output reg  [7:0]  mrd_req_tag,    // Tag 8'h01 reserved for SG Fetch
    input  wire        mrd_req_ack,

    // PCIe CplD Completion Interface (From RC RX Decoder)
    input  wire        cpld_valid,
    input  wire [DATA_WIDTH-1:0] cpld_data,
    input  wire        cpld_last,
    input  wire [7:0]  cpld_tag,

    // SGL Segment Push Ports (To sg_segment_walker)
    output reg  [2:0]  sgl_channel,
    output reg         sgl_y_wr_en,
    output reg  [63:0] sgl_y_wr_addr,
    output reg  [31:0] sgl_y_wr_len,
    output reg  [31:0] sgl_y_wr_flags,

    output reg         sgl_uv_wr_en,
    output reg  [63:0] sgl_uv_wr_addr,
    output reg  [31:0] sgl_uv_wr_len,
    output reg  [31:0] sgl_uv_wr_flags
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
    reg [11:0] curr_slot_offset; // 0 .. 4095
    reg [63:0] next_slot_ptr;
    reg        curr_plane_last_seen;

    // 16-Entry Burst Buffer for 128-bit SGL descriptors
    reg [63:0] buf_addr  [0:15];
    reg [31:0] buf_len   [0:15];
    reg [31:0] buf_flags [0:15];
    reg [3:0]  buf_wr_idx;
    reg [4:0]  buf_rd_idx;
    reg [31:0] dw_hold;
    reg [4:0]  cpld_beat_cnt;

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

    // Main Control State Machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            fetch_busy           <= 1'b0;
            fetch_done           <= 1'b0;
            mrd_req_valid        <= 1'b0;
            mrd_req_addr         <= 64'd0;
            mrd_req_dw_len       <= 11'd64; // 256 Bytes (64 DWs)
            mrd_req_tag          <= 8'h01;
            sgl_y_wr_en          <= 1'b0;
            sgl_y_wr_addr        <= 64'd0;
            sgl_y_wr_len         <= 32'd0;
            sgl_y_wr_flags       <= 32'd0;
            sgl_uv_wr_en         <= 1'b0;
            sgl_uv_wr_addr       <= 64'd0;
            sgl_uv_wr_len        <= 32'd0;
            sgl_uv_wr_flags      <= 32'd0;
            curr_channel         <= 3'd0;
            sgl_channel          <= 3'd0;
            curr_plane           <= 1'b0;
            curr_slot_base       <= 64'd0;
            curr_slot_offset     <= 12'd0;
            next_slot_ptr        <= 64'd0;
            curr_plane_last_seen <= 1'b0;
            buf_rd_idx           <= 5'd0;
        end else begin
            sgl_y_wr_en  <= 1'b0;
            sgl_uv_wr_en <= 1'b0;
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
                        curr_slot_offset     <= 12'd0;
                        curr_plane_last_seen <= 1'b0;
                        state                <= S_REQ_BURST;
                    end
                end

                S_REQ_BURST: begin
                    mrd_req_valid  <= 1'b1;
                    mrd_req_addr   <= curr_slot_base + curr_slot_offset;
                    mrd_req_dw_len <= 11'd64; // 256 Bytes (16 entries)
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
                    sgl_channel <= curr_channel;
                    if (buf_rd_idx < 5'd16) begin
                        buf_rd_idx <= buf_rd_idx + 1'b1;

                        // Check if entry has chain pointer flag (Bit 0)
                        if (buf_flags[buf_rd_idx[3:0]][0]) begin
                            next_slot_ptr <= buf_addr[buf_rd_idx[3:0]];
                        end else if (buf_len[buf_rd_idx[3:0]] > 0) begin
                            // Valid segment descriptor: push to Segment Walker FIFO
                            if (curr_plane == 1'b0) begin
                                sgl_y_wr_en    <= 1'b1;
                                sgl_y_wr_addr  <= buf_addr[buf_rd_idx[3:0]];
                                sgl_y_wr_len   <= buf_len[buf_rd_idx[3:0]];
                                sgl_y_wr_flags <= buf_flags[buf_rd_idx[3:0]];
                            end else begin
                                sgl_uv_wr_en    <= 1'b1;
                                sgl_uv_wr_addr  <= buf_addr[buf_rd_idx[3:0]];
                                sgl_uv_wr_len   <= buf_len[buf_rd_idx[3:0]];
                                sgl_uv_wr_flags <= buf_flags[buf_rd_idx[3:0]];
                            end

                            // Check if last segment in plane (Bit 1)
                            if (buf_flags[buf_rd_idx[3:0]][1]) begin
                                curr_plane_last_seen <= 1'b1;
                            end
                        end
                    end else begin
                        state <= S_NEXT_BURST;
                    end
                end

                S_NEXT_BURST: begin
                    if (curr_plane_last_seen) begin
                        // Current plane is finished
                        if (curr_plane == 1'b0 && plane1_slot_addr != 64'd0) begin
                            state <= S_SWITCH_UV;
                        end else begin
                            state <= S_DONE;
                        end
                    end else if (curr_slot_offset >= 12'hF00) begin
                        // End of 4KB slot reached, follow chained link pointer!
                        if (next_slot_ptr != 64'd0) begin
                            curr_slot_base   <= next_slot_ptr;
                            curr_slot_offset <= 12'd0;
                            state            <= S_REQ_BURST;
                        end else begin
                            if (curr_plane == 1'b0 && plane1_slot_addr != 64'd0) begin
                                state <= S_SWITCH_UV;
                            end else begin
                                state <= S_DONE;
                            end
                        end
                    end else begin
                        // Advance to next 256B burst within current 4KB slot
                        curr_slot_offset <= curr_slot_offset + 12'd256;
                        state            <= S_REQ_BURST;
                    end
                end

                S_SWITCH_UV: begin
                    curr_plane           <= 1'b1; // Switch to UV Plane
                    curr_slot_base       <= plane1_slot_addr;
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

endmodule
