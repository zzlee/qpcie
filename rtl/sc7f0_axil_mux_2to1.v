`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_axil_mux_2to1
//
// Single-clock 2-to-1 AXI4-Lite arbiter (independent write & read channels).
// Holds ownership of the write channel from first AW/W until B handshake, and
// ownership of the read channel from AR until R handshake, so AW and W from
// different masters can never interleave.
// ============================================================================
module sc7f0_axil_mux_2to1 (
    input  wire        clk,
    input  wire        rst_n,

    // Slave 0 (PS / lower priority)
    input  wire [31:0] s0_awaddr,
    input  wire        s0_awvalid,
    output wire        s0_awready,
    input  wire [31:0] s0_wdata,
    input  wire [3:0]  s0_wstrb,
    input  wire        s0_wvalid,
    output wire        s0_wready,
    output wire [1:0]  s0_bresp,
    output wire        s0_bvalid,
    input  wire        s0_bready,
    input  wire [31:0] s0_araddr,
    input  wire        s0_arvalid,
    output wire        s0_arready,
    output wire [31:0] s0_rdata,
    output wire [1:0]  s0_rresp,
    output wire        s0_rvalid,
    input  wire        s0_rready,

    // Slave 1 (PCIe BAR0 / higher priority)
    input  wire [31:0] s1_awaddr,
    input  wire        s1_awvalid,
    output wire        s1_awready,
    input  wire [31:0] s1_wdata,
    input  wire [3:0]  s1_wstrb,
    input  wire        s1_wvalid,
    output wire        s1_wready,
    output wire [1:0]  s1_bresp,
    output wire        s1_bvalid,
    input  wire        s1_bready,
    input  wire [31:0] s1_araddr,
    input  wire        s1_arvalid,
    output wire        s1_arready,
    output wire [31:0] s1_rdata,
    output wire [1:0]  s1_rresp,
    output wire        s1_rvalid,
    input  wire        s1_rready,

    // Master (to register file)
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready
);
    // Write channel arbitration
    reg wr_active;
    reg wr_owner; // 0 = s0, 1 = s1

    wire s0_wr_req = s0_awvalid || s0_wvalid;
    wire s1_wr_req = s1_awvalid || s1_wvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active <= 1'b0;
            wr_owner  <= 1'b0;
        end else begin
            if (!wr_active) begin
                if (s1_wr_req) begin
                    wr_active <= 1'b1;
                    wr_owner  <= 1'b1;
                end else if (s0_wr_req) begin
                    wr_active <= 1'b1;
                    wr_owner  <= 1'b0;
                end
            end else if (m_bvalid && m_bready) begin
                wr_active <= 1'b0;
            end
        end
    end

    assign m_awaddr   = wr_owner ? s1_awaddr : s0_awaddr;
    assign m_awvalid  = wr_active && (wr_owner ? s1_awvalid : s0_awvalid);
    assign m_wdata    = wr_owner ? s1_wdata  : s0_wdata;
    assign m_wstrb    = wr_owner ? s1_wstrb  : s0_wstrb;
    assign m_wvalid   = wr_active && (wr_owner ? s1_wvalid  : s0_wvalid);
    assign m_bready   = wr_active && (wr_owner ? s1_bready  : s0_bready);

    assign s0_awready = wr_active && !wr_owner && m_awready;
    assign s0_wready  = wr_active && !wr_owner && m_wready;
    assign s0_bresp   = m_bresp;
    assign s0_bvalid  = wr_active && !wr_owner && m_bvalid;

    assign s1_awready = wr_active &&  wr_owner && m_awready;
    assign s1_wready  = wr_active &&  wr_owner && m_wready;
    assign s1_bresp   = m_bresp;
    assign s1_bvalid  = wr_active &&  wr_owner && m_bvalid;

    // Read channel arbitration
    reg rd_active;
    reg rd_owner; // 0 = s0, 1 = s1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active <= 1'b0;
            rd_owner  <= 1'b0;
        end else begin
            if (!rd_active) begin
                if (s1_arvalid) begin
                    rd_active <= 1'b1;
                    rd_owner  <= 1'b1;
                end else if (s0_arvalid) begin
                    rd_active <= 1'b1;
                    rd_owner  <= 1'b0;
                end
            end else if (m_rvalid && m_rready) begin
                rd_active <= 1'b0;
            end
        end
    end

    assign m_araddr   = rd_owner ? s1_araddr : s0_araddr;
    assign m_arvalid  = rd_active && (rd_owner ? s1_arvalid : s0_arvalid);
    assign m_rready   = rd_active && (rd_owner ? s1_rready  : s0_rready);

    assign s0_arready = rd_active && !rd_owner && m_arready;
    assign s0_rdata   = m_rdata;
    assign s0_rresp   = m_rresp;
    assign s0_rvalid  = rd_active && !rd_owner && m_rvalid;

    assign s1_arready = rd_active &&  rd_owner && m_arready;
    assign s1_rdata   = m_rdata;
    assign s1_rresp   = m_rresp;
    assign s1_rvalid  = rd_active &&  rd_owner && m_rvalid;

endmodule
`default_nettype wire
