// ============================================================================
// Module: h2c_dma_engine
// Description: Multi-Planar 2D Strided Host-to-Card DMA Engine.
//              Loops over multiple video planes and 2D scanlines, calculating
//              line addresses with stride/pitch padding, requesting Host MRd TLPs,
//              and driving AXI4 Master Write transactions into FPGA Memory.
// ============================================================================

`timescale 1ns / 1ps

module h2c_dma_engine #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 64
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Extended 2D Descriptor Interface from Descriptor Fetch Engine
    input  wire                      h2c_desc_valid,
    input  wire [63:0]               h2c_plane0_src, h2c_plane0_dst,
    input  wire [63:0]               h2c_plane1_src, h2c_plane1_dst,
    input  wire [63:0]               h2c_plane2_src, h2c_plane2_dst,
    input  wire [15:0]               h2c_line_width, h2c_line_count,
    input  wire [15:0]               h2c_src_stride, h2c_dst_stride,
    input  wire [15:0]               h2c_plane12_width, h2c_plane12_count,
    input  wire [3:0]                h2c_format, h2c_plane_count,
    input  wire [15:0]               h2c_desc_ctrl,
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
    localparam NEXT_LINE  = 3'b101;

    reg [2:0]  state;
    reg [3:0]  curr_plane;
    reg [15:0] curr_line;
    reg [63:0] curr_plane_src_base;
    reg [63:0] curr_plane_dst_base;
    reg [15:0] curr_active_width;
    reg [15:0] curr_max_lines;
    reg [7:0]  assigned_tag;

    // Active plane base address lookup
    always @(*) begin
        case (curr_plane)
            4'd0: begin
                curr_plane_src_base = h2c_plane0_src;
                curr_plane_dst_base = h2c_plane0_dst;
                curr_active_width   = h2c_line_width;
                curr_max_lines      = h2c_line_count;
            end
            4'd1: begin
                curr_plane_src_base = h2c_plane1_src;
                curr_plane_dst_base = h2c_plane1_dst;
                curr_active_width   = (h2c_plane12_width > 0) ? h2c_plane12_width : h2c_line_width;
                curr_max_lines      = (h2c_plane12_count > 0) ? h2c_plane12_count : h2c_line_count;
            end
            default: begin
                curr_plane_src_base = h2c_plane2_src;
                curr_plane_dst_base = h2c_plane2_dst;
                curr_active_width   = (h2c_plane12_width > 0) ? h2c_plane12_width : h2c_line_width;
                curr_max_lines      = (h2c_plane12_count > 0) ? h2c_plane12_count : h2c_line_count;
            end
        endcase
    end

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
            curr_plane       <= 4'd0;
            curr_line        <= 16'd0;
            assigned_tag     <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    h2c_done       <= 1'b0;
                    h2c_count_inc  <= 1'b0;
                    h2c_desc_ready <= 1'b1;

                    if (h2c_desc_valid && h2c_desc_ready) begin
                        h2c_desc_ready <= 1'b0;
                        h2c_busy       <= 1'b1;
                        curr_plane     <= 4'd0;
                        curr_line      <= 16'd0;
                        tag_alloc_req  <= 1'b1;
                        state          <= ALLOC_TAG;
                    end
                end

                ALLOC_TAG: begin
                    tag_alloc_req <= 1'b0;
                    if (tag_alloc_valid) begin
                        assigned_tag  <= tag_alloc_tag;
                        h2c_req_addr  <= curr_plane_src_base + (curr_line * h2c_src_stride);
                        h2c_req_dw_len<= curr_active_width / 4;
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
                        m_axi_awaddr  <= curr_plane_dst_base + (curr_line * h2c_dst_stride);
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
                        m_axi_bready <= 1'b0;
                        state        <= NEXT_LINE;
                    end
                end

                NEXT_LINE: begin
                    if (curr_line + 1'b1 < curr_max_lines) begin
                        curr_line     <= curr_line + 1'b1;
                        tag_alloc_req <= 1'b1;
                        state         <= ALLOC_TAG;
                    end else if (curr_plane + 1'b1 < h2c_plane_count) begin
                        curr_plane    <= curr_plane + 1'b1;
                        curr_line     <= 16'd0;
                        tag_alloc_req <= 1'b1;
                        state         <= ALLOC_TAG;
                    end else begin
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
