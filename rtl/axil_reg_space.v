// ============================================================================
// Module: axil_reg_space
// Description: BAR0 AXI4-Lite Control & Status Register Space.
//              Contains DMA Ring Configuration, Interrupt Registers, Completed Counters,
//              and Firmware Version / Git Commit / Build Timestamp / Capabilities Regs.
// ============================================================================

`timescale 1ns / 1ps

module axil_reg_space (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite Slave Interface
    input  wire [31:0] s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output reg         s_axil_wready,
    output reg  [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,

    input  wire [31:0] s_axil_araddr,
    input  wire        s_axil_arvalid,
    output reg         s_axil_arready,
    output reg  [31:0] s_axil_rdata,
    output reg  [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,

    // Exported Register Signals
    output reg  [31:0] reg_dma_ctrl,
    input  wire [31:0] reg_dma_status,

    output reg  [63:0] reg_h2c_ring_addr,
    output reg  [15:0] reg_h2c_ring_size,
    output reg  [15:0] reg_h2c_tail_ptr,

    output reg  [63:0] reg_c2h_ring_addr,
    output reg  [15:0] reg_c2h_ring_size,
    output reg  [15:0] reg_c2h_tail_ptr,

    output reg  [31:0]           reg_irq_ctrl,
    input  wire [31:0]           reg_irq_status,
    output reg  [31:0]           reg_irq_status_w1c,
    output reg  [31:0]           reg_pacer_ctrl,
    output reg  [31:0]           reg_slice_height,
    output reg  [31:0]           reg_video_ctrl,
    output reg  [31:0]           reg_video_sub_reset,

    input  wire [31:0] reg_sof_count,
    input  wire [31:0] reg_eol_count,
    input  wire [31:0] reg_beat_count,

    input  wire [31:0] completed_h2c_count,
    input  wire [31:0] completed_c2h_count,
    input  wire [15:0] reg_h2c_head_ptr,
    input  wire [15:0] reg_c2h_head_ptr,

    // Telemetry & Hardware AV Sync Input Registers
    input  wire [63:0] reg_global_timestamp,
    input  wire [63:0] reg_last_video_pts,
    input  wire [63:0] reg_last_audio_pts,
    input  wire [31:0] reg_frame_drop_count,
    input  wire [31:0] reg_bandwidth_bps,
    input  wire [31:0] reg_latency_max_ns,

    // Hardware Performance Monitor Ports (BAR0 Offsets 0xA0..0xDC)
    output wire        perf_enable,
    output wire        perf_reset,
    input  wire [63:0] reg_perf_cycles,
    input  wire [31:0] reg_perf_tlp_count,
    input  wire [63:0] reg_perf_payload_bytes,
    input  wire [31:0] reg_perf_tx_active_cycles,
    input  wire [31:0] reg_perf_tx_idle_cycles,
    input  wire [31:0] reg_perf_tready_stall_cycles,
    input  wire [31:0] reg_perf_inter_tlp_gap,
    input  wire [31:0] reg_perf_tlp_128b_count,
    input  wire [31:0] reg_perf_tlp_256b_count,
    input  wire [31:0] reg_perf_split_4k_count,
    input  wire [15:0] reg_perf_max_queue_depth,
    input  wire [31:0] reg_perf_idle_cdc_empty,
    input  wire [31:0] reg_perf_idle_no_req,

    // Scatter-Gather Page Table Programming Ports (BAR0 Offsets 0xE0..0xEC)
    output reg         pt_y_wr_en,
    output reg  [10:0] pt_y_wr_addr,
    output reg  [63:0] pt_y_wr_data,
    output reg         pt_uv_wr_en,
    output reg  [10:0] pt_uv_wr_addr,
    output reg  [63:0] pt_uv_wr_data,
    input  wire [10:0] cur_y_page_idx,
    input  wire [10:0] cur_uv_page_idx,

    // Audio DMA Configuration & Status Ports (BAR0 Offsets 0x48, 0x4C, 0x94, 0x98, 0x100..0x160)
    output reg  [63:0] reg_audio_dma_addr,
    output reg  [31:0] reg_audio_dma_cfg,
    input  wire [31:0] reg_audio_dma_ptr,

    output reg  [63:0] reg_audio_dma_addr_ch1,
    output reg  [31:0] reg_audio_dma_cfg_ch1,
    input  wire [31:0] reg_audio_dma_ptr_ch1,

    output reg  [63:0] reg_audio_dma_addr_ch2,
    output reg  [31:0] reg_audio_dma_cfg_ch2,
    input  wire [31:0] reg_audio_dma_ptr_ch2,

    output reg  [63:0] reg_audio_dma_addr_ch3,
    output reg  [31:0] reg_audio_dma_cfg_ch3,
    input  wire [31:0] reg_audio_dma_ptr_ch3,

    // H2C Playback FIFO Ports
    output reg         h2c_fifo_wr_en_ch1,
    output reg         h2c_fifo_wr_en_ch2,
    output reg         h2c_fifo_wr_en_ch3,
    output wire [31:0] h2c_fifo_wr_data,
    input  wire [7:0]  h2c_fifo_count_ch1,
    input  wire [7:0]  h2c_fifo_count_ch2,
    input  wire [7:0]  h2c_fifo_count_ch3,
    input  wire        h2c_fifo_full_ch1,
    input  wire        h2c_fifo_full_ch2,
    input  wire        h2c_fifo_full_ch3,
    input  wire        h2c_fifo_empty_ch1,
    input  wire        h2c_fifo_empty_ch2,
    input  wire        h2c_fifo_empty_ch3,

    output reg  [31:0] reg_audio_loopback_ctrl
);

    // BAR0 Register Offset Definitions
    localparam ADDR_DMA_CTRL         = 8'h00;
    localparam ADDR_DMA_STATUS       = 8'h04;
    localparam ADDR_H2C_RING_ADDR_L  = 8'h08;
    localparam ADDR_H2C_RING_ADDR_H  = 8'h0C;
    localparam ADDR_H2C_RING_CFG     = 8'h10;
    localparam ADDR_C2H_RING_ADDR_L  = 8'h14;
    localparam ADDR_C2H_RING_ADDR_H  = 8'h18;
    localparam ADDR_C2H_RING_CFG     = 8'h1C;
    localparam ADDR_IRQ_CTRL         = 8'h20;
    localparam ADDR_IRQ_STATUS       = 8'h24;
    localparam ADDR_COMPLETED_H2C    = 8'h28;
    localparam ADDR_COMPLETED_C2H    = 8'h2C;

    // New Version & Capability Registers (Read-Only)
    localparam ADDR_VERSION_ID       = 8'h30; // Major[31:24], Minor[23:16], Patch[15:8], Variant[7:0]
    localparam ADDR_GIT_COMMIT_HASH  = 8'h34; // Git Commit Hash (Lower 32-bit)
    localparam ADDR_BUILD_TIMESTAMP  = 8'h38; // BCD Date YYYYMMDD
    localparam ADDR_HARDWARE_CAPS    = 8'h3C; // Caps: [23:16]=NumAudioCh, [15:8]=NumVideoCh, [3:0]=Flags

    `ifndef GIT_COMMIT_HASH_DEF
        `define GIT_COMMIT_HASH_DEF 32'h01D6_A9C5
    `endif

    `ifndef BUILD_TIMESTAMP_DEF
        `define BUILD_TIMESTAMP_DEF 32'h2026_0821
    `endif

    // Hardware Debug Write Capture Registers
    reg [31:0] reg_debug_last_wdata;
    reg [31:0] reg_debug_last_waddr;

    // Performance Monitor Control Registers
    reg reg_perf_enable;
    reg reg_perf_reset_w1c;

    assign perf_enable = reg_perf_enable;
    assign perf_reset  = reg_perf_reset_w1c;
    assign h2c_fifo_wr_data = s_axil_wdata;

    // Version Constant Constants
    localparam [31:0] VERSION_ID_VAL      = 32'h0201_0001; // v2.1.0 (Variant 1)
    localparam [31:0] GIT_COMMIT_HASH_VAL = `GIT_COMMIT_HASH_DEF;
    localparam [31:0] BUILD_TIMESTAMP_VAL = `BUILD_TIMESTAMP_DEF;
    localparam [31:0] HARDWARE_CAPS_VAL   = 32'h0004_040F; // 4 Audio, 4 Video, Caps: 2D+AES3+DualBAR+Stream

    // Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_dma_ctrl       <= 32'd0;
            reg_h2c_ring_addr  <= 64'd0;
            reg_h2c_ring_size  <= 16'd0;
            reg_h2c_tail_ptr   <= 16'd0;
            reg_c2h_ring_addr  <= 64'd0;
            reg_c2h_ring_size  <= 16'd0;
            reg_c2h_tail_ptr   <= 16'd0;
            reg_audio_dma_addr <= 64'd0;
            reg_audio_dma_cfg  <= 32'h1000_0000; // Default: period 4096 (0x1000), buffer 65536
            reg_audio_dma_addr_ch1 <= 64'd0;
            reg_audio_dma_cfg_ch1  <= 32'h1000_0000;
            reg_audio_dma_addr_ch2 <= 64'd0;
            reg_audio_dma_cfg_ch2  <= 32'h1000_0000;
            reg_audio_dma_addr_ch3 <= 64'd0;
            reg_audio_dma_cfg_ch3  <= 32'h1000_0000;
            h2c_fifo_wr_en_ch1     <= 1'b0;
            h2c_fifo_wr_en_ch2     <= 1'b0;
            h2c_fifo_wr_en_ch3     <= 1'b0;
            reg_audio_loopback_ctrl<= 32'h0000_0007; // Default: Pacer enabled for Ch1, Ch2, Ch3
            reg_irq_ctrl       <= 32'd0;
            reg_irq_status_w1c <= 32'd0;
            reg_pacer_ctrl     <= 32'd1; // Default: 1 (Enabled - Internal Clock Pacer Mode)
            reg_slice_height   <= 32'd0; // Default: 0 (Disabled - Full Frame IRQ)
            reg_video_ctrl     <= 32'd0; // Bit 0: reset TPG and video CDC FIFO
            reg_video_sub_reset<= 32'd0; // Bit 0: TPG-only reset, Bit 1: NV12 engine reset
            reg_perf_enable    <= 1'b0;
            reg_perf_reset_w1c <= 1'b0;
            pt_y_wr_en         <= 1'b0;
            pt_y_wr_addr       <= 11'd0;
            pt_y_wr_data       <= 64'd0;
            pt_uv_wr_en        <= 1'b0;
            pt_uv_wr_addr      <= 11'd0;
            pt_uv_wr_data      <= 64'd0;
            reg_debug_last_wdata <= 32'd0;
            reg_debug_last_waddr <= 32'd0;
            s_axil_awready       <= 1'b0;
            s_axil_wready     <= 1'b0;
            s_axil_bvalid     <= 1'b0;
            s_axil_bresp      <= 2'b00; // OKAY
        end else begin
            reg_irq_status_w1c <= 32'd0;
            reg_perf_reset_w1c <= 1'b0;
            pt_y_wr_en         <= 1'b0;
            pt_uv_wr_en        <= 1'b0;
            h2c_fifo_wr_en_ch1 <= 1'b0;
            h2c_fifo_wr_en_ch2 <= 1'b0;
            h2c_fifo_wr_en_ch3 <= 1'b0;
            if (s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid) begin
                s_axil_awready <= 1'b1;
                s_axil_wready  <= 1'b1;
                s_axil_bvalid  <= 1'b1;

                case (s_axil_awaddr[8:0])
                    ADDR_DMA_CTRL:        reg_dma_ctrl             <= s_axil_wdata;
                    ADDR_H2C_RING_ADDR_L: reg_h2c_ring_addr[31:0]  <= s_axil_wdata;
                    ADDR_H2C_RING_ADDR_H: reg_h2c_ring_addr[63:32] <= s_axil_wdata;
                    ADDR_H2C_RING_CFG: begin
                        reg_h2c_ring_size <= s_axil_wdata[15:0];
                        reg_h2c_tail_ptr  <= s_axil_wdata[31:16];
                    end
                    ADDR_C2H_RING_ADDR_L: reg_c2h_ring_addr[31:0]  <= s_axil_wdata;
                    ADDR_C2H_RING_ADDR_H: reg_c2h_ring_addr[63:32] <= s_axil_wdata;
                    ADDR_C2H_RING_CFG: begin
                        reg_c2h_ring_size <= s_axil_wdata[15:0];
                        reg_c2h_tail_ptr  <= s_axil_wdata[31:16];
                    end
                    9'h048:               reg_audio_dma_addr[31:0]  <= s_axil_wdata;
                    9'h04C:               reg_audio_dma_addr[63:32] <= s_axil_wdata;
                    ADDR_IRQ_CTRL:        reg_irq_ctrl             <= s_axil_wdata;
                    ADDR_IRQ_STATUS:      reg_irq_status_w1c       <= s_axil_wdata;
                    9'h068:               reg_debug_last_wdata     <= s_axil_wdata;
                    9'h06C:               reg_debug_last_waddr     <= {20'd0, s_axil_awaddr[11:0]};
                    9'h074:               reg_pacer_ctrl           <= s_axil_wdata; // BAR0 0x74: Pacer Control
                    9'h078:               reg_slice_height         <= s_axil_wdata; // BAR0 0x78: Sub-Frame Slice Height
                    9'h080:               reg_video_ctrl           <= s_axil_wdata; // BAR0 0x80: Video Pipeline Control
                    9'h084:               reg_video_sub_reset      <= s_axil_wdata; // BAR0 0x84: Sub-Domain Reset Control
                    9'h094:               reg_audio_dma_cfg         <= s_axil_wdata; // BAR0 0x94: Audio DMA Config (period/buffer)
                    9'h0A0: begin
                        reg_perf_enable    <= s_axil_wdata[0];
                        reg_perf_reset_w1c <= s_axil_wdata[1];
                    end
                    9'h0E0: begin
                        pt_y_wr_addr  <= s_axil_wdata[10:0];
                        pt_uv_wr_addr <= s_axil_wdata[10:0];
                    end
                    9'h0E4: begin
                        pt_y_wr_data[31:0]  <= s_axil_wdata;
                        pt_uv_wr_data[31:0] <= s_axil_wdata;
                    end
                    9'h0E8: begin
                        pt_y_wr_data[63:32]  <= s_axil_wdata;
                        pt_uv_wr_data[63:32] <= s_axil_wdata;
                        if (!s_axil_wdata[31]) begin // Bit 31: 0 = Y Plane, 1 = UV Plane
                            pt_y_wr_en   <= 1'b1;
                            pt_y_wr_addr <= pt_y_wr_addr + 1'b1;
                        end else begin
                            pt_uv_wr_en   <= 1'b1;
                            pt_uv_wr_addr <= pt_uv_wr_addr + 1'b1;
                        end
                    end

                    // Audio Ch0 DMA Aliases (0x100..0x108)
                    9'h100: reg_audio_dma_addr[31:0]  <= s_axil_wdata;
                    9'h104: reg_audio_dma_addr[63:32] <= s_axil_wdata;
                    9'h108: reg_audio_dma_cfg         <= s_axil_wdata;

                    // Audio Ch1 DMA (0x110..0x118)
                    9'h110: reg_audio_dma_addr_ch1[31:0]  <= s_axil_wdata;
                    9'h114: reg_audio_dma_addr_ch1[63:32] <= s_axil_wdata;
                    9'h118: reg_audio_dma_cfg_ch1         <= s_axil_wdata;

                    // Audio Ch2 DMA (0x120..0x128)
                    9'h120: reg_audio_dma_addr_ch2[31:0]  <= s_axil_wdata;
                    9'h124: reg_audio_dma_addr_ch2[63:32] <= s_axil_wdata;
                    9'h128: reg_audio_dma_cfg_ch2         <= s_axil_wdata;

                    // Audio Ch3 DMA (0x130..0x138)
                    9'h130: reg_audio_dma_addr_ch3[31:0]  <= s_axil_wdata;
                    9'h134: reg_audio_dma_addr_ch3[63:32] <= s_axil_wdata;
                    9'h138: reg_audio_dma_cfg_ch3         <= s_axil_wdata;

                    // Audio Playback H2C Data (0x150, 0x154, 0x158)
                    9'h150: h2c_fifo_wr_en_ch1 <= 1'b1;
                    9'h154: h2c_fifo_wr_en_ch2 <= 1'b1;
                    9'h158: h2c_fifo_wr_en_ch3 <= 1'b1;

                    // Audio Loopback Control (0x160)
                    9'h160: reg_audio_loopback_ctrl <= s_axil_wdata;
                    default: ; // Ignore writes to read-only registers
                endcase
                reg_debug_last_wdata <= s_axil_wdata;
                reg_debug_last_waddr <= {24'd0, s_axil_awaddr[7:0]};
            end else begin
                s_axil_awready <= 1'b0;
                s_axil_wready  <= 1'b0;
                if (s_axil_bready && s_axil_bvalid) begin
                    s_axil_bvalid <= 1'b0;
                end
            end
        end
    end

    // Read Logic
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

                case (s_axil_araddr[8:0])
                    ADDR_DMA_CTRL:        s_axil_rdata <= reg_dma_ctrl;
                    ADDR_DMA_STATUS:      s_axil_rdata <= reg_dma_status;
                    ADDR_H2C_RING_ADDR_L: s_axil_rdata <= reg_h2c_ring_addr[31:0];
                    ADDR_H2C_RING_ADDR_H: s_axil_rdata <= reg_h2c_ring_addr[63:32];
                    ADDR_H2C_RING_CFG:    s_axil_rdata <= {reg_h2c_tail_ptr, reg_h2c_ring_size};
                    ADDR_C2H_RING_ADDR_L: s_axil_rdata <= reg_c2h_ring_addr[31:0];
                    ADDR_C2H_RING_ADDR_H: s_axil_rdata <= reg_c2h_ring_addr[63:32];
                    ADDR_C2H_RING_CFG:    s_axil_rdata <= {reg_c2h_tail_ptr, reg_c2h_ring_size};
                    ADDR_IRQ_CTRL:        s_axil_rdata <= reg_irq_ctrl;
                    ADDR_IRQ_STATUS:      s_axil_rdata <= reg_irq_status;
                    ADDR_COMPLETED_H2C:   s_axil_rdata <= completed_h2c_count;
                    ADDR_COMPLETED_C2H:   s_axil_rdata <= completed_c2h_count;

                    // New Version & Firmware Capability Registers
                    ADDR_VERSION_ID:      s_axil_rdata <= VERSION_ID_VAL;
                    ADDR_GIT_COMMIT_HASH: s_axil_rdata <= GIT_COMMIT_HASH_VAL;
                    ADDR_BUILD_TIMESTAMP: s_axil_rdata <= BUILD_TIMESTAMP_VAL;
                    ADDR_HARDWARE_CAPS:   s_axil_rdata <= HARDWARE_CAPS_VAL;
                    9'h040:               s_axil_rdata <= {reg_h2c_tail_ptr, reg_h2c_head_ptr};
                    9'h044:               s_axil_rdata <= {reg_c2h_tail_ptr, reg_c2h_head_ptr};
                    9'h048:               s_axil_rdata <= reg_audio_dma_addr[31:0];
                    9'h04C:               s_axil_rdata <= reg_audio_dma_addr[63:32];

                    // Hardware AV Sync Timestamp Registers (BAR0 Offsets 0x50..0x64)
                    9'h050:               s_axil_rdata <= reg_global_timestamp[31:0];
                    9'h054:               s_axil_rdata <= reg_global_timestamp[63:32];
                    9'h058:               s_axil_rdata <= reg_last_video_pts[31:0];
                    9'h05C:               s_axil_rdata <= reg_last_video_pts[63:32];
                    9'h060:               s_axil_rdata <= reg_last_audio_pts[31:0];
                    9'h064:               s_axil_rdata <= reg_last_audio_pts[63:32];

                    // Hardware Telemetry & Frame Dropper Registers (BAR0 Offsets 0x68..0x78)
                    9'h068:               s_axil_rdata <= reg_debug_last_wdata;
                    9'h06C:               s_axil_rdata <= reg_debug_last_waddr;
                    9'h070:               s_axil_rdata <= reg_latency_max_ns;
                    9'h074:               s_axil_rdata <= reg_pacer_ctrl;
                    9'h078:               s_axil_rdata <= reg_slice_height;
                    9'h07C:               s_axil_rdata <= reg_frame_drop_count;
                    9'h080:               s_axil_rdata <= reg_video_ctrl;
                    9'h084:               s_axil_rdata <= reg_video_sub_reset;
                    9'h088:               s_axil_rdata <= reg_sof_count;
                    9'h08C:               s_axil_rdata <= reg_eol_count;
                    9'h090:               s_axil_rdata <= reg_beat_count;
                    9'h094:               s_axil_rdata <= reg_audio_dma_cfg;
                    9'h098:               s_axil_rdata <= reg_audio_dma_ptr;

                    // Hardware Performance Monitor Registers (BAR0 Offsets 0xA0..0xDC)
                    9'h0A0:               s_axil_rdata <= {30'd0, reg_perf_reset_w1c, reg_perf_enable};
                    9'h0A4:               s_axil_rdata <= reg_perf_cycles[31:0];
                    9'h0A8:               s_axil_rdata <= reg_perf_cycles[63:32];
                    9'h0AC:               s_axil_rdata <= reg_perf_tlp_count;
                    9'h0B0:               s_axil_rdata <= reg_perf_payload_bytes[31:0];
                    9'h0B4:               s_axil_rdata <= reg_perf_payload_bytes[63:32];
                    9'h0B8:               s_axil_rdata <= reg_perf_tx_active_cycles;
                    9'h0BC:               s_axil_rdata <= reg_perf_tx_idle_cycles;
                    9'h0C0:               s_axil_rdata <= reg_perf_tready_stall_cycles;
                    9'h0C4:               s_axil_rdata <= reg_perf_inter_tlp_gap;
                    9'h0C8:               s_axil_rdata <= reg_perf_tlp_128b_count;
                    9'h0CC:               s_axil_rdata <= reg_perf_tlp_256b_count;
                    9'h0D0:               s_axil_rdata <= reg_perf_split_4k_count;
                    9'h0D4:               s_axil_rdata <= {16'd0, reg_perf_max_queue_depth};
                    9'h0D8:               s_axil_rdata <= reg_perf_idle_cdc_empty;
                    9'h0DC:               s_axil_rdata <= reg_perf_idle_no_req;

                    // Scatter-Gather Page Table & Status Registers (BAR0 0xE0..0xEC)
                    9'h0E0:               s_axil_rdata <= {21'd0, pt_y_wr_addr};
                    9'h0E4:               s_axil_rdata <= pt_y_wr_data[31:0];
                    9'h0E8:               s_axil_rdata <= pt_y_wr_data[63:32];
                    9'h0EC:               s_axil_rdata <= {5'd0, cur_uv_page_idx, 5'd0, cur_y_page_idx};

                    // Audio Ch0 aliases (0x100..0x10C)
                    9'h100:               s_axil_rdata <= reg_audio_dma_addr[31:0];
                    9'h104:               s_axil_rdata <= reg_audio_dma_addr[63:32];
                    9'h108:               s_axil_rdata <= reg_audio_dma_cfg;
                    9'h10C:               s_axil_rdata <= reg_audio_dma_ptr;

                    // Audio Ch1 (0x110..0x11C)
                    9'h110:               s_axil_rdata <= reg_audio_dma_addr_ch1[31:0];
                    9'h114:               s_axil_rdata <= reg_audio_dma_addr_ch1[63:32];
                    9'h118:               s_axil_rdata <= reg_audio_dma_cfg_ch1;
                    9'h11C:               s_axil_rdata <= reg_audio_dma_ptr_ch1;

                    // Audio Ch2 (0x120..0x12C)
                    9'h120:               s_axil_rdata <= reg_audio_dma_addr_ch2[31:0];
                    9'h124:               s_axil_rdata <= reg_audio_dma_addr_ch2[63:32];
                    9'h128:               s_axil_rdata <= reg_audio_dma_cfg_ch2;
                    9'h12C:               s_axil_rdata <= reg_audio_dma_ptr_ch2;

                    // Audio Ch3 (0x130..0x13C)
                    9'h130:               s_axil_rdata <= reg_audio_dma_addr_ch3[31:0];
                    9'h134:               s_axil_rdata <= reg_audio_dma_addr_ch3[63:32];
                    9'h138:               s_axil_rdata <= reg_audio_dma_cfg_ch3;
                    9'h13C:               s_axil_rdata <= reg_audio_dma_ptr_ch3;

                    // Audio H2C FIFO Status (0x15C)
                    9'h15C:               s_axil_rdata <= {
                        1'b0,
                        h2c_fifo_empty_ch3, h2c_fifo_empty_ch2, h2c_fifo_empty_ch1, // [30:28]
                        1'b0,
                        h2c_fifo_full_ch3,  h2c_fifo_full_ch2,  h2c_fifo_full_ch1,  // [26:24]
                        h2c_fifo_count_ch3,                                         // [23:16]
                        h2c_fifo_count_ch2,                                         // [15:8]
                        h2c_fifo_count_ch1                                          // [7:0]
                    };

                    // Audio Loopback Control (0x160)
                    9'h160:               s_axil_rdata <= reg_audio_loopback_ctrl;

                    default:              s_axil_rdata <= 32'hDEAD_BEEF;
                endcase
            end else begin
                s_axil_arready <= 1'b0;
                if (s_axil_rready && s_axil_rvalid) begin
                    s_axil_rvalid <= 1'b0;
                end
            end
        end
    end

endmodule
