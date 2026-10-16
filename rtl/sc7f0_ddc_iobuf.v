// HDMI DDC open-drain pads. Even an IP output of 1 must release, not drive high.
`timescale 1ns/1ps
module sc7f0_ddc_iobuf (
    output wire scl_i, input wire scl_o, input wire scl_t,
    output wire sda_i, input wire sda_o, input wire sda_t,
    inout wire scl, inout wire sda
);
    IOBUF u_scl (.I(1'b0), .T(scl_t | scl_o), .O(scl_i), .IO(scl));
    IOBUF u_sda (.I(1'b0), .T(sda_t | sda_o), .O(sda_i), .IO(sda));
endmodule
