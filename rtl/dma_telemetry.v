// ============================================================================
// Module: dma_telemetry
// Description: Real-time PCIe DMA Bandwidth and Latency Profiling Module.
//              - Counts total C2H Bytes transferred in 1-second interval
//              - Measures maximum PCIe MWr ACK request-to-ack latency (ns)
// ============================================================================

`timescale 1ns / 1ps

module dma_telemetry (
    input  wire        clk,
    input  wire        rst_n,

    // C2H MWr Request Monitoring
    input  wire        c2h_req_valid,
    input  wire [10:0] c2h_req_dw_len,   // Length in Double Words (4 Bytes)
    input  wire        c2h_req_ack,

    // Telemetry Registers (Read-Only via BAR0)
    output reg  [31:0] reg_bandwidth_bps, // Real-time Bytes/sec throughput
    output reg  [31:0] reg_latency_max_ns // Maximum MWr Ack Latency (ns)
);

    // 1 Second Timer Counter @ 125MHz (125,000,000 cycles)
    localparam ONE_SEC_CYCLES = 32'd125_000_000;

    reg [31:0] sec_clk_cnt;
    reg [31:0] byte_accumulator;

    // Latency Measurement Counter
    reg        measuring_lat;
    reg [31:0] lat_timer;
    reg [31:0] max_lat_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_clk_cnt       <= 32'd0;
            byte_accumulator  <= 32'd0;
            reg_bandwidth_bps <= 32'd0;
        end else begin
            if (sec_clk_cnt + 1'b1 >= ONE_SEC_CYCLES) begin
                sec_clk_cnt       <= 32'd0;
                reg_bandwidth_bps <= byte_accumulator;
                byte_accumulator  <= 32'd0;
            end else begin
                sec_clk_cnt <= sec_clk_cnt + 1'b1;
                if (c2h_req_valid && c2h_req_ack) begin
                    byte_accumulator <= byte_accumulator + (c2h_req_dw_len * 4);
                end
            end
        end
    end

    // MWr Ack Latency Measurement (ns)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            measuring_lat     <= 1'b0;
            lat_timer         <= 32'd0;
            max_lat_acc       <= 32'd0;
            reg_latency_max_ns <= 32'd0;
        end else begin
            if (c2h_req_valid && !measuring_lat) begin
                measuring_lat <= 1'b1;
                lat_timer     <= 32'd0;
            end else if (measuring_lat) begin
                lat_timer <= lat_timer + 8; // 8ns per cycle @ 125MHz
                if (c2h_req_ack) begin
                    measuring_lat <= 1'b0;
                    if (lat_timer > max_lat_acc) begin
                        max_lat_acc <= lat_timer;
                    end
                end
            end

            // Reset max latency accumulator every 1 second
            if (sec_clk_cnt == 0) begin
                reg_latency_max_ns <= max_lat_acc;
                max_lat_acc        <= 32'd0;
            end
        end
    end

endmodule
