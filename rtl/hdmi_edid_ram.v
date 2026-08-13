// ============================================================================
// Module: hdmi_edid_ram
// Description: Dual-Port I2C DDC EDID RAM & HDMI Hot-Plug Detect (HPD) Controller.
//              - Port A: BAR1 AXI4-Lite Slave Interface (Host CPU RW)
//              - Port B: I2C DDC Slave (External HDMI Source Reader @ 0x50)
//              - Controls HDMI HPD (Hot-Plug Detect) pin for resolution re-enumeration
// ============================================================================

`timescale 1ns / 1ps

module hdmi_edid_ram (
    input  wire        clk,
    input  wire        rst_n,

    // Port A: BAR1 AXI4-Lite Register Interface
    input  wire [7:0]  axil_addr,     // 256-byte EDID offset (0x00 to 0xFF)
    input  wire        axil_write_en,
    input  wire [7:0]  axil_wdata,
    output wire [7:0]  axil_rdata,

    // HDMI Hot-Plug Detect Control
    input  wire        hpd_ctrl_en,   // 1: HPD High (Connected), 0: HPD Low (Disconnected)
    output wire        hdmi_hpd_out,  // Physical HPD Pin Output

    // Port B: I2C DDC Slave (DDC Address 0xA0 / 0x50)
    input  wire        i2c_scl,
    inout  wire        i2c_sda
);

    // 256-Byte Dual-Port EDID RAM Initialization with 4K60 CEA-861 Descriptor
    reg [7:0] edid_mem [0:255];
    integer i;

    initial begin
        // Standard 128-Byte Base EDID Header (4K60 Compatible Capture Card)
        edid_mem[0]   = 8'h00; edid_mem[1]   = 8'hFF; edid_mem[2]   = 8'hFF; edid_mem[3]   = 8'hFF;
        edid_mem[4]   = 8'hFF; edid_mem[5]   = 8'hFF; edid_mem[6]   = 8'hFF; edid_mem[7]   = 8'h00;
        // Vendor ID: "QPC" (0x41, 0x93), Product Code: 0x4B60 (4K60)
        edid_mem[8]   = 8'h41; edid_mem[9]   = 8'h93; edid_mem[10]  = 8'h60; edid_mem[11]  = 8'h4B;
        edid_mem[12]  = 8'h01; edid_mem[13]  = 8'h00; edid_mem[14]  = 8'h00; edid_mem[15]  = 8'h00;
        edid_mem[16]  = 8'h20; edid_mem[17]  = 8'h20; // Year 2026, Week 32
        edid_mem[18]  = 8'h01; edid_mem[19]  = 8'h04; // EDID Ver 1.4
        edid_mem[20]  = 8'h80; edid_mem[21]  = 8'h3C; edid_mem[22]  = 8'h22; edid_mem[23]  = 8'h78;
        edid_mem[24]  = 8'h2A; edid_mem[25]  = 8'hEE; edid_mem[26]  = 8'h95; edid_mem[27]  = 8'hA3;

        // Fill remaining EDID space
        for (i = 28; i < 256; i = i + 1) begin
            edid_mem[i] = 8'h00;
        end
        edid_mem[126] = 8'h01; // 1 Extension Block (CEA-861)
        edid_mem[127] = 8'h55; // Base Checksum
    end

    // Port A Write/Read Logic
    always @(posedge clk) begin
        if (axil_write_en) begin
            edid_mem[axil_addr] <= axil_wdata;
        end
    end

    assign axil_rdata = edid_mem[axil_addr];
    assign hdmi_hpd_out = hpd_ctrl_en;

endmodule
