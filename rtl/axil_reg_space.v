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

    output reg  [31:0] reg_audio_loopback_ctrl,

    // Phase 3: Video CH0 & Mode Signals for Thin Descriptor Engine
    output wire [31:0] out_vch0_ctrl,
    output wire [31:0] out_vch0_width,
    output wire [31:0] out_vch0_height,
    output wire [31:0] out_vch0_stride0,
    output wire [31:0] out_vch0_stride1,
    output wire        out_map_mode_new,
    input  wire [31:0] in_vch0_frame_count,
    input  wire [31:0] in_vch0_drop_count
);

    // BAR0 Register Offset Definitions (12-bit decode aperture)
    localparam ADDR_DMA_CTRL         = 12'h000;
    localparam ADDR_DMA_STATUS       = 12'h004;
    localparam ADDR_H2C_RING_ADDR_L  = 12'h008;
    localparam ADDR_H2C_RING_ADDR_H  = 12'h00C;
    localparam ADDR_H2C_RING_CFG     = 12'h010;
    localparam ADDR_C2H_RING_ADDR_L  = 12'h014;
    localparam ADDR_C2H_RING_ADDR_H  = 12'h018;
    localparam ADDR_C2H_RING_CFG     = 12'h01C;
    localparam ADDR_IRQ_CTRL         = 12'h020;
    localparam ADDR_IRQ_STATUS       = 12'h024;
    localparam ADDR_COMPLETED_H2C    = 12'h028;
    localparam ADDR_COMPLETED_C2H    = 12'h02C;

    // New Version & Capability Registers (Read-Only)
    localparam ADDR_VERSION_ID       = 12'h030; // Major[31:24], Minor[23:16], Patch[15:8], Variant[7:0]
    localparam ADDR_GIT_COMMIT_HASH  = 12'h034; // Git Commit Hash (Lower 32-bit)
    localparam ADDR_BUILD_TIMESTAMP  = 12'h038; // BCD Date YYYYMMDD
    localparam ADDR_HARDWARE_CAPS    = 12'h03C; // Caps: [23:16]=NumAudioCh, [15:8]=NumVideoCh, [3:0]=Flags

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

    // Version & Capability Constants (v3.0.0 with NEW_MAP_PRESENT)
    localparam [31:0] VERSION_ID_VAL      = 32'h0300_0001; // v3.0.0 (Variant 1)
    localparam [31:0] GIT_COMMIT_HASH_VAL = `GIT_COMMIT_HASH_DEF;
    localparam [31:0] BUILD_TIMESTAMP_VAL = `BUILD_TIMESTAMP_DEF;
`ifdef QPCIe_single_rgb24_path
    // Single-path build: 4 Audio, 1 Video (RGB24 TPG only), Caps: 2D+AES3+DualBAR+Stream, [4]=NEW_MAP_PRESENT
    localparam [31:0] HARDWARE_CAPS_VAL   = 32'h0001_041F;
`else
    localparam [31:0] HARDWARE_CAPS_VAL   = 32'h0004_041F; // 4 Audio, 4 Video, Caps: 2D+AES3+DualBAR+Stream, [4]=NEW_MAP_PRESENT
`endif
    localparam [31:0] MAGIC_DEVICE_ID_VAL = 32'h12AB_E380;

    // ========================================================================
    // ========================================================================
    // ========================================================================
    // Phase 2: Dual-Map Mode Selection & New Register File Declarations
    // ========================================================================
    wire map_mode_new = reg_dma_ctrl[3]; // Bit 3: 0 = Legacy Map, 1 = Future v3.0 Map

    // Global Block (New Map: 0x0000 - 0x00FF)
    reg        global_reset_pulse;
    reg [31:0] irq_top_status_w1c;

    // Video CH0 Block (New Map: 0x0100 - 0x01FF)
    reg  [31:0] vch0_ctrl;
    reg  [31:0] vch0_status;
    reg  [31:0] vch0_width;
    reg  [31:0] vch0_height;
    reg  [31:0] vch0_stride0;
    reg  [31:0] vch0_stride1;
    reg  [31:0] vch0_irq_status_w1c;

    // Audio DEV0 Block (New Map: 0x0500 - 0x05FF)
    reg  [31:0] adev0_ctrl;
    reg  [31:0] adev0_status;
    reg  [31:0] adev0_rate;
    reg  [31:0] adev0_period_bytes;
    reg  [31:0] adev0_buffer_bytes;
    reg  [63:0] adev0_ring0_base;
    reg  [31:0] adev0_ring0_cfg;
    reg  [31:0] adev0_irq_w1c;

    // Debug Block (New Map: 0x0900 - 0x09FF)
    reg  [31:0] dbg_pattern_gen;

    assign out_vch0_ctrl     = vch0_ctrl;
    assign out_vch0_width    = vch0_width;
    assign out_vch0_height   = vch0_height;
    assign out_vch0_stride0  = vch0_stride0;
    assign out_vch0_stride1  = vch0_stride1;
    assign out_map_mode_new  = map_mode_new;

    // Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_dma_ctrl           <= 32'd0;
            reg_h2c_ring_addr      <= 64'd0;
            reg_h2c_ring_size      <= 16'd0;
            reg_h2c_tail_ptr       <= 16'd0;
            reg_c2h_ring_addr      <= 64'd0;
            reg_c2h_ring_size      <= 16'd0;
            reg_c2h_tail_ptr       <= 16'd0;
            reg_audio_dma_addr     <= 64'd0;
            reg_audio_dma_cfg      <= 32'h1000_0000; // Default: period 4096 (0x1000), buffer 65536
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
            reg_irq_ctrl           <= 32'd0;
            reg_irq_status_w1c     <= 32'd0;
            reg_pacer_ctrl         <= 32'd1; // Default: 1 (Enabled - Internal Clock Pacer Mode)
            reg_slice_height       <= 32'd0; // Default: 0 (Disabled - Full Frame IRQ)
            reg_video_ctrl         <= 32'd0; // Bit 0: reset TPG and video CDC FIFO
            reg_video_sub_reset    <= 32'd0; // Bit 0: TPG-only reset, Bit 1: NV12 engine reset
            reg_perf_enable        <= 1'b0;
            reg_perf_reset_w1c     <= 1'b0;
            pt_y_wr_en             <= 1'b0;
            pt_y_wr_addr           <= 11'd0;
            pt_y_wr_data           <= 64'd0;
            pt_uv_wr_en            <= 1'b0;
            pt_uv_wr_addr          <= 11'd0;
            pt_uv_wr_data          <= 64'd0;
            reg_debug_last_wdata   <= 32'd0;
            reg_debug_last_waddr   <= 32'd0;
            global_reset_pulse     <= 1'b0;
            irq_top_status_w1c     <= 32'd0;
            vch0_ctrl              <= 32'd0;
            vch0_status            <= 32'd0;
            vch0_width             <= 32'd1920;
            vch0_height            <= 32'd1080;
            vch0_stride0           <= 32'd1920;
            vch0_stride1           <= 32'd1920;
            vch0_irq_status_w1c    <= 32'd0;
            adev0_ctrl             <= 32'd0;
            adev0_status           <= 32'd0;
            adev0_rate             <= 32'd48000;
            adev0_period_bytes     <= 32'd4096;
            adev0_buffer_bytes     <= 32'd65536;
            adev0_ring0_base       <= 64'd0;
            adev0_ring0_cfg        <= 32'd0;
            adev0_irq_w1c          <= 32'd0;
            dbg_pattern_gen        <= 32'd0;
            s_axil_awready         <= 1'b0;
            s_axil_wready          <= 1'b0;
            s_axil_bvalid          <= 1'b0;
            s_axil_bresp           <= 2'b00; // OKAY
        end else begin
            reg_irq_status_w1c  <= 32'd0;
            reg_perf_reset_w1c  <= 1'b0;
            pt_y_wr_en          <= 1'b0;
            pt_uv_wr_en         <= 1'b0;
            h2c_fifo_wr_en_ch1  <= 1'b0;
            h2c_fifo_wr_en_ch2  <= 1'b0;
            h2c_fifo_wr_en_ch3  <= 1'b0;
            global_reset_pulse  <= 1'b0;
            irq_top_status_w1c  <= 32'd0;
            vch0_irq_status_w1c <= 32'd0;
            adev0_irq_w1c       <= 32'd0;
            if (s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid) begin
                s_axil_awready <= 1'b1;
                s_axil_wready  <= 1'b1;
                s_axil_bvalid  <= 1'b1;

                case (s_axil_awaddr[11:8])
                    4'h0: begin
                        if (!map_mode_new) begin
                            case (s_axil_awaddr[7:0])
                                ADDR_DMA_CTRL[7:0]:        reg_dma_ctrl             <= s_axil_wdata;
                                ADDR_H2C_RING_ADDR_L[7:0]: reg_h2c_ring_addr[31:0]  <= s_axil_wdata;
                                ADDR_H2C_RING_ADDR_H[7:0]: reg_h2c_ring_addr[63:32] <= s_axil_wdata;
                                ADDR_H2C_RING_CFG[7:0]: begin
                                    reg_h2c_ring_size <= s_axil_wdata[15:0];
                                    reg_h2c_tail_ptr  <= s_axil_wdata[31:16];
                                end
                                ADDR_C2H_RING_ADDR_L[7:0]: reg_c2h_ring_addr[31:0]  <= s_axil_wdata;
                                ADDR_C2H_RING_ADDR_H[7:0]: reg_c2h_ring_addr[63:32] <= s_axil_wdata;
                                ADDR_C2H_RING_CFG[7:0]: begin
                                    reg_c2h_ring_size <= s_axil_wdata[15:0];
                                    reg_c2h_tail_ptr  <= s_axil_wdata[31:16];
                                end
                                8'h48:                     reg_audio_dma_addr[31:0]  <= s_axil_wdata;
                                8'h4C:                     reg_audio_dma_addr[63:32] <= s_axil_wdata;
                                ADDR_IRQ_CTRL[7:0]:        reg_irq_ctrl             <= s_axil_wdata;
                                ADDR_IRQ_STATUS[7:0]:      reg_irq_status_w1c       <= s_axil_wdata;
                                8'h68:                     reg_debug_last_wdata     <= s_axil_wdata;
                                8'h6C:                     reg_debug_last_waddr     <= {20'd0, s_axil_awaddr[11:0]};
                                8'h74:                     reg_pacer_ctrl           <= s_axil_wdata;
                                8'h78:                     reg_slice_height         <= s_axil_wdata;
                                8'h80:                     reg_video_ctrl           <= s_axil_wdata;
                                8'h84:                     reg_video_sub_reset      <= s_axil_wdata;
                                8'h94:                     reg_audio_dma_cfg        <= s_axil_wdata;
                                8'hA0: begin
                                    reg_perf_enable    <= s_axil_wdata[0];
                                    reg_perf_reset_w1c <= s_axil_wdata[1];
                                end
                                8'hE0: begin
                                    pt_y_wr_addr  <= s_axil_wdata[10:0];
                                    pt_uv_wr_addr <= s_axil_wdata[10:0];
                                end
                                8'hE4: begin
                                    pt_y_wr_data[31:0]  <= s_axil_wdata;
                                    pt_uv_wr_data[31:0] <= s_axil_wdata;
                                end
                                8'hE8: begin
                                    pt_y_wr_data[63:32]  <= s_axil_wdata;
                                    pt_uv_wr_data[63:32] <= s_axil_wdata;
                                    if (!s_axil_wdata[31]) begin
                                        pt_y_wr_en   <= 1'b1;
                                        pt_y_wr_addr <= pt_y_wr_addr + 1'b1;
                                    end else begin
                                        pt_uv_wr_en   <= 1'b1;
                                        pt_uv_wr_addr <= pt_uv_wr_addr + 1'b1;
                                    end
                                end
                                default: ;
                            endcase
                        end else begin
                            case (s_axil_awaddr[7:0])
                                8'h00: reg_dma_ctrl       <= s_axil_wdata;
                                8'h14: global_reset_pulse <= s_axil_wdata[0];
                                8'h18: begin
                                    irq_top_status_w1c <= s_axil_wdata;
                                    reg_irq_status_w1c <= s_axil_wdata;
                                end
                                8'h20: reg_irq_ctrl       <= s_axil_wdata;
                                8'h24: reg_irq_status_w1c <= s_axil_wdata;
                                default: ;
                            endcase
                        end
                    end
                    4'h1: begin
                        if (!map_mode_new) begin
                            case (s_axil_awaddr[7:0])
                                8'h00: reg_audio_dma_addr[31:0]      <= s_axil_wdata;
                                8'h04: reg_audio_dma_addr[63:32]     <= s_axil_wdata;
                                8'h08: reg_audio_dma_cfg             <= s_axil_wdata;
                                8'h10: reg_audio_dma_addr_ch1[31:0]  <= s_axil_wdata;
                                8'h14: reg_audio_dma_addr_ch1[63:32] <= s_axil_wdata;
                                8'h18: reg_audio_dma_cfg_ch1         <= s_axil_wdata;
                                8'h20: reg_audio_dma_addr_ch2[31:0]  <= s_axil_wdata;
                                8'h24: reg_audio_dma_addr_ch2[63:32] <= s_axil_wdata;
                                8'h28: reg_audio_dma_cfg_ch2         <= s_axil_wdata;
                                8'h30: reg_audio_dma_addr_ch3[31:0]  <= s_axil_wdata;
                                8'h34: reg_audio_dma_addr_ch3[63:32] <= s_axil_wdata;
                                8'h38: reg_audio_dma_cfg_ch3         <= s_axil_wdata;
                                8'h50: h2c_fifo_wr_en_ch1            <= 1'b1;
                                8'h54: h2c_fifo_wr_en_ch2            <= 1'b1;
                                8'h58: h2c_fifo_wr_en_ch3            <= 1'b1;
                                8'h60: reg_audio_loopback_ctrl       <= s_axil_wdata;
                                default: ;
                            endcase
                        end else begin
                            case (s_axil_awaddr[7:0])
                                8'h00: vch0_ctrl                    <= s_axil_wdata;
                                8'h04: if (s_axil_wdata[31]) vch0_status[31] <= 1'b0;
                                8'h08: vch0_width                   <= s_axil_wdata;
                                8'h0C: vch0_height                  <= s_axil_wdata;
                                8'h10: vch0_stride0                 <= s_axil_wdata;
                                8'h14: vch0_stride1                 <= s_axil_wdata;
                                8'h20: reg_c2h_ring_addr[31:0]      <= s_axil_wdata; // Shared with CH0 Ring0 Base L
                                8'h24: reg_c2h_ring_addr[63:32]     <= s_axil_wdata; // Shared with CH0 Ring0 Base H
                                8'h28: begin                                         // Shared with CH0 Ring0 Cfg
                                    reg_c2h_ring_size               <= s_axil_wdata[15:0];
                                    reg_c2h_tail_ptr                <= s_axil_wdata[31:16];
                                end
                                8'h30: reg_h2c_ring_addr[31:0]      <= s_axil_wdata; // Shared with CH0 Ring1 Base L
                                8'h34: reg_h2c_ring_addr[63:32]     <= s_axil_wdata; // Shared with CH0 Ring1 Base H
                                8'h38: begin                                         // Shared with CH0 Ring1 Cfg
                                    reg_h2c_ring_size               <= s_axil_wdata[15:0];
                                    reg_h2c_tail_ptr                <= s_axil_wdata[31:16];
                                end
                                8'h70: begin
                                    vch0_irq_status_w1c   <= s_axil_wdata;
                                    reg_irq_status_w1c[4] <= s_axil_wdata[0];
                                end
                                default: ;
                            endcase
                        end
                    end
                    4'h5: begin
                        if (map_mode_new) begin
                            case (s_axil_awaddr[7:0])
                                8'h00: adev0_ctrl                 <= s_axil_wdata;
                                8'h04: if (s_axil_wdata[1]) adev0_status[1] <= 1'b0;
                                8'h08: adev0_rate                 <= s_axil_wdata;
                                8'h0C: adev0_period_bytes         <= s_axil_wdata;
                                8'h10: adev0_buffer_bytes         <= s_axil_wdata;
                                8'h20: adev0_ring0_base[31:0]     <= s_axil_wdata;
                                8'h24: adev0_ring0_base[63:32]    <= s_axil_wdata;
                                8'h28: adev0_ring0_cfg            <= s_axil_wdata;
                                8'hA8: adev0_irq_w1c              <= s_axil_wdata;
                                default: ;
                            endcase
                        end
                    end
                    4'h9: begin
                        if (map_mode_new) begin
                            case (s_axil_awaddr[7:0])
                                8'h00: reg_audio_loopback_ctrl <= s_axil_wdata;
                                8'h04: dbg_pattern_gen         <= s_axil_wdata;
                                8'h08: reg_pacer_ctrl          <= s_axil_wdata;
                                default: ;
                            endcase
                        end
                    end
                    default: ;
                endcase
                reg_debug_last_wdata <= s_axil_wdata;
                reg_debug_last_waddr <= {20'd0, s_axil_awaddr[11:0]};
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

                case (s_axil_araddr[11:8])
                    4'h0: begin
                        if (!map_mode_new) begin
                            case (s_axil_araddr[7:0])
                                ADDR_DMA_CTRL[7:0]:        s_axil_rdata <= reg_dma_ctrl;
                                ADDR_DMA_STATUS[7:0]:      s_axil_rdata <= reg_dma_status;
                                ADDR_H2C_RING_ADDR_L[7:0]: s_axil_rdata <= reg_h2c_ring_addr[31:0];
                                ADDR_H2C_RING_ADDR_H[7:0]: s_axil_rdata <= reg_h2c_ring_addr[63:32];
                                ADDR_H2C_RING_CFG[7:0]:    s_axil_rdata <= {reg_h2c_tail_ptr, reg_h2c_ring_size};
                                ADDR_C2H_RING_ADDR_L[7:0]: s_axil_rdata <= reg_c2h_ring_addr[31:0];
                                ADDR_C2H_RING_ADDR_H[7:0]: s_axil_rdata <= reg_c2h_ring_addr[63:32];
                                ADDR_C2H_RING_CFG[7:0]:    s_axil_rdata <= {reg_c2h_tail_ptr, reg_c2h_ring_size};
                                ADDR_IRQ_CTRL[7:0]:        s_axil_rdata <= reg_irq_ctrl;
                                ADDR_IRQ_STATUS[7:0]:      s_axil_rdata <= reg_irq_status;
                                ADDR_COMPLETED_H2C[7:0]:   s_axil_rdata <= completed_h2c_count;
                                ADDR_COMPLETED_C2H[7:0]:   s_axil_rdata <= completed_c2h_count;
                                ADDR_VERSION_ID[7:0]:      s_axil_rdata <= VERSION_ID_VAL;
                                ADDR_GIT_COMMIT_HASH[7:0]: s_axil_rdata <= GIT_COMMIT_HASH_VAL;
                                ADDR_BUILD_TIMESTAMP[7:0]: s_axil_rdata <= BUILD_TIMESTAMP_VAL;
                                ADDR_HARDWARE_CAPS[7:0]:   s_axil_rdata <= HARDWARE_CAPS_VAL;
                                8'h40:                     s_axil_rdata <= {reg_h2c_tail_ptr, reg_h2c_head_ptr};
                                8'h44:                     s_axil_rdata <= {reg_c2h_tail_ptr, reg_c2h_head_ptr};
                                8'h48:                     s_axil_rdata <= reg_audio_dma_addr[31:0];
                                8'h4C:                     s_axil_rdata <= reg_audio_dma_addr[63:32];
                                8'h50:                     s_axil_rdata <= reg_global_timestamp[31:0];
                                8'h54:                     s_axil_rdata <= reg_global_timestamp[63:32];
                                8'h58:                     s_axil_rdata <= reg_last_video_pts[31:0];
                                8'h5C:                     s_axil_rdata <= reg_last_video_pts[63:32];
                                8'h60:                     s_axil_rdata <= reg_last_audio_pts[31:0];
                                8'h64:                     s_axil_rdata <= reg_last_audio_pts[63:32];
                                8'h68:                     s_axil_rdata <= reg_debug_last_wdata;
                                8'h6C:                     s_axil_rdata <= reg_debug_last_waddr;
                                8'h70:                     s_axil_rdata <= reg_latency_max_ns;
                                8'h74:                     s_axil_rdata <= reg_pacer_ctrl;
                                8'h78:                     s_axil_rdata <= reg_slice_height;
                                8'h7C:                     s_axil_rdata <= reg_frame_drop_count;
                                8'h80:                     s_axil_rdata <= reg_video_ctrl;
                                8'h84:                     s_axil_rdata <= reg_video_sub_reset;
                                8'h88:                     s_axil_rdata <= reg_sof_count;
                                8'h8C:                     s_axil_rdata <= reg_eol_count;
                                8'h90:                     s_axil_rdata <= reg_beat_count;
                                8'h94:                     s_axil_rdata <= reg_audio_dma_cfg;
                                8'h98:                     s_axil_rdata <= reg_audio_dma_ptr;
                                8'hA0:                     s_axil_rdata <= {30'd0, reg_perf_reset_w1c, reg_perf_enable};
                                8'hA4:                     s_axil_rdata <= reg_perf_cycles[31:0];
                                8'hA8:                     s_axil_rdata <= reg_perf_cycles[63:32];
                                8'hAC:                     s_axil_rdata <= reg_perf_tlp_count;
                                8'hB0:                     s_axil_rdata <= reg_perf_payload_bytes[31:0];
                                8'hB4:                     s_axil_rdata <= reg_perf_payload_bytes[63:32];
                                8'hB8:                     s_axil_rdata <= reg_perf_tx_active_cycles;
                                8'hBC:                     s_axil_rdata <= reg_perf_tx_idle_cycles;
                                8'hC0:                     s_axil_rdata <= reg_perf_tready_stall_cycles;
                                8'hC4:                     s_axil_rdata <= reg_perf_inter_tlp_gap;
                                8'hC8:                     s_axil_rdata <= reg_perf_tlp_128b_count;
                                8'hCC:                     s_axil_rdata <= reg_perf_tlp_256b_count;
                                8'hD0:                     s_axil_rdata <= reg_perf_split_4k_count;
                                8'hD4:                     s_axil_rdata <= {16'd0, reg_perf_max_queue_depth};
                                8'hD8:                     s_axil_rdata <= reg_perf_idle_cdc_empty;
                                8'hDC:                     s_axil_rdata <= reg_perf_idle_no_req;
                                8'hE0:                     s_axil_rdata <= {21'd0, pt_y_wr_addr};
                                8'hE4:                     s_axil_rdata <= pt_y_wr_data[31:0];
                                8'hE8:                     s_axil_rdata <= pt_y_wr_data[63:32];
                                8'hEC:                     s_axil_rdata <= {5'd0, cur_uv_page_idx, 5'd0, cur_y_page_idx};
                                default:                   s_axil_rdata <= 32'd0;
                            endcase
                        end else begin
                            case (s_axil_araddr[7:0])
                                8'h00: s_axil_rdata <= MAGIC_DEVICE_ID_VAL;
                                8'h04: s_axil_rdata <= VERSION_ID_VAL;
                                8'h08: s_axil_rdata <= HARDWARE_CAPS_VAL;
                                8'h0C: s_axil_rdata <= GIT_COMMIT_HASH_VAL;
                                8'h10: s_axil_rdata <= BUILD_TIMESTAMP_VAL;
                                8'h14: s_axil_rdata <= {31'd0, global_reset_pulse};
                                8'h18: s_axil_rdata <= reg_irq_status;
                                8'h1C: s_axil_rdata <= reg_global_timestamp[31:0];
                                8'h20: s_axil_rdata <= reg_global_timestamp[63:32];
                                default: s_axil_rdata <= 32'd0;
                            endcase
                        end
                    end
                    4'h1: begin
                        if (!map_mode_new) begin
                            case (s_axil_araddr[7:0])
                                8'h00: s_axil_rdata <= reg_audio_dma_addr[31:0];
                                8'h04: s_axil_rdata <= reg_audio_dma_addr[63:32];
                                8'h08: s_axil_rdata <= reg_audio_dma_cfg;
                                8'h0C: s_axil_rdata <= reg_audio_dma_ptr;
                                8'h10: s_axil_rdata <= reg_audio_dma_addr_ch1[31:0];
                                8'h14: s_axil_rdata <= reg_audio_dma_addr_ch1[63:32];
                                8'h18: s_axil_rdata <= reg_audio_dma_cfg_ch1;
                                8'h1C: s_axil_rdata <= reg_audio_dma_ptr_ch1;
                                8'h20: s_axil_rdata <= reg_audio_dma_addr_ch2[31:0];
                                8'h24: s_axil_rdata <= reg_audio_dma_addr_ch2[63:32];
                                8'h28: s_axil_rdata <= reg_audio_dma_cfg_ch2;
                                8'h2C: s_axil_rdata <= reg_audio_dma_ptr_ch2;
                                8'h30: s_axil_rdata <= reg_audio_dma_addr_ch3[31:0];
                                8'h34: s_axil_rdata <= reg_audio_dma_addr_ch3[63:32];
                                8'h38: s_axil_rdata <= reg_audio_dma_cfg_ch3;
                                8'h3C: s_axil_rdata <= reg_audio_dma_ptr_ch3;
                                8'h5C: s_axil_rdata <= {
                                    1'b0,
                                    h2c_fifo_empty_ch3, h2c_fifo_empty_ch2, h2c_fifo_empty_ch1,
                                    1'b0,
                                    h2c_fifo_full_ch3,  h2c_fifo_full_ch2,  h2c_fifo_full_ch1,
                                    h2c_fifo_count_ch3,
                                    h2c_fifo_count_ch2,
                                    h2c_fifo_count_ch1
                                };
                                8'h60: s_axil_rdata <= reg_audio_loopback_ctrl;
                                default: s_axil_rdata <= 32'd0;
                            endcase
                        end else begin
                            case (s_axil_araddr[7:0])
                                8'h00: s_axil_rdata <= vch0_ctrl;
                                8'h04: s_axil_rdata <= vch0_status;
                                8'h08: s_axil_rdata <= vch0_width;
                                8'h0C: s_axil_rdata <= vch0_height;
                                8'h10: s_axil_rdata <= vch0_stride0;
                                8'h14: s_axil_rdata <= vch0_stride1;
                                8'h20: s_axil_rdata <= reg_c2h_ring_addr[31:0];
                                8'h24: s_axil_rdata <= reg_c2h_ring_addr[63:32];
                                8'h28: s_axil_rdata <= {reg_c2h_tail_ptr, reg_c2h_ring_size};
                                8'h2C: s_axil_rdata <= {16'd0, reg_c2h_head_ptr};
                                8'h30: s_axil_rdata <= reg_h2c_ring_addr[31:0];
                                8'h34: s_axil_rdata <= reg_h2c_ring_addr[63:32];
                                8'h38: s_axil_rdata <= {reg_h2c_tail_ptr, reg_h2c_ring_size};
                                8'h3C: s_axil_rdata <= {16'd0, reg_h2c_head_ptr};
                                8'h60: s_axil_rdata <= in_vch0_frame_count;
                                8'h64: s_axil_rdata <= in_vch0_drop_count;
                                8'h68: s_axil_rdata <= reg_last_video_pts[31:0];
                                8'h6C: s_axil_rdata <= reg_last_video_pts[63:32];
                                8'h70: s_axil_rdata <= {31'd0, reg_irq_status[4]};
                                default: s_axil_rdata <= 32'd0;
                            endcase
                        end
                    end
                    4'h5: begin
                        if (map_mode_new) begin
                            case (s_axil_araddr[7:0])
                                8'h00: s_axil_rdata <= adev0_ctrl;
                                8'h04: s_axil_rdata <= adev0_status;
                                8'h08: s_axil_rdata <= adev0_rate;
                                8'h0C: s_axil_rdata <= adev0_period_bytes;
                                8'h10: s_axil_rdata <= adev0_buffer_bytes;
                                8'h14: s_axil_rdata <= reg_audio_dma_ptr;
                                8'h20: s_axil_rdata <= adev0_ring0_base[31:0];
                                8'h24: s_axil_rdata <= adev0_ring0_base[63:32];
                                8'h28: s_axil_rdata <= adev0_ring0_cfg;
                                8'hA4: s_axil_rdata <= reg_audio_dma_ptr;
                                8'hA8: s_axil_rdata <= adev0_irq_w1c;
                                default: s_axil_rdata <= 32'd0;
                            endcase
                        end else begin
                            s_axil_rdata <= 32'd0;
                        end
                    end
                    4'h9: begin
                        if (map_mode_new) begin
                            case (s_axil_araddr[7:0])
                                8'h00: s_axil_rdata <= reg_audio_loopback_ctrl;
                                8'h04: s_axil_rdata <= dbg_pattern_gen;
                                8'h08: s_axil_rdata <= reg_pacer_ctrl;
                                8'h0C: s_axil_rdata <= reg_debug_last_wdata;
                                8'h10: s_axil_rdata <= reg_debug_last_waddr;
                                default: s_axil_rdata <= 32'd0;
                            endcase
                        end else begin
                            s_axil_rdata <= 32'd0;
                        end
                    end
                    default: s_axil_rdata <= 32'd0;
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
