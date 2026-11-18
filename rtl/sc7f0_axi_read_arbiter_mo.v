`default_nettype none
`timescale 1ns/1ps
// Two AXI4 read masters, pipelined multi-outstanding transactions using ARID/RID.
// Bit ID_BIT of m_arid/m_rid identifies the downstream master (0 = s0, 1 = s1);
// all other ID bits pass through unchanged so arbiters can be cascaded.
module sc7f0_axi_read_arbiter_mo #(
    parameter integer AW     = 49,
    parameter integer IW     = 6,
    parameter integer ID_BIT = 0
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire [AW-1:0]     s0_addr,
    input  wire [7:0]        s0_len,
    input  wire [2:0]        s0_size,
    input  wire [1:0]        s0_burst,
    input  wire [IW-1:0]     s0_arid,
    input  wire              s0_valid,
    output wire              s0_ready,
    output wire [127:0]      s0_data,
    output wire [1:0]        s0_resp,
    output wire [IW-1:0]     s0_rid,
    output wire              s0_last,
    output wire              s0_rvalid,
    input  wire              s0_rready,

    input  wire [AW-1:0]     s1_addr,
    input  wire [7:0]        s1_len,
    input  wire [2:0]        s1_size,
    input  wire [1:0]        s1_burst,
    input  wire [IW-1:0]     s1_arid,
    input  wire              s1_valid,
    output wire              s1_ready,
    output wire [127:0]      s1_data,
    output wire [1:0]        s1_resp,
    output wire [IW-1:0]     s1_rid,
    output wire              s1_last,
    output wire              s1_rvalid,
    input  wire              s1_rready,

    output reg  [AW-1:0]     m_addr,
    output reg  [7:0]        m_len,
    output reg  [2:0]        m_size,
    output reg  [1:0]        m_burst,
    output reg  [IW-1:0]     m_arid,
    output reg               m_valid,
    input  wire              m_ready,
    input  wire [127:0]      m_data,
    input  wire [1:0]        m_resp,
    input  wire [IW-1:0]     m_rid,
    input  wire              m_last,
    input  wire              m_rvalid,
    output wire              m_rready
);
    reg previous;

    wire ar_free = !m_valid || m_ready;
    wire sel0    = (!s1_valid || previous);
    wire sel1    = (!s0_valid || !previous);

    assign s0_ready = rst_n && ar_free && sel0;
    assign s1_ready = rst_n && ar_free && sel1;

    wire [IW-1:0] s0_id_masked = (s0_arid & ~({{(IW-1){1'b0}}, 1'b1} << ID_BIT));
    wire [IW-1:0] s1_id_masked = (s1_arid |  ({{(IW-1){1'b0}}, 1'b1} << ID_BIT));

    always @(posedge clk) begin
        if (!rst_n) begin
            previous <= 1'b1;
            m_valid  <= 1'b0;
            m_addr   <= {AW{1'b0}};
            m_len    <= 8'd0;
            m_size   <= 3'd0;
            m_burst  <= 2'd0;
            m_arid   <= {IW{1'b0}};
        end else if (ar_free) begin
            if (s0_valid && sel0) begin
                m_valid  <= 1'b1;
                m_addr   <= s0_addr;
                m_len    <= s0_len;
                m_size   <= s0_size;
                m_burst  <= s0_burst;
                m_arid   <= s0_id_masked;
                previous <= 1'b0;
            end else if (s1_valid && sel1) begin
                m_valid  <= 1'b1;
                m_addr   <= s1_addr;
                m_len    <= s1_len;
                m_size   <= s1_size;
                m_burst  <= s1_burst;
                m_arid   <= s1_id_masked;
                previous <= 1'b1;
            end else begin
                m_valid  <= 1'b0;
            end
        end
    end

    wire r_to_s1 = m_rid[ID_BIT];
    assign s0_data   = m_data;
    assign s1_data   = m_data;
    assign s0_resp   = m_resp;
    assign s1_resp   = m_resp;
    assign s0_rid    = m_rid;
    assign s1_rid    = m_rid;
    assign s0_last   = m_last;
    assign s1_last   = m_last;
    assign s0_rvalid = m_rvalid && !r_to_s1;
    assign s1_rvalid = m_rvalid &&  r_to_s1;
    assign m_rready  = r_to_s1 ? s1_rready : s0_rready;
endmodule
`default_nettype wire
