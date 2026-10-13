`timescale 1ns/1ps
// No-slave regression: a multi-byte transfer must hold SCL LOW
// between software commands. Otherwise the slave sees an extra bit.
module IOBUF(inout wire IO, output wire O, input wire I, T);
    assign IO = T ? 1'bz : I;
    assign O = IO;
endmodule

module i2c_byte_gap_tb;
    reg clk=0, rst_n=0;
    always #4 clk=~clk;
    reg [7:0] awaddr=0;
    reg [31:0] wdata=0;
    reg av=0, wv=0;
    wire ar, wr, bv;
    tri1 scl, sda;
    integer starts=0, stops=0;
    always @(negedge sda) if(rst_n && scl) starts=starts+1;
    always @(posedge sda) if(rst_n && scl) stops=stops+1;
    i2c_master_axi #(.DEFAULT_PRESCALER(9)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(av), .s_axil_awready(ar),
        .s_axil_wdata(wdata), .s_axil_wstrb(4'hf),
        .s_axil_wvalid(wv), .s_axil_wready(wr),
        .s_axil_bresp(), .s_axil_bvalid(bv), .s_axil_bready(1'b1),
        .s_axil_araddr(8'd0), .s_axil_arvalid(1'b0), .s_axil_arready(),
        .s_axil_rdata(), .s_axil_rresp(), .s_axil_rvalid(),
        .s_axil_rready(1'b1), .scl_io(scl), .sda_io(sda), .irq()
    );
    task write_reg(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk); awaddr=a; wdata=d; av=1; wv=1;
            fork
                begin wait(ar); @(negedge clk); av=0; end
                begin wait(wr); @(negedge clk); wv=0; end
            join
            wait(bv); @(negedge clk);
            repeat(4) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        write_reg(8'h08, 8'h80);
        write_reg(8'h0c, 8'h54);
        write_reg(8'h10, 8'h90);
        wait(dut.reg_sr_tip); wait(!dut.reg_sr_tip);
        repeat(40) @(negedge clk);
        if(scl !== 1'b0) $fatal(1, "SCL released between bytes: phantom clock");
        if(dut.reg_sr_rxack !== 1'b1) $fatal(1, "No-slave address should NACK");
        write_reg(8'h0c, 8'h55);
        write_reg(8'h10, 8'h90);
        wait(dut.reg_sr_tip); wait(!dut.reg_sr_tip);
        repeat(40) @(negedge clk);
        if(starts != 2 || stops != 0)
            $fatal(1, "Expected initial + repeated START, no STOP: starts=%0d stops=%0d", starts, stops);
        write_reg(8'h10, 8'h40);
        wait(dut.reg_sr_tip); wait(!dut.reg_sr_tip);
        repeat(40) @(negedge clk);
        if(stops != 1 || scl !== 1 || sda !== 1)
            $fatal(1, "Explicit STOP did not release bus");
        $display("TB_PASS: byte gap, no-slave NACK, repeated START, explicit STOP");
        $finish;
    end
    initial begin #100000; $fatal(1, "timeout"); end
endmodule
