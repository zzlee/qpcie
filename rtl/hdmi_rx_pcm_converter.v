// PG236 audio AXIS -> stereo S32_LE. Both interfaces use PCIe user_clk.
// PG236 preambles are 1 (block start), 2 (left), 3 (right), NOT B/9/C.
// TID is the channel number. Invalid samples become silence, not parity noise.
// HDMI is never backpressured: idle samples are drained; a full FIFO drops a
// whole stereo pair and raises overflow. No new block RAM is required.
`timescale 1ns/1ps
module hdmi_rx_pcm_converter #(
    parameter CLOCK_HZ = 125000000,
    parameter FIFO_DEPTH = 64
)(
    input wire clk, input wire rst_n, input wire capture_enable,
    input wire diagnostic_raw, // RXA1 trace: {A5,TID,cycle16}, original IEC word
    input wire [31:0] s_axis_audio_tdata,
    input wire [7:0] s_axis_audio_tid,
    input wire s_axis_audio_tvalid,
    output wire s_axis_audio_tready,
    output wire [31:0] m_axis_pcm_tdata,
    output wire m_axis_pcm_tvalid,
    input wire m_axis_pcm_tready,
    output reg overflow,
    output reg [31:0] frame_count, output reg [31:0] measured_rate,
    output reg [31:0] error_count, output reg [31:0] channel_mask,
    output reg [31:0] channel_status
);
    wire left = s_axis_audio_tid == 0 &&
                (s_axis_audio_tdata[3:0] == 1 || s_axis_audio_tdata[3:0] == 2);
    wire right = s_axis_audio_tid == 1 && s_axis_audio_tdata[3:0] == 3;
    wire [31:0] pcm = s_axis_audio_tdata[28] ? 32'd0 :
                     {s_axis_audio_tdata[27:4], 8'd0};
    reg [31:0] left_pcm;
    reg have_left, stream_started;
    reg [15:0] trace_cycle;
    always @(posedge clk) begin
        if (!rst_n) trace_cycle <= 0;
        else trace_cycle <= trace_cycle + 1;
    end
    wire pair_valid = s_axis_audio_tvalid && (diagnostic_raw || (right && have_left));
    wire fifo_full, fifo_empty, wr_busy, rd_busy;
    wire [63:0] pair_data;
    reg output_right;
    assign s_axis_audio_tready = 1'b1;
    assign m_axis_pcm_tvalid = capture_enable && !fifo_empty && !rd_busy;
    assign m_axis_pcm_tdata = output_right ? pair_data[63:32] : pair_data[31:0];
    wire output_fire = m_axis_pcm_tvalid && m_axis_pcm_tready;
    wire active = capture_enable && !wr_busy && !rd_busy;
    wire pair_drop = active && pair_valid && fifo_full;
    wire framing_error = active && !diagnostic_raw && s_axis_audio_tvalid &&
                         ((left && have_left) || (right && !have_left && stream_started));
    always @(posedge clk) begin
        if (!rst_n || !active) begin
            have_left <= 0;
            stream_started <= 0;
            left_pcm <= 0;
            output_right <= 0;
        end else begin
            if (output_fire) output_right <= !output_right;
            if (!diagnostic_raw && s_axis_audio_tvalid && left) begin
                have_left <= 1;
                stream_started <= 1;
                left_pcm <= pcm;
            end else if (s_axis_audio_tvalid && right) have_left <= 0;
        end
    end
    // Store complete pairs; pop only after both L and R have been consumed.
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(FIFO_DEPTH),
        .WRITE_DATA_WIDTH(64), .READ_DATA_WIDTH(64), .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000")
    ) u_pcm_fifo (
        .sleep(1'b0), .rst(!rst_n || !capture_enable), .wr_clk(clk),
        .wr_en(active && pair_valid && !fifo_full),
        .din(diagnostic_raw ? {8'hA5,s_axis_audio_tid,trace_cycle,s_axis_audio_tdata} :
                             {pcm,left_pcm}), .full(fifo_full), .wr_rst_busy(wr_busy),
        .rd_en(output_fire && output_right), .dout(pair_data),
        .empty(fifo_empty), .rd_rst_busy(rd_busy),
        .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .prog_full(), .wr_data_count(), .overflow(), .almost_full(), .wr_ack(),
        .prog_empty(), .rd_data_count(), .underflow(), .almost_empty(),
        .data_valid(), .dbiterr(), .sbiterr()
    );
    reg [31:0] timer, rate_count;
    reg [7:0] cs_index;
    reg cs_started;
    reg [31:0] cs_work;
    always @(posedge clk) begin
        if (!rst_n) begin
            frame_count <= 0; measured_rate <= 0; timer <= 0; rate_count <= 0;
            error_count <= 0; channel_mask <= 0; overflow <= 0;
            cs_index <= 0; cs_started <= 0; cs_work <= 0; channel_status <= 0;
        end else begin
            overflow <= pair_drop;
            if (pair_drop || framing_error) error_count <= error_count + 1;
            if (s_axis_audio_tvalid && s_axis_audio_tid < 32)
                channel_mask <= channel_mask | (32'b1 << s_axis_audio_tid);
            if (timer == CLOCK_HZ-1) begin
                timer <= 0;
                measured_rate <= rate_count + (s_axis_audio_tvalid && left);
                rate_count <= 0;
            end else begin
                timer <= timer + 1;
                if (s_axis_audio_tvalid && left) rate_count <= rate_count + 1;
            end
            if (s_axis_audio_tvalid && left) begin
                frame_count <= frame_count + 1;
                if (s_axis_audio_tdata[3:0] == 1) begin
                    cs_index <= 1; cs_started <= 1;
                    cs_work <= {31'd0,s_axis_audio_tdata[30]};
                end else if (cs_started) begin
                    if (cs_index < 32) cs_work[cs_index[4:0]] <= s_axis_audio_tdata[30];
                    if (cs_index == 32) channel_status <= cs_work;
                    if (cs_index != 255) cs_index <= cs_index + 1;
                end
            end
        end
    end
endmodule
