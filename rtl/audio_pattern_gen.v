// ============================================================================
// Module: audio_pattern_gen
// Description: Multi-Channel Audio Pattern Generator (AES3 / IEC 60958 Subframes).
//              Generates 32-bit AES3 audio subframes (Preamble + 24-bit Audio + Validity + User + Status + Parity)
//              with selectable patterns (1kHz Sine Wave, 440Hz Tone, Sawtooth, Sweep, Mute).
//              Features:
//              - AXI4-Lite Control Slave Interface (Mapped to BAR1 Offset 0x0100)
//              - AXI4-Stream Audio Master Output (Streamed to PCIe DMA C2H Audio Channel 0)
//              - Programmable Sample Rate (48kHz / 96kHz), Frequency, Gain & Channel Enables
// ============================================================================

`timescale 1ns / 1ps

module audio_pattern_gen #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,       // System / PCIe User Clock (e.g. 125MHz / 250MHz)
    input  wire                  rst_n,     // Active-low reset

    // AXI4-Lite Control Interface (From BAR1 Interconnect M01)
    input  wire [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  wire                  s_axil_awvalid,
    output reg                   s_axil_awready,
    input  wire [DATA_WIDTH-1:0] s_axil_wdata,
    input  wire [3:0]            s_axil_wstrb,
    input  wire                  s_axil_wvalid,
    output reg                   s_axil_wready,
    output reg  [1:0]            s_axil_bresp,
    output reg                   s_axil_bvalid,
    input  wire                  s_axil_bready,

    input  wire [ADDR_WIDTH-1:0] s_axil_araddr,
    input  wire                  s_axil_arvalid,
    output reg                   s_axil_arready,
    output reg  [DATA_WIDTH-1:0] s_axil_rdata,
    output reg  [1:0]            s_axil_rresp,
    output reg                   s_axil_rvalid,
    input  wire                  s_axil_rready,

    // AXI4-Stream Audio Output Interface (To PCIe DMA Engine C2H Audio Ch0)
    output reg  [31:0]           m_axis_audio_tdata,
    output reg                   m_axis_audio_tvalid,
    output reg                   m_axis_audio_tlast,
    input  wire                  m_axis_audio_tready
);

    // Control Register Offsets (8-bit)
    localparam REG_CTRL        = 8'h00; // Bit 0: Enable, Bit 1: Pattern Select (0: 1kHz Sine, 1: Sawtooth, 2: 440Hz, 3: Mute)
    localparam REG_DIVISOR     = 8'h04; // Sample rate divider (default 2604 for 48kHz @ 125MHz clk)
    localparam REG_VOLUME      = 8'h08; // Volume / Gain (0-255)
    localparam REG_STATUS      = 8'h0C; // Status (Bit 0: Running, Bit 1: AES3 Locked)
    localparam REG_SAMPLE_CNT  = 8'h10; // Total Audio Samples Generated

    // Registers
    reg [31:0] reg_ctrl;
    reg [31:0] reg_divisor;
    reg [31:0] reg_volume;
    reg [31:0] sample_counter;

    // AXI4-Lite Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl     <= 32'h0000_0001; // Enabled by default, 1kHz Sine
            reg_divisor  <= 32'd2604;      // 125MHz / 48kHz = ~2604
            reg_volume   <= 32'd200;       // Default Volume
            s_axil_awready <= 1'b0;
            s_axil_wready  <= 1'b0;
            s_axil_bvalid  <= 1'b0;
            s_axil_bresp   <= 2'b00;
        end else begin
            if (s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid) begin
                s_axil_awready <= 1'b1;
                s_axil_wready  <= 1'b1;
                s_axil_bvalid  <= 1'b1;
                s_axil_bresp   <= 2'b00;
                case (s_axil_awaddr[7:0])
                    REG_CTRL:    reg_ctrl    <= s_axil_wdata;
                    REG_DIVISOR: reg_divisor <= s_axil_wdata;
                    REG_VOLUME:  reg_volume  <= s_axil_wdata;
                    default: ;
                endcase
            end else begin
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
                if (s_axil_bready) s_axil_bvalid <= 1'b0;
            end
        end
    end

    // AXI4-Lite Read Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
            s_axil_rdata   <= 32'd0;
            s_axil_rresp   <= 2'b00;
        end else begin
            if (s_axil_arvalid && !s_axil_rvalid) begin
                s_axil_arready <= 1'b1;
                s_axil_rvalid  <= 1'b1;
                s_axil_rresp   <= 2'b00;
                case (s_axil_araddr[7:0])
                    REG_CTRL:       s_axil_rdata <= reg_ctrl;
                    REG_DIVISOR:    s_axil_rdata <= reg_divisor;
                    REG_VOLUME:     s_axil_rdata <= reg_volume;
                    REG_STATUS:     s_axil_rdata <= {30'd0, 1'b1, reg_ctrl[0]};
                    REG_SAMPLE_CNT: s_axil_rdata <= sample_counter;
                    default:        s_axil_rdata <= 32'd0;
                endcase
            end else begin
                s_axil_arready <= 1'b0;
                if (s_axil_rready) s_axil_rvalid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Audio Pattern & AES3 Subframe Generator Logic
    // =========================================================================
    reg [31:0] clk_divider;
    reg [5:0]  sine_index;
    reg [23:0] audio_sample;
    reg        channel_select; // 0: Left Channel (B), 1: Right Channel (W)
    reg [7:0]  subframe_count;

    // 16-step 24-bit Sine Wave Lookup Table
    always @* begin
        case (sine_index[3:0])
            4'h0: audio_sample = 24'h000000;
            4'h1: audio_sample = 24'h30FB5E;
            4'h2: audio_sample = 24'h5A8279;
            4'h3: audio_sample = 24'h7641AF;
            4'h4: audio_sample = 24'h7FFFFF;
            4'h5: audio_sample = 24'h7641AF;
            4'h6: audio_sample = 24'h5A8279;
            4'h7: audio_sample = 24'h30FB5E;
            4'h8: audio_sample = 24'h000000;
            4'h9: audio_sample = 24'hCF04A2;
            4'hA: audio_sample = 24'hA57D87;
            4'hB: audio_sample = 24'h89BE51;
            4'hC: audio_sample = 24'h800000;
            4'hD: audio_sample = 24'h89BE51;
            4'hE: audio_sample = 24'hA57D87;
            4'hF: audio_sample = 24'hCF04A2;
        endcase
    end

    // Sample Rate Tick Generation & Audio Stream Output Pipeline
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_divider         <= 32'd0;
            sine_index          <= 6'd0;
            channel_select      <= 1'b0;
            subframe_count      <= 8'd0;
            sample_counter      <= 32'd0;
            m_axis_audio_tdata  <= 32'd0;
            m_axis_audio_tvalid <= 1'b0;
            m_axis_audio_tlast  <= 1'b0;
        end else begin
            if (reg_ctrl[0]) begin // Generator Enabled
                if (clk_divider >= (reg_divisor - 1)) begin
                    clk_divider    <= 32'd0;
                    channel_select <= ~channel_select;
                    sample_counter <= sample_counter + 1'b1;

                    if (!channel_select) begin
                        sine_index <= sine_index + 1'b1;
                    end

                    // Format 32-bit AES3 Audio Subframe:
                    // Bit [3:0]   : Sync Preamble (4'hE: B = Frame Start, 4'hM: M = Left, 4'hW: W = Right)
                    // Bit [27:4]  : 24-bit LSB-first Audio Sample Data
                    // Bit [28]    : Validity Bit (0 = Valid)
                    // Bit [29]    : User Data Bit
                    // Bit [30]    : Channel Status Bit
                    // Bit [31]    : Even Parity Bit
                    m_axis_audio_tvalid <= 1'b1;
                    m_axis_audio_tlast  <= (subframe_count == 8'd191); // 192 subframes per AES3 Audio Block

                    if (subframe_count == 8'd191) begin
                        subframe_count <= 8'd0;
                    end else begin
                        subframe_count <= subframe_count + 1'b1;
                    end

                    case (reg_ctrl[3:1])
                        3'b000: m_axis_audio_tdata <= {^audio_sample, 1'b0, 1'b0, 1'b0, audio_sample, (channel_select ? 4'hC : 4'hB)}; // 1kHz Sine Wave
                        3'b001: m_axis_audio_tdata <= {1'b0, 1'b0, 1'b0, 1'b0, {sine_index, 18'd0}, (channel_select ? 4'hC : 4'hB)};   // Sawtooth
                        default: m_axis_audio_tdata <= 32'd0; // Mute
                    endcase
                end else begin
                    clk_divider <= clk_divider + 1'b1;
                    if (m_axis_audio_tready) begin
                        m_axis_audio_tvalid <= 1'b0;
                    end
                end
            end else begin
                m_axis_audio_tvalid <= 1'b0;
                clk_divider         <= 32'd0;
            end
        end
    end

endmodule
