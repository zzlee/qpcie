// ============================================================================
// Module: hdmi_i2s_bridge
// Target: AMD/Xilinx Artix-7 (xc7a50t-csg325-2)
// Description:
//   HDMI I2S to AES3 32-bit AXI4-Stream Audio Bridge & CDC FIFO.
//   - Receives native I2S (SCK, WS, D0) from IT68051.
//   - Deserializes standard 24-bit stereo PCM audio (WS=0: Left, WS=1: Right).
//   - Encapsulates into standard 32-bit AES3/IEC60958 subframes:
//       Bits [3:0]   : Preamble (0xB=Left Channel, 0xC=Right Channel)
//       Bits [27:4]  : 24-bit Audio Sample (MSB at bit 27)
//       Bit  [28]    : Validity bit (0=Valid)
//       Bit  [29]    : User bit (0)
//       Bit  [30]    : Channel Status bit (0)
//       Bit  [31]    : Even Parity bit over bits [31:4]
//   - Bridges into pcie_user_clk (125 MHz) domain via Xilinx xpm_fifo_async.
//   - Emits 32-bit AXI4-Stream matching the Audio DMA C2H Channel 0 engine.
// ============================================================================

`timescale 1ns / 1ps

module hdmi_i2s_bridge #(
    parameter FIFO_DEPTH = 512
)(
    // Native IT68051 I2S Audio Interface
    input  wire        i2s_sck,
    input  wire        i2s_rst_n,
    input  wire        i2s_ws,
    input  wire        i2s_d0,

    // PCIe DMA User Clock Domain (125 MHz)
    input  wire        pcie_user_clk,
    input  wire        pcie_user_rst_n,

    // 32-bit AXI4-Stream Audio Output to PCIe DMA Audio C2H
    output wire [31:0] m_axis_audio_tdata,
    output wire         m_axis_audio_tvalid,
    output wire         m_axis_audio_tlast,
    input  wire         m_axis_audio_tready
);

    // =========================================================================
    // 1. I2S Deserializer (i2s_sck domain)
    // Standard I2S format: MSB is delayed by 1 SCK cycle after WS transition.
    // WS=0: Left Channel, WS=1: Right Channel.
    // =========================================================================
    reg        ws_d = 1'b0;
    reg [5:0]  bit_idx = 6'd0;
    reg [23:0] shift_reg = 24'd0;

    reg [31:0] fifo_din = 32'd0;
    reg        fifo_wr_en = 1'b0;

    // Helper: calculate even parity over bits [30:4] + parity bit = [31]
    function automatic [31:0] build_aes3_subframe(
        input [3:0]  preamble,
        input [23:0] sample
    );
        reg parity;
        begin
            // Even parity over sample (bits 4..27) and V/U/C (bits 28..30 = 0)
            parity = ^sample;
            build_aes3_subframe = {parity, 3'b000, sample, preamble};
        end
    endfunction

    always @(posedge i2s_sck or negedge i2s_rst_n) begin
        if (!i2s_rst_n) begin
            ws_d       <= 1'b0;
            bit_idx    <= 6'd0;
            shift_reg  <= 24'd0;
            fifo_din   <= 32'd0;
            fifo_wr_en <= 1'b0;
        end else begin
            ws_d <= i2s_ws;

            // WS transition marks start of new channel
            if (i2s_ws != ws_d) begin
                bit_idx    <= 6'd0;
                fifo_wr_en <= 1'b0;

                // Output the completed sample of previous channel if we captured 24 bits
                if (bit_idx >= 6'd24) begin
                    if (!ws_d) begin
                        // Left channel completed -> Preamble 0xB
                        fifo_din   <= build_aes3_subframe(4'hB, shift_reg);
                        fifo_wr_en <= 1'b1;
                    end else begin
                        // Right channel completed -> Preamble 0xC
                        fifo_din   <= build_aes3_subframe(4'hC, shift_reg);
                        fifo_wr_en <= 1'b1;
                    end
                end
            end else begin
                fifo_wr_en <= 1'b0;
                if (bit_idx < 6'd24) begin
                    shift_reg <= {shift_reg[22:0], i2s_d0};
                    bit_idx   <= bit_idx + 1'b1;
                end else begin
                    bit_idx   <= bit_idx + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 2. Asynchronous CDC FIFO (i2s_sck -> pcie_user_clk 125 MHz)
    // =========================================================================
    wire fifo_full;
    wire fifo_empty;
    wire fifo_rd_en;
    wire fifo_rst = (!i2s_rst_n) || (!pcie_user_rst_n);

    assign fifo_rd_en          = m_axis_audio_tready && !fifo_empty;
    assign m_axis_audio_tvalid = !fifo_empty;
    assign m_axis_audio_tlast  = 1'b0; // Continuous stream

    xpm_fifo_async #(
        .CDC_SYNC_STAGES     (4),
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
        .READ_DATA_WIDTH     (32),
        .READ_MODE           ("fwft"),
        .RELATED_CLOCKS      (0),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0707"),
        .WAKEUP_TIME         (0),
        .WRITE_DATA_WIDTH    (32),
        .WR_DATA_COUNT_WIDTH (10),
        .RD_DATA_COUNT_WIDTH (10)
    ) u_audio_cdc_fifo (
        .sleep         (1'b0),
        .rst           (fifo_rst),
        .wr_clk        (i2s_sck),
        .wr_en         (fifo_wr_en && !fifo_full),
        .din           (fifo_din),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (),
        .almost_full   (),
        .wr_ack        (),
        .rd_clk        (pcie_user_clk),
        .rd_en         (fifo_rd_en),
        .dout          (m_axis_audio_tdata),
        .empty         (fifo_empty),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .rd_rst_busy   (),
        .almost_empty  (),
        .data_valid    (),
        .dbiterr       (),
        .sbiterr       ()
    );

endmodule
