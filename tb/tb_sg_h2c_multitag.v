`timescale 1ns/1ps

module tb_sg_h2c_multitag;
    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk;

    reg desc_valid = 0, req_ack = 0;
    reg cpl_valid = 0;
    reg [7:0] cpl_tag = 0;
    reg [127:0] cpl_data = 0;
    reg [2:0] cpl_count = 0;
    wire desc_ready, req_valid;
    wire [63:0] req_addr;
    wire [10:0] req_len;
    wire [7:0] req_tag;
    wire [127:0] out_data;
    wire out_valid, out_last, out_user;
    wire [31:0] completed_count, error_count;
    integer request, packet, beat, lane;
    integer output_beat = 0;

    sg_dma_engine dut (
        .clk(clk), .rst_n(rst_n),
        .h2c_desc_valid(desc_valid), .h2c_plane0_src(64'h1000),
        .h2c_plane1_src(64'd0), .h2c_line_width(16'd8704),
        .h2c_line_count(16'd1), .h2c_plane12_width(16'd0),
        .h2c_plane12_count(16'd0), .h2c_plane_count(4'd1),
        .h2c_format(4'd2), .h2c_desc_ctrl(16'd0),
        .h2c_desc_ready(desc_ready), .h2c_loopback_enable(),
        .h2c_loopback_channel(),
        .sgl_h2c_y_wr_en(1'b0), .sgl_h2c_y_wr_addr(64'd0),
        .sgl_h2c_y_wr_len(32'd0), .sgl_h2c_y_wr_flags(32'd0),
        .sgl_h2c_uv_wr_en(1'b0), .sgl_h2c_uv_wr_addr(64'd0),
        .sgl_h2c_uv_wr_len(32'd0), .sgl_h2c_uv_wr_flags(32'd0),
        .c2h_desc_valid(1'b0), .c2h_plane0_dst(64'd0),
        .c2h_line_width(16'd0), .c2h_line_count(16'd0),
        .c2h_plane12_width(16'd0), .c2h_plane12_count(16'd0),
        .c2h_plane_count(4'd0), .c2h_desc_ready(),
        .h2c_req_valid(req_valid), .h2c_req_addr(req_addr),
        .h2c_req_dw_len(req_len), .h2c_req_tag(req_tag),
        .h2c_req_ack(req_ack), .c2h_req_valid(), .c2h_req_addr(),
        .c2h_req_dw_len(), .c2h_req_data(), .c2h_req_last(),
        .c2h_req_data_ready(1'b0), .c2h_req_ack(1'b0),
        .h2c_cpl_valid(cpl_valid), .h2c_cpl_data(cpl_data),
        .h2c_cpl_last(1'b0), .h2c_cpl_dw_count(cpl_count),
        .h2c_cpl_tag(cpl_tag), .h2c_y_almost_full(),
        .h2c_uv_almost_full(), .m_axis_loopback_tdata(out_data),
        .m_axis_loopback_tvalid(out_valid), .m_axis_loopback_tlast(out_last),
        .m_axis_loopback_tuser(out_user), .m_axis_loopback_tready(1'b1),
        .h2c_busy(), .c2h_busy(), .completed_h2c_count(completed_count),
        .completed_c2h_count(), .h2c_bytes_transferred(),
        .c2h_bytes_transferred(), .dma_error_count(error_count)
    );

    always @(posedge clk) begin
        if (out_valid) begin
            for (lane = 0; lane < 4; lane = lane + 1)
                if (out_data[lane*32 +: 32] !== output_beat*4 + lane)
                    $fatal(1, "Ordered stream mismatch beat=%0d lane=%0d got=%h",
                           output_beat, lane, out_data[lane*32 +: 32]);
            if (out_user !== (output_beat == 0))
                $fatal(1, "SOF mismatch at beat %0d", output_beat);
            if (out_last !== (output_beat == 543))
                $fatal(1, "TLAST mismatch at beat %0d", output_beat);
            output_beat <= output_beat + 1;
        end
    end

    task return_512b;
        input [7:0] tag;
        input integer base_dw;
        begin
            for (packet = 0; packet < 2; packet = packet + 1) begin
                for (beat = 0; beat < 17; beat = beat + 1) begin
                    @(negedge clk);
                    cpl_tag = tag;
                    cpl_data = 0;
                    if (beat == 0) begin
                        cpl_data[31:0] = base_dw + packet*64;
                        cpl_count = 1;
                    end else begin
                        for (lane = 0; lane < 4; lane = lane + 1)
                            if (1 + (beat-1)*4 + lane < 64)
                                cpl_data[lane*32 +: 32] =
                                    base_dw + packet*64 + 1 + (beat-1)*4 + lane;
                        cpl_count = (beat == 16) ? 3 : 4;
                    end
                    cpl_valid = 1;
                end
                @(negedge clk);
                cpl_valid = 0;
                cpl_count = 0;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        desc_valid = 1;
        @(negedge clk);
        desc_valid = 0;

        // Fill the complete sixteen-request window before returning any data.
        for (request = 0; request < 16; request = request + 1) begin
            wait(req_valid);
            if (req_addr != 64'h1000 + request*512 || req_len != 128 ||
                req_tag != request + 2)
                $fatal(1, "Request %0d mismatch addr=%h len=%0d tag=%0d",
                       request, req_addr, req_len, req_tag);
            @(negedge clk);
            req_ack = 1;
            @(negedge clk);
            req_ack = 0;
        end

        // Return all requests in reverse order; retirement must remain ordered.
        for (request = 15; request >= 0; request = request - 1)
            return_512b(request + 2, request*128);

        // Retirement of the oldest slot must permit safe tag-2 reuse while
        // the other fifteen slots are still draining in issue order.
        wait(req_valid);
        if (req_addr != 64'h3000 || req_len != 128 || req_tag != 2)
            $fatal(1, "Wrapped request mismatch addr=%h len=%0d tag=%0d",
                   req_addr, req_len, req_tag);
        @(negedge clk);
        req_ack = 1;
        @(negedge clk);
        req_ack = 0;
        return_512b(2, 2048);

        wait(completed_count == 1);
        wait(output_beat == 544);
        if (error_count != 0)
            $fatal(1, "DMA error count is %0d", error_count);
        $display("SUCCESS: sixteen-tag window reordered responses and safely reused tag 2");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Timeout");
    end
endmodule
