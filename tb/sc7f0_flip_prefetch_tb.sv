`timescale 1ns/1ps
module sc7f0_flip_prefetch_tb;
    reg p=0,m=0,r=0,valid=0,sof=0,take=0;
    always #4 p=!p; always #1.667 m=!m;
    reg [31:0] cookie=0;
    reg [127:0] data=0;
    wire ready,out_v,out_sof;
    wire [31:0] out_cookie;
    sc7f0_ovl_pull_prefetch #(.ACTIVE_BEATS_PER_LINE(4),.ACTIVE_LINES(1),
                              .URAM_FIFO_DEPTH(16384)) dut (
        .pcie_clk(p),.pcie_rst_n(r),.mem_clk(m),.mem_rst_n(r),
        .host_ovl_enable(1'b0),.host_ovl_go(1'b0),.host_src_addr(64'd0),
        .host_xfer_bytes(32'd0),.host_max_bytes_per_req(16'd0),
        .ing_busy(1'b0),.ing_quarantined(1'b0),.ing_done_pulse(1'b0),
        .ing_abort_evt(1'b0),.base_vblank_p_m(1'b0),
        .s_cookie(cookie),.s_axis_tvalid(valid),.s_axis_tready(ready),
        .s_axis_tuser(sof),.s_axis_tdata(data),.m_cookie(out_cookie),
        .m_o_axis_tvalid(out_v),.m_o_axis_tready(take),.m_o_axis_tuser(out_sof));
    integer rx=0,stalls=0,beat=0,n;
    always @(posedge m) if(r) begin
        if(sof && valid && !ready) stalls=stalls+1;
        if(out_v && take) begin
            if(out_sof!==(beat%4==0)) $fatal(1,"SOF beat %d",beat);
            if(out_sof) begin rx=rx+1;
                if(out_cookie!==(32'h80000+rx)) $fatal(1,"cookie %h, rx=%d",out_cookie,rx);
            end
            beat=beat+1;
        end
    end
    task push(input bit first,input [31:0] id);
        begin
            @(negedge m);sof=first;valid=1;cookie=id;data={4{id}};
            @(posedge m);while(!ready) @(posedge m);
            @(negedge m);valid=0;sof=0;
        end
    endtask
    initial begin
        repeat(40) @(negedge m);r=1;repeat(40) @(negedge m);
        fork
            for(n=1;n<=40;n=n+1) begin push(1,32'h80000+n);push(0,~n);end
            begin
                repeat(80) @(negedge m);
                while(beat<160) begin take=$urandom_range(0,3)!=0;@(negedge m);end
            end
        join
        if(rx!=40 || stalls==0) $fatal;
        $display("FLIP_PREFETCH_PASS tags=%0d beats=%0d full_stalls=%0d",rx,beat,stalls);
        $finish;
    end
    initial begin #25000;$fatal(1,"timeout beat=%d",beat);end
endmodule
