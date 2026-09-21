// ============================================================================
// Testbench: tb_axil_reg_space
// Description: Unit testbench for axil_reg_space module testing Version, Git Commit,
//              Timestamp, and Hardware Capabilities Read-Only registers.
// ============================================================================

`timescale 1ns / 1ps

module tb_axil_reg_space;

    reg        clk;
    reg        rst_n;

    reg [31:0] s_axil_awaddr;
    reg        s_axil_awvalid;
    wire       s_axil_awready;
    reg [31:0] s_axil_wdata;
    reg [3:0]  s_axil_wstrb;
    reg        s_axil_wvalid;
    wire       s_axil_wready;
    wire [1:0] s_axil_bresp;
    wire       s_axil_bvalid;
    reg        s_axil_bready;

    reg [31:0] s_axil_araddr;
    reg        s_axil_arvalid;
    wire       s_axil_arready;
    wire [31:0] s_axil_rdata;
    wire [1:0] s_axil_rresp;
    wire       s_axil_rvalid;
    reg        s_axil_rready;

    wire [31:0] reg_dma_ctrl;
    reg  [31:0] reg_dma_status;
    wire [63:0] reg_h2c_ring_addr;
    wire [15:0] reg_h2c_ring_size;
    wire [15:0] reg_h2c_tail_ptr;
    wire [63:0] reg_c2h_ring_addr;
    wire [15:0] reg_c2h_ring_size;
    wire [15:0] reg_c2h_tail_ptr;
    wire [31:0] reg_irq_ctrl;
    wire [31:0] reg_irq_status;
    wire [31:0] irq_w1c_obs;
    wire [31:0] reg_pacer_ctrl, reg_slice_height, reg_video_ctrl;
    reg  [31:0] completed_h2c_count;
    reg  [31:0] completed_c2h_count;
    reg  [15:0] h2c_head_stub;
    reg  [15:0] c2h_head_stub;
    reg         w1c_pulsed;
    always @(posedge clk) begin
        if (irq_w1c_obs === 32'h00000003)
            w1c_pulsed <= 1'b1;
    end

    // Instantiate uut
    axil_reg_space uut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .reg_dma_ctrl(reg_dma_ctrl),
        .reg_dma_status(reg_dma_status),
        .reg_h2c_ring_addr(reg_h2c_ring_addr),
        .reg_h2c_ring_size(reg_h2c_ring_size),
        .reg_h2c_tail_ptr(reg_h2c_tail_ptr),
        .reg_c2h_ring_addr(reg_c2h_ring_addr),
        .reg_c2h_ring_size(reg_c2h_ring_size),
        .reg_c2h_tail_ptr(reg_c2h_tail_ptr),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status(reg_irq_status),
        .reg_irq_status_w1c(irq_w1c_obs),
        .reg_h2c_head_ptr(h2c_head_stub),
        .reg_c2h_head_ptr(c2h_head_stub),
        .reg_pacer_ctrl(reg_pacer_ctrl),
        .reg_slice_height(reg_slice_height),
        .reg_video_ctrl(reg_video_ctrl),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count)
    );

    always #5 clk = ~clk;

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axil_awaddr  <= addr;
            s_axil_awvalid <= 1;
            s_axil_wdata   <= data;
            s_axil_wstrb   <= 4'hF;
            s_axil_wvalid  <= 1;
            wait(s_axil_awready && s_axil_wready);
            @(posedge clk);
            s_axil_awvalid <= 0;
            s_axil_wvalid  <= 0;
            wait(s_axil_bvalid);
            @(posedge clk);
            s_axil_bready  <= 1;
            @(posedge clk);
            s_axil_bready  <= 0;
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s_axil_araddr  <= addr;
            s_axil_arvalid <= 1;
            wait(s_axil_arready);
            @(posedge clk);
            s_axil_arvalid <= 0;
            wait(s_axil_rvalid);
            data = s_axil_rdata;
            @(posedge clk);
            s_axil_rready  <= 1;
            @(posedge clk);
            s_axil_rready  <= 0;
        end
    endtask

    reg [31:0] read_val;

    initial begin
        clk = 0;
        rst_n = 0;
        s_axil_awaddr = 0;
        s_axil_awvalid = 0;
        s_axil_wdata = 0;
        s_axil_wstrb = 0;
        s_axil_wvalid = 0;
        s_axil_bready = 0;
        s_axil_araddr = 0;
        s_axil_arvalid = 0;
        s_axil_rready = 0;
        reg_dma_status = 0;
        completed_h2c_count = 0;
        completed_c2h_count = 0;
        h2c_head_stub = 0;
        c2h_head_stub = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Write DMA_CTRL (0x00) = 0x00000001...", $time);
        axil_write(32'h00, 32'h00000001);
        axil_read(32'h00, read_val);
        $display("[%0t] Read DMA_CTRL: 0x%h", $time, read_val);

        #20;
        $display("[%0t] Test 2: Read Version Register (0x30)...", $time);
        axil_read(32'h30, read_val);
        $display("[%0t] Read REG_VERSION_ID (0x30): 0x%h (Expect 0x02010001)", $time, read_val);

        $display("[%0t] Test 3: Read Git Commit Hash Register (0x34)...", $time);
        axil_read(32'h34, read_val);
        $display("[%0t] Read REG_GIT_COMMIT_HASH (0x34): 0x%h (Expect 0x01D6A9C5)", $time, read_val);

        $display("[%0t] Test 4: Read Build Timestamp Register (0x38)...", $time);
        axil_read(32'h38, read_val);
        $display("[%0t] Read REG_BUILD_TIMESTAMP (0x38): 0x%h (Expect 0x20260812)", $time, read_val);

        $display("[%0t] Test 5: Read Hardware Capabilities Register (0x3C)...", $time);
        axil_read(32'h3C, read_val);
        $display("[%0t] Read REG_HARDWARE_CAPS (0x3C): 0x%h (Expect 0x0004040F)", $time, read_val);

        $display("[%0t] Test 6: Toggle Video Pipeline Reset (0x80)...", $time);
        axil_write(32'h80, 32'h00000001);
        axil_read(32'h80, read_val);
        if (read_val !== 32'h00000001 || reg_video_ctrl !== 32'h00000001) begin
            $display("FAIL: VIDEO_CTRL set/readback mismatch");
            $fatal(1);
        end
        axil_write(32'h80, 32'h00000000);
        axil_read(32'h80, read_val);
        if (read_val !== 32'h00000000 || reg_video_ctrl !== 32'h00000000) begin
            $display("FAIL: VIDEO_CTRL clear/readback mismatch");
            $fatal(1);
        end

        // ---- P0-1 golden freeze: audio addr alias 0x48/0x4C == 0x100/0x104 ----
        $display("[%0t] Test 7: Audio addr alias 0x48/0x4C == 0x100/0x104 ...", $time);
        axil_write(32'h48, 32'hDEADBEEF);
        axil_write(32'h4C, 32'h00001234);
        axil_read(32'h100, read_val);
        if (read_val !== 32'hDEADBEEF) begin
            $display("FAIL: alias lo 0x48 -> 0x100 mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h104, read_val);
        if (read_val !== 32'h00001234) begin
            $display("FAIL: alias hi 0x4C -> 0x104 mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // ---- P0-1 golden freeze: RING_CFG tail packing + 0x40/0x44 {tail,head} ----
        $display("[%0t] Test 8: RING_CFG tail + PTR {tail,head} packing ...", $time);
        h2c_head_stub = 16'd7;
        c2h_head_stub = 16'd9;
        axil_write(32'h10, 32'h00050080); // H2C tail=5 size=128
        axil_read(32'h40, read_val);
        if (read_val !== 32'h00050007) begin
            $display("FAIL: H2C PTR packing mismatch: 0x%h (expect 0x00050007)", read_val);
            $fatal(1);
        end
        axil_write(32'h1C, 32'h00030080); // C2H tail=3 size=128
        axil_read(32'h44, read_val);
        if (read_val !== 32'h00030009) begin
            $display("FAIL: C2H PTR packing mismatch: 0x%h (expect 0x00030009)", read_val);
            $fatal(1);
        end

        // ---- P0-1 golden freeze: IRQ W1C is a single-cycle pulse ----
        $display("[%0t] Test 9: IRQ W1C pulse (not sticky) ...", $time);
        w1c_pulsed = 1'b0;
        axil_write(32'h24, 32'h00000003);
        #30;
        if (w1c_pulsed !== 1'b1) begin
            $display("FAIL: W1C pulse never asserted");
            $fatal(1);
        end
        if (irq_w1c_obs !== 32'h00000000) begin
            $display("FAIL: W1C mask sticky (expect auto-clear): 0x%h", irq_w1c_obs);
            $fatal(1);
        end

        // ---- P0-1 golden freeze: COMPLETED counter mapping ----
        $display("[%0t] Test 10: COMPLETED counter mapping ...", $time);
        completed_h2c_count = 32'd41;
        completed_c2h_count = 32'd17;
        #10;
        axil_read(32'h28, read_val);
        if (read_val !== 32'd41) begin
            $display("FAIL: COMPLETED_H2C mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h2C, read_val);
        if (read_val !== 32'd17) begin
            $display("FAIL: COMPLETED_C2H mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // ---- P0-2 golden freeze: DMA_CTRL reset == 0 (mode-bit default) ----
        // NOTE: future dual-map transition will use DMA_CTRL bit3 as NEW_MAP
        // select. Reset MUST stay 0 so old drivers (bits 0-2 only) always land
        // on the old map, even on new hardware.
        $display("[%0t] Test 11: DMA_CTRL reset default + CAPS new-map absent ...", $time);
        axil_write(32'h00, 32'h00000000);
        axil_read(32'h00, read_val);
        if (read_val !== 32'h00000000) begin
            $display("FAIL: DMA_CTRL not zero after clear: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h3C, read_val);
        if ((read_val & 32'h00000010) !== 32'h00000000) begin
            $display("FAIL: CAPS bit4 (NEW_MAP) set before Phase 2: 0x%h", read_val);
            $fatal(1);
        end

        // ---- P1-1 validation: 12-bit address decode, new region zero-return & non-aliasing ----
        $display("[%0t] Test 12: New region offsets return 0 on read ...", $time);
        axil_read(32'h200, read_val);
        if (read_val !== 32'h00000000) begin
            $display("FAIL: Offset 0x200 read returned non-zero: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h500, read_val);
        if (read_val !== 32'h00000000) begin
            $display("FAIL: Offset 0x500 read returned non-zero: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h900, read_val);
        if (read_val !== 32'h00000000) begin
            $display("FAIL: Offset 0x900 read returned non-zero: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'hFFC, read_val);
        if (read_val !== 32'h00000000) begin
            $display("FAIL: Offset 0xFFC read returned non-zero: 0x%h", read_val);
            $fatal(1);
        end

        $display("[%0t] Test 13: New region writes are ignored and do NOT alias to legacy regs ...", $time);
        // Set DMA_CTRL (0x000) to known pattern
        axil_write(32'h000, 32'h00000005);
        axil_read(32'h000, read_val);
        if (read_val !== 32'h00000005) begin
            $display("FAIL: DMA_CTRL write pattern mismatch: 0x%h", read_val);
            $fatal(1);
        end
        // In legacy 9-bit decode, writing 0x200 or 0x400 or 0x800 aliased to 0x000!
        axil_write(32'h200, 32'hA5A5A5A5);
        axil_write(32'h400, 32'h5A5A5A5A);
        axil_write(32'h800, 32'h12345678);
        axil_read(32'h000, read_val);
        if (read_val !== 32'h00000005) begin
            $display("FAIL: Offset 0x200/0x400/0x800 aliased to 0x000! DMA_CTRL corrupted: 0x%h", read_val);
            $fatal(1);
        end

        $display("[%0t] Test 14: Debug write address captures 12 bits ...", $time);
        axil_write(32'h160, 32'h00000003); // Audio loopback ctrl at 0x160
        axil_read(32'h06C, read_val);      // REG_DEBUG_LAST_WADDR
        if (read_val !== 32'h00000160) begin
            $display("FAIL: Debug write address not 0x160 (truncated?): 0x%h", read_val);
            $fatal(1);
        end

        #30;
        $display("[%0t] SUCCESS: axil_reg_space Version & Control Test Completed!", $time);
        $finish;
    end

endmodule
