`timescale 1ns/1ps
module tb_sg_dma_engine;
    reg clk=0, rst_n=0;
    reg h2c_desc_valid=0, h2c_req_ack=0, h2c_cpl_valid=0, h2c_cpl_last=0;
    reg [63:0] h2c_plane0_src=64'h1000;
    reg [15:0] h2c_line_width=16'd256, h2c_line_count=16'd1;
    reg [15:0] h2c_desc_ctrl=16'd0;
    reg sgl_h2c_y_wr_en=0;
    reg [63:0] sgl_h2c_y_wr_addr=0;
    reg [31:0] sgl_h2c_y_wr_len=0, sgl_h2c_y_wr_flags=0;
    wire h2c_desc_ready, h2c_req_valid;
    wire [63:0] h2c_req_addr; wire [10:0] h2c_req_dw_len; wire [7:0] h2c_req_tag;
    wire [31:0] completed_h2c_count, h2c_bytes_transferred;
    integer beat;
    always #4 clk=~clk;

    sg_dma_engine #(.PCIE_DATA_WIDTH(128)) dut (
        .clk(clk), .rst_n(rst_n),
        .h2c_desc_valid(h2c_desc_valid), .h2c_plane0_src(h2c_plane0_src),
        .h2c_plane1_src(64'd0), .h2c_line_width(h2c_line_width),
        .h2c_line_count(h2c_line_count), .h2c_plane12_width(16'd0),
        .h2c_plane12_count(16'd0), .h2c_plane_count(4'd1),
        .h2c_desc_ctrl(h2c_desc_ctrl), .h2c_desc_ready(h2c_desc_ready),
        .sgl_h2c_y_wr_en(sgl_h2c_y_wr_en),
        .sgl_h2c_y_wr_addr(sgl_h2c_y_wr_addr),
        .sgl_h2c_y_wr_len(sgl_h2c_y_wr_len),
        .sgl_h2c_y_wr_flags(sgl_h2c_y_wr_flags),
        .sgl_h2c_uv_wr_en(1'b0), .sgl_h2c_uv_wr_addr(64'd0),
        .sgl_h2c_uv_wr_len(32'd0), .sgl_h2c_uv_wr_flags(32'd0),
        .c2h_desc_valid(1'b0), .c2h_plane0_dst(64'd0), .c2h_line_width(16'd0),
        .c2h_line_count(16'd0), .c2h_plane12_width(16'd0),
        .c2h_plane12_count(16'd0), .c2h_plane_count(4'd0),
        .c2h_desc_ready(), .h2c_req_valid(h2c_req_valid),
        .h2c_req_addr(h2c_req_addr), .h2c_req_dw_len(h2c_req_dw_len),
        .h2c_req_tag(h2c_req_tag), .h2c_req_ack(h2c_req_ack),
        .c2h_req_valid(), .c2h_req_addr(), .c2h_req_dw_len(), .c2h_req_data(),
        .c2h_req_last(), .c2h_req_data_ready(1'b0), .c2h_req_ack(1'b0),
        .h2c_cpl_valid(h2c_cpl_valid), .h2c_cpl_data(128'd0),
        .h2c_cpl_last(h2c_cpl_last),
        .h2c_y_almost_full(), .h2c_uv_almost_full(),
        .m_axis_loopback_tdata(), .m_axis_loopback_tvalid(),
        .m_axis_loopback_tlast(), .m_axis_loopback_tuser(),
        .m_axis_loopback_tready(1'b1),
        .completed_h2c_count(completed_h2c_count), .completed_c2h_count(),
        .h2c_bytes_transferred(h2c_bytes_transferred), .c2h_bytes_transferred(),
        .h2c_busy(), .c2h_busy(), .dma_error_count());

    task complete_request;
        input integer request_dw;
        integer completion_beats;
        begin
            completion_beats = 1 + ((request_dw + 2) / 4);
            for (beat=0; beat<completion_beats; beat=beat+1) begin
                @(posedge clk);
                h2c_cpl_valid <= 1'b1;
                h2c_cpl_last <= (beat == completion_beats - 1);
            end
            @(posedge clk);
            h2c_cpl_valid <= 1'b0; h2c_cpl_last <= 1'b0;
        end
    endtask

    task start_h2c;
        input [63:0] source_addr;
        input [15:0] frame_bytes;
        input [15:0] control;
        begin
            h2c_plane0_src = source_addr;
            h2c_line_width = frame_bytes;
            h2c_desc_ctrl = control;
            @(posedge clk); h2c_desc_valid <= 1;
            @(posedge clk); h2c_desc_valid <= 0;
        end
    endtask

    task push_y_segment;
        input [63:0] segment_addr;
        input [31:0] segment_len;
        begin
            @(posedge clk);
            sgl_h2c_y_wr_addr <= segment_addr;
            sgl_h2c_y_wr_len <= segment_len;
            sgl_h2c_y_wr_flags <= 32'd2;
            sgl_h2c_y_wr_en <= 1;
            @(posedge clk); sgl_h2c_y_wr_en <= 0;
        end
    endtask

    task service_request;
        input [63:0] expected_addr;
        input [10:0] expected_dw;
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while (!h2c_req_valid && timeout_cycles < 100) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!h2c_req_valid) begin
                $display("FAIL: timeout waiting for H2C request addr=%h len=%0d state=%0d rem=%0d walker_valid=%0d walker_addr=%h walker_left=%0d",
                         expected_addr, expected_dw, dut.h2c_state,
                         dut.h2c_rem_bytes, dut.h2c_y_seg_valid,
                         dut.h2c_y_walker_addr, dut.h2c_y_walker_bytes_left);
                $finish;
            end
            if (h2c_req_dw_len !== expected_dw || h2c_req_tag !== 8'h02 ||
                h2c_req_addr !== expected_addr) begin
                $display("FAIL: H2C request expected addr=%h len=%0d, got addr=%h len=%0d",
                         expected_addr, expected_dw, h2c_req_addr, h2c_req_dw_len);
                $finish;
            end
            if (h2c_req_dw_len == 0) begin
                $display("FAIL: zero-length MRd emitted");
                $finish;
            end
            @(posedge clk); h2c_req_ack<=1;
            @(posedge clk); h2c_req_ack<=0;
            repeat (3) begin
                @(posedge clk);
                if (h2c_req_valid) begin
                    $display("FAIL: duplicate MRd issued before completion");
                    $finish;
                end
            end
            complete_request(expected_dw);
            $display("  request addr=%h len=%0d DW completed", expected_addr, expected_dw);
        end
    endtask

    task reset_dut;
        begin
            rst_n = 0;
            h2c_desc_valid = 0;
            h2c_req_ack = 0;
            h2c_cpl_valid = 0;
            h2c_cpl_last = 0;
            sgl_h2c_y_wr_en = 0;
            repeat (3) @(posedge clk);
            rst_n = 1;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        reset_dut();

        $display("[TEST 1] Linear H2C completion serialization");
        start_h2c(64'h1000, 16'd256, 16'd0);
        service_request(64'h1000, 11'd64);
        wait(completed_h2c_count == 1);
        if (h2c_bytes_transferred !== 256) begin
            $display("FAIL: H2C byte count %0d", h2c_bytes_transferred); $finish;
        end

        reset_dut();
        $display("[TEST 2] 64-KiB SG segment cannot truncate to zero length");
        start_h2c(64'h0, 16'd256, 16'h0020);
        push_y_segment(64'h00000000_20000000, 32'h00010000);
        service_request(64'h00000000_20000000, 11'd64);
        wait(completed_h2c_count == 1);

        reset_dut();
        $display("[TEST 3] SG MRds cannot cross a 4-KiB boundary");
        start_h2c(64'h0, 16'd512, 16'h0020);
        push_y_segment(64'h00000000_20000ff0, 32'h00010000);
        service_request(64'h00000000_20000ff0, 11'd4);
        service_request(64'h00000000_20001000, 11'd64);
        service_request(64'h00000000_20001100, 11'd60);
        wait(completed_h2c_count == 1);

        $display("SUCCESS: H2C SG burst limits and completion accounting passed");
        $finish;
    end
endmodule
