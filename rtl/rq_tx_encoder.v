// ============================================================================
// Module: rq_tx_encoder
// Description: Arbitrates and packages requester MRd/MWr/Msg transactions.
//              In 128-bit mode a 4-DW MWr is always emitted as a header beat
//              followed by one payload beat; source acknowledgement occurs only
//              after the payload beat is accepted.
// ============================================================================
`timescale 1ns / 1ps

module rq_tx_encoder #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = DATA_WIDTH / 8,
    parameter [15:0] REQUESTER_ID = 16'h0001
)(
    input wire clk, input wire rst_n,
    output reg [DATA_WIDTH-1:0] m_axis_rq_tdata,
    output reg m_axis_rq_tvalid, output reg m_axis_rq_tlast,
    output reg [61:0] m_axis_rq_tuser,
    output reg [KEEP_WIDTH-1:0] m_axis_rq_tkeep,
    input wire m_axis_rq_tready,
    input wire irq_req_valid, input wire [7:0] irq_req_code, output reg irq_req_ack,
    input wire desc_req_valid, input wire [63:0] desc_req_addr,
    input wire [10:0] desc_req_dw_len, input wire [7:0] desc_req_tag, output reg desc_req_ack,
    input wire h2c_req_valid, input wire [63:0] h2c_req_addr,
    input wire [10:0] h2c_req_dw_len, input wire [7:0] h2c_req_tag, output reg h2c_req_ack,
    input wire c2h_req_valid, input wire [63:0] c2h_req_addr,
    input wire [10:0] c2h_req_dw_len, input wire [DATA_WIDTH-1:0] c2h_req_data,
    input wire c2h_req_last, output reg c2h_req_ack
);
    localparam IDLE = 3'd0, SEND_IRQ = 3'd1, SEND_DESC = 3'd2,
               SEND_H2C = 3'd3, SEND_MWR_HEADER = 3'd4, SEND_MWR_DATA = 3'd5;
    reg [2:0] state;
    reg [63:0] c2h_addr_q;
    reg [10:0] c2h_len_q;
    reg [DATA_WIDTH-1:0] c2h_data_q;
    reg c2h_last_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            m_axis_rq_tdata <= {DATA_WIDTH{1'b0}};
            m_axis_rq_tvalid <= 1'b0;
            m_axis_rq_tlast <= 1'b0;
            m_axis_rq_tuser <= 62'd0;
            m_axis_rq_tkeep <= {KEEP_WIDTH{1'b1}};
            irq_req_ack <= 1'b0; desc_req_ack <= 1'b0;
            h2c_req_ack <= 1'b0; c2h_req_ack <= 1'b0;
            c2h_addr_q <= 64'd0; c2h_len_q <= 11'd0;
            c2h_data_q <= {DATA_WIDTH{1'b0}}; c2h_last_q <= 1'b0;
        end else begin
            irq_req_ack <= 1'b0; desc_req_ack <= 1'b0;
            h2c_req_ack <= 1'b0; c2h_req_ack <= 1'b0;
            case (state)
                IDLE: begin
                    m_axis_rq_tvalid <= 1'b0;
                    m_axis_rq_tlast <= 1'b0;
                    m_axis_rq_tdata <= {DATA_WIDTH{1'b0}};
                    if (irq_req_valid && !irq_req_ack) begin
                        m_axis_rq_tdata[74:64] <= 11'd0;
                        m_axis_rq_tdata[78:75] <= 4'b0010;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[127:120] <= irq_req_code;
                        m_axis_rq_tkeep <= {{(KEEP_WIDTH-4){1'b0}}, 4'hF};
                        m_axis_rq_tlast <= 1'b1; m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_IRQ;
                    end else if (desc_req_valid && !desc_req_ack) begin
                        m_axis_rq_tdata[63:0] <= desc_req_addr;
                        m_axis_rq_tdata[74:64] <= desc_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0000;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96] <= desc_req_tag;
                        m_axis_rq_tkeep <= {{(KEEP_WIDTH-4){1'b0}}, 4'hF};
                        m_axis_rq_tlast <= 1'b1; m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_DESC;
                    end else if (h2c_req_valid && !h2c_req_ack) begin
                        m_axis_rq_tdata[63:0] <= h2c_req_addr;
                        m_axis_rq_tdata[74:64] <= h2c_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0000;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96] <= h2c_req_tag;
                        m_axis_rq_tkeep <= {{(KEEP_WIDTH-4){1'b0}}, 4'hF};
                        m_axis_rq_tlast <= 1'b1; m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_H2C;
                    end else if (c2h_req_valid && !c2h_req_ack) begin
                        c2h_addr_q <= c2h_req_addr; c2h_len_q <= c2h_req_dw_len;
                        c2h_data_q <= c2h_req_data; c2h_last_q <= c2h_req_last;
                        m_axis_rq_tdata[63:0] <= c2h_req_addr;
                        m_axis_rq_tdata[74:64] <= c2h_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0001;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96] <= 8'd0;
                        m_axis_rq_tkeep <= {KEEP_WIDTH{1'b1}};
                        if (DATA_WIDTH >= 256) begin
                            m_axis_rq_tdata[255:128] <= c2h_req_data[127:0];
                            m_axis_rq_tlast <= c2h_req_last;
                        end else begin
                            m_axis_rq_tlast <= 1'b0;
                        end
                        m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_MWR_HEADER;
                    end
                end
                SEND_IRQ: if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                    irq_req_ack <= 1'b1; m_axis_rq_tvalid <= 1'b0; state <= IDLE;
                end
                SEND_DESC: if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                    desc_req_ack <= 1'b1; m_axis_rq_tvalid <= 1'b0; state <= IDLE;
                end
                SEND_H2C: if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                    h2c_req_ack <= 1'b1; m_axis_rq_tvalid <= 1'b0; state <= IDLE;
                end
                SEND_MWR_HEADER: if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                    if (DATA_WIDTH >= 256) begin
                        c2h_req_ack <= 1'b1; m_axis_rq_tvalid <= 1'b0; state <= IDLE;
                    end else begin
                        m_axis_rq_tdata <= c2h_data_q;
                        m_axis_rq_tkeep <= {KEEP_WIDTH{1'b1}};
                        m_axis_rq_tlast <= 1'b1;
                        m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_MWR_DATA;
                    end
                end
                SEND_MWR_DATA: if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                    c2h_req_ack <= 1'b1; m_axis_rq_tvalid <= 1'b0; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
