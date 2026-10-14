`timescale 1ns / 1ps

module tb_rgb24_capture_4k;
    localparam [15:0] WIDTH = 16'd3840;
    localparam [15:0] HEIGHT = 16'd2160;
    localparam [15:0] STRIDE = 16'd11520;
    localparam [15:0] EFF_WIDTH = 16'd11520;

    reg clk = 0;
    reg rst_n = 0;
    always #3.333 clk = ~clk; // 150 MHz video_clk

    reg desc_valid = 0;
    wire desc_ready;
    reg stream_enable = 0;
    reg [15:0] line_idx = 0;
    reg [15:0] beat_idx = 0;
    wire s_ready;
    wire s_valid = stream_enable && (line_idx < HEIGHT);
    wire s_last = (beat_idx == 16'd959);
    wire s_user = (line_idx == 0 && beat_idx == 0);
    wire [127:0] s_data = 128'h0123456789ABCDEF0123456789ABCDEF;

    wire req_valid, req_data_ready, req_ack, req_last;
    wire [63:0] req_addr;
    wire [10:0] req_len;
    wire [127:0] req_data;
    wire busy, done;
    wire [31:0] errors;

    reg sgl_y_wr_en = 0;
    reg [63:0] sgl_y_wr_addr = 0;
    reg [31:0] sgl_y_wr_len = 0;
    reg [31:0] sgl_y_wr_flags = 0;
    wire sgl_y_pop_ready;

    nv12_capture_engine #(
        .MAX_WIDTH(4096),
        .PCIE_DATA_WIDTH(128),
        .FIFO_DEPTH(512),
        .MWR_PAYLOAD_BYTES(256)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .desc_valid(desc_valid),
        .desc_ready(desc_ready),
        .desc_format(4'd1), // RGB24
        .desc_sg_mode(1'b1), // SGL mode
        .plane_y_addr(64'd0),
        .plane_uv_addr(64'd0),
        .frame_width(EFF_WIDTH), // 11520 bytes
        .frame_height(HEIGHT),   // 2160 lines
        .frame_stride(STRIDE),   // 11520 bytes
        .sgl_y_wr_en(sgl_y_wr_en),
        .sgl_y_wr_addr(sgl_y_wr_addr),
        .sgl_y_wr_len(sgl_y_wr_len),
        .sgl_y_wr_flags(sgl_y_wr_flags),
        .sgl_uv_wr_en(1'b0),
        .sgl_uv_wr_addr(64'd0),
        .sgl_uv_wr_len(32'd0),
        .sgl_uv_wr_flags(32'd0),
        .cur_y_sgl_count(),
        .cur_uv_sgl_count(),
        .sgl_y_pop_ready(sgl_y_pop_ready),
        .sgl_uv_pop_ready(),
        .pacer_enable(1'b0),
        .frame_interval_clks(32'd0),
        .global_timestamp(64'd0),
        .s_axis_tdata(s_data),
        .s_axis_tvalid(s_valid),
        .s_axis_tlast(s_last),
        .s_axis_tuser(s_user),
        .s_axis_tready(s_ready),
        .c2h_req_valid(req_valid),
        .c2h_req_addr(req_addr),
        .c2h_req_dw_len(req_len),
        .c2h_req_data(req_data),
        .c2h_req_last(req_last),
        .c2h_req_data_ready(req_data_ready),
        .c2h_req_ack(req_ack),
        .video_busy(busy),
        .video_frame_done(done),
        .frame_pts(),
        .protocol_error_count(errors)
    );

    // Fast requester drain mock
    reg [4:0] beat_down;
    reg draining = 0;
    assign req_data_ready = draining;
    assign req_ack = (draining && beat_down == 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            draining <= 0;
            beat_down <= 0;
        end else begin
            if (req_valid && !draining) begin
                draining <= 1;
                beat_down <= (req_len == 11'd64) ? 5'd16 : 5'd8;
            end else if (draining) begin
                beat_down <= beat_down - 1'b1;
                if (beat_down == 1) begin
                    draining <= 0;
                end
            end
        end
    end

    // Video stream driving
    always @(posedge clk) begin
        if (!rst_n) begin
            line_idx <= 0;
            beat_idx <= 0;
        end else if (s_valid && s_ready) begin
            if (beat_idx == 16'd959) begin
                beat_idx <= 0;
                line_idx <= line_idx + 1'b1;
            end else begin
                beat_idx <= beat_idx + 1'b1;
            end
        end
    end

    integer k;
    initial begin
        #100;
        rst_n = 1;
        #100;

        // Queue 13 descriptors matching host driver
        // buf7: 5x 4MB, 1x 2MB, 1x 1MB, 1x 512KB, 1x 128KB, 1x 64KB, 1x 32KB, 1x 8KB, 1x 4KB = 24,883,200 bytes
        @(negedge clk);
        desc_valid = 1;
        wait(desc_ready);
        @(negedge clk);
        desc_valid = 0;

        // Push 6x 4MB descriptors to cover 24.88MB
        for (k = 0; k < 6; k = k + 1) begin
            @(posedge clk);
            sgl_y_wr_en   <= 1;
            sgl_y_wr_addr <= 64'h1_0000_0000 + k * 32'd4194304;
            sgl_y_wr_len  <= 32'd4194304;
            sgl_y_wr_flags<= 32'd1;
            @(posedge clk);
            sgl_y_wr_en   <= 0;
            #10;
        end

        #50;
        $display("[%0t] Starting video stream for 4K RGB24...", $time);
        stream_enable = 1;

        fork
            begin
                wait(line_idx == HEIGHT);
                $display("[%0t] Frontend finished line 2160!", $time);
            end
            begin
                wait(done);
                $display("[%0t] SUCCESS: video_frame_done asserted!", $time);
                $finish;
            end
            begin
                #20000000; // 20ms timeout
                $display("[%0t] TIMEOUT: video_frame_done never asserted!", $time);
                $display("busy=%b frontend_done=%b y_fifo_count=%0d req_valid=%b errors=%0d",
                         dut.video_busy, dut.frontend_done, dut.y_fifo_count, dut.c2h_req_valid, dut.protocol_error_count);
                $display("y_send_line=%0d line_idx=%0d y_walker_bytes_left=%0d y_seg_valid=%b",
                         dut.y_send_line, dut.line_idx, dut.y_walker_bytes_left, dut.y_seg_valid);
                $fatal(1);
            end
        join
    end
endmodule
