// ============================================================================
// Module: cc_tx_encoder
// Description: Encodes PCIe IP CC (Completer Completion) AXI4-Stream TLP packets.
//              Responds to Host MRd requests with Completion with Data (CplD).
// ============================================================================

`timescale 1ns / 1ps

module cc_tx_encoder #(
    parameter DATA_WIDTH = 256,
    parameter KEEP_WIDTH = DATA_WIDTH / 32,
    parameter [15:0] COMPLETER_ID = 16'h0001
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // CC AXI4-Stream Interface (User Logic -> PCIe IP)
    output reg  [DATA_WIDTH-1:0] m_axis_cc_tdata,
    output reg                   m_axis_cc_tvalid,
    output reg                   m_axis_cc_tlast,
    output reg  [32:0]           m_axis_cc_tuser,
    output reg  [KEEP_WIDTH-1:0] m_axis_cc_tkeep,
    input  wire                  m_axis_cc_tready,

    // Interface from CQ RX Decoder
    input  wire                  read_req_valid,
    input  wire [7:0]            read_req_tag,
    input  wire [15:0]           read_req_id,
    input  wire [6:0]            read_req_lower_addr,
    input  wire [10:0]           read_req_tc,
    output reg                   read_req_ack,

    // Interface from AXI4-Lite Slave (Read Response Data)
    input  wire [31:0]           axil_rdata,
    input  wire [1:0]            axil_rresp,
    input  wire                  axil_rvalid,
    output reg                   axil_rready
);

    localparam IDLE = 2'b00;
    localparam SEND_CPLD = 2'b01;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            m_axis_cc_tdata  <= {DATA_WIDTH{1'b0}};
            m_axis_cc_tvalid <= 1'b0;
            m_axis_cc_tlast  <= 1'b0;
            m_axis_cc_tuser  <= 33'd0;
            m_axis_cc_tkeep  <= {KEEP_WIDTH{1'b1}};
            axil_rready      <= 1'b0;
            read_req_ack     <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    read_req_ack     <= 1'b0;
                    m_axis_cc_tvalid <= 1'b0;
                    m_axis_cc_tlast  <= 1'b0;
                    axil_rready      <= 1'b1;

                    if (read_req_valid && axil_rvalid && axil_rready) begin
                        axil_rready      <= 1'b0;
                        m_axis_cc_tvalid <= 1'b1;
                        m_axis_cc_tlast  <= 1'b1;
                        m_axis_cc_tkeep  <= 8'h0F; // DW0-DW3 valid

                        // Build CplD TLP Header
                        // DW0: Lower Addr [6:0], Byte Count [28:16] (4 bytes), Status [11:9] (000 SC)
                        m_axis_cc_tdata[6:0]   <= read_req_lower_addr;
                        m_axis_cc_tdata[11:9]  <= (axil_rresp == 2'b00) ? 3'b000 : 3'b001; // SC or UR
                        m_axis_cc_tdata[28:16] <= 13'd4; // 1 DW payload = 4 bytes

                        // DW1: Dword Count [10:0], Tag [26:19], Requester ID [31:16] (shifted)
                        m_axis_cc_tdata[42:32] <= read_req_tc[10:0];
                        m_axis_cc_tdata[58:51] <= read_req_tag;
                        m_axis_cc_tdata[63:59] <= 5'd0;

                        // DW2: Completer ID [47:32], Requester ID [31:16]
                        m_axis_cc_tdata[79:64]  <= read_req_id;
                        m_axis_cc_tdata[95:80]  <= COMPLETER_ID;

                        // DW3 Payload: AXI-Lite Read Data
                        m_axis_cc_tdata[127:96] <= axil_rdata;

                        read_req_ack <= 1'b1;
                        state        <= SEND_CPLD;
                    end
                end

                SEND_CPLD: begin
                    if (m_axis_cc_tready) begin
                        m_axis_cc_tvalid <= 1'b0;
                        m_axis_cc_tlast  <= 1'b0;
                        read_req_ack     <= 1'b0;
                        state            <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
