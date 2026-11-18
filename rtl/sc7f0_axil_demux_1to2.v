`default_nettype none
`timescale 1ns / 1ps
// ============================================================================
// sc7f0_axil_demux_1to2
//
// Single-clock 1-to-2 AXI4-Lite decoder/splitter for PCIe BAR0:
//   BAR0 0x4000..0x4FFF (addr[15:12] == 4'h4) -> m1 (Overlay CSR in pcie_clk)
//   All other BAR0 offsets                   -> m0 (existing axi_clock_converter_0)
//
// Strictly 1 outstanding write and 1 outstanding read at a time so AW/W/B and
// AR/R stay paired to the decoded slave.
// ============================================================================
module sc7f0_axil_demux_1to2 (
    input  wire        clk,
    input  wire        rst_n,

    // Slave (from PCIe BAR0 master)
    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rvalid,
    input  wire        s_rready,

    // Master 0 (default BAR0 path: 0x0000..0x3FFF)
    output wire [31:0] m0_awaddr,
    output wire        m0_awvalid,
    input  wire        m0_awready,
    output wire [31:0] m0_wdata,
    output wire [3:0]  m0_wstrb,
    output wire        m0_wvalid,
    input  wire        m0_wready,
    input  wire [1:0]  m0_bresp,
    input  wire        m0_bvalid,
    output wire        m0_bready,
    output wire [31:0] m0_araddr,
    output wire        m0_arvalid,
    input  wire        m0_arready,
    input  wire [31:0] m0_rdata,
    input  wire [1:0]  m0_rresp,
    input  wire        m0_rvalid,
    output wire        m0_rready,

    // Master 1 (BAR0 0x4000..0x4FFF: Overlay CSR)
    output wire [31:0] m1_awaddr,
    output wire        m1_awvalid,
    input  wire        m1_awready,
    output wire [31:0] m1_wdata,
    output wire [3:0]  m1_wstrb,
    output wire        m1_wvalid,
    input  wire        m1_wready,
    input  wire [1:0]  m1_bresp,
    input  wire        m1_bvalid,
    output wire        m1_bready,
    output wire [31:0] m1_araddr,
    output wire        m1_arvalid,
    input  wire        m1_arready,
    input  wire [31:0] m1_rdata,
    input  wire [1:0]  m1_rresp,
    input  wire        m1_rvalid,
    output wire        m1_rready
);
    // Write channel: wait for s_awvalid to know target slave before forwarding AW/W
    reg wr_active;
    reg wr_sel; // 0 = m0, 1 = m1

    wire wr_dec_m1 = (s_awaddr[15:12] == 4'h4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active <= 1'b0;
            wr_sel    <= 1'b0;
        end else begin
            if (!wr_active) begin
                if (s_awvalid) begin
                    wr_active <= 1'b1;
                    wr_sel    <= wr_dec_m1;
                end
            end else if (s_bvalid && s_bready) begin
                wr_active <= 1'b0;
            end
        end
    end

    assign m0_awaddr  = s_awaddr;
    assign m0_awvalid = wr_active && !wr_sel && s_awvalid;
    assign m0_wdata   = s_wdata;
    assign m0_wstrb   = s_wstrb;
    assign m0_wvalid  = wr_active && !wr_sel && s_wvalid;
    assign m0_bready  = wr_active && !wr_sel && s_bready;

    assign m1_awaddr  = s_awaddr;
    assign m1_awvalid = wr_active &&  wr_sel && s_awvalid;
    assign m1_wdata   = s_wdata;
    assign m1_wstrb   = s_wstrb;
    assign m1_wvalid  = wr_active &&  wr_sel && s_wvalid;
    assign m1_bready  = wr_active &&  wr_sel && s_bready;

    assign s_awready  = wr_active && (wr_sel ? m1_awready : m0_awready);
    assign s_wready   = wr_active && (wr_sel ? m1_wready  : m0_wready);
    assign s_bresp    = wr_sel ? m1_bresp : m0_bresp;
    assign s_bvalid   = wr_active && (wr_sel ? m1_bvalid  : m0_bvalid);

    // Read channel
    reg rd_active;
    reg rd_sel; // 0 = m0, 1 = m1

    wire rd_dec_m1 = (s_araddr[15:12] == 4'h4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active <= 1'b0;
            rd_sel    <= 1'b0;
        end else begin
            if (!rd_active) begin
                if (s_arvalid) begin
                    rd_active <= 1'b1;
                    rd_sel    <= rd_dec_m1;
                end
            end else if (s_rvalid && s_rready) begin
                rd_active <= 1'b0;
            end
        end
    end

    assign m0_araddr  = s_araddr;
    assign m0_arvalid = rd_active && !rd_sel && s_arvalid;
    assign m0_rready  = rd_active && !rd_sel && s_rready;

    assign m1_araddr  = s_araddr;
    assign m1_arvalid = rd_active &&  rd_sel && s_arvalid;
    assign m1_rready  = rd_active &&  rd_sel && s_rready;

    assign s_arready  = rd_active && (rd_sel ? m1_arready : m0_arready);
    assign s_rdata    = rd_sel ? m1_rdata : m0_rdata;
    assign s_rresp    = rd_sel ? m1_rresp : m0_rresp;
    assign s_rvalid   = rd_active && (rd_sel ? m1_rvalid : m0_rvalid);

endmodule
`default_nettype wire
