// ============================================================================
// Testbench: tb_cq_rx_decoder
// Description: Unit testbench for cq_rx_decoder module with Dual-BAR (BAR0 & BAR1)
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

    // BAR0 Ports
    wire [31:0]          m_axil_bar0_awaddr;
    wire                 m_axil_bar0_awvalid;
    reg                  m_axil_bar0_awready;
    wire [31:0]          m_axil_bar0_wdata;
    wire [3:0]           m_axil_bar0_wstrb;
    wire                 m_axil_bar0_wvalid;
    reg                  m_axil_bar0_wready;
    reg  [1:0]           m_axil_bar0_bresp;
    reg                  m_axil_bar0_bvalid;
    wire                 m_axil_bar0_bready;

    wire [31:0]          m_axil_bar0_araddr;
    wire                 m_axil_bar0_arvalid;
    reg                  m_axil_bar0_arready;
    reg  [31:0]          m_axil_bar0_rdata;
    reg  [1:0]           m_axil_bar0_rresp;
    reg                  m_axil_bar0_rvalid;
    wire                 m_axil_bar0_rready;

    // BAR1 Ports
    wire [31:0]          m_axil_bar1_awaddr;
    wire                 m_axil_bar1_awvalid;
    reg                  m_axil_bar1_awready;
    wire [31:0]          m_axil_bar1_wdata;
    wire [3:0]           m_axil_bar1_wstrb;
    wire                 m_axil_bar1_wvalid;
    reg                  m_axil_bar1_wready;
    reg  [1:0]           m_axil_bar1_bresp;
    reg                  m_axil_bar1_bvalid;
    wire                 m_axil_bar1_bready;

    wire [31:0]          m_axil_bar1_araddr;
    wire                 m_axil_bar1_arvalid;
    reg                  m_axil_bar1_arready;
    reg  [31:0]          m_axil_bar1_rdata;
    reg  [1:0]           m_axil_bar1_rresp;
    reg                  m_axil_bar1_rvalid;
    wire                 m_axil_bar1_rready;

    wire                 read_req_valid;
    wire [7:0]           read_req_tag;
    wire [15:0]          read_req_id;
    wire [6:0]           read_req_lower_addr;
    wire [10:0]          read_req_tc;
    wire                 read_req_bar_sel;
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
        .m_axil_bar0_awaddr(m_axil_bar0_awaddr),
        .m_axil_bar0_awvalid(m_axil_bar0_awvalid),
        .m_axil_bar0_awready(m_axil_bar0_awready),
        .m_axil_bar0_wdata(m_axil_bar0_wdata),
        .m_axil_bar0_wstrb(m_axil_bar0_wstrb),
        .m_axil_bar0_wvalid(m_axil_bar0_wvalid),
        .m_axil_bar0_wready(m_axil_bar0_wready),
        .m_axil_bar0_bresp(m_axil_bar0_bresp),
        .m_axil_bar0_bvalid(m_axil_bar0_bvalid),
        .m_axil_bar0_bready(m_axil_bar0_bready),
        .m_axil_bar0_araddr(m_axil_bar0_araddr),
        .m_axil_bar0_arvalid(m_axil_bar0_arvalid),
        .m_axil_bar0_arready(m_axil_bar0_arready),
        .m_axil_bar0_rdata(m_axil_bar0_rdata),
        .m_axil_bar0_rresp(m_axil_bar0_rresp),
        .m_axil_bar0_rvalid(m_axil_bar0_rvalid),
        .m_axil_bar0_rready(m_axil_bar0_rready),
        .m_axil_bar1_awaddr(m_axil_bar1_awaddr),
        .m_axil_bar1_awvalid(m_axil_bar1_awvalid),
        .m_axil_bar1_awready(m_axil_bar1_awready),
        .m_axil_bar1_wdata(m_axil_bar1_wdata),
        .m_axil_bar1_wstrb(m_axil_bar1_wstrb),
        .m_axil_bar1_wvalid(m_axil_bar1_wvalid),
        .m_axil_bar1_wready(m_axil_bar1_wready),
        .m_axil_bar1_bresp(m_axil_bar1_bresp),
        .m_axil_bar1_bvalid(m_axil_bar1_bvalid),
        .m_axil_bar1_bready(m_axil_bar1_bready),
        .m_axil_bar1_araddr(m_axil_bar1_araddr),
        .m_axil_bar1_arvalid(m_axil_bar1_arvalid),
        .m_axil_bar1_arready(m_axil_bar1_arready),
        .m_axil_bar1_rdata(m_axil_bar1_rdata),
        .m_axil_bar1_rresp(m_axil_bar1_rresp),
        .m_axil_bar1_rvalid(m_axil_bar1_rvalid),
        .m_axil_bar1_rready(m_axil_bar1_rready),
        .read_req_valid(read_req_valid),
        .read_req_tag(read_req_tag),
        .read_req_id(read_req_id),
        .read_req_lower_addr(read_req_lower_addr),
        .read_req_tc(read_req_tc),
        .read_req_bar_sel(read_req_bar_sel),
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
        m_axil_bar0_awready = 1;
        m_axil_bar0_wready = 1;
        m_axil_bar0_bresp = 0;
        m_axil_bar0_bvalid = 0;
        m_axil_bar0_arready = 1;
        m_axil_bar0_rdata = 32'hA5A5A5A5;
        m_axil_bar0_rresp = 0;
        m_axil_bar0_rvalid = 0;
        m_axil_bar1_awready = 1;
        m_axil_bar1_wready = 1;
        m_axil_bar1_bresp = 0;
        m_axil_bar1_bvalid = 0;
        m_axil_bar1_arready = 1;
        m_axil_bar1_rdata = 32'h5A5A5A5A;
        m_axil_bar1_rresp = 0;
        m_axil_bar1_rvalid = 0;
        read_req_ack = 0;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: BAR0 Memory Write (DMA_CTRL Addr 0x00)...", $time);
        @(posedge clk);
        s_axis_cq_tvalid <= 1;
        s_axis_cq_tlast  <= 1;
        s_axis_cq_tdata[63:0]    <= 64'h0000_0000;
        s_axis_cq_tdata[78:75]   <= 4'b0001; // MWr
        s_axis_cq_tdata[114:112] <= 3'b000;  // BAR0
        s_axis_cq_tdata[159:128] <= 32'h0000_0001;

        wait(m_axil_bar0_awvalid && m_axil_bar0_wvalid);
        $display("[%0t] CQ Decoder demuxed MWr to BAR0! Addr: 0x%h Data: 0x%h", $time, m_axil_bar0_awaddr, m_axil_bar0_wdata);
        @(posedge clk);
        s_axis_cq_tvalid <= 0;
        m_axil_bar0_bvalid <= 1;
        @(posedge clk);
        m_axil_bar0_bvalid <= 0;

        #30;
        $display("[%0t] Test 2: BAR1 absolute-address Memory Write (offset 0x1000)...", $time);
        @(posedge clk);
        s_axis_cq_tvalid <= 1;
        s_axis_cq_tlast  <= 1;
        s_axis_cq_tdata[63:0]    <= 64'h0000_0024_2810_1000;
        s_axis_cq_tdata[78:75]   <= 4'b0001; // MWr
        s_axis_cq_tdata[114:112] <= 3'b001;  // BAR1
        s_axis_cq_tdata[159:128] <= 32'h1234_5678;

        wait(m_axil_bar1_awvalid && m_axil_bar1_wvalid);
        if (m_axil_bar1_awaddr !== 32'h0000_1000)
            $fatal(1, "BAR1 write address was not normalized: 0x%h", m_axil_bar1_awaddr);
        $display("[%0t] CQ Decoder normalized BAR1 MWr to offset 0x%h", $time, m_axil_bar1_awaddr);
        @(posedge clk);
        s_axis_cq_tvalid <= 0;
        m_axil_bar1_bvalid <= 1;
        @(posedge clk);
        m_axil_bar1_bvalid <= 0;

        #30;
        $display("[%0t] Test 3: BAR1 absolute-address Memory Read (TPG offset 0x20)...", $time);
        @(posedge clk);
        s_axis_cq_tdata <= {DATA_WIDTH{1'b0}};
        s_axis_cq_tvalid <= 1;
        s_axis_cq_tlast  <= 1;
        s_axis_cq_tdata[63:0]    <= 64'h0000_0024_2810_0020;
        s_axis_cq_tdata[78:75]   <= 4'b0000; // MRd
        s_axis_cq_tdata[114:112] <= 3'b001;  // BAR1

        wait(m_axil_bar1_arvalid);
        if (m_axil_bar1_araddr !== 32'h0000_0020)
            $fatal(1, "BAR1 read address was not normalized: 0x%h", m_axil_bar1_araddr);
        @(posedge clk);
        s_axis_cq_tvalid <= 0;
        m_axil_bar1_rvalid <= 1;
        @(posedge clk);
        m_axil_bar1_rvalid <= 0;
        wait(read_req_valid && read_req_bar_sel);
        read_req_ack <= 1;
        @(posedge clk);
        read_req_ack <= 0;

        #30;
        $display("[%0t] SUCCESS: Dual-BAR CQ RX Decoder Test Completed!", $time);
        $finish;
    end

endmodule
