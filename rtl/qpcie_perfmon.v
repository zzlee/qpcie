// SPDX-License-Identifier: MIT
// QPCIe Hardware Performance Monitor (qpcie_perfmon.v)
// High-precision RTL performance counters for PCIe DMA bandwidth & bottleneck attribution.

`timescale 1ns / 1ps

module qpcie_perfmon (
    input  wire        clk,                 // PCIe user clock (125 MHz)
    input  wire        rst_n,

    // Control from BAR0
    input  wire        perf_enable,         // Level enable
    input  wire        perf_reset,          // Pulse or W1C reset

    // Monitored Signals on PCIe TX / RQ interface
    input  wire        tx_tvalid,           // s_axis_tx_tvalid / s_axis_rq_tvalid
    input  wire        tx_tready,           // s_axis_tx_tready / s_axis_rq_tready
    input  wire        tx_tlast,            // s_axis_tx_tlast / s_axis_rq_tlast
    input  wire [10:0] tx_dw_len,           // Dword length of current TLP (32 DW=128B, 64 DW=256B)
    input  wire        tlp_start,           // Pulse on first beat of each TLP

    // Monitored Signals on upstream request / CDC interface
    input  wire        req_valid,           // Upstream DMA request valid
    input  wire        req_ack,             // Upstream request accepted
    input  wire        fifo_empty,          // Video CDC / Request FIFO empty
    input  wire [9:0]  fifo_count,          // Current request / data FIFO depth
    input  wire        split_4k_event,      // Pulse when a 4KB boundary clamp occurs

    // Performance Registers Output to BAR0 (Read-Only)
    output reg  [63:0] reg_perf_cycles,             // Total clocks while enabled
    output reg  [31:0] reg_perf_tlp_count,          // Total TLPs transmitted
    output reg  [63:0] reg_perf_payload_bytes,      // Total payload bytes sent
    output reg  [31:0] reg_perf_tx_active_cycles,   // Cycles when tx_tvalid && tx_tready
    output reg  [31:0] reg_perf_tx_idle_cycles,     // Cycles when !tx_tvalid
    output reg  [31:0] reg_perf_tready_stall_cycles,// Cycles when tx_tvalid && !tx_tready
    output reg  [31:0] reg_perf_inter_tlp_gap,      // Idle cycles between TLPs when FIFO is non-empty
    output reg  [31:0] reg_perf_tlp_128b_count,     // Count of 128-byte TLPs
    output reg  [31:0] reg_perf_tlp_256b_count,     // Count of 256-byte TLPs
    output reg  [31:0] reg_perf_split_4k_count,     // Count of 4KB boundary splits
    output reg  [15:0] reg_perf_max_queue_depth,    // Maximum FIFO count observed
    output reg  [31:0] reg_perf_idle_cdc_empty,     // Idle cycles due to empty CDC FIFO
    output reg  [31:0] reg_perf_idle_no_req         // Idle cycles with no DMA request active
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_perf_cycles              <= 64'd0;
            reg_perf_tlp_count           <= 32'd0;
            reg_perf_payload_bytes       <= 64'd0;
            reg_perf_tx_active_cycles    <= 32'd0;
            reg_perf_tx_idle_cycles      <= 32'd0;
            reg_perf_tready_stall_cycles <= 32'd0;
            reg_perf_inter_tlp_gap       <= 32'd0;
            reg_perf_tlp_128b_count      <= 32'd0;
            reg_perf_tlp_256b_count      <= 32'd0;
            reg_perf_split_4k_count      <= 32'd0;
            reg_perf_max_queue_depth     <= 16'd0;
            reg_perf_idle_cdc_empty      <= 32'd0;
            reg_perf_idle_no_req         <= 32'd0;
        end else if (perf_reset) begin
            reg_perf_cycles              <= 64'd0;
            reg_perf_tlp_count           <= 32'd0;
            reg_perf_payload_bytes       <= 64'd0;
            reg_perf_tx_active_cycles    <= 32'd0;
            reg_perf_tx_idle_cycles      <= 32'd0;
            reg_perf_tready_stall_cycles <= 32'd0;
            reg_perf_inter_tlp_gap       <= 32'd0;
            reg_perf_tlp_128b_count      <= 32'd0;
            reg_perf_tlp_256b_count      <= 32'd0;
            reg_perf_split_4k_count      <= 32'd0;
            reg_perf_max_queue_depth     <= 16'd0;
            reg_perf_idle_cdc_empty      <= 32'd0;
            reg_perf_idle_no_req         <= 32'd0;
        end else if (perf_enable) begin
            // 1. Total Cycles
            reg_perf_cycles <= reg_perf_cycles + 1'b1;

            // 2. TX Activity & Downstream Backpressure Stalls
            if (tx_tvalid && tx_tready) begin
                reg_perf_tx_active_cycles <= reg_perf_tx_active_cycles + 1'b1;
            end else if (tx_tvalid && !tx_tready) begin
                reg_perf_tready_stall_cycles <= reg_perf_tready_stall_cycles + 1'b1;
            end else begin
                reg_perf_tx_idle_cycles <= reg_perf_tx_idle_cycles + 1'b1;
                if (!fifo_empty)
                    reg_perf_inter_tlp_gap <= reg_perf_inter_tlp_gap + 1'b1;
                if (fifo_empty)
                    reg_perf_idle_cdc_empty <= reg_perf_idle_cdc_empty + 1'b1;
                if (!req_valid)
                    reg_perf_idle_no_req <= reg_perf_idle_no_req + 1'b1;
            end

            // 3. TLP Header & Length Tracking
            if (tlp_start) begin
                reg_perf_tlp_count <= reg_perf_tlp_count + 1'b1;
                if (tx_dw_len >= 11'd64) begin
                    reg_perf_tlp_256b_count <= reg_perf_tlp_256b_count + 1'b1;
                    reg_perf_payload_bytes  <= reg_perf_payload_bytes + 64'd256;
                end else if (tx_dw_len >= 11'd32) begin
                    reg_perf_tlp_128b_count <= reg_perf_tlp_128b_count + 1'b1;
                    reg_perf_payload_bytes  <= reg_perf_payload_bytes + 64'd128;
                end else begin
                    reg_perf_payload_bytes  <= reg_perf_payload_bytes + (tx_dw_len << 2);
                end
            end

            // 4. Boundary & Queue Depth Tracking
            if (split_4k_event)
                reg_perf_split_4k_count <= reg_perf_split_4k_count + 1'b1;

            if ({6'd0, fifo_count} > reg_perf_max_queue_depth)
                reg_perf_max_queue_depth <= {6'd0, fifo_count};
        end
    end

endmodule
