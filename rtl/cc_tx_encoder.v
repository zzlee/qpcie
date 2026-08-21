// ============================================================================
// Module: cc_tx_encoder
// Description: Encodes PCIe IP CC (Completer Completion with Data CplD) AXI4-Stream TLP.
//              Supports BAR0 and BAR1 read completion multiplexing.
// ============================================================================

`timescale 1ns / 1ps

module cc_tx_encoder #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = DATA_WIDTH / 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // CC AXI4-Stream Interface (DMA Top -> PCIe IP)
    output reg  [DATA_WIDTH-1:0] m_axis_cc_tdata,
    output reg                   m_axis_cc_tvalid,
    output reg                   m_axis_cc_tlast,
    output reg  [32:0]           m_axis_cc_tuser,
    output reg  [KEEP_WIDTH-1:0] m_axis_cc_tkeep,
    input  wire                  m_axis_cc_tready,

    // Read Request Tracking from CQ RX Decoder
    input  wire                  read_req_valid,
    input  wire [7:0]            read_req_tag,
    input  wire [15:0]           read_req_id,
    input  wire [6:0]            read_req_lower_addr,
    input  wire [10:0]           read_req_tc,
    input  wire                  read_req_bar_sel, // 0: BAR0, 1: BAR1
    output reg                   read_req_ack,

    // BAR0 AXI4-Lite Read Data Channel
    input  wire [31:0]           bar0_axil_rdata,
    input  wire [1:0]            bar0_axil_rresp,
    input  wire                  bar0_axil_rvalid,
    output reg                   bar0_axil_rready,

    // BAR1 AXI4-Lite Read Data Channel (User IP Cores Interconnect)
    input  wire [31:0]           bar1_axil_rdata,
    input  wire [1:0]            bar1_axil_rresp,
    input  wire                  bar1_axil_rvalid,
    output reg                   bar1_axil_rready
);

    localparam IDLE      = 2'b00;
    localparam WAIT_RDATA= 2'b01;
    localparam SEND_CC   = 2'b10;

    reg [1:0]  state;
    reg [7:0]  req_tag_q;
    reg [15:0] req_id_q;
    reg [6:0]  req_lower_addr_q;
    reg        req_bar_sel_q;
    reg [31:0] rdata_captured;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            m_axis_cc_tdata  <= {DATA_WIDTH{1'b0}};
            m_axis_cc_tvalid <= 1'b0;
            m_axis_cc_tlast  <= 1'b0;
            m_axis_cc_tuser  <= 33'd0;
            m_axis_cc_tkeep  <= 8'h0F; // 4 DWs (Header 3 DWs + Data 1 DW)
            read_req_ack     <= 1'b0;
            bar0_axil_rready <= 1'b1;
            bar1_axil_rready <= 1'b1;
            req_tag_q        <= 8'd0;
            req_id_q         <= 16'd0;
            req_lower_addr_q <= 7'd0;
            req_bar_sel_q    <= 1'b0;
            rdata_captured   <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    m_axis_cc_tvalid <= 1'b0;
                    read_req_ack     <= 1'b0;

                    if (read_req_valid) begin
                        req_tag_q        <= read_req_tag;
                        req_id_q         <= read_req_id;
                        req_lower_addr_q <= read_req_lower_addr;
                        req_bar_sel_q    <= read_req_bar_sel;
                        read_req_ack     <= 1'b1;
                        state            <= WAIT_RDATA;
                    end
                end

                WAIT_RDATA: begin
                    read_req_ack <= 1'b0;
                    if (req_bar_sel_q ? bar1_axil_rvalid : bar0_axil_rvalid) begin
                        rdata_captured <= req_bar_sel_q ? bar1_axil_rdata : bar0_axil_rdata;

                        // Build 256-bit CC TLP Frame
                        m_axis_cc_tdata         <= {DATA_WIDTH{1'b0}};
                        m_axis_cc_tdata[6:0]    <= req_lower_addr_q;  // Lower Address
                        m_axis_cc_tdata[11:9]   <= 3'b000;            // Error Code (Successful Completion)
                        m_axis_cc_tdata[28:16]  <= 13'd4;             // Byte Count (4 Bytes = 1 DW)
                        m_axis_cc_tdata[42:32]  <= 11'd1;             // Dword Count (1 DW)
                        m_axis_cc_tdata[46:44]  <= 3'b000;            // Completion Status: Successful
                        m_axis_cc_tdata[58:51]  <= req_tag_q;         // Tag
                        m_axis_cc_tdata[79:64]  <= req_id_q;          // Requester ID
                        m_axis_cc_tdata[95:80]  <= 16'h0100;          // Completer ID
                        m_axis_cc_tdata[127:96] <= req_bar_sel_q ? bar1_axil_rdata : bar0_axil_rdata; // CplD Data

                        m_axis_cc_tkeep         <= 8'h0F;             // First 4 DWs valid
                        m_axis_cc_tlast         <= 1'b1;
                        m_axis_cc_tvalid        <= 1'b1;
                        state                   <= SEND_CC;
                    end
                end

                SEND_CC: begin
                    if (m_axis_cc_tready) begin
                        m_axis_cc_tvalid <= 1'b0;
                        state            <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
