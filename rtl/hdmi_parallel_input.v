// Source-synchronous input sampling. One IOB register stage keeps data and
// DE/VS/HS aligned before any packing/counter logic in the PCLK domain.
`timescale 1ns/1ps
module hdmi_parallel_input (
    input wire pclk,
    input wire [59:0] pixel_data,
    input wire de, vs, hs,
    output wire [59:0] sampled_data,
    output wire sampled_de, sampled_vs, sampled_hs
);
    (* IOB = "TRUE" *) reg [62:0] sampled = 63'd0;
    always @(posedge pclk) sampled <= {pixel_data, de, vs, hs};
    assign {sampled_data, sampled_de, sampled_vs, sampled_hs} = sampled;
endmodule
