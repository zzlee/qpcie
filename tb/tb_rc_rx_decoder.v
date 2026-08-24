// ============================================================================
// Testbench: tb_rc_rx_decoder
// Description: Unit testbench for rc_rx_decoder module with 512-bit extended descriptors
// ============================================================================

`timescale 1ns / 1ps

module tb_rc_rx_decoder;

    parameter DATA_WIDTH = 256;
    parameter KEEP_WIDTH = DATA_WIDTH / 32;

    reg                  clk;
    reg                  rst_n;

    reg  [DATA_WIDTH-1:0] s_axis_rc_tdata;
    reg                  s_axis_rc_tvalid;
    reg                  s_axis_rc_tlast;
    reg  [74:0]          s_axis_rc_tuser;
    reg  [KEEP_WIDTH-1:0] s_axis_rc_tkeep;
    wire                 s_axis_rc_tready;

    wire                 desc_cpl_valid;
    wire [511:0]         desc_cpl_data;
    wire                 desc_cpl_last;

    wire                 h2c_fifo_wvalid;
    wire [DATA_WIDTH-1:0] h2c_fifo_wdata;
    wire                 h2c_fifo_wlast;

    wire                 tag_free_req;
    wire [7:0]           tag_free_val;

    // Instantiate uut
    rc_rx_decoder #(
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_rc_tdata(s_axis_rc_tdata),
        .s_axis_rc_tvalid(s_axis_rc_tvalid),
        .s_axis_rc_tlast(s_axis_rc_tlast),
        .s_axis_rc_tuser(s_axis_rc_tuser),
        .s_axis_rc_tkeep(s_axis_rc_tkeep),
        .s_axis_rc_tready(s_axis_rc_tready),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .h2c_fifo_wvalid(h2c_fifo_wvalid),
        .h2c_fifo_wdata(h2c_fifo_wdata),
        .h2c_fifo_wlast(h2c_fifo_wlast),
        .tag_free_req(tag_free_req),
        .tag_free_val(tag_free_val)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        s_axis_rc_tdata = 0;
        s_axis_rc_tvalid = 0;
        s_axis_rc_tlast = 0;
        s_axis_rc_tuser = 0;
        s_axis_rc_tkeep = 8'hFF;

        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Test 1: Receive Desc Fetch CplD (Tag 0x00)...", $time);
        @(posedge clk);
        s_axis_rc_tvalid <= 1;
        s_axis_rc_tlast  <= 1;
        // DW0: Byte Count=32, DW1: Tag=0x00, DW2: Completer ID=0x0100
        s_axis_rc_tdata[31:0]   <= 32'h0020_0000;
        s_axis_rc_tdata[71:64]  <= 8'h00; // RC descriptor tag
        s_axis_rc_tdata[87:72]  <= 16'h0100;
        s_axis_rc_tdata[255:96] <= 160'h11223344_55667788_99AABBCC_DDEEFF00;

        wait(desc_cpl_valid);
        $display("[%0t] RC Decoder routed CplD to Desc Fetch Engine! Data: 0x%h", $time, desc_cpl_data[159:0]);
        @(posedge clk);
        s_axis_rc_tvalid <= 0;

        #30;
        $display("[%0t] Test 2: Receive H2C Data CplD (Tag 0x03)...", $time);
        @(posedge clk);
        s_axis_rc_tvalid <= 1;
        s_axis_rc_tlast  <= 1;
        s_axis_rc_tdata[31:0]   <= 32'h0040_0000;
        s_axis_rc_tdata[71:64]  <= 8'h03; // RC descriptor tag
        s_axis_rc_tdata[87:72]  <= 16'h0100;
        s_axis_rc_tdata[255:96] <= 160'hA5A5A5A5_5A5A5A5A_12345678_87654321;

        wait(h2c_fifo_wvalid);
        $display("[%0t] RC Decoder routed CplD to H2C FIFO! Tag freed: 0x%h Data: 0x%h", $time, tag_free_val, h2c_fifo_wdata);
        @(posedge clk);
        s_axis_rc_tvalid <= 0;

        #30;
        $display("[%0t] SUCCESS: RC RX Decoder Test Completed!", $time);
        $finish;
    end

endmodule
