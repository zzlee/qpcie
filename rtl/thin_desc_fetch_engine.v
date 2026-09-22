// ============================================================================
// Module: thin_desc_fetch_engine
// Description: Thin 16-Byte Descriptor Fetch Engine for Video Channel 0
//              Implements Phase 3 architecture from Future-Register-Map-and-Descriptor-Spec:
//              - 16-Byte Thin Descriptor format:
//                [63:0]   host_addr (physical DMA address)
//                [95:64]  len_bytes (transfer length in bytes)
//                [127:96] flags     (bit 0: chain, bit 1: last, IRQ policies)
//              - Dual-ring parallel support:
//                RING0: Y plane or packed RGB24
//                RING1: UV plane (NV12M)
//              - Autonomous doorbell monitoring (head != tail)
//              - Byte-count framing & automatic multi-frame dispatch
//              - Hardware head pointer advancement & frame counters
// ============================================================================

`timescale 1ns / 1ps

module thin_desc_fetch_engine #(
    parameter integer DATA_WIDTH = 128
)(
    input  wire        clk,
    input  wire        rst_n,

    // Channel 0 Control & Geometry from axil_reg_space
    input  wire        enable,             // vch0_ctrl[0]
    input  wire [3:0]  format,             // vch0_ctrl[7:4]: 4'd0 = NV12M, 4'd1 = RGB24
    input  wire [15:0] frame_width,        // vch0_width[15:0]
    input  wire [15:0] frame_height,       // vch0_height[15:0]
    input  wire [15:0] frame_stride0,      // vch0_stride0[15:0]
    input  wire [15:0] frame_stride1,      // vch0_stride1[15:0]
    input  wire [63:0] global_timestamp,

    // RING0 (Y / RGB24) Interface
    input  wire [63:0] ring0_base_addr,
    input  wire [15:0] ring0_size,
    input  wire [15:0] ring0_tail,
    output reg  [15:0] ring0_head,

    // RING1 (UV) Interface
    input  wire [63:0] ring1_base_addr,
    input  wire [15:0] ring1_size,
    input  wire [15:0] ring1_tail,
    output reg  [15:0] ring1_head,

    // Status & Diagnostics
    input  wire        frame_done_in,      // pcie_frame_done pulse
    output reg  [31:0] frame_count,
    output reg  [31:0] drop_count,
    output wire        busy,

    // PCIe MRd Requester Interface (Tag 8'h02 for Thin Fetch)
    output reg         mrd_req_valid,
    output reg  [63:0] mrd_req_addr,
    output reg  [10:0] mrd_req_dw_len,     // 4 DW = 16 Bytes (1 Thin Descriptor)
    output reg  [7:0]  mrd_req_tag,
    input  wire        mrd_req_ack,

    // PCIe CplD Completion Interface
    input  wire        cpld_valid,
    input  wire [DATA_WIDTH-1:0] cpld_data,
    input  wire        cpld_last,
    input  wire [7:0]  cpld_tag,

    // SGL Segment Push to Walkers / CDCs
    output reg         sgl_y_wr_en,
    output reg  [63:0] sgl_y_wr_addr,
    output reg  [31:0] sgl_y_wr_len,
    output reg  [31:0] sgl_y_wr_flags,
    input  wire        sgl_y_almost_full,

    output reg         sgl_uv_wr_en,
    output reg  [63:0] sgl_uv_wr_addr,
    output reg  [31:0] sgl_uv_wr_len,
    output reg  [31:0] sgl_uv_wr_flags,
    input  wire        sgl_uv_almost_full,

    // Frame Launch Handshake to u_desc_cdc
    output reg         frame_launch_req,
    output reg [244:0] frame_launch_bus,
    input  wire        frame_launch_ack,
    input  wire        capture_engine_busy
);

    localparam [7:0] THIN_MRD_TAG = 8'h00;

    // FSM States
    localparam S_IDLE        = 3'd0;
    localparam S_REQ_MRD     = 3'd1;
    localparam S_WAIT_CPLD   = 3'd2;
    localparam S_PUSH_DESC   = 3'd3;
    localparam S_ADVANCE_RING= 3'd4;
    localparam S_LAUNCH_WAIT = 3'd5;

    reg [2:0] state;
    reg       sel_ring1; // 0 = RING0 (Y/RGB), 1 = RING1 (UV)
    reg       frame_active;
    reg [31:0] frame_bytes_target_y;
    reg [31:0] frame_bytes_accum_y;
    reg [31:0] frame_bytes_target_uv;
    reg [31:0] frame_bytes_accum_uv;

    // Ring occupancy checks
    wire ring0_has_work = (ring0_head != ring0_tail) && (ring0_size != 16'd0);
    wire ring1_has_work = (ring1_head != ring1_tail) && (ring1_size != 16'd0) && (format != 4'd1);
    wire ring0_needed   = frame_active ? (frame_bytes_accum_y < frame_bytes_target_y) : 1'b1;
    wire ring1_needed   = frame_active ? (frame_bytes_accum_uv < frame_bytes_target_uv) : 1'b1;

    assign busy = (state != S_IDLE) || frame_active;

    // Target frame bytes calculation
    // RGB24: line_width_bytes * height = stride0 * height (e.g. 5760 * 1080 = 6,220,800 bytes)
    // NV12M: Y = width * height, UV = width * (height / 2)
    wire [15:0] effective_width = (format == 4'd1) ? ((frame_stride0 > 16'd0) ? frame_stride0 : (frame_width * 16'd3)) : frame_width;
    wire [31:0] target_y  = effective_width * frame_height;
    wire [31:0] target_uv = (format == 4'd1) ? 32'd0 : (frame_width * (frame_height >> 1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            sel_ring1            <= 1'b0;
            ring0_head           <= 16'd0;
            ring1_head           <= 16'd0;
            frame_count          <= 32'd0;
            drop_count           <= 32'd0;
            frame_active         <= 1'b0;
            frame_bytes_target_y <= 32'd0;
            frame_bytes_accum_y  <= 32'd0;
            frame_bytes_target_uv<= 32'd0;
            frame_bytes_accum_uv <= 32'd0;
            mrd_req_valid        <= 1'b0;
            mrd_req_addr         <= 64'd0;
            mrd_req_dw_len       <= 11'd4; // 16 bytes
            mrd_req_tag          <= THIN_MRD_TAG;
            sgl_y_wr_en          <= 1'b0;
            sgl_y_wr_addr        <= 64'd0;
            sgl_y_wr_len         <= 32'd0;
            sgl_y_wr_flags       <= 32'd0;
            sgl_uv_wr_en         <= 1'b0;
            sgl_uv_wr_addr       <= 64'd0;
            sgl_uv_wr_len        <= 32'd0;
            sgl_uv_wr_flags      <= 32'd0;
            frame_launch_req     <= 1'b0;
        end else if (!enable) begin
            state                <= S_IDLE;
            sel_ring1            <= 1'b0;
            frame_active         <= 1'b0;
            mrd_req_valid        <= 1'b0;
            sgl_y_wr_en          <= 1'b0;
            sgl_uv_wr_en         <= 1'b0;
            frame_launch_req     <= 1'b0;
        end else begin
            // Frame completion tracking
            if (frame_done_in) begin
                frame_count  <= frame_count + 1'b1;
                frame_active <= 1'b0;
            end

            // Default strobes
            sgl_y_wr_en  <= 1'b0;
            sgl_uv_wr_en <= 1'b0;

            // Handshake clear
            if (frame_launch_req && frame_launch_ack) begin
                frame_launch_req <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    mrd_req_valid <= 1'b0;

                    if (enable) begin
                        // Check if we can launch a frame
                        if (!frame_active && !capture_engine_busy && !frame_launch_req &&
                            ring0_has_work && (format == 4'd1 || ring1_has_work)) begin
                            // Latch geometry targets
                            frame_bytes_target_y  <= target_y;
                            frame_bytes_accum_y   <= 32'd0;
                            frame_bytes_target_uv <= target_uv;
                            frame_bytes_accum_uv  <= 32'd0;

                            // Launch frame to capture engine via u_desc_cdc format
                            // hs_bus_q: {format[3:0], desc_ctrl[4]|desc_ctrl[5] (sg_mode=1),
                            //            ts[63:0], stride[15:0], height[15:0], width[15:0],
                            //            plane1_dst[63:0], plane0_dst[63:0]}
                            frame_launch_bus <= {
                                format,
                                1'b1, // sg_mode = 1
                                global_timestamp,
                                frame_stride0,
                                frame_height,
                                effective_width,
                                64'd0, // plane1 dummy (walker supplies address)
                                64'd0  // plane0 dummy (walker supplies address)
                            };
                            frame_launch_req <= 1'b1;
                            frame_active     <= 1'b1;
                            state            <= S_LAUNCH_WAIT;
                        end else if (ring0_has_work && !sgl_y_almost_full && ring0_needed) begin
                            // Fetch next entry for RING0
                            sel_ring1      <= 1'b0;
                            mrd_req_addr   <= ring0_base_addr + (ring0_head * 16);
                            mrd_req_dw_len <= 11'd4; // 16 bytes
                            mrd_req_tag    <= THIN_MRD_TAG;
                            mrd_req_valid  <= 1'b1;
                            state          <= S_REQ_MRD;
                        end else if (ring1_has_work && !sgl_uv_almost_full && ring1_needed) begin
                            // Fetch next entry for RING1
                            sel_ring1      <= 1'b1;
                            mrd_req_addr   <= ring1_base_addr + (ring1_head * 16);
                            mrd_req_dw_len <= 11'd4; // 16 bytes
                            mrd_req_tag    <= THIN_MRD_TAG;
                            mrd_req_valid  <= 1'b1;
                            state          <= S_REQ_MRD;
                        end
                    end
                end

                S_LAUNCH_WAIT: begin
                    // Wait for CDC handshake to be acknowledged
                    if (frame_launch_ack || !frame_launch_req) begin
                        state <= S_IDLE;
                    end
                end

                S_REQ_MRD: begin
                    if (mrd_req_ack) begin
                        mrd_req_valid <= 1'b0;
                        state         <= S_WAIT_CPLD;
                    end
                end

                S_WAIT_CPLD: begin
                    if (cpld_valid && (cpld_tag == THIN_MRD_TAG)) begin
                        // cpld_data: [63:0]=addr, [95:64]=len, [127:96]=flags
                        if (!sel_ring1) begin
                            sgl_y_wr_addr   <= cpld_data[63:0];
                            sgl_y_wr_len    <= cpld_data[95:64];
                            sgl_y_wr_flags  <= cpld_data[127:96];
                            sgl_y_wr_en     <= 1'b1;
                            frame_bytes_accum_y <= frame_bytes_accum_y + cpld_data[95:64];
                        end else begin
                            sgl_uv_wr_addr  <= cpld_data[63:0];
                            sgl_uv_wr_len   <= cpld_data[95:64];
                            sgl_uv_wr_flags <= cpld_data[127:96];
                            sgl_uv_wr_en    <= 1'b1;
                            frame_bytes_accum_uv <= frame_bytes_accum_uv + cpld_data[95:64];
                        end
                        state <= S_ADVANCE_RING;
                    end
                end

                S_ADVANCE_RING: begin
                    if (!sel_ring1) begin
                        if (ring0_size > 16'd0 && ((ring0_head + 1'b1) >= ring0_size))
                            ring0_head <= 16'd0;
                        else
                            ring0_head <= ring0_head + 1'b1;
                    end else begin
                        if (ring1_size > 16'd0 && ((ring1_head + 1'b1) >= ring1_size))
                            ring1_head <= 16'd0;
                        else
                            ring1_head <= ring1_head + 1'b1;
                    end
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
