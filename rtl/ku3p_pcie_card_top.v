// ============================================================================
// Module: ku3p_pcie_card_top
// Target: Xilinx Kintex UltraScale+ (xcku3p-ffva676-2-e)
// Description: Top-level FPGA card wrapper module for standalone bitstream build.
//              Integrates:
//              - Xilinx UltraScale+ PCIe Core (pcie4_uscale_plus_0) Gen3 x4
//              - Custom PCIe DMA Top Controller (BAR0: DMA Regs, BAR1: AXI Master)
//              - AXI4-Lite 1x3 Interconnect Module (axil_interconnect)
//              - Xilinx Video Test Pattern Generator IP (v_tpg_0) at BAR1 Offset 0x0000
//              - AES3 Audio Pattern Generator Module (audio_pattern_gen) at BAR1 Offset 0x0100
//              - Direct Video Streaming: TPG m_axis_video -> DMA s_axis_video (Ch0)
//              - Direct Audio Streaming: AudPatGen m_axis_audio -> DMA s_axis_audio (Ch0)
// ============================================================================

`timescale 1ns / 1ps

module ku3p_pcie_card_top #(
    parameter PCIE_DATA_WIDTH  = 256,
    parameter PCIE_KEEP_WIDTH  = PCIE_DATA_WIDTH / 32,
    parameter NUM_VIDEO_CH     = 4,
    parameter NUM_AUDIO_CH     = 4,
    parameter VIDEO_DATA_WIDTH = 128,
    parameter AUDIO_DATA_WIDTH = 32
)(
    // Physical PCIe Reference Clock & PERST# Reset Pins (Bank 224 / Bank 65)
    input  wire                                             sys_clk_p,
    input  wire                                             sys_clk_n,
    input  wire                                             sys_rst_n,

    // Physical PCIe Transceiver Serial Lanes (Gen3 x4)
    output wire [3:0]                                       pci_exp_txp,
    output wire [3:0]                                       pci_exp_txn,
    input  wire [3:0]                                       pci_exp_rxp,
    input  wire [3:0]                                       pci_exp_rxn,

    // Status LEDs (Bank 65)
    output wire                                             user_led_dma_active,
    output wire                                             user_led_pcie_link_up
);

    // =========================================================================
    // Internal Clocks and Resets
    // =========================================================================
    wire pcie_user_clk;
    wire pcie_user_reset;
    wire pcie_user_rst_n;
    wire pcie_user_lnk_up;
    wire phy_ready;

    assign pcie_user_rst_n       = ~pcie_user_reset;
    assign user_led_pcie_link_up = pcie_user_lnk_up;
    assign user_led_dma_active   = 1'b1;

    // =========================================================================
    // BAR1 AXI4-Lite Master Interconnect Wires
    // Connected to axil_interconnect S00 Interface
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
    // AXI Interconnect Master 0 (M00) Wires -> To Xilinx Video TPG (v_tpg_0)
    // Address Offset: 0x0000 - 0x00FF
    // =========================================================================
    wire [7:0]  tpg_axi_awaddr;
    wire        tpg_axi_awvalid;
    wire        tpg_axi_awready;
    wire [31:0] tpg_axi_wdata;
    wire [3:0]  tpg_axi_wstrb;
    wire        tpg_axi_wvalid;
    wire        tpg_axi_wready;
    wire [1:0]  tpg_axi_bresp;
    wire        tpg_axi_bvalid;
    wire        tpg_axi_bready;
    wire [7:0]  tpg_axi_araddr;
    wire        tpg_axi_arvalid;
    wire        tpg_axi_arready;
    wire [31:0] tpg_axi_rdata;
    wire [1:0]  tpg_axi_rresp;
    wire        tpg_axi_rvalid;
    wire        tpg_axi_rready;

    // =========================================================================
    // AXI Interconnect Master 1 (M01) Wires -> To Audio Pattern Generator
    // Address Offset: 0x0100 - 0x01FF
    // =========================================================================
    wire [7:0]  aud_axi_awaddr;
    wire        aud_axi_awvalid;
    wire        aud_axi_awready;
    wire [31:0] aud_axi_wdata;
    wire [3:0]  aud_axi_wstrb;
    wire        aud_axi_wvalid;
    wire        aud_axi_wready;
    wire [1:0]  aud_axi_bresp;
    wire        aud_axi_bvalid;
    wire        aud_axi_bready;
    wire [7:0]  aud_axi_araddr;
    wire        aud_axi_arvalid;
    wire        aud_axi_arready;
    wire [31:0] aud_axi_rdata;
    wire [1:0]  aud_axi_rresp;
    wire        aud_axi_rvalid;
    wire        aud_axi_rready;

    // =========================================================================
    // AXI Interconnect Master 2 (M02) Wires -> To User Register / Peripheral Space
    // Address Offset: 0x0200 - 0xFFFF
    // =========================================================================
    wire [31:0] bar1_reg_awaddr;
    wire        bar1_reg_awvalid;
    wire        bar1_reg_awready;
    wire [31:0] bar1_reg_wdata;
    wire [3:0]  bar1_reg_wstrb;
    wire        bar1_reg_wvalid;
    wire        bar1_reg_wready;
    wire [1:0]  bar1_reg_bresp;
    wire        bar1_reg_bvalid;
    wire        bar1_reg_bready;
    wire [31:0] bar1_reg_araddr;
    wire        bar1_reg_arvalid;
    wire        bar1_reg_arready;
    wire [31:0] bar1_reg_rdata;
    wire [1:0]  bar1_reg_rresp;
    wire        bar1_reg_rvalid;
    wire        bar1_reg_rready;

    // Internal BAR1 User Register Stub
    reg [31:0] user_reg_mem [0:63];
    reg        user_reg_awready_r;
    reg        user_reg_wready_r;
    reg        user_reg_bvalid_r;
    reg        user_reg_arready_r;
    reg        user_reg_rvalid_r;
    reg [31:0] user_reg_rdata_r;

    assign bar1_reg_awready = user_reg_awready_r;
    assign bar1_reg_wready  = user_reg_wready_r;
    assign bar1_reg_bvalid  = user_reg_bvalid_r;
    assign bar1_reg_bresp   = 2'b00; // OKAY
    assign bar1_reg_arready = user_reg_arready_r;
    assign bar1_reg_rvalid  = user_reg_rvalid_r;
    assign bar1_reg_rdata   = user_reg_rdata_r;
    assign bar1_reg_rresp   = 2'b00; // OKAY

    always @(posedge pcie_user_clk or negedge pcie_user_rst_n) begin
        if (!pcie_user_rst_n) begin
            user_reg_awready_r <= 1'b0;
            user_reg_wready_r  <= 1'b0;
            user_reg_bvalid_r  <= 1'b0;
            user_reg_arready_r <= 1'b0;
            user_reg_rvalid_r  <= 1'b0;
            user_reg_rdata_r   <= 32'd0;
        end else begin
            // Write
            if (bar1_reg_awvalid && bar1_reg_wvalid && !user_reg_bvalid_r) begin
                user_reg_awready_r <= 1'b1;
                user_reg_wready_r  <= 1'b1;
                user_reg_bvalid_r  <= 1'b1;
                user_reg_mem[bar1_reg_awaddr[7:2]] <= bar1_reg_wdata;
            end else begin
                user_reg_awready_r <= 1'b0;
                user_reg_wready_r  <= 1'b0;
                if (bar1_reg_bready) user_reg_bvalid_r <= 1'b0;
            end

            // Read
            if (bar1_reg_arvalid && !user_reg_rvalid_r) begin
                user_reg_arready_r <= 1'b1;
                user_reg_rvalid_r  <= 1'b1;
                user_reg_rdata_r   <= user_reg_mem[bar1_reg_araddr[7:2]];
            end else begin
                user_reg_arready_r <= 1'b0;
                if (bar1_reg_rready) user_reg_rvalid_r <= 1'b0;
            end
        end
    end

    // Instantiate AXI4-Lite 1x3 Interconnect (BAR1 Master -> Video TPG, Audio Pat Gen, User Regs)
    axil_interconnect #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32)
    ) u_axil_interconnect (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),

        // Slave Interface (From PCIe DMA Top BAR1 Master)
        .s_axil_awaddr(bar1_m_awaddr),
        .s_axil_awvalid(bar1_m_awvalid),
        .s_axil_awready(bar1_m_awready),
        .s_axil_wdata(bar1_m_wdata),
        .s_axil_wstrb(bar1_m_wstrb),
        .s_axil_wvalid(bar1_m_wvalid),
        .s_axil_wready(bar1_m_wready),
        .s_axil_bresp(bar1_m_bresp),
        .s_axil_bvalid(bar1_m_bvalid),
        .s_axil_bready(bar1_m_bready),
        .s_axil_araddr(bar1_m_araddr),
        .s_axil_arvalid(bar1_m_arvalid),
        .s_axil_arready(bar1_m_arready),
        .s_axil_rdata(bar1_m_rdata),
        .s_axil_rresp(bar1_m_rresp),
        .s_axil_rvalid(bar1_m_rvalid),
        .s_axil_rready(bar1_m_rready),

        // Master 0 (M00) -> Video TPG IP s_axi_CTRL (Offset 0x0000 - 0x00FF)
        .m00_axil_awaddr(tpg_axi_awaddr),
        .m00_axil_awvalid(tpg_axi_awvalid),
        .m00_axil_awready(tpg_axi_awready),
        .m00_axil_wdata(tpg_axi_wdata),
        .m00_axil_wstrb(tpg_axi_wstrb),
        .m00_axil_wvalid(tpg_axi_wvalid),
        .m00_axil_wready(tpg_axi_wready),
        .m00_axil_bresp(tpg_axi_bresp),
        .m00_axil_bvalid(tpg_axi_bvalid),
        .m00_axil_bready(tpg_axi_bready),
        .m00_axil_araddr(tpg_axi_araddr),
        .m00_axil_arvalid(tpg_axi_arvalid),
        .m00_axil_arready(tpg_axi_arready),
        .m00_axil_rdata(tpg_axi_rdata),
        .m00_axil_rresp(tpg_axi_rresp),
        .m00_axil_rvalid(tpg_axi_rvalid),
        .m00_axil_rready(tpg_axi_rready),

        // Master 1 (M01) -> Audio Pattern Generator (Offset 0x0100 - 0x01FF)
        .m01_axil_awaddr(aud_axi_awaddr),
        .m01_axil_awvalid(aud_axi_awvalid),
        .m01_axil_awready(aud_axi_awready),
        .m01_axil_wdata(aud_axi_wdata),
        .m01_axil_wstrb(aud_axi_wstrb),
        .m01_axil_wvalid(aud_axi_wvalid),
        .m01_axil_wready(aud_axi_wready),
        .m01_axil_bresp(aud_axi_bresp),
        .m01_axil_bvalid(aud_axi_bvalid),
        .m01_axil_bready(aud_axi_bready),
        .m01_axil_araddr(aud_axi_araddr),
        .m01_axil_arvalid(aud_axi_arvalid),
        .m01_axil_arready(aud_axi_arready),
        .m01_axil_rdata(aud_axi_rdata),
        .m01_axil_rresp(aud_axi_rresp),
        .m01_axil_rvalid(aud_axi_rvalid),
        .m01_axil_rready(aud_axi_rready),

        // Master 2 (M02) -> User Register Space (Offset 0x0200 - 0xFFFF)
        .m02_axil_awaddr(bar1_reg_awaddr),
        .m02_axil_awvalid(bar1_reg_awvalid),
        .m02_axil_awready(bar1_reg_awready),
        .m02_axil_wdata(bar1_reg_wdata),
        .m02_axil_wstrb(bar1_reg_wstrb),
        .m02_axil_wvalid(bar1_reg_wvalid),
        .m02_axil_wready(bar1_reg_wready),
        .m02_axil_bresp(bar1_reg_bresp),
        .m02_axil_bvalid(bar1_reg_bvalid),
        .m02_axil_bready(bar1_reg_bready),
        .m02_axil_araddr(bar1_reg_araddr),
        .m02_axil_arvalid(bar1_reg_arvalid),
        .m02_axil_arready(bar1_reg_arready),
        .m02_axil_rdata(bar1_reg_rdata),
        .m02_axil_rresp(bar1_reg_rresp),
        .m02_axil_rvalid(bar1_reg_rvalid),
        .m02_axil_rready(bar1_reg_rready)
    );

    // =========================================================================
    // Xilinx Video Test Pattern Generator IP (v_tpg_0) Wires & Instantiation
    // Configuration: 4 PPC (Samples per Clock = 4) @ 4K60, 96-bit AXI4-Stream
    // =========================================================================
    wire [95:0] tpg_axis_tdata;  // 4 pixels * 24-bit = 96-bit
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

    // =========================================================================
    // AES3 Audio Pattern Generator (audio_pattern_gen) Wires & Instantiation
    // =========================================================================
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

        // AXI4-Lite Control Slave (Mapped to BAR1 Offset 0x0100)
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

    // =========================================================================
    // Multi-Channel AXI4-Stream Video Multiplexing:
    // Channel 0: Connected directly to Xilinx Video TPG IP (m_axis_video)
    // Channels 1-3: Connected in internal loopback mode (H2C -> C2H)
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

    // Channel 0: Video TPG (4 PPC) -> PCIe DMA C2H Stream Input (128-bit = 4 Pixels * 32-bit AYUV)
    assign s_video_tdata[127:0] = {
        8'hFF, tpg_axis_tdata[95:72], // Pixel 3
        8'hFF, tpg_axis_tdata[71:48], // Pixel 2
        8'hFF, tpg_axis_tdata[47:24], // Pixel 1
        8'hFF, tpg_axis_tdata[23:0]   // Pixel 0
    };
    assign s_video_tvalid[0]   = tpg_axis_tvalid;
    assign s_video_tlast[0]    = tpg_axis_tlast;  // EOL
    assign s_video_tuser[0]    = tpg_axis_tuser[0]; // SOF
    assign tpg_axis_tready     = s_video_tready[0];

    // Channels 1..3: Internal loopback for testing
    assign s_video_tdata[511:128] = m_video_tdata[511:128];
    assign s_video_tvalid[3:1]    = m_video_tvalid[3:1];
    assign s_video_tlast[3:1]     = m_video_tlast[3:1];
    assign s_video_tuser[3:1]     = m_video_tuser[3:1];
    assign m_video_tready[3:1]    = s_video_tready[3:1];
    assign m_video_tready[0]      = 1'b1; // Channel 0 H2C sink ready

    // =========================================================================
    // Multi-Channel AXI4-Stream Audio Multiplexing:
    // Channel 0: Connected directly to AES3 Audio Pattern Generator
    // Channels 1-3: Connected in internal loopback mode (H2C -> C2H)
    // =========================================================================
    wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0] s_audio_tdata;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tvalid;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tlast;
    wire [NUM_AUDIO_CH-1:0]                    s_audio_tready;

    wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0] m_audio_tdata;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tvalid;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tlast;
    wire [NUM_AUDIO_CH-1:0]                    m_audio_tready;

    // Channel 0: Audio Pattern Generator -> PCIe DMA C2H Audio Input
    assign s_audio_tdata[31:0] = aud_pat_axis_tdata;
    assign s_audio_tvalid[0]   = aud_pat_axis_tvalid;
    assign s_audio_tlast[0]    = aud_pat_axis_tlast;
    assign aud_pat_axis_tready = s_audio_tready[0];

    // Channels 1..3: Internal loopback for testing
    assign s_audio_tdata[127:32] = m_audio_tdata[127:32];
    assign s_audio_tvalid[3:1]   = m_audio_tvalid[3:1];
    assign s_audio_tlast[3:1]    = m_audio_tlast[3:1];
    assign m_audio_tready[3:1]   = s_audio_tready[3:1];
    assign m_audio_tready[0]     = 1'b1; // Channel 0 H2C sink ready

    // =========================================================================
    // PCIe AXI-Stream CQ / CC / RQ / RC Wires
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
    wire [15:0] cfg_function_status;
    wire [5:0]  cfg_ltssm_state;
    wire [7:0]  cfg_bus_number;

    wire        cfg_interrupt_sent;
    wire [3:0]  cfg_interrupt_msi_enable;
    wire        cfg_interrupt_msi_sent;
    wire        cfg_interrupt_msi_fail;

    wire usr_irq_req, usr_irq_ack;

    // Differential Reference Clock Input Buffer
    wire sys_clk;
    wire sys_clk_gt;
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_ibufds_gte4 (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .CEB(1'b0),
        .O(sys_clk_gt),
        .ODIV2(sys_clk)
    );

    // Instantiate UltraScale+ PCIe IP Core (pcie4_uscale_plus_0)
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

        .m_axis_cq_tdata                           (m_axis_cq_tdata),
        .m_axis_cq_tvalid                          (m_axis_cq_tvalid),
        .m_axis_cq_tlast                           (m_axis_cq_tlast),
        .m_axis_cq_tuser                           (m_axis_cq_tuser),
        .m_axis_cq_tkeep                           (m_axis_cq_tkeep),
        .m_axis_cq_tready                          (m_axis_cq_tready),

        .s_axis_cc_tdata                           (s_axis_cc_tdata),
        .s_axis_cc_tvalid                          (s_axis_cc_tvalid),
        .s_axis_cc_tlast                           (s_axis_cc_tlast),
        .s_axis_cc_tuser                           (s_axis_cc_tuser),
        .s_axis_cc_tkeep                           (s_axis_cc_tkeep),
        .s_axis_cc_tready                          (s_axis_cc_tready_vec),

        .s_axis_rq_tdata                           (s_axis_rq_tdata),
        .s_axis_rq_tvalid                          (s_axis_rq_tvalid),
        .s_axis_rq_tlast                           (s_axis_rq_tlast),
        .s_axis_rq_tuser                           (s_axis_rq_tuser),
        .s_axis_rq_tkeep                           (s_axis_rq_tkeep),
        .s_axis_rq_tready                          (s_axis_rq_tready_vec),

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
        .cfg_function_status                       (cfg_function_status),
        .cfg_function_power_state                  (),
        .cfg_vf_status                             (),
        .cfg_vf_power_state                        (),
        .cfg_link_power_state                      (),

        .cfg_mgmt_addr                             (10'b0),
        .cfg_mgmt_function_number                  (8'b0),
        .cfg_mgmt_write                            (1'b0),
        .cfg_mgmt_write_data                       (32'b0),
        .cfg_mgmt_byte_enable                      (4'b0),
        .cfg_mgmt_read                             (1'b0),
        .cfg_mgmt_read_data                        (),
        .cfg_mgmt_read_write_done                  (),
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

        .cfg_interrupt_int                         (4'b0),
        .cfg_interrupt_pending                     (4'b0),
        .cfg_interrupt_sent                        (cfg_interrupt_sent),

        .cfg_interrupt_msi_enable                  (cfg_interrupt_msi_enable),
        .cfg_interrupt_msi_mmenable                (),
        .cfg_interrupt_msi_mask_update             (),
        .cfg_interrupt_msi_data                    (),
        .cfg_interrupt_msi_select                  (2'b0),
        .cfg_interrupt_msi_int                     (32'b0),
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

    // Instantiate Custom PCIe DMA Controller Top Module
    custom_pcie_dma_top #(
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH),
        .NUM_VIDEO_CH(NUM_VIDEO_CH),
        .NUM_AUDIO_CH(NUM_AUDIO_CH),
        .VIDEO_DATA_WIDTH(VIDEO_DATA_WIDTH),
        .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH)
    ) u_dma_top (
        .clk(pcie_user_clk),
        .rst_n(pcie_user_rst_n),

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

        // BAR1 AXI4-Lite Master Interface -> Connected to axil_interconnect S00
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

        // Multi-Channel Video Streams (Ch0: TPG IP, Ch1-3: Loopback)
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

        // Multi-Channel Audio Streams (Ch0: AudPatGen, Ch1-3: Loopback)
        .s_axis_audio_tdata(s_audio_tdata),
        .s_axis_audio_tvalid(s_audio_tvalid),
        .s_axis_audio_tlast(s_audio_tlast),
        .s_axis_audio_tready(s_audio_tready),

        .m_axis_audio_tdata(m_audio_tdata),
        .m_axis_audio_tvalid(m_audio_tvalid),
        .m_axis_audio_tlast(m_audio_tlast),
        .m_axis_audio_tready(m_audio_tready),

        // Interrupts
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

endmodule
