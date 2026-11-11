// Disabled peripheral aperture: independent AW/W acceptance, bounded DECERR.
// Keep removed TX/TPG addresses responsive without exposing dummy devices.
`timescale 1ns / 1ps
module sc7f0_axil_disabled #(
    parameter integer ADDR_WIDTH = 32
)(
    input wire clk, input wire rst_n,
    input wire [ADDR_WIDTH-1:0] s_axil_awaddr,
    input wire s_axil_awvalid, output wire s_axil_awready,
    input wire [31:0] s_axil_wdata, input wire [3:0] s_axil_wstrb,
    input wire s_axil_wvalid, output wire s_axil_wready,
    output wire [1:0] s_axil_bresp, output reg s_axil_bvalid,
    input wire s_axil_bready,
    input wire [ADDR_WIDTH-1:0] s_axil_araddr,
    input wire s_axil_arvalid, output wire s_axil_arready,
    output wire [31:0] s_axil_rdata, output wire [1:0] s_axil_rresp,
    output reg s_axil_rvalid, input wire s_axil_rready
);
    reg aw_pending, w_pending;
    assign s_axil_awready = rst_n && !aw_pending && !s_axil_bvalid;
    assign s_axil_wready = rst_n && !w_pending && !s_axil_bvalid;
    assign s_axil_arready = rst_n && !s_axil_rvalid;
    assign s_axil_bresp = 2'b11;
    assign s_axil_rresp = 2'b11;
    assign s_axil_rdata = 32'hdead_ec00;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_pending <= 0; w_pending <= 0;
            s_axil_bvalid <= 0; s_axil_rvalid <= 0;
        end else begin
            if (s_axil_awvalid && s_axil_awready) aw_pending <= 1;
            if (s_axil_wvalid && s_axil_wready) w_pending <= 1;
            if (aw_pending && w_pending) begin
                aw_pending <= 0; w_pending <= 0;
                s_axil_bvalid <= 1;
            end else if (s_axil_bvalid && s_axil_bready)
                s_axil_bvalid <= 0;
            if (s_axil_arvalid && s_axil_arready) s_axil_rvalid <= 1;
            else if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 0;
        end
    end
endmodule
