// ============================================================================
// Module: axil_decerr_slave
// Description: AXI4-Lite guard responder. Returns DECERR instantly for any
//              access to an unmapped/reserved window (e.g. BAR1 0x0000 after
//              zzlab_env moved to BAR0). Prevents requester hang on stray
//              accesses: host gets an error completion instead of a wedge.
// ============================================================================
`timescale 1ns / 1ps

module axil_decerr_slave (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output reg         s_axil_wready,
    output wire [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [31:0] s_axil_araddr,
    input  wire        s_axil_arvalid,
    output reg         s_axil_arready,
    output wire [31:0] s_axil_rdata,
    output wire [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready
);
    assign s_axil_bresp = 2'b11; // DECERR
    assign s_axil_rresp = 2'b11; // DECERR
    assign s_axil_rdata = 32'hDEAD_EC00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready <= 1'b0;
            s_axil_wready  <= 1'b0;
            s_axil_bvalid  <= 1'b0;
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
        end else begin
            s_axil_awready <= s_axil_awvalid && !s_axil_bvalid;
            s_axil_wready  <= s_axil_wvalid && !s_axil_bvalid;
            if (s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid)
                s_axil_bvalid <= 1'b1;
            else if (s_axil_bready)
                s_axil_bvalid <= 1'b0;
            s_axil_arready <= s_axil_arvalid && !s_axil_rvalid;
            if (s_axil_arvalid && !s_axil_rvalid)
                s_axil_rvalid <= 1'b1;
            else if (s_axil_rready)
                s_axil_rvalid <= 1'b0;
        end
    end
endmodule
