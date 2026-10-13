// BAR0-triggered read-only canary probe. Never cancel an outstanding AXI AR:
// timeout is sticky, but BUSY remains asserted until the response is drained.
`timescale 1ns / 1ps
module zu4ev_ddr_readback #(
    parameter integer TIMEOUT_CYCLES = 1000000
)(
    input wire clk, rst_n,
    input wire request,
    input wire [31:0] offset,
    input wire dma_active,
    output reg [31:0] status, sequence_id,
    output reg [127:0] data,
    output reg [48:0] araddr,
    output reg arvalid,
    input wire arready,
    input wire [127:0] rdata,
    input wire [1:0] rresp,
    input wire [5:0] rid,
    input wire rlast, rvalid,
    output wire rready
);
    reg waiting;
    reg [31:0] timer;
    assign rready = waiting;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status <= 0; sequence_id <= 0; data <= 0;
            araddr <= 0; arvalid <= 0; waiting <= 0; timer <= 0;
        end else begin
            if (request && !status[0]) begin
                sequence_id <= sequence_id + 1;
                data <= 0; timer <= 0;
                if (dma_active || offset > 32'hff0 || offset[3:0] != 0)
                    status <= 32'h16; // DONE | ERROR | REJECTED; no AXI request
                else begin
                    status <= 1;
                    araddr <= 49'h30000000 + offset;
                    arvalid <= 1;
                end
            end
            if (status[0]) begin
                if (timer < TIMEOUT_CYCLES) timer <= timer + 1;
                else status[3] <= 1;
                if (arvalid && arready) begin
                    arvalid <= 0;
                    waiting <= 1;
                end
                if (rvalid && rready) begin
                    if (rresp != 0 || rid != 0 || !rlast) status[2] <= 1;
                    if (rlast) begin
                        data <= rdata;
                        status[0] <= 0;
                        status[1] <= 1;
                        waiting <= 0;
                    end
                end
            end
        end
    end
endmodule
