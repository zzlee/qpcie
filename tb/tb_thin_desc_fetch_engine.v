// ============================================================================
// Testbench: tb_thin_desc_fetch_engine
// Description: Unit testbench for Phase 3 Thin Descriptor Fetch Engine.
//              Tests 16-Byte descriptor fetch, dual-ring arbitration (Y & UV),
//              doorbell/HEAD mechanics, backpressure, and frame launch handshake.
// ============================================================================

`timescale 1ns / 1ps

module tb_thin_desc_fetch_engine;

    reg         clk;
    reg         rst_n;

    // Controls & Config
    reg         enable;
    reg  [3:0]  format;
    reg  [15:0] frame_width;
    reg  [15:0] frame_height;
    reg  [15:0] frame_stride0;
    reg  [15:0] frame_stride1;
    reg  [63:0] global_timestamp;

    // RING0
    reg  [63:0] ring0_base_addr;
    reg  [15:0] ring0_size;
    reg  [15:0] ring0_tail;
    wire [15:0] ring0_head;

    // RING1
    reg  [63:0] ring1_base_addr;
    reg  [15:0] ring1_size;
    reg  [15:0] ring1_tail;
    wire [15:0] ring1_head;

    // Status
    reg         frame_done_in;
    wire [31:0] frame_count;
    wire [31:0] drop_count;
    wire        busy;

    // PCIe MRd Requester
    wire        mrd_req_valid;
    wire [63:0] mrd_req_addr;
    wire [10:0] mrd_req_dw_len;
    wire [7:0]  mrd_req_tag;
    reg         mrd_req_ack;

    // PCIe CplD Completion
    reg         cpld_valid;
    reg  [127:0] cpld_data;
    reg         cpld_last;
    reg  [7:0]  cpld_tag;

    // SGL Walker Push
    wire        sgl_y_wr_en;
    wire [63:0] sgl_y_wr_addr;
    wire [31:0] sgl_y_wr_len;
    wire [31:0] sgl_y_wr_flags;
    reg         sgl_y_almost_full;

    wire        sgl_uv_wr_en;
    wire [63:0] sgl_uv_wr_addr;
    wire [31:0] sgl_uv_wr_len;
    wire [31:0] sgl_uv_wr_flags;
    reg         sgl_uv_almost_full;

    // Frame Launch Handshake
    wire        frame_launch_req;
    wire [244:0] frame_launch_bus;
    reg         frame_launch_ack;
    reg         capture_engine_busy;

    // Instantiate UUT
    thin_desc_fetch_engine #(
        .DATA_WIDTH(128)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .format(format),
        .frame_width(frame_width),
        .frame_height(frame_height),
        .frame_stride0(frame_stride0),
        .frame_stride1(frame_stride1),
        .global_timestamp(global_timestamp),
        .ring0_base_addr(ring0_base_addr),
        .ring0_size(ring0_size),
        .ring0_tail(ring0_tail),
        .ring0_head(ring0_head),
        .ring1_base_addr(ring1_base_addr),
        .ring1_size(ring1_size),
        .ring1_tail(ring1_tail),
        .ring1_head(ring1_head),
        .frame_done_in(frame_done_in),
        .frame_count(frame_count),
        .drop_count(drop_count),
        .busy(busy),
        .mrd_req_valid(mrd_req_valid),
        .mrd_req_addr(mrd_req_addr),
        .mrd_req_dw_len(mrd_req_dw_len),
        .mrd_req_tag(mrd_req_tag),
        .mrd_req_ack(mrd_req_ack),
        .cpld_valid(cpld_valid),
        .cpld_data(cpld_data),
        .cpld_last(cpld_last),
        .cpld_tag(cpld_tag),
        .sgl_y_wr_en(sgl_y_wr_en),
        .sgl_y_wr_addr(sgl_y_wr_addr),
        .sgl_y_wr_len(sgl_y_wr_len),
        .sgl_y_wr_flags(sgl_y_wr_flags),
        .sgl_y_almost_full(sgl_y_almost_full),
        .sgl_uv_wr_en(sgl_uv_wr_en),
        .sgl_uv_wr_addr(sgl_uv_wr_addr),
        .sgl_uv_wr_len(sgl_uv_wr_len),
        .sgl_uv_wr_flags(sgl_uv_wr_flags),
        .sgl_uv_almost_full(sgl_uv_almost_full),
        .frame_launch_req(frame_launch_req),
        .frame_launch_bus(frame_launch_bus),
        .frame_launch_ack(frame_launch_ack),
        .capture_engine_busy(capture_engine_busy)
    );

    // Clock generation: 125 MHz (8ns period)
    always #4 clk = ~clk;

    // Emulated host memory responder
    always @(posedge clk) begin
        if (!rst_n) begin
            mrd_req_ack <= 1'b0;
            cpld_valid  <= 1'b0;
            cpld_data   <= 128'd0;
            cpld_last   <= 1'b0;
            cpld_tag    <= 8'd0;
        end else begin
            mrd_req_ack <= 1'b0;
            cpld_valid  <= 1'b0;

            if (mrd_req_valid && !mrd_req_ack) begin
                mrd_req_ack <= 1'b1;
            end

            if (mrd_req_ack) begin
                // Return CplD next cycle
                cpld_valid <= 1'b1;
                cpld_last  <= 1'b1;
                cpld_tag   <= mrd_req_tag;
                // Host memory pattern:
                // [63:0]   host_addr = mrd_req_addr | 64'h8000_0000
                // [95:64]  len_bytes = 32'd4096 (4KB page)
                // [127:96] flags     = 32'h0000_0001
                cpld_data  <= {32'h0000_0001, 32'd4096, (mrd_req_addr | 64'h8000_0000)};
            end
        end
    end

    // Frame launch ACK auto-responder
    always @(posedge clk) begin
        if (!rst_n) begin
            frame_launch_ack <= 1'b0;
        end else begin
            if (frame_launch_req && !frame_launch_ack) begin
                frame_launch_ack <= 1'b1;
            end else begin
                frame_launch_ack <= 1'b0;
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        enable = 0;
        format = 4'd1; // RGB24
        frame_width = 16'd1920;
        frame_height = 16'd1080;
        frame_stride0 = 16'd5760;
        frame_stride1 = 16'd0;
        global_timestamp = 64'h0000_0001_0000_2026;
        ring0_base_addr = 64'h0000_0001_1000_0000;
        ring0_size = 16'd16;
        ring0_tail = 16'd0;
        ring1_base_addr = 64'h0000_0001_2000_0000;
        ring1_size = 16'd16;
        ring1_tail = 16'd0;
        frame_done_in = 0;
        sgl_y_almost_full = 0;
        sgl_uv_almost_full = 0;
        capture_engine_busy = 0;

        #20;
        rst_n = 1;
        #20;

        $display("--- [Test 1: Reset State] ---");
        if (ring0_head !== 16'd0 || ring1_head !== 16'd0 || frame_count !== 32'd0) begin
            $display("FAIL: Test 1 reset state mismatch");
            $fatal(1);
        end
        $display("  PASS: Reset state clean (head=0, count=0)");

        #20;
        $display("--- [Test 2: RGB24 Single-Ring Fetch & Frame Launch] ---");
        // Program ring0 tail = 4 (4 descriptors queued by host driver)
        ring0_tail = 16'd4;
        enable = 1'b1;

        // Wait for frame launch handshake
        @(posedge frame_launch_req);
        $display("  Detected frame_launch_req!");
        if (frame_launch_bus[244:241] !== 4'd1 || // format RGB24
            frame_launch_bus[240] !== 1'b1     || // sg_mode = 1
            frame_launch_bus[143:128] !== 16'd1920 || // width
            frame_launch_bus[159:144] !== 16'd1080) begin // height
            $display("FAIL: Test 2 frame_launch_bus parameters mismatch: 0x%h", frame_launch_bus);
            $fatal(1);
        end
        $display("  PASS: Frame launch handshake correctly asserted with 1920x1080 RGB24 parameters");

        // Wait for all 4 descriptors to be fetched
        wait(ring0_head == 16'd4);
        $display("  PASS: All 4 thin descriptors fetched, ring0_head advanced to 4");

        #40;
        $display("--- [Test 3: Frame Completion Pulse] ---");
        frame_done_in = 1'b1;
        #8;
        frame_done_in = 1'b0;
        #8;
        if (frame_count !== 32'd1) begin
            $display("FAIL: Test 3 frame_count did not increment: %d", frame_count);
            $fatal(1);
        end
        $display("  PASS: frame_count incremented to %d", frame_count);

        #40;
        $display("--- [Test 4: NV12M Dual-Ring Parallel Fetch] ---");
        // Switch to NV12M
        format = 4'd0; // NV12M
        frame_stride1 = 16'd1920;
        // Queue 2 descriptors in RING0 (tail=6) and 2 in RING1 (tail=2)
        ring0_tail = 16'd6;
        ring1_tail = 16'd2;

        // Wait for frame launch
        @(posedge frame_launch_req);
        if (frame_launch_bus[244:241] !== 4'd0) begin // format NV12M
            $display("FAIL: Test 4 format mismatch: expected NV12M (0), got %d", frame_launch_bus[244:241]);
            $fatal(1);
        end
        $display("  PASS: Frame launch correctly emitted for NV12M");

        // Wait for ring heads to catch up to tails
        wait(ring0_head == 16'd6 && ring1_head == 16'd2);
        $display("  PASS: Dual-ring parallel fetch complete (RING0 head=6, RING1 head=2)");

        #40;
        $display("--- [Test 5: Backpressure Handling] ---");
        sgl_y_almost_full = 1'b1;
        ring0_tail = 16'd8;
        #100;
        // With backpressure asserted on Y, ring0_head should not advance past 6
        if (ring0_head !== 16'd6) begin
            $display("FAIL: Test 5 ring0_head advanced despite backpressure: %d", ring0_head);
            $fatal(1);
        end
        $display("  PASS: SGL Y backpressure successfully held off MRd requests");

        sgl_y_almost_full = 1'b0;
        wait(ring0_head == 16'd8);
        $display("  PASS: Backpressure cleared, ring0_head resumed and reached 8");

        #40;
        $display("--- [Test 6: Ring Wrap-Around] ---");
        ring0_size = 16'd10; // size = 10
        ring0_tail = 16'd2;  // tail = 2 (wrapped: 8 -> 9 -> 0 -> 1 -> 2)
        wait(ring0_head == 16'd2);
        $display("  PASS: Ring wrapped cleanly past size=10 to head=2");

        #40;
        $display("=================================================================");
        $display(" 🎉 ALL THIN DESC FETCH ENGINE TESTS PASSED (100%% PASS)!");
        $display("=================================================================");
        $finish;
    end

endmodule
