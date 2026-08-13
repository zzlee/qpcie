// ============================================================================
// Module: axil_interconnect
// Description: 1-to-3 AXI4-Lite Interconnect / Crossbar Module.
//              Routes BAR1 AXI4-Lite Master transactions from PCIe DMA Top to:
//              - Master 0 (M00): Xilinx Video TPG IP s_axi_CTRL (Offset 0x0000 - 0x00FF)
//              - Master 1 (M01): Audio Pattern Generator IP (Offset 0x0100 - 0x01FF)
//              - Master 2 (M02): User Register / Peripheral Space (Offset 0x0200 - 0xFFFF)
// ============================================================================

`timescale 1ns / 1ps

module axil_interconnect #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Slave Interface (S00) - From BAR1 AXI4-Lite Master (PCIe DMA Top)
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

    // Master 0 Interface (M00) - To Video TPG IP s_axi_CTRL (Address Offset 0x0000 - 0x00FF)
    output wire [7:0]            m00_axil_awaddr,
    output wire                  m00_axil_awvalid,
    input  wire                  m00_axil_awready,
    output wire [DATA_WIDTH-1:0] m00_axil_wdata,
    output wire [3:0]            m00_axil_wstrb,
    output wire                  m00_axil_wvalid,
    input  wire                  m00_axil_wready,
    input  wire [1:0]            m00_axil_bresp,
    input  wire                  m00_axil_bvalid,
    output wire                  m00_axil_bready,

    output wire [7:0]            m00_axil_araddr,
    output wire                  m00_axil_arvalid,
    input  wire                  m00_axil_arready,
    input  wire [DATA_WIDTH-1:0] m00_axil_rdata,
    input  wire [1:0]            m00_axil_rresp,
    input  wire                  m00_axil_rvalid,
    output wire                  m00_axil_rready,

    // Master 1 Interface (M01) - To Audio Pattern Generator (Address Offset 0x0100 - 0x01FF)
    output wire [7:0]            m01_axil_awaddr,
    output wire                  m01_axil_awvalid,
    input  wire                  m01_axil_awready,
    output wire [DATA_WIDTH-1:0] m01_axil_wdata,
    output wire [3:0]            m01_axil_wstrb,
    output wire                  m01_axil_wvalid,
    input  wire                  m01_axil_wready,
    input  wire [1:0]            m01_axil_bresp,
    input  wire                  m01_axil_bvalid,
    output wire                  m01_axil_bready,

    output wire [7:0]            m01_axil_araddr,
    output wire                  m01_axil_arvalid,
    input  wire                  m01_axil_arready,
    input  wire [DATA_WIDTH-1:0] m01_axil_rdata,
    input  wire [1:0]            m01_axil_rresp,
    input  wire                  m01_axil_rvalid,
    output wire                  m01_axil_rready,

    // Master 2 Interface (M02) - To User Peripherals / Reg Space (Address Offset 0x0200 - 0xFFFF)
    output wire [ADDR_WIDTH-1:0] m02_axil_awaddr,
    output wire                  m02_axil_awvalid,
    input  wire                  m02_axil_awready,
    output wire [DATA_WIDTH-1:0] m02_axil_wdata,
    output wire [3:0]            m02_axil_wstrb,
    output wire                  m02_axil_wvalid,
    input  wire                  m02_axil_wready,
    input  wire [1:0]            m02_axil_bresp,
    input  wire                  m02_axil_bvalid,
    output wire                  m02_axil_bready,

    output wire [ADDR_WIDTH-1:0] m02_axil_araddr,
    output wire                  m02_axil_arvalid,
    input  wire                  m02_axil_arready,
    input  wire [DATA_WIDTH-1:0] m02_axil_rdata,
    input  wire [1:0]            m02_axil_rresp,
    input  wire                  m02_axil_rvalid,
    output wire                  m02_axil_rready
);

    // Address Decoding:
    // 2'b00: M00 Video TPG (Offset 0x0000 - 0x00FF, addr[15:8] == 8'h00)
    // 2'b01: M01 Audio Pat Gen (Offset 0x0100 - 0x01FF, addr[15:8] == 8'h01)
    // 2'b10: M02 User Regs (Offset 0x0200 - 0xFFFF, addr[15:8] >= 8'h02)
    wire [1:0] wr_target = (s_axil_awaddr[15:8] == 8'h00) ? 2'b00 :
                           (s_axil_awaddr[15:8] == 8'h01) ? 2'b01 : 2'b10;

    wire [1:0] rd_target = (s_axil_araddr[15:8] == 8'h00) ? 2'b00 :
                           (s_axil_araddr[15:8] == 8'h01) ? 2'b01 : 2'b10;

    reg [1:0] wr_active_target;
    reg [1:0] rd_active_target;

    // Write Channel Muxing
    assign m00_axil_awaddr  = s_axil_awaddr[7:0];
    assign m00_axil_awvalid = s_axil_awvalid && (wr_target == 2'b00);
    assign m00_axil_wdata   = s_axil_wdata;
    assign m00_axil_wstrb   = s_axil_wstrb;
    assign m00_axil_wvalid  = s_axil_wvalid && (wr_target == 2'b00);
    assign m00_axil_bready  = s_axil_bready && (wr_active_target == 2'b00);

    assign m01_axil_awaddr  = s_axil_awaddr[7:0];
    assign m01_axil_awvalid = s_axil_awvalid && (wr_target == 2'b01);
    assign m01_axil_wdata   = s_axil_wdata;
    assign m01_axil_wstrb   = s_axil_wstrb;
    assign m01_axil_wvalid  = s_axil_wvalid && (wr_target == 2'b01);
    assign m01_axil_bready  = s_axil_bready && (wr_active_target == 2'b01);

    assign m02_axil_awaddr  = s_axil_awaddr;
    assign m02_axil_awvalid = s_axil_awvalid && (wr_target == 2'b10);
    assign m02_axil_wdata   = s_axil_wdata;
    assign m02_axil_wstrb   = s_axil_wstrb;
    assign m02_axil_wvalid  = s_axil_wvalid && (wr_target == 2'b10);
    assign m02_axil_bready  = s_axil_bready && (wr_active_target == 2'b10);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active_target <= 2'b00;
            s_axil_awready   <= 1'b0;
            s_axil_wready    <= 1'b0;
            s_axil_bvalid    <= 1'b0;
            s_axil_bresp     <= 2'b00;
        end else begin
            if (s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid) begin
                wr_active_target <= wr_target;
                case (wr_target)
                    2'b00: begin
                        s_axil_awready <= m00_axil_awready;
                        s_axil_wready  <= m00_axil_wready;
                        s_axil_bvalid  <= m00_axil_bvalid;
                        s_axil_bresp   <= m00_axil_bresp;
                    end
                    2'b01: begin
                        s_axil_awready <= m01_axil_awready;
                        s_axil_wready  <= m01_axil_wready;
                        s_axil_bvalid  <= m01_axil_bvalid;
                        s_axil_bresp   <= m01_axil_bresp;
                    end
                    default: begin
                        s_axil_awready <= m02_axil_awready;
                        s_axil_wready  <= m02_axil_wready;
                        s_axil_bvalid  <= m02_axil_bvalid;
                        s_axil_bresp   <= m02_axil_bresp;
                    end
                endcase
            end else begin
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
                case (wr_active_target)
                    2'b00: begin
                        s_axil_bvalid <= m00_axil_bvalid;
                        s_axil_bresp  <= m00_axil_bresp;
                    end
                    2'b01: begin
                        s_axil_bvalid <= m01_axil_bvalid;
                        s_axil_bresp  <= m01_axil_bresp;
                    end
                    default: begin
                        s_axil_bvalid <= m02_axil_bvalid;
                        s_axil_bresp  <= m02_axil_bresp;
                    end
                endcase
            end
        end
    end

    // Read Channel Muxing
    assign m00_axil_araddr  = s_axil_araddr[7:0];
    assign m00_axil_arvalid = s_axil_arvalid && (rd_target == 2'b00);
    assign m00_axil_rready  = s_axil_rready && (rd_active_target == 2'b00);

    assign m01_axil_araddr  = s_axil_araddr[7:0];
    assign m01_axil_arvalid = s_axil_arvalid && (rd_target == 2'b01);
    assign m01_axil_rready  = s_axil_rready && (rd_active_target == 2'b01);

    assign m02_axil_araddr  = s_axil_araddr;
    assign m02_axil_arvalid = s_axil_arvalid && (rd_target == 2'b10);
    assign m02_axil_rready  = s_axil_rready && (rd_active_target == 2'b10);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active_target <= 2'b00;
            s_axil_arready   <= 1'b0;
            s_axil_rvalid    <= 1'b0;
            s_axil_rdata     <= {DATA_WIDTH{1'b0}};
            s_axil_rresp     <= 2'b00;
        end else begin
            if (s_axil_arvalid && !s_axil_rvalid) begin
                rd_active_target <= rd_target;
                case (rd_target)
                    2'b00: begin
                        s_axil_arready <= m00_axil_arready;
                        s_axil_rvalid  <= m00_axil_rvalid;
                        s_axil_rdata   <= m00_axil_rdata;
                        s_axil_rresp   <= m00_axil_rresp;
                    end
                    2'b01: begin
                        s_axil_arready <= m01_axil_arready;
                        s_axil_rvalid  <= m01_axil_rvalid;
                        s_axil_rdata   <= m01_axil_rdata;
                        s_axil_rresp   <= m01_axil_rresp;
                    end
                    default: begin
                        s_axil_arready <= m02_axil_arready;
                        s_axil_rvalid  <= m02_axil_rvalid;
                        s_axil_rdata   <= m02_axil_rdata;
                        s_axil_rresp   <= m02_axil_rresp;
                    end
                endcase
            end else begin
                s_axil_arready <= 1'b0;
                case (rd_active_target)
                    2'b00: begin
                        s_axil_rvalid <= m00_axil_rvalid;
                        s_axil_rdata  <= m00_axil_rdata;
                        s_axil_rresp  <= m00_axil_rresp;
                    end
                    2'b01: begin
                        s_axil_rvalid <= m01_axil_rvalid;
                        s_axil_rdata  <= m01_axil_rdata;
                        s_axil_rresp  <= m01_axil_rresp;
                    end
                    default: begin
                        s_axil_rvalid <= m02_axil_rvalid;
                        s_axil_rdata  <= m02_axil_rdata;
                        s_axil_rresp  <= m02_axil_rresp;
                    end
                endcase
            end
        end
    end

endmodule
