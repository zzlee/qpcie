// ============================================================================
// Module: a50t_pcie_card_top
// Target: AMD/Xilinx Artix-7 (xc7a50t-csg325-2)
// Description: Top-level FPGA card wrapper module for Artix-7 A50T target.
//              Uses pcie_7x_0 (7-Series PCIe Block Gen2 x4, 128-bit AXI-Stream).
//              100% shared core DMA logic with UltraScale+ solutions.
//              Supports 4K60 NV12 / NV16 Multi-Planar C2H/H2C streaming.
// ============================================================================

`timescale 1ns / 1ps

module a50t_pcie_card_top #(
    parameter PCIE_DATA_WIDTH  = 128,
    parameter PCIE_KEEP_WIDTH  = PCIE_DATA_WIDTH / 8,
    parameter NUM_VIDEO_CH     = 4,
    parameter NUM_AUDIO_CH     = 4,
    parameter VIDEO_DATA_WIDTH = 128,
    parameter AUDIO_DATA_WIDTH = 32
)(
    // Physical PCIe Reference Clock & PERST# Reset Pins
    input  wire                                             sys_clk_p,
    input  wire                                             sys_clk_n,
    input  wire                                             sys_rst_n,

    // Physical PCIe Transceiver Serial Lanes (Gen2 x4)
    output wire [3:0]                                       pci_exp_txp,
    output wire [3:0]                                       pci_exp_txn,
    input  wire [3:0]                                       pci_exp_rxp,
    input  wire [3:0]                                       pci_exp_rxn
);

    // =========================================================================
    // Internal Clocks and Resets
    // =========================================================================
    wire pcie_user_clk;
    wire pcie_user_reset;
    wire pcie_user_rst_n;
    wire pcie_user_lnk_up;

    assign pcie_user_rst_n = ~pcie_user_reset;

    // =========================================================================
    // BAR1 AXI4-Lite Master Interconnect Wires
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
    // AXI Crossbar Master Interface Wires (3 Masters)
    // M00: Video TPG (0x0000), M01: Audio Pattern Gen (0x0100), M02: EDID/HPD (0x0300)
    // =========================================================================
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

    wire [31:0] bar1_reg_awaddr, bar1_reg_araddr;
    wire        bar1_reg_awvalid, bar1_reg_awready;
    wire [31:0] bar1_reg_wdata;
    wire [3:0]  bar1_reg_wstrb;
    wire        bar1_reg_wvalid, bar1_reg_wready;
    wire [1:0]  bar1_reg_bresp;
    wire        bar1_reg_bvalid, bar1_reg_bready;
    wire        bar1_reg_arvalid, bar1_reg_arready;
    wire [31:0] bar1_reg_rdata;
    wire [1:0]  bar1_reg_rresp;
    wire        bar1_reg_rvalid, bar1_reg_rready;

    wire [31:0] tpg_axi_awaddr_32, tpg_axi_araddr_32;
    wire [31:0] aud_axi_awaddr_32, aud_axi_araddr_32;

    assign tpg_axi_awaddr = tpg_axi_awaddr_32[7:0];
    assign tpg_axi_araddr = tpg_axi_araddr_32[7:0];
    assign aud_axi_awaddr = aud_axi_awaddr_32[7:0];
    assign aud_axi_araddr = aud_axi_araddr_32[7:0];

    // AXI Crossbar IP Instance
    axi_crossbar_0 u_axil_crossbar (
        .aclk(pcie_user_clk),
        .aresetn(pcie_user_rst_n),
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

        .m_axi_awaddr({bar1_reg_awaddr, aud_axi_awaddr_32, tpg_axi_awaddr_32}),
        .m_axi_awprot(),
        .m_axi_awvalid({bar1_reg_awvalid, aud_axi_awvalid, tpg_axi_awvalid}),
        .m_axi_awready({bar1_reg_awready, aud_axi_awready, tpg_axi_awready}),
        .m_axi_wdata({bar1_reg_wdata, aud_axi_wdata, tpg_axi_wdata}),
        .m_axi_wstrb({bar1_reg_wstrb, aud_axi_wstrb, tpg_axi_wstrb}),
        .m_axi_wvalid({bar1_reg_wvalid, aud_axi_wvalid, tpg_axi_wvalid}),
        .m_axi_wready({bar1_reg_wready, aud_axi_wready, tpg_axi_wready}),
        .m_axi_bresp({bar1_reg_bresp, aud_axi_bresp, tpg_axi_bresp}),
        .m_axi_bvalid({bar1_reg_bvalid, aud_axi_bvalid, tpg_axi_bvalid}),
        .m_axi_bready({bar1_reg_bready, aud_axi_bready, tpg_axi_bready}),
        .m_axi_araddr({bar1_reg_araddr, aud_axi_araddr_32, tpg_axi_araddr_32}),
        .m_axi_arprot(),
        .m_axi_arvalid({bar1_reg_arvalid, aud_axi_arvalid, tpg_axi_arvalid}),
        .m_axi_arready({bar1_reg_arready, aud_axi_arready, tpg_axi_arready}),
        .m_axi_rdata({bar1_reg_rdata, aud_axi_rdata, tpg_axi_rdata}),
        .m_axi_rresp({bar1_reg_rresp, aud_axi_rresp, tpg_axi_rresp}),
        .m_axi_rvalid({bar1_reg_rvalid, aud_axi_rvalid, tpg_axi_rvalid}),
        .m_axi_rready({bar1_reg_rready, aud_axi_rready, tpg_axi_rready})
    );

    // Xilinx Video TPG IP Core Instance
    wire [95:0] tpg_axis_tdata;
    wire        tpg_axis_tvalid;
    wire        tpg_axis_tready;
    wire        tpg_axis_tlast;
    wire [0:0]  tpg_axis_tuser;
    wire [11:0] tpg_axis_tkeep;
    wire [11:0] tpg_axis_tstrb;
    wire        tpg_interrupt;

    v_tpg_0 u_v_tpg (
        .ap_clk(pcie_user_clk),
        .ap_rst_n(pcie_user_rst_n),
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

    // Audio Pattern Generator Instance
    wire [31:0] aud_pat_axis_tdata;
    wire        aud_pat_axis_tvalid;
    wire        aud_pat_axis_tlast;
    wire        aud_pat_axis_tready;

    audio_pattern_gen #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) u_audio_pattern_gen (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),
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
        .m_axis_audio_tdata(aud_pat_axis_tdata),
        .m_axis_audio_tvalid(aud_pat_axis_tvalid),
        .m_axis_audio_tlast(aud_pat_axis_tlast),
        .m_axis_audio_tready(aud_pat_axis_tready)
    );

    // Dynamic EDID RAM Instance
    wire [7:0] edid_rdata_byte;

    hdmi_edid_ram u_hdmi_edid_ram (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),
        .axil_addr(bar1_reg_awaddr[7:0]),
        .axil_write_en(bar1_reg_wvalid && bar1_reg_wready),
        .axil_wdata(bar1_reg_wdata[7:0]),
        .axil_rdata(edid_rdata_byte),
        .hpd_ctrl_en(1'b1),
        .hdmi_hpd_out(hdmi_hpd_out),
        .i2c_scl(),
        .i2c_sda()
    );

    assign bar1_reg_rdata   = {24'd0, edid_rdata_byte};
    assign bar1_reg_awready = 1'b1;
    assign bar1_reg_wready  = 1'b1;
    assign bar1_reg_bvalid  = bar1_reg_wvalid;
    assign bar1_reg_bresp   = 2'b00;
    assign bar1_reg_arready = 1'b1;
    assign bar1_reg_rvalid  = bar1_reg_arvalid;
    assign bar1_reg_rresp   = 2'b00;

    // Multi-Channel Video Streams
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

    assign s_video_tdata[127:0] = {
        8'hFF, tpg_axis_tdata[95:72],
        8'hFF, tpg_axis_tdata[71:48],
        8'hFF, tpg_axis_tdata[47:24],
        8'hFF, tpg_axis_tdata[23:0]
    };
    assign s_video_tvalid[0]   = tpg_axis_tvalid;
    assign s_video_tlast[0]    = tpg_axis_tlast;
    assign s_video_tuser[0]    = tpg_axis_tuser[0];
    assign tpg_axis_tready     = s_video_tready[0];

    assign s_video_tdata[511:128] = m_video_tdata[511:128];
    assign s_video_tvalid[3:1]    = m_video_tvalid[3:1];
    assign s_video_tlast[3:1]     = m_video_tlast[3:1];
    assign s_video_tuser[3:1]     = m_video_tuser[3:1];
    assign m_video_tready[3:1]    = s_video_tready[3:1];
    assign m_video_tready[0]      = 1'b1;

    // Multi-Channel Audio Streams
    wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0] s_audio_tdata;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tvalid;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tlast;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tready;

    wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0] m_audio_tdata;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tvalid;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tlast;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tready;

    assign s_audio_tdata[31:0] = aud_pat_axis_tdata;
    assign s_audio_tvalid[0]   = aud_pat_axis_tvalid;
    assign s_audio_tlast[0]    = aud_pat_axis_tlast;
    assign aud_pat_axis_tready = s_audio_tready[0];

    assign s_audio_tdata[127:32] = m_audio_tdata[127:32];
    assign s_audio_tvalid[3:1]   = m_audio_tvalid[3:1];
    assign s_audio_tlast[3:1]    = m_audio_tlast[3:1];
    assign m_audio_tready[3:1]   = s_audio_tready[3:1];
    assign m_audio_tready[0]     = 1'b1;

    // PCIe 128-bit AXI-Stream Internal CQ / CC / RQ / RC Wires
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
    wire                       s_axis_cc_tready;

    wire [PCIE_DATA_WIDTH-1:0] s_axis_rq_tdata;
    wire                       s_axis_rq_tvalid;
    wire                       s_axis_rq_tlast;
    wire [61:0]                s_axis_rq_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] s_axis_rq_tkeep;
    wire                       s_axis_rq_tready;

    wire [PCIE_DATA_WIDTH-1:0] m_axis_rc_tdata;
    wire                       m_axis_rc_tvalid;
    wire                       m_axis_rc_tlast;
    wire [74:0]                m_axis_rc_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] m_axis_rc_tkeep;
    wire                       m_axis_rc_tready;

    wire usr_irq_req, usr_irq_ack;

    // Differential Reference Clock Input Buffer for Artix-7 GTP Transceiver (sys_clk_p/n D6/D5)
    wire sys_clk;
    IBUFDS_GTE2 u_ibufds_gte2_sys_clk (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .CEB(1'b0),
        .O(sys_clk),
        .ODIV2()
    );

    // 7-Series PCIe 128-bit AXI-Stream Wires
    wire [127:0] m_axis_rx_tdata;
    wire [15:0]  m_axis_rx_tkeep;
    wire         m_axis_rx_tlast;
    wire         m_axis_rx_tvalid;
    wire         m_axis_rx_tready;
    wire [21:0]  m_axis_rx_tuser;

    wire [127:0] s_axis_tx_tdata;
    wire [15:0]  s_axis_tx_tkeep;
    wire         s_axis_tx_tlast;
    wire         s_axis_tx_tvalid;
    wire         s_axis_tx_tready;
    wire [3:0]   s_axis_tx_tuser;

    // Instantiate Xilinx 7-Series Integrated PCIe Block (pg054) - Gen2 x4, 128-bit AXI-Stream
    pcie_7x_0 u_pcie_ip (
        .pci_exp_txp(pci_exp_txp),
        .pci_exp_txn(pci_exp_txn),
        .pci_exp_rxp(pci_exp_rxp),
        .pci_exp_rxn(pci_exp_rxn),

        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .user_clk_out(pcie_user_clk),
        .user_reset_out(pcie_user_reset),
        .user_lnk_up(pcie_user_lnk_up),

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

        // Management & Config Interfaces
        .cfg_mgmt_di(32'h0),
        .cfg_mgmt_byte_en(4'h0),
        .cfg_mgmt_dwaddr(10'h0),
        .cfg_mgmt_wr_en(1'b0),
        .cfg_mgmt_rd_en(1'b0),
        .cfg_mgmt_wr_readonly(1'b0),
        .cfg_mgmt_wr_rw1c_as_rw(1'b0),

        // Error Reporting Inputs
        .cfg_err_ecrc(1'b0),
        .cfg_err_ur(1'b0),
        .cfg_err_cpl_timeout(1'b0),
        .cfg_err_cpl_unexpect(1'b0),
        .cfg_err_cpl_abort(1'b0),
        .cfg_err_posted(1'b0),
        .cfg_err_cor(1'b0),
        .cfg_err_atomic_egress_blocked(1'b0),
        .cfg_err_internal_cor(1'b0),
        .cfg_err_malformed(1'b0),
        .cfg_err_mc_blocked(1'b0),
        .cfg_err_poisoned(1'b0),
        .cfg_err_norecovery(1'b0),
        .cfg_err_tlp_cpl_header(48'h0),
        .cfg_err_locked(1'b0),
        .cfg_err_acs(1'b0),
        .cfg_err_internal_uncor(1'b0),
        .cfg_err_aer_headerlog(128'h0),
        .cfg_aer_interrupt_msgnum(5'b0),

        .tx_cfg_gnt(1'b1),
        .rx_np_ok(1'b1),
        .rx_np_req(1'b1),
        .cfg_trn_pending(1'b0),
        .cfg_pm_halt_aspm_l0s(1'b0),
        .cfg_pm_halt_aspm_l1(1'b0),
        .cfg_pm_force_state_en(1'b0),
        .cfg_pm_force_state(2'b00),
        .cfg_dsn(64'h0),
        .cfg_turnoff_ok(1'b0),
        .cfg_pm_wake(1'b0),

        .cfg_pm_send_pme_to(1'b0),
        .cfg_ds_bus_number(8'b0),
        .cfg_ds_device_number(5'b0),
        .cfg_ds_function_number(3'b0),
        .cfg_bus_number(cfg_bus_number),
        .cfg_device_number(cfg_device_number),
        .cfg_function_number(cfg_function_number),

        .cfg_interrupt(1'b0),
        .cfg_interrupt_assert(1'b0),
        .cfg_interrupt_di(8'b0),
        .cfg_interrupt_stat(1'b0),
        .cfg_pciecap_interrupt_msgnum(5'b0),

        .pl_directed_link_change(2'b00),
        .pl_directed_link_width(2'b00),
        .pl_directed_link_speed(1'b0),
        .pl_directed_link_auton(1'b0),
        .pl_upstream_prefer_deemph(1'b1),

        .pcie_drp_clk(1'b0),
        .pcie_drp_en(1'b0),
        .pcie_drp_we(1'b0),
        .pcie_drp_addr(9'h0),
        .pcie_drp_di(16'h0)
    );

    wire [7:0] cfg_bus_number;
    wire [4:0] cfg_device_number;
    wire [2:0] cfg_function_number;

    // Instantiate 7-Series PCIe AXI-Stream Protocol Bridge (256-bit internal CQ descriptor bus)
    pcie_7x_axi_bridge #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_pcie_bridge (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),

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

    // Instantiate Custom PCIe DMA Controller Top Module (256-bit internal CQ descriptor bus)
    custom_pcie_dma_top #(
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH),
        .NUM_VIDEO_CH(NUM_VIDEO_CH),
        .NUM_AUDIO_CH(NUM_AUDIO_CH),
        .VIDEO_DATA_WIDTH(VIDEO_DATA_WIDTH),
        .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH)
    ) u_dma_top (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),

        .s_axis_cq_tdata(m_axis_cq_tdata),
        .s_axis_cq_tvalid(m_axis_cq_tvalid),
        .s_axis_cq_tlast(m_axis_cq_tlast),
        .s_axis_cq_tuser(m_axis_cq_tuser),
        .s_axis_cq_tkeep(m_axis_cq_tkeep),
        .s_axis_cq_tready(m_axis_cq_tready),

        .m_axis_cc_tdata(s_axis_cc_tdata),
        .m_axis_cc_tvalid(s_axis_cc_tvalid),
        .m_axis_cc_tlast(s_axis_cc_tlast),
        .m_axis_cc_tuser(s_axis_cc_tuser),
        .m_axis_cc_tkeep(s_axis_cc_tkeep),
        .m_axis_cc_tready(s_axis_cc_tready),

        .m_axis_rq_tdata(s_axis_rq_tdata),
        .m_axis_rq_tvalid(s_axis_rq_tvalid),
        .m_axis_rq_tlast(s_axis_rq_tlast),
        .m_axis_rq_tuser(s_axis_rq_tuser),
        .m_axis_rq_tkeep(s_axis_rq_tkeep),
        .m_axis_rq_tready(s_axis_rq_tready),

        .s_axis_rc_tdata(m_axis_rc_tdata),
        .s_axis_rc_tvalid(m_axis_rc_tvalid),
        .s_axis_rc_tlast(m_axis_rc_tlast),
        .s_axis_rc_tuser(m_axis_rc_tuser),
        .s_axis_rc_tkeep(m_axis_rc_tkeep),
        .s_axis_rc_tready(m_axis_rc_tready),

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

        .s_axis_video_tdata(s_video_tdata),
        .s_axis_video_tvalid(s_video_tvalid),
        .s_axis_video_tlast(s_video_tlast),
        .s_axis_video_tuser(s_video_tuser),
        .s_axis_video_tready(s_video_tready),

        .m_axis_video_tdata(m_video_tdata),
        .m_axis_video_tvalid(m_video_tvalid),
        .m_axis_video_tlast(m_video_tlast),
        .m_axis_video_tuser(m_video_tuser),
        .m_axis_video_tready(m_video_tready),

        .s_axis_audio_tdata(s_audio_tdata),
        .s_axis_audio_tvalid(s_audio_tvalid),
        .s_axis_audio_tlast(s_audio_tlast),
        .s_axis_audio_tready(s_audio_tready),

        .m_axis_audio_tdata(m_audio_tdata),
        .m_axis_audio_tvalid(m_audio_tvalid),
        .m_axis_audio_tlast(m_audio_tlast),
        .m_axis_audio_tready(m_audio_tready),

        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

endmodule
