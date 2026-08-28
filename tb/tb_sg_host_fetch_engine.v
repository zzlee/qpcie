// ============================================================================
// Testbench: tb_sg_host_fetch_engine
// Description: Unit testbench for PCIe MRd Host Variable-Length SGL Fetch Engine.
//              Verifies 256B burst MRd generation, 128-bit SGL unpacking,
//              chained 4KB slot traversal (following Entry[255] link pointer),
//              and SGL segment push interface.
// ============================================================================

`timescale 1ns / 1ps

module tb_sg_host_fetch_engine;
    localparam CLK_PERIOD = 8.0; // 125 MHz

    reg         clk;
    reg         rst_n;

    reg         fetch_start;
    reg  [63:0] plane0_slot_addr;
    reg  [63:0] plane1_slot_addr;
    reg  [15:0] plane0_pages_req;
    reg  [15:0] plane1_pages_req;
    wire        fetch_busy;
    wire        fetch_done;

    wire        mrd_req_valid;
    wire [63:0] mrd_req_addr;
    wire [10:0] mrd_req_dw_len;
    wire [7:0]  mrd_req_tag;
    reg         mrd_req_ack;

    reg         cpld_valid;
    reg  [127:0] cpld_data;
    reg         cpld_last;
    reg  [7:0]  cpld_tag;

    wire        sgl_y_wr_en;
    wire [63:0] sgl_y_wr_addr;
    wire [31:0] sgl_y_wr_len;
    wire [31:0] sgl_y_wr_flags;

    wire        sgl_uv_wr_en;
    wire [63:0] sgl_uv_wr_addr;
    wire [31:0] sgl_uv_wr_len;
    wire [31:0] sgl_uv_wr_flags;

    // Captured SGL entries in Testbench
    reg [63:0] captured_addr  [0:511];
    reg [31:0] captured_len   [0:511];
    reg [31:0] captured_flags [0:511];
    integer    captured_cnt;

    always @(posedge clk) begin
        if (sgl_y_wr_en) begin
            captured_addr[captured_cnt]  <= sgl_y_wr_addr;
            captured_len[captured_cnt]   <= sgl_y_wr_len;
            captured_flags[captured_cnt] <= sgl_y_wr_flags;
            captured_cnt <= captured_cnt + 1;
        end
    end

    // DUT Instantiation
    sg_host_fetch_engine #(
        .DATA_WIDTH(128)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_start(fetch_start),
        .plane0_slot_addr(plane0_slot_addr),
        .plane1_slot_addr(plane1_slot_addr),
        .plane0_pages_req(plane0_pages_req),
        .plane1_pages_req(plane1_pages_req),
        .fetch_busy(fetch_busy),
        .fetch_done(fetch_done),
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
        .sgl_uv_wr_en(sgl_uv_wr_en),
        .sgl_uv_wr_addr(sgl_uv_wr_addr),
        .sgl_uv_wr_len(sgl_uv_wr_len),
        .sgl_uv_wr_flags(sgl_uv_wr_flags)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Simulated Host RAM (Holds two chained 4KB slots of 128-bit entries)
    // Slot 0 at 0x200000000, Slot 1 at 0x200001000
    reg [63:0] host_slot0_addr  [0:255];
    reg [31:0] host_slot0_len   [0:255];
    reg [31:0] host_slot0_flags [0:255];

    reg [63:0] host_slot1_addr  [0:255];
    reg [31:0] host_slot1_len   [0:255];
    reg [31:0] host_slot1_flags [0:255];

    integer i;
    initial begin
        // Setup Slot 0 (255 variable segments: 64KB, 1MB, etc.)
        for (i = 0; i < 255; i = i + 1) begin
            host_slot0_addr[i]  = 64'h0000000300000000 + (i * 64'h10000);
            host_slot0_len[i]   = 32'h00010000; // 64 KB per chunk
            host_slot0_flags[i] = 32'h00000000;
        end
        host_slot0_addr[255]  = 64'h0000000200001000; // Pointer to Slot 1!
        host_slot0_len[255]   = 32'd0;
        host_slot0_flags[255] = 32'h00000001; // Bit 0: CHAIN_PTR

        // Setup Slot 1 (Another 100 variable segments)
        for (i = 0; i < 255; i = i + 1) begin
            host_slot1_addr[i]  = 64'h0000000400000000 + (i * 64'h10000);
            host_slot1_len[i]   = 32'h00010000;
            host_slot1_flags[i] = (i == 44) ? 32'h00000002 : 32'h00000000; // Bit 1: LAST_SEG at entry 44
        end
    end

    // Responder Task: Emits 256B CplD (16 x 128-bit entries)
    task respond_burst_cpld;
        input [63:0] burst_addr;
        integer beat, idx_base;
        reg [63:0] e_addr;
        reg [31:0] e_len, e_flags;
        reg [31:0] hold_dw;
        begin
            idx_base = (burst_addr[11:0]) / 16;

            @(posedge clk);
            cpld_valid <= 1'b1;
            cpld_tag   <= 8'h01;
            cpld_last  <= 1'b0;

            // Beat 0: 3 DWs of Header, Payload DW0 in [127:96]
            if (burst_addr[31:12] == 20'h00000) begin
                e_addr = host_slot0_addr[idx_base];
            end else begin
                e_addr = host_slot1_addr[idx_base];
            end
            hold_dw = e_addr[31:0];

            cpld_data  <= {hold_dw, 32'h00000000, 32'h04080100, 32'h4A000040};

            for (beat = 1; beat <= 16; beat = beat + 1) begin
                @(posedge clk);
                if (burst_addr[31:12] == 20'h00000) begin
                    e_addr  = host_slot0_addr[idx_base + beat - 1];
                    e_len   = host_slot0_len[idx_base + beat - 1];
                    e_flags = host_slot0_flags[idx_base + beat - 1];
                end else begin
                    e_addr  = host_slot1_addr[idx_base + beat - 1];
                    e_len   = host_slot1_len[idx_base + beat - 1];
                    e_flags = host_slot1_flags[idx_base + beat - 1];
                end

                if (beat < 16) begin
                    if (burst_addr[31:12] == 20'h00000)
                        hold_dw = host_slot0_addr[idx_base + beat][31:0];
                    else
                        hold_dw = host_slot1_addr[idx_base + beat][31:0];
                end else begin
                    hold_dw = 32'h00000000;
                end

                cpld_last <= (beat == 16);
                cpld_data <= {hold_dw, e_flags, e_len, e_addr[63:32]};
            end

            @(posedge clk);
            cpld_valid <= 1'b0;
            cpld_last  <= 1'b0;
            cpld_data  <= 128'd0;
        end
    endtask

    // Requester Acknowledger & Memory Responder
    initial begin
        mrd_req_ack <= 1'b0;
        forever begin
            @(posedge clk);
            if (mrd_req_valid) begin
                mrd_req_ack <= 1'b1;
                @(posedge clk);
                mrd_req_ack <= 1'b0;
                #16;
                respond_burst_cpld(mrd_req_addr);
            end
        end
    end

    // Test Sequence
    initial begin
        clk = 0;
        rst_n = 0;
        fetch_start = 0;
        plane0_slot_addr = 64'h0000000200000000;
        plane1_slot_addr = 64'd0;
        plane0_pages_req = 16'd300;
        plane1_pages_req = 16'd0;
        cpld_valid = 0;
        cpld_data = 0;
        cpld_last = 0;
        cpld_tag = 0;
        captured_cnt = 0;

        #40;
        rst_n = 1;
        #40;

        $display("=========================================================");
        $display(" Running tb_sg_host_fetch_engine Verification Testbench");
        $display("=========================================================");

        $display("[TEST 1] Triggering Variable SGL Fetch across chained slots...");
        @(posedge clk);
        fetch_start <= 1'b1;
        @(posedge clk);
        fetch_start <= 1'b0;

        // Wait until fetch_done
        while (!fetch_done) @(posedge clk);

        $display("[TEST 2] Verifying SGL Segments (captured %0d entries)...", captured_cnt);
        if (captured_cnt < 300) begin
            $fatal(1, "FAIL: Expected at least 300 entries, got %0d", captured_cnt);
        end

        // Verify entries from Slot 0
        for (i = 0; i < 255; i = i + 1) begin
            if (captured_addr[i] !== host_slot0_addr[i] || captured_len[i] !== host_slot0_len[i]) begin
                $fatal(1, "FAIL: Entry %0d mismatch! Expected addr=%h len=%h, got addr=%h len=%h",
                       i, host_slot0_addr[i], host_slot0_len[i], captured_addr[i], captured_len[i]);
            end
        end

        // Verify entries from Slot 1 (following chain pointer!)
        for (i = 0; i < 45; i = i + 1) begin
            if (captured_addr[255 + i] !== host_slot1_addr[i] || captured_len[255 + i] !== host_slot1_len[i]) begin
                $fatal(1, "FAIL: Slot1 Entry %0d mismatch! Expected addr=%h, got %h",
                       i, host_slot1_addr[i], captured_addr[255 + i]);
            end
        end

        $display("  [PASS] All SGL entries and chained slot traversal verified!");
        $display("=========================================================");
        $display(" ALL TESTS PASSED: Variable-Length SGL Fetch Verified!");
        $display("=========================================================");
        #100;
        $finish;
    end

endmodule
