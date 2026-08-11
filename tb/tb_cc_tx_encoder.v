// ============================================================================
// Testbench: tb_cc_tx_encoder
// Description: Unit testbench for cc_tx_encoder module
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
    wire                 read_req_ack;

    reg  [31:0]          axil_rdata;
    reg  [1:0]           axil_rresp;
    reg                  axil_rvalid;
    wire                 axil_rready;

    // Instantiate UUT
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
        .read_req_ack(read_req_ack),
        .axil_rdata(axil_rdata),
        .axil_rresp(axil_rresp),
        .axil_rvalid(axil_rvalid),
        .axil_rready(axil_rready)
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
        axil_rdata = 0;
        axil_rresp = 0;
        axil_rvalid = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Send CplD Response (Tag=0x07, Data=0xABCD1234)...", $time);
        @(posedge clk);
        read_req_valid      <= 1;
        read_req_tag        <= 8'h07;
        read_req_id         <= 16'h0200;
        read_req_lower_addr <= 7'h10;
        read_req_tc         <= 11'd1;

        axil_rdata          <= 32'hABCD1234;
        axil_rresp          <= 2'b00;
        axil_rvalid         <= 1;

        wait(m_axis_cc_tvalid);
        $display("[%0t] CC Encoder output TLP Header & Payload:", $time);
        $display("       DW0-DW2 Header: 0x%h", m_axis_cc_tdata[95:0]);
        $display("       DW3 Payload Data: 0x%h", m_axis_cc_tdata[127:96]);

        wait(read_req_ack);
        @(posedge clk);
        read_req_valid <= 0;
        axil_rvalid    <= 0;

        #30;
        $display("[%0t] SUCCESS: CC TX Encoder Test Completed!", $time);
        $finish;
    end

endmodule
