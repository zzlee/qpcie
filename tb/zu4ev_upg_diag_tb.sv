`timescale 1ns / 1ps
module zu4ev_upg_diag_tb;
    reg clk_pcie = 0, clk_pl = 0;
    always #2 clk_pcie = ~clk_pcie;
    always #5 clk_pl = ~clk_pl;
    reg rst_pcie_n = 0, rst_pl_n = 0, clear_toggle = 0;
    reg [12:0] pcie_events = 0;
    reg [13:0] writer_events = 0;
    wire [31:0] pcie_sticky, writer_sticky;
    wire ack;
    reg test_passed = 0;
    zu4ev_upg_diag dut (
        .clk_pcie(clk_pcie), .rst_pcie_n(rst_pcie_n),
        .clk_pl(clk_pl), .rst_pl_n(rst_pl_n),
        .clear_toggle_pl(clear_toggle),
        .pcie_events(pcie_events), .writer_events(writer_events),
        .pcie_sticky_pl(pcie_sticky), .writer_sticky_pl(writer_sticky),
        .clear_ack_pl(ack)
    );
    initial begin
        repeat (4) @(negedge clk_pl);
        rst_pl_n = 1;
        rst_pcie_n = 1;
        repeat (3) @(negedge clk_pcie);
        pcie_events[0] = 1;
        pcie_events[5] = 1;
        @(negedge clk_pcie);
        pcie_events = 0; // 4ns pulse, shorter than one PL clock
        @(negedge clk_pl);
        writer_events[4] = 1;
        @(negedge clk_pl);
        writer_events = 0;
        repeat (5) @(negedge clk_pl);
        if (pcie_sticky !== 32'h21 || writer_sticky !== 32'h10)
            $fatal(1, "lost or corrupted events: pcie=%h writer=%h", pcie_sticky, writer_sticky);

        clear_toggle = 1;
        wait (ack == 1);
        repeat (5) @(negedge clk_pl);
        if (pcie_sticky !== 0 || writer_sticky !== 0)
            $fatal(1, "clear failed pcie=%h writer=%h", pcie_sticky, writer_sticky);
        @(negedge clk_pcie); pcie_events[7] = 1;
        @(negedge clk_pcie); pcie_events = 0;
        repeat (5) @(negedge clk_pl);
        if (pcie_sticky !== 32'h80) $fatal(1, "post-clear event missing");

        clear_toggle = 0;
        wait (ack == 0);
        repeat (5) @(negedge clk_pl);
        if (pcie_sticky !== 0 || writer_sticky !== 0)
            $fatal(1, "second clear failed");
        test_passed = 1;
        $display("TB_PASS: sticky events, PCIe->PL CDC, clear/ack, second canary");
        $finish;
    end
    initial begin #20000; $fatal(1, "watchdog"); end
endmodule
