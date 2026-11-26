`timescale 1ns/1ps
module sc7f0_flip_output_tb;
    reg clk=0; always #1.667 clk=!clk;
    reg resetn=0,bv=0,ov=0,ready=0,en=1;
    reg [31:0] cookie=0;
    wire br,orr,v,sof; wire [31:0] tag;
    sc7f0_alpha_blend_2ppc dut(.clk(clk),.rst_n(resetn),
        .blend_enable(en),.alpha_force_opaque(1'b0),.unlock(1'b0),
        .ovl_cookie(cookie),.out_cookie(tag),
        .s_b_axis_tvalid(bv),.s_b_axis_tready(br),.s_b_axis_tdata(64'h1234),
        .s_b_axis_tuser(1'b1),.s_b_axis_tlast(1'b0),
        .s_o_axis_tvalid(ov),.s_o_axis_tready(orr),.s_o_axis_tdata(64'h5678),
        .s_o_axis_tuser(1'b1),.s_o_axis_tlast(1'b0),
        .m_axis_tvalid(v),.m_axis_tready(ready),.m_axis_tuser(sof));
    integer count=0; reg [31:0] expected;
    always @(posedge clk) if(v && ready && sof) begin
        if(tag!==expected) $fatal(1,"expected %h got %h",expected,tag);
        count=count+1;
    end
    task transfer(input bit overlay,input bit base,input [31:0] id);
      begin
        @(negedge clk); while(!br || !orr) @(negedge clk);
        ov=overlay; bv=base; cookie=id;
        @(negedge clk); ov=0; bv=0;cookie=~id;
      end
    endtask
    task accept(input [31:0] id);
      begin
        while(!v) @(negedge clk);
        repeat(15) begin @(negedge clk);if(!v || !sof || tag!==id) $fatal;end
        expected=id;ready=1;@(negedge clk);ready=0;
      end
    endtask
    initial begin
        repeat(15) @(negedge clk);resetn=1;repeat(20) @(negedge clk);
        transfer(0,1,0);accept(0);
        transfer(1,0,32'h987655aa);
        repeat(30) begin @(negedge clk);if(v) $fatal;end
        transfer(0,1,0);accept(32'h987655aa);
        en=0;transfer(1,1,32'h12345678);accept(0);
        if(count!=3) $fatal;
        $display("FLIP_OUTPUT_PASS: base only, no base, tagged paired SOF, stall stability, disabled blend");
        $finish;
    end
    initial begin #20000;$fatal(1,"watchdog");end
endmodule
