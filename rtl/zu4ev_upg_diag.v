// Independent monotonic sticky event levels, not a coherent data bus.
// PL clear toggle and PCIe ACK use recognized XPM synchronizers. The host
// must wait for clear ACK before issuing a new canary. No broad clock waiver.
`timescale 1ns / 1ps
module zu4ev_upg_diag (
    input  wire        clk_pcie,
    input  wire        rst_pcie_n,
    input  wire        clk_pl,
    input  wire        rst_pl_n,
    input  wire        clear_toggle_pl,
    input  wire [12:0] pcie_events,
    input  wire [13:0] writer_events,
    output wire [31:0] pcie_sticky_pl,
    output reg  [31:0] writer_sticky_pl,
    output wire        clear_ack_pl
);
    reg [12:0] pcie_sticky;
    wire clear_pcie_sync, ack_sync;
    wire [12:0] pcie_levels_pl;
    reg clear_pcie_seen;
    reg clear_writer_seen;

    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0)) u_clear (
        .src_clk(clk_pl), .src_in(clear_toggle_pl),
        .dest_clk(clk_pcie), .dest_out(clear_pcie_sync)
    );
    xpm_cdc_array_single #(.WIDTH(13), .DEST_SYNC_FF(3), .SRC_INPUT_REG(0)) u_levels (
        .src_clk(clk_pcie), .src_in(pcie_sticky),
        .dest_clk(clk_pl), .dest_out(pcie_levels_pl)
    );
    // One additional ACK stage lets cleared sticky levels settle first.
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(0)) u_ack (
        .src_clk(clk_pcie), .src_in(clear_pcie_seen),
        .dest_clk(clk_pl), .dest_out(ack_sync)
    );
    assign pcie_sticky_pl = rst_pl_n ? {19'd0, pcie_levels_pl} : 32'd0;
    assign clear_ack_pl = rst_pl_n && ack_sync;

    always @(posedge clk_pcie or negedge rst_pcie_n) begin
        if (!rst_pcie_n) begin
            clear_pcie_seen <= 1'b0;
            pcie_sticky <= 13'd0;
        end else if (clear_pcie_sync != clear_pcie_seen) begin
            clear_pcie_seen <= clear_pcie_sync;
            pcie_sticky <= 13'd0;
        end else
            pcie_sticky <= pcie_sticky | pcie_events;
    end

    always @(posedge clk_pl or negedge rst_pl_n) begin
        if (!rst_pl_n) begin
            writer_sticky_pl <= 32'd0;
            clear_writer_seen <= 1'b0;
        end else if (clear_writer_seen != clear_toggle_pl) begin
            clear_writer_seen <= clear_toggle_pl;
            writer_sticky_pl <= 32'd0;
        end else
            writer_sticky_pl <= writer_sticky_pl | {18'd0, writer_events};
    end
endmodule
