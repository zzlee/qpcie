// ============================================================================
// Module: custom_pcie_dma_top
// Description: Top-level module for Custom PCIe AXI4-Stream DMA Controller.
//              Supports Dual-BAR Architecture:
//              - BAR0: PCIe BAR0 DMA Control Registers (axil_reg_space.v)
//              - BAR1: PCIe BAR1 AXI4-Lite Master (Connects to Interconnect for User IP Cores)
// ============================================================================

`timescale 1ns / 1ps

module custom_pcie_dma_top #(
    parameter PCIE_DATA_WIDTH = 256,
    parameter PCIE_KEEP_WIDTH = PCIE_DATA_WIDTH / 32,
    parameter AXI_DATA_WIDTH  = 256,
    parameter AXI_ADDR_WIDTH  = 64
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // PCIe CQ Interface (PCIe IP -> DMA Top)
    input  wire [PCIE_DATA_WIDTH-1:0] s_axis_cq_tdata,
    input  wire                       s_axis_cq_tvalid,
    input  wire                       s_axis_cq_tlast,
    input  wire [87:0]                s_axis_cq_tuser,
    input  wire [PCIE_KEEP_WIDTH-1:0] s_axis_cq_tkeep,
    output wire                       s_axis_cq_tready,

    // PCIe CC Interface (DMA Top -> PCIe IP)
    output wire [PCIE_DATA_WIDTH-1:0] m_axis_cc_tdata,
    output wire                       m_axis_cc_tvalid,
    output wire                       m_axis_cc_tlast,
    output wire [32:0]                m_axis_cc_tuser,
    output wire [PCIE_KEEP_WIDTH-1:0] m_axis_cc_tkeep,
    input  wire                       m_axis_cc_tready,

    // PCIe RQ Interface (DMA Top -> PCIe IP)
    output wire [PCIE_DATA_WIDTH-1:0] m_axis_rq_tdata,
    output wire                       m_axis_rq_tvalid,
    output wire                       m_axis_rq_tlast,
    output wire [59:0]                m_axis_rq_tuser,
    output wire [PCIE_KEEP_WIDTH-1:0] m_axis_rq_tkeep,
    input  wire                       m_axis_rq_tready,

    // PCIe RC Interface (PCIe IP -> DMA Top)
    input  wire [PCIE_DATA_WIDTH-1:0] s_axis_rc_tdata,
    input  wire                       s_axis_rc_tvalid,
    input  wire                       s_axis_rc_tlast,
    input  wire [74:0]                s_axis_rc_tuser,
    input  wire [PCIE_KEEP_WIDTH-1:0] s_axis_rc_tkeep,
    output wire                       s_axis_rc_tready,

    // BAR1 AXI4-Lite Master Interface (Connects to Interconnect for User IP Cores: I2C, UART, etc.)
    output wire [31:0]                m_axil_bar1_awaddr,
    output wire                       m_axil_bar1_awvalid,
    input  wire                       m_axil_bar1_awready,
    output wire [31:0]                m_axil_bar1_wdata,
    output wire [3:0]                 m_axil_bar1_wstrb,
    output wire                       m_axil_bar1_wvalid,
    input  wire                       m_axil_bar1_wready,
    input  wire [1:0]                 m_axil_bar1_bresp,
    input  wire                       m_axil_bar1_bvalid,
    output wire                       m_axil_bar1_bready,

    output wire [31:0]                m_axil_bar1_araddr,
    output wire                       m_axil_bar1_arvalid,
    input  wire                       m_axil_bar1_arready,
    input  wire [31:0]                m_axil_bar1_rdata,
    input  wire [1:0]                 m_axil_bar1_rresp,
    input  wire                       m_axil_bar1_rvalid,
    output wire                       m_axil_bar1_rready,

    // AXI4 Memory Mapped Master Interface (To FPGA Memory/Logic)
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_awaddr,
    output wire [7:0]                 m_axi_awlen,
    output wire [2:0]                 m_axi_awsize,
    output wire [1:0]                 m_axi_awburst,
    output wire                       m_axi_awvalid,
    input  wire                       m_axi_awready,

    output wire [AXI_DATA_WIDTH-1:0]  m_axi_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                       m_axi_wlast,
    output wire                       m_axi_wvalid,
    input  wire                       m_axi_wready,

    input  wire [1:0]                 m_axi_bresp,
    input  wire                       m_axi_bvalid,
    output wire                       m_axi_bready,

    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
    output wire [7:0]                 m_axi_arlen,
    output wire [2:0]                 m_axi_arsize,
    output wire [1:0]                 m_axi_arburst,
    output wire                       m_axi_arvalid,
    input  wire                       m_axi_arready,

    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  wire [1:0]                 m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output wire                       m_axi_rready,

    // Interrupt Pins
    output wire                       usr_irq_req,
    input  wire                       usr_irq_ack
);

    // Internal Wires for BAR0 Inter-module Connection
    wire [31:0] bar0_axil_awaddr, bar0_axil_wdata, bar0_axil_araddr, bar0_axil_rdata;
    wire [3:0]  bar0_axil_wstrb;
    wire [1:0]  bar0_axil_bresp, bar0_axil_rresp;
    wire        bar0_axil_awvalid, bar0_axil_awready, bar0_axil_wvalid, bar0_axil_wready;
    wire        bar0_axil_bvalid, bar0_axil_bready, bar0_axil_arvalid, bar0_axil_arready;
    wire        bar0_axil_rvalid, bar0_axil_rready;

    wire        read_req_valid, read_req_ack, read_req_bar_sel;
    wire [7:0]  read_req_tag;
    wire [15:0] read_req_id;
    wire [6:0]  read_req_lower_addr;
    wire [10:0] read_req_tc;

    wire [31:0] reg_dma_ctrl, reg_dma_status, reg_irq_ctrl, reg_irq_status;
    wire [63:0] reg_h2c_ring_addr, reg_c2h_ring_addr;
    wire [15:0] reg_h2c_ring_size, reg_h2c_tail_ptr, reg_h2c_head_ptr;
    wire [15:0] reg_c2h_ring_size, reg_c2h_tail_ptr, reg_c2h_head_ptr;
    reg  [31:0] completed_h2c_count, completed_c2h_count;

    wire        tag_alloc_req, tag_alloc_valid, tag_full;
    wire [7:0]  tag_alloc_tag, tag_free_val;
    wire        tag_free_req;

    wire        desc_req_valid, desc_req_ack;
    wire [63:0] desc_req_addr;
    wire [10:0] desc_req_dw_len;
    wire [7:0]  desc_req_tag;

    wire        desc_cpl_valid, desc_cpl_last;
    wire [511:0] desc_cpl_data;

    wire        h2c_desc_valid, h2c_desc_ready;
    wire [63:0] h2c_plane0_src, h2c_plane0_dst;
    wire [63:0] h2c_plane1_src, h2c_plane1_dst;
    wire [63:0] h2c_plane2_src, h2c_plane2_dst;
    wire [15:0] h2c_line_width, h2c_line_count;
    wire [15:0] h2c_src_stride, h2c_dst_stride;
    wire [15:0] h2c_plane12_width, h2c_plane12_count;
    wire [3:0]  h2c_format, h2c_plane_count;
    wire [15:0] h2c_desc_ctrl;

    wire        c2h_desc_valid, c2h_desc_ready;
    wire [63:0] c2h_plane0_src, c2h_plane0_dst;
    wire [63:0] c2h_plane1_src, c2h_plane1_dst;
    wire [63:0] c2h_plane2_src, c2h_plane2_dst;
    wire [15:0] c2h_line_width, c2h_line_count;
    wire [15:0] c2h_src_stride, c2h_dst_stride;
    wire [15:0] c2h_plane12_width, c2h_plane12_count;
    wire [3:0]  c2h_format, c2h_plane_count;
    wire [15:0] c2h_desc_ctrl;

    wire        h2c_req_valid, h2c_req_ack;
    wire [63:0] h2c_req_addr;
    wire [10:0] h2c_req_dw_len;
    wire [7:0]  h2c_req_tag;

    wire        c2h_req_valid, c2h_req_ack, c2h_req_last;
    wire [63:0] c2h_req_addr;
    wire [10:0] c2h_req_dw_len;
    wire [PCIE_DATA_WIDTH-1:0] c2h_req_data;

    wire        h2c_fifo_wvalid, h2c_fifo_wlast;
    wire [PCIE_DATA_WIDTH-1:0] h2c_fifo_wdata;

    wire        irq_req_valid, irq_req_ack;
    wire [7:0]  irq_req_code;
    wire        h2c_busy, h2c_done, h2c_count_inc;
    wire        c2h_busy, c2h_done, c2h_count_inc;

    // Completed Descriptor Counter Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            completed_h2c_count <= 32'd0;
            completed_c2h_count <= 32'd0;
        end else begin
            if (h2c_count_inc) completed_h2c_count <= completed_h2c_count + 1'b1;
            if (c2h_count_inc) completed_c2h_count <= completed_c2h_count + 1'b1;
        end
    end

    assign reg_dma_status = {28'd0, c2h_done, h2c_done, c2h_busy, h2c_busy};

    // 1. CQ RX Decoder (BAR0 & BAR1 Demux)
    cq_rx_decoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_cq_rx_decoder (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_cq_tdata(s_axis_cq_tdata),
        .s_axis_cq_tvalid(s_axis_cq_tvalid),
        .s_axis_cq_tlast(s_axis_cq_tlast),
        .s_axis_cq_tuser(s_axis_cq_tuser),
        .s_axis_cq_tkeep(s_axis_cq_tkeep),
        .s_axis_cq_tready(s_axis_cq_tready),
        .m_axil_bar0_awaddr(bar0_axil_awaddr),
        .m_axil_bar0_awvalid(bar0_axil_awvalid),
        .m_axil_bar0_awready(bar0_axil_awready),
        .m_axil_bar0_wdata(bar0_axil_wdata),
        .m_axil_bar0_wstrb(bar0_axil_wstrb),
        .m_axil_bar0_wvalid(bar0_axil_wvalid),
        .m_axil_bar0_wready(bar0_axil_wready),
        .m_axil_bar0_bresp(bar0_axil_bresp),
        .m_axil_bar0_bvalid(bar0_axil_bvalid),
        .m_axil_bar0_bready(bar0_axil_bready),
        .m_axil_bar0_araddr(bar0_axil_araddr),
        .m_axil_bar0_arvalid(bar0_axil_arvalid),
        .m_axil_bar0_arready(bar0_axil_arready),
        .m_axil_bar0_rdata(bar0_axil_rdata),
        .m_axil_bar0_rresp(bar0_axil_rresp),
        .m_axil_bar0_rvalid(bar0_axil_rvalid),
        .m_axil_bar0_rready(bar0_axil_rready),
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

    // 2. CC TX Encoder (BAR0 & BAR1 Read Completion Mux)
    cc_tx_encoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_cc_tx_encoder (
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
        .bar1_axil_rdata(m_axil_bar1_rdata),
        .bar1_axil_rresp(m_axil_bar1_rresp),
        .bar1_axil_rvalid(m_axil_bar1_rvalid),
        .bar1_axil_rready(m_axil_bar1_rready)
    );

    // 3. BAR0 AXI4-Lite Register Space (DMA Control Registers)
    axil_reg_space u_axil_reg_space (
        .clk(clk),
        .rst_n(rst_n),
        .s_axil_awaddr(bar0_axil_awaddr),
        .s_axil_awvalid(bar0_axil_awvalid),
        .s_axil_awready(bar0_axil_awready),
        .s_axil_wdata(bar0_axil_wdata),
        .s_axil_wstrb(bar0_axil_wstrb),
        .s_axil_wvalid(bar0_axil_wvalid),
        .s_axil_wready(bar0_axil_wready),
        .s_axil_bresp(bar0_axil_bresp),
        .s_axil_bvalid(bar0_axil_bvalid),
        .s_axil_bready(bar0_axil_bready),
        .s_axil_araddr(bar0_axil_araddr),
        .s_axil_arvalid(bar0_axil_arvalid),
        .s_axil_arready(bar0_axil_arready),
        .s_axil_rdata(bar0_axil_rdata),
        .s_axil_rresp(bar0_axil_rresp),
        .s_axil_rvalid(bar0_axil_rvalid),
        .s_axil_rready(bar0_axil_rready),
        .reg_dma_ctrl(reg_dma_ctrl),
        .reg_dma_status(reg_dma_status),
        .reg_h2c_ring_addr(reg_h2c_ring_addr),
        .reg_h2c_ring_size(reg_h2c_ring_size),
        .reg_h2c_tail_ptr(reg_h2c_tail_ptr),
        .reg_c2h_ring_addr(reg_c2h_ring_addr),
        .reg_c2h_ring_size(reg_c2h_ring_size),
        .reg_c2h_tail_ptr(reg_c2h_tail_ptr),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status(reg_irq_status),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count)
    );

    // 4. PCIe Tag Manager
    pcie_tag_manager #(
        .MAX_TAGS(64)
    ) u_tag_manager (
        .clk(clk),
        .rst_n(rst_n),
        .alloc_req(tag_alloc_req),
        .alloc_valid(tag_alloc_valid),
        .alloc_tag(tag_alloc_tag),
        .tag_full(tag_full),
        .free_req(tag_free_req),
        .free_tag(tag_free_val),
        .active_count()
    );

    // 5. RQ TX Encoder
    rq_tx_encoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_rq_tx_encoder (
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

    // 6. RC RX Decoder
    rc_rx_decoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_rc_rx_decoder (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_rc_tdata(s_axis_rc_tdata),
        .s_axis_rc_tvalid(s_axis_rc_tvalid),
        .s_axis_rc_tlast(s_axis_rc_tlast),
        .s_axis_rc_tuser(s_axis_rc_tuser),
        .s_axis_rc_tkeep(s_axis_rc_tkeep),
        .s_axis_rc_tready(s_axis_rc_tready),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .h2c_fifo_wvalid(h2c_fifo_wvalid),
        .h2c_fifo_wdata(h2c_fifo_wdata),
        .h2c_fifo_wlast(h2c_fifo_wlast),
        .tag_free_req(tag_free_req),
        .tag_free_val(tag_free_val)
    );

    // 7. Descriptor Fetch Engine
    desc_fetch_engine u_desc_fetch_engine (
        .clk(clk),
        .rst_n(rst_n),
        .dma_run(reg_dma_ctrl[0]),
        .ring_base_addr(reg_h2c_ring_addr),
        .ring_size(reg_h2c_ring_size),
        .tail_ptr(reg_h2c_tail_ptr),
        .head_ptr(reg_h2c_head_ptr),
        .desc_req_valid(desc_req_valid),
        .desc_req_addr(desc_req_addr),
        .desc_req_dw_len(desc_req_dw_len),
        .desc_req_tag(desc_req_tag),
        .desc_req_ack(desc_req_ack),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_plane0_src(h2c_plane0_src), .h2c_plane0_dst(h2c_plane0_dst),
        .h2c_plane1_src(h2c_plane1_src), .h2c_plane1_dst(h2c_plane1_dst),
        .h2c_plane2_src(h2c_plane2_src), .h2c_plane2_dst(h2c_plane2_dst),
        .h2c_line_width(h2c_line_width), .h2c_line_count(h2c_line_count),
        .h2c_src_stride(h2c_src_stride), .h2c_dst_stride(h2c_dst_stride),
        .h2c_plane12_width(h2c_plane12_width), .h2c_plane12_count(h2c_plane12_count),
        .h2c_format(h2c_format), .h2c_plane_count(h2c_plane_count),
        .h2c_desc_ctrl(h2c_desc_ctrl),
        .h2c_desc_ready(h2c_desc_ready),
        .c2h_desc_valid(c2h_desc_valid),
        .c2h_plane0_src(c2h_plane0_src), .c2h_plane0_dst(c2h_plane0_dst),
        .c2h_plane1_src(c2h_plane1_src), .c2h_plane1_dst(c2h_plane1_dst),
        .c2h_plane2_src(c2h_plane2_src), .c2h_plane2_dst(c2h_plane2_dst),
        .c2h_line_width(c2h_line_width), .c2h_line_count(c2h_line_count),
        .c2h_src_stride(c2h_src_stride), .c2h_dst_stride(c2h_dst_stride),
        .c2h_plane12_width(c2h_plane12_width), .c2h_plane12_count(c2h_plane12_count),
        .c2h_format(c2h_format), .c2h_plane_count(c2h_plane_count),
        .c2h_desc_ctrl(c2h_desc_ctrl),
        .c2h_desc_ready(c2h_desc_ready)
    );

    // 8. H2C DMA Engine
    h2c_dma_engine #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) u_h2c_dma_engine (
        .clk(clk),
        .rst_n(rst_n),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_plane0_src(h2c_plane0_src), .h2c_plane0_dst(h2c_plane0_dst),
        .h2c_plane1_src(h2c_plane1_src), .h2c_plane1_dst(h2c_plane1_dst),
        .h2c_plane2_src(h2c_plane2_src), .h2c_plane2_dst(h2c_plane2_dst),
        .h2c_line_width(h2c_line_width), .h2c_line_count(h2c_line_count),
        .h2c_src_stride(h2c_src_stride), .h2c_dst_stride(h2c_dst_stride),
        .h2c_plane12_width(h2c_plane12_width), .h2c_plane12_count(h2c_plane12_count),
        .h2c_format(h2c_format), .h2c_plane_count(h2c_plane_count),
        .h2c_desc_ctrl(h2c_desc_ctrl),
        .h2c_desc_ready(h2c_desc_ready),
        .tag_alloc_req(tag_alloc_req),
        .tag_alloc_tag(tag_alloc_tag),
        .tag_alloc_valid(tag_alloc_valid),
        .h2c_req_valid(h2c_req_valid),
        .h2c_req_addr(h2c_req_addr),
        .h2c_req_dw_len(h2c_req_dw_len),
        .h2c_req_tag(h2c_req_tag),
        .h2c_req_ack(h2c_req_ack),
        .h2c_fifo_wvalid(h2c_fifo_wvalid),
        .h2c_fifo_wdata(h2c_fifo_wdata),
        .h2c_fifo_wlast(h2c_fifo_wlast),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .h2c_busy(h2c_busy),
        .h2c_done(h2c_done),
        .h2c_count_inc(h2c_count_inc)
    );

    // 9. C2H DMA Engine
    c2h_dma_engine #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) u_c2h_dma_engine (
        .clk(clk),
        .rst_n(rst_n),
        .c2h_desc_valid(c2h_desc_valid),
        .c2h_plane0_src(c2h_plane0_src), .c2h_plane0_dst(c2h_plane0_dst),
        .c2h_plane1_src(c2h_plane1_src), .c2h_plane1_dst(c2h_plane1_dst),
        .c2h_plane2_src(c2h_plane2_src), .c2h_plane2_dst(c2h_plane2_dst),
        .c2h_line_width(c2h_line_width), .c2h_line_count(c2h_line_count),
        .c2h_src_stride(c2h_src_stride), .c2h_dst_stride(c2h_dst_stride),
        .c2h_plane12_width(c2h_plane12_width), .c2h_plane12_count(c2h_plane12_count),
        .c2h_format(c2h_format), .c2h_plane_count(c2h_plane_count),
        .c2h_desc_ctrl(c2h_desc_ctrl),
        .c2h_desc_ready(c2h_desc_ready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .c2h_req_valid(c2h_req_valid),
        .c2h_req_addr(c2h_req_addr),
        .c2h_req_dw_len(c2h_req_dw_len),
        .c2h_req_data(c2h_req_data),
        .c2h_req_last(c2h_req_last),
        .c2h_req_ack(c2h_req_ack),
        .c2h_busy(c2h_busy),
        .c2h_done(c2h_done),
        .c2h_count_inc(c2h_count_inc)
    );

    // 10. Interrupt Controller
    interrupt_ctrl u_interrupt_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status(reg_irq_status),
        .h2c_done(h2c_done),
        .c2h_done(c2h_done),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

endmodule
