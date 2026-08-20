`timescale 1ns / 1ps

module pcie_7x_tlp_loopback (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [127:0] m_axis_rx_tdata,
    input  wire [15:0]  m_axis_rx_tkeep,
    input  wire         m_axis_rx_tlast,
    input  wire         m_axis_rx_tvalid,
    output wire         m_axis_rx_tready,
    input  wire [21:0]  m_axis_rx_tuser,

    output reg  [127:0] s_axis_tx_tdata,
    output reg  [15:0]  s_axis_tx_tkeep,
    output reg          s_axis_tx_tlast,
    output reg          s_axis_tx_tvalid,
    input  wire         s_axis_tx_tready,
    output reg  [3:0]   s_axis_tx_tuser,

    input  wire [7:0]   cfg_bus_number,
    input  wire [4:0]   cfg_device_number,
    input  wire [2:0]   cfg_function_number,

    output wire         heartbeat_led
);

    wire [15:0] compl_id;
    assign compl_id = {cfg_bus_number, cfg_device_number, cfg_function_number};

    wire [1:0]  rx_fmt;
    wire [4:0]  rx_type;
    wire        rx_is_mrd;
    wire        rx_is_mwr;
    wire        rx_is_4dw;

    assign rx_fmt    = m_axis_rx_tdata[30:29];
    assign rx_type   = m_axis_rx_tdata[28:24];
    assign rx_is_mrd = (rx_type == 5'b00000) && (rx_fmt == 2'b00);
    assign rx_is_mwr = (rx_type == 5'b00000) && (rx_fmt[1] == 1'b1);
    assign rx_is_4dw = rx_fmt[0];

    reg [15:0] saved_req_id;
    reg [7:0]  saved_tag;
    reg [31:0] saved_addr_lo;

    reg        tx_active;
    reg        heartbeat;

    assign m_axis_rx_tready = !tx_active;

    wire [7:0] reg_offset;
    assign reg_offset = saved_addr_lo[7:0];

    reg [31:0] reg_rdata;
    always @(*) begin
        case (reg_offset)
            8'h00: reg_rdata = 32'h00000000;
            8'h04: reg_rdata = 32'h00000001;
            8'h08: reg_rdata = 32'h00000000;
            8'h0C: reg_rdata = 32'h00000000;
            8'h10: reg_rdata = 32'h00000000;
            8'h14: reg_rdata = 32'h00000000;
            8'h18: reg_rdata = 32'h00000000;
            8'h1C: reg_rdata = 32'h00000000;
            8'h20: reg_rdata = 32'h00000000;
            8'h24: reg_rdata = 32'h00000000;
            8'h28: reg_rdata = 32'h00000000;
            8'h2C: reg_rdata = 32'h00000000;
            8'h30: reg_rdata = 32'h01000001;
            8'h34: reg_rdata = 32'hDEADBEEF;
            8'h38: reg_rdata = 32'h20260820;
            8'h3C: reg_rdata = 32'h04040200;
            default: reg_rdata = 32'h00000000;
        endcase
    end

    localparam ST_IDLE  = 2'd0;
    localparam ST_CPLD  = 2'd1;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            tx_active      <= 1'b0;
            s_axis_tx_tdata  <= 128'd0;
            s_axis_tx_tkeep  <= 16'd0;
            s_axis_tx_tlast  <= 1'b0;
            s_axis_tx_tvalid <= 1'b0;
            s_axis_tx_tuser  <= 4'd0;
            saved_req_id   <= 16'd0;
            saved_tag      <= 8'd0;
            saved_addr_lo  <= 32'd0;
            heartbeat      <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    s_axis_tx_tvalid <= 1'b0;
                    s_axis_tx_tlast  <= 1'b0;
                    tx_active        <= 1'b0;

                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        if (rx_is_mrd) begin
                            saved_req_id  <= m_axis_rx_tdata[63:48];
                            saved_tag     <= m_axis_rx_tdata[47:40];

                            if (rx_is_4dw)
                                saved_addr_lo <= m_axis_rx_tdata[127:96];
                            else
                                saved_addr_lo <= m_axis_rx_tdata[95:64];

                            tx_active <= 1'b1;
                            state     <= ST_CPLD;
                        end else if (rx_is_mwr) begin
                            heartbeat <= 1'b1;
                        end
                    end
                end

                ST_CPLD: begin
                    if (s_axis_tx_tready || !s_axis_tx_tvalid) begin
                        s_axis_tx_tdata <= {
                            reg_rdata,
                            {saved_req_id, saved_tag, 8'h00},
                            {compl_id, 16'h0000},
                            32'h4A00_0004
                        };
                        s_axis_tx_tkeep  <= 16'hFFFF;
                        s_axis_tx_tlast  <= 1'b1;
                        s_axis_tx_tvalid <= 1'b1;
                        s_axis_tx_tuser  <= 4'b0000;
                        tx_active        <= 1'b0;
                        state            <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    assign heartbeat_led = heartbeat;

endmodule
