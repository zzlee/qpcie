`timescale 1ns / 1ps

module tb_nv12_capture_4k_performance;
    localparam [15:0] WIDTH = 16'd3840;
    localparam [15:0] HEIGHT = 16'd2160;
    localparam integer EXPECTED_REQS = (3840/256)*2160 +
                                       (3840/256)*(2160/2);
    localparam integer FRAME_BUDGET_CLKS = 2083333;

    reg clk = 0;
    reg rst_n = 0;
    always #4 clk = ~clk;

    reg desc_valid;
    wire desc_ready;
    reg stream_enable;
    reg [15:0] line_idx;
    reg [15:0] beat_idx;
    wire s_ready;
    wire s_valid = stream_enable && (line_idx < HEIGHT);
    wire s_last = (beat_idx == 16'd959);
    wire s_user = (line_idx == 0 && beat_idx == 0);
    wire [127:0] s_data = {4{32'h0080_8010}};

    wire req_valid, req_data_ready, req_ack, req_last;
    wire [63:0] req_addr;
    wire [10:0] req_len;
    wire [127:0] req_data;
    wire busy, done;
    wire [31:0] errors;

    wire [127:0] rq_data;
    wire rq_valid, rq_last;
    wire [61:0] rq_user;
    wire [15:0] rq_keep;
    reg rq_ready;
    reg [7:0] ready_lfsr;
    integer frame_clks, request_count, input_stalls;

    nv12_capture_engine #(
        .MAX_WIDTH(3840), .PCIE_DATA_WIDTH(128),
        .FIFO_DEPTH(128), .MWR_PAYLOAD_BYTES(256)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .desc_valid(desc_valid), .desc_ready(desc_ready),
        .plane_y_addr(64'h1000_0000), .plane_uv_addr(64'h1080_0000),
        .frame_width(WIDTH), .frame_height(HEIGHT), .frame_stride(WIDTH),
        .pacer_enable(1'b0), .frame_interval_clks(32'd0),
        .global_timestamp(64'd0),
        .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
        .s_axis_tlast(s_last), .s_axis_tuser(s_user), .s_axis_tready(s_ready),
        .c2h_req_valid(req_valid), .c2h_req_addr(req_addr),
        .c2h_req_dw_len(req_len), .c2h_req_data(req_data),
        .c2h_req_last(req_last), .c2h_req_data_ready(req_data_ready),
        .c2h_req_ack(req_ack),
        .video_busy(busy), .video_frame_done(done), .frame_pts(),
        .protocol_error_count(errors)
    );

    rq_tx_encoder #(.DATA_WIDTH(128)) encoder (
        .clk(clk), .rst_n(rst_n),
        .m_axis_rq_tdata(rq_data), .m_axis_rq_tvalid(rq_valid),
        .m_axis_rq_tlast(rq_last), .m_axis_rq_tuser(rq_user),
        .m_axis_rq_tkeep(rq_keep), .m_axis_rq_tready(rq_ready),
        .irq_req_valid(1'b0), .irq_req_code(8'd0), .irq_req_ack(),
        .desc_req_valid(1'b0), .desc_req_addr(64'd0),
        .desc_req_dw_len(11'd0), .desc_req_tag(8'd0), .desc_req_ack(),
        .h2c_req_valid(1'b0), .h2c_req_addr(64'd0),
        .h2c_req_dw_len(11'd0), .h2c_req_tag(8'd0), .h2c_req_ack(),
        .c2h_req_valid(req_valid), .c2h_req_addr(req_addr),
        .c2h_req_dw_len(req_len), .c2h_req_data(req_data),
        .c2h_req_last(req_last), .c2h_req_data_ready(req_data_ready),
        .c2h_req_ack(req_ack)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            rq_ready <= 1'b0;
            ready_lfsr <= 8'hA7;
        end else begin
            ready_lfsr <= {ready_lfsr[6:0],
                           ready_lfsr[7] ^ ready_lfsr[5] ^
                           ready_lfsr[4] ^ ready_lfsr[3]};
            rq_ready <= ready_lfsr[0] | ready_lfsr[1];
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            line_idx <= 0;
            beat_idx <= 0;
            frame_clks <= 0;
            request_count <= 0;
            input_stalls <= 0;
        end else begin
            if (busy)
                frame_clks <= frame_clks + 1;
            if (req_ack)
                request_count <= request_count + 1;
            if (s_valid && !s_ready)
                input_stalls <= input_stalls + 1;
            if (s_valid && s_ready) begin
                if (beat_idx == 16'd959) begin
                    beat_idx <= 0;
                    line_idx <= line_idx + 1'b1;
                end else begin
                    beat_idx <= beat_idx + 1'b1;
                end
            end
        end
    end

    initial begin
        desc_valid = 0;
        stream_enable = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        desc_valid = 1;
        wait(desc_ready);
        @(negedge clk);
        desc_valid = 0;
        stream_enable = 1;
        wait(done);
        @(posedge clk);
        stream_enable = 0;

        if (request_count != EXPECTED_REQS)
            $fatal(1, "Request count %0d expected %0d",
                   request_count, EXPECTED_REQS);
        if (errors != 0)
            $fatal(1, "Protocol errors %0d", errors);
        if (input_stalls != 0)
            $fatal(1, "Video frontend stalled for %0d clocks", input_stalls);
        if (frame_clks > FRAME_BUDGET_CLKS)
            $fatal(1, "4K frame took %0d clocks, budget %0d",
                   frame_clks, FRAME_BUDGET_CLKS);
        $display("SUCCESS: 4K NV12 frame completed in %0d clocks (%0.3f ms), requests=%0d, input_stalls=%0d",
                 frame_clks, frame_clks * 0.000008,
                 request_count, input_stalls);
        $finish;
    end

    initial begin
        repeat (2200000) @(posedge clk);
        $fatal(1, "4K performance simulation timeout");
    end
endmodule
