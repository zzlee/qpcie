// ============================================================================
// Module: spi_flash_controller
// Description: AXI4-Lite SPI Flash Master & ICAPE2 In-System Reconfiguration.
//              - Controls Macronix MX25L12835F SPI Flash on Artix-7 A50T.
//              - Uses STARTUPE2 primitive to drive dedicated CCLK_0 (Pin E8).
//              - Controls physical CS# (Pin T18), MOSI (Pin K16), MISO (Pin L17).
//              - Integrates ICAPE2 primitive to execute IPROG warm reload.
//
// Register Map (32-bit aligned):
//   Offset 0x00: SPICR       (R/W) - SPI Control Register:
//                                    [0]   = CS_N (0: Assert / Select, 1: Deassert)
//                                    [1]   = SPI_EN (1: Enable SPI controller)
//                                    [7:4] = CLK_DIV (SPI Clock Div: freq = clk / (2*(DIV+1)))
//                                            Default DIV=3 -> 125MHz / 8 = 15.625 MHz
//   Offset 0x04: SPISR       (R)   - SPI Status Register:
//                                    [0] = BUSY (1: Byte transfer in progress)
//                                    [1] = RX_VALID (1: Last read byte valid)
//   Offset 0x08: SPIDTR      (W)   - Transmit Data Register (Write 8-bit byte triggers shift)
//   Offset 0x0C: SPIDRR      (R)   - Receive Data Register (Read 8-bit received byte)
//   Offset 0x20: ICAP_CMD    (W)   - Write 32'h52454C4F ("RELO") to trigger IPROG warm boot
//   Offset 0x24: ICAP_STATUS (R)   - [0] = ICAP_BUSY, [1] = RELOAD_STARTED
// ============================================================================

`timescale 1ns / 1ps

module spi_flash_controller (
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

    // Physical SPI Flash Pins (Bank 14)
    output reg         spi_cs_n,
    output reg         spi_mosi,
    input  wire        spi_miso
);

    // =========================================================================
    // Registers
    // =========================================================================
    reg [3:0] reg_clk_div;
    reg       reg_spi_en;
    reg       spi_busy;
    reg       rx_valid;
    reg [7:0] reg_rx_data;

    // ICAP control & status
    reg        icap_trigger;
    reg        icap_busy;
    reg        reload_started;

    // =========================================================================
    // AXI-Lite Write Channels
    // =========================================================================
    reg [7:0]  awaddr_q;
    reg [31:0] wdata_q;
    reg        aw_done;
    reg        w_done;
    reg        start_tx_pulse;
    reg [7:0]  tx_data_latch;

    wire [7:0]  wr_addr = aw_done ? awaddr_q : s_axil_awaddr;
    wire [31:0] wr_data = w_done  ? wdata_q  : s_axil_wdata;

    wire spi_engine_busy = (spi_state != SPI_IDLE) || start_tx_pulse;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready <= 1'b0;
            s_axil_wready  <= 1'b0;
            s_axil_bvalid  <= 1'b0;
            s_axil_bresp   <= 2'b00;
            aw_done        <= 1'b0;
            w_done         <= 1'b0;
            awaddr_q       <= 8'h00;
            wdata_q        <= 32'h00000000;
            spi_cs_n       <= 1'b1; // Default deasserted
            reg_spi_en     <= 1'b1;
            reg_clk_div    <= 4'd6; // ~10 MHz @ 125 MHz
            start_tx_pulse <= 1'b0;
            tx_data_latch  <= 8'h00;
            icap_trigger   <= 1'b0;
        end else begin
            start_tx_pulse <= 1'b0;
            icap_trigger   <= 1'b0;

            if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid  <= 1'b0;
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
            end

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

            // Execute Register Write when both ADDR & DATA are present
            if ((aw_done || (s_axil_awvalid && s_axil_awready)) &&
                (w_done  || (s_axil_wvalid && s_axil_wready)) &&
                !s_axil_bvalid) begin
                s_axil_bvalid  <= 1'b1;
                s_axil_bresp   <= 2'b00;
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
                aw_done        <= 1'b0;
                w_done         <= 1'b0;

                case (wr_addr[5:2])
                    4'h0: begin // 0x00: SPICR
                        spi_cs_n    <= wr_data[0];
                        reg_spi_en  <= wr_data[1];
                        reg_clk_div <= wr_data[7:4];
                    end
                    4'h2: begin // 0x08: SPIDTR
                        if (!spi_engine_busy) begin
                            tx_data_latch  <= wr_data[7:0];
                            start_tx_pulse <= 1'b1;
                        end
                    end
                    4'h8: begin // 0x20: ICAP_CMD
                        if (wr_data == 32'h52454C4F) begin // "RELO"
                            icap_trigger <= 1'b1;
                        end
                    end
                    default: ;
                endcase
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

                case (s_axil_araddr[5:2])
                    4'h0: s_axil_rdata <= {24'h0, reg_clk_div, 2'b00, reg_spi_en, spi_cs_n};
                    4'h1: s_axil_rdata <= {30'h0, rx_valid, spi_engine_busy};
                    4'h3: s_axil_rdata <= {24'h0, reg_rx_data};
                    4'h9: s_axil_rdata <= {30'h0, reload_started, icap_busy};
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
    // SPI Master Shift Engine (Mode 0: CPOL=0, CPHA=0)
    // =========================================================================
    reg [4:0] div_cnt;
    reg [3:0] bit_cnt;
    reg [7:0] shift_reg_tx;
    reg [7:0] shift_reg_rx;
    reg       spi_sclk_reg;
    wire      spi_sclk_out = spi_sclk_reg;

    localparam SPI_IDLE  = 2'd0;
    localparam SPI_SETUP = 2'd1;
    localparam SPI_SAMPLE= 2'd2;

    reg [1:0] spi_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_state     <= SPI_IDLE;
            spi_busy      <= 1'b0;
            rx_valid      <= 1'b0;
            spi_mosi      <= 1'b1;
            spi_sclk_reg  <= 1'b0;
            shift_reg_tx  <= 8'h00;
            shift_reg_rx  <= 8'h00;
            reg_rx_data   <= 8'h00;
            div_cnt       <= 5'd0;
            bit_cnt       <= 4'd0;
        end else begin
            case (spi_state)
                SPI_IDLE: begin
                    spi_sclk_reg <= 1'b0;
                    if (start_tx_pulse && reg_spi_en && !spi_cs_n) begin
                        spi_busy     <= 1'b1;
                        rx_valid     <= 1'b0;
                        shift_reg_tx <= tx_data_latch;
                        spi_mosi     <= tx_data_latch[7];
                        bit_cnt      <= 4'd0;
                        div_cnt      <= 5'd0;
                        spi_state    <= SPI_SETUP;
                    end else begin
                        spi_busy <= 1'b0;
                    end
                end

                SPI_SETUP: begin
                    // Half-period low: SCLK=0, MOSI stable
                    if (div_cnt >= {1'b0, reg_clk_div}) begin
                        div_cnt      <= 5'd0;
                        spi_sclk_reg <= 1'b1; // Rising edge
                        spi_state    <= SPI_SAMPLE;
                    end else begin
                        div_cnt <= div_cnt + 1'b1;
                    end
                end

                SPI_SAMPLE: begin
                    // Half-period high: SCLK=1, sample MISO
                    if (div_cnt >= {1'b0, reg_clk_div}) begin
                        div_cnt      <= 5'd0;
                        spi_sclk_reg <= 1'b0; // Falling edge
                        shift_reg_rx <= {shift_reg_rx[6:0], spi_miso};

                        if (bit_cnt == 4'd7) begin
                            // Finished 8 bits
                            reg_rx_data <= {shift_reg_rx[6:0], spi_miso};
                            rx_valid    <= 1'b1;
                            spi_busy    <= 1'b0;
                            spi_mosi    <= 1'b1;
                            spi_state   <= SPI_IDLE;
                        end else begin
                            bit_cnt      <= bit_cnt + 1'b1;
                            shift_reg_tx <= {shift_reg_tx[6:0], 1'b0};
                            spi_mosi     <= shift_reg_tx[6];
                            spi_state    <= SPI_SETUP;
                        end
                    end else begin
                        div_cnt <= div_cnt + 1'b1;
                    end
                end

                default: spi_state <= SPI_IDLE;
            endcase
        end
    end

    // =========================================================================
    // STARTUPE2 Primitive to Drive Dedicated CCLK_0 (Pin E8)
    // =========================================================================
    // Xilinx 7-Series STARTUPE2 requires 3-4 clock cycles on USRCCLKO after EOS
    // to switch internal multiplexer to user clock. We run a 4-cycle toggle
    // while CS_N is deasserted when reg_spi_en is first asserted.
    reg [2:0] startup_sync_cnt;
    reg       startup_sync_active;
    reg       reg_spi_en_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_spi_en_prev     <= 1'b0;
            startup_sync_active <= 1'b0;
            startup_sync_cnt    <= 3'd0;
        end else begin
            reg_spi_en_prev <= reg_spi_en;
            if (reg_spi_en && !reg_spi_en_prev) begin
                startup_sync_active <= 1'b1;
                startup_sync_cnt    <= 3'd0;
            end else if (startup_sync_active) begin
                if (startup_sync_cnt == 3'd7) begin
                    startup_sync_active <= 1'b0;
                end else begin
                    startup_sync_cnt <= startup_sync_cnt + 1'b1;
                end
            end
        end
    end

    wire sync_clk   = startup_sync_active ? startup_sync_cnt[0] : spi_sclk_reg;
    wire cclk_drive = sync_clk;
    wire cclk_ts    = reg_spi_en ? 1'b0 : 1'b1;

    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(0.0)
    ) u_startup (
        .CFGCLK     (),
        .CFGMCLK    (),
        .EOS        (),
        .PREQ       (),
        .CLK        (1'b0),
        .GSR        (1'b0),
        .GTS        (1'b0),
        .KEYCLEARB  (1'b1),
        .PACK       (1'b0),
        .USRCCLKO   (cclk_drive),
        .USRCCLKTS  (cclk_ts),
        .USRDONEO   (1'b1),
        .USRDONETS  (1'b1)
    );

    // =========================================================================
    // ICAPE2 Warm Boot (IPROG) State Machine
    // =========================================================================
    reg [31:0] icap_din;
    reg        icap_csib;
    reg        icap_rdwrb;
    reg [3:0]  icap_step;

    // Bit-swap function for 7-Series ICAP 32-bit interface (Xilinx UG470 requirement)
    function [31:0] bitswap32(input [31:0] in);
        integer b;
        for (b = 0; b < 32; b = b + 1) begin
            bitswap32[b] = in[{b[4:3], 3'd7 - b[2:0]}];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icap_busy      <= 1'b0;
            reload_started <= 1'b0;
            icap_csib      <= 1'b1;
            icap_rdwrb     <= 1'b1;
            icap_din       <= 32'hFFFFFFFF;
            icap_step      <= 4'd0;
        end else begin
            if (icap_trigger && !icap_busy) begin
                icap_busy      <= 1'b1;
                reload_started <= 1'b0;
                icap_step      <= 4'd0;
            end else if (icap_busy) begin
                case (icap_step)
                    4'd0: begin // Dummy Word
                        icap_csib  <= 1'b0;
                        icap_rdwrb <= 1'b0; // Write
                        icap_din   <= bitswap32(32'hFFFFFFFF);
                        icap_step  <= 4'd1;
                    end
                    4'd1: begin // Sync Word
                        icap_din   <= bitswap32(32'hAA995566);
                        icap_step  <= 4'd2;
                    end
                    4'd2: begin // Type 1 NOOP
                        icap_din   <= bitswap32(32'h20000000);
                        icap_step  <= 4'd3;
                    end
                    4'd3: begin // Type 1 Write 1 Word to WBSTAR
                        icap_din   <= bitswap32(32'h30020001);
                        icap_step  <= 4'd4;
                    end
                    4'd4: begin // Warm Boot Start Address (0x00000000)
                        icap_din   <= bitswap32(32'h00000000);
                        icap_step  <= 4'd5;
                    end
                    4'd5: begin // Type 1 Write 1 Word to CMD
                        icap_din   <= bitswap32(32'h30008001);
                        icap_step  <= 4'd6;
                    end
                    4'd6: begin // IPROG Command (0x0000000F)
                        icap_din   <= bitswap32(32'h0000000F);
                        icap_step  <= 4'd7;
                    end
                    4'd7: begin // Type 1 NOOP
                        icap_din   <= bitswap32(32'h20000000);
                        icap_step  <= 4'd8;
                    end
                    4'd8: begin // Finish
                        icap_csib      <= 1'b1;
                        icap_rdwrb     <= 1'b1;
                        icap_din       <= 32'hFFFFFFFF;
                        reload_started <= 1'b1;
                        icap_busy      <= 1'b0;
                    end
                    default: icap_step <= 4'd0;
                endcase
            end
        end
    end

    ICAPE2 #(
        .DEVICE_ID(32'h03622093), // Artix-7 A50T ID
        .ICAP_WIDTH("X32"),
        .SIM_CFG_FILE_NAME("NONE")
    ) u_icape2 (
        .O     (),
        .CLK   (clk),
        .CSIB  (icap_csib),
        .RDWRB (icap_rdwrb),
        .I     (icap_din)
    );

endmodule
