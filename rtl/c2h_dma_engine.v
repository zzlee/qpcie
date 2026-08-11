// ============================================================================
// Module: c2h_dma_engine
// Description: Card-to-Host DMA Engine.
//              Reads data from FPGA memory via AXI4 Master Read,
//              and sends PCIe MWr TLPs to Host memory via RQ Encoder.
// ============================================================================

`timescale 1ns / 1ps

module c2h_dma_engine #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 64
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Descriptor Interface from Descriptor Fetch Engine
    input  wire                      c2h_desc_valid,
    input  wire [63:0]               c2h_desc_src_addr,
    input  wire [63:0]               c2h_desc_dst_addr,
    input  wire [31:0]               c2h_desc_len,
    input  wire [31:0]               c2h_desc_ctrl,
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

    localparam IDLE      = 2'b00;
    localparam READ_AXI  = 2'b01;
    localparam SEND_MWR  = 2'b10;

    reg [1:0] state;
    reg [63:0] current_src;
    reg [63:0] current_dst;
    reg [31:0] remaining_bytes;

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
            current_src     <= 64'd0;
            current_dst     <= 64'd0;
            remaining_bytes <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    c2h_done       <= 1'b0;
                    c2h_count_inc  <= 1'b0;
                    c2h_desc_ready <= 1'b1;

                    if (c2h_desc_valid && c2h_desc_ready) begin
                        c2h_desc_ready  <= 1'b0;
                        c2h_busy        <= 1'b1;
                        current_src     <= c2h_desc_src_addr;
                        current_dst     <= c2h_desc_dst_addr;
                        remaining_bytes <= c2h_desc_len;

                        m_axi_araddr    <= c2h_desc_src_addr;
                        m_axi_arlen     <= 8'd0; // 1 beat
                        m_axi_arvalid   <= 1'b1;
                        state           <= READ_AXI;
                    end
                end

                READ_AXI: begin
                    if (m_axi_arready) m_axi_arvalid <= 1'b0;
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready   <= 1'b0;
                        c2h_req_addr   <= current_dst;
                        c2h_req_dw_len <= remaining_bytes / 4;
                        c2h_req_data   <= m_axi_rdata;
                        c2h_req_last   <= 1'b1;
                        c2h_req_valid  <= 1'b1;
                        state          <= SEND_MWR;
                    end
                end

                SEND_MWR: begin
                    if (c2h_req_ack) begin
                        c2h_req_valid  <= 1'b0;
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
