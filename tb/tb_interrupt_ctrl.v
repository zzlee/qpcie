// ============================================================================
// Testbench: tb_interrupt_ctrl
// Description: Unit testbench for interrupt_ctrl module
// ============================================================================

`timescale 1ns / 1ps

module tb_interrupt_ctrl;

    reg        clk;
    reg        rst_n;

    reg  [31:0] reg_irq_ctrl;
    reg  [31:0] reg_irq_status_w1c;
    wire [31:0] reg_irq_status;

    reg        h2c_done;
    reg        c2h_done;

    wire       irq_req_valid;
    wire [7:0] irq_req_code;
    reg        irq_req_ack;

    wire       usr_irq_req;
    reg        usr_irq_ack;

    // Instantiate uut
    interrupt_ctrl uut (
        .clk(clk),
        .rst_n(rst_n),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status_w1c(reg_irq_status_w1c),
        .reg_irq_status(reg_irq_status),
        .h2c_done(h2c_done),
        .c2h_done(c2h_done),
        .v_done_ch(4'd0),
        .h2c_done_ch(3'd0),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        reg_irq_ctrl = 32'h0000_0003; // Enable both H2C and C2H IRQ
        reg_irq_status_w1c = 0;
        h2c_done = 0;
        c2h_done = 0;
        irq_req_ack = 0;
        usr_irq_ack = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Trigger H2C Done interrupt...", $time);
        @(posedge clk);
        h2c_done <= 1;
        @(posedge clk);
        h2c_done <= 0;

        wait(irq_req_valid);
        $display("[%0t] Interrupt Controller requested MSI Msg Code: 0x%h Status: 0x%h", $time, irq_req_code, reg_irq_status);

        @(posedge clk);
        irq_req_ack <= 1;
        @(posedge clk);
        irq_req_ack <= 0;
        @(posedge clk);
        reg_irq_status_w1c <= 32'h1;
        @(posedge clk);
        reg_irq_status_w1c <= 0;
        #1;
        if (reg_irq_status[0] !== 1'b0) begin
            $display("FAIL: IRQ status W1C did not clear");
            $finish;
        end

        #30;
        $display("[%0t] Test 2: Back-to-back C2H done while MSI in flight...", $time);
        @(posedge clk);
        c2h_done <= 1;
        @(posedge clk);
        c2h_done <= 1;      // second completion while first MSI still pending
        @(posedge clk);
        c2h_done <= 0;

        wait(irq_req_valid);
        if (irq_req_code !== 8'h02) begin
            $display("FAIL: expected C2H code 0x02, got 0x%h", irq_req_code);
            $finish;
        end
        // Hold usr_irq_ack low across the next completion event.
        repeat (4) @(posedge clk);
        @(posedge clk);
        irq_req_ack <= 1;
        @(posedge clk);
        irq_req_ack <= 0;
        // First MSI retired; the queued completion must raise a new MSI.
        wait(irq_req_valid);
        if (irq_req_code !== 8'h02) begin
            $display("FAIL: queued completion lost (code=0x%h)", irq_req_code);
            $finish;
        end
        @(posedge clk);
        irq_req_ack <= 1;
        @(posedge clk);
        irq_req_ack <= 0;
        repeat (6) @(posedge clk);
        if (irq_req_valid !== 1'b0) begin
            $display("FAIL: unexpected extra MSI request");
            $finish;
        end

        #30;
        $display("[%0t] SUCCESS: interrupt_ctrl Test Completed!", $time);
        $finish;
    end

endmodule
