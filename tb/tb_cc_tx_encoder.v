// ============================================================================
// Testbench: tb_cc_tx_encoder
// Description: Unit testbench for cc_tx_encoder module with Dual-BAR (BAR0 & BAR1)
// ============================================================================

`timescale 1ns / 1ps

module tb_cc_tx_encoder;

    parameter DATA_WIDTH = 256;
    parameter KEEP_WIDTH = DATA_WIDTH / 32;

    reg                  clk;
    reg                  rst_n;

    wire [DATA_WIDTH-1:0] m_axis_cc_tdata;
    wire                 m_axis_cc_tvalid;
    wire                 m_axis_cc_tlast;
    wire [32:0]          m_axis_cc_tuser;
    wire [KEEP_WIDTH-1:0] m_axis_cc_tkeep;
    reg                  m_axis_cc_tready;

    reg                  read_req_valid;
    reg  [7:0]           read_req_tag;
    reg  [15:0]          read_req_id;
    reg  [6:0]           read_req_lower_addr;
    reg  [10:0]          read_req_tc;
    reg                  read_req_bar_sel;
    wire                 read_req_ack;

    reg  [31:0]          bar0_axil_rdata;
    reg  [1:0]           bar0_axil_rresp;
    reg                  bar0_axil_rvalid;
    wire                 bar0_axil_rready;

    reg  [31:0]          bar1_axil_rdata;
    reg  [1:0]           bar1_axil_rresp;
    reg                  bar1_axil_rvalid;
    wire                 bar1_axil_rready;

    // Instantiate uut
    cc_tx_encoder #(
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .m_axis_cc_tdata(m_axis_cc_tdata),
        .m_axis_cc_tvalid(m_axis_cc_tvalid),
        .m_axis_cc_tlast(m_axis_cc_tlast),
        .m_axis_cc_tuser(m_axis_cc_tuser),
        .m_axis_cc_tkeep(m_axis_cc_tkeep),
        .m_axis_cc_tready(m_axis_cc_tready),
        .read_req_valid(read_req_valid),
        .read_req_tag(read_req_tag),
        .read_req_id(read_req_id),
        .read_req_lower_addr(read_req_lower_addr),
        .read_req_tc(read_req_tc),
        .read_req_bar_sel(read_req_bar_sel),
        .read_req_ack(read_req_ack),
        .bar0_axil_rdata(bar0_axil_rdata),
        .bar0_axil_rresp(bar0_axil_rresp),
        .bar0_axil_rvalid(bar0_axil_rvalid),
        .bar0_axil_rready(bar0_axil_rready),
        .bar1_axil_rdata(bar1_axil_rdata),
        .bar1_axil_rresp(bar1_axil_rresp),
        .bar1_axil_rvalid(bar1_axil_rvalid),
        .bar1_axil_rready(bar1_axil_rready)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        m_axis_cc_tready = 1;
        read_req_valid = 0;
        read_req_tag = 0;
        read_req_id = 0;
        read_req_lower_addr = 0;
        read_req_tc = 0;
        read_req_bar_sel = 0;
        bar0_axil_rdata = 32'hDEADBEEF;
        bar0_axil_rresp = 0;
        bar0_axil_rvalid = 0;
        bar1_axil_rdata = 32'hCAFEBABE;
        bar1_axil_rresp = 0;
        bar1_axil_rvalid = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: BAR0 Read Completion (Data 0xDEADBEEF)...", $time);
        @(posedge clk);
        read_req_valid      <= 1;
        read_req_tag        <= 8'h05;
        read_req_id         <= 16'h0100;
        read_req_lower_addr <= 7'h04;
        read_req_tc         <= 11'd1;
        read_req_bar_sel    <= 1'b0; // BAR0

        wait(read_req_ack);
        @(posedge clk);
        read_req_valid <= 0;

        #10;
        @(posedge clk);
        bar0_axil_rvalid <= 1;

        wait(m_axis_cc_tvalid);
        $display("[%0t] BAR0 CC TLP generated! Tag: 0x%h Data: 0x%h", $time, m_axis_cc_tdata[58:51], m_axis_cc_tdata[127:96]);
        @(posedge clk);
        bar0_axil_rvalid <= 0;

        #30;
        $display("[%0t] Test 2: BAR1 Read Completion (Data 0xCAFEBABE)...", $time);
        @(posedge clk);
        read_req_valid      <= 1;
        read_req_tag        <= 8'h09;
        read_req_id         <= 16'h0100;
        read_req_lower_addr <= 7'h08;
        read_req_tc         <= 11'd1;
        read_req_bar_sel    <= 1'b1; // BAR1

        wait(read_req_ack);
        @(posedge clk);
        read_req_valid <= 0;

        #10;
        @(posedge clk);
        bar1_axil_rvalid <= 1;

        wait(m_axis_cc_tvalid);
        $display("[%0t] BAR1 CC TLP generated! Tag: 0x%h Data: 0x%h", $time, m_axis_cc_tdata[58:51], m_axis_cc_tdata[127:96]);
        @(posedge clk);
        bar1_axil_rvalid <= 0;

        #30;
        $display("[%0t] SUCCESS: Dual-BAR CC TX Encoder Test Completed!", $time);
        $finish;
    end

endmodule
