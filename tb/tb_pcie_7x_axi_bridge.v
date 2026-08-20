// ============================================================================
// Testbench: tb_pcie_7x_axi_bridge
// Description: Comprehensive Edge-Case Verification Testbench for pcie_7x_axi_bridge
// Coverage:
//   1. Host MRd32 (3-DW 32-bit Memory Read -> CQ Descriptor)
//   2. Host MRd64 (4-DW 64-bit Memory Read -> CQ Descriptor & BAR1 Demux)
//   3. BAR Register Read Response (CC Descriptor -> 7-Series CplD TLP)
//   4. DMA Memory Read Request (RQ Descriptor -> 7-Series 3-DW MRd TLP)
//   5. RX Backpressure Stall (m_axis_cq_tready = 0)
//   6. Concurrent TX CC vs RQ Arbitration Priority Test
// ============================================================================

`timescale 1ns / 1ps

module tb_pcie_7x_axi_bridge;

    parameter DATA_WIDTH = 128;
    parameter KEEP_WIDTH = DATA_WIDTH / 8;

    // Clock & Reset
    reg clk;
    reg rst_n;

    // Dynamic BDF Inputs
    reg [7:0] cfg_bus_number;
    reg [4:0] cfg_device_number;
    reg [2:0] cfg_function_number;

    // 7-Series PCIe RX Interface (Input to Bridge)
    reg  [DATA_WIDTH-1:0] m_axis_rx_tdata;
    reg  [KEEP_WIDTH-1:0] m_axis_rx_tkeep;
    reg                   m_axis_rx_tlast;
    reg                   m_axis_rx_tvalid;
    wire                  m_axis_rx_tready;
    reg  [21:0]           m_axis_rx_tuser;

    // 7-Series PCIe TX Interface (Output from Bridge)
    wire [DATA_WIDTH-1:0] s_axis_tx_tdata;
    wire [KEEP_WIDTH-1:0] s_axis_tx_tkeep;
    wire                  s_axis_tx_tlast;
    wire                  s_axis_tx_tvalid;
    reg                   s_axis_tx_tready;
    wire [3:0]            s_axis_tx_tuser;

    // CQ Interface (Output from Bridge)
    wire [DATA_WIDTH-1:0] m_axis_cq_tdata;
    wire                  m_axis_cq_tvalid;
    wire                  m_axis_cq_tlast;
    wire [87:0]           m_axis_cq_tuser;
    wire [KEEP_WIDTH-1:0] m_axis_cq_tkeep;
    reg                   m_axis_cq_tready;

    // CC Interface (Input to Bridge)
    reg  [DATA_WIDTH-1:0] s_axis_cc_tdata;
    reg                   s_axis_cc_tvalid;
    reg                   s_axis_cc_tlast;
    reg  [32:0]           s_axis_cc_tuser;
    reg  [KEEP_WIDTH-1:0] s_axis_cc_tkeep;
    wire                  s_axis_cc_tready;

    // RQ Interface (Input to Bridge)
    reg  [DATA_WIDTH-1:0] s_axis_rq_tdata;
    reg                   s_axis_rq_tvalid;
    reg                   s_axis_rq_tlast;
    reg  [61:0]           s_axis_rq_tuser;
    reg  [KEEP_WIDTH-1:0] s_axis_rq_tkeep;
    wire                  s_axis_rq_tready;

    // RC Interface (Output from Bridge)
    wire [DATA_WIDTH-1:0] m_axis_rc_tdata;
    wire                  m_axis_rc_tvalid;
    wire                  m_axis_rc_tlast;
    wire [74:0]           m_axis_rc_tuser;
    wire [KEEP_WIDTH-1:0] m_axis_rc_tkeep;
    reg                   m_axis_rc_tready;

    // Instantiate Unit Under Test (UUT)
    pcie_7x_axi_bridge #(
        .DATA_WIDTH(128)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),

        .cfg_bus_number(cfg_bus_number),
        .cfg_device_number(cfg_device_number),
        .cfg_function_number(cfg_function_number),

        .m_axis_rx_tdata(m_axis_rx_tdata),
        .m_axis_rx_tkeep(m_axis_rx_tkeep),
        .m_axis_rx_tlast(m_axis_rx_tlast),
        .m_axis_rx_tvalid(m_axis_rx_tvalid),
        .m_axis_rx_tready(m_axis_rx_tready),
        .m_axis_rx_tuser(m_axis_rx_tuser),

        .s_axis_tx_tdata(s_axis_tx_tdata),
        .s_axis_tx_tkeep(s_axis_tx_tkeep),
        .s_axis_tx_tlast(s_axis_tx_tlast),
        .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .s_axis_tx_tready(s_axis_tx_tready),
        .s_axis_tx_tuser(s_axis_tx_tuser),

        .m_axis_cq_tdata(m_axis_cq_tdata),
        .m_axis_cq_tvalid(m_axis_cq_tvalid),
        .m_axis_cq_tlast(m_axis_cq_tlast),
        .m_axis_cq_tuser(m_axis_cq_tuser),
        .m_axis_cq_tkeep(m_axis_cq_tkeep),
        .m_axis_cq_tready(m_axis_cq_tready),

        .s_axis_cc_tdata(s_axis_cc_tdata),
        .s_axis_cc_tvalid(s_axis_cc_tvalid),
        .s_axis_cc_tlast(s_axis_cc_tlast),
        .s_axis_cc_tuser(s_axis_cc_tuser),
        .s_axis_cc_tkeep(s_axis_cc_tkeep),
        .s_axis_cc_tready(s_axis_cc_tready),

        .s_axis_rq_tdata(s_axis_rq_tdata),
        .s_axis_rq_tvalid(s_axis_rq_tvalid),
        .s_axis_rq_tlast(s_axis_rq_tlast),
        .s_axis_rq_tuser(s_axis_rq_tuser),
        .s_axis_rq_tkeep(s_axis_rq_tkeep),
        .s_axis_rq_tready(s_axis_rq_tready),

        .m_axis_rc_tdata(m_axis_rc_tdata),
        .m_axis_rc_tvalid(m_axis_rc_tvalid),
        .m_axis_rc_tlast(m_axis_rc_tlast),
        .m_axis_rc_tuser(m_axis_rc_tuser),
        .m_axis_rc_tkeep(m_axis_rc_tkeep),
        .m_axis_rc_tready(m_axis_rc_tready)
    );

    // Clock Generation (125 MHz = 8ns period)
    always #4 clk = ~clk;

    integer pass_cnt;
    integer fail_cnt;

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;

        clk = 0;
        rst_n = 0;
        cfg_bus_number = 8'h04;
        cfg_device_number = 5'h01;
        cfg_function_number = 3'h0;

        m_axis_rx_tdata = 128'd0;
        m_axis_rx_tkeep = 16'd0;
        m_axis_rx_tlast = 0;
        m_axis_rx_tvalid = 0;
        m_axis_rx_tuser = 22'd0;

        s_axis_tx_tready = 1;
        m_axis_cq_tready = 1;
        s_axis_cc_tdata = 128'd0;
        s_axis_cc_tvalid = 0;
        s_axis_cc_tlast = 0;
        s_axis_cc_tuser = 33'd0;
        s_axis_cc_tkeep = 16'd0;

        s_axis_rq_tdata = 128'd0;
        s_axis_rq_tvalid = 0;
        s_axis_rq_tlast = 0;
        s_axis_rq_tuser = 62'd0;
        s_axis_rq_tkeep = 16'd0;

        m_axis_rc_tready = 1;

        #20;
        rst_n = 1;
        #20;

        $display("=================================================================");
        $display(" Starting Edge-Case Verification for pcie_7x_axi_bridge");
        $display("=================================================================");

        // ---------------------------------------------------------------------
        // TEST 1: Host MRd32 (3-DW Memory Read -> CQ Descriptor)
        // ---------------------------------------------------------------------
        $display("[TEST 1] Testing 7-Series RX 3-DW MRd32 -> UltraScale CQ Descriptor...");
        @(posedge clk);
        m_axis_rx_tvalid = 1;
        m_axis_rx_tlast  = 1;
        m_axis_rx_tkeep  = 16'h0FFF;
        // 7-Series 3-DW MRd: DW0={Fmt=00, Type=00000, Len=1}, DW1={ReqID=1234, Tag=55, BE=FF}, DW2={Addr=0x00000004}
        m_axis_rx_tdata  = {32'h00000000, 32'h00000004, 32'h123455FF, 32'h00000001};

        #2;
        if (m_axis_cq_tvalid && m_axis_cq_tdata[63:0] == 64'h00000004 && m_axis_cq_tdata[103:96] == 8'h55 && m_axis_cq_tdata[114:112] == 3'b000) begin
            $display("  -> TEST 1 PASSED: CQ Address=0x04, BAR0 (000), Tag=0x55 successfully translated!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  -> TEST 1 FAILED: Invalid CQ translation! Data=0x%h", m_axis_cq_tdata);
            fail_cnt = fail_cnt + 1;
        end

        @(posedge clk);
        m_axis_rx_tvalid = 0;
        m_axis_rx_tlast  = 0;

        #20;

        // ---------------------------------------------------------------------
        // TEST 2: Host MRd64 (4-DW Memory Read -> BAR1 Demux)
        // ---------------------------------------------------------------------
        $display("[TEST 2] Testing 7-Series RX 4-DW MRd64 -> UltraScale CQ Descriptor (BAR1)...");
        @(posedge clk);
        m_axis_rx_tvalid = 1;
        m_axis_rx_tlast  = 1;
        m_axis_rx_tkeep  = 16'hFFFF;
        // 7-Series 4-DW MRd: DW0={Fmt=01, Type=00000, Len=1}, DW1={ReqID=1234, Tag=AA, BE=FF}, DW2={AddrHi=0x00000001}, DW3={AddrLo=0x40000000}
        m_axis_rx_tdata  = {32'h40000000, 32'h00000001, 32'h1234AAFF, 32'h20000001};

        #2;
        if (m_axis_cq_tvalid && m_axis_cq_tdata[63:0] == 64'h0000000140000000 && m_axis_cq_tdata[114:112] == 3'b001) begin
            $display("  -> TEST 2 PASSED: 64-bit Address 0x1_40000000 & BAR1 (001) demux verified!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  -> TEST 2 FAILED: BAR1 demux error! CQ Data=0x%h, BAR_ID=%b", m_axis_cq_tdata, m_axis_cq_tdata[114:112]);
            fail_cnt = fail_cnt + 1;
        end

        @(posedge clk);
        m_axis_rx_tvalid = 0;
        m_axis_rx_tlast  = 0;

        #20;

        // ---------------------------------------------------------------------
        // TEST 3: BAR Register Read Response (CC Descriptor -> 7-Series CplD TLP)
        // ---------------------------------------------------------------------
        $display("[TEST 3] Testing UltraScale CC Descriptor -> 7-Series CplD TLP Response...");
        @(posedge clk);
        s_axis_cc_tvalid = 1;
        s_axis_cc_tlast  = 1;
        s_axis_cc_tkeep  = 16'hFFFF;
        // CC Descriptor matching cc_tx_encoder.v layout (128-bit exact concatenation):
        s_axis_cc_tdata  = {
            32'hDEADBEEF,  // [127:96] Data
            16'h0100,      // [95:80] Completer ID
            16'h0400,      // [79:64] Requester ID
            5'b0,          // [63:59] Reserved
            8'h55,         // [58:51] Tag
            4'b0,          // [50:47] Reserved
            3'b000,        // [46:44] Completion Status
            1'b0,          // [43] Reserved
            11'd1,         // [42:32] Dword Count (1 DW)
            3'b0,          // [31:29] Reserved
            13'd4,         // [28:16] Byte Count (4 Bytes)
            4'b0,          // [15:12] Reserved
            3'b000,        // [11:9] Error Code
            2'b0,          // [8:7] Reserved
            7'h04          // [6:0] Lower Address
        };

        #2;
        if (s_axis_tx_tvalid && s_axis_tx_tdata[127:96] == 32'hDEADBEEF && s_axis_tx_tdata[31:0] == 32'h4A000001 && s_axis_tx_tdata[63:32] == 32'h01000004 && s_axis_tx_tdata[95:64] == 32'h04005504) begin
            $display("  -> TEST 3 PASSED: 7-Series CplD Header (0x4A000001, Len=1 DW, ReqID=0x0400, Tag=0x55) & Data (0xDEADBEEF) verified!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  -> TEST 3 FAILED: CplD formatting error! TX Data=0x%h, DW0=0x%h, DW1=0x%h, DW2=0x%h", s_axis_tx_tdata, s_axis_tx_tdata[31:0], s_axis_tx_tdata[63:32], s_axis_tx_tdata[95:64]);
            fail_cnt = fail_cnt + 1;
        end

        @(posedge clk);
        s_axis_cc_tvalid = 0;
        s_axis_cc_tlast  = 0;

        #20;

        // ---------------------------------------------------------------------
        // TEST 4: DMA Memory Read Request (RQ -> 7-Series 3-DW MRd32 TLP)
        // ---------------------------------------------------------------------
        $display("[TEST 4] Testing UltraScale RQ Descriptor -> 7-Series 3-DW MRd32 TLP...");
        @(posedge clk);
        s_axis_rq_tvalid = 1;
        s_axis_rq_tlast  = 1;
        s_axis_rq_tkeep  = 16'h0FFF;
        s_axis_rq_tdata  = {32'h00000000, 32'h10040110, 32'h00000000, 32'h80000000};

        #2;
        if (s_axis_tx_tvalid && s_axis_tx_tdata[95:64] == 32'h80000000 && (s_axis_tx_tdata[31:24] == 8'b00000000)) begin
            $display("  -> TEST 4 PASSED: DMA MRd32 TLP Header generated cleanly!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  -> TEST 4 FAILED: RQ to 7-Series MRd error! TX Data=0x%h", s_axis_tx_tdata);
            fail_cnt = fail_cnt + 1;
        end

        @(posedge clk);
        s_axis_rq_tvalid = 0;
        s_axis_rq_tlast  = 0;

        #20;

        // ---------------------------------------------------------------------
        // TEST 5: Backpressure Stall Test (m_axis_cq_tready = 0)
        // ---------------------------------------------------------------------
        $display("[TEST 5] Testing RX Backpressure Stall (m_axis_cq_tready = 0)...");
        m_axis_cq_tready = 0;
        @(posedge clk);
        m_axis_rx_tvalid = 1;
        m_axis_rx_tlast  = 1;
        m_axis_rx_tkeep  = 16'h0FFF;
        m_axis_rx_tdata  = {32'h00000000, 32'h00000010, 32'h1234AAFF, 32'h00000001};

        #2;
        if (m_axis_cq_tvalid && !m_axis_rx_tready) begin
            $display("  -> TEST 5 PASSED: Bridge correctly backpressured RX when CQ was not ready.");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  -> TEST 5 FAILED: Backpressure handling error.");
            fail_cnt = fail_cnt + 1;
        end

        m_axis_cq_tready = 1;
        @(posedge clk);
        m_axis_rx_tvalid = 0;

        #20;

        // ---------------------------------------------------------------------
        // TEST 6: Concurrent TX CC vs RQ Arbitration Priority Test
        // ---------------------------------------------------------------------
        $display("[TEST 6] Testing Concurrent TX Arbitration (CC Priority over RQ)...");
        @(posedge clk);
        s_axis_cc_tvalid = 1;
        s_axis_cc_tdata  = {
            32'h11223344,  // [127:96] Data
            16'h0100,      // [95:80] Completer ID
            16'h0400,      // [79:64] Requester ID
            5'b0,          // [63:59] Reserved
            8'h55,         // [58:51] Tag
            4'b0,          // [50:47] Reserved
            3'b000,        // [46:44] Completion Status
            1'b0,          // [43] Reserved
            11'd1,         // [42:32] Dword Count (1 DW)
            3'b0,          // [31:29] Reserved
            13'd4,         // [28:16] Byte Count (4 Bytes)
            4'b0,          // [15:12] Reserved
            3'b000,        // [11:9] Error Code
            2'b0,          // [8:7] Reserved
            7'h04          // [6:0] Lower Address
        };

        s_axis_rq_tvalid = 1;
        s_axis_rq_tdata  = {32'h00000000, 32'h10040110, 32'h00000000, 32'h90000000};

        #2;
        if (s_axis_tx_tvalid && s_axis_tx_tdata[127:96] == 32'h11223344 && s_axis_cc_tready && !s_axis_rq_tready) begin
            $display("  -> TEST 6 PASSED: CC read response granted priority over RQ DMA request!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  -> TEST 6 FAILED: Priority arbitration error!");
            fail_cnt = fail_cnt + 1;
        end

        @(posedge clk);
        s_axis_cc_tvalid = 0;

        #2;
        if (s_axis_tx_tvalid && s_axis_rq_tready) begin
            $display("  -> TEST 6 (Part B) PASSED: RQ DMA request granted immediately after CC completed.");
        end

        @(posedge clk);
        s_axis_rq_tvalid = 0;

        #20;

        // Summary
        $display("=================================================================");
        $display(" Verification Summary: %0d Passed, %0d Failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display(" 🎉 ALL BRIDGE EDGE-CASE VERIFICATION TESTS PASSED!");
        else
            $display(" ❌ VERIFICATION FAILED!");
        $display("=================================================================");

        $finish;
    end

endmodule
