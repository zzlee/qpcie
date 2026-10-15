// Ordered CSR snapshots, including one-cycle write events, across unrelated
// clocks. Keep the authoritative register bank on the independent PS clock.
// src_commit is asserted on the SAME edge that updates that register bank;
// src_level/src_event are sampled on the following edge (after the update).
// The register bank must gate commits with src_ready. Reads never wait here.
//
// No PCIe clock/link: writes update the PS bank without waiting. A new link
// receives the current levels once, with ZERO events (no reset/W1C replay).
// A stopped destination clock is detected locally, so PS writes cannot hang
// indefinitely even if the PCIe core's link/reset outputs stop changing.
`timescale 1ns / 1ps
module qpcie_csr_cdc #(
    parameter integer LEVEL_WIDTH = 32,
    parameter integer EVENT_WIDTH = 1
)(
    input wire src_clk, src_rst_n,
    input wire dest_clk, dest_rst_n,
    input wire [LEVEL_WIDTH-1:0] src_level,
    input wire [EVENT_WIDTH-1:0] src_event,
    input wire src_commit,
    output wire src_ready,
    output wire src_online,
    output reg [LEVEL_WIDTH-1:0] dest_level,
    output reg [EVENT_WIDTH-1:0] dest_event
);
    reg [3:0] heartbeat = 4'd0;
    always @(posedge dest_clk or negedge dest_rst_n)
        if (!dest_rst_n) heartbeat <= 4'd0;
        else heartbeat <= heartbeat + 1'b1;

    // Export a registered level, not the PCIe core's combined reset/link
    // expression, into the independent PS domain.
    reg dest_running = 1'b0;
    always @(posedge dest_clk or negedge dest_rst_n)
        if (!dest_rst_n) dest_running <= 1'b0;
        else dest_running <= 1'b1;
    wire pcie_ready, heartbeat_sync;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(3), .RST_ACTIVE_HIGH(0)) u_online_sync (
        .src_arst(dest_running), .dest_clk(src_clk), .dest_arst(pcie_ready)
    );
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0)) u_heartbeat_sync (
        .src_clk(dest_clk), .src_in(heartbeat[3]),
        .dest_clk(src_clk), .dest_out(heartbeat_sync)
    );
    reg clock_alive = 1'b0;
    reg heartbeat_last = 1'b0;
    reg [7:0] heartbeat_age = 8'hff;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            clock_alive <= 1'b0;
            heartbeat_last <= 1'b0;
            heartbeat_age <= 8'hff;
        end else if (!pcie_ready) begin
            clock_alive <= 1'b0;
            heartbeat_last <= heartbeat_sync;
            heartbeat_age <= 8'hff;
        end else if (heartbeat_sync != heartbeat_last) begin
            clock_alive <= 1'b1;
            heartbeat_last <= heartbeat_sync;
            heartbeat_age <= 8'd0;
        end else if (heartbeat_age != 8'hff) begin
            heartbeat_age <= heartbeat_age + 1'b1;
            if (heartbeat_age == 8'hfe) clock_alive <= 1'b0;
        end
    end
    // Registered timeout: do not drive asynchronous FIFO reset with a binary
    // counter's combinational terminal-count decode (which can glitch).
    assign src_online = pcie_ready && clock_alive;

    wire full, empty, wr_busy, rd_busy;
    wire [LEVEL_WIDTH+EVENT_WIDTH-1:0] fifo_data;
    reg pending = 1'b0;
    reg initialize = 1'b1;
    wire fifo_write = src_online && !wr_busy && !full && (pending || initialize);
    wire ps_ready_pcie;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(3), .RST_ACTIVE_HIGH(0)) u_bank_reset (
        .src_arst(src_rst_n), .dest_clk(dest_clk), .dest_arst(ps_ready_pcie)
    );
    // Combine resets only AFTER the PS reset has crossed into PCIe.
    wire bank_reset = !ps_ready_pcie || !dest_rst_n;
    wire fifo_read = !bank_reset && !rd_busy && !empty;
    assign src_ready = !src_online || (!wr_busy && !full && !pending && !initialize);

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            pending <= 1'b0;
            initialize <= 1'b1;
        end else if (!src_online) begin
            pending <= 1'b0;
            initialize <= 1'b1;
        end else begin
            if (fifo_write) begin
                pending <= 1'b0;
                initialize <= 1'b0;
            end
            if (src_commit && src_ready)
                pending <= 1'b1;
        end
    end

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(16),
        .WRITE_DATA_WIDTH(LEVEL_WIDTH+EVENT_WIDTH),
        .READ_DATA_WIDTH(LEVEL_WIDTH+EVENT_WIDTH),
        .CDC_SYNC_STAGES(3), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES("0000"), .SIM_ASSERT_CHK(1)
    ) u_fifo (
        .rst(!src_rst_n || !src_online),
        .wr_clk(src_clk), .wr_en(fifo_write),
        .din({src_level, initialize ? {EVENT_WIDTH{1'b0}} : src_event}),
        .full(full), .wr_rst_busy(wr_busy),
        .rd_clk(dest_clk), .rd_en(fifo_read), .dout(fifo_data),
        .empty(empty), .rd_rst_busy(rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
    );

    always @(posedge dest_clk or posedge bank_reset) begin
        if (bank_reset) begin
            dest_level <= {LEVEL_WIDTH{1'b0}};
            dest_event <= {EVENT_WIDTH{1'b0}};
        end else begin
            dest_event <= {EVENT_WIDTH{1'b0}};
            if (fifo_read) begin
                dest_level <= fifo_data[LEVEL_WIDTH+EVENT_WIDTH-1:EVENT_WIDTH];
                dest_event <= fifo_data[EVENT_WIDTH-1:0];
            end
        end
    end
endmodule
