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
    reg [7:0]  awaddr_q;
    reg [31:0] wdata_q;
    reg        aw_done;
    reg        w_done;

    wire [7:0]  wr_addr = aw_done ? awaddr_q : s_axil_awaddr;
    wire [31:0] wr_data = w_done  ? wdata_q  : s_axil_wdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready  <= 1'b0;
            s_axil_wready   <= 1'b0;
            s_axil_bvalid   <= 1'b0;
            s_axil_bresp    <= 2'b00;
            aw_done         <= 1'b0;
            w_done          <= 1'b0;
            awaddr_q        <= 8'h00;
            wdata_q         <= 32'h00000000;
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
            snif_armed      <= 1'b0;
            snif_clear_req  <= 1'b0;
        end else begin
            cmd_start_pulse <= 1'b0;
            cmd_iack_pulse  <= 1'b0;
            snif_clear_req  <= 1'b0;

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
                wdata_q       <= s_axil_wdata;
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

                if (wr_addr[7:0] == 8'h40) begin
                    // Sniffer control (not a master register)
                    snif_armed <= wr_data[0];
                    if (wr_data[0])
                        snif_clear_req <= 1'b1;
                end else begin
                case (wr_addr[4:2])
                    3'b000: reg_prer[7:0]  <= wr_data[7:0];   // 0x00
                    3'b001: reg_prer[15:8] <= wr_data[7:0];   // 0x04
                    3'b010: begin                             // 0x08 (CTR)
                        reg_ctr_en  <= wr_data[7];
                        reg_ctr_ien <= wr_data[6];
                    end
                    3'b011: reg_txr <= wr_data[7:0];          // 0x0C (TXR)
                    3'b100: begin                             // 0x10 (CR)
                        cmd_sta         <= wr_data[7];
                        cmd_sto         <= wr_data[6];
                        cmd_rd          <= wr_data[5];
                        cmd_wr          <= wr_data[4];
                        cmd_ack         <= wr_data[3];
                        cmd_iack_pulse  <= wr_data[0];
                        cmd_start_pulse <= (wr_data[7] | wr_data[6] | 
                                            wr_data[5] | wr_data[4]);
                    end
                    default: ;
                endcase
                end
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
            snif_rd_total   <= 10'd0;
        end else begin
            if (snif_clear_req) begin
                snif_rd_total   <= 10'd0;
            end
            // Accept one AR per R-completion (no re-accept while outstanding):
            // this makes FIFO pops exact even if the master holds ARVALID.
            if (s_axil_arvalid && !s_axil_rvalid) begin
                s_axil_arready <= 1'b1;
                s_axil_rvalid  <= 1'b1;
                s_axil_rresp   <= 2'b00;

                if (s_axil_araddr[7:0] == 8'h40) begin
                    s_axil_rdata <= {21'h0, snif_overflow, snif_armed,
                                     snif_avail[8:0]};
                end else if (s_axil_araddr[7:0] == 8'h44) begin
                    s_axil_rdata <= {16'h0, snif_mem[snif_rd_total[6:0]]};
                    if (snif_wr_total != snif_rd_total)
                        snif_rd_total <= snif_rd_total + 1'b1;
                end else begin
                case (s_axil_araddr[4:2])
                    3'b000: s_axil_rdata <= {24'h0, reg_prer[7:0]};
                    3'b001: s_axil_rdata <= {24'h0, reg_prer[15:8]};
                    3'b010: s_axil_rdata <= {24'h0, reg_ctr_en, reg_ctr_ien, 6'h0};
                    3'b011: s_axil_rdata <= {24'h0, reg_rxr};
                    3'b101: s_axil_rdata <= {24'h0, reg_sr_rxack, reg_sr_busy, reg_sr_al, 3'h0, reg_sr_tip, reg_sr_if};
                    // Bus spy (RO, passive; no effect on master FSM):
                    // 0x18: [1:0]={SCL,SDA} live, [31:16]=SCL rising-edge count
                    // 0x1C: [15:0]=START count, [31:16]=STOP count
                    3'b110: s_axil_rdata <= {spy_scl_rise_cnt, 14'h0, spy_scl, spy_sda};
                    3'b111: s_axil_rdata <= {spy_stop_cnt, spy_start_cnt};
                    default: s_axil_rdata <= 32'h0;
                endcase
                end
            end else begin
                s_axil_arready <= 1'b0;
                if (s_axil_rvalid && s_axil_rready) begin
                    s_axil_rvalid <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // Passive Bus Spy (levels + SCL/START/STOP counters, saturating)
    // =========================================================================
    reg spy_scl_q, spy_sda_q, spy_scl_qq, spy_sda_qq;
    reg spy_scl, spy_sda;
    reg [15:0] spy_scl_rise_cnt, spy_start_cnt, spy_stop_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spy_scl_q <= 1'b1; spy_sda_q <= 1'b1;
            spy_scl_qq <= 1'b1; spy_sda_qq <= 1'b1;
            spy_scl <= 1'b1; spy_sda <= 1'b1;
            spy_scl_rise_cnt <= 16'd0;
            spy_start_cnt <= 16'd0;
            spy_stop_cnt <= 16'd0;
        end else begin
            spy_scl_q <= scl_i; spy_sda_q <= sda_i;
            spy_scl_qq <= spy_scl_q; spy_sda_qq <= spy_sda_q;
            spy_scl <= spy_scl_qq; spy_sda <= spy_sda_qq;
            if (!spy_scl_qq && spy_scl_q && spy_scl_rise_cnt != 16'hFFFF)
                spy_scl_rise_cnt <= spy_scl_rise_cnt + 1'b1;
            if (spy_scl_qq && !spy_sda_qq && spy_sda_q && spy_start_cnt != 16'hFFFF)
                spy_start_cnt <= spy_start_cnt + 1'b1;
            if (spy_scl_qq && spy_sda_qq && !spy_sda_q && spy_stop_cnt != 16'hFFFF)
                spy_stop_cnt <= spy_stop_cnt + 1'b1;
        end
    end

    // =========================================================================
    // Passive Sniffer Transcript FIFO (512 x {marker,data})
    // =========================================================================
    reg        n_scl_q, n_sda_q, n_scl, n_sda, p_scl, p_sda;
    reg        snif_in_frame;
    reg [3:0]  snif_bitcnt;
    reg [7:0]  snif_shreg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_scl_q <= 1'b1; n_sda_q <= 1'b1;
            n_scl <= 1'b1; n_sda <= 1'b1;
            p_scl <= 1'b1; p_sda <= 1'b1;
            snif_in_frame <= 1'b0;
            snif_bitcnt <= 4'd0;
            snif_shreg <= 8'h00;
            snif_wr_total <= 10'd0;
            snif_overflow <= 1'b0;
        end else begin
            n_scl_q <= scl_i; n_sda_q <= sda_i;
            p_scl <= n_scl; p_sda <= n_sda;
            n_scl <= n_scl_q; n_sda <= n_sda_q;
            if (snif_clear_req) begin
                snif_wr_total <= 10'd0;
                snif_overflow <= 1'b0;
                snif_in_frame <= 1'b0;
                snif_bitcnt <= 4'd0;
            end else if (snif_armed) begin
                if (n_scl && p_sda && !n_sda) begin
                    // START (also marks repeated START)
                    if (!snif_full) begin
                        snif_mem[snif_wr_total[6:0]] <= {8'h03, 8'h00};
                        snif_wr_total <= snif_wr_total + 1'b1;
                    end else begin
                        snif_overflow <= 1'b1;
                    end
                    snif_in_frame <= 1'b1;
                    snif_bitcnt <= 4'd0;
                end else if (n_scl && !p_sda && n_sda) begin
                    // STOP
                    if (snif_in_frame) begin
                        if (!snif_full) begin
                            snif_mem[snif_wr_total[6:0]] <= {8'h02, 8'h00};
                            snif_wr_total <= snif_wr_total + 1'b1;
                        end else begin
                            snif_overflow <= 1'b1;
                        end
                    end
                    snif_in_frame <= 1'b0;
                    snif_bitcnt <= 4'd0;
                end else if (!p_scl && n_scl && snif_in_frame) begin
                    // SCL rise: shift in data/ACK bit
                    if (snif_bitcnt == 4'd8) begin
                        // ACK bit done: record it (FF=NACK, 00=ACK)
                        if (!snif_full) begin
                            snif_mem[snif_wr_total[6:0]] <= {8'h01, n_sda ? 8'hFF : 8'h00};
                            snif_wr_total <= snif_wr_total + 1'b1;
                        end else begin
                            snif_overflow <= 1'b1;
                        end
                        snif_bitcnt <= 4'd0;
                    end else begin
                        snif_shreg <= {snif_shreg[6:0], n_sda};
                        if (snif_bitcnt == 4'd7) begin
                            // 8th data bit done: record byte
                            if (!snif_full) begin
                                snif_mem[snif_wr_total[6:0]] <= {8'h00, snif_shreg[6:0], n_sda};
                                snif_wr_total <= snif_wr_total + 1'b1;
                            end else begin
                                snif_overflow <= 1'b1;
                            end
                        end
                        snif_bitcnt <= snif_bitcnt + 1'b1;
                    end
                end
            end
        end
    end

    // Sniffer transcript FIFO 128 deep (passive, per-bus logic analyzer)
    // 0x40 W: bit0 1=arm+clear, 0=disarm
    // 0x40 R: [10]=overflow, [9]=armed, [8:0]=entries available
    // 0x44 R: pop {marker,data}: 0x00=data byte, 0x01=ACK(00)/NACK(FF),
    //                            0x02=STOP, 0x03=repeated START
    reg        snif_armed;
    reg        snif_clear_req;
    reg [9:0]  snif_wr_total;   // capture block
    reg [9:0]  snif_rd_total;   // read block (pop on AR accept)
    reg        snif_overflow;   // capture block
    reg [15:0] snif_mem [0:127];
    wire [9:0] snif_avail = snif_wr_total - snif_rd_total;
    wire       snif_full  = (snif_avail >= 10'd128);

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
    localparam ST_RESTART_RELEASE = 4'd10;
    localparam ST_RESTART_HIGH = 4'd11;

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
                    // Hold the byte-boundary SCL LOW until software sends
                    // another command. Releasing it clocks a phantom bit.
                    if (!reg_sr_busy) begin
                        scl_oen <= 1'b1;
                        sda_oen <= 1'b1;
                    end
                    if (cmd_start_pulse) begin
                        reg_sr_if    <= 1'b0;
                        reg_sr_tip   <= 1'b1;
                        shift_tx     <= reg_txr;
                        is_read_op   <= cmd_rd;
                        need_stop    <= cmd_sto;
                        send_ack_bit <= cmd_ack;
                        bit_idx      <= 4'd0;

                        if (cmd_sta) begin
                            state       <= reg_sr_busy ? ST_RESTART_RELEASE : ST_START_A;
                            reg_sr_busy <= 1'b1;
                        end else if (cmd_wr || cmd_rd) begin
                            state <= ST_BIT_Q0;
                        end else if (cmd_sto) begin
                            state <= ST_STOP_A;
                        end
                    end
                end

                ST_RESTART_RELEASE: begin
                    if (tick) begin
                        scl_oen <= 1'b0;
                        sda_oen <= 1'b1;
                        state <= ST_RESTART_HIGH;
                    end
                end

                ST_RESTART_HIGH: begin
                    if (tick) begin
                        scl_oen <= 1'b1;
                        // Wait for a stretching slave to release SCL before
                        // generating SDA's high-to-low START transition.
                        if (scl_oen && scl_i)
                            state <= ST_START_A;
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
