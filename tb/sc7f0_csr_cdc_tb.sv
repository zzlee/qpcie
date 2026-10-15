`timescale 1ns / 1ps
module sc7f0_csr_cdc_tb;
    reg test_passed = 0;
    reg clk = 0, rst_n = 0, pcie_clk = 0, pcie_rst_n = 0;
    reg run_pcie = 0;
    integer pcie_half = 4;
    always #5 clk = ~clk;
    always begin
        #(pcie_half);
        if (run_pcie) pcie_clk = ~pcie_clk;
        else pcie_clk = 0;
    end
    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    wire [31:0] ctrl, width, height;
    wire [63:0] ring;
    wire reset_event;
    wire [31:0] upg_ctrl, upg_size;
    wire [63:0] upg_host;
    wire [31:0] w1c_event;
    reg [15:0] status_counter = 0;
    reg xrun = 0;
    always @(posedge pcie_clk or negedge pcie_rst_n)
        if (!pcie_rst_n) status_counter <= 0;
        else status_counter <= status_counter + 1'b1;
    qpcie_csr_reg_space dut (
        .clk(clk), .rst_n(rst_n), .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(4'hf), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .reg_dma_status({status_counter, ~status_counter}),
        .in_requester_id(16'h0300), .in_adev0_xrun(xrun), .in_adev0_running(1'b0),
        .in_dma_upg_write_done(1'b0), .in_dma_upg_bytes_written(32'd17),
        .in_dma_upg_diag_pcie(32'd0), .in_dma_upg_diag_writer(32'd0),
        .in_dma_upg_diag_clear_ack(1'b0), .in_ddr_read_status(32'd0),
        .in_ddr_read_sequence(32'd0), .in_ddr_read_data(128'd0),
        .out_vch0_ctrl(ctrl), .out_vch0_width(width), .out_vch0_height(height),
        .reg_c2h_ring_addr(ring), .out_global_reset_pulse(reset_event),
        .reg_irq_status_w1c(w1c_event),
        .pcie_upg_ctrl(upg_ctrl), .pcie_upg_size(upg_size), .pcie_upg_host_addr(upg_host)
    );

    integer resets = 0, clears = 0;
    always @(posedge pcie_clk) begin
        if (reset_event) resets = resets + 1;
        if (w1c_event == 32'hcafebabe) clears = clears + 1;
        if (upg_ctrl[0] && (upg_size !== 12345 || upg_host !== 64'hfedcba9876543210))
            $fatal(1, "Incoherent upgrade START");
        if (pcie_rst_n && ctrl[0] &&
            (width !== 32'd1280 || height !== 32'd720 || ring !== 64'h1234567887654321))
            $fatal(1, "Incoherent configuration at START: %h %h %h", width, height, ring);
    end

    task write_reg(input [31:0] addr, input [31:0] data);
        integer count;
        begin
            @(negedge clk);
            awaddr = addr; wdata = data; awvalid = 1; wvalid = 1; bready = 0;
            count = 0;
            do begin
                @(posedge clk); count = count + 1;
                if (count > 2000) $fatal(1, "write hung at %h", addr);
            end while (!(awready && wready));
            #1;
            @(negedge clk); awvalid = 0; wvalid = 0; wdata = 32'hdeadbeef;
            if (!bvalid || bresp != 0) $fatal(1, "Missing/failed write response");
            bready = 1;
            @(negedge clk); bready = 0;
        end
    endtask
    task read_reg(input [31:0] addr, output [31:0] value);
        integer count;
        begin
            @(negedge clk); araddr = addr; arvalid = 1; rready = 0;
            count = 0;
            do begin
                @(posedge clk); count = count + 1;
                if (count > 20) $fatal(1, "PS read depends on PCIe at %h", addr);
            end while (!arready);
            #1; value = rdata;
            if (!rvalid || rresp != 0) $fatal(1, "Missing/failed read response");
            @(negedge clk); arvalid = 0; rready = 1;
            @(negedge clk); rready = 0;
        end
    endtask

    reg [31:0] value;
    integer i, old_resets, old_clears;
    initial begin
        #37; rst_n = 1;
        // Independent PS bank with NO PCIe clock.
        read_reg(0, value);
        if (value !== 32'h12abe380) $fatal(1, "standalone magic %h", value);
        read_reg('h4, value);
        if (value !== 32'h26101503) $fatal(1, "candidate hardware version %h", value);
`ifdef SC7F0_DEBUG_ONLY
        read_reg('h8, value);
        if (value !== 32'h80000010) $fatal(1, "debug profile advertises AV hardware: %h", value);
`endif
        write_reg('h108, 1280); write_reg('h10c, 720);
        write_reg('h120, 32'h87654321); write_reg('h124, 32'h12345678);
        write_reg('h14, 1); write_reg('h24, 32'hcafebabe);
        write_reg('h784, 12345);
        read_reg('h784, value);
        if (value !== 12345) $fatal(1, "standalone upgrade CSR");
        read_reg('h108, value);
        if (value !== 1280) $fatal(1, "standalone config");
        run_pcie = 1; #19; pcie_rst_n = 1;
        #3000;
        if (width !== 1280 || height !== 720 || ring !== 64'h1234567887654321)
            $fatal(1, "initial snapshot missing");
        if (resets || clears) $fatal(1, "replayed offline events");
        write_reg('h100, 1);
        #1000;
        if (!ctrl[0]) $fatal(1, "START missing");
        write_reg('h100, 0);
        #1000;
        // Slow, unrelated clock: force FIFO full and write backpressure.
        pcie_half = 75;
        old_resets = resets; old_clears = clears;
        for (i = 0; i < 80; i = i + 1) begin
            write_reg('h14, 1);
            write_reg('h24, 32'hcafebabe);
        end
        #10000;
        if (resets - old_resets != 80 || clears - old_clears != 80)
            $fatal(1, "lost/duplicated events: reset=%0d clear=%0d", resets-old_resets, clears-old_clears);
        pcie_half = 4;
        write_reg('h7a0, 32'h76543210); write_reg('h7a4, 32'hfedcba98);
        write_reg('h780, 1);
        #3000;
        if (!upg_ctrl[0]) $fatal(1, "Upgrade START missing");
        write_reg('h780, 0);
        for (i = 0; i < 100; i = i + 1) begin
            read_reg('h28, value);
            if (value[31:16] !== ~value[15:0]) $fatal(1, "torn status %h", value);
        end
        // Pulse telemetry survives skipped/full status snapshots.
        @(negedge pcie_clk); xrun = 1;
        @(negedge pcie_clk); xrun = 0;
        #3000; read_reg('h504, value);
        if (!value[1]) $fatal(1, "lost xrun pulse");
        write_reg('h504, 2); #3000; read_reg('h504, value);
        if (value[1]) $fatal(1, "stale xrun was relatched");
        // Clock disappears WITHOUT link/reset changing. PS still responds.
        old_resets = resets;
        run_pcie = 0;
        // Fill the FIFO while the stale link indication is still HIGH; the
        // source watchdog must release a blocked write without another clock.
        for (i = 0; i < 32; i = i + 1) write_reg('h14, 1);
        #5000;
        read_reg(0, value);
        if (value !== 32'h12abe380) $fatal(1, "stopped-clock magic");
        write_reg('h108, 1920);
        write_reg('h14, 1);
        run_pcie = 1;
        #4000;
        if (width !== 1920) $fatal(1, "clock-recovery snapshot missing");
        if (resets != old_resets) $fatal(1, "clock-recovery replayed reset");
        read_reg('h504, value);
        if (value[1]) $fatal(1, "clock recovery generated a phantom xrun");
        pcie_rst_n = 0; #100; pcie_rst_n = 1;
        #4000; read_reg('h504, value);
        if (value[1]) $fatal(1, "PCIe reset generated a phantom xrun");
        // PS reset clears the destination configuration even if PCIe stays up.
        rst_n = 0; #100; rst_n = 1; #4000;
        if (width !== 1920 || ctrl !== 0) $fatal(1, "PS reset/config initialization");
        test_passed = 1;
        $display("TB_PASS sc7f0 CSR CDC: standalone, ordering, backpressure, events, coherent status, clock recovery");
        $finish;
    end
    initial begin #2000000; $fatal(1, "global timeout"); end
endmodule
