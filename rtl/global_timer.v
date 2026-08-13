// ============================================================================
// Module: global_timer
// Description: 64-bit Precision System Timestamp Generator for Hardware AV Sync.
//              Driven by pcie_user_clk (125MHz, 8ns resolution).
//              Provides latched timestamps for Video SOF & Audio Block Starts.
// ============================================================================

`timescale 1ns / 1ps

module global_timer (
    input  wire        clk,
    input  wire        rst_n,

    // Control Registers (BAR0 Mapped)
    input  wire        timer_clear,        // Pulse to clear timer to 0
    input  wire        timer_enable,       // Enable timer increment (default 1)
    input  wire [63:0] timer_preset,       // Preset timestamp value
    input  wire        timer_load,         // Load preset value pulse

    // Timestamp Outputs
    output reg  [63:0] global_timestamp,   // Current freerunning 64-bit timestamp (ns)
    output wire [63:0] timestamp_90khz     // Converted 90kHz MPEG PTS timestamp
);

    // Increment step: at 125MHz, each clock cycle is exactly 8ns
    localparam INC_STEP = 64'd8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_timestamp <= 64'd0;
        end else if (timer_clear) begin
            global_timestamp <= 64'd0;
        end else if (timer_load) begin
            global_timestamp <= timer_preset;
        end else if (timer_enable) begin
            global_timestamp <= global_timestamp + INC_STEP;
        end
    end

    // 90kHz Timestamp Conversion: timestamp_ns * 90000 / 1,000,000,000 = (ns * 9) / 100000
    // Simplified fixed-point multiplication for 90kHz PTS
    assign timestamp_90khz = (global_timestamp * 64'd9) / 64'd100000;

endmodule
