`timescale 1ns/1ps

module tb_sg_loopback_packing;
    reg clk = 0;
    reg rst_n = 0;
    always #4 clk = ~clk;

    reg desc_valid, req_ack, cpl_valid, cpl_last;
    reg [2:0] cpl_dw_count;
    reg [127:0] cpl_data;
    wire desc_ready, req_valid;
    wire [10:0] req_len;
    wire [127:0] loop_data;
    wire loop_valid, loop_last, loop_user;
    wire [31:0] completed_count;
    integer packet, beat, lane, output_dw, output_beats;

    sg_dma_engine #(.PCIE_DATA_WIDTH(128)) dut (
        .clk(clk), .rst_n(rst_n),
        .h2c_desc_valid(desc_valid), .h2c_plane0_src(64'h1000),
        .h2c_plane1_src(64'd0), .h2c_line_width(16'd512),
        .h2c_line_count(16'd1), .h2c_plane12_width(16'd0),
        .h2c_plane12_count(16'd0), .h2c_plane_count(4'd1),
        .h2c_desc_ctrl(16'd0), .h2c_desc_ready(desc_ready),
        .sgl_h2c_y_wr_en(1'b0), .sgl_h2c_y_wr_addr(64'd0),
        .sgl_h2c_y_wr_len(32'd0), .sgl_h2c_y_wr_flags(32'd0),
        .sgl_h2c_uv_wr_en(1'b0), .sgl_h2c_uv_wr_addr(64'd0),
        .sgl_h2c_uv_wr_len(32'd0), .sgl_h2c_uv_wr_flags(32'd0),
        .c2h_desc_valid(1'b0), .c2h_plane0_dst(64'd0),
        .c2h_line_width(16'd0), .c2h_line_count(16'd0),
        .c2h_plane12_width(16'd0), .c2h_plane12_count(16'd0),
        .c2h_plane_count(4'd0), .c2h_desc_ready(),
        .h2c_req_valid(req_valid), .h2c_req_addr(),
        .h2c_req_dw_len(req_len), .h2c_req_tag(), .h2c_req_ack(req_ack),
        .c2h_req_valid(), .c2h_req_addr(), .c2h_req_dw_len(),
        .c2h_req_data(), .c2h_req_last(),
        .c2h_req_data_ready(1'b0), .c2h_req_ack(1'b0),
        .h2c_cpl_valid(cpl_valid), .h2c_cpl_data(cpl_data),
        .h2c_cpl_last(cpl_last), .h2c_cpl_dw_count(cpl_dw_count),
        .h2c_cpl_tag(8'd2),
        .h2c_y_almost_full(), .h2c_uv_almost_full(),
        .m_axis_loopback_tdata(loop_data),
        .m_axis_loopback_tvalid(loop_valid),
        .m_axis_loopback_tlast(loop_last),
        .m_axis_loopback_tuser(loop_user),
        .m_axis_loopback_tready(1'b1),
        .completed_h2c_count(completed_count), .completed_c2h_count(),
        .h2c_bytes_transferred(), .c2h_bytes_transferred(),
        .h2c_busy(), .c2h_busy(), .dma_error_count()
    );

    always @(posedge clk) begin
        if (rst_n && loop_valid) begin
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (loop_data[lane*32 +: 32] !== output_dw)
                    $fatal(1, "Payload mismatch DW%0d: got %h", output_dw,
                           loop_data[lane*32 +: 32]);
                output_dw = output_dw + 1;
            end
            if (loop_user !== (output_beats == 0))
                $fatal(1, "SOF mismatch on output beat %0d", output_beats);
            if (loop_last !== (output_beats == 31))
                $fatal(1, "TLAST mismatch on output beat %0d", output_beats);
            output_beats = output_beats + 1;
        end
    end

    initial begin
        desc_valid = 0;
        req_ack = 0;
        cpl_valid = 0;
        cpl_last = 0;
        cpl_dw_count = 0;
        cpl_data = 0;
        output_dw = 0;
        output_beats = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        desc_valid = 1;
        @(negedge clk);
        desc_valid = 0;

        wait(req_valid);
        if (req_len != 128)
            $fatal(1, "Expected 128-DW MRd, got %0d", req_len);
        @(negedge clk);
        req_ack = 1;
        @(negedge clk);
        req_ack = 0;

        // Root-port MPS is 256 bytes, so one 512-byte MRd returns as two
        // independently aligned 64-DW CplD packets with an idle gap.
        for (packet = 0; packet < 2; packet = packet + 1) begin
          for (beat = 0; beat < 17; beat = beat + 1) begin
            @(negedge clk);
            cpl_data = 0;
            if (beat == 0) begin
                cpl_data[31:0] = packet * 64;
                cpl_dw_count = 1;
            end else begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (packet*64 + 1 + (beat-1)*4 + lane < (packet+1)*64)
                        cpl_data[lane*32 +: 32] =
                            packet*64 + 1 + (beat-1)*4 + lane;
                cpl_dw_count = (beat == 16) ? 3 : 4;
                if (beat == 16)
                    cpl_data[127:96] = 32'hDEAD_BEEF;
            end
            cpl_valid = 1;
            cpl_last = (beat == 16);
          end
          @(negedge clk);
          cpl_valid = 0;
          cpl_last = 0;
          cpl_dw_count = 0;
          repeat (2) @(posedge clk);
        end

        wait(completed_count == 1);
        repeat (2) @(posedge clk);
        if (output_beats != 32 || output_dw != 128)
            $fatal(1, "Expected 32 packed beats/128 DW, got %0d/%0d",
                   output_beats, output_dw);
        $display("SUCCESS: split 512-byte MRd payload repacked into 32 contiguous loopback beats");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "Timeout");
    end
endmodule
