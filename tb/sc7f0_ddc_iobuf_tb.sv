`timescale 1ns/1ps
// Behavioral IOBUF model for pad-direction tests only (not an HDMI IP model).
module IOBUF(input I, input T, output O, inout IO);
    assign IO = T ? 1'bz : I;
    assign O = IO;
endmodule

module sc7f0_ddc_iobuf_tb;
    tri1 scl, sda;
    reg scl_o=0, scl_t=1, sda_o=0, sda_t=1;
    reg peer_scl_low=0, peer_sda_low=0;
    wire scl_i, sda_i;
    assign scl = peer_scl_low ? 1'b0 : 1'bz;
    assign sda = peer_sda_low ? 1'b0 : 1'bz;
    sc7f0_ddc_iobuf dut(.*);
    initial begin
        #1;
        if (scl_i !== 1 || sda_i !== 1) $fatal(1,"idle must release pads");
        scl_t=0; sda_t=0;
        #1;
        if (scl_i !== 0 || sda_i !== 0) $fatal(1,"drive low");
        scl_o=1; sda_o=1;
        #1;
        if (scl_i !== 1 || sda_i !== 1) $fatal(1,"logic one must release");
        peer_scl_low=1; peer_sda_low=1;
        #1;
        if (scl_i !== 0 || sda_i !== 0) $fatal(1,"peer low must override one without contention");
        scl_t=1; sda_t=1;
        #1;
        if (scl_i !== 0 || sda_i !== 0) $fatal(1,"clock stretch/readback");
        $display("TB_PASS: DDC release, low drive, peer clock stretch and no high drive");
        $finish;
    end
endmodule
