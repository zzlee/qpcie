`timescale 1ns / 1ps

module tb_nv12_raw_loopback;
    localparam [15:0] WIDTH = 256;
    localparam [15:0] HEIGHT = 4;
    localparam Y_BYTES = WIDTH * HEIGHT;
    localparam UV_BYTES = WIDTH * HEIGHT / 2;
    localparam TOTAL_BYTES = Y_BYTES + UV_BYTES;
    localparam Y_BASE = 64'h0000_0000_0000_1000;
    localparam UV_BASE = 64'h0000_0000_0000_2000;

    reg clk = 0;
    reg rst_n = 0;
    always #4 clk = ~clk;

    reg desc_valid;
    wire desc_ready;
    reg [127:0] s_data;
    reg s_valid, s_last, s_user;
    wire s_ready;
    wire req_valid;
    wire [63:0] req_addr;
    wire [10:0] req_len;
    wire [127:0] req_data;
    reg req_data_ready, req_ack;
    wire busy, done;
    wire [31:0] errors;

    reg [7:0] y_mem [0:Y_BYTES-1];
    reg [7:0] uv_mem [0:UV_BYTES-1];
    integer byte_idx, stream_off, payload_beat, request_count, mem_off;

    nv12_capture_engine #(
        .MAX_WIDTH(WIDTH),
        .PCIE_DATA_WIDTH(128),
        .MWR_PAYLOAD_BYTES(256),
        .RAW_INPUT(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .desc_valid(desc_valid), .desc_ready(desc_ready),
        .desc_sg_mode(1'b0),
        .plane_y_addr(Y_BASE), .plane_uv_addr(UV_BASE),
        .frame_width(WIDTH), .frame_height(HEIGHT), .frame_stride(WIDTH),
        .sgl_y_wr_en(1'b0), .sgl_y_wr_addr(64'd0),
        .sgl_y_wr_len(32'd0), .sgl_y_wr_flags(32'd0),
        .sgl_uv_wr_en(1'b0), .sgl_uv_wr_addr(64'd0),
        .sgl_uv_wr_len(32'd0), .sgl_uv_wr_flags(32'd0),
        .cur_y_sgl_count(), .cur_uv_sgl_count(),
        .sgl_y_pop_ready(), .sgl_uv_pop_ready(),
        .pacer_enable(1'b0), .frame_interval_clks(32'd0),
        .global_timestamp(64'h0123_4567_89AB_CDEF),
        .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
        .s_axis_tlast(s_last), .s_axis_tuser(s_user),
        .s_axis_tready(s_ready),
        .c2h_req_valid(req_valid), .c2h_req_addr(req_addr),
        .c2h_req_dw_len(req_len), .c2h_req_data(req_data),
        .c2h_req_last(), .c2h_req_data_ready(req_data_ready),
        .c2h_req_ack(req_ack),
        .video_busy(busy), .video_frame_done(done), .frame_pts(),
        .protocol_error_count(errors)
    );

    always @(negedge clk) begin
        req_data_ready <= rst_n && req_valid && payload_beat < 16;
        req_ack <= rst_n && req_valid && payload_beat == 16;
    end

    always @(posedge clk) begin
        if (rst_n && req_valid && req_data_ready) begin
            if (req_len !== 11'd64)
                $fatal(1, "Unexpected request length %0d", req_len);
            if (req_addr >= Y_BASE && req_addr < Y_BASE + Y_BYTES) begin
                mem_off = req_addr - Y_BASE + payload_beat * 16;
                for (byte_idx = 0; byte_idx < 16; byte_idx = byte_idx + 1)
                    y_mem[mem_off + byte_idx] = req_data[byte_idx*8 +: 8];
            end else if (req_addr >= UV_BASE && req_addr < UV_BASE + UV_BYTES) begin
                mem_off = req_addr - UV_BASE + payload_beat * 16;
                for (byte_idx = 0; byte_idx < 16; byte_idx = byte_idx + 1)
                    uv_mem[mem_off + byte_idx] = req_data[byte_idx*8 +: 8];
            end else begin
                $fatal(1, "MWr outside raw NV12 planes: %h", req_addr);
            end
            payload_beat = payload_beat + 1;
        end
        if (rst_n && req_valid && req_ack) begin
            if (payload_beat != 16)
                $fatal(1, "Request acknowledged after %0d beats", payload_beat);
            payload_beat = 0;
            request_count = request_count + 1;
        end
    end

    task send_raw_beat;
        input integer offset;
        begin
            while (!s_ready) @(posedge clk);
            @(negedge clk);
            for (byte_idx = 0; byte_idx < 16; byte_idx = byte_idx + 1)
                s_data[byte_idx*8 +: 8] = (offset + byte_idx) & 8'hff;
            s_valid = 1;
            s_user = (offset == 0);
            s_last = (offset + 16 == TOTAL_BYTES);
            @(posedge clk);
            @(negedge clk);
            s_valid = 0;
            s_user = 0;
            s_last = 0;
        end
    endtask

    initial begin
        desc_valid = 0;
        s_data = 0;
        s_valid = 0;
        s_last = 0;
        s_user = 0;
        req_data_ready = 0;
        req_ack = 0;
        payload_beat = 0;
        request_count = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        desc_valid = 1;
        wait(desc_ready);
        @(negedge clk);
        desc_valid = 0;

        for (stream_off = 0; stream_off < TOTAL_BYTES; stream_off = stream_off + 16)
            send_raw_beat(stream_off);

        wait(done);
        @(posedge clk);
        if (request_count != 6)
            $fatal(1, "Expected 6 MWr requests, got %0d", request_count);
        if (errors != 0)
            $fatal(1, "Protocol error count is %0d", errors);
        for (byte_idx = 0; byte_idx < Y_BYTES; byte_idx = byte_idx + 1)
            if (y_mem[byte_idx] !== (byte_idx & 8'hff))
                $fatal(1, "Y mismatch at %0d", byte_idx);
        for (byte_idx = 0; byte_idx < UV_BYTES; byte_idx = byte_idx + 1)
            if (uv_mem[byte_idx] !== ((Y_BYTES + byte_idx) & 8'hff))
                $fatal(1, "UV mismatch at %0d", byte_idx);

        $display("SUCCESS: raw NV12M H2C stream preserved bit-exact across C2H planes");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Timeout");
    end
endmodule
