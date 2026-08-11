// ============================================================================
// Module: cq_rx_decoder
// Description: Decodes PCIe IP CQ (Completer Request) AXI4-Stream TLP packets.
//              Converts Host MRd/MWr requests (BAR Access) into AXI4-Lite Master transactions.
// ============================================================================

`timescale 1ns / 1ps

module cq_rx_decoder #(
    parameter DATA_WIDTH = 256,
    parameter KEEP_WIDTH = DATA_WIDTH / 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // CQ AXI4-Stream Interface (PCIe IP -> User Logic)
    input  wire [DATA_WIDTH-1:0] s_axis_cq_tdata,
    input  wire                  s_axis_cq_tvalid,
    input  wire                  s_axis_cq_tlast,
    input  wire [87:0]           s_axis_cq_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_cq_tkeep,
    output reg                   s_axis_cq_tready,

    // AXI4-Lite Master Interface (To Register Space)
    output reg  [31:0]           m_axil_awaddr,
    output reg                   m_axil_awvalid,
    input  wire                  m_axil_awready,

    output reg  [31:0]           m_axil_wdata,
    output reg  [3:0]            m_axil_wstrb,
    output reg                   m_axil_wvalid,
    input  wire                  m_axil_wready,

    input  wire [1:0]            m_axil_bresp,
    input  wire                  m_axil_bvalid,
    output reg                   m_axil_bready,

    output reg  [31:0]           m_axil_araddr,
    output reg                   m_axil_arvalid,
    input  wire                  m_axil_arready,

    input  wire [31:0]           m_axil_rdata,
    input  wire [1:0]            m_axil_rresp,
    input  wire                  m_axil_rvalid,
    output reg                   m_axil_rready,

    // Read Request sideband interface to CC Encoder
    output reg                   read_req_valid,
    output reg  [7:0]            read_req_tag,
    output reg  [15:0]           read_req_id,
    output reg  [6:0]            read_req_lower_addr,
    output reg  [10:0]           read_req_tc,
    input  wire                  read_req_ack
);

    // FSM States
    localparam IDLE       = 3'b000;
    localparam WRITE_AXIL = 3'b001;
    localparam WAIT_BRESP = 3'b010;
    localparam READ_AXIL  = 3'b011;
    localparam WAIT_RRESP = 3'b100;

    reg [2:0] state;

    // CQ TLP Header breakdown (DW0-DW3 in first beat of tdata)
    wire [63:0] req_addr    = s_axis_cq_tdata[63:0];
    wire [10:0] req_dword_len = s_axis_cq_tdata[74:64];
    wire [3:0]  req_type     = s_axis_cq_tdata[78:75]; // 0000=MRd, 0001=MWr
    wire [15:0] req_id       = s_axis_cq_tdata[95:80];
    wire [7:0]  req_tag      = s_axis_cq_tdata[103:96];
    wire [2:0]  bar_id       = s_axis_cq_tdata[114:112];

    // Payload for MWr (in 256-bit interface, DW4 payload is at tdata[159:128])
    wire [31:0] req_payload  = s_axis_cq_tdata[159:128];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            s_axis_cq_tready <= 1'b1;
            m_axil_awaddr    <= 32'd0;
            m_axil_awvalid   <= 1'b0;
            m_axil_wdata     <= 32'd0;
            m_axil_wstrb     <= 4'b1111;
            m_axil_wvalid    <= 1'b0;
            m_axil_bready    <= 1'b1;
            m_axil_araddr    <= 32'd0;
            m_axil_arvalid   <= 1'b0;
            m_axil_rready    <= 1'b0;
            read_req_valid   <= 1'b0;
            read_req_tag     <= 8'd0;
            read_req_id      <= 16'd0;
            read_req_lower_addr <= 7'd0;
            read_req_tc      <= 11'd0;
        end else begin
            case (state)
                IDLE: begin
                    s_axis_cq_tready <= 1'b1;
                    m_axil_awvalid   <= 1'b0;
                    m_axil_wvalid    <= 1'b0;
                    m_axil_arvalid   <= 1'b0;

                    if (s_axis_cq_tvalid && s_axis_cq_tready) begin
                        if (req_type == 4'b0001) begin // Memory Write
                            m_axil_awaddr  <= req_addr[31:0];
                            m_axil_awvalid <= 1'b1;
                            m_axil_wdata   <= req_payload;
                            m_axil_wvalid  <= 1'b1;
                            s_axis_cq_tready <= 1'b0;
                            state          <= WRITE_AXIL;
                        end else if (req_type == 4'b0000) begin // Memory Read
                            m_axil_araddr       <= req_addr[31:0];
                            m_axil_arvalid      <= 1'b1;
                            read_req_tag        <= req_tag;
                            read_req_id         <= req_id;
                            read_req_lower_addr <= req_addr[6:0];
                            read_req_tc         <= req_dword_len;
                            s_axis_cq_tready    <= 1'b0;
                            state               <= READ_AXIL;
                        end
                    end
                end

                WRITE_AXIL: begin
                    if (m_axil_awready) m_axil_awvalid <= 1'b0;
                    if (m_axil_wready)  m_axil_wvalid  <= 1'b0;

                    if ((!m_axil_awvalid || m_axil_awready) && (!m_axil_wvalid || m_axil_wready)) begin
                        m_axil_bready <= 1'b1;
                        state         <= WAIT_BRESP;
                    end
                end

                WAIT_BRESP: begin
                    if (m_axil_bvalid) begin
                        m_axil_bready    <= 1'b0;
                        s_axis_cq_tready <= 1'b1;
                        state            <= IDLE;
                    end
                end

                READ_AXIL: begin
                    if (m_axil_arready) begin
                        m_axil_arvalid <= 1'b0;
                        read_req_valid <= 1'b1;
                        state          <= WAIT_RRESP;
                    end
                end

                WAIT_RRESP: begin
                    if (read_req_ack) begin
                        read_req_valid   <= 1'b0;
                        s_axis_cq_tready <= 1'b1;
                        state            <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
