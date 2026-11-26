// ============================================================================
// Module: custom_pcie_dma_top
// Description: Multi-Channel 2D Video & Audio PCIe DMA Controller (AXI4-Stream Native).
//              Uses Verilog parameter & generator loops to configure arbitrary channels:
//              - NUM_VIDEO_CH: AXI4-Stream Video Interfaces (s_axis_video / m_axis_video)
//              - NUM_AUDIO_CH: AXI4-Stream AES3 Audio Interfaces (s_axis_audio / m_axis_audio)
//              - Dual-BAR: BAR0 (DMA Control), BAR1 (User IP Cores Interconnect)
//              - Direct Streaming Architecture: Completely replaces AXI MM with native streams.
// ============================================================================

`timescale 1ns / 1ps

module custom_pcie_dma_top #(
    parameter [31:0] C_VERSION = 32'h2610_1905,
    parameter PCIE_DATA_WIDTH  = 128,
    parameter PCIE_KEEP_WIDTH  = PCIE_DATA_WIDTH / 8,
    parameter NUM_VIDEO_CH     = 2,
    parameter NUM_AUDIO_CH     = 2,
    parameter VIDEO_DATA_WIDTH = 32,
    parameter AUDIO_DATA_WIDTH = 32,
    parameter ENABLE_PACKET_C2H = 0,
    // SC7F0-RGB-COMPOSITOR-2PPC.  0 leaves this file exactly as published.
    // 1 replaces the channel-0 NV12 capture engine with the packed-RGB24
    // engine (same thin-descriptor launch, same format code 4'd1, same C2H MWr
    // byte-enable and completion semantics, same video_req_cdc crossing) and
    // adds the plan-A overlay path: native 256-bit RC completions ->
    // sc7f0_overlay_ingress -> 128-bit 300 MHz stream -> sc7f0_overlay_writer
    // -> PS DDR.  Nothing here touches the H2C upgrade engine, the mailbox ABI
    // or the BAR0 register map.
    parameter ENABLE_RGB_COMPOSITOR = 0
)(
    input wire packet_req_valid,
    input wire [63:0] packet_req_addr,
    input wire [10:0] packet_req_dw_len,
    input wire [PCIE_DATA_WIDTH-1:0] packet_req_data,
    input wire [3:0] packet_req_first_be, packet_req_last_be,
    output wire packet_req_data_ready, packet_req_ack,
    input wire packet_done_irq,
    input wire [31:0] in_pkt_submit_cnt,
    input wire [31:0] in_pkt_done_cnt,
    input wire [31:0] in_pkt_err_cnt,
    input wire [31:0] in_pkt_msi_cnt,
    input wire [31:0] in_pkt_bytes_lo,
    input wire [31:0] in_pkt_bytes_hi,
    input wire [31:0] in_pkt_fsm_state,
    input wire [31:0] in_pkt_last_len,
    input wire [31:0] in_pkt_last_pts_lo,
    input wire [31:0] in_pkt_last_pts_hi,
    input  wire                                             clk,
    input  wire                                             pl_clk0,
    input  wire                                             pl_resetn0,
    input  wire                                             sys_100m_rst_n,
    input  wire [15:0]                                      ps_hpm0_arid,
    input  wire [7:0]                                       ps_hpm0_arlen,
    input  wire [2:0]                                       ps_hpm0_arsize,
    input  wire                                             ps_hpm0_arvalid_raw,
    input  wire                                             ps_hpm0_arready_raw,
    input  wire [15:0]                                      ps_hpm0_rid_raw,
    input  wire                                             ps_hpm0_rvalid_raw,
    input  wire                                             rst_n,

    // PCIe CQ Interface (PCIe IP -> DMA Top)
    input  wire [PCIE_DATA_WIDTH-1:0]                       s_axis_cq_tdata,
    input  wire                                             s_axis_cq_tvalid,
    input  wire                                             s_axis_cq_tlast,
    input  wire [87:0]                                      s_axis_cq_tuser,
    input  wire [PCIE_KEEP_WIDTH-1:0]                       s_axis_cq_tkeep,
    output wire                                             s_axis_cq_tready,

    // PCIe CC Interface (DMA Top -> PCIe IP)
    output wire [PCIE_DATA_WIDTH-1:0]                       m_axis_cc_tdata,
    output wire                                             m_axis_cc_tvalid,
    output wire                                             m_axis_cc_tlast,
    output wire [32:0]                                      m_axis_cc_tuser,
    output wire [PCIE_KEEP_WIDTH-1:0]                       m_axis_cc_tkeep,
    input  wire                                             m_axis_cc_tready,

    // PCIe RQ Interface (DMA Top -> PCIe IP)
    output wire [PCIE_DATA_WIDTH-1:0]                       m_axis_rq_tdata,
    output wire                                             m_axis_rq_tvalid,
    output wire                                             m_axis_rq_tlast,
    output wire [61:0]                                      m_axis_rq_tuser,
    output wire [PCIE_KEEP_WIDTH-1:0]                       m_axis_rq_tkeep,
    input  wire                                             m_axis_rq_tready,

    // PCIe RC Interface (PCIe IP -> DMA Top)
    input  wire [PCIE_DATA_WIDTH-1:0]                       s_axis_rc_tdata,
    input  wire                                             s_axis_rc_tvalid,
    input  wire                                             s_axis_rc_tlast,
    input  wire [74:0]                                      s_axis_rc_tuser,
    input  wire [PCIE_KEEP_WIDTH-1:0]                       s_axis_rc_tkeep,
    output wire                                             s_axis_rc_tready,

    // Dynamic PCIe Requester ID (Bus/Device/Function)
    input  wire [15:0]                                      requester_id,

    // BAR1 AXI4-Lite Master Interface (Connects to Interconnect for User IP Cores: I2C, UART, etc.)
    output wire [31:0]                                      m_axil_bar1_awaddr,
    output wire                                             m_axil_bar1_awvalid,
    input  wire                                             m_axil_bar1_awready,
    output wire [31:0]                                      m_axil_bar1_wdata,
    output wire [3:0]                                       m_axil_bar1_wstrb,
    output wire                                             m_axil_bar1_wvalid,
    input  wire                                             m_axil_bar1_wready,
    input  wire [1:0]                                       m_axil_bar1_bresp,
    input  wire                                             m_axil_bar1_bvalid,
    output wire                                             m_axil_bar1_bready,

    output wire [31:0]                                      m_axil_bar1_araddr,
    output wire                                             m_axil_bar1_arvalid,
    input  wire                                             m_axil_bar1_arready,
    input  wire [31:0]                                      m_axil_bar1_rdata,
    input  wire [1:0]                                       m_axil_bar1_rresp,
    input  wire                                             m_axil_bar1_rvalid,
    output wire                                             m_axil_bar1_rready,

    // Multi-Channel AXI4-Stream Video Interfaces (s_axis_video: C2H In, m_axis_video: H2C Out)
    input  wire [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0]       s_axis_video_tdata,
    input  wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tvalid,
    input  wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tlast,
    input  wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tuser, // tuser[0] = SOF
    output wire [NUM_VIDEO_CH-1:0]                          s_axis_video_tready,

    // 150 MHz NV12 capture domain (channel 0). The engine runs here and its
    // C2H requests cross back through video_req_cdc.
    input  wire                                             video_clk,
    input  wire                                             video_rst_n,
    input  wire [127:0]                                     video_ch0_tdata,
    input  wire                                             video_ch0_tvalid,
    input  wire                                             video_ch0_tlast,
    input  wire                                             video_ch0_tuser,
    output wire                                             video_ch0_tready,
    output wire                                             video_capture_active, // video_clk domain

    output wire [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0]       m_axis_video_tdata,
    output wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tvalid,
    output wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tlast,
    output wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tuser,
    input  wire [NUM_VIDEO_CH-1:0]                          m_axis_video_tready,

    // Multi-Channel AXI4-Stream Audio Interfaces (AES3 Subframes)
    input  wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0]       s_axis_audio_tdata,
    input  wire [NUM_AUDIO_CH-1:0]                          s_axis_audio_tvalid,
    input  wire [NUM_AUDIO_CH-1:0]                          s_axis_audio_tlast,
    output wire [NUM_AUDIO_CH-1:0]                          s_axis_audio_tready,

    output wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0]       m_axis_audio_tdata,
    output wire [NUM_AUDIO_CH-1:0]                          m_axis_audio_tvalid,
    output wire [NUM_AUDIO_CH-1:0]                          m_axis_audio_tlast,
    input  wire [NUM_AUDIO_CH-1:0]                          m_axis_audio_tready,

    // Video pipeline control exported to the board-level clock/CDC logic.
    output wire                                             video_pipeline_reset,
    output wire                                             video_tpg_reset,
    output wire                                             video_engine_reset,
    output wire                                             overlay_en,
    output wire [15:0]                                      overlay_width,
    output wire [15:0]                                      overlay_height,
    output wire [31:0]                                      out_vch0_ctrl,

    // Interrupt Pins
    output wire                                             usr_irq_req,
    input  wire                                             usr_irq_ack,

    // HDMI RX & TX Status and Control Ports
    input  wire [31:0]                                      in_hdmi_rx_status,
    input  wire [31:0]                                      in_hdmi_rx_res,
    input  wire [31:0]                                      in_hdmi_rx_timing,
    input  wire [31:0]                                      in_hdmi_rx_audio,
    output wire [31:0] out_audio_capture_control,
    input wire [31:0] in_audio_rx_frames, in_audio_rx_errors,
    input wire [31:0] in_audio_rx_channels, in_audio_rx_cs,
    input  wire [31:0]                                      in_hdmi_tx_status,
    output wire [31:0]                                      out_hdmi_tx_ctrl,
    output wire [31:0]                                      out_hdmi_tx_res,
    output wire [31:0]                                      out_hdmi_tx_fps,
    output wire [31:0]                                      out_hdmi_ipc_cmd,
    output wire [31:0]                                      out_hdmi_ipc_arg,
    output wire [31:0]                                      out_hdmi_ipc_status,
    output wire [31:0]                                      out_hdmi_ipc_doorbell,

    // Probing & Diagnostic Ports (BAR0 0x0680 - 0x06DC)
    input  wire [31:0]                                      in_probe_version,
    input  wire [31:0]                                      in_probe_rx_clk_freq,
    input  wire [31:0]                                      in_probe_dru_clk_freq,
    input  wire [31:0]                                      in_probe_rxoutclk_freq,
    input  wire [31:0]                                      in_probe_rx_video_clk_freq,
    input  wire [31:0]                                      in_probe_tx_clk_freq,
    input  wire [31:0]                                      in_probe_txoutclk_freq,
    input  wire [31:0]                                      in_probe_tx_video_clk_freq,
    input  wire [31:0]                                      in_probe_pins,
    input  wire [31:0]                                      in_probe_pulse_cnt1,
    input  wire [31:0]                                      in_probe_ddc_cnt,
    input  wire [31:0]                                      in_probe_irq_cnt,
    input  wire [31:0]                                      in_probe_ch0_beats,
    input  wire [31:0]                                      in_probe_ch1_beats,
    input  wire [31:0]                                      in_probe_ch2_beats,
    input  wire [31:0]                                      in_probe_rx_video_sof,
    input  wire [31:0]                                      in_probe_rx_video_eol,
    input  wire [31:0]                                      in_probe_rx_video_pix,
    input  wire [31:0]                                      in_probe_raw_rx_clk,
    input  wire [31:0]                                      in_probe_raw_dru_clk,
    input  wire [31:0]                                      in_probe_raw_rxoutclk,
    input  wire [31:0]                                      in_probe_raw_rx_video_clk,
    input  wire [31:0]                                      in_probe_raw_refclk100,
    output wire [31:0]                                      out_probe_ctrl,

    // PS ARM Linux AXI4-Lite Slave Interface (from PS M_AXI_HPM0_FPD)
    input  wire [31:0]                                      s_axil_ps_awaddr,
    input  wire                                             s_axil_ps_awvalid,
    output wire                                             s_axil_ps_awready,
    input  wire [31:0]                                      s_axil_ps_wdata,
    input  wire [3:0]                                       s_axil_ps_wstrb,
    input  wire                                             s_axil_ps_wvalid,
    output wire                                             s_axil_ps_wready,
    output wire [1:0]                                       s_axil_ps_bresp,
    output wire                                             s_axil_ps_bvalid,
    input  wire                                             s_axil_ps_bready,
    input  wire [31:0]                                      s_axil_ps_araddr,
    input  wire                                             s_axil_ps_arvalid,
    output wire                                             s_axil_ps_arready,
    output wire [31:0]                                      s_axil_ps_rdata,
    output wire [1:0]                                       s_axil_ps_rresp,
    output wire                                             s_axil_ps_rvalid,
    input  wire                                             s_axil_ps_rready,

    // PS DDR4 AXI4 Master Write Interface (to PS S_AXI_HP0_FPD)
    output wire [48:0]                                      m_axi_hp0_awaddr,
    output wire [7:0]                                       m_axi_hp0_awlen,
    output wire [2:0]                                       m_axi_hp0_awsize,
    output wire [1:0]                                       m_axi_hp0_awburst,
    output wire                                             m_axi_hp0_awvalid,
    input  wire                                             m_axi_hp0_awready,
    output wire [127:0]                                     m_axi_hp0_wdata,
    output wire [15:0]                                      m_axi_hp0_wstrb,
    output wire                                             m_axi_hp0_wlast,
    output wire                                             m_axi_hp0_wvalid,
    input  wire                                             m_axi_hp0_wready,
    input  wire [1:0]                                       m_axi_hp0_bresp,
    input  wire                                             m_axi_hp0_bvalid,
    output wire                                             m_axi_hp0_bready,
    output wire [48:0]                                      m_axi_hp0_araddr,
    output wire                                             m_axi_hp0_arvalid,
    input wire                                              m_axi_hp0_arready,
    input wire [127:0]                                      m_axi_hp0_rdata,
    input wire [1:0]                                        m_axi_hp0_rresp,
    input wire [5:0]                                        m_axi_hp0_rid,
    input wire                                              m_axi_hp0_rlast, m_axi_hp0_rvalid,
    output wire                                             m_axi_hp0_rready,

    // PS Interrupt Notification Pulse (to PS pl_ps_irq0)
    output wire                                             out_ps_irq_pulse,

    // ---- SC7F0-RGB-COMPOSITOR-2PPC (ENABLE_RGB_COMPOSITOR) ---------------
    // Packed RGB24 payload arriving in the video_clk domain from
    // rtl/sc7f0_rgb24_axis_pack.v.  video_ch0_tdata/tvalid/tuser/tready are
    // reused as that stream (tuser = first beat of a source frame); only the
    // FIFO occupancy and the two sticky source faults are new, because the
    // engine must be able to refuse a frame it cannot place rather than write
    // a torn one.
    input  wire [10:0]                                      video_ch0_avail,
    input  wire                                             video_ch0_src_overflow_sticky,
    input  wire                                             video_ch0_src_line_align_sticky,

    // Negotiated Extended Tag Field Enable from the PCIe core (real config
    // input, never tied).  Tag 64..127 only exists once the host has set the
    // Device Control bit; with this low the overlay simply cannot arm and
    // ovl_ext_tag_unsupported reports why.  The legacy 0..63 pool and the
    // upgrade path never look at it.
    input  wire                                             ext_tag_enable,

    // Overlay transfer arm / status (PCIe user clock domain)
    input  wire                                             ovl_enable,
    input  wire [63:0]                                      ovl_src_addr,
    input  wire [31:0]                                      ovl_xfer_bytes,
    input  wire [15:0]                                      ovl_max_bytes_per_req,
    input  wire                                             ovl_go,
    // Review H1: software-requested plane discard (from the overlay control block).
    // It releases the ingress arm AND tells the writer to retire, which plain
    // ovl_quiesce deliberately does not do.
    input  wire                                             ovl_abort_req,
    input  wire                                             ovl_quiesce_req,
    input  wire                                             ovl_discard_pending,
    output wire [31:0]                                      ovl_status_bytes_issued,
    output wire [31:0]                                      ovl_status_bytes_staged,
    output wire [31:0]                                      ovl_status_bytes_drained,
    output wire [5:0]                                       ovl_status_outstanding,
    output wire                                             ovl_status_busy,
    output wire                                             ovl_status_quiesced,
    output wire                                             ovl_status_quarantined,
    output wire                                             ovl_status_ext_tag_blocked,
    output wire [31:0]                                      ovl_status_counts,
    // Review H2: the video-descriptor format guard of THIS profile's channel 0.
    // A refused descriptor launches no DMA and raises these instead; nothing
    // else in the design is gated by them.
    output wire                                             ovl_video_guard_sticky,
    output wire [31:0]                                      ovl_video_guard_count,
    // Review H1: plane-discard handshake with the plane writer
    output wire                                             ovl_wr_abort_busy,
    output wire [31:0]                                      ovl_wr_err_frames,
    output wire                                             ovl_video_poison,

    // Overlay plane writer (memory clock domain, PS HP3)
    input  wire                                             ovl_mem_clk,
    input  wire                                             ovl_mem_rst_n,
    input  wire                                             ovl_wr_enable,
    input  wire [48:0]                                      ovl_wr_dst_base,
    input  wire [31:0]                                      ovl_wr_slot_bytes,
    input  wire [2:0]                                       ovl_wr_slot_count,
    input  wire [31:0]                                      ovl_wr_frame_bytes,
    input  wire                                             ovl_wr_auto_advance,
    input  wire [1:0]                                       ovl_wr_force_slot,
    input  wire [3:0]                                       ovl_wr_consume,
    output wire [3:0]                                       ovl_wr_slot_ready,
    output wire                                             ovl_wr_busy,
    output wire [1:0]                                       ovl_wr_active_slot,
    output wire [31:0]                                      ovl_wr_frames_done,
    output wire [31:0]                                      ovl_wr_bytes_written,
    output wire [5:0]                                       ovl_wr_sticky,
    output wire [3:0]                                       ovl_axi_dbg,
    output wire                                             ovl_wr_irq_pulse,
    output wire [48:0]                                      ovl_awaddr,
    output wire [7:0]                                       ovl_awlen,
    output wire [2:0]                                       ovl_awsize,
    output wire [1:0]                                       ovl_awburst,
    output wire [3:0]                                       ovl_awcache,
    output wire                                             ovl_awvalid,
    input  wire                                             ovl_awready,
    output wire [127:0]                                     ovl_wdata,
    output wire [15:0]                                      ovl_wstrb,
    output wire                                             ovl_wlast,
    output wire                                             ovl_wvalid,
    input  wire                                             ovl_wready,
    input  wire [1:0]                                       ovl_bresp,
    input  wire                                             ovl_bvalid,
    output wire                                             ovl_bready,

    // Hardware Reader-B slot auto-advance handshake (ovl_mem_clk domain)
    input  wire [3:0]                                       ovl_wr_slot_release_m,
    output wire [3:0]                                       ovl_wr_slot_ready_m,
    output wire [1:0]                                       ovl_wr_last_slot_m,
    output wire [31:0]                                      ovl_wr_slot_bytes_m,

    // Direct pull-mode H2C overlay stream (ovl_mem_clk domain)
    input wire [1:0] flip_control,
    input wire flip_submit, flip_sof,
    input wire [31:0] flip_cookie, flip_present,
    output wire [31:0] flip_tag, flip_admitted, flip_pending, flip_active, flip_retired, flip_frame,
    output wire [1:0] flip_status,
    input  wire                                             ovl_base_vblank_p,
    output wire [63:0]                                      ovl_direct_tdata,
    output wire                                             ovl_direct_tvalid,
    input  wire                                             ovl_direct_tready,
    output wire                                             ovl_direct_tlast,
    output wire                                             ovl_direct_tuser,

    // PCIe BAR0 0x4000..0x4FFF Overlay CSR Master (pcie_user_clk domain)
    output wire [31:0]                                      m_axil_ovl_awaddr,
    output wire                                             m_axil_ovl_awvalid,
    input  wire                                             m_axil_ovl_awready,
    output wire [31:0]                                      m_axil_ovl_wdata,
    output wire [3:0]                                       m_axil_ovl_wstrb,
    output wire                                             m_axil_ovl_wvalid,
    input  wire                                             m_axil_ovl_wready,
    input  wire [1:0]                                       m_axil_ovl_bresp,
    input  wire                                             m_axil_ovl_bvalid,
    output wire                                             m_axil_ovl_bready,
    output wire [31:0]                                      m_axil_ovl_araddr,
    output wire                                             m_axil_ovl_arvalid,
    input  wire                                             m_axil_ovl_arready,
    input  wire [31:0]                                      m_axil_ovl_rdata,
    input  wire [1:0]                                       m_axil_ovl_rresp,
    input  wire                                             m_axil_ovl_rvalid,
    output wire                                             m_axil_ovl_rready
);

    // Internal Wires for BAR0 Inter-module Connection
    wire [31:0] bar0_axil_awaddr, bar0_axil_wdata, bar0_axil_araddr, bar0_axil_rdata;
    wire [3:0]  bar0_axil_wstrb;
    wire [1:0]  bar0_axil_bresp, bar0_axil_rresp;
    wire        bar0_axil_awvalid, bar0_axil_awready, bar0_axil_wvalid, bar0_axil_wready;
    wire        bar0_axil_bvalid, bar0_axil_bready, bar0_axil_arvalid, bar0_axil_arready;
    wire        bar0_axil_rvalid, bar0_axil_rready;

    // Arbitrated AXI-Lite signals driving axil_reg_space (PCIe BAR0 + PS HPM0_FPD)
    // M00 (0x000-0xFFF). Shared PS/PCIe: transaction-atomic via crossbar.
    wire [31:0] arb_axil_awaddr, arb_axil_wdata, arb_axil_araddr, arb_axil_rdata;
    wire [3:0]  arb_axil_wstrb;
    wire [1:0]  arb_axil_bresp, arb_axil_rresp;
    wire        arb_axil_awvalid, arb_axil_awready, arb_axil_wvalid, arb_axil_wready;
    wire        arb_axil_bvalid, arb_axil_bready, arb_axil_arvalid, arb_axil_arready;
    wire        arb_axil_rvalid, arb_axil_rready;

    // Arbitrated AXI-Lite signals driving zzlab_env_ctrl (version/platform)
    // M01 (0x1000-0x1FFF). Shared PS/PCIe so eMMC standalone boot (no PCIe
    // clock) can still read version info for triage.
    wire [31:0] env_axil_awaddr, env_axil_wdata, env_axil_araddr, env_axil_rdata;
    wire [3:0]  env_axil_wstrb;
    wire [1:0]  env_axil_bresp, env_axil_rresp;
    wire        env_axil_awvalid, env_axil_awready, env_axil_wvalid, env_axil_wready;
    wire        env_axil_bvalid, env_axil_bready, env_axil_arvalid, env_axil_arready;
    wire        env_axil_rvalid, env_axil_rready;
    wire [31:0] env_ap_rst_n;

    // M02: dedicated 8 KiB debug mailbox, BAR0 0x2000..0x3fff.
    wire [31:0] dbg_axil_awaddr, dbg_axil_wdata, dbg_axil_araddr, dbg_axil_rdata;
    wire [3:0] dbg_axil_wstrb;
    wire [1:0] dbg_axil_bresp, dbg_axil_rresp;
    wire dbg_axil_awvalid, dbg_axil_awready, dbg_axil_wvalid, dbg_axil_wready;
    wire dbg_axil_bvalid, dbg_axil_bready, dbg_axil_arvalid, dbg_axil_arready;
    wire dbg_axil_rvalid, dbg_axil_rready;
    qpcie_debug_mailbox u_debug_mailbox (
        .clk(pl_clk0), .rst_n(sys_100m_rst_n),
        .s_axi_awaddr(dbg_axil_awaddr[12:0]),
        .s_axi_awvalid(dbg_axil_awvalid), .s_axi_awready(dbg_axil_awready),
        .s_axi_wdata(dbg_axil_wdata), .s_axi_wstrb(dbg_axil_wstrb),
        .s_axi_wvalid(dbg_axil_wvalid), .s_axi_wready(dbg_axil_wready),
        .s_axi_bresp(dbg_axil_bresp), .s_axi_bvalid(dbg_axil_bvalid),
        .s_axi_bready(dbg_axil_bready), .s_axi_araddr(dbg_axil_araddr[12:0]),
        .s_axi_arvalid(dbg_axil_arvalid), .s_axi_arready(dbg_axil_arready),
        .s_axi_rdata(dbg_axil_rdata), .s_axi_rresp(dbg_axil_rresp),
        .s_axi_rvalid(dbg_axil_rvalid), .s_axi_rready(dbg_axil_rready)
    );

    wire [31:0] cvt_bar0_axil_awaddr, cvt_bar0_axil_wdata, cvt_bar0_axil_araddr, cvt_bar0_axil_rdata;
    wire [3:0]  cvt_bar0_axil_wstrb;
    wire [1:0]  cvt_bar0_axil_bresp, cvt_bar0_axil_rresp;
    wire        cvt_bar0_axil_awvalid, cvt_bar0_axil_awready, cvt_bar0_axil_wvalid, cvt_bar0_axil_wready;
    wire        cvt_bar0_axil_bvalid, cvt_bar0_axil_bready, cvt_bar0_axil_arvalid, cvt_bar0_axil_arready;
    wire        cvt_bar0_axil_rvalid, cvt_bar0_axil_rready;

    // Production dual-path design: PS AXI ILA removed. The independent
    // debug mailbox and normal PS/PCIe AXI control path remain intact.

    wire [31:0] bar0_def_awaddr, bar0_def_wdata, bar0_def_araddr, bar0_def_rdata;
    wire [3:0]  bar0_def_wstrb;
    wire [1:0]  bar0_def_bresp, bar0_def_rresp;
    wire        bar0_def_awvalid, bar0_def_awready, bar0_def_wvalid, bar0_def_wready;
    wire        bar0_def_bvalid, bar0_def_bready, bar0_def_arvalid, bar0_def_arready;
    wire        bar0_def_rvalid, bar0_def_rready;

    sc7f0_axil_demux_1to2 u_bar0_demux (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(bar0_axil_awaddr), .s_awvalid(bar0_axil_awvalid), .s_awready(bar0_axil_awready),
        .s_wdata(bar0_axil_wdata),   .s_wstrb(bar0_axil_wstrb),     .s_wvalid(bar0_axil_wvalid),   .s_wready(bar0_axil_wready),
        .s_bresp(bar0_axil_bresp),   .s_bvalid(bar0_axil_bvalid),   .s_bready(bar0_axil_bready),
        .s_araddr(bar0_axil_araddr), .s_arvalid(bar0_axil_arvalid), .s_arready(bar0_axil_arready),
        .s_rdata(bar0_axil_rdata),   .s_rresp(bar0_axil_rresp),     .s_rvalid(bar0_axil_rvalid),   .s_rready(bar0_axil_rready),
        .m0_awaddr(bar0_def_awaddr), .m0_awvalid(bar0_def_awvalid), .m0_awready(bar0_def_awready),
        .m0_wdata(bar0_def_wdata),   .m0_wstrb(bar0_def_wstrb),     .m0_wvalid(bar0_def_wvalid),   .m0_wready(bar0_def_wready),
        .m0_bresp(bar0_def_bresp),   .m0_bvalid(bar0_def_bvalid),   .m0_bready(bar0_def_bready),
        .m0_araddr(bar0_def_araddr), .m0_arvalid(bar0_def_arvalid), .m0_arready(bar0_def_arready),
        .m0_rdata(bar0_def_rdata),   .m0_rresp(bar0_def_rresp),     .m0_rvalid(bar0_def_rvalid),   .m0_rready(bar0_def_rready),
        .m1_awaddr(m_axil_ovl_awaddr), .m1_awvalid(m_axil_ovl_awvalid), .m1_awready(m_axil_ovl_awready),
        .m1_wdata(m_axil_ovl_wdata),   .m1_wstrb(m_axil_ovl_wstrb),     .m1_wvalid(m_axil_ovl_wvalid),   .m1_wready(m_axil_ovl_wready),
        .m1_bresp(m_axil_ovl_bresp),   .m1_bvalid(m_axil_ovl_bvalid),   .m1_bready(m_axil_ovl_bready),
        .m1_araddr(m_axil_ovl_araddr), .m1_arvalid(m_axil_ovl_arvalid), .m1_arready(m_axil_ovl_arready),
        .m1_rdata(m_axil_ovl_rdata),   .m1_rresp(m_axil_ovl_rresp),     .m1_rvalid(m_axil_ovl_rvalid),   .m1_rready(m_axil_ovl_rready)
    );

    axi_clock_converter_0 u_axi_clock_converter_0 (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
        .s_axi_awaddr(bar0_def_awaddr),
        .s_axi_awprot(3'd0),
        .s_axi_awvalid(bar0_def_awvalid),
        .s_axi_awready(bar0_def_awready),
        .s_axi_wdata(bar0_def_wdata),
        .s_axi_wstrb(bar0_def_wstrb),
        .s_axi_wvalid(bar0_def_wvalid),
        .s_axi_wready(bar0_def_wready),
        .s_axi_bresp(bar0_def_bresp),
        .s_axi_bvalid(bar0_def_bvalid),
        .s_axi_bready(bar0_def_bready),
        .s_axi_araddr(bar0_def_araddr),
        .s_axi_arprot(3'd0),
        .s_axi_arvalid(bar0_def_arvalid),
        .s_axi_arready(bar0_def_arready),
        .s_axi_rdata(bar0_def_rdata),
        .s_axi_rresp(bar0_def_rresp),
        .s_axi_rvalid(bar0_def_rvalid),
        .s_axi_rready(bar0_def_rready),
        
        .m_axi_aclk(pl_clk0),
        .m_axi_aresetn(sys_100m_rst_n),
        .m_axi_awaddr(cvt_bar0_axil_awaddr),
        .m_axi_awprot(),
        .m_axi_awvalid(cvt_bar0_axil_awvalid),
        .m_axi_awready(cvt_bar0_axil_awready),
        .m_axi_wdata(cvt_bar0_axil_wdata),
        .m_axi_wstrb(cvt_bar0_axil_wstrb),
        .m_axi_wvalid(cvt_bar0_axil_wvalid),
        .m_axi_wready(cvt_bar0_axil_wready),
        .m_axi_bresp(cvt_bar0_axil_bresp),
        .m_axi_bvalid(cvt_bar0_axil_bvalid),
        .m_axi_bready(cvt_bar0_axil_bready),
        .m_axi_araddr(cvt_bar0_axil_araddr),
        .m_axi_arprot(),
        .m_axi_arvalid(cvt_bar0_axil_arvalid),
        .m_axi_arready(cvt_bar0_axil_arready),
        .m_axi_rdata(cvt_bar0_axil_rdata),
        .m_axi_rresp(cvt_bar0_axil_rresp),
        .m_axi_rvalid(cvt_bar0_axil_rvalid),
        .m_axi_rready(cvt_bar0_axil_rready)
    );

    axi_crossbar_1 u_axi_crossbar_1 (
        .aclk(pl_clk0),
        .aresetn(sys_100m_rst_n),
        // Strip the PS 0xA0000000 base, preserving the full 1 MiB BAR0
        // offset (not just 13 bits, which aliases the debug window to CSR).
        .s_axi_awaddr({{12'd0, s_axil_ps_awaddr[19:0]}, cvt_bar0_axil_awaddr}),
        .s_axi_awprot(6'd0),
        .s_axi_awvalid({s_axil_ps_awvalid, cvt_bar0_axil_awvalid}),
        .s_axi_awready({s_axil_ps_awready, cvt_bar0_axil_awready}),
        .s_axi_wdata({s_axil_ps_wdata, cvt_bar0_axil_wdata}),
        .s_axi_wstrb({s_axil_ps_wstrb, cvt_bar0_axil_wstrb}),
        .s_axi_wvalid({s_axil_ps_wvalid, cvt_bar0_axil_wvalid}),
        .s_axi_wready({s_axil_ps_wready, cvt_bar0_axil_wready}),
        .s_axi_bresp({s_axil_ps_bresp, cvt_bar0_axil_bresp}),
        .s_axi_bvalid({s_axil_ps_bvalid, cvt_bar0_axil_bvalid}),
        .s_axi_bready({s_axil_ps_bready, cvt_bar0_axil_bready}),
        .s_axi_araddr({{12'd0, s_axil_ps_araddr[19:0]}, cvt_bar0_axil_araddr}),
        .s_axi_arprot(6'd0),
        .s_axi_arvalid({s_axil_ps_arvalid, cvt_bar0_axil_arvalid}),
        .s_axi_arready({s_axil_ps_arready, cvt_bar0_axil_arready}),
        .s_axi_rdata({s_axil_ps_rdata, cvt_bar0_axil_rdata}),
        .s_axi_rresp({s_axil_ps_rresp, cvt_bar0_axil_rresp}),
        .s_axi_rvalid({s_axil_ps_rvalid, cvt_bar0_axil_rvalid}),
        .s_axi_rready({s_axil_ps_rready, cvt_bar0_axil_rready}),

        // M02 = debug mailbox, M01 = zzlab_env_ctrl, M00 = axil_reg_space
        .m_axi_awaddr({dbg_axil_awaddr, env_axil_awaddr, arb_axil_awaddr}),
        .m_axi_awprot(),
        .m_axi_awvalid({dbg_axil_awvalid, env_axil_awvalid, arb_axil_awvalid}),
        .m_axi_awready({dbg_axil_awready, env_axil_awready, arb_axil_awready}),
        .m_axi_wdata({dbg_axil_wdata, env_axil_wdata, arb_axil_wdata}),
        .m_axi_wstrb({dbg_axil_wstrb, env_axil_wstrb, arb_axil_wstrb}),
        .m_axi_wvalid({dbg_axil_wvalid, env_axil_wvalid, arb_axil_wvalid}),
        .m_axi_wready({dbg_axil_wready, env_axil_wready, arb_axil_wready}),
        .m_axi_bresp({dbg_axil_bresp, env_axil_bresp, arb_axil_bresp}),
        .m_axi_bvalid({dbg_axil_bvalid, env_axil_bvalid, arb_axil_bvalid}),
        .m_axi_bready({dbg_axil_bready, env_axil_bready, arb_axil_bready}),
        .m_axi_araddr({dbg_axil_araddr, env_axil_araddr, arb_axil_araddr}),
        .m_axi_arprot(),
        .m_axi_arvalid({dbg_axil_arvalid, env_axil_arvalid, arb_axil_arvalid}),
        .m_axi_arready({dbg_axil_arready, env_axil_arready, arb_axil_arready}),
        .m_axi_rdata({dbg_axil_rdata, env_axil_rdata, arb_axil_rdata}),
        .m_axi_rresp({dbg_axil_rresp, env_axil_rresp, arb_axil_rresp}),
        .m_axi_rvalid({dbg_axil_rvalid, env_axil_rvalid, arb_axil_rvalid}),
        .m_axi_rready({dbg_axil_rready, env_axil_rready, arb_axil_rready})
    );

    // =========================================================================
    // ZZLAB Environment Control Register Block (zzlab_env_ctrl)
    // BAR0 Offset 0x1000 - 0x1FFF (was BAR1 0x0000). On pl_clk0 so PS and
    // PCIe host share access; readable during eMMC standalone boot.
    // =========================================================================
    zzlab_env_ctrl #(
        .C_S_AXI_ADDR_WIDTH(6),
        .C_S_AXI_DATA_WIDTH(32),
        .C_VERSION(C_VERSION),
        .C_PLATFORM("PCIE"),
        .C_BOARD_VERSION(32'h00000101)
    ) u_zzlab_env_ctrl (
        .clk                (pl_clk0),
        .rst_n              (sys_100m_rst_n),
        .s_axi_ctrl_awaddr  (env_axil_awaddr[5:0]),
        .s_axi_ctrl_awvalid (env_axil_awvalid),
        .s_axi_ctrl_awready (env_axil_awready),
        .s_axi_ctrl_wdata   (env_axil_wdata),
        .s_axi_ctrl_wstrb   (env_axil_wstrb),
        .s_axi_ctrl_wvalid  (env_axil_wvalid),
        .s_axi_ctrl_wready  (env_axil_wready),
        .s_axi_ctrl_bresp   (env_axil_bresp),
        .s_axi_ctrl_bvalid  (env_axil_bvalid),
        .s_axi_ctrl_bready  (env_axil_bready),
        .s_axi_ctrl_araddr  (env_axil_araddr[5:0]),
        .s_axi_ctrl_arvalid (env_axil_arvalid),
        .s_axi_ctrl_arready (env_axil_arready),
        .s_axi_ctrl_rdata   (env_axil_rdata),
        .s_axi_ctrl_rresp   (env_axil_rresp),
        .s_axi_ctrl_rvalid  (env_axil_rvalid),
        .s_axi_ctrl_rready  (env_axil_rready),
        .ap_rst_n           (env_ap_rst_n)
    );

    wire        read_req_valid, read_req_ack, read_req_bar_sel;
    wire [7:0]  read_req_tag;
    wire [15:0] read_req_id;
    wire [6:0]  read_req_lower_addr;
    wire [10:0] read_req_tc;

    wire [31:0] reg_dma_ctrl, reg_dma_status, reg_irq_ctrl, reg_irq_status;
    wire        global_reset_pulse_w; // From axil_reg_space BAR0[0x14] — flushes DMA-domain FIFOs

    // BAR0[0x14] is transported as a one-cycle *event* in `clk` (pcie_user_clk).
    // It used to be ANDed straight into dma_rst_n, which made a single-cycle
    // cross-domain event the asynchronous preset of the whole DMA domain and of
    // every xpm_cdc_async_rst fed by dma_rst_n.  report_cdc proved the failure
    // mode: CDC-10 row
    //   u_axil_reg_space/u_controls/dest_event_reg[0]/C
    //     -> u_dma_top/u_video_req_cdc/u_wr_reset/arststages_ff_reg[0]/PRE
    // Whether a destination clock saw that one cycle was undefined.
    //
    // Now the event becomes a controlled in-domain reset *level*: asserted for
    // at least GLOBAL_RESET_HOLD cycles of clk, which is how the flush stays
    // provable for any slower destination clock, and how it can never be lost
    // (the event is captured by an ordinary same-domain flop, not synchronised).
    localparam GLOBAL_RESET_HOLD = 64;
    wire global_reset_hold_n;
    (* MARK_DEBUG = "TRUE" *) wire global_reset_busy; // flush in progress, probe-only
    sc7f0_event_reset #(.WIDTH(1), .HOLD_CYCLES(GLOBAL_RESET_HOLD)) u_global_reset_hold (
        .evt_clk   (clk),
        .evt_rst_n (rst_n),
        .evt       (global_reset_pulse_w),
        .rst_n     (global_reset_hold_n),
        .pending   (global_reset_busy)
    );

    // dma_rst_n is now a level built only from terms that have each crossed into
    // `clk` through their own synchronizer (rtl/sc7f0_reset_cdc.v).  It is safe
    // as the async preset of the DMA-domain flops and as one source for the
    // video FIFO reset below.
    wire dma_rst_n;
    sc7f0_reset_sync #(.SOURCES(3)) u_dma_reset (
        .dest_clk   (clk),
        .src_rst_n  ({global_reset_hold_n, !reg_dma_ctrl[1], rst_n}),
        .dest_rst_n (dma_rst_n)
    );

    // XPM async FIFOs require reset release synchronous to their write clock.
    // dma_rst_n (clk domain) and video_rst_n (video_clk domain) are separate
    // sources; they are never OR-ed in front of a synchronizer any more.
    wire video_cdc_reset_pcie;
    wire video_cdc_reset_n;
    sc7f0_reset_sync #(.SOURCES(2)) u_video_fifo_reset (
        .dest_clk   (clk),
        .src_rst_n  ({video_rst_n, dma_rst_n}),
        .dest_rst_n (video_cdc_reset_n)
    );
    assign video_cdc_reset_pcie = !video_cdc_reset_n;

    wire [31:0] reg_irq_status_w1c;
    wire [31:0] reg_slice_height;
    wire [31:0] reg_video_ctrl;
    assign video_pipeline_reset = reg_video_ctrl[0];

    // Fine-grained sub-domain reset requests (BAR0 0x84). The board top
    // synchronizes these into the 150 MHz domain and gates only the targeted
    // reset, so software can realign the TPG (or the NV12 engine) without
    // tearing down the whole pipeline.
    wire [31:0] reg_video_sub_reset;
    wire [31:0] reg_sof_count;
    wire [31:0] reg_eol_count;
    wire [31:0] reg_beat_count;
    assign video_tpg_reset    = reg_video_sub_reset[0];
    assign video_engine_reset = reg_video_sub_reset[1];

    // ------------------------------------------------------------------
    // Free-running stream counters (video domain, gray-coded):
    //   sof_count   - accepted TUSER pulses (frame starts)
    //   eol_count   - accepted TLAST pulses (line ends)
    //   beat_count  - accepted data beats
    // Crossed to the PCI domain for BAR0 readout; comparing the three
    // rates characterizes exactly how the TPG drives the stream.
    // ------------------------------------------------------------------
    wire       video_transfer = video_ch0_tvalid && video_ch0_tready;
    wire       sof_pulse  = video_transfer && video_ch0_tuser;
    wire       eol_pulse  = video_transfer && video_ch0_tlast;

    reg [31:0] sof_bin_v   = 32'd0;
    reg [31:0] eol_bin_v   = 32'd0;
    reg [31:0] beat_bin_v  = 32'd0;

    wire [31:0] sof_bin_next  = sof_bin_v + 32'd1;
    wire [31:0] eol_bin_next  = eol_bin_v + 32'd1;
    wire [31:0] beat_bin_next = beat_bin_v + 32'd1;

    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            sof_bin_v   <= 32'd0;
            eol_bin_v   <= 32'd0;
            beat_bin_v  <= 32'd0;
        end else begin
            if (sof_pulse) begin
                sof_bin_v   <= sof_bin_next;
            end
            if (eol_pulse) begin
                eol_bin_v   <= eol_bin_next;
            end
            if (video_transfer) begin
                beat_bin_v  <= beat_bin_next;
            end
        end
    end

    // XPM supplies the per-bit CDC timing/skew constraints. These clocks
    // are genuinely asynchronous in HDMI08, rather than both PCIe user_clk.
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_sof_count_cdc (
        .src_clk(video_clk), .src_in_bin(sof_bin_v),
        .dest_clk(clk), .dest_out_bin(reg_sof_count));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_eol_count_cdc (
        .src_clk(video_clk), .src_in_bin(eol_bin_v),
        .dest_clk(clk), .dest_out_bin(reg_eol_count));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_beat_count_cdc (
        .src_clk(video_clk), .src_in_bin(beat_bin_v),
        .dest_clk(clk), .dest_out_bin(reg_beat_count));

    // RGB C2H engine diagnosis words presented to the register bank at BAR0
    // GLOBAL 0x0E0..0x0F4 (read-only).  They arrive in this (PCIe user) clock
    // from the capture domain; see the SC7F0_RGB_COMPOSITOR block below the
    // channel-0 engine for the packing and the other personalities tie 0.
    wire [31:0] reg_rgb_c2h_dbg0, reg_rgb_c2h_dbg1, reg_rgb_c2h_dbg2;
    wire [31:0] reg_rgb_c2h_dbg3, reg_rgb_c2h_dbg4, reg_rgb_c2h_dbg5;
    wire [63:0] reg_h2c_ring_addr, reg_c2h_ring_addr;
    wire [15:0] reg_h2c_ring_size, reg_h2c_tail_ptr, reg_h2c_head_ptr;
    wire [15:0] reg_c2h_ring_size, reg_c2h_tail_ptr, reg_c2h_head_ptr;
    wire [31:0] completed_h2c_count, completed_c2h_count;
    reg  [31:0] completed_h2c_count_q, completed_c2h_count_q;
    wire sg_h2c_done_irq = (completed_h2c_count != completed_h2c_count_q);
    wire sg_c2h_done_irq = (completed_c2h_count != completed_c2h_count_q);

    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            completed_h2c_count_q <= 32'd0;
            completed_c2h_count_q <= 32'd0;
        end else begin
            completed_h2c_count_q <= completed_h2c_count;
            completed_c2h_count_q <= completed_c2h_count;
        end
    end

    wire        tag_alloc_req, tag_alloc_valid, tag_full;
    wire [7:0]  tag_alloc_tag, tag_free_val;
    wire        tag_free_req;

    wire        desc_req_valid, desc_req_ack;
    wire        desc_fetch_idle;
    wire [63:0] desc_req_addr;
    wire [10:0] desc_req_dw_len;
    wire [7:0]  desc_req_tag;

    wire        desc_cpl_valid, desc_cpl_last;
    wire [511:0] desc_cpl_data;

    wire        h2c_desc_valid, h2c_desc_ready;
    wire [63:0] h2c_plane0_src, h2c_plane0_dst;
    wire [63:0] h2c_plane1_src, h2c_plane1_dst;
    wire [63:0] h2c_plane2_src, h2c_plane2_dst;
    wire [15:0] h2c_line_width, h2c_line_count;
    wire [15:0] h2c_src_stride, h2c_dst_stride;
    wire [15:0] h2c_plane12_width, h2c_plane12_count;
    wire [3:0]  h2c_format, h2c_plane_count;
    wire [15:0] h2c_desc_ctrl;

    wire        c2h_desc_valid, c2h_desc_ready;
    wire [63:0] c2h_plane0_src, c2h_plane0_dst;
    wire [63:0] c2h_plane1_src, c2h_plane1_dst;
    wire [63:0] c2h_plane2_src, c2h_plane2_dst;
    wire [15:0] c2h_line_width, c2h_line_count;
    wire [15:0] c2h_src_stride, c2h_dst_stride;
    wire [15:0] c2h_plane12_width, c2h_plane12_count;
    wire [3:0]  c2h_format, c2h_plane_count;
    wire [15:0] c2h_desc_ctrl;

    wire        h2c_req_valid, h2c_req_ack;
    wire [63:0] h2c_req_addr;
    wire [10:0] h2c_req_dw_len;
    wire [7:0]  h2c_req_tag;

    wire        h2c_fifo_wvalid, h2c_fifo_wlast;
    wire [PCIE_DATA_WIDTH-1:0] h2c_fifo_wdata;
    wire [2:0]  h2c_fifo_wdw_count;
    wire [7:0]  h2c_fifo_wtag;

    wire        irq_req_valid, irq_req_ack;
    wire [7:0]  irq_req_code;

    // Stream Engine Channel Wires (Flat Packed Vectors for Verilog Standard Compatibility)
    wire [NUM_VIDEO_CH-1:0]                    v_c2h_req_valid;
    wire [(NUM_VIDEO_CH*64)-1:0]               v_c2h_req_addr;
    wire [(NUM_VIDEO_CH*11)-1:0]               v_c2h_req_dw_len;
    wire [(NUM_VIDEO_CH*PCIE_DATA_WIDTH)-1:0] v_c2h_req_data;
    wire [NUM_VIDEO_CH-1:0]                    v_c2h_req_last;
    wire [NUM_VIDEO_CH-1:0]                    v_c2h_req_data_ready;
    wire [NUM_VIDEO_CH-1:0]                    v_busy, v_done;
    wire        video_cdc_fifo_empty;
    wire [9:0]  video_cdc_fifo_count;

    wire [NUM_AUDIO_CH-1:0]                    a_c2h_req_valid;
    wire [(NUM_AUDIO_CH*64)-1:0]               a_c2h_req_addr;
    wire [(NUM_AUDIO_CH*11)-1:0]               a_c2h_req_dw_len;
    wire [(NUM_AUDIO_CH*128)-1:0]              a_c2h_req_data;
    wire [NUM_AUDIO_CH-1:0]                    a_c2h_req_last;
    wire [NUM_AUDIO_CH-1:0]                    a_busy, a_done;

    // SG DMA Engine Wires
    wire        sg_h2c_desc_ready, sg_c2h_desc_ready;
    wire        nv12_desc_ready;
`ifndef QPCIe_single_rgb24_path
    wire        nv12_ch1_desc_ready;
    wire        nv12_ch2_desc_ready;
    wire        nv12_ch3_desc_ready;
`endif
    `ifdef QPCIe_single_rgb24_path
    // The format-0 legacy SG C2H pattern-generator path is disabled.
    wire        sg_c2h_desc_select = 1'b0;
`else
    wire        sg_c2h_desc_select = (c2h_format == 4'd0);
`endif
    wire        nv12_desc_select   = (((c2h_format == 4'd2 || c2h_format == 4'd3) && c2h_plane_count == 4'd2) ||
                                      (c2h_format == 4'd1 && c2h_plane_count == 4'd1)) && (c2h_desc_ctrl[7:6] == 2'd0);
`ifndef QPCIe_single_rgb24_path
    wire        nv12_ch1_desc_sel  = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd1);
    wire        nv12_ch2_desc_sel  = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd2);
    wire        nv12_ch3_desc_sel  = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd3);
    assign c2h_desc_ready = nv12_desc_select ? nv12_desc_ready :
                            (NUM_VIDEO_CH > 1 && nv12_ch1_desc_sel) ? nv12_ch1_desc_ready :
                            (NUM_VIDEO_CH > 2 && nv12_ch2_desc_sel) ? nv12_ch2_desc_ready :
                            (NUM_VIDEO_CH > 3 && nv12_ch3_desc_sel) ? nv12_ch3_desc_ready :
                            sg_c2h_desc_select ? sg_c2h_desc_ready : 1'b0;
`else
    assign c2h_desc_ready = nv12_desc_select ? nv12_desc_ready :
                            sg_c2h_desc_select ? sg_c2h_desc_ready : 1'b0;
`endif
    wire        sg_h2c_req_valid, sg_h2c_req_ack;
    wire [63:0] sg_h2c_req_addr;
    wire [10:0] sg_h2c_req_dw_len;
    wire [7:0]  sg_h2c_req_tag;
    wire        sg_c2h_req_valid, sg_c2h_req_ack, sg_c2h_req_last;
    wire        sg_c2h_req_data_ready;
    wire [63:0] sg_c2h_req_addr;
    wire [10:0] sg_c2h_req_dw_len;
    wire [127:0] sg_c2h_req_data;
    wire [31:0] sg_h2c_bytes, sg_c2h_bytes;
    wire        sg_h2c_busy, sg_c2h_busy;

    // Firmware Upgrade Wires (BAR0 0x0780 - 0x079C & H2C PS DDR Writer)
    wire [31:0] dma_upg_ctrl_w;
    wire [31:0] dma_upg_size_w;
    wire [31:0] dma_upg_crc32_w;
    wire [63:0] dma_upg_ps_addr_w;
    wire [63:0] dma_upg_host_addr_w;
    wire [31:0] dma_upg_status_w;
    wire [31:0] dma_upg_progress_w;
    wire [31:0] dma_upg_doorbell_w;
    wire        upg_write_done_w;
    wire [31:0] upg_bytes_written_w;
    wire        upg_irq_pulse_w;
    wire        upg_lb_tready;
    reg         upg_h2c_desc_valid_q;
    wire        lb_tvalid, lb_tlast, lb_tuser, lb_tready;
    wire        upg_lb_tvalid_cdc, upg_lb_tlast_cdc, upg_lb_tready_cdc;
    wire        upg_diag_clear_toggle_w;
    wire        upg_diag_clear_ack_w;
    wire [31:0] upg_diag_pcie_sync, upg_diag_writer_sticky;
    wire ddr_read_request;
    wire [31:0] ddr_read_offset, ddr_read_status, ddr_read_sequence;
    wire [127:0] ddr_read_data;
    zu4ev_ddr_readback u_ddr_readback (
        .clk(pl_clk0), .rst_n(sys_100m_rst_n),
        .request(ddr_read_request), .offset(ddr_read_offset),
        .dma_active(dma_upg_ctrl_w[0]),
        .status(ddr_read_status), .sequence_id(ddr_read_sequence), .data(ddr_read_data),
        .araddr(m_axi_hp0_araddr), .arvalid(m_axi_hp0_arvalid), .arready(m_axi_hp0_arready),
        .rdata(m_axi_hp0_rdata), .rresp(m_axi_hp0_rresp), .rid(m_axi_hp0_rid),
        .rlast(m_axi_hp0_rlast), .rvalid(m_axi_hp0_rvalid), .rready(m_axi_hp0_rready)
    );

    // H2C upgrade parameters now arrive as ordered coherent CSR snapshots.
    // This local pipeline detects START only after preceding SIZE/HOST_ADDR
    // writes have crossed the FIFO. No raw pl_clk0 bus sampling is required.
    wire [31:0] dma_upg_ctrl_pcie, dma_upg_size_pcie;
    wire [63:0] dma_upg_host_addr_pcie;
    reg  [1:0]  upg_start_sync;
    reg  [31:0] upg_size_pcie;
    reg  [63:0] upg_host_addr_pcie;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            upg_start_sync     <= 2'b00;
            upg_size_pcie      <= 32'd0;
            upg_host_addr_pcie <= 64'd0;
        end else begin
            upg_start_sync <= {upg_start_sync[0], dma_upg_ctrl_pcie[0]};
            if (upg_start_sync == 2'b01) begin
                upg_size_pcie      <= dma_upg_size_pcie;
                upg_host_addr_pcie <= dma_upg_host_addr_pcie;
            end
        end
    end
    wire upg_active_pcie = upg_start_sync[1];
    wire upg_start_pulse = (upg_start_sync == 2'b01);

    // A sticky event is set in its source clock domain, then a stable LEVEL
    // (never a narrow pulse or multi-bit counter) crosses into pl_clk0.
    // BAR0+0x7B0/0x7B4 remain readable after the driver's 3s timeout.
    wire [12:0] upg_diag_pcie_events;
    assign upg_diag_pcie_events[0] = upg_start_pulse;
    assign upg_diag_pcie_events[1] = upg_h2c_desc_valid_q;
    assign upg_diag_pcie_events[2] = upg_h2c_desc_valid_q && sg_h2c_desc_ready;
    assign upg_diag_pcie_events[3] = upg_active_pcie && sg_h2c_req_valid;
    assign upg_diag_pcie_events[4] = upg_active_pcie && sg_h2c_req_valid && sg_h2c_req_ack;
    assign upg_diag_pcie_events[5] = upg_active_pcie && m_axis_rq_tvalid && m_axis_rq_tready &&
                                     (m_axis_rq_tdata[103:96] >= 8'd2) &&
                                     (m_axis_rq_tdata[103:96] <= 8'd17);
    assign upg_diag_pcie_events[6] = upg_active_pcie && s_axis_rc_tvalid && s_axis_rc_tready;
    assign upg_diag_pcie_events[7] = upg_active_pcie && h2c_fifo_wvalid &&
                                     (h2c_fifo_wtag >= 8'd2) && (h2c_fifo_wtag <= 8'd17);
    assign upg_diag_pcie_events[8] = upg_active_pcie && lb_tvalid;
    assign upg_diag_pcie_events[9] = upg_active_pcie && lb_tvalid && lb_tready;
    assign upg_diag_pcie_events[10] = upg_active_pcie && sg_h2c_busy;
    assign upg_diag_pcie_events[11] = upg_active_pcie && sg_h2c_bytes != 0;
    assign upg_diag_pcie_events[12] = upg_active_pcie && upg_lb_tready;

    wire [13:0] upg_diag_writer_events = {
        sys_100m_rst_n, (upg_bytes_written_w != 0), upg_write_done_w,
        (m_axi_hp0_bvalid && m_axi_hp0_bready && m_axi_hp0_bresp != 2'b00),
        (m_axi_hp0_bvalid && m_axi_hp0_bready), m_axi_hp0_bvalid,
        (m_axi_hp0_wvalid && m_axi_hp0_wready && m_axi_hp0_wlast),
        (m_axi_hp0_wvalid && m_axi_hp0_wready), m_axi_hp0_wvalid,
        (m_axi_hp0_awvalid && m_axi_hp0_awready), m_axi_hp0_awvalid,
        (upg_lb_tvalid_cdc && upg_lb_tready_cdc), upg_lb_tvalid_cdc,
        dma_upg_ctrl_w[0]
    };
    zu4ev_upg_diag u_zu4ev_upg_diag (
        .clk_pcie(clk), .rst_pcie_n(rst_n),
        .clk_pl(pl_clk0), .rst_pl_n(sys_100m_rst_n),
        .clear_toggle_pl(upg_diag_clear_toggle_w),
        .pcie_events(upg_diag_pcie_events),
        .writer_events(upg_diag_writer_events),
        .pcie_sticky_pl(upg_diag_pcie_sync),
        .writer_sticky_pl(upg_diag_writer_sticky),
        .clear_ack_pl(upg_diag_clear_ack_w)
    );

    wire [127:0] lb_tdata;
    wire        sg_loopback_enable;
    wire [1:0]  sg_loopback_channel;
`ifndef QPCIe_single_rgb24_path
    wire        ch1_loopback_full;
    wire        ch2_loopback_full;
    wire        ch3_loopback_full;
`endif
`ifdef QPCIe_single_rgb24_path
    // When firmware upgrade is active, route backpressure from h2c_ps_ddr_writer
    // NOTE: upg_active_pcie is the pl_clk0 START level synchronized into this
    // (pcie_user_clk) domain. Sampling dma_upg_ctrl_w[0] directly here is an
    // unsynchronized CDC; 1204 still timed out and needs stage tracing.
    assign lb_tready = upg_active_pcie ? upg_lb_tready : 1'b1;
`else
    assign lb_tready = upg_active_pcie ? upg_lb_tready :
                            (!sg_loopback_enable ? 1'b1 :
                            (NUM_VIDEO_CH > 2 && sg_loopback_channel == 2'd2) ? !ch2_loopback_full :
                            (NUM_VIDEO_CH > 3 && sg_loopback_channel == 2'd3) ? !ch3_loopback_full :
                            (NUM_VIDEO_CH > 1) ? !ch1_loopback_full : 1'b1);
`endif

    // Multiplexed C2H Request Signals
    reg                        c2h_req_valid_mux;
    reg  [63:0]                c2h_req_addr_mux;
    reg  [10:0]                c2h_req_dw_len_mux;
    reg  [PCIE_DATA_WIDTH-1:0] c2h_req_data_mux;
    reg                        c2h_req_last_mux;
    wire                       c2h_req_data_ready_mux;
    wire                       c2h_req_ack_mux;
    reg [3:0] c2h_first_be_mux,c2h_last_be_mux;
    localparam [7:0] PACKET_OWNER=2+NUM_VIDEO_CH+NUM_AUDIO_CH;
    reg prefer_packet;
    reg [7:0]                  c2h_owner;
    reg [7:0]                  c2h_selected;
    wire [NUM_VIDEO_CH-1:0]    v_c2h_req_ack;
    wire [NUM_AUDIO_CH-1:0]    a_c2h_req_ack;
    integer i_arb;
    reg c2h_arb_found;

    always @(*) begin
        c2h_req_valid_mux = 1'b0; c2h_req_addr_mux = 64'd0;
        c2h_req_dw_len_mux = 11'd0;
        c2h_req_data_mux = {PCIE_DATA_WIDTH{1'b0}};
        c2h_req_last_mux = 1'b0; c2h_arb_found = 1'b0;
        c2h_selected = c2h_owner;
        c2h_first_be_mux=4'hf;c2h_last_be_mux=4'hf;

        if ((c2h_owner == 8'd1) || ((c2h_owner == 0) && sg_c2h_req_valid)) begin
            c2h_req_valid_mux = sg_c2h_req_valid; c2h_req_addr_mux = sg_c2h_req_addr;
            c2h_req_dw_len_mux = sg_c2h_req_dw_len;
            c2h_req_data_mux = {{PCIE_DATA_WIDTH-128{1'b0}}, sg_c2h_req_data};
            c2h_req_last_mux = sg_c2h_req_last; c2h_arb_found = 1'b1;
            c2h_selected = 8'd1;
        end
        // Low-bandwidth audio gets the next packet boundary; never preempt an owner.
        for (i_arb = 0; i_arb < NUM_AUDIO_CH; i_arb = i_arb + 1) begin
            if (((c2h_owner == (8'd2+NUM_VIDEO_CH+i_arb)) ||
                 ((c2h_owner == 0) && !c2h_arb_found && a_c2h_req_valid[i_arb]))) begin
                c2h_req_valid_mux = a_c2h_req_valid[i_arb];
                c2h_req_addr_mux = a_c2h_req_addr[(i_arb*64)+:64];
                c2h_req_dw_len_mux = a_c2h_req_dw_len[(i_arb*11)+:11];
                c2h_req_data_mux = {{PCIE_DATA_WIDTH-128{1'b0}}, a_c2h_req_data[(i_arb*128)+:128]};
                c2h_req_last_mux = a_c2h_req_last[i_arb]; c2h_arb_found = 1'b1;
                c2h_selected = 8'd2+NUM_VIDEO_CH+i_arb;
            end
        end
        if(ENABLE_PACKET_C2H && ((c2h_owner==PACKET_OWNER) ||
            (c2h_owner==0&&!c2h_arb_found&&prefer_packet&&packet_req_valid)))begin
            c2h_req_valid_mux=packet_req_valid;c2h_req_addr_mux=packet_req_addr;
            c2h_req_dw_len_mux=packet_req_dw_len;c2h_req_data_mux=packet_req_data;
            c2h_req_last_mux=1;c2h_first_be_mux=packet_req_first_be;
            c2h_last_be_mux=packet_req_last_be;c2h_arb_found=1;c2h_selected=PACKET_OWNER;
        end
        for (i_arb = 0; i_arb < NUM_VIDEO_CH; i_arb = i_arb + 1) begin
            if (((c2h_owner == (8'd2+i_arb)) ||
                 ((c2h_owner == 0) && !c2h_arb_found && v_c2h_req_valid[i_arb]))) begin
                c2h_req_valid_mux = v_c2h_req_valid[i_arb];
                c2h_req_addr_mux = v_c2h_req_addr[(i_arb*64)+:64];
                c2h_req_dw_len_mux = v_c2h_req_dw_len[(i_arb*11)+:11];
                c2h_req_data_mux = v_c2h_req_data[(i_arb*PCIE_DATA_WIDTH)+:PCIE_DATA_WIDTH];
                c2h_req_last_mux = v_c2h_req_last[i_arb]; c2h_arb_found = 1'b1;
                c2h_selected = 8'd2+i_arb;
            end
        end
        if(ENABLE_PACKET_C2H&&c2h_owner==0&&!c2h_arb_found&&packet_req_valid)begin
            c2h_req_valid_mux=1;c2h_req_addr_mux=packet_req_addr;
            c2h_req_dw_len_mux=packet_req_dw_len;c2h_req_data_mux=packet_req_data;
            c2h_req_last_mux=1;c2h_first_be_mux=packet_req_first_be;
            c2h_last_be_mux=packet_req_last_be;c2h_selected=PACKET_OWNER;
        end
    end

    // Ownership is committed one cycle before the engine can act on it: the
    // arbiter above is combinational, so in a c2h_owner==0 cycle the selected
    // source is only a tentative grant. rq_tx_encoder still has to win its own
    // MRd/MWr priority chain (a same-cycle desc_req_valid, or an ack for the
    // fetch it is retiring, sends it to S_SEND_DESC instead of sampling C2H),
    // and a FWFT source FIFO that pops on data_ready can never get that beat
    // back. Keep C2H invisible to the encoder until the grant is committed so
    // that "c2h_owner is locked" and "the encoder may sample c2h_req_data" are
    // the same condition.
    wire c2h_req_valid_enc = (c2h_owner != 8'd0) ? c2h_req_valid_mux : 1'b0;

    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) c2h_owner <= 8'd0;
        else if (c2h_owner == 0 && c2h_req_valid_mux) c2h_owner <= c2h_selected;
        else if (c2h_owner != 0 && c2h_req_ack_mux) c2h_owner <= 8'd0;
    end

    always @(posedge clk or negedge dma_rst_n)begin
        if(!dma_rst_n)prefer_packet<=1;
        else if(c2h_req_ack_mux)prefer_packet<=c2h_owner!=PACKET_OWNER;
    end
    // data_ready hands a FWFT source its head beat and is irreversible, so it
    // may only ever reach the committed owner. A tentative grant is NOT an
    // acceptance: popping on it drops 32 bytes that rq_tx_encoder never
    // latched, which shifts every later TLP header/payload pair by one beat
    // and leaves a residue beat that a later packet (or a completion record
    // write) then consumes.
    assign packet_req_data_ready=ENABLE_PACKET_C2H &&
        (c2h_owner==PACKET_OWNER)&&c2h_req_data_ready_mux;
    assign packet_req_ack=ENABLE_PACKET_C2H&&c2h_owner==PACKET_OWNER&&c2h_req_ack_mux;

    assign sg_c2h_req_data_ready =
        (c2h_owner == 8'd1) && c2h_req_data_ready_mux;
    assign sg_c2h_req_ack = (c2h_owner == 8'd1) && c2h_req_ack_mux;
    genvar v_ack_i, a_ack_i;
    generate
        for (v_ack_i=0; v_ack_i<NUM_VIDEO_CH; v_ack_i=v_ack_i+1) begin : gen_v_ack
            assign v_c2h_req_data_ready[v_ack_i] =
                (c2h_owner == (8'd2+v_ack_i)) && c2h_req_data_ready_mux;
            assign v_c2h_req_ack[v_ack_i] =
                (c2h_owner == (8'd2+v_ack_i)) && c2h_req_ack_mux;
        end
        for (a_ack_i=0; a_ack_i<NUM_AUDIO_CH; a_ack_i=a_ack_i+1) begin : gen_a_ack
            assign a_c2h_req_ack[a_ack_i] = (c2h_owner == (8'd2+NUM_VIDEO_CH+a_ack_i)) && c2h_req_ack_mux;
        end
    endgenerate

    // Forward declaration: video_tx_idle below consumes it, and xvlog rejects
    // a reg that is referenced ahead of its declaration (VRFC 10-3380) which
    // made the whole module unverifiable in the xsim regression flow.
    wire        ch0_owner_busy;   // driven by u_ch0_arbiter (both launch entries)

    // An empty packet FIFO alone is not idle: the frontend may still be
    // producing writes to the current host buffer. Retire the owner first.
    wire video_tx_idle = !ch0_owner_busy && !v_busy[0] &&
                         video_cdc_fifo_empty && !v_c2h_req_valid[0] &&
                         (c2h_owner != 8'd2);
    assign reg_dma_status = {20'd0, sg_c2h_busy, sg_h2c_busy,
                             desc_fetch_idle, video_tx_idle, 4'd0,
                             a_done[0], v_done[0], a_busy[0], v_busy[0]};

    wire cc_busy;

    // 1. CQ RX Decoder
    cq_rx_decoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH),
        .KEEP_WIDTH(PCIE_KEEP_WIDTH)
    ) u_cq_rx_decoder (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_cq_tdata(s_axis_cq_tdata),
        .s_axis_cq_tvalid(s_axis_cq_tvalid),
        .s_axis_cq_tlast(s_axis_cq_tlast),
        .s_axis_cq_tuser(s_axis_cq_tuser),
        .s_axis_cq_tkeep(s_axis_cq_tkeep),
        .s_axis_cq_tready(s_axis_cq_tready),
        .m_axil_bar0_awaddr(bar0_axil_awaddr),
        .m_axil_bar0_awvalid(bar0_axil_awvalid),
        .m_axil_bar0_awready(bar0_axil_awready),
        .m_axil_bar0_wdata(bar0_axil_wdata),
        .m_axil_bar0_wstrb(bar0_axil_wstrb),
        .m_axil_bar0_wvalid(bar0_axil_wvalid),
        .m_axil_bar0_wready(bar0_axil_wready),
        .m_axil_bar0_bresp(bar0_axil_bresp),
        .m_axil_bar0_bvalid(bar0_axil_bvalid),
        .m_axil_bar0_bready(bar0_axil_bready),
        .m_axil_bar0_araddr(bar0_axil_araddr),
        .m_axil_bar0_arvalid(bar0_axil_arvalid),
        .m_axil_bar0_arready(bar0_axil_arready),
        .m_axil_bar0_rdata(bar0_axil_rdata),
        .m_axil_bar0_rresp(bar0_axil_rresp),
        .m_axil_bar0_rvalid(bar0_axil_rvalid),
        .m_axil_bar1_awaddr(m_axil_bar1_awaddr),
        .m_axil_bar1_awvalid(m_axil_bar1_awvalid),
        .m_axil_bar1_awready(m_axil_bar1_awready),
        .m_axil_bar1_wdata(m_axil_bar1_wdata),
        .m_axil_bar1_wstrb(m_axil_bar1_wstrb),
        .m_axil_bar1_wvalid(m_axil_bar1_wvalid),
        .m_axil_bar1_wready(m_axil_bar1_wready),
        .m_axil_bar1_bresp(m_axil_bar1_bresp),
        .m_axil_bar1_bvalid(m_axil_bar1_bvalid),
        .m_axil_bar1_bready(m_axil_bar1_bready),
        .m_axil_bar1_araddr(m_axil_bar1_araddr),
        .m_axil_bar1_arvalid(m_axil_bar1_arvalid),
        .m_axil_bar1_arready(m_axil_bar1_arready),
        .m_axil_bar1_rdata(m_axil_bar1_rdata),
        .m_axil_bar1_rresp(m_axil_bar1_rresp),
        .m_axil_bar1_rvalid(m_axil_bar1_rvalid),
        .read_req_valid(read_req_valid),
        .read_req_tag(read_req_tag),
        .read_req_id(read_req_id),
        .read_req_lower_addr(read_req_lower_addr),
        .read_req_tc(read_req_tc),
        .read_req_bar_sel(read_req_bar_sel),
        .read_req_ack(read_req_ack),
        .cc_busy(cc_busy)
    );

    // 2. CC TX Encoder
    cc_tx_encoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH),
        .KEEP_WIDTH(PCIE_KEEP_WIDTH)
    ) u_cc_tx_encoder (
        .clk(clk),
        .rst_n(rst_n),
        .m_axis_cc_tdata(m_axis_cc_tdata),
        .m_axis_cc_tvalid(m_axis_cc_tvalid),
        .m_axis_cc_tlast(m_axis_cc_tlast),
        .m_axis_cc_tuser(m_axis_cc_tuser),
        .m_axis_cc_tkeep(m_axis_cc_tkeep),
        .m_axis_cc_tready(m_axis_cc_tready),
        .read_req_valid(read_req_valid),
        .read_req_tag(read_req_tag),
        .read_req_id(read_req_id),
        .read_req_lower_addr(read_req_lower_addr),
        .read_req_tc(read_req_tc),
        .read_req_bar_sel(read_req_bar_sel),
        .read_req_ack(read_req_ack),
        .cc_busy(cc_busy),
        .bar0_axil_rdata(bar0_axil_rdata),
        .bar0_axil_rresp(bar0_axil_rresp),
        .bar0_axil_rvalid(bar0_axil_rvalid),
        .bar0_axil_rready(bar0_axil_rready),
        .bar1_axil_rdata(m_axil_bar1_rdata),
        .bar1_axil_rresp(m_axil_bar1_rresp),
        .bar1_axil_rvalid(m_axil_bar1_rvalid),
        .bar1_axil_rready(m_axil_bar1_rready)
    );

    // Hardware AV Sync Global Precision Timestamp Wires & Telemetry
    wire [63:0] global_timestamp;
    wire [63:0] timestamp_90khz;
    wire [63:0] v_pts[NUM_VIDEO_CH-1:0];
    wire [63:0] a_pts[NUM_AUDIO_CH-1:0];
    wire [31:0] v_drop_cnt[NUM_VIDEO_CH-1:0];
    wire [31:0] reg_bandwidth_bps;
    wire [31:0] reg_latency_max_ns;
    wire [31:0] reg_pacer_ctrl;

    // Performance Monitor Signals (RTL Bandwidth & Bottleneck Attribution)
    wire        perf_enable;
    wire        perf_reset;
    wire [63:0] reg_perf_cycles;
    wire [31:0] reg_perf_tlp_count;
    wire [63:0] reg_perf_payload_bytes;
    wire [31:0] reg_perf_tx_active_cycles;
    wire [31:0] reg_perf_tx_idle_cycles;
    wire [31:0] reg_perf_tready_stall_cycles;
    wire [31:0] reg_perf_inter_tlp_gap;
    wire [31:0] reg_perf_tlp_128b_count;
    wire [31:0] reg_perf_tlp_256b_count;
    wire [31:0] reg_perf_split_4k_count;
    wire [15:0] reg_perf_max_queue_depth;
    wire [31:0] reg_perf_idle_cdc_empty;
    wire [31:0] reg_perf_idle_no_req;

    wire        perf_tlp_start = m_axis_rq_tvalid && m_axis_rq_tready && m_axis_rq_tuser[0];
    wire        perf_split_4k_event = (c2h_req_valid_mux && c2h_req_ack_mux &&
                                       (c2h_req_dw_len_mux == 11'd32) &&
                                       (c2h_req_addr_mux[11:7] == 5'b11111));

    // Scatter-Gather Page Table Wires
    wire        pt_y_wr_en, pt_uv_wr_en;
    wire [10:0] pt_y_wr_addr, pt_uv_wr_addr;
    wire [63:0] pt_y_wr_data, pt_uv_wr_data;
    wire [10:0] cur_y_page_idx, cur_uv_page_idx;

    // Audio DMA Configuration Wires (Ch0..Ch3)
    wire [63:0] reg_audio_dma_addr;
    wire [31:0] reg_audio_dma_cfg;
    wire [31:0] reg_audio_dma_ptr;

    wire [63:0] reg_audio_dma_addr_ch1, reg_audio_dma_addr_ch2, reg_audio_dma_addr_ch3;
    wire [31:0] reg_audio_dma_cfg_ch1,  reg_audio_dma_cfg_ch2,  reg_audio_dma_cfg_ch3;
    wire [31:0] reg_audio_dma_ptr_ch1,  reg_audio_dma_ptr_ch2,  reg_audio_dma_ptr_ch3;

    // Audio Playback H2C FIFO Wires
    wire        h2c_fifo_wr_en_ch1, h2c_fifo_wr_en_ch2, h2c_fifo_wr_en_ch3;
    wire [31:0] h2c_fifo_wr_data;
    wire [7:0]  h2c_fifo_count_ch1, h2c_fifo_count_ch2, h2c_fifo_count_ch3;
    wire        h2c_fifo_full_ch1,  h2c_fifo_full_ch2,  h2c_fifo_full_ch3;
    wire        h2c_fifo_empty_ch1, h2c_fifo_empty_ch2, h2c_fifo_empty_ch3;
    wire [31:0] h2c_fifo_rdata_ch1, h2c_fifo_rdata_ch2, h2c_fifo_rdata_ch3;
    wire        h2c_fifo_rd_en_ch1, h2c_fifo_rd_en_ch2, h2c_fifo_rd_en_ch3;
    wire [31:0] reg_audio_loopback_ctrl;

    // Phase 3: Video CH0 Thin Descriptor Engine Wires
    wire [31:0] vch0_ctrl_w;
    wire [31:0] vch0_width_w;
    wire [31:0] vch0_height_w;
    wire [31:0] vch0_stride0_w;
    wire [31:0] vch0_stride1_w;
    wire        map_mode_new_w;
    wire [31:0] thin_frame_count;
    wire [31:0] thin_drop_count;
    wire [15:0] thin_ring0_head;
    wire [15:0] thin_ring1_head;
    wire        thin_active = vch0_ctrl_w[0];
    // Declared here because the thin fetch engine instance and the thin launch
    // branches below both reference them, and this file analyses with implicit net
    // declarations enabled: a first use would create a 1-bit implicit net that a
    // later explicit declaration then collides with.
    //   thin_fmt_ok         : the armed thin profile may drive the channel-0 engine
    //   thin_launch_refused : a launch request being refused and retired this cycle
    wire        thin_fmt_ok;
    // Driven by u_ch0_arbiter and consumed by the thin walker below, so they must be
    // declared ahead of that instantiation (xvlog otherwise creates implicit 1-bit
    // nets on first use and then rejects the later explicit declaration).
    wire        thin_engine_enable;   // arbiter -> walker enable (profile guarded)
    wire        thin_frame_abort;     // arbiter -> walker frame retire (refusal)
    wire        thin_launch_refused;
    wire        overlay_en_w;
    assign out_vch0_ctrl = vch0_ctrl_w;

    wire [31:0] vch1_ctrl_w;
    wire [31:0] vch1_width_w;
    wire [31:0] vch1_height_w;
    wire [31:0] vch1_stride0_w;
    wire [31:0] vch1_stride1_w;
    wire [63:0] vch1_ring0_base_w;
    wire [15:0] vch1_ring0_size_w;
    wire [15:0] vch1_ring0_tail_w;
    wire [15:0] vch1_ring0_head_w;
    wire [3:0]  vch1_irq_status_w;
    wire [3:0]  vch1_irq_status_w1c_w;
    wire        vch1_irq_en_w;

    wire        thin_cpld_valid;
    wire [127:0] thin_cpld_data;
    wire        thin_cpld_last;

    assign overlay_en     = overlay_en_w;
    assign overlay_width  = vch0_width_w[15:0];
    assign overlay_height = vch0_height_w[15:0];

    // Phase 4: Three-Level Interrupt Wires
    wire [31:0] irq_top_status_w;
    wire [31:0] irq_top_status_w1c_w;
    wire [3:0]  vch0_irq_status_w;
    wire [3:0]  vch0_irq_status_w1c_w;
    wire        vch0_irq_en_w;

    // Phase 4 P4-2: Audio DEV0 Wires
    wire [31:0] adev0_ctrl_w;
    wire [31:0] adev0_rate_w;
    wire [31:0] adev0_period_bytes_w;
    wire [31:0] adev0_buffer_bytes_w;
    wire [63:0] adev0_ring0_base_w;
    wire [31:0] adev0_ring0_cfg_w;
    wire [1:0]  adev0_irq_status_w;
    wire [1:0]  adev0_irq_status_w1c_w;
    wire        adev0_xrun_inject_w;
    wire [3:0]  a_xrun;

    reg  [31:0] d_thin_drop_count;
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n)
            d_thin_drop_count <= 32'd0;
        else
            d_thin_drop_count <= thin_drop_count;
    end
    wire vch0_overflow_pulse = (thin_drop_count != d_thin_drop_count);


    // 3. PS-clock register bank, ordered DMA controls and coherent telemetry.
    qpcie_csr_reg_space #(
        .C_VERSION(C_VERSION),
        .NUM_VIDEO_CH(NUM_VIDEO_CH),
        .NUM_AUDIO_CH(NUM_AUDIO_CH)
    ) u_axil_reg_space (
        .clk(pl_clk0),
        .rst_n(sys_100m_rst_n),
        .pcie_clk(clk), .pcie_rst_n(rst_n),
        .pcie_upg_ctrl(dma_upg_ctrl_pcie), .pcie_upg_size(dma_upg_size_pcie),
        .pcie_upg_host_addr(dma_upg_host_addr_pcie),
        .in_requester_id(requester_id),
        .s_axil_awaddr(arb_axil_awaddr),
        .s_axil_awvalid(arb_axil_awvalid),
        .s_axil_awready(arb_axil_awready),
        .s_axil_wdata(arb_axil_wdata),
        .s_axil_wstrb(arb_axil_wstrb),
        .s_axil_wvalid(arb_axil_wvalid),
        .s_axil_wready(arb_axil_wready),
        .s_axil_bresp(arb_axil_bresp),
        .s_axil_bvalid(arb_axil_bvalid),
        .s_axil_bready(arb_axil_bready),
        .s_axil_araddr(arb_axil_araddr),
        .s_axil_arvalid(arb_axil_arvalid),
        .s_axil_arready(arb_axil_arready),
        .s_axil_rdata(arb_axil_rdata),
        .s_axil_rresp(arb_axil_rresp),
        .s_axil_rvalid(arb_axil_rvalid),
        .s_axil_rready(arb_axil_rready),
        .reg_dma_ctrl(reg_dma_ctrl),
        .reg_dma_status(reg_dma_status),
        .reg_h2c_ring_addr(reg_h2c_ring_addr),
        .reg_h2c_ring_size(reg_h2c_ring_size),
        .reg_h2c_tail_ptr(reg_h2c_tail_ptr),
        .reg_c2h_ring_addr(reg_c2h_ring_addr),
        .reg_c2h_ring_size(reg_c2h_ring_size),
        .reg_c2h_tail_ptr(reg_c2h_tail_ptr),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status(reg_irq_status),
        .reg_irq_status_w1c(reg_irq_status_w1c),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count),
        .reg_h2c_head_ptr(thin_ring1_head),
        .reg_c2h_head_ptr(thin_ring0_head),
        .reg_global_timestamp(global_timestamp),
        .reg_last_video_pts(v_pts[0]),
        .reg_last_audio_pts(a_pts[0]),
        .reg_frame_drop_count(v_drop_cnt[0]),
        .reg_bandwidth_bps(reg_bandwidth_bps),
        .reg_latency_max_ns(reg_latency_max_ns),
        .reg_pacer_ctrl(reg_pacer_ctrl),
        .reg_slice_height(reg_slice_height),
        .reg_video_ctrl(reg_video_ctrl),
        .reg_video_sub_reset(reg_video_sub_reset),
        .reg_sof_count(reg_sof_count),
        .reg_eol_count(reg_eol_count),
        .reg_beat_count(reg_beat_count),
        .reg_rgb_c2h_dbg0(reg_rgb_c2h_dbg0),
        .reg_rgb_c2h_dbg1(reg_rgb_c2h_dbg1),
        .reg_rgb_c2h_dbg2(reg_rgb_c2h_dbg2),
        .reg_rgb_c2h_dbg3(reg_rgb_c2h_dbg3),
        .reg_rgb_c2h_dbg4(reg_rgb_c2h_dbg4),
        .reg_rgb_c2h_dbg5(reg_rgb_c2h_dbg5),

        // Hardware Performance Monitor Ports
        .perf_enable(perf_enable),
        .perf_reset(perf_reset),
        .reg_perf_cycles(reg_perf_cycles),
        .reg_perf_tlp_count(reg_perf_tlp_count),
        .reg_perf_payload_bytes(reg_perf_payload_bytes),
        .reg_perf_tx_active_cycles(reg_perf_tx_active_cycles),
        .reg_perf_tx_idle_cycles(reg_perf_tx_idle_cycles),
        .reg_perf_tready_stall_cycles(reg_perf_tready_stall_cycles),
        .reg_perf_inter_tlp_gap(reg_perf_inter_tlp_gap),
        .reg_perf_tlp_128b_count(reg_perf_tlp_128b_count),
        .reg_perf_tlp_256b_count(reg_perf_tlp_256b_count),
        .reg_perf_split_4k_count(reg_perf_split_4k_count),
        .reg_perf_max_queue_depth(reg_perf_max_queue_depth),
        .reg_perf_idle_cdc_empty(reg_perf_idle_cdc_empty),
        .reg_perf_idle_no_req(reg_perf_idle_no_req),
        .pt_y_wr_en(pt_y_wr_en),
        .pt_y_wr_addr(pt_y_wr_addr),
        .pt_y_wr_data(pt_y_wr_data),
        .pt_uv_wr_en(pt_uv_wr_en),
        .pt_uv_wr_addr(pt_uv_wr_addr),
        .pt_uv_wr_data(pt_uv_wr_data),
        .cur_y_page_idx(cur_y_page_idx),
        .cur_uv_page_idx(cur_uv_page_idx),
        .reg_audio_dma_addr(reg_audio_dma_addr),
        .reg_audio_dma_cfg(reg_audio_dma_cfg),
        .reg_audio_dma_ptr(reg_audio_dma_ptr),

        // Multi-Channel Audio Ports
        .reg_audio_dma_addr_ch1(reg_audio_dma_addr_ch1),
        .reg_audio_dma_cfg_ch1(reg_audio_dma_cfg_ch1),
        .reg_audio_dma_ptr_ch1(reg_audio_dma_ptr_ch1),
        .reg_audio_dma_addr_ch2(reg_audio_dma_addr_ch2),
        .reg_audio_dma_cfg_ch2(reg_audio_dma_cfg_ch2),
        .reg_audio_dma_ptr_ch2(reg_audio_dma_ptr_ch2),
        .reg_audio_dma_addr_ch3(reg_audio_dma_addr_ch3),
        .reg_audio_dma_cfg_ch3(reg_audio_dma_cfg_ch3),
        .reg_audio_dma_ptr_ch3(reg_audio_dma_ptr_ch3),

        .h2c_fifo_wr_en_ch1(h2c_fifo_wr_en_ch1),
        .h2c_fifo_wr_en_ch2(h2c_fifo_wr_en_ch2),
        .h2c_fifo_wr_en_ch3(h2c_fifo_wr_en_ch3),
        .h2c_fifo_wr_data(h2c_fifo_wr_data),
        .h2c_fifo_count_ch1(h2c_fifo_count_ch1),
        .h2c_fifo_count_ch2(h2c_fifo_count_ch2),
        .h2c_fifo_count_ch3(h2c_fifo_count_ch3),
        .h2c_fifo_full_ch1(h2c_fifo_full_ch1),
        .h2c_fifo_full_ch2(h2c_fifo_full_ch2),
        .h2c_fifo_full_ch3(h2c_fifo_full_ch3),
        .h2c_fifo_empty_ch1(h2c_fifo_empty_ch1),
        .h2c_fifo_empty_ch2(h2c_fifo_empty_ch2),
        .h2c_fifo_empty_ch3(h2c_fifo_empty_ch3),
        .reg_audio_loopback_ctrl(reg_audio_loopback_ctrl),
        .out_vch0_ctrl(vch0_ctrl_w),
        .out_vch0_width(vch0_width_w),
        .out_vch0_height(vch0_height_w),
        .out_vch0_stride0(vch0_stride0_w),
        .out_vch0_stride1(vch0_stride1_w),
        .out_map_mode_new(map_mode_new_w),
        .in_vch0_frame_count(thin_frame_count),
        .in_vch0_drop_count(thin_drop_count),
        .out_overlay_en(overlay_en_w),
        .in_irq_top_status(irq_top_status_w),
        .out_irq_top_status_w1c(irq_top_status_w1c_w),
        .in_vch0_irq_status(vch0_irq_status_w),
        .out_vch0_irq_status_w1c(vch0_irq_status_w1c_w),
        .out_vch0_irq_en(vch0_irq_en_w),
        // Phase 6: Video CH1 Ports
        .out_vch1_ctrl(vch1_ctrl_w),
        .out_vch1_width(vch1_width_w),
        .out_vch1_height(vch1_height_w),
        .out_vch1_stride0(vch1_stride0_w),
        .out_vch1_stride1(vch1_stride1_w),
        .out_vch1_ring0_base(vch1_ring0_base_w),
        .out_vch1_ring0_size(vch1_ring0_size_w),
        .out_vch1_ring0_tail(vch1_ring0_tail_w),
        .in_vch1_ring0_head(reg_h2c_head_ptr),
        .in_vch1_frame_count(completed_c2h_count),
        .in_vch1_drop_count(v_drop_cnt[1]),
        .in_vch1_irq_status(vch1_irq_status_w),
        .out_vch1_irq_status_w1c(vch1_irq_status_w1c_w),
        .out_vch1_irq_en(vch1_irq_en_w),
        .in_pkt_submit_cnt(in_pkt_submit_cnt),
        .in_pkt_done_cnt(in_pkt_done_cnt),
        .in_pkt_err_cnt(in_pkt_err_cnt),
        .in_pkt_msi_cnt(in_pkt_msi_cnt),
        .in_pkt_bytes_lo(in_pkt_bytes_lo),
        .in_pkt_bytes_hi(in_pkt_bytes_hi),
        .in_pkt_fsm_state(in_pkt_fsm_state),
        .in_pkt_last_len(in_pkt_last_len),
        .in_pkt_last_pts_lo(in_pkt_last_pts_lo),
        .in_pkt_last_pts_hi(in_pkt_last_pts_hi),
        // Phase 4 P4-2: Audio DEV0 Ports
        .out_adev0_ctrl(adev0_ctrl_w),
        .out_adev0_rate(adev0_rate_w),
        .out_adev0_period_bytes(adev0_period_bytes_w),
        .out_adev0_buffer_bytes(adev0_buffer_bytes_w),
        .out_adev0_ring0_base(adev0_ring0_base_w),
        .out_adev0_ring0_cfg(adev0_ring0_cfg_w),
        .in_adev0_running(a_busy[0]),
        .in_adev0_xrun(a_xrun[0]),
        .in_adev0_position(reg_audio_dma_ptr),
        .in_adev0_irq_status(adev0_irq_status_w),
        .out_adev0_irq_status_w1c(adev0_irq_status_w1c_w),
        .out_adev0_xrun_inject(adev0_xrun_inject_w),
        .out_global_reset_pulse(global_reset_pulse_w),

        // HDMI RX & TX Status and Control
        .in_hdmi_rx_status(in_hdmi_rx_status),
        .in_hdmi_rx_res(in_hdmi_rx_res),
        .in_hdmi_rx_timing(in_hdmi_rx_timing),
        .in_hdmi_rx_audio(in_hdmi_rx_audio),
        .in_audio_rx_frames(in_audio_rx_frames), .in_audio_rx_errors(in_audio_rx_errors),
        .in_audio_rx_channels(in_audio_rx_channels), .in_audio_rx_cs(in_audio_rx_cs),
        .in_hdmi_tx_status(in_hdmi_tx_status),
        .out_hdmi_tx_ctrl(out_hdmi_tx_ctrl),
        .out_hdmi_tx_res(out_hdmi_tx_res),
        .out_hdmi_tx_fps(out_hdmi_tx_fps),
        .out_hdmi_ipc_cmd(out_hdmi_ipc_cmd),
        .out_hdmi_ipc_arg(out_hdmi_ipc_arg),
        .out_hdmi_ipc_status(out_hdmi_ipc_status),
        .out_hdmi_ipc_doorbell(out_hdmi_ipc_doorbell),

        // Probing & Diagnostic Ports
        .in_probe_version(in_probe_version),
        .in_probe_rx_clk_freq(in_probe_rx_clk_freq),
        .in_probe_dru_clk_freq(in_probe_dru_clk_freq),
        .in_probe_rxoutclk_freq(in_probe_rxoutclk_freq),
        .in_probe_rx_video_clk_freq(in_probe_rx_video_clk_freq),
        .in_probe_tx_clk_freq(in_probe_tx_clk_freq),
        .in_probe_txoutclk_freq(in_probe_txoutclk_freq),
        .in_probe_tx_video_clk_freq(in_probe_tx_video_clk_freq),
        .in_probe_pins(in_probe_pins),
        .in_probe_pulse_cnt1(in_probe_pulse_cnt1),
        .in_probe_ddc_cnt(in_probe_ddc_cnt),
        .in_probe_irq_cnt(in_probe_irq_cnt),
        .in_probe_ch0_beats(in_probe_ch0_beats),
        .in_probe_ch1_beats(in_probe_ch1_beats),
        .in_probe_ch2_beats(in_probe_ch2_beats),
        .in_probe_rx_video_sof(in_probe_rx_video_sof),
        .in_probe_rx_video_eol(in_probe_rx_video_eol),
        .in_probe_rx_video_pix(in_probe_rx_video_pix),
        .in_probe_raw_rx_clk(in_probe_raw_rx_clk),
        .in_probe_raw_dru_clk(in_probe_raw_dru_clk),
        .in_probe_raw_rxoutclk(in_probe_raw_rxoutclk),
        .in_probe_raw_rx_video_clk(in_probe_raw_rx_video_clk),
        .in_probe_raw_refclk100(in_probe_raw_refclk100),
        .out_probe_ctrl(out_probe_ctrl),

        // Firmware Upgrade CSR Ports (BAR0 0x0780 - 0x079C)
        .out_dma_upg_ctrl(dma_upg_ctrl_w),
        .out_dma_upg_size(dma_upg_size_w),
        .out_dma_upg_crc32(dma_upg_crc32_w),
        .out_dma_upg_ps_addr(dma_upg_ps_addr_w),
        .out_dma_upg_host_addr(dma_upg_host_addr_w),
        .out_dma_upg_status(dma_upg_status_w),
        .out_dma_upg_progress(dma_upg_progress_w),
        .out_dma_upg_doorbell(dma_upg_doorbell_w),
        .in_dma_upg_write_done(upg_write_done_w),
        .in_dma_upg_bytes_written(upg_bytes_written_w),
        .in_dma_upg_diag_pcie(upg_diag_pcie_sync),
        .in_dma_upg_diag_writer(upg_diag_writer_sticky),
        .in_dma_upg_diag_clear_ack(upg_diag_clear_ack_w),
        .out_dma_upg_diag_clear_toggle(upg_diag_clear_toggle_w),
        .out_ddr_read_request(ddr_read_request), .out_ddr_read_offset(ddr_read_offset),
        .in_ddr_read_status(ddr_read_status), .in_ddr_read_sequence(ddr_read_sequence),
        .in_ddr_read_data(ddr_read_data)
    );

    wire [127:0] upg_lb_tdata_cdc;
    wire [84:0]  upg_lb_tuser_cdc_w;

    axis_clock_converter_0 u_upg_cdc (
        .s_axis_aclk(clk),
        .s_axis_aresetn(rst_n),
        .s_axis_tdata(lb_tdata),
        .s_axis_tkeep(16'hFFFF),
        .s_axis_tvalid(lb_tvalid && upg_active_pcie),
        .s_axis_tlast(lb_tlast),
        .s_axis_tuser({84'd0, lb_tuser}),
        .s_axis_tready(upg_lb_tready),

        .m_axis_aclk(pl_clk0),
        .m_axis_aresetn(sys_100m_rst_n),
        .m_axis_tdata(upg_lb_tdata_cdc),
        .m_axis_tkeep(),
        .m_axis_tvalid(upg_lb_tvalid_cdc),
        .m_axis_tlast(upg_lb_tlast_cdc),
        .m_axis_tuser(upg_lb_tuser_cdc_w),
        .m_axis_tready(upg_lb_tready_cdc)
    );

    h2c_ps_ddr_writer #(
        .DATA_WIDTH(128),
        .ADDR_WIDTH(49)
    ) u_h2c_ps_ddr_writer (
        .clk(pl_clk0),
        .rst_n(sys_100m_rst_n),
        .upg_enable(dma_upg_ctrl_w[0]),
        .upg_dst_addr(dma_upg_ps_addr_w[48:0]),
        .upg_total_size(dma_upg_size_w),
        .upg_bytes_written(upg_bytes_written_w),
        .upg_write_done(upg_write_done_w),
        .upg_irq_pulse(upg_irq_pulse_w),
        .s_axis_tdata(upg_lb_tdata_cdc),
        .s_axis_tvalid(upg_lb_tvalid_cdc),
        .s_axis_tlast(upg_lb_tlast_cdc),
        .s_axis_tready(upg_lb_tready_cdc),
        .m_axi_awaddr(m_axi_hp0_awaddr),
        .m_axi_awlen(m_axi_hp0_awlen),
        .m_axi_awsize(m_axi_hp0_awsize),
        .m_axi_awburst(m_axi_hp0_awburst),
        .m_axi_awvalid(m_axi_hp0_awvalid),
        .m_axi_awready(m_axi_hp0_awready),
        .m_axi_wdata(m_axi_hp0_wdata),
        .m_axi_wstrb(m_axi_hp0_wstrb),
        .m_axi_wlast(m_axi_hp0_wlast),
        .m_axi_wvalid(m_axi_hp0_wvalid),
        .m_axi_wready(m_axi_hp0_wready),
        .m_axi_bresp(m_axi_hp0_bresp),
        .m_axi_bvalid(m_axi_hp0_bvalid),
        .m_axi_bready(m_axi_hp0_bready)
    );

    assign out_ps_irq_pulse = upg_irq_pulse_w || (dma_upg_doorbell_w != 32'd0);


    // 3.1 Hardware Performance Monitor Instance
    qpcie_perfmon u_qpcie_perfmon (
        .clk(clk),
        .rst_n(rst_n),
        .perf_enable(perf_enable),
        .perf_reset(perf_reset),
        .tx_tvalid(m_axis_rq_tvalid),
        .tx_tready(m_axis_rq_tready),
        .tx_tlast(m_axis_rq_tlast),
        .tx_dw_len(c2h_req_dw_len_mux),
        .tlp_start(perf_tlp_start),
        .req_valid(c2h_req_valid_mux),
        .req_ack(c2h_req_ack_mux),
        .fifo_empty(video_cdc_fifo_empty),
        .fifo_count(video_cdc_fifo_count),
        .split_4k_event(perf_split_4k_event),
        .reg_perf_cycles(reg_perf_cycles),
        .reg_perf_tlp_count(reg_perf_tlp_count),
        .reg_perf_payload_bytes(reg_perf_payload_bytes),
        .reg_perf_tx_active_cycles(reg_perf_tx_active_cycles),
        .reg_perf_tx_idle_cycles(reg_perf_tx_idle_cycles),
        .reg_perf_tready_stall_cycles(reg_perf_tready_stall_cycles),
        .reg_perf_inter_tlp_gap(reg_perf_inter_tlp_gap),
        .reg_perf_tlp_128b_count(reg_perf_tlp_128b_count),
        .reg_perf_tlp_256b_count(reg_perf_tlp_256b_count),
        .reg_perf_split_4k_count(reg_perf_split_4k_count),
        .reg_perf_max_queue_depth(reg_perf_max_queue_depth),
        .reg_perf_idle_cdc_empty(reg_perf_idle_cdc_empty),
        .reg_perf_idle_no_req(reg_perf_idle_no_req)
    );

    // 3.2 Hardware AV Sync Global Precision Timestamp Generator (64-bit @ 125MHz, 8ns resolution)
    global_timer u_global_timer (
        .clk(clk),
        .rst_n(rst_n),
        .timer_clear(1'b0),
        .timer_enable(1'b1),
        .timer_preset(64'd0),
        .timer_load(1'b0),
        .global_timestamp(global_timestamp),
        .timestamp_90khz(timestamp_90khz)
    );

    // 3.3 Real-time Hardware Telemetry & Profiler (Throughput Bps & ACK Latency ns)
    dma_telemetry u_dma_telemetry (
        .clk(clk),
        .rst_n(rst_n),
        .c2h_req_valid(c2h_req_valid_mux),
        .c2h_req_dw_len(c2h_req_dw_len_mux),
        .c2h_req_ack(c2h_req_ack_mux),
        .reg_bandwidth_bps(reg_bandwidth_bps),
        .reg_latency_max_ns(reg_latency_max_ns)
    );

    // 4. PCIe Tag Manager
    pcie_tag_manager #(
        .MAX_TAGS(64)
    ) u_tag_manager (
        .clk(clk),
        .rst_n(dma_rst_n),
        .alloc_req(tag_alloc_req),
        .alloc_valid(tag_alloc_valid),
        .alloc_tag(tag_alloc_tag),
        .tag_full(tag_full),
        .free_req(tag_free_req),
        .free_tag(tag_free_val),
        .active_count()
    );

    wire        sg_req_valid, sg_req_ack;
    wire [63:0] sg_req_addr;
    wire [10:0] sg_req_dw_len;
    wire [7:0]  sg_req_tag;

    wire        sg_cpl_valid, sg_cpl_last;
    wire [PCIE_DATA_WIDTH-1:0] sg_cpl_data;
    wire [7:0]  sg_cpl_tag;

    wire        sgl_y_wr_en, sgl_uv_wr_en;
    wire [63:0] sgl_y_wr_addr, sgl_uv_wr_addr;
    wire [31:0] sgl_y_wr_len, sgl_uv_wr_len;
    wire [31:0] sgl_y_wr_flags, sgl_uv_wr_flags;
    wire        sg_fetch_busy, sg_fetch_done;

    // Legacy & Thin Descriptor Fetch Engine Muxing
    wire        legacy_desc_req_valid;
    wire [63:0] legacy_desc_req_addr;
    wire [10:0] legacy_desc_req_dw_len;
    wire [7:0]  legacy_desc_req_tag;
    wire        legacy_desc_req_ack;

    wire        thin_mrd_req_valid;
    wire [63:0] thin_mrd_req_addr;
    wire [10:0] thin_mrd_req_dw_len;
    wire [7:0]  thin_mrd_req_tag;
    wire        thin_mrd_req_ack;

    wire        thin_sgl_y_wr_en, thin_sgl_uv_wr_en;
    wire [63:0] thin_sgl_y_wr_addr, thin_sgl_uv_wr_addr;
    wire [31:0] thin_sgl_y_wr_len, thin_sgl_uv_wr_len;
    wire [31:0] thin_sgl_y_wr_flags, thin_sgl_uv_wr_flags;

    wire        thin_frame_launch_req;
    wire [244:0] thin_frame_launch_bus;
    wire        thin_frame_launch_ack;
    wire        thin_busy;

    wire        pcie_frame_done;

    // Canonical v3.0 Native: Pure Thin Descriptor Fetch Requests
    wire        desc_req_valid_mux  = thin_mrd_req_valid;
    wire [63:0] desc_req_addr_mux   = thin_mrd_req_addr;
    wire [10:0] desc_req_dw_len_mux = thin_mrd_req_dw_len;
    wire [7:0]  desc_req_tag_mux    = thin_mrd_req_tag;
    assign thin_mrd_req_ack         = desc_req_ack;

    // 5. RQ TX Encoder
    wire [PCIE_DATA_WIDTH-1:0] rq_c2h_req_data = c2h_req_data_mux;

    // Overlay-plane Memory-Read client (lowest priority inside the encoder).
    wire        ovl_mrd_req_valid, ovl_mrd_req_ack;
    wire [63:0] ovl_mrd_req_addr;
    wire [10:0] ovl_mrd_req_dw_len;
    wire [7:0]  ovl_mrd_req_tag;
    wire [3:0]  ovl_mrd_req_first_be, ovl_mrd_req_last_be;
    // Overlay completion route out of rc_rx_decoder.
    wire        ovl_cpl_valid, ovl_cpl_last;
    wire [255:0] ovl_cpl_data;
    wire [3:0]  ovl_cpl_dw_count;
    wire [7:0]  ovl_cpl_tag;
    wire        ovl_sticky_timeout, ovl_sticky_unaligned, ovl_sticky_err;

    rq_tx_encoder #(
        .ENABLE_C2H_BYTE_ENABLE(1),
        .DATA_WIDTH(PCIE_DATA_WIDTH),
        .KEEP_WIDTH(PCIE_KEEP_WIDTH),
        .ENABLE_OVL_REQ(ENABLE_RGB_COMPOSITOR)
    ) u_rq_tx_encoder (
        .clk(clk),
        .rst_n(dma_rst_n),
        .requester_id(requester_id),
        .m_axis_rq_tdata(m_axis_rq_tdata),
        .m_axis_rq_tvalid(m_axis_rq_tvalid),
        .m_axis_rq_tlast(m_axis_rq_tlast),
        .m_axis_rq_tuser(m_axis_rq_tuser),
        .m_axis_rq_tkeep(m_axis_rq_tkeep),
        .m_axis_rq_tready(m_axis_rq_tready),
        // MSI is delivered through the 7-series cfg_interrupt interface.
        .irq_req_valid(1'b0),
        .irq_req_code(8'd0),
        .irq_req_ack(irq_req_ack),
        .desc_req_valid(desc_req_valid_mux),
        .desc_req_addr(desc_req_addr_mux),
        .desc_req_dw_len(desc_req_dw_len_mux),
        .desc_req_tag(desc_req_tag_mux),
        .desc_req_ack(desc_req_ack),
        .sg_req_valid(sg_req_valid),
        .sg_req_addr(sg_req_addr),
        .sg_req_dw_len(sg_req_dw_len),
        .sg_req_tag(sg_req_tag),
        .sg_req_ack(sg_req_ack),
        .h2c_req_valid(sg_h2c_req_valid),
        .h2c_req_addr(sg_h2c_req_addr),
        .h2c_req_dw_len(sg_h2c_req_dw_len),
        .h2c_req_tag(sg_h2c_req_tag),
        .h2c_req_ack(sg_h2c_req_ack),
        .c2h_req_valid(c2h_req_valid_enc),
        .c2h_req_addr(c2h_req_addr_mux),
        .c2h_req_dw_len(c2h_req_dw_len_mux),
        .c2h_req_data(rq_c2h_req_data),
        .c2h_req_last(c2h_req_last_mux),
        .c2h_req_first_be(c2h_first_be_mux),.c2h_req_last_be(c2h_last_be_mux),
        .c2h_req_data_ready(c2h_req_data_ready_mux),
        .c2h_req_ack(c2h_req_ack_mux),
        .ovl_req_valid(ovl_mrd_req_valid),
        .ovl_req_addr(ovl_mrd_req_addr),
        .ovl_req_dw_len(ovl_mrd_req_dw_len),
        .ovl_req_tag(ovl_mrd_req_tag),
        .ovl_req_first_be(ovl_mrd_req_first_be),
        .ovl_req_last_be(ovl_mrd_req_last_be),
        .ovl_req_ack(ovl_mrd_req_ack)
    );

    // 6. RC RX Decoder
    rc_rx_decoder #(
        .DATA_WIDTH(PCIE_DATA_WIDTH),
        .KEEP_WIDTH(PCIE_KEEP_WIDTH),
        .ENABLE_OVL_ROUTE(ENABLE_RGB_COMPOSITOR)
    ) u_rc_rx_decoder (
        .clk(clk),
        .rst_n(dma_rst_n),
        .s_axis_rc_tdata(s_axis_rc_tdata),
        .s_axis_rc_tvalid(s_axis_rc_tvalid),
        .s_axis_rc_tlast(s_axis_rc_tlast),
        .s_axis_rc_tuser(s_axis_rc_tuser),
        .s_axis_rc_tkeep(s_axis_rc_tkeep),
        .s_axis_rc_tready(s_axis_rc_tready),
        .thin_cpl_valid(thin_cpld_valid),
        .thin_cpl_data(thin_cpld_data),
        .thin_cpl_last(thin_cpld_last),
        .desc_cpl_valid(desc_cpl_valid),
        .desc_cpl_data(desc_cpl_data),
        .desc_cpl_last(desc_cpl_last),
        .sg_cpl_valid(sg_cpl_valid),
        .sg_cpl_data(sg_cpl_data),
        .sg_cpl_last(sg_cpl_last),
        .sg_cpl_tag(sg_cpl_tag),
        .h2c_fifo_wvalid(h2c_fifo_wvalid),
        .h2c_fifo_wdata(h2c_fifo_wdata),
        .h2c_fifo_wlast(h2c_fifo_wlast),
        .h2c_fifo_wdw_count(h2c_fifo_wdw_count),
        .h2c_fifo_wtag(h2c_fifo_wtag),
        .tag_free_req(tag_free_req),
        .tag_free_val(tag_free_val),
        .ovl_cpl_valid(ovl_cpl_valid),
        .ovl_cpl_data(ovl_cpl_data),
        .ovl_cpl_dw_count(ovl_cpl_dw_count),
        .ovl_cpl_last(ovl_cpl_last),
        .ovl_cpl_tag(ovl_cpl_tag)
    );

    // ---------------------------------------------------------------------
    // 6.05 Plan-A overlay path (SC7F0-RGB-COMPOSITOR-2PPC only).
    //
    //   host IOVA --MRd(tag 64..127)--> rc_rx_decoder native 256-bit CplD
    //             --> sc7f0_overlay_ingress (reorder, 4 KB split, quarantine)
    //             --> xpm_fifo_async 256->128, 125 MHz -> 300 MHz
    //             --> sc7f0_overlay_writer -> PS DDR plane slots (HP3)
    //
    // Why the ingress is fed by its own RC route instead of the H2C FIFO: the
    // H2C route exists to turn one 256-bit CplD beat into two 128-bit FIFO
    // writes and pulls s_axis_rc_tready low to do it.  A 1.990656 GB/s
    // RGBA32 plane (33177600 B/frame) cannot be fetched through a half-rate,
    // stall-prone intake.
    //
    // Upgrade priority: ovl_quiesce is asserted whenever the H2C engine is
    // busy, so an in-progress firmware transfer first stops the overlay from
    // issuing anything new.  rtl/sc7f0_overlay_ingress.v then drains or drops
    // every inflight read and frees every tag (proven by its T7 quiesce and
    // T9 backpressure gates), and its quarantine (T11) keeps a late completion
    // from landing in a later transfer.  The overlay's MRd is also the lowest
    // priority in rq_tx_encoder, so it can never delay an H2C read.
    // ---------------------------------------------------------------------
`ifdef SC7F0_RGB_COMPOSITOR
    wire flip_go;
    wire flip_mux = flip_control[0] || flip_go || flip_status[1];
    wire ovl_quiesce = ovl_quiesce_req | sg_h2c_busy | (flip_mux && !flip_control[0]);
    // Review H1: pause and discard are different things and must not be merged.
    // ovl_quiesce ALONE only stops NEW MRd issue (rtl/sc7f0_overlay_ingress.v
    // keeps consuming the completions it already owes and still stages them), so
    // a plain upgrade pause must leave the in-flight plane alone - it still
    // completes and still publishes.  A plane is discarded only when software or
    // the engine says so: discard requested while quiescing, or the ingress
    // abandoning the arm, timing out, or dropping payload it was told to discard.
    // In those cases the plane can never be complete, and the writer must retire
    // it rather than hold active_m until a frame end that will never arrive.
    wire ovl_ingress_abort;
    wire ovl_plane_abort = ovl_ingress_abort | (ovl_quiesce & ovl_discard_pending) |
                           ovl_abort_req;
    // A new plane may not be armed while the writer is still retiring the old one:
    // the ack (ovl_wr_abort_busy falling) IS the statement that the payload FIFO,
    // the intake counters and the upstream crossing are free of the dead plane.
    wire ovl_enable_eff = ovl_enable & ext_tag_enable & ~ovl_wr_abort_busy;
    assign ovl_status_ext_tag_blocked = ovl_enable & ~ext_tag_enable;

    wire [127:0] ovl_axis_tdata;
    wire         ovl_axis_tuser, ovl_axis_tvalid, ovl_axis_tready;
    wire [7:0]   ovl_axis_avail;
    wire         ovl_axis_ovf_sticky;
    wire         ovl_ing_done_pulse;

    wire         pull_ing_enable, pull_ing_go;
    wire [63:0]  pull_ing_src_addr;
    wire [31:0]  pull_ing_xfer_bytes;
    wire [15:0]  pull_ing_max_req;
    wire blank_p;
    wire [31:0] run_cookie, ingress_cookie;
    wire [63:0] flip_addr;
    wire [15:0] flip_cap;
    reg [31:0] sent_m;
    reg send_m;
    wire received, new_shown;
    wire [31:0] shown_data;
    reg [31:0] shown;
    always @(posedge ovl_mem_clk or negedge ovl_mem_rst_n)
        if (!ovl_mem_rst_n) begin sent_m<=0; send_m<=0; end
        else begin
            if (received) send_m<=0;
            else if (!send_m && flip_sof && flip_present!=0 && flip_present!=sent_m) begin
                sent_m<=flip_present; send_m<=1;
            end
        end
    xpm_cdc_handshake #(.WIDTH(32),.DEST_EXT_HSK(0),.DEST_SYNC_FF(4),.SRC_SYNC_FF(4))
        u_flip_present (.src_clk(ovl_mem_clk),.src_in(sent_m),.src_send(send_m),
                        .src_rcv(received),.dest_clk(clk),.dest_req(new_shown),
                        .dest_out(shown_data),.dest_ack(1'b0));
    always @(posedge clk or negedge rst_n)
        if (!rst_n) shown<=0; else if (new_shown) shown<=shown_data;
    wire frame_tick;
    xpm_cdc_pulse #(.DEST_SYNC_FF(4),.REG_OUTPUT(1),.RST_USED(1))
        u_flip_frame (.src_clk(ovl_mem_clk),.src_pulse(flip_sof),.src_rst(!ovl_mem_rst_n),
                      .dest_clk(clk),.dest_rst(!rst_n),.dest_pulse(frame_tick));
    reg [31:0] frame_q;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) frame_q<=0; else if(frame_tick) frame_q<=frame_q+1'b1;
    assign flip_frame=frame_q;
    // Observe the exact reset release that owns the MRd issuer. A second
    // synchronizer for mem reset creates differing epochs (26112407 CDC-11).
    wire issue_domain_ready;
    sc7f0_flip_scheduler u_flip (
        .clk(clk),.rst_n(rst_n),.run_ok(issue_domain_ready && ext_tag_enable),.mode(flip_control[0]),
        .submit(flip_submit),.blank(blank_p),.cookie(flip_cookie),.bytes(ovl_xfer_bytes),
        .shown(shown),.addr(ovl_src_addr),.cap(ovl_max_bytes_per_req),.busy(ovl_status_busy),
        .debt(ovl_status_quarantined),.quiet(ovl_status_quiesced && !ovl_mrd_req_valid && !pull_ing_go),
        .issue_idle(!ovl_mrd_req_valid && ovl_status_outstanding==0 && !ovl_status_quarantined),
        .done(ovl_ing_done_pulse),.abort_evt(ovl_plane_abort),
        .admitted(flip_admitted),.pending(flip_pending),.active(flip_active),.retired(flip_retired),
        .run_cookie(run_cookie),.run_addr(flip_addr),.run_cap(flip_cap),.go(flip_go),
        .fault(flip_status[1]),.drained(flip_status[0]));

    sc7f0_overlay_ingress #(
        .OVL_TAG_BASE   (64),
        .OVL_TAG_COUNT  (64),
        .NSLOT          (8),
        .SLOT_BYTES     (2048),
        .FIFO_DEPTH     (64),
        .MAX_REQ_CLAMP  (16'd4096)
    ) u_overlay_ingress (
        .clk                   (clk),
        .rst_n                 (dma_rst_n),
        .epoch_rst_n           (rst_n),
        .src_cookie            (flip_mux ? run_cookie : 32'd0),
        .issue_domain_ready    (issue_domain_ready),
        .m_axis_cookie         (ingress_cookie),
        .ovl_enable            (flip_mux ? (!flip_status[1] && ext_tag_enable) : pull_ing_enable),
        .ovl_src_addr          (flip_mux ? flip_addr : pull_ing_src_addr),
        .ovl_xfer_bytes        (flip_mux ? 32'd33177600 : pull_ing_xfer_bytes),
        .ovl_max_bytes_per_req (flip_mux ? flip_cap : pull_ing_max_req),
        .ovl_go                (flip_mux ? flip_go : pull_ing_go),
        .quiesce               (ovl_quiesce),
        .discard_pending       (ovl_discard_pending),
        .mrd_req_valid         (ovl_mrd_req_valid),
        .mrd_req_addr          (ovl_mrd_req_addr),
        .mrd_req_dw_len        (ovl_mrd_req_dw_len),
        .mrd_req_tag           (ovl_mrd_req_tag),
        .mrd_req_first_be      (ovl_mrd_req_first_be),
        .mrd_req_last_be       (ovl_mrd_req_last_be),
        .mrd_req_ack           (ovl_mrd_req_ack),
        .ovl_cpl_valid         (ovl_cpl_valid),
        .ovl_cpl_data          (ovl_cpl_data),
        .ovl_cpl_dw_count      (ovl_cpl_dw_count),
        .ovl_cpl_last          (ovl_cpl_last),
        .ovl_cpl_tag           (ovl_cpl_tag),
        .ovl_bytes_issued      (ovl_status_bytes_issued),
        .ovl_bytes_staged      (ovl_status_bytes_staged),
        .ovl_bytes_drained     (ovl_status_bytes_drained),
        .ovl_outstanding       (ovl_status_outstanding),
        .ovl_busy              (ovl_status_busy),
        .ovl_quiesced          (ovl_status_quiesced),
        .ovl_unexpected_count  (),
        .ovl_overflow_count    (),
        .ovl_split_count       (),
        .ovl_abort_count       (),
        .ovl_timeout_sticky    (ovl_sticky_timeout),
        .ovl_unaligned_sticky  (ovl_sticky_unaligned),
        .ovl_quarantined       (ovl_status_quarantined),
        .ovl_err_sticky        (ovl_sticky_err),
        .ovl_abort_evt         (ovl_ingress_abort),
        .ovl_poison_sticky     (ovl_video_poison),
        .ovl_done_pulse        (ovl_ing_done_pulse),
        .mem_clk               (ovl_mem_clk),
        .mem_rst_n             (ovl_mem_rst_n),
        .m_axis_tdata          (ovl_axis_tdata),
        .m_axis_tuser          (ovl_axis_tuser),
        .m_axis_tvalid         (ovl_axis_tvalid),
        .m_axis_tready         (ovl_axis_tready),
        .m_axis_avail          (ovl_axis_avail),
        .m_axis_ovf_sticky     (ovl_axis_ovf_sticky)
    );
    // Four ingress fault levels, packed so one CSR word carries all of them.
    assign ovl_status_counts = {27'd0, ovl_axis_ovf_sticky, ovl_sticky_err,
                                ovl_sticky_unaligned, ovl_sticky_timeout};

    wire legacy_vblank;
    wire ovl_vblank_irq_pulse = flip_control[0] ? (flip_control[1] && frame_tick) : legacy_vblank;
    sc7f0_ovl_pull_prefetch #(
        .ACTIVE_BEATS_PER_LINE(1920),
        .ACTIVE_LINES         (2160),
        .URAM_FIFO_DEPTH      (16384)
    ) u_ovl_pull_prefetch (
        .pcie_clk               (clk),
        .pcie_rst_n             (dma_rst_n),
        .host_ovl_enable        (ovl_enable_eff && !flip_control[0]),
        .blank_p(blank_p),.s_cookie(ingress_cookie),.m_cookie(flip_tag),
        .host_ovl_go            (ovl_go & ~ovl_abort_req),
        .host_src_addr          (ovl_src_addr),
        .host_xfer_bytes        (ovl_xfer_bytes),
        .host_max_bytes_per_req (ovl_max_bytes_per_req),
        .ing_ovl_enable         (pull_ing_enable),
        .ing_ovl_go             (pull_ing_go),
        .ing_src_addr           (pull_ing_src_addr),
        .ing_xfer_bytes         (pull_ing_xfer_bytes),
        .ing_max_bytes_per_req  (pull_ing_max_req),
        .ing_busy               (ovl_status_busy),
        .ing_quarantined        (ovl_status_quarantined),
        .ing_done_pulse         (ovl_ing_done_pulse),
        .ing_abort_evt          (ovl_ingress_abort),
        .ovl_wr_irq_pulse       (ovl_wr_irq_pulse),
        .ovl_vblank_irq_pulse   (legacy_vblank),
        .ovl_wr_frames_done     (ovl_wr_frames_done),
        .ovl_wr_bytes_written   (ovl_wr_bytes_written),
        .ovl_wr_busy            (ovl_wr_busy),
        .mem_clk                (ovl_mem_clk),
        .mem_rst_n              (ovl_mem_rst_n),
        .base_vblank_p_m        (ovl_base_vblank_p),
        .s_axis_tdata           (ovl_axis_tdata),
        .s_axis_tuser           (ovl_axis_tuser),
        .s_axis_tvalid          (ovl_axis_tvalid),
        .s_axis_tready          (ovl_axis_tready),
        .m_o_axis_tdata         (ovl_direct_tdata),
        .m_o_axis_tvalid        (ovl_direct_tvalid),
        .m_o_axis_tready        (ovl_direct_tready),
        .m_o_axis_tlast         (ovl_direct_tlast),
        .m_o_axis_tuser         (ovl_direct_tuser)
    );
    assign ovl_wr_slot_ready   = 4'd0;
    assign ovl_wr_slot_ready_m = 4'd0;
    assign ovl_wr_last_slot_m  = 2'd0;
    assign ovl_wr_slot_bytes_m = 32'd0;
    assign ovl_wr_active_slot  = 2'd0;
    assign ovl_wr_sticky       = 6'd0;
    assign ovl_wr_err_frames   = 32'd0;
    assign ovl_wr_abort_busy   = 1'b0;
    assign ovl_axi_dbg         = 4'd0;
    assign ovl_awaddr          = 49'd0;
    assign ovl_awlen           = 8'd0;
    assign ovl_awsize          = 3'd0;
    assign ovl_awburst         = 2'd0;
    assign ovl_awcache         = 4'd0;
    assign ovl_awvalid         = 1'b0;
    assign ovl_wdata           = 128'd0;
    assign ovl_wstrb           = 16'd0;
    assign ovl_wlast           = 1'b0;
    assign ovl_wvalid          = 1'b0;
    assign ovl_bready          = 1'b0;
`else
    assign ovl_status_bytes_issued      = 32'd0;
    assign ovl_status_bytes_staged      = 32'd0;
    assign ovl_status_bytes_drained     = 32'd0;
    assign ovl_status_outstanding       = 6'd0;
    assign ovl_status_busy              = 1'b0;
    assign ovl_status_quiesced          = 1'b1;
    assign ovl_status_quarantined       = 1'b0;
    assign ovl_status_ext_tag_blocked   = 1'b0;
    assign ovl_status_counts            = 32'd0;
    assign ovl_video_guard_sticky       = 1'b0;
    assign ovl_video_guard_count        = 32'd0;
    assign ovl_wr_abort_busy            = 1'b0;
    assign ovl_wr_err_frames            = 32'd0;
    assign ovl_video_poison             = 1'b0;
    assign ovl_wr_slot_ready            = 4'd0;
    assign ovl_wr_slot_ready_m          = 4'd0;
    assign ovl_wr_last_slot_m           = 2'd0;
    assign ovl_wr_slot_bytes_m          = 32'd0;
    assign ovl_wr_busy                  = 1'b0;
    assign ovl_wr_active_slot           = 2'd0;
    assign ovl_wr_frames_done           = 32'd0;
    assign ovl_wr_bytes_written         = 32'd0;
    assign ovl_wr_sticky                = 6'd0;
    assign ovl_axi_dbg                  = 4'd0;
    assign ovl_wr_irq_pulse             = 1'b0;
    wire   ovl_vblank_irq_pulse         = 1'b0;
    assign ovl_awaddr                   = 49'd0;
    assign ovl_awlen                    = 8'd0;
    assign ovl_awsize                   = 3'd0;
    assign ovl_awburst                  = 2'd0;
    assign ovl_awcache                  = 4'd0;
    assign ovl_awvalid                  = 1'b0;
    assign ovl_wdata                    = 128'd0;
    assign ovl_wstrb                    = 16'd0;
    assign ovl_wlast                    = 1'b0;
    assign ovl_wvalid                   = 1'b0;
    assign ovl_bready                   = 1'b0;
    assign ovl_direct_tdata             = 64'd0;
    assign ovl_direct_tvalid            = 1'b0;
    assign ovl_direct_tlast             = 1'b0;
    assign ovl_direct_tuser             = 1'b0;
`endif

    // 6.1 SG Host Variable-Length SGL Fetch Engine
    wire [2:0]  sgl_y_channel, sgl_uv_channel;
    wire        sgl_h2c_y_wr_en  = sgl_y_wr_en  && (sgl_y_channel == 3'd4);
    wire        sgl_h2c_uv_wr_en = sgl_uv_wr_en && (sgl_uv_channel == 3'd4);

    wire        sgl_ch0_y_wr_en  = sgl_y_wr_en  && (sgl_y_channel == 3'd0);
    wire        sgl_ch0_uv_wr_en = sgl_uv_wr_en && (sgl_uv_channel == 3'd0);

`ifndef QPCIe_single_rgb24_path
    wire        sgl_ch1_y_wr_en  = sgl_y_wr_en  && (sgl_y_channel == 3'd1);
    wire        sgl_ch1_uv_wr_en = sgl_uv_wr_en && (sgl_uv_channel == 3'd1);

    wire        sgl_ch2_y_wr_en  = sgl_y_wr_en  && (sgl_y_channel == 3'd2);
    wire        sgl_ch2_uv_wr_en = sgl_uv_wr_en && (sgl_uv_channel == 3'd2);

    wire        sgl_ch3_y_wr_en  = sgl_y_wr_en  && (sgl_y_channel == 3'd3);
    wire        sgl_ch3_uv_wr_en = sgl_uv_wr_en && (sgl_uv_channel == 3'd3);
`endif

    wire        h2c_y_almost_full, h2c_uv_almost_full;
    wire        ch0_sgl_y_almost_full, ch0_sgl_uv_almost_full;
`ifndef QPCIe_single_rgb24_path
    wire        ch1_sgl_y_almost_full, ch1_sgl_uv_almost_full;
    wire        ch2_sgl_y_almost_full, ch2_sgl_uv_almost_full;
    wire        ch3_sgl_y_almost_full, ch3_sgl_uv_almost_full;
`endif

`ifdef QPCIe_single_rgb24_path
    wire [4:0]  channel_y_almost_full  = {h2c_y_almost_full, 3'b0, ch0_sgl_y_almost_full};
    wire [4:0]  channel_uv_almost_full = {h2c_uv_almost_full, 3'b0, ch0_sgl_uv_almost_full};
`else
    wire [4:0]  channel_y_almost_full  = {h2c_y_almost_full,
                                          (NUM_VIDEO_CH > 3 ? ch3_sgl_y_almost_full : 1'b0),
                                          (NUM_VIDEO_CH > 2 ? ch2_sgl_y_almost_full : 1'b0),
                                          (NUM_VIDEO_CH > 1 ? ch1_sgl_y_almost_full : 1'b0),
                                          ch0_sgl_y_almost_full};
    wire [4:0]  channel_uv_almost_full = {h2c_uv_almost_full,
                                          (NUM_VIDEO_CH > 3 ? ch3_sgl_uv_almost_full : 1'b0),
                                          (NUM_VIDEO_CH > 2 ? ch2_sgl_uv_almost_full : 1'b0),
                                          (NUM_VIDEO_CH > 1 ? ch1_sgl_uv_almost_full : 1'b0),
                                          ch0_sgl_uv_almost_full};
`endif

    sg_host_fetch_engine #(
        .DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_sg_host_fetch_engine (
        .clk(clk),
        .rst_n(dma_rst_n),
        .fetch_start((h2c_desc_valid && sg_h2c_desc_ready && (h2c_desc_ctrl[4] || h2c_desc_ctrl[5])) ||
                     (c2h_desc_valid && c2h_desc_ready && (c2h_desc_ctrl[4] || c2h_desc_ctrl[5]))),
        .fetch_channel(h2c_desc_valid ? 3'd4 : {1'b0, c2h_desc_ctrl[7:6]}),
        .plane0_slot_addr(h2c_desc_valid ? h2c_plane0_src : c2h_plane0_dst),
        .plane1_slot_addr(h2c_desc_valid ? h2c_plane1_src : c2h_plane1_dst),
        .plane0_pages_req(16'd2025),
        .plane1_pages_req(16'd1013),
        .fetch_busy(sg_fetch_busy),
        .fetch_done(sg_fetch_done),
        .mrd_req_valid(sg_req_valid),
        .mrd_req_addr(sg_req_addr),
        .mrd_req_dw_len(sg_req_dw_len),
        .mrd_req_tag(sg_req_tag),
        .mrd_req_ack(sg_req_ack),
        .cpld_valid(sg_cpl_valid),
        .cpld_data(sg_cpl_data),
        .cpld_last(sg_cpl_last),
        .cpld_tag(sg_cpl_tag),
        .sgl_y_channel(sgl_y_channel),
        .sgl_uv_channel(sgl_uv_channel),
        .sgl_y_wr_en(sgl_y_wr_en),
        .sgl_y_wr_addr(sgl_y_wr_addr),
        .sgl_y_wr_len(sgl_y_wr_len),
        .sgl_y_wr_flags(sgl_y_wr_flags),
        .sgl_uv_wr_en(sgl_uv_wr_en),
        .sgl_uv_wr_addr(sgl_uv_wr_addr),
        .sgl_uv_wr_len(sgl_uv_wr_len),
        .sgl_uv_wr_flags(sgl_uv_wr_flags),
        .channel_y_almost_full(channel_y_almost_full),
        .channel_uv_almost_full(channel_uv_almost_full)
    );

    // 7. Canonical v3.0 Thin Descriptor Engine Ties + Upgrade H2C DMA Trigger
    // upg_start_pulse / upg_h2c_desc_valid_q are in the pcie_user_clk domain
    // and are now driven by the synchronized START (see upg_start_sync above).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            upg_h2c_desc_valid_q <= 1'b0;
        else if (upg_start_pulse)
            upg_h2c_desc_valid_q <= 1'b1;
        else if (sg_h2c_desc_ready)
            upg_h2c_desc_valid_q <= 1'b0;
    end

    assign desc_fetch_idle = !thin_busy && !sg_h2c_busy;
    assign h2c_desc_valid  = upg_h2c_desc_valid_q;
    assign c2h_desc_valid  = 1'b0;
    assign h2c_plane0_src  = upg_host_addr_pcie;
    assign h2c_plane0_dst  = 64'd0;
    assign h2c_plane1_src  = {32'd0, upg_size_pcie};
    assign h2c_plane1_dst  = 64'd0;
    assign h2c_plane2_src  = 64'd0;
    assign h2c_plane2_dst  = 64'd0;
    assign h2c_line_width  = 16'd4096;
    assign h2c_line_count  = (upg_size_pcie[11:0] == 12'd0) ?
                             upg_size_pcie[27:12] :
                             (upg_size_pcie[27:12] + 16'd1);
    assign h2c_src_stride  = 16'd0;
    assign h2c_dst_stride  = 16'd0;
    assign h2c_plane12_width = 16'd0;
    assign h2c_plane12_count = 16'd0;
    assign h2c_format      = 4'd0;
    assign h2c_plane_count = 4'd1;
    assign h2c_desc_ctrl   = 16'd0;
    assign c2h_plane0_src  = 64'd0;
    assign c2h_plane0_dst  = 64'd0;
    assign c2h_plane1_src  = 64'd0;
    assign c2h_plane1_dst  = 64'd0;
    assign c2h_plane2_src  = 64'd0;
    assign c2h_plane2_dst  = 64'd0;
    assign c2h_line_width  = 16'd0;
    assign c2h_line_count  = 16'd0;
    assign c2h_src_stride  = 16'd0;
    assign c2h_dst_stride  = 16'd0;
    assign c2h_plane12_width = 16'd0;
    assign c2h_plane12_count = 16'd0;
    assign c2h_format      = 4'd0;
    assign c2h_plane_count = 4'd0;
    assign c2h_desc_ctrl   = 8'd0;

    // 7.0b Thin Descriptor Fetch Engine (Phase 3 16-Byte)
    thin_desc_fetch_engine #(
        .DATA_WIDTH(PCIE_DATA_WIDTH),
        // RGB personality: the launch bus carries PIXELS in its width field, like the
        // ordinary descriptor path.  Legacy profiles keep the historical byte/row
        // field untouched (default 0).  See rtl/thin_desc_fetch_engine.v.
`ifdef SC7F0_C2H_RGB24
        .WIDTH_FIELD_PIXELS(1)
`else
        .WIDTH_FIELD_PIXELS(0)
`endif
    ) u_thin_desc_fetch_engine (
        .clk(clk),
        .rst_n(dma_rst_n),
        .enable(thin_engine_enable),
        .format(vch0_ctrl_w[7:4]),
        .frame_width(vch0_width_w[15:0]),
        .frame_height(vch0_height_w[15:0]),
        .frame_stride0(vch0_stride0_w[15:0]),
        .frame_stride1(vch0_stride1_w[15:0]),
        .global_timestamp(global_timestamp),
        .ring0_base_addr(reg_c2h_ring_addr),
        .ring0_size(reg_c2h_ring_size),
        .ring0_tail(reg_c2h_tail_ptr),
        .ring0_head(thin_ring0_head),
        .ring1_base_addr(reg_h2c_ring_addr),
        .ring1_size(reg_h2c_ring_size),
        .ring1_tail(reg_h2c_tail_ptr),
        .ring1_head(thin_ring1_head),
        .frame_done_in(pcie_frame_done),
        .frame_abort(thin_frame_abort),
        .frame_count(thin_frame_count),
        .drop_count(thin_drop_count),
        .busy(thin_busy),
        .mrd_req_valid(thin_mrd_req_valid),
        .mrd_req_addr(thin_mrd_req_addr),
        .mrd_req_dw_len(thin_mrd_req_dw_len),
        .mrd_req_tag(thin_mrd_req_tag),
        .mrd_req_ack(thin_mrd_req_ack),
        .cpld_valid(thin_cpld_valid),
        .cpld_data(thin_cpld_data),
        .cpld_last(thin_cpld_last),
        .cpld_tag(8'h00),
        .sgl_y_wr_en(thin_sgl_y_wr_en),
        .sgl_y_wr_addr(thin_sgl_y_wr_addr),
        .sgl_y_wr_len(thin_sgl_y_wr_len),
        .sgl_y_wr_flags(thin_sgl_y_wr_flags),
        .sgl_y_almost_full(ch0_sgl_y_almost_full),
        .sgl_uv_wr_en(thin_sgl_uv_wr_en),
        .sgl_uv_wr_addr(thin_sgl_uv_wr_addr),
        .sgl_uv_wr_len(thin_sgl_uv_wr_len),
        .sgl_uv_wr_flags(thin_sgl_uv_wr_flags),
        .sgl_uv_almost_full(ch0_sgl_uv_almost_full),
        .frame_launch_req(thin_frame_launch_req),
        .frame_launch_bus(thin_frame_launch_bus),
        .frame_launch_ack(thin_frame_launch_ack),
        .capture_engine_busy(ch0_owner_busy)
    );

    // 7.1 Scatter-Gather (SG) DMA Engine (H2C MRd Stream Consumer & C2H MWr Pattern Generator)
    sg_dma_engine #(
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH)
    ) u_sg_dma_engine (
        .clk(clk),
        .rst_n(dma_rst_n),
        .h2c_desc_valid(h2c_desc_valid),
        .h2c_plane0_src(h2c_plane0_src),
        .h2c_plane1_src(h2c_plane1_src),
        .h2c_line_width(h2c_line_width),
        .h2c_line_count(h2c_line_count),
        .h2c_plane12_width(h2c_plane12_width),
        .h2c_plane12_count(h2c_plane12_count),
        .h2c_plane_count(h2c_plane_count),
        .h2c_format(h2c_format),
        .h2c_desc_ctrl(h2c_desc_ctrl),
        .h2c_desc_ready(sg_h2c_desc_ready),
        .h2c_loopback_enable(sg_loopback_enable),
        .h2c_loopback_channel(sg_loopback_channel),
        .sgl_h2c_y_wr_en(sgl_h2c_y_wr_en),
        .sgl_h2c_y_wr_addr(sgl_y_wr_addr),
        .sgl_h2c_y_wr_len(sgl_y_wr_len),
        .sgl_h2c_y_wr_flags(sgl_y_wr_flags),
        .sgl_h2c_uv_wr_en(sgl_h2c_uv_wr_en),
        .sgl_h2c_uv_wr_addr(sgl_uv_wr_addr),
        .sgl_h2c_uv_wr_len(sgl_uv_wr_len),
        .sgl_h2c_uv_wr_flags(sgl_uv_wr_flags),
        .c2h_desc_valid(c2h_desc_valid && sg_c2h_desc_select),
        .c2h_plane0_dst(c2h_plane0_dst),
        .c2h_line_width(c2h_line_width),
        .c2h_line_count(c2h_line_count),
        .c2h_plane12_width(c2h_plane12_width),
        .c2h_plane12_count(c2h_plane12_count),
        .c2h_plane_count(c2h_plane_count),
        .c2h_desc_ready(sg_c2h_desc_ready),
        .h2c_req_valid(sg_h2c_req_valid),
        .h2c_req_addr(sg_h2c_req_addr),
        .h2c_req_dw_len(sg_h2c_req_dw_len),
        .h2c_req_tag(sg_h2c_req_tag),
        .h2c_req_ack(sg_h2c_req_ack),
        .c2h_req_valid(sg_c2h_req_valid),
        .c2h_req_addr(sg_c2h_req_addr),
        .c2h_req_dw_len(sg_c2h_req_dw_len),
        .c2h_req_data(sg_c2h_req_data),
        .c2h_req_last(sg_c2h_req_last),
        .c2h_req_data_ready(sg_c2h_req_data_ready),
        .c2h_req_ack(sg_c2h_req_ack),
        .h2c_cpl_valid(h2c_fifo_wvalid),
        .h2c_cpl_data(h2c_fifo_wdata),
        .h2c_cpl_last(h2c_fifo_wlast),
        .h2c_cpl_dw_count(h2c_fifo_wdw_count),
        .h2c_cpl_tag(h2c_fifo_wtag),
        .h2c_y_almost_full(h2c_y_almost_full),
        .h2c_uv_almost_full(h2c_uv_almost_full),
        .m_axis_loopback_tdata(lb_tdata),
        .m_axis_loopback_tvalid(lb_tvalid),
        .m_axis_loopback_tlast(lb_tlast),
        .m_axis_loopback_tuser(lb_tuser),
        .m_axis_loopback_tready(lb_tready),
        .completed_h2c_count(completed_h2c_count),
        .completed_c2h_count(completed_c2h_count),
        .h2c_bytes_transferred(sg_h2c_bytes),
        .c2h_bytes_transferred(sg_c2h_bytes),
        .dma_error_count(),
        .h2c_busy(sg_h2c_busy),
        .c2h_busy(sg_c2h_busy)
    );

    // 8. Channel-0 YUV444 -> NV12M Capture Engine (150 MHz video domain)
    // Descriptor format 0 remains reserved for the SG diagnostic engine;
    // format 2 with two planes is accepted only by this video engine.
    localparam integer NUM_V_CH = NUM_VIDEO_CH;
    localparam integer NUM_A_CH = NUM_AUDIO_CH;

    // ---- Signal declarations (before any use) ----------------------------
    // Both channel-0 launch entries and the crossing itself live in
    // rtl/sc7f0_video_launch_arbiter.v (u_ch0_arbiter below), so these are driven
    // there rather than by an always block in this file.
    wire        hs_send_q;
    wire [244:0] hs_bus_q;
    wire        hs_src_rcv, hs_dest_req;
    wire [244:0] hs_dest_bus;
    reg          hs_dest_ack;
    reg          eng_desc_valid;
    reg [3:0]    eng_format;
    reg          eng_desc_sg_mode;
    reg [63:0]   eng_y_addr, eng_uv_addr, eng_ts;
    reg [15:0]   eng_width, eng_height, eng_stride;
    wire         nv12_desc_ready_v;

    // Pacer enable crosses as a quasi-static level (BAR0 write, rare).
    (* ASYNC_REG = "TRUE" *) reg [1:0] pacer_sync = 2'b01;

    wire        eng_frame_done, eng_busy;
    assign video_capture_active = eng_busy;
    wire [31:0] eng_err_count;
    wire [63:0] eng_frame_pts;
    wire        eng_req_valid, eng_req_ready, eng_req_ack;
    wire [63:0] eng_req_addr;
    wire [127:0] eng_req_data;

    wire eng_busy_pcie;

    wire        tel_dest_req;
    wire [95:0]  tel_dest_out;
    wire        tel_dest_ack_unused;
    reg [31:0]  v_err_sync_q = 32'd0;
    reg [63:0]  v_pts_sync_q = 64'd0;

    // ------------------------------------------------------------------------
    // Review H2: channel-0 video descriptor format gate (RGB compositor only).
    //
    // The decision lives in rtl/sc7f0_video_format_guard.v so the predicate the
    // card uses is the predicate the fixture tests.  Note what is NOT changed:
    // c2h_desc_ready / nv12_desc_ready keep their existing meaning, so a refused
    // legacy NV12 descriptor is still CONSUMED from the shared mailbox and the
    // programming, upgrade, MCU and readback paths keep running.  Only the launch
    // of the RGB24 engine (hs_bus_q / ch0_owner_busy below) is withheld, which is
    // what turns "old app arms format 2 against an NV12 ring" from a host-memory
    // overrun into zero C2H requests plus a readable fault.
    // ------------------------------------------------------------------------
    // ------------------------------------------------------------------------
    // Review H2: channel-0 video format gate for BOTH launch entries.
    //
    // The predicates live in rtl/sc7f0_video_format_guard.v and are instantiated by
    // rtl/sc7f0_video_launch_arbiter.v (u_ch0_arbiter below), which also holds the
    // crossing, so the arbiter this card instantiates is the arbiter the fixture
    // tests.  What is NOT changed is unchanged on purpose:
    //   * nv12_desc_ready keeps its pre-guard meaning, so a refused legacy NV12
    //     descriptor is still CONSUMED from the shared mailbox and the programming,
    //     upgrade, MCU and readback paths keep running;
    //   * only the launch of the RGB24 engine (hs_bus_q / ch0_owner_busy) is
    //     withheld, which is what turns "old app arms format 2 against an NV12
    //     ring" into zero C2H requests plus a readable fault.
    // ------------------------------------------------------------------------
    wire rgb_fmt_ok;
    wire rgb_fmt_refused;
    wire desc_guard_sticky;
    wire [31:0] desc_guard_count;
    wire [63:0] desc_frame_bytes;
    // The arbiter's combined report pair, read by ovl_video_guard_* below.
    wire        arb_guard_sticky;
    wire [31:0] arb_guard_count;
    // thin_engine_enable / thin_frame_abort are declared with the other thin signals,
    // ahead of the walker instantiation that consumes them.
`ifdef SC7F0_C2H_RGB24
    // ---- Second launch entry: the THIN walker path -----------------------
    // thin_active (vch0_ctrl[0]) puts channel 0 behind rtl/thin_desc_fetch_engine.v,
    // which builds the same 245-bit launch bus and can launch a frame by itself.
    // Guarding only the c2h_desc_valid branch above would leave that entry wide
    // open: vch0_ctrl[7:4] = 4'd0 is NV12M in this file's own words
    // (rtl/thin_desc_fetch_engine.v:27), and the walker would happily compute
    // stride = width for two planes while the packed RGB24 engine writes 3 B/px into
    // whatever the ring entries point at.  The predicate is the same one, evaluated
    // on the profile the walker actually launches from: format, width, height and
    // stride0 are exactly the inputs from which it derives launch_stride and
    // effective_width (rtl/thin_desc_fetch_engine.v:115-117), so no field that can
    // reach the engine is left unchecked.
    //
    // Refusal is not "hold the handshake": with enable gated the walker never
    // fetches, never pushes an SGL entry and never raises frame_launch_req for an
    // unsafe profile, and a request that is already up when the profile changes
    // under it is acked AND aborted (thin_frame_launch_ack, frame_abort), so the
    // walker returns to idle instead of waiting for a frame_done that a refused
    // engine will never send.  Nothing else in the design is gated: BAR0
    // programming, the common mailbox, the upgrade writer, the MCU path and DDR
    // readback all keep running while an unsafe video profile is refused.
    // The thin entry's guard instances, its refusal counting and its launch/snapshot
    // cross-check all live in u_ch0_arbiter below, which also drives thin_enable and
    // frame_abort into the walker, so one module holds both channel-0 entries.
    wire arb_thin_ack;
    wire [63:0] thin_frame_bytes;   // arbiter observation: bus-implied frame bytes
`else
    // Any other profile elaborates the pre-guard arbiter (ARB_ENABLED=0): same
    // crossing, same handshake, no refusal and no reporting.  rgb_fmt_ok,
    // rgb_fmt_refused and the guard report pair are DRIVEN BY that instance, so they
    // must not be assigned here as well - a second driver on the same net.
`endif
`ifdef SC7F0_C2H_RGB24
    // Both entries report into one readable pair: a driver reading 0x68[0]/0x70
    // cannot tell a refused legacy descriptor from a refused legacy thin profile,
    // but each entry counts its own refusals and the sticky covers both.
    assign ovl_video_guard_sticky = arb_guard_sticky;
    assign ovl_video_guard_count  = arb_guard_count;
`else
    assign ovl_video_guard_sticky = 1'b0;
    assign ovl_video_guard_count  = 32'd0;
`endif

    // ---- Descriptor crossing: 125 MHz fetch -> 150 MHz engine ------------
    // Bus layout: {format[3:0], desc_ctrl[4]|desc_ctrl[5], timestamp[63:0], stride[15:0], height[15:0], width[15:0],
    //              uv_addr[63:0], y_addr[63:0]}
    // ---- Channel-0 launch arbiter: BOTH entries, one crossing -----------
    // Moved out of this file so the ordinary descriptor entry and the thin walker
    // entry are guarded, refused, acked and retired by one module that a fixture can
    // bind (rtl/sc7f0_video_launch_arbiter.v).  ENABLED is a build-time constant: a
    // profile whose channel-0 engine is already format-aware gets the pre-guard
    // crossing with no refusal and no reporting.
`ifdef SC7F0_C2H_RGB24
    localparam ARB_ENABLED = 1;
`else
    localparam ARB_ENABLED = 0;
`endif
    sc7f0_video_launch_arbiter #(.MAX_WIDTH(4096), .MAX_HEIGHT(2160),
                                .ENABLED(ARB_ENABLED)) u_ch0_arbiter (
        .clk              (clk),
        .rst_n            (dma_rst_n),
        .desc_valid       (c2h_desc_valid),
        .desc_select      (nv12_desc_select),
        .desc_format      (c2h_format),
        .desc_plane_count (c2h_plane_count),
        .desc_width       (c2h_line_width),
        .desc_height      (c2h_line_count),
        .desc_stride      (c2h_dst_stride),
        .desc_y_addr      (c2h_plane0_dst),
        .desc_uv_addr     (c2h_plane1_dst),
        .desc_sg_mode     (c2h_desc_ctrl[4] | c2h_desc_ctrl[5]),
        .timestamp        (global_timestamp),
        .desc_ready       (nv12_desc_ready),
        .thin_active      (thin_active),
        .thin_format      (vch0_ctrl_w[7:4]),
        .thin_width       (vch0_width_w[15:0]),
        .thin_height      (vch0_height_w[15:0]),
        .thin_stride0     (vch0_stride0_w[15:0]),
        .thin_enable      (thin_engine_enable),
        .thin_launch_req  (thin_frame_launch_req),
        .thin_launch_bus  (thin_frame_launch_bus),
        .thin_launch_ack  (arb_thin_ack),
        .thin_frame_abort (thin_frame_abort),
        .force_clear      (reg_video_ctrl[0]),
        .hs_src_rcv       (hs_src_rcv),
        .owner_release    (pcie_frame_done),
        .hs_send_q        (hs_send_q),
        .hs_bus_q         (hs_bus_q),
        .ch0_owner_busy   (ch0_owner_busy),
        .desc_fmt_ok      (rgb_fmt_ok),
        .desc_refused     (rgb_fmt_refused),
        .thin_profile_ok  (thin_fmt_ok),
        .guard_sticky     (arb_guard_sticky),
        .guard_count      (arb_guard_count),
        .desc_frame_bytes (desc_frame_bytes),
        .thin_frame_bytes (thin_frame_bytes));
    assign thin_frame_launch_ack = arb_thin_ack;

    // Keep the descriptor owner until the PCIe-side EOF retires. eng_busy drops
    // once the video-domain FIFO drains into the CDC, before the final MWr is
    // transmitted; accepting another descriptor then can mix frame addresses.
    // (The descriptor owner is now held inside u_ch0_arbiter, with the same
    //  pcie_frame_done retirement as before.)

    // Review H2: a refused thin launch is still CONSUMED, and a refused descriptor
    // is still consumed as before.  Both expressions moved into the arbiter, which
    // drives desc_ready and thin_frame_launch_ack above; keeping them here would put
    // two drivers on the same net.

    xpm_cdc_handshake #(
        .WIDTH(245),
        .DEST_EXT_HSK(1)
    ) u_desc_cdc (
        .src_clk    (clk),
        .src_send   (hs_send_q),
        .src_rcv    (hs_src_rcv),
        .src_in     (hs_bus_q),
        .dest_clk   (video_clk),
        .dest_req   (hs_dest_req),
        .dest_out   (hs_dest_bus),
        .dest_ack   (hs_dest_ack)
    );

    localparam DEST_IDLE         = 2'd0,
               DEST_WAIT_ENG     = 2'd1,
               DEST_WAIT_REQ_LOW = 2'd2;
    reg [1:0]  dest_state;

    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            dest_state       <= DEST_IDLE;
            eng_desc_valid   <= 1'b0;
            eng_format       <= 4'd2;
            eng_desc_sg_mode <= 1'b0;
            hs_dest_ack      <= 1'b0;
            eng_y_addr       <= 64'd0;
            eng_uv_addr      <= 64'd0;
            eng_width        <= 16'd0;
            eng_height       <= 16'd0;
            eng_stride       <= 16'd0;
            eng_ts           <= 64'd0;
        end else begin
            case (dest_state)
                DEST_IDLE: begin
                    hs_dest_ack <= 1'b0;
                    if (hs_dest_req) begin
                        eng_y_addr       <= hs_dest_bus[63:0];
                        eng_uv_addr      <= hs_dest_bus[127:64];
                        eng_width        <= hs_dest_bus[143:128];
                        eng_height       <= hs_dest_bus[159:144];
                        eng_stride       <= hs_dest_bus[175:160];
                        eng_ts           <= hs_dest_bus[239:176];
                        eng_desc_sg_mode <= hs_dest_bus[240];
                        eng_format       <= hs_dest_bus[244:241];
                        eng_desc_valid   <= 1'b1;
                        dest_state       <= DEST_WAIT_ENG;
                    end
                end

                DEST_WAIT_ENG: begin
                    if (eng_desc_valid && nv12_desc_ready_v) begin
                        eng_desc_valid <= 1'b0;
                        hs_dest_ack    <= 1'b1;
                        dest_state     <= DEST_WAIT_REQ_LOW;
                    end
                end

                DEST_WAIT_REQ_LOW: begin
                    if (!hs_dest_req) begin
                        hs_dest_ack <= 1'b0;
                        dest_state  <= DEST_IDLE;
                    end
                end

                default: dest_state <= DEST_IDLE;
            endcase
        end
    end

    always @(posedge video_clk) pacer_sync <= {pacer_sync[0], reg_pacer_ctrl[0]};

    // Busy crosses back as a level; completion is ordered through the request FIFO.
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_capture_busy_cdc (
        .src_clk(video_clk), .src_in(eng_busy),
        .dest_clk(clk), .dest_out(eng_busy_pcie));

    // Telemetry handshake: {protocol_error_count, frame_pts} per frame done.
    xpm_cdc_handshake #(
        .WIDTH(96),
        .DEST_EXT_HSK(0)
    ) u_tel_cdc (
        .src_clk    (video_clk),
        .src_send   (eng_frame_done),
        .src_rcv    (),
        .src_in     ({eng_err_count, eng_frame_pts}),
        .dest_clk   (clk),
        .dest_req   (tel_dest_req),
        .dest_out   (tel_dest_out),
        .dest_ack   (tel_dest_ack_unused)
    );

    assign tel_dest_ack_unused = tel_dest_req;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_err_sync_q <= 32'd0;
            v_pts_sync_q <= 64'd0;
        end else if (tel_dest_req) begin
            v_err_sync_q <= tel_dest_out[95:64];
            v_pts_sync_q <= tel_dest_out[63:0];
        end
    end

    // Channel-0 status/telemetry now come from the synchronized copies.
    assign v_done[0]     = pcie_frame_done;
    assign v_busy[0]     = eng_busy_pcie || !video_cdc_fifo_empty || v_c2h_req_valid[0];
    assign v_pts[0]      = v_pts_sync_q;
    assign v_drop_cnt[0] = v_err_sync_q;
    assign s_axis_video_tready = {NUM_VIDEO_CH{1'b0}};

`ifdef QPCIe_single_rgb24_path
    // Ch1-3 request buses and status are tied off: the single RGB24 path
    // instantiates only the channel-0 capture engine.
    assign v_c2h_req_valid[1] = 1'b0; assign v_c2h_req_valid[2] = 1'b0; assign v_c2h_req_valid[3] = 1'b0;
    assign v_c2h_req_addr[127:64]    = 64'd0; assign v_c2h_req_addr[191:128] = 64'd0; assign v_c2h_req_addr[255:192] = 64'd0;
    assign v_c2h_req_dw_len[21:11]   = 11'd0; assign v_c2h_req_dw_len[32:22]  = 11'd0; assign v_c2h_req_dw_len[43:33]  = 11'd0;
    assign v_c2h_req_data[(1*PCIE_DATA_WIDTH)+:PCIE_DATA_WIDTH] = {PCIE_DATA_WIDTH{1'b0}};
    assign v_c2h_req_data[(2*PCIE_DATA_WIDTH)+:PCIE_DATA_WIDTH] = {PCIE_DATA_WIDTH{1'b0}};
    assign v_c2h_req_data[(3*PCIE_DATA_WIDTH)+:PCIE_DATA_WIDTH] = {PCIE_DATA_WIDTH{1'b0}};
    assign v_c2h_req_last[1] = 1'b0; assign v_c2h_req_last[2] = 1'b0; assign v_c2h_req_last[3] = 1'b0;
    assign v_done[1] = 1'b0; assign v_done[2] = 1'b0; assign v_done[3] = 1'b0;
    assign v_busy[1] = 1'b0; assign v_busy[2] = 1'b0; assign v_busy[3] = 1'b0;
    assign v_pts[1] = 64'd0; assign v_pts[2] = 64'd0; assign v_pts[3] = 64'd0;
    assign v_drop_cnt[1] = 32'd0; assign v_drop_cnt[2] = 32'd0; assign v_drop_cnt[3] = 32'd0;
`endif

    assign v_c2h_req_last[0] = 1'b0;

    // ---- Request crossing: engine @150 MHz -> RQ arbiter @125 MHz --------
    wire [10:0] eng_req_dw_len;

    video_req_cdc #(
        .DATA_WIDTH(PCIE_DATA_WIDTH),
        .MAX_DWORDS(64),
        .FIFO_DEPTH(512)
    ) u_video_req_cdc (
        .wr_clk           (video_clk),
        .wr_rst_n         (video_rst_n),
        .s_req_valid      (eng_req_valid),
        .s_req_addr       (eng_req_addr),
        .s_req_dw_len     (eng_req_dw_len),
        .s_req_data       (eng_req_data),
        .s_req_data_ready (eng_req_ready),
        .s_req_ack        (eng_req_ack),
        .s_frame_done     (eng_frame_done),
        .rd_clk           (clk),
        .rd_rst_n         (dma_rst_n),
        .m_req_valid      (v_c2h_req_valid[0]),
        .m_req_addr       (v_c2h_req_addr[63:0]),
        .m_req_dw_len     (v_c2h_req_dw_len[10:0]),
        .m_req_data       (v_c2h_req_data[PCIE_DATA_WIDTH-1:0]),
        .m_req_data_ready (v_c2h_req_data_ready[0]),
        .m_req_ack        (v_c2h_req_ack[0]),
        .m_frame_done     (pcie_frame_done),
        .m_fifo_empty     (video_cdc_fifo_empty),
        .m_fifo_count     (video_cdc_fifo_count)
    );

    // SGL Y CDC FIFO for Channel 0 (125 MHz clk -> 150 MHz video_clk)
    wire [127:0] v_sgl_y_dout;
    wire        v_sgl_y_empty;
    wire        v_sgl_y_full;
    wire        v_sgl_y_pop_ready;
    // One named wire for the whole SGL push/pop gate.  The source FIFO's rd_en and
    // the engine's sgl_wr_en are the SAME condition, and Defect 3 was exactly
    // these two drifting apart (rtl/sc7f0_rgb24_c2h_engine.v sgl_pop_ready was
    // the un-inverted walker almost_full).  Naming it once means a future edit
    // cannot fix one side and leave the other gated off; it also makes the real
    // integration equation something a testbench can connect to literally
    // (tb/tb_sc7f0_rgb24_c2h_engine.sv).
    wire        v_sgl_y_wr_en = !v_sgl_y_empty && v_sgl_y_pop_ready && eng_busy;
`ifdef SC7F0_RGB_COMPOSITOR
    // Entries this CDC FIFO still holds would be the ideal extra bit here (it is
    // the one signal that separates "the thin fetcher stopped" from "the engine
    // will not take entries"), but reading it costs the FIFO's
    // rd_data_count port, and this part is at 88 % LUT / 86 % BRAM with the
    // 300 MHz capture group already the binding constraint.  empty + prog_full
    // + the pop gate (BAR0 GLOBAL 0x0F4 [8]/[7]/[6]) answer the same question
    // with three bits, and the walker's own entry count is already at 0x0E0[6:0],
    // so the FIFO keeps the exact configuration every deployed round has used.
`endif
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_WRITE_DEPTH(512),
        .WRITE_DATA_WIDTH(128),
        .READ_DATA_WIDTH(128),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),
        .PROG_FULL_THRESH(480),
        .USE_ADV_FEATURES("0002"),
        .SIM_ASSERT_CHK(1)
    ) u_sgl_y_cdc (
        .rst(video_cdc_reset_pcie),
        .wr_clk(clk),
        .wr_en((thin_active ? thin_sgl_y_wr_en : sgl_ch0_y_wr_en) && !v_sgl_y_full),
        .din(thin_active ? {thin_sgl_y_wr_flags, thin_sgl_y_wr_len, thin_sgl_y_wr_addr} : {sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}),
        .prog_full(ch0_sgl_y_almost_full),
        .full(v_sgl_y_full),
        .rd_clk(video_clk),
        .rd_en(v_sgl_y_wr_en),
        .dout(v_sgl_y_dout),
        .empty(v_sgl_y_empty),
        .sleep(1'b0),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0),
        .sbiterr(),
        .dbiterr(),
        .wr_rst_busy(),
        .rd_rst_busy()
    );

    // SGL UV CDC FIFO for Channel 0 (125 MHz clk -> 150 MHz video_clk)
    wire [127:0] v_sgl_uv_dout;
    wire        v_sgl_uv_empty;
    wire        v_sgl_uv_full;
    wire        v_sgl_uv_pop_ready;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_WRITE_DEPTH(512),
        .WRITE_DATA_WIDTH(128),
        .READ_DATA_WIDTH(128),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),
        .PROG_FULL_THRESH(480),
        .USE_ADV_FEATURES("0002")
    ) u_sgl_uv_cdc (
        .rst(video_cdc_reset_pcie),
        .wr_clk(clk),
        .wr_en((thin_active ? thin_sgl_uv_wr_en : sgl_ch0_uv_wr_en) && !v_sgl_uv_full),
        .din(thin_active ? {thin_sgl_uv_wr_flags, thin_sgl_uv_wr_len, thin_sgl_uv_wr_addr} : {sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}),
        .prog_full(ch0_sgl_uv_almost_full),
        .full(v_sgl_uv_full),
        .rd_clk(video_clk),
        .rd_en(!v_sgl_uv_empty && v_sgl_uv_pop_ready && eng_busy),
        .dout(v_sgl_uv_dout),
        .empty(v_sgl_uv_empty),
        .sleep(1'b0),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0),
        .sbiterr(),
        .dbiterr(),
        .wr_rst_busy(),
        .rd_rst_busy()
    );

    // ---- The Channel 0 capture engine itself -----------------------------
`ifdef SC7F0_C2H_RGB24
    // Packed RGB24 channel-0 engine.  Same thin-descriptor launch bus, same
    // format code (vch0_ctrl[7:4] == 4'd1, for which rtl/thin_desc_fetch_engine.v
    // already computes stride = width*3 and needs no second plane ring), same
    // C2H MWr request interface into u_video_req_cdc.  Only the payload is
    // different: it is already byte-packed R,G,B by
    // rtl/sc7f0_rgb24_axis_pack.v, so the host image is 3 bytes/pixel with the
    // programmed stride (11520 B per 3840-pixel line, 24883200 B per frame at
    // 4K60 = 1.492992 GB/s), never RGBA and never padded to 4.
    wire        eng_rgb_desc_ready;
    wire [31:0] rgb_drop_count;
    wire        rgb_error_sticky;
    // Defect 3 read-only diagnosis taps (BAR0 GLOBAL 0x0E0..0x0F4).
    wire [6:0]  rgb_sgl_count;
    wire [31:0] rgb_dbg_bus;
    wire [31:0] rgb_bytes_committed;
    wire [31:0] rgb_frames_completed;
    wire        rgb_uv_pop_ready = 1'b0;   // single-plane format
    assign      v_sgl_uv_pop_ready = rgb_uv_pop_ready;
    sc7f0_rgb24_c2h_engine #(
        .MAX_WIDTH(4096),
        .PCIE_DATA_WIDTH(128),
        .MAX_REQ_BYTES(256),
        .SRC_FIFO_DEPTH(1024)
    ) u_rgb24_capture_engine (
        .clk(video_clk),
        .rst_n(video_rst_n),
        .desc_valid(eng_desc_valid),
        .desc_ready(eng_rgb_desc_ready),
        .desc_sg_mode(eng_desc_sg_mode),
        .plane_y_addr(eng_y_addr),
        .frame_width(eng_width),
        .frame_height(eng_height),
        .frame_stride(eng_stride),
        .sgl_wr_en(v_sgl_y_wr_en),
        .sgl_wr_addr(v_sgl_y_dout[63:0]),
        .sgl_wr_len(v_sgl_y_dout[95:64]),
        .sgl_wr_flags(v_sgl_y_dout[127:96]),
        .cur_sgl_count(rgb_sgl_count),
        .sgl_pop_ready(v_sgl_y_pop_ready),
        .dbg_bus(rgb_dbg_bus),
        .global_timestamp(eng_ts),
        .p_axis_tdata(video_ch0_tdata),
        .p_axis_tuser(video_ch0_tuser),
        .p_axis_tvalid(video_ch0_tvalid),
        .p_axis_avail(video_ch0_avail),
        .p_axis_tready(video_ch0_tready),
        .c2h_req_valid(eng_req_valid),
        .c2h_req_addr(eng_req_addr),
        .c2h_req_dw_len(eng_req_dw_len),
        .c2h_req_data(eng_req_data),
        .c2h_req_last(),
        .c2h_req_data_ready(eng_req_ready),
        .c2h_req_ack(eng_req_ack),
        .video_busy(eng_busy),
        .video_frame_done(eng_frame_done),
        .frame_pts(eng_frame_pts),
        .protocol_error_count(eng_err_count),
        .drop_count(rgb_drop_count),
        .frames_completed(rgb_frames_completed),
        .align_discard_count(),
        .bytes_committed(rgb_bytes_committed),
        .active_line_bytes(),
        .active_stride(),
        .src_overflow_sticky(video_ch0_src_overflow_sticky),
        .src_line_align_sticky(video_ch0_src_line_align_sticky),
        .error_sticky(rgb_error_sticky)
    );
    // The shared ch0 descriptor handshake waits on whichever engine is present.
    assign nv12_desc_ready_v = eng_rgb_desc_ready;

    // ------------------------------------------------------------------
    // Defect 3 read-only diagnosis path -> BAR0 GLOBAL 0x0E0..0x0F4
    // (docs/sc7f0_defect3_c2h_zero_payload_rootcause_20261116.md §5.3).
    //
    // Why it exists: every field below was dangling.  With Payload 0 B and
    // frames 0 there was no read that could tell "the engine never armed" from
    // "the engine armed but never got an SGL segment" from "the source FIFO was
    // empty"; the root cause cost a full RTL trace to find.  With entries /
    // seg_valid / pl_seg_ready / avail / tready readable in one word each, that
    // same diagnosis is one devmem.
    //
    // Transport: the bundle is formed in the capture (video_clk) domain, then
    //   * status bundles    -> xpm_cdc_array_single (per-bit; bits may come from
    //                          adjacent cycles, which is exactly what a status
    //                          snapshot of a running engine means),
    //   * monotonic counters -> xpm_cdc_gray (word-coherent, same pattern as
    //                          reg_sof/eol/beat_count above),
    // into the PCIe user clock, which is this register bank's source domain.
    // Nothing here is writable and no address map changes, so the XSA address
    // segments (SEG_M_AXI_HPM0_FPD_Reg @ 0x00A0000000) are untouched.
    // ------------------------------------------------------------------
    reg  [31:0] rgb_dbg0_v, rgb_dbg1_v, rgb_dbg2_v, rgb_dbg3_v, rgb_dbg4_v, rgb_dbg5_v;

    // prog_full belongs to the FIFO's WRITE side (pcie_user_clk), while the rest
    // of this bundle is formed in video_clk.  The first build of this window
    // (rgb-c2h-fix-26111601-20261116T055423Z) sampled it directly and the routed
    // netlist measured that as a real crossing:
    //   u_sgl_y_cdc/gen_pf_ic_rc.gpf_ic.prog_full_i_reg (pcie_user_clk)
    //     -> rgb_dbg5_v_reg[6] (capture_clk_300m), requirement 0.337 ns,
    //     slack -1.003 ns - an unsynchronised sample of an asynchronous bit and
    //     a violation no directive can close.  Everything else in this bundle is
    //     either a video_clk signal or already sits in the video domain; this one
    //     needs its own synchroniser, so it gets one.
    wire sgl_src_af_v;
    xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1)) u_sgl_src_af_cdc (
        .src_clk(clk), .src_in(ch0_sgl_y_almost_full),
        .dest_clk(video_clk), .dest_out(sgl_src_af_v));

    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            rgb_dbg0_v <= 32'd0;  rgb_dbg1_v <= 32'd0;  rgb_dbg2_v <= 32'd0;
            rgb_dbg3_v <= 32'd0;  rgb_dbg4_v <= 32'd0;  rgb_dbg5_v <= 32'd0;
        end else begin
            // 0x0E0 engine state bundle, straight from the engine.
            rgb_dbg0_v <= rgb_dbg_bus;
            // 0x0E4 payload side: [10:0] avail, [12] tvalid, [13] tready,
            // [14] burst_start, [15] pl_valid, [16] have_all, [17] pl_seg_ready,
            // [18] eng_busy, [19] sgl_wr_en, [20] sgl_pop_ready, [21] src empty.
            rgb_dbg1_v <= {10'd0, v_sgl_y_empty, v_sgl_y_pop_ready, v_sgl_y_wr_en,
                           eng_busy, rgb_dbg_bus[8], rgb_dbg_bus[25], rgb_dbg_bus[16],
                           rgb_dbg_bus[26], video_ch0_tready, video_ch0_tvalid, 1'b0,
                           video_ch0_avail};
            rgb_dbg2_v <= rgb_bytes_committed;
            rgb_dbg3_v <= rgb_drop_count;
            rgb_dbg4_v <= rgb_frames_completed;
            // 0x0F4 sticky/flow: [0] error_sticky, [1] src_overflow_sticky,
            // [2] src_line_align_sticky, [3] video_busy, [4] desc_valid,
            // [5] desc_ready, [6] SGL source FIFO prog_full (synchronised, see
            // u_sgl_src_af_cdc), [7] SGL source FIFO empty, [8] pop gate.
            rgb_dbg5_v <= {23'd0, v_sgl_y_wr_en, v_sgl_y_empty,
                           sgl_src_af_v,
                           eng_rgb_desc_ready, eng_desc_valid, eng_busy,
                           video_ch0_src_line_align_sticky,
                           video_ch0_src_overflow_sticky, rgb_error_sticky};
        end
    end

    xpm_cdc_array_single #(.WIDTH(32), .DEST_SYNC_FF(4)) u_rgb_dbg0_cdc (
        .src_clk(video_clk), .src_in(rgb_dbg0_v), .dest_clk(clk),
        .dest_out(reg_rgb_c2h_dbg0));
    xpm_cdc_array_single #(.WIDTH(32), .DEST_SYNC_FF(4)) u_rgb_dbg1_cdc (
        .src_clk(video_clk), .src_in(rgb_dbg1_v), .dest_clk(clk),
        .dest_out(reg_rgb_c2h_dbg1));
    xpm_cdc_array_single #(.WIDTH(32), .DEST_SYNC_FF(4)) u_rgb_dbg5_cdc (
        .src_clk(video_clk), .src_in(rgb_dbg5_v), .dest_clk(clk),
        .dest_out(reg_rgb_c2h_dbg5));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_rgb_bytes_cdc (
        .src_clk(video_clk), .src_in_bin(rgb_dbg2_v),
        .dest_clk(clk), .dest_out_bin(reg_rgb_c2h_dbg2));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_rgb_drop_cdc (
        .src_clk(video_clk), .src_in_bin(rgb_dbg3_v),
        .dest_clk(clk), .dest_out_bin(reg_rgb_c2h_dbg3));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1)) u_rgb_frames_cdc (
        .src_clk(video_clk), .src_in_bin(rgb_dbg4_v),
        .dest_clk(clk), .dest_out_bin(reg_rgb_c2h_dbg4));
`else
    nv12_capture_engine #(
        .MAX_WIDTH(4096),
        .PCIE_DATA_WIDTH(128),
        .FIFO_DEPTH(512),
        .MWR_PAYLOAD_BYTES(256)
    ) u_nv12_capture_engine (
        .clk(video_clk),
        .rst_n(video_rst_n),
        .desc_valid(eng_desc_valid),
        .desc_ready(nv12_desc_ready_v),
        .desc_format(eng_format),
        .desc_sg_mode(eng_desc_sg_mode),
        .plane_y_addr(eng_y_addr),
        .plane_uv_addr(eng_uv_addr),
        .frame_width(eng_width),
        .frame_height(eng_height),
        .frame_stride(eng_stride),
        .sgl_y_wr_en(v_sgl_y_wr_en),
        .sgl_y_wr_addr(v_sgl_y_dout[63:0]),
        .sgl_y_wr_len(v_sgl_y_dout[95:64]),
        .sgl_y_wr_flags(v_sgl_y_dout[127:96]),
        .sgl_uv_wr_en(!v_sgl_uv_empty && v_sgl_uv_pop_ready && eng_busy),
        .sgl_uv_wr_addr(v_sgl_uv_dout[63:0]),
        .sgl_uv_wr_len(v_sgl_uv_dout[95:64]),
        .sgl_uv_wr_flags(v_sgl_uv_dout[127:96]),
        .cur_y_sgl_count(),
        .cur_uv_sgl_count(),
        .sgl_y_pop_ready(v_sgl_y_pop_ready),
        .sgl_uv_pop_ready(v_sgl_uv_pop_ready),
        .pacer_enable(1'b0),   /* Hardware pacer disabled; Linux driver pacer drives 60 FPS */
        .frame_interval_clks(32'd2500000),   // 60 FPS @ 150 MHz
        .global_timestamp(eng_ts),
        .s_axis_tdata(video_ch0_tdata),
        .s_axis_tvalid(video_ch0_tvalid),
        .s_axis_tlast(video_ch0_tlast),
        .s_axis_tuser(video_ch0_tuser),
        .s_axis_tready(video_ch0_tready),
        .c2h_req_valid(eng_req_valid),
        .c2h_req_addr(eng_req_addr),
        .c2h_req_dw_len(eng_req_dw_len),
        .c2h_req_data(eng_req_data),
        .c2h_req_last(),
        .c2h_req_data_ready(eng_req_ready),
        .c2h_req_ack(eng_req_ack),
        .video_busy(eng_busy),
        .video_frame_done(eng_frame_done),
        .frame_pts(eng_frame_pts),
        .protocol_error_count(eng_err_count)
    );

    // Every other personality keeps the 0x0E0..0x0F4 reads at 0: they are this
    // engine's internals, not a shared channel ABI.
    assign reg_rgb_c2h_dbg0 = 32'd0;
    assign reg_rgb_c2h_dbg1 = 32'd0;
    assign reg_rgb_c2h_dbg2 = 32'd0;
    assign reg_rgb_c2h_dbg3 = 32'd0;
    assign reg_rgb_c2h_dbg4 = 32'd0;
    assign reg_rgb_c2h_dbg5 = 32'd0;
`endif

    // =========================================================================
    // Loopback & Capture Engines for Channels 1, 2, and 3
    // =========================================================================
    // NOTE: The full multi-channel block below is disabled when the
    // `QPCIe_single_rgb24_path` define is set, leaving only the Ch0 TPG->RGB24
    // SGL capture path (used for single-path bandwidth validation builds).
`ifndef SC7F0_C2H_ONLY
`ifndef QPCIe_single_rgb24_path
    // ---------------------- CHANNEL 1 ----------------------------------------
    wire [127:0] ch1_sgl_y_dout, ch1_sgl_uv_dout;
    wire        ch1_sgl_y_empty, ch1_sgl_uv_empty;
    wire        ch1_sgl_y_pop_ready, ch1_sgl_uv_pop_ready;
    wire        ch1_sgl_y_rd_en, ch1_sgl_uv_rd_en;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch1_sgl_y_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(sgl_ch1_y_wr_en), .din({sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}), .prog_full(ch1_sgl_y_almost_full), .full(), .rd_clk(video_clk), .rd_en(ch1_sgl_y_rd_en), .dout(ch1_sgl_y_dout), .empty(ch1_sgl_y_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
    u_ch1_sgl_uv_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(sgl_ch1_uv_wr_en), .din({sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}), .prog_full(ch1_sgl_uv_almost_full), .full(), .rd_clk(video_clk), .rd_en(ch1_sgl_uv_rd_en), .dout(ch1_sgl_uv_dout), .empty(ch1_sgl_uv_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());

    wire [129:0] ch1_fifo_dout;
    wire        ch1_fifo_empty, ch1_tready;
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(512), .WRITE_DATA_WIDTH(130), .READ_DATA_WIDTH(130), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000"))
    u_ch1_loopback_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(lb_tvalid && lb_tready && sg_loopback_enable && (sg_loopback_channel == 2'd1 || sg_loopback_channel == 2'd0)), .din({lb_tuser, lb_tlast, lb_tdata}), .full(ch1_loopback_full), .rd_clk(video_clk), .rd_en(!ch1_fifo_empty && ch1_tready), .dout(ch1_fifo_dout), .empty(ch1_fifo_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
    wire [127:0] ch1_tdata = ch1_fifo_dout[127:0]; wire ch1_tlast = ch1_fifo_dout[128]; wire ch1_tuser = ch1_fifo_dout[129]; wire ch1_tvalid = !ch1_fifo_empty;

    reg hs1_send_q; reg [240:0] hs1_bus_q; wire hs1_src_rcv, hs1_dest_req; wire [240:0] hs1_dest_bus; reg hs1_dest_ack; reg eng1_desc_valid, eng1_desc_sg_mode; reg [63:0] eng1_y_addr, eng1_uv_addr, eng1_ts; reg [15:0] eng1_width, eng1_height, eng1_stride; wire nv12_ch1_desc_ready_v;
    wire pcie_frame_done_ch1;
    reg ch1_owner_busy;
    wire nv12_ch1_desc_select = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd1);
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin hs1_send_q <= 1'b0; hs1_bus_q <= 241'd0; end
        else if (!hs1_send_q && !hs1_src_rcv && !ch1_owner_busy && c2h_desc_valid && nv12_ch1_desc_select) begin hs1_bus_q <= {(c2h_desc_ctrl[4] | c2h_desc_ctrl[5]), global_timestamp, c2h_dst_stride, c2h_line_count, c2h_line_width, c2h_plane1_dst, c2h_plane0_dst}; hs1_send_q <= 1'b1; end
        else if (hs1_send_q && hs1_src_rcv) begin hs1_send_q <= 1'b0; end
    end
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n)
            ch1_owner_busy <= 1'b0;
        else if (pcie_frame_done_ch1)
            ch1_owner_busy <= 1'b0;
        else if (c2h_desc_valid && nv12_ch1_desc_select &&
                 !hs1_send_q && !hs1_src_rcv && !ch1_owner_busy)
            ch1_owner_busy <= 1'b1;
    end
    assign nv12_ch1_desc_ready = c2h_desc_valid && nv12_ch1_desc_select &&
                                  !hs1_send_q && !hs1_src_rcv && !ch1_owner_busy;
    xpm_cdc_handshake #(.WIDTH(241), .DEST_EXT_HSK(1)) u_desc_cdc_ch1 (.src_clk(clk), .src_send(hs1_send_q), .src_rcv(hs1_src_rcv), .src_in(hs1_bus_q), .dest_clk(video_clk), .dest_req(hs1_dest_req), .dest_out(hs1_dest_bus), .dest_ack(hs1_dest_ack));
    reg [1:0] dest1_state;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin dest1_state <= DEST_IDLE; eng1_desc_valid <= 1'b0; eng1_desc_sg_mode <= 1'b0; hs1_dest_ack <= 1'b0; eng1_y_addr <= 64'd0; eng1_uv_addr <= 64'd0; eng1_width <= 16'd0; eng1_height <= 16'd0; eng1_stride <= 16'd0; eng1_ts <= 64'd0; end
        else case (dest1_state)
            DEST_IDLE: begin hs1_dest_ack <= 1'b0; if (hs1_dest_req) begin eng1_y_addr <= hs1_dest_bus[63:0]; eng1_uv_addr <= hs1_dest_bus[127:64]; eng1_width <= hs1_dest_bus[143:128]; eng1_height <= hs1_dest_bus[159:144]; eng1_stride <= hs1_dest_bus[175:160]; eng1_ts <= hs1_dest_bus[239:176]; eng1_desc_sg_mode <= hs1_dest_bus[240]; eng1_desc_valid <= 1'b1; dest1_state <= DEST_WAIT_ENG; end end
            DEST_WAIT_ENG: begin if (eng1_desc_valid && nv12_ch1_desc_ready_v) begin eng1_desc_valid <= 1'b0; hs1_dest_ack <= 1'b1; dest1_state <= DEST_WAIT_REQ_LOW; end end
            DEST_WAIT_REQ_LOW: begin if (!hs1_dest_req) begin hs1_dest_ack <= 1'b0; dest1_state <= DEST_IDLE; end end
            default: dest1_state <= DEST_IDLE;
        endcase
    end
    wire eng1_req_valid, eng1_req_ready, eng1_req_ack; wire [63:0] eng1_req_addr; wire [10:0] eng1_req_dw_len; wire [127:0] eng1_req_data; wire eng1_frame_done;
    assign ch1_sgl_y_rd_en = !ch1_sgl_y_empty && ch1_sgl_y_pop_ready && v_busy[1];
    assign ch1_sgl_uv_rd_en = !ch1_sgl_uv_empty && ch1_sgl_uv_pop_ready && v_busy[1];
    nv12_capture_engine #(.MAX_WIDTH(4096), .PCIE_DATA_WIDTH(128), .FIFO_DEPTH(32), .MWR_PAYLOAD_BYTES(256), .RAW_INPUT(1))
    u_nv12_capture_engine_ch1 (.clk(video_clk), .rst_n(video_rst_n), .desc_valid(eng1_desc_valid), .desc_ready(nv12_ch1_desc_ready_v), .desc_format(4'd2), .desc_sg_mode(eng1_desc_sg_mode), .plane_y_addr(eng1_y_addr), .plane_uv_addr(eng1_uv_addr), .frame_width(eng1_width), .frame_height(eng1_height), .frame_stride(eng1_stride),
        .sgl_y_wr_en(ch1_sgl_y_rd_en), .sgl_y_wr_addr(ch1_sgl_y_dout[63:0]), .sgl_y_wr_len(ch1_sgl_y_dout[95:64]), .sgl_y_wr_flags(ch1_sgl_y_dout[127:96]),
        .sgl_uv_wr_en(ch1_sgl_uv_rd_en), .sgl_uv_wr_addr(ch1_sgl_uv_dout[63:0]), .sgl_uv_wr_len(ch1_sgl_uv_dout[95:64]), .sgl_uv_wr_flags(ch1_sgl_uv_dout[127:96]),
        .cur_y_sgl_count(), .cur_uv_sgl_count(), .sgl_y_pop_ready(ch1_sgl_y_pop_ready), .sgl_uv_pop_ready(ch1_sgl_uv_pop_ready), .pacer_enable(1'b0), .frame_interval_clks(32'd2500000), .global_timestamp(eng1_ts), .s_axis_tdata(ch1_tdata), .s_axis_tvalid(ch1_tvalid), .s_axis_tlast(ch1_tlast), .s_axis_tuser(ch1_tuser), .s_axis_tready(ch1_tready),
        .c2h_req_valid(eng1_req_valid), .c2h_req_addr(eng1_req_addr), .c2h_req_dw_len(eng1_req_dw_len), .c2h_req_data(eng1_req_data), .c2h_req_last(), .c2h_req_data_ready(eng1_req_ready), .c2h_req_ack(eng1_req_ack), .video_busy(v_busy[1]), .video_frame_done(eng1_frame_done), .frame_pts(v_pts[1]), .protocol_error_count(v_drop_cnt[1]));
    assign v_done[1] = pcie_frame_done_ch1;
    video_req_cdc #(.DATA_WIDTH(PCIE_DATA_WIDTH),
        .MAX_DWORDS(64), .FIFO_DEPTH(512)) u_video_req_cdc_ch1 (.wr_clk(video_clk), .wr_rst_n(video_rst_n), .s_req_valid(eng1_req_valid), .s_req_addr(eng1_req_addr), .s_req_dw_len(eng1_req_dw_len), .s_req_data(eng1_req_data), .s_req_data_ready(eng1_req_ready), .s_req_ack(eng1_req_ack), .s_frame_done(eng1_frame_done), .rd_clk(clk), .rd_rst_n(dma_rst_n), .m_req_valid(v_c2h_req_valid[1]), .m_req_addr(v_c2h_req_addr[127:64]), .m_req_dw_len(v_c2h_req_dw_len[21:11]), .m_req_data(v_c2h_req_data[(1*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]), .m_req_data_ready(v_c2h_req_data_ready[1]), .m_req_ack(v_c2h_req_ack[1]), .m_frame_done(pcie_frame_done_ch1), .m_fifo_empty(), .m_fifo_count());

    // ---------------------- CHANNEL 2 ----------------------------------------
    generate
        if (NUM_VIDEO_CH > 2) begin : gen_vch2
            wire [127:0] ch2_sgl_y_dout, ch2_sgl_uv_dout;
            wire        ch2_sgl_y_empty, ch2_sgl_uv_empty;
            wire        ch2_sgl_y_pop_ready, ch2_sgl_uv_pop_ready;
            xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
            u_ch2_sgl_y_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(sgl_ch2_y_wr_en), .din({sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}), .prog_full(ch2_sgl_y_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch2_sgl_y_empty && ch2_sgl_y_pop_ready), .dout(ch2_sgl_y_dout), .empty(ch2_sgl_y_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
            xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
            u_ch2_sgl_uv_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(sgl_ch2_uv_wr_en), .din({sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}), .prog_full(ch2_sgl_uv_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch2_sgl_uv_empty && ch2_sgl_uv_pop_ready), .dout(ch2_sgl_uv_dout), .empty(ch2_sgl_uv_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());

            wire [129:0] ch2_fifo_dout;
            wire        ch2_fifo_empty, ch2_tready;
            xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(512), .WRITE_DATA_WIDTH(130), .READ_DATA_WIDTH(130), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000"))
            u_ch2_loopback_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(lb_tvalid && lb_tready && sg_loopback_enable && (sg_loopback_channel == 2'd2)), .din({lb_tuser, lb_tlast, lb_tdata}), .full(ch2_loopback_full), .rd_clk(video_clk), .rd_en(!ch2_fifo_empty && ch2_tready), .dout(ch2_fifo_dout), .empty(ch2_fifo_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
            wire [127:0] ch2_tdata = ch2_fifo_dout[127:0]; wire ch2_tlast = ch2_fifo_dout[128]; wire ch2_tuser = ch2_fifo_dout[129]; wire ch2_tvalid = !ch2_fifo_empty;

            reg hs2_send_q; reg [240:0] hs2_bus_q; wire hs2_src_rcv, hs2_dest_req; wire [240:0] hs2_dest_bus; reg hs2_dest_ack; reg eng2_desc_valid, eng2_desc_sg_mode; reg [63:0] eng2_y_addr, eng2_uv_addr, eng2_ts; reg [15:0] eng2_width, eng2_height, eng2_stride; wire nv12_ch2_desc_ready_v;
            wire pcie_frame_done_ch2;
            reg ch2_owner_busy;
            wire nv12_ch2_desc_select = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd2);
            always @(posedge clk or negedge dma_rst_n) begin
                if (!dma_rst_n) begin hs2_send_q <= 1'b0; hs2_bus_q <= 241'd0; end
                else if (!hs2_send_q && !hs2_src_rcv && !ch2_owner_busy && c2h_desc_valid && nv12_ch2_desc_select) begin hs2_bus_q <= {(c2h_desc_ctrl[4] | c2h_desc_ctrl[5]), global_timestamp, c2h_dst_stride, c2h_line_count, c2h_line_width, c2h_plane1_dst, c2h_plane0_dst}; hs2_send_q <= 1'b1; end
                else if (hs2_send_q && hs2_src_rcv) begin hs2_send_q <= 1'b0; end
            end
            always @(posedge clk or negedge dma_rst_n) begin
                if (!dma_rst_n)
                    ch2_owner_busy <= 1'b0;
                else if (pcie_frame_done_ch2)
                    ch2_owner_busy <= 1'b0;
                else if (c2h_desc_valid && nv12_ch2_desc_select &&
                         !hs2_send_q && !hs2_src_rcv && !ch2_owner_busy)
                    ch2_owner_busy <= 1'b1;
            end
            assign nv12_ch2_desc_ready = c2h_desc_valid && nv12_ch2_desc_select &&
                                          !hs2_send_q && !hs2_src_rcv && !ch2_owner_busy;
            xpm_cdc_handshake #(.WIDTH(241), .DEST_EXT_HSK(1)) u_desc_cdc_ch2 (.src_clk(clk), .src_send(hs2_send_q), .src_rcv(hs2_src_rcv), .src_in(hs2_bus_q), .dest_clk(video_clk), .dest_req(hs2_dest_req), .dest_out(hs2_dest_bus), .dest_ack(hs2_dest_ack));
            reg [1:0] dest2_state;
            always @(posedge video_clk or negedge video_rst_n) begin
                if (!video_rst_n) begin dest2_state <= DEST_IDLE; eng2_desc_valid <= 1'b0; eng2_desc_sg_mode <= 1'b0; hs2_dest_ack <= 1'b0; eng2_y_addr <= 64'd0; eng2_uv_addr <= 64'd0; eng2_width <= 16'd0; eng2_height <= 16'd0; eng2_stride <= 16'd0; eng2_ts <= 64'd0; end
                else case (dest2_state)
                    DEST_IDLE: begin hs2_dest_ack <= 1'b0; if (hs2_dest_req) begin eng2_y_addr <= hs2_dest_bus[63:0]; eng2_uv_addr <= hs2_dest_bus[127:64]; eng2_width <= hs2_dest_bus[143:128]; eng2_height <= hs2_dest_bus[159:144]; eng2_stride <= hs2_dest_bus[175:160]; eng2_ts <= hs2_dest_bus[239:176]; eng2_desc_sg_mode <= hs2_dest_bus[240]; eng2_desc_valid <= 1'b1; dest2_state <= DEST_WAIT_ENG; end end
                    DEST_WAIT_ENG: begin if (eng2_desc_valid && nv12_ch2_desc_ready_v) begin eng2_desc_valid <= 1'b0; hs2_dest_ack <= 1'b1; dest2_state <= DEST_WAIT_REQ_LOW; end end
                    DEST_WAIT_REQ_LOW: begin if (!hs2_dest_req) begin hs2_dest_ack <= 1'b0; dest2_state <= DEST_IDLE; end end
                    default: dest2_state <= DEST_IDLE;
                endcase
            end
            wire eng2_req_valid, eng2_req_ready, eng2_req_ack; wire [63:0] eng2_req_addr; wire [10:0] eng2_req_dw_len; wire [127:0] eng2_req_data; wire eng2_frame_done;
            nv12_capture_engine #(.MAX_WIDTH(4096), .PCIE_DATA_WIDTH(128), .FIFO_DEPTH(32), .MWR_PAYLOAD_BYTES(256), .RAW_INPUT(1))
            u_nv12_capture_engine_ch2 (.clk(video_clk), .rst_n(video_rst_n), .desc_valid(eng2_desc_valid), .desc_ready(nv12_ch2_desc_ready_v), .desc_format(4'd2), .desc_sg_mode(eng2_desc_sg_mode), .plane_y_addr(eng2_y_addr), .plane_uv_addr(eng2_uv_addr), .frame_width(eng2_width), .frame_height(eng2_height), .frame_stride(eng2_stride),
                .sgl_y_wr_en(!ch2_sgl_y_empty && ch2_sgl_y_pop_ready), .sgl_y_wr_addr(ch2_sgl_y_dout[63:0]), .sgl_y_wr_len(ch2_sgl_y_dout[95:64]), .sgl_y_wr_flags(ch2_sgl_y_dout[127:96]),
                .sgl_uv_wr_en(!ch2_sgl_uv_empty && ch2_sgl_uv_pop_ready), .sgl_uv_wr_addr(ch2_sgl_uv_dout[63:0]), .sgl_uv_wr_len(ch2_sgl_uv_dout[95:64]), .sgl_uv_wr_flags(ch2_sgl_uv_dout[127:96]),
                .cur_y_sgl_count(), .cur_uv_sgl_count(), .sgl_y_pop_ready(ch2_sgl_y_pop_ready), .sgl_uv_pop_ready(ch2_sgl_uv_pop_ready), .pacer_enable(1'b0), .frame_interval_clks(32'd2500000), .global_timestamp(eng2_ts), .s_axis_tdata(ch2_tdata), .s_axis_tvalid(ch2_tvalid), .s_axis_tlast(ch2_tlast), .s_axis_tuser(ch2_tuser), .s_axis_tready(ch2_tready),
                .c2h_req_valid(eng2_req_valid), .c2h_req_addr(eng2_req_addr), .c2h_req_dw_len(eng2_req_dw_len), .c2h_req_data(eng2_req_data), .c2h_req_last(), .c2h_req_data_ready(eng2_req_ready), .c2h_req_ack(eng2_req_ack), .video_busy(v_busy[2]), .video_frame_done(eng2_frame_done), .frame_pts(v_pts[2]), .protocol_error_count(v_drop_cnt[2]));
            assign v_done[2] = pcie_frame_done_ch2;
            video_req_cdc #(.DATA_WIDTH(PCIE_DATA_WIDTH),
        .MAX_DWORDS(64), .FIFO_DEPTH(512)) u_video_req_cdc_ch2 (.wr_clk(video_clk), .wr_rst_n(video_rst_n), .s_req_valid(eng2_req_valid), .s_req_addr(eng2_req_addr), .s_req_dw_len(eng2_req_dw_len), .s_req_data(eng2_req_data), .s_req_data_ready(eng2_req_ready), .s_req_ack(eng2_req_ack), .s_frame_done(eng2_frame_done), .rd_clk(clk), .rd_rst_n(dma_rst_n), .m_req_valid(v_c2h_req_valid[2]), .m_req_addr(v_c2h_req_addr[191:128]), .m_req_dw_len(v_c2h_req_dw_len[32:22]), .m_req_data(v_c2h_req_data[(2*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]), .m_req_data_ready(v_c2h_req_data_ready[2]), .m_req_ack(v_c2h_req_ack[2]), .m_frame_done(pcie_frame_done_ch2), .m_fifo_empty(), .m_fifo_count());
        end else begin : gen_no_vch2
            assign ch2_sgl_y_almost_full  = 1'b0;
            assign ch2_sgl_uv_almost_full = 1'b0;
            assign ch2_loopback_full      = 1'b0;
            assign nv12_ch2_desc_ready    = 1'b0;
        end
    endgenerate

    // ---------------------- CHANNEL 3 ----------------------------------------
    generate
        if (NUM_VIDEO_CH > 3) begin : gen_vch3
            wire [127:0] ch3_sgl_y_dout, ch3_sgl_uv_dout;
            wire        ch3_sgl_y_empty, ch3_sgl_uv_empty;
            wire        ch3_sgl_y_pop_ready, ch3_sgl_uv_pop_ready;
            xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
            u_ch3_sgl_y_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(sgl_ch3_y_wr_en), .din({sgl_y_wr_flags, sgl_y_wr_len, sgl_y_wr_addr}), .prog_full(ch3_sgl_y_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch3_sgl_y_empty && ch3_sgl_y_pop_ready), .dout(ch3_sgl_y_dout), .empty(ch3_sgl_y_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
            xpm_fifo_async #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(48), .USE_ADV_FEATURES("0002"))
            u_ch3_sgl_uv_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(sgl_ch3_uv_wr_en), .din({sgl_uv_wr_flags, sgl_uv_wr_len, sgl_uv_wr_addr}), .prog_full(ch3_sgl_uv_almost_full), .full(), .rd_clk(video_clk), .rd_en(!ch3_sgl_uv_empty && ch3_sgl_uv_pop_ready), .dout(ch3_sgl_uv_dout), .empty(ch3_sgl_uv_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());

            wire [129:0] ch3_fifo_dout;
            wire        ch3_fifo_empty, ch3_tready;
            xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(512), .WRITE_DATA_WIDTH(130), .READ_DATA_WIDTH(130), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000"))
            u_ch3_loopback_cdc (.rst(video_cdc_reset_pcie), .wr_clk(clk), .wr_en(lb_tvalid && lb_tready && sg_loopback_enable && (sg_loopback_channel == 2'd3)), .din({lb_tuser, lb_tlast, lb_tdata}), .full(ch3_loopback_full), .rd_clk(video_clk), .rd_en(!ch3_fifo_empty && ch3_tready), .dout(ch3_fifo_dout), .empty(ch3_fifo_empty), .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr(), .wr_rst_busy(), .rd_rst_busy());
            wire [127:0] ch3_tdata = ch3_fifo_dout[127:0]; wire ch3_tlast = ch3_fifo_dout[128]; wire ch3_tuser = ch3_fifo_dout[129]; wire ch3_tvalid = !ch3_fifo_empty;

            reg hs3_send_q; reg [240:0] hs3_bus_q; wire hs3_src_rcv, hs3_dest_req; wire [240:0] hs3_dest_bus; reg hs3_dest_ack; reg eng3_desc_valid, eng3_desc_sg_mode; reg [63:0] eng3_y_addr, eng3_uv_addr, eng3_ts; reg [15:0] eng3_width, eng3_height, eng3_stride; wire nv12_ch3_desc_ready_v;
            wire pcie_frame_done_ch3;
            reg ch3_owner_busy;
            wire nv12_ch3_desc_select = (c2h_format == 4'd2) && (c2h_plane_count == 4'd2) && (c2h_desc_ctrl[7:6] == 2'd3);
            always @(posedge clk or negedge dma_rst_n) begin
                if (!dma_rst_n) begin hs3_send_q <= 1'b0; hs3_bus_q <= 241'd0; end
                else if (!hs3_send_q && !hs3_src_rcv && !ch3_owner_busy && c2h_desc_valid && nv12_ch3_desc_select) begin hs3_bus_q <= {(c2h_desc_ctrl[4] | c2h_desc_ctrl[5]), global_timestamp, c2h_dst_stride, c2h_line_count, c2h_line_width, c2h_plane1_dst, c2h_plane0_dst}; hs3_send_q <= 1'b1; end
                else if (hs3_send_q && hs3_src_rcv) begin hs3_send_q <= 1'b0; end
            end
            always @(posedge clk or negedge dma_rst_n) begin
                if (!dma_rst_n)
                    ch3_owner_busy <= 1'b0;
                else if (pcie_frame_done_ch3)
                    ch3_owner_busy <= 1'b0;
                else if (c2h_desc_valid && nv12_ch3_desc_select &&
                         !hs3_send_q && !hs3_src_rcv && !ch3_owner_busy)
                    ch3_owner_busy <= 1'b1;
            end
            assign nv12_ch3_desc_ready = c2h_desc_valid && nv12_ch3_desc_select &&
                                          !hs3_send_q && !hs3_src_rcv && !ch3_owner_busy;
            xpm_cdc_handshake #(.WIDTH(241), .DEST_EXT_HSK(1)) u_desc_cdc_ch3 (.src_clk(clk), .src_send(hs3_send_q), .src_rcv(hs3_src_rcv), .src_in(hs3_bus_q), .dest_clk(video_clk), .dest_req(hs3_dest_req), .dest_out(hs3_dest_bus), .dest_ack(hs3_dest_ack));
            reg [1:0] dest3_state;
            always @(posedge video_clk or negedge video_rst_n) begin
                if (!video_rst_n) begin dest3_state <= DEST_IDLE; eng3_desc_valid <= 1'b0; eng3_desc_sg_mode <= 1'b0; hs3_dest_ack <= 1'b0; eng3_y_addr <= 64'd0; eng3_uv_addr <= 64'd0; eng3_width <= 16'd0; eng3_height <= 16'd0; eng3_stride <= 16'd0; eng3_ts <= 64'd0; end
                else case (dest3_state)
                    DEST_IDLE: begin hs3_dest_ack <= 1'b0; if (hs3_dest_req) begin eng3_y_addr <= hs3_dest_bus[63:0]; eng3_uv_addr <= hs3_dest_bus[127:64]; eng3_width <= hs3_dest_bus[143:128]; eng3_height <= hs3_dest_bus[159:144]; eng3_stride <= hs3_dest_bus[175:160]; eng3_ts <= hs3_dest_bus[239:176]; eng3_desc_sg_mode <= hs3_dest_bus[240]; eng3_desc_valid <= 1'b1; dest3_state <= DEST_WAIT_ENG; end end
                    DEST_WAIT_ENG: begin if (eng3_desc_valid && nv12_ch3_desc_ready_v) begin eng3_desc_valid <= 1'b0; hs3_dest_ack <= 1'b1; dest3_state <= DEST_WAIT_REQ_LOW; end end
                    DEST_WAIT_REQ_LOW: begin if (!hs3_dest_req) begin hs3_dest_ack <= 1'b0; dest3_state <= DEST_IDLE; end end
                    default: dest3_state <= DEST_IDLE;
                endcase
            end
            wire eng3_req_valid, eng3_req_ready, eng3_req_ack; wire [63:0] eng3_req_addr; wire [10:0] eng3_req_dw_len; wire [127:0] eng3_req_data; wire eng3_frame_done;
            nv12_capture_engine #(.MAX_WIDTH(4096), .PCIE_DATA_WIDTH(128), .FIFO_DEPTH(32), .MWR_PAYLOAD_BYTES(256), .RAW_INPUT(1))
            u_nv12_capture_engine_ch3 (.clk(video_clk), .rst_n(video_rst_n), .desc_valid(eng3_desc_valid), .desc_ready(nv12_ch3_desc_ready_v), .desc_format(4'd2), .desc_sg_mode(eng3_desc_sg_mode), .plane_y_addr(eng3_y_addr), .plane_uv_addr(eng3_uv_addr), .frame_width(eng3_width), .frame_height(eng3_height), .frame_stride(eng3_stride),
                .sgl_y_wr_en(!ch3_sgl_y_empty && ch3_sgl_y_pop_ready), .sgl_y_wr_addr(ch3_sgl_y_dout[63:0]), .sgl_y_wr_len(ch3_sgl_y_dout[95:64]), .sgl_y_wr_flags(ch3_sgl_y_dout[127:96]),
                .sgl_uv_wr_en(!ch3_sgl_uv_empty && ch3_sgl_uv_pop_ready), .sgl_uv_wr_addr(ch3_sgl_uv_dout[63:0]), .sgl_uv_wr_len(ch3_sgl_uv_dout[95:64]), .sgl_uv_wr_flags(ch3_sgl_uv_dout[127:96]),
                .cur_y_sgl_count(), .cur_uv_sgl_count(), .sgl_y_pop_ready(ch3_sgl_y_pop_ready), .sgl_uv_pop_ready(ch3_sgl_uv_pop_ready), .pacer_enable(1'b0), .frame_interval_clks(32'd2500000), .global_timestamp(eng3_ts), .s_axis_tdata(ch3_tdata), .s_axis_tvalid(ch3_tvalid), .s_axis_tlast(ch3_tlast), .s_axis_tuser(ch3_tuser), .s_axis_tready(ch3_tready),
                .c2h_req_valid(eng3_req_valid), .c2h_req_addr(eng3_req_addr), .c2h_req_dw_len(eng3_req_dw_len), .c2h_req_data(eng3_req_data), .c2h_req_last(), .c2h_req_data_ready(eng3_req_ready), .c2h_req_ack(eng3_req_ack), .video_busy(v_busy[3]), .video_frame_done(eng3_frame_done), .frame_pts(v_pts[3]), .protocol_error_count(v_drop_cnt[3]));
            assign v_done[3] = pcie_frame_done_ch3;
            video_req_cdc #(.DATA_WIDTH(PCIE_DATA_WIDTH),
        .MAX_DWORDS(64), .FIFO_DEPTH(512)) u_video_req_cdc_ch3 (.wr_clk(video_clk), .wr_rst_n(video_rst_n), .s_req_valid(eng3_req_valid), .s_req_addr(eng3_req_addr), .s_req_dw_len(eng3_req_dw_len), .s_req_data(eng3_req_data), .s_req_data_ready(eng3_req_ready), .s_req_ack(eng3_req_ack), .s_frame_done(eng3_frame_done), .rd_clk(clk), .rd_rst_n(dma_rst_n), .m_req_valid(v_c2h_req_valid[3]), .m_req_addr(v_c2h_req_addr[255:192]), .m_req_dw_len(v_c2h_req_dw_len[43:33]), .m_req_data(v_c2h_req_data[(3*PCIE_DATA_WIDTH) +: PCIE_DATA_WIDTH]), .m_req_data_ready(v_c2h_req_data_ready[3]), .m_req_ack(v_c2h_req_ack[3]), .m_frame_done(pcie_frame_done_ch3), .m_fifo_empty(), .m_fifo_count());
        end else begin : gen_no_vch3
            assign ch3_sgl_y_almost_full  = 1'b0;
            assign ch3_sgl_uv_almost_full = 1'b0;
            assign ch3_loopback_full      = 1'b0;
            assign nv12_ch3_desc_ready    = 1'b0;
        end
    endgenerate

`endif // QPCIe_single_rgb24_path
`else
    // Register ABI keeps four slots, but only raw video channel zero exists.
    assign v_c2h_req_valid[1]=0; assign v_c2h_req_addr[64+:64]=0;
    assign v_c2h_req_dw_len[11+:11]=0; assign v_c2h_req_data[1*PCIE_DATA_WIDTH+:PCIE_DATA_WIDTH]=0;
    assign v_c2h_req_last[1]=0; assign v_busy[1]=0; assign v_done[1]=0;
    assign v_pts[1]=0; assign v_drop_cnt[1]=0; assign nv12_ch1_desc_ready=0;
    assign ch1_sgl_y_almost_full=0; assign ch1_sgl_uv_almost_full=0; assign ch1_loopback_full=0;
    assign v_c2h_req_valid[2]=0; assign v_c2h_req_addr[128+:64]=0;
    assign v_c2h_req_dw_len[22+:11]=0; assign v_c2h_req_data[2*PCIE_DATA_WIDTH+:PCIE_DATA_WIDTH]=0;
    assign v_c2h_req_last[2]=0; assign v_busy[2]=0; assign v_done[2]=0;
    assign v_pts[2]=0; assign v_drop_cnt[2]=0; assign nv12_ch2_desc_ready=0;
    assign ch2_sgl_y_almost_full=0; assign ch2_sgl_uv_almost_full=0; assign ch2_loopback_full=0;
    assign v_c2h_req_valid[3]=0; assign v_c2h_req_addr[192+:64]=0;
    assign v_c2h_req_dw_len[33+:11]=0; assign v_c2h_req_data[3*PCIE_DATA_WIDTH+:PCIE_DATA_WIDTH]=0;
    assign v_c2h_req_last[3]=0; assign v_busy[3]=0; assign v_done[3]=0;
    assign v_pts[3]=0; assign v_drop_cnt[3]=0; assign nv12_ch3_desc_ready=0;
    assign ch3_sgl_y_almost_full=0; assign ch3_sgl_uv_almost_full=0; assign ch3_loopback_full=0;
`endif // SC7F0_C2H_ONLY

    assign m_axis_video_tdata  = {(NUM_VIDEO_CH*VIDEO_DATA_WIDTH){1'b0}};
    assign m_axis_video_tvalid = {NUM_VIDEO_CH{1'b0}};
    assign m_axis_video_tlast  = {NUM_VIDEO_CH{1'b0}};
    assign m_axis_video_tuser  = {NUM_VIDEO_CH{1'b0}};

`ifndef SC7F0_C2H_ONLY
    // 8.1 Audio Playback H2C Block RAM FIFOs (Channels 1, 2, 3)
    audio_h2c_fifo #(.DEPTH(512)) u_audio_h2c_fifo_ch1 (
        .clk(clk),
        .rst_n(dma_rst_n),
        .flush(reg_audio_loopback_ctrl[8]),
        .wr_data(h2c_fifo_wr_data),
        .wr_en(h2c_fifo_wr_en_ch1),
        .full(h2c_fifo_full_ch1),
        .count(h2c_fifo_count_ch1),
        .empty(h2c_fifo_empty_ch1),
        .rd_en(h2c_fifo_rd_en_ch1),
        .rd_data(h2c_fifo_rdata_ch1),
        .rd_valid()
    );

    generate
        if (NUM_AUDIO_CH > 2) begin : gen_ach2_fifo
            audio_h2c_fifo #(.DEPTH(512)) u_audio_h2c_fifo_ch2 (
                .clk(clk),
                .rst_n(dma_rst_n),
                .flush(reg_audio_loopback_ctrl[9]),
                .wr_data(h2c_fifo_wr_data),
                .wr_en(h2c_fifo_wr_en_ch2),
                .full(h2c_fifo_full_ch2),
                .count(h2c_fifo_count_ch2),
                .empty(h2c_fifo_empty_ch2),
                .rd_en(h2c_fifo_rd_en_ch2),
                .rd_data(h2c_fifo_rdata_ch2),
                .rd_valid()
            );
        end else begin : gen_no_ach2_fifo
            assign h2c_fifo_full_ch2  = 1'b0;
            assign h2c_fifo_count_ch2 = 8'd0;
            assign h2c_fifo_empty_ch2 = 1'b1;
            assign h2c_fifo_rdata_ch2 = 32'd0;
        end

        if (NUM_AUDIO_CH > 3) begin : gen_ach3_fifo
            audio_h2c_fifo #(.DEPTH(512)) u_audio_h2c_fifo_ch3 (
                .clk(clk),
                .rst_n(dma_rst_n),
                .flush(reg_audio_loopback_ctrl[10]),
                .wr_data(h2c_fifo_wr_data),
                .wr_en(h2c_fifo_wr_en_ch3),
                .full(h2c_fifo_full_ch3),
                .count(h2c_fifo_count_ch3),
                .empty(h2c_fifo_empty_ch3),
                .rd_en(h2c_fifo_rd_en_ch3),
                .rd_data(h2c_fifo_rdata_ch3),
                .rd_valid()
            );
        end else begin : gen_no_ach3_fifo
            assign h2c_fifo_full_ch3  = 1'b0;
            assign h2c_fifo_count_ch3 = 8'd0;
            assign h2c_fifo_empty_ch3 = 1'b1;
            assign h2c_fifo_rdata_ch3 = 32'd0;
        end
    endgenerate

    // Audio Playback Rate Generator (48kHz stereo @ 125MHz clk: 125M / 96k subframes = 1302 cycles)
    reg [31:0] aud_tick_cnt;
    reg        aud_sample_tick;
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            aud_tick_cnt    <= 32'd0;
            aud_sample_tick <= 1'b0;
        end else begin
            if (aud_tick_cnt >= 32'd1301) begin
                aud_tick_cnt    <= 32'd0;
                aud_sample_tick <= 1'b1;
            end else begin
                aud_tick_cnt    <= aud_tick_cnt + 1'b1;
                aud_sample_tick <= 1'b0;
            end
        end
    end

    reg [NUM_AUDIO_CH-1:1] pacer_sample_pending;
    always @(posedge clk or negedge dma_rst_n) begin
        if (!dma_rst_n) begin
            pacer_sample_pending <= {(NUM_AUDIO_CH-1){1'b0}};
        end else begin
            if (reg_audio_loopback_ctrl[8])  pacer_sample_pending[1] <= 1'b0;
            else if (aud_sample_tick && !h2c_fifo_empty_ch1) pacer_sample_pending[1] <= 1'b1;
            else if (m_axis_audio_tvalid[1] && m_axis_audio_tready[1]) pacer_sample_pending[1] <= 1'b0;

            if (NUM_AUDIO_CH > 2) begin
                if (reg_audio_loopback_ctrl[9])  pacer_sample_pending[2] <= 1'b0;
                else if (aud_sample_tick && !h2c_fifo_empty_ch2) pacer_sample_pending[2] <= 1'b1;
                else if (m_axis_audio_tvalid[2] && m_axis_audio_tready[2]) pacer_sample_pending[2] <= 1'b0;
            end

            if (NUM_AUDIO_CH > 3) begin
                if (reg_audio_loopback_ctrl[10]) pacer_sample_pending[3] <= 1'b0;
                else if (aud_sample_tick && !h2c_fifo_empty_ch3) pacer_sample_pending[3] <= 1'b1;
                else if (m_axis_audio_tvalid[3] && m_axis_audio_tready[3]) pacer_sample_pending[3] <= 1'b0;
            end
        end
    end

    assign m_axis_audio_tvalid[0] = 1'b0;
    assign m_axis_audio_tlast[0]  = 1'b0;
    assign m_axis_audio_tdata[31:0] = 32'd0;

    assign m_axis_audio_tvalid[1] = reg_audio_loopback_ctrl[0] ?
                                    (pacer_sample_pending[1] && !h2c_fifo_empty_ch1) :
                                    (!h2c_fifo_empty_ch1);
    assign m_axis_audio_tlast[1]  = 1'b0;
    assign m_axis_audio_tdata[63:32] = h2c_fifo_rdata_ch1;
    assign h2c_fifo_rd_en_ch1     = m_axis_audio_tvalid[1] && m_axis_audio_tready[1];

    generate
        if (NUM_AUDIO_CH > 2) begin : gen_audio_m_axis_ch2
            assign m_axis_audio_tvalid[2] = reg_audio_loopback_ctrl[1] ?
                                            (pacer_sample_pending[2] && !h2c_fifo_empty_ch2) :
                                            (!h2c_fifo_empty_ch2);
            assign m_axis_audio_tlast[2]  = 1'b0;
            assign m_axis_audio_tdata[95:64] = h2c_fifo_rdata_ch2;
            assign h2c_fifo_rd_en_ch2     = m_axis_audio_tvalid[2] && m_axis_audio_tready[2];
        end
        if (NUM_AUDIO_CH > 3) begin : gen_audio_m_axis_ch3
            assign m_axis_audio_tvalid[3] = reg_audio_loopback_ctrl[2] ?
                                            (pacer_sample_pending[3] && !h2c_fifo_empty_ch3) :
                                            (!h2c_fifo_empty_ch3);
            assign m_axis_audio_tlast[3]  = 1'b0;
            assign m_axis_audio_tdata[127:96] = h2c_fifo_rdata_ch3;
            assign h2c_fifo_rd_en_ch3     = m_axis_audio_tvalid[3] && m_axis_audio_tready[3];
        end
    endgenerate

`else
    assign h2c_fifo_full_ch1=0; assign h2c_fifo_empty_ch1=1;
    assign h2c_fifo_count_ch1=0; assign h2c_fifo_rdata_ch1=0; assign h2c_fifo_rd_en_ch1=0;
    assign h2c_fifo_full_ch2=0; assign h2c_fifo_empty_ch2=1;
    assign h2c_fifo_count_ch2=0; assign h2c_fifo_rdata_ch2=0; assign h2c_fifo_rd_en_ch2=0;
    assign h2c_fifo_full_ch3=0; assign h2c_fifo_empty_ch3=1;
    assign h2c_fifo_count_ch3=0; assign h2c_fifo_rdata_ch3=0; assign h2c_fifo_rd_en_ch3=0;
    assign m_axis_audio_tvalid=0; assign m_axis_audio_tlast=0; assign m_axis_audio_tdata=0;
`endif

    // 9. Multi-Channel AES3 Audio Stream Engines
    // qpcie_csr_reg_space already transports ordered configuration snapshots
    // to clk and coherent telemetry back to pl_clk0. Do not cross these
    // outputs again using the PS clock: they are already in the PCIe domain.
    wire [31:0] audio0_ctrl = adev0_ctrl_w;
    wire [63:0] audio0_buffer_addr = adev0_ring0_base_w;
    wire [31:0] audio0_buffer_size = adev0_buffer_bytes_w;
    wire [31:0] audio0_period_size = adev0_period_bytes_w;
    assign out_audio_capture_control = audio0_ctrl;
    wire audio0_start = audio0_ctrl[0];

    audio_stream_engine #(
        .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH),
        .PCIE_DATA_WIDTH(128)
    ) u_audio_stream_engine_ch0 (
        .clk(clk),
        .rst_n(dma_rst_n),
        .audio_start(audio0_start),
        .aes3_sync_disable(audio0_ctrl[4] || audio0_ctrl[5]),
        .host_buffer_addr(audio0_buffer_addr),
        .buffer_size_bytes(audio0_buffer_size),
        .period_size_bytes(audio0_period_size),
        .cur_write_ptr(reg_audio_dma_ptr),
        .global_timestamp(global_timestamp),
        .s_axis_audio_tdata(s_axis_audio_tdata[31:0]),
        .s_axis_audio_tvalid(s_axis_audio_tvalid[0]),
        .s_axis_audio_tlast(s_axis_audio_tlast[0]),
        .s_axis_audio_tready(s_axis_audio_tready[0]),
        .c2h_req_valid(a_c2h_req_valid[0]),
        .c2h_req_addr(a_c2h_req_addr[63:0]),
        .c2h_req_dw_len(a_c2h_req_dw_len[10:0]),
        .c2h_req_data(a_c2h_req_data[127:0]),
        .c2h_req_last(a_c2h_req_last[0]),
        .c2h_req_ack(a_c2h_req_ack[0]),
        .audio_busy(a_busy[0]),
        .audio_block_done(a_done[0]),
        .audio_xrun(a_xrun[0]),
        .audio_pts(a_pts[0])
    );

`ifndef SC7F0_C2H_ONLY
    audio_stream_engine #(
        .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH),
        .PCIE_DATA_WIDTH(128)
    ) u_audio_stream_engine_ch1 (
        .clk(clk),
        .rst_n(dma_rst_n),
        .audio_start(reg_dma_ctrl[3]),
        .aes3_sync_disable(reg_audio_loopback_ctrl[5]),
        .host_buffer_addr(reg_audio_dma_addr_ch1),
        .buffer_size_bytes({16'd0, reg_audio_dma_cfg_ch1[15:0]}),
        .period_size_bytes({16'd0, reg_audio_dma_cfg_ch1[31:16]}),
        .cur_write_ptr(reg_audio_dma_ptr_ch1),
        .global_timestamp(global_timestamp),
        .s_axis_audio_tdata(s_axis_audio_tdata[63:32]),
        .s_axis_audio_tvalid(s_axis_audio_tvalid[1]),
        .s_axis_audio_tlast(s_axis_audio_tlast[1]),
        .s_axis_audio_tready(s_axis_audio_tready[1]),
        .c2h_req_valid(a_c2h_req_valid[1]),
        .c2h_req_addr(a_c2h_req_addr[(1*64)+:64]),
        .c2h_req_dw_len(a_c2h_req_dw_len[(1*11)+:11]),
        .c2h_req_data(a_c2h_req_data[(1*128)+:128]),
        .c2h_req_last(a_c2h_req_last[1]),
        .c2h_req_ack(a_c2h_req_ack[1]),
        .audio_busy(a_busy[1]),
        .audio_block_done(a_done[1]),
        .audio_xrun(a_xrun[1]),
        .audio_pts(a_pts[1])
    );

    generate
        if (NUM_AUDIO_CH > 2) begin : gen_ach2_engine
            audio_stream_engine #(
                .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH),
                .PCIE_DATA_WIDTH(128)
            ) u_audio_stream_engine_ch2 (
                .clk(clk),
                .rst_n(dma_rst_n),
                .audio_start(reg_dma_ctrl[4]),
                .aes3_sync_disable(reg_audio_loopback_ctrl[6]),
                .host_buffer_addr(reg_audio_dma_addr_ch2),
                .buffer_size_bytes({16'd0, reg_audio_dma_cfg_ch2[15:0]}),
                .period_size_bytes({16'd0, reg_audio_dma_cfg_ch2[31:16]}),
                .cur_write_ptr(reg_audio_dma_ptr_ch2),
                .global_timestamp(global_timestamp),
                .s_axis_audio_tdata(s_axis_audio_tdata[95:64]),
                .s_axis_audio_tvalid(s_axis_audio_tvalid[2]),
                .s_axis_audio_tlast(s_axis_audio_tlast[2]),
                .s_axis_audio_tready(s_axis_audio_tready[2]),
                .c2h_req_valid(a_c2h_req_valid[2]),
                .c2h_req_addr(a_c2h_req_addr[(2*64)+:64]),
                .c2h_req_dw_len(a_c2h_req_dw_len[(2*11)+:11]),
                .c2h_req_data(a_c2h_req_data[(2*128)+:128]),
                .c2h_req_last(a_c2h_req_last[2]),
                .c2h_req_ack(a_c2h_req_ack[2]),
                .audio_busy(a_busy[2]),
                .audio_block_done(a_done[2]),
                .audio_xrun(a_xrun[2]),
                .audio_pts(a_pts[2])
            );
        end else begin : gen_no_ach2_engine
            assign reg_audio_dma_ptr_ch2 = 32'd0;
        end

        if (NUM_AUDIO_CH > 3) begin : gen_ach3_engine
            audio_stream_engine #(
                .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH),
                .PCIE_DATA_WIDTH(128)
            ) u_audio_stream_engine_ch3 (
                .clk(clk),
                .rst_n(dma_rst_n),
                .audio_start(reg_dma_ctrl[5]),
                .aes3_sync_disable(reg_audio_loopback_ctrl[7]),
                .host_buffer_addr(reg_audio_dma_addr_ch3),
                .buffer_size_bytes({16'd0, reg_audio_dma_cfg_ch3[15:0]}),
                .period_size_bytes({16'd0, reg_audio_dma_cfg_ch3[31:16]}),
                .cur_write_ptr(reg_audio_dma_ptr_ch3),
                .global_timestamp(global_timestamp),
                .s_axis_audio_tdata(s_axis_audio_tdata[127:96]),
                .s_axis_audio_tvalid(s_axis_audio_tvalid[3]),
                .s_axis_audio_tlast(s_axis_audio_tlast[3]),
                .s_axis_audio_tready(s_axis_audio_tready[3]),
                .c2h_req_valid(a_c2h_req_valid[3]),
                .c2h_req_addr(a_c2h_req_addr[(3*64)+:64]),
                .c2h_req_dw_len(a_c2h_req_dw_len[(3*11)+:11]),
                .c2h_req_data(a_c2h_req_data[(3*128)+:128]),
                .c2h_req_last(a_c2h_req_last[3]),
                .c2h_req_ack(a_c2h_req_ack[3]),
                .audio_busy(a_busy[3]),
                .audio_block_done(a_done[3]),
                .audio_xrun(a_xrun[3]),
                .audio_pts(a_pts[3])
            );
        end else begin : gen_no_ach3_engine
            assign reg_audio_dma_ptr_ch3 = 32'd0;
        end
    endgenerate

`else
    assign a_c2h_req_valid[1]=0; assign a_c2h_req_addr[64+:64]=0;
    assign a_c2h_req_dw_len[11+:11]=0; assign a_c2h_req_data[128+:128]=0;
    assign a_c2h_req_last[1]=0; assign a_busy[1]=0; assign a_done[1]=0;
    assign a_xrun[1]=0; assign a_pts[1]=0; assign reg_audio_dma_ptr_ch1=0;
    assign s_axis_audio_tready[1]=1;
    assign a_c2h_req_valid[2]=0; assign a_c2h_req_addr[128+:64]=0;
    assign a_c2h_req_dw_len[22+:11]=0; assign a_c2h_req_data[256+:128]=0;
    assign a_c2h_req_last[2]=0; assign a_busy[2]=0; assign a_done[2]=0;
    assign a_xrun[2]=0; assign a_pts[2]=0; assign reg_audio_dma_ptr_ch2=0;
    assign s_axis_audio_tready[2]=1;
    assign a_c2h_req_valid[3]=0; assign a_c2h_req_addr[192+:64]=0;
    assign a_c2h_req_dw_len[33+:11]=0; assign a_c2h_req_data[384+:128]=0;
    assign a_c2h_req_last[3]=0; assign a_busy[3]=0; assign a_done[3]=0;
    assign a_xrun[3]=0; assign a_pts[3]=0; assign reg_audio_dma_ptr_ch3=0;
    assign s_axis_audio_tready[3]=1;
`endif

    wire [3:0] v_done_ch = {
        (NUM_VIDEO_CH >= 4 ? v_done[3] : 1'b0),
        (NUM_VIDEO_CH >= 3 ? v_done[2] : 1'b0),
        (NUM_VIDEO_CH >= 2 ? (v_done[1] | packet_done_irq) : 1'b0),
        (v_done[0] | sg_c2h_done_irq)
    };
    wire [3:1] h2c_done_ch = {
        (NUM_VIDEO_CH >= 4 && sg_h2c_done_irq && (sg_loopback_channel == 2'd3)),
        (NUM_VIDEO_CH >= 3 && sg_h2c_done_irq && (sg_loopback_channel == 2'd2)),
        (sg_h2c_done_irq && (sg_loopback_channel == 2'd1 || sg_loopback_channel == 2'd0))
    };
    wire [3:0] a_done_irq_vec = {
        (NUM_AUDIO_CH >= 4 ? a_done[3] : 1'b0),
        (NUM_AUDIO_CH >= 3 ? a_done[2] : 1'b0),
        (NUM_AUDIO_CH >= 2 ? a_done[1] : 1'b0),
        a_done[0]
    };
    wire [3:0] a_xrun_ch_vec = {
        (NUM_AUDIO_CH >= 4 ? a_xrun[3] : 1'b0),
        (NUM_AUDIO_CH >= 3 ? a_xrun[2] : 1'b0),
        (NUM_AUDIO_CH >= 2 ? a_xrun[1] : 1'b0),
        (a_xrun[0] | adev0_xrun_inject_w)
    };

    // 10. Interrupt Controller
    interrupt_ctrl u_interrupt_ctrl (
        .clk(clk),
        .rst_n(dma_rst_n),
        .reg_irq_ctrl(reg_irq_ctrl),
        .reg_irq_status_w1c(reg_irq_status_w1c),
        .reg_irq_status(reg_irq_status),
        .irq_top_status(irq_top_status_w),
        .irq_top_status_w1c(irq_top_status_w1c_w),
        .vch0_irq_status(vch0_irq_status_w),
        .vch0_irq_status_w1c(vch0_irq_status_w1c_w),
        .vch0_irq_en(vch0_irq_en_w),
        .vch1_irq_status(vch1_irq_status_w),
        .vch1_irq_status_w1c(vch1_irq_status_w1c_w),
        .vch1_irq_en(vch1_irq_en_w),
        .vch2_irq_status(),
        .vch2_irq_status_w1c(4'd0),
        .vch2_irq_en(1'b0),
        .vch3_irq_status(),
        .vch3_irq_status_w1c(4'd0),
        .vch3_irq_en(1'b0),
        .adev0_irq_status(adev0_irq_status_w),
        .adev0_irq_status_w1c(adev0_irq_status_w1c_w),
        .adev0_irq_en(adev0_ctrl_w[8]),
        .h2c_done(sg_h2c_done_irq),
        .c2h_done(sg_c2h_done_irq),
        .v_done_ch(v_done_ch),
        .h2c_done_ch(h2c_done_ch),
        .a_done_irq(a_done_irq_vec),
        .ovl_wr_done(ovl_wr_irq_pulse),
        .ovl_vblank_irq(ovl_vblank_irq_pulse),
        .v_overflow_ch({3'd0, vch0_overflow_pulse}),
        .v_desc_err_ch(4'd0),
        .v_fifo_err_ch(4'd0),
        .a_xrun_ch(a_xrun_ch_vec),
        .global_err(1'b0),
        .irq_req_valid(irq_req_valid),
        .irq_req_code(irq_req_code),
        .irq_req_ack(irq_req_ack),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

endmodule
