// ============================================================================
// Testbench: tb_axil_reg_space
// Description: Unit testbench for axil_reg_space module testing canonical v3.0.0
//              Phase 6 specification:
//              - Unconditional New Map active on reset
//              - Global Block (0x0000 - 0x00FF): Magic ID, Version v3.0.0, Caps, Mirrors
//              - Video CH0 Block (0x0100 - 0x01FF): Dimensions, Ring0/1, Counters, IRQ
//              - Audio DEV0 Block (0x0500 - 0x05FF): ALSA registers, Ring0, Xrun, IRQ
//              - Debug Block (0x0900 - 0x09FF): Loopback, Pacer, Patterns, Observability
//              - Unmapped Address Isolation & Legacy Non-Aliasing
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

`ifdef QPCIe_single_rgb24_path
    localparam [31:0] EXP_CAPS = 32'h0001_041F;
`else
    localparam [31:0] EXP_CAPS = 32'h0004_041F;
`endif
    localparam [31:0] EXP_VERSION = 32'h0300_0000;
    localparam [31:0] EXP_MAGIC   = 32'h12AB_E380;

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
    reg  [31:0] tb_irq_top_status;
    wire [31:0] tb_irq_top_status_w1c;
    reg  [3:0]  tb_vch0_irq_status;
    wire [3:0]  tb_vch0_irq_status_w1c;
    wire        tb_vch0_irq_en;
    reg         vch0_w1c_pulsed;
    reg         top_w1c_pulsed;

    // Audio DEV0 TB Signals
    reg         tb_adev0_running;
    reg         tb_adev0_xrun;
    reg  [31:0] tb_adev0_position;
    reg  [1:0]  tb_adev0_irq_status;
    wire [1:0]  tb_adev0_irq_status_w1c;
    wire        tb_adev0_xrun_inject;
    wire [31:0] tb_adev0_ctrl;
    wire [31:0] tb_adev0_rate;
    wire [31:0] tb_adev0_period_bytes;
    wire [31:0] tb_adev0_buffer_bytes;
    wire [63:0] tb_adev0_ring0_base;
    wire [31:0] tb_adev0_ring0_cfg;
    reg         adev0_w1c_pulsed;
    reg         adev0_inject_pulsed;

    always @(posedge clk) begin
        if (tb_vch0_irq_status_w1c === 4'h1)
            vch0_w1c_pulsed <= 1'b1;
        if (tb_irq_top_status_w1c === 32'h0000_0001)
            top_w1c_pulsed <= 1'b1;
        if (tb_adev0_irq_status_w1c === 2'b11)
            adev0_w1c_pulsed <= 1'b1;
        if (tb_adev0_xrun_inject)
            adev0_inject_pulsed <= 1'b1;
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
        .completed_c2h_count(completed_c2h_count),
        .in_irq_top_status(tb_irq_top_status),
        .out_irq_top_status_w1c(tb_irq_top_status_w1c),
        .in_vch0_irq_status(tb_vch0_irq_status),
        .out_vch0_irq_status_w1c(tb_vch0_irq_status_w1c),
        .out_vch0_irq_en(tb_vch0_irq_en),
        .out_adev0_ctrl(tb_adev0_ctrl),
        .out_adev0_rate(tb_adev0_rate),
        .out_adev0_period_bytes(tb_adev0_period_bytes),
        .out_adev0_buffer_bytes(tb_adev0_buffer_bytes),
        .out_adev0_ring0_base(tb_adev0_ring0_base),
        .out_adev0_ring0_cfg(tb_adev0_ring0_cfg),
        .in_adev0_running(tb_adev0_running),
        .in_adev0_xrun(tb_adev0_xrun),
        .in_adev0_position(tb_adev0_position),
        .in_adev0_irq_status(tb_adev0_irq_status),
        .out_adev0_irq_status_w1c(tb_adev0_irq_status_w1c),
        .out_adev0_xrun_inject(tb_adev0_xrun_inject)
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
        tb_irq_top_status = 0;
        tb_vch0_irq_status = 0;
        vch0_w1c_pulsed = 0;
        top_w1c_pulsed = 0;
        tb_adev0_running = 0;
        tb_adev0_xrun = 0;
        tb_adev0_position = 0;
        tb_adev0_irq_status = 0;
        adev0_w1c_pulsed = 0;
        adev0_inject_pulsed = 0;

        #20;
        rst_n = 1;
        #10;

        // =====================================================================
        // Test 1: Canonical Global Identification Registers (0x0000 - 0x0010)
        // =====================================================================
        $display("[%0t] Test 1: Canonical Global Identification Registers...", $time);
        
        // 0x000: Magic Device ID
        axil_read(32'h000, read_val);
        $display("  [0x000] Magic Device ID: 0x%08X (Expect: 0x%08X)", read_val, EXP_MAGIC);
        if (read_val !== EXP_MAGIC) begin
            $display("FAIL: Magic Device ID mismatch: 0x%h (Expect 0x%h)", read_val, EXP_MAGIC);
            $fatal(1);
        end

        // 0x004: Version ID (v3.0.0)
        axil_read(32'h004, read_val);
        $display("  [0x004] Version ID: 0x%08X (Expect: 0x%08X)", read_val, EXP_VERSION);
        if (read_val !== EXP_VERSION) begin
            $display("FAIL: Version ID mismatch: 0x%h (Expect 0x%h)", read_val, EXP_VERSION);
            $fatal(1);
        end

        // 0x008: Hardware Capabilities
        axil_read(32'h008, read_val);
        $display("  [0x008] Hardware Caps: 0x%08X (Expect: 0x%08X)", read_val, EXP_CAPS);
        if (read_val !== EXP_CAPS) begin
            $display("FAIL: Hardware Caps mismatch: 0x%h (Expect 0x%h)", read_val, EXP_CAPS);
            $fatal(1);
        end

        // 0x00C: Git Commit Hash
        axil_read(32'h00C, read_val);
        $display("  [0x00C] Git Commit Hash: 0x%08X", read_val);
        if (read_val !== 32'h01D6_A9C5) begin
            $display("FAIL: Git Commit Hash mismatch: 0x%h (Expect 0x01D6A9C5)", read_val);
            $fatal(1);
        end

        // 0x010: Build Timestamp
        axil_read(32'h010, read_val);
        $display("  [0x010] Build Timestamp: 0x%08X", read_val);
        if (read_val !== 32'h2026_0821) begin
            $display("FAIL: Build Timestamp mismatch: 0x%h (Expect 0x20260821)", read_val);
            $fatal(1);
        end

        // =====================================================================
        // Test 2: Backward-Compatibility Mirrors (0x030 - 0x03C)
        // =====================================================================
        $display("[%0t] Test 2: Backward-Compatibility Mirrors (0x030 - 0x03C)...", $time);
        axil_read(32'h030, read_val);
        if (read_val !== EXP_VERSION) begin
            $display("FAIL: Mirror 0x030 Version mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h034, read_val);
        if (read_val !== 32'h01D6_A9C5) begin
            $display("FAIL: Mirror 0x034 Git Hash mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h038, read_val);
        if (read_val !== 32'h2026_0821) begin
            $display("FAIL: Mirror 0x038 Timestamp mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h03C, read_val);
        if (read_val !== EXP_CAPS) begin
            $display("FAIL: Mirror 0x03C Caps mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // =====================================================================
        // Test 3: Write to DMA_CTRL at 0x000 & Video Ctrl at 0x080
        // =====================================================================
        $display("[%0t] Test 3: Write DMA_CTRL (0x00) and Video Reset (0x80)...", $time);
        axil_write(32'h000, 32'h0000_0001);
        if (reg_dma_ctrl !== 32'h0000_0001) begin
            $display("FAIL: reg_dma_ctrl internal signal mismatch: 0x%h", reg_dma_ctrl);
            $fatal(1);
        end
        // Read at 0x000 must STILL return MAGIC ID (read is read-only Magic ID)
        axil_read(32'h000, read_val);
        if (read_val !== EXP_MAGIC) begin
            $display("FAIL: 0x000 read was overwritten by DMA_CTRL write: 0x%h", read_val);
            $fatal(1);
        end

        // Video control at 0x080
        axil_write(32'h080, 32'h0000_0001);
        axil_read(32'h080, read_val);
        if (read_val !== 32'h0000_0001 || reg_video_ctrl !== 32'h0000_0001) begin
            $display("FAIL: VIDEO_CTRL set/readback mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_write(32'h080, 32'h0000_0000);
        axil_read(32'h080, read_val);
        if (read_val !== 32'h0000_0000 || reg_video_ctrl !== 32'h0000_0000) begin
            $display("FAIL: VIDEO_CTRL clear/readback mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // =====================================================================
        // Test 4: Global IRQ Top Status (0x018) & W1C
        // =====================================================================
        $display("[%0t] Test 4: Global IRQ Top Status (0x018) & W1C...", $time);
        tb_irq_top_status <= 32'h0000_0001;
        #10;
        axil_read(32'h018, read_val);
        if (read_val !== 32'h0000_0001) begin
            $display("FAIL: IRQ_TOP_STATUS read mismatch: 0x%h", read_val);
            $fatal(1);
        end
        top_w1c_pulsed <= 1'b0;
        axil_write(32'h018, 32'h0000_0001);
        #10;
        if (!top_w1c_pulsed) begin
            $display("FAIL: top_w1c_pulsed not asserted");
            $fatal(1);
        end

        // =====================================================================
        // Test 5: VIDEO CH0 Block (0x0100 - 0x0170)
        // =====================================================================
        $display("[%0t] Test 5: VIDEO CH0 Block Configuration & Ring Setup...", $time);
        axil_write(32'h100, 32'h0000_0101); // CH_CTRL: enable=1, irq_en=1
        axil_read(32'h100, read_val);
        if (read_val !== 32'h0000_0101) begin
            $display("FAIL: CH0_CTRL mismatch: 0x%h", read_val);
            $fatal(1);
        end
        if (tb_vch0_irq_en !== 1'b1) begin
            $display("FAIL: tb_vch0_irq_en not asserted");
            $fatal(1);
        end

        axil_write(32'h108, 32'd1920);      // WIDTH
        axil_write(32'h10C, 32'd1080);      // HEIGHT
        axil_write(32'h110, 32'd1920);      // STRIDE0
        axil_read(32'h108, read_val);
        if (read_val !== 32'd1920) begin
            $display("FAIL: CH0_WIDTH mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h10C, read_val);
        if (read_val !== 32'd1080) begin
            $display("FAIL: CH0_HEIGHT mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h110, read_val);
        if (read_val !== 32'd1920) begin
            $display("FAIL: CH0_STRIDE0 mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // C2H Thin Ring0 (0x120 - 0x12C)
        h2c_head_stub = 16'd7;
        c2h_head_stub = 16'd9;
        axil_write(32'h120, 32'h8000_0000); // RING0_BASE_L
        axil_write(32'h124, 32'h0000_0008); // RING0_BASE_H
        axil_write(32'h128, 32'h0005_0100); // RING0_CFG (tail=5, size=256)
        axil_read(32'h120, read_val);
        if (read_val !== 32'h8000_0000) begin
            $display("FAIL: RING0_BASE_L mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h124, read_val);
        if (read_val !== 32'h0000_0008) begin
            $display("FAIL: RING0_BASE_H mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h128, read_val);
        if (read_val !== 32'h0005_0100) begin
            $display("FAIL: RING0_CFG mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h12C, read_val);
        if (read_val !== 32'h0000_0009) begin
            $display("FAIL: RING0_HEAD mismatch: 0x%h (Expect 0x0009)", read_val);
            $fatal(1);
        end

        // H2C Ring1 (0x130 - 0x13C)
        axil_write(32'h130, 32'h9000_0000);
        axil_write(32'h134, 32'h0000_0008);
        axil_write(32'h138, 32'h0003_0080);
        axil_read(32'h130, read_val);
        if (read_val !== 32'h9000_0000) begin
            $display("FAIL: RING1_BASE_L mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h138, read_val);
        if (read_val !== 32'h0003_0080) begin
            $display("FAIL: RING1_CFG mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h13C, read_val);
        if (read_val !== 32'h0000_0007) begin
            $display("FAIL: RING1_HEAD mismatch: 0x%h (Expect 0x0007)", read_val);
            $fatal(1);
        end

        // CH0 IRQ Status & W1C (0x170)
        tb_vch0_irq_status <= 4'h1;
        #10;
        axil_read(32'h170, read_val);
        if (read_val !== 32'h0000_0001) begin
            $display("FAIL: CH0_IRQ_STATUS mismatch: 0x%h", read_val);
            $fatal(1);
        end
        vch0_w1c_pulsed <= 1'b0;
        axil_write(32'h170, 32'h0000_0001);
        #10;
        if (!vch0_w1c_pulsed) begin
            $display("FAIL: vch0_w1c_pulsed not detected");
            $fatal(1);
        end

        // =====================================================================
        // Test 6: AUDIO DEV0 Block (0x0500 - 0x05A8)
        // =====================================================================
        $display("[%0t] Test 6: AUDIO DEV0 Block & ALSA Compliance...", $time);
        axil_write(32'h500, 32'h0000_0001); // DEV0_CTRL: enable=1
        axil_read(32'h500, read_val);
        if (read_val !== 32'h0000_0001) begin
            $display("FAIL: DEV0_CTRL mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_write(32'h508, 32'd48000);     // RATE
        axil_write(32'h50C, 32'd4096);      // PERIOD_BYTES
        axil_write(32'h510, 32'd65536);     // BUFFER_BYTES
        axil_read(32'h508, read_val);
        if (read_val !== 32'd48000) begin
            $display("FAIL: RATE mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h50C, read_val);
        if (read_val !== 32'd4096) begin
            $display("FAIL: PERIOD_BYTES mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h510, read_val);
        if (read_val !== 32'd65536) begin
            $display("FAIL: BUFFER_BYTES mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // Position / Running check
        tb_adev0_running  <= 1'b1;
        tb_adev0_position <= 32'h0000_4000;
        #10;
        axil_read(32'h504, read_val);
        if (read_val[0] !== 1'b1 || read_val[1] !== 1'b0) begin
            $display("FAIL: DEV0 STATUS mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h514, read_val);
        if (read_val !== 32'h0000_4000) begin
            $display("FAIL: DEV0 POSITION mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h5A4, read_val);
        if (read_val !== 32'h0000_4000) begin
            $display("FAIL: DEV0 PTR mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // Hardware Xrun & Sticky bit
        tb_adev0_xrun <= 1'b1;
        #10;
        tb_adev0_xrun <= 1'b0;
        #10;
        axil_read(32'h504, read_val);
        if (read_val[1] !== 1'b1) begin
            $display("FAIL: DEV0 STATUS xrun sticky bit not set: 0x%h", read_val);
            $fatal(1);
        end
        // Clear sticky xrun (W1C)
        axil_write(32'h504, 32'h0000_0002);
        axil_read(32'h504, read_val);
        if (read_val[1] !== 1'b0) begin
            $display("FAIL: DEV0 STATUS xrun sticky bit not cleared: 0x%h", read_val);
            $fatal(1);
        end

        // Software Xrun Injection (Bit 31 of 0x500)
        adev0_inject_pulsed <= 1'b0;
        axil_write(32'h500, 32'h8000_0001);
        #10;
        if (!adev0_inject_pulsed) begin
            $display("FAIL: tb_adev0_xrun_inject pulse not seen");
            $fatal(1);
        end
        axil_read(32'h504, read_val);
        if (read_val[1] !== 1'b1) begin
            $display("FAIL: DEV0 STATUS xrun sticky bit not set after SW injection: 0x%h", read_val);
            $fatal(1);
        end
        axil_write(32'h504, 32'h0000_0002);

        // Audio IRQ Status (0x5A8) & W1C
        tb_adev0_irq_status <= 2'b11;
        #10;
        axil_read(32'h5A8, read_val);
        if (read_val !== 32'h0000_0003) begin
            $display("FAIL: ADEV0_IRQ_STATUS mismatch: 0x%h", read_val);
            $fatal(1);
        end
        adev0_w1c_pulsed <= 1'b0;
        axil_write(32'h5A8, 32'h0000_0003);
        #10;
        if (!adev0_w1c_pulsed) begin
            $display("FAIL: adev0_w1c_pulsed not detected");
            $fatal(1);
        end

        // =====================================================================
        // Test 7: DEBUG Block (0x0900 - 0x0910)
        // =====================================================================
        $display("[%0t] Test 7: DEBUG Block Observability & Overrides...", $time);
        axil_write(32'h900, 32'h0000_0007); // dbg_loopback_ctrl
        axil_read(32'h900, read_val);
        if (read_val !== 32'h0000_0007) begin
            $display("FAIL: DEBUG 0x900 mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_write(32'h904, 32'h0000_00AA); // dbg_pattern_gen
        axil_read(32'h904, read_val);
        if (read_val !== 32'h0000_00AA) begin
            $display("FAIL: DEBUG 0x904 mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_write(32'h908, 32'h0000_0055); // dbg_pacer_ctrl
        axil_read(32'h908, read_val);
        if (read_val !== 32'h0000_0055) begin
            $display("FAIL: DEBUG 0x908 mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h90C, read_val);      // dbg_last_wdata
        if (read_val !== 32'h0000_0055) begin
            $display("FAIL: DEBUG 0x90C last_wdata mismatch: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h910, read_val);      // dbg_last_waddr
        if (read_val !== 32'h0000_0908) begin
            $display("FAIL: DEBUG 0x910 last_waddr mismatch: 0x%h", read_val);
            $fatal(1);
        end

        // =====================================================================
        // Test 8: Unmapped Regions Return 0 & Writes Ignored (Non-aliasing)
        // =====================================================================
        $display("[%0t] Test 8: Unmapped Regions Zero-Return & Non-Aliasing...", $time);
        // Channels 2..4 (0x200..0x400) and Unused Regions (0x600..0x800, 0xA00..0xFFC)
        axil_read(32'h200, read_val);
        if (read_val !== 32'd0) begin
            $display("FAIL: Unmapped 0x200 returned non-zero: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h300, read_val);
        if (read_val !== 32'd0) begin
            $display("FAIL: Unmapped 0x300 returned non-zero: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h600, read_val);
        if (read_val !== 32'd0) begin
            $display("FAIL: Unmapped 0x600 returned non-zero: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'hFFC, read_val);
        if (read_val !== 32'd0) begin
            $display("FAIL: Unmapped 0xFFC returned non-zero: 0x%h", read_val);
            $fatal(1);
        end

        // Writes to unmapped addresses do not alter valid registers
        axil_write(32'h200, 32'hDEADBEEF);
        axil_write(32'h400, 32'hCAFE1234);
        axil_read(32'h000, read_val);
        if (read_val !== EXP_MAGIC) begin
            $display("FAIL: Offset 0x000 corrupted after unmapped writes: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h100, read_val);
        if (read_val !== 32'h0000_0101) begin
            $display("FAIL: CH0_CTRL corrupted after unmapped writes: 0x%h", read_val);
            $fatal(1);
        end

        // =====================================================================
        // Test 9: Legacy Audio Alias Removal Check (0x048 / 0x04C / 0x010)
        // =====================================================================
        $display("[%0t] Test 9: Legacy Removed Offsets Check...", $time);
        axil_read(32'h048, read_val);
        if (read_val !== 32'd0) begin
            $display("FAIL: Legacy 0x048 returned non-zero: 0x%h", read_val);
            $fatal(1);
        end
        axil_read(32'h04C, read_val);
        if (read_val !== 32'd0) begin
            $display("FAIL: Legacy 0x04C returned non-zero: 0x%h", read_val);
            $fatal(1);
        end

        #30;
        $display("=================================================================");
        $display(" 🎉 SUCCESS: axil_reg_space Phase 6 Canonical v3.0 ALL PASS!");
        $display("=================================================================");
        $finish;
    end

endmodule
