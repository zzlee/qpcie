`timescale 1ns / 1ps

module tb_sg_c2h_burst_boundary;
    reg clk = 0;
    reg rst_n = 0;
    always #4 clk = ~clk;

    reg c2h_desc_valid = 0;
    wire c2h_desc_ready;
    wire c2h_req_valid;
    wire [63:0] c2h_req_addr;
    wire [10:0] c2h_req_dw_len;
    wire [127:0] c2h_req_data;
    wire c2h_req_last;
    wire c2h_req_data_ready;
    wire c2h_req_ack;
    wire [31:0] completed_c2h_count;
    wire [31:0] c2h_bytes_transferred;

    wire [127:0] rq_data;
    wire rq_valid;
    wire rq_last;
    wire [61:0] rq_user;
    wire [15:0] rq_keep;
    reg rq_ready = 0;
    reg [7:0] lfsr = 8'hA5;

    integer burst;
    integer beat;
    integer global_dw;
    reg [63:0] expected_addr;
    reg [10:0] expected_len;

    sg_dma_engine #(.PCIE_DATA_WIDTH(128)) source (
        .clk(clk), .rst_n(rst_n),
        .h2c_desc_valid(1'b0), .h2c_plane0_src(64'd0),
        .h2c_line_width(16'd0), .h2c_desc_ready(),
        .c2h_desc_valid(c2h_desc_valid),
        .c2h_plane0_dst(64'h0000_0001_0000_FFC0),
        .c2h_line_width(16'd256), .c2h_desc_ready(c2h_desc_ready),
        .h2c_req_valid(), .h2c_req_addr(), .h2c_req_dw_len(),
        .h2c_req_tag(), .h2c_req_ack(1'b0),
        .c2h_req_valid(c2h_req_valid), .c2h_req_addr(c2h_req_addr),
        .c2h_req_dw_len(c2h_req_dw_len), .c2h_req_data(c2h_req_data),
        .c2h_req_last(c2h_req_last),
        .c2h_req_data_ready(c2h_req_data_ready),
        .c2h_req_ack(c2h_req_ack),
        .h2c_cpl_valid(1'b0), .h2c_cpl_data(128'd0),
        .h2c_cpl_last(1'b0),
        .completed_h2c_count(), .completed_c2h_count(completed_c2h_count),
        .h2c_bytes_transferred(),
        .c2h_bytes_transferred(c2h_bytes_transferred),
        .h2c_busy(), .c2h_busy()
    );

    rq_tx_encoder #(.DATA_WIDTH(128)) encoder (
        .clk(clk), .rst_n(rst_n),
        .m_axis_rq_tdata(rq_data), .m_axis_rq_tvalid(rq_valid),
        .m_axis_rq_tlast(rq_last), .m_axis_rq_tuser(rq_user),
        .m_axis_rq_tkeep(rq_keep), .m_axis_rq_tready(rq_ready),
        .irq_req_valid(1'b0), .irq_req_code(8'd0), .irq_req_ack(),
        .desc_req_valid(1'b0), .desc_req_addr(64'd0),
        .desc_req_dw_len(11'd0), .desc_req_tag(8'd0), .desc_req_ack(),
        .sg_req_valid(1'b0), .sg_req_addr(64'd0),
        .sg_req_dw_len(11'd0), .sg_req_tag(8'd0), .sg_req_ack(),
        .h2c_req_valid(1'b0), .h2c_req_addr(64'd0),
        .h2c_req_dw_len(11'd0), .h2c_req_tag(8'd0), .h2c_req_ack(),
        .c2h_req_valid(c2h_req_valid), .c2h_req_addr(c2h_req_addr),
        .c2h_req_dw_len(c2h_req_dw_len), .c2h_req_data(c2h_req_data),
        .c2h_req_last(c2h_req_last),
        .c2h_req_data_ready(c2h_req_data_ready),
        .c2h_req_ack(c2h_req_ack)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 8'hA5;
            rq_ready <= 1'b0;
        end else begin
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            rq_ready <= lfsr[0] | lfsr[3];
        end
    end

    task wait_rq_transfer;
        begin
            @(posedge clk);
            while (!(rq_valid && rq_ready))
                @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        c2h_desc_valid <= 1;
        wait(c2h_desc_ready);
        @(posedge clk);
        c2h_desc_valid <= 0;

        global_dw = 0;
        for (burst = 0; burst < 2; burst = burst + 1) begin
            case (burst)
                0: begin
                    expected_addr = 64'h0000_0001_0000_FFC0;
                    expected_len = 11'd16;
                end
                default: begin
                    expected_addr = 64'h0000_0001_0001_0000;
                    expected_len = 11'd48;
                end
            endcase

            wait_rq_transfer();
            if (rq_data[78:75] !== 4'b0001 ||
                rq_data[63:0] !== expected_addr ||
                rq_data[74:64] !== expected_len || rq_last)
                $fatal(1, "Burst %0d header mismatch addr=%h len=%0d last=%b",
                       burst, rq_data[63:0], rq_data[74:64], rq_last);

            for (beat = 0; beat < ((expected_len + 3) / 4);
                 beat = beat + 1) begin
                wait_rq_transfer();
                if (rq_data[31:0] !== (32'hC200_0000 | global_dw) ||
                    rq_data[63:32] !== (32'hC200_0000 | (global_dw + 1)) ||
                    rq_data[95:64] !== (32'hC200_0000 | (global_dw + 2)) ||
                    rq_data[127:96] !== (32'hC200_0000 | (global_dw + 3)))
                    $fatal(1, "Burst %0d payload beat %0d mismatch: %h",
                           burst, beat, rq_data);
                if (rq_last !== (beat == (((expected_len + 3) / 4) - 1)))
                    $fatal(1, "Burst %0d payload beat %0d TLAST mismatch",
                           burst, beat);
                if (rq_keep !== 16'hffff)
                    $fatal(1, "Burst %0d payload beat %0d TKEEP mismatch",
                           burst, beat);
                global_dw = global_dw + 4;
            end
        end

        wait(completed_c2h_count == 1);
        if (c2h_bytes_transferred !== 32'd256 || global_dw != 64)
            $fatal(1, "Byte/DWORD accounting mismatch bytes=%0d dw=%0d",
                   c2h_bytes_transferred, global_dw);

        $display("SUCCESS: 256-byte C2H bursts split 64/192 at 4-KiB boundary under backpressure");
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "C2H burst boundary test timeout");
    end
endmodule
