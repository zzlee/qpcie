`timescale 1ns/1ps

module tb_rc_h2c_dw_count;
    reg clk = 0;
    reg rst_n = 0;
    always #4 clk = ~clk;

    reg [127:0] rc_data;
    reg rc_valid, rc_last;
    wire h2c_valid, h2c_last;
    wire [127:0] h2c_data;
    wire [2:0] h2c_dw_count;
    wire [7:0] h2c_tag;
    wire tag_free_req;
    integer beat, lane;

    rc_rx_decoder #(.DATA_WIDTH(128)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_rc_tdata(rc_data), .s_axis_rc_tvalid(rc_valid),
        .s_axis_rc_tlast(rc_last), .s_axis_rc_tuser(75'd0),
        .s_axis_rc_tkeep(16'hffff), .s_axis_rc_tready(),
        .desc_cpl_valid(), .desc_cpl_data(), .desc_cpl_last(),
        .sg_cpl_valid(), .sg_cpl_data(), .sg_cpl_last(), .sg_cpl_tag(),
        .h2c_fifo_wvalid(h2c_valid), .h2c_fifo_wdata(h2c_data),
        .h2c_fifo_wlast(h2c_last), .h2c_fifo_wdw_count(h2c_dw_count),
        .h2c_fifo_wtag(h2c_tag),
        .tag_free_req(tag_free_req), .tag_free_val()
    );

    initial begin
        rc_data = 0;
        rc_valid = 0;
        rc_last = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        // First RC beat contains a three-DW header and payload DW0.
        @(negedge clk);
        rc_data = 0;
        rc_data[42:32] = 64;
        rc_data[71:64] = 8'h02;
        rc_data[127:96] = 0;
        rc_valid = 1;
        @(posedge clk); #1;
        if (!h2c_valid || h2c_dw_count != 1 || h2c_data[31:0] != 0)
            $fatal(1, "First CplD beat count/alignment mismatch");

        for (beat = 1; beat < 17; beat = beat + 1) begin
            if (beat == 8) begin
                @(negedge clk);
                rc_valid = 0;
                @(posedge clk); #1;
                if (h2c_valid)
                    $fatal(1, "H2C valid repeated across an RC idle gap");
            end
            @(negedge clk);
            rc_data = 0;
            for (lane = 0; lane < 4; lane = lane + 1)
                rc_data[lane*32 +: 32] = 1 + (beat-1)*4 + lane;
            if (beat == 16)
                rc_data[127:96] = 32'hDEAD_BEEF;
            rc_valid = 1;
            rc_last = (beat == 16);
            @(posedge clk); #1;
            if (!h2c_valid || h2c_dw_count != ((beat == 16) ? 3 : 4))
                $fatal(1, "Continuation beat %0d count mismatch: %0d",
                       beat, h2c_dw_count);
        end

        @(negedge clk);
        rc_valid = 0;
        rc_last = 0;
        @(posedge clk); #1;
        if (h2c_valid)
            $fatal(1, "H2C valid remained asserted after CplD");
        $display("SUCCESS: RC H2C payload reports exact DW counts across gaps");
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && h2c_valid && h2c_tag != 8'h02)
            $fatal(1, "H2C packet tag changed on a continuation beat: %0h", h2c_tag);
        if (rst_n && tag_free_req)
            $fatal(1, "H2C tag was recycled at CplD packet end");
    end

    initial begin
        #20000;
        $fatal(1, "Timeout");
    end
endmodule
