`timescale 1ns / 1ps

// Unit test for the pl_clk0 -> pcie_user_clk upgrade-START synchronizer
// added in 26101204 (custom_pcie_dma_top.v). The 1203 failure was: START
// latched in the CSR, zero bytes moved, DMA_DONE never set, because the
// pcie-domain edge detector sampled the pl_clk0 CSR bit with no sync.
// This TB replicates the exact sync block with asynchronous clocks and
// requires: exactly one pcie-domain pulse per START, correct parameter
// capture, and clean deassert.
module zu4ev_upg_cdc_tb;
    reg clk_pl = 0;    // 100 MHz
    reg clk_pcie = 0;  // 250 MHz
    always #5 clk_pl = ~clk_pl;
    always #2 clk_pcie = ~clk_pcie;

    reg rst_n = 0;

    // Driven in pl_clk0 domain (CSR model)
    reg        csr_start = 0;
    reg [31:0] csr_size = 0;
    reg [63:0] csr_host = 0;

    // ---- exact copy of the 1204 sync block (pcie domain) ----
    reg  [1:0]  upg_start_sync;
    reg  [31:0] upg_size_pcie;
    reg  [63:0] upg_host_addr_pcie;
    always @(posedge clk_pcie or negedge rst_n) begin
        if (!rst_n) begin
            upg_start_sync     <= 2'b00;
            upg_size_pcie      <= 32'd0;
            upg_host_addr_pcie <= 64'd0;
        end else begin
            upg_start_sync <= {upg_start_sync[0], csr_start};
            if (upg_start_sync == 2'b01) begin
                upg_size_pcie      <= csr_size;
                upg_host_addr_pcie <= csr_host;
            end
        end
    end
    wire upg_active_pcie = upg_start_sync[1];
    wire upg_start_pulse = (upg_start_sync == 2'b01);
    // ---- end copy ----

    integer pulse_count = 0;
    always @(posedge clk_pcie) begin
        if (rst_n && upg_start_pulse)
            pulse_count = pulse_count + 1;
    end

    initial begin
        repeat (4) @(negedge clk_pl);
        rst_n = 1;
        repeat (10) @(negedge clk_pl);

        // Program params, then assert START asynchronously (as the driver
        // does over BAR0 MMIO: SIZE/HOST first, then CTRL).
        @(negedge clk_pl);
        csr_size = 32'd4096;
        csr_host = 64'h0000_1234_5678_9ABC;
        @(negedge clk_pl);
        csr_start = 1'b1;

        // Hold START long (driver holds until DMA_DONE, up to 3 s).
        repeat (300) @(negedge clk_pl);

        if (pulse_count !== 1)
            $fatal(1, "expected exactly 1 synced pulse, got %0d", pulse_count);
        if (upg_active_pcie !== 1'b1)
            $fatal(1, "active level not held while START asserted");
        if (upg_size_pcie !== 32'd4096)
            $fatal(1, "size capture mismatch: %h", upg_size_pcie);
        if (upg_host_addr_pcie !== 64'h0000_1234_5678_9ABC)
            $fatal(1, "host addr capture mismatch: %h", upg_host_addr_pcie);

        // Deassert: active must drop, no extra pulse.
        @(negedge clk_pl);
        csr_start = 1'b0;
        repeat (100) @(negedge clk_pl);
        if (pulse_count !== 1)
            $fatal(1, "spurious pulse after deassert: %0d", pulse_count);
        if (upg_active_pcie !== 1'b0)
            $fatal(1, "active level stuck after deassert");

        // Second transfer with new params (reusability across chunks).
        @(negedge clk_pl);
        csr_size = 32'd2097152;
        csr_host = 64'h0000_DEAD_BEEF_0001;
        @(negedge clk_pl);
        csr_start = 1'b1;
        repeat (300) @(negedge clk_pl);
        if (pulse_count !== 2)
            $fatal(1, "second START produced %0d total pulses", pulse_count);
        if (upg_size_pcie !== 32'd2097152 || upg_host_addr_pcie !== 64'h0000_DEAD_BEEF_0001)
            $fatal(1, "second capture mismatch: %h %h", upg_size_pcie, upg_host_addr_pcie);
        @(negedge clk_pl);
        csr_start = 1'b0;
        repeat (50) @(negedge clk_pl);

        $display("TB_PASS: upg START CDC pulse-once, param capture, clean deassert");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Global simulation watchdog timeout");
    end
endmodule
