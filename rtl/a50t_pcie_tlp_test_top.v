`timescale 1ns / 1ps

module a50t_pcie_tlp_test_top (
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        sys_rst_n,
    output wire [3:0]  pci_exp_txp,
    output wire [3:0]  pci_exp_txn,
    input  wire [3:0]  pci_exp_rxp,
    input  wire [3:0]  pci_exp_rxn
);

    wire pcie_user_clk;
    wire pcie_user_reset;
    wire pcie_user_rst_n;
    wire pcie_user_lnk_up;
    assign pcie_user_rst_n = ~pcie_user_reset;

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

    wire [7:0]  cfg_bus_number;
    wire [4:0]  cfg_device_number;
    wire [2:0]  cfg_function_number;

    wire sys_clk;
    IBUFDS_GTE2 u_ibufds_gte2 (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .CEB(1'b0),
        .O(sys_clk),
        .ODIV2()
    );

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

        .cfg_mgmt_di(32'h0),
        .cfg_mgmt_byte_en(4'h0),
        .cfg_mgmt_dwaddr(10'h0),
        .cfg_mgmt_wr_en(1'b0),
        .cfg_mgmt_rd_en(1'b0),
        .cfg_mgmt_wr_readonly(1'b0),
        .cfg_mgmt_wr_rw1c_as_rw(1'b0),

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

    pcie_7x_tlp_loopback u_tlp_loopback (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),

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

        .cfg_bus_number(cfg_bus_number),
        .cfg_device_number(cfg_device_number),
        .cfg_function_number(cfg_function_number),

        .heartbeat_led()
    );

endmodule
