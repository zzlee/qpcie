// ============================================================================
// Module: rq_tx_encoder
// Description: Encodes PCIe IP RQ (Requester Request) AXI4-Stream TLP packets.
//              Arbitrates and packages MRd, MWr, and Msg TLPs to Host memory/PCIe RC.
// ============================================================================

`timescale 1ns / 1ps

module rq_tx_encoder #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = DATA_WIDTH / 8,
    parameter [15:0] REQUESTER_ID = 16'h0001
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // RQ AXI4-Stream Interface (User Logic -> PCIe IP)
    output reg  [DATA_WIDTH-1:0] m_axis_rq_tdata,
    output reg                   m_axis_rq_tvalid,
    output reg                   m_axis_rq_tlast,
    output reg  [61:0]           m_axis_rq_tuser,
    output reg  [KEEP_WIDTH-1:0] m_axis_rq_tkeep,
    input  wire                  m_axis_rq_tready,

    // Source 1: IRQ Request
    input  wire                  irq_req_valid,
    input  wire [7:0]            irq_req_code,
    output reg                   irq_req_ack,

    // Source 2: Descriptor Fetch Read Request (MRd)
    input  wire                  desc_req_valid,
    input  wire [63:0]           desc_req_addr,
    input  wire [10:0]           desc_req_dw_len,
    input  wire [7:0]            desc_req_tag,
    output reg                   desc_req_ack,

    // Source 3: H2C DMA Data Read Request (MRd)
    input  wire                  h2c_req_valid,
    input  wire [63:0]           h2c_req_addr,
    input  wire [10:0]           h2c_req_dw_len,
    input  wire [7:0]            h2c_req_tag,
    output reg                   h2c_req_ack,

    // Source 4: C2H DMA Data Write Request (MWr)
    input  wire                  c2h_req_valid,
    input  wire [63:0]           c2h_req_addr,
    input  wire [10:0]           c2h_req_dw_len,
    input  wire [DATA_WIDTH-1:0] c2h_req_data,
    input  wire                  c2h_req_last,
    output reg                   c2h_req_ack
);

    localparam IDLE     = 2'b00;
    localparam SEND_SINGLE = 2'b01;
    localparam SEND_MWR    = 2'b10;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            m_axis_rq_tdata  <= {DATA_WIDTH{1'b0}};
            m_axis_rq_tvalid <= 1'b0;
            m_axis_rq_tlast  <= 1'b0;
            m_axis_rq_tuser  <= 62'd0;
            m_axis_rq_tkeep  <= {KEEP_WIDTH{1'b1}};
            irq_req_ack      <= 1'b0;
            desc_req_ack     <= 1'b0;
            h2c_req_ack      <= 1'b0;
            c2h_req_ack      <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    irq_req_ack      <= 1'b0;
                    desc_req_ack     <= 1'b0;
                    h2c_req_ack      <= 1'b0;
                    c2h_req_ack      <= 1'b0;
                    m_axis_rq_tvalid <= 1'b0;
                    m_axis_rq_tlast  <= 1'b0;

                    // Priority Arbitration: IRQ > Desc Fetch > H2C Read > C2H Write
                    if (irq_req_valid) begin
                        m_axis_rq_tvalid       <= 1'b1;
                        m_axis_rq_tlast        <= 1'b1;
                        m_axis_rq_tkeep        <= 8'h0F;
                        m_axis_rq_tdata[63:0]  <= 64'd0;
                        m_axis_rq_tdata[74:64] <= 11'd0;
                        m_axis_rq_tdata[78:75] <= 4'b0010; // Msg
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96]<= 8'd0;
                        m_axis_rq_tdata[127:120] <= irq_req_code;
                        irq_req_ack            <= 1'b1;
                        state                  <= SEND_SINGLE;
                    end else if (desc_req_valid) begin
                        m_axis_rq_tvalid       <= 1'b1;
                        m_axis_rq_tlast        <= 1'b1;
                        m_axis_rq_tkeep        <= 8'h0F;
                        m_axis_rq_tdata[63:0]  <= desc_req_addr;
                        m_axis_rq_tdata[74:64] <= desc_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0000; // MRd
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96]<= desc_req_tag;
                        desc_req_ack           <= 1'b1;
                        state                  <= SEND_SINGLE;
                    end else if (h2c_req_valid) begin
                        m_axis_rq_tvalid       <= 1'b1;
                        m_axis_rq_tlast        <= 1'b1;
                        m_axis_rq_tkeep        <= 8'h0F;
                        m_axis_rq_tdata[63:0]  <= h2c_req_addr;
                        m_axis_rq_tdata[74:64] <= h2c_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0000; // MRd
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96]<= h2c_req_tag;
                        h2c_req_ack            <= 1'b1;
                        state                  <= SEND_SINGLE;
                    end else if (c2h_req_valid) begin
                        m_axis_rq_tvalid       <= 1'b1;
                        m_axis_rq_tkeep        <= {KEEP_WIDTH{1'b1}};
                        m_axis_rq_tdata[63:0]  <= c2h_req_addr;
                        m_axis_rq_tdata[74:64] <= c2h_req_dw_len;
                        m_axis_rq_tdata[78:75] <= 4'b0001; // MWr
                        m_axis_rq_tdata[95:80] <= REQUESTER_ID;
                        m_axis_rq_tdata[103:96]<= 8'd0;
                        if (DATA_WIDTH >= 256) begin
                            m_axis_rq_tdata[255:128] <= c2h_req_data[127:0]; // Payload starting at DW4
                            m_axis_rq_tlast          <= c2h_req_last;
                            c2h_req_ack              <= 1'b1;
                            state                    <= c2h_req_last ? SEND_SINGLE : SEND_MWR;
                        end else begin
                            // 128-bit Mode: Beat 0 is 4-DW Header, Beat 1 is 128-bit Data Payload
                            m_axis_rq_tlast          <= 1'b0;
                            state                    <= SEND_MWR;
                        end
                    end
                end

                SEND_SINGLE: begin
                    if (m_axis_rq_tready) begin
                        m_axis_rq_tvalid <= 1'b0;
                        m_axis_rq_tlast  <= 1'b0;
                        irq_req_ack      <= 1'b0;
                        desc_req_ack     <= 1'b0;
                        h2c_req_ack      <= 1'b0;
                        c2h_req_ack      <= 1'b0;
                        state            <= IDLE;
                    end
                end

                SEND_MWR: begin
                    if (m_axis_rq_tready) begin
                        m_axis_rq_tdata  <= c2h_req_data[127:0];
                        m_axis_rq_tvalid <= 1'b1;
                        m_axis_rq_tlast  <= 1'b1;
                        c2h_req_ack      <= 1'b1;
                        state            <= SEND_SINGLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
