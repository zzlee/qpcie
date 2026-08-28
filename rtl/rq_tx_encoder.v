// ============================================================================
// Module: rq_tx_encoder
// Description: Arbitrates and packages requester MRd/MWr/Msg transactions.
//              Priority: IRQ > Desc Fetch > SG Table Fetch > H2C Read > C2H Write.
//              A C2H MWr uses one 4-DW header beat followed by an arbitrary
//              number of streaming payload beats.  The source keeps the
//              request metadata valid until c2h_req_ack and advances payload
//              data only when c2h_req_data_ready is asserted.
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
    input wire sg_req_valid, input wire [63:0] sg_req_addr,
    input wire [10:0] sg_req_dw_len, input wire [7:0] sg_req_tag, output reg sg_req_ack,
    input wire h2c_req_valid, input wire [63:0] h2c_req_addr,
    input wire [10:0] h2c_req_dw_len, input wire [7:0] h2c_req_tag, output reg h2c_req_ack,
    input wire c2h_req_valid, input wire [63:0] c2h_req_addr,
    input wire [10:0] c2h_req_dw_len, input wire [DATA_WIDTH-1:0] c2h_req_data,
    input wire c2h_req_last, output wire c2h_req_data_ready,
    output reg c2h_req_ack
);
    localparam IDLE = 3'd0, SEND_IRQ = 3'd1, SEND_DESC = 3'd2,
               SEND_H2C = 3'd3, SEND_MWR_HEADER = 3'd4,
               SEND_MWR_DATA = 3'd5, SEND_SG = 3'd6;
    localparam integer DATA_DWORDS = DATA_WIDTH / 32;

    reg [2:0] state;
    reg [10:0] c2h_dw_remaining;
    wire [10:0] first_payload_dw =
        (c2h_req_dw_len > DATA_DWORDS) ? DATA_DWORDS : c2h_req_dw_len;
    wire [10:0] next_payload_dw =
        (c2h_dw_remaining > DATA_DWORDS) ? DATA_DWORDS : c2h_dw_remaining;

    assign c2h_req_data_ready =
        (state == SEND_MWR_HEADER && m_axis_rq_tvalid && m_axis_rq_tready) ||
        (state == SEND_MWR_DATA && m_axis_rq_tvalid && m_axis_rq_tready &&
         c2h_dw_remaining != 0);

    function [KEEP_WIDTH-1:0] payload_keep;
        input [10:0] valid_dw;
        integer byte_idx;
        begin
            payload_keep = {KEEP_WIDTH{1'b0}};
            for (byte_idx = 0; byte_idx < KEEP_WIDTH; byte_idx = byte_idx + 1)
                if (byte_idx < (valid_dw * 4))
                    payload_keep[byte_idx] = 1'b1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            m_axis_rq_tdata <= {DATA_WIDTH{1'b0}};
            m_axis_rq_tvalid <= 1'b0;
            m_axis_rq_tlast <= 1'b0;
            m_axis_rq_tuser <= 62'd0;
            m_axis_rq_tkeep <= {KEEP_WIDTH{1'b1}};
            irq_req_ack <= 1'b0;
            desc_req_ack <= 1'b0;
            sg_req_ack <= 1'b0;
            h2c_req_ack <= 1'b0;
            c2h_req_ack <= 1'b0;
            c2h_dw_remaining <= 11'd0;
        end else begin
            irq_req_ack <= 1'b0;
            desc_req_ack <= 1'b0;
            sg_req_ack <= 1'b0;
            h2c_req_ack <= 1'b0;
            c2h_req_ack <= 1'b0;

            case (state)
                IDLE: begin
                    m_axis_rq_tvalid <= 1'b0;
                    m_axis_rq_tlast <= 1'b0;
                    m_axis_rq_tdata <= {DATA_WIDTH{1'b0}};
                    m_axis_rq_tuser <= 62'd0;
                    if (irq_req_valid && !irq_req_ack) begin
                        m_axis_rq_tdata[74:64] <= 11'd0;
                        m_axis_rq_tdata[78:75] <= 4'b0010;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[127:120] <= irq_req_code;
                        m_axis_rq_tkeep <= {{(KEEP_WIDTH-4){1'b0}}, 4'hF};
                        m_axis_rq_tlast <= 1'b1;
                        m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_IRQ;
                    end else if (desc_req_valid && !desc_req_ack) begin
                        m_axis_rq_tdata[63:0] <= desc_req_addr;
                        m_axis_rq_tdata[74:64] <= desc_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0000;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96] <= desc_req_tag;
                        m_axis_rq_tkeep <= {{(KEEP_WIDTH-4){1'b0}}, 4'hF};
                        m_axis_rq_tlast <= 1'b1;
                        m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_DESC;
                    end else if (sg_req_valid && !sg_req_ack) begin
                        m_axis_rq_tdata[63:0] <= sg_req_addr;
                        m_axis_rq_tdata[74:64] <= sg_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0000;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96] <= sg_req_tag;
                        m_axis_rq_tkeep <= {{(KEEP_WIDTH-4){1'b0}}, 4'hF};
                        m_axis_rq_tlast <= 1'b1;
                        m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_SG;
                    end else if (h2c_req_valid && !h2c_req_ack) begin
                        m_axis_rq_tdata[63:0] <= h2c_req_addr;
                        m_axis_rq_tdata[74:64] <= h2c_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0000;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96] <= h2c_req_tag;
                        m_axis_rq_tkeep <= {{(KEEP_WIDTH-4){1'b0}}, 4'hF};
                        m_axis_rq_tlast <= 1'b1;
                        m_axis_rq_tvalid <= 1'b1;
                        state <= SEND_H2C;
                    end else if (c2h_req_valid && !c2h_req_ack &&
                                 c2h_req_dw_len != 0) begin
                        m_axis_rq_tdata[63:0] <= c2h_req_addr;
                        m_axis_rq_tdata[74:64] <= c2h_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0001;
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96] <= 8'd0;
                        m_axis_rq_tkeep <= {KEEP_WIDTH{1'b1}};
                        m_axis_rq_tlast <= 1'b0;
                        m_axis_rq_tvalid <= 1'b1;
                        c2h_dw_remaining <= c2h_req_dw_len;
                        state <= SEND_MWR_HEADER;
                    end
                end

                SEND_IRQ: begin
                    if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                        irq_req_ack <= 1'b1;
                        m_axis_rq_tvalid <= 1'b0;
                        m_axis_rq_tlast <= 1'b0;
                        state <= IDLE;
                    end
                end

                SEND_DESC: begin
                    if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                        desc_req_ack <= 1'b1;
                        m_axis_rq_tvalid <= 1'b0;
                        m_axis_rq_tlast <= 1'b0;
                        state <= IDLE;
                    end
                end

                SEND_SG: begin
                    if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                        sg_req_ack <= 1'b1;
                        m_axis_rq_tvalid <= 1'b0;
                        m_axis_rq_tlast <= 1'b0;
                        state <= IDLE;
                    end
                end

                SEND_H2C: begin
                    if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                        h2c_req_ack <= 1'b1;
                        m_axis_rq_tvalid <= 1'b0;
                        m_axis_rq_tlast <= 1'b0;
                        state <= IDLE;
                    end
                end

                SEND_MWR_HEADER: begin
                    if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                        m_axis_rq_tdata <= c2h_req_data;
                        m_axis_rq_tuser <= 62'd0;
                        m_axis_rq_tkeep <= payload_keep(first_payload_dw);
                        m_axis_rq_tlast <= (c2h_req_dw_len <= DATA_DWORDS);
                        m_axis_rq_tvalid <= 1'b1;
                        c2h_dw_remaining <= c2h_req_dw_len - first_payload_dw;
                        state <= SEND_MWR_DATA;
                    end
                end

                SEND_MWR_DATA: begin
                    if (m_axis_rq_tvalid && m_axis_rq_tready) begin
                        if (c2h_dw_remaining == 0) begin
                            c2h_req_ack <= 1'b1;
                            m_axis_rq_tvalid <= 1'b0;
                            m_axis_rq_tlast <= 1'b0;
                            state <= IDLE;
                        end else begin
                            m_axis_rq_tdata <= c2h_req_data;
                            m_axis_rq_tkeep <= payload_keep(next_payload_dw);
                            m_axis_rq_tlast <= (c2h_dw_remaining <= DATA_DWORDS);
                            c2h_dw_remaining <= c2h_dw_remaining - next_payload_dw;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    wire unused_c2h_req_last = c2h_req_last;

endmodule
