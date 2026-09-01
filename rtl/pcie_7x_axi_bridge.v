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
    input  wire [127:0]          m_axis_rx_tdata,
    input  wire [15:0]           m_axis_rx_tkeep,
    input  wire                  m_axis_rx_tlast,
    input  wire                  m_axis_rx_tvalid,
    output reg                   m_axis_rx_tready,
    input  wire [21:0]           m_axis_rx_tuser,

    // ------------------------------------------------------------------------
    // 7-Series PCIe IP (pg054) 128-bit AXI-Stream TX Interface
    // ------------------------------------------------------------------------
    output reg  [127:0]          s_axis_tx_tdata,
    output reg  [15:0]           s_axis_tx_tkeep,
    output reg                   s_axis_tx_tlast,
    output reg                   s_axis_tx_tvalid,
    input  wire                  s_axis_tx_tready,
    output reg  [3:0]            s_axis_tx_tuser,

    // ------------------------------------------------------------------------
    // UltraScale/PCIe4 CQ Interface (Completer Request - to cq_rx_decoder)
    // ------------------------------------------------------------------------
    output reg  [DATA_WIDTH-1:0] m_axis_cq_tdata,
    output reg                   m_axis_cq_tvalid,
    output reg                   m_axis_cq_tlast,
    output reg  [87:0]           m_axis_cq_tuser,
    output reg  [KEEP_WIDTH-1:0] m_axis_cq_tkeep,
    input  wire                  m_axis_cq_tready,

    // ------------------------------------------------------------------------
    // UltraScale/PCIe4 CC Interface (Completer Completion - from cc_tx_encoder)
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] s_axis_cc_tdata,
    input  wire                  s_axis_cc_tvalid,
    input  wire                  s_axis_cc_tlast,
    input  wire [32:0]           s_axis_cc_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_cc_tkeep,
    output reg                   s_axis_cc_tready,

    // ------------------------------------------------------------------------
    // UltraScale/PCIe4 RQ Interface (Requester Request - from rq_tx_encoder)
    // ------------------------------------------------------------------------
    input  wire [DATA_WIDTH-1:0] s_axis_rq_tdata,
    input  wire                  s_axis_rq_tvalid,
    input  wire                  s_axis_rq_tlast,
    input  wire [61:0]           s_axis_rq_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_rq_tkeep,
    output reg                   s_axis_rq_tready,

    // ------------------------------------------------------------------------
    // UltraScale/PCIe4 RC Interface (Requester Completion - to rc_rx_decoder)
    // ------------------------------------------------------------------------
    output reg  [DATA_WIDTH-1:0] m_axis_rc_tdata,
    output reg                   m_axis_rc_tvalid,
    output reg                   m_axis_rc_tlast,
    output reg  [74:0]           m_axis_rc_tuser,
    output reg  [KEEP_WIDTH-1:0] m_axis_rc_tkeep,
    input  wire                  m_axis_rc_tready
);

    wire [15:0] compl_id = {cfg_bus_number, cfg_device_number, cfg_function_number};

    // pg054 places PCIe byte 0 on AXI bits [31:24]. Header fields are decoded
    // in their documented bit positions, but payload DWORDs must be byte-swapped
    // at the boundary so internal AXI-Lite/DMA values use normal little-endian
    // CPU numeric representation.
    function [31:0] payload_bswap32;
        input [31:0] value;
        begin
            payload_bswap32 = {value[7:0], value[15:8], value[23:16], value[31:24]};
        end
    endfunction

    function [127:0] payload_bswap128;
        input [127:0] value;
        begin
            payload_bswap128 = {
                payload_bswap32(value[127:96]), payload_bswap32(value[95:64]),
                payload_bswap32(value[63:32]), payload_bswap32(value[31:0])
            };
        end
    endfunction

    // -------------------------------------------------------------------------
    // 1. RX Path: 7-Series PCIe RX AXI-Stream -> UltraScale CQ / RC Interfaces
    // -------------------------------------------------------------------------

    // 7-Series RX Header Decode. An upper-QWORD SOF is completed with
    // the following lower QWORD before the common decoder consumes it.
    localparam RX_IDLE = 3'd0, RX_MWR4_BEAT1 = 3'd1,
               RX_PASS_RC = 3'd2, RX_ALIGN_UPPER = 3'd3,
               RX_SHIFT_RC = 3'd4, RX_FLUSH_RC = 3'd5;
    reg [2:0] rx_state;
    reg [63:0] reg_upper_header;
    reg [63:0] rc_carry_data;
    reg [7:0]  rc_carry_keep;
    wire [127:0] rx_data = (rx_state == RX_ALIGN_UPPER) ?
                            {m_axis_rx_tdata[63:0], reg_upper_header} :
                            m_axis_rx_tdata;
    wire [1:0]  rx_fmt       = rx_data[30:29];
    wire [4:0]  rx_type      = rx_data[28:24];
    wire [9:0]  rx_length    = rx_data[9:0];
    wire        rx_is_3dw    = (rx_fmt == 2'b00 || rx_fmt == 2'b10);
    wire        rx_is_4dw    = (rx_fmt == 2'b01 || rx_fmt == 2'b11);
    wire        rx_is_mrd    = (rx_type == 5'b00000 && (rx_fmt == 2'b00 || rx_fmt == 2'b01));
    wire        rx_is_mwr    = (rx_type == 5'b00000 && (rx_fmt == 2'b10 || rx_fmt == 2'b11));
    wire        rx_is_cpl    = (rx_type == 5'b01010);

    // The 128-bit 7-series RX interface reports packet boundaries in tuser;
    // tlast is tied low by the core. Keep tlast as a simulation fallback.
    wire [4:0]  rx_eof_info  = m_axis_rx_tuser[21:17];
    wire        rx_eof       = rx_eof_info[4] | m_axis_rx_tlast;
    wire        rx_sof_upper = m_axis_rx_tuser[14] && (m_axis_rx_tuser[13:10] == 4'd8);
    wire [15:0] rx_packet_keep = m_axis_rx_tlast ? m_axis_rx_tkeep :
                                 !rx_eof_info[4] ? 16'hFFFF :
                                 (rx_eof_info[3:0] == 4'd3)  ? 16'h000F :
                                 (rx_eof_info[3:0] == 4'd7)  ? 16'h00FF :
                                 (rx_eof_info[3:0] == 4'd11) ? 16'h0FFF : 16'hFFFF;

    function [127:0] keep_to_mask;
        input [15:0] keep;
        integer keep_idx;
        begin
            for (keep_idx = 0; keep_idx < 16; keep_idx = keep_idx + 1)
                keep_to_mask[(keep_idx*8) +: 8] = {8{keep[keep_idx]}};
        end
    endfunction
    wire [127:0] rx_packet_data = payload_bswap128(
        m_axis_rx_tdata & keep_to_mask(rx_packet_keep));
    wire [15:0] rc_shift_keep = {rx_packet_keep[7:0], rc_carry_keep};
    wire [127:0] rc_shift_data = payload_bswap128(
        {m_axis_rx_tdata[63:0], rc_carry_data} & keep_to_mask(rc_shift_keep));
    wire [15:0] rc_flush_keep = {8'd0, rc_carry_keep};
    wire [127:0] rc_flush_data = payload_bswap128(
        {64'd0, rc_carry_data} & keep_to_mask(rc_flush_keep));
    wire rx_eof_lower = rx_eof && (rx_eof_info[3:0] <= 4'd7);
    wire rx_eof_upper = rx_eof && (rx_eof_info[3:0] >= 4'd11);

    wire [15:0] rx_req_id    = rx_data[63:48];
    wire [7:0]  rx_tag       = rx_data[47:40];
    wire [31:0] rx_addr_lo   = rx_is_4dw ? rx_data[127:96] : rx_data[95:64];
    wire [31:0] rx_addr_hi   = rx_is_4dw ? rx_data[95:64]  : 32'h0;
    wire [63:0] rx_addr_64   = {rx_addr_hi, rx_addr_lo};
    wire [2:0]  rx_bar_id    = m_axis_rx_tuser[3] ? 3'b001 :
                               m_axis_rx_tuser[4] ? 3'b010 :
                               m_axis_rx_tuser[5] ? 3'b011 :
                               m_axis_rx_tuser[6] ? 3'b100 :
                               m_axis_rx_tuser[7] ? 3'b101 : 3'b000;

    // Physical Cpl/CplD header fields after pg054 AXI byte ordering.
    // DW1={CompleterID,Status,BCM,ByteCount}; DW2={RequesterID,Tag,R,LowerAddr}.
    wire [6:0]  rc_lower_addr = rx_data[70:64];
    wire [11:0] rc_byte_count = rx_data[43:32];
    wire [2:0]  rc_cpl_status = rx_data[47:45];
    wire [7:0]  rc_tag        = rx_data[79:72];
    wire [15:0] rc_req_id     = rx_data[95:80];

    reg [63:0] reg_mwr4_addr;
    reg [9:0]  reg_mwr4_length;
    reg [15:0] reg_mwr4_req_id;
    reg [7:0]  reg_mwr4_tag;
    reg [2:0]  reg_mwr4_bar_id;

    // Combinational RX Bridge Logic
    always @(*) begin
        m_axis_cq_tvalid = 1'b0;
        m_axis_cq_tlast  = 1'b0;
        m_axis_cq_tkeep  = {KEEP_WIDTH{1'b1}};
        m_axis_cq_tdata  = {DATA_WIDTH{1'b0}};
        m_axis_cq_tuser  = 88'd0;
        m_axis_rx_tready = 1'b0;

        m_axis_rc_tvalid = 1'b0;
        m_axis_rc_tlast  = 1'b0;
        m_axis_rc_tkeep  = {KEEP_WIDTH{1'b1}};
        m_axis_rc_tdata  = {DATA_WIDTH{1'b0}};
        m_axis_rc_tuser  = 75'd0;

        case (rx_state)
            RX_IDLE, RX_ALIGN_UPPER: begin
                if (m_axis_rx_tvalid) begin
                    if (rx_state == RX_IDLE && rx_sof_upper) begin
                        m_axis_rx_tready = 1'b1;
                    end else if (rx_is_mrd) begin // MRd (3-DW or 4-DW Memory Read)
                        m_axis_cq_tvalid = 1'b1;
                        m_axis_cq_tlast  = 1'b1;
                        m_axis_cq_tkeep  = {KEEP_WIDTH{1'b1}};
                        m_axis_cq_tuser  = {85'd0, rx_bar_id};
                        m_axis_cq_tdata  = {
                            {24'd0, rx_tag},              // [127:96]: Request tag
                            rx_req_id,                    // [95:80]: Requester ID
                            1'b0,                         // [79]
                            4'b0000,                      // [78:75]: ReqType (0000 = MRd)
                            1'b0, rx_length,              // [74:64]: Dword Length
                            rx_addr_64                    // [63:0]: 64-bit Target Address
                        };
                        m_axis_rx_tready = m_axis_cq_tready;
                    end else if (rx_is_mwr) begin
                        if (rx_state == RX_ALIGN_UPPER && rx_is_4dw && rx_length == 10'd1 && rx_eof) begin
                            // Header DW2/DW3 occupy the lower QWORD and the
                            // one-DWORD payload occupies raw AXI bits [95:64].
                            m_axis_cq_tvalid = 1'b1; m_axis_cq_tlast = 1'b1;
                            m_axis_cq_tkeep = {KEEP_WIDTH{1'b1}};
                            m_axis_cq_tuser = {85'd0, rx_bar_id};
                            m_axis_cq_tdata = {payload_bswap32(m_axis_rx_tdata[95:64]), rx_req_id,
                                1'b0, 4'b0001, 1'b0, rx_length, rx_addr_64};
                            m_axis_rx_tready = m_axis_cq_tready;
                        end else if (!rx_is_4dw) begin // 3-DW MWr: Payload data is at [127:96]
                            m_axis_cq_tvalid = 1'b1;
                            m_axis_cq_tlast  = 1'b1;
                            m_axis_cq_tkeep  = {KEEP_WIDTH{1'b1}};
                            m_axis_cq_tuser  = {85'd0, rx_bar_id};
                            m_axis_cq_tdata  = {
                                payload_bswap32(rx_data[127:96]), // [127:96]: Little-endian write payload
                                rx_req_id,                    // [95:80]: Requester ID
                                1'b0,                         // [79]
                                4'b0001,                      // [78:75]: ReqType (0001 = MWr)
                                1'b0, rx_length,              // [74:64]: Dword Length
                                rx_addr_64                    // [63:0]: 64-bit Target Address
                            };
                            m_axis_rx_tready = m_axis_cq_tready;
                        end else begin // 4-DW MWr: Beat 0 holds Address, Beat 1 holds Payload Data
                            m_axis_rx_tready = 1'b1; // Accept Beat 0 and latch fields
                        end
                    end else if (rx_is_cpl) begin
                        m_axis_rc_tvalid = 1'b1;
                        m_axis_rc_tlast  = (rx_state == RX_ALIGN_UPPER) ?
                                           rx_eof_lower : rx_eof;
                        m_axis_rc_tkeep  = (rx_state == RX_ALIGN_UPPER && rx_eof_info[4] &&
                                              rx_eof_info[3:0] == 4'd3) ? 16'h0FFF :
                                             (rx_state == RX_ALIGN_UPPER ? 16'hFFFF : rx_packet_keep);
                        m_axis_rc_tdata  = {
                            payload_bswap32(rx_data[127:96]), // [127:96]: Little-endian payload DW0
                            8'd0,                     // [95:88]: Reserved
                            rc_req_id,                // [87:72]: Requester ID (16 bits)
                            rc_tag,                   // [71:64]: Tag (8 bits)
                            18'd0,                    // [63:46]: Reserved
                            rc_cpl_status,            // [45:43]: Completion Status (3 bits)
                            1'b0, rx_length,          // [42:32]: Dword Count (11 bits)
                            3'b000,                   // [31:29]: Reserved
                            1'b0, rc_byte_count,      // [28:16]: Byte Count (13 bits)
                            4'd0,                     // [15:12]: Error Code (4 bits)
                            5'd0, rc_lower_addr       // [11:0]: Lower Address (12 bits)
                        };
                        m_axis_rx_tready = m_axis_rc_tready;
                    end
                end
            end

            RX_MWR4_BEAT1: begin // Beat 1 of 4-DW MWr: Payload data is at [31:0]
                if (m_axis_rx_tvalid) begin
                    m_axis_cq_tvalid = 1'b1;
                    m_axis_cq_tlast  = 1'b1;
                    m_axis_cq_tkeep  = {KEEP_WIDTH{1'b1}};
                    m_axis_cq_tuser  = {85'd0, reg_mwr4_bar_id};
                    m_axis_cq_tdata  = {
                        payload_bswap32(m_axis_rx_tdata[31:0]),       // [127:96]: Little-endian payload from Beat 1
                        reg_mwr4_req_id,                              // [95:80]: Requester ID
                        1'b0,                                         // [79]
                        4'b0001,                                      // [78:75]: ReqType (0001 = MWr)
                        1'b0, reg_mwr4_length,                        // [74:64]: Dword Length
                        reg_mwr4_addr                                 // [63:0]: 64-bit Target Address
                    };
                    m_axis_rx_tready = m_axis_cq_tready;
                end
            end

            RX_PASS_RC: begin
                m_axis_rc_tvalid = m_axis_rx_tvalid;
                m_axis_rc_tlast  = rx_eof;
                m_axis_rc_tkeep  = rx_packet_keep;
                // A following TLP can start in the upper QWORD of this same
                // physical beat. Mask it out of the current completion.
                m_axis_rc_tdata  = rx_packet_data;
                m_axis_rx_tready = m_axis_rc_tready;
            end

            RX_SHIFT_RC: begin
                m_axis_rc_tvalid = m_axis_rx_tvalid;
                m_axis_rc_tlast  = rx_eof_lower;
                m_axis_rc_tkeep  = rc_shift_keep;
                m_axis_rc_tdata  = rc_shift_data;
                m_axis_rx_tready = m_axis_rc_tready;
            end

            RX_FLUSH_RC: begin
                m_axis_rc_tvalid = 1'b1;
                m_axis_rc_tlast  = 1'b1;
                m_axis_rc_tkeep  = rc_flush_keep;
                m_axis_rc_tdata  = rc_flush_data;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state        <= RX_IDLE;
            reg_upper_header <= 64'd0;
            rc_carry_data   <= 64'd0;
            rc_carry_keep   <= 8'd0;
            reg_mwr4_addr   <= 64'd0;
            reg_mwr4_length <= 10'd0;
            reg_mwr4_req_id <= 16'd0;
            reg_mwr4_tag    <= 8'd0;
            reg_mwr4_bar_id <= 3'd0;
        end else begin
            case (rx_state)
                RX_IDLE: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        if (rx_sof_upper) begin
                            reg_upper_header <= m_axis_rx_tdata[127:64];
                            rx_state <= RX_ALIGN_UPPER;
                        end else if (rx_is_mwr && rx_is_4dw && !rx_eof) begin
                            reg_mwr4_addr   <= rx_addr_64;
                            reg_mwr4_length <= rx_length;
                            reg_mwr4_req_id <= rx_req_id;
                            reg_mwr4_tag    <= rx_tag;
                            reg_mwr4_bar_id <= rx_bar_id;
                            rx_state        <= RX_MWR4_BEAT1;
                        end else if (rx_is_cpl && !rx_eof) begin
                            rx_state        <= RX_PASS_RC;
                        end
                    end
                end

                RX_ALIGN_UPPER: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        if (rx_is_mwr && rx_is_4dw && !rx_eof) begin
                            reg_mwr4_addr <= rx_addr_64;
                            reg_mwr4_length <= rx_length;
                            reg_mwr4_req_id <= rx_req_id;
                            reg_mwr4_tag <= rx_tag;
                            reg_mwr4_bar_id <= rx_bar_id;
                            rx_state <= RX_MWR4_BEAT1;
                        end else if (rx_is_cpl && !rx_eof) begin
                            rc_carry_data <= m_axis_rx_tdata[127:64];
                            rc_carry_keep <= 8'hFF;
                            rx_state <= RX_SHIFT_RC;
                        end else if (rx_is_cpl && rx_eof_upper) begin
                            rc_carry_data <= m_axis_rx_tdata[127:64];
                            rc_carry_keep <= rx_packet_keep[15:8];
                            rx_state <= RX_FLUSH_RC;
                        end else if (rx_sof_upper) begin
                            // The aligned packet ended in the lower QWORD and
                            // another packet begins in this beat's upper QWORD.
                            reg_upper_header <= m_axis_rx_tdata[127:64];
                            rx_state <= RX_ALIGN_UPPER;
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end
                end

                RX_MWR4_BEAT1: begin
                    if (m_axis_rx_tvalid && m_axis_cq_tready) begin
                        if (rx_sof_upper) begin
                            reg_upper_header <= m_axis_rx_tdata[127:64];
                            rx_state <= RX_ALIGN_UPPER;
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end
                end

                RX_PASS_RC: begin
                    if (m_axis_rx_tvalid && m_axis_rc_tready && rx_eof) begin
                        if (rx_sof_upper) begin
                            reg_upper_header <= m_axis_rx_tdata[127:64];
                            rx_state <= RX_ALIGN_UPPER;
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end
                end


                RX_SHIFT_RC: begin
                    if (m_axis_rx_tvalid && m_axis_rc_tready) begin
                        if (!rx_eof) begin
                            rc_carry_data <= m_axis_rx_tdata[127:64];
                            rc_carry_keep <= 8'hFF;
                        end else if (rx_eof_upper) begin
                            rc_carry_data <= m_axis_rx_tdata[127:64];
                            rc_carry_keep <= rx_packet_keep[15:8];
                            rx_state <= RX_FLUSH_RC;
                        end else if (rx_sof_upper) begin
                            rc_carry_keep <= 8'd0;
                            reg_upper_header <= m_axis_rx_tdata[127:64];
                            rx_state <= RX_ALIGN_UPPER;
                        end else begin
                            rc_carry_keep <= 8'd0;
                            rx_state <= RX_IDLE;
                        end
                    end
                end

                RX_FLUSH_RC: begin
                    if (m_axis_rc_tready) begin
                        rc_carry_keep <= 8'd0;
                        rx_state <= RX_IDLE;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // 2. TX Path: CC / RQ -> 7-Series TX Protocol Translator
    // =========================================================================
    // CC Header Extraction (Matches UltraScale CC Encoder Format from cc_tx_encoder.v)
    wire [6:0]  cc_lower_addr  = s_axis_cc_tdata[6:0];
    wire [9:0]  cc_dword_len   = s_axis_cc_tdata[41:32];
    wire [7:0]  cc_tag         = s_axis_cc_tdata[58:51];
    wire [15:0] cc_req_id      = s_axis_cc_tdata[79:64];
    wire [15:0] cc_compl_id    = (s_axis_cc_tdata[95:80] != 16'd0) ? s_axis_cc_tdata[95:80] : compl_id;
    wire [31:0] cc_reg_rdata   = s_axis_cc_tdata[127:96];

    // CC CplD DW0..DW3 Definition (pg054 Table 2-8: 128-bit beat)
    wire [31:0] tx_cpld_dw0 = {1'b0, 2'b10, 5'b01010, 1'b0, 3'b000, 4'b0000, 2'b00, 2'b00, 2'b00, cc_dword_len};
    wire [31:0] tx_cpld_dw1 = {cc_compl_id, 3'b000, 1'b0, 12'd4};
    wire [31:0] tx_cpld_dw2 = {cc_req_id, cc_tag, 1'b0, cc_lower_addr};
    wire [31:0] tx_cpld_dw3 = payload_bswap32(cc_reg_rdata);

    // Decoding RQ Descriptor
    wire [63:0] rq_target_addr = s_axis_rq_tdata[63:0];
    wire [9:0]  rq_dword_len   = s_axis_rq_tdata[73:64];
    wire [3:0]  rq_req_type    = s_axis_rq_tdata[78:75];
    wire [15:0] rq_req_id      = compl_id;
    wire [7:0]  rq_tag         = s_axis_rq_tdata[103:96];
    wire        rq_is_mwr      = (rq_req_type == 4'b0001);
    wire        rq_is_4dw      = 1'b1; // Always use standard 4-DW (64-bit Address) TLPs for all DMA transactions

    // RQ MRd / MWr DW0 Definitions (pg054 Table 2-8: 128-bit beat)
    wire [31:0] tx_mrd3_dw0 = {1'b0, 2'b00, 5'b00000, 1'b0, 3'b000, 4'b0000, 2'b00, 2'b00, 2'b00, rq_dword_len};
    wire [31:0] tx_mwr3_dw0 = {1'b0, 2'b10, 5'b00000, 1'b0, 3'b000, 4'b0000, 2'b00, 2'b00, 2'b00, rq_dword_len};
    wire [31:0] tx_mrd4_dw0 = {1'b0, 2'b01, 5'b00000, 1'b0, 3'b000, 4'b0000, 2'b00, 2'b00, 2'b00, rq_dword_len};
    wire [31:0] tx_mwr4_dw0 = {1'b0, 2'b11, 5'b00000, 1'b0, 3'b000, 4'b0000, 2'b00, 2'b00, 2'b00, rq_dword_len};
    wire [31:0] tx_rq_dw1   = {rq_req_id, rq_tag, 4'hF, 4'hF};

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
                    s_axis_tx_tdata  = {tx_cpld_dw3, tx_cpld_dw2, tx_cpld_dw1, tx_cpld_dw0};
                end
                // RQ Priority (DMA Memory Reads / Writes to Host RAM)
                else if (s_axis_rq_tvalid) begin
                    s_axis_rq_tready = s_axis_tx_tready;
                    s_axis_tx_tvalid = 1'b1;
                    s_axis_tx_tkeep  = 16'hFFFF;

                    if (!rq_is_mwr) begin // MRd: Always 1 beat on TX (Headers fit in 128-bit beat)
                        s_axis_tx_tlast = 1'b1;
                    end else if (!rq_is_4dw) begin // 3-DW MWr
                        s_axis_tx_tlast = s_axis_rq_tlast;
                    end else begin // 4-DW MWr
                        s_axis_tx_tlast = 1'b0;
                    end

                    if (!rq_is_4dw) begin // 3-DW TLP
                        s_axis_tx_tdata = {
                            (rq_is_mwr ? payload_bswap32(s_axis_rq_tdata[127:96]) : 32'd0), // DW3 payload
                            rq_target_addr[31:0],                         // DW2: 32-bit Address
                            tx_rq_dw1,                                    // DW1: ReqID + Tag + BE
                            (rq_is_mwr ? tx_mwr3_dw0 : tx_mrd3_dw0)       // DW0: Header
                        };
                    end else begin // 4-DW TLP
                        s_axis_tx_tdata = {
                            rq_target_addr[31:0],                         // DW3: Addr Low
                            rq_target_addr[63:32],                        // DW2: Addr High
                            tx_rq_dw1,                                    // DW1: ReqID + Tag + BE
                            (rq_is_mwr ? tx_mwr4_dw0 : tx_mrd4_dw0)       // DW0: Header
                        };
                    end
                end
            end

            TX_PASS_RQ: begin
                s_axis_rq_tready = s_axis_tx_tready;
                s_axis_tx_tvalid = s_axis_rq_tvalid;
                s_axis_tx_tlast  = s_axis_rq_tlast;
                s_axis_tx_tkeep  = 16'hFFFF;
                s_axis_tx_tdata  = payload_bswap128(s_axis_rq_tdata[127:0]);
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    if (!s_axis_cc_tvalid && s_axis_rq_tvalid && s_axis_tx_tready && !s_axis_tx_tlast) begin
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
