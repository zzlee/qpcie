// ============================================================================
// Testbench: tb_rq_tx_encoder
// Description: Unit testbench for rq_tx_encoder module
// ============================================================================

`timescale 1ns / 1ps

module tb_rq_tx_encoder;

    parameter DATA_WIDTH = 256;
    parameter KEEP_WIDTH = DATA_WIDTH / 32;

    reg                  clk;
    reg                  rst_n;

    wire [DATA_WIDTH-1:0] m_axis_rq_tdata;
    wire                 m_axis_rq_tvalid;
    wire                 m_axis_rq_tlast;
    wire [59:0]          m_axis_rq_tuser;
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
    wire                 c2h_req_ack;

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
        .c2h_req_ack(c2h_req_ack)
    );

    always #5 clk = ~clk;

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
        $display("[%0t] SUCCESS: RQ TX Encoder Test Completed!", $time);
        $finish;
    end

endmodule
