`timescale 1ns/1ps
module spi_icap_clock_tb;
    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk; // 125 MHz PCIe/AXI clock
    reg awvalid = 0, wvalid = 0;
    reg [31:0] wdata = 0;
    wire awready, wready, bvalid;
    wire [1:0] bresp;
    spi_flash_controller dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(8'h20), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(1'b1),
        .s_axil_araddr(8'h24), .s_axil_arvalid(1'b0), .s_axil_arready(),
        .s_axil_rdata(), .s_axil_rresp(), .s_axil_rvalid(), .s_axil_rready(1'b1),
        .spi_cs_n(), .spi_mosi(), .spi_miso(1'b1)
    );
    task automatic command(input [31:0] value);
        begin
            @(negedge clk); awvalid = 1; wvalid = 1; wdata = value;
            do @(posedge clk); while (!awready || !wready);
            @(negedge clk); awvalid = 0; wvalid = 0;
            wait (bvalid);
            if (bresp != 0) $fatal(1, "AXI write response failed");
            repeat (2) @(negedge clk);
        end
    endtask
    initial begin
        repeat (30) @(negedge clk);
        rst_n = 1;
        repeat (8) @(negedge clk);
        command(32'h00000000);
        repeat (8) @(negedge clk);
        if (dut.icap_busy || dut.u_icape2.words != 0) $fatal(1, "Invalid command triggered reload");
        command(32'h52454C4F);
        wait (dut.icap_busy);
        command(32'h52454C4F); // A second command during BUSY must be ignored
        wait (dut.reload_started && !dut.icap_busy);
        repeat (5) @(negedge clk);
        if (dut.u_icape2.words != 8) $fatal(1, "Expected 8 words, got %0d", dut.u_icape2.words);
        command(32'h52454C4F);
        wait (dut.icap_busy);
        wait (dut.reload_started && !dut.icap_busy);
        repeat (5) @(negedge clk);
        if (dut.u_icape2.words != 16) $fatal(1, "Second reload sequence failed");
        $display("TB_PASS: 62.5 MHz ICAP, bit-swapped IPROG words, busy rejection and repeated reload");
        $finish;
    end
    initial begin #5000; $fatal(1, "Timeout"); end
endmodule

// Protocol monitor, not a model of configuration/reboot effects. No FPGA is
// reconfigured by this test. BUFG and STARTUPE2 use the real UNISIM models.
module ICAPE2 #(parameter DEVICE_ID = 32'h0, parameter ICAP_WIDTH = "X32",
                parameter SIM_CFG_FILE_NAME = "NONE") (
    output wire [31:0] O, input wire CLK, CSIB, RDWRB, input wire [31:0] I
);
    assign O = 0;
    integer words = 0;
    realtime previous = 0;
    reg [31:0] expected;
    function automatic [31:0] unswap(input [31:0] v);
        for (integer bit_index = 0; bit_index < 32; bit_index++)
            unswap[bit_index] = v[(bit_index/8)*8 + 7 - (bit_index%8)];
    endfunction
    always @(posedge CLK) begin
        if (previous != 0 && $realtime - previous != 16.0)
            $fatal(1, "ICAP clock period is %0.3f ns, expected 16 ns", $realtime - previous);
        previous = $realtime;
        if (!CSIB) begin
            if (RDWRB !== 0) $fatal(1, "ICAP is not in write mode");
            case (words % 8)
                0: expected = 32'hFFFFFFFF;
                1: expected = 32'hAA995566;
                2: expected = 32'h20000000;
                3: expected = 32'h30020001;
                4: expected = 32'h00000000;
                5: expected = 32'h30008001;
                6: expected = 32'h0000000F;
                7: expected = 32'h20000000;
            endcase
            if (unswap(I) !== expected)
                $fatal(1, "ICAP word %0d: got %h expected %h", words, unswap(I), expected);
            words = words + 1;
        end
    end
endmodule
