// SPDX-License-Identifier: GPL-2.0
// 8 KiB PS/PCIe shared debug mailbox. Entirely on pl_clk0; PCIe CDC is
// upstream. No dependency on DMA soft resets, PS DDR, or PCIe link reset.
// Only aligned full-word accesses are supported. Payload RAM is NOT reset.
`timescale 1ns/1ps
module qpcie_debug_mailbox (
    input wire clk, input wire rst_n,
    input wire [12:0] s_axi_awaddr,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp, output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [12:0] s_axi_araddr,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready
);
    (* ram_style = "block" *) reg [31:0] mem [0:2047];
    reg [31:0] control [2:31];
    reg aw_full, w_full, rd_pending;
    reg [12:0] awaddr;
    reg [31:0] wdata, rd_value;
    reg [3:0] wstrb;
    reg [1:0] rd_resp;
    integer i;
    assign s_axi_awready = !aw_full && !s_axi_bvalid;
    assign s_axi_wready = !w_full && !s_axi_bvalid;
    assign s_axi_arready = !rd_pending && !s_axi_rvalid;

    // Synchronous RAM read, separate from reset logic to preserve BRAM inference.
    reg [31:0] ram_read;
    always @(posedge clk) begin
        if (s_axi_arvalid && s_axi_arready)
            ram_read <= mem[s_axi_araddr[12:2]];
        if (aw_full && w_full && !s_axi_bvalid &&
            awaddr[1:0] == 0 && wstrb == 4'hf && awaddr >= 13'h080)
            mem[awaddr[12:2]] <= wdata;
    end
    reg rd_is_ram;
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_full <= 0; w_full <= 0; rd_pending <= 0;
            s_axi_bvalid <= 0; s_axi_bresp <= 0;
            s_axi_rvalid <= 0; s_axi_rdata <= 0; s_axi_rresp <= 0;
            awaddr <= 0; wdata <= 0; wstrb <= 0;
            rd_value <= 0; rd_resp <= 0; rd_is_ram <= 0;
            for (i = 2; i < 32; i = i + 1) control[i] <= 0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr <= s_axi_awaddr; aw_full <= 1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata <= s_axi_wdata; wstrb <= s_axi_wstrb; w_full <= 1;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (aw_full && w_full && !s_axi_bvalid) begin
                aw_full <= 0; w_full <= 0; s_axi_bvalid <= 1;
                s_axi_bresp <= 0;
                if (awaddr[1:0] != 0 || wstrb != 4'hf || awaddr < 8)
                    s_axi_bresp <= 2'b10;
                else if (awaddr < 13'h080) control[awaddr[6:2]] <= wdata;
            end
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                rd_pending <= 1;
                rd_is_ram <= s_axi_araddr >= 13'h080;
                rd_resp <= s_axi_araddr[1:0] == 0 ? 2'b00 : 2'b10;
                case (s_axi_araddr[12:2])
                    0: rd_value <= 32'h53434442; // SCDB numeric magic
                    1: rd_value <= 32'd1;
                    default: rd_value <= control[s_axi_araddr[6:2]];
                endcase
            end
            if (rd_pending) begin
                rd_pending <= 0; s_axi_rvalid <= 1;
                s_axi_rdata <= rd_is_ram ? ram_read : rd_value;
                s_axi_rresp <= rd_resp;
            end
        end
    end
endmodule
