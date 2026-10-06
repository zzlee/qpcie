// ============================================================================
// Module: h2c_ps_ddr_writer
// Description: Converts H2C PCIe AXI-Stream into AXI4 Memory-Mapped Master Write
//              transactions directly into Zynq UltraScale+ PS DDR4 via S_AXI_HP0_FPD.
//              Used by SC7F0 PCIe Fast-Push In-System Firmware Upgrade pathway.
//              - Data Width: 128-bit native (16 bytes per beat)
//              - Burst Length: Up to 16 beats (256-byte burst matching PCIe MPS)
//              - Auto-increments address from base dst_addr (e.g. 0x70000000)
//              - Counts bytes written and signals dma_complete & doorbell IRQ
// ============================================================================

`timescale 1ns / 1ps

module h2c_ps_ddr_writer #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 49
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // Control & Status Interface
    input  wire                    upg_enable,       // Asserted during firmware push (REG_DMA_UPG_CTRL[0])
    input  wire [ADDR_WIDTH-1:0]   upg_dst_addr,     // Target PS DDR4 physical address (REG_DMA_UPG_PS_ADDR)
    input  wire [31:0]             upg_total_size,   // Total expected package size in bytes
    output reg  [31:0]             upg_bytes_written,// Current bytes written to PS DDR4
    output reg                     upg_write_done,   // Asserted when transfer finishes
    output reg                     upg_irq_pulse,    // Pulse to interrupt PS ARM core (pl_ps_irq0)

    // AXI-Stream Input (From PCIe H2C / Loopback Stream)
    input  wire [DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire                    s_axis_tvalid,
    input  wire                    s_axis_tlast,
    output wire                    s_axis_tready,

    // AXI4 Master Write Interface (To PS S_AXI_HP0_FPD)
    output reg  [ADDR_WIDTH-1:0]   m_axi_awaddr,
    output reg  [7:0]              m_axi_awlen,
    output wire [2:0]              m_axi_awsize,
    output wire [1:0]              m_axi_awburst,
    output reg                     m_axi_awvalid,
    input  wire                    m_axi_awready,

    output wire [DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [(DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                    m_axi_wlast,
    output wire                    m_axi_wvalid,
    input  wire                    m_axi_wready,

    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output reg                     m_axi_bready
);

    assign m_axi_awsize  = 3'b100; // 16 bytes = 128-bit
    assign m_axi_awburst = 2'b01;  // INCR
    assign m_axi_wstrb   = 16'hFFFF;

    // Synchronous FIFO to absorb PCIe bursts (256 beats = 4KB = 16x 256B bursts)
    localparam FIFO_DEPTH = 256;
    reg [DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [8:0] wr_ptr = 9'd0;
    reg [8:0] rd_ptr = 9'd0;
    wire [8:0] fifo_count = wr_ptr - rd_ptr;
    wire fifo_full  = (fifo_count >= (FIFO_DEPTH - 4));
    wire fifo_empty = (wr_ptr == rd_ptr);

    assign s_axis_tready = upg_enable && !fifo_full && !upg_write_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 9'd0;
        end else if (upg_enable && s_axis_tvalid && s_axis_tready) begin
            fifo_mem[wr_ptr[7:0]] <= s_axis_tdata;
            wr_ptr <= wr_ptr + 1'b1;
        end else if (!upg_enable) begin
            wr_ptr <= 9'd0;
        end
    end

    // FSM States
    localparam S_IDLE     = 3'd0;
    localparam S_START    = 3'd1;
    localparam S_AW_ISSUE = 3'd2;
    localparam S_W_BURST  = 3'd3;
    localparam S_WAIT_B   = 3'd4;
    localparam S_DONE     = 3'd5;

    reg [2:0]  state;
    reg [7:0]  burst_cnt;
    reg [7:0]  target_len;
    reg [ADDR_WIDTH-1:0] cur_addr;

    wire fifo_rd_en = (state == S_W_BURST) && m_axi_wready;
    assign m_axi_wdata  = fifo_mem[rd_ptr[7:0]];
    assign m_axi_wvalid = (state == S_W_BURST);
    assign m_axi_wlast  = (state == S_W_BURST) && (burst_cnt == target_len);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 9'd0;
        end else if (fifo_rd_en) begin
            rd_ptr <= rd_ptr + 1'b1;
        end else if (!upg_enable) begin
            rd_ptr <= 9'd0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            m_axi_awaddr      <= {ADDR_WIDTH{1'b0}};
            m_axi_awlen       <= 8'd0;
            m_axi_awvalid     <= 1'b0;
            m_axi_bready      <= 1'b0;
            burst_cnt         <= 8'd0;
            target_len        <= 8'd0;
            cur_addr          <= {ADDR_WIDTH{1'b0}};
            upg_bytes_written <= 32'd0;
            upg_write_done    <= 1'b0;
            upg_irq_pulse     <= 1'b0;
        end else begin
            upg_irq_pulse <= 1'b0;

            case (state)
                S_IDLE: begin
                    upg_write_done    <= 1'b0;
                    upg_bytes_written <= 32'd0;
                    if (upg_enable && (upg_total_size > 0)) begin
                        cur_addr <= upg_dst_addr;
                        state    <= S_START;
                    end
                end

                S_START: begin
                    if (!upg_enable) begin
                        state <= S_IDLE;
                    end else if (upg_bytes_written >= upg_total_size) begin
                        state <= S_DONE;
                    end else if (fifo_count >= 9'd16 || (fifo_count > 9'd0 && (upg_bytes_written + (fifo_count * 16) >= upg_total_size))) begin
                        // Determine burst length (0-indexed: 0 means 1 beat)
                        target_len    <= (fifo_count >= 9'd16) ? 8'd15 : (fifo_count[7:0] - 1'b1);
                        m_axi_awlen   <= (fifo_count >= 9'd16) ? 8'd15 : (fifo_count[7:0] - 1'b1);
                        m_axi_awaddr  <= cur_addr;
                        m_axi_awvalid <= 1'b1;
                        burst_cnt     <= 8'd0;
                        state         <= S_AW_ISSUE;
                    end
                end

                S_AW_ISSUE: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        state         <= S_W_BURST;
                    end
                end

                S_W_BURST: begin
                    if (m_axi_wready) begin
                        if (burst_cnt == target_len) begin
                            m_axi_bready <= 1'b1;
                            state        <= S_WAIT_B;
                        end else begin
                            burst_cnt <= burst_cnt + 1'b1;
                        end
                    end
                end

                S_WAIT_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready      <= 1'b0;
                        cur_addr          <= cur_addr + ((target_len + 1'b1) * 16);
                        upg_bytes_written <= upg_bytes_written + ((target_len + 1'b1) * 16);
                        state             <= S_START;
                    end
                end

                S_DONE: begin
                    upg_write_done <= 1'b1;
                    upg_irq_pulse  <= 1'b1;
                    if (!upg_enable) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
