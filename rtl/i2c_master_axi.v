// ============================================================================
// Module: i2c_master_axi
// Description: AXI4-Lite I2C Master Controller.
//              Provides standard register interface compatible with Linux i2c.
//              Controls external SCL and SDA with clock prescaler.
//
// Register Map (32-bit aligned):
//   Offset 0x00: PRER_LO (R/W) - Clock Prescaler Low Byte (bits [7:0])
//   Offset 0x04: PRER_HI (R/W) - Clock Prescaler High Byte (bits [7:0])
//                              SCL freq = clk / (5 * (PRER + 1))
//                              Default: 125MHz / (5 * 250) = 100 kHz (PRER = 249 = 0x00F9)
//   Offset 0x08: CTR     (R/W) - Control: [7]=EN (Core Enable), [6]=IEN (Interrupt Enable)
//   Offset 0x0C: TXR/RXR (W/R) - TXR: Transmit Data Byte [7:0]
//                              RXR: Receive Data Byte [7:0]
//   Offset 0x10: CR      (W)   - Command Register (auto-clears):
//                              [7]=STA (Generate START)
//                              [6]=STO (Generate STOP)
//                              [5]=RD  (Read 1 byte from slave)
//                              [4]=WR  (Write 1 byte to slave)
//                              [3]=ACK (ACK value to send when RD: 0=ACK, 1=NACK)
//                              [0]=IACK (Interrupt Acknowledge / clear IF)
//   Offset 0x14: SR      (R)   - Status Register:
//                              [7]=RXACK (0=ACK received, 1=NACK received)
//                              [6]=BUSY  (Bus is busy: START to STOP)
//                              [5]=AL    (Arbitration Lost)
//                              [1]=TIP   (Transfer In Progress)
//                              [0]=IF    (Interrupt Flag: command completed)
// ============================================================================

`timescale 1ns / 1ps

module i2c_master_axi #(
    parameter DEFAULT_PRESCALER = 16'd249 // 100 kHz @ 125 MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite Slave Interface
    input  wire [7:0]  s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output reg         s_axil_wready,
    output reg  [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,

    input  wire [7:0]  s_axil_araddr,
    input  wire        s_axil_arvalid,
    output reg         s_axil_arready,
    output reg  [31:0] s_axil_rdata,
    output reg  [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,

    // I2C Physical Signals (Open Drain / Tri-State)
    inout  wire        scl_io,
    inout  wire        sda_io,

    // Optional Interrupt Output
    output wire        irq
);

    // =========================================================================
    // Registers
    // =========================================================================
    reg [15:0] reg_prer;
    reg        reg_ctr_en;
    reg        reg_ctr_ien;
    reg [7:0]  reg_txr;
    reg [7:0]  reg_rxr;
    reg        reg_sr_rxack;
    reg        reg_sr_busy;
    reg        reg_sr_al;
    reg        reg_sr_tip;
    reg        reg_sr_if;

    assign irq = reg_ctr_ien && reg_sr_if;

    // Command pulses / flags
    reg cmd_sta, cmd_sto, cmd_rd, cmd_wr, cmd_ack;
    reg cmd_start_pulse;
    reg cmd_iack_pulse;

    // =========================================================================
    // I2C Open-Drain Pad Drivers (IOBUF)
    // =========================================================================
    reg  scl_oen; // 1: Float (High via pull-up), 0: Drive Low
    reg  sda_oen; // 1: Float (High via pull-up), 0: Drive Low
    wire scl_i;
    wire sda_i;

    IOBUF u_iobuf_scl (
        .IO(scl_io),
        .O(scl_i),
        .I(1'b0),
        .T(scl_oen)
    );

    IOBUF u_iobuf_sda (
        .IO(sda_io),
        .O(sda_i),
        .I(1'b0),
        .T(sda_oen)
    );

    // =========================================================================
    // AXI-Lite Write Channels
    // =========================================================================
    reg [7:0] awaddr_q;
    reg       aw_done;
    reg       w_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready  <= 1'b0;
            s_axil_wready   <= 1'b0;
            s_axil_bvalid   <= 1'b0;
            s_axil_bresp    <= 2'b00;
            aw_done         <= 1'b0;
            w_done          <= 1'b0;
            awaddr_q        <= 8'h00;
            reg_prer        <= DEFAULT_PRESCALER;
            reg_ctr_en      <= 1'b0;
            reg_ctr_ien     <= 1'b0;
            reg_txr         <= 8'h00;
            cmd_sta         <= 1'b0;
            cmd_sto         <= 1'b0;
            cmd_rd          <= 1'b0;
            cmd_wr          <= 1'b0;
            cmd_ack         <= 1'b0;
            cmd_start_pulse <= 1'b0;
            cmd_iack_pulse  <= 1'b0;
        end else begin
            cmd_start_pulse <= 1'b0;
            cmd_iack_pulse  <= 1'b0;

            // Address write handshake
            if (!aw_done && s_axil_awvalid && (!s_axil_bvalid || s_axil_bready)) begin
                s_axil_awready <= 1'b1;
                awaddr_q       <= s_axil_awaddr;
                aw_done        <= 1'b1;
            end else begin
                s_axil_awready <= 1'b0;
            end

            // Data write handshake
            if (!w_done && s_axil_wvalid && (!s_axil_bvalid || s_axil_bready)) begin
                s_axil_wready <= 1'b1;
                w_done        <= 1'b1;
            end else begin
                s_axil_wready <= 1'b0;
            end

            // Execute Register Write when both ADDR & DATA are ready
            if ((aw_done || (s_axil_awvalid && s_axil_awready)) &&
                (w_done  || (s_axil_wvalid && s_axil_wready)) &&
                !s_axil_bvalid) begin
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00;
                aw_done       <= 1'b0;
                w_done        <= 1'b0;

                case (awaddr_q[4:2])
                    3'b000: reg_prer[7:0]  <= s_axil_wdata[7:0];   // 0x00
                    3'b001: reg_prer[15:8] <= s_axil_wdata[7:0];   // 0x04
                    3'b010: begin                                  // 0x08 (CTR)
                        reg_ctr_en  <= s_axil_wdata[7];
                        reg_ctr_ien <= s_axil_wdata[6];
                    end
                    3'b011: reg_txr <= s_axil_wdata[7:0];          // 0x0C (TXR)
                    3'b100: begin                                  // 0x10 (CR)
                        cmd_sta         <= s_axil_wdata[7];
                        cmd_sto         <= s_axil_wdata[6];
                        cmd_rd          <= s_axil_wdata[5];
                        cmd_wr          <= s_axil_wdata[4];
                        cmd_ack         <= s_axil_wdata[3];
                        cmd_iack_pulse  <= s_axil_wdata[0];
                        cmd_start_pulse <= (s_axil_wdata[7] | s_axil_wdata[6] | 
                                            s_axil_wdata[5] | s_axil_wdata[4]);
                    end
                    default: ;
                endcase
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // AXI-Lite Read Channels
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
            s_axil_rresp   <= 2'b00;
            s_axil_rdata   <= 32'h0;
        end else begin
            if (s_axil_arvalid && (!s_axil_rvalid || s_axil_rready)) begin
                s_axil_arready <= 1'b1;
                s_axil_rvalid  <= 1'b1;
                s_axil_rresp   <= 2'b00;

                case (s_axil_araddr[4:2])
                    3'b000: s_axil_rdata <= {24'h0, reg_prer[7:0]};
                    3'b001: s_axil_rdata <= {24'h0, reg_prer[15:8]};
                    3'b010: s_axil_rdata <= {24'h0, reg_ctr_en, reg_ctr_ien, 6'h0};
                    3'b011: s_axil_rdata <= {24'h0, reg_rxr};
                    3'b101: s_axil_rdata <= {24'h0, reg_sr_rxack, reg_sr_busy, reg_sr_al, 3'h0, reg_sr_tip, reg_sr_if};
                    default: s_axil_rdata <= 32'h0;
                endcase
            end else begin
                s_axil_arready <= 1'b0;
                if (s_axil_rvalid && s_axil_rready) begin
                    s_axil_rvalid <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // I2C Timing & Sub-State Machine (Byte & Condition Engine)
    // =========================================================================
    // Each I2C bit is divided into 4 quarters (Q0, Q1, Q2, Q3) by clock tick.
    reg [15:0] clk_cnt;
    wire tick = (clk_cnt == 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 16'd0;
        end else if (!reg_ctr_en) begin
            clk_cnt <= 16'd0;
        end else if (clk_cnt >= reg_prer) begin
            clk_cnt <= 16'd0;
        end else begin
            clk_cnt <= clk_cnt + 1'b1;
        end
    end

    localparam ST_IDLE       = 4'd0;
    localparam ST_START_A    = 4'd1;
    localparam ST_START_B    = 4'd2;
    localparam ST_BIT_Q0     = 4'd3;
    localparam ST_BIT_Q1     = 4'd4;
    localparam ST_BIT_Q2     = 4'd5;
    localparam ST_BIT_Q3     = 4'd6;
    localparam ST_STOP_A     = 4'd7;
    localparam ST_STOP_B     = 4'd8;
    localparam ST_STOP_C     = 4'd9;

    reg [3:0] state;
    reg [3:0] bit_idx;      // 0..7 for data bits, 8 for ACK bit
    reg [7:0] shift_tx;
    reg [7:0] shift_rx;
    reg       is_read_op;
    reg       need_stop;
    reg       send_ack_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            scl_oen      <= 1'b1;
            sda_oen      <= 1'b1;
            reg_sr_rxack <= 1'b0;
            reg_sr_busy  <= 1'b0;
            reg_sr_al    <= 1'b0;
            reg_sr_tip   <= 1'b0;
            reg_sr_if    <= 1'b0;
            reg_rxr      <= 8'h00;
            bit_idx      <= 4'd0;
            shift_tx     <= 8'h00;
            shift_rx     <= 8'h00;
            is_read_op   <= 1'b0;
            need_stop    <= 1'b0;
            send_ack_bit <= 1'b0;
        end else if (!reg_ctr_en) begin
            state        <= ST_IDLE;
            scl_oen      <= 1'b1;
            sda_oen      <= 1'b1;
            reg_sr_busy  <= 1'b0;
            reg_sr_tip   <= 1'b0;
            reg_sr_if    <= 1'b0;
        end else begin
            if (cmd_iack_pulse) begin
                reg_sr_if <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    scl_oen <= 1'b1;
                    sda_oen <= 1'b1;
                    if (cmd_start_pulse) begin
                        reg_sr_if    <= 1'b0;
                        reg_sr_tip   <= 1'b1;
                        shift_tx     <= reg_txr;
                        is_read_op   <= cmd_rd;
                        need_stop    <= cmd_sto;
                        send_ack_bit <= cmd_ack;
                        bit_idx      <= 4'd0;

                        if (cmd_sta) begin
                            state       <= ST_START_A;
                            reg_sr_busy <= 1'b1;
                        end else if (cmd_wr || cmd_rd) begin
                            state <= ST_BIT_Q0;
                        end else if (cmd_sto) begin
                            state <= ST_STOP_A;
                        end
                    end
                end

                // --- START Condition ---
                ST_START_A: begin
                    if (tick) begin
                        sda_oen <= 1'b0; // SDA Low while SCL High
                        state   <= ST_START_B;
                    end
                end

                ST_START_B: begin
                    if (tick) begin
                        scl_oen <= 1'b0; // SCL Low
                        if (cmd_wr || cmd_rd) begin
                            bit_idx <= 4'd0;
                            state   <= ST_BIT_Q0;
                        end else if (need_stop) begin
                            state <= ST_STOP_A;
                        end else begin
                            reg_sr_tip <= 1'b0;
                            reg_sr_if  <= 1'b1;
                            state      <= ST_IDLE;
                        end
                    end
                end

                // --- 8 Data Bits + 1 ACK Bit Cycle ---
                // Q0: SCL Low, Drive SDA
                ST_BIT_Q0: begin
                    if (tick) begin
                        scl_oen <= 1'b0;
                        if (bit_idx < 4'd8) begin
                            if (is_read_op) begin
                                sda_oen <= 1'b1; // Master release SDA to read
                            end else begin
                                sda_oen <= shift_tx[7]; // Shift MSB first
                            end
                        end else begin
                            // ACK bit (bit_idx == 8)
                            if (is_read_op) begin
                                sda_oen <= send_ack_bit; // 0: ACK, 1: NACK
                            end else begin
                                sda_oen <= 1'b1; // Release for slave ACK
                            end
                        end
                        state <= ST_BIT_Q1;
                    end
                end

                // Q1: SCL Rising / High
                ST_BIT_Q1: begin
                    if (tick) begin
                        scl_oen <= 1'b1; // SCL High
                        state   <= ST_BIT_Q2;
                    end
                end

                // Q2: Sample SDA while SCL High
                ST_BIT_Q2: begin
                    if (tick) begin
                        if (bit_idx < 4'd8) begin
                            if (is_read_op) begin
                                shift_rx <= {shift_rx[6:0], sda_i};
                            end
                        end else begin
                            // Sample Slave ACK
                            if (!is_read_op) begin
                                reg_sr_rxack <= sda_i; // 0=ACK, 1=NACK
                            end
                        end
                        state <= ST_BIT_Q3;
                    end
                end

                // Q3: SCL Falling / Setup for next bit
                ST_BIT_Q3: begin
                    if (tick) begin
                        scl_oen <= 1'b0; // SCL Low
                        if (bit_idx < 4'd8) begin
                            if (!is_read_op) begin
                                shift_tx <= {shift_tx[6:0], 1'b0};
                            end
                            bit_idx <= bit_idx + 1'b1;
                            state   <= ST_BIT_Q0;
                        end else begin
                            // Byte completed
                            if (is_read_op) begin
                                reg_rxr <= shift_rx;
                            end

                            if (need_stop) begin
                                state <= ST_STOP_A;
                            end else begin
                                reg_sr_tip <= 1'b0;
                                reg_sr_if  <= 1'b1;
                                state      <= ST_IDLE;
                            end
                        end
                    end
                end

                // --- STOP Condition ---
                ST_STOP_A: begin
                    if (tick) begin
                        sda_oen <= 1'b0; // SDA Low while SCL Low
                        state   <= ST_STOP_B;
                    end
                end

                ST_STOP_B: begin
                    if (tick) begin
                        scl_oen <= 1'b1; // SCL High
                        state   <= ST_STOP_C;
                    end
                end

                ST_STOP_C: begin
                    if (tick) begin
                        sda_oen     <= 1'b1; // SDA High while SCL High (STOP!)
                        reg_sr_busy <= 1'b0;
                        reg_sr_tip  <= 1'b0;
                        reg_sr_if   <= 1'b1;
                        state       <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
