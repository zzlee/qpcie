// ============================================================================
// Testbench: tb_interrupt_ctrl
// Description: Comprehensive unit testbench for interrupt_ctrl module.
//              Verifies:
//                1. Legacy H2C and C2H completions.
//                2. In-flight burst completion accumulation (150MHz scenario).
//                3. Error priority preemption over normal completions.
//                4. Three-Level Hierarchy (MSI -> IRQ_TOP -> CH_IRQ) and W1C ordering.
//                5. Same-cycle event priority over W1C clear.
//                6. 8-bit saturating pending counter limit (saturation at 255).
// ============================================================================

`timescale 1ns / 1ps

module tb_interrupt_ctrl;

    reg        clk;
    reg        rst_n;

    // Legacy register interface
    reg  [31:0] reg_irq_ctrl;
    reg  [31:0] reg_irq_status_w1c;
    wire [31:0] reg_irq_status;

    // Three-Level Hierarchy
    wire [31:0] irq_top_status;
    reg  [31:0] irq_top_status_w1c;

    wire [3:0]  vch0_irq_status;
    reg  [3:0]  vch0_irq_status_w1c;
    reg         vch0_irq_en;

    wire [3:0]  vch1_irq_status;
    reg  [3:0]  vch1_irq_status_w1c;
    reg         vch1_irq_en;

    wire [3:0]  vch2_irq_status;
    reg  [3:0]  vch2_irq_status_w1c;
    reg         vch2_irq_en;

    wire [3:0]  vch3_irq_status;
    reg  [3:0]  vch3_irq_status_w1c;
    reg         vch3_irq_en;

    wire [1:0]  adev0_irq_status;
    reg  [1:0]  adev0_irq_status_w1c;
    reg         adev0_irq_en;

    // Triggers
    reg        h2c_done;
    reg        c2h_done;
    reg  [3:0] v_done_ch;
    reg  [3:1] h2c_done_ch;
    reg  [3:0] a_done_irq;

    // Errors
    reg  [3:0] v_overflow_ch;
    reg  [3:0] v_desc_err_ch;
    reg  [3:0] v_fifo_err_ch;
    reg  [3:0] a_xrun_ch;
    reg        global_err;

    // MSI Handshake
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
        .irq_top_status(irq_top_status),
        .irq_top_status_w1c(irq_top_status_w1c),
        .vch0_irq_status(vch0_irq_status),
        .vch0_irq_status_w1c(vch0_irq_status_w1c),
        .vch0_irq_en(vch0_irq_en),
        .vch1_irq_status(vch1_irq_status),
        .vch1_irq_status_w1c(vch1_irq_status_w1c),
        .vch1_irq_en(vch1_irq_en),
        .vch2_irq_status(vch2_irq_status),
        .vch2_irq_status_w1c(vch2_irq_status_w1c),
        .vch2_irq_en(vch2_irq_en),
        .vch3_irq_status(vch3_irq_status),
        .vch3_irq_status_w1c(vch3_irq_status_w1c),
        .vch3_irq_en(vch3_irq_en),
        .adev0_irq_status(adev0_irq_status),
        .adev0_irq_status_w1c(adev0_irq_status_w1c),
        .adev0_irq_en(adev0_irq_en),
        .h2c_done(h2c_done),
        .c2h_done(c2h_done),
        .v_done_ch(v_done_ch),
        .h2c_done_ch(h2c_done_ch),
        .a_done_irq(a_done_irq),
        .v_overflow_ch(v_overflow_ch),
        .v_desc_err_ch(v_desc_err_ch),
        .v_fifo_err_ch(v_fifo_err_ch),
        .a_xrun_ch(a_xrun_ch),
        .global_err(global_err),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        clk = 0;
        rst_n = 0;
        reg_irq_ctrl = 32'h0000_0003; // Enable both H2C and C2H in legacy
        reg_irq_status_w1c = 0;
        irq_top_status_w1c = 0;
        vch0_irq_status_w1c = 0;
        vch0_irq_en = 1'b1;
        vch1_irq_status_w1c = 0;
        vch1_irq_en = 1'b1;
        vch2_irq_status_w1c = 0;
        vch2_irq_en = 1'b1;
        vch3_irq_status_w1c = 0;
        vch3_irq_en = 1'b1;
        adev0_irq_status_w1c = 0;
        adev0_irq_en = 1'b1;

        h2c_done = 0;
        c2h_done = 0;
        v_done_ch = 4'd0;
        h2c_done_ch = 3'd0;
        a_done_irq = 4'd0;

        v_overflow_ch = 4'd0;
        v_desc_err_ch = 4'd0;
        v_fifo_err_ch = 4'd0;
        a_xrun_ch = 4'd0;
        global_err = 0;

        irq_req_ack = 0;
        usr_irq_ack = 0;

        #20;
        rst_n = 1;
        #10;

        // ====================================================================
        // Test 1: Trigger H2C Done interrupt & verify legacy status
        // ====================================================================
        $display("[%0t] Test 1: Trigger H2C Done interrupt...", $time);
        @(posedge clk);
        h2c_done <= 1;
        @(posedge clk);
        h2c_done <= 0;

        wait(irq_req_valid);
        if (irq_req_code !== 8'h01) begin
            $display("FAIL: Test 1 expected H2C code 0x01, got 0x%h", irq_req_code);
            $fatal(1);
        end
        if (reg_irq_status[0] !== 1'b1 || irq_top_status[7] !== 1'b1) begin
            $display("FAIL: Test 1 status bit not set: legacy=0x%h top=0x%h", reg_irq_status, irq_top_status);
            $fatal(1);
        end

        @(posedge clk);
        irq_req_ack <= 1;
        @(posedge clk);
        irq_req_ack <= 0;
        @(posedge clk);
        reg_irq_status_w1c <= 32'h1;
        irq_top_status_w1c <= 32'h80;
        @(posedge clk);
        reg_irq_status_w1c <= 0;
        irq_top_status_w1c <= 0;
        #1;
        if (reg_irq_status[0] !== 1'b0 || irq_top_status[7] !== 1'b0) begin
            $display("FAIL: Test 1 IRQ status W1C did not clear");
            $fatal(1);
        end
        $display("[%0t] PASS: Test 1 H2C Done verified.", $time);

        // ====================================================================
        // Test 2: Back-to-back C2H done while MSI in flight
        // ====================================================================
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
            $display("FAIL: Test 2 expected C2H code 0x02, got 0x%h", irq_req_code);
            $fatal(1);
        end
        repeat (4) @(posedge clk);
        @(posedge clk);
        irq_req_ack <= 1;
        @(posedge clk);
        irq_req_ack <= 0;

        // First MSI retired; the queued completion must raise a new MSI
        wait(irq_req_valid);
        if (irq_req_code !== 8'h02) begin
            $display("FAIL: Test 2 queued completion lost (code=0x%h)", irq_req_code);
            $fatal(1);
        end
        @(posedge clk);
        irq_req_ack <= 1;
        @(posedge clk);
        irq_req_ack <= 0;
        repeat (6) @(posedge clk);
        if (irq_req_valid !== 1'b0) begin
            $display("FAIL: Test 2 unexpected extra MSI request");
            $fatal(1);
        end
        $display("[%0t] PASS: Test 2 Back-to-back C2H verified.", $time);

        // ====================================================================
        // Test 3: Burst completion injection while MSI in flight (150MHz scenario)
        // Inject 5 completions back-to-back; verify exact 5 MSIs generated
        // ====================================================================
        #30;
        $display("[%0t] Test 3: In-flight burst completion injection (5 consecutive frames)...", $time);
        @(posedge clk);
        v_done_ch[0] <= 1;  // First completion triggers MSI
        @(posedge clk);
        v_done_ch[0] <= 0;
        wait(irq_req_valid);

        // While MSI is in-flight (waiting for ack), inject 4 more completions
        repeat (2) @(posedge clk);
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            v_done_ch[0] <= 1;
        end
        @(posedge clk);
        v_done_ch[0] <= 0;

        // Now retire all 5 MSIs one by one
        for (i = 0; i < 5; i = i + 1) begin
            wait(irq_req_valid);
            if (irq_req_code !== 8'h02) begin
                $display("FAIL: Test 3 burst MSI %0d code mismatch: 0x%h", i, irq_req_code);
                $fatal(1);
            end
            @(posedge clk);
            usr_irq_ack <= 1;
            @(posedge clk);
            usr_irq_ack <= 0;
            @(posedge clk);
        end

        repeat (5) @(posedge clk);
        if (irq_req_valid !== 1'b0) begin
            $display("FAIL: Test 3 unexpected extra MSI after 5 burst frames");
            $fatal(1);
        end
        $display("[%0t] PASS: Test 3 Burst in-flight completions verified (all 5 preserved).", $time);

        // ====================================================================
        // Test 4: Strict priority arbitration: Error > Video Frame Done
        // ====================================================================
        #30;
        $display("[%0t] Test 4: Error priority preemption over normal completions...", $time);
        @(posedge clk);
        // Inject both Video frame_done and FIFO overflow error in same cycle
        v_done_ch[0]    <= 1;
        v_overflow_ch[0] <= 1;
        @(posedge clk);
        v_done_ch[0]    <= 0;
        v_overflow_ch[0] <= 0;

        wait(irq_req_valid);
        if (irq_req_code !== 8'hE0) begin
            $display("FAIL: Test 4 expected Error code 0xE0, got 0x%h", irq_req_code);
            $fatal(1);
        end
        $display("[%0t]   First MSI is Error (0xE0) as expected.", $time);

        @(posedge clk);
        usr_irq_ack <= 1;
        @(posedge clk);
        usr_irq_ack <= 0;
        @(posedge clk);

        // Next MSI must be the normal video frame done (0x02)
        wait(irq_req_valid);
        if (irq_req_code !== 8'h02) begin
            $display("FAIL: Test 4 expected Video code 0x02 following error, got 0x%h", irq_req_code);
            $fatal(1);
        end
        $display("[%0t]   Second MSI is Video CH0 (0x02).", $time);
        @(posedge clk);
        usr_irq_ack <= 1;
        @(posedge clk);
        usr_irq_ack <= 0;
        @(posedge clk);
        $display("[%0t] PASS: Test 4 Error priority arbitration verified.", $time);

        // ====================================================================
        // Test 5: Three-Level Hierarchy & W1C Ordering
        // Level 3 (0x170) -> Level 2 (0x18)
        // ====================================================================
        #30;
        $display("[%0t] Test 5: Three-Level Hierarchy & W1C Clearing Sequence...", $time);
        // Clean out any lingering status
        @(posedge clk);
        vch0_irq_status_w1c <= 4'hF;
        irq_top_status_w1c <= 32'hFFFF_FFFF;
        reg_irq_status_w1c <= 32'hFFFF_FFFF;
        @(posedge clk);
        vch0_irq_status_w1c <= 4'h0;
        irq_top_status_w1c <= 32'h0;
        reg_irq_status_w1c <= 32'h0;
        #1;
        if (vch0_irq_status !== 4'd0 || irq_top_status !== 32'd0) begin
            $display("FAIL: Test 5 initialization clear failed: vch0=0x%h top=0x%h", vch0_irq_status, irq_top_status);
            $fatal(1);
        end

        // Trigger Frame Done on CH0
        @(posedge clk);
        v_done_ch[0] <= 1;
        @(posedge clk);
        v_done_ch[0] <= 0;
        #1;
        // Verify Level 3 (0x170) and Level 2 (0x18)
        if (vch0_irq_status[0] !== 1'b1) begin
            $display("FAIL: Test 5 Level 3 vch0_irq_status[0] not set");
            $fatal(1);
        end
        if (irq_top_status[0] !== 1'b1) begin
            $display("FAIL: Test 5 Level 2 irq_top_status[0] not set");
            $fatal(1);
        end

        // Step 1: Clear branch / channel status first
        @(posedge clk);
        vch0_irq_status_w1c[0] <= 1;
        @(posedge clk);
        vch0_irq_status_w1c[0] <= 0;
        #1;
        if (vch0_irq_status[0] !== 1'b0) begin
            $display("FAIL: Test 5 Level 3 vch0_irq_status[0] did not clear");
            $fatal(1);
        end
        if (irq_top_status[0] !== 1'b1) begin
            $display("FAIL: Test 5 Level 2 prematurely cleared before W1C");
            $fatal(1);
        end

        // Step 2: Clear Level 2 TOP status
        @(posedge clk);
        irq_top_status_w1c[0] <= 1;
        @(posedge clk);
        irq_top_status_w1c[0] <= 0;
        #1;
        if (irq_top_status[0] !== 1'b0) begin
            $display("FAIL: Test 5 Level 2 irq_top_status[0] did not clear");
            $fatal(1);
        end
        // Retire the MSI
        wait(irq_req_valid);
        @(posedge clk);
        usr_irq_ack <= 1;
        @(posedge clk);
        usr_irq_ack <= 0;
        $display("[%0t] PASS: Test 5 Three-Level Hierarchy & W1C sequence verified.", $time);

        // ====================================================================
        // Test 6: Same-cycle event priority over W1C clear
        // ====================================================================
        #30;
        $display("[%0t] Test 6: Same-cycle event priority over W1C clear...", $time);
        @(posedge clk);
        v_done_ch[0]           <= 1;
        vch0_irq_status_w1c[0] <= 1; // Attempt to clear in same cycle as new event
        @(posedge clk);
        v_done_ch[0]           <= 0;
        vch0_irq_status_w1c[0] <= 0;
        #1;
        if (vch0_irq_status[0] !== 1'b1) begin
            $display("FAIL: Test 6 same-cycle event did not win over W1C clear");
            $fatal(1);
        end
        wait(irq_req_valid);
        @(posedge clk);
        usr_irq_ack <= 1;
        @(posedge clk);
        usr_irq_ack <= 0;
        @(posedge clk);
        vch0_irq_status_w1c[0] <= 1;
        irq_top_status_w1c[0]  <= 1;
        @(posedge clk);
        vch0_irq_status_w1c[0] <= 0;
        irq_top_status_w1c[0]  <= 0;
        $display("[%0t] PASS: Test 6 Same-cycle event priority verified.", $time);

        // ====================================================================
        // Test 7: 8-bit saturating pending counter limits
        // ====================================================================
        #30;
        $display("[%0t] Test 7: Saturating pending counter limits (saturation at 255)...", $time);
        // Disable interrupt so we can flood the pending counter
        vch0_irq_en <= 0;
        reg_irq_ctrl[1] <= 0;
        @(posedge clk);
        for (i = 0; i < 300; i = i + 1) begin
            v_done_ch[0] <= 1;
            @(posedge clk);
        end
        v_done_ch[0] <= 0;
        @(posedge clk);
        if (uut.vch0_pending !== 8'hFF) begin
            $display("FAIL: Test 7 expected saturation at 255, got %0d", uut.vch0_pending);
            $fatal(1);
        end
        $display("[%0t]   Pending counter successfully saturated at 255.", $time);

        // Re-enable and verify it decrements without underflow
        vch0_irq_en <= 1;
        @(posedge clk);
        wait(irq_req_valid);
        @(posedge clk);
        usr_irq_ack <= 1;
        @(posedge clk);
        usr_irq_ack <= 0;
        @(posedge clk);
        if (uut.vch0_pending !== 8'd254) begin
            $display("FAIL: Test 7 expected 254 after 1 ACK, got %0d", uut.vch0_pending);
            $fatal(1);
        end
        $display("[%0t] PASS: Test 7 Saturating pending counter verified.", $time);

        #50;
        $display("================================================================");
        $display(" 🎉 ALL P4-1 INTERRUPT CONTROLLER TESTS PASSED SUCCESSFULLY!   ");
        $display("================================================================");
        $finish;
    end

endmodule
