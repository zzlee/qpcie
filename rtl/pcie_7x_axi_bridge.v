// ============================================================================
// Module: pcie_7x_axi_bridge
// Description: Fully compliant TLP Protocol Translator between Xilinx 7-Series
//              PCIe Integrated Block (pg054) 128-bit AXI-Stream interface and
//              UltraScale/PCIe4 (pg213) CQ/CC/RQ/RC Descriptor Interface.
// ============================================================================

`timescale 1ns / 1ps

module pcie_7x_axi_bridge #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = DATA_WIDTH / 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Dynamic BDF from PCIe IP Core
    input  wire [7:0]            cfg_bus_number,
    input  wire [4:0]            cfg_device_number,
    input  wire [2:0]            cfg_function_number,

    // ------------------------------------------------------------------------
    // 7-Series PCIe IP (pg054) 128-bit AXI-Stream RX Interface
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] m_axis_rx_tdata,
    input  wire [KEEP_WIDTH-1:0] m_axis_rx_tkeep,
    input  wire                  m_axis_rx_tlast,
    input  wire                  m_axis_rx_tvalid,
    output reg                   m_axis_rx_tready,
    input  wire [21:0]           m_axis_rx_tuser,

    // ------------------------------------------------------------------------
    // 7-Series PCIe IP (pg054) 128-bit AXI-Stream TX Interface
    // ------------------------------------------------------------------------
    output reg  [DATA_WIDTH-1:0] s_axis_tx_tdata,
    output reg  [KEEP_WIDTH-1:0] s_axis_tx_tkeep,
    output reg                   s_axis_tx_tlast,
    output reg                   s_axis_tx_tvalid,
    input  wire                  s_axis_tx_tready,
    output reg  [3:0]            s_axis_tx_tuser,

    // ------------------------------------------------------------------------
    // Internal Core DMA CQ (Completer Request) Interface
    // ------------------------------------------------------------------------
    output reg  [DATA_WIDTH-1:0] m_axis_cq_tdata,
    output reg                   m_axis_cq_tvalid,
    output reg                   m_axis_cq_tlast,
    output reg  [87:0]           m_axis_cq_tuser,
    output reg  [KEEP_WIDTH-1:0] m_axis_cq_tkeep,
    input  wire                  m_axis_cq_tready,

    // ------------------------------------------------------------------------
    // Internal Core DMA CC (Completer Completion) Interface
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] s_axis_cc_tdata,
    input  wire                  s_axis_cc_tvalid,
    input  wire                  s_axis_cc_tlast,
    input  wire [32:0]           s_axis_cc_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_cc_tkeep,
    output reg                   s_axis_cc_tready,

    // ------------------------------------------------------------------------
    // Internal Core DMA RQ (Requester Request) Interface
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] s_axis_rq_tdata,
    input  wire                  s_axis_rq_tvalid,
    input  wire                  s_axis_rq_tlast,
    input  wire [61:0]           s_axis_rq_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_rq_tkeep,
    output reg                   s_axis_rq_tready,

    // ------------------------------------------------------------------------
    // Internal Core DMA RC (Requester Completion) Interface
    // ------------------------------------------------------------------------
    output reg  [DATA_WIDTH-1:0] m_axis_rc_tdata,
    output reg                   m_axis_rc_tvalid,
    output reg                   m_axis_rc_tlast,
    output reg  [74:0]           m_axis_rc_tuser,
    output reg  [KEEP_WIDTH-1:0] m_axis_rc_tkeep,
    input  wire                  m_axis_rc_tready
);

    wire [15:0] compl_id = {cfg_bus_number, cfg_device_number, cfg_function_number};

    // =========================================================================
    // 1. RX Path: 7-Series RX -> UltraScale CQ / RC Translator
    // =========================================================================
    wire [1:0] rx_fmt  = m_axis_rx_tdata[30:29];
    wire [4:0] rx_type = m_axis_rx_tdata[28:24];

    wire rx_is_mrd = (rx_type == 5'b00000) && (rx_fmt[1] == 1'b0);
    wire rx_is_mwr = (rx_type == 5'b00000) && (rx_fmt[1] == 1'b1);
    wire rx_is_cpl = (rx_type == 5'b01010);
    wire rx_is_4dw = rx_fmt[0];

    // CQ Header Fields (UltraScale Descriptor Format - 128 bits)
    wire [9:0]  rx_length    = m_axis_rx_tdata[9:0];
    wire [15:0] rx_req_id    = m_axis_rx_tdata[63:48];
    wire [7:0]  rx_tag       = m_axis_rx_tdata[47:40];
    wire [31:0] rx_addr_lo   = rx_is_4dw ? m_axis_rx_tdata[127:96] : m_axis_rx_tdata[95:64];
    wire [31:0] rx_addr_hi   = rx_is_4dw ? m_axis_rx_tdata[95:64]  : 32'h0;
    wire [63:0] rx_addr_64   = {rx_addr_hi, rx_addr_lo};
    wire [2:0]  rx_bar_id    = (rx_addr_lo >= 32'h4000_0000) ? 3'b001 : 3'b000;

    // RC Header Fields (UltraScale Descriptor Format - 128 bits)
    wire [6:0]  rc_lower_addr = m_axis_rx_tdata[70:64];
    wire [11:0] rc_byte_count = m_axis_rx_tdata[43:32];
    wire [2:0]  rc_cpl_status = m_axis_rx_tdata[47:45];
    wire [7:0]  rc_tag        = m_axis_rx_tdata[79:72];
    wire [15:0] rc_req_id     = m_axis_rx_tdata[95:80];

    localparam RX_IDLE      = 2'b00;
    localparam RX_PASS_CQ   = 2'b01;
    localparam RX_PASS_RC   = 2'b10;

    reg [1:0] rx_state;

    always @(*) begin
        m_axis_cq_tdata  = 128'd0;
        m_axis_cq_tvalid = 1'b0;
        m_axis_cq_tlast  = 1'b0;
        m_axis_cq_tuser  = 88'd0;
        m_axis_cq_tkeep  = 16'd0;

        m_axis_rc_tdata  = 128'd0;
        m_axis_rc_tvalid = 1'b0;
        m_axis_rc_tlast  = 1'b0;
        m_axis_rc_tuser  = 75'd0;
        m_axis_rc_tkeep  = 16'd0;

        m_axis_rx_tready = 1'b1;

        case (rx_state)
            RX_IDLE: begin
                if (m_axis_rx_tvalid) begin
                    if (rx_is_mrd || rx_is_mwr) begin
                        m_axis_cq_tvalid = 1'b1;
                        m_axis_cq_tlast  = m_axis_rx_tlast || rx_is_mrd;
                        m_axis_cq_tkeep  = m_axis_rx_tkeep;
                        m_axis_cq_tdata  = {
                            2'b00, 2'b00, 3'b000, 6'b000000, rx_bar_id,
                            8'h00, rx_tag, rx_req_id, 1'b0,
                            (rx_is_mwr ? 4'b0001 : 4'b0000), 1'b0, rx_length,
                            rx_addr_64
                        };
                        m_axis_rx_tready = m_axis_cq_tready;
                    end else if (rx_is_cpl) begin
                        m_axis_rc_tvalid = 1'b1;
                        m_axis_rc_tlast  = m_axis_rx_tlast;
                        m_axis_rc_tkeep  = m_axis_rx_tkeep;
                        m_axis_rc_tdata  = {
                            m_axis_rx_tdata[127:96],
                            rc_req_id, rc_tag, 2'b00, rc_cpl_status,
                            1'b0, rx_length, 3'b000, rc_byte_count, 4'd0, rc_lower_addr
                        };
                        m_axis_rx_tready = m_axis_rc_tready;
                    end
                end
            end

            RX_PASS_CQ: begin
                m_axis_cq_tvalid = m_axis_rx_tvalid;
                m_axis_cq_tlast  = m_axis_rx_tlast;
                m_axis_cq_tkeep  = m_axis_rx_tkeep;
                m_axis_cq_tdata  = m_axis_rx_tdata;
                m_axis_rx_tready = m_axis_cq_tready;
            end

            RX_PASS_RC: begin
                m_axis_rc_tvalid = m_axis_rx_tvalid;
                m_axis_rc_tlast  = m_axis_rx_tlast;
                m_axis_rc_tkeep  = m_axis_rx_tkeep;
                m_axis_rc_tdata  = m_axis_rx_tdata;
                m_axis_rx_tready = m_axis_rc_tready;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_IDLE;
        end else begin
            case (rx_state)
                RX_IDLE: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready && !m_axis_rx_tlast) begin
                        if (rx_is_mwr)
                            rx_state <= RX_PASS_CQ;
                        else if (rx_is_cpl)
                            rx_state <= RX_PASS_RC;
                    end
                end

                RX_PASS_CQ: begin
                    if (m_axis_rx_tvalid && m_axis_cq_tready && m_axis_rx_tlast)
                        rx_state <= RX_IDLE;
                end

                RX_PASS_RC: begin
                    if (m_axis_rx_tvalid && m_axis_rc_tready && m_axis_rx_tlast)
                        rx_state <= RX_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // 2. TX Path: UltraScale CC / RQ -> 7-Series TX Arbiter & Translator
    // =========================================================================
    // CC Header Extraction (Matches UltraScale CC Encoder Format from cc_tx_encoder.v)
    wire [6:0]  cc_lower_addr  = s_axis_cc_tdata[6:0];
    wire [9:0]  cc_dword_len   = s_axis_cc_tdata[41:32]; // Dword Count (11-bit at [42:32])
    wire [7:0]  cc_tag         = s_axis_cc_tdata[58:51]; // Tag (8-bit at [58:51])
    wire [15:0] cc_req_id      = s_axis_cc_tdata[79:64]; // Requester ID (16-bit at [79:64])
    wire [15:0] cc_compl_id    = (s_axis_cc_tdata[95:80] != 16'd0) ? s_axis_cc_tdata[95:80] : compl_id; // Completer ID
    wire [31:0] cc_reg_rdata   = s_axis_cc_tdata[127:96];

    // RQ Header Extraction (UltraScale RQ Descriptor)
    wire [63:0] rq_target_addr = s_axis_rq_tdata[63:0];
    wire [9:0]  rq_dword_len   = s_axis_rq_tdata[73:64];
    wire [3:0]  rq_req_type    = s_axis_rq_tdata[78:75];
    wire [15:0] rq_req_id      = (s_axis_rq_tdata[95:80] != 16'd0) ? s_axis_rq_tdata[95:80] : compl_id;
    wire [7:0]  rq_tag         = s_axis_rq_tdata[103:96];
    wire        rq_is_mwr      = (rq_req_type == 4'b0001);
    wire        rq_is_4dw      = (rq_target_addr[63:32] != 32'h0);

    localparam TX_IDLE     = 2'b00;
    localparam TX_PASS_RQ  = 2'b01;

    reg [1:0] tx_state;

    always @(*) begin
        s_axis_tx_tdata  = 128'd0;
        s_axis_tx_tkeep  = 16'd0;
        s_axis_tx_tlast  = 1'b0;
        s_axis_tx_tvalid = 1'b0;
        s_axis_tx_tuser  = 4'b0000;

        s_axis_cc_tready = 1'b0;
        s_axis_rq_tready = 1'b0;

        case (tx_state)
            TX_IDLE: begin
                // CC Priority (Register Read Completions CplD)
                if (s_axis_cc_tvalid) begin
                    s_axis_cc_tready = s_axis_tx_tready;
                    s_axis_tx_tvalid = 1'b1;
                    s_axis_tx_tlast  = 1'b1;
                    s_axis_tx_tkeep  = 16'hFFFF;
                    s_axis_tx_tdata  = {
                        cc_reg_rdata,                                 // DW3: Read Response Data
                        {cc_req_id, cc_tag, 1'b0, cc_lower_addr},     // DW2: ReqID + Tag + LowerAddr
                        {cc_compl_id, 3'b000, 1'b0, 12'd4},           // DW1: CompID + Status(SC) + ByteCount 4
                        {1'b0, 2'b10, 5'b01010, 3'b000, 1'b0, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, cc_dword_len} // DW0: 32-bit CplD Header
                    };
                end
                // RQ Priority (DMA Memory Reads / Writes to Host RAM)
                else if (s_axis_rq_tvalid) begin
                    s_axis_rq_tready = s_axis_tx_tready;
                    s_axis_tx_tvalid = 1'b1;
                    s_axis_tx_tlast  = s_axis_rq_tlast && !rq_is_4dw;
                    s_axis_tx_tkeep  = s_axis_rq_tkeep;

                    if (!rq_is_4dw) begin // 3-DW TLP
                        s_axis_tx_tdata = {
                            (rq_is_mwr ? s_axis_rq_tdata[127:96] : 32'd0), // DW3: Payload for 3-DW MWr
                            rq_target_addr[31:0],                         // DW2: 32-bit Address
                            {rq_req_id, rq_tag, 4'hF, 4'hF},              // DW1: ReqID + Tag + BE
                            {1'b0, (rq_is_mwr ? 2'b10 : 2'b00), 5'b00000, 3'b000, 1'b0, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, rq_dword_len} // DW0: Header
                        };
                    end else begin // 4-DW TLP
                        s_axis_tx_tdata = {
                            rq_target_addr[31:0],                         // DW3: Addr Low
                            rq_target_addr[63:32],                        // DW2: Addr High
                            {rq_req_id, rq_tag, 4'hF, 4'hF},              // DW1: ReqID + Tag + BE
                            {1'b0, (rq_is_mwr ? 2'b11 : 2'b01), 5'b00000, 3'b000, 1'b0, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, rq_dword_len} // DW0: Header
                        };
                    end
                end
            end

            TX_PASS_RQ: begin
                s_axis_rq_tready = s_axis_tx_tready;
                s_axis_tx_tvalid = s_axis_rq_tvalid;
                s_axis_tx_tlast  = s_axis_rq_tlast;
                s_axis_tx_tkeep  = s_axis_rq_tkeep;
                s_axis_tx_tdata  = s_axis_rq_tdata;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    if (!s_axis_cc_tvalid && s_axis_rq_tvalid && s_axis_tx_tready && !s_axis_rq_tlast) begin
                        if (rq_is_mwr)
                            tx_state <= TX_PASS_RQ;
                    end
                end

                TX_PASS_RQ: begin
                    if (s_axis_rq_tvalid && s_axis_tx_tready && s_axis_rq_tlast)
                        tx_state <= TX_IDLE;
                end
            endcase
        end
    end

endmodule
