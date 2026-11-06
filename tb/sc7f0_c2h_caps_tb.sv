`timescale 1ns/1ps
module sc7f0_c2h_caps_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,arvalid=0,rready=0;
    reg [11:0] araddr=0;
    wire arready,rvalid; wire [31:0] rdata;
    axil_reg_space #(.C_VERSION(32'h26102802)) dut(
        .clk(clk),.rst_n(rst_n),.cdc_write_ready(1'b1),
        .s_axil_awaddr(12'd0),.s_axil_awvalid(1'b0),
        .s_axil_wdata(32'd0),.s_axil_wstrb(4'd0),.s_axil_wvalid(1'b0),
        .s_axil_bready(1'b1),.s_axil_araddr(araddr),.s_axil_arvalid(arvalid),
        .s_axil_arready(arready),.s_axil_rdata(rdata),
        .s_axil_rvalid(rvalid),.s_axil_rready(rready));
    task read_check(input [11:0] addr,input [31:0] expected);
      begin
        @(negedge clk); araddr=addr; arvalid=1;
        do @(posedge clk); while(arready!==1);
        @(negedge clk); arvalid=0;
        wait(rvalid===1); #1;
        if(rdata!==expected) $fatal(1,"CSR %h got %h expected %h",addr,rdata,expected);
        @(negedge clk); rready=1; @(posedge clk); @(negedge clk); rready=0;
      end
    endtask
    initial begin
        repeat(3) @(posedge clk); @(negedge clk); rst_n=1;
        read_check(12'h004,32'h26102802);
        read_check(12'h008,32'h1001011f);
        $display("SC7F0_C2H_CAPS_PASS"); $finish;
    end
    initial begin #20000; $fatal(1,"timeout"); end
endmodule
