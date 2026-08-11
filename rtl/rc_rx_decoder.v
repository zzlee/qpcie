// ============================================================================
// Module: rc_rx_decoder
// Description: Decodes PCIe IP RC (Requester Completion) AXI4-Stream TLP packets.
//              Extracts CplD data and routes to Descriptor Fetch Engine or H2C FIFO based on Tag.
// ============================================================================

`timescale 1ns / 1ps

module rc_rx_decoder #(
    parameter DATA_WIDTH = 256,
    parameter KEEP_WIDTH = DATA_WIDTH / 32
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

    // Interface to Descriptor Fetch Engine (Tag 0 reserved for Descriptor Fetch)
    output reg                   desc_cpl_valid,
    output reg  [159:0]          desc_cpl_data, // Payload payload
    output reg                   desc_cpl_last,

    // Interface to H2C DMA Data FIFO (Tag > 0)
    output reg                   h2c_fifo_wvalid,
    output reg  [DATA_WIDTH-1:0] h2c_fifo_wdata,
    output reg                   h2c_fifo_wlast,

    // Tag Recycle Interface
    output reg                   tag_free_req,
    output reg  [7:0]            tag_free_val
);

    localparam IDLE         = 2'b00;
    localparam ROUTE_DESC   = 2'b01;
    localparam ROUTE_H2C    = 2'b10;

    reg [1:0] state;
    reg [7:0] current_tag;

    // Header Extraction from first beat
    wire [7:0]  rc_tag       = s_axis_rc_tdata[58:51];
    wire [10:0] rc_dword_len = s_axis_rc_tdata[42:32];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            s_axis_rc_tready <= 1'b1;
            desc_cpl_valid   <= 1'b0;
            desc_cpl_data    <= 160'd0;
            desc_cpl_last    <= 1'b0;
            h2c_fifo_wvalid  <= 1'b0;
            h2c_fifo_wdata   <= {DATA_WIDTH{1'b0}};
            h2c_fifo_wlast   <= 1'b0;
            tag_free_req     <= 1'b0;
            tag_free_val     <= 8'd0;
            current_tag      <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    desc_cpl_valid  <= 1'b0;
                    h2c_fifo_wvalid <= 1'b0;
                    tag_free_req    <= 1'b0;
                    s_axis_rc_tready <= 1'b1;

                    if (s_axis_rc_tvalid && s_axis_rc_tready) begin
                        current_tag <= rc_tag;

                        if (rc_tag == 8'h00) begin // Descriptor CplD
                            desc_cpl_valid <= 1'b1;
                            desc_cpl_data  <= s_axis_rc_tdata[255:96]; // First 160 bits payload
                            desc_cpl_last  <= s_axis_rc_tlast;
                            if (!s_axis_rc_tlast) begin
                                s_axis_rc_tready <= 1'b1;
                                state            <= ROUTE_DESC;
                            end
                        end else begin // H2C DMA CplD
                            h2c_fifo_wvalid <= 1'b1;
                            h2c_fifo_wdata  <= {96'd0, s_axis_rc_tdata[255:96]};
                            h2c_fifo_wlast  <= s_axis_rc_tlast;
                            tag_free_req    <= 1'b1;
                            tag_free_val    <= rc_tag;
                            if (!s_axis_rc_tlast) begin
                                state <= ROUTE_H2C;
                            end
                        end
                    end
                end

                ROUTE_DESC: begin
                    if (s_axis_rc_tvalid) begin
                        desc_cpl_valid <= 1'b1;
                        desc_cpl_data  <= s_axis_rc_tdata[159:0];
                        desc_cpl_last  <= s_axis_rc_tlast;
                        if (s_axis_rc_tlast) state <= IDLE;
                    end else begin
                        desc_cpl_valid <= 1'b0;
                    end
                end

                ROUTE_H2C: begin
                    tag_free_req <= 1'b0;
                    if (s_axis_rc_tvalid) begin
                        h2c_fifo_wvalid <= 1'b1;
                        h2c_fifo_wdata  <= s_axis_rc_tdata;
                        h2c_fifo_wlast  <= s_axis_rc_tlast;
                        if (s_axis_rc_tlast) state <= IDLE;
                    end else begin
                        h2c_fifo_wvalid <= 1'b0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
