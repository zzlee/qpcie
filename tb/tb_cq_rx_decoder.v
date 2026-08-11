// ============================================================================
// Testbench: tb_cq_rx_decoder
// Description: Unit testbench for cq_rx_decoder module
// ============================================================================

`timescale 1ns / 1ps

module tb_cq_rx_decoder;

    parameter DATA_WIDTH = 256;
    parameter KEEP_WIDTH = DATA_WIDTH / 32;

    reg                  clk;
    reg                  rst_n;

    reg  [DATA_WIDTH-1:0] s_axis_cq_tdata;
    reg                  s_axis_cq_tvalid;
    reg                  s_axis_cq_tlast;
    reg  [87:0]          s_axis_cq_tuser;
    reg  [KEEP_WIDTH-1:0] s_axis_cq_tkeep;
    wire                 s_axis_cq_tready;

    wire [31:0]          m_axil_awaddr;
    wire                 m_axil_awvalid;
    reg                  m_axil_awready;

    wire [31:0]          m_axil_wdata;
    wire [3:0]           m_axil_wstrb;
    wire                 m_axil_wvalid;
    reg                  m_axil_wready;

    reg  [1:0]           m_axil_bresp;
    reg                  m_axil_bvalid;
    wire                 m_axil_bready;

    wire [31:0]          m_axil_araddr;
    wire                 m_axil_arvalid;
    reg                  m_axil_arready;

    reg  [31:0]          m_axil_rdata;
    reg  [1:0]           m_axil_rresp;
    reg                  m_axil_rvalid;
    wire                 m_axil_rready;

    wire                 read_req_valid;
    wire [7:0]           read_req_tag;
    wire [15:0]          read_req_id;
    wire [6:0]           read_req_lower_addr;
    wire [10:0]          read_req_tc;
    reg                  read_req_ack;

    // Instantiate uut
    cq_rx_decoder #(
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_cq_tdata(s_axis_cq_tdata),
        .s_axis_cq_tvalid(s_axis_cq_tvalid),
        .s_axis_cq_tlast(s_axis_cq_tlast),
        .s_axis_cq_tuser(s_axis_cq_tuser),
        .s_axis_cq_tkeep(s_axis_cq_tkeep),
        .s_axis_cq_tready(s_axis_cq_tready),
        .m_axil_awaddr(m_axil_awaddr),
        .m_axil_awvalid(m_axil_awvalid),
        .m_axil_awready(m_axil_awready),
        .m_axil_wdata(m_axil_wdata),
        .m_axil_wstrb(m_axil_wstrb),
        .m_axil_wvalid(m_axil_wvalid),
        .m_axil_wready(m_axil_wready),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_bvalid(m_axil_bvalid),
        .m_axil_bready(m_axil_bready),
        .m_axil_araddr(m_axil_araddr),
        .m_axil_arvalid(m_axil_arvalid),
        .m_axil_arready(m_axil_arready),
        .m_axil_rdata(m_axil_rdata),
        .m_axil_rresp(m_axil_rresp),
        .m_axil_rvalid(m_axil_rvalid),
        .m_axil_rready(m_axil_rready),
        .read_req_valid(read_req_valid),
        .read_req_tag(read_req_tag),
        .read_req_id(read_req_id),
        .read_req_lower_addr(read_req_lower_addr),
        .read_req_tc(read_req_tc),
        .read_req_ack(read_req_ack)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        s_axis_cq_tdata = 0;
        s_axis_cq_tvalid = 0;
        s_axis_cq_tlast = 0;
        s_axis_cq_tuser = 0;
        s_axis_cq_tkeep = 8'hFF;
        m_axil_awready = 1;
        m_axil_wready = 1;
        m_axil_bresp = 0;
        m_axil_bvalid = 0;
        m_axil_arready = 1;
        m_axil_rdata = 32'hDEADBEEF;
        m_axil_rresp = 0;
        m_axil_rvalid = 0;
        read_req_ack = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Send Host MWr TLP (Address 0x10, Data 0x12345678)...", $time);
        @(posedge clk);
        s_axis_cq_tvalid <= 1;
        s_axis_cq_tlast  <= 1;
        // DW0-DW1: Addr=0x10, DW2: Len=1, Type=0001 (MWr), DW3: ReqID=0x0100, Tag=0x05, BAR=0
        s_axis_cq_tdata[63:0]    <= 64'h00000000_00000010;
        s_axis_cq_tdata[74:64]   <= 11'd1;
        s_axis_cq_tdata[78:75]   <= 4'b0001; // MWr
        s_axis_cq_tdata[95:80]   <= 16'h0100;
        s_axis_cq_tdata[103:96]  <= 8'h05;
        s_axis_cq_tdata[114:112] <= 3'b000;
        s_axis_cq_tdata[159:128] <= 32'h12345678; // Payload

        @(posedge clk);
        s_axis_cq_tvalid <= 0;

        // Wait for AXI4-Lite Write transaction
        wait(m_axil_awvalid && m_axil_wvalid);
        $display("[%0t] CQ Decoder output AXI-Lite Write Addr: 0x%h Data: 0x%h", $time, m_axil_awaddr, m_axil_wdata);

        @(posedge clk);
        m_axil_bvalid <= 1;
        @(posedge clk);
        m_axil_bvalid <= 0;

        #30;
        $display("[%0t] Test 2: Send Host MRd TLP (Address 0x20)...", $time);
        @(posedge clk);
        s_axis_cq_tvalid <= 1;
        s_axis_cq_tlast  <= 1;
        s_axis_cq_tdata[63:0]    <= 64'h00000000_00000020;
        s_axis_cq_tdata[74:64]   <= 11'd1;
        s_axis_cq_tdata[78:75]   <= 4'b0000; // MRd
        s_axis_cq_tdata[95:80]   <= 16'h0100;
        s_axis_cq_tdata[103:96]  <= 8'h0A;
        s_axis_cq_tdata[114:112] <= 3'b000;

        @(posedge clk);
        s_axis_cq_tvalid <= 0;

        wait(m_axil_arvalid);
        $display("[%0t] CQ Decoder output AXI-Lite Read Addr: 0x%h", $time, m_axil_araddr);

        wait(read_req_valid);
        $display("[%0t] CQ Decoder generated Read Req Sideband: Tag=0x%h, ReqID=0x%h", $time, read_req_tag, read_req_id);

        @(posedge clk);
        read_req_ack <= 1;
        @(posedge clk);
        read_req_ack <= 0;

        #30;
        $display("[%0t] SUCCESS: CQ RX Decoder Test Completed!", $time);
        $finish;
    end

endmodule
