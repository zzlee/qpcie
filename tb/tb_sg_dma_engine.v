`timescale 1ns/1ps
module tb_sg_dma_engine;
    reg clk=0, rst_n=0;
    reg h2c_desc_valid=0, h2c_req_ack=0, h2c_cpl_valid=0, h2c_cpl_last=0;
    wire h2c_desc_ready, h2c_req_valid;
    wire [63:0] h2c_req_addr; wire [10:0] h2c_req_dw_len; wire [7:0] h2c_req_tag;
    wire [31:0] completed_h2c_count, h2c_bytes_transferred;
    integer burst, beat;
    always #4 clk=~clk;

    sg_dma_engine #(.PCIE_DATA_WIDTH(128)) dut (
        .clk(clk), .rst_n(rst_n),
        .h2c_desc_valid(h2c_desc_valid), .h2c_plane0_src(64'h1000),
        .h2c_line_width(16'd256), .h2c_desc_ready(h2c_desc_ready),
        .c2h_desc_valid(1'b0), .c2h_plane0_dst(64'd0), .c2h_line_width(16'd0),
        .c2h_desc_ready(), .h2c_req_valid(h2c_req_valid),
        .h2c_req_addr(h2c_req_addr), .h2c_req_dw_len(h2c_req_dw_len),
        .h2c_req_tag(h2c_req_tag), .h2c_req_ack(h2c_req_ack),
        .c2h_req_valid(), .c2h_req_addr(), .c2h_req_dw_len(), .c2h_req_data(),
        .c2h_req_last(), .c2h_req_data_ready(1'b0), .c2h_req_ack(1'b0),
        .h2c_cpl_valid(h2c_cpl_valid), .h2c_cpl_data(128'd0),
        .h2c_cpl_last(h2c_cpl_last),
        .completed_h2c_count(completed_h2c_count), .completed_c2h_count(),
        .h2c_bytes_transferred(h2c_bytes_transferred), .c2h_bytes_transferred(),
        .h2c_busy(), .c2h_busy());

    task complete_32dw;
        begin
            for (beat=0; beat<9; beat=beat+1) begin
                @(posedge clk);
                h2c_cpl_valid <= 1'b1;
                h2c_cpl_last <= (beat == 8);
            end
            @(posedge clk);
            h2c_cpl_valid <= 1'b0; h2c_cpl_last <= 1'b0;
        end
    endtask

    initial begin
        #20; rst_n=1;
        @(posedge clk); h2c_desc_valid<=1;
        @(posedge clk); h2c_desc_valid<=0;
        for (burst=0; burst<2; burst=burst+1) begin
            wait(h2c_req_valid);
            if (h2c_req_dw_len !== 32 || h2c_req_tag !== 8'h01 ||
                h2c_req_addr !== (64'h1000 + burst*128)) begin
                $display("FAIL: H2C request %0d malformed", burst); $finish;
            end
            @(posedge clk); h2c_req_ack<=1;
            @(posedge clk); h2c_req_ack<=0;
            repeat (3) begin
                @(posedge clk);
                if (h2c_req_valid) begin
                    $display("FAIL: duplicate MRd issued before completion"); $finish;
                end
            end
            complete_32dw();
        end
        wait(completed_h2c_count == 1);
        if (h2c_bytes_transferred !== 256) begin
            $display("FAIL: H2C byte count %0d", h2c_bytes_transferred); $finish;
        end
        $display("SUCCESS: serialized H2C completion accounting passed");
        $finish;
    end
endmodule
