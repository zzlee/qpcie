// ============================================================================
// Module: sc7f0_axil_merge_2to1
//
// Two AXI4-Lite slices merged onto one AXI4-Lite slave port, with a caller
// supplied address prefix per slice.  Used by rtl/zu4ev_pcie_card_top.v to put
// the two 64 KiB halves of the HDMI TX subsystem aperture back together so the
// subsystem's own address bit 16 (0 = TX core at +0x00000, 1 = VTC at +0x10000)
// is generated in fabric instead of being carried by a crossbar address slice.
//
// Why not rtl/axil_arbiter_2to1.v?  That module drives
//     m_axil_arvalid = s_axil_arvalid && (state != IDLE || s_axil_arvalid)
// which reduces to plain s_axil_arvalid, so a request reaches the slave while
// the grant state has not been entered yet.  The slave then accepts the request
// and raises its response before s_axil_arready can ever be high, so a
// spec-compliant master (which must hold arvalid until arready) can never see a
// handshake.  Measured in
//   xsim-txss-merge/ (tb_hdmi_txss_ctl_merge DBG trace, 2026-11-16):
//     DBG rstn=1 s0arv=1 s0arr=0 m_arv=1 m_arr=0 m_rv=1 r_state=01
//   i.e. the slave handshakes, the master never gets arready, and the request
//   re-fires forever.  That module stays as-is for its existing BAR0/HPM0 user;
//   this one gates every forwarded channel on the grant state.
//
// Behavior: fixed priority to slice 0 with the grant held until the transaction
// completes (AXI4-Lite: one outstanding transaction per channel), so a beat can
// never be split between the two slices.
// ============================================================================
`timescale 1ns / 1ps

module sc7f0_axil_merge_2to1 #(
    parameter ADDR_WIDTH = 17,
    parameter DATA_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Slice 0 (in this use: 0xB0020000..0xB002FFFF -> TX core)
    input  wire [ADDR_WIDTH-1:0]  s0_axil_awaddr,
    input  wire                   s0_axil_awvalid,
    output wire                   s0_axil_awready,
    input  wire [DATA_WIDTH-1:0]  s0_axil_wdata,
    input  wire [3:0]             s0_axil_wstrb,
    input  wire                   s0_axil_wvalid,
    output wire                   s0_axil_wready,
    output wire [1:0]             s0_axil_bresp,
    output wire                   s0_axil_bvalid,
    input  wire                   s0_axil_bready,
    input  wire [ADDR_WIDTH-1:0]  s0_axil_araddr,
    input  wire                   s0_axil_arvalid,
    output wire                   s0_axil_arready,
    output wire [DATA_WIDTH-1:0]  s0_axil_rdata,
    output wire [1:0]             s0_axil_rresp,
    output wire                   s0_axil_rvalid,
    input  wire                   s0_axil_rready,

    // Slice 1 (in this use: 0xB0030000..0xB003FFFF -> VTC)
    input  wire [ADDR_WIDTH-1:0]  s1_axil_awaddr,
    input  wire                   s1_axil_awvalid,
    output wire                   s1_axil_awready,
    input  wire [DATA_WIDTH-1:0]  s1_axil_wdata,
    input  wire [3:0]             s1_axil_wstrb,
    input  wire                   s1_axil_wvalid,
    output wire                   s1_axil_wready,
    output wire [1:0]             s1_axil_bresp,
    output wire                   s1_axil_bvalid,
    input  wire                   s1_axil_bready,
    input  wire [ADDR_WIDTH-1:0]  s1_axil_araddr,
    input  wire                   s1_axil_arvalid,
    output wire                   s1_axil_arready,
    output wire [DATA_WIDTH-1:0]  s1_axil_rdata,
    output wire [1:0]             s1_axil_rresp,
    output wire                   s1_axil_rvalid,
    input  wire                   s1_axil_rready,

    // Merged slave port
    output wire [ADDR_WIDTH-1:0]  m_axil_awaddr,
    output wire                   m_axil_awvalid,
    input  wire                   m_axil_awready,
    output wire [DATA_WIDTH-1:0]  m_axil_wdata,
    output wire [3:0]             m_axil_wstrb,
    output wire                   m_axil_wvalid,
    input  wire                   m_axil_wready,
    input  wire [1:0]             m_axil_bresp,
    input  wire                   m_axil_bvalid,
    output wire                   m_axil_bready,
    output wire [ADDR_WIDTH-1:0]  m_axil_araddr,
    output wire                   m_axil_arvalid,
    input  wire                   m_axil_arready,
    input  wire [DATA_WIDTH-1:0]  m_axil_rdata,
    input  wire [1:0]             m_axil_rresp,
    input  wire                   m_axil_rvalid,
    output wire                   m_axil_rready
);

    localparam G_IDLE  = 2'd0,
               G_GRANT0 = 2'd1,
               G_GRANT1 = 2'd2;

    // ---------------------------------------------------------------- write --
    reg [1:0] w_state;
    reg       w_sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_state <= G_IDLE; w_sel <= 1'b0;
        end else case (w_state)
            G_IDLE: if (s0_axil_awvalid)      begin w_sel <= 1'b0; w_state <= G_GRANT0; end
                    else if (s1_axil_awvalid) begin w_sel <= 1'b1; w_state <= G_GRANT1; end
            // Hold the grant until the write response completes, so AW, W and B
            // of one transaction can never be split across the two slices.
            G_GRANT0: if (m_axil_bvalid && (s0_axil_bready))      w_state <= G_IDLE;
            G_GRANT1: if (m_axil_bvalid && (s1_axil_bready))      w_state <= G_IDLE;
            default: w_state <= G_IDLE;
        endcase
    end

    wire w_g0 = (w_state == G_GRANT0);
    wire w_g1 = (w_state == G_GRANT1);

    assign m_axil_awaddr = w_g1 ? s1_axil_awaddr : s0_axil_awaddr;
    assign m_axil_wdata  = w_g1 ? s1_axil_wdata  : s0_axil_wdata;
    assign m_axil_wstrb  = w_g1 ? s1_axil_wstrb  : s0_axil_wstrb;
    // Forwarded only while granted: the slave must never see a request that the
    // grant state has not accepted, or its response cannot be routed back.
    assign m_axil_awvalid = (w_g0 & s0_axil_awvalid) | (w_g1 & s1_axil_awvalid);
    assign m_axil_wvalid  = (w_g0 & s0_axil_wvalid)  | (w_g1 & s1_axil_wvalid);
    assign m_axil_bready  = w_g1 ? s1_axil_bready : s0_axil_bready;

    assign s0_axil_awready = w_g0 ? m_axil_awready : 1'b0;
    assign s0_axil_wready  = w_g0 ? m_axil_wready  : 1'b0;
    assign s0_axil_bresp   = m_axil_bresp;
    assign s0_axil_bvalid  = w_g0 ? m_axil_bvalid  : 1'b0;

    assign s1_axil_awready = w_g1 ? m_axil_awready : 1'b0;
    assign s1_axil_wready  = w_g1 ? m_axil_wready  : 1'b0;
    assign s1_axil_bresp   = m_axil_bresp;
    assign s1_axil_bvalid  = w_g1 ? m_axil_bvalid  : 1'b0;

    // ----------------------------------------------------------------- read --
    reg [1:0] r_state;
    reg       r_sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state <= G_IDLE; r_sel <= 1'b0;
        end else case (r_state)
            G_IDLE: if (s0_axil_arvalid)      begin r_sel <= 1'b0; r_state <= G_GRANT0; end
                    else if (s1_axil_arvalid) begin r_sel <= 1'b1; r_state <= G_GRANT1; end
            G_GRANT0: if (m_axil_rvalid && s0_axil_rready) r_state <= G_IDLE;
            G_GRANT1: if (m_axil_rvalid && s1_axil_rready) r_state <= G_IDLE;
            default: r_state <= G_IDLE;
        endcase
    end

    wire r_g0 = (r_state == G_GRANT0);
    wire r_g1 = (r_state == G_GRANT1);

    assign m_axil_araddr  = r_g1 ? s1_axil_araddr : s0_axil_araddr;
    assign m_axil_arvalid = (r_g0 & s0_axil_arvalid) | (r_g1 & s1_axil_arvalid);
    assign m_axil_rready  = r_g1 ? s1_axil_rready : s0_axil_rready;

    assign s0_axil_arready = r_g0 ? m_axil_arready : 1'b0;
    assign s0_axil_rdata   = m_axil_rdata;
    assign s0_axil_rresp   = m_axil_rresp;
    assign s0_axil_rvalid  = r_g0 ? m_axil_rvalid : 1'b0;

    assign s1_axil_arready = r_g1 ? m_axil_arready : 1'b0;
    assign s1_axil_rdata   = m_axil_rdata;
    assign s1_axil_rresp   = m_axil_rresp;
    assign s1_axil_rvalid  = r_g1 ? m_axil_rvalid : 1'b0;

endmodule
