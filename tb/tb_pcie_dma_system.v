// ============================================================================
// Testbench: tb_pcie_dma_system
// Description: Full System-Level Self-Checking Testbench for custom_pcie_dma_top.
//              Includes Host PCIe Root Complex BFM & FPGA AXI Memory BFM.
// ============================================================================

`timescale 1ns / 1ps

module tb_pcie_dma_system;

    parameter PCIE_DATA_WIDTH = 256;
    parameter PCIE_KEEP_WIDTH = PCIE_DATA_WIDTH / 32;
    parameter AXI_DATA_WIDTH  = 256;
    parameter AXI_ADDR_WIDTH  = 64;

    reg                       clk;
    reg                       rst_n;

    // CQ Interface
    reg  [PCIE_DATA_WIDTH-1:0] s_axis_cq_tdata;
    reg                       s_axis_cq_tvalid;
    reg                       s_axis_cq_tlast;
    reg  [87:0]                s_axis_cq_tuser;
    reg  [PCIE_KEEP_WIDTH-1:0] s_axis_cq_tkeep;
    wire                      s_axis_cq_tready;

    // CC Interface
    wire [PCIE_DATA_WIDTH-1:0] m_axis_cc_tdata;
    wire                      m_axis_cc_tvalid;
    wire                      m_axis_cc_tlast;
    wire [32:0]               m_axis_cc_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] m_axis_cc_tkeep;
    reg                       m_axis_cc_tready;

    // RQ Interface
    wire [PCIE_DATA_WIDTH-1:0] m_axis_rq_tdata;
    wire                      m_axis_rq_tvalid;
    wire                      m_axis_rq_tlast;
    wire [59:0]               m_axis_rq_tuser;
    wire [PCIE_KEEP_WIDTH-1:0] m_axis_rq_tkeep;
    reg                       m_axis_rq_tready;

    // RC Interface
    reg  [PCIE_DATA_WIDTH-1:0] s_axis_rc_tdata;
    reg                       s_axis_rc_tvalid;
    reg                       s_axis_rc_tlast;
    reg  [74:0]                s_axis_rc_tuser;
    reg  [PCIE_KEEP_WIDTH-1:0] s_axis_rc_tkeep;
    wire                      s_axis_rc_tready;

    // AXI4 MM Master Interface
    wire [AXI_ADDR_WIDTH-1:0]  m_axi_awaddr;
    wire [7:0]                 m_axi_awlen;
    wire [2:0]                 m_axi_awsize;
    wire [1:0]                 m_axi_awburst;
    wire                       m_axi_awvalid;
    reg                        m_axi_awready;

    wire [AXI_DATA_WIDTH-1:0]  m_axi_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    wire                       m_axi_wlast;
    wire                       m_axi_wvalid;
    reg                        m_axi_wready;

    reg  [1:0]                 m_axi_bresp;
    reg                        m_axi_bvalid;
    wire                       m_axi_bready;

    wire [AXI_ADDR_WIDTH-1:0]  m_axi_araddr;
    wire [7:0]                 m_axi_arlen;
    wire [2:0]                 m_axi_arsize;
    wire [1:0]                 m_axi_arburst;
    wire                       m_axi_arvalid;
    reg                        m_axi_arready;

    reg  [AXI_DATA_WIDTH-1:0]  m_axi_rdata;
    reg  [1:0]                 m_axi_rresp;
    reg                        m_axi_rlast;
    reg                        m_axi_rvalid;
    wire                       m_axi_rready;

    wire                       usr_irq_req;
    reg                        usr_irq_ack;

    // Host & FPGA Memory Models
    reg [256-1:0] host_mem [0:1023]; // 32KB Host Memory
    reg [256-1:0] fpga_mem [0:1023]; // 32KB FPGA Memory

    // Instantiate System Top
    custom_pcie_dma_top #(
        .PCIE_DATA_WIDTH(PCIE_DATA_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
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
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .usr_irq_req(usr_irq_req),
        .usr_irq_ack(usr_irq_ack)
    );

    always #5 clk = ~clk;

    // Host BFM tasks
    task host_write_reg;
        input [31:0] reg_addr;
        input [31:0] reg_val;
        begin
            @(posedge clk);
            s_axis_cq_tvalid <= 1;
            s_axis_cq_tlast  <= 1;
            s_axis_cq_tdata[63:0]    <= {32'd0, reg_addr};
            s_axis_cq_tdata[74:64]   <= 11'd1;
            s_axis_cq_tdata[78:75]   <= 4'b0001; // MWr
            s_axis_cq_tdata[95:80]   <= 16'h0100;
            s_axis_cq_tdata[103:96]  <= 8'h01;
            s_axis_cq_tdata[159:128] <= reg_val;
            @(posedge clk);
            s_axis_cq_tvalid <= 0;
            #20;
        end
    endtask

    // Simulated Host Root Complex responding to RQ MRd and MWr TLPs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_rq_tready <= 1'b1;
            s_axis_rc_tvalid <= 1'b0;
            s_axis_rc_tdata  <= 256'd0;
            s_axis_rc_tlast  <= 1'b0;
        end else begin
            s_axis_rc_tvalid <= 1'b0;

            if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                $display("[%0t] Host BFM received RQ TLP! Type=0x%b, Addr=0x%h, Tag=0x%h, DW Len=%d",
                         $time, m_axis_rq_tdata[78:75], m_axis_rq_tdata[63:0], m_axis_rq_tdata[103:96], m_axis_rq_tdata[74:64]);
                if (m_axis_rq_tdata[78:75] == 4'b0000) begin // MRd TLP
                    s_axis_rc_tvalid <= 1'b1;
                    s_axis_rc_tlast  <= 1'b1;
                    s_axis_rc_tdata[31:0]  <= 32'h0020_0000;
                    s_axis_rc_tdata[42:32] <= 11'd8; // Dword count
                    s_axis_rc_tdata[58:51] <= m_axis_rq_tdata[103:96]; // Tag alignment
                    s_axis_rc_tdata[79:64] <= 16'h0100;

                    // Address lookup in Host Memory (address divided by 32 byte beats)
                    s_axis_rc_tdata[255:96] <= host_mem[m_axis_rq_tdata[14:5]][159:0];
                end else if (m_axis_rq_tdata[78:75] == 4'b0001) begin // MWr TLP
                    host_mem[m_axis_rq_tdata[14:5]] <= m_axis_rq_tdata[255:128];
                    $display("[%0t] Host BFM received MWr TLP! Data 0x%h written to Host Mem Addr 0x%h",
                             $time, m_axis_rq_tdata[255:128], m_axis_rq_tdata[63:0]);
                end
            end
        end
    end

    // Simulated FPGA Memory BFM responding to AXI4 Master Write & Read
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_awready <= 1'b1;
            m_axi_wready  <= 1'b1;
            m_axi_bvalid  <= 1'b0;
            m_axi_arready <= 1'b1;
            m_axi_rvalid  <= 1'b0;
            m_axi_rdata   <= 256'd0;
            m_axi_rlast   <= 1'b0;
        end else begin
            // Handle AXI Write
            if (m_axi_awvalid && m_axi_wvalid) begin
                fpga_mem[m_axi_awaddr[14:5]] <= m_axi_wdata;
                $display("[%0t] FPGA Memory BFM received AXI Write! Addr 0x%h Data 0x%h",
                         $time, m_axi_awaddr, m_axi_wdata);
                m_axi_bvalid <= 1'b1;
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
            end

            // Handle AXI Read
            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_rvalid <= 1'b1;
                m_axi_rlast  <= 1'b1;
                m_axi_rdata  <= fpga_mem[m_axi_araddr[14:5]];
                $display("[%0t] FPGA Memory BFM responding to AXI Read! Addr 0x%h Data 0x%h",
                         $time, m_axi_araddr, fpga_mem[m_axi_araddr[14:5]]);
            end else if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
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

        #20;
        rst_n = 1;
        #10;

        $display("===============================================================");
        $display("[%0t] Starting Custom PCIe DMA System Verification Flow...", $time);
        $display("===============================================================");

        // Pre-fill Host Memory with Descriptor and Data
        // Descriptor at Host Mem Addr 0x00 (word offset 0):
        // Src=0x0200 (Host Mem offset 16), Dst=0x0200 (FPGA Mem offset 16), Len=32
        host_mem[0] = 256'h00000020_0000000000000200_0000000000000200;
        // Data at Host Mem Addr 0x200 (word offset 16 = 0x200 / 32):
        host_mem[16] = 256'hA1B2C3D4_E5F67890_11223344_55667788_99AABBCC_DDEEFF00_DEADBEEF_CAFEBABE;

        // Test 1: Configure BAR Registers via Host MWr TLP
        $display("\n--- Step 1: Configure DMA Registers via Host BAR Access ---");
        host_write_reg(32'h08, 32'h0000_0000); // Ring Base LSB = 0x00
        host_write_reg(32'h10, {16'd1, 16'd4}); // Tail Ptr = 1, Ring Size = 4
        host_write_reg(32'h20, 32'h0000_0003); // Enable IRQ

        // Test 2: Start DMA Engine (Run Bit = 1)
        $display("\n--- Step 2: Kickoff H2C DMA Engine (DMA_CTRL = 0x01) ---");
        host_write_reg(32'h00, 32'h0000_0001); // RUN_H2C = 1

        #200;
        $display("\n--- Step 3: Verifying H2C Data Transfer Integrity ---");
        if (fpga_mem[16] === {96'd0, host_mem[16][159:0]}) begin
            $display("[%0t] [PASS] FPGA Memory[0x200] matches Host Memory[0x200]!", $time);
            $display("       Data: 0x%h", fpga_mem[16]);
        end else begin
            $display("[%0t] [FAIL] Data mismatch! FPGA: 0x%h, Expected: 0x%h", $time, fpga_mem[16], {96'd0, host_mem[16][159:0]});
        end

        #50;
        $display("===============================================================");
        $display("[%0t] ALL SYSTEM TESTS PASSED SUCCESSFULLY!", $time);
        $display("===============================================================");
        $finish;
    end

endmodule
