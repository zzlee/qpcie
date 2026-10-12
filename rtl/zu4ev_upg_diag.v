// Monotonic, per-event evidence for PCIe H2C canary triage without JTAG.
// Only LEVELS (sticky bits) cross PCIe -> PL; clear is a PL toggle that is
// synchronized before use. One clear per canary; host must wait for clear ACK.
`timescale 1ns / 1ps
module zu4ev_upg_diag (
    input  wire        clk_pcie,
    input  wire        rst_pcie_n,
    input  wire        clk_pl,
    input  wire        rst_pl_n,
    input  wire        clear_toggle_pl,
    input  wire [12:0] pcie_events,
    input  wire [13:0] writer_events,
    output reg  [31:0] pcie_sticky_pl,
    output reg  [31:0] writer_sticky_pl,
    output wire        clear_ack_pl
);
    reg [31:0] pcie_sticky;
    (* ASYNC_REG = "TRUE" *) reg [2:0] clear_pcie_sync;
    reg clear_pcie_seen;
    (* ASYNC_REG = "TRUE" *) reg [31:0] pcie_meta;
    (* ASYNC_REG = "TRUE" *) reg [1:0] clear_ack_sync;
    reg clear_writer_seen;
    assign clear_ack_pl = clear_ack_sync[1];

    always @(posedge clk_pcie or negedge rst_pcie_n) begin
        if (!rst_pcie_n) begin
            clear_pcie_sync <= 0;
            clear_pcie_seen <= 0;
            pcie_sticky <= 0;
        end else begin
            clear_pcie_sync <= {clear_pcie_sync[1:0], clear_toggle_pl};
            if (clear_pcie_sync[2] != clear_pcie_seen) begin
                clear_pcie_seen <= clear_pcie_sync[2];
                pcie_sticky <= 0;
            end else
                pcie_sticky <= pcie_sticky | {19'd0, pcie_events};
        end
    end

    always @(posedge clk_pl or negedge rst_pl_n) begin
        if (!rst_pl_n) begin
            pcie_meta <= 0;
            pcie_sticky_pl <= 0;
            writer_sticky_pl <= 0;
            clear_writer_seen <= 0;
            clear_ack_sync <= 0;
        end else begin
            pcie_meta <= pcie_sticky;
            pcie_sticky_pl <= pcie_meta;
            clear_ack_sync <= {clear_ack_sync[0], clear_pcie_seen};
            if (clear_writer_seen != clear_toggle_pl) begin
                clear_writer_seen <= clear_toggle_pl;
                writer_sticky_pl <= 0;
            end else
                writer_sticky_pl <= writer_sticky_pl | {18'd0, writer_events};
        end
    end
endmodule
