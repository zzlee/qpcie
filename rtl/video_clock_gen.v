// ============================================================================
// Module: video_clock_gen
// Description: Generate a 150 MHz video clock from the PCIe 125 MHz user
//              clock.  MMCM VCO = 125 * 24 / 5 = 600 MHz; CLKOUT0 = /4.
// ============================================================================
`timescale 1ns / 1ps

module video_clock_gen (
    input  wire clk_125mhz,
    input  wire reset,
    output wire clk_150mhz,
    output wire locked
);
    wire clkfb_mmcm;
    wire clkfb_bufg;
    wire clk150_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(8.000),
        .DIVCLK_DIVIDE(5),
        .CLKFBOUT_MULT_F(24.000),
        .CLKOUT0_DIVIDE_F(4.000),
        .CLKOUT0_PHASE(0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .STARTUP_WAIT("FALSE")
    ) u_video_mmcm (
        .CLKIN1(clk_125mhz),
        .RST(reset),
        .PWRDWN(1'b0),
        .CLKFBIN(clkfb_bufg),
        .CLKFBOUT(clkfb_mmcm),
        .CLKOUT0(clk150_mmcm),
        .CLKOUT0B(),
        .CLKOUT1(),
        .CLKOUT1B(),
        .CLKOUT2(),
        .CLKOUT2B(),
        .CLKOUT3(),
        .CLKOUT3B(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .LOCKED(locked)
    );

    BUFG u_video_clkfb_bufg (
        .I(clkfb_mmcm),
        .O(clkfb_bufg)
    );

    BUFG u_video_clk_bufg (
        .I(clk150_mmcm),
        .O(clk_150mhz)
    );
endmodule
