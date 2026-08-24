// ============================================================================
// Testbench: tb_rq_tx_encoder
// Description: Unit testbench for rq_tx_encoder module
// ============================================================================

`timescale 1ns / 1ps

module tb_rq_tx_encoder;

    parameter DATA_WIDTH = 128;
    parameter KEEP_WIDTH = DATA_WIDTH / 8;

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
    reg  [DATA_WIDTH-1:0] c2h_req_data;
    reg                  c2h_req_last;
    wire                 c2h_req_data_ready;
    wire                 c2h_req_ack;
    reg                  burst_mode;

    // Instantiate uut
    rq_tx_encoder #(
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
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

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (burst_mode && c2h_req_data_ready)
            c2h_req_data <= c2h_req_data + 1'b1;
    end

    integer burst_beat;
    reg [127:0] held_data;

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
        c2h_req_data = 0;
        c2h_req_last = 0;
        burst_mode = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Send Desc Fetch MRd TLP (Addr=0x8000_1000, DW Len=8, Tag=0x01)...", $time);
        @(posedge clk);
        desc_req_valid  <= 1;
        desc_req_addr   <= 64'h8000_1000;
        desc_req_dw_len <= 11'd8;
        desc_req_tag    <= 8'h01;

        wait(m_axis_rq_tvalid);
        $display("[%0t] RQ Encoder output MRd Header: 0x%h", $time, m_axis_rq_tdata[127:0]);
        wait(desc_req_ack);
        @(posedge clk);
        desc_req_valid  <= 0;

        #30;
        $display("[%0t] Test 2: Send IRQ Request Message TLP (Vector 0x05)...", $time);
        @(posedge clk);
        irq_req_valid <= 1;
        irq_req_code  <= 8'h05;

        wait(m_axis_rq_tvalid);
        $display("[%0t] RQ Encoder output Msg Header: 0x%h", $time, m_axis_rq_tdata[127:0]);
        wait(irq_req_ack);
        @(posedge clk);
        irq_req_valid <= 0;

        #30;
        $display("[%0t] Test 3: 128-bit C2H MWr under backpressure...", $time);
        m_axis_rq_tready <= 0;
        c2h_req_addr <= 64'h1234_5678_9ABC_DEF0;
        c2h_req_dw_len <= 11'd4;
        c2h_req_data <= 128'h44444444_33333333_22222222_11111111;
        c2h_req_last <= 1;
        c2h_req_valid <= 1;
        wait(m_axis_rq_tvalid);
        if (m_axis_rq_tdata[78:75] !== 4'b0001 || m_axis_rq_tlast !== 0) begin
            $display("FAIL: C2H header beat malformed");
            $finish;
        end
        #20;
        if (m_axis_rq_tdata[63:0] !== 64'h1234_5678_9ABC_DEF0) begin
            $display("FAIL: C2H header changed under backpressure");
            $finish;
        end
        m_axis_rq_tready <= 1;
        #1; @(posedge clk); #1;
        if (!m_axis_rq_tvalid || !m_axis_rq_tlast ||
            m_axis_rq_tdata !== 128'h44444444_33333333_22222222_11111111) begin
            $display("FAIL: C2H payload beat malformed valid=%b last=%b data=%h", m_axis_rq_tvalid, m_axis_rq_tlast, m_axis_rq_tdata);
            $finish;
        end
        @(posedge clk); #1;
        if (!c2h_req_ack) begin
            $display("FAIL: C2H acknowledgement missing");
            $finish;
        end
        c2h_req_valid <= 0;

        #30;
        $display("[%0t] Test 4: 128-byte/8-beat C2H MWr with payload backpressure...", $time);
        c2h_req_addr <= 64'h0000_0001_2345_6780;
        c2h_req_dw_len <= 11'd32;
        c2h_req_data <= 128'hA5A5_0000_0000_0000_0000_0000_0000_0000;
        c2h_req_last <= 1;
        c2h_req_valid <= 1;
        burst_mode <= 1;

        wait(m_axis_rq_tvalid);
        if (m_axis_rq_tdata[78:75] !== 4'b0001 ||
            m_axis_rq_tdata[74:64] !== 11'd32 || m_axis_rq_tlast !== 0)
            $fatal(1, "128-byte MWr header malformed");
        @(posedge clk); #1;

        for (burst_beat = 0; burst_beat < 8; burst_beat = burst_beat + 1) begin
            wait(m_axis_rq_tvalid);
            if (m_axis_rq_tdata !==
                (128'hA5A5_0000_0000_0000_0000_0000_0000_0000 + burst_beat))
                $fatal(1, "Burst payload beat %0d mismatch: %h", burst_beat,
                       m_axis_rq_tdata);
            if (m_axis_rq_tlast !== (burst_beat == 7))
                $fatal(1, "Burst TLAST mismatch on beat %0d", burst_beat);
            if (m_axis_rq_tkeep !== 16'hffff)
                $fatal(1, "Burst TKEEP mismatch on beat %0d", burst_beat);

            if (burst_beat == 3) begin
                held_data = m_axis_rq_tdata;
                m_axis_rq_tready <= 0;
                repeat (3) begin
                    @(posedge clk); #1;
                    if (!m_axis_rq_tvalid || m_axis_rq_tdata !== held_data)
                        $fatal(1, "Burst payload changed under backpressure");
                end
                m_axis_rq_tready <= 1;
            end
            @(posedge clk); #1;
        end
        if (!c2h_req_ack)
            $fatal(1, "128-byte MWr acknowledgement missing");
        burst_mode <= 0;
        c2h_req_valid <= 0;

        #30;
        $display("[%0t] SUCCESS: RQ TX Encoder Test Completed!", $time);
        $finish;
    end

endmodule
