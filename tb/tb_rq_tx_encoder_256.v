// ============================================================================
// Testbench: tb_rq_tx_encoder_256
// Description: Unit testbench for rq_tx_encoder module in 256-bit UltraScale+ mode
// ============================================================================

`timescale 1ns / 1ps

module tb_rq_tx_encoder_256;

    parameter DATA_WIDTH = 256;
    parameter KEEP_WIDTH = 8; // 8 DWs for 256-bit

    reg                  clk;
    reg                  rst_n;

    wire [DATA_WIDTH-1:0] m_axis_rq_tdata;
    wire                 m_axis_rq_tvalid;
    wire                 m_axis_rq_tlast;
    wire [61:0]          m_axis_rq_tuser;
    wire [KEEP_WIDTH-1:0] m_axis_rq_tkeep;
    reg                  m_axis_rq_tready;

    reg                  irq_req_valid;
    reg  [7:0]           irq_req_code;
    wire                 irq_req_ack;

    reg                  desc_req_valid;
    reg  [63:0]          desc_req_addr;
    reg  [10:0]          desc_req_dw_len;
    reg  [7:0]           desc_req_tag;
    wire                 desc_req_ack;

    reg                  h2c_req_valid;
    reg  [63:0]          h2c_req_addr;
    reg  [10:0]          h2c_req_dw_len;
    reg  [7:0]           h2c_req_tag;
    wire                 h2c_req_ack;

    reg                  c2h_req_valid;
    reg  [63:0]          c2h_req_addr;
    reg  [10:0]          c2h_req_dw_len;
    wire [DATA_WIDTH-1:0] c2h_req_data;
    reg                  c2h_req_last;
    wire                 c2h_req_data_ready;
    wire                 c2h_req_ack;

    // Simulation source FIFO (mimics FWFT video/audio FIFO)
    reg [127:0] src_fifo [0:31];
    reg [4:0]   src_rd_ptr;

    // Instantiate uut
    rq_tx_encoder #(
        .DATA_WIDTH(DATA_WIDTH),
        .KEEP_WIDTH(KEEP_WIDTH),
        .REQUESTER_ID(16'h0300)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .requester_id(16'h0300),
        .m_axis_rq_tdata(m_axis_rq_tdata),
        .m_axis_rq_tvalid(m_axis_rq_tvalid),
        .m_axis_rq_tlast(m_axis_rq_tlast),
        .m_axis_rq_tuser(m_axis_rq_tuser),
        .m_axis_rq_tkeep(m_axis_rq_tkeep),
        .m_axis_rq_tready(m_axis_rq_tready),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .desc_req_valid(desc_req_valid),
        .desc_req_addr(desc_req_addr),
        .desc_req_dw_len(desc_req_dw_len),
        .desc_req_tag(desc_req_tag),
        .desc_req_ack(desc_req_ack),
        .sg_req_valid(1'b0),
        .sg_req_addr(64'd0),
        .sg_req_dw_len(11'd0),
        .sg_req_tag(8'd0),
        .sg_req_ack(),
        .h2c_req_valid(h2c_req_valid),
        .h2c_req_addr(h2c_req_addr),
        .h2c_req_dw_len(h2c_req_dw_len),
        .h2c_req_tag(h2c_req_tag),
        .h2c_req_ack(h2c_req_ack),
        .c2h_req_valid(c2h_req_valid),
        .c2h_req_addr(c2h_req_addr),
        .c2h_req_dw_len(c2h_req_dw_len),
        .c2h_req_data(c2h_req_data),
        .c2h_req_last(c2h_req_last),
        .c2h_req_data_ready(c2h_req_data_ready),
        .c2h_req_ack(c2h_req_ack)
    );

    always #4 clk = ~clk; // 125 MHz clock (8 ns period)

    // FWFT source FIFO: 256-bit native stream {src_fifo[2k+1], src_fifo[2k]}
    assign c2h_req_data = {src_fifo[2*src_rd_ptr + 1], src_fifo[2*src_rd_ptr]};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_rd_ptr <= 0;
        end else begin
            if (c2h_req_data_ready) begin
                src_rd_ptr <= src_rd_ptr + 1'b1;
            end
        end
    end

    integer i;

    initial begin
        clk = 0;
        rst_n = 0;
        m_axis_rq_tready = 1;
        irq_req_valid = 0;
        irq_req_code = 0;
        desc_req_valid = 0;
        desc_req_addr = 0;
        desc_req_dw_len = 0;
        desc_req_tag = 0;
        h2c_req_valid = 0;
        h2c_req_addr = 0;
        h2c_req_dw_len = 0;
        h2c_req_tag = 0;
        c2h_req_valid = 0;
        c2h_req_addr = 0;
        c2h_req_dw_len = 0;
        c2h_req_last = 0;
        src_rd_ptr = 0;

        // Populate test FIFO
        for (i = 0; i < 32; i = i + 1) begin
            src_fifo[i] = {32'hBEEF0000 + i, 32'hCAFE0000 + i, 32'hDEAD0000 + i, 32'hFEED0000 + i};
        end

        #24;
        rst_n = 1;
        #16;

        // -----------------------------------------------------------------
        // Test 1: MRd Descriptor Fetch (Single Beat, No Payload)
        // -----------------------------------------------------------------
        $display("[%0t] Test 1: Desc Fetch MRd (Addr=0x8000_1000, DW Len=8)...", $time);
        @(posedge clk); #1;
        desc_req_addr   <= 64'h8000_1000;
        desc_req_dw_len <= 11'd8;
        desc_req_tag    <= 8'h01;
        desc_req_valid  <= 1'b1;

        wait(m_axis_rq_tvalid);
        if (m_axis_rq_tdata[78:75] !== 4'b0000 || m_axis_rq_tdata[74:64] !== 11'd8 || !m_axis_rq_tlast)
            $fatal(1, "Test 1 FAIL: MRd malformed");
        @(posedge clk); #1;
        if (!desc_req_ack)
            $fatal(1, "Test 1 FAIL: desc_req_ack missing");
        desc_req_valid <= 0;
        @(posedge clk); #1;
        $display("[%0t] Test 1 PASS!", $time);

        #16;

        // -----------------------------------------------------------------
        // Test 2: Audio C2H MWr (DW Len = 4, 16 Bytes -> Single Beat in DW4..DW7!)
        // -----------------------------------------------------------------
        $display("[%0t] Test 2: Audio C2H MWr (DW Len = 4, single beat)...", $time);
        src_rd_ptr <= 0;
        @(posedge clk); #1;
        c2h_req_addr <= 64'h1_1395_0000;
        c2h_req_dw_len <= 11'd4;
        c2h_req_last <= 1;
        c2h_req_valid <= 1;

        wait(m_axis_rq_tvalid);
        #1;
        // Verify DW0..DW3 header
        if (m_axis_rq_tdata[63:0] !== 64'h1_1395_0000)
            $fatal(1, "Test 2 FAIL: Addr mismatch: %h", m_axis_rq_tdata[63:0]);
        if (m_axis_rq_tdata[74:64] !== 11'd4)
            $fatal(1, "Test 2 FAIL: DW Len mismatch: %d", m_axis_rq_tdata[74:64]);
        if (m_axis_rq_tdata[78:75] !== 4'b0001)
            $fatal(1, "Test 2 FAIL: Req type not MWr: %b", m_axis_rq_tdata[78:75]);
        // Verify DW4..DW7 payload contains src_fifo[0]!
        if (m_axis_rq_tdata[255:128] !== src_fifo[0])
            $fatal(1, "Test 2 FAIL: DW4..DW7 payload mismatch! Got %h, Expected %h",
                   m_axis_rq_tdata[255:128], src_fifo[0]);
        if (m_axis_rq_tkeep !== 8'hFF)
            $fatal(1, "Test 2 FAIL: TKEEP mismatch: %h", m_axis_rq_tkeep);
        if (!m_axis_rq_tlast)
            $fatal(1, "Test 2 FAIL: TLAST should be 1 for 4-DW packet!");

        @(posedge clk); #1;
        if (!c2h_req_ack)
            $fatal(1, "Test 2 FAIL: c2h_req_ack missing!");
        c2h_req_valid <= 0;
        @(posedge clk); #1;
        $display("[%0t] Test 2 PASS: Audio single-beat MWr correctly packed into DW4..DW7!", $time);

        #16;

        // -----------------------------------------------------------------
        // Test 3: Video 256-byte C2H MWr (DW Len = 64, 16 beats from source)
        // Beat 0: Header (DW0..DW3) + Payload Beat 0 (DW4..DW7), tlast = 0
        // Beat 1: Payload {Beat 2, Beat 1}, tkeep = 8'hFF, tlast = 0
        // ...
        // Beat 8: Payload {128'd0, Beat 15}, tkeep = 8'h0F, tlast = 1
        // -----------------------------------------------------------------
        $display("[%0t] Test 3: Video 256-byte C2H MWr (DW Len = 64)...", $time);
        src_rd_ptr <= 0;
        @(posedge clk); #1;
        c2h_req_addr <= 64'h1_56E0_0000;
        c2h_req_dw_len <= 11'd64;
        c2h_req_last <= 1;
        c2h_req_valid <= 1;

        // Verify Beat 0
        wait(m_axis_rq_tvalid);
        #1;
        if (m_axis_rq_tdata[63:0] !== 64'h1_56E0_0000)
            $fatal(1, "Test 3 Beat 0 FAIL: Addr mismatch");
        if (m_axis_rq_tdata[74:64] !== 11'd64)
            $fatal(1, "Test 3 Beat 0 FAIL: DW Len mismatch");
        if (m_axis_rq_tdata[255:128] !== src_fifo[0])
            $fatal(1, "Test 3 Beat 0 FAIL: Payload Beat 0 mismatch");
        if (m_axis_rq_tkeep !== 8'hFF)
            $fatal(1, "Test 3 Beat 0 FAIL: TKEEP mismatch");
        if (m_axis_rq_tlast !== 1'b0)
            $fatal(1, "Test 3 Beat 0 FAIL: TLAST should be 0");
        @(posedge clk); #1;

        // Verify Beats 1 through 7 (each carries 2 source beats)
        for (i = 1; i <= 7; i = i + 1) begin
            wait(m_axis_rq_tvalid);
            #1;
            if (m_axis_rq_tdata !== {src_fifo[2*i], src_fifo[2*i - 1]})
                $fatal(1, "Test 3 Beat %0d FAIL: Expected {%h, %h}, Got %h",
                       i, src_fifo[2*i], src_fifo[2*i - 1], m_axis_rq_tdata);
            if (m_axis_rq_tkeep !== 8'hFF)
                $fatal(1, "Test 3 Beat %0d FAIL: TKEEP mismatch", i);
            if (m_axis_rq_tlast !== 1'b0)
                $fatal(1, "Test 3 Beat %0d FAIL: TLAST should be 0", i);
            @(posedge clk); #1;
        end

        // Verify Beat 8 (final beat: carries Beat 15 in lower 128 bits, tkeep = 8'h0F, tlast = 1)
        wait(m_axis_rq_tvalid);
        #1;
        if (m_axis_rq_tdata[127:0] !== src_fifo[15])
            $fatal(1, "Test 3 Beat 8 FAIL: Lower 128b payload mismatch: Got %h, Exp %h",
                   m_axis_rq_tdata[127:0], src_fifo[15]);
        if (m_axis_rq_tkeep !== 8'h0F)
            $fatal(1, "Test 3 Beat 8 FAIL: TKEEP mismatch: Got %h, Exp 8'h0F", m_axis_rq_tkeep);
        if (m_axis_rq_tlast !== 1'b1)
            $fatal(1, "Test 3 Beat 8 FAIL: TLAST should be 1");
        @(posedge clk); #1;

        if (!c2h_req_ack)
            $fatal(1, "Test 3 FAIL: c2h_req_ack missing!");
        c2h_req_valid <= 0;
        @(posedge clk); #1;
        if (src_rd_ptr !== 5'd8)
            $fatal(1, "Test 3 FAIL: FIFO pop count mismatch! Expected 8 pops, got %0d", src_rd_ptr);
        $display("[%0t] Test 3 PASS: Video 256-byte MWr transferred across 9 beats with 100%% precision (exact 8 FIFO pops)!", $time);

        #16;

        // -----------------------------------------------------------------
        // Test 4: Video 128-byte C2H MWr (DW Len = 32, 8 beats from source)
        // -----------------------------------------------------------------
        $display("[%0t] Test 4: Video 128-byte C2H MWr (DW Len = 32)...", $time);
        src_rd_ptr <= 0;
        @(posedge clk); #1;
        c2h_req_addr <= 64'h1_56E0_1000;
        c2h_req_dw_len <= 11'd32;
        c2h_req_last <= 1;
        c2h_req_valid <= 1;

        // Verify Beat 0: Header + Beat 0
        wait(m_axis_rq_tvalid);
        #1;
        if (m_axis_rq_tdata[74:64] !== 11'd32)
            $fatal(1, "Test 4 Beat 0 FAIL: DW Len mismatch");
        if (m_axis_rq_tdata[255:128] !== src_fifo[0])
            $fatal(1, "Test 4 Beat 0 FAIL: Payload Beat 0 mismatch");
        @(posedge clk); #1;

        // Verify Beats 1 through 3
        for (i = 1; i <= 3; i = i + 1) begin
            wait(m_axis_rq_tvalid);
            #1;
            if (m_axis_rq_tdata !== {src_fifo[2*i], src_fifo[2*i - 1]})
                $fatal(1, "Test 4 Beat %0d FAIL", i);
            @(posedge clk); #1;
        end

        // Verify Beat 4: Beat 7 in lower 128 bits
        wait(m_axis_rq_tvalid);
        #1;
        if (m_axis_rq_tdata[127:0] !== src_fifo[7])
            $fatal(1, "Test 4 Beat 4 FAIL: Got %h, Exp %h", m_axis_rq_tdata[127:0], src_fifo[7]);
        if (m_axis_rq_tkeep !== 8'h0F || !m_axis_rq_tlast)
            $fatal(1, "Test 4 Beat 4 FAIL: tkeep or tlast mismatch");
        @(posedge clk); #1;

        if (!c2h_req_ack)
            $fatal(1, "Test 4 FAIL: c2h_req_ack missing!");
        c2h_req_valid <= 0;
        @(posedge clk); #1;
        if (src_rd_ptr !== 5'd4)
            $fatal(1, "Test 4 FAIL: FIFO pop count mismatch! Expected 4 pops, got %0d", src_rd_ptr);
        $display("[%0t] Test 4 PASS: Video 128-byte MWr transferred cleanly (exact 4 FIFO pops)!", $time);

        #16;

        // -----------------------------------------------------------------
        // Test 5: Backpressure handling (tready deasserted mid-packet)
        // -----------------------------------------------------------------
        $display("[%0t] Test 5: Backpressure handling on 128-byte MWr...", $time);
        src_rd_ptr <= 0;
        @(posedge clk); #1;
        c2h_req_addr <= 64'h1_56E0_2000;
        c2h_req_dw_len <= 11'd32;
        c2h_req_valid <= 1;

        // Beat 0: insert 2 cycles of tready deassertion
        wait(m_axis_rq_tvalid);
        #1;
        m_axis_rq_tready <= 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        m_axis_rq_tready <= 1;
        @(posedge clk); #1;

        // Let the rest stream through
        wait(m_axis_rq_tvalid && m_axis_rq_tlast);
        @(posedge clk); #1;
        if (!c2h_req_ack)
            $fatal(1, "Test 5 FAIL: c2h_req_ack missing!");
        c2h_req_valid <= 0;
        @(posedge clk); #1;
        if (src_rd_ptr !== 5'd4)
            $fatal(1, "Test 5 FAIL: FIFO pop count mismatch under backpressure! Expected 4 pops, got %0d", src_rd_ptr);
        $display("[%0t] Test 5 PASS: Backpressure survived with 0 corruption (exact 4 FIFO pops)!", $time);

        #32;
        $display("[%0t] ALL 256-BIT RQ TESTS PASSED!", $time);
        $finish;
    end

endmodule
