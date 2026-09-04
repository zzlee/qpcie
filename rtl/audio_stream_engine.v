// ============================================================================
// Module: audio_stream_engine
// Description: Multi-Channel Audio Stream Engine with Circular Host DMA & Hardware PTS.
//              Captures 32-bit AES3/IEC 60958 audio subframes from audio_pattern_gen:
//              - Internal 64-entry decoupling FIFO absorbs PCIe bus latency
//              - Packs 4 subframes into 128-bit PCIe beats (16-byte MWr bursts)
//              - Streams into host ALSA circular DMA buffer (host_buffer_addr + cur_write_ptr)
//              - Generates audio_block_done period interrupt every period_size_bytes
//              - Latches 64-bit hardware PTS timestamp on AES3 Block Start (Preamble B)
// ============================================================================

`timescale 1ns / 1ps

module audio_stream_engine #(
    parameter AUDIO_DATA_WIDTH = 32,
    parameter PCIE_DATA_WIDTH  = 128
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // Audio Engine Control
    input  wire                          audio_start,
    input  wire [63:0]                   host_buffer_addr,
    input  wire [31:0]                   buffer_size_bytes, // Total ALSA ring size (e.g. 64KB = 65536)
    input  wire [31:0]                   period_size_bytes, // Period size (e.g. 4KB = 4096)
    output wire [31:0]                   cur_write_ptr,     // Current byte offset in ALSA buffer
    input  wire [63:0]                   global_timestamp,  // Hardware AV Sync Master Timestamp (ns)

    // C2H Input AES3 Audio Stream (From audio_pattern_gen)
    input  wire [AUDIO_DATA_WIDTH-1:0]   s_axis_audio_tdata, // 32-bit AES3 subframe
    input  wire                          s_axis_audio_tvalid,
    input  wire                          s_axis_audio_tlast, // End of audio block
    output wire                          s_axis_audio_tready,

    // Interface to RQ Encoder (C2H Low-Latency Audio MWr Request)
    output reg                           c2h_req_valid,
    output reg  [63:0]                   c2h_req_addr,
    output reg  [10:0]                   c2h_req_dw_len,
    output reg  [PCIE_DATA_WIDTH-1:0]    c2h_req_data,
    output reg                           c2h_req_last,
    input  wire                          c2h_req_ack,

    // Status & PTS Signals
    output reg                           audio_busy,
    output reg                           audio_block_done,
    output reg  [63:0]                   audio_pts          // Latched AES3 Block PTS Timestamp (ns)
);

    localparam IDLE     = 1'b0;
    localparam C2H_SEND = 1'b1;

    // Default buffer and period sizes if unconfigured
    wire [31:0] actual_buf_size    = (buffer_size_bytes != 32'd0) ? buffer_size_bytes : 32'd65536;
    wire [31:0] actual_period_size = (period_size_bytes != 32'd0) ? period_size_bytes : 32'd4096;

    reg [31:0] reg_write_ptr;
    reg [31:0] reg_period_accum;
    assign cur_write_ptr = reg_write_ptr;

    // -------------------------------------------------------------------------
    // 64-entry 32-bit Decoupling FIFO
    // -------------------------------------------------------------------------
    reg [31:0] fifo_mem [0:63];
    reg [5:0]  fifo_wr_ptr;
    reg [5:0]  fifo_rd_ptr;
    reg [6:0]  fifo_count;

    wire fifo_push = s_axis_audio_tvalid && s_axis_audio_tready;
    wire fifo_pop4 = (state == IDLE) && audio_start && (fifo_count >= 7'd4);

    assign s_axis_audio_tready = audio_start && (fifo_count <= 7'd58);

    reg state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= IDLE;
            reg_write_ptr       <= 32'd0;
            reg_period_accum    <= 32'd0;
            fifo_wr_ptr         <= 6'd0;
            fifo_rd_ptr         <= 6'd0;
            fifo_count          <= 7'd0;
            c2h_req_valid       <= 1'b0;
            c2h_req_addr        <= 64'd0;
            c2h_req_dw_len      <= 11'd0;
            c2h_req_data        <= {PCIE_DATA_WIDTH{1'b0}};
            c2h_req_last        <= 1'b0;
            audio_busy          <= 1'b0;
            audio_block_done    <= 1'b0;
            audio_pts           <= 64'd0;
        end else begin
            if (!audio_start) begin
                state            <= IDLE;
                reg_write_ptr    <= 32'd0;
                reg_period_accum <= 32'd0;
                fifo_wr_ptr      <= 6'd0;
                fifo_rd_ptr      <= 6'd0;
                fifo_count       <= 7'd0;
                c2h_req_valid    <= 1'b0;
                audio_busy       <= 1'b0;
                audio_block_done <= 1'b0;
            end else begin
                // FIFO Push
                if (fifo_push) begin
                    fifo_mem[fifo_wr_ptr] <= s_axis_audio_tdata;
                    fifo_wr_ptr <= fifo_wr_ptr + 1'b1;

                    // Latch Audio PTS on AES3 Block Start Preamble (4'hB)
                    if (s_axis_audio_tdata[3:0] == 4'hB) begin
                        audio_pts <= global_timestamp;
                    end
                end

                // FIFO Pop and Count update
                case ({fifo_push, fifo_pop4})
                    2'b10: fifo_count <= fifo_count + 7'd1;
                    2'b01: fifo_count <= fifo_count - 7'd4;
                    2'b11: fifo_count <= fifo_count - 7'd3;
                    default: ;
                endcase

                case (state)
                    IDLE: begin
                        audio_block_done <= 1'b0;

                        if (fifo_count >= 7'd4) begin
                            // Read 4 subframes (128 bits = 16 bytes = 1 beat)
                            c2h_req_data   <= {fifo_mem[(fifo_rd_ptr + 3) & 6'd63],
                                               fifo_mem[(fifo_rd_ptr + 2) & 6'd63],
                                               fifo_mem[(fifo_rd_ptr + 1) & 6'd63],
                                               fifo_mem[fifo_rd_ptr]};
                            fifo_rd_ptr    <= fifo_rd_ptr + 6'd4;
                            c2h_req_addr   <= host_buffer_addr + {32'd0, reg_write_ptr};
                            c2h_req_dw_len <= 11'd4; // 4 DWs = 16 bytes
                            c2h_req_last   <= 1'b1;
                            c2h_req_valid  <= 1'b1;
                            audio_busy     <= 1'b1;
                            state          <= C2H_SEND;
                        end
                    end

                    C2H_SEND: begin
                        if (c2h_req_ack) begin
                            c2h_req_valid <= 1'b0;

                            // Wrap circular ALSA buffer write pointer
                            if (reg_write_ptr + 32'd16 >= actual_buf_size)
                                reg_write_ptr <= 32'd0;
                            else
                                reg_write_ptr <= reg_write_ptr + 32'd16;

                            // Check period elapsed boundary
                            if (reg_period_accum + 32'd16 >= actual_period_size) begin
                                reg_period_accum <= 32'd0;
                                audio_block_done <= 1'b1; // Pulse period IRQ
                            end else begin
                                reg_period_accum <= reg_period_accum + 32'd16;
                                audio_block_done <= 1'b0;
                            end

                            state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end

endmodule
