`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/09/2025 10:16:09 AM
// Design Name: 
// Module Name: zzlab_env_ctrl
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module zzlab_env_ctrl #(
	parameter C_S_AXI_ADDR_WIDTH = 6,
	parameter C_S_AXI_DATA_WIDTH = 32,

	parameter C_VERSION = 32'h26100803,
	parameter C_PLATFORM = "YYYY",
	parameter C_BOARD_VERSION = 32'h0
) (
	input clk,
	input rst_n,

	input  [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_ctrl_awaddr,
	input                             s_axi_ctrl_awvalid,
	output                            s_axi_ctrl_awready,
	input  [C_S_AXI_DATA_WIDTH-1:0]   s_axi_ctrl_wdata,
	input  [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_ctrl_wstrb,
	input                             s_axi_ctrl_wvalid,
	output                            s_axi_ctrl_wready,
	output [1:0]                      s_axi_ctrl_bresp,
	output                            s_axi_ctrl_bvalid,
	input                             s_axi_ctrl_bready,
	input  [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_ctrl_araddr,
	input                             s_axi_ctrl_arvalid,
	output                            s_axi_ctrl_arready,
	output [C_S_AXI_DATA_WIDTH-1:0]   s_axi_ctrl_rdata,
	output [1:0]                      s_axi_ctrl_rresp,
	output                            s_axi_ctrl_rvalid,
	input                             s_axi_ctrl_rready,

	output [31:0] ap_rst_n
);
//------------------------Address Info-------------------

//------------------------Parameter----------------------
localparam
	ADDR_OUT_VERSION        = 6'h00,
	ADDR_OUT_PLATFORM       = 6'h04,
	ADDR_OUT_BOARD_VERSION  = 6'h08,
	ADDR_OUT_TICK_COUNTER   = 6'h0C,
	ADDR_OUT_AP_RST_N       = 6'h10,
	ADDR_OUT_VALUE0         = 6'h14,
	ADDR_BITS               = 6;

localparam
	WRIDLE                  = 2'd0,
	WRDATA                  = 2'd1,
	WRRESP                  = 2'd2,
	WRRESET                 = 2'd3,
	RDIDLE                  = 2'd0,
	RDDATA                  = 2'd1,
	RDRESET                 = 2'd2;

//------------------------Local signal-------------------
	wire                            ACLK_EN;
	wire                            ACLK;
	wire                            ARESET;
	wire [C_S_AXI_ADDR_WIDTH-1:0]   AWADDR;
	wire                            AWVALID;
	wire                            AWREADY;
	wire [C_S_AXI_DATA_WIDTH-1:0]   WDATA;
	wire [C_S_AXI_DATA_WIDTH/8-1:0] WSTRB;
	wire                            WVALID;
	wire                            WREADY;
	wire [1:0]                      BRESP;
	wire                            BVALID;
	wire                            BREADY;
	wire [C_S_AXI_ADDR_WIDTH-1:0]   ARADDR;
	wire                            ARVALID;
	wire                            ARREADY;
	wire [C_S_AXI_DATA_WIDTH-1:0]   RDATA;
	wire [1:0]                      RRESP;
	wire                            RVALID;
	wire                            RREADY;

	reg  [1:0]                    wstate = WRRESET;
	reg  [1:0]                    wnext;
	reg  [ADDR_BITS-1:0]          waddr;
	wire [C_S_AXI_DATA_WIDTH-1:0] wmask;
	wire                          aw_hs;
	wire                          w_hs;
	reg  [1:0]                    rstate = RDRESET;
	reg  [1:0]                    rnext;
	reg  [C_S_AXI_DATA_WIDTH-1:0] rdata;
	wire                          ar_hs;
	wire [ADDR_BITS-1:0]          raddr;

	// internal registers
    reg  [31:0]                   int_out_tick_counter = 'b0;
    reg  [31:0]                   int_out_ap_rst_n = 'b0;
    reg  [31:0]                   int_out_value0 = 'b0;

//------------------------Instantiation------------------
assign ACLK_EN = 1;
assign ACLK = clk;
assign ARESET = ~rst_n;
assign AWADDR = s_axi_ctrl_awaddr;
assign AWVALID = s_axi_ctrl_awvalid;
assign s_axi_ctrl_awready = AWREADY;
assign WDATA = s_axi_ctrl_wdata;
assign WSTRB = s_axi_ctrl_wstrb;
assign WVALID = s_axi_ctrl_wvalid;
assign s_axi_ctrl_wready = WREADY;
assign s_axi_ctrl_bresp = BRESP;
assign s_axi_ctrl_bvalid = BVALID;
assign BREADY = s_axi_ctrl_bready;
assign ARADDR = s_axi_ctrl_araddr;
assign ARVALID = s_axi_ctrl_arvalid;
assign s_axi_ctrl_arready = ARREADY;
assign s_axi_ctrl_rdata = RDATA;
assign s_axi_ctrl_rresp = RRESP;
assign s_axi_ctrl_rvalid = RVALID;
assign RREADY = s_axi_ctrl_rready;

assign ap_rst_n = int_out_ap_rst_n;

//------------------------AXI write fsm------------------
assign AWREADY = (wstate == WRIDLE);
assign WREADY  = (wstate == WRDATA);
assign BRESP   = 2'b00;  // OKAY
assign BVALID  = (wstate == WRRESP);
assign wmask   = { {8{WSTRB[3]}}, {8{WSTRB[2]}}, {8{WSTRB[1]}}, {8{WSTRB[0]}} };
assign aw_hs   = AWVALID & AWREADY;
assign w_hs    = WVALID & WREADY;

// wstate
always @(posedge ACLK) begin
	if (ARESET)
		wstate <= WRRESET;
	else if (ACLK_EN)
		wstate <= wnext;
end

// wnext
always @(*) begin
	case (wstate)
		WRIDLE:
			if (AWVALID)
				wnext = WRDATA;
			else
				wnext = WRIDLE;
		WRDATA:
			if (WVALID)
				wnext = WRRESP;
			else
				wnext = WRDATA;
		WRRESP:
			if (BREADY)
				wnext = WRIDLE;
			else
				wnext = WRRESP;
		default:
			wnext = WRIDLE;
	endcase
end

// waddr
always @(posedge ACLK) begin
	if (ACLK_EN) begin
		if (aw_hs)
			waddr <= AWADDR[ADDR_BITS-1:0];
	end
end

//------------------------AXI read fsm-------------------
assign ARREADY = (rstate == RDIDLE);
assign RDATA   = rdata;
assign RRESP   = 2'b00;  // OKAY
assign RVALID  = (rstate == RDDATA);
assign ar_hs   = ARVALID & ARREADY;
assign raddr   = ARADDR[ADDR_BITS-1:0];

// rstate
always @(posedge ACLK) begin
	if (ARESET)
		rstate <= RDRESET;
	else if (ACLK_EN)
		rstate <= rnext;
end

// rnext
always @(*) begin
	case (rstate)
		RDIDLE:
			if (ARVALID)
				rnext = RDDATA;
			else
				rnext = RDIDLE;
		RDDATA:
			if (RREADY & RVALID)
				rnext = RDIDLE;
			else
				rnext = RDDATA;
		default:
			rnext = RDIDLE;
	endcase
end

// rdata
always @(posedge ACLK) begin
	if (ACLK_EN) begin
		if (ar_hs) begin
			rdata <= 'b0;
			case (raddr)
				ADDR_OUT_VERSION: begin
					rdata <= C_VERSION;
				end
				ADDR_OUT_PLATFORM: begin
					rdata <= C_PLATFORM;
				end
				ADDR_OUT_BOARD_VERSION: begin
					rdata <= C_BOARD_VERSION;
				end
				ADDR_OUT_TICK_COUNTER: begin
					rdata <= int_out_tick_counter;
				end
				ADDR_OUT_AP_RST_N: begin
					rdata <= int_out_ap_rst_n;
				end
				ADDR_OUT_VALUE0: begin
					rdata <= int_out_value0;
				end
			endcase
		end
	end
end


//------------------------Register logic-----------------
// int_out_tick_counter
always @(posedge ACLK) begin
    if (ARESET)
        int_out_tick_counter <= 0;
    else if (ACLK_EN) begin
        int_out_tick_counter <= int_out_tick_counter + 1;
    end
end

// int_out_ap_rst_n
always @(posedge ACLK) begin
    if (ARESET)
        int_out_ap_rst_n <= 0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_OUT_AP_RST_N)
			int_out_ap_rst_n[31:0] <= (WDATA[31:0] & wmask) | (int_out_ap_rst_n[31:0] & ~wmask);
    end
end

// int_out_value0
always @(posedge ACLK) begin
    if (ARESET)
        int_out_value0 <= 0;
    else if (ACLK_EN) begin
        if (w_hs && waddr == ADDR_OUT_VALUE0)
			int_out_value0[31:0] <= (WDATA[31:0] & wmask) | (int_out_value0[31:0] & ~wmask);
    end
end

//------------------------Memory logic-------------------

endmodule

