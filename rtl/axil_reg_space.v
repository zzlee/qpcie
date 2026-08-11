// ============================================================================
// Module: axil_reg_space
// Description: AXI4-Lite Slave Register Block mapping PCIe BAR0 to DMA control/status.
// ============================================================================

`timescale 1ns / 1ps

module axil_reg_space #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // AXI4-Lite Slave Interface
    input  wire [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  wire                  s_axil_awvalid,
    output reg                   s_axil_awready,

    input  wire [DATA_WIDTH-1:0] s_axil_wdata,
    input  wire [3:0]            s_axil_wstrb,
    input  wire                  s_axil_wvalid,
    output reg                   s_axil_wready,

    output reg  [1:0]            s_axil_bresp,
    output reg                   s_axil_bvalid,
    input  wire                  s_axil_bready,

    input  wire [ADDR_WIDTH-1:0] s_axil_araddr,
    input  wire                  s_axil_arvalid,
    output reg                   s_axil_arready,

    output reg  [DATA_WIDTH-1:0] s_axil_rdata,
    output reg  [1:0]            s_axil_rresp,
    output reg                   s_axil_rvalid,
    input  wire                  s_axil_rready,

    // Exported Register Controls & Status Inputs
    output reg  [31:0]           reg_dma_ctrl,
    input  wire [31:0]           reg_dma_status,

    output reg  [63:0]           reg_h2c_ring_addr,
    output reg  [15:0]           reg_h2c_ring_size,
    output reg  [15:0]           reg_h2c_tail_ptr,

    output reg  [63:0]           reg_c2h_ring_addr,
    output reg  [15:0]           reg_c2h_ring_size,
    output reg  [15:0]           reg_c2h_tail_ptr,

    output reg  [31:0]           reg_irq_ctrl,
    input  wire [31:0]           reg_irq_status,

    input  wire [31:0]           completed_h2c_count,
    input  wire [31:0]           completed_c2h_count
);

    // Register Offsets
    localparam ADDR_DMA_CTRL        = 8'h00;
    localparam ADDR_DMA_STATUS      = 8'h04;
    localparam ADDR_H2C_RING_ADDR_L = 8'h08;
    localparam ADDR_H2C_RING_ADDR_H = 8'h0C;
    localparam ADDR_H2C_RING_CFG    = 8'h10;
    localparam ADDR_C2H_RING_ADDR_L = 8'h14;
    localparam ADDR_C2H_RING_ADDR_H = 8'h18;
    localparam ADDR_C2H_RING_CFG    = 8'h1C;
    localparam ADDR_IRQ_CTRL        = 8'h20;
    localparam ADDR_IRQ_STATUS      = 8'h24;
    localparam ADDR_H2C_COUNT       = 8'h28;
    localparam ADDR_C2H_COUNT       = 8'h2C;

    // AXI4-Lite Write Logic
    reg [ADDR_WIDTH-1:0] waddr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready     <= 1'b1;
            s_axil_wready      <= 1'b1;
            s_axil_bvalid      <= 1'b0;
            s_axil_bresp       <= 2'b00;
            waddr              <= {ADDR_WIDTH{1'b0}};
            reg_dma_ctrl       <= 32'd0;
            reg_h2c_ring_addr  <= 64'd0;
            reg_h2c_ring_size  <= 16'd0;
            reg_h2c_tail_ptr   <= 16'd0;
            reg_c2h_ring_addr  <= 64'd0;
            reg_c2h_ring_size  <= 16'd0;
            reg_c2h_tail_ptr   <= 16'd0;
            reg_irq_ctrl       <= 32'd0;
        end else begin
            if (s_axil_awvalid && s_axil_awready && s_axil_wvalid && s_axil_wready) begin
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
                s_axil_bvalid  <= 1'b1;
                s_axil_bresp   <= 2'b00;

                case (s_axil_awaddr[7:0])
                    ADDR_DMA_CTRL:        reg_dma_ctrl               <= s_axil_wdata;
                    ADDR_H2C_RING_ADDR_L: reg_h2c_ring_addr[31:0]    <= s_axil_wdata;
                    ADDR_H2C_RING_ADDR_H: reg_h2c_ring_addr[63:32]   <= s_axil_wdata;
                    ADDR_H2C_RING_CFG: begin
                        reg_h2c_ring_size <= s_axil_wdata[15:0];
                        reg_h2c_tail_ptr  <= s_axil_wdata[31:16];
                    end
                    ADDR_C2H_RING_ADDR_L: reg_c2h_ring_addr[31:0]    <= s_axil_wdata;
                    ADDR_C2H_RING_ADDR_H: reg_c2h_ring_addr[63:32]   <= s_axil_wdata;
                    ADDR_C2H_RING_CFG: begin
                        reg_c2h_ring_size <= s_axil_wdata[15:0];
                        reg_c2h_tail_ptr  <= s_axil_wdata[31:16];
                    end
                    ADDR_IRQ_CTRL:        reg_irq_ctrl               <= s_axil_wdata;
                    default: ;
                endcase
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid  <= 1'b0;
                s_axil_awready <= 1'b1;
                s_axil_wready  <= 1'b1;
            end
        end
    end

    // AXI4-Lite Read Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b1;
            s_axil_rvalid  <= 1'b0;
            s_axil_rresp   <= 2'b00;
            s_axil_rdata   <= 32'd0;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_arready <= 1'b0;
                s_axil_rvalid  <= 1'b1;
                s_axil_rresp   <= 2'b00;

                case (s_axil_araddr[7:0])
                    ADDR_DMA_CTRL:        s_axil_rdata <= reg_dma_ctrl;
                    ADDR_DMA_STATUS:      s_axil_rdata <= reg_dma_status;
                    ADDR_H2C_RING_ADDR_L: s_axil_rdata <= reg_h2c_ring_addr[31:0];
                    ADDR_H2C_RING_ADDR_H: s_axil_rdata <= reg_h2c_ring_addr[63:32];
                    ADDR_H2C_RING_CFG:    s_axil_rdata <= {reg_h2c_tail_ptr, reg_h2c_ring_size};
                    ADDR_C2H_RING_ADDR_L: s_axil_rdata <= reg_c2h_ring_addr[31:0];
                    ADDR_C2H_RING_ADDR_H: s_axil_rdata <= reg_c2h_ring_addr[63:32];
                    ADDR_C2H_RING_CFG:    s_axil_rdata <= {reg_c2h_tail_ptr, reg_c2h_ring_size};
                    ADDR_IRQ_CTRL:        s_axil_rdata <= reg_irq_ctrl;
                    ADDR_IRQ_STATUS:      s_axil_rdata <= reg_irq_status;
                    ADDR_H2C_COUNT:       s_axil_rdata <= completed_h2c_count;
                    ADDR_C2H_COUNT:       s_axil_rdata <= completed_c2h_count;
                    default:              s_axil_rdata <= 32'hDEADBEEF;
                endcase
            end else if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid  <= 1'b0;
                s_axil_arready <= 1'b1;
            end
        end
    end

endmodule
