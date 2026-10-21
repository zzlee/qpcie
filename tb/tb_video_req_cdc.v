`timescale 1ns / 1ps

module tb_video_req_cdc;
    reg wr_clk = 0;
    reg rd_clk = 0;
    reg wr_rst_n = 0;
    reg rd_rst_n = 0;

    always #3.333 wr_clk = ~wr_clk; // 150 MHz
    always #4.000 rd_clk = ~rd_clk; // 125 MHz

    reg         s_req_valid = 0;
    reg  [63:0] s_req_addr = 0;
    reg  [10:0] s_req_dw_len = 0;
    reg  [127:0] s_req_data = 0;
    wire        s_req_data_ready;
    wire        s_req_ack;
    reg         s_frame_done = 0;

    wire        m_req_valid;
    wire [63:0] m_req_addr;
    wire [10:0] m_req_dw_len;
    wire [255:0] m_req_data;
    reg         m_req_data_ready = 0;
    reg         m_req_ack = 0;
    wire        m_frame_done;

    video_req_cdc #(
        .MAX_DWORDS(64),
        .FIFO_DEPTH(512),
        .WR_DATA_WIDTH(128),
        .DATA_WIDTH(256)
    ) dut (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .s_req_valid(s_req_valid),
        .s_req_addr(s_req_addr),
        .s_req_dw_len(s_req_dw_len),
        .s_req_data(s_req_data),
        .s_req_data_ready(s_req_data_ready),
        .s_req_ack(s_req_ack),
        .s_frame_done(s_frame_done),
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n),
        .m_req_valid(m_req_valid),
        .m_req_addr(m_req_addr),
        .m_req_dw_len(m_req_dw_len),
        .m_req_data(m_req_data),
        .m_req_data_ready(m_req_data_ready),
        .m_req_ack(m_req_ack),
        .m_frame_done(m_frame_done),
        .m_fifo_empty(),
        .m_fifo_count()
    );

    integer i;
    reg [255:0] captured_words [0:15];
    integer word_idx;

    initial begin
        $display("[0 ns] Starting tb_video_req_cdc...");
        #50;
        wr_rst_n = 1;
        rd_rst_n = 1;
        #100;

        // Test 1: Send a 256-byte packet (16 x 128-bit words = 8 x 256-bit words)
        $display("[%0t] Test 1: Sending Packet 0 (256B, Addr=0x1000_0000)...", $time);
        @(posedge wr_clk);
        s_req_valid  <= 1;
        s_req_addr   <= 64'h1000_0000;
        s_req_dw_len <= 11'd64; // 256 bytes
        s_req_data   <= {64'hAAAA_BBBB_CCCC_DDD0, 64'h1111_2222_3333_4440};

        i = 0;
        while (i < 16) begin
            @(posedge wr_clk);
            if (s_req_data_ready) begin
                i = i + 1;
                s_req_data <= {64'hAAAA_BBBB_CCCC_DDD0 + i, 64'h1111_2222_3333_4440 + i};
            end
        end
        while (!s_req_ack) @(posedge wr_clk);
        s_req_valid <= 0;

        // On reader side, wait for m_req_valid
        @(posedge rd_clk);
        while (!m_req_valid) @(posedge rd_clk);
        if (m_req_addr !== 64'h1000_0000 || m_req_dw_len !== 11'd64) begin
            $display("ERROR: Header mismatch! Addr=%h len=%d", m_req_addr, m_req_dw_len);
            $fatal(1);
        end

        // Read 8 x 256-bit words
        for (word_idx = 0; word_idx < 8; word_idx = word_idx + 1) begin
            m_req_data_ready = 1;
            @(posedge rd_clk);
            captured_words[word_idx] = m_req_data;
        end
        m_req_data_ready = 0;
        m_req_ack = 1;
        @(posedge rd_clk);
        m_req_ack = 0;

        // Verify captured words for Packet 0
        for (word_idx = 0; word_idx < 8; word_idx = word_idx + 1) begin
            $display("  Packet 0 Word %0d: %h", word_idx, captured_words[word_idx]);
        end
        if (captured_words[0][63:0] !== 64'h1111_2222_3333_4440) begin
            $display("ERROR: Packet 0 Word 0 corrupted: %h", captured_words[0]);
            $fatal(1);
        end
        $display("[%0t] Test 1 PASS: Packet 0 received cleanly!", $time);

        // Test 2: Inactivity & Spurious data_ready when idle / EOF
        $display("[%0t] Test 2: Spurious data_ready while idle / sending EOF...", $time);
        // Pulse m_req_data_ready several times while m_req_valid == 0
        repeat (5) begin
            m_req_data_ready = 1;
            @(posedge rd_clk);
        end
        m_req_data_ready = 0;

        // Send EOF on wr_clk
        @(posedge wr_clk);
        s_frame_done = 1;
        @(posedge wr_clk);
        s_frame_done = 0;

        // Wait for m_frame_done on rd_clk while asserting m_req_data_ready
        repeat (10) begin
            m_req_data_ready = 1;
            @(posedge rd_clk);
            if (m_frame_done) begin
                $display("[%0t] m_frame_done received successfully!", $time);
            end
        end
        m_req_data_ready = 0;

        // Test 3: Send Packet 1 (256B, Addr=0x1000_0100)
        // Verify that the spurious data_ready did NOT discard word 0 of Packet 1!
        $display("[%0t] Test 3: Sending Packet 1 (256B, Addr=0x1000_0100)...", $time);
        @(posedge wr_clk);
        s_req_valid  <= 1;
        s_req_addr   <= 64'h1000_0100;
        s_req_dw_len <= 11'd64;

        s_req_data   <= {64'hEEEE_FFFF_0000_1110, 64'h5555_6666_7777_8880};

        i = 0;
        while (i < 16) begin
            @(posedge wr_clk);
            if (s_req_data_ready) begin
                i = i + 1;
                s_req_data <= {64'hEEEE_FFFF_0000_1110 + i, 64'h5555_6666_7777_8880 + i};
            end
        end
        while (!s_req_ack) @(posedge wr_clk);
        s_req_valid <= 0;

        @(posedge rd_clk);
        while (!m_req_valid) @(posedge rd_clk);

        for (word_idx = 0; word_idx < 8; word_idx = word_idx + 1) begin
            m_req_data_ready = 1;
            @(posedge rd_clk);
            captured_words[word_idx] = m_req_data;
        end
        m_req_data_ready = 0;
        m_req_ack = 1;
        @(posedge rd_clk);
        m_req_ack = 0;

        for (word_idx = 0; word_idx < 8; word_idx = word_idx + 1) begin
            $display("  Packet 1 Word %0d: %h", word_idx, captured_words[word_idx]);
        end
        if (captured_words[0][63:0] !== 64'h5555_6666_7777_8880) begin
            $display("ERROR: Packet 1 Word 0 MISMATCH (bleed/discard detected)! Got: %h, expected low 64b: 5555666677778880", captured_words[0]);
            $fatal(1);
        end

        $display("[%0t] ALL video_req_cdc TESTS PASSED WITH 100%% INTEGRITY!", $time);
        $finish;
    end

endmodule
