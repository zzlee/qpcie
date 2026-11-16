// ---------------------------------------------------------------------------
// tb_sc7f0_pcie_ext_tag_enable.sv
//
// Narrow fixture for rtl/sc7f0_pcie_ext_tag_enable.v only.  Not a test suite,
// and it says nothing about FPGA fit.  It proves, against a modelled
// configuration space, that the block:
//
//   * drives cfg_mgmt_addr as a DOUBLEWORD index (config byte 0x34 must be read
//     as doubleword 0x0D and never as 0x34),
//   * takes the capability pointer from the LOW byte of doubleword 0x0D
//     (bits [15:8] is byte 0x35 and is booby-trapped here),
//   * publishes Device Control bit 8 (PCI_EXP_DEVCTL_EXT_TAG 0x0100) and never
//     bit 4 (PCI_EXP_DEVCTL_RELAX_EN 0x0010),
//   * requires Device Capability bit 5 (PCI_EXP_DEVCAP_EXT_TAG) before it will
//     report an enable at all,
//   * re-reads periodically, so a host that enables Extended Tags after
//     enumeration is seen with no software action,
//   * clears on link down, and fails closed on an unanswered read, a zero
//     capability pointer and a looping capability chain,
//   * only ever reads PF0.
//
// Any failed check ends the run with a non-zero exit status.
//
// Harness note: waiting is written as an inline `while (!signal)` loop at each
// site.  A task argument of type `input bit cond` is sampled once when the task
// is called, so a shared wait_until(...) task silently tested a stale value -
// the first version of this file did exactly that and reported eight bogus
// failures.  Nets cannot be passed by reference, so there is no task here.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_sc7f0_pcie_ext_tag_enable;

    localparam integer CLK = 8;

    reg clk = 0;
    reg rst_n = 0;
    reg user_lnk_up = 0;

    always #(CLK/2) clk = ~clk;

    // ------------------------------------------------------------------ model
    reg [31:0] cfg [0:1023];
    reg        model_ignore = 0;      // case J: core stops answering
    integer    fail_count = 0;
    integer    checks = 0;

    wire [9:0]  mgmt_addr;
    wire [7:0]  mgmt_func;
    wire        mgmt_read;
    reg  [31:0] mgmt_rdata = 0;
    reg         mgmt_done  = 0;

    reg         read_pending = 0;
    reg         accepted     = 0;   // one transaction per asserted mgmt_read
    reg  [9:0]  addr_latched = 0;   // address captured when the request was taken
    integer     delay = 0;
    integer     resp = 2;
    reg  [9:0]  addr_seen [0:511];
    integer     n_addr_seen = 0;
    reg  [7:0]  func_seen_max = 8'd0;

    wire ext_tag_enable, devcap_ext_tag, walk_done, walk_overflow, mgmt_timeout;

    // Small timers so the fixture runs quickly.  The defaults in the module
    // (1 ms tick, 2^16 cycle timeout at 125 MHz) are the hardware values; only
    // the parameters are scaled here.
    sc7f0_pcie_ext_tag_enable #(
        .REFRESH_SHIFT (10),
        .MGMT_TO_SHIFT (8),
        .WALK_BOUND    (8'd8)
    ) dut (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .user_lnk_up              (user_lnk_up),
        .cfg_mgmt_addr            (mgmt_addr),
        .cfg_mgmt_function_number (mgmt_func),
        .cfg_mgmt_read            (mgmt_read),
        .cfg_mgmt_read_data       (mgmt_rdata),
        .cfg_mgmt_read_write_done (mgmt_done),
        .ext_tag_enable           (ext_tag_enable),
        .devcap_ext_tag           (devcap_ext_tag),
        .walk_done                (walk_done),
        .walk_overflow            (walk_overflow),
        .mgmt_timeout             (mgmt_timeout)
    );

    // Doubleword-addressed configuration space model.  Handshake rules, because
    // a sloppy responder can hide real timing bugs:
    //   * the address is LATCHED when a request is accepted and the answer is
    //     taken from the latched doubleword, never from the live port when the
    //     DUT may already have changed it;
    //   * a request held high counts as ONE transaction: after answering, the
    //     model waits until cfg_mgmt_read deasserts before accepting another,
    //     so no phantom read can be charged to the same assertion;
    //   * there is no write path at all, mirroring the DUT having no write
    //     ports.
    always @(posedge clk) begin
        if (!rst_n) begin
            read_pending <= 0;
            accepted     <= 0;
            mgmt_done    <= 0;
            mgmt_rdata   <= 32'd0;
        end else begin
            mgmt_done <= 1'b0;
            if (!mgmt_read)
                accepted <= 1'b0;
            if (mgmt_read && !accepted) begin
                accepted     <= 1'b1;
                read_pending <= 1'b1;
                addr_latched <= mgmt_addr;
                delay        <= 0;
                if (n_addr_seen < 512) begin
                    addr_seen[n_addr_seen] = mgmt_addr;
                    n_addr_seen = n_addr_seen + 1;
                end
                if (mgmt_func > func_seen_max) func_seen_max = mgmt_func;
            end else if (read_pending && !model_ignore) begin
                if (delay == resp) begin
                    read_pending <= 1'b0;
                    mgmt_done    <= 1'b1;
                    mgmt_rdata   <= cfg[addr_latched];
                end else begin
                    delay <= delay + 1;
                end
            end
        end
    end

    // ----------------------------------------------------------------- checks
    task fail(input string msg);
        begin
            $display("FIXTURE_FAIL: %s", msg);
            fail_count = fail_count + 1;
        end
    endtask

    task good(input string msg);
        begin
            checks = checks + 1;
            $display("ok: %s", msg);
        end
    endtask

    task reset_model_space;
        integer i;
        begin
            for (i = 0; i < 1024; i = i + 1) cfg[i] = 32'd0;
            n_addr_seen   = 0;
            func_seen_max = 8'd0;
            model_ignore  = 0;

            // byte 0x34 is the low byte of doubleword 0x0D.  Byte 0x35
            // (bits [15:8]) is a booby trap that also decodes as a usable PCIe
            // capability, so reading the wrong field yields an answer instead
            // of an obvious crash.
            cfg[10'h00D] = {16'h0000, 8'h99, 8'h40};

            // first capability at byte 0x40 (doubleword 0x10): power
            // management, next pointer 0x60, so the walk has to take a step
            cfg[10'h010] = {16'h0001, 8'h60, 8'h01};

            // PCI Express capability at byte 0x60 (doubleword 0x18), the last one
            cfg[10'h018] = {16'h0002, 8'h00, 8'h10};
            // Device Capability, byte 0x64: Extended Tags supported (bit 5)
            cfg[10'h019] = 32'h0000_0020;
            // Device Control, byte 0x68: each case sets bits [15:0]
            cfg[10'h01A] = {16'h0000, 16'h0000};

            // trap chain, reachable only by reading bits [15:8] of 0x0D:
            // byte 0x99 -> doubleword 0x26, says DISABLED
            cfg[10'h026] = {16'h0002, 8'h00, 8'h10};
            cfg[10'h027] = 32'h0000_0020;
            cfg[10'h028] = {16'h0000, 16'h0000};
        end
    endtask

    task apply_reset;
        begin
            rst_n       = 0;
            user_lnk_up = 0;
            repeat (4) @(posedge clk);
            rst_n       = 1;
            repeat (2) @(posedge clk);
            user_lnk_up = 1;
            @(posedge clk);
        end
    endtask

    integer saw_0D, saw_34, i, n;

    initial begin : main
        // ---------------------------------------------------------- case A
        // Device Control bit 8 set: the only case that may report enabled.
        reset_model_space; apply_reset;
        cfg[10'h01A] = {16'h0000, 16'h0100};
        n = 0;
        while (!walk_done && n < 400) begin @(posedge clk); n = n + 1; end
        if (!walk_done)         fail("A: walk did not complete");
        if (ext_tag_enable !== 1'b1)  fail("A: Device Control bit 8 must authorise extended tags");
        if (devcap_ext_tag !== 1'b1)  fail("A: Device Capability bit 5 was never observed");
        good("A: DevCtl[8] authorises, DevCap[5] observed");

        saw_0D = 0; saw_34 = 0;
        for (i = 0; i < n_addr_seen; i = i + 1) begin
            if (addr_seen[i] == 10'h00D) saw_0D = 1;
            if (addr_seen[i] == 10'h034) saw_34 = 1;
        end
        if (!saw_0D)              fail("A: cfg_mgmt_addr must be a doubleword index; doubleword 0x0D (byte 0x34) was never read");
        if (saw_34)               fail("A: 0x34 was used as the address, i.e. cfg_mgmt_addr was treated as a byte address");
        if (func_seen_max != 8'd0) fail("A: read of a non-zero function number");
        good("A: doubleword addressing (0x0D seen, 0x34 never), PF0 only");

        // ---------------------------------------------------------- case B
        // Relaxed Ordering only (bit 4): the mistake that would have
        // authorised the overlay plane for entirely the wrong reason.
        reset_model_space; apply_reset;
        cfg[10'h01A] = {16'h0000, 16'h0010};
        n = 0;
        while (!walk_done && n < 400) begin @(posedge clk); n = n + 1; end
        if (!walk_done)                fail("B: walk did not complete");
        if (ext_tag_enable !== 1'b0) fail("B: Relaxed Ordering is not the Extended Tag enable");
        else good("B: DevCtl[4] alone does not authorise");

        // ---------------------------------------------------------- case C
        reset_model_space; apply_reset;
        cfg[10'h01A] = {16'h0000, 16'h0000};
        n = 0;
        while (!walk_done && n < 400) begin @(posedge clk); n = n + 1; end
        if (!walk_done)                fail("C: walk did not complete");
        if (ext_tag_enable !== 1'b0) fail("C: an all-zero Device Control must not authorise");
        else good("C: DevCtl 0x0000 does not authorise");

        // ---------------------------------------------------------- case D
        // Host enables Extended Tags some time after enumeration.
        reset_model_space; apply_reset;
        cfg[10'h01A] = {16'h0000, 16'h0000};
        n = 0;
        while (!walk_done && n < 400) begin @(posedge clk); n = n + 1; end
        if (!walk_done)                fail("D: initial walk did not complete");
        if (ext_tag_enable !== 1'b0) fail("D: enabled before the host set it");
        cfg[10'h01A] = {16'h0000, 16'h0100};   // host writes Device Control
        n = 0;
        while (!ext_tag_enable && n < 4000) begin @(posedge clk); n = n + 1; end
        if (!ext_tag_enable) fail("D: refresh never observed a later host enable");
        else good("D: a later host enable is picked up with no software action");

        // ---------------------------------------------------------- case E
        // Link drops: the answer goes back to disabled immediately.
        user_lnk_up = 0;
        repeat (2) @(posedge clk);
        if (ext_tag_enable !== 1'b0) fail("E: link down did not clear the enable");
        if (walk_done !== 1'b0)      fail("E: link down did not invalidate the walk");
        else good("E: link down clears immediately");
        user_lnk_up = 1;

        // ---------------------------------------------------------- case F
        // No capability list at all.
        reset_model_space; apply_reset;
        cfg[10'h00D] = 32'd0;
        repeat (80) @(posedge clk);
        if (ext_tag_enable !== 1'b0) fail("F: a zero capability pointer must not authorise");
        if (walk_done !== 1'b0)      fail("F: the walk must not report success");
        else good("F: capability pointer 0 fails closed");

        // ---------------------------------------------------------- case G
        // Capability chain that loops: the bounded walk must stop, stay off and
        // say why.
        reset_model_space; apply_reset;
        cfg[10'h010] = {16'h0001, 8'h40, 8'h01};   // next points back at 0x40
        cfg[10'h01A] = {16'h0000, 16'h0100};
        n = 0;
        while (!walk_overflow && n < 2000) begin @(posedge clk); n = n + 1; end
        if (!walk_overflow)          fail("G: the bounded walk did not report overflow");
        if (ext_tag_enable !== 1'b0) fail("G: a looping capability chain must not authorise");
        else good("G: looping capability chain fails closed with overflow");

        // ---------------------------------------------------------- case H
        // The function does not support Extended Tags at all, so nothing may be
        // authorised no matter what Device Control says.
        reset_model_space; apply_reset;
        cfg[10'h019] = 32'h0000_0000;              // DevCap bit 5 clear
        cfg[10'h01A] = {16'h0000, 16'h0100};       // DevCtl claims enabled
        repeat (200) @(posedge clk);
        if (devcap_ext_tag !== 1'b0) fail("H: Device Capability must not report support when the bit is clear");
        if (ext_tag_enable !== 1'b0) fail("H: enabled although Device Capability says unsupported");
        else good("H: DevCap.Ext_Tag clear keeps it disabled");

        // ---------------------------------------------------------- case I
        // The wrong capability-pointer field leads to the trap chain, which
        // says DISABLED; the real chain says ENABLED.  Only a correct low-byte
        // pointer produces the enabled answer.
        reset_model_space; apply_reset;
        cfg[10'h028] = {16'h0000, 16'h0000};       // trap: disabled
        cfg[10'h01A] = {16'h0000, 16'h0100};       // real: enabled
        n = 0;
        while (!walk_done && n < 400) begin @(posedge clk); n = n + 1; end
        if (!walk_done)                fail("I: walk did not complete");
        if (ext_tag_enable !== 1'b1) fail("I: the capability pointer must come from bits [7:0] of doubleword 0x0D");
        else good("I: pointer taken from the low byte of doubleword 0x0D");

        // ---------------------------------------------------------- case J
        // The core never answers: no enable, and the timeout is visible.
        reset_model_space; apply_reset;
        cfg[10'h01A] = {16'h0000, 16'h0100};
        model_ignore = 1;
        n = 0;
        while (!mgmt_timeout && n < 600) begin @(posedge clk); n = n + 1; end
        if (!mgmt_timeout)           fail("J: an unanswered read did not time out");
        if (ext_tag_enable !== 1'b0) fail("J: an unanswered read must not authorise");
        else good("J: cfg_mgmt timeout fails closed");
        model_ignore = 0;

        // ----------------------------------------------------------- result
        repeat (10) @(posedge clk);
        if (fail_count == 0) begin
            $display("FIXTURE_PASS sc7f0_pcie_ext_tag_enable: %0d checks, %0d config reads observed",
                     checks, n_addr_seen);
            $finish;
        end else begin
            $display("FIXTURE_RESULT %0d check(s) failed", fail_count);
            $fatal(1, "sc7f0_pcie_ext_tag_enable fixture failed");
        end
    end

    // global runaway guard
    initial begin
        #400000;
        $display("FIXTURE_FAIL: simulation timeout");
        $fatal(1, "sc7f0_pcie_ext_tag_enable fixture timed out");
    end

endmodule
