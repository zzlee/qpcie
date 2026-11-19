// ============================================================================
// Module: zu4ev_pcie_card_top
// Target: AMD/Xilinx Zynq UltraScale+ (xczu4ev-fbvb900-2-e)
// Board:  SC7F0 N1 HDMI2 V11
// Description: Top-level FPGA card wrapper module for ZU4EV.
//              Integrates:
//              - Xilinx UltraScale+ PCIe Core (pcie4_uscale_plus_0) Gen3 x4, 256-bit
//              - Custom PCIe DMA Top Controller (BAR0: DMA Regs, BAR1: AXI Master)
//              - AXI4-Lite 1x3 Interconnect Module (axi_crossbar_0)
//              - Xilinx Video Test Pattern Generator IP (v_tpg_0) at BAR1 Offset 0x0000
//              - AES3 Audio Pattern Generator Module (audio_pattern_gen) at BAR1 Offset 0x1000
//              - Dynamic EDID RAM + HPD Controller (hdmi_edid_ram) at BAR1 Offset 0x2000
//              - Direct Video Streaming: TPG m_axis_video -> DMA s_axis_video (Ch0)
//              - Direct Audio Streaming: AudPatGen m_axis_audio -> DMA s_axis_audio (Ch0)
// ============================================================================

`timescale 1ns / 1ps

module zu4ev_pcie_card_top #(
    parameter [31:0] C_VERSION = 32'h2610_2901,
    parameter PCIE_DATA_WIDTH  = 256,
    parameter PCIE_KEEP_WIDTH  = PCIE_DATA_WIDTH / 32, // 8 DW keep for 256-bit
    parameter NUM_VIDEO_CH     = 4,
    parameter NUM_AUDIO_CH     = 4,
    parameter VIDEO_DATA_WIDTH = 128,
    parameter AUDIO_DATA_WIDTH = 32
)(
    // Physical PCIe Reference Clock & PERST# Reset Pins (Bank 223 / Bank 46)
    input  wire                                             sys_clk_p,
    input  wire                                             sys_clk_n,
    input  wire                                             sys_rst_n,

    // Physical PCIe Transceiver Serial Lanes (Gen3 x4, Quad 223)
    output wire [3:0]                                       pci_exp_txp,
    output wire [3:0]                                       pci_exp_txn,
    input  wire [3:0]                                       pci_exp_rxp,
    input  wire [3:0]                                       pci_exp_rxn,

    // Status LEDs (Bank 45)
    output wire                                             user_led_dma_active,
    output wire                                             user_led_pcie_link_up
`ifndef SC7F0_DEBUG_ONLY
    ,
    // Physical HDMI Reference Clocks (Bank 225/226 MGT)
    input  wire                                             hdmi_rx_clk_p,        // Pin B10 (Bank 226 MGTREFCLK1)
    input  wire                                             hdmi_rx_clk_n,        // Pin B9
    input  wire                                             hdmi_dru_clk_p,       // Pin F10 (Bank 225 MGTREFCLK1)
    input  wire                                             hdmi_dru_clk_n,       // Pin F9
    input  wire                                             hdmi_tx_clk_p,        // Pin D10 (Bank 226 MGTREFCLK0)
    input  wire                                             hdmi_tx_clk_n,        // Pin D9

    // Physical HDMI Transceiver Serial Data Lanes (Bank 226 Quad 226)
    input  wire [2:0]                                       hdmi_rx_p,            // GTHE4_CHANNEL_X0Y12..14 RX
    input  wire [2:0]                                       hdmi_rx_n,
    output wire [2:0]                                       hdmi_tx_p,            // GTHE4_CHANNEL_X0Y12..14 TX
    output wire [2:0]                                       hdmi_tx_n,
    output wire                                             hdmi_tx_tmds_clk_p,   // Pin AH6 (ODDR TMDS Clk Out)
    output wire                                             hdmi_tx_tmds_clk_n,   // Pin AJ6
    output wire                                             hdmi_rx_recko_p,      // Pin AG6 (RX Recovered Clk -> Si5319 CKIN1)
    output wire                                             hdmi_rx_recko_n,      // Pin AG5

    // Physical HDMI RX Interface Pins (Bank 46 HDIO 3.3V)
    input  wire                                             hdmi_rx_5v_det,       // Pin A12 (Cable 5V Detect)
    output wire                                             hdmi_rx_hpd_out,      // Pin B12 (HPD Assert to Source)
    inout  wire                                             hdmi_rx_ddc_scl,      // Pin D14 (DDC I2C SCL)
    inout  wire                                             hdmi_rx_ddc_sda,      // Pin C13 (DDC I2C SDA)

    // Physical HDMI TX Interface Pins (Bank 46 HDIO 3.3V)
    input  wire                                             hdmi_tx_hpd_in,       // Pin G14 (Sink HPD Input)
    input  wire                                             hdmi_tx_refclk_rdy,   // G13: X0_5319_LOL (active HIGH=not ready; PHY inverts)
    inout  wire                                             hdmi_tx_ddc_scl,      // Pin F12 (Sink DDC SCL)
    inout  wire                                             hdmi_tx_ddc_sda,      // Pin E12 (Sink DDC SDA)
    
    // 300MHz Si5341B Clock for Multimedia IPs (Bank 64 LVDS)
    input  wire                                             pl_clk_300m_p,        // Pin AD17
    input  wire                                             pl_clk_300m_n         // Pin AE17
`endif
);

    // =========================================================================
    // Internal Clocks and Resets
    // =========================================================================
    wire pcie_user_clk;
    wire pcie_user_reset;
    wire pcie_user_lnk_up;
    wire phy_ready;

    wire pcie_user_rst_n;
    assign pcie_user_rst_n       = pcie_user_lnk_up && ~pcie_user_reset;
    assign user_led_pcie_link_up = pcie_user_lnk_up;

    // 100MHz PS Clock Domain
    wire pl_clk0;
    wire pl_resetn0;
    wire sys_100m_rst_n;
    proc_sys_reset_0 u_100m_reset (
        .slowest_sync_clk(pl_clk0),
        // NOTE: pl_resetn0 is ACTIVE-LOW, ext_reset_in is ACTIVE-HIGH.
        // Direct connection held the whole 100MHz domain in reset forever
        // (silent slaves -> any PS/PCIe BAR0 read wedged the NoC, RCU stalls).
        .ext_reset_in(~pl_resetn0),
        // proc_sys_reset_0 has C_AUX_RESET_HIGH=1: tie LOW when unused.
        // Tying this input HIGH held the entire 100 MHz domain in reset.
        .aux_reset_in(1'b0),
        .mb_debug_sys_rst(1'b0),
        .dcm_locked(1'b1),
        .mb_reset(),
        .bus_struct_reset(),
        .peripheral_reset(),
        .interconnect_aresetn(),
        .peripheral_aresetn(sys_100m_rst_n)
    );

`ifndef SC7F0_DEBUG_ONLY
    // Full-profile05: PS HPM1 -> AXI4/Lite converter (BD) -> HDMI registers.
    // M00 PHY @ B0000000; M01 RX @ B0010000; M02 TX @ B0020000.
    // Control clock/reset are independent of the PCIe link and video clocks.
    wire [31:0] hdmi_ps_awaddr, hdmi_ps_araddr;
    wire [31:0] hdmi_ps_wdata, hdmi_ps_rdata;
    wire [3:0] hdmi_ps_wstrb;
    wire hdmi_ps_awvalid, hdmi_ps_awready, hdmi_ps_wvalid, hdmi_ps_wready;
    wire hdmi_ps_bvalid, hdmi_ps_bready, hdmi_ps_arvalid, hdmi_ps_arready;
    wire hdmi_ps_rvalid, hdmi_ps_rready;
    wire [1:0] hdmi_ps_bresp, hdmi_ps_rresp;
    // Eight AXI-Lite master slices, one 32-bit slice per axi_crossbar_hdmi port:
    // M00 PHY, M01 RX SS, M02 TX SS, M03 dualpath, M04..M06 capture branch, and
    // M07 = 0xB0080000 display/sc7f0_frmbuf_rd CSR (only consumed when
    // SC7F0_DISPLAY_TX is defined; the slice stays unconnected otherwise, exactly
    // as before this personality existed).
`ifdef SC7F0_RGB_COMPOSITOR
    // Eleven 32-bit slices: M00..M09 plus M10 = 0xB0030000, the upper half of the
    // HDMI TX subsystem aperture (its VTC lives at tx_ss+0x10000).  u_hdmi_tx_ctl_merge
    // below re-merges the two TX halves in fabric and is what actually drives
    // subsystem address bit 16; see the comment there and
    // scripts/create_sc7f0_hdmi_crossbar.tcl.
    wire [351:0] hdmi_ctl_awaddr, hdmi_ctl_araddr, hdmi_ctl_wdata, hdmi_ctl_rdata;
    wire [43:0] hdmi_ctl_wstrb;
    wire [10:0] hdmi_ctl_awvalid, hdmi_ctl_awready, hdmi_ctl_wvalid, hdmi_ctl_wready;
    wire [10:0] hdmi_ctl_bvalid, hdmi_ctl_bready, hdmi_ctl_arvalid, hdmi_ctl_arready;
    wire [10:0] hdmi_ctl_rvalid, hdmi_ctl_rready;
    wire [21:0] hdmi_ctl_bresp, hdmi_ctl_rresp;
`else
    wire [255:0] hdmi_ctl_awaddr, hdmi_ctl_araddr, hdmi_ctl_wdata, hdmi_ctl_rdata;
    wire [31:0] hdmi_ctl_wstrb;
    wire [7:0] hdmi_ctl_awvalid, hdmi_ctl_awready, hdmi_ctl_wvalid, hdmi_ctl_wready;
    wire [7:0] hdmi_ctl_bvalid, hdmi_ctl_bready, hdmi_ctl_arvalid, hdmi_ctl_arready;
    wire [7:0] hdmi_ctl_rvalid, hdmi_ctl_rready;
    wire [15:0] hdmi_ctl_bresp, hdmi_ctl_rresp;
`endif
    // as before this personality existed).  SC7F0_RGB_COMPOSITOR widens the
    // vector to ten 32-bit slices because that personality adds
    // M08 = 0xB0090000 (compositor Reader-B v_frmbuf_rd CSR) and
    // M09 = 0xB00A0000 (overlay ingress / overlay writer CSR).
    axi_crossbar_hdmi u_hdmi_control (
        .aclk(pl_clk0), .aresetn(sys_100m_rst_n),
        .s_axi_awaddr(hdmi_ps_awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(hdmi_ps_awvalid), .s_axi_awready(hdmi_ps_awready),
        .s_axi_wdata(hdmi_ps_wdata), .s_axi_wstrb(hdmi_ps_wstrb),
        .s_axi_wvalid(hdmi_ps_wvalid), .s_axi_wready(hdmi_ps_wready),
        .s_axi_bresp(hdmi_ps_bresp), .s_axi_bvalid(hdmi_ps_bvalid), .s_axi_bready(hdmi_ps_bready),
        .s_axi_araddr(hdmi_ps_araddr), .s_axi_arprot(3'b000),
        .s_axi_arvalid(hdmi_ps_arvalid), .s_axi_arready(hdmi_ps_arready),
        .s_axi_rdata(hdmi_ps_rdata), .s_axi_rresp(hdmi_ps_rresp),
        .s_axi_rvalid(hdmi_ps_rvalid), .s_axi_rready(hdmi_ps_rready),
        .m_axi_awaddr(hdmi_ctl_awaddr), .m_axi_awprot(),
        .m_axi_awvalid(hdmi_ctl_awvalid), .m_axi_awready(hdmi_ctl_awready),
        .m_axi_wdata(hdmi_ctl_wdata), .m_axi_wstrb(hdmi_ctl_wstrb),
        .m_axi_wvalid(hdmi_ctl_wvalid), .m_axi_wready(hdmi_ctl_wready),
        .m_axi_bresp(hdmi_ctl_bresp), .m_axi_bvalid(hdmi_ctl_bvalid), .m_axi_bready(hdmi_ctl_bready),
        .m_axi_araddr(hdmi_ctl_araddr), .m_axi_arprot(),
        .m_axi_arvalid(hdmi_ctl_arvalid), .m_axi_arready(hdmi_ctl_arready),
        .m_axi_rdata(hdmi_ctl_rdata), .m_axi_rresp(hdmi_ctl_rresp),
        .m_axi_rvalid(hdmi_ctl_rvalid), .m_axi_rready(hdmi_ctl_rready)
    );

    // Si5341 OUT8: 300 MHz. Divide locally for a 150 MHz capture domain.
    wire pl_clk_300m_ibufg;
    wire pl_clk_300m;
    wire sys_300m_rst_n;
    
    IBUFDS #(
        .DIFF_TERM("FALSE"),
        .IOSTANDARD("LVDS")
    ) u_ibufds_300m (
        .I(pl_clk_300m_p),
        .IB(pl_clk_300m_n),
        .O(pl_clk_300m_ibufg)
    );

    BUFGCE u_bufgce_300m (
        .I(pl_clk_300m_ibufg),
        .CE(1'b1),
        .O(pl_clk_300m)
    );

    proc_sys_reset_0 u_300m_reset (
        .slowest_sync_clk(pl_clk_300m),
        // Keep the capture/memory clock alive across host PCIe resets.
        .ext_reset_in(~pl_resetn0),
        .aux_reset_in(1'b0),
        .mb_debug_sys_rst(1'b0),
        .dcm_locked(1'b1),
        .mb_reset(),
        .bus_struct_reset(),
        .peripheral_reset(),
        .interconnect_aresetn(),
        .peripheral_aresetn(sys_300m_rst_n)
    );


`endif
    // Fine-grained sub-domain resets (BAR0 0x84)
    wire video_pipeline_reset;
    wire video_tpg_reset;
    wire video_engine_reset;
    (* ASYNC_REG = "TRUE" *) reg [1:0] video_pipeline_reset_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] video_tpg_reset_sync      = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] video_engine_reset_sync   = 2'b00;

    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n) begin
            video_pipeline_reset_sync <= 2'b00;
            video_tpg_reset_sync      <= 2'b00;
            video_engine_reset_sync   <= 2'b00;
        end else begin
            video_pipeline_reset_sync <= {video_pipeline_reset_sync[0], video_pipeline_reset};
            video_tpg_reset_sync      <= {video_tpg_reset_sync[0], video_tpg_reset};
            video_engine_reset_sync   <= {video_engine_reset_sync[0], video_engine_reset};
        end
    end

    wire video_pipeline_rst_n = pcie_user_rst_n && !video_pipeline_reset_sync[1];
    wire video_tpg_rst_n      = video_pipeline_rst_n && !video_tpg_reset_sync[1];
    wire video_engine_rst_n   = video_pipeline_rst_n && !video_engine_reset_sync[1];

    wire capture_clk, capture_rst_n;
    wire video_capture_active;
    wire capture_use_tpg;
    wire dp_packet_valid,dp_packet_data_ready,dp_packet_ack;
    wire [63:0] dp_packet_addr;
    wire [10:0] dp_packet_dw_len;
    wire [3:0] dp_packet_first_be,dp_packet_last_be;
    wire [255:0] dp_packet_data;
`ifdef SC7F0_DEBUG_ONLY
    assign dp_packet_valid=0;assign dp_packet_addr=0;assign dp_packet_dw_len=0;
    assign dp_packet_first_be=0;assign dp_packet_last_be=0;assign dp_packet_data=0;
`else
    wire dp_mem_reset,dp_mem_rst_n,dp_irq,capture_irq;
    // sys_100m_rst_n (PS 100 MHz proc_sys_reset) and sys_300m_rst_n (300 MHz
    // Si5341 domain) are independent asynchronous sources.  They must never be
    // OR-ed in front of a synchronizer's async preset: that is the CDC-10/CDC-12
    // root cause this file used to carry.  sc7f0_reset_sync gives each source its
    // own crossing into capture_clk and combines them only afterwards.
    wire dp_mem_all_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_dp_mem_reset(
        .dest_clk(capture_clk),
        .src_rst_n({sys_300m_rst_n, sys_100m_rst_n}),
        .dest_rst_n(dp_mem_all_n));
    assign dp_mem_reset =!dp_mem_all_n;
    assign dp_mem_rst_n=dp_mem_all_n;
    wire [48:0] dp_awaddr,dp_araddr;
    wire [7:0] dp_awlen,dp_arlen;
    wire [2:0] dp_awsize,dp_arsize;
    wire [1:0] dp_awburst,dp_arburst,dp_bresp,dp_rresp;
    wire dp_awvalid,dp_awready,dp_wvalid,dp_wready,dp_wlast,dp_bvalid,dp_bready;
    wire dp_arvalid,dp_arready,dp_rvalid,dp_rready,dp_rlast;
    wire [5:0] dp_arid,dp_rid;
    wire [127:0] dp_wdata,dp_rdata;
    wire [15:0] dp_wstrb;
`ifdef SC7F0_TX_VIDEO_PRESENT
    // Display framebuffer reader read stream (sc7f0_display_pipeline -> HP1).
    // Declared here because u_hp1_read_arbiter and its merge stage sit above the
    // HDMI TX block in this file; `default_nettype none` forbids use-before-decl.
    wire [63:0]  disp_araddr;
    wire [7:0]   disp_arlen;
    wire [2:0]   disp_arsize;
    wire [1:0]   disp_arburst;
    wire         disp_arvalid,disp_arready,disp_rvalid,disp_rready,disp_rlast;
    wire [127:0] disp_rdata;
    wire [1:0]   disp_rresp;
    wire         hdmi_tx_irq,display_frmbuf_irq;
`endif
`endif
`ifdef SC7F0_DEBUG_ONLY
    assign capture_clk = pcie_user_clk;
    assign capture_rst_n = video_engine_rst_n;
    wire ovl_wr_clk = pcie_user_clk;
    wire ovl_wr_rst_n = video_engine_rst_n;
`else
    BUFGCE_DIV #(.BUFGCE_DIVIDE(1)) u_capture_clock (
        .I(pl_clk_300m_ibufg), .CE(1'b1), .CLR(!sys_300m_rst_n),
        .O(capture_clk));
    wire capture_mmcm_clkout0, capture_mmcm_fb, capture_mmcm_locked;
    MMCME4_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(5.0),
        .CLKIN1_PERIOD(3.333),
        .CLKOUT0_DIVIDE_F(6.0),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) u_capture_mmcm (
        .CLKOUT0(capture_mmcm_clkout0),
        .CLKFBOUT(capture_mmcm_fb),
        .LOCKED(capture_mmcm_locked),
        .CLKIN1(pl_clk_300m_ibufg),
        .PWRDWN(1'b0),
        .RST(!sys_300m_rst_n),
        .CLKFBIN(capture_mmcm_fb)
    );
    wire ovl_wr_clk;
    BUFGCE u_ovl_wr_clock (
        .I(capture_mmcm_clkout0), .CE(1'b1),
        .O(ovl_wr_clk));
    wire ovl_wr_rst_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_ovl_wr_reset (
        .dest_clk(ovl_wr_clk),
        .src_rst_n({sys_300m_rst_n, sys_100m_rst_n}),
        .dest_rst_n(ovl_wr_rst_n));
    wire capture_reset;
    // Same rule as u_dp_mem_reset: one crossing per source, combine in-domain.
    wire capture_all_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_capture_reset (
        .dest_clk(capture_clk),
        .src_rst_n({sys_300m_rst_n, sys_100m_rst_n}),
        .dest_rst_n(capture_all_n));
    assign capture_reset = !capture_all_n;
    assign capture_rst_n = capture_all_n;
`endif

    // =========================================================================
    // BAR1 AXI4-Lite Master Interconnect Wires
    // Connected to axi_crossbar_0 S00 Interface
    // =========================================================================
    wire [31:0] bar1_m_awaddr;
    wire        bar1_m_awvalid;
    wire        bar1_m_awready;
    wire [31:0] bar1_m_wdata;
    wire [3:0]  bar1_m_wstrb;
    wire        bar1_m_wvalid;
    wire        bar1_m_wready;
    wire [1:0]  bar1_m_bresp;
    wire        bar1_m_bvalid;
    wire        bar1_m_bready;
    wire [31:0] bar1_m_araddr;
    wire        bar1_m_arvalid;
    wire        bar1_m_arready;
    wire [31:0] bar1_m_rdata;
    wire [1:0]  bar1_m_rresp;
    wire        bar1_m_rvalid;
    wire        bar1_m_rready;

    // =========================================================================
    // =========================================================================
    // AXI Crossbar Master Interface Wires (4 Masters)
    // M00 (Bits 31:0)   : RESERVED hole -> axil_decerr_slave (was ZZLAB ENV,
    //                     moved to BAR0 0x1000). Answers DECERR, never hangs.
    // M01 (Bits 63:32)  : Audio Pattern Generator (Offset 0x1000 - 0x1FFF)
    // M02 (Bits 95:64)  : Dynamic EDID RAM + HPD (Offset 0x2000 - 0x2FFF)
    // M03 (Bits 127:96) : Video TPG IP s_axi_CTRL (Offset 0x3000 - 0x3FFF)
    // =========================================================================
    // BAR1 M00 (Bits 31:0, Offset 0x0000 - 0x0FFF): RESERVED hole.
    // zzlab_env moved to BAR0 0x1000 (pl_clk0, PS+PCIe shared). This DECERR
    // guard answers stray host reads here instantly instead of wedging.
    wire [31:0] hole_axi_awaddr_32, hole_axi_araddr_32;
    wire        hole_axi_awvalid, hole_axi_awready;
    wire [31:0] hole_axi_wdata;
    wire [3:0]  hole_axi_wstrb;
    wire        hole_axi_wvalid, hole_axi_wready;
    wire [1:0]  hole_axi_bresp;
    wire        hole_axi_bvalid, hole_axi_bready;
    wire        hole_axi_arvalid, hole_axi_arready;
    wire [31:0] hole_axi_rdata;
    wire [1:0]  hole_axi_rresp;
    wire        hole_axi_rvalid, hole_axi_rready;

    wire [31:0] tpg_axi_awaddr_32, tpg_axi_araddr_32;
    wire [7:0]  tpg_axi_awaddr, tpg_axi_araddr;
    wire        tpg_axi_awvalid, tpg_axi_awready;
    wire [31:0] tpg_axi_wdata;
    wire [3:0]  tpg_axi_wstrb;
    wire        tpg_axi_wvalid, tpg_axi_wready;
    wire [1:0]  tpg_axi_bresp;
    wire        tpg_axi_bvalid, tpg_axi_bready;
    wire        tpg_axi_arvalid, tpg_axi_arready;
    wire [31:0] tpg_axi_rdata;
    wire [1:0]  tpg_axi_rresp;
    wire        tpg_axi_rvalid, tpg_axi_rready;

    wire [31:0] aud_axi_awaddr_32, aud_axi_araddr_32;
    wire [7:0]  aud_axi_awaddr, aud_axi_araddr;
    wire        aud_axi_awvalid, aud_axi_awready;
    wire [31:0] aud_axi_wdata;
    wire [3:0]  aud_axi_wstrb;
    wire        aud_axi_wvalid, aud_axi_wready;
    wire [1:0]  aud_axi_bresp;
    wire        aud_axi_bvalid, aud_axi_bready;
    wire        aud_axi_arvalid, aud_axi_arready;
    wire [31:0] aud_axi_rdata;
    wire [1:0]  aud_axi_rresp;
    wire        aud_axi_rvalid, aud_axi_rready;

    wire [31:0] edid_axi_awaddr, edid_axi_araddr;
    wire        edid_axi_awvalid, edid_axi_awready;
    wire [31:0] edid_axi_wdata;
    wire [3:0]  edid_axi_wstrb;
    wire        edid_axi_wvalid, edid_axi_wready;
    wire [1:0]  edid_axi_bresp;
    wire        edid_axi_bvalid, edid_axi_bready;
    wire        edid_axi_arvalid, edid_axi_arready;
    wire [31:0] edid_axi_rdata;
    wire [1:0]  edid_axi_rresp;
    wire        edid_axi_rvalid, edid_axi_rready;

    assign tpg_axi_awaddr = tpg_axi_awaddr_32[7:0];
    assign tpg_axi_araddr = tpg_axi_araddr_32[7:0];
    assign aud_axi_awaddr = aud_axi_awaddr_32[7:0];
    assign aud_axi_araddr = aud_axi_araddr_32[7:0];

    // =========================================================================
    // Xilinx Official AXI Crossbar IP (1 SI x 4 MI AXI4-Lite)
    // =========================================================================
    axi_crossbar_0 u_axil_crossbar (
        .aclk(pcie_user_clk),
        .aresetn(pcie_user_rst_n),

        // Slave Interface 0 (S00) <- BAR1 Master
        .s_axi_awaddr(bar1_m_awaddr),
        .s_axi_awprot(3'b000),
        .s_axi_awvalid(bar1_m_awvalid),
        .s_axi_awready(bar1_m_awready),
        .s_axi_wdata(bar1_m_wdata),
        .s_axi_wstrb(bar1_m_wstrb),
        .s_axi_wvalid(bar1_m_wvalid),
        .s_axi_wready(bar1_m_wready),
        .s_axi_bresp(bar1_m_bresp),
        .s_axi_bvalid(bar1_m_bvalid),
        .s_axi_bready(bar1_m_bready),
        .s_axi_araddr(bar1_m_araddr),
        .s_axi_arprot(3'b000),
        .s_axi_arvalid(bar1_m_arvalid),
        .s_axi_arready(bar1_m_arready),
        .s_axi_rdata(bar1_m_rdata),
        .s_axi_rresp(bar1_m_rresp),
        .s_axi_rvalid(bar1_m_rvalid),
        .s_axi_rready(bar1_m_rready),

        // Master Interfaces Vector Output: [M03 (TPG), M02 (EDID), M01 (Audio), M00 (ENV)]
        .m_axi_awaddr({tpg_axi_awaddr_32, edid_axi_awaddr, aud_axi_awaddr_32, hole_axi_awaddr_32}),
        .m_axi_awprot(),
        .m_axi_awvalid({tpg_axi_awvalid, edid_axi_awvalid, aud_axi_awvalid, hole_axi_awvalid}),
        .m_axi_awready({tpg_axi_awready, edid_axi_awready, aud_axi_awready, hole_axi_awready}),
        .m_axi_wdata({tpg_axi_wdata, edid_axi_wdata, aud_axi_wdata, hole_axi_wdata}),
        .m_axi_wstrb({tpg_axi_wstrb, edid_axi_wstrb, aud_axi_wstrb, hole_axi_wstrb}),
        .m_axi_wvalid({tpg_axi_wvalid, edid_axi_wvalid, aud_axi_wvalid, hole_axi_wvalid}),
        .m_axi_wready({tpg_axi_wready, edid_axi_wready, aud_axi_wready, hole_axi_wready}),
        .m_axi_bresp({tpg_axi_bresp, edid_axi_bresp, aud_axi_bresp, hole_axi_bresp}),
        .m_axi_bvalid({tpg_axi_bvalid, edid_axi_bvalid, aud_axi_bvalid, hole_axi_bvalid}),
        .m_axi_bready({tpg_axi_bready, edid_axi_bready, aud_axi_bready, hole_axi_bready}),
        .m_axi_araddr({tpg_axi_araddr_32, edid_axi_araddr, aud_axi_araddr_32, hole_axi_araddr_32}),
        .m_axi_arprot(),
        .m_axi_arvalid({tpg_axi_arvalid, edid_axi_arvalid, aud_axi_arvalid, hole_axi_arvalid}),
        .m_axi_arready({tpg_axi_arready, edid_axi_arready, aud_axi_arready, hole_axi_arready}),
        .m_axi_rdata({tpg_axi_rdata, edid_axi_rdata, aud_axi_rdata, hole_axi_rdata}),
        .m_axi_rresp({tpg_axi_rresp, edid_axi_rresp, aud_axi_rresp, hole_axi_rresp}),
        .m_axi_rvalid({tpg_axi_rvalid, edid_axi_rvalid, aud_axi_rvalid, hole_axi_rvalid}),
        .m_axi_rready({tpg_axi_rready, edid_axi_rready, aud_axi_rready, hole_axi_rready})
    );

    // =========================================================================
    // BAR1 0x0000 - 0x0FFF DECERR guard (was zzlab_env_ctrl, now at BAR0
    // 0x1000 on pl_clk0). Answers stray host accesses instantly; the BAR1
    // M00 window must never hang the PCIe CQ path.
    // =========================================================================
    axil_decerr_slave u_bar1_hole_decerr (
        .clk                (pcie_user_clk),
        .rst_n              (pcie_user_rst_n),
        .s_axil_awaddr      (hole_axi_awaddr_32),
        .s_axil_awvalid     (hole_axi_awvalid),
        .s_axil_awready     (hole_axi_awready),
        .s_axil_wdata       (hole_axi_wdata),
        .s_axil_wstrb       (hole_axi_wstrb),
        .s_axil_wvalid      (hole_axi_wvalid),
        .s_axil_wready      (hole_axi_wready),
        .s_axil_bresp       (hole_axi_bresp),
        .s_axil_bvalid      (hole_axi_bvalid),
        .s_axil_bready      (hole_axi_bready),
        .s_axil_araddr      (hole_axi_araddr_32),
        .s_axil_arvalid     (hole_axi_arvalid),
        .s_axil_arready     (hole_axi_arready),
        .s_axil_rdata       (hole_axi_rdata),
        .s_axil_rresp       (hole_axi_rresp),
        .s_axil_rvalid      (hole_axi_rvalid),
        .s_axil_rready      (hole_axi_rready)
    );

    // =========================================================================
    // Xilinx Video Test Pattern Generator IP (v_tpg_0) Wires & Instantiation
    // Configuration: 4 PPC (Samples per Clock = 4) @ 4K60, 96-bit AXI4-Stream
    // =========================================================================
    wire [95:0] tpg_axis_tdata;  // 4 pixels * 24-bit RGB = 96-bit
    wire        tpg_axis_tvalid;
    wire        tpg_axis_tready;
    wire        tpg_axis_tlast;
    wire [0:0]  tpg_axis_tuser;
    wire [11:0] tpg_axis_tkeep;
    wire [11:0] tpg_axis_tstrb;
    wire        tpg_interrupt;

`ifndef SC7F0_C2H_ONLY
    v_tpg_0 u_v_tpg (
        .ap_clk(pcie_user_clk),
        .ap_rst_n(video_tpg_rst_n),

        // AXI4-Lite Control Slave (s_axi_CTRL)
        .s_axi_CTRL_AWADDR(tpg_axi_awaddr),
        .s_axi_CTRL_AWVALID(tpg_axi_awvalid),
        .s_axi_CTRL_AWREADY(tpg_axi_awready),
        .s_axi_CTRL_WDATA(tpg_axi_wdata),
        .s_axi_CTRL_WSTRB(tpg_axi_wstrb),
        .s_axi_CTRL_WVALID(tpg_axi_wvalid),
        .s_axi_CTRL_WREADY(tpg_axi_wready),
        .s_axi_CTRL_BRESP(tpg_axi_bresp),
        .s_axi_CTRL_BVALID(tpg_axi_bvalid),
        .s_axi_CTRL_BREADY(tpg_axi_bready),
        .s_axi_CTRL_ARADDR(tpg_axi_araddr),
        .s_axi_CTRL_ARVALID(tpg_axi_arvalid),
        .s_axi_CTRL_ARREADY(tpg_axi_arready),
        .s_axi_CTRL_RDATA(tpg_axi_rdata),
        .s_axi_CTRL_RRESP(tpg_axi_rresp),
        .s_axi_CTRL_RVALID(tpg_axi_rvalid),
        .s_axi_CTRL_RREADY(tpg_axi_rready),

        .fid(),
        .fid_in(1'b0),
        .interrupt(tpg_interrupt),

        // AXI4-Stream Video Output Interface
        .m_axis_video_TDATA(tpg_axis_tdata),
        .m_axis_video_TVALID(tpg_axis_tvalid),
        .m_axis_video_TREADY(tpg_axis_tready),
        .m_axis_video_TLAST(tpg_axis_tlast),
        .m_axis_video_TUSER(tpg_axis_tuser),
        .m_axis_video_TKEEP(tpg_axis_tkeep),
        .m_axis_video_TSTRB(tpg_axis_tstrb),
        .m_axis_video_TID(),
        .m_axis_video_TDEST()
    );

`else
    assign tpg_axis_tdata=0; assign tpg_axis_tvalid=0; assign tpg_axis_tlast=0; assign tpg_axis_tuser=0;
    assign tpg_axis_tkeep=0; assign tpg_axis_tstrb=0; assign tpg_interrupt=0;
    sc7f0_axil_disabled #(.ADDR_WIDTH(8)) u_disabled_tpg (.clk(pcie_user_clk), .rst_n(pcie_user_rst_n),
        .s_axil_awaddr(tpg_axi_awaddr),
        .s_axil_awvalid(tpg_axi_awvalid),
        .s_axil_awready(tpg_axi_awready),
        .s_axil_wdata(tpg_axi_wdata),
        .s_axil_wstrb(tpg_axi_wstrb),
        .s_axil_wvalid(tpg_axi_wvalid),
        .s_axil_wready(tpg_axi_wready),
        .s_axil_bresp(tpg_axi_bresp),
        .s_axil_bvalid(tpg_axi_bvalid),
        .s_axil_bready(tpg_axi_bready),
        .s_axil_araddr(tpg_axi_araddr),
        .s_axil_arvalid(tpg_axi_arvalid),
        .s_axil_arready(tpg_axi_arready),
        .s_axil_rdata(tpg_axi_rdata),
        .s_axil_rresp(tpg_axi_rresp),
        .s_axil_rvalid(tpg_axi_rvalid),
        .s_axil_rready(tpg_axi_rready)
    );
`endif

    // =========================================================================
    // AES3 Audio Pattern Generator (audio_pattern_gen) Wires & Instantiation
    // =========================================================================
    wire [31:0] aud_pat_axis_tdata;
    wire        aud_pat_axis_tvalid;
    wire        aud_pat_axis_tlast;
    wire        aud_pat_axis_tready;

`ifndef SC7F0_C2H_ONLY
    audio_pattern_gen #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) u_audio_pattern_gen (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),

        // AXI4-Lite Control Slave (Mapped to BAR1 Offset 0x1000)
        .s_axil_awaddr(aud_axi_awaddr),
        .s_axil_awvalid(aud_axi_awvalid),
        .s_axil_awready(aud_axi_awready),
        .s_axil_wdata(aud_axi_wdata),
        .s_axil_wstrb(aud_axi_wstrb),
        .s_axil_wvalid(aud_axi_wvalid),
        .s_axil_wready(aud_axi_wready),
        .s_axil_bresp(aud_axi_bresp),
        .s_axil_bvalid(aud_axi_bvalid),
        .s_axil_bready(aud_axi_bready),
        .s_axil_araddr(aud_axi_araddr),
        .s_axil_arvalid(aud_axi_arvalid),
        .s_axil_arready(aud_axi_arready),
        .s_axil_rdata(aud_axi_rdata),
        .s_axil_rresp(aud_axi_rresp),
        .s_axil_rvalid(aud_axi_rvalid),
        .s_axil_rready(aud_axi_rready),

        // AXI4-Stream Audio Output Interface (Direct to PCIe DMA Audio Ch0)
        .m_axis_audio_tdata(aud_pat_axis_tdata),
        .m_axis_audio_tvalid(aud_pat_axis_tvalid),
        .m_axis_audio_tlast(aud_pat_axis_tlast),
        .m_axis_audio_tready(aud_pat_axis_tready)
    );

`else
    assign aud_pat_axis_tdata=0; assign aud_pat_axis_tvalid=0; assign aud_pat_axis_tlast=0;
    sc7f0_axil_disabled #(.ADDR_WIDTH(8)) u_disabled_audio_tpg (.clk(pcie_user_clk), .rst_n(pcie_user_rst_n),
        .s_axil_awaddr(aud_axi_awaddr),
        .s_axil_awvalid(aud_axi_awvalid),
        .s_axil_awready(aud_axi_awready),
        .s_axil_wdata(aud_axi_wdata),
        .s_axil_wstrb(aud_axi_wstrb),
        .s_axil_wvalid(aud_axi_wvalid),
        .s_axil_wready(aud_axi_wready),
        .s_axil_bresp(aud_axi_bresp),
        .s_axil_bvalid(aud_axi_bvalid),
        .s_axil_bready(aud_axi_bready),
        .s_axil_araddr(aud_axi_araddr),
        .s_axil_arvalid(aud_axi_arvalid),
        .s_axil_arready(aud_axi_arready),
        .s_axil_rdata(aud_axi_rdata),
        .s_axil_rresp(aud_axi_rresp),
        .s_axil_rvalid(aud_axi_rvalid),
        .s_axil_rready(aud_axi_rready)
    );
`endif

    // =========================================================================
    // Dynamic EDID RAM & HDMI HPD Controller (BAR1 Offset 0x2000)
    // =========================================================================
    wire [7:0] edid_rdata_byte;
    reg [7:0]  edid_awaddr_q;
    reg [7:0]  edid_wdata_q;
    reg        edid_aw_pending, edid_w_pending;
    reg        edid_bvalid_q, edid_rvalid_q;
    reg [31:0] edid_rdata_q;
    wire       edid_write_en = edid_aw_pending && edid_w_pending && !edid_bvalid_q;
    wire [7:0] edid_mem_addr = edid_write_en ? edid_awaddr_q : edid_axi_araddr[7:0];

`ifdef SC7F0_DEBUG_ONLY
    // No external DDC/EDID hardware in the debug-first profile.
    assign edid_rdata_byte = 8'd0;
`else
    // RX subsystem owns EDID/DDC and HPD; never attach two slave engines.
    // Legacy BAR1 EDID RAM aperture no longer programs the physical DDC bus.
    assign edid_rdata_byte = 8'd0;
`endif

    assign edid_axi_awready = !edid_aw_pending && !edid_bvalid_q;
    assign edid_axi_wready  = !edid_w_pending && !edid_bvalid_q;
    assign edid_axi_bvalid  = edid_bvalid_q;
    assign edid_axi_bresp   = 2'b00;
    assign edid_axi_arready = !edid_rvalid_q;
    assign edid_axi_rvalid  = edid_rvalid_q;
    assign edid_axi_rdata   = edid_rdata_q;
    assign edid_axi_rresp   = 2'b00;

    always @(posedge pcie_user_clk) begin
        if (!pcie_user_rst_n) begin
            edid_awaddr_q   <= 8'd0;
            edid_wdata_q    <= 8'd0;
            edid_aw_pending <= 1'b0;
            edid_w_pending  <= 1'b0;
            edid_bvalid_q   <= 1'b0;
            edid_rvalid_q   <= 1'b0;
            edid_rdata_q    <= 32'd0;
        end else begin
            if (edid_axi_awvalid && edid_axi_awready) begin
                edid_awaddr_q   <= edid_axi_awaddr[7:0];
                edid_aw_pending <= 1'b1;
            end
            if (edid_axi_wvalid && edid_axi_wready) begin
                edid_wdata_q   <= edid_axi_wdata[7:0];
                edid_w_pending <= 1'b1;
            end
            if (edid_write_en) begin
                edid_aw_pending <= 1'b0;
                edid_w_pending  <= 1'b0;
                edid_bvalid_q   <= 1'b1;
            end else if (edid_axi_bready) begin
                edid_bvalid_q   <= 1'b0;
            end

            if (edid_axi_arvalid && edid_axi_arready) begin
                edid_rvalid_q <= 1'b1;
                edid_rdata_q  <= {24'd0, edid_rdata_byte};
            end else if (edid_axi_rready) begin
                edid_rvalid_q <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Multi-Channel AXI4-Stream Video Multiplexing & Diagnostic Marker Overlay
    // =========================================================================
    wire [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0] s_video_tdata;
    wire [NUM_VIDEO_CH-1:0]                    s_video_tvalid;
    wire [NUM_VIDEO_CH-1:0]                    s_video_tlast;
    wire [NUM_VIDEO_CH-1:0]                    s_video_tuser;
    wire [NUM_VIDEO_CH-1:0]                    s_video_tready;

    wire [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0] m_video_tdata;
    wire [NUM_VIDEO_CH-1:0]                    m_video_tvalid;
    wire [NUM_VIDEO_CH-1:0]                    m_video_tlast;
    wire [NUM_VIDEO_CH-1:0]                    m_video_tuser;
    wire [NUM_VIDEO_CH-1:0]                    m_video_tready;

    // The audio AXI-Stream group is declared here, next to the video group, because
    // the display-profile stubs above reference m_audio_tready / m_audio_tvalid /
    // m_audio_tdata (assign m_audio_tready[1] = 1'b1, and the v_hdmi_tx_ss s_axis_audio
    // ports).  Strict analysis rejects use-before-declaration, and leaving them in the
    // audio section below also truncated nothing but hid the dependency; the audio
    // section keeps its own comment block and its s_audio_* group.
    wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0] m_audio_tdata;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tvalid;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tlast;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tready;

    // v_tpg emits each pixel as {R,G,B} or {V,U,Y}. Present {8'hFF, C2, C1, C0} consistently
    // with native rx_video_packed_tdata so that Byte 0 = Y/C0, Byte 1 = U/C1, Byte 2 = V/C2.
    wire [127:0] tpg_padded_tdata = {
        8'hFF, tpg_axis_tdata[95:88], tpg_axis_tdata[87:80], tpg_axis_tdata[79:72],
        8'hFF, tpg_axis_tdata[71:64], tpg_axis_tdata[63:56], tpg_axis_tdata[55:48],
        8'hFF, tpg_axis_tdata[47:40], tpg_axis_tdata[39:32], tpg_axis_tdata[31:24],
        8'hFF, tpg_axis_tdata[23:16], tpg_axis_tdata[15:8],  tpg_axis_tdata[7:0]
    };
    wire [127:0] tpg_capture_tdata;
    wire         tpg_capture_tvalid, tpg_capture_tlast, tpg_capture_tuser;
    wire         tpg_capture_tready;

    wire        dma_overlay_en;
    wire [15:0] dma_overlay_width;
    wire [15:0] dma_overlay_height;

`ifndef SC7F0_C2H_ONLY
    tpg_marker_overlay #(
        .FRAME_WIDTH(4096),
        .FRAME_HEIGHT(2160)
    ) u_tpg_marker_overlay (
        .clk(pcie_user_clk),
        .rst_n(video_engine_rst_n),
        .overlay_en(dma_overlay_en),
        .frame_width(dma_overlay_width),
        .frame_height(dma_overlay_height),
        .s_axis_tdata(tpg_padded_tdata),
        .s_axis_tvalid(tpg_axis_tvalid),
        .s_axis_tlast(tpg_axis_tlast),
        .s_axis_tuser(tpg_axis_tuser),
        .s_axis_tready(tpg_axis_tready),
        .m_axis_tdata(tpg_capture_tdata),
        .m_axis_tvalid(tpg_capture_tvalid),
        .m_axis_tlast(tpg_capture_tlast),
        .m_axis_tuser(tpg_capture_tuser),
        .m_axis_tready(tpg_capture_tready)
    );

`else
    assign tpg_axis_tready=1; assign tpg_capture_tdata=0; assign tpg_capture_tvalid=0;
    assign tpg_capture_tlast=0; assign tpg_capture_tuser=0;
`endif

    // =========================================================================
    // HDMI RX & TX Wires & Bridge Instances (4-Channel Dedicated Streams)
    // =========================================================================
    // BAR0 0x0600 - 0x063C Registers
    wire [31:0] hdmi_rx_status_w;
    wire [31:0] hdmi_rx_res_w;
    wire [31:0] hdmi_rx_timing_w;
    wire [31:0] hdmi_rx_audio_w;
    wire [31:0] audio_capture_control;
    wire [31:0] audio_rx_frames, audio_rx_errors, audio_rx_channels, audio_rx_cs;
    wire [31:0] hdmi_tx_status_w;
    wire [31:0] hdmi_tx_ctrl_w;
    wire [31:0] hdmi_tx_res_w;
    wire [31:0] hdmi_tx_fps_w;
    wire [31:0] hdmi_ipc_cmd_w;
    wire [31:0] hdmi_ipc_arg_w;
    wire [31:0] hdmi_ipc_status_w;
    wire [31:0] hdmi_ipc_doorbell_w;

    // Probing & Diagnostic Wires (BAR0 0x0680 - 0x06DC)
    wire [31:0] probe_version_w;
    wire [31:0] probe_rx_clk_freq_w;
    wire [31:0] probe_dru_clk_freq_w;
    wire [31:0] probe_rxoutclk_freq_w;
    wire [31:0] probe_rx_video_clk_freq_w;
    wire [31:0] probe_tx_clk_freq_w;
    wire [31:0] probe_txoutclk_freq_w;
    wire [31:0] probe_tx_video_clk_freq_w;
    wire [31:0] probe_pins_w;
    wire [31:0] probe_pulse_cnt1_w;
    wire [31:0] probe_ddc_cnt_w;
    wire [31:0] probe_irq_cnt_w;
    wire [31:0] probe_ch0_beats_w;
    wire [31:0] probe_ch1_beats_w;
    wire [31:0] probe_ch2_beats_w;
    wire [31:0] probe_rx_video_sof_w;
    wire [31:0] probe_rx_video_eol_w;
    wire [31:0] probe_rx_video_pix_w;
    wire [31:0] probe_raw_rx_clk_w;
    wire [31:0] probe_raw_dru_clk_w;
    wire [31:0] probe_raw_rxoutclk_w;
    wire [31:0] probe_raw_rx_video_clk_w;
    wire [31:0] probe_raw_refclk100_w;
    wire [31:0] probe_ctrl_w;

    // =========================================================================
    // HDMI Transceiver Physical Clock Buffers (Bank 225/226 MGT)
    // =========================================================================
`ifndef SC7F0_DEBUG_ONLY
    wire rx_mgtrefclk1, rx_mgtrefclk1_odiv2, rx_mgtrefclk1_odiv2_bufg;
    wire rx_ddc_scl_i, rx_ddc_scl_o, rx_ddc_scl_t;
    wire rx_ddc_sda_i, rx_ddc_sda_o, rx_ddc_sda_t;
    wire tx_ddc_scl_i, tx_ddc_scl_o, tx_ddc_scl_t;
    wire tx_ddc_sda_i, tx_ddc_sda_o, tx_ddc_sda_t;
    // Sheet11/14: FPGA is the sink of IT6663 P1TX (RX DDC slave).
    // Sheet11/16: FPGA is the source into IT66318 (TX DDC master).
    sc7f0_ddc_iobuf u_rx_ddc (
        .scl_i(rx_ddc_scl_i), .scl_o(rx_ddc_scl_o), .scl_t(rx_ddc_scl_t),
        .sda_i(rx_ddc_sda_i), .sda_o(rx_ddc_sda_o), .sda_t(rx_ddc_sda_t),
        .scl(hdmi_rx_ddc_scl), .sda(hdmi_rx_ddc_sda)
    );
    sc7f0_ddc_iobuf u_tx_ddc (
        .scl_i(tx_ddc_scl_i), .scl_o(tx_ddc_scl_o), .scl_t(tx_ddc_scl_t),
        .sda_i(tx_ddc_sda_i), .sda_o(tx_ddc_sda_o), .sda_t(tx_ddc_sda_t),
        .scl(hdmi_tx_ddc_scl), .sda(hdmi_tx_ddc_sda)
    );
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_ibufds_rx_clk (
        .I(hdmi_rx_clk_p),
        .IB(hdmi_rx_clk_n),
        .CEB(1'b0),
        .O(rx_mgtrefclk1),
        .ODIV2(rx_mgtrefclk1_odiv2)
    );
    BUFG_GT u_bufg_gt_rx_clk (
        .I(rx_mgtrefclk1_odiv2),
        .CE(1'b1),
        .CEMASK(1'b0),
        .CLR(1'b0),
        .CLRMASK(1'b0),
        .DIV(3'b000),
        .O(rx_mgtrefclk1_odiv2_bufg)
    );

    wire dru_gtnorthrefclk1, dru_gtnorthrefclk1_odiv2, dru_gtnorthrefclk1_odiv2_bufg;
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_ibufds_dru_clk (
        .I(hdmi_dru_clk_p),
        .IB(hdmi_dru_clk_n),
        .CEB(1'b0),
        .O(dru_gtnorthrefclk1),
        .ODIV2(dru_gtnorthrefclk1_odiv2)
    );
    BUFG_GT u_bufg_gt_dru_clk (
        .I(dru_gtnorthrefclk1_odiv2),
        .CE(1'b1),
        .CEMASK(1'b0),
        .CLR(1'b0),
        .CLRMASK(1'b0),
        .DIV(3'b000),
        .O(dru_gtnorthrefclk1_odiv2_bufg)
    );

    wire tx_mgtrefclk0, tx_mgtrefclk0_odiv2, tx_mgtrefclk0_odiv2_bufg;
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_ibufds_tx_clk (
        .I(hdmi_tx_clk_p),
        .IB(hdmi_tx_clk_n),
        .CEB(1'b0),
        .O(tx_mgtrefclk0),
        .ODIV2(tx_mgtrefclk0_odiv2)
    );
    BUFG_GT u_bufg_gt_tx_clk (
        .I(tx_mgtrefclk0_odiv2),
        .CE(1'b1),
        .CEMASK(1'b0),
        .CLR(1'b0),
        .CLRMASK(1'b0),
        .DIV(3'b000),
        .O(tx_mgtrefclk0_odiv2_bufg)
    );

    // TX Refclk Bypass: forward Si5319 clock (tx_mgtrefclk0_odiv2_bufg)
    // directly to hdmi_tx_tmds_clk_p/n via ODDRE1 + OBUFDS, bypassing VPHY's
    // internal TXOUTCLK -> MMCM clock path.
    wire tx_tmds_clk_fwd;
    ODDRE1 #(
        .IS_C_INVERTED  (1'b0),
        .IS_D1_INVERTED (1'b0),
        .IS_D2_INVERTED (1'b0),
        .SIM_DEVICE     ("ULTRASCALE_PLUS"),
        .SRVAL          (1'b0)
    ) u_tx_tmds_clk_oddr (
        .Q  (tx_tmds_clk_fwd),
        .C  (tx_mgtrefclk0_odiv2_bufg),
        .D1 (1'b1),
        .D2 (1'b0),
        .SR (1'b0)
    );
    OBUFDS u_tx_tmds_clk_obufds (
        .O  (hdmi_tx_tmds_clk_p),
        .OB (hdmi_tx_tmds_clk_n),
        .I  (tx_tmds_clk_fwd)
    );

    // =========================================================================
    // Video PHY Controller (vid_phy_controller_0)
    // Full-Duplex Quad 226 Transceiver (RX + TX)
    // =========================================================================
    wire        phy_rx_video_clk;
    wire        hdmi_phy_irq;
    wire        hdmi_rx_irq;
    wire        phy_tx_video_clk;
    wire        phy_rxoutclk;
    wire        phy_txoutclk;
    wire rx_link_rst, tx_link_rst, rx_video_rst, tx_video_rst;
    // Each generated HDMI clock may start/stop during PHY programming.
    // Assert asynchronously, release only after that destination clock runs.
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_rx_link_reset (
        .src_arst(!sys_100m_rst_n), .dest_clk(phy_rxoutclk), .dest_arst(rx_link_rst));
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_tx_link_reset (
        .src_arst(!sys_100m_rst_n), .dest_clk(phy_txoutclk), .dest_arst(tx_link_rst));
    // rx_video domain: two independent sources, two crossings, then combine.
    wire rx_video_all_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_rx_video_reset (
        .dest_clk(phy_rx_video_clk),
        .src_rst_n({sys_300m_rst_n, sys_100m_rst_n}),
        .dest_rst_n(rx_video_all_n));
    assign rx_video_rst = !rx_video_all_n;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(1)) u_tx_video_reset (
        .src_arst(!sys_100m_rst_n), .dest_clk(phy_tx_video_clk), .dest_arst(tx_video_rst));

`ifdef SC7F0_RGB_COMPOSITOR
    // GT AXIS lane width is PPC samples + 8 spare bits: 24 bit at 2 PPC.
    // Physical TMDS lanes are unchanged (3 RX + 3 TX + clock pair) and the serial
    // rate stays 5.94 Gb/s with a 297 MHz reference: pixels per clock moves the
    // parallel width and the pixel clock, never the lanes.
    wire [23:0] phy_rx_axi4s_ch0_tdata;
    wire        phy_rx_axi4s_ch0_tvalid;
    wire [23:0] phy_rx_axi4s_ch1_tdata;
    wire        phy_rx_axi4s_ch1_tvalid;
    wire [23:0] phy_rx_axi4s_ch2_tdata;
    wire        phy_rx_axi4s_ch2_tvalid;

    wire [23:0] phy_tx_axi4s_ch0_tdata;
    wire        phy_tx_axi4s_ch0_tvalid;
    wire [23:0] phy_tx_axi4s_ch1_tdata;
    wire        phy_tx_axi4s_ch1_tvalid;
    wire [23:0] phy_tx_axi4s_ch2_tdata;
    wire        phy_tx_axi4s_ch2_tvalid;
`else
    wire [39:0] phy_rx_axi4s_ch0_tdata;
    wire        phy_rx_axi4s_ch0_tvalid;
    wire [39:0] phy_rx_axi4s_ch1_tdata;
    wire        phy_rx_axi4s_ch1_tvalid;
    wire [39:0] phy_rx_axi4s_ch2_tdata;
    wire        phy_rx_axi4s_ch2_tvalid;

    wire [39:0] phy_tx_axi4s_ch0_tdata;
    wire        phy_tx_axi4s_ch0_tvalid;
    wire [39:0] phy_tx_axi4s_ch1_tdata;
    wire        phy_tx_axi4s_ch1_tvalid;
    wire [39:0] phy_tx_axi4s_ch2_tdata;
    wire        phy_tx_axi4s_ch2_tvalid;
`endif

    wire [7:0]  phy_status_sb_rx_tdata;
    wire        phy_status_sb_rx_tvalid;
    wire [7:0]  phy_status_sb_tx_tdata;
    wire        phy_status_sb_tx_tvalid;

`ifdef SC7F0_RGB_COMPOSITOR
    vid_phy_controller_rgb u_vid_phy_controller (
`else
    vid_phy_controller_0 u_vid_phy_controller (
`endif
        .tx_refclk_rdy                (hdmi_tx_refclk_rdy),
        .tx_tmds_clk                  (),
        .tx_video_clk                 (phy_tx_video_clk),
        .tx_tmds_clk_p                (),
        .tx_tmds_clk_n                (),
        .rx_tmds_clk                  (),
        .rx_video_clk                 (phy_rx_video_clk),
        .rx_tmds_clk_p                (hdmi_rx_recko_p),
        .rx_tmds_clk_n                (hdmi_rx_recko_n),
        .mgtrefclk0_in                (tx_mgtrefclk0),
        .mgtrefclk1_in                (rx_mgtrefclk1),
        .mgtrefclk0_odiv2_in          (tx_mgtrefclk0_odiv2_bufg),
        .mgtrefclk1_odiv2_in          (rx_mgtrefclk1_odiv2_bufg),
        .gtnorthrefclk1_in            (dru_gtnorthrefclk1),
        .gtnorthrefclk1_odiv2_in      (dru_gtnorthrefclk1_odiv2_bufg),
        .phy_rxn_in                   (hdmi_rx_n),
        .phy_rxp_in                   (hdmi_rx_p),
        .phy_txn_out                  (hdmi_tx_n),
        .phy_txp_out                  (hdmi_tx_p),
        .rxoutclk                     (phy_rxoutclk),
        .txoutclk                     (phy_txoutclk),
        .vid_phy_tx_axi4s_aclk        (phy_txoutclk),
        .vid_phy_tx_axi4s_aresetn     (!tx_link_rst),
        .vid_phy_tx_axi4s_ch0_tdata   (phy_tx_axi4s_ch0_tdata),
        .vid_phy_tx_axi4s_ch0_tuser   (1'b0),
        .vid_phy_tx_axi4s_ch0_tvalid  (phy_tx_axi4s_ch0_tvalid),
        .vid_phy_tx_axi4s_ch0_tready  (),
        .vid_phy_tx_axi4s_ch1_tdata   (phy_tx_axi4s_ch1_tdata),
        .vid_phy_tx_axi4s_ch1_tuser   (1'b0),
        .vid_phy_tx_axi4s_ch1_tvalid  (phy_tx_axi4s_ch1_tvalid),
        .vid_phy_tx_axi4s_ch1_tready  (),
        .vid_phy_tx_axi4s_ch2_tdata   (phy_tx_axi4s_ch2_tdata),
        .vid_phy_tx_axi4s_ch2_tuser   (1'b0),
        .vid_phy_tx_axi4s_ch2_tvalid  (phy_tx_axi4s_ch2_tvalid),
        .vid_phy_tx_axi4s_ch2_tready  (),
        .vid_phy_rx_axi4s_ch0_tdata   (phy_rx_axi4s_ch0_tdata),
        .vid_phy_rx_axi4s_ch0_tuser   (),
        .vid_phy_rx_axi4s_ch0_tvalid  (phy_rx_axi4s_ch0_tvalid),
        .vid_phy_rx_axi4s_ch0_tready  (1'b1),
        .vid_phy_rx_axi4s_aclk        (phy_rxoutclk),
        .vid_phy_rx_axi4s_aresetn     (!rx_link_rst),
        .vid_phy_rx_axi4s_ch1_tdata   (phy_rx_axi4s_ch1_tdata),
        .vid_phy_rx_axi4s_ch1_tuser   (),
        .vid_phy_rx_axi4s_ch1_tvalid  (phy_rx_axi4s_ch1_tvalid),
        .vid_phy_rx_axi4s_ch1_tready  (1'b1),
        .vid_phy_rx_axi4s_ch2_tdata   (phy_rx_axi4s_ch2_tdata),
        .vid_phy_rx_axi4s_ch2_tuser   (),
        .vid_phy_rx_axi4s_ch2_tvalid  (phy_rx_axi4s_ch2_tvalid),
        .vid_phy_rx_axi4s_ch2_tready  (1'b1),
        .irq                          (hdmi_phy_irq),
        .vid_phy_sb_aclk              (pl_clk0),
        .vid_phy_sb_aresetn           (sys_100m_rst_n),
        .vid_phy_status_sb_tx_tdata   (phy_status_sb_tx_tdata),
        .vid_phy_status_sb_tx_tvalid  (phy_status_sb_tx_tvalid),
        .vid_phy_status_sb_tx_tready  (1'b1),
        .vid_phy_status_sb_rx_tdata   (phy_status_sb_rx_tdata),
        .vid_phy_status_sb_rx_tvalid  (phy_status_sb_rx_tvalid),
        .vid_phy_status_sb_rx_tready  (1'b1),
        .vid_phy_axi4lite_awaddr      (hdmi_ctl_awaddr[9:0]),
        .vid_phy_axi4lite_awprot      (3'd0),
        .vid_phy_axi4lite_awvalid     (hdmi_ctl_awvalid[0]),
        .vid_phy_axi4lite_awready     (hdmi_ctl_awready[0]),
        .vid_phy_axi4lite_wdata       (hdmi_ctl_wdata[31:0]),
        .vid_phy_axi4lite_wstrb       (hdmi_ctl_wstrb[3:0]),
        .vid_phy_axi4lite_wvalid      (hdmi_ctl_wvalid[0]),
        .vid_phy_axi4lite_wready      (hdmi_ctl_wready[0]),
        .vid_phy_axi4lite_bresp       (hdmi_ctl_bresp[1:0]),
        .vid_phy_axi4lite_bvalid      (hdmi_ctl_bvalid[0]),
        .vid_phy_axi4lite_bready      (hdmi_ctl_bready[0]),
        .vid_phy_axi4lite_araddr      (hdmi_ctl_araddr[9:0]),
        .vid_phy_axi4lite_arprot      (3'd0),
        .vid_phy_axi4lite_arvalid     (hdmi_ctl_arvalid[0]),
        .vid_phy_axi4lite_arready     (hdmi_ctl_arready[0]),
        .vid_phy_axi4lite_rdata       (hdmi_ctl_rdata[31:0]),
        .vid_phy_axi4lite_rresp       (hdmi_ctl_rresp[1:0]),
        .vid_phy_axi4lite_rvalid      (hdmi_ctl_rvalid[0]),
        .vid_phy_axi4lite_rready      (hdmi_ctl_rready[0]),
        .vid_phy_axi4lite_aclk        (pl_clk0),
        .vid_phy_axi4lite_aresetn     (sys_100m_rst_n),
        .drpclk                       (pl_clk0)
    );

    // =========================================================================
    // HDMI RX Subsystem (v_hdmi_rx_ss_0)
    // =========================================================================
`ifdef SC7F0_RGB_COMPOSITOR
    wire [47:0] rx_ss_video_tdata;      // 2 PPC x 24 bit native RGB
`else
    wire [95:0] rx_ss_video_tdata;
`endif
    wire        rx_ss_video_tvalid;
    wire        rx_ss_video_tready;
    wire        rx_ss_video_tlast;
    wire        rx_ss_video_tuser;

    wire [31:0] rx_ss_audio_tdata;
    wire [7:0] rx_ss_audio_tid;
    wire        rx_ss_audio_tvalid;
    wire        rx_ss_audio_tready;
    wire        hdmi_rx_hpd_from_ss;

    // The official RX driver owns EDID and HPD. AXI-Lite runs on pl_clk0,
    // independent of the incoming TMDS/video clock, so HPD can bootstrap RX.
    // Keep the driver's low pulse visible to IT6663 when EDID is replaced.
    assign hdmi_rx_hpd_out = hdmi_rx_hpd_from_ss;

`ifdef SC7F0_RGB_COMPOSITOR
    v_hdmi_rx_ss_rgb u_hdmi_rx_ss (
`else
    v_hdmi_rx_ss_0 u_hdmi_rx_ss (
`endif
        .s_axi_cpu_aclk        (pl_clk0),
        .s_axi_cpu_aresetn     (sys_100m_rst_n),
        .cable_detect          (hdmi_rx_5v_det),
        .link_clk              (phy_rxoutclk),
        .s_axis_audio_aclk     (pcie_user_clk),
        .s_axis_audio_aresetn  (pcie_user_rst_n),
        .acr_cts               (),
        .acr_n                 (),
        .acr_valid             (),
        .hpd                   (hdmi_rx_hpd_from_ss),
        .irq                   (hdmi_rx_irq),
        .video_clk             (phy_rx_video_clk),
        .fid                   (),
        .s_axis_video_aresetn  (sys_100m_rst_n),
        .s_axis_video_aclk     (phy_rx_video_clk),
        .LINK_DATA0_IN_tdata   (phy_rx_axi4s_ch0_tdata),
        .LINK_DATA0_IN_tvalid  (phy_rx_axi4s_ch0_tvalid),
        .LINK_DATA1_IN_tdata   (phy_rx_axi4s_ch1_tdata),
        .LINK_DATA1_IN_tvalid  (phy_rx_axi4s_ch1_tvalid),
        .LINK_DATA2_IN_tdata   (phy_rx_axi4s_ch2_tdata),
        .LINK_DATA2_IN_tvalid  (phy_rx_axi4s_ch2_tvalid),
        .SB_STATUS_IN_tdata    (phy_status_sb_rx_tdata),
        .SB_STATUS_IN_tvalid   (phy_status_sb_rx_tvalid),
        .S_AXI_CPU_IN_araddr   (hdmi_ctl_araddr[40:32]),
        .S_AXI_CPU_IN_arprot   (3'd0),
        .S_AXI_CPU_IN_arready  (hdmi_ctl_arready[1]),
        .S_AXI_CPU_IN_arvalid  (hdmi_ctl_arvalid[1]),
        .S_AXI_CPU_IN_awaddr   (hdmi_ctl_awaddr[40:32]),
        .S_AXI_CPU_IN_awprot   (3'd0),
        .S_AXI_CPU_IN_awready  (hdmi_ctl_awready[1]),
        .S_AXI_CPU_IN_awvalid  (hdmi_ctl_awvalid[1]),
        .S_AXI_CPU_IN_bready   (hdmi_ctl_bready[1]),
        .S_AXI_CPU_IN_bresp    (hdmi_ctl_bresp[3:2]),
        .S_AXI_CPU_IN_bvalid   (hdmi_ctl_bvalid[1]),
        .S_AXI_CPU_IN_rdata    (hdmi_ctl_rdata[63:32]),
        .S_AXI_CPU_IN_rready   (hdmi_ctl_rready[1]),
        .S_AXI_CPU_IN_rresp    (hdmi_ctl_rresp[3:2]),
        .S_AXI_CPU_IN_rvalid   (hdmi_ctl_rvalid[1]),
        .S_AXI_CPU_IN_wdata    (hdmi_ctl_wdata[63:32]),
        .S_AXI_CPU_IN_wready   (hdmi_ctl_wready[1]),
        .S_AXI_CPU_IN_wstrb    (hdmi_ctl_wstrb[7:4]),
        .S_AXI_CPU_IN_wvalid   (hdmi_ctl_wvalid[1]),
        .AUDIO_OUT_tdata       (rx_ss_audio_tdata),
        .AUDIO_OUT_tid         (rx_ss_audio_tid),
        .AUDIO_OUT_tready      (rx_ss_audio_tready),
        .AUDIO_OUT_tvalid      (rx_ss_audio_tvalid),
        .DDC_OUT_scl_i         (rx_ddc_scl_i),
        .DDC_OUT_scl_o         (rx_ddc_scl_o),
        .DDC_OUT_scl_t         (rx_ddc_scl_t),
        .DDC_OUT_sda_i         (rx_ddc_sda_i),
        .DDC_OUT_sda_o         (rx_ddc_sda_o),
        .DDC_OUT_sda_t         (rx_ddc_sda_t),
        .VIDEO_OUT_tdata       (rx_ss_video_tdata),
        .VIDEO_OUT_tlast       (rx_ss_video_tlast),
        .VIDEO_OUT_tready      (rx_ss_video_tready),
        .VIDEO_OUT_tuser       (rx_ss_video_tuser),
        .VIDEO_OUT_tvalid      (rx_ss_video_tvalid)
    );

    // Ch 0: HDMI 148.5 MHz -> capture 150 MHz, NOT PCIe 125 MHz.
`ifdef SC7F0_RGB_COMPOSITOR
    // =====================================================================
    // Packed RGB24 host capture path (SC7F0-RGB-COMPOSITOR-2PPC).
    //
    // The decided format change for this personality is that the host receives
    // packed RGB24 (byte order R,G,B, stride 11520 B per 3840-pixel line,
    // 24883200 B per 4K frame = 1.492992 GB/s) instead of the legacy host-side
    // NV12/RGB-expanded 128-bit DMA word.  It is not RGBA and it is not the
    // 1.99 GB/s padded figure: rtl/sc7f0_rgb24_axis_pack.v gearboxes the
    // 2 PPC native RX field into dense 16-byte groups and publishes whole
    // groups only, so no padding and no truncation is involved anywhere.
    //
    // The packer is a second observer of the same unpausable VIDEO_OUT stream
    // that feeds the PS capture branch.  Both consumers always accept, so
    // neither can gate RX; the packer's own s_axis_tready is deliberately
    // unconnected and it abandons a whole frame (never part of one) when its
    // crossing is not ready, re-arming at the next SOF.
    // =====================================================================
    wire [127:0] rgb24_tdata;
    wire         rgb24_tuser, rgb24_tvalid, rgb24_tready;
    wire [10:0]  rgb24_avail;
    wire         rgb24_ovf_sticky, rgb24_line_align_sticky;
    sc7f0_rgb24_axis_pack #(.NATIVE_PPC(2), .FIFO_DEPTH(1024)) u_rgb24_pack (
        .s_clk(phy_rx_video_clk), .s_rst_n(!rx_video_rst),
        .s_axis_tdata(rx_ss_video_tdata), .s_axis_tvalid(rx_ss_video_tvalid),
        .s_axis_tlast(rx_ss_video_tlast), .s_axis_tuser(rx_ss_video_tuser),
        .s_axis_tready(),
        .m_clk(capture_clk), .m_rst_n(capture_rst_n),
        .m_axis_tdata(rgb24_tdata), .m_axis_tuser(rgb24_tuser),
        .m_axis_tvalid(rgb24_tvalid), .m_axis_tready(rgb24_tready),
        .m_axis_avail(rgb24_avail),
        .overflow_sticky(rgb24_ovf_sticky),
        .line_align_sticky(rgb24_line_align_sticky));

    // The legacy raw video crossing is replaced by the packer above, but the
    // mux and status wiring below is shared, so keep the old names defined.
    wire [127:0] hdmi_rx_v_tdata  = 128'd0;
    wire         hdmi_rx_v_tvalid = 1'b0;
    wire         hdmi_rx_v_tready = 1'b1;
    wire         hdmi_rx_v_tlast  = 1'b0;
    wire         hdmi_rx_v_tuser  = 1'b0;
`else
    wire [127:0] hdmi_rx_v_tdata;
    wire         hdmi_rx_v_tvalid;
    wire         hdmi_rx_v_tready;
    wire         hdmi_rx_v_tlast;
    wire         hdmi_rx_v_tuser;

    // CH0_CTRL[9]: RGB8 input -> BT.709 YUV444 before NV12/NV16 sampling.
    // Driver sets it only for a validated RGB input and semiplanar output.
    // Configuration is changed only while capture is stopped; SOF realigns it.
    wire rx_pack_rgb, rx_csc_enable;
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_rx_pack_mode (
        .src_clk(pcie_user_clk), .src_in(vch0_ctrl_w[7:4] == 4'd1 || vch0_ctrl_w[9]),
        .dest_clk(phy_rx_video_clk), .dest_out(rx_pack_rgb));
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_rx_csc_mode (
        .src_clk(pcie_user_clk), .src_in(vch0_ctrl_w[9]),
        .dest_clk(phy_rx_video_clk), .dest_out(rx_csc_enable));
    wire [127:0] rx_video_packed_tdata;
    hdmi_rx_pixel_pack u_rx_pixel_pack (
        .native_data(rx_ss_video_tdata), .rgb_mode(rx_pack_rgb),
        .dma_data(rx_video_packed_tdata));

    wire [127:0] rx_csc_data;
    wire rx_csc_valid, rx_csc_sof, rx_csc_eol, rx_csc_ready,raw_csc_input_ready;
    wire raw_rx_enabled;
    xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1)) u_raw_rx_enable(
        .src_clk(capture_clk),.src_in(video_capture_active&&capture_rst_n&&!capture_use_tpg),
        .dest_clk(phy_rx_video_clk),.dest_out(raw_rx_enabled));
    // v_hdmi_rx_ss_0 VIDEO_OUT is an unpausable physical scan source: TREADY must
    // stay constant high. Raw Video backpressure (raw_csc_input_ready) is confined
    // to u_rx_csc / u_hdmi_rx_video_cdc_fifo and must never gate PS capture valid.
    // In SC7F0_RGB_COMPOSITOR the adapter u_rx_ppc_upsize drives TREADY (it is
    // constant 1 there too) so the two drivers can never fight.
`ifndef SC7F0_RGB_COMPOSITOR
    assign rx_ss_video_tready=1'b1;
`endif
    video_rgb_to_yuv709 u_rx_csc (
        .clk(phy_rx_video_clk), .rst_n(!rx_video_rst), .enable(rx_csc_enable),
        .s_data(rx_video_packed_tdata), .s_valid(rx_ss_video_tvalid&&raw_rx_enabled),
        .s_sof(rx_ss_video_tuser), .s_eol(rx_ss_video_tlast),
        .s_ready(raw_csc_input_ready),
        .m_data(rx_csc_data), .m_valid(rx_csc_valid),
        .m_sof(rx_csc_sof), .m_eol(rx_csc_eol), .m_ready(rx_csc_ready));

    video_axis_async_fifo #(.DEPTH(1024)) u_hdmi_rx_video_cdc_fifo (
        .s_clk(phy_rx_video_clk), .s_rst_n(!rx_video_rst),
        .s_data(rx_csc_data), .s_valid(rx_csc_valid),
        .s_sof(rx_csc_sof), .s_eol(rx_csc_eol),
        .s_ready(rx_csc_ready),
        .m_clk(capture_clk), .m_rst_n(capture_rst_n),
        .m_data(hdmi_rx_v_tdata), .m_valid(hdmi_rx_v_tvalid),
        .m_sof(hdmi_rx_v_tuser), .m_eol(hdmi_rx_v_tlast),
        .m_ready(hdmi_rx_v_tready)
    );
`endif

    // Official PS V4L2 branch: no downstream READY is connected to RX.
`ifdef SC7F0_RGB_COMPOSITOR
    // The RX subsystem is 2 PPC in this personality while the published PS
    // capture chain (frame tap -> v_proc_ss CSC -> v_frmbuf_wr) is 4 PPC, so the
    // two geometries are joined by rtl/sc7f0_ppc_upsize.v: two 48-bit beats
    // become one 96-bit beat, same pixels, same raster order, half the beat
    // rate, validated capture-chain geometry kept untouched.
    wire [95:0] rx_ss_video_up_tdata;
    wire        rx_ss_video_up_tvalid, rx_ss_video_up_tready;
    wire        rx_ss_video_up_tlast,  rx_ss_video_up_tuser;
    wire        rx_up_odd_line_sticky, rx_up_out_stall_sticky;
    wire [31:0] rx_up_odd_line_count,  rx_up_out_stall_count;
    // PS-side READY contract.  rtl/sc7f0_capture_pipeline.v publishes the RX
    // stream as an observer input only (its port list has rx_data/rx_valid/
    // rx_sof/rx_eol and NO ready, and the module header says "no connection can
    // propagate downstream READY to RX"), so nothing in the PS branch can ever
    // drive this net.  Left undriven (round H: [Synth 8-3848] on line 1202, and
    // the PS observer then samples a beat that never retires) sc7f0_ppc_upsize's
    // out_room = !m_axis_tvalid || m_axis_tready goes false from the SECOND
    // published beat onward: m_axis_tvalid stays 1 carrying a stale 96-bit word,
    // the same SOF is re-published to the observer forever, and every later
    // completed input pair is dropped into output_stall_count.  Both ends are
    // unpausable - the RX source has .s_axis_tready tied 1 one level up, and the
    // frame tap cannot back-pressure a physical scan - so the sink contract here
    // is a documented constant 1: take every complete beat.  This changes no
    // algorithm, no port, no 4PPC geometry and no throughput.
    assign rx_ss_video_up_tready = 1'b1;
    sc7f0_ppc_upsize #(.PPC_IN(2), .PPC_OUT(4)) u_rx_ppc_upsize (
        .clk(phy_rx_video_clk), .rst_n(!rx_video_rst),
        .s_axis_tdata(rx_ss_video_tdata), .s_axis_tvalid(rx_ss_video_tvalid),
        .s_axis_tlast(rx_ss_video_tlast), .s_axis_tuser(rx_ss_video_tuser),
        .s_axis_tready(rx_ss_video_tready),
        .m_axis_tdata(rx_ss_video_up_tdata), .m_axis_tvalid(rx_ss_video_up_tvalid),
        .m_axis_tready(rx_ss_video_up_tready), .m_axis_tlast(rx_ss_video_up_tlast),
        .m_axis_tuser(rx_ss_video_up_tuser),
        .odd_line_sticky(rx_up_odd_line_sticky), .odd_line_count(rx_up_odd_line_count),
        .output_stall_sticky(rx_up_out_stall_sticky),
        .output_stall_count(rx_up_out_stall_count));
`endif
    wire [63:0] fb_awaddr,fb_araddr;
    wire [7:0] fb_arlen,pkt_arlen;
    wire [2:0] fb_arsize,pkt_arsize;
    wire [1:0] fb_arburst,pkt_arburst,fb_rresp,pkt_rresp;
    wire fb_arvalid,fb_arready,fb_rlast,fb_rvalid,fb_rready;
    wire pkt_arvalid,pkt_arready,pkt_rlast,pkt_rvalid,pkt_rready;
    wire [39:0] pkt_araddr;
    wire [127:0] fb_rdata,pkt_rdata;
    assign dp_awaddr=fb_awaddr[48:0];
    // Frame-tap reset bit 2.  Only sc7f0_display_pipeline consumes it; the wire
    // exists in every personality because the CSR lives in u_ps_capture.
    wire display_reader_rst_n;
    sc7f0_capture_pipeline u_ps_capture(
        .csr_clk(pl_clk0),.csr_rst_n(sys_100m_rst_n),.mem_clk(capture_clk),.mem_rst_n(dp_mem_rst_n),
`ifdef SC7F0_RGB_COMPOSITOR
        .rx_clk(phy_rx_video_clk),.rx_rst_n(!rx_video_rst),.rx_data(rx_ss_video_up_tdata),
        .rx_valid(rx_ss_video_up_tvalid),.rx_sof(rx_ss_video_up_tuser),.rx_eol(rx_ss_video_up_tlast),
`else
        .rx_clk(phy_rx_video_clk),.rx_rst_n(!rx_video_rst),.rx_data(rx_ss_video_tdata),
        .rx_valid(rx_ss_video_tvalid),.rx_sof(rx_ss_video_tuser),.rx_eol(rx_ss_video_tlast),
`endif
        .s_awaddr(hdmi_ctl_awaddr[223:128]),.s_awvalid(hdmi_ctl_awvalid[6:4]),.s_awready(hdmi_ctl_awready[6:4]),
        .s_wdata(hdmi_ctl_wdata[223:128]),.s_wstrb(hdmi_ctl_wstrb[27:16]),.s_wvalid(hdmi_ctl_wvalid[6:4]),.s_wready(hdmi_ctl_wready[6:4]),
        .s_bresp(hdmi_ctl_bresp[13:8]),.s_bvalid(hdmi_ctl_bvalid[6:4]),.s_bready(hdmi_ctl_bready[6:4]),
        .s_araddr(hdmi_ctl_araddr[223:128]),.s_arvalid(hdmi_ctl_arvalid[6:4]),.s_arready(hdmi_ctl_arready[6:4]),
        .s_rdata(hdmi_ctl_rdata[223:128]),.s_rresp(hdmi_ctl_rresp[13:8]),.s_rvalid(hdmi_ctl_rvalid[6:4]),.s_rready(hdmi_ctl_rready[6:4]),
        .irq(capture_irq),
        .display_reader_rst_n(display_reader_rst_n),
        .awaddr(fb_awaddr),.awlen(dp_awlen),.awsize(dp_awsize),.awburst(dp_awburst),.awvalid(dp_awvalid),.awready(dp_awready),
        .wdata(dp_wdata),.wstrb(dp_wstrb),.wlast(dp_wlast),.wvalid(dp_wvalid),.wready(dp_wready),
        .bresp(dp_bresp),.bvalid(dp_bvalid),.bready(dp_bready),
        .araddr(fb_araddr),.arlen(fb_arlen),.arsize(fb_arsize),.arburst(fb_arburst),.arvalid(fb_arvalid),.arready(fb_arready),
        .rdata(fb_rdata),.rresp(fb_rresp),.rlast(fb_rlast),.rvalid(fb_rvalid),.rready(fb_rready));
    wire dp_packet_done_msi_pulse;
    wire [31:0] dp_pkt_sub_cnt, dp_pkt_done_cnt, dp_pkt_err_cnt, dp_pkt_msi_cnt;
    wire [31:0] dp_pkt_bytes_lo, dp_pkt_bytes_hi, dp_pkt_fsm_state, dp_pkt_last_len;
    wire [31:0] dp_pkt_last_pts_lo, dp_pkt_last_pts_hi;

    // Keep variable-length packet DMA, but retire the custom image writer.
    sc7f0_dualpath #(.LEGACY_CAPTURE(0)) u_dualpath(
        .csr_clk(pl_clk0),.csr_rst_n(sys_100m_rst_n),
        .mem_clk(capture_clk),.mem_rst_n(dp_mem_rst_n),
        .pcie_clk(pcie_user_clk),.pcie_rst_n(pcie_user_rst_n),
        .video_data(128'd0),.video_valid(1'b0),.video_sof(1'b0),.video_eol(1'b0),
        .s_awaddr(hdmi_ctl_awaddr[127:96]),.s_awvalid(hdmi_ctl_awvalid[3]),.s_awready(hdmi_ctl_awready[3]),
        .s_wdata(hdmi_ctl_wdata[127:96]),.s_wstrb(hdmi_ctl_wstrb[15:12]),
        .s_wvalid(hdmi_ctl_wvalid[3]),.s_wready(hdmi_ctl_wready[3]),
        .s_bresp(hdmi_ctl_bresp[7:6]),.s_bvalid(hdmi_ctl_bvalid[3]),.s_bready(hdmi_ctl_bready[3]),
        .s_araddr(hdmi_ctl_araddr[127:96]),.s_arvalid(hdmi_ctl_arvalid[3]),.s_arready(hdmi_ctl_arready[3]),
        .s_rdata(hdmi_ctl_rdata[127:96]),.s_rresp(hdmi_ctl_rresp[7:6]),
        .s_rvalid(hdmi_ctl_rvalid[3]),.s_rready(hdmi_ctl_rready[3]),.irq(dp_irq),
        .awaddr(),.awlen(),.awsize(),.awburst(),.awvalid(),.awready(1'b0),
        .wdata(),.wstrb(),.wlast(),.wvalid(),.wready(1'b0),.bresp(2'b00),.bvalid(1'b0),.bready(),
        .araddr(pkt_araddr),.arlen(pkt_arlen),.arsize(pkt_arsize),.arburst(pkt_arburst),
        .arvalid(pkt_arvalid),.arready(pkt_arready),.rdata(pkt_rdata),.rresp(pkt_rresp),
        .rlast(pkt_rlast),.rvalid(pkt_rvalid),.rready(pkt_rready),
        .packet_valid(dp_packet_valid),.packet_addr(dp_packet_addr),.packet_dw_len(dp_packet_dw_len),
        .packet_first_be(dp_packet_first_be),.packet_last_be(dp_packet_last_be),
        .packet_data(dp_packet_data),.packet_data_ready(dp_packet_data_ready),.packet_ack(dp_packet_ack),
        .packet_done_msi_pulse(dp_packet_done_msi_pulse),
        .probe_pkt_submit_cnt(dp_pkt_sub_cnt),
        .probe_pkt_done_cnt(dp_pkt_done_cnt),
        .probe_pkt_err_cnt(dp_pkt_err_cnt),
        .probe_pkt_msi_cnt(dp_pkt_msi_cnt),
        .probe_pkt_bytes_lo(dp_pkt_bytes_lo),
        .probe_pkt_bytes_hi(dp_pkt_bytes_hi),
        .probe_pkt_fsm_state(dp_pkt_fsm_state),
        .probe_pkt_last_len(dp_pkt_last_len),
        .probe_pkt_last_pts_lo(dp_pkt_last_pts_lo),
        .probe_pkt_last_pts_hi(dp_pkt_last_pts_hi));
    // S_AXI_HP1_FPD is one 128-bit read-only slave stream. Without the display
    // personality the two capture readers drive it directly, as before. With it,
    // a second identical arbiter merges the display framebuffer reader in; the
    // capture reader logic itself is untouched.
    wire [48:0] hp1r_addr; wire [7:0] hp1r_len; wire [2:0] hp1r_size; wire [1:0] hp1r_burst;
    wire [5:0] hp1r_arid,hp1r_rid;
    wire hp1r_valid,hp1r_ready,hp1r_rvalid,hp1r_rready,hp1r_rlast;
    wire [127:0] hp1r_rdata; wire [1:0] hp1r_rresp;
    sc7f0_axi_read_arbiter_mo #(.AW(49), .IW(6), .ID_BIT(0)) u_hp1_read_arbiter(
        .clk(capture_clk),.rst_n(dp_mem_rst_n),
        .s0_addr({9'd0,pkt_araddr}),.s0_len(pkt_arlen),.s0_size(pkt_arsize),.s0_burst(pkt_arburst),.s0_arid(6'd0),
        .s0_valid(pkt_arvalid),.s0_ready(pkt_arready),.s0_data(pkt_rdata),.s0_resp(pkt_rresp),.s0_rid(),
        .s0_last(pkt_rlast),.s0_rvalid(pkt_rvalid),.s0_rready(pkt_rready),
        .s1_addr(fb_araddr[48:0]),.s1_len(fb_arlen),.s1_size(fb_arsize),.s1_burst(fb_arburst),.s1_arid(6'd0),
        .s1_valid(fb_arvalid),.s1_ready(fb_arready),.s1_data(fb_rdata),.s1_resp(fb_rresp),.s1_rid(),
        .s1_last(fb_rlast),.s1_rvalid(fb_rvalid),.s1_rready(fb_rready),
        .m_addr(hp1r_addr),.m_len(hp1r_len),.m_size(hp1r_size),.m_burst(hp1r_burst),.m_arid(hp1r_arid),
        .m_valid(hp1r_valid),.m_ready(hp1r_ready),.m_data(hp1r_rdata),.m_resp(hp1r_rresp),.m_rid(hp1r_rid),
        .m_last(hp1r_rlast),.m_rvalid(hp1r_rvalid),.m_rready(hp1r_rready));
`ifdef SC7F0_TX_VIDEO_PRESENT
    sc7f0_axi_read_arbiter_mo #(.AW(49), .IW(6), .ID_BIT(1)) u_hp1_display_read_arbiter(
        .clk(capture_clk),.rst_n(dp_mem_rst_n),
        .s0_addr(hp1r_addr),.s0_len(hp1r_len),.s0_size(hp1r_size),.s0_burst(hp1r_burst),.s0_arid(hp1r_arid),
        .s0_valid(hp1r_valid),.s0_ready(hp1r_ready),.s0_data(hp1r_rdata),.s0_resp(hp1r_rresp),.s0_rid(hp1r_rid),
        .s0_last(hp1r_rlast),.s0_rvalid(hp1r_rvalid),.s0_rready(hp1r_rready),
        .s1_addr(disp_araddr[48:0]),.s1_len(disp_arlen),.s1_size(disp_arsize),.s1_burst(disp_arburst),.s1_arid(6'd0),
        .s1_valid(disp_arvalid),.s1_ready(disp_arready),.s1_data(disp_rdata),.s1_resp(disp_rresp),.s1_rid(),
        .s1_last(disp_rlast),.s1_rvalid(disp_rvalid),.s1_rready(disp_rready),
        .m_addr(dp_araddr),.m_len(dp_arlen),.m_size(dp_arsize),.m_burst(dp_arburst),.m_arid(dp_arid),
        .m_valid(dp_arvalid),.m_ready(dp_arready),.m_data(dp_rdata),.m_resp(dp_rresp),.m_rid(dp_rid),
        .m_last(dp_rlast),.m_rvalid(dp_rvalid),.m_rready(dp_rready));
`else
    assign dp_araddr=hp1r_addr;assign dp_arlen=hp1r_len;assign dp_arsize=hp1r_size;
    assign dp_arburst=hp1r_burst;assign dp_arid=hp1r_arid;assign dp_arvalid=hp1r_valid;assign hp1r_ready=dp_arready;
    assign hp1r_rdata=dp_rdata;assign hp1r_rresp=dp_rresp;assign hp1r_rid=dp_rid;assign hp1r_rlast=dp_rlast;
    assign hp1r_rvalid=dp_rvalid;assign dp_rready=hp1r_rready;
`endif

    // Synchronize 5V Cable Detect & HPD status to pcie_user_clk
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_5v_det_q;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_hpd_out_q;
    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n) begin
            sync_5v_det_q  <= 2'b00;
            sync_hpd_out_q <= 2'b00;
        end else begin
            sync_5v_det_q  <= {sync_5v_det_q[0], hdmi_rx_5v_det};
            sync_hpd_out_q <= {sync_hpd_out_q[0], hdmi_rx_hpd_out};
        end
    end

    // Direct hardware status: [0]=5V Detect, [1]=HPD Out
    assign hdmi_rx_status_w = {30'd0, sync_hpd_out_q[1], sync_5v_det_q[1]};
    assign hdmi_rx_res_w    = 32'd0;
    assign hdmi_rx_timing_w = 32'd0;

    // Ch 0: HDMI RX Audio Bridge
    wire [31:0] hdmi_rx_a_tdata;
    wire        hdmi_rx_a_tvalid;
    wire        hdmi_rx_a_tready;
    wire        hdmi_rx_a_tlast;

    // RX audio AXIS already runs on PCIe125; no second clock or raw fan-out.
    hdmi_rx_pcm_converter u_hdmi_rx_pcm_converter (
        .clk(pcie_user_clk), .rst_n(pcie_user_rst_n),
        .capture_enable(audio_capture_control[0] && (audio_capture_control[4] || audio_capture_control[5])),
        .diagnostic_raw(audio_capture_control[5]),
        .s_axis_audio_tdata(rx_ss_audio_tdata), .s_axis_audio_tid(rx_ss_audio_tid),
        .s_axis_audio_tvalid(rx_ss_audio_tvalid), .s_axis_audio_tready(rx_ss_audio_tready),
        .m_axis_pcm_tdata(hdmi_rx_a_tdata), .m_axis_pcm_tvalid(hdmi_rx_a_tvalid),
        .m_axis_pcm_tready(hdmi_rx_a_tready), .overflow(),
        .frame_count(audio_rx_frames), .measured_rate(hdmi_rx_audio_w),
        .error_count(audio_rx_errors), .channel_mask(audio_rx_channels),
        .channel_status(audio_rx_cs)
    );
    assign hdmi_rx_a_tlast = 1'b0;

    // =========================================================================
    // HDMI TX Subsystem (v_hdmi_tx_ss_0)
    // =========================================================================
`ifdef SC7F0_RGB_COMPOSITOR
    wire [47:0] tx_ss_video_tdata;      // v_hdmi_tx_ss_rgb VIDEO_IN is 2 PPC
`else
    wire [95:0] tx_ss_video_tdata;
`endif
    wire        tx_ss_video_tvalid;
    wire        tx_ss_video_tready;
    wire        tx_ss_video_tlast;
    wire        tx_ss_video_tuser;

    wire [31:0] tx_ss_audio_tdata;
    wire        tx_ss_audio_tvalid;
    wire        tx_ss_audio_tready;
    wire        tx_ss_audio_tlast;
    wire        tx_ss_locked;

`ifdef SC7F0_TX_VIDEO_PRESENT
    // =====================================================================
    // TX personalities: PS DDR -> v_frmbuf_rd -> HDMI TX.
    //   SC7F0_DISPLAY_TX       one base plane, 4 PPC, 96-bit VIDEO_IN
    //   SC7F0_RGB_COMPOSITOR   base plane + overlay plane, 2 PPC, 48-bit
    //                          VIDEO_IN, composited by
    //                          rtl/sc7f0_rgb_compositor.v
    // Every register in this chain is owned by an AMD/Xilinx driver:
    //   u_hdmi_tx_ss           hdmi-modules xlnx_drm_hdmi  (xlnx,v-hdmi-tx-ss-3.1)
    //   u_frmbuf_rd (inside)   in-kernel xlnx,axi-frmbuf-rd-v2.2 + xlnx,pl-disp
    //   u_vid_phy_controller   hdmi-modules phy-vphy (xlnx,vid-phy-controller-2.2)
    // No private kernel ABI, no daemon and no bare MMIO is introduced.  The RX
    // direct bypass (mux mode 0) and the host PCIe H2C stream (mux mode 2) are
    // deliberately NOT wired, so the only source of VIDEO_IN is the framebuffer
    // reader: whatever the monitor shows is exactly what the PS wrote to DDR.
    // =====================================================================
`ifdef SC7F0_RGB_COMPOSITOR
    // =====================================================================
    // SC7F0-RGB-COMPOSITOR-2PPC: two INDEPENDENT official v_frmbuf_rd readers,
    // one per plane, both 2 PPC RGBA8888 with native 128-bit AXIMM.
    //
    //   Reader-A  base plane    -> PS HP1 read channel (shared with the two
    //                             capture readers through u_hp1_read_arbiter /
    //                             u_hp1_display_read_arbiter, read-only, so the
    //                             already-proven HP1 merge ordering is kept)
    //   Reader-B  overlay plane -> the NEW PS HP2 read channel, 300 MHz
    //
    // Two separate 128-bit 300 MHz read ports (4.8 GB/s each) carry two 4K60
    // RGBA32 planes (1.990656 GB/s each); squeezing 3.98 GB/s of reads plus the
    // overlay write through the single HP1 port would not fit, which is exactly
    // why HP2 exists in this personality.
    //
    // The composited output is native RGB at 2 PPC (48 bit) because the HDMI
    // cable carries RGB8 with no alpha: rtl/sc7f0_alpha_blend_2ppc.v consumes
    // native RGBA {A,R,B,G} beats from memory RGBA byte R,G,B,A and emits
    // native RGB {R,B,G}, and v_hdmi_tx_ss_rgb VIDEO_IN at 2 PPC is 2*24 bit.
    // =====================================================================
    wire [47:0] disp_video_tdata;
    wire        disp_video_tvalid,disp_video_tready,disp_video_tlast,disp_video_tuser;

    // Reader-B reset: PS EMIO GPIO bit 3 (the official xilinx_frmbuf driver
    // requires a reset-gpios on a framebuffer reader), synchronised and
    // stretched in capture_clk, then qualified with the CSR level.
    wire        reader_b_gpio_reset;      // from the BD, emio_gpio_o[3]
    wire        reader_b_reset_sync;
    sc7f0_reset_sync #(.SOURCES(1)) u_reader_b_reset (
        .dest_clk(capture_clk),
        .src_rst_n(~reader_b_gpio_reset),
        .dest_rst_n(reader_b_reset_sync));

    // Reader-B AXI4 read-only master on the new PS HP2 port.
    wire [63:0] rd_b_araddr;  wire [7:0] rd_b_arlen;
    wire [2:0]  rd_b_arsize;  wire [1:0] rd_b_arburst;
    wire        rd_b_arvalid, rd_b_arready, rd_b_rvalid, rd_b_rready, rd_b_rlast;
    wire [127:0] rd_b_rdata;  wire [1:0] rd_b_rresp;

    // Overlay plane writer -> PS HP3.
    wire [48:0]  ovl_hp3_awaddr; wire [7:0] ovl_hp3_awlen;
    wire [2:0]   ovl_hp3_awsize; wire [1:0] ovl_hp3_awburst;
    wire [3:0]   ovl_hp3_awcache;
    wire         ovl_hp3_awvalid, ovl_hp3_awready;
    wire [127:0] ovl_hp3_wdata;  wire [15:0] ovl_hp3_wstrb;
    wire         ovl_hp3_wlast, ovl_hp3_wvalid, ovl_hp3_wready;
    wire [1:0]   ovl_hp3_bresp;  wire ovl_hp3_bvalid, ovl_hp3_bready;

    // Overlay control window + compositor control (axi_crossbar_hdmi M09).
    wire         ovl_ctrl_enable, ovl_ctrl_go, ovl_ctrl_quiesce_req, ovl_ctrl_discard_pending;
    wire [63:0]  ovl_ctrl_src_addr;
    wire [31:0]  ovl_ctrl_xfer_bytes;
    wire [15:0]  ovl_ctrl_max_bytes_per_req;
    wire         ovl_ctrl_wr_enable, ovl_ctrl_wr_auto_advance;
    wire [48:0]  ovl_ctrl_wr_dst_base;
    wire [31:0]  ovl_ctrl_wr_slot_bytes, ovl_ctrl_wr_frame_bytes;
    wire [2:0]   ovl_ctrl_wr_slot_count; wire [1:0] ovl_ctrl_wr_force_slot;
    wire [3:0]   ovl_ctrl_wr_consume;
    wire [31:0]  ovl_status_bytes_issued, ovl_status_bytes_staged, ovl_status_bytes_drained;
    wire [5:0]   ovl_status_outstanding;
    wire         ovl_status_busy, ovl_status_quiesced, ovl_status_quarantined;
    wire         ovl_status_ext_tag_blocked;
    wire [31:0]  ovl_status_counts;
    wire [3:0]   ovl_wr_slot_ready;  wire ovl_wr_busy;
    wire [1:0]   ovl_wr_active_slot;
    wire [31:0]  ovl_wr_frames_done, ovl_wr_bytes_written;
    wire [5:0]   ovl_wr_sticky;      wire [3:0] ovl_axi_dbg; wire ovl_wr_irq_pulse;
    // Review H1/H2 additions between dma_top, the plane writer and the control
    // block: software plane discard, writer retirement/frames-suppressed, the H2
    // video format guard, and the abandoned-tag (poison) state.
    wire         ovl_ctrl_abort_req;
    wire         ovl_wr_abort_busy;
    wire [31:0]  ovl_wr_err_frames;
    wire         ovl_video_guard_sticky;
    wire [31:0]  ovl_video_guard_count;
    wire         ovl_video_poison;
    wire         comp_irq_a, comp_irq_b;
    wire         blend_locked, blend_busy, blend_enable, alpha_force_opaque, blend_unlock;
    wire         reader_b_reset, rx_passthrough;
    wire         ovl_hw_auto_slot;
    wire [3:0]   ovl_wr_slot_release_m, ovl_wr_slot_ready_m;
    wire [1:0]   ovl_wr_last_slot_m;
    wire [31:0]  ovl_wr_slot_bytes_m;
    wire         ovl_base_vblank_p;
    wire [63:0]  ovl_direct_tdata;
    wire         ovl_direct_tvalid, ovl_direct_tready, ovl_direct_tlast, ovl_direct_tuser;
    wire [31:0]  bar0_ovl_awaddr, bar0_ovl_wdata, bar0_ovl_araddr, bar0_ovl_rdata;
    wire [3:0]   bar0_ovl_wstrb;
    wire [1:0]   bar0_ovl_bresp, bar0_ovl_rresp;
    wire         bar0_ovl_awvalid, bar0_ovl_awready, bar0_ovl_wvalid, bar0_ovl_wready;
    wire         bar0_ovl_bvalid, bar0_ovl_bready, bar0_ovl_arvalid, bar0_ovl_arready;
    wire         bar0_ovl_rvalid, bar0_ovl_rready;
    wire [31:0]  blend_lock_lost, blend_sat_watchdog, blend_beats;
    // B1 SOF genlock status.  The 2-bit state is expanded to three one-hot levels
    // before it reaches sc7f0_rgb_overlay_ctrl, because only single-bit levels may
    // cross into the CSR clock without a tearing hazard.
    wire [1:0]   blend_gl_state;
    wire [2:0]   blend_drop_reason;
    wire [31:0]  blend_lock_count, blend_base_passthru;
    wire         blend_gl_seeking   = (blend_gl_state == 2'd0);
    wire         blend_gl_wait_vsof = (blend_gl_state == 2'd1);
    wire         blend_gl_lock_state= (blend_gl_state == 2'd2);

    sc7f0_rgb_compositor #(.PPC(2), .DIRECT_OVL_STREAM(1)) u_rgb_compositor (
        .csr_clk(pl_clk0),           .csr_rst_n(sys_100m_rst_n),
        .mem_clk(capture_clk),       .mem_rst_n(dp_mem_rst_n),
        // Plane-A controllable reset stays the reviewed frame-tap CSR bit 2.
        .reader_a_rst_n(display_reader_rst_n),
        .reader_b_rst_n(reader_b_reset_sync & ~reader_b_reset),
        .tx_clk(phy_tx_video_clk),   .tx_rst_n(!tx_video_rst),
        .rx_clk(phy_rx_video_clk),   .rx_rst_n(!rx_video_rst),
        .rx_axis_tdata(rx_ss_video_tdata),
        .rx_axis_tvalid(rx_ss_video_tvalid),
        .rx_axis_tlast(rx_ss_video_tlast),
        .rx_axis_tuser(rx_ss_video_tuser),
        .rx_passthrough(rx_passthrough),
        // Plane A control: axi_crossbar_hdmi M07, 0xB0080000.
        .s_axi_a_awaddr(hdmi_ctl_awaddr[255:224]),
        .s_axi_a_awvalid(hdmi_ctl_awvalid[7]),
        .s_axi_a_awready(hdmi_ctl_awready[7]),
        .s_axi_a_wdata(hdmi_ctl_wdata[255:224]),
        .s_axi_a_wstrb(hdmi_ctl_wstrb[31:28]),
        .s_axi_a_wvalid(hdmi_ctl_wvalid[7]),
        .s_axi_a_wready(hdmi_ctl_wready[7]),
        .s_axi_a_bresp(hdmi_ctl_bresp[15:14]),
        .s_axi_a_bvalid(hdmi_ctl_bvalid[7]),
        .s_axi_a_bready(hdmi_ctl_bready[7]),
        .s_axi_a_araddr(hdmi_ctl_araddr[255:224]),
        .s_axi_a_arvalid(hdmi_ctl_arvalid[7]),
        .s_axi_a_arready(hdmi_ctl_arready[7]),
        .s_axi_a_rdata(hdmi_ctl_rdata[255:224]),
        .s_axi_a_rresp(hdmi_ctl_rresp[15:14]),
        .s_axi_a_rvalid(hdmi_ctl_rvalid[7]),
        .s_axi_a_rready(hdmi_ctl_rready[7]),
        // Plane B control: axi_crossbar_hdmi M08, 0xB0090000.
        .s_axi_b_awaddr(hdmi_ctl_awaddr[287:256]),
        .s_axi_b_awvalid(hdmi_ctl_awvalid[8]),
        .s_axi_b_awready(hdmi_ctl_awready[8]),
        .s_axi_b_wdata(hdmi_ctl_wdata[287:256]),
        .s_axi_b_wstrb(hdmi_ctl_wstrb[35:32]),
        .s_axi_b_wvalid(hdmi_ctl_wvalid[8]),
        .s_axi_b_wready(hdmi_ctl_wready[8]),
        .s_axi_b_bresp(hdmi_ctl_bresp[17:16]),
        .s_axi_b_bvalid(hdmi_ctl_bvalid[8]),
        .s_axi_b_bready(hdmi_ctl_bready[8]),
        .s_axi_b_araddr(hdmi_ctl_araddr[287:256]),
        .s_axi_b_arvalid(hdmi_ctl_arvalid[8]),
        .s_axi_b_arready(hdmi_ctl_arready[8]),
        .s_axi_b_rdata(hdmi_ctl_rdata[287:256]),
        .s_axi_b_rresp(hdmi_ctl_rresp[17:16]),
        .s_axi_b_rvalid(hdmi_ctl_rvalid[8]),
        .s_axi_b_rready(hdmi_ctl_rready[8]),
        // Plane A read master: merged into S_AXI_HP1_FPD (read-only).
        .a_araddr(disp_araddr), .a_arlen(disp_arlen),
        .a_arsize(disp_arsize), .a_arburst(disp_arburst),
        .a_arvalid(disp_arvalid), .a_arready(disp_arready),
        .a_rdata(disp_rdata), .a_rresp(disp_rresp),
        .a_rlast(disp_rlast), .a_rvalid(disp_rvalid), .a_rready(disp_rready),
        // Plane B read master: the new S_AXI_HP2_FPD read channel.
        .b_araddr(rd_b_araddr), .b_arlen(rd_b_arlen),
        .b_arsize(rd_b_arsize), .b_arburst(rd_b_arburst),
        .b_arvalid(rd_b_arvalid), .b_arready(rd_b_arready),
        .b_rdata(rd_b_rdata), .b_rresp(rd_b_rresp),
        .b_rlast(rd_b_rlast), .b_rvalid(rd_b_rvalid), .b_rready(rd_b_rready),
        .blend_enable(blend_enable),
        .alpha_force_opaque(alpha_force_opaque),
        .blend_unlock(blend_unlock),
        .ovl_slot_ready_m(ovl_wr_slot_ready_m),
        .ovl_last_slot_m(ovl_wr_last_slot_m),
        .ovl_slot_bytes_m(ovl_wr_slot_bytes_m),
        .ovl_hw_auto_slot(ovl_hw_auto_slot),
        .ovl_slot_release_m(ovl_wr_slot_release_m),
        .s_o_axis_tdata(ovl_direct_tdata),
        .s_o_axis_tvalid(ovl_direct_tvalid),
        .s_o_axis_tready(ovl_direct_tready),
        .s_o_axis_tlast(ovl_direct_tlast),
        .s_o_axis_tuser(ovl_direct_tuser),
        .base_vblank_p(ovl_base_vblank_p),
        .m_axis_video_tdata(disp_video_tdata),
        .m_axis_video_tvalid(disp_video_tvalid),
        .m_axis_video_tready(disp_video_tready),
        .m_axis_video_tlast(disp_video_tlast),
        .m_axis_video_tuser(disp_video_tuser),
        .irq_a(comp_irq_a), .irq_b(comp_irq_b),
        .blend_locked(blend_locked), .blend_busy(blend_busy),
        .blend_lock_lost(blend_lock_lost),
        .blend_sat_watchdog(blend_sat_watchdog),
        .blend_beats(blend_beats),
        .blend_gl_state(blend_gl_state),
        .blend_drop_reason(blend_drop_reason),
        .blend_lock_count(blend_lock_count),
        .blend_base_passthru(blend_base_passthru));

    sc7f0_rgb_overlay_ctrl u_overlay_ctrl (
        .csr_clk(pl_clk0),      .csr_rst_n(sys_100m_rst_n),
        .pcie_clk(pcie_user_clk), .pcie_rst_n(pcie_user_rst_n),
        .mem_clk(capture_clk),  .mem_rst_n(dp_mem_rst_n),
        // axi_crossbar_hdmi M09, 0xB00A0000.
        .s_axi_awaddr(hdmi_ctl_awaddr[319:288]),
        .s_axi_awvalid(hdmi_ctl_awvalid[9]),
        .s_axi_awready(hdmi_ctl_awready[9]),
        .s_axi_wdata(hdmi_ctl_wdata[319:288]),
        .s_axi_wstrb(hdmi_ctl_wstrb[39:36]),
        .s_axi_wvalid(hdmi_ctl_wvalid[9]),
        .s_axi_wready(hdmi_ctl_wready[9]),
        .s_axi_bresp(hdmi_ctl_bresp[19:18]),
        .s_axi_bvalid(hdmi_ctl_bvalid[9]),
        .s_axi_bready(hdmi_ctl_bready[9]),
        .s_axi_araddr(hdmi_ctl_araddr[319:288]),
        .s_axi_arvalid(hdmi_ctl_arvalid[9]),
        .s_axi_arready(hdmi_ctl_arready[9]),
        .s_axi_rdata(hdmi_ctl_rdata[319:288]),
        .s_axi_rresp(hdmi_ctl_rresp[19:18]),
        .s_axi_rvalid(hdmi_ctl_rvalid[9]),
        .s_axi_rready(hdmi_ctl_rready[9]),
        .s_axil_pcie_awaddr(bar0_ovl_awaddr),
        .s_axil_pcie_awvalid(bar0_ovl_awvalid),
        .s_axil_pcie_awready(bar0_ovl_awready),
        .s_axil_pcie_wdata(bar0_ovl_wdata),
        .s_axil_pcie_wstrb(bar0_ovl_wstrb),
        .s_axil_pcie_wvalid(bar0_ovl_wvalid),
        .s_axil_pcie_wready(bar0_ovl_wready),
        .s_axil_pcie_bresp(bar0_ovl_bresp),
        .s_axil_pcie_bvalid(bar0_ovl_bvalid),
        .s_axil_pcie_bready(bar0_ovl_bready),
        .s_axil_pcie_araddr(bar0_ovl_araddr),
        .s_axil_pcie_arvalid(bar0_ovl_arvalid),
        .s_axil_pcie_arready(bar0_ovl_arready),
        .s_axil_pcie_rdata(bar0_ovl_rdata),
        .s_axil_pcie_rresp(bar0_ovl_rresp),
        .s_axil_pcie_rvalid(bar0_ovl_rvalid),
        .s_axil_pcie_rready(bar0_ovl_rready),
        .wr_auto_advance_m(ovl_hw_auto_slot),
        .rx_passthrough(rx_passthrough),
        .ovl_enable(ovl_ctrl_enable),
        .ovl_src_addr(ovl_ctrl_src_addr),
        .ovl_xfer_bytes(ovl_ctrl_xfer_bytes),
        .ovl_max_bytes_per_req(ovl_ctrl_max_bytes_per_req),
        .ovl_go(ovl_ctrl_go),
        .ovl_quiesce_req(ovl_ctrl_quiesce_req),
        .ovl_discard_pending(ovl_ctrl_discard_pending),
        .ovl_bytes_issued(ovl_status_bytes_issued),
        .ovl_bytes_staged(ovl_status_bytes_staged),
        .ovl_bytes_drained(ovl_status_bytes_drained),
        .ovl_outstanding(ovl_status_outstanding),
        .ovl_busy(ovl_status_busy),
        .ovl_quiesced(ovl_status_quiesced),
        .ovl_quarantined(ovl_status_quarantined),
        .ovl_ext_tag_blocked(ovl_status_ext_tag_blocked),
        .ovl_counts(ovl_status_counts),
        .ovl_done_pulse(ovl_wr_irq_pulse),
        .ovl_abort_req(ovl_ctrl_abort_req),
        .wr_abort_busy(ovl_wr_abort_busy),
        .wr_err_frames(ovl_wr_err_frames),
        .video_guard_sticky(ovl_video_guard_sticky),
        .video_guard_count(ovl_video_guard_count),
        .video_poison(ovl_video_poison),
        .wr_enable(ovl_ctrl_wr_enable),
        .wr_dst_base(ovl_ctrl_wr_dst_base),
        .wr_slot_bytes(ovl_ctrl_wr_slot_bytes),
        .wr_slot_count(ovl_ctrl_wr_slot_count),
        .wr_frame_bytes(ovl_ctrl_wr_frame_bytes),
        .wr_auto_advance(ovl_ctrl_wr_auto_advance),
        .wr_force_slot(ovl_ctrl_wr_force_slot),
        .wr_consume(ovl_ctrl_wr_consume),
        .wr_slot_ready(ovl_wr_slot_ready),
        .wr_busy(ovl_wr_busy),
        .wr_active_slot(ovl_wr_active_slot),
        .wr_frames_done(ovl_wr_frames_done),
        .wr_bytes_written(ovl_wr_bytes_written),
        .wr_sticky(ovl_wr_sticky),
        .wr_axi_dbg(ovl_axi_dbg),
        .wr_irq_pulse(ovl_wr_irq_pulse),
        .blend_enable(blend_enable),
        .alpha_force_opaque(alpha_force_opaque),
        .blend_unlock(blend_unlock),
        .reader_b_reset(reader_b_reset),
        .blend_locked(blend_locked), .blend_busy(blend_busy),
        .blend_lock_lost(blend_lock_lost),
        .blend_sat_watchdog(blend_sat_watchdog),
        .blend_beats(blend_beats),
        .blend_gl_seeking(blend_gl_seeking),
        .blend_gl_wait_vsof(blend_gl_wait_vsof),
        .blend_gl_lock_state(blend_gl_lock_state),
        .blend_gl_drop_reason(blend_drop_reason),
        .blend_gl_lock_count(blend_lock_count),
        .blend_base_passthru(blend_base_passthru));
`else
    wire [95:0] disp_video_tdata;
    wire        disp_video_tvalid,disp_video_tready,disp_video_tlast,disp_video_tuser;

    sc7f0_display_pipeline u_display_pipeline (
        .csr_clk(pl_clk0),           .csr_rst_n(sys_100m_rst_n),
        .mem_clk(capture_clk),       .mem_rst_n(dp_mem_rst_n),
        .reader_rst_n(display_reader_rst_n),
        .tx_clk(phy_tx_video_clk),   .tx_rst_n(!tx_video_rst),
        // axi_crossbar_hdmi M07, 0xB0080000 (32-bit slice 7 of the vector).
        .s_axi_ctrl_awaddr(hdmi_ctl_awaddr[255:224]),
        .s_axi_ctrl_awvalid(hdmi_ctl_awvalid[7]),
        .s_axi_ctrl_awready(hdmi_ctl_awready[7]),
        .s_axi_ctrl_wdata(hdmi_ctl_wdata[255:224]),
        .s_axi_ctrl_wstrb(hdmi_ctl_wstrb[31:28]),
        .s_axi_ctrl_wvalid(hdmi_ctl_wvalid[7]),
        .s_axi_ctrl_wready(hdmi_ctl_wready[7]),
        .s_axi_ctrl_bresp(hdmi_ctl_bresp[15:14]),
        .s_axi_ctrl_bvalid(hdmi_ctl_bvalid[7]),
        .s_axi_ctrl_bready(hdmi_ctl_bready[7]),
        .s_axi_ctrl_araddr(hdmi_ctl_araddr[255:224]),
        .s_axi_ctrl_arvalid(hdmi_ctl_arvalid[7]),
        .s_axi_ctrl_arready(hdmi_ctl_arready[7]),
        .s_axi_ctrl_rdata(hdmi_ctl_rdata[255:224]),
        .s_axi_ctrl_rresp(hdmi_ctl_rresp[15:14]),
        .s_axi_ctrl_rvalid(hdmi_ctl_rvalid[7]),
        .s_axi_ctrl_rready(hdmi_ctl_rready[7]),
        // 128-bit read-only master into S_AXI_HP1_FPD (300 MHz domain).
        .araddr(disp_araddr),.arlen(disp_arlen),.arsize(disp_arsize),
        .arburst(disp_arburst),.arvalid(disp_arvalid),.arready(disp_arready),
        .rdata(disp_rdata),.rresp(disp_rresp),.rlast(disp_rlast),
        .rvalid(disp_rvalid),.rready(disp_rready),
        .m_axis_video_tdata(disp_video_tdata),
        .m_axis_video_tvalid(disp_video_tvalid),
        .m_axis_video_tready(disp_video_tready),
        .m_axis_video_tlast(disp_video_tlast),
        .m_axis_video_tuser(disp_video_tuser),
        .irq(display_frmbuf_irq)
    );
`endif

    // Single-source use of the reviewed frame-locked selector: 01 selects the
    // framebuffer reader and never moves, so the TX only ever sees whole frames
    // that start on a real SOF.  The two unused sources are inert (tvalid 0) and
    // DRAIN_UNSELECTED is off because nothing drives them.
    sc7f0_hdmi_tx_mux #(
`ifdef SC7F0_RGB_COMPOSITOR
        .TDATA_WIDTH(48),          // 2 PPC composited native RGB
`else
        .TDATA_WIDTH(96),
`endif
        .DRAIN_UNSELECTED(0),
        .SEL_STABLE_CYCLES(8),
        .STALL_LIMIT(1048576)
    ) u_hdmi_tx_mux (
        .clk(phy_tx_video_clk),
        .rst_n(!tx_video_rst),
        .mux_sel(2'b01),
        .s0_axis_video_tdata(
`ifdef SC7F0_RGB_COMPOSITOR
            48'd0),
`else
            96'd0),
`endif
            .s0_axis_video_tvalid(1'b0),
        .s0_axis_video_tready(), .s0_axis_video_tlast(1'b0), .s0_axis_video_tuser(1'b0),
        .s1_axis_video_tdata(disp_video_tdata), .s1_axis_video_tvalid(disp_video_tvalid),
        .s1_axis_video_tready(disp_video_tready), .s1_axis_video_tlast(disp_video_tlast),
        .s1_axis_video_tuser(disp_video_tuser),
        .s2_axis_video_tdata(
`ifdef SC7F0_RGB_COMPOSITOR
            48'd0),
`else
            96'd0),
`endif
            .s2_axis_video_tvalid(1'b0),
        .s2_axis_video_tready(), .s2_axis_video_tlast(1'b0), .s2_axis_video_tuser(1'b0),
        .m_axis_video_tdata(tx_ss_video_tdata),
        .m_axis_video_tvalid(tx_ss_video_tvalid),
        .m_axis_video_tready(tx_ss_video_tready),
        .m_axis_video_tlast(tx_ss_video_tlast),
        .m_axis_video_tuser(tx_ss_video_tuser)
    );

`ifdef SC7F0_RGB_COMPOSITOR
    // ------------------------------------------------------------------------
    // G8: HDMI TX subsystem control merge (26111602).
    //
    // v_hdmi_tx_ss keeps its VTC at +0x10000, so software must see one
    // contiguous 128 KiB aperture (the driver derives VTC = base + 0x10000 from a
    // single reg).  The 26111601 bitstream published that aperture as one 17-bit
    // crossbar slice, and on hardware every access with address bit 16 set died
    // with DECERR (synchronous external abort / SIGBUS) while the TX core aliased
    // every 2 KiB.  The deployed routed design shows a single crossbar-carried
    // bit 16 cannot be trusted here: the read-channel bit is connected
    // (u_hdmi_control/m_axi_araddr[80] -> u_hdmi_tx_ss/S_AXI_CPU_IN_araddr[16] ->
    // inner crossbar -> inst/v_tc/s_axi_araddr[0]) while the write-channel bit has
    // no net at all at the subsystem boundary (m_axi_awaddr[80] and
    // S_AXI_CPU_IN_awaddr[16] both report no net), so a VTC write could never have
    // selected the VTC segment.  Evidence:
    //   build/g6g8-20261116T110140Z/tx-ss-slice2-readprobe.txt
    //   build/g6g8-20261116T110140Z/netlist-probe/probe*.log (routed + IP DCP)
    //   tb/tb_sc7f0_hdmi_xbar_addr_map.v (gate-level crossbar decode simulation)
    //
    // Fix: the crossbar now decodes two 64 KiB slices -- the window class that is
    // proven good on this card (RX SS, frame tap, frmbuf, overlay) -- and this
    // lock-safe 2:1 AXI4-Lite merge drives subsystem address bit 16 from the slice
    // index: slice 2 (0xB0020000) -> bit16 = 0 selects the TX core, slice 10
    // (0xB0030000) -> bit16 = 1 selects the VTC.  No other address bit changes, so
    // the PS still sees 0xB0020000..0xB003FFFF as one contiguous aperture and the
    // driver/device-tree contract is untouched.
    // ------------------------------------------------------------------------
    wire [16:0] txss_ctl_awaddr, txss_ctl_araddr;
    wire        txss_ctl_awvalid, txss_ctl_awready, txss_ctl_wvalid, txss_ctl_wready;
    wire        txss_ctl_bvalid, txss_ctl_bready, txss_ctl_arvalid, txss_ctl_arready;
    wire        txss_ctl_rvalid, txss_ctl_rready;
    wire [31:0] txss_ctl_wdata, txss_ctl_rdata;
    wire [3:0]  txss_ctl_wstrb;
    wire [1:0]  txss_ctl_bresp, txss_ctl_rresp;

    sc7f0_axil_merge_2to1 #(.ADDR_WIDTH(17), .DATA_WIDTH(32)) u_hdmi_tx_ctl_merge (
        .clk(pl_clk0), .rst_n(sys_100m_rst_n),
        // S0 = slice 2,  0xB0020000..0xB002FFFF -> subsystem address bit16 = 0
        .s0_axil_awaddr ({1'b0, hdmi_ctl_awaddr[79:64]}),
        .s0_axil_awvalid(hdmi_ctl_awvalid[2]),
        .s0_axil_awready(hdmi_ctl_awready[2]),
        .s0_axil_wdata  (hdmi_ctl_wdata[95:64]),
        .s0_axil_wstrb  (hdmi_ctl_wstrb[11:8]),
        .s0_axil_wvalid (hdmi_ctl_wvalid[2]),
        .s0_axil_wready (hdmi_ctl_wready[2]),
        .s0_axil_bresp  (hdmi_ctl_bresp[5:4]),
        .s0_axil_bvalid (hdmi_ctl_bvalid[2]),
        .s0_axil_bready (hdmi_ctl_bready[2]),
        .s0_axil_araddr ({1'b0, hdmi_ctl_araddr[79:64]}),
        .s0_axil_arvalid(hdmi_ctl_arvalid[2]),
        .s0_axil_arready(hdmi_ctl_arready[2]),
        .s0_axil_rdata  (hdmi_ctl_rdata[95:64]),
        .s0_axil_rresp  (hdmi_ctl_rresp[5:4]),
        .s0_axil_rvalid (hdmi_ctl_rvalid[2]),
        .s0_axil_rready (hdmi_ctl_rready[2]),
        // S1 = slice 10, 0xB0030000..0xB003FFFF -> subsystem address bit16 = 1
        .s1_axil_awaddr ({1'b1, hdmi_ctl_awaddr[335:320]}),
        .s1_axil_awvalid(hdmi_ctl_awvalid[10]),
        .s1_axil_awready(hdmi_ctl_awready[10]),
        .s1_axil_wdata  (hdmi_ctl_wdata[351:320]),
        .s1_axil_wstrb  (hdmi_ctl_wstrb[43:40]),
        .s1_axil_wvalid (hdmi_ctl_wvalid[10]),
        .s1_axil_wready (hdmi_ctl_wready[10]),
        .s1_axil_bresp  (hdmi_ctl_bresp[21:20]),
        .s1_axil_bvalid (hdmi_ctl_bvalid[10]),
        .s1_axil_bready (hdmi_ctl_bready[10]),
        .s1_axil_araddr ({1'b1, hdmi_ctl_araddr[335:320]}),
        .s1_axil_arvalid(hdmi_ctl_arvalid[10]),
        .s1_axil_arready(hdmi_ctl_arready[10]),
        .s1_axil_rdata  (hdmi_ctl_rdata[351:320]),
        .s1_axil_rresp  (hdmi_ctl_rresp[21:20]),
        .s1_axil_rvalid (hdmi_ctl_rvalid[10]),
        .s1_axil_rready (hdmi_ctl_rready[10]),
        // M = the subsystem's single control port, 17-bit address
        .m_axil_awaddr  (txss_ctl_awaddr),
        .m_axil_awvalid (txss_ctl_awvalid),
        .m_axil_awready (txss_ctl_awready),
        .m_axil_wdata   (txss_ctl_wdata),
        .m_axil_wstrb   (txss_ctl_wstrb),
        .m_axil_wvalid  (txss_ctl_wvalid),
        .m_axil_wready  (txss_ctl_wready),
        .m_axil_bresp   (txss_ctl_bresp),
        .m_axil_bvalid  (txss_ctl_bvalid),
        .m_axil_bready  (txss_ctl_bready),
        .m_axil_araddr  (txss_ctl_araddr),
        .m_axil_arvalid (txss_ctl_arvalid),
        .m_axil_arready (txss_ctl_arready),
        .m_axil_rdata   (txss_ctl_rdata),
        .m_axil_rresp   (txss_ctl_rresp),
        .m_axil_rvalid  (txss_ctl_rvalid),
        .m_axil_rready  (txss_ctl_rready)
    );

    v_hdmi_tx_ss_rgb u_hdmi_tx_ss (
`else
    v_hdmi_tx_ss_0 u_hdmi_tx_ss (
`endif
        .s_axi_cpu_aclk        (pl_clk0),
        .s_axi_cpu_aresetn     (sys_100m_rst_n),
        .link_clk              (phy_txoutclk),
        // No audio formatter in this personality and xlnx,audio-enabled is
        // absent from DT, so the audio slave is quiesced, not routed.
        .s_axis_audio_aclk     (pcie_user_clk),
        .s_axis_audio_aresetn  (pcie_user_rst_n),
        .acr_cts               (20'd148500),
        .acr_n                 (20'd6144),
        .acr_valid             (1'b0),
        .hpd                   (hdmi_tx_hpd_in),
        .irq                   (hdmi_tx_irq),
        .video_clk             (phy_tx_video_clk),
        .fid                   (1'b0),
        .locked                (tx_ss_locked),
        .s_axis_video_aclk     (phy_tx_video_clk),
        .s_axis_video_aresetn  (!tx_video_rst),
        .VIDEO_IN_tdata        (tx_ss_video_tdata),
        .VIDEO_IN_tlast        (tx_ss_video_tlast),
        .VIDEO_IN_tready       (tx_ss_video_tready),
        .VIDEO_IN_tuser        (tx_ss_video_tuser),
        .VIDEO_IN_tvalid       (tx_ss_video_tvalid),
        .SB_STATUS_IN_tdata    (phy_status_sb_tx_tdata),
        .SB_STATUS_IN_tvalid   (phy_status_sb_tx_tvalid),
        .AUDIO_IN_tdata        (32'd0),
        .AUDIO_IN_tid          (8'd0),
        .AUDIO_IN_tready       (),
        .AUDIO_IN_tvalid       (1'b0),
        // SC7F0_RGB_COMPOSITOR: two 64 KiB crossbar slices merged by
        // u_hdmi_tx_ctl_merge, which drives subsystem address bit 16 (0 = TX core
        // at +0x00000, 1 = VTC at +0x10000).  Other personalities keep the
        // original single slice-2 connection.
`ifdef SC7F0_RGB_COMPOSITOR
        .S_AXI_CPU_IN_araddr   (txss_ctl_araddr),
        .S_AXI_CPU_IN_arprot   (3'd0),
        .S_AXI_CPU_IN_arready  (txss_ctl_arready),
        .S_AXI_CPU_IN_arvalid  (txss_ctl_arvalid),
        .S_AXI_CPU_IN_awaddr   (txss_ctl_awaddr),
        .S_AXI_CPU_IN_awprot   (3'd0),
        .S_AXI_CPU_IN_awready  (txss_ctl_awready),
        .S_AXI_CPU_IN_awvalid  (txss_ctl_awvalid),
        .S_AXI_CPU_IN_bready   (txss_ctl_bready),
        .S_AXI_CPU_IN_bresp    (txss_ctl_bresp),
        .S_AXI_CPU_IN_bvalid   (txss_ctl_bvalid),
        .S_AXI_CPU_IN_rdata    (txss_ctl_rdata),
        .S_AXI_CPU_IN_rready   (txss_ctl_rready),
        .S_AXI_CPU_IN_rresp    (txss_ctl_rresp),
        .S_AXI_CPU_IN_rvalid   (txss_ctl_rvalid),
        .S_AXI_CPU_IN_wdata    (txss_ctl_wdata),
        .S_AXI_CPU_IN_wready   (txss_ctl_wready),
        .S_AXI_CPU_IN_wstrb    (txss_ctl_wstrb),
        .S_AXI_CPU_IN_wvalid   (txss_ctl_wvalid),
`else
        .S_AXI_CPU_IN_araddr   (hdmi_ctl_araddr[80:64]),
        .S_AXI_CPU_IN_arprot   (3'd0),
        .S_AXI_CPU_IN_arready  (hdmi_ctl_arready[2]),
        .S_AXI_CPU_IN_arvalid  (hdmi_ctl_arvalid[2]),
        .S_AXI_CPU_IN_awaddr   (hdmi_ctl_awaddr[80:64]),
        .S_AXI_CPU_IN_awprot   (3'd0),
        .S_AXI_CPU_IN_awready  (hdmi_ctl_awready[2]),
        .S_AXI_CPU_IN_awvalid  (hdmi_ctl_awvalid[2]),
        .S_AXI_CPU_IN_bready   (hdmi_ctl_bready[2]),
        .S_AXI_CPU_IN_bresp    (hdmi_ctl_bresp[5:4]),
        .S_AXI_CPU_IN_bvalid   (hdmi_ctl_bvalid[2]),
        .S_AXI_CPU_IN_rdata    (hdmi_ctl_rdata[95:64]),
        .S_AXI_CPU_IN_rready   (hdmi_ctl_rready[2]),
        .S_AXI_CPU_IN_rresp    (hdmi_ctl_rresp[5:4]),
        .S_AXI_CPU_IN_rvalid   (hdmi_ctl_rvalid[2]),
        .S_AXI_CPU_IN_wdata    (hdmi_ctl_wdata[95:64]),
        .S_AXI_CPU_IN_wready   (hdmi_ctl_wready[2]),
        .S_AXI_CPU_IN_wstrb    (hdmi_ctl_wstrb[11:8]),
        .S_AXI_CPU_IN_wvalid   (hdmi_ctl_wvalid[2]),
`endif
        .DDC_OUT_scl_i         (tx_ddc_scl_i),
        .DDC_OUT_scl_o         (tx_ddc_scl_o),
        .DDC_OUT_scl_t         (tx_ddc_scl_t),
        .DDC_OUT_sda_i         (tx_ddc_sda_i),
        .DDC_OUT_sda_o         (tx_ddc_sda_o),
        .DDC_OUT_sda_t         (tx_ddc_sda_t),
        .LINK_DATA0_OUT_tdata  (phy_tx_axi4s_ch0_tdata),
        .LINK_DATA0_OUT_tvalid (phy_tx_axi4s_ch0_tvalid),
        .LINK_DATA1_OUT_tdata  (phy_tx_axi4s_ch1_tdata),
        .LINK_DATA1_OUT_tvalid (phy_tx_axi4s_ch1_tvalid),
        .LINK_DATA2_OUT_tdata  (phy_tx_axi4s_ch2_tdata),
        .LINK_DATA2_OUT_tvalid (phy_tx_axi4s_ch2_tvalid)
    );

    // BAR0 TX readback and the BAR1 channel-1 streams keep the values the
    // deployed C2H image reports: the display path is not a PCIe video channel.
    assign hdmi_tx_status_w = 32'd0;
    assign m_video_tready[1] = 1'b1;
    assign m_audio_tready[1] = 1'b1;
`else
`ifndef SC7F0_C2H_ONLY
    v_hdmi_tx_ss_0 u_hdmi_tx_ss (
        .s_axi_cpu_aclk        (pl_clk0),
        .s_axi_cpu_aresetn     (sys_100m_rst_n),
        .link_clk              (phy_txoutclk),
        .s_axis_audio_aclk     (pcie_user_clk),
        .s_axis_audio_aresetn  (pcie_user_rst_n),
        .acr_cts               (20'd148500),
        .acr_n                 (20'd6144),
        .acr_valid             (1'b1),
        .hpd                   (hdmi_tx_hpd_in),
        .irq                   (),
        .video_clk             (phy_tx_video_clk),
        .fid                   (1'b0),
        .locked                (tx_ss_locked),
        .s_axis_video_aclk     (phy_tx_video_clk),
        .s_axis_video_aresetn  (!tx_video_rst),
        .VIDEO_IN_tdata        (tx_ss_video_tdata),
        .VIDEO_IN_tlast        (tx_ss_video_tlast),
        .VIDEO_IN_tready       (tx_ss_video_tready),
        .VIDEO_IN_tuser        (tx_ss_video_tuser),
        .VIDEO_IN_tvalid       (tx_ss_video_tvalid),
        .SB_STATUS_IN_tdata    (phy_status_sb_tx_tdata),
        .SB_STATUS_IN_tvalid   (phy_status_sb_tx_tvalid),
        .AUDIO_IN_tdata        (tx_ss_audio_tdata),
        .AUDIO_IN_tid          (8'd0),
        .AUDIO_IN_tready       (tx_ss_audio_tready),
        .AUDIO_IN_tvalid       (tx_ss_audio_tvalid),
        .S_AXI_CPU_IN_araddr   (hdmi_ctl_araddr[80:64]),
        .S_AXI_CPU_IN_arprot   (3'd0),
        .S_AXI_CPU_IN_arready  (hdmi_ctl_arready[2]),
        .S_AXI_CPU_IN_arvalid  (hdmi_ctl_arvalid[2]),
        .S_AXI_CPU_IN_awaddr   (hdmi_ctl_awaddr[80:64]),
        .S_AXI_CPU_IN_awprot   (3'd0),
        .S_AXI_CPU_IN_awready  (hdmi_ctl_awready[2]),
        .S_AXI_CPU_IN_awvalid  (hdmi_ctl_awvalid[2]),
        .S_AXI_CPU_IN_bready   (hdmi_ctl_bready[2]),
        .S_AXI_CPU_IN_bresp    (hdmi_ctl_bresp[5:4]),
        .S_AXI_CPU_IN_bvalid   (hdmi_ctl_bvalid[2]),
        .S_AXI_CPU_IN_rdata    (hdmi_ctl_rdata[95:64]),
        .S_AXI_CPU_IN_rready   (hdmi_ctl_rready[2]),
        .S_AXI_CPU_IN_rresp    (hdmi_ctl_rresp[5:4]),
        .S_AXI_CPU_IN_rvalid   (hdmi_ctl_rvalid[2]),
        .S_AXI_CPU_IN_wdata    (hdmi_ctl_wdata[95:64]),
        .S_AXI_CPU_IN_wready   (hdmi_ctl_wready[2]),
        .S_AXI_CPU_IN_wstrb    (hdmi_ctl_wstrb[11:8]),
        .S_AXI_CPU_IN_wvalid   (hdmi_ctl_wvalid[2]),
        .DDC_OUT_scl_i         (tx_ddc_scl_i),
        .DDC_OUT_scl_o         (tx_ddc_scl_o),
        .DDC_OUT_scl_t         (tx_ddc_scl_t),
        .DDC_OUT_sda_i         (tx_ddc_sda_i),
        .DDC_OUT_sda_o         (tx_ddc_sda_o),
        .DDC_OUT_sda_t         (tx_ddc_sda_t),
        .LINK_DATA0_OUT_tdata  (phy_tx_axi4s_ch0_tdata),
        .LINK_DATA0_OUT_tvalid (phy_tx_axi4s_ch0_tvalid),
        .LINK_DATA1_OUT_tdata  (phy_tx_axi4s_ch1_tdata),
        .LINK_DATA1_OUT_tvalid (phy_tx_axi4s_ch1_tvalid),
        .LINK_DATA2_OUT_tdata  (phy_tx_axi4s_ch2_tdata),
        .LINK_DATA2_OUT_tvalid (phy_tx_axi4s_ch2_tvalid)
    );

    // Ch 1: HDMI TX Video Bridge
    hdmi_tx_video_bridge #(
        .FIFO_DEPTH(1024)
    ) u_hdmi_tx_video_bridge (
        .pcie_user_clk(pcie_user_clk),
        .pcie_user_rst_n(pcie_user_rst_n),
        .s_axis_video_tdata(m_video_tdata[255:128]),
        .s_axis_video_tvalid(m_video_tvalid[1]),
        .s_axis_video_tready(m_video_tready[1]),
        .s_axis_video_tlast(m_video_tlast[1]),
        .s_axis_video_tuser(m_video_tuser[1]),
        .tx_ctrl_reg(hdmi_tx_ctrl_w),
        .tx_video_clk(phy_tx_video_clk),
        .tx_video_rst_n(!tx_video_rst),
        .m_axis_video_tdata(tx_ss_video_tdata),
        .m_axis_video_tvalid(tx_ss_video_tvalid),
        .m_axis_video_tready(tx_ss_video_tready),
        .m_axis_video_tlast(tx_ss_video_tlast),
        .m_axis_video_tuser(tx_ss_video_tuser),
        .tx_hpd_in(hdmi_tx_hpd_in),
        .tx_status_reg(hdmi_tx_status_w)
    );

    // Ch 1: HDMI TX Audio Bridge
    hdmi_tx_audio_bridge #(
        .FIFO_DEPTH(512)
    ) u_hdmi_tx_audio_bridge (
        .pcie_user_clk(pcie_user_clk),
        .pcie_user_rst_n(pcie_user_rst_n),
        .s_axis_audio_tdata(m_audio_tdata[63:32]),
        .s_axis_audio_tvalid(m_audio_tvalid[1]),
        .s_axis_audio_tready(m_audio_tready[1]),
        .s_axis_audio_tlast(m_audio_tlast[1]),
        .tx_ctrl_reg(hdmi_tx_ctrl_w),
        .tx_audio_clk(pcie_user_clk),
        .tx_audio_rst_n(pcie_user_rst_n),
        .m_axis_audio_tdata(tx_ss_audio_tdata),
        .m_axis_audio_tvalid(tx_ss_audio_tvalid),
        .m_axis_audio_tready(tx_ss_audio_tready),
        .m_axis_audio_tlast(tx_ss_audio_tlast)
    );

`else
    // Shared PHY/refclks stay unchanged; TX protocol and bridges are absent.
    assign phy_tx_axi4s_ch0_tdata=0; assign phy_tx_axi4s_ch0_tvalid=0;
    assign phy_tx_axi4s_ch1_tdata=0; assign phy_tx_axi4s_ch1_tvalid=0;
    assign phy_tx_axi4s_ch2_tdata=0; assign phy_tx_axi4s_ch2_tvalid=0;
    assign tx_ddc_scl_o=0; assign tx_ddc_scl_t=1; assign tx_ddc_sda_o=0; assign tx_ddc_sda_t=1;
    assign hdmi_tx_status_w=0; assign m_video_tready[1]=1; assign m_audio_tready[1]=1;
    sc7f0_axil_disabled #(.ADDR_WIDTH(32)) u_disabled_hdmi_tx (.clk(pl_clk0), .rst_n(sys_100m_rst_n),
        .s_axil_awaddr(hdmi_ctl_awaddr[95:64]),
        .s_axil_awvalid(hdmi_ctl_awvalid[2]),
        .s_axil_awready(hdmi_ctl_awready[2]),
        .s_axil_wdata(hdmi_ctl_wdata[95:64]),
        .s_axil_wstrb(hdmi_ctl_wstrb[11:8]),
        .s_axil_wvalid(hdmi_ctl_wvalid[2]),
        .s_axil_wready(hdmi_ctl_wready[2]),
        .s_axil_bresp(hdmi_ctl_bresp[5:4]),
        .s_axil_bvalid(hdmi_ctl_bvalid[2]),
        .s_axil_bready(hdmi_ctl_bready[2]),
        .s_axil_araddr(hdmi_ctl_araddr[95:64]),
        .s_axil_arvalid(hdmi_ctl_arvalid[2]),
        .s_axil_arready(hdmi_ctl_arready[2]),
        .s_axil_rdata(hdmi_ctl_rdata[95:64]),
        .s_axil_rresp(hdmi_ctl_rresp[5:4]),
        .s_axil_rvalid(hdmi_ctl_rvalid[2]),
        .s_axil_rready(hdmi_ctl_rready[2])
    );
`endif
`endif

    // =========================================================================
    // SC7F0 Hardware Probing and Frequency Meter Module
    // =========================================================================
    sc7f0_hdmi_probe u_hdmi_probe (
        .clk(pl_clk0),
        .rst_n(sys_100m_rst_n),

        .clk_rx_mgtref(rx_mgtrefclk1_odiv2_bufg),
        .clk_dru_ref(dru_gtnorthrefclk1_odiv2_bufg),
        .clk_rxout(phy_rxoutclk),
        .clk_rx_video(phy_rx_video_clk),
        .clk_tx_mgtref(tx_mgtrefclk0_odiv2_bufg),
        .clk_txout(phy_txoutclk),
        .clk_tx_video(phy_tx_video_clk),

        .hdmi_rx_5v_det(hdmi_rx_5v_det),
        .hdmi_rx_hpd_out(hdmi_rx_hpd_out),
        .rx_ddc_scl_i(rx_ddc_scl_i),
        .rx_ddc_scl_o(rx_ddc_scl_o),
        .rx_ddc_scl_t(rx_ddc_scl_t),
        .rx_ddc_sda_i(rx_ddc_sda_i),
        .rx_ddc_sda_o(rx_ddc_sda_o),
        .rx_ddc_sda_t(rx_ddc_sda_t),

        .hdmi_tx_hpd_in(hdmi_tx_hpd_in),
        .hdmi_tx_refclk_rdy(hdmi_tx_refclk_rdy),
        .tx_ddc_scl_i(tx_ddc_scl_i),
        .tx_ddc_sda_i(tx_ddc_sda_i),

        .hdmi_phy_irq(hdmi_phy_irq),
        .hdmi_rx_irq(hdmi_rx_irq),

        .phy_status_sb_rx_tdata(phy_status_sb_rx_tdata),
        .phy_status_sb_rx_tvalid(phy_status_sb_rx_tvalid),
        .phy_rx_axi4s_ch0_tvalid(phy_rx_axi4s_ch0_tvalid),
        .phy_rx_axi4s_ch1_tvalid(phy_rx_axi4s_ch1_tvalid),
        .phy_rx_axi4s_ch2_tvalid(phy_rx_axi4s_ch2_tvalid),

        .rx_ss_video_tvalid(rx_ss_video_tvalid),
        .rx_ss_video_tuser(rx_ss_video_tuser),
        .rx_ss_video_tlast(rx_ss_video_tlast),
        .rx_ss_video_tready(rx_ss_video_tready),

        .probe_ctrl(probe_ctrl_w),

        .reg_probe_version(probe_version_w),
        .reg_probe_rx_clk_freq(probe_rx_clk_freq_w),
        .reg_probe_dru_clk_freq(probe_dru_clk_freq_w),
        .reg_probe_rxoutclk_freq(probe_rxoutclk_freq_w),
        .reg_probe_rx_video_clk_freq(probe_rx_video_clk_freq_w),
        .reg_probe_tx_clk_freq(probe_tx_clk_freq_w),
        .reg_probe_txoutclk_freq(probe_txoutclk_freq_w),
        .reg_probe_tx_video_clk_freq(probe_tx_video_clk_freq_w),
        .reg_probe_pins(probe_pins_w),
        .reg_probe_pulse_cnt1(probe_pulse_cnt1_w),
        .reg_probe_ddc_cnt(probe_ddc_cnt_w),
        .reg_probe_irq_cnt(probe_irq_cnt_w),
        .reg_probe_ch0_beats(probe_ch0_beats_w),
        .reg_probe_ch1_beats(probe_ch1_beats_w),
        .reg_probe_ch2_beats(probe_ch2_beats_w),
        .reg_probe_rx_video_sof(probe_rx_video_sof_w),
        .reg_probe_rx_video_eol(probe_rx_video_eol_w),
        .reg_probe_rx_video_pix(probe_rx_video_pix_w),
        .reg_probe_raw_rx_clk(probe_raw_rx_clk_w),
        .reg_probe_raw_dru_clk(probe_raw_dru_clk_w),
        .reg_probe_raw_rxoutclk(probe_raw_rxoutclk_w),
        .reg_probe_raw_rx_video_clk(probe_raw_rx_video_clk_w),
        .reg_probe_raw_refclk100(probe_raw_refclk100_w)
    );

`else
    // Debug-first build: no HDMI IP, GT, external reference clock or pin.
    // Keep the internal PCIe-clock TPG/loopback plumbing for DMA diagnostics.
    wire [127:0] hdmi_rx_v_tdata = 128'd0;
    wire hdmi_rx_v_tvalid = 1'b0, hdmi_rx_v_tlast = 1'b0, hdmi_rx_v_tuser = 1'b0;
    wire hdmi_rx_v_tready;
    wire [31:0] hdmi_rx_a_tdata = 32'd0;
    wire hdmi_rx_a_tvalid = 1'b0, hdmi_rx_a_tlast = 1'b0;
    wire hdmi_rx_a_tready;
    assign hdmi_rx_status_w = 32'd0;
    assign hdmi_rx_res_w = 32'd0;
    assign hdmi_rx_timing_w = 32'd0;
    assign hdmi_rx_audio_w = 32'd0;
    assign audio_rx_frames = 0;
    assign audio_rx_errors = 0;
    assign audio_rx_channels = 0;
    assign audio_rx_cs = 0;
    assign hdmi_tx_status_w = 32'd0;
    assign m_video_tready[1] = 1'b1;
    assign m_audio_tready[1] = 1'b1;

    assign probe_version_w = 32'd0;
    assign probe_rx_clk_freq_w = 32'd0;
    assign probe_dru_clk_freq_w = 32'd0;
    assign probe_rxoutclk_freq_w = 32'd0;
    assign probe_rx_video_clk_freq_w = 32'd0;
    assign probe_tx_clk_freq_w = 32'd0;
    assign probe_txoutclk_freq_w = 32'd0;
    assign probe_tx_video_clk_freq_w = 32'd0;
    assign probe_pins_w = 32'd0;
    assign probe_pulse_cnt1_w = 32'd0;
    assign probe_ddc_cnt_w = 32'd0;
    assign probe_irq_cnt_w = 32'd0;
    assign probe_ch0_beats_w = 32'd0;
    assign probe_ch1_beats_w = 32'd0;
    assign probe_ch2_beats_w = 32'd0;
    assign probe_rx_video_sof_w = 32'd0;
    assign probe_rx_video_eol_w = 32'd0;
    assign probe_rx_video_pix_w = 32'd0;
    assign probe_raw_rx_clk_w = 32'd0;
    assign probe_raw_dru_clk_w = 32'd0;
    assign probe_raw_rxoutclk_w = 32'd0;
    assign probe_raw_rx_video_clk_w = 32'd0;
    assign probe_raw_refclk100_w = 32'd0;
`endif

    // =========================================================================
    // Multi-Channel AXI4-Stream Audio Multiplexing:
    // Ch 0: HDMI RX (C2H)
    // Ch 1: HDMI TX (H2C)
    // Ch 2: Internal hardware loopback (H2C -> C2H)
    // Ch 3: Audio Pattern Generator -> C2H
    // =========================================================================
    wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0] s_audio_tdata;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tvalid;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tlast;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tready;

    // =========================================================================
    // Channel 0 Video Source Multiplexer (TPG vs HDMI RX)
    // vch0_ctrl_w[21:20]:
    //   2'b00 = Auto mode: fallback to TPG if no HDMI 5V detected; use HDMI RX if 5V detected.
    //   2'b01 = Force TPG.
    //   2'b10 = Force HDMI RX.
    // =========================================================================
    wire [31:0] vch0_ctrl_w;
`ifdef SC7F0_DEBUG_ONLY
    wire ch0_use_tpg = 1'b1;
`elsif SC7F0_C2H_ONLY
    wire ch0_use_tpg = 1'b0;
`else
    wire ch0_use_tpg = (vch0_ctrl_w[21:20] == 2'b01) ||
                       (!sync_5v_det_q[1] && (vch0_ctrl_w[21:20] != 2'b10));
`endif

    // Source changes are allowed only while stopped. Audio retains the
    // PCIe-domain selector; video gets its own synchronized selector.
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_capture_source (
        .src_clk(pcie_user_clk), .src_in(ch0_use_tpg),
        .dest_clk(capture_clk), .dest_out(capture_use_tpg));
    wire [127:0] tpg_cdc_data;
    wire tpg_cdc_valid, tpg_cdc_sof, tpg_cdc_eol, tpg_cdc_ready;
`ifndef SC7F0_C2H_ONLY
    video_axis_async_fifo #(.DEPTH(32), .MEMORY_TYPE("distributed")) u_tpg_video_cdc (
        .s_clk(pcie_user_clk), .s_rst_n(video_engine_rst_n),
        .s_data(tpg_capture_tdata), .s_valid(tpg_capture_tvalid),
        .s_sof(tpg_capture_tuser), .s_eol(tpg_capture_tlast),
        .s_ready(tpg_capture_tready),
        .m_clk(capture_clk), .m_rst_n(capture_rst_n),
        .m_data(tpg_cdc_data), .m_valid(tpg_cdc_valid),
        .m_sof(tpg_cdc_sof), .m_eol(tpg_cdc_eol), .m_ready(tpg_cdc_ready)
    );
`else
    assign tpg_capture_tready=1; assign tpg_cdc_data=0; assign tpg_cdc_valid=0;
    assign tpg_cdc_sof=0; assign tpg_cdc_eol=0;
`endif

`ifdef SC7F0_RGB_COMPOSITOR
    // Channel 0 of the dma top is the packed RGB24 payload in this personality
    // (rtl/sc7f0_rgb24_c2h_engine.v p_axis_*), still launched by the same thin
    // descriptor ring with format code 4'd1, so the host descriptor ABI, the
    // C2H byte-enable/completion semantics and the mailbox ABI are unchanged.
    wire [127:0] video_ch0_mux_tdata = rgb24_tdata;
    wire         video_ch0_mux_tuser = rgb24_tuser;
    wire         video_ch0_mux_tvalid = rgb24_tvalid;
    wire         video_ch0_mux_tlast  = 1'b0;   // line ends are inside the packer
    wire         video_ch0_mux_tready;
    assign       rgb24_tready = video_ch0_mux_tready;
`else
    wire [127:0] video_ch0_mux_tdata  = capture_use_tpg ? tpg_cdc_data  : hdmi_rx_v_tdata;
    wire         video_ch0_mux_tvalid = capture_use_tpg ? tpg_cdc_valid : hdmi_rx_v_tvalid;
    wire         video_ch0_mux_tlast  = capture_use_tpg ? tpg_cdc_eol   : hdmi_rx_v_tlast;
    wire         video_ch0_mux_tuser  = capture_use_tpg ? tpg_cdc_sof   : hdmi_rx_v_tuser;
    wire         video_ch0_mux_tready;
`endif
    assign tpg_cdc_ready = capture_use_tpg ? video_ch0_mux_tready : 1'b1;
    // Live TMDS cannot be backpressured. Drain unowned frames continuously;
    // the engine consumes/discards a partial raster until the next SOF.
    assign hdmi_rx_v_tready = (capture_use_tpg || !video_capture_active) ?
                             1'b1 : video_ch0_mux_tready;

    // =========================================================================
    // 4-Channel Dedicated Datapath Wiring:
    // =========================================================================
    // Channel 0 (HDMI RX / TPG mux):
`ifdef SC7F0_RGB_COMPOSITOR
    // Channel 0 carries the packed RGB24 payload instead of the legacy raw
    // video word, so s_axis_video ch0 is quiesced and the dma top's channel-0
    // engine (rtl/sc7f0_rgb24_c2h_engine.v) consumes video_ch0_* instead.
    assign s_video_tdata[127:0] = 128'd0;
    assign s_video_tvalid[0]    = 1'b0;
    assign s_video_tlast[0]     = 1'b0;
    assign s_video_tuser[0]     = 1'b0;
    assign m_video_tready[0]    = 1'b1;
`else
    assign s_video_tdata[127:0] = video_ch0_mux_tdata;
    assign s_video_tvalid[0]    = video_ch0_mux_tvalid;
    assign s_video_tlast[0]     = video_ch0_mux_tlast;
    assign s_video_tuser[0]     = video_ch0_mux_tuser;
    assign m_video_tready[0]    = 1'b1;
`endif

`ifdef SC7F0_C2H_ONLY
    assign s_audio_tdata[31:0]=hdmi_rx_a_tdata;
    assign s_audio_tvalid[0]=(audio_capture_control[4] || audio_capture_control[5]) && hdmi_rx_a_tvalid;
    assign s_audio_tlast[0]=hdmi_rx_a_tlast;
    assign hdmi_rx_a_tready=(audio_capture_control[4] || audio_capture_control[5]) ? s_audio_tready[0] : 1'b1;
    assign m_audio_tready[0]=1;
`else
    // ADEV0 CTRL[4] is independent of video: 0=legacy TPG raw, 1=HDMI PCM.
    assign s_audio_tdata[31:0] = (audio_capture_control[4] || audio_capture_control[5]) ? hdmi_rx_a_tdata : aud_pat_axis_tdata;
    assign s_audio_tvalid[0] = (audio_capture_control[4] || audio_capture_control[5]) ? hdmi_rx_a_tvalid : aud_pat_axis_tvalid;
    assign s_audio_tlast[0] = audio_capture_control[4] ? hdmi_rx_a_tlast : aud_pat_axis_tlast;
    assign hdmi_rx_a_tready = (audio_capture_control[4] || audio_capture_control[5]) ? s_audio_tready[0] : 1'b1;
    assign m_audio_tready[0]    = 1'b1;

`endif

    // Channel 1 (HDMI TX):
    assign s_video_tdata[255:128] = 128'd0;
    assign s_video_tvalid[1]      = 1'b0;
    assign s_video_tlast[1]       = 1'b0;
    assign s_video_tuser[1]       = 1'b0;

    assign s_audio_tdata[63:32]   = 32'd0;
    assign s_audio_tvalid[1]      = 1'b0;
    assign s_audio_tlast[1]       = 1'b0;

`ifdef SC7F0_C2H_ONLY
    assign s_video_tdata[511:256]=0;
    assign s_video_tvalid[3:2]=0; assign s_video_tlast[3:2]=0; assign s_video_tuser[3:2]=0;
    assign m_video_tready[3:2]=2'b11;
    assign s_audio_tdata[127:64]=0; assign s_audio_tvalid[3:2]=0; assign s_audio_tlast[3:2]=0;
    assign m_audio_tready[3:2]=2'b11; assign aud_pat_axis_tready=1;
`else
    // Channel 2 (Internal Hardware Loopback):
    assign s_video_tdata[383:256] = m_video_tdata[383:256];
    assign s_video_tvalid[2]      = m_video_tvalid[2];
    assign s_video_tlast[2]       = m_video_tlast[2];
    assign s_video_tuser[2]       = m_video_tuser[2];
    assign m_video_tready[2]      = s_video_tready[2];

    assign s_audio_tdata[95:64]   = m_audio_tdata[95:64];
    assign s_audio_tvalid[2]      = m_audio_tvalid[2];
    assign s_audio_tlast[2]       = m_audio_tlast[2];
    assign m_audio_tready[2]      = s_audio_tready[2];

    // Channel 3 (Internal TPG & Audio Pattern Generator):
    assign s_video_tdata[511:384] = tpg_capture_tdata;
    assign s_video_tvalid[3]      = tpg_capture_tvalid;
    assign s_video_tlast[3]       = tpg_capture_tlast;
    assign s_video_tuser[3]       = tpg_capture_tuser;
    assign m_video_tready[3]      = 1'b1;

    assign s_audio_tdata[127:96]  = aud_pat_axis_tdata;
    assign s_audio_tvalid[3]      = aud_pat_axis_tvalid;
    assign s_audio_tlast[3]       = aud_pat_axis_tlast;
    assign aud_pat_axis_tready = ((!audio_capture_control[4] && !audio_capture_control[5] && audio_capture_control[0]) ? s_audio_tready[0] : 1'b1);
    assign m_audio_tready[3]      = 1'b1;

    // =========================================================================
`endif
    // PCIe AXI-Stream CQ / CC / RQ / RC Wires (256-bit)
    // =========================================================================
    wire [PCIE_DATA_WIDTH-1:0] m_axis_cq_tdata;
    wire                       m_axis_cq_tvalid;
    wire                       m_axis_cq_tlast;
    wire [87:0]                m_axis_cq_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] m_axis_cq_tkeep;
    wire                       m_axis_cq_tready;

    wire [PCIE_DATA_WIDTH-1:0] s_axis_cc_tdata;
    wire                       s_axis_cc_tvalid;
    wire                       s_axis_cc_tlast;
    wire [32:0]                s_axis_cc_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] s_axis_cc_tkeep;
    wire [3:0]                 s_axis_cc_tready_vec;

    wire [PCIE_DATA_WIDTH-1:0] s_axis_rq_tdata;
    wire                       s_axis_rq_tvalid;
    wire                       s_axis_rq_tlast;
    wire [61:0]                s_axis_rq_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] s_axis_rq_tkeep;
    wire [3:0]                 s_axis_rq_tready_vec;

    wire [PCIE_DATA_WIDTH-1:0] m_axis_rc_tdata;
    wire                       m_axis_rc_tvalid;
    wire                       m_axis_rc_tlast;
    wire [74:0]                m_axis_rc_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] m_axis_rc_tkeep;
    wire                       m_axis_rc_tready;

    wire        cfg_phy_link_down;
    wire [1:0]  cfg_phy_link_status;
    wire [2:0]  cfg_negotiated_width;
    wire [1:0]  cfg_current_speed;
    wire [1:0]  cfg_max_payload;
    wire [2:0]  cfg_max_read_req;
    // Negotiated Extended Tag Field Enable (PCIe Device Control bit 7).  This is
    // a real dynamic config output of pcie4_uscale_plus, not a strappable and
    // not a constant: with it low the core may only ever issue tags [5:0], so
    // the overlay's private 64..127 pool does not exist and
    // sc7f0_overlay_ingress.v must not arm.  The legacy 0..63 path, the upgrade
    // path and the mailbox never look at it.
    wire        cfg_ext_tag_enable;
    wire [15:0] cfg_function_status;
    wire [5:0]  cfg_ltssm_state;
    wire [7:0]  cfg_bus_number;

    wire        cfg_interrupt_sent;
    wire [3:0]  cfg_interrupt_msi_enable;
    wire        cfg_interrupt_msi_sent;
    wire        cfg_interrupt_msi_fail;

    wire usr_irq_req, usr_irq_ack;

    // Interrupt generation (MSI or Legacy INTx)
    reg [31:0] msi_int_reg;
    reg [3:0]  legacy_int_reg;
    reg        irq_ack_reg;
    reg        msi_req_pending;
    reg [11:0] msi_watchdog;

    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n) begin
            msi_int_reg     <= 32'd0;
            legacy_int_reg  <= 4'd0;
            irq_ack_reg     <= 1'b0;
            msi_req_pending <= 1'b0;
            msi_watchdog    <= 12'd0;
        end else begin
            irq_ack_reg <= 1'b0;
            msi_int_reg <= 32'd0; // Ensure cfg_interrupt_msi_int is strictly a 1-clock-cycle pulse per PG213

            if (cfg_interrupt_msi_enable[0]) begin
                legacy_int_reg <= 4'd0;
                if (usr_irq_req && !msi_req_pending) begin
                    msi_int_reg     <= 32'h00000001; // Vector 0 (1-cycle pulse)
                    msi_req_pending <= 1'b1;
                    msi_watchdog    <= 12'd0;
                end else if (msi_req_pending) begin
                    msi_watchdog <= msi_watchdog + 1'b1;
                    if (cfg_interrupt_msi_sent || cfg_interrupt_msi_fail || msi_watchdog[11]) begin
                        msi_req_pending <= 1'b0;
                        irq_ack_reg     <= 1'b1;
                    end
                end
            end else begin
                msi_req_pending <= 1'b0;
                msi_watchdog    <= 12'd0;
                if (usr_irq_req && !legacy_int_reg[0]) begin
                    legacy_int_reg <= 4'b0001; // Assert INTA
                end else if (cfg_interrupt_sent) begin
                    legacy_int_reg <= 4'd0;
                    irq_ack_reg    <= 1'b1;
                end
            end
        end
    end

    assign usr_irq_ack = irq_ack_reg;

    // Differential Reference Clock Input Buffer (Bank 223)
    wire sys_clk;
    wire sys_clk_gt;
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_ibufds_gte4 (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .CEB(1'b0),
        .O(sys_clk_gt),
        .ODIV2(sys_clk)
    );

    // cfg_mgmt read-back wires for the extended-tag capability walk.  These are
    // declared here, before the PCIe core instance below, because u_pcie_ip connects
    // them (cfg_mgmt_addr / _function_number / _read / _read_data /
    // _read_write_done).  Declaring them after that instance made the analyzer see
    // an implicit 1-bit net first and then an explicit wide declaration, which is an
    // error and, worse, would have truncated ext_tag_mgmt_read_data to one bit.
    // ------------------------------------------------------------------------
    wire [9:0]  ext_tag_mgmt_addr;
    wire [7:0]  ext_tag_mgmt_func;
    wire        ext_tag_mgmt_read;
    wire [31:0] ext_tag_mgmt_read_data;
    wire        ext_tag_mgmt_done;

    // =========================================================================
    // AMD/Xilinx UltraScale+ Integrated PCIe Core (pcie4_uscale_plus_0)
    // Gen3 x4, 256-bit AXI-Stream, Tandem PCIe enabled
    // =========================================================================
    pcie4_uscale_plus_0 u_pcie_ip (
        .sys_clk                                   (sys_clk),
        .sys_clk_gt                                (sys_clk_gt),
        .sys_reset                                 (sys_rst_n),
        .phy_rdy_out                               (phy_ready),

        .user_clk                                  (pcie_user_clk),
        .user_reset                                (pcie_user_reset),
        .user_lnk_up                               (pcie_user_lnk_up),

        .pci_exp_txp                               (pci_exp_txp),
        .pci_exp_txn                               (pci_exp_txn),
        .pci_exp_rxp                               (pci_exp_rxp),
        .pci_exp_rxn                               (pci_exp_rxn),

        // CQ
        .m_axis_cq_tdata                           (m_axis_cq_tdata),
        .m_axis_cq_tvalid                          (m_axis_cq_tvalid),
        .m_axis_cq_tlast                           (m_axis_cq_tlast),
        .m_axis_cq_tuser                           (m_axis_cq_tuser),
        .m_axis_cq_tkeep                           (m_axis_cq_tkeep),
        .m_axis_cq_tready                          (m_axis_cq_tready),

        // CC
        .s_axis_cc_tdata                           (s_axis_cc_tdata),
        .s_axis_cc_tvalid                          (s_axis_cc_tvalid),
        .s_axis_cc_tlast                           (s_axis_cc_tlast),
        .s_axis_cc_tuser                           (s_axis_cc_tuser),
        .s_axis_cc_tkeep                           (s_axis_cc_tkeep),
        .s_axis_cc_tready                          (s_axis_cc_tready_vec),

        // RQ
        .s_axis_rq_tdata                           (s_axis_rq_tdata),
        .s_axis_rq_tvalid                          (s_axis_rq_tvalid),
        .s_axis_rq_tlast                           (s_axis_rq_tlast),
        .s_axis_rq_tuser                           (s_axis_rq_tuser),
        .s_axis_rq_tkeep                           (s_axis_rq_tkeep),
        .s_axis_rq_tready                          (s_axis_rq_tready_vec),

        // RC
        .m_axis_rc_tdata                           (m_axis_rc_tdata),
        .m_axis_rc_tvalid                          (m_axis_rc_tvalid),
        .m_axis_rc_tlast                           (m_axis_rc_tlast),
        .m_axis_rc_tuser                           (m_axis_rc_tuser),
        .m_axis_rc_tkeep                           (m_axis_rc_tkeep),
        .m_axis_rc_tready                          (m_axis_rc_tready),

        .pcie_rq_seq_num0                          (),
        .pcie_rq_seq_num_vld0                      (),
        .pcie_rq_seq_num1                          (),
        .pcie_rq_seq_num_vld1                      (),
        .pcie_rq_tag0                              (),
        .pcie_rq_tag1                              (),
        .pcie_rq_tag_av                            (),
        .pcie_rq_tag_vld0                          (),
        .pcie_rq_tag_vld1                          (),

        .pcie_tfc_nph_av                           (),
        .pcie_tfc_npd_av                           (),

        .pcie_cq_np_req                            (2'b11),
        .pcie_cq_np_req_count                      (),

        .cfg_phy_link_down                         (cfg_phy_link_down),
        .cfg_phy_link_status                       (cfg_phy_link_status),
        .cfg_negotiated_width                      (cfg_negotiated_width),
        .cfg_current_speed                         (cfg_current_speed),
        .cfg_max_payload                           (cfg_max_payload),
        .cfg_max_read_req                          (cfg_max_read_req),
        // cfg_ext_tag_enable is NOT a port of pcie4_uscale_plus_0 in this
        // configuration: the generated IP stub lists 137 ports and none of them
        // carries the Extended Tag Field Enable (only cfg_max_payload,
        // cfg_max_read_req, cfg_rcb_status and the like).  Naming it here made
        // synthesis stop with [Synth 8-11365] named port connection
        // 'cfg_ext_tag_enable' does not exist.  The value is obtained from
        // configuration space below, through the cfg_mgmt read port.
        .cfg_function_status                       (cfg_function_status),
        .cfg_function_power_state                  (),
        .cfg_vf_status                             (),
        .cfg_vf_power_state                        (),
        .cfg_link_power_state                      (),

        .cfg_mgmt_addr                             (ext_tag_mgmt_addr),
        .cfg_mgmt_function_number                  (ext_tag_mgmt_func),
        .cfg_mgmt_write                            (1'b0),
        .cfg_mgmt_write_data                       (32'b0),
        .cfg_mgmt_byte_enable                      (4'b0),
        .cfg_mgmt_read                             (ext_tag_mgmt_read),
        .cfg_mgmt_read_data                        (ext_tag_mgmt_read_data),
        .cfg_mgmt_read_write_done                  (ext_tag_mgmt_done),
        .cfg_mgmt_debug_access                     (1'b0),

        .cfg_err_cor_out                           (),
        .cfg_err_nonfatal_out                      (),
        .cfg_err_fatal_out                         (),
        .cfg_local_error_valid                     (),
        .cfg_local_error_out                       (),

        .cfg_ltssm_state                           (cfg_ltssm_state),
        .cfg_rx_pm_state                           (),
        .cfg_tx_pm_state                           (),
        .cfg_rcb_status                            (),
        .cfg_obff_enable                           (),
        .cfg_pl_status_change                      (),

        .cfg_tph_requester_enable                  (),
        .cfg_tph_st_mode                           (),
        .cfg_vf_tph_requester_enable               (),
        .cfg_vf_tph_st_mode                        (),

        .cfg_msg_received                          (),
        .cfg_msg_received_data                     (),
        .cfg_msg_received_type                     (),
        .cfg_msg_transmit                          (1'b0),
        .cfg_msg_transmit_type                     (3'b0),
        .cfg_msg_transmit_data                     (32'b0),
        .cfg_msg_transmit_done                     (),

        .cfg_fc_ph                                 (),
        .cfg_fc_pd                                 (),
        .cfg_fc_nph                                (),
        .cfg_fc_npd                                (),
        .cfg_fc_cplh                               (),
        .cfg_fc_cpld                               (),
        .cfg_fc_sel                                (3'b0),

        .cfg_dsn                                   (64'h00000001_00000001),

        .cfg_bus_number                            (cfg_bus_number),

        .cfg_power_state_change_ack                (1'b1),
        .cfg_power_state_change_interrupt          (),

        .cfg_err_cor_in                            (1'b0),
        .cfg_err_uncor_in                          (1'b0),

        .cfg_flr_in_process                        (),
        .cfg_flr_done                              (4'd0),
        .cfg_vf_flr_in_process                     (),
        .cfg_vf_flr_func_num                       (8'd0),
        .cfg_vf_flr_done                           (1'b0),

        .cfg_link_training_enable                  (1'b1),

        .cfg_interrupt_int                         (legacy_int_reg),
        .cfg_interrupt_pending                     (legacy_int_reg),
        .cfg_interrupt_sent                        (cfg_interrupt_sent),

        .cfg_interrupt_msi_enable                  (cfg_interrupt_msi_enable),
        .cfg_interrupt_msi_mmenable                (),
        .cfg_interrupt_msi_mask_update             (),
        .cfg_interrupt_msi_data                    (),
        .cfg_interrupt_msi_select                  (2'b0),
        .cfg_interrupt_msi_int                     (msi_int_reg),
        .cfg_interrupt_msi_pending_status          (32'b0),
        .cfg_interrupt_msi_pending_status_data_enable (1'b0),
        .cfg_interrupt_msi_pending_status_function_num (2'b0),
        .cfg_interrupt_msi_sent                    (cfg_interrupt_msi_sent),
        .cfg_interrupt_msi_fail                    (cfg_interrupt_msi_fail),
        .cfg_interrupt_msi_attr                    (3'b0),
        .cfg_interrupt_msi_tph_present             (1'b0),
        .cfg_interrupt_msi_tph_type                (2'b0),
        .cfg_interrupt_msi_tph_st_tag              (8'b0),
        .cfg_interrupt_msi_function_number         (8'b0),

        .cfg_pm_aspm_l1_entry_reject               (1'b0),
        .cfg_pm_aspm_tx_l0s_entry_disable          (1'b0),

        .cfg_hot_reset_out                         (),
        .cfg_hot_reset_in                          (1'b0),

        .cfg_config_space_enable                   (1'b1),

        .cfg_req_pm_transition_l23_ready           (1'b0),

        .cfg_ds_port_number                        (8'b0),
        .cfg_ds_bus_number                         (8'b0),
        .cfg_ds_device_number                      (5'b0)
    );

    // ------------------------------------------------------------------------
    // Extended Tag Field Enable, read from configuration space.
    //
    // The overlay plane uses completion tags 64..127, which are only legal
    // while the host has Device Control[4] (Extended Tag Field Enable) set for
    // this function.  The PCIe core exposes no such output in this
    // configuration, so the bit is read back through cfg_mgmt (read-only; see
    // rtl/sc7f0_pcie_ext_tag_enable.v for the port-list evidence and the
    // capability walk).  Until a walk completes, cfg_ext_tag_enable stays 0 and
    // custom_pcie_dma_top keeps the overlay ingress disarmed and reports
    // ovl_status_ext_tag_blocked - it never silently uses a >31 tag.
    // ------------------------------------------------------------------------
    wire        ext_tag_walk_done, ext_tag_walk_overflow;
    wire        ext_tag_devcap_support, ext_tag_mgmt_timeout;

    sc7f0_pcie_ext_tag_enable u_ext_tag (
        .clk                         (pcie_user_clk),
        .rst_n                       (pcie_user_rst_n),
        // Only user_lnk_up gates the walk.  cfg_phy_link_status and
        // cfg_function_status are deliberately NOT used here: their bit
        // encodings were not re-derived from a source in this session (D0 has
        // its own cfg_function_power_state port), and a wrong gate would leave
        // the overlay plane permanently disarmed.  pcie_user_lnk_up is the
        // indicator this design has always trusted (pcie_user_rst_n is derived
        // from it).  cfg_phy_link_status stays connected to the PCIe core above.
        .user_lnk_up                 (pcie_user_lnk_up),
        .cfg_mgmt_addr               (ext_tag_mgmt_addr),
        .cfg_mgmt_function_number    (ext_tag_mgmt_func),
        .cfg_mgmt_read               (ext_tag_mgmt_read),
        .cfg_mgmt_read_data          (ext_tag_mgmt_read_data),
        .cfg_mgmt_read_write_done    (ext_tag_mgmt_done),
        .ext_tag_enable              (cfg_ext_tag_enable),
        .devcap_ext_tag              (ext_tag_devcap_support),
        .walk_done                   (ext_tag_walk_done),
        .walk_overflow               (ext_tag_walk_overflow),
        .mgmt_timeout                (ext_tag_mgmt_timeout)
    );

    // ext_tag_devcap_support / ext_tag_walk_done / ext_tag_walk_overflow /
    // ext_tag_mgmt_timeout are observations only in this revision: the overlay
    // arm gate in custom_pcie_dma_top uses ext_tag_enable.  They are named here
    // so they can be attached to overlay status later without re-deriving the
    // walk.

    // =========================================================================
    // Custom Multi-Channel PCIe DMA Controller Top Module
    // =========================================================================
    wire dma_active;
    assign user_led_dma_active = dma_active;

    // Full AXI4 PS HPM0_FPD, adapted to AXI4-Lite before the BAR0 arbiter.
    wire [39:0]  ps_hpm0_awaddr;
    wire [15:0]  ps_hpm0_awid, ps_hpm0_bid, ps_hpm0_rid;
    wire [7:0]   ps_hpm0_awlen;
    wire [2:0]   ps_hpm0_awsize;
    wire [1:0]   ps_hpm0_awburst;
    wire         ps_hpm0_awlock;
    wire [3:0]   ps_hpm0_awcache, ps_hpm0_awqos;
    wire [2:0]   ps_hpm0_awprot;
    wire         ps_hpm0_awvalid, ps_hpm0_awready;
    wire [31:0]  ps_hpm0_wdata;
    wire [3:0]   ps_hpm0_wstrb;
    wire         ps_hpm0_wlast, ps_hpm0_wvalid, ps_hpm0_wready;
    wire [1:0]   ps_hpm0_bresp;
    wire         ps_hpm0_bvalid, ps_hpm0_bready;
    wire [39:0]  ps_hpm0_araddr;
    wire [15:0]  ps_hpm0_arid;
    wire [7:0]   ps_hpm0_arlen;
    wire [2:0]   ps_hpm0_arsize;
    wire [1:0]   ps_hpm0_arburst;
    wire         ps_hpm0_arlock;
    wire [3:0]   ps_hpm0_arcache, ps_hpm0_arqos;
    wire [2:0]   ps_hpm0_arprot;
    wire         ps_hpm0_arvalid, ps_hpm0_arready;
    wire [31:0]  ps_hpm0_rdata;
    wire [1:0]   ps_hpm0_rresp;
    wire         ps_hpm0_rlast, ps_hpm0_rvalid, ps_hpm0_rready;

    wire [31:0]  ps_lite_awaddr, ps_lite_wdata, ps_lite_araddr, ps_lite_rdata;
    wire [3:0]   ps_lite_wstrb;
    wire [1:0]   ps_lite_bresp, ps_lite_rresp;
    wire         ps_lite_awvalid, ps_lite_awready, ps_lite_wvalid, ps_lite_wready;
    wire         ps_lite_bvalid, ps_lite_bready, ps_lite_arvalid, ps_lite_arready;
    wire         ps_lite_rvalid, ps_lite_rready;

    // A direct AXI4-to-AXI-Lite hookup loses HPM0's transaction IDs.
    // In the 1202 capture ARID=0x002D, but the former hardwired RID=0,
    // leaving the CPU stuck despite a valid 0x12ABE380 RDATA handshake.
    // This IP preserves AXI4 ID/last/burst semantics on the PS side and
    // issues AXI4-Lite accesses into the existing two-master BAR0 crossbar.
    axi_protocol_converter_0 u_ps_axi4_to_lite (
        .aclk(pl_clk0),
        .aresetn(sys_100m_rst_n),
        .s_axi_awid(ps_hpm0_awid),
        .s_axi_awaddr(ps_hpm0_awaddr[31:0]),
        .s_axi_awlen(ps_hpm0_awlen),
        .s_axi_awsize(ps_hpm0_awsize),
        .s_axi_awburst(ps_hpm0_awburst),
        .s_axi_awlock(ps_hpm0_awlock),
        .s_axi_awcache(ps_hpm0_awcache),
        .s_axi_awprot(ps_hpm0_awprot),
        .s_axi_awregion(4'd0),
        .s_axi_awqos(ps_hpm0_awqos),
        .s_axi_awvalid(ps_hpm0_awvalid),
        .s_axi_awready(ps_hpm0_awready),
        .s_axi_wdata(ps_hpm0_wdata),
        .s_axi_wstrb(ps_hpm0_wstrb),
        .s_axi_wlast(ps_hpm0_wlast),
        .s_axi_wvalid(ps_hpm0_wvalid),
        .s_axi_wready(ps_hpm0_wready),
        .s_axi_bid(ps_hpm0_bid),
        .s_axi_bresp(ps_hpm0_bresp),
        .s_axi_bvalid(ps_hpm0_bvalid),
        .s_axi_bready(ps_hpm0_bready),
        .s_axi_arid(ps_hpm0_arid),
        .s_axi_araddr(ps_hpm0_araddr[31:0]),
        .s_axi_arlen(ps_hpm0_arlen),
        .s_axi_arsize(ps_hpm0_arsize),
        .s_axi_arburst(ps_hpm0_arburst),
        .s_axi_arlock(ps_hpm0_arlock),
        .s_axi_arcache(ps_hpm0_arcache),
        .s_axi_arprot(ps_hpm0_arprot),
        .s_axi_arregion(4'd0),
        .s_axi_arqos(ps_hpm0_arqos),
        .s_axi_arvalid(ps_hpm0_arvalid),
        .s_axi_arready(ps_hpm0_arready),
        .s_axi_rid(ps_hpm0_rid),
        .s_axi_rdata(ps_hpm0_rdata),
        .s_axi_rresp(ps_hpm0_rresp),
        .s_axi_rlast(ps_hpm0_rlast),
        .s_axi_rvalid(ps_hpm0_rvalid),
        .s_axi_rready(ps_hpm0_rready),
        .m_axi_awaddr(ps_lite_awaddr),
        .m_axi_awprot(),
        .m_axi_awvalid(ps_lite_awvalid),
        .m_axi_awready(ps_lite_awready),
        .m_axi_wdata(ps_lite_wdata),
        .m_axi_wstrb(ps_lite_wstrb),
        .m_axi_wvalid(ps_lite_wvalid),
        .m_axi_wready(ps_lite_wready),
        .m_axi_bresp(ps_lite_bresp),
        .m_axi_bvalid(ps_lite_bvalid),
        .m_axi_bready(ps_lite_bready),
        .m_axi_araddr(ps_lite_araddr),
        .m_axi_arprot(),
        .m_axi_arvalid(ps_lite_arvalid),
        .m_axi_arready(ps_lite_arready),
        .m_axi_rdata(ps_lite_rdata),
        .m_axi_rresp(ps_lite_rresp),
        .m_axi_rvalid(ps_lite_rvalid),
        .m_axi_rready(ps_lite_rready)
    );

`ifndef SC7F0_DEBUG_ONLY
    wire [15:0]  ps_hpm1_awid, ps_hpm1_bid, ps_hpm1_arid, ps_hpm1_rid;
    wire [39:0]  ps_hpm1_awaddr;
    wire [7:0]   ps_hpm1_awlen;
    wire [2:0]   ps_hpm1_awsize;
    wire [1:0]   ps_hpm1_awburst;
    wire         ps_hpm1_awlock;
    wire [3:0]   ps_hpm1_awcache, ps_hpm1_awqos;
    wire [2:0]   ps_hpm1_awprot;
    wire         ps_hpm1_awvalid, ps_hpm1_awready;
    wire [31:0]  ps_hpm1_wdata;
    wire [3:0]   ps_hpm1_wstrb;
    wire         ps_hpm1_wlast, ps_hpm1_wvalid, ps_hpm1_wready;
    wire [1:0]   ps_hpm1_bresp;
    wire         ps_hpm1_bvalid, ps_hpm1_bready;
    wire [39:0]  ps_hpm1_araddr;
    wire [7:0]   ps_hpm1_arlen;
    wire [2:0]   ps_hpm1_arsize;
    wire [1:0]   ps_hpm1_arburst;
    wire         ps_hpm1_arlock;
    wire [3:0]   ps_hpm1_arcache, ps_hpm1_arqos;
    wire [2:0]   ps_hpm1_arprot;
    wire         ps_hpm1_arvalid, ps_hpm1_arready;
    wire [31:0]  ps_hpm1_rdata;
    wire [1:0]   ps_hpm1_rresp;
    wire         ps_hpm1_rlast, ps_hpm1_rvalid, ps_hpm1_rready;

    // Symmetrical to HPM0: converts full AXI4 from PS HPM1 to AXI4-Lite
    // preserving transaction IDs and guaranteeing proper 32-bit register access.
    axi_protocol_converter_0 u_hdmi_axi4_to_lite (
        .aclk(pl_clk0),
        .aresetn(sys_100m_rst_n),
        .s_axi_awid(ps_hpm1_awid),
        .s_axi_awaddr(ps_hpm1_awaddr[31:0]),
        .s_axi_awlen(ps_hpm1_awlen),
        .s_axi_awsize(ps_hpm1_awsize),
        .s_axi_awburst(ps_hpm1_awburst),
        .s_axi_awlock(ps_hpm1_awlock),
        .s_axi_awcache(ps_hpm1_awcache),
        .s_axi_awprot(ps_hpm1_awprot),
        .s_axi_awregion(4'd0),
        .s_axi_awqos(ps_hpm1_awqos),
        .s_axi_awvalid(ps_hpm1_awvalid),
        .s_axi_awready(ps_hpm1_awready),
        .s_axi_wdata(ps_hpm1_wdata),
        .s_axi_wstrb(ps_hpm1_wstrb),
        .s_axi_wlast(ps_hpm1_wlast),
        .s_axi_wvalid(ps_hpm1_wvalid),
        .s_axi_wready(ps_hpm1_wready),
        .s_axi_bid(ps_hpm1_bid),
        .s_axi_bresp(ps_hpm1_bresp),
        .s_axi_bvalid(ps_hpm1_bvalid),
        .s_axi_bready(ps_hpm1_bready),
        .s_axi_arid(ps_hpm1_arid),
        .s_axi_araddr(ps_hpm1_araddr[31:0]),
        .s_axi_arlen(ps_hpm1_arlen),
        .s_axi_arsize(ps_hpm1_arsize),
        .s_axi_arburst(ps_hpm1_arburst),
        .s_axi_arlock(ps_hpm1_arlock),
        .s_axi_arcache(ps_hpm1_arcache),
        .s_axi_arprot(ps_hpm1_arprot),
        .s_axi_arregion(4'd0),
        .s_axi_arqos(ps_hpm1_arqos),
        .s_axi_arvalid(ps_hpm1_arvalid),
        .s_axi_arready(ps_hpm1_arready),
        .s_axi_rid(ps_hpm1_rid),
        .s_axi_rdata(ps_hpm1_rdata),
        .s_axi_rresp(ps_hpm1_rresp),
        .s_axi_rlast(ps_hpm1_rlast),
        .s_axi_rvalid(ps_hpm1_rvalid),
        .s_axi_rready(ps_hpm1_rready),
        .m_axi_awaddr(hdmi_ps_awaddr),
        .m_axi_awprot(),
        .m_axi_awvalid(hdmi_ps_awvalid),
        .m_axi_awready(hdmi_ps_awready),
        .m_axi_wdata(hdmi_ps_wdata),
        .m_axi_wstrb(hdmi_ps_wstrb),
        .m_axi_wvalid(hdmi_ps_wvalid),
        .m_axi_wready(hdmi_ps_wready),
        .m_axi_bresp(hdmi_ps_bresp),
        .m_axi_bvalid(hdmi_ps_bvalid),
        .m_axi_bready(hdmi_ps_bready),
        .m_axi_araddr(hdmi_ps_araddr),
        .m_axi_arprot(),
        .m_axi_arvalid(hdmi_ps_arvalid),
        .m_axi_arready(hdmi_ps_arready),
        .m_axi_rdata(hdmi_ps_rdata),
        .m_axi_rresp(hdmi_ps_rresp),
        .m_axi_rvalid(hdmi_ps_rvalid),
        .m_axi_rready(hdmi_ps_rready)
    );
`endif

    wire [48:0]  hp0_awaddr_w;
    wire [48:0] hp0_araddr_w;
    wire hp0_arvalid_w, hp0_arready_w, hp0_rvalid_w, hp0_rready_w, hp0_rlast_w;
    wire [127:0] hp0_rdata_w;
    wire [1:0] hp0_rresp_w;
    wire [5:0] hp0_rid_w;
    wire [7:0]   hp0_awlen_w;
    wire [2:0]   hp0_awsize_w;
    wire [1:0]   hp0_awburst_w;
    wire         hp0_awvalid_w, hp0_awready_w;
    wire [127:0] hp0_wdata_w;
    wire [15:0]  hp0_wstrb_w;
    wire         hp0_wlast_w;
    wire         hp0_wvalid_w, hp0_wready_w;
    wire [1:0]   hp0_bresp_w;
    wire         hp0_bvalid_w, hp0_bready_w;
    wire         ps_irq_pulse_w;

    custom_pcie_dma_top #(
        .C_VERSION(C_VERSION),
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH),
        .PCIE_KEEP_WIDTH(PCIE_KEEP_WIDTH),
        .NUM_VIDEO_CH(NUM_VIDEO_CH),
        .NUM_AUDIO_CH(NUM_AUDIO_CH),
        .VIDEO_DATA_WIDTH(VIDEO_DATA_WIDTH),
        .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH)
        ,.ENABLE_PACKET_C2H(1)
        ,.ENABLE_RGB_COMPOSITOR(
`ifdef SC7F0_RGB_COMPOSITOR
            1
`else
            0
`endif
        )
    ) u_dma_top (
        .packet_req_valid(dp_packet_valid),.packet_req_addr(dp_packet_addr),
        .packet_req_dw_len(dp_packet_dw_len),.packet_req_data(dp_packet_data),
        .packet_req_first_be(dp_packet_first_be),.packet_req_last_be(dp_packet_last_be),
        .packet_req_data_ready(dp_packet_data_ready),.packet_req_ack(dp_packet_ack),
        .packet_done_irq(dp_packet_done_msi_pulse),
        .in_pkt_submit_cnt(dp_pkt_sub_cnt),
        .in_pkt_done_cnt(dp_pkt_done_cnt),
        .in_pkt_err_cnt(dp_pkt_err_cnt),
        .in_pkt_msi_cnt(dp_pkt_msi_cnt),
        .in_pkt_bytes_lo(dp_pkt_bytes_lo),
        .in_pkt_bytes_hi(dp_pkt_bytes_hi),
        .in_pkt_fsm_state(dp_pkt_fsm_state),
        .in_pkt_last_len(dp_pkt_last_len),
        .in_pkt_last_pts_lo(dp_pkt_last_pts_lo),
        .in_pkt_last_pts_hi(dp_pkt_last_pts_hi),
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),
        .pl_clk0(pl_clk0),
        .pl_resetn0(pl_resetn0),
        .sys_100m_rst_n(sys_100m_rst_n),
        .ps_hpm0_arid(ps_hpm0_arid),
        .ps_hpm0_arlen(ps_hpm0_arlen),
        .ps_hpm0_arsize(ps_hpm0_arsize),
        .ps_hpm0_arvalid_raw(ps_hpm0_arvalid),
        .ps_hpm0_arready_raw(ps_hpm0_arready),
        .ps_hpm0_rid_raw(ps_hpm0_rid),
        .ps_hpm0_rvalid_raw(ps_hpm0_rvalid),

        // PCIe CQ
        .s_axis_cq_tdata(m_axis_cq_tdata),
        .s_axis_cq_tvalid(m_axis_cq_tvalid),
        .s_axis_cq_tlast(m_axis_cq_tlast),
        .s_axis_cq_tuser(m_axis_cq_tuser),
        .s_axis_cq_tkeep(m_axis_cq_tkeep),
        .s_axis_cq_tready(m_axis_cq_tready),

        // PCIe CC
        .m_axis_cc_tdata(s_axis_cc_tdata),
        .m_axis_cc_tvalid(s_axis_cc_tvalid),
        .m_axis_cc_tlast(s_axis_cc_tlast),
        .m_axis_cc_tuser(s_axis_cc_tuser),
        .m_axis_cc_tkeep(s_axis_cc_tkeep),
        .m_axis_cc_tready(s_axis_cc_tready_vec[0]),

        // PCIe RQ
        .m_axis_rq_tdata(s_axis_rq_tdata),
        .m_axis_rq_tvalid(s_axis_rq_tvalid),
        .m_axis_rq_tlast(s_axis_rq_tlast),
        .m_axis_rq_tuser(s_axis_rq_tuser),
        .m_axis_rq_tkeep(s_axis_rq_tkeep),
        .m_axis_rq_tready(s_axis_rq_tready_vec[0]),

        // PCIe RC
        .s_axis_rc_tdata(m_axis_rc_tdata),
        .s_axis_rc_tvalid(m_axis_rc_tvalid),
        .s_axis_rc_tlast(m_axis_rc_tlast),
        .s_axis_rc_tuser(m_axis_rc_tuser),
        .s_axis_rc_tkeep(m_axis_rc_tkeep),
        .s_axis_rc_tready(m_axis_rc_tready),

        // Dynamic Requester ID ({cfg_bus_number, 5'b00000, 3'b000})
        .requester_id({cfg_bus_number, 8'h00}),

        // BAR1 AXI4-Lite Master Interface -> Connected to axi_crossbar_0 S00
        .m_axil_bar1_awaddr(bar1_m_awaddr),
        .m_axil_bar1_awvalid(bar1_m_awvalid),
        .m_axil_bar1_awready(bar1_m_awready),
        .m_axil_bar1_wdata(bar1_m_wdata),
        .m_axil_bar1_wstrb(bar1_m_wstrb),
        .m_axil_bar1_wvalid(bar1_m_wvalid),
        .m_axil_bar1_wready(bar1_m_wready),
        .m_axil_bar1_bresp(bar1_m_bresp),
        .m_axil_bar1_bvalid(bar1_m_bvalid),
        .m_axil_bar1_bready(bar1_m_bready),
        .m_axil_bar1_araddr(bar1_m_araddr),
        .m_axil_bar1_arvalid(bar1_m_arvalid),
        .m_axil_bar1_arready(bar1_m_arready),
        .m_axil_bar1_rdata(bar1_m_rdata),
        .m_axil_bar1_rresp(bar1_m_rresp),
        .m_axil_bar1_rvalid(bar1_m_rvalid),
        .m_axil_bar1_rready(bar1_m_rready),

        // Multi-Channel Video Streams
        .s_axis_video_tdata(s_video_tdata),
        .s_axis_video_tvalid(s_video_tvalid),
        .s_axis_video_tlast(s_video_tlast),
        .s_axis_video_tuser(s_video_tuser),
        .s_axis_video_tready(s_video_tready),

        .video_clk(capture_clk),
        .video_rst_n(capture_rst_n),
        .video_capture_active(video_capture_active),
        .video_ch0_tdata(video_ch0_mux_tdata),
        .video_ch0_tvalid(video_ch0_mux_tvalid),
        .video_ch0_tlast(video_ch0_mux_tlast),
        .video_ch0_tuser(video_ch0_mux_tuser),
        .video_ch0_tready(video_ch0_mux_tready),

        .m_axis_video_tdata(m_video_tdata),
        .m_axis_video_tvalid(m_video_tvalid),
        .m_axis_video_tlast(m_video_tlast),
        .m_axis_video_tuser(m_video_tuser),
        .m_axis_video_tready(m_video_tready),

        // Multi-Channel Audio Streams
        .s_axis_audio_tdata(s_audio_tdata),
        .s_axis_audio_tvalid(s_audio_tvalid),
        .s_axis_audio_tlast(s_audio_tlast),
        .s_axis_audio_tready(s_audio_tready),

        .m_axis_audio_tdata(m_audio_tdata),
        .m_axis_audio_tvalid(m_audio_tvalid),
        .m_axis_audio_tlast(m_audio_tlast),
        .m_axis_audio_tready(m_audio_tready),

        // Sub-domain Resets & Diagnostic Marker Overlay
        .video_pipeline_reset(video_pipeline_reset),
        .video_tpg_reset(video_tpg_reset),
        .video_engine_reset(video_engine_reset),
        .overlay_en(dma_overlay_en),
        .overlay_width(dma_overlay_width),
        .overlay_height(dma_overlay_height),
        .out_vch0_ctrl(vch0_ctrl_w),

        // Interrupts
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack),

        // HDMI RX & TX Status and Control Ports (BAR0 0x0600 - 0x063C)
        .in_hdmi_rx_status(hdmi_rx_status_w),
        .in_hdmi_rx_res(hdmi_rx_res_w),
        .in_hdmi_rx_timing(hdmi_rx_timing_w),
        .in_hdmi_rx_audio(hdmi_rx_audio_w),
        .out_audio_capture_control(audio_capture_control),
        .in_audio_rx_frames(audio_rx_frames), .in_audio_rx_errors(audio_rx_errors),
        .in_audio_rx_channels(audio_rx_channels), .in_audio_rx_cs(audio_rx_cs),
        .in_hdmi_tx_status(hdmi_tx_status_w),
        .out_hdmi_tx_ctrl(hdmi_tx_ctrl_w),
        .out_hdmi_tx_res(hdmi_tx_res_w),
        .out_hdmi_tx_fps(hdmi_tx_fps_w),
        .out_hdmi_ipc_cmd(hdmi_ipc_cmd_w),
        .out_hdmi_ipc_arg(hdmi_ipc_arg_w),
        .out_hdmi_ipc_status(hdmi_ipc_status_w),
        .out_hdmi_ipc_doorbell(hdmi_ipc_doorbell_w),

        // Probing & Diagnostic Ports
        .in_probe_version(probe_version_w),
        .in_probe_rx_clk_freq(probe_rx_clk_freq_w),
        .in_probe_dru_clk_freq(probe_dru_clk_freq_w),
        .in_probe_rxoutclk_freq(probe_rxoutclk_freq_w),
        .in_probe_rx_video_clk_freq(probe_rx_video_clk_freq_w),
        .in_probe_tx_clk_freq(probe_tx_clk_freq_w),
        .in_probe_txoutclk_freq(probe_txoutclk_freq_w),
        .in_probe_tx_video_clk_freq(probe_tx_video_clk_freq_w),
        .in_probe_pins(probe_pins_w),
        .in_probe_pulse_cnt1(probe_pulse_cnt1_w),
        .in_probe_ddc_cnt(probe_ddc_cnt_w),
        .in_probe_irq_cnt(probe_irq_cnt_w),
        .in_probe_ch0_beats(probe_ch0_beats_w),
        .in_probe_ch1_beats(probe_ch1_beats_w),
        .in_probe_ch2_beats(probe_ch2_beats_w),
        .in_probe_rx_video_sof(probe_rx_video_sof_w),
        .in_probe_rx_video_eol(probe_rx_video_eol_w),
        .in_probe_rx_video_pix(probe_rx_video_pix_w),
        .in_probe_raw_rx_clk(probe_raw_rx_clk_w),
        .in_probe_raw_dru_clk(probe_raw_dru_clk_w),
        .in_probe_raw_rxoutclk(probe_raw_rxoutclk_w),
        .in_probe_raw_rx_video_clk(probe_raw_rx_video_clk_w),
        .in_probe_raw_refclk100(probe_raw_refclk100_w),
        .out_probe_ctrl(probe_ctrl_w),

        // AXI4-Lite from PS AXI4 protocol converter (PCIe shares BAR0 here)
        .s_axil_ps_awaddr(ps_lite_awaddr),
        .s_axil_ps_awvalid(ps_lite_awvalid),
        .s_axil_ps_awready(ps_lite_awready),
        .s_axil_ps_wdata(ps_lite_wdata),
        .s_axil_ps_wstrb(ps_lite_wstrb),
        .s_axil_ps_wvalid(ps_lite_wvalid),
        .s_axil_ps_wready(ps_lite_wready),
        .s_axil_ps_bresp(ps_lite_bresp),
        .s_axil_ps_bvalid(ps_lite_bvalid),
        .s_axil_ps_bready(ps_lite_bready),
        .s_axil_ps_araddr(ps_lite_araddr),
        .s_axil_ps_arvalid(ps_lite_arvalid),
        .s_axil_ps_arready(ps_lite_arready),
        .s_axil_ps_rdata(ps_lite_rdata),
        .s_axil_ps_rresp(ps_lite_rresp),
        .s_axil_ps_rvalid(ps_lite_rvalid),
        .s_axil_ps_rready(ps_lite_rready),

        // PS DDR4 AXI4 Master Write Interface (to PS S_AXI_HP0_FPD)
        .m_axi_hp0_awaddr(hp0_awaddr_w),
        .m_axi_hp0_araddr(hp0_araddr_w), .m_axi_hp0_arvalid(hp0_arvalid_w),
        .m_axi_hp0_arready(hp0_arready_w), .m_axi_hp0_rdata(hp0_rdata_w),
        .m_axi_hp0_rresp(hp0_rresp_w), .m_axi_hp0_rid(hp0_rid_w),
        .m_axi_hp0_rlast(hp0_rlast_w), .m_axi_hp0_rvalid(hp0_rvalid_w),
        .m_axi_hp0_rready(hp0_rready_w),
        .m_axi_hp0_awlen(hp0_awlen_w),
        .m_axi_hp0_awsize(hp0_awsize_w),
        .m_axi_hp0_awburst(hp0_awburst_w),
        .m_axi_hp0_awvalid(hp0_awvalid_w),
        .m_axi_hp0_awready(hp0_awready_w),
        .m_axi_hp0_wdata(hp0_wdata_w),
        .m_axi_hp0_wstrb(hp0_wstrb_w),
        .m_axi_hp0_wlast(hp0_wlast_w),
        .m_axi_hp0_wvalid(hp0_wvalid_w),
        .m_axi_hp0_wready(hp0_wready_w),
        .m_axi_hp0_bresp(hp0_bresp_w),
        .m_axi_hp0_bvalid(hp0_bvalid_w),
        .m_axi_hp0_bready(hp0_bready_w),

        // PS Interrupt Notification Pulse (to PS pl_ps_irq0)
        .out_ps_irq_pulse(ps_irq_pulse_w),

        // ---- SC7F0-RGB-COMPOSITOR-2PPC ---------------------------------
        .video_ch0_avail                 (
`ifdef SC7F0_RGB_COMPOSITOR
            rgb24_avail
`else
            11'd0
`endif
        ),
        .video_ch0_src_overflow_sticky   (
`ifdef SC7F0_RGB_COMPOSITOR
            rgb24_ovf_sticky
`else
            1'b0
`endif
        ),
        .video_ch0_src_line_align_sticky (
`ifdef SC7F0_RGB_COMPOSITOR
            rgb24_line_align_sticky
`else
            1'b0
`endif
        ),
        .ext_tag_enable                  (cfg_ext_tag_enable),
`ifdef SC7F0_RGB_COMPOSITOR
        .ovl_enable                      (ovl_ctrl_enable),
        .ovl_src_addr                    (ovl_ctrl_src_addr),
        .ovl_xfer_bytes                  (ovl_ctrl_xfer_bytes),
        .ovl_max_bytes_per_req           (ovl_ctrl_max_bytes_per_req),
        .ovl_go                          (ovl_ctrl_go),
        .ovl_abort_req                   (ovl_ctrl_abort_req),
        .ovl_quiesce_req                 (ovl_ctrl_quiesce_req),
        .ovl_discard_pending             (ovl_ctrl_discard_pending),
        .ovl_status_bytes_issued         (ovl_status_bytes_issued),
        .ovl_status_bytes_staged         (ovl_status_bytes_staged),
        .ovl_status_bytes_drained        (ovl_status_bytes_drained),
        .ovl_status_outstanding          (ovl_status_outstanding),
        .ovl_status_busy                 (ovl_status_busy),
        .ovl_status_quiesced             (ovl_status_quiesced),
        .ovl_status_quarantined          (ovl_status_quarantined),
        .ovl_status_ext_tag_blocked      (ovl_status_ext_tag_blocked),
        .ovl_status_counts               (ovl_status_counts),
        // Round 26111402: these five status outputs have been module ports of
        // custom_pcie_dma_top (rtl/custom_pcie_dma_top.v:296-301) and are consumed by
        // the overlay controller below (.wr_abort_busy / .wr_err_frames /
        // .video_guard_sticky / .video_guard_count / .video_poison, read back as CSR
        // 0x068 / 0x070 / 0x074), but this instance never connected them, so the
        // wires above had no driver.  Synthesis then removed the whole producer
        // chain, which is what round 26111401's routed Gray check measured:
        //   WARNING [Synth 8-7071] port 'ovl_wr_err_frames' ... unconnected for 'u_dma_top'
        //   WARNING [Synth 8-3848] Net ovl_wr_err_frames ... does not have driver
        //   and xpm_cdc_gray u_errf (rtl/sc7f0_overlay_writer.v:558) vanished from the
        //   implemented netlist (32 source + 128 destination cells absent).
        // Connecting them restores an already-designed path; no behaviour, protocol
        // or clock assignment here is changed.
        .ovl_wr_abort_busy               (ovl_wr_abort_busy),
        .ovl_wr_err_frames               (ovl_wr_err_frames),
        .ovl_video_guard_sticky          (ovl_video_guard_sticky),
        .ovl_video_guard_count           (ovl_video_guard_count),
        .ovl_video_poison                (ovl_video_poison),
        .ovl_mem_clk                     (capture_clk),
        .ovl_mem_rst_n                   (dp_mem_rst_n),
        .ovl_wr_enable                   (ovl_ctrl_wr_enable),
        .ovl_wr_dst_base                 (ovl_ctrl_wr_dst_base),
        .ovl_wr_slot_bytes               (ovl_ctrl_wr_slot_bytes),
        .ovl_wr_slot_count               (ovl_ctrl_wr_slot_count),
        .ovl_wr_frame_bytes              (ovl_ctrl_wr_frame_bytes),
        .ovl_wr_auto_advance             (ovl_ctrl_wr_auto_advance),
        .ovl_wr_force_slot               (ovl_ctrl_wr_force_slot),
        .ovl_wr_consume                  (ovl_ctrl_wr_consume),
        .ovl_wr_slot_ready               (ovl_wr_slot_ready),
        .ovl_wr_busy                     (ovl_wr_busy),
        .ovl_wr_active_slot              (ovl_wr_active_slot),
        .ovl_wr_frames_done              (ovl_wr_frames_done),
        .ovl_wr_bytes_written            (ovl_wr_bytes_written),
        .ovl_wr_sticky                   (ovl_wr_sticky),
        .ovl_axi_dbg                     (ovl_axi_dbg),
        .ovl_wr_irq_pulse                (ovl_wr_irq_pulse),
        .ovl_awaddr                      (ovl_hp3_awaddr),
        .ovl_awlen                       (ovl_hp3_awlen),
        .ovl_awsize                      (ovl_hp3_awsize),
        .ovl_awburst                     (ovl_hp3_awburst),
        .ovl_awcache                     (ovl_hp3_awcache),
        .ovl_awvalid                     (ovl_hp3_awvalid),
        .ovl_awready                     (ovl_hp3_awready),
        .ovl_wdata                       (ovl_hp3_wdata),
        .ovl_wstrb                       (ovl_hp3_wstrb),
        .ovl_wlast                       (ovl_hp3_wlast),
        .ovl_wvalid                      (ovl_hp3_wvalid),
        .ovl_wready                      (ovl_hp3_wready),
        .ovl_bresp                       (ovl_hp3_bresp),
        .ovl_bvalid                      (ovl_hp3_bvalid),
        .ovl_bready                      (ovl_hp3_bready),
        .ovl_wr_slot_release_m           (ovl_wr_slot_release_m),
        .ovl_wr_slot_ready_m             (ovl_wr_slot_ready_m),
        .ovl_wr_last_slot_m              (ovl_wr_last_slot_m),
        .ovl_wr_slot_bytes_m             (ovl_wr_slot_bytes_m),
        .ovl_base_vblank_p               (ovl_base_vblank_p),
        .ovl_direct_tdata                (ovl_direct_tdata),
        .ovl_direct_tvalid               (ovl_direct_tvalid),
        .ovl_direct_tready               (ovl_direct_tready),
        .ovl_direct_tlast                (ovl_direct_tlast),
        .ovl_direct_tuser                (ovl_direct_tuser),
        .m_axil_ovl_awaddr               (bar0_ovl_awaddr),
        .m_axil_ovl_awvalid              (bar0_ovl_awvalid),
        .m_axil_ovl_awready              (bar0_ovl_awready),
        .m_axil_ovl_wdata                (bar0_ovl_wdata),
        .m_axil_ovl_wstrb                (bar0_ovl_wstrb),
        .m_axil_ovl_wvalid               (bar0_ovl_wvalid),
        .m_axil_ovl_wready               (bar0_ovl_wready),
        .m_axil_ovl_bresp                (bar0_ovl_bresp),
        .m_axil_ovl_bvalid               (bar0_ovl_bvalid),
        .m_axil_ovl_bready               (bar0_ovl_bready),
        .m_axil_ovl_araddr               (bar0_ovl_araddr),
        .m_axil_ovl_arvalid              (bar0_ovl_arvalid),
        .m_axil_ovl_arready              (bar0_ovl_arready),
        .m_axil_ovl_rdata                (bar0_ovl_rdata),
        .m_axil_ovl_rresp                (bar0_ovl_rresp),
        .m_axil_ovl_rvalid               (bar0_ovl_rvalid),
        .m_axil_ovl_rready               (bar0_ovl_rready)
`else
        .ovl_enable                      (1'b0),
        .ovl_src_addr                    (64'd0),
        .ovl_xfer_bytes                  (32'd0),
        .ovl_max_bytes_per_req           (16'd0),
        .ovl_go                          (1'b0),
        .ovl_abort_req                   (1'b0),
        .ovl_quiesce_req                 (1'b0),
        .ovl_discard_pending             (1'b0),
        .ovl_status_bytes_issued         (),
        .ovl_status_bytes_staged         (),
        .ovl_status_bytes_drained        (),
        .ovl_status_outstanding          (),
        .ovl_status_busy                 (),
        .ovl_status_quiesced             (),
        .ovl_status_quarantined          (),
        .ovl_status_ext_tag_blocked      (),
        .ovl_status_counts               (),
        // Same five status ports, explicitly left open in the inactive configuration
        // (this branch's convention for every unused output, e.g. .ovl_wr_sticky ()
        // below).  Nothing is driven and nothing is read here, so the legacy
        // configuration's behaviour is unchanged.
        .ovl_wr_abort_busy               (),
        .ovl_wr_err_frames               (),
        .ovl_video_guard_sticky          (),
        .ovl_video_guard_count           (),
        .ovl_video_poison                (),
        .ovl_mem_clk                     (capture_clk),
        .ovl_mem_rst_n                   (dp_mem_rst_n),
        .ovl_wr_enable                   (1'b0),
        .ovl_wr_dst_base                 (49'd0),
        .ovl_wr_slot_bytes               (32'd0),
        .ovl_wr_slot_count               (3'd1),
        .ovl_wr_frame_bytes              (32'd0),
        .ovl_wr_auto_advance             (1'b0),
        .ovl_wr_force_slot               (2'd0),
        .ovl_wr_consume                  (4'd0),
        .ovl_wr_slot_ready               (),
        .ovl_wr_busy                     (),
        .ovl_wr_active_slot              (),
        .ovl_wr_frames_done              (),
        .ovl_wr_bytes_written            (),
        .ovl_wr_sticky                   (),
        .ovl_axi_dbg                     (),
        .ovl_wr_irq_pulse                (),
        .ovl_awaddr                      (),
        .ovl_awlen                       (),
        .ovl_awsize                      (),
        .ovl_awburst                     (),
        .ovl_awcache                     (),
        .ovl_awvalid                     (),
        .ovl_wdata                       (),
        .ovl_wstrb                       (),
        .ovl_wlast                       (),
        .ovl_wvalid                      (),
        .ovl_wready                      (1'b0),
        .ovl_bresp                       (2'b00),
        .ovl_bvalid                      (1'b0),
        .ovl_bready                      (),
        .ovl_wr_slot_release_m           (4'd0),
        .ovl_wr_slot_ready_m             (),
        .ovl_wr_last_slot_m              (),
        .ovl_wr_slot_bytes_m             (),
        .ovl_base_vblank_p               (1'b0),
        .ovl_direct_tdata                (),
        .ovl_direct_tvalid               (),
        .ovl_direct_tready               (1'b0),
        .ovl_direct_tlast                (),
        .ovl_direct_tuser                (),
        .m_axil_ovl_awaddr               (),
        .m_axil_ovl_awvalid              (),
        .m_axil_ovl_awready              (1'b1),
        .m_axil_ovl_wdata                (),
        .m_axil_ovl_wstrb                (),
        .m_axil_ovl_wvalid               (),
        .m_axil_ovl_wready               (1'b1),
        .m_axil_ovl_bresp                (2'b00),
        .m_axil_ovl_bvalid               (1'b0),
        .m_axil_ovl_bready               (),
        .m_axil_ovl_araddr               (),
        .m_axil_ovl_arvalid              (),
        .m_axil_ovl_arready              (1'b1),
        .m_axil_ovl_rdata                (32'd0),
        .m_axil_ovl_rresp                (2'b00),
        .m_axil_ovl_rvalid               (1'b0),
        .m_axil_ovl_rready               ()
`endif
    );

    // =========================================================================
    // Zynq UltraScale+ Processing System Subsystem (zu4ev_ps_bd_wrapper)
    // =========================================================================
    zu4ev_ps_bd_wrapper u_zu4ev_ps_bd (
`ifndef SC7F0_DEBUG_ONLY
        .dp_mem_clk(capture_clk),
        .S_AXI_HP1_FPD_awaddr(dp_awaddr),.S_AXI_HP1_FPD_awlen(dp_awlen),
        .S_AXI_HP1_FPD_awsize(dp_awsize),.S_AXI_HP1_FPD_awburst(dp_awburst),
        .S_AXI_HP1_FPD_awid(6'd0),.S_AXI_HP1_FPD_awlock(1'b0),
        .S_AXI_HP1_FPD_awcache(4'd3),.S_AXI_HP1_FPD_awprot(3'd0),
        .S_AXI_HP1_FPD_awqos(4'd0),.S_AXI_HP1_FPD_awuser(1'b0),
        .S_AXI_HP1_FPD_awvalid(dp_awvalid),.S_AXI_HP1_FPD_awready(dp_awready),
        .S_AXI_HP1_FPD_wdata(dp_wdata),.S_AXI_HP1_FPD_wstrb(dp_wstrb),
        .S_AXI_HP1_FPD_wlast(dp_wlast),.S_AXI_HP1_FPD_wvalid(dp_wvalid),
        .S_AXI_HP1_FPD_wready(dp_wready),.S_AXI_HP1_FPD_bid(),
        .S_AXI_HP1_FPD_bresp(dp_bresp),.S_AXI_HP1_FPD_bvalid(dp_bvalid),.S_AXI_HP1_FPD_bready(dp_bready),
        .S_AXI_HP1_FPD_araddr(dp_araddr),.S_AXI_HP1_FPD_arlen(dp_arlen),
        .S_AXI_HP1_FPD_arsize(dp_arsize),.S_AXI_HP1_FPD_arburst(dp_arburst),
        .S_AXI_HP1_FPD_arid(dp_arid),.S_AXI_HP1_FPD_arlock(1'b0),
        .S_AXI_HP1_FPD_arcache(4'd3),.S_AXI_HP1_FPD_arprot(3'd0),
        .S_AXI_HP1_FPD_arqos(4'hF),.S_AXI_HP1_FPD_aruser(1'b0),
        .S_AXI_HP1_FPD_arvalid(dp_arvalid),.S_AXI_HP1_FPD_arready(dp_arready),
        .S_AXI_HP1_FPD_rdata(dp_rdata),.S_AXI_HP1_FPD_rid(dp_rid),
        .S_AXI_HP1_FPD_rresp(dp_rresp),.S_AXI_HP1_FPD_rlast(dp_rlast),
        .S_AXI_HP1_FPD_rvalid(dp_rvalid),.S_AXI_HP1_FPD_rready(dp_rready),
        // M_AXI_HPM1_FPD (full AXI4 PS master -> protocol converter -> HDMI crossbar)
        .M_AXI_HPM1_FPD_araddr(ps_hpm1_araddr),
        .M_AXI_HPM1_FPD_arburst(ps_hpm1_arburst),
        .M_AXI_HPM1_FPD_arcache(ps_hpm1_arcache),
        .M_AXI_HPM1_FPD_arid(ps_hpm1_arid),
        .M_AXI_HPM1_FPD_arlen(ps_hpm1_arlen),
        .M_AXI_HPM1_FPD_arlock(ps_hpm1_arlock),
        .M_AXI_HPM1_FPD_arprot(ps_hpm1_arprot),
        .M_AXI_HPM1_FPD_arqos(ps_hpm1_arqos),
        .M_AXI_HPM1_FPD_arready(ps_hpm1_arready),
        .M_AXI_HPM1_FPD_arsize(ps_hpm1_arsize),
        .M_AXI_HPM1_FPD_aruser(),
        .M_AXI_HPM1_FPD_arvalid(ps_hpm1_arvalid),
        .M_AXI_HPM1_FPD_awaddr(ps_hpm1_awaddr),
        .M_AXI_HPM1_FPD_awburst(ps_hpm1_awburst),
        .M_AXI_HPM1_FPD_awcache(ps_hpm1_awcache),
        .M_AXI_HPM1_FPD_awid(ps_hpm1_awid),
        .M_AXI_HPM1_FPD_awlen(ps_hpm1_awlen),
        .M_AXI_HPM1_FPD_awlock(ps_hpm1_awlock),
        .M_AXI_HPM1_FPD_awprot(ps_hpm1_awprot),
        .M_AXI_HPM1_FPD_awqos(ps_hpm1_awqos),
        .M_AXI_HPM1_FPD_awready(ps_hpm1_awready),
        .M_AXI_HPM1_FPD_awsize(ps_hpm1_awsize),
        .M_AXI_HPM1_FPD_awuser(),
        .M_AXI_HPM1_FPD_awvalid(ps_hpm1_awvalid),
        .M_AXI_HPM1_FPD_bid(ps_hpm1_bid),
        .M_AXI_HPM1_FPD_bready(ps_hpm1_bready),
        .M_AXI_HPM1_FPD_bresp(ps_hpm1_bresp),
        .M_AXI_HPM1_FPD_bvalid(ps_hpm1_bvalid),
        .M_AXI_HPM1_FPD_rdata(ps_hpm1_rdata),
        .M_AXI_HPM1_FPD_rid(ps_hpm1_rid),
        .M_AXI_HPM1_FPD_rlast(ps_hpm1_rlast),
        .M_AXI_HPM1_FPD_rready(ps_hpm1_rready),
        .M_AXI_HPM1_FPD_rresp(ps_hpm1_rresp),
        .M_AXI_HPM1_FPD_rvalid(ps_hpm1_rvalid),
        .M_AXI_HPM1_FPD_wdata(ps_hpm1_wdata),
        .M_AXI_HPM1_FPD_wlast(ps_hpm1_wlast),
        .M_AXI_HPM1_FPD_wready(ps_hpm1_wready),
        .M_AXI_HPM1_FPD_wstrb(ps_hpm1_wstrb),
        .M_AXI_HPM1_FPD_wvalid(ps_hpm1_wvalid),
`endif
`ifdef SC7F0_RGB_COMPOSITOR
        .ovl_hp3_clk(capture_clk),
        // ---- S_AXI_HP2_FPD: idle (overlay reader replaced by direct pull) ----
        .S_AXI_HP2_FPD_awaddr(49'd0), .S_AXI_HP2_FPD_awlen(8'd0),
        .S_AXI_HP2_FPD_awsize(3'd0), .S_AXI_HP2_FPD_awburst(2'd1),
        .S_AXI_HP2_FPD_awid(6'd0), .S_AXI_HP2_FPD_awlock(1'b0),
        .S_AXI_HP2_FPD_awcache(4'd3), .S_AXI_HP2_FPD_awprot(3'd0),
        .S_AXI_HP2_FPD_awqos(4'd0), .S_AXI_HP2_FPD_awuser(1'b0),
        .S_AXI_HP2_FPD_awvalid(1'b0), .S_AXI_HP2_FPD_awready(),
        .S_AXI_HP2_FPD_wdata(128'd0), .S_AXI_HP2_FPD_wstrb(16'd0),
        .S_AXI_HP2_FPD_wlast(1'b0), .S_AXI_HP2_FPD_wvalid(1'b0),
        .S_AXI_HP2_FPD_wready(), .S_AXI_HP2_FPD_bid(),
        .S_AXI_HP2_FPD_bresp(), .S_AXI_HP2_FPD_bvalid(), .S_AXI_HP2_FPD_bready(1'b0),
        .S_AXI_HP2_FPD_araddr(49'd0), .S_AXI_HP2_FPD_arlen(8'd0),
        .S_AXI_HP2_FPD_arsize(3'd0), .S_AXI_HP2_FPD_arburst(2'd1),
        .S_AXI_HP2_FPD_arid(6'd0), .S_AXI_HP2_FPD_arlock(1'b0),
        .S_AXI_HP2_FPD_arcache(4'd3), .S_AXI_HP2_FPD_arprot(3'd0),
        .S_AXI_HP2_FPD_arqos(4'd0), .S_AXI_HP2_FPD_aruser(1'b0),
        .S_AXI_HP2_FPD_arvalid(1'b0), .S_AXI_HP2_FPD_arready(rd_b_arready),
        .S_AXI_HP2_FPD_rdata(rd_b_rdata), .S_AXI_HP2_FPD_rid(),
        .S_AXI_HP2_FPD_rresp(rd_b_rresp), .S_AXI_HP2_FPD_rlast(rd_b_rlast),
        .S_AXI_HP2_FPD_rvalid(rd_b_rvalid), .S_AXI_HP2_FPD_rready(1'b0),

        // ---- S_AXI_HP3_FPD: idle (overlay writer replaced by direct pull) ----
        .S_AXI_HP3_FPD_awaddr(49'd0), .S_AXI_HP3_FPD_awlen(8'd0),
        .S_AXI_HP3_FPD_awsize(3'd0), .S_AXI_HP3_FPD_awburst(2'd1),
        .S_AXI_HP3_FPD_awid(6'd0), .S_AXI_HP3_FPD_awlock(1'b0),
        .S_AXI_HP3_FPD_awcache(4'd3), .S_AXI_HP3_FPD_awprot(3'd0),
        .S_AXI_HP3_FPD_awqos(4'd0), .S_AXI_HP3_FPD_awuser(1'b0),
        .S_AXI_HP3_FPD_awvalid(1'b0), .S_AXI_HP3_FPD_awready(ovl_hp3_awready),
        .S_AXI_HP3_FPD_wdata(128'd0), .S_AXI_HP3_FPD_wstrb(16'd0),
        .S_AXI_HP3_FPD_wlast(1'b0), .S_AXI_HP3_FPD_wvalid(1'b0),
        .S_AXI_HP3_FPD_wready(ovl_hp3_wready), .S_AXI_HP3_FPD_bid(),
        .S_AXI_HP3_FPD_bresp(ovl_hp3_bresp), .S_AXI_HP3_FPD_bvalid(ovl_hp3_bvalid),
        .S_AXI_HP3_FPD_bready(1'b0),
        .S_AXI_HP3_FPD_araddr(49'd0), .S_AXI_HP3_FPD_arlen(8'd0),
        .S_AXI_HP3_FPD_arsize(3'd0), .S_AXI_HP3_FPD_arburst(2'd1),
        .S_AXI_HP3_FPD_arid(6'd0), .S_AXI_HP3_FPD_arlock(1'b0),
        .S_AXI_HP3_FPD_arcache(4'd3), .S_AXI_HP3_FPD_arprot(3'd0),
        .S_AXI_HP3_FPD_arqos(4'd0), .S_AXI_HP3_FPD_aruser(1'b0),
        .S_AXI_HP3_FPD_arvalid(1'b0), .S_AXI_HP3_FPD_arready(),
        .S_AXI_HP3_FPD_rdata(), .S_AXI_HP3_FPD_rid(), .S_AXI_HP3_FPD_rresp(),
        .S_AXI_HP3_FPD_rlast(), .S_AXI_HP3_FPD_rvalid(), .S_AXI_HP3_FPD_rready(1'b0),

        // Reader-B reset, PS EMIO GPIO output bit 3.
        .frmbuf_rd_b_resetn(reader_b_gpio_reset),
`endif
        .pl_clk0(pl_clk0),
        .pl_resetn0(pl_resetn0),
`ifdef SC7F0_DEBUG_ONLY
        .pl_ps_irq0(ps_irq_pulse_w),
`else
`ifdef SC7F0_RGB_COMPOSITOR
        // RGB-compositor personality.  pl_ps_irq0[4:0] keeps the published
        // sources in the same slots (mailbox, VPHY, HDMI RX SS, dualpath,
        // capture frmbuf_wr).  The three new sources cannot go there: this PS
        // configuration caps pl_ps_irq0 at 8 inputs (validate_bd_design reports
        // "BD 17-147 ... Maximum Supported width ... is 8"), so they use the
        // second PL vector, which is the slot the removed VCU encoder frees up:
        //   pl_ps_irq1[0]  compositor Reader-A (base plane) v_frmbuf_rd
        //   pl_ps_irq1[1]  compositor Reader-B (overlay plane) reader
        //   pl_ps_irq1[2]  overlay plane writer frame complete
        //   pl_ps_irq1[3]  HDMI TX subsystem (v_hdmi_tx_ss irq)
        // The vector is FOUR bits wide and every bit is a real source: in the
        // previous revision hdmi_tx_irq had no destination at all in this
        // personality (the display branch routes it through pl_ps_irq_disp,
        // which this build does not have), so the DRM HDMI TX driver could bind
        // through a tied-off device-tree interrupt but never saw an HPD / cable
        // / alarm event.  Nothing is OR-ed and nothing is faked: bit 3 is the
        // same level-high source the display branch puts on its own vector.
        //
        // Numeric ids, now verified against two local authoritative sources
        // (not inferred from the IRQ0 numbers):
        //   Vitis standalone BSP, ARMv8/64bit/platform/ZynqMP/xparameters_ps.h
        //     XPS_FPGA0..7_INT_ID  = 121..128   (pl_ps_irq0, GIC INTID)
        //     XPS_FPGA8..15_INT_ID = 136..143   (pl_ps_irq1, GIC INTID)
        //   PetaLinux device-tree generator, device_tree/data/common_proc.tcl
        //     IRQ0_F2P -> 89 + bit,  IRQ1_F2P -> 104 + bit   (DT SPI index)
        // So the two banks are NOT contiguous: INTID = SPI + 32, IRQ0[n] is
        // SPI 89+n (INTID 121+n) and IRQ1[n] is SPI 104+n (INTID 136+n).
        // Reader-A/B, the overlay writer and the TX SS are therefore DT SPIs
        // 104, 105, 106 and 107.
        .pl_ps_irq0({capture_irq,dp_irq,hdmi_rx_irq,hdmi_phy_irq,ps_irq_pulse_w}),
        .pl_ps_irq1({hdmi_tx_irq, ovl_wr_irq_pulse, comp_irq_b, comp_irq_a}),
`else
        // Both HDMI IRQs originate in the PS pl_clk0 AXI-Lite domain.
        // [0]=existing PS notification, [1]=VPHY, [2]=HDMI RX SS.
        .pl_ps_irq0({capture_irq,dp_irq,hdmi_rx_irq,hdmi_phy_irq,ps_irq_pulse_w}),
`ifdef SC7F0_DISPLAY_TX
        // Display branch: HDMI TX SS -> GIC SPI 95, display v_frmbuf_rd -> SPI 96.
        // The block design concatenates these into pl_ps_irq0[7:6]; bits 4:0 and
        // the VCU bit 5 keep the numbers every deployed device tree already uses.
        .pl_ps_irq_disp({display_frmbuf_irq,hdmi_tx_irq}),
`endif
`endif
`endif

        // M_AXI_HPM0_FPD (full AXI4 PS master -> protocol converter)
        .M_AXI_HPM0_FPD_araddr(ps_hpm0_araddr),
        .M_AXI_HPM0_FPD_arburst(ps_hpm0_arburst),
        .M_AXI_HPM0_FPD_arcache(ps_hpm0_arcache),
        .M_AXI_HPM0_FPD_arid(ps_hpm0_arid),
        .M_AXI_HPM0_FPD_arlen(ps_hpm0_arlen),
        .M_AXI_HPM0_FPD_arlock(ps_hpm0_arlock),
        .M_AXI_HPM0_FPD_arprot(ps_hpm0_arprot),
        .M_AXI_HPM0_FPD_arqos(ps_hpm0_arqos),
        .M_AXI_HPM0_FPD_arready(ps_hpm0_arready),
        .M_AXI_HPM0_FPD_arsize(ps_hpm0_arsize),
        .M_AXI_HPM0_FPD_aruser(),
        .M_AXI_HPM0_FPD_arvalid(ps_hpm0_arvalid),
        .M_AXI_HPM0_FPD_awaddr(ps_hpm0_awaddr),
        .M_AXI_HPM0_FPD_awburst(ps_hpm0_awburst),
        .M_AXI_HPM0_FPD_awcache(ps_hpm0_awcache),
        .M_AXI_HPM0_FPD_awid(ps_hpm0_awid),
        .M_AXI_HPM0_FPD_awlen(ps_hpm0_awlen),
        .M_AXI_HPM0_FPD_awlock(ps_hpm0_awlock),
        .M_AXI_HPM0_FPD_awprot(ps_hpm0_awprot),
        .M_AXI_HPM0_FPD_awqos(ps_hpm0_awqos),
        .M_AXI_HPM0_FPD_awready(ps_hpm0_awready),
        .M_AXI_HPM0_FPD_awsize(ps_hpm0_awsize),
        .M_AXI_HPM0_FPD_awuser(),
        .M_AXI_HPM0_FPD_awvalid(ps_hpm0_awvalid),
        .M_AXI_HPM0_FPD_bid(ps_hpm0_bid),
        .M_AXI_HPM0_FPD_bready(ps_hpm0_bready),
        .M_AXI_HPM0_FPD_bresp(ps_hpm0_bresp),
        .M_AXI_HPM0_FPD_bvalid(ps_hpm0_bvalid),
        .M_AXI_HPM0_FPD_rdata(ps_hpm0_rdata),
        .M_AXI_HPM0_FPD_rid(ps_hpm0_rid),
        .M_AXI_HPM0_FPD_rlast(ps_hpm0_rlast),
        .M_AXI_HPM0_FPD_rready(ps_hpm0_rready),
        .M_AXI_HPM0_FPD_rresp(ps_hpm0_rresp),
        .M_AXI_HPM0_FPD_rvalid(ps_hpm0_rvalid),
        .M_AXI_HPM0_FPD_wdata(ps_hpm0_wdata),
        .M_AXI_HPM0_FPD_wlast(ps_hpm0_wlast),
        .M_AXI_HPM0_FPD_wready(ps_hpm0_wready),
        .M_AXI_HPM0_FPD_wstrb(ps_hpm0_wstrb),
        .M_AXI_HPM0_FPD_wvalid(ps_hpm0_wvalid),

        // S_AXI_HP0_FPD (PL H2C DMA Master into PS DDR4)
        .S_AXI_HP0_FPD_araddr(hp0_araddr_w),
        .S_AXI_HP0_FPD_arburst(2'b01),
        .S_AXI_HP0_FPD_arcache(4'd0),
        .S_AXI_HP0_FPD_arid(6'd0),
        .S_AXI_HP0_FPD_arlen(8'd0),
        .S_AXI_HP0_FPD_arlock(1'b0),
        .S_AXI_HP0_FPD_arprot(3'd0),
        .S_AXI_HP0_FPD_arqos(4'd0),
        .S_AXI_HP0_FPD_arready(hp0_arready_w),
        .S_AXI_HP0_FPD_arsize(3'b100),
        .S_AXI_HP0_FPD_aruser(1'b0),
        .S_AXI_HP0_FPD_arvalid(hp0_arvalid_w),
        .S_AXI_HP0_FPD_awaddr(hp0_awaddr_w),
        .S_AXI_HP0_FPD_awburst(hp0_awburst_w),
        .S_AXI_HP0_FPD_awcache(4'd3),
        .S_AXI_HP0_FPD_awid(6'd0),
        .S_AXI_HP0_FPD_awlen(hp0_awlen_w),
        .S_AXI_HP0_FPD_awlock(1'b0),
        .S_AXI_HP0_FPD_awprot(3'd0),
        .S_AXI_HP0_FPD_awqos(4'd0),
        .S_AXI_HP0_FPD_awready(hp0_awready_w),
        .S_AXI_HP0_FPD_awsize(hp0_awsize_w),
        .S_AXI_HP0_FPD_awuser(1'b0),
        .S_AXI_HP0_FPD_awvalid(hp0_awvalid_w),
        .S_AXI_HP0_FPD_bid(),
        .S_AXI_HP0_FPD_bready(hp0_bready_w),
        .S_AXI_HP0_FPD_bresp(hp0_bresp_w),
        .S_AXI_HP0_FPD_bvalid(hp0_bvalid_w),
        .S_AXI_HP0_FPD_rdata(hp0_rdata_w),
        .S_AXI_HP0_FPD_rid(hp0_rid_w),
        .S_AXI_HP0_FPD_rlast(hp0_rlast_w),
        .S_AXI_HP0_FPD_rready(hp0_rready_w),
        .S_AXI_HP0_FPD_rresp(hp0_rresp_w),
        .S_AXI_HP0_FPD_rvalid(hp0_rvalid_w),
        .S_AXI_HP0_FPD_wdata(hp0_wdata_w),
        .S_AXI_HP0_FPD_wlast(hp0_wlast_w),
        .S_AXI_HP0_FPD_wready(hp0_wready_w),
        .S_AXI_HP0_FPD_wstrb(hp0_wstrb_w),
        .S_AXI_HP0_FPD_wvalid(hp0_wvalid_w)
    );

    // Heartbeat / DMA activity indicator
    reg [25:0] heartbeat_cnt;
    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n)
            heartbeat_cnt <= 26'd0;
        else
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
    end
    assign dma_active = heartbeat_cnt[25];

endmodule
