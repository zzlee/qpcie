// ============================================================================
// Module: h2c_dma_engine
// Description: Host-to-Card DMA Engine.
//              Requests Host data via RQ MRd TLPs, buffers incoming CplD data,
//              and performs AXI4 Master Write transactions to write into FPGA memory.
// ============================================================================

`timescale 1ns / 1ps

module h2c_dma_engine #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 64
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Descriptor Interface from Descriptor Fetch Engine
    input  wire                      h2c_desc_valid,
    input  wire [63:0]               h2c_desc_src_addr,
    input  wire [63:0]               h2c_desc_dst_addr,
    input  wire [31:0]               h2c_desc_len,
    input  wire [31:0]               h2c_desc_ctrl,
    output reg                       h2c_desc_ready,

    // Tag Manager Interface
    output reg                       tag_alloc_req,
    input  wire [7:0]                tag_alloc_tag,
    input  wire                      tag_alloc_valid,

    // RQ MRd Request Interface
    output reg                       h2c_req_valid,
    output reg  [63:0]               h2c_req_addr,
    output reg  [10:0]               h2c_req_dw_len,
    output reg  [7:0]                h2c_req_tag,
    input  wire                      h2c_req_ack,

    // RC CplD Data Interface
    input  wire                      h2c_fifo_wvalid,
    input  wire [AXI_DATA_WIDTH-1:0] h2c_fifo_wdata,
    input  wire                      h2c_fifo_wlast,

    // AXI4 Memory Mapped Master Write Interface
    output reg  [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output reg  [7:0]                m_axi_awlen,
    output reg  [2:0]                m_axi_awsize,
    output reg  [1:0]                m_axi_awburst,
    output reg                       m_axi_awvalid,
    input  wire                      m_axi_awready,

    output reg  [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output reg  [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output reg                       m_axi_wlast,
    output reg                       m_axi_wvalid,
    input  wire                      m_axi_wready,

    input  wire [1:0]                m_axi_bresp,
    input  wire                      m_axi_bvalid,
    output reg                       m_axi_bready,

    // Engine Status Signals
    output reg                       h2c_busy,
    output reg                       h2c_done,
    output reg                       h2c_count_inc
);

    localparam IDLE       = 3'b000;
    localparam ALLOC_TAG  = 3'b001;
    localparam SEND_MRD   = 3'b010;
    localparam WRITE_AXI  = 3'b011;
    localparam WAIT_BRESP = 3'b100;

    reg [2:0] state;
    reg [63:0] current_src;
    reg [63:0] current_dst;
    reg [31:0] remaining_bytes;
    reg [7:0]  assigned_tag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            h2c_desc_ready   <= 1'b1;
            tag_alloc_req    <= 1'b0;
            h2c_req_valid    <= 1'b0;
            h2c_req_addr     <= 64'd0;
            h2c_req_dw_len   <= 11'd0;
            h2c_req_tag      <= 8'd0;
            m_axi_awaddr     <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awlen      <= 8'd0;
            m_axi_awsize     <= 3'b101; // 32 bytes (256-bit)
            m_axi_awburst    <= 2'b01;  // INCR
            m_axi_awvalid    <= 1'b0;
            m_axi_wdata      <= {AXI_DATA_WIDTH{1'b0}};
            m_axi_wstrb      <= {(AXI_DATA_WIDTH/8){1'b1}};
            m_axi_wlast      <= 1'b0;
            m_axi_wvalid     <= 1'b0;
            m_axi_bready     <= 1'b1;
            h2c_busy         <= 1'b0;
            h2c_done         <= 1'b0;
            h2c_count_inc    <= 1'b0;
            current_src      <= 64'd0;
            current_dst      <= 64'd0;
            remaining_bytes  <= 32'd0;
            assigned_tag     <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    h2c_done       <= 1'b0;
                    h2c_count_inc  <= 1'b0;
                    h2c_desc_ready <= 1'b1;

                    if (h2c_desc_valid && h2c_desc_ready) begin
                        h2c_desc_ready  <= 1'b0;
                        h2c_busy        <= 1'b1;
                        current_src     <= h2c_desc_src_addr;
                        current_dst     <= h2c_desc_dst_addr;
                        remaining_bytes <= h2c_desc_len;
                        tag_alloc_req   <= 1'b1;
                        state           <= ALLOC_TAG;
                    end
                end

                ALLOC_TAG: begin
                    tag_alloc_req <= 1'b0;
                    if (tag_alloc_valid) begin
                        assigned_tag  <= tag_alloc_tag;
                        h2c_req_addr  <= current_src;
                        h2c_req_dw_len<= remaining_bytes / 4;
                        h2c_req_tag   <= tag_alloc_tag;
                        h2c_req_valid <= 1'b1;
                        state         <= SEND_MRD;
                    end else begin
                        tag_alloc_req <= 1'b1; // Retry alloc
                    end
                end

                SEND_MRD: begin
                    if (h2c_req_ack) begin
                        h2c_req_valid <= 1'b0;
                        state         <= WRITE_AXI;
                    end
                end

                WRITE_AXI: begin
                    if (h2c_fifo_wvalid) begin
                        m_axi_awaddr  <= current_dst;
                        m_axi_awlen   <= 8'd0; // 1 burst beat for 256-bit
                        m_axi_awvalid <= 1'b1;
                        m_axi_wdata   <= h2c_fifo_wdata;
                        m_axi_wlast   <= 1'b1;
                        m_axi_wvalid  <= 1'b1;
                        m_axi_bready  <= 1'b1;
                        state         <= WAIT_BRESP;
                    end
                end

                WAIT_BRESP: begin
                    if (m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wready)  m_axi_wvalid  <= 1'b0;

                    if (m_axi_bvalid) begin
                        m_axi_bready   <= 1'b0;
                        h2c_busy       <= 1'b0;
                        h2c_done       <= 1'b1;
                        h2c_count_inc  <= 1'b1;
                        h2c_desc_ready <= 1'b1;
                        state          <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
