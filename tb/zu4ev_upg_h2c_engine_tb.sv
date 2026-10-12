`timescale 1ns / 1ps

// Reproduce the 1204 H2C canary stall in simulation: drive sg_dma_engine
// with the EXACT upgrade descriptor the 1204 design builds for a 4096-byte
// transfer (plane0_src=host addr, plane1_src=size, width=4096, count=1,
// planes=1, ctrl=0). RQ side is acked immediately; one completion per MRd
// is returned with the allocated tag. PASS = busy drops, bytes=4096,
// exactly one descriptor completion. This isolates the engine; it cannot
// validate the full RQ/RC, clock crossings, or PS DDR writer.
module zu4ev_upg_h2c_engine_tb;
    reg clk = 0;
    always #2 clk = ~clk; // 250 MHz pcie domain
    reg rst_n = 0;

    reg        desc_valid = 0;
    reg [63:0] plane0_src = 64'h0000_1111_2222_3000;
    reg [63:0] plane1_src = 64'h0000_0000_0000_1000; // 4096
    reg [15:0] line_width = 16'd4096;
    reg [15:0] line_count = 16'd1;

    wire        req_valid;
    wire        req_ack_stub;
    assign      req_ack_stub = req_valid && !pend && !cpl_valid;
    wire [63:0] req_addr;
    wire [10:0] req_dw_len;
    wire [7:0]  req_tag;
    wire        desc_ready;
    wire        busy;
    wire [31:0] bytes_xfr;
    wire [31:0] completed;

    reg         cpl_valid = 0;
    reg [255:0] cpl_data = 0;
    reg  [2:0]  cpl_dw_count = 0;
    reg  [7:0]  cpl_tag = 0;

    sg_dma_engine #(.PCIE_DATA_WIDTH(256)) dut (
        .clk(clk), .rst_n(rst_n),
        .h2c_desc_valid(desc_valid),
        .h2c_plane0_src(plane0_src),
        .h2c_plane1_src(plane1_src),
        .h2c_line_width(line_width),
        .h2c_line_count(line_count),
        .h2c_plane12_width(16'd0),
        .h2c_plane12_count(16'd0),
        .h2c_plane_count(4'd1),
        .h2c_format(4'd0),
        .h2c_desc_ctrl(16'd0),
        .h2c_desc_ready(desc_ready),
        .h2c_loopback_enable(),
        .h2c_loopback_channel(),
        .sgl_h2c_y_wr_en(1'b0),
        .sgl_h2c_y_wr_addr(64'd0),
        .sgl_h2c_y_wr_len(32'd0),
        .sgl_h2c_y_wr_flags(32'd0),
        .sgl_h2c_uv_wr_en(1'b0),
        .sgl_h2c_uv_wr_addr(64'd0),
        .sgl_h2c_uv_wr_len(32'd0),
        .sgl_h2c_uv_wr_flags(32'd0),
        .c2h_desc_valid(1'b0),
        .c2h_plane0_dst(64'd0),
        .c2h_line_width(16'd0),
        .c2h_line_count(16'd0),
        .c2h_plane12_width(16'd0),
        .c2h_plane12_count(16'd0),
        .c2h_plane_count(4'd0),
        .c2h_desc_ready(),
        .h2c_req_valid(req_valid),
        .h2c_req_addr(req_addr),
        .h2c_req_dw_len(req_dw_len),
        .h2c_req_tag(req_tag),
        .h2c_req_ack(req_ack_stub),
        .c2h_req_valid(),
        .c2h_req_addr(),
        .c2h_req_dw_len(),
        .c2h_req_data(),
        .c2h_req_last(),
        .c2h_req_data_ready(),
        .c2h_req_ack(),
        .h2c_cpl_valid(cpl_valid),
        .h2c_cpl_data(cpl_data),
        .h2c_cpl_dw_count(cpl_dw_count),
        .h2c_cpl_tag(cpl_tag),
        .h2c_cpl_last(1'b0),
        .h2c_y_almost_full(),
        .h2c_uv_almost_full(),
        .m_axis_loopback_tdata(),
        .m_axis_loopback_tvalid(),
        .m_axis_loopback_tlast(),
        .m_axis_loopback_tuser(),
        .m_axis_loopback_tready(1'b1),
        .h2c_busy(busy),
        .c2h_busy(),
        .completed_h2c_count(completed),
        .completed_c2h_count(),
        .h2c_bytes_transferred(bytes_xfr),
        .c2h_bytes_transferred(),
        .dma_error_count()
    );

    // Backpressure RQ until the prior MRd's completion is fully returned.
    reg        pend = 0;
    reg [7:0]  pend_tag = 0;
    integer beats_left = 0;
    integer request_count = 0;
    integer retire_count = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            pend <= 0; cpl_valid <= 0; beats_left <= 0;
            request_count <= 0; retire_count <= 0;
        end else begin
            cpl_valid <= 1'b0;
            if (req_valid && req_ack_stub) begin
                if (req_dw_len == 0 || req_dw_len > 64 || req_addr[11:0] + (req_dw_len << 2) > 4096)
                    $fatal(1, "invalid MRd addr=%h dw=%0d", req_addr, req_dw_len);
                $display("MRD %0d addr=%h dw=%0d tag=%0d", request_count, req_addr, req_dw_len, req_tag);
                request_count <= request_count + 1;
                pend <= 1'b1;
                pend_tag <= req_tag;
                // 128-bit datapath: 4 DW per beat
                beats_left <= (req_dw_len + 11'd3) >> 2;
            end
            if (pend) begin
                cpl_valid <= 1'b1;
                cpl_data <= {128'd0, 32'hC0FFEE00, 32'hDEADBEEF, 32'h12345678, 32'h9ABCDEF0};
                cpl_dw_count <= 3'd4;
                cpl_tag <= pend_tag;
                if (beats_left <= 1) begin
                    pend <= 1'b0;
                end
                beats_left <= beats_left - 1;
            end
            if (dut.h2c_rob_retire_valid) begin
                retire_count <= retire_count + 1;
                $display("RET %0d dw=%0d last=%b bytes=%0d", retire_count,
                         dut.h2c_rob_retire_dw_len, dut.h2c_rob_retire_frame_last, bytes_xfr);
            end
        end
    end

    initial begin
        repeat (8) @(negedge clk);
        rst_n = 1;
        repeat (8) @(negedge clk);
        @(negedge clk);
        desc_valid = 1'b1;
        // Hold until accepted (mirrors upg_h2c_desc_valid_q behavior)
        fork : wait_ready
            wait (desc_ready == 1'b1);
            begin
                repeat (2000) @(negedge clk);
                $fatal(1, "desc never accepted: state=%0d busy=%b", dut.h2c_state, busy);
            end
        join_any
        disable wait_ready;
        @(negedge clk);
        desc_valid = 1'b0;
        // Wait for completion
        fork : wait_done
            wait (completed == 32'd1);
            begin
                repeat (10000) @(negedge clk);
                $fatal(1, "engine stall: state=%0d busy=%b requests=%0d retired=%0d bytes=%0d completed=%0d",
                       dut.h2c_state, busy, request_count, retire_count, bytes_xfr, completed);
            end
        join_any
        disable wait_done;
        if (bytes_xfr !== 32'd4096)
            $fatal(1, "byte count mismatch: %0d", bytes_xfr);
        if (request_count !== 16 || retire_count !== 16 || busy !== 1'b0)
            $fatal(1, "request/retire mismatch: requests=%0d retired=%0d busy=%b", request_count, retire_count, busy);
        $display("TB_PASS: sg H2C engine moves 4096B upgrade descriptor (busy cleared, bytes=4096)");
        $finish;
    end

endmodule
