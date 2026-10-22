`timescale 1ns/1ps
module sc7f0_hdmi_pack_tb;
    reg [95:0] native_data;
    reg rgb;
    wire [127:0] packed_data;
    hdmi_rx_pixel_pack dut(.native_data(native_data), .rgb_mode(rgb), .dma_data(packed_data));
    initial begin
        // Low native pixel is R=12, B=56, G=34. Little-endian host is 12 34 56.
        rgb=1;
        native_data={24'habefcd,24'h789a89,24'h456756,24'h125634}; #1;
        if (packed_data !== {32'hffefcdab,32'hff9a8978,32'hff675645,32'hff563412})
            $fatal(1,"RGB component or PPC order wrong: %h",packed_data);
        rgb=0;
        native_data={24'habcdef,24'h789abc,24'h456789,24'h123456}; #1;
        if (packed_data !== {32'hffabcdef,32'hff789abc,32'hff456789,32'hff123456})
            $fatal(1,"YUV444 component or PPC order wrong: %h",packed_data);
        $display("TB_PASS: HDMI RBG to host RGB; VUY to converter YUV; all four pixels");
        $finish;
    end
endmodule
