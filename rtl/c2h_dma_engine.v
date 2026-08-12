// ============================================================================
// Module: c2h_dma_engine
// Description: Multi-Planar 2D Strided Card-to-Host DMA Engine.
//              Loops over multiple video planes and 2D scanlines, calculating
//              line addresses with stride/pitch padding, reading FPGA AXI4 Memory,
//              and issuing MWr TLPs to Host Memory via RQ Encoder.
// ============================================================================

`timescale 1ns / 1ps

module c2h_dma_engine #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 64
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Extended 2D Descriptor Interface from Descriptor Fetch Engine
    input  wire                      c2h_desc_valid,
    input  wire [63:0]               c2h_plane0_src, c2h_plane0_dst,
    input  wire [63:0]               c2h_plane1_src, c2h_plane1_dst,
    input  wire [63:0]               c2h_plane2_src, c2h_plane2_dst,
    input  wire [15:0]               c2h_line_width, c2h_line_count,
    input  wire [15:0]               c2h_src_stride, c2h_dst_stride,
    input  wire [15:0]               c2h_plane12_width, c2h_plane12_count,
    input  wire [3:0]                c2h_format, c2h_plane_count,
    input  wire [15:0]               c2h_desc_ctrl,
    output reg                       c2h_desc_ready,

    // AXI4 Memory Mapped Master Read Interface (FPGA Memory)
    output reg  [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output reg  [7:0]                m_axi_arlen,
    output reg  [2:0]                m_axi_arsize,
    output reg  [1:0]                m_axi_arburst,
    output reg                       m_axi_arvalid,
    input  wire                      m_axi_arready,

    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]                m_axi_rresp,
    input  wire                      m_axi_rlast,
    input  wire                      m_axi_rvalid,
    output reg                       m_axi_rready,

    // RQ MWr Request Interface (To Host Memory)
    output reg                       c2h_req_valid,
    output reg  [63:0]               c2h_req_addr,
    output reg  [10:0]               c2h_req_dw_len,
    output reg  [AXI_DATA_WIDTH-1:0] c2h_req_data,
    output reg                       c2h_req_last,
    input  wire                      c2h_req_ack,

    // Engine Status Signals
    output reg                       c2h_busy,
    output reg                       c2h_done,
    output reg                       c2h_count_inc
);

    localparam IDLE      = 3'b000;
    localparam READ_AXI  = 3'b001;
    localparam SEND_MWR  = 3'b010;
    localparam NEXT_LINE = 3'b011;

    reg [2:0]  state;
    reg [3:0]  curr_plane;
    reg [15:0] curr_line;
    reg [63:0] curr_plane_src_base;
    reg [63:0] curr_plane_dst_base;
    reg [15:0] curr_active_width;
    reg [15:0] curr_max_lines;

    // Active plane base address lookup
    always @(*) begin
        case (curr_plane)
            4'd0: begin
                curr_plane_src_base = c2h_plane0_src;
                curr_plane_dst_base = c2h_plane0_dst;
                curr_active_width   = c2h_line_width;
                curr_max_lines      = c2h_line_count;
            end
            4'd1: begin
                curr_plane_src_base = c2h_plane1_src;
                curr_plane_dst_base = c2h_plane1_dst;
                curr_active_width   = (c2h_plane12_width > 0) ? c2h_plane12_width : c2h_line_width;
                curr_max_lines      = (c2h_plane12_count > 0) ? c2h_plane12_count : c2h_line_count;
            end
            default: begin
                curr_plane_src_base = c2h_plane2_src;
                curr_plane_dst_base = c2h_plane2_dst;
                curr_active_width   = (c2h_plane12_width > 0) ? c2h_plane12_width : c2h_line_width;
                curr_max_lines      = (c2h_plane12_count > 0) ? c2h_plane12_count : c2h_line_count;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            c2h_desc_ready  <= 1'b1;
            m_axi_araddr    <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_arlen     <= 8'd0;
            m_axi_arsize    <= 3'b101; // 32 bytes
            m_axi_arburst   <= 2'b01;
            m_axi_arvalid   <= 1'b0;
            m_axi_rready    <= 1'b0;
            c2h_req_valid   <= 1'b0;
            c2h_req_addr    <= 64'd0;
            c2h_req_dw_len  <= 11'd0;
            c2h_req_data    <= {AXI_DATA_WIDTH{1'b0}};
            c2h_req_last    <= 1'b0;
            c2h_busy        <= 1'b0;
            c2h_done        <= 1'b0;
            c2h_count_inc   <= 1'b0;
            curr_plane      <= 4'd0;
            curr_line       <= 16'd0;
        end else begin
            case (state)
                IDLE: begin
                    c2h_done       <= 1'b0;
                    c2h_count_inc  <= 1'b0;
                    c2h_desc_ready <= 1'b1;

                    if (c2h_desc_valid && c2h_desc_ready) begin
                        c2h_desc_ready <= 1'b0;
                        c2h_busy       <= 1'b1;
                        curr_plane     <= 4'd0;
                        curr_line      <= 16'd0;

                        m_axi_araddr   <= c2h_plane0_src;
                        m_axi_arlen    <= 8'd0; // 1 beat
                        m_axi_arvalid  <= 1'b1;
                        state          <= READ_AXI;
                    end
                end

                READ_AXI: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready   <= 1'b0;
                        c2h_req_addr   <= curr_plane_dst_base + (curr_line * c2h_dst_stride);
                        c2h_req_dw_len <= curr_active_width / 4;
                        c2h_req_data   <= m_axi_rdata;
                        c2h_req_last   <= 1'b1;
                        c2h_req_valid  <= 1'b1;
                        state          <= SEND_MWR;
                    end
                end

                SEND_MWR: begin
                    if (c2h_req_ack) begin
                        c2h_req_valid <= 1'b0;
                        state         <= NEXT_LINE;
                    end
                end

                NEXT_LINE: begin
                    if (curr_line + 1'b1 < curr_max_lines) begin
                        curr_line    <= curr_line + 1'b1;
                        m_axi_araddr <= curr_plane_src_base + ((curr_line + 1'b1) * c2h_src_stride);
                        m_axi_arlen  <= 8'd0;
                        m_axi_arvalid<= 1'b1;
                        state        <= READ_AXI;
                    end else if (curr_plane + 1'b1 < c2h_plane_count) begin
                        curr_plane   <= curr_plane + 1'b1;
                        curr_line    <= 16'd0;
                        m_axi_araddr <= (curr_plane == 4'd0) ? c2h_plane1_src : c2h_plane2_src;
                        m_axi_arlen  <= 8'd0;
                        m_axi_arvalid<= 1'b1;
                        state        <= READ_AXI;
                    end else begin
                        c2h_busy       <= 1'b0;
                        c2h_done       <= 1'b1;
                        c2h_count_inc  <= 1'b1;
                        c2h_desc_ready <= 1'b1;
                        state          <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
