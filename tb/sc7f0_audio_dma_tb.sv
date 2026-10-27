`timescale 1ns/1ps
module sc7f0_audio_dma_tb;
    reg clk=0; always #4 clk=~clk;
    reg rst_n=0,start=0,valid=0,ack=0,allow_ack=1;
    reg [31:0] data=0;
    wire ready,req,busy,done,xrun;
    wire [63:0] addr,pts;
    wire [10:0] len;
    wire [127:0] payload;
    wire [31:0] pos;
    reg test_passed=0;
    integer packets=0, periods=0, nextword=0, cycles=0;
    reg held=0; reg [127:0] held_payload;reg [63:0] held_addr;
    audio_stream_engine dut (
        .clk(clk),.rst_n(rst_n),.audio_start(start),.aes3_sync_disable(1'b1),
        .host_buffer_addr(64'h100000),.buffer_size_bytes(32'd64),.period_size_bytes(32'd32),
        .cur_write_ptr(pos),.global_timestamp(64'd0),
        .s_axis_audio_tdata(data),.s_axis_audio_tvalid(valid),.s_axis_audio_tlast(1'b0),
        .s_axis_audio_tready(ready),.c2h_req_valid(req),.c2h_req_addr(addr),
        .c2h_req_dw_len(len),.c2h_req_data(payload),.c2h_req_last(),.c2h_req_ack(ack),
        .audio_busy(busy),.audio_block_done(done),.audio_xrun(xrun),.audio_pts(pts));
    always @(negedge clk) begin
        cycles=cycles+1;
        ack=allow_ack && req && cycles%7==0;
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if(held && (!req || payload!==held_payload || addr!==held_addr))
                $fatal(1,"DMA request changed before retirement (including STOP)");
            if(req && ack) begin
                if(len!=4 || addr!=64'h100000+(packets%4)*16) $fatal(1,"DMA addr/len");
                for(integer i=0;i<4;i=i+1)
                    if(payload[i*32+:32]!==32'h12340000+nextword+i)
                        $fatal(1,"DMA payload %d got %h want %h",nextword+i,payload[i*32+:32],32'h12340000+nextword+i);
                nextword=nextword+4;packets=packets+1;
            end
            if(done) periods=periods+1;
            if(xrun) $fatal(1,"legal backpressure reported as XRUN");
        end
        held=rst_n && req && !ack;held_payload=payload;held_addr=addr;
    end
    task sendword(input integer n);
        begin
            @(negedge clk);data=32'h12340000+n;valid=1;
            do @(posedge clk); while(!ready);
            @(negedge clk);valid=0;
        end
    endtask
    initial begin
        repeat(10) @(negedge clk);rst_n=1;start=1;
        repeat(20) @(negedge clk);
        for(integer i=0;i<128;i=i+1) sendword(i);
        wait(packets==32);repeat(10) @(negedge clk);
        if(periods!=16 || pos!=0) $fatal(1,"period/wrap error periods=%d pos=%d",periods,pos);
        allow_ack=0;
        for(integer i=128;i<132;i=i+1) sendword(i);
        wait(req);@(negedge clk);start=0;
        repeat(25) @(negedge clk);
        if(!req || !busy) $fatal(1,"STOP abandoned owned DMA");
        allow_ack=1;wait(!req);repeat(20) @(negedge clk);
        if(busy || pos!=0) $fatal(1,"STOP did not finish");
        // New session starts at ring offset zero, not the last partial buffer.
        packets=0;nextword=132;start=1;repeat(20) @(negedge clk);
        for(integer i=132;i<136;i=i+1) sendword(i);
        wait(packets==1);repeat(10) @(negedge clk);
        test_passed=1;$display("TB_PASS: audio DMA payload/IRQ/wrap/stall/STOP retirement/restart");$finish;
    end
    initial begin #200000;$fatal(1,"DMA timeout");end
endmodule
