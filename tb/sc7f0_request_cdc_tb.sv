`timescale 1ns/1ps
module sc7f0_request_cdc_tb;
    reg wr_clk=0, rd_clk=0, wr_run=1;
    always #3.333 if(wr_run) wr_clk=~wr_clk;
    always #4 rd_clk=~rd_clk;
    reg wr_rst_n=0, rd_rst_n=0;
    reg valid=0, eof=0;
    reg [63:0] addr=0;
    reg [10:0] len=0;
    reg [127:0] data=0;
    wire ready, ack, out_valid, out_eof;
    wire [63:0] out_addr;
    wire [10:0] out_len;
    wire [255:0] out_data;
    reg out_ready=0, out_ack=0;
    integer eof_count=0;
    video_req_cdc #(.DATA_WIDTH(256)) dut (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .s_req_valid(valid),
        .s_req_addr(addr), .s_req_dw_len(len), .s_req_data(data),
        .s_req_data_ready(ready), .s_req_ack(ack), .s_frame_done(eof),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .m_req_valid(out_valid),
        .m_req_addr(out_addr), .m_req_dw_len(out_len), .m_req_data(out_data),
        .m_req_data_ready(out_ready), .m_req_ack(out_ack), .m_frame_done(out_eof),
        .m_fifo_empty(), .m_fifo_count());
    function [127:0] word_data(input integer id, input integer n);
        word_data={32'hfeedcafe,32'(id),32'h12345678,32'(n)};
    endfunction
    always @(posedge rd_clk) if(out_eof) eof_count<=eof_count+1;
    task send_packet(input integer id, input integer dw_len);
        integer n;
        begin
            @(negedge wr_clk);
            valid=1; addr=64'h10000000+id*4096; len=dw_len; data=word_data(id,0);
            for(n=0;n<dw_len/4;n=n+1) begin
                @(posedge wr_clk);
                while(!ready) @(posedge wr_clk);
                @(negedge wr_clk);
                data=word_data(id,n+1);
            end
            wait(ack);
            valid=0;
            @(negedge wr_clk); eof=1;
            @(negedge wr_clk); eof=0;
        end
    endtask
    task receive_packet(input integer id, input integer dw_len);
        integer n;
        reg [255:0] held;
        begin
            wait(out_valid);
            @(negedge rd_clk);
            if(out_addr!==64'h10000000+id*4096 || out_len!==dw_len)
                $fatal(1,"Header mismatch for packet %0d",id);
            for(n=0;n<dw_len/8;n=n+1) begin
                held=out_data;
                repeat(2) @(negedge rd_clk);
                if(!out_valid || out_data!==held) $fatal(1,"Payload changed while stalled");
                out_ready=1;
                @(posedge rd_clk);
                if(out_data!=={word_data(id,n*2+1),word_data(id,n*2)})
                    $fatal(1,"Packet %0d word %0d corrupted: %h",id,n,out_data);
                @(negedge rd_clk); out_ready=0;
            end
            out_ack=1;
            @(negedge rd_clk); out_ack=0;
            wait(!out_valid);
        end
    endtask
    task transaction(input integer id, input integer dw_len, input integer expected_eof);
        begin
            fork send_packet(id,dw_len); receive_packet(id,dw_len); join
            wait(eof_count==expected_eof);
            // Spurious ready must not consume the following packet/EOF.
            @(negedge rd_clk); out_ready=1;
            repeat(5) @(negedge rd_clk);
            out_ready=0;
        end
    endtask
    initial begin
        #100; wr_rst_n=1; rd_rst_n=1;
        #500;
        transaction(1,64,1);
        transaction(2,32,2);
        @(negedge wr_clk); wr_run=0;
        #50; wr_rst_n=0; rd_rst_n=0;
        #50; wr_rst_n=1; rd_rst_n=1;
        #200;
        if(out_valid || out_eof) $fatal(1,"Phantom transaction while source clock stopped");
        wr_run=1;
        #500;
        transaction(3,64,3);
        $display("REQUEST_CDC_PASS: 128/256-byte payload, stalls, EOF, reset with stopped source clock");
        $finish;
    end
    initial begin #100000; $fatal(1,"Request CDC timeout"); end
endmodule
