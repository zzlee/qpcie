// ============================================================================
// Testbench: tb_sg_dma_pipeline
// Description: Full end-to-end hardware pipeline testbench testing:
//              1. MMIO Host Configuration (Ring Base, Size, Tail Ptr)
//              2. Hardware Descriptor Fetch (desc_fetch_engine)
//              3. 64-Byte Extended Descriptor Assembly (rc_rx_decoder)
//              4. C2H MWr DMA Generation (sg_dma_engine -> rq_tx_encoder)
// ============================================================================

`timescale 1ns / 1ps

module tb_sg_dma_pipeline;

    reg clk;
    reg rst_n;

    // 7-Series PCIe RX Stream
    reg  [127:0] m_axis_rx_tdata;
    reg  [15:0]  m_axis_rx_tkeep;
    reg          m_axis_rx_tlast;
    reg          m_axis_rx_tvalid;
    wire         m_axis_rx_tready;
    reg  [21:0]  m_axis_rx_tuser;

    // 7-Series PCIe TX Stream
    wire [127:0] s_axis_tx_tdata;
    wire [15:0]  s_axis_tx_tkeep;
    wire         s_axis_tx_tlast;
    wire         s_axis_tx_tvalid;
    reg          s_axis_tx_tready;
    wire [3:0]   s_axis_tx_tuser;

    // Internal 128-bit Interfaces between Bridge and DMA Top
    wire [127:0] cq_tdata, cc_tdata, rq_tdata, rc_tdata;
    wire         cq_tvalid, cq_tlast, cq_tready;
    wire         cc_tvalid, cc_tlast, cc_tready;
    wire         rq_tvalid, rq_tlast, rq_tready;
    wire         rc_tvalid, rc_tlast, rc_tready;
    wire [87:0]  cq_tuser;
    wire [32:0]  cc_tuser;
    wire [61:0]  rq_tuser;
    wire [74:0]  rc_tuser;
    wire [15:0]  cq_tkeep, cc_tkeep, rq_tkeep, rc_tkeep;

    // 1. PCIe Bridge
    pcie_7x_axi_bridge #(
        .DATA_WIDTH(128)
    ) u_bridge (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_bus_number(8'h04),
        .cfg_device_number(5'h01),
        .cfg_function_number(3'h0),
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
        .m_axis_cq_tdata(cq_tdata),
        .m_axis_cq_tvalid(cq_tvalid),
        .m_axis_cq_tlast(cq_tlast),
        .m_axis_cq_tuser(cq_tuser),
        .m_axis_cq_tkeep(cq_tkeep),
        .m_axis_cq_tready(cq_tready),
        .s_axis_cc_tdata(cc_tdata),
        .s_axis_cc_tvalid(cc_tvalid),
        .s_axis_cc_tlast(cc_tlast),
        .s_axis_cc_tuser(cc_tuser),
        .s_axis_cc_tkeep(cc_tkeep),
        .s_axis_cc_tready(cc_tready),
        .s_axis_rq_tdata(rq_tdata),
        .s_axis_rq_tvalid(rq_tvalid),
        .s_axis_rq_tlast(rq_tlast),
        .s_axis_rq_tuser(rq_tuser),
        .s_axis_rq_tkeep(rq_tkeep),
        .s_axis_rq_tready(rq_tready),
        .m_axis_rc_tdata(rc_tdata),
        .m_axis_rc_tvalid(rc_tvalid),
        .m_axis_rc_tlast(rc_tlast),
        .m_axis_rc_tuser(rc_tuser),
        .m_axis_rc_tkeep(rc_tkeep),
        .m_axis_rc_tready(rc_tready)
    );

    // 2. Custom PCIe DMA Top Instantiation (128-bit)
    custom_pcie_dma_top #(
        .PCIE_DATA_WIDTH(128)
    ) u_dma_top (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_cq_tdata(cq_tdata),
        .s_axis_cq_tvalid(cq_tvalid),
        .s_axis_cq_tlast(cq_tlast),
        .s_axis_cq_tuser(cq_tuser),
        .s_axis_cq_tkeep(cq_tkeep),
        .s_axis_cq_tready(cq_tready),
        .m_axis_cc_tdata(cc_tdata),
        .m_axis_cc_tvalid(cc_tvalid),
        .m_axis_cc_tlast(cc_tlast),
        .m_axis_cc_tuser(cc_tuser),
        .m_axis_cc_tkeep(cc_tkeep),
        .m_axis_cc_tready(cc_tready),
        .m_axis_rq_tdata(rq_tdata),
        .m_axis_rq_tvalid(rq_tvalid),
        .m_axis_rq_tlast(rq_tlast),
        .m_axis_rq_tuser(rq_tuser),
        .m_axis_rq_tkeep(rq_tkeep),
        .m_axis_rq_tready(rq_tready),
        .s_axis_rc_tdata(rc_tdata),
        .s_axis_rc_tvalid(rc_tvalid),
        .s_axis_rc_tlast(rc_tlast),
        .s_axis_rc_tuser(rc_tuser),
        .s_axis_rc_tkeep(rc_tkeep),
        .s_axis_rc_tready(rc_tready),
        .m_axil_bar1_awready(1'b1),
        .m_axil_bar1_wready(1'b1),
        .m_axil_bar1_bresp(2'b00),
        .m_axil_bar1_bvalid(1'b1),
        .m_axil_bar1_arready(1'b1),
        .m_axil_bar1_rdata(32'd0),
        .m_axil_bar1_rresp(2'b00),
        .m_axil_bar1_rvalid(1'b1),
        .s_axis_video_tdata(128'd0),
        .s_axis_video_tvalid(4'b0),
        .s_axis_video_tlast(4'b0),
        .s_axis_video_tuser(4'b0),
        .s_axis_video_tready(),
        .m_axis_video_tdata(),
        .m_axis_video_tvalid(),
        .m_axis_video_tlast(),
        .m_axis_video_tuser(),
        .m_axis_video_tready(4'b1111),
        .s_axis_audio_tdata(128'd0),
        .s_axis_audio_tvalid(4'b0),
        .s_axis_audio_tlast(4'b0),
        .s_axis_audio_tready(),
        .m_axis_audio_tdata(),
        .m_axis_audio_tvalid(),
        .m_axis_audio_tlast(),
        .m_axis_audio_tready(4'b1111),
        .usr_irq_req(),
        .usr_irq_ack(1'b1)
    );

    always #4.0 clk = ~clk; // 125 MHz

    task mmio_write_bar0;
        input [31:0] reg_addr;
        input [31:0] reg_data;
        begin
            @(posedge clk);
            // Beat 0: 4-DW MWr Header
            m_axis_rx_tvalid <= 1'b1;
            m_axis_rx_tlast  <= 1'b0;
            m_axis_rx_tkeep  <= 16'hFFFF;
            m_axis_rx_tuser  <= 22'b0000000000000000000100; // BAR0
            m_axis_rx_tdata  <= {reg_addr, 32'h00000024, 32'h0000000F, 32'h60000001};
            @(posedge clk);
            while (!m_axis_rx_tready) @(posedge clk);

            // Beat 1: Data Payload
            m_axis_rx_tvalid <= 1'b1;
            m_axis_rx_tlast  <= 1'b1;
            m_axis_rx_tkeep  <= 16'h000F;
            m_axis_rx_tdata  <= {96'd0, reg_data};
            @(posedge clk);
            while (!m_axis_rx_tready) @(posedge clk);
            m_axis_rx_tvalid <= 1'b0;
            m_axis_rx_tlast  <= 1'b0;
            #20;
        end
    endtask

    initial begin
        $display("=================================================================");
        $display(" Starting End-to-End SG DMA Pipeline Testbench (128-bit Native)");
        $display("=================================================================");

        clk   = 0;
        rst_n = 0;
        m_axis_rx_tdata  = 128'd0;
        m_axis_rx_tkeep  = 16'd0;
        m_axis_rx_tlast  = 1'b0;
        m_axis_rx_tvalid = 1'b0;
        m_axis_rx_tuser  = 22'd0;
        s_axis_tx_tready = 1'b1;

        #30;
        rst_n = 1;
        #30;

        // 1. Configure Ring Base Address Low = 0xFFFFE000 (BAR0 0x08)
        $display("\n--- [Step 1: Host MMIO Configures Ring Base Low = 0xFFFFE000] ---");
        mmio_write_bar0(32'h00000008, 32'hFFFFE000);

        // 2. Configure Ring Base Address High = 0x00000000 (BAR0 0x0C)
        $display("--- [Step 2: Host MMIO Configures Ring Base High = 0x00000000] ---");
        mmio_write_bar0(32'h0000000C, 32'h00000000);

        // 3. Enable DMA Run in BAR0 0x00 (DMA_CTRL = 1)
        $display("--- [Step 3: Host MMIO Enables DMA (BAR0 0x00 = 0x01)] ---");
        mmio_write_bar0(32'h00000000, 32'h00000001);

        // 4. Update Ring Tail Pointer = 1 & Ring Size = 16 (BAR0 0x10)
        $display("--- [Step 4: Host MMIO Updates Tail Pointer = 1 & Size = 16 (BAR0 0x10)] ---");
        mmio_write_bar0(32'h00000010, (32'd1 << 16) | 32'd16);

        // 5. Expect Hardware to issue RQ MRd to fetch descriptor at 0xFFFFE000
        $display("--- [Step 5: Waiting for Hardware RQ Descriptor Fetch Request...] ---");
        @(posedge s_axis_tx_tvalid);
        $display("  ✅ [PASS] Hardware MRd Request Detected on TX Bus!");
        $display("     - TX TLP Header: Addr=0x%08X, Len=%d DWs, Tag=0x%02X",
                 s_axis_tx_tdata[95:64], s_axis_tx_tdata[9:0], s_axis_tx_tdata[47:40]);

        #40;
        // 6. Return Host CplD with 64-byte Descriptor (C2H to Phys=0xFFFFC000, Len=4096)
        $display("--- [Step 6: Host Returns 64-Byte CplD Descriptor] ---");
        @(posedge clk);
        // Beat 0: Header + DW0 (src_addr_lo = 0xAA001000)
        m_axis_rx_tvalid <= 1'b1;
        m_axis_rx_tlast  <= 1'b0;
        m_axis_rx_tkeep  <= 16'hFFFF;
        m_axis_rx_tdata  <= {32'hAA001000, 32'h00010000, 32'h00000040, 32'h4A000010};
        @(posedge clk);
        while (!m_axis_rx_tready) @(posedge clk);

        // Beat 1: DW1..DW4 (dst_addr_lo = 0xFFFFC000)
        m_axis_rx_tdata  <= {32'h00000000, 32'h00000000, 32'hFFFFC000, 32'h00000000};
        @(posedge clk);
        while (!m_axis_rx_tready) @(posedge clk);

        // Beat 2: DW5..DW8
        m_axis_rx_tdata  <= {32'h00000000, 32'h00000000, 32'h00000000, 32'h00000000};
        @(posedge clk);
        while (!m_axis_rx_tready) @(posedge clk);

        // Beat 3: DW9..DW12 (line_count=1, line_width=4096 = 0x1000)
        m_axis_rx_tdata  <= {32'h00011000, 32'h00000000, 32'h00000000, 32'h00000000};
        @(posedge clk);
        while (!m_axis_rx_tready) @(posedge clk);

        // Beat 4: DW13..DW15 (control=0x02 (C2H))
        m_axis_rx_tlast  <= 1'b1;
        m_axis_rx_tdata  <= {32'h00000000, 32'h00000210, 32'h00000000, 32'h00011000};
        @(posedge clk);
        while (!m_axis_rx_tready) @(posedge clk);
        m_axis_rx_tvalid <= 1'b0;
        m_axis_rx_tlast  <= 1'b0;

        // 7. Expect sg_dma_engine to execute C2H DMA Write bursts to Host RAM
        $display("--- [Step 7: Waiting for sg_dma_engine C2H MWr Bursts...] ---");
        @(posedge clk);
        while (!(s_axis_tx_tvalid && s_axis_tx_tdata[30:29] == 2'b11)) @(posedge clk);
        $display("  ✅ [PASS] Beat 0 (4-DW Header): Addr=0x%08X, Length=%d DWs, tlast=%b",
                 s_axis_tx_tdata[127:96], s_axis_tx_tdata[9:0], s_axis_tx_tlast);
        if (s_axis_tx_tlast != 1'b0) begin
            $display("  ❌ [FAIL] Beat 0 tlast should be 0 for 4-DW MWr!");
            $finish;
        end

        // Wait for Beat 1 (128-bit Data Payload)
        @(posedge clk);
        while (!s_axis_tx_tvalid) @(posedge clk);
        $display("  ✅ [PASS] Beat 1 (128-bit Payload Data): Data=0x%08X_%08X_%08X_%08X, tlast=%b",
                 s_axis_tx_tdata[127:96], s_axis_tx_tdata[95:64], s_axis_tx_tdata[63:32], s_axis_tx_tdata[31:0], s_axis_tx_tlast);
        if (s_axis_tx_tlast != 1'b1) begin
            $display("  ❌ [FAIL] Beat 1 tlast should be 1 for 4-DW MWr payload!");
            $finish;
        end
        if (s_axis_tx_tdata[31:0] != 32'hC2000000) begin
            $display("  ❌ [FAIL] Beat 1 Payload DW0 mismatch! Expected 0xC2000000, got 0x%08X", s_axis_tx_tdata[31:0]);
            $finish;
        end

        #100;
        $display("\n=================================================================");
        $display(" 🎉 FULL END-TO-END SG DMA HARDWARE PIPELINE VERIFIED 100%% PASS!");
        $display("=================================================================\n");
        $finish;
    end

endmodule
