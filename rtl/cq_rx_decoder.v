// ============================================================================
// Module: cq_rx_decoder
// Description: Decodes PCIe IP CQ (Completer Request) AXI4-Stream TLP packets.
//              Supports Dual-BAR Demuxing:
//              - BAR0 (bar_id == 0): Demuxes MWr/MRd to BAR0 AXI4-Lite (DMA Control Regs)
//              - BAR1 (bar_id == 1): Demuxes MWr/MRd to BAR1 AXI4-Lite (External IP Cores Interconnect)
// ============================================================================

`timescale 1ns / 1ps

module cq_rx_decoder #(
    parameter DATA_WIDTH = 128,
    parameter KEEP_WIDTH = DATA_WIDTH / 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // CQ AXI4-Stream Interface (PCIe IP -> User Logic)
    input  wire [DATA_WIDTH-1:0] s_axis_cq_tdata,
    input  wire                  s_axis_cq_tvalid,
    input  wire                  s_axis_cq_tlast,
    input  wire [87:0]           s_axis_cq_tuser,
    input  wire [KEEP_WIDTH-1:0] s_axis_cq_tkeep,
    output reg                   s_axis_cq_tready,

    // BAR0 AXI4-Lite Master Interface (DMA Control Registers)
    output reg  [31:0]           m_axil_bar0_awaddr,
    output reg                   m_axil_bar0_awvalid,
    input  wire                  m_axil_bar0_awready,
    output reg  [31:0]           m_axil_bar0_wdata,
    output reg  [3:0]            m_axil_bar0_wstrb,
    output reg                   m_axil_bar0_wvalid,
    input  wire                  m_axil_bar0_wready,
    input  wire [1:0]            m_axil_bar0_bresp,
    input  wire                  m_axil_bar0_bvalid,
    output reg                   m_axil_bar0_bready,

    output reg  [31:0]           m_axil_bar0_araddr,
    output reg                   m_axil_bar0_arvalid,
    input  wire                  m_axil_bar0_arready,
    input  wire [31:0]           m_axil_bar0_rdata,
    input  wire [1:0]            m_axil_bar0_rresp,
    input  wire                  m_axil_bar0_rvalid,

    // BAR1 AXI4-Lite Master Interface (User IP Cores Interconnect: I2C, UART, etc.)
    output reg  [31:0]           m_axil_bar1_awaddr,
    output reg                   m_axil_bar1_awvalid,
    input  wire                  m_axil_bar1_awready,
    output reg  [31:0]           m_axil_bar1_wdata,
    output reg  [3:0]            m_axil_bar1_wstrb,
    output reg                   m_axil_bar1_wvalid,
    input  wire                  m_axil_bar1_wready,
    input  wire [1:0]            m_axil_bar1_bresp,
    input  wire                  m_axil_bar1_bvalid,
    output reg                   m_axil_bar1_bready,

    output reg  [31:0]           m_axil_bar1_araddr,
    output reg                   m_axil_bar1_arvalid,
    input  wire                  m_axil_bar1_arready,
    input  wire [31:0]           m_axil_bar1_rdata,
    input  wire [1:0]            m_axil_bar1_rresp,
    input  wire                  m_axil_bar1_rvalid,

    // Read Request Tracking to CC TX Encoder
    output reg                   read_req_valid,
    output reg  [7:0]            read_req_tag,
    output reg  [15:0]           read_req_id,
    output reg  [6:0]            read_req_lower_addr,
    output reg  [10:0]           read_req_tc,
    output reg                   read_req_bar_sel, // 0: BAR0, 1: BAR1
    input  wire                  read_req_ack,
    input  wire                  cc_busy
);

    localparam IDLE       = 2'b00;
    localparam WRITE_AXIL = 2'b01;
    localparam READ_AXIL  = 2'b10;

    reg [1:0] state;

    // CQ TLP Header Fields
    wire [63:0] req_addr   = s_axis_cq_tdata[63:0];
    wire [10:0] dword_len  = s_axis_cq_tdata[74:64];
    wire [3:0]  req_type   = s_axis_cq_tdata[78:75]; // 0000: MRd, 0001: MWr
    wire [15:0] req_id     = s_axis_cq_tdata[95:80];
    wire [7:0]  req_tag    = s_axis_cq_tdata[103:96];
    wire [2:0]  bar_id     = (DATA_WIDTH >= 256) ? s_axis_cq_tdata[114:112] : s_axis_cq_tuser[2:0]; // 3'b000: BAR0, 3'b001: BAR1

    reg         write_req_bar_sel; // 0: BAR0, 1: BAR1
    reg         aw_done;
    reg         w_done;
    reg         ar_done;
    reg         rdata_seen;
    reg [11:0]  watch_dog_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= IDLE;
            s_axis_cq_tready    <= 1'b1;
            m_axil_bar0_awaddr  <= 32'd0;
            m_axil_bar0_awvalid <= 1'b0;
            m_axil_bar0_wdata   <= 32'd0;
            m_axil_bar0_wstrb   <= 4'hF;
            m_axil_bar0_wvalid  <= 1'b0;
            m_axil_bar0_bready  <= 1'b1;
            m_axil_bar0_araddr  <= 32'd0;
            m_axil_bar0_arvalid <= 1'b0;

            m_axil_bar1_awaddr  <= 32'd0;
            m_axil_bar1_awvalid <= 1'b0;
            m_axil_bar1_wdata   <= 32'd0;
            m_axil_bar1_wstrb   <= 4'hF;
            m_axil_bar1_wvalid  <= 1'b0;
            m_axil_bar1_bready  <= 1'b1;
            m_axil_bar1_araddr  <= 32'd0;
            m_axil_bar1_arvalid <= 1'b0;

            read_req_valid      <= 1'b0;
            read_req_tag        <= 8'd0;
            read_req_id         <= 16'd0;
            read_req_lower_addr <= 7'd0;
            read_req_tc         <= 11'd0;
            read_req_bar_sel    <= 1'b0;
            write_req_bar_sel   <= 1'b0;
            aw_done             <= 1'b0;
            w_done              <= 1'b0;
            ar_done             <= 1'b0;
            rdata_seen          <= 1'b0;
            watch_dog_cnt       <= 12'd0;
        end else begin
            case (state)
                IDLE: begin
                    read_req_valid      <= 1'b0;
                    m_axil_bar0_awvalid <= 1'b0;
                    m_axil_bar0_wvalid  <= 1'b0;
                    m_axil_bar0_arvalid <= 1'b0;
                    m_axil_bar1_awvalid <= 1'b0;
                    m_axil_bar1_wvalid  <= 1'b0;
                    m_axil_bar1_arvalid <= 1'b0;
                    aw_done             <= 1'b0;
                    w_done              <= 1'b0;
                    ar_done             <= 1'b0;
                    rdata_seen          <= 1'b0;
                    watch_dog_cnt       <= 12'd0;

                    if (s_axis_cq_tvalid && s_axis_cq_tready) begin
                        if (req_type == 4'b0001) begin // Memory Write (MWr)
                            if (bar_id == 3'b001) begin // BAR1
                                /* PCIe requests carry the host-assigned BAR
                                 * address. BAR1 is a 64-KiB aperture, so pass
                                 * only its BAR-relative offset to the AXI
                                 * crossbar. */
                                write_req_bar_sel   <= 1'b1;
                                m_axil_bar1_awaddr  <= {16'd0, req_addr[15:0]};
                                m_axil_bar1_awvalid <= 1'b1;
                                m_axil_bar1_wdata   <= (DATA_WIDTH >= 256) ? s_axis_cq_tdata[159:128] : s_axis_cq_tdata[127:96];
                                m_axil_bar1_wstrb   <= 4'hF;
                                m_axil_bar1_wvalid  <= 1'b1;
                            end else begin // BAR0
                                write_req_bar_sel   <= 1'b0;
                                m_axil_bar0_awaddr  <= req_addr[31:0];
                                m_axil_bar0_awvalid <= 1'b1;
                                m_axil_bar0_wdata   <= (DATA_WIDTH >= 256) ? s_axis_cq_tdata[159:128] : s_axis_cq_tdata[127:96];
                                m_axil_bar0_wstrb   <= 4'hF;
                                m_axil_bar0_wvalid  <= 1'b1;
                            end
                            s_axis_cq_tready <= 1'b0;
                            state            <= WRITE_AXIL;
                        end else if (req_type == 4'b0000) begin // Memory Read (MRd)
                            if (bar_id == 3'b001) begin // BAR1
                                m_axil_bar1_araddr  <= {16'd0, req_addr[15:0]};
                                m_axil_bar1_arvalid <= 1'b1;
                                read_req_bar_sel    <= 1'b1;
                            end else begin // BAR0
                                m_axil_bar0_araddr  <= req_addr[31:0];
                                m_axil_bar0_arvalid <= 1'b1;
                                read_req_bar_sel    <= 1'b0;
                            end
                            read_req_valid      <= 1'b1;
                            read_req_tag        <= req_tag;
                            read_req_id         <= req_id;
                            read_req_lower_addr <= req_addr[6:0];
                            read_req_tc         <= dword_len;
                            s_axis_cq_tready    <= 1'b0;
                            state               <= READ_AXIL;
                        end
                    end
                end

                WRITE_AXIL: begin
                    watch_dog_cnt <= watch_dog_cnt + 12'd1;
                    if (write_req_bar_sel) begin // BAR1
                        if (m_axil_bar1_awvalid && m_axil_bar1_awready) begin
                            m_axil_bar1_awvalid <= 1'b0;
                            aw_done             <= 1'b1;
                        end
                        if (m_axil_bar1_wvalid && m_axil_bar1_wready) begin
                            m_axil_bar1_wvalid  <= 1'b0;
                            w_done              <= 1'b1;
                        end
                        if (((aw_done || (m_axil_bar1_awvalid && m_axil_bar1_awready)) &&
                             (w_done  || (m_axil_bar1_wvalid  && m_axil_bar1_wready)) &&
                             m_axil_bar1_bvalid) || (watch_dog_cnt >= 12'd1024)) begin
                            m_axil_bar1_awvalid <= 1'b0;
                            m_axil_bar1_wvalid  <= 1'b0;
                            s_axis_cq_tready    <= 1'b1;
                            aw_done             <= 1'b0;
                            w_done              <= 1'b0;
                            state               <= IDLE;
                        end
                    end else begin // BAR0
                        if (m_axil_bar0_awvalid && m_axil_bar0_awready) begin
                            m_axil_bar0_awvalid <= 1'b0;
                            aw_done             <= 1'b1;
                        end
                        if (m_axil_bar0_wvalid && m_axil_bar0_wready) begin
                            m_axil_bar0_wvalid  <= 1'b0;
                            w_done              <= 1'b1;
                        end
                        if (((aw_done || (m_axil_bar0_awvalid && m_axil_bar0_awready)) &&
                             (w_done  || (m_axil_bar0_wvalid  && m_axil_bar0_wready)) &&
                             m_axil_bar0_bvalid) || (watch_dog_cnt >= 12'd1024)) begin
                            m_axil_bar0_awvalid <= 1'b0;
                            m_axil_bar0_wvalid  <= 1'b0;
                            s_axis_cq_tready    <= 1'b1;
                            aw_done             <= 1'b0;
                            w_done              <= 1'b0;
                            state               <= IDLE;
                        end
                    end
                end

                READ_AXIL: begin
                    watch_dog_cnt <= watch_dog_cnt + 12'd1;
                    if (read_req_ack) read_req_valid <= 1'b0;

                    if (read_req_bar_sel) begin // BAR1
                        if (m_axil_bar1_arvalid && m_axil_bar1_arready) begin
                            m_axil_bar1_arvalid <= 1'b0;
                            ar_done             <= 1'b1;
                        end
                        if ((ar_done || (m_axil_bar1_arvalid && m_axil_bar1_arready)) && m_axil_bar1_rvalid) begin
                            rdata_seen <= 1'b1;
                        end
                        if ((rdata_seen || ((ar_done || (m_axil_bar1_arvalid && m_axil_bar1_arready)) && m_axil_bar1_rvalid)) && !cc_busy) begin
                            s_axis_cq_tready <= 1'b1;
                            rdata_seen       <= 1'b0;
                            ar_done          <= 1'b0;
                            state            <= IDLE;
                        end else if (watch_dog_cnt >= 12'd1024) begin
                            m_axil_bar1_arvalid <= 1'b0;
                            read_req_valid      <= 1'b0;
                            s_axis_cq_tready    <= 1'b1;
                            rdata_seen          <= 1'b0;
                            ar_done             <= 1'b0;
                            state               <= IDLE;
                        end
                    end else begin // BAR0
                        if (m_axil_bar0_arvalid && m_axil_bar0_arready) begin
                            m_axil_bar0_arvalid <= 1'b0;
                            ar_done             <= 1'b1;
                        end
                        if ((ar_done || (m_axil_bar0_arvalid && m_axil_bar0_arready)) && m_axil_bar0_rvalid) begin
                            rdata_seen <= 1'b1;
                        end
                        if ((rdata_seen || ((ar_done || (m_axil_bar0_arvalid && m_axil_bar0_arready)) && m_axil_bar0_rvalid)) && !cc_busy) begin
                            s_axis_cq_tready <= 1'b1;
                            rdata_seen       <= 1'b0;
                            ar_done          <= 1'b0;
                            state            <= IDLE;
                        end else if (watch_dog_cnt >= 12'd1024) begin
                            m_axil_bar0_arvalid <= 1'b0;
                            read_req_valid      <= 1'b0;
                            s_axis_cq_tready    <= 1'b1;
                            rdata_seen          <= 1'b0;
                            ar_done             <= 1'b0;
                            state               <= IDLE;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
