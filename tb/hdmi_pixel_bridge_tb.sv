`timescale 1ns/1ps
module hdmi_pixel_bridge_tb;
    reg pclk = 0, vclk = 0, rst_n = 0, single_mode = 0, stamp_mode = 0;
    always #1.6835 pclk = ~pclk; // Native 4K dual-pixel clock, ~297 MHz
    always #3.333 vclk = ~vclk;
    reg de = 0, vs = 0;
    reg [9:0] a = 0, b = 0;
    wire [127:0] data;
    wire valid, last;
    wire [0:0] user_bit;
    reg ready = 0;
    integer tick = 0, sent = 0, received = 0;
    reg [127:0] expected_data[0:16383];
    reg expected_last[0:16383], expected_user[0:16383];
    integer phase, frame_seq = 0, row_seq = 0;
    wire [59:0] sampled_pixels;
    wire sampled_de, sampled_vs, sampled_hs;
    hdmi_parallel_input input_stage (
        .pclk(pclk), .pixel_data({a, (a + 10'd4), (a + 10'd8), b, (b + 10'd4), (b + 10'd8)}),
        .de(de), .vs(vs), .hs(1'b0), .sampled_data(sampled_pixels),
        .sampled_de(sampled_de), .sampled_vs(sampled_vs), .sampled_hs(sampled_hs)
    );

    hdmi_dual_pixel_bridge #(.FIFO_DEPTH(2048)) dut (
        .tm0_pclk(pclk), .tm0_rst_n(rst_n), .tm0_de(sampled_de), .tm0_vs(sampled_vs), .tm0_hs(sampled_hs),
        .single_pixel_mode(single_mode),
        .frame_stamp_enable(stamp_mode), .capture_active(1'b1), .debug_gray(),
        .tm0_a_r(sampled_pixels[59:50]), .tm0_a_g(sampled_pixels[49:40]), .tm0_a_b(sampled_pixels[39:30]),
        .tm0_b_r(sampled_pixels[29:20]), .tm0_b_g(sampled_pixels[19:10]), .tm0_b_b(sampled_pixels[9:0]),
        .video_clk(vclk), .video_rst_n(rst_n),
        .m_axis_video_tdata(data), .m_axis_video_tvalid(valid),
        .m_axis_video_tlast(last), .m_axis_video_tuser(user_bit),
        .m_axis_video_tready(ready)
    );
    reg stalled = 0;
    reg [129:0] held;
    always @(posedge vclk) begin
        if (!rst_n) begin
            ready <= 0;
            tick <= 0;
            stalled <= 0;
        end else begin
            tick <= tick + 1;
            ready <= ((tick % 7) >= 3);
            if (stalled && (!valid || {user_bit, last, data} !== held))
                $fatal(1, "AXIS changed while stalled");
            stalled <= valid && !ready;
            held <= {user_bit, last, data};
            if (valid && ready) begin
                if (received >= sent) $fatal(1, "Unexpected extra beat");
                if (data !== expected_data[received] || last !== expected_last[received] ||
                    user_bit[0] !== expected_user[received])
                    $fatal(1, "Beat %0d mismatch: data=%h last=%b user=%b expected=%h/%b/%b",
                           received, data, last, user_bit, expected_data[received],
                           expected_last[received], expected_user[received]);
                received = received + 1;
            end
        end
    end

    function automatic [31:0] pixel(input integer n);
        pixel = {8'hFF, 8'(n), 8'(n+1), 8'(n+2)};
    endfunction

    task automatic line_pixels(input integer width, input integer start, input bit sof);
        integer i, j, n;
        reg [127:0] word_data;
        begin
            for (i = 0; i < width; i = i + 4) begin
                word_data = 0;
                for (j = 0; j < 4; j = j + 1)
                    if (i + j < width) word_data[j*32 +: 32] = pixel(start + i + j);
                if (stamp_mode && i == 0 && width >= 4)
                    word_data = {
                        8'hFF, 8'h5A, ~8'(row_seq >> 8), ~8'(row_seq),
                        8'hFF, ~8'(frame_seq >> 16), ~8'(frame_seq >> 8), ~8'(frame_seq),
                        8'hFF, 8'(row_seq >> 8), 8'(row_seq), 8'(frame_seq >> 16),
                        8'hFF, 8'(frame_seq >> 8), 8'(frame_seq), 8'hA5
                    };
                expected_data[sent] = word_data;
                expected_last[sent] = (i + 4 >= width);
                expected_user[sent] = sof && (i == 0);
                sent = sent + 1;
            end
            n = single_mode ? 1 : 2;
            for (i = 0; i < width; i = i + n) begin
                @(negedge pclk);
                de = 1;
                a = (start + i) << 2;
                b = (start + i + 1) << 2;
            end
            @(negedge pclk); de = 0;
            repeat (10) @(negedge pclk);
            row_seq = row_seq + 1;
        end
    endtask

    task automatic frame;
        begin
            frame_seq = frame_seq + 1;
            row_seq = 0;
            @(negedge pclk); vs = 1;
            repeat (4) @(negedge pclk);
            vs = 0;
            repeat (4) @(negedge pclk);
            line_pixels(8, 1, 1);
            line_pixels(12, 11, 0);
            line_pixels(2, 31, 0);
            if (single_mode) line_pixels(1, 41, 0);
            line_pixels(1920, 51, 0);
            line_pixels(3840, 61, 0);
        end
    endtask

    initial begin
        for (phase = 0; phase < 4; phase = phase + 1) begin
            single_mode = phase & 1;
            stamp_mode = phase >= 2;
            frame_seq = 0;
            rst_n = 0;
            de = 0; vs = 0;
            repeat (20) @(negedge pclk);
            rst_n = 1;
            repeat (100) @(negedge pclk);
            frame();
            frame();
            repeat (4000) @(negedge vclk);
            if (received != sent) $fatal(1, "Missing beats: %0d/%0d", received, sent);
        end
        $display("TB_PASS: IOB input, 297 MHz single/dual pixels, frame/line stamps, TLAST, padding and AXIS stalls (%0d beats)", received);
        $finish;
    end
    initial begin #300000; $fatal(1, "Timeout"); end
endmodule
