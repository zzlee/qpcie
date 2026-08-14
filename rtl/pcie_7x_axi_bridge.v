// ============================================================================
// Module: pcie_7x_axi_bridge
// Description: AXI-Stream TLP Protocol Bridge for Xilinx 7-Series PCIe IP (pg054)
//              Converts 128-bit 7-Series AXI-Stream RX/TX into internal
//              128-bit CQ / CC / RQ / RC interface.
// ============================================================================

`timescale 1ns / 1ps

module pcie_7x_axi_bridge #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = DATA_WIDTH / 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ------------------------------------------------------------------------
    // 7-Series PCIe IP (pg054) 128-bit AXI-Stream RX Interface
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] m_axis_rx_tdata,
    input  wire [KEEP_WIDTH-1:0] m_axis_rx_tkeep,
    input  wire                  m_axis_rx_tlast,
    input  wire                  m_axis_rx_tvalid,
    output wire                  m_axis_rx_tready,
    input  wire [21:0]           m_axis_rx_tuser,

    // ------------------------------------------------------------------------
    // 7-Series PCIe IP (pg054) 128-bit AXI-Stream TX Interface
    // ------------------------------------------------------------------------
    output wire [DATA_WIDTH-1:0] s_axis_tx_tdata,
    output wire [KEEP_WIDTH-1:0] s_axis_tx_tkeep,
    output wire                  s_axis_tx_tlast,
    output wire                  s_axis_tx_tvalid,
    input  wire                  s_axis_tx_tready,
    output wire [3:0]            s_axis_tx_tuser,

    // ------------------------------------------------------------------------
    // Internal Core DMA CQ (Completer Request) Interface
    // ------------------------------------------------------------------------
    output wire [DATA_WIDTH-1:0] m_axis_cq_tdata,
    output wire                  m_axis_cq_tvalid,
    output wire                  m_axis_cq_tlast,
    output wire [87:0]           m_axis_cq_tuser,
    output wire [KEEP_WIDTH-1:0] m_axis_cq_tkeep,
    input  wire                  m_axis_cq_tready,

    // ------------------------------------------------------------------------
    // Internal Core DMA CC (Completer Completion) Interface
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] s_axis_cc_tdata,
    input  wire                  s_axis_cc_tvalid,
    input  wire                  s_axis_cc_tlast,
    input  wire [32:0]           s_axis_cc_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_cc_tkeep,
    output wire                  s_axis_cc_tready,

    // ------------------------------------------------------------------------
    // Internal Core DMA RQ (Requester Request) Interface
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] s_axis_rq_tdata,
    input  wire                  s_axis_rq_tvalid,
    input  wire                  s_axis_rq_tlast,
    input  wire [61:0]           s_axis_rq_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_rq_tkeep,
    output wire                  s_axis_rq_tready,

    // ------------------------------------------------------------------------
    // Internal Core DMA RC (Requester Completion) Interface
    // ------------------------------------------------------------------------
    output wire [DATA_WIDTH-1:0] m_axis_rc_tdata,
    output wire                  m_axis_rc_tvalid,
    output wire                  m_axis_rc_tlast,
    output wire [74:0]           m_axis_rc_tuser,
    output wire [KEEP_WIDTH-1:0] m_axis_rc_tkeep,
    input  wire                  m_axis_rc_tready
);

    // Direct AXI-Stream Passthrough & Protocol Alignment Logic for 128-bit
    assign m_axis_cq_tdata  = m_axis_rx_tdata;
    assign m_axis_cq_tvalid = m_axis_rx_tvalid && (m_axis_rx_tdata[30:24] == 7'b0000000 || m_axis_rx_tdata[30:24] == 7'b1000000); // MRd/MWr
    assign m_axis_cq_tlast  = m_axis_rx_tlast;
    assign m_axis_cq_tuser  = 88'd0;
    assign m_axis_cq_tkeep  = m_axis_rx_tkeep;

    assign m_axis_rc_tdata  = m_axis_rx_tdata;
    assign m_axis_rc_tvalid = m_axis_rx_tvalid && (m_axis_rx_tdata[30:24] == 7'b1001010); // CplD
    assign m_axis_rc_tlast  = m_axis_rx_tlast;
    assign m_axis_rc_tuser  = 75'd0;
    assign m_axis_rc_tkeep  = m_axis_rx_tkeep;

    assign m_axis_rx_tready = m_axis_cq_tready && m_axis_rc_tready;

    // TX Arbiter (CC vs RQ)
    wire tx_sel_cc = s_axis_cc_tvalid;

    assign s_axis_tx_tdata  = tx_sel_cc ? s_axis_cc_tdata  : s_axis_rq_tdata;
    assign s_axis_tx_tvalid = tx_sel_cc ? s_axis_cc_tvalid : s_axis_rq_tvalid;
    assign s_axis_tx_tlast  = tx_sel_cc ? s_axis_cc_tlast  : s_axis_rq_tlast;
    assign s_axis_tx_tkeep  = tx_sel_cc ? s_axis_cc_tkeep  : s_axis_rq_tkeep;
    assign s_axis_tx_tuser  = 4'b0000;

    assign s_axis_cc_tready = s_axis_tx_tready;
    assign s_axis_rq_tready = s_axis_tx_tready && !s_axis_cc_tvalid;

endmodule
