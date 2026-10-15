`timescale 1ns/1ps
module qpcie_debug_mailbox_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0;
    reg [12:0] awaddr=0, araddr=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;
    reg [31:0] wdata=0; reg [3:0] wstrb=15;
    wire [31:0] rdata; wire [1:0] bresp,rresp;
    qpcie_debug_mailbox dut(clk,rst_n,awaddr,awvalid,awready,
        wdata,wstrb,wvalid,wready,bresp,bvalid,bready,
        araddr,arvalid,arready,rdata,rresp,rvalid,rready);
    task write_word(input [12:0] a,input [31:0] d,input bit data_first,
                    input [3:0] strobe,input [1:0] expected);
        begin
            @(negedge clk); awaddr=a; wdata=d; wstrb=strobe;
            if (data_first) begin
                wvalid=1; do @(posedge clk); while (!wready);
                @(negedge clk); wvalid=0; repeat(3) @(negedge clk);
                awvalid=1; do @(posedge clk); while (!awready);
                @(negedge clk); awvalid=0;
            end else begin
                awvalid=1; do @(posedge clk); while (!awready);
                @(negedge clk); awvalid=0; repeat(3) @(negedge clk);
                wvalid=1; do @(posedge clk); while (!wready);
                @(negedge clk); wvalid=0;
            end
            wait(bvalid); repeat(3) begin
                @(negedge clk); if (!bvalid || bresp!==expected) $fatal(1,"B unstable");
            end
            bready=1; @(negedge clk); bready=0;
        end
    endtask
    task read_word(input [12:0] a,input [31:0] d,input [1:0] resp);
        begin
            @(negedge clk); araddr=a; arvalid=1;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid=0;
            wait(rvalid); repeat(3) begin
                @(negedge clk);
                if (!rvalid || rresp!==resp || (resp==0 && rdata!==d))
                    $fatal(1,"read %x expected %x got %x resp %x",a,d,rdata,rresp);
            end
            rready=1; @(negedge clk); rready=0;
        end
    endtask
    initial begin
        #1000000; $fatal(1,"timeout");
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        read_word(0,32'h53434442,0); read_word(4,1,0); read_word(8,0,0);
        write_word(8,1,0,15,0); read_word(8,1,0);
        write_word(13'h400,32'haabbccdd,1,15,0);
        write_word(13'h1ffc,32'h76543210,0,15,0);
        read_word(13'h400,32'haabbccdd,0); read_word(13'h1ffc,32'h76543210,0);
        write_word(0,0,0,15,2); read_word(0,32'h53434442,0);
        write_word(13'h400,0,1,1,2); read_word(13'h400,32'haabbccdd,0);
        write_word(13'h401,0,0,15,2); read_word(13'h401,0,2);
        @(negedge clk); rst_n=0; repeat(3) @(negedge clk); rst_n=1;
        read_word(8,0,0); read_word(13'h400,32'haabbccdd,0);
        $display("TB_PASS: debug mailbox AXI split AW/W, backpressure, bounds, reset");
        $finish;
    end
endmodule
