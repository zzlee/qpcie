// ============================================================================
// Module: audio_stream_engine
// Description: Multi-Channel Audio Stream Engine (AXI4-Stream AES3 Subframe Interface).
//              Formats and streams 32-bit AES3/IEC 60958 audio subframes:
//              - s_axis_audio_* (C2H: Audio Input AES3 -> Low Latency PCIe Host MWr)
//              - m_axis_audio_* (H2C: PCIe Host MRd -> Audio Output AES3 Subframes)
//              Handles low-latency audio block buffering & high-priority DMA scheduling.
// ============================================================================

`timescale 1ns / 1ps

module audio_stream_engine #(
    parameter AUDIO_DATA_WIDTH = 32,
    parameter PCIE_DATA_WIDTH  = 256
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // Audio Engine Control
    input  wire                          audio_start,
    input  wire [63:0]                   host_buffer_addr,
    input  wire [15:0]                   sample_block_size, // Number of AES3 subframes per block
    input  wire                          is_c2h,

    // C2H Input AES3 Audio Stream (External AES3 Audio Src -> PCIe Engine)
    input  wire [AUDIO_DATA_WIDTH-1:0]   s_axis_audio_tdata, // 32-bit AES3 subframe
    input  wire                          s_axis_audio_tvalid,
    input  wire                          s_axis_audio_tlast, // End of audio block
    output reg                           s_axis_audio_tready,

    // H2C Output AES3 Audio Stream (PCIe Engine -> External AES3 Audio Sink)
    output reg  [AUDIO_DATA_WIDTH-1:0]   m_axis_audio_tdata,
    output reg                           m_axis_audio_tvalid,
    output reg                           m_axis_audio_tlast,
    input  wire                          m_axis_audio_tready,

    // Interface to RQ Encoder (C2H Low-Latency Audio MWr Request)
    output reg                           c2h_req_valid,
    output reg  [63:0]                   c2h_req_addr,
    output reg  [10:0]                   c2h_req_dw_len,
    output reg  [PCIE_DATA_WIDTH-1:0]    c2h_req_data,
    output reg                           c2h_req_last,
    input  wire                          c2h_req_ack,

    // Interface to RC Decoder / H2C FIFO (H2C Audio CplD Input)
    input  wire                          h2c_fifo_wvalid,
    input  wire [PCIE_DATA_WIDTH-1:0]    h2c_fifo_wdata,
    input  wire                          h2c_fifo_wlast,

    // Status Signals
    output reg                           audio_busy,
    output reg                           audio_block_done
);

    localparam IDLE       = 2'b00;
    localparam C2H_STREAM = 2'b01;
    localparam C2H_SEND   = 2'b10;
    localparam H2C_STREAM = 2'b11;

    reg [1:0]  state;
    reg [15:0] sample_count;
    reg [PCIE_DATA_WIDTH-1:0] audio_buffer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= IDLE;
            s_axis_audio_tready <= 1'b0;
            m_axis_audio_tdata  <= 32'd0;
            m_axis_audio_tvalid <= 1'b0;
            m_axis_audio_tlast  <= 1'b0;
            c2h_req_valid       <= 1'b0;
            c2h_req_addr        <= 64'd0;
            c2h_req_dw_len      <= 11'd0;
            c2h_req_data        <= {PCIE_DATA_WIDTH{1'b0}};
            c2h_req_last        <= 1'b0;
            audio_busy          <= 1'b0;
            audio_block_done    <= 1'b0;
            sample_count        <= 16'd0;
            audio_buffer        <= {PCIE_DATA_WIDTH{1'b0}};
        end else begin
            case (state)
                IDLE: begin
                    audio_block_done    <= 1'b0;
                    s_axis_audio_tready <= 1'b0;
                    m_axis_audio_tvalid <= 1'b0;

                    if (audio_start) begin
                        audio_busy   <= 1'b1;
                        sample_count <= 16'd0;
                        if (is_c2h) begin
                            s_axis_audio_tready <= 1'b1;
                            state               <= C2H_STREAM;
                        end else begin
                            state               <= H2C_STREAM;
                        end
                    end
                end

                // C2H: Collect 32-bit AES3 subframes and send low-latency PCIe MWr
                C2H_STREAM: begin
                    if (s_axis_audio_tvalid && s_axis_audio_tready) begin
                        audio_buffer <= {s_axis_audio_tdata, audio_buffer[PCIE_DATA_WIDTH-1:AUDIO_DATA_WIDTH]};
                        if (s_axis_audio_tlast || (sample_count + 1'b1 == sample_block_size)) begin
                            s_axis_audio_tready <= 1'b0;
                            c2h_req_addr   <= host_buffer_addr;
                            c2h_req_dw_len <= 11'd8; // 8 DWs = 32 Bytes
                            c2h_req_data   <= {s_axis_audio_tdata, audio_buffer[PCIE_DATA_WIDTH-1:AUDIO_DATA_WIDTH]};
                            c2h_req_last   <= 1'b1;
                            c2h_req_valid  <= 1'b1;
                            state          <= C2H_SEND;
                        end else begin
                            sample_count <= sample_count + 1'b1;
                        end
                    end
                end

                C2H_SEND: begin
                    if (c2h_req_ack) begin
                        c2h_req_valid    <= 1'b0;
                        audio_busy       <= 1'b0;
                        audio_block_done <= 1'b1;
                        state            <= IDLE;
                    end
                end

                // H2C: Stream AES3 subframes to external AXI4-Stream Audio interface
                H2C_STREAM: begin
                    if (h2c_fifo_wvalid) begin
                        m_axis_audio_tdata  <= h2c_fifo_wdata[AUDIO_DATA_WIDTH-1:0];
                        m_axis_audio_tvalid <= 1'b1;
                        m_axis_audio_tlast  <= h2c_fifo_wlast;
                        if (m_axis_audio_tready) begin
                            audio_busy       <= 1'b0;
                            audio_block_done <= 1'b1;
                            state            <= IDLE;
                        end
                    end else begin
                        m_axis_audio_tvalid <= 1'b0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
