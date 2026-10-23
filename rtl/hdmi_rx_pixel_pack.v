// HDMI RX AXI video follows UG934: RGB is R:B:G (MSB->LSB),
// YUV444 is V:U:Y. Present host RGB bytes R,G,B or converter bytes Y,U,V.
`timescale 1ns/1ps
module hdmi_rx_pixel_pack (
    input wire [95:0] native_data,
    input wire rgb_mode,
    output wire [127:0] dma_data
);
    genvar p;
    generate for (p=0; p<4; p=p+1) begin : pixel
        wire [23:0] c = native_data[p*24 +: 24];
        // Little-endian byte order: RGB = R,G,B,X; YUV = Y,U,V,X.
        assign dma_data[p*32 +: 32] = rgb_mode ?
            {8'hff, c[15:8], c[7:0], c[23:16]} : {8'h00, c};
    end endgenerate
endmodule
