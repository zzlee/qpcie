`timescale 1ns / 1ps
// This tests the RTL contract, not the hard PCIe IP: each MRd must retain its
// client tag, and each unstraddled RC completion must carry the SAME tag.
// scripts/build_zu4ev.tcl separately asserts both required IP settings.
module zu4ev_client_tag_rc_tb;
    reg clk = 0, rst_n = 0;
    always #2 clk = ~clk;
    reg req_valid = 0;
    reg [7:0] req_tag = 0;
    wire req_ack;
    wire [255:0] rq_data;
    wire rq_valid;
    reg [255:0] rc_data = 0;
    reg rc_valid = 0;
    wire rc_ready, fifo_valid, thin_valid, sg_valid;
    wire [7:0] fifo_tag;
    wire [2:0] fifo_count;
    wire [255:0] fifo_data;

    rq_tx_encoder #(.DATA_WIDTH(256), .KEEP_WIDTH(8)) rq (
        .clk(clk), .rst_n(rst_n), .requester_id(16'h0100),
        .m_axis_rq_tdata(rq_data), .m_axis_rq_tvalid(rq_valid),
        .m_axis_rq_tlast(), .m_axis_rq_tuser(), .m_axis_rq_tkeep(),
        .m_axis_rq_tready(1'b1),
        .irq_req_valid(1'b0), .irq_req_code(8'd0), .irq_req_ack(),
        .desc_req_valid(1'b0), .desc_req_addr(64'd0),
        .desc_req_dw_len(11'd0), .desc_req_tag(8'd0), .desc_req_ack(),
        .sg_req_valid(1'b0), .sg_req_addr(64'd0),
        .sg_req_dw_len(11'd0), .sg_req_tag(8'd0), .sg_req_ack(),
        .h2c_req_valid(req_valid), .h2c_req_addr(64'h12345000),
        .h2c_req_dw_len(11'd4), .h2c_req_tag(req_tag), .h2c_req_ack(req_ack),
        .c2h_req_valid(1'b0), .c2h_req_addr(64'd0),
        .c2h_req_dw_len(11'd0), .c2h_req_data(256'd0), .c2h_req_last(1'b0),
        .c2h_req_data_ready(), .c2h_req_ack()
    );
    rc_rx_decoder #(.DATA_WIDTH(256), .KEEP_WIDTH(8)) rc (
        .clk(clk), .rst_n(rst_n), .s_axis_rc_tdata(rc_data),
        .s_axis_rc_tvalid(rc_valid), .s_axis_rc_tlast(1'b1),
        .s_axis_rc_tuser(75'd0), .s_axis_rc_tkeep(8'hff),
        .s_axis_rc_tready(rc_ready),
        .thin_cpl_valid(thin_valid), .thin_cpl_data(), .thin_cpl_last(),
        .desc_cpl_valid(), .desc_cpl_data(), .desc_cpl_last(),
        .sg_cpl_valid(sg_valid), .sg_cpl_data(), .sg_cpl_last(), .sg_cpl_tag(),
        .h2c_fifo_wvalid(fifo_valid), .h2c_fifo_wdata(fifo_data),
        .h2c_fifo_wlast(), .h2c_fifo_wdw_count(fifo_count),
        .h2c_fifo_wtag(fifo_tag), .tag_free_req(), .tag_free_val()
    );

    task automatic check_tag(input [7:0] expected);
        @(negedge clk);
        req_tag = expected;
        req_valid = 1;
        wait (rq_valid);
        if (rq_data[103:96] !== expected || rq_data[78:75] !== 4'b0000)
            $fatal(1, "RQ MRd tag or type wrong for tag %0d", expected);
        wait (req_ack);
        @(negedge clk); req_valid = 0;
        repeat (3) @(negedge clk);
        rc_data = 256'd0;
        rc_data[71:64] = expected;
        rc_data[42:32] = 11'd4;
        rc_data[223:96] = 128'h01234567_89abcdef_cafebabe_11223344;
        rc_valid = 1;
        @(negedge clk); rc_valid = 0;
        if (fifo_valid !== 1 || fifo_tag !== expected || fifo_count !== 4 ||
            fifo_data[127:0] !== 128'h01234567_89abcdef_cafebabe_11223344 ||
            thin_valid !== 0 || sg_valid !== 0)
            $fatal(1, "H2C RC tag %0d misrouted: fifo=%b tag=%0d thin=%b sg=%b",
                   expected, fifo_valid, fifo_tag, thin_valid, sg_valid);
        repeat (2) @(negedge clk);
    endtask
    initial begin
        repeat (5) @(negedge clk); rst_n = 1;
        check_tag(8'd2);
        check_tag(8'd17);
        // A core-generated tag 0 would route this same CplD to thin descriptor,
        // NOT H2C: the failure observed in 1205 is thus consistent with IP defaults.
        rc_data = 256'd0; rc_data[42:32] = 11'd4;
        @(negedge clk); rc_valid = 1;
        @(negedge clk); rc_valid = 0;
        if (!thin_valid || fifo_valid) $fatal(1, "tag 0 routing contrast failed");
        $display("TB_PASS: client tags 2/17 route to H2C, core tag 0 would not");
        $finish;
    end
    initial begin #10000; $fatal(1, "watchdog"); end
endmodule
