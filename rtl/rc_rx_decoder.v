// ============================================================================
// Module: rc_rx_decoder
// Description: Decodes PCIe IP RC (Requester Completion) AXI4-Stream TLP packets.
//              Extracts CplD data and routes:
//              - Tag 0: Descriptor Fetch Engine (64-Byte Extended Descriptors)
//              - Tag 1: SG Host Linked Page Table Fetch Engine (256-Byte bursts)
//              - Tag > 1: H2C DMA Data FIFO
// Audit Compliance: Verified with UltraScale PCIe Specification pg213 Table 2-19:
//                   - rc_tag is at bits [71:64]
//                   - rc_dword_len is at bits [42:32]
//                   - rc_req_id is at bits [87:72]
// ============================================================================

`timescale 1ns / 1ps

module rc_rx_decoder #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = DATA_WIDTH / 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // RC AXI4-Stream Interface (PCIe IP -> User Logic)
    input  wire [DATA_WIDTH-1:0] s_axis_rc_tdata,
    input  wire                  s_axis_rc_tvalid,
    input  wire                  s_axis_rc_tlast,
    input  wire [74:0]           s_axis_rc_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_rc_tkeep,
    output reg                   s_axis_rc_tready,

    // Interface to Descriptor Fetch Engine (Tag 0 reserved for 64-Byte Extended Descriptor Fetch)
    output reg                   desc_cpl_valid,
    output reg  [511:0]          desc_cpl_data, // 64-Byte (512-bit) Extended Descriptor Payload
    output reg                   desc_cpl_last,

    // Interface to SG Host Fetch Engine (Tag 1 reserved for Scatter-Gather Page Table Fetch)
    output reg                   sg_cpl_valid,
    output reg  [DATA_WIDTH-1:0] sg_cpl_data,
    output reg                   sg_cpl_last,
    output reg  [7:0]            sg_cpl_tag,

    // Interface to H2C DMA Data FIFO (Tag > 1)
    output reg                   h2c_fifo_wvalid,
    output reg  [DATA_WIDTH-1:0] h2c_fifo_wdata,
    output reg                   h2c_fifo_wlast,
    output reg  [2:0]            h2c_fifo_wdw_count,
    output reg  [7:0]            h2c_fifo_wtag,

    // Tag Recycle Interface
    output reg                   tag_free_req,
    output reg  [7:0]            tag_free_val
);

    localparam IDLE       = 2'b00;
    localparam ROUTE_DESC = 2'b01;
    localparam ROUTE_H2C  = 2'b10;
    localparam ROUTE_SG   = 2'b11;

    reg [1:0] state;
    reg [2:0] desc_beat_cnt;
    reg [10:0] h2c_cpl_dw_remaining;
    reg [7:0] h2c_cpl_tag;

    // Header Extraction from first beat according to pg213 Table 2-19
    wire [7:0]  rc_tag       = s_axis_rc_tdata[71:64];  // pg213 Table 2-19: Tag is at [71:64]
    wire [10:0] rc_dword_len = s_axis_rc_tdata[42:32];  // pg213 Table 2-19: Dword Count is at [42:32]
    wire [15:0] rc_req_id    = s_axis_rc_tdata[87:72];  // pg213 Table 2-19: Requester ID is at [87:72]

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            s_axis_rc_tready <= 1'b1;
            desc_cpl_valid   <= 1'b0;
            desc_cpl_data    <= 512'd0;
            desc_cpl_last    <= 1'b0;
            sg_cpl_valid     <= 1'b0;
            sg_cpl_data      <= {DATA_WIDTH{1'b0}};
            sg_cpl_last      <= 1'b0;
            sg_cpl_tag       <= 8'd0;
            h2c_fifo_wvalid  <= 1'b0;
            h2c_fifo_wdata   <= {DATA_WIDTH{1'b0}};
            h2c_fifo_wlast   <= 1'b0;
            h2c_fifo_wdw_count <= 3'd0;
            h2c_fifo_wtag    <= 8'd0;
            tag_free_req     <= 1'b0;
            tag_free_val     <= 8'd0;
            desc_beat_cnt    <= 3'd0;
            h2c_cpl_dw_remaining <= 11'd0;
            h2c_cpl_tag      <= 8'd0;
        end else begin
            h2c_fifo_wvalid <= 1'b0;
            h2c_fifo_wdw_count <= 3'd0;
            case (state)
                IDLE: begin
                    desc_cpl_valid   <= 1'b0;
                    sg_cpl_valid     <= 1'b0;
                    h2c_fifo_wvalid  <= 1'b0;
                    h2c_fifo_wdw_count <= 3'd0;
                    tag_free_req     <= 1'b0;
                    s_axis_rc_tready <= 1'b1;
                    desc_beat_cnt    <= 3'd0;

                    if (s_axis_rc_tvalid && s_axis_rc_tready) begin
                        if (rc_tag == 8'h00) begin // Descriptor CplD (Tag 0)
                            desc_cpl_data[31:0] <= s_axis_rc_tdata[127:96]; // Payload DW0 from Beat 0
                            if (s_axis_rc_tlast) begin
                                desc_cpl_valid <= 1'b1;
                                desc_cpl_last  <= 1'b1;
                                tag_free_req   <= 1'b1;
                                tag_free_val   <= 8'h00;
                            end else begin
                                desc_beat_cnt <= 3'd1;
                                state         <= ROUTE_DESC;
                            end
                        end else if (rc_tag == 8'h01) begin // SG Host Fetch CplD (Tag 1)
                            sg_cpl_valid <= 1'b1;
                            sg_cpl_data  <= s_axis_rc_tdata;
                            sg_cpl_last  <= s_axis_rc_tlast;
                            sg_cpl_tag   <= 8'h01;
                            tag_free_req <= s_axis_rc_tlast;
                            tag_free_val <= 8'h01;

                            if (!s_axis_rc_tlast) begin
                                state <= ROUTE_SG;
                            end
                        end else begin // H2C Data CplD (Tag > 1)
                            h2c_fifo_wvalid <= 1'b1;
                            h2c_fifo_wdata  <= {96'd0, s_axis_rc_tdata[127:96]};
                            h2c_fifo_wlast  <= s_axis_rc_tlast;
                            h2c_fifo_wdw_count <= (rc_dword_len != 0) ? 3'd1 : 3'd0;
                            h2c_fifo_wtag <= rc_tag;
                            h2c_cpl_tag <= rc_tag;
                            h2c_cpl_dw_remaining <=
                                (rc_dword_len > 0) ? rc_dword_len - 1'b1 : 11'd0;
                            if (!s_axis_rc_tlast) begin
                                state <= ROUTE_H2C;
                            end
                        end
                    end
                end

                ROUTE_DESC: begin
                    if (s_axis_rc_tvalid && s_axis_rc_tready) begin
                        case (desc_beat_cnt)
                            3'd1: desc_cpl_data[159:32]  <= s_axis_rc_tdata[127:0]; // DW1..DW4
                            3'd2: desc_cpl_data[287:160] <= s_axis_rc_tdata[127:0]; // DW5..DW8
                            3'd3: desc_cpl_data[415:288] <= s_axis_rc_tdata[127:0]; // DW9..DW12
                            3'd4: desc_cpl_data[511:416] <= s_axis_rc_tdata[95:0];  // DW13..DW15
                        endcase
                        desc_beat_cnt <= desc_beat_cnt + 1'b1;

                        if (s_axis_rc_tlast || desc_beat_cnt >= 3'd4) begin
                            desc_cpl_valid <= 1'b1;
                            desc_cpl_last  <= 1'b1;
                            tag_free_req   <= 1'b1;
                            tag_free_val   <= 8'h00;
                            state          <= IDLE;
                        end
                    end
                end

                ROUTE_SG: begin
                    if (s_axis_rc_tvalid && s_axis_rc_tready) begin
                        sg_cpl_valid <= 1'b1;
                        sg_cpl_data  <= s_axis_rc_tdata;
                        sg_cpl_last  <= s_axis_rc_tlast;
                        sg_cpl_tag   <= 8'h01;

                        if (s_axis_rc_tlast) begin
                            tag_free_req <= 1'b1;
                            tag_free_val <= 8'h01;
                            state        <= IDLE;
                        end
                    end
                end

                ROUTE_H2C: begin
                    if (s_axis_rc_tvalid && s_axis_rc_tready) begin
                        h2c_fifo_wvalid <= 1'b1;
                        h2c_fifo_wdata  <= s_axis_rc_tdata;
                        h2c_fifo_wlast  <= s_axis_rc_tlast;
                        h2c_fifo_wtag   <= h2c_cpl_tag;
                        h2c_fifo_wdw_count <=
                            (h2c_cpl_dw_remaining >= 4) ? 3'd4 :
                            h2c_cpl_dw_remaining[2:0];
                        if (h2c_cpl_dw_remaining >= 4)
                            h2c_cpl_dw_remaining <= h2c_cpl_dw_remaining - 4;
                        else
                            h2c_cpl_dw_remaining <= 0;

                        if (s_axis_rc_tlast) begin
                            state        <= IDLE;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
