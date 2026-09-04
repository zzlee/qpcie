// ============================================================================
// Module: audio_stream_engine
// Description: Multi-Channel Audio Stream Engine with Circular Host DMA & Hardware PTS.
//              Captures 32-bit AES3/IEC 60958 audio subframes:
//              - Packs 4 subframes (128 bits) into PCIe C2H DMA beats
//              - Internal BRAM FIFO (xpm_fifo_sync 128x128) absorbs PCIe bus latency
//                without consuming Slice LUTs or Flip-Flops
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
    input  wire                          aes3_sync_disable, // If 1, accept any 32-bit PCM without preamble sync check
    input  wire [63:0]                   host_buffer_addr,
    input  wire [31:0]                   buffer_size_bytes, // Total ALSA ring size (e.g. 64KB = 65536)
    input  wire [31:0]                   period_size_bytes, // Period size (e.g. 4KB = 4096)
    output wire [31:0]                   cur_write_ptr,     // Current byte offset in ALSA buffer
    input  wire [63:0]                   global_timestamp,  // Hardware AV Sync Master Timestamp (ns)

    // C2H Input AES3 Audio Stream (From audio_pattern_gen or loopback)
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
    // 4-Subframe Packing Logic (32-bit -> 128-bit)
    // -------------------------------------------------------------------------
    reg [1:0]   pack_cnt;
    reg [95:0]  pack_buf;
    reg         stream_synced;

    wire is_left_subframe  = (s_axis_audio_tdata[3:0] == 4'hB) || (s_axis_audio_tdata[3:0] == 4'h9);
    wire is_right_subframe = (s_axis_audio_tdata[3:0] == 4'hC);

    wire can_push = aes3_sync_disable ? 1'b1 :
                    (stream_synced ? (pack_cnt[0] ? is_right_subframe : is_left_subframe)
                                   : (s_axis_audio_tdata[3:0] == 4'hB));

    wire fifo_full;
    wire fifo_empty;
    wire [127:0] fifo_dout;
    reg          fifo_wr_en;
    reg  [127:0] fifo_din;
    reg          fifo_rd_en;

    assign s_axis_audio_tready = audio_start && !fifo_full;

    wire sample_fire = s_axis_audio_tvalid && s_axis_audio_tready && can_push;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pack_cnt       <= 2'd0;
            pack_buf       <= 96'd0;
            stream_synced  <= 1'b0;
            fifo_wr_en     <= 1'b0;
            fifo_din       <= 128'd0;
            audio_pts      <= 64'd0;
        end else if (!audio_start) begin
            pack_cnt       <= 2'd0;
            pack_buf       <= 96'd0;
            stream_synced  <= 1'b0;
            fifo_wr_en     <= 1'b0;
            fifo_din       <= 128'd0;
        end else begin
            fifo_wr_en <= 1'b0; // Default pulse

            if (sample_fire) begin
                // Latch PTS on AES3 Block Start (Preamble 4'hB)
                if (s_axis_audio_tdata[3:0] == 4'hB) begin
                    audio_pts <= global_timestamp;
                end

                if (!stream_synced && !aes3_sync_disable) begin
                    // First lock to Left Channel / Block Start
                    stream_synced  <= 1'b1;
                    pack_buf[31:0] <= s_axis_audio_tdata;
                    pack_cnt       <= 2'd1;
                end else begin
                    case (pack_cnt)
                        2'd0: begin
                            pack_buf[31:0]  <= s_axis_audio_tdata;
                            pack_cnt        <= 2'd1;
                        end
                        2'd1: begin
                            pack_buf[63:32] <= s_axis_audio_tdata;
                            pack_cnt        <= 2'd2;
                        end
                        2'd2: begin
                            pack_buf[95:64] <= s_axis_audio_tdata;
                            pack_cnt        <= 2'd3;
                        end
                        2'd3: begin
                            fifo_din   <= {s_axis_audio_tdata, pack_buf};
                            fifo_wr_en <= 1'b1;
                            pack_cnt   <= 2'd0;
                        end
                    endcase
                end
            end else if (s_axis_audio_tvalid && s_axis_audio_tready && !can_push && !aes3_sync_disable) begin
                // Sync loss on framing violation: reset packing and re-acquire Preamble 4'hB
                stream_synced <= 1'b0;
                pack_cnt      <= 2'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 128-entry 128-bit Block RAM Decoupling FIFO (RAMB18)
    // -------------------------------------------------------------------------
    wire fifo_rst = (!rst_n) || (!audio_start);

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_WRITE_DEPTH    (128),
        .WRITE_DATA_WIDTH    (128),
        .READ_DATA_WIDTH     (128),
        .READ_MODE           ("fwft"),
        .FIFO_READ_LATENCY   (0),
        .WR_DATA_COUNT_WIDTH (8),
        .RD_DATA_COUNT_WIDTH (8),
        .USE_ADV_FEATURES    ("0707")
    ) u_decouple_fifo (
        .sleep         (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (clk),
        .wr_en         (fifo_wr_en && !fifo_full),
        .din           (fifo_din),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (),
        .almost_full   (),
        .wr_ack        (),

        .rd_en         (fifo_rd_en && !fifo_empty),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .rd_rst_busy   (),
        .almost_empty  (),
        .data_valid    (),

        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .sbiterr       (),
        .dbiterr       ()
    );

    // -------------------------------------------------------------------------
    // C2H PCIe DMA Stream FSM
    // -------------------------------------------------------------------------
    reg state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            reg_write_ptr    <= 32'd0;
            reg_period_accum <= 32'd0;
            c2h_req_valid    <= 1'b0;
            c2h_req_addr     <= 64'd0;
            c2h_req_dw_len   <= 11'd0;
            c2h_req_data     <= {PCIE_DATA_WIDTH{1'b0}};
            c2h_req_last     <= 1'b0;
            audio_busy       <= 1'b0;
            audio_block_done <= 1'b0;
            fifo_rd_en       <= 1'b0;
        end else if (!audio_start) begin
            state            <= IDLE;
            reg_write_ptr    <= 32'd0;
            reg_period_accum <= 32'd0;
            c2h_req_valid    <= 1'b0;
            audio_busy       <= 1'b0;
            audio_block_done <= 1'b0;
            fifo_rd_en       <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    audio_block_done <= 1'b0;

                    if (!fifo_empty) begin
                        c2h_req_data   <= fifo_dout;
                        fifo_rd_en     <= 1'b1; // Pop 128-bit beat
                        c2h_req_addr   <= host_buffer_addr + {32'd0, reg_write_ptr};
                        c2h_req_dw_len <= 11'd4; // 4 DWs = 16 bytes
                        c2h_req_last   <= 1'b1;
                        c2h_req_valid  <= 1'b1;
                        audio_busy     <= 1'b1;
                        state          <= C2H_SEND;
                    end else begin
                        fifo_rd_en <= 1'b0;
                    end
                end

                C2H_SEND: begin
                    fifo_rd_en <= 1'b0;

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

endmodule
