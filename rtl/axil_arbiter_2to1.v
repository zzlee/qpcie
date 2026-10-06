// ============================================================================
// Module: axil_arbiter_2to1
// Description: Synchronous 2-to-1 AXI4-Lite Arbiter / Interconnect.
//              Arbitrates between two AXI4-Lite Masters (PCIe BAR0 & PS HPM0_FPD)
//              to access a single AXI4-Lite Slave (axil_reg_space).
//              Provides independent, lock-safe arbitration for Write and Read channels.
// ============================================================================

`timescale 1ns / 1ps

module axil_arbiter_2to1 #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // =========================================================================
    // Slave Interface S0 (Priority 0: PCIe BAR0 Master)
    // =========================================================================
    input  wire [ADDR_WIDTH-1:0] s0_axil_awaddr,
    input  wire                  s0_axil_awvalid,
    output wire                  s0_axil_awready,
    input  wire [DATA_WIDTH-1:0] s0_axil_wdata,
    input  wire [3:0]            s0_axil_wstrb,
    input  wire                  s0_axil_wvalid,
    output wire                  s0_axil_wready,
    output wire [1:0]            s0_axil_bresp,
    output wire                  s0_axil_bvalid,
    input  wire                  s0_axil_bready,

    input  wire [ADDR_WIDTH-1:0] s0_axil_araddr,
    input  wire                  s0_axil_arvalid,
    output wire                  s0_axil_arready,
    output wire [DATA_WIDTH-1:0] s0_axil_rdata,
    output wire [1:0]            s0_axil_rresp,
    output wire                  s0_axil_rvalid,
    input  wire                  s0_axil_rready,

    // =========================================================================
    // Slave Interface S1 (Priority 1: PS ARM Linux M_AXI_HPM0_FPD Master)
    // =========================================================================
    input  wire [ADDR_WIDTH-1:0] s1_axil_awaddr,
    input  wire                  s1_axil_awvalid,
    output wire                  s1_axil_awready,
    input  wire [DATA_WIDTH-1:0] s1_axil_wdata,
    input  wire [3:0]            s1_axil_wstrb,
    input  wire                  s1_axil_wvalid,
    output wire                  s1_axil_wready,
    output wire [1:0]            s1_axil_bresp,
    output wire                  s1_axil_bvalid,
    input  wire                  s1_axil_bready,

    input  wire [ADDR_WIDTH-1:0] s1_axil_araddr,
    input  wire                  s1_axil_arvalid,
    output wire                  s1_axil_arready,
    output wire [DATA_WIDTH-1:0] s1_axil_rdata,
    output wire [1:0]            s1_axil_rresp,
    output wire                  s1_axil_rvalid,
    input  wire                  s1_axil_rready,

    // =========================================================================
    // Master Interface M (To axil_reg_space Slave)
    // =========================================================================
    output wire [ADDR_WIDTH-1:0] m_axil_awaddr,
    output wire                  m_axil_awvalid,
    input  wire                  m_axil_awready,
    output wire [DATA_WIDTH-1:0] m_axil_wdata,
    output wire [3:0]            m_axil_wstrb,
    output wire                  m_axil_wvalid,
    input  wire                  m_axil_wready,
    input  wire [1:0]            m_axil_bresp,
    input  wire                  m_axil_bvalid,
    output wire                  m_axil_bready,

    output wire [ADDR_WIDTH-1:0] m_axil_araddr,
    output wire                  m_axil_arvalid,
    input  wire                  m_axil_arready,
    input  wire [DATA_WIDTH-1:0] m_axil_rdata,
    input  wire [1:0]            m_axil_rresp,
    input  wire                  m_axil_rvalid,
    output wire                  m_axil_rready
);

    // =========================================================================
    // Write Channel Arbitration FSM
    // =========================================================================
    localparam W_IDLE  = 2'd0;
    localparam W_GRANT0 = 2'd1;
    localparam W_GRANT1 = 2'd2;

    reg [1:0] w_state;
    reg       w_sel; // 0: S0, 1: S1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_state <= W_IDLE;
            w_sel   <= 1'b0;
        end else begin
            case (w_state)
                W_IDLE: begin
                    if (s0_axil_awvalid) begin
                        w_sel   <= 1'b0;
                        w_state <= W_GRANT0;
                    end else if (s1_axil_awvalid) begin
                        w_sel   <= 1'b1;
                        w_state <= W_GRANT1;
                    end
                end

                W_GRANT0: begin
                    if (m_axil_bvalid && m_axil_bready) begin
                        if (s1_axil_awvalid) begin
                            w_sel   <= 1'b1;
                            w_state <= W_GRANT1;
                        end else begin
                            w_state <= W_IDLE;
                        end
                    end
                end

                W_GRANT1: begin
                    if (m_axil_bvalid && m_axil_bready) begin
                        if (s0_axil_awvalid) begin
                            w_sel   <= 1'b0;
                            w_state <= W_GRANT0;
                        end else begin
                            w_state <= W_IDLE;
                        end
                    end
                end

                default: w_state <= W_IDLE;
            endcase
        end
    end

    // Muxing Write Channel
    assign m_axil_awaddr  = (w_sel == 1'b0) ? s0_axil_awaddr : s1_axil_awaddr;
    assign m_axil_awvalid = (w_sel == 1'b0) ? (s0_axil_awvalid && (w_state != W_IDLE || s0_axil_awvalid)) :
                                              (s1_axil_awvalid && (w_state != W_IDLE || s1_axil_awvalid));
    assign s0_axil_awready = (w_sel == 1'b0 && w_state == W_GRANT0) ? m_axil_awready : 1'b0;
    assign s1_axil_awready = (w_sel == 1'b1 && w_state == W_GRANT1) ? m_axil_awready : 1'b0;

    assign m_axil_wdata   = (w_sel == 1'b0) ? s0_axil_wdata : s1_axil_wdata;
    assign m_axil_wstrb   = (w_sel == 1'b0) ? s0_axil_wstrb : s1_axil_wstrb;
    assign m_axil_wvalid  = (w_sel == 1'b0) ? s0_axil_wvalid : s1_axil_wvalid;
    assign s0_axil_wready = (w_sel == 1'b0 && w_state == W_GRANT0) ? m_axil_wready : 1'b0;
    assign s1_axil_wready = (w_sel == 1'b1 && w_state == W_GRANT1) ? m_axil_wready : 1'b0;

    assign s0_axil_bresp  = m_axil_bresp;
    assign s0_axil_bvalid = (w_sel == 1'b0 && w_state == W_GRANT0) ? m_axil_bvalid : 1'b0;
    assign s1_axil_bresp  = m_axil_bresp;
    assign s1_axil_bvalid = (w_sel == 1'b1 && w_state == W_GRANT1) ? m_axil_bvalid : 1'b0;
    assign m_axil_bready  = (w_sel == 1'b0) ? s0_axil_bready : s1_axil_bready;

    // =========================================================================
    // Read Channel Arbitration FSM
    // =========================================================================
    localparam R_IDLE   = 2'd0;
    localparam R_GRANT0 = 2'd1;
    localparam R_GRANT1 = 2'd2;

    reg [1:0] r_state;
    reg       r_sel; // 0: S0, 1: S1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state <= R_IDLE;
            r_sel   <= 1'b0;
        end else begin
            case (r_state)
                R_IDLE: begin
                    if (s0_axil_arvalid) begin
                        r_sel   <= 1'b0;
                        r_state <= R_GRANT0;
                    end else if (s1_axil_arvalid) begin
                        r_sel   <= 1'b1;
                        r_state <= R_GRANT1;
                    end
                end

                R_GRANT0: begin
                    if (m_axil_rvalid && m_axil_rready) begin
                        if (s1_axil_arvalid) begin
                            r_sel   <= 1'b1;
                            r_state <= R_GRANT1;
                        end else begin
                            r_state <= R_IDLE;
                        end
                    end
                end

                R_GRANT1: begin
                    if (m_axil_rvalid && m_axil_rready) begin
                        if (s0_axil_arvalid) begin
                            r_sel   <= 1'b0;
                            r_state <= R_GRANT0;
                        end else begin
                            r_state <= R_IDLE;
                        end
                    end
                end

                default: r_state <= R_IDLE;
            endcase
        end
    end

    // Muxing Read Channel
    assign m_axil_araddr   = (r_sel == 1'b0) ? s0_axil_araddr : s1_axil_araddr;
    assign m_axil_arvalid  = (r_sel == 1'b0) ? (s0_axil_arvalid && (r_state != R_IDLE || s0_axil_arvalid)) :
                                               (s1_axil_arvalid && (r_state != R_IDLE || s1_axil_arvalid));
    assign s0_axil_arready = (r_sel == 1'b0 && r_state == R_GRANT0) ? m_axil_arready : 1'b0;
    assign s1_axil_arready = (r_sel == 1'b1 && r_state == R_GRANT1) ? m_axil_arready : 1'b0;

    assign s0_axil_rdata   = m_axil_rdata;
    assign s0_axil_rresp   = m_axil_rresp;
    assign s0_axil_rvalid  = (r_sel == 1'b0 && r_state == R_GRANT0) ? m_axil_rvalid : 1'b0;

    assign s1_axil_rdata   = m_axil_rdata;
    assign s1_axil_rresp   = m_axil_rresp;
    assign s1_axil_rvalid  = (r_sel == 1'b1 && r_state == R_GRANT1) ? m_axil_rvalid : 1'b0;

    assign m_axil_rready   = (r_sel == 1'b0) ? s0_axil_rready : s1_axil_rready;

endmodule
