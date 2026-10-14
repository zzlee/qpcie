// ============================================================================
// Module: rq_tx_encoder
// Description: Arbitrates and packages requester MRd/MWr/Msg transactions.
//              Priority: IRQ > Desc Fetch > SG Table Fetch > H2C Read > C2H Write.
//              Supports both:
//              - 128-bit AXI4-Stream interface (7-Series / A50T)
//              - 256-bit AXI4-Stream interface in DWORD_Aligned mode (UltraScale+ / ZU4EV)
// ============================================================================
`timescale 1ns / 1ps

module rq_tx_encoder #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = (DATA_WIDTH == 256) ? 8 : (DATA_WIDTH / 8),
    parameter [15:0] REQUESTER_ID = 16'h0001
)(
    input wire clk, input wire rst_n,
    input wire [15:0] requester_id,
    output wire [DATA_WIDTH-1:0] m_axis_rq_tdata,
    output wire m_axis_rq_tvalid, output wire m_axis_rq_tlast,
    output wire [61:0] m_axis_rq_tuser,
    output wire [KEEP_WIDTH-1:0] m_axis_rq_tkeep,
    input wire m_axis_rq_tready,
    input wire irq_req_valid, input wire [7:0] irq_req_code, output wire irq_req_ack,
    input wire desc_req_valid, input wire [63:0] desc_req_addr,
    input wire [10:0] desc_req_dw_len, input wire [7:0] desc_req_tag, output wire desc_req_ack,
    input wire sg_req_valid, input wire [63:0] sg_req_addr,
    input wire [10:0] sg_req_dw_len, input wire [7:0] sg_req_tag, output wire sg_req_ack,
    input wire h2c_req_valid, input wire [63:0] h2c_req_addr,
    input wire [10:0] h2c_req_dw_len, input wire [7:0] h2c_req_tag, output wire h2c_req_ack,
    input wire c2h_req_valid, input wire [63:0] c2h_req_addr,
    input wire [10:0] c2h_req_dw_len, input wire [DATA_WIDTH-1:0] c2h_req_data,
    input wire c2h_req_last, output wire c2h_req_data_ready,
    output wire c2h_req_ack
);
    wire unused_c2h_req_last = c2h_req_last;
    wire [15:0] active_requester_id = (requester_id != 16'd0) ? requester_id : REQUESTER_ID;
    wire [3:0] desc_last_be = (desc_req_dw_len > 11'd1) ? 4'hF : 4'h0;
    wire [3:0] sg_last_be   = (sg_req_dw_len > 11'd1)   ? 4'hF : 4'h0;
    wire [3:0] h2c_last_be  = (h2c_req_dw_len > 11'd1)  ? 4'hF : 4'h0;
    wire [3:0] c2h_last_be  = (c2h_req_dw_len > 11'd1)  ? 4'hF : 4'h0;

    generate
        if (DATA_WIDTH == 256) begin : gen_256b
            localparam S_IDLE      = 3'd0,
                       S_SEND_IRQ  = 3'd1,
                       S_SEND_DESC = 3'd2,
                       S_SEND_SG   = 3'd3,
                       S_SEND_H2C  = 3'd4,
                       S_MWR_BURST = 3'd5;

            reg [2:0] state;
            reg [DATA_WIDTH-1:0] rq_tdata;
            reg rq_tvalid;
            reg rq_tlast;
            reg [61:0] rq_tuser;
            reg [KEEP_WIDTH-1:0] rq_tkeep;
            reg irq_ack, desc_ack, sg_ack, h2c_ack, c2h_ack;

            reg [127:0] hold_hi;
            reg [3:0]   rq_beats_left;

            assign m_axis_rq_tdata  = rq_tdata;
            assign m_axis_rq_tvalid = rq_tvalid;
            assign m_axis_rq_tlast  = rq_tlast;
            assign m_axis_rq_tuser  = rq_tuser;
            assign m_axis_rq_tkeep  = rq_tkeep;
            assign irq_req_ack      = irq_ack;
            assign desc_req_ack     = desc_ack;
            assign sg_req_ack       = sg_ack;
            assign h2c_req_ack      = h2c_ack;
            assign c2h_req_ack      = c2h_ack;

            wire c2h_req_active = c2h_req_valid && !c2h_ack &&
                                  !irq_req_valid && !desc_req_valid &&
                                  !sg_req_valid && !h2c_req_valid;

            assign c2h_req_data_ready =
                (state == S_IDLE && c2h_req_active) ||
                (state == S_MWR_BURST && m_axis_rq_tready && rq_beats_left > 4'd1);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    state         <= S_IDLE;
                    rq_tdata      <= {DATA_WIDTH{1'b0}};
                    rq_tvalid     <= 1'b0;
                    rq_tlast      <= 1'b0;
                    rq_tuser      <= 62'd0;
                    rq_tkeep      <= {KEEP_WIDTH{1'b1}};
                    irq_ack       <= 1'b0;
                    desc_ack      <= 1'b0;
                    sg_ack        <= 1'b0;
                    h2c_ack       <= 1'b0;
                    c2h_ack       <= 1'b0;
                    hold_hi       <= 128'd0;
                    rq_beats_left <= 4'd0;
                end else begin
                    irq_ack  <= 1'b0;
                    desc_ack <= 1'b0;
                    sg_ack   <= 1'b0;
                    h2c_ack  <= 1'b0;
                    c2h_ack  <= 1'b0;

                    case (state)
                        S_IDLE: begin
                            rq_tvalid <= 1'b0;
                            rq_tlast  <= 1'b0;
                            rq_tdata  <= {DATA_WIDTH{1'b0}};
                            rq_tuser  <= 62'd0;

                            if (irq_req_valid && !irq_req_ack) begin
                                rq_tdata[74:64]   <= 11'd0;
                                rq_tdata[78:75]   <= 4'b0010;
                                rq_tdata[95:80]   <= active_requester_id;
                                rq_tdata[127:120] <= irq_req_code;
                                rq_tuser          <= {54'd0, 4'h0, 4'hF};
                                rq_tkeep          <= {KEEP_WIDTH{1'b1}};
                                rq_tlast          <= 1'b1;
                                rq_tvalid         <= 1'b1;
                                state             <= S_SEND_IRQ;
                            end else if (desc_req_valid && !desc_req_ack) begin
                                rq_tdata[63:0]   <= desc_req_addr;
                                rq_tdata[74:64]  <= desc_req_dw_len;
                                rq_tdata[78:75]  <= 4'b0000;
                                rq_tdata[95:80]  <= active_requester_id;
                                rq_tdata[103:96] <= desc_req_tag;
                                rq_tuser         <= {54'd0, desc_last_be, 4'hF};
                                rq_tkeep         <= {KEEP_WIDTH{1'b1}};
                                rq_tlast         <= 1'b1;
                                rq_tvalid        <= 1'b1;
                                state            <= S_SEND_DESC;
                            end else if (sg_req_valid && !sg_req_ack) begin
                                rq_tdata[63:0]   <= sg_req_addr;
                                rq_tdata[74:64]  <= sg_req_dw_len;
                                rq_tdata[78:75]  <= 4'b0000;
                                rq_tdata[95:80]  <= active_requester_id;
                                rq_tdata[103:96] <= sg_req_tag;
                                rq_tuser         <= {54'd0, sg_last_be, 4'hF};
                                rq_tkeep         <= {KEEP_WIDTH{1'b1}};
                                rq_tlast         <= 1'b1;
                                rq_tvalid        <= 1'b1;
                                state            <= S_SEND_SG;
                            end else if (h2c_req_valid && !h2c_req_ack) begin
                                rq_tdata[63:0]   <= h2c_req_addr;
                                rq_tdata[74:64]  <= h2c_req_dw_len;
                                rq_tdata[78:75]  <= 4'b0000;
                                rq_tdata[95:80]  <= active_requester_id;
                                rq_tdata[103:96] <= h2c_req_tag;
                                rq_tuser         <= {54'd0, h2c_last_be, 4'hF};
                                rq_tkeep         <= {KEEP_WIDTH{1'b1}};
                                rq_tlast         <= 1'b1;
                                rq_tvalid        <= 1'b1;
                                state            <= S_SEND_H2C;
                            end else if (c2h_req_valid && !c2h_req_ack && c2h_req_dw_len != 0) begin
                                rq_tdata[63:0]    <= c2h_req_addr;
                                rq_tdata[74:64]   <= c2h_req_dw_len;
                                rq_tdata[78:75]   <= 4'b0001; // MWr
                                rq_tdata[95:80]   <= active_requester_id;
                                rq_tdata[103:96]  <= 8'd0;
                                rq_tdata[127:104] <= 24'd0;
                                rq_tdata[255:128] <= c2h_req_data[127:0];
                                rq_tuser          <= {54'd0, c2h_last_be, 4'hF};
                                rq_tvalid         <= 1'b1;

                                if (c2h_req_dw_len <= 11'd4) begin
                                    rq_tkeep      <= (c2h_req_dw_len == 1) ? 8'h1F :
                                                     (c2h_req_dw_len == 2) ? 8'h3F :
                                                     (c2h_req_dw_len == 3) ? 8'h7F : 8'hFF;
                                    rq_tlast      <= 1'b1;
                                    rq_beats_left <= 4'd0;
                                end else begin
                                    rq_tkeep      <= 8'hFF;
                                    rq_tlast      <= 1'b0;
                                    rq_beats_left <= (c2h_req_dw_len == 11'd64) ? 4'd8 :
                                                     (c2h_req_dw_len == 11'd32) ? 4'd4 :
                                                     ((c2h_req_dw_len - 11'd4 + 11'd7) / 8);
                                    hold_hi       <= c2h_req_data[255:128];
                                end
                                state <= S_MWR_BURST;
                            end
                        end

                        S_SEND_IRQ: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                irq_ack   <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast  <= 1'b0;
                                state     <= S_IDLE;
                            end
                        end

                        S_SEND_DESC: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                desc_ack  <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast  <= 1'b0;
                                state     <= S_IDLE;
                            end
                        end

                        S_SEND_SG: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                sg_ack    <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast  <= 1'b0;
                                state     <= S_IDLE;
                            end
                        end

                        S_SEND_H2C: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                h2c_ack   <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast  <= 1'b0;
                                state     <= S_IDLE;
                            end
                        end

                        S_MWR_BURST: begin
                            if (m_axis_rq_tready) begin
                                if (rq_beats_left == 4'd0) begin
                                    c2h_ack   <= 1'b1;
                                    rq_tvalid <= 1'b0;
                                    rq_tlast  <= 1'b0;
                                    state     <= S_IDLE;
                                end else if (rq_beats_left == 4'd1) begin
                                    rq_tdata      <= {{128{1'b0}}, hold_hi};
                                    rq_tuser      <= 62'd0;
                                    rq_tkeep      <= 8'h0F;
                                    rq_tlast      <= 1'b1;
                                    rq_tvalid     <= 1'b1;
                                    rq_beats_left <= 4'd0;
                                end else begin
                                    rq_tdata      <= {c2h_req_data[127:0], hold_hi};
                                    rq_tuser      <= 62'd0;
                                    hold_hi       <= c2h_req_data[255:128];
                                    rq_tkeep      <= 8'hFF;
                                    rq_tlast      <= 1'b0;
                                    rq_tvalid     <= 1'b1;
                                    rq_beats_left <= rq_beats_left - 1'b1;
                                end
                            end
                        end

                        default: state <= S_IDLE;
                    endcase
                end
            end
        end else begin : gen_128b
            localparam IDLE = 3'd0, SEND_IRQ = 3'd1, SEND_DESC = 3'd2,
                       SEND_H2C = 3'd3, SEND_MWR_HEADER = 3'd4,
                       SEND_MWR_DATA = 3'd5, SEND_SG = 3'd6;
            localparam integer DATA_DWORDS = DATA_WIDTH / 32;

            reg [2:0] state;
            reg [DATA_WIDTH-1:0] rq_tdata;
            reg rq_tvalid;
            reg rq_tlast;
            reg [61:0] rq_tuser;
            reg [KEEP_WIDTH-1:0] rq_tkeep;
            reg irq_ack, desc_ack, sg_ack, h2c_ack, c2h_ack;

            reg [10:0] c2h_dw_remaining;
            wire [10:0] first_payload_dw =
                (c2h_req_dw_len > DATA_DWORDS) ? DATA_DWORDS : c2h_req_dw_len;
            wire [10:0] next_payload_dw =
                (c2h_dw_remaining > DATA_DWORDS) ? DATA_DWORDS : c2h_dw_remaining;

            assign c2h_req_data_ready =
                (state == SEND_MWR_HEADER && rq_tvalid && m_axis_rq_tready) ||
                (state == SEND_MWR_DATA && rq_tvalid && m_axis_rq_tready &&
                 c2h_dw_remaining != 0);

            assign m_axis_rq_tdata    = rq_tdata;
            assign m_axis_rq_tvalid   = rq_tvalid;
            assign m_axis_rq_tlast    = rq_tlast;
            assign m_axis_rq_tuser    = rq_tuser;
            assign m_axis_rq_tkeep    = rq_tkeep;
            assign irq_req_ack        = irq_ack;
            assign desc_req_ack       = desc_ack;
            assign sg_req_ack         = sg_ack;
            assign h2c_req_ack        = h2c_ack;
            assign c2h_req_ack        = c2h_ack;

            function [KEEP_WIDTH-1:0] payload_keep;
                input [10:0] valid_dw;
                integer idx;
                begin
                    payload_keep = {KEEP_WIDTH{1'b0}};
                    for (idx = 0; idx < KEEP_WIDTH; idx = idx + 1) begin
                        if (KEEP_WIDTH == DATA_WIDTH / 8) begin
                            if (idx < (valid_dw * 4))
                                payload_keep[idx] = 1'b1;
                        end else begin
                            if (idx < valid_dw)
                                payload_keep[idx] = 1'b1;
                        end
                    end
                end
            endfunction

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    state <= IDLE;
                    rq_tdata <= {DATA_WIDTH{1'b0}};
                    rq_tvalid <= 1'b0;
                    rq_tlast <= 1'b0;
                    rq_tuser <= 62'd0;
                    rq_tkeep <= {KEEP_WIDTH{1'b1}};
                    irq_ack <= 1'b0;
                    desc_ack <= 1'b0;
                    sg_ack <= 1'b0;
                    h2c_ack <= 1'b0;
                    c2h_ack <= 1'b0;
                    c2h_dw_remaining <= 11'd0;
                end else begin
                    irq_ack <= 1'b0;
                    desc_ack <= 1'b0;
                    sg_ack <= 1'b0;
                    h2c_ack <= 1'b0;
                    c2h_ack <= 1'b0;

                    case (state)
                        IDLE: begin
                            rq_tvalid <= 1'b0;
                            rq_tlast <= 1'b0;
                            rq_tdata <= {DATA_WIDTH{1'b0}};
                            rq_tuser <= 62'd0;
                            if (irq_req_valid && !irq_req_ack) begin
                                rq_tdata[74:64] <= 11'd0;
                                rq_tdata[78:75] <= 4'b0010;
                                rq_tdata[95:80] <= active_requester_id;
                                rq_tdata[127:120] <= irq_req_code;
                                rq_tuser <= {54'd0, 4'h0, 4'hF};
                                rq_tkeep <= {KEEP_WIDTH{1'b1}};
                                rq_tlast <= 1'b1;
                                rq_tvalid <= 1'b1;
                                state <= SEND_IRQ;
                            end else if (desc_req_valid && !desc_req_ack) begin
                                rq_tdata[63:0] <= desc_req_addr;
                                rq_tdata[74:64] <= desc_req_dw_len;
                                rq_tdata[78:75] <= 4'b0000;
                                rq_tdata[95:80] <= active_requester_id;
                                rq_tdata[103:96] <= desc_req_tag;
                                rq_tuser <= {54'd0, desc_last_be, 4'hF};
                                rq_tkeep <= {KEEP_WIDTH{1'b1}};
                                rq_tlast <= 1'b1;
                                rq_tvalid <= 1'b1;
                                state <= SEND_DESC;
                            end else if (sg_req_valid && !sg_req_ack) begin
                                rq_tdata[63:0] <= sg_req_addr;
                                rq_tdata[74:64] <= sg_req_dw_len;
                                rq_tdata[78:75] <= 4'b0000;
                                rq_tdata[95:80] <= active_requester_id;
                                rq_tdata[103:96] <= sg_req_tag;
                                rq_tuser <= {54'd0, sg_last_be, 4'hF};
                                rq_tkeep <= {KEEP_WIDTH{1'b1}};
                                rq_tlast <= 1'b1;
                                rq_tvalid <= 1'b1;
                                state <= SEND_SG;
                            end else if (h2c_req_valid && !h2c_req_ack) begin
                                rq_tdata[63:0] <= h2c_req_addr;
                                rq_tdata[74:64] <= h2c_req_dw_len;
                                rq_tdata[78:75] <= 4'b0000;
                                rq_tdata[95:80] <= active_requester_id;
                                rq_tdata[103:96] <= h2c_req_tag;
                                rq_tuser <= {54'd0, h2c_last_be, 4'hF};
                                rq_tkeep <= {KEEP_WIDTH{1'b1}};
                                rq_tlast <= 1'b1;
                                rq_tvalid <= 1'b1;
                                state <= SEND_H2C;
                            end else if (c2h_req_valid && !c2h_req_ack && c2h_req_dw_len != 0) begin
                                rq_tdata[63:0] <= c2h_req_addr;
                                rq_tdata[74:64] <= c2h_req_dw_len;
                                rq_tdata[78:75] <= 4'b0001;
                                rq_tdata[95:80] <= active_requester_id;
                                rq_tdata[103:96] <= 8'd0;
                                rq_tuser <= {54'd0, c2h_last_be, 4'hF};
                                rq_tkeep <= {KEEP_WIDTH{1'b1}};
                                rq_tlast <= 1'b0;
                                rq_tvalid <= 1'b1;
                                c2h_dw_remaining <= c2h_req_dw_len;
                                state <= SEND_MWR_HEADER;
                            end
                        end

                        SEND_IRQ: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                irq_ack <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast <= 1'b0;
                                state <= IDLE;
                            end
                        end

                        SEND_DESC: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                desc_ack <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast <= 1'b0;
                                state <= IDLE;
                            end
                        end

                        SEND_SG: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                sg_ack <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast <= 1'b0;
                                state <= IDLE;
                            end
                        end

                        SEND_H2C: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                h2c_ack <= 1'b1;
                                rq_tvalid <= 1'b0;
                                rq_tlast <= 1'b0;
                                state <= IDLE;
                            end
                        end

                        SEND_MWR_HEADER: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                rq_tdata <= c2h_req_data;
                                rq_tuser <= 62'd0;
                                rq_tkeep <= payload_keep(first_payload_dw);
                                rq_tlast <= (c2h_req_dw_len <= DATA_DWORDS);
                                rq_tvalid <= 1'b1;
                                c2h_dw_remaining <= c2h_req_dw_len - first_payload_dw;
                                state <= SEND_MWR_DATA;
                            end
                        end

                        SEND_MWR_DATA: begin
                            if (rq_tvalid && m_axis_rq_tready) begin
                                if (c2h_dw_remaining == 0) begin
                                    c2h_ack <= 1'b1;
                                    rq_tvalid <= 1'b0;
                                    rq_tlast <= 1'b0;
                                    state <= IDLE;
                                end else begin
                                    rq_tdata <= c2h_req_data;
                                    rq_tkeep <= payload_keep(next_payload_dw);
                                    rq_tlast <= (c2h_dw_remaining <= DATA_DWORDS);
                                    c2h_dw_remaining <= c2h_dw_remaining - next_payload_dw;
                                end
                            end
                        end

                        default: state <= IDLE;
                    endcase
                end
            end
        end
    endgenerate

endmodule
