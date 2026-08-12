// ============================================================================
// Module: axil_reg_space
// Description: BAR0 AXI4-Lite Control & Status Register Space.
//              Contains DMA Ring Configuration, Interrupt Registers, Completed Counters,
//              and Firmware Version / Git Commit / Build Timestamp / Capabilities Regs.
// ============================================================================

`timescale 1ns / 1ps

module axil_reg_space (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite Slave Interface
    input  wire [31:0] s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output reg         s_axil_wready,
    output reg  [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,

    input  wire [31:0] s_axil_araddr,
    input  wire        s_axil_arvalid,
    output reg         s_axil_arready,
    output reg  [31:0] s_axil_rdata,
    output reg  [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,

    // Exported Register Signals
    output reg  [31:0] reg_dma_ctrl,
    input  wire [31:0] reg_dma_status,

    output reg  [63:0] reg_h2c_ring_addr,
    output reg  [15:0] reg_h2c_ring_size,
    output reg  [15:0] reg_h2c_tail_ptr,

    output reg  [63:0] reg_c2h_ring_addr,
    output reg  [15:0] reg_c2h_ring_size,
    output reg  [15:0] reg_c2h_tail_ptr,

    output reg  [31:0] reg_irq_ctrl,
    output reg  [31:0] reg_irq_status,

    input  wire [31:0] completed_h2c_count,
    input  wire [31:0] completed_c2h_count
);

    // BAR0 Register Offset Definitions
    localparam ADDR_DMA_CTRL         = 8'h00;
    localparam ADDR_DMA_STATUS       = 8'h04;
    localparam ADDR_H2C_RING_ADDR_L  = 8'h08;
    localparam ADDR_H2C_RING_ADDR_H  = 8'h0C;
    localparam ADDR_H2C_RING_CFG     = 8'h10;
    localparam ADDR_C2H_RING_ADDR_L  = 8'h14;
    localparam ADDR_C2H_RING_ADDR_H  = 8'h18;
    localparam ADDR_C2H_RING_CFG     = 8'h1C;
    localparam ADDR_IRQ_CTRL         = 8'h20;
    localparam ADDR_IRQ_STATUS       = 8'h24;
    localparam ADDR_COMPLETED_H2C    = 8'h28;
    localparam ADDR_COMPLETED_C2H    = 8'h2C;

    // New Version & Capability Registers (Read-Only)
    localparam ADDR_VERSION_ID       = 8'h30; // Major[31:24], Minor[23:16], Patch[15:8], Variant[7:0]
    localparam ADDR_GIT_COMMIT_HASH  = 8'h34; // Git Commit Hash (Lower 32-bit)
    localparam ADDR_BUILD_TIMESTAMP  = 8'h38; // BCD Date YYYYMMDD
    localparam ADDR_HARDWARE_CAPS    = 8'h3C; // Caps: [23:16]=NumAudioCh, [15:8]=NumVideoCh, [3:0]=Flags

    // Version Constant Constants
    localparam [31:0] VERSION_ID_VAL      = 32'h0201_0001; // v2.1.0 (Variant 1)
    localparam [31:0] GIT_COMMIT_HASH_VAL = 32'h01D6_A9C5; // Git Commit 1d6a9c5
    localparam [31:0] BUILD_TIMESTAMP_VAL = 32'h2026_0812; // Date 2026-08-12
    localparam [31:0] HARDWARE_CAPS_VAL   = 32'h0004_040F; // 4 Audio, 4 Video, Caps: 2D+AES3+DualBAR+Stream

    // Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_dma_ctrl      <= 32'd0;
            reg_h2c_ring_addr <= 64'd0;
            reg_h2c_ring_size <= 16'd0;
            reg_h2c_tail_ptr  <= 16'd0;
            reg_c2h_ring_addr <= 64'd0;
            reg_c2h_ring_size <= 16'd0;
            reg_c2h_tail_ptr  <= 16'd0;
            reg_irq_ctrl      <= 32'd0;
            reg_irq_status    <= 32'd0;
            s_axil_awready    <= 1'b0;
            s_axil_wready     <= 1'b0;
            s_axil_bvalid     <= 1'b0;
            s_axil_bresp      <= 2'b00; // OKAY
        end else begin
            if (s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid) begin
                s_axil_awready <= 1'b1;
                s_axil_wready  <= 1'b1;
                s_axil_bvalid  <= 1'b1;

                case (s_axil_awaddr[7:0])
                    ADDR_DMA_CTRL:        reg_dma_ctrl             <= s_axil_wdata;
                    ADDR_H2C_RING_ADDR_L: reg_h2c_ring_addr[31:0]  <= s_axil_wdata;
                    ADDR_H2C_RING_ADDR_H: reg_h2c_ring_addr[63:32] <= s_axil_wdata;
                    ADDR_H2C_RING_CFG: begin
                        reg_h2c_ring_size <= s_axil_wdata[15:0];
                        reg_h2c_tail_ptr  <= s_axil_wdata[31:16];
                    end
                    ADDR_C2H_RING_ADDR_L: reg_c2h_ring_addr[31:0]  <= s_axil_wdata;
                    ADDR_C2H_RING_ADDR_H: reg_c2h_ring_addr[63:32] <= s_axil_wdata;
                    ADDR_C2H_RING_CFG: begin
                        reg_c2h_ring_size <= s_axil_wdata[15:0];
                        reg_c2h_tail_ptr  <= s_axil_wdata[31:16];
                    end
                    ADDR_IRQ_CTRL:        reg_irq_ctrl             <= s_axil_wdata;
                    ADDR_IRQ_STATUS:      reg_irq_status           <= reg_irq_status & ~s_axil_wdata; // W1C
                    default: ; // Ignore writes to read-only registers
                endcase
            end else begin
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
                if (s_axil_bready && s_axil_bvalid) begin
                    s_axil_bvalid <= 1'b0;
                end
            end
        end
    end

    // Read Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
            s_axil_rdata   <= 32'd0;
            s_axil_rresp   <= 2'b00;
        end else begin
            if (s_axil_arvalid && !s_axil_rvalid) begin
                s_axil_arready <= 1'b1;
                s_axil_rvalid  <= 1'b1;

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
                    ADDR_COMPLETED_H2C:   s_axil_rdata <= completed_h2c_count;
                    ADDR_COMPLETED_C2H:   s_axil_rdata <= completed_c2h_count;

                    // New Version & Firmware Capability Registers
                    ADDR_VERSION_ID:      s_axil_rdata <= VERSION_ID_VAL;
                    ADDR_GIT_COMMIT_HASH: s_axil_rdata <= GIT_COMMIT_HASH_VAL;
                    ADDR_BUILD_TIMESTAMP: s_axil_rdata <= BUILD_TIMESTAMP_VAL;
                    ADDR_HARDWARE_CAPS:   s_axil_rdata <= HARDWARE_CAPS_VAL;

                    default:              s_axil_rdata <= 32'hDEAD_BEEF;
                endcase
            end else begin
                s_axil_arready <= 1'b0;
                if (s_axil_rready && s_axil_rvalid) begin
                    s_axil_rvalid <= 1'b0;
                end
            end
        end
    end

endmodule
