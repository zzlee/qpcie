`timescale 1ns/1ps

module tb_h2c_reorder_buffer;
    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk;

    wire alloc_ready;
    wire [7:0] alloc_tag;
    reg alloc_commit = 0, alloc_first = 0, alloc_last = 0;
    reg cpl_valid = 0;
    reg [7:0] cpl_tag = 0;
    reg [127:0] cpl_data = 0;
    reg [2:0] cpl_count = 0;
    wire [127:0] out_data;
    wire out_valid, out_last, out_user;
    reg out_ready = 0;
    wire error_valid;
    integer cycle_count = 0;
    integer output_beat = 0;
    integer lane;
    reg stalled;
    reg [129:0] stalled_value;

    h2c_reorder_buffer dut (
        .clk(clk), .rst_n(rst_n),
        .alloc_ready(alloc_ready), .alloc_tag(alloc_tag),
        .alloc_commit(alloc_commit), .alloc_dw_len(11'd8),
        .alloc_frame_first(alloc_first), .alloc_frame_last(alloc_last),
        .cpl_valid(cpl_valid), .cpl_tag(cpl_tag), .cpl_data(cpl_data),
        .cpl_dw_count(cpl_count), .m_axis_tdata(out_data),
        .m_axis_tvalid(out_valid), .m_axis_tlast(out_last),
        .m_axis_tuser(out_user), .m_axis_tready(out_ready),
        .retire_valid(), .retire_dw_len(), .retire_frame_last(),
        .error_valid(error_valid)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            out_ready <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            out_ready <= cycle_count[1:0] != 0;
        end
    end

    always @(posedge clk) begin
        if (rst_n && error_valid)
            $fatal(1, "Unexpected reorder-buffer protocol error");
        if (rst_n && out_valid && !out_ready) begin
            if (stalled && {out_user, out_last, out_data} !== stalled_value)
                $fatal(1, "AXI output changed while stalled");
            stalled <= 1;
            stalled_value <= {out_user, out_last, out_data};
        end else begin
            stalled <= 0;
        end
        if (rst_n && out_valid && out_ready) begin
            for (lane = 0; lane < 4; lane = lane + 1)
                if (out_data[lane*32 +: 32] !== output_beat*4 + lane)
                    $fatal(1, "Output reorder mismatch beat=%0d lane=%0d got=%h",
                           output_beat, lane, out_data[lane*32 +: 32]);
            if (out_user !== (output_beat == 0))
                $fatal(1, "SOF mismatch on beat %0d", output_beat);
            if (out_last !== (output_beat == 5))
                $fatal(1, "TLAST mismatch on beat %0d", output_beat);
            output_beat <= output_beat + 1;
        end
    end

    task allocate_request;
        input [7:0] expected_tag;
        input first_request;
        input last_request;
        begin
            wait(alloc_ready);
            if (alloc_tag != expected_tag)
                $fatal(1, "Expected allocated tag %0d, got %0d", expected_tag, alloc_tag);
            @(negedge clk);
            alloc_first = first_request;
            alloc_last = last_request;
            alloc_commit = 1;
            @(negedge clk);
            alloc_commit = 0;
        end
    endtask

    task return_request;
        input [7:0] tag;
        input integer base_dw;
        begin
            @(negedge clk);
            cpl_tag = tag;
            cpl_data = base_dw;
            cpl_count = 1;
            cpl_valid = 1;
            @(negedge clk);
            for (lane = 0; lane < 4; lane = lane + 1)
                cpl_data[lane*32 +: 32] = base_dw + 1 + lane;
            cpl_count = 4;
            @(negedge clk);
            cpl_data = 128'hDEAD_BEEF_0000_0000_0000_0000_0000_0000;
            for (lane = 0; lane < 3; lane = lane + 1)
                cpl_data[lane*32 +: 32] = base_dw + 5 + lane;
            cpl_count = 3;
            @(negedge clk);
            cpl_valid = 0;
            cpl_count = 0;
        end
    endtask

    initial begin
        stalled = 0;
        stalled_value = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        allocate_request(2, 1, 0);
        allocate_request(3, 0, 0);
        allocate_request(4, 0, 1);

        // Complete youngest first. Output must remain in tag 2,3,4 issue order.
        return_request(4, 16);
        return_request(2, 0);
        return_request(3, 8);

        wait(output_beat == 6);
        repeat (4) @(posedge clk);
        $display("SUCCESS: three out-of-order tags retired in issue order under backpressure");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "Timeout");
    end
endmodule
