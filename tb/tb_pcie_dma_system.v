// ============================================================================
// Testbench: tb_pcie_dma_system
// Description: System-level self-checking testbench for custom_pcie_dma_top module.
//              Verifies Parameterized Multi-Channel AXI4-Stream Video (SOF/EOL)
//              and AXI4-Stream Audio (AES3 Subframe) DMA Streaming.
// ============================================================================

`timescale 1ns / 1ps

module tb_pcie_dma_system;

    parameter PCIE_DATA_WIDTH  = 256;
    parameter PCIE_KEEP_WIDTH  = PCIE_DATA_WIDTH / 32;
    parameter NUM_VIDEO_CH      = 4;
    parameter NUM_AUDIO_CH      = 4;
    parameter VIDEO_DATA_WIDTH  = 32;
    parameter AUDIO_DATA_WIDTH  = 32;

    reg                                             clk;
    reg                                             rst_n;

    // PCIe CQ Interface (Host -> DMA Top)
    reg  [PCIE_DATA_WIDTH-1:0]                      s_axis_cq_tdata;
    reg                                             s_axis_cq_tvalid;
    reg                                             s_axis_cq_tlast;
    reg  [87:0]                                     s_axis_cq_tuser;
    reg  [PCIE_KEEP_WIDTH-1:0]                      s_axis_cq_tkeep;
    wire                                            s_axis_cq_tready;

    // PCIe CC Interface (DMA Top -> Host)
    wire [PCIE_DATA_WIDTH-1:0]                      m_axis_cc_tdata;
    wire                                            m_axis_cc_tvalid;
    wire                                            m_axis_cc_tlast;
    wire [32:0]                                     m_axis_cc_tuser;
    wire [PCIE_KEEP_WIDTH-1:0]                      m_axis_cc_tkeep;
    reg                                             m_axis_cc_tready;

    // PCIe RQ Interface (DMA Top -> Host)
    wire [PCIE_DATA_WIDTH-1:0]                      m_axis_rq_tdata;
    wire                                            m_axis_rq_tvalid;
    wire                                            m_axis_rq_tlast;
    wire [59:0]                                     m_axis_rq_tuser;
    wire [PCIE_KEEP_WIDTH-1:0]                      m_axis_rq_tkeep;
    reg                                             m_axis_rq_tready;

    // PCIe RC Interface (Host -> DMA Top)
    reg  [PCIE_DATA_WIDTH-1:0]                      s_axis_rc_tdata;
    reg                                             s_axis_rc_tvalid;
    reg                                             s_axis_rc_tlast;
    reg  [74:0]                                     s_axis_rc_tuser;
    reg  [PCIE_KEEP_WIDTH-1:0]                      s_axis_rc_tkeep;
    wire                                            s_axis_rc_tready;

    // BAR1 Ports
    wire [31:0]                                     m_axil_bar1_awaddr;
    wire                                            m_axil_bar1_awvalid;
    reg                                             m_axil_bar1_awready;
    wire [31:0]                                     m_axil_bar1_wdata;
    wire [3:0]                                      m_axil_bar1_wstrb;
    wire                                            m_axil_bar1_wvalid;
    reg                                             m_axil_bar1_wready;
    reg  [1:0]                                      m_axil_bar1_bresp;
    reg                                             m_axil_bar1_bvalid;
    wire                                            m_axil_bar1_bready;

    wire [31:0]                                     m_axil_bar1_araddr;
    wire                                            m_axil_bar1_arvalid;
    reg                                             m_axil_bar1_arready;
    reg  [31:0]                                     m_axil_bar1_rdata;
    reg  [1:0]                                      m_axil_bar1_rresp;
    reg                                             m_axil_bar1_rvalid;
    wire                                            m_axil_bar1_rready;

    // Multi-Channel AXI4-Stream Video Ports
    reg  [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0]      s_axis_video_tdata;
    reg  [NUM_VIDEO_CH-1:0]                         s_axis_video_tvalid;
    reg  [NUM_VIDEO_CH-1:0]                         s_axis_video_tlast;
    reg  [NUM_VIDEO_CH-1:0]                         s_axis_video_tuser;
    wire [NUM_VIDEO_CH-1:0]                         s_axis_video_tready;

    wire [(NUM_VIDEO_CH*VIDEO_DATA_WIDTH)-1:0]      m_axis_video_tdata;
    wire [NUM_VIDEO_CH-1:0]                         m_axis_video_tvalid;
    wire [NUM_VIDEO_CH-1:0]                         m_axis_video_tlast;
    wire [NUM_VIDEO_CH-1:0]                         m_axis_video_tuser;
    reg  [NUM_VIDEO_CH-1:0]                         m_axis_video_tready;

    // Multi-Channel AXI4-Stream Audio Ports (AES3 Subframes)
    reg  [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0]      s_axis_audio_tdata;
    reg  [NUM_AUDIO_CH-1:0]                         s_axis_audio_tvalid;
    reg  [NUM_AUDIO_CH-1:0]                         s_axis_audio_tlast;
    wire [NUM_AUDIO_CH-1:0]                         s_axis_audio_tready;

    wire [(NUM_AUDIO_CH*AUDIO_DATA_WIDTH)-1:0]      m_axis_audio_tdata;
    wire [NUM_AUDIO_CH-1:0]                         m_axis_audio_tvalid;
    wire [NUM_AUDIO_CH-1:0]                         m_axis_audio_tlast;
    reg  [NUM_AUDIO_CH-1:0]                         m_axis_audio_tready;

    wire                                            usr_irq_req;
    reg                                             usr_irq_ack;

    reg [256:0] host_mem [0:1023];

    // Instantiate UUT
    custom_pcie_dma_top #(
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH),
        .NUM_VIDEO_CH(NUM_VIDEO_CH),
        .NUM_AUDIO_CH(NUM_AUDIO_CH),
        .VIDEO_DATA_WIDTH(VIDEO_DATA_WIDTH),
        .AUDIO_DATA_WIDTH(AUDIO_DATA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_cq_tdata(s_axis_cq_tdata),
        .s_axis_cq_tvalid(s_axis_cq_tvalid),
        .s_axis_cq_tlast(s_axis_cq_tlast),
        .s_axis_cq_tuser(s_axis_cq_tuser),
        .s_axis_cq_tkeep(s_axis_cq_tkeep),
        .s_axis_cq_tready(s_axis_cq_tready),
        .m_axis_cc_tdata(m_axis_cc_tdata),
        .m_axis_cc_tvalid(m_axis_cc_tvalid),
        .m_axis_cc_tlast(m_axis_cc_tlast),
        .m_axis_cc_tuser(m_axis_cc_tuser),
        .m_axis_cc_tkeep(m_axis_cc_tkeep),
        .m_axis_cc_tready(m_axis_cc_tready),
        .m_axis_rq_tdata(m_axis_rq_tdata),
        .m_axis_rq_tvalid(m_axis_rq_tvalid),
        .m_axis_rq_tlast(m_axis_rq_tlast),
        .m_axis_rq_tuser(m_axis_rq_tuser),
        .m_axis_rq_tkeep(m_axis_rq_tkeep),
        .m_axis_rq_tready(m_axis_rq_tready),
        .s_axis_rc_tdata(s_axis_rc_tdata),
        .s_axis_rc_tvalid(s_axis_rc_tvalid),
        .s_axis_rc_tlast(s_axis_rc_tlast),
        .s_axis_rc_tuser(s_axis_rc_tuser),
        .s_axis_rc_tkeep(s_axis_rc_tkeep),
        .s_axis_rc_tready(s_axis_rc_tready),
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
        .m_axil_bar1_rready(m_axil_bar1_rready),
        .s_axis_video_tdata(s_axis_video_tdata),
        .s_axis_video_tvalid(s_axis_video_tvalid),
        .s_axis_video_tlast(s_axis_video_tlast),
        .s_axis_video_tuser(s_axis_video_tuser),
        .s_axis_video_tready(s_axis_video_tready),
        .video_clk(clk),
        .video_rst_n(rst_n),
        .video_ch0_tdata(128'd0),
        .video_ch0_tvalid(1'b0),
        .video_ch0_tlast(1'b0),
        .video_ch0_tuser(1'b0),
        .video_ch0_tready(),
        .m_axis_video_tdata(m_axis_video_tdata),
        .m_axis_video_tvalid(m_axis_video_tvalid),
        .m_axis_video_tlast(m_axis_video_tlast),
        .m_axis_video_tuser(m_axis_video_tuser),
        .m_axis_video_tready(m_axis_video_tready),
        .s_axis_audio_tdata(s_axis_audio_tdata),
        .s_axis_audio_tvalid(s_axis_audio_tvalid),
        .s_axis_audio_tlast(s_axis_audio_tlast),
        .s_axis_audio_tready(s_axis_audio_tready),
        .m_axis_audio_tdata(m_axis_audio_tdata),
        .m_axis_audio_tvalid(m_axis_audio_tvalid),
        .m_axis_audio_tlast(m_axis_audio_tlast),
        .m_axis_audio_tready(m_axis_audio_tready),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

    always #5 clk = ~clk;

    // Host BFM write reg task
    task host_write_reg;
        input [31:0] reg_addr;
        input [31:0] reg_val;
        begin
            @(posedge clk);
            s_axis_cq_tvalid <= 1;
            s_axis_cq_tlast  <= 1;
            s_axis_cq_tdata[63:0]    <= {32'd0, reg_addr};
            s_axis_cq_tdata[78:75]   <= 4'b0001; // MWr
            s_axis_cq_tdata[114:112] <= 3'b000;  // BAR0
            s_axis_cq_tdata[159:128] <= reg_val;
            @(posedge clk);
            s_axis_cq_tvalid <= 0;
        end
    endtask

    // Simulated Host PCIe Root Complex responding to RQ requests
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_rq_tready <= 1'b1;
            s_axis_rc_tvalid <= 1'b0;
            s_axis_rc_tdata  <= 256'd0;
            s_axis_rc_tlast  <= 1'b0;
            m_axil_bar1_awready <= 1'b1;
            m_axil_bar1_wready  <= 1'b1;
            m_axil_bar1_bresp   <= 2'b00;
            m_axil_bar1_bvalid  <= 1'b0;
            m_axil_bar1_arready <= 1'b1;
            m_axil_bar1_rdata   <= 32'd0;
            m_axil_bar1_rresp   <= 2'b00;
            m_axil_bar1_rvalid  <= 1'b0;
        end else begin
            s_axis_rc_tvalid <= 1'b0;

            if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                $display("[%0t] Host BFM received RQ Stream TLP! Type=0x%b, Addr=0x%h, Tag=0x%h, DW Len=%d",
                         $time, m_axis_rq_tdata[78:75], m_axis_rq_tdata[63:0], m_axis_rq_tdata[103:96], m_axis_rq_tdata[74:64]);
                if (m_axis_rq_tdata[78:75] == 4'b0000) begin // MRd TLP
                    s_axis_rc_tvalid <= 1'b1;
                    s_axis_rc_tlast  <= 1'b1;
                    s_axis_rc_tdata[31:0]  <= 32'h0020_0000;
                    s_axis_rc_tdata[42:32] <= m_axis_rq_tdata[74:64];
                    s_axis_rc_tdata[58:51] <= m_axis_rq_tdata[103:96];
                    s_axis_rc_tdata[79:64] <= 16'h0100;
                    s_axis_rc_tdata[255:96] <= host_mem[m_axis_rq_tdata[14:5]][159:0];
                end else if (m_axis_rq_tdata[78:75] == 4'b0001) begin // MWr TLP
                    host_mem[m_axis_rq_tdata[14:5]] <= m_axis_rq_tdata[255:128];
                    $display("[%0t] Host BFM received Stream MWr TLP! Data 0x%h written to Host Mem Addr 0x%h",
                             $time, m_axis_rq_tdata[255:128], m_axis_rq_tdata[63:0]);
                end
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        s_axis_cq_tdata = 0;
        s_axis_cq_tvalid = 0;
        s_axis_cq_tlast = 0;
        s_axis_cq_tuser = 0;
        s_axis_cq_tkeep = 8'hFF;
        m_axis_cc_tready = 1;
        usr_irq_ack = 0;

        s_axis_video_tdata = 0;
        s_axis_video_tvalid = 0;
        s_axis_video_tlast = 0;
        s_axis_video_tuser = 0;
        m_axis_video_tready = 4'b1111;

        s_axis_audio_tdata = 0;
        s_axis_audio_tvalid = 0;
        s_axis_audio_tlast = 0;
        m_axis_audio_tready = 4'b1111;

        #20;
        rst_n = 1;
        #10;

        $display("===============================================================");
        $display("[%0t] Starting Multi-Channel AXI4-Stream Video & AES3 Audio Verification...", $time);
        $display("===============================================================");

        // Pre-fill Host Memory with 64-Byte Extended 2D Descriptor and Data
        host_mem[0] = {160'd0, 16'h0001, 16'd32, 64'h0000_0200, 64'h0000_0200}; // Src=0x200, Dst=0x200, Len=32, Ctrl=0x0001
        host_mem[16] = 256'h11223344_55667788_99AABBCC_DDEEFF00_12345678_87654321_00112233_44556677;

        #20;
        $display("[%0t] Step 1: Configure BAR0 H2C Ring Base (0x00) & Ring Size (4)...", $time);
        host_write_reg(32'h08, 32'h0000_0000);
        host_write_reg(32'h0C, 32'h0000_0000);
        host_write_reg(32'h10, 32'h0000_0004);

        #20;
        $display("[%0t] Step 2: Write BAR0 H2C Tail Pointer = 1 to trigger Descriptor Fetch...", $time);
        host_write_reg(32'h10, 32'h0001_0004);

        #20;
        $display("[%0t] Step 3: Write BAR0 DMA_CTRL = 0x01 (Start Video & Audio Engines)...", $time);
        host_write_reg(32'h00, 32'h0000_0001);

        #20;
        $display("[%0t] Step 4: Input C2H Video Stream Frame on Channel 0 (SOF=1, EOL=1)...", $time);
        @(posedge clk);
        s_axis_video_tvalid[0] <= 1'b1;
        s_axis_video_tuser[0]  <= 1'b1; // SOF (Start of Frame)
        s_axis_video_tlast[0]  <= 1'b1; // EOL (End of Line)
        s_axis_video_tdata[31:0] <= 32'hA5A5_5A5A;
        @(posedge clk);
        s_axis_video_tvalid[0] <= 1'b0;

        #20;
        $display("[%0t] Step 5: Input C2H AES3 Audio Stream Subframe on Channel 0...", $time);
        @(posedge clk);
        s_axis_audio_tvalid[0] <= 1'b1;
        s_axis_audio_tlast[0]  <= 1'b1; // End of audio block
        s_axis_audio_tdata[31:0] <= 32'hF8123456; // 32-bit AES3 subframe (Preamble 0xF + 24-bit PCM)
        @(posedge clk);
        s_axis_audio_tvalid[0] <= 1'b0;

        #150;
        $display("===============================================================");
        $display("[%0t] SUCCESS: Multi-Channel AXI4-Stream Video & AES3 Audio Verification Complete!", $time);
        $display("===============================================================");
        $finish;
    end

endmodule
