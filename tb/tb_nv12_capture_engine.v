`timescale 1ns / 1ps

module tb_nv12_capture_engine;
    localparam WIDTH = 16;
    localparam HEIGHT = 4;
    localparam STRIDE = 16;
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
    wire req_last;
    reg req_ack;
    wire busy, done;
    wire [63:0] pts;
    wire [31:0] errors;

    reg [7:0] y_mem [0:(WIDTH*HEIGHT)-1];
    reg [7:0] uv_mem [0:(WIDTH*HEIGHT/2)-1];
    integer i, row, beat, byte_idx, req_count;
    integer stall_count;
    integer off;
    reg [7:0] expected;

    nv12_capture_engine #(
        .MAX_WIDTH(WIDTH),
        .PCIE_DATA_WIDTH(128)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .desc_valid(desc_valid), .desc_ready(desc_ready),
        .plane_y_addr(Y_BASE), .plane_uv_addr(UV_BASE),
        .frame_width(WIDTH), .frame_height(HEIGHT), .frame_stride(STRIDE),
        .pacer_enable(1'b0), .frame_interval_clks(32'd0),
        .global_timestamp(64'h1122_3344_5566_7788),
        .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
        .s_axis_tlast(s_last), .s_axis_tuser(s_user),
        .s_axis_tready(s_ready),
        .c2h_req_valid(req_valid), .c2h_req_addr(req_addr),
        .c2h_req_dw_len(req_len), .c2h_req_data(req_data),
        .c2h_req_last(req_last), .c2h_req_ack(req_ack),
        .video_busy(busy), .video_frame_done(done), .frame_pts(pts),
        .protocol_error_count(errors)
    );

    function [7:0] y_value;
        input integer r;
        input integer x;
        begin y_value = r * 32 + x; end
    endfunction

    function [7:0] u_value;
        input integer r;
        input integer x;
        begin u_value = 40 + r * 4 + x; end
    endfunction

    function [7:0] v_value;
        input integer r;
        input integer x;
        begin v_value = 100 + r * 4 + x; end
    endfunction

    function [31:0] pixel4;
        input integer r;
        input integer x;
        begin pixel4 = {8'h00, v_value(r, x), u_value(r, x), y_value(r, x)}; end
    endfunction

    task send_beat;
        input integer r;
        input integer b;
        begin
            while (!s_ready) @(posedge clk);
            @(negedge clk);
            s_data  = {pixel4(r, b*4+3), pixel4(r, b*4+2),
                       pixel4(r, b*4+1), pixel4(r, b*4+0)};
            s_user  = (r == 0 && b == 0);
            s_last  = (b == (WIDTH/4)-1);
            s_valid = 1'b1;
            @(posedge clk);
            while (!s_ready) @(posedge clk);
            @(negedge clk);
            s_valid = 1'b0;
            s_user  = 1'b0;
            s_last  = 1'b0;
        end
    endtask

    // Deterministic 0..2-cycle PCIe backpressure, sampled on the falling edge
    // so ACK is stable before the engine's active edge.
    always @(negedge clk) begin
        if (!rst_n) begin
            req_ack <= 1'b0;
            stall_count <= 0;
        end else if (req_valid) begin
            if (stall_count == 0) begin
                req_ack <= 1'b1;
                stall_count <= req_count % 3;
            end else begin
                req_ack <= 1'b0;
                stall_count <= stall_count - 1;
            end
        end else begin
            req_ack <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst_n && req_valid && req_ack) begin
            if (req_len !== 11'd4 || !req_last || req_addr[3:0] != 0)
                $fatal(1, "Malformed MWr request addr=%h len=%0d last=%b",
                       req_addr, req_len, req_last);
            if (req_addr >= Y_BASE && req_addr < Y_BASE + WIDTH*HEIGHT) begin
                off = req_addr - Y_BASE;
                for (byte_idx = 0; byte_idx < 16; byte_idx = byte_idx + 1)
                    y_mem[off + byte_idx] = req_data[(byte_idx*8) +: 8];
            end else if (req_addr >= UV_BASE && req_addr < UV_BASE + WIDTH*HEIGHT/2) begin
                off = req_addr - UV_BASE;
                for (byte_idx = 0; byte_idx < 16; byte_idx = byte_idx + 1)
                    uv_mem[off + byte_idx] = req_data[(byte_idx*8) +: 8];
            end else begin
                $fatal(1, "MWr outside NV12 planes: %h", req_addr);
            end
            req_count = req_count + 1;
        end
    end

    initial begin
        desc_valid = 0;
        s_data = 0; s_valid = 0; s_last = 0; s_user = 0;
        req_ack = 0; req_count = 0; stall_count = 0;
        for (i = 0; i < WIDTH*HEIGHT; i = i + 1) y_mem[i] = 8'hEE;
        for (i = 0; i < WIDTH*HEIGHT/2; i = i + 1) uv_mem[i] = 8'hEE;

        repeat (5) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        desc_valid = 1;
        wait(desc_ready);
        @(negedge clk);
        desc_valid = 0;

        // Pre-SOF garbage must be drained and never reach host memory.
        while (!s_ready) @(posedge clk);
        @(negedge clk);
        s_data = {4{32'h00FF_FFEE}};
        s_valid = 1;
        @(posedge clk);
        @(negedge clk);
        s_valid = 0;

        for (row = 0; row < HEIGHT; row = row + 1)
            for (beat = 0; beat < WIDTH/4; beat = beat + 1)
                send_beat(row, beat);

        wait(done);
        @(posedge clk);

        if (req_count != 6)
            $fatal(1, "Expected 6 MWr requests, got %0d", req_count);
        if (errors != 0)
            $fatal(1, "Protocol error count is %0d", errors);
        if (pts != 64'h1122_3344_5566_7788)
            $fatal(1, "SOF PTS mismatch: %h", pts);

        for (row = 0; row < HEIGHT; row = row + 1) begin
            for (i = 0; i < WIDTH; i = i + 1) begin
                expected = y_value(row, i);
                if (y_mem[row*STRIDE+i] !== expected)
                    $fatal(1, "Y mismatch row=%0d x=%0d got=%0d expected=%0d",
                           row, i, y_mem[row*STRIDE+i], expected);
            end
        end

        for (row = 0; row < HEIGHT/2; row = row + 1) begin
            for (i = 0; i < WIDTH/2; i = i + 1) begin
                expected = (u_value(row*2, i*2) + u_value(row*2, i*2+1) +
                            u_value(row*2+1, i*2) + u_value(row*2+1, i*2+1) + 2) >> 2;
                if (uv_mem[row*STRIDE+i*2] !== expected)
                    $fatal(1, "U mismatch row=%0d pair=%0d got=%0d expected=%0d",
                           row, i, uv_mem[row*STRIDE+i*2], expected);
                expected = (v_value(row*2, i*2) + v_value(row*2, i*2+1) +
                            v_value(row*2+1, i*2) + v_value(row*2+1, i*2+1) + 2) >> 2;
                if (uv_mem[row*STRIDE+i*2+1] !== expected)
                    $fatal(1, "V mismatch row=%0d pair=%0d got=%0d expected=%0d",
                           row, i, uv_mem[row*STRIDE+i*2+1], expected);
            end
        end

        $display("SUCCESS: YUV444 -> NV12M 2x2 box-filter DMA payload verified");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Timeout");
    end
endmodule
