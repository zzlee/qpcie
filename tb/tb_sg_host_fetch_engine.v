// ============================================================================
// Testbench: tb_sg_host_fetch_engine
// Description: Unit testbench for the direction-decoupled SGL fetch engine.
//              Verifies 64B burst MRd generation, 128-bit SGL unpacking,
//              chained 4KB slot traversal (following Entry[255] link pointer),
//              LAST_SEG handling across a slot boundary, and the Y->UV plane
//              switch.  Also verifies the deadlock fix: the fetch completes
//              while the destination SGL FIFO remains almost-full (the table
//              is buffered on-chip), and the buffered entries drain in order
//              once backpressure clears.  A dual-direction test verifies that
//              an H2C table and a C2H table buffer/drain concurrently to their
//              respective channels.
// ============================================================================

`timescale 1ns / 1ps

module tb_sg_host_fetch_engine;
    localparam CLK_PERIOD = 8.0; // 125 MHz

    // Simulated Host RAM slot base addresses
    localparam [63:0] SLOT0_BASE = 64'h0000_0002_0000_0000; // Y plane slot 0
    localparam [63:0] SLOT1_BASE = 64'h0000_0002_0000_1000; // Y plane slot 1 (chained)
    localparam [63:0] UV0_BASE   = 64'h0000_0003_0000_0000; // UV plane slot 0

    reg         clk;
    reg         rst_n;

    reg         fetch_start;
    reg  [2:0]  fetch_channel;
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
    wire [2:0]  sgl_y_channel;

    wire        sgl_uv_wr_en;
    wire [63:0] sgl_uv_wr_addr;
    wire [31:0] sgl_uv_wr_len;
    wire [31:0] sgl_uv_wr_flags;
    wire [2:0]  sgl_uv_channel;
    reg  [4:0]  channel_y_almost_full;
    reg  [4:0]  channel_uv_almost_full;

    // Captured SGL entries pushed to the Y walker FIFOs (with destination channel)
    reg [63:0] captured_addr  [0:2047];
    reg [31:0] captured_len   [0:2047];
    reg [31:0] captured_flags [0:2047];
    reg [2:0]  captured_y_ch  [0:2047];
    integer    captured_cnt;

    // Captured SGL entries pushed to the UV walker FIFOs (with destination channel)
    reg [63:0] captured_uv_addr  [0:2047];
    reg [31:0] captured_uv_len   [0:2047];
    reg [31:0] captured_uv_flags [0:2047];
    reg [2:0]  captured_uv_ch    [0:2047];
    integer    captured_uv_cnt;

    always @(posedge clk) begin
        if (sgl_y_wr_en) begin
            captured_addr[captured_cnt]  <= sgl_y_wr_addr;
            captured_len[captured_cnt]   <= sgl_y_wr_len;
            captured_flags[captured_cnt] <= sgl_y_wr_flags;
            captured_y_ch[captured_cnt]  <= sgl_y_channel;
            captured_cnt <= captured_cnt + 1;
        end
        if (sgl_uv_wr_en) begin
            captured_uv_addr[captured_uv_cnt]  <= sgl_uv_wr_addr;
            captured_uv_len[captured_uv_cnt]   <= sgl_uv_wr_len;
            captured_uv_flags[captured_uv_cnt] <= sgl_uv_wr_flags;
            captured_uv_ch[captured_uv_cnt]    <= sgl_uv_channel;
            captured_uv_cnt <= captured_uv_cnt + 1;
        end
    end

    // DUT Instantiation
    sg_host_fetch_engine #(
        .DATA_WIDTH(128)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_start(fetch_start),
        .fetch_channel(fetch_channel),
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
        .sgl_y_channel(sgl_y_channel),
        .sgl_y_wr_en(sgl_y_wr_en),
        .sgl_y_wr_addr(sgl_y_wr_addr),
        .sgl_y_wr_len(sgl_y_wr_len),
        .sgl_y_wr_flags(sgl_y_wr_flags),
        .sgl_uv_channel(sgl_uv_channel),
        .sgl_uv_wr_en(sgl_uv_wr_en),
        .sgl_uv_wr_addr(sgl_uv_wr_addr),
        .sgl_uv_wr_len(sgl_uv_wr_len),
        .sgl_uv_wr_flags(sgl_uv_wr_flags),
        .channel_y_almost_full(channel_y_almost_full),
        .channel_uv_almost_full(channel_uv_almost_full)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------------
    // Simulated Host RAM: three 4KB slots of 128-bit SGL entries
    //   Y slot 0 at SLOT0_BASE, Y slot 1 at SLOT1_BASE, UV slot 0 at UV0_BASE
    // ------------------------------------------------------------------------
    reg [63:0] host_slot0_addr  [0:255];
    reg [31:0] host_slot0_len   [0:255];
    reg [31:0] host_slot0_flags [0:255];

    reg [63:0] host_slot1_addr  [0:255];
    reg [31:0] host_slot1_len   [0:255];
    reg [31:0] host_slot1_flags [0:255];

    reg [63:0] host_uv0_addr  [0:255];
    reg [31:0] host_uv0_len   [0:255];
    reg [31:0] host_uv0_flags [0:255];

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) begin
            host_slot0_addr[i]  = 64'd0; host_slot0_len[i]  = 32'd0; host_slot0_flags[i] = 32'd0;
            host_slot1_addr[i]  = 64'd0; host_slot1_len[i]  = 32'd0; host_slot1_flags[i] = 32'd0;
            host_uv0_addr[i]    = 64'd0; host_uv0_len[i]    = 32'd0; host_uv0_flags[i]   = 32'd0;
        end
    end

    // Load the Y plane: slot 0 fully packed (255 entries + chain at 255),
    // slot 1 holds the final entries with LAST_SEG on the last one.
    // last1 = index of the LAST_SEG entry in slot 1 (inclusive count = last1+1)
    task load_y_table;
        input integer last1;
        integer k;
        begin
            for (k = 0; k < 256; k = k + 1) begin
                host_slot0_addr[k]  = 64'd0; host_slot0_len[k]  = 32'd0; host_slot0_flags[k] = 32'd0;
                host_slot1_addr[k]  = 64'd0; host_slot1_len[k]  = 32'd0; host_slot1_flags[k] = 32'd0;
            end
            for (k = 0; k < 255; k = k + 1) begin
                host_slot0_addr[k]  = 64'h0000000100000000 + (k * 64'h1000); // 4KiB pages
                host_slot0_len[k]   = 32'h00001000;
                host_slot0_flags[k] = 32'h00000000;
            end
            host_slot0_addr[255]  = SLOT1_BASE;
            host_slot0_len[255]   = 32'd0;
            host_slot0_flags[255] = 32'h00000001; // CHAIN_PTR

            for (k = 0; k <= last1; k = k + 1) begin
                host_slot1_addr[k]  = 64'h0000000400000000 + (k * 64'h1000);
                host_slot1_len[k]   = 32'h00001000;
                host_slot1_flags[k] = (k == last1) ? 32'h00000002 : 32'h00000000;
            end
        end
    endtask

    // Load the UV plane: 2 entries, LAST_SEG on the last (partial) one
    task load_uv_table;
        integer k;
        begin
            for (k = 0; k < 256; k = k + 1) begin
                host_uv0_addr[k]  = 64'd0; host_uv0_len[k]  = 32'd0; host_uv0_flags[k] = 32'd0;
            end
            host_uv0_addr[0]  = 64'h0000000500000000;
            host_uv0_len[0]   = 32'h00001000;
            host_uv0_flags[0] = 32'h00000000;
            host_uv0_addr[1]  = 64'h0000000500001000;
            host_uv0_len[1]   = 32'h00000800; // partial final UV entry
            host_uv0_flags[1] = 32'h00000002; // LAST_SEG
        end
    endtask

    // Map a burst address to a host RAM slot: 0 = Y slot0, 1 = Y slot1, 2 = UV
    function integer which_slot;
        input [63:0] addr;
        begin
            if (addr >= SLOT0_BASE && addr < (SLOT0_BASE + 64'h1000))
                which_slot = 0;
            else if (addr >= SLOT1_BASE && addr < (SLOT1_BASE + 64'h1000))
                which_slot = 1;
            else if (addr >= UV0_BASE && addr < (UV0_BASE + 64'h1000))
                which_slot = 2;
            else
                which_slot = -1;
        end
    endfunction

    // Read one 128-bit entry from the selected host RAM slot
    task get_entry;
        input  integer slot;
        input  integer idx;
        output reg [63:0] e_addr;
        output reg [31:0] e_len;
        output reg [31:0] e_flags;
        begin
            case (slot)
                0: begin
                    e_addr  = host_slot0_addr[idx];
                    e_len   = host_slot0_len[idx];
                    e_flags = host_slot0_flags[idx];
                end
                1: begin
                    e_addr  = host_slot1_addr[idx];
                    e_len   = host_slot1_len[idx];
                    e_flags = host_slot1_flags[idx];
                end
                default: begin
                    e_addr  = host_uv0_addr[idx];
                    e_len   = host_uv0_len[idx];
                    e_flags = host_uv0_flags[idx];
                end
            endcase
        end
    endtask

    // Responder Task: Emits one 64B CplD (4 x 128-bit entries)
    //
    // Wire format per beat (128-bit lanes):
    //   [127:96] = next entry's low DW  (held for the following beat)
    //   [95:64]  = current entry flags
    //   [63:32]  = current entry length
    //   [31:0]   = current entry high DW
    // Beat 0 carries only the header with the first entry's low DW in [127:96].
    task respond_burst_cpld;
        input [63:0] burst_addr;
        integer beat, idx_base, slot;
        reg [63:0] cur_addr, nxt_addr;
        reg [31:0] cur_len, cur_flags, nxt_len, nxt_flags;
        reg [31:0] hold_dw;
        begin
            slot = which_slot(burst_addr);
            if (slot < 0)
                $fatal(1, "FAIL: MRd to unknown address %h", burst_addr);

            idx_base = (burst_addr[11:0]) / 16;

            @(posedge clk);
            cpld_valid <= 1'b1;
            cpld_tag   <= 8'h01;
            cpld_last  <= 1'b0;

            // Beat 0: 3 DWs of Header, Payload DW0 (entry low word) in [127:96]
            get_entry(slot, idx_base, cur_addr, cur_len, cur_flags);
            hold_dw = cur_addr[31:0];
            cpld_data <= {hold_dw, 32'h00000000, 32'h04080100, 32'h4A000040};

            for (beat = 1; beat <= 4; beat = beat + 1) begin
                @(posedge clk);
                // Current entry (independent regs so nothing is overwritten)
                get_entry(slot, idx_base + beat - 1, cur_addr, cur_len, cur_flags);
                // Next entry's low DW for the following beat (separate regs)
                if (beat < 4) begin
                    get_entry(slot, idx_base + beat, nxt_addr, nxt_len, nxt_flags);
                    hold_dw = nxt_addr[31:0];
                end else begin
                    hold_dw = 32'h00000000;
                end

                cpld_last <= (beat == 4);
                cpld_data <= {hold_dw, cur_flags, cur_len, cur_addr[63:32]};
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
                if (mrd_req_dw_len !== 11'd16)
                    $fatal(1, "FAIL: SG fetch MRd length is %0d DW, expected 16", mrd_req_dw_len);
                if (mrd_req_tag !== 8'h01)
                    $fatal(1, "FAIL: SG fetch MRd tag is %h, expected 8'h01", mrd_req_tag);
                mrd_req_ack <= 1'b1;
                @(posedge clk);
                mrd_req_ack <= 1'b0;
                #16;
                respond_burst_cpld(mrd_req_addr);
            end
        end
    end

    task pulse_fetch_start;
        begin
            @(posedge clk);
            fetch_start <= 1'b1;
            @(posedge clk);
            fetch_start <= 1'b0;
        end
    endtask

    // Wait until the capture counts reach the expected totals, plus a small
    // settling margin for the final in-flight push.
    task wait_drain_complete;
        input integer y_exp;
        input integer uv_exp;
        begin
            while (captured_cnt < y_exp || captured_uv_cnt < uv_exp) @(posedge clk);
            repeat (8) @(posedge clk);
        end
    endtask

    // Verify the captured Y entries for one channel against the host table
    task verify_y_entries;
        input integer ch;
        input integer y_exp; // total Y entries expected for this channel
        integer n, k;
        begin
            n = 0;
            for (k = 0; k < captured_cnt; k = k + 1) begin
                if (captured_y_ch[k] == ch) begin
                    if (n < 255) begin
                        if (captured_addr[k] !== host_slot0_addr[n] ||
                            captured_len[k]  !== host_slot0_len[n])
                            $fatal(1, "FAIL: ch%0d Y slot0 entry %0d mismatch (addr=%h len=%h)",
                                   ch, n, captured_addr[k], captured_len[k]);
                    end else begin
                        if (captured_addr[k] !== host_slot1_addr[n - 255] ||
                            captured_len[k]  !== host_slot1_len[n - 255])
                            $fatal(1, "FAIL: ch%0d Y slot1 entry %0d mismatch (addr=%h len=%h)",
                                   ch, n - 255, captured_addr[k], captured_len[k]);
                    end
                    n = n + 1;
                end
            end
            if (n != y_exp)
                $fatal(1, "FAIL: ch%0d expected %0d Y entries, got %0d", ch, y_exp, n);
        end
    endtask

    // Verify the captured UV entries for one channel against the host table
    task verify_uv_entries;
        input integer ch;
        input integer uv_exp;
        integer n, k;
        begin
            n = 0;
            for (k = 0; k < captured_uv_cnt; k = k + 1) begin
                if (captured_uv_ch[k] == ch) begin
                    if (captured_uv_addr[k] !== host_uv0_addr[n] ||
                        captured_uv_len[k]  !== host_uv0_len[n]  ||
                        captured_uv_flags[k] !== host_uv0_flags[n])
                        $fatal(1, "FAIL: ch%0d UV entry %0d mismatch", ch, n);
                    n = n + 1;
                end
            end
            if (n != uv_exp)
                $fatal(1, "FAIL: ch%0d expected %0d UV entries, got %0d", ch, uv_exp, n);
        end
    endtask

    // ------------------------------------------------------------------------
    // TEST 1: Deadlock fix + chained slot traversal with consumer almost-full
    // ------------------------------------------------------------------------
    task run_test1;
        integer n;
        begin
            load_y_table(44); // 255 + 45 = 300 Y entries
            load_uv_table();

            captured_cnt    = 0;
            captured_uv_cnt = 0;

            $display("[TEST 1] Fetching with destination FIFO almost-full (deadlock scenario)...");
            // Destination C2H ch0 is held almost-full for the whole fetch
            channel_y_almost_full[0] <= 1'b1;
            channel_uv_almost_full[0] <= 1'b1;

            @(posedge clk);
            pulse_fetch_start(); // fetch_channel = 0 (C2H ch0)

            // While the consumer is full, the fetch must still complete (the
            // whole table is buffered internally) -- this is the deadlock fix.
            while (!fetch_done) @(posedge clk);

            if (captured_cnt != 0 || captured_uv_cnt != 0)
                $fatal(1, "FAIL: entries pushed while destination FIFO was almost-full");

            $display("  [PASS] fetch completed while consumer was stalled (no deadlock)");

            // Release backpressure: all 300 + 2 entries must drain in order
            channel_y_almost_full[0] <= 1'b0;
            channel_uv_almost_full[0] <= 1'b0;

            wait_drain_complete(300, 2);

            verify_y_entries(0, 300);
            verify_uv_entries(0, 2);

            if (!captured_flags[299][1])
                $fatal(1, "FAIL: LAST_SEG missing on final Y entry (flags=0x%x)", captured_flags[299]);

            $display("  [PASS] TEST 1: deadlock broken, chained slots traversed, entries drained in order");
        end
    endtask

    // ------------------------------------------------------------------------
    // TEST 2: 255-entry full slot + chain at Entry 255, LAST_SEG in the next
    //         slot (crossing the slot boundary), then Y -> UV plane switch
    // ------------------------------------------------------------------------
    task run_test2;
        integer n;
        begin
            load_y_table(1);  // 255 + 2 = 257 Y entries, LAST_SEG in slot 1
            load_uv_table();

            captured_cnt    = 0;
            captured_uv_cnt = 0;

            $display("[TEST 2] Full-slot chain and LAST_SEG crossing slot boundary, Y->UV switch...");
            pulse_fetch_start();

            while (!fetch_done) @(posedge clk);
            wait_drain_complete(257, 2);

            verify_y_entries(0, 257);
            verify_uv_entries(0, 2);

            // LAST_SEG must be carried on the final Y entry and the partial UV entry
            n = 0;
            for (i = 0; i < captured_cnt; i = i + 1)
                if (captured_y_ch[i] == 0) n = n + 1;
            // n == 257; find the last channel-0 entry
            begin : find_last
                integer k;
                integer last_idx;
                last_idx = -1;
                for (k = 0; k < captured_cnt; k = k + 1)
                    if (captured_y_ch[k] == 0) last_idx = k;
                if (!captured_flags[last_idx][1])
                    $fatal(1, "FAIL: LAST_SEG missing on final Y entry (flags=0x%x)", captured_flags[last_idx]);
                if (!captured_uv_flags[1][1])
                    $fatal(1, "FAIL: LAST_SEG missing on partial UV entry (flags=0x%x)", captured_uv_flags[1]);
            end

            $display("  [PASS] TEST 2: full-slot chain followed, LAST_SEG crossed slot boundary, Y->UV switch");
        end
    endtask

    // ------------------------------------------------------------------------
    // TEST 3: Dual direction -- an H2C table and a C2H ch1 table buffer and
    //         drain concurrently to their respective channels
    // ------------------------------------------------------------------------
    task run_test3;
        begin
            load_y_table(1);  // 257 Y entries
            load_uv_table();  // 2 UV entries

            captured_cnt    = 0;
            captured_uv_cnt = 0;

            $display("[TEST 3] H2C fetch (ch4) then C2H ch1 fetch with concurrent drain...");

            // H2C request
            fetch_channel <= 3'd4;
            pulse_fetch_start();
            while (!fetch_done) @(posedge clk);

            // C2H ch1 request -- starts while the H2C drain is still delivering
            fetch_channel <= 3'd1;
            pulse_fetch_start();
            while (!fetch_done) @(posedge clk);

            wait_drain_complete(257 * 2, 2 * 2);

            verify_y_entries(4, 257);
            verify_y_entries(1, 257);
            verify_uv_entries(4, 2);
            verify_uv_entries(1, 2);

            $display("  [PASS] TEST 3: H2C (ch4) and C2H ch1 tables buffered/drained concurrently");
        end
    endtask

    // Test Sequence
    initial begin
        clk = 0;
        rst_n = 0;
        fetch_start = 0;
        fetch_channel = 3'd0;
        plane0_slot_addr = SLOT0_BASE;
        plane1_slot_addr = UV0_BASE;
        plane0_pages_req = 16'd300;
        plane1_pages_req = 16'd2;
        cpld_valid = 0;
        cpld_data = 0;
        cpld_last = 0;
        cpld_tag = 0;
        captured_cnt = 0;
        captured_uv_cnt = 0;
        channel_y_almost_full = 5'd0;
        channel_uv_almost_full = 5'd0;

        #40;
        rst_n = 1;
        #40;

        $display("=========================================================");
        $display(" Running tb_sg_host_fetch_engine Verification Testbench");
        $display("=========================================================");

        run_test1();
        run_test2();
        run_test3();

        $display("=========================================================");
        $display(" ALL TESTS PASSED: Variable-Length SGL Fetch Verified!");
        $display("=========================================================");
        #100;
        $finish;
    end

endmodule