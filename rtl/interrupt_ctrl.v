// ============================================================================
// Module: interrupt_ctrl
// Description: PCIe DMA Interrupt Controller.
//              Implements Phase 4 Three-Level Interrupt Hierarchy:
//                Level 1: PCIe MSI Single Vector (usr_irq_req / irq_req_valid)
//                Level 2: IRQ_TOP (GLOBAL 0x18, W1C)
//                Level 3: Per-Source Event Registers (e.g. VCH0 0x170, W1C)
//              Features:
//                - Per-source 8-bit saturating pending counters (saturating at 255)
//                  ensuring in-flight completions during MSI transmission are never lost.
//                - Strict priority arbitration:
//                  ERR > H2C > VCH0 > VCH1 > VCH2 > VCH3 > AUD > PERF
//                - Errors bypass interrupt enable and cannot be masked.
//                - Backward compatibility with legacy REG_IRQ_STATUS (0x24).
// ============================================================================

`timescale 1ns / 1ps

module interrupt_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // Legacy register interface (0x20, 0x24)
    input  wire [31:0] reg_irq_ctrl,          // bit 0: H2C IE, bit 1: C2H IE
    input  wire [31:0] reg_irq_status_w1c,
    output reg  [31:0] reg_irq_status,

    // Phase 4: Three-Level Hierarchy Register Interface
    // Level 2: IRQ_TOP (GLOBAL 0x18)
    output reg  [31:0] irq_top_status,
    input  wire [31:0] irq_top_status_w1c,

    // Level 3: VIDEO CH0..CH3 IRQ STATUS (VCHn 0x70)
    output reg  [3:0]  vch0_irq_status,       // [0]=frame_done, [1]=overflow, [2]=desc_error, [3]=fifo_error
    input  wire [3:0]  vch0_irq_status_w1c,
    input  wire        vch0_irq_en,           // from vch0_ctrl[8]

    output reg  [3:0]  vch1_irq_status,
    input  wire [3:0]  vch1_irq_status_w1c,
    input  wire        vch1_irq_en,

    output reg  [3:0]  vch2_irq_status,
    input  wire [3:0]  vch2_irq_status_w1c,
    input  wire        vch2_irq_en,

    output reg  [3:0]  vch3_irq_status,
    input  wire [3:0]  vch3_irq_status_w1c,
    input  wire        vch3_irq_en,

    // Level 3: AUDIO DEV0 IRQ STATUS (DEV0 0xA8)
    output reg  [1:0]  adev0_irq_status,      // [0]=period_done, [1]=xrun
    input  wire [1:0]  adev0_irq_status_w1c,
    input  wire        adev0_irq_en,

    // Completion triggers from DMA Engines
    input  wire        h2c_done,
    input  wire        c2h_done,
    input  wire [3:0]  v_done_ch,
    input  wire [3:1]  h2c_done_ch,
    input  wire [3:0]  a_done_irq,

    // Error triggers
    input  wire [3:0]  v_overflow_ch,
    input  wire [3:0]  v_desc_err_ch,
    input  wire [3:0]  v_fifo_err_ch,
    input  wire [3:0]  a_xrun_ch,
    input  wire        global_err,

    // Interface to RQ TX Encoder (MSI Interrupt Msg TLP)
    output reg         irq_req_valid,
    output reg  [7:0]  irq_req_code,
    input  wire        irq_req_ack,

    // Dedicated physical IRQ pin output (7-series cfg_interrupt)
    output reg         usr_irq_req,
    input  wire        usr_irq_ack
);

    localparam IDLE     = 2'b00;
    localparam SEND_MSI = 2'b01;

    localparam SRC_NONE = 4'd0;
    localparam SRC_ERR  = 4'd1;
    localparam SRC_H2C  = 4'd2;
    localparam SRC_VCH0 = 4'd3;
    localparam SRC_VCH1 = 4'd4;
    localparam SRC_VCH2 = 4'd5;
    localparam SRC_VCH3 = 4'd6;
    localparam SRC_AUD  = 4'd7;
    localparam SRC_PERF = 4'd8;

    reg [1:0] state;
    reg [3:0] active_source;

    // Per-source 8-bit saturating pending counters
    reg [7:0] err_pending;
    reg [7:0] h2c_pending;
    reg [7:0] vch0_pending;
    reg [7:0] vch1_pending;
    reg [7:0] vch2_pending;
    reg [7:0] vch3_pending;
    reg [7:0] aud_pending;
    reg [7:0] perf_pending;

    // Event signals
    wire vch0_frame_done = v_done_ch[0] | c2h_done;
    wire vch1_frame_done = v_done_ch[1];
    wire vch2_frame_done = v_done_ch[2];
    wire vch3_frame_done = v_done_ch[3];

    wire vch0_err = v_overflow_ch[0] | v_desc_err_ch[0] | v_fifo_err_ch[0];
    wire vch1_err = v_overflow_ch[1] | v_desc_err_ch[1] | v_fifo_err_ch[1];
    wire vch2_err = v_overflow_ch[2] | v_desc_err_ch[2] | v_fifo_err_ch[2];
    wire vch3_err = v_overflow_ch[3] | v_desc_err_ch[3] | v_fifo_err_ch[3];
    wire aud_err  = (|a_xrun_ch);
    wire any_err  = vch0_err | vch1_err | vch2_err | vch3_err | aud_err | global_err;

    wire aud_done = (|a_done_irq);

    // MSI Handshake
    wire msi_ack = (irq_req_ack || usr_irq_ack);

    wire ack_err  = (state == SEND_MSI) && msi_ack && (active_source == SRC_ERR);
    wire ack_h2c  = (state == SEND_MSI) && msi_ack && (active_source == SRC_H2C);
    wire ack_vch0 = (state == SEND_MSI) && msi_ack && (active_source == SRC_VCH0);
    wire ack_vch1 = (state == SEND_MSI) && msi_ack && (active_source == SRC_VCH1);
    wire ack_vch2 = (state == SEND_MSI) && msi_ack && (active_source == SRC_VCH2);
    wire ack_vch3 = (state == SEND_MSI) && msi_ack && (active_source == SRC_VCH3);
    wire ack_aud  = (state == SEND_MSI) && msi_ack && (active_source == SRC_AUD);
    wire ack_perf = (state == SEND_MSI) && msi_ack && (active_source == SRC_PERF);

    // Arbitration (Strict Priority: ERR > H2C > VCH0 > VCH1 > VCH2 > VCH3 > AUD > PERF)
    // Note: Errors ALWAYS bypass enable and cannot be masked!
    wire err_req  = (err_pending != 8'd0);
    wire h2c_req  = (h2c_pending != 8'd0)  && reg_irq_ctrl[0];
    wire vch0_req = (vch0_pending != 8'd0) && (vch0_irq_en | reg_irq_ctrl[1]);
    wire vch1_req = (vch1_pending != 8'd0) && (vch1_irq_en | reg_irq_ctrl[1]);
    wire vch2_req = (vch2_pending != 8'd0) && (vch2_irq_en | reg_irq_ctrl[1]);
    wire vch3_req = (vch3_pending != 8'd0) && (vch3_irq_en | reg_irq_ctrl[1]);
    wire aud_req  = (aud_pending != 8'd0)  && (adev0_irq_en | reg_irq_ctrl[1]);
    wire perf_req = (perf_pending != 8'd0);

    reg [3:0] arb_winner;
    reg [7:0] arb_code;

    always @(*) begin
        if (err_req) begin
            arb_winner = SRC_ERR;
            arb_code   = 8'hE0;
        end else if (h2c_req) begin
            arb_winner = SRC_H2C;
            arb_code   = 8'h01;
        end else if (vch0_req) begin
            arb_winner = SRC_VCH0;
            arb_code   = 8'h02; // Keep 0x02 for backward compatibility with C2H / VCH0
        end else if (vch1_req) begin
            arb_winner = SRC_VCH1;
            arb_code   = 8'h03;
        end else if (vch2_req) begin
            arb_winner = SRC_VCH2;
            arb_code   = 8'h04;
        end else if (vch3_req) begin
            arb_winner = SRC_VCH3;
            arb_code   = 8'h05;
        end else if (aud_req) begin
            arb_winner = SRC_AUD;
            arb_code   = 8'h06;
        end else if (perf_req) begin
            arb_winner = SRC_PERF;
            arb_code   = 8'h07;
        end else begin
            arb_winner = SRC_NONE;
            arb_code   = 8'h00;
        end
    end

    // Pending Counters (Saturating at 255, protected against underflow)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_pending  <= 8'd0;
            h2c_pending  <= 8'd0;
            vch0_pending <= 8'd0;
            vch1_pending <= 8'd0;
            vch2_pending <= 8'd0;
            vch3_pending <= 8'd0;
            aud_pending  <= 8'd0;
            perf_pending <= 8'd0;
        end else begin
            // ERR
            case ({any_err, ack_err})
                2'b10: if (err_pending != 8'hFF) err_pending <= err_pending + 8'd1;
                2'b01: if (err_pending != 8'd0)  err_pending <= err_pending - 8'd1;
                default: ;
            endcase

            // H2C
            case ({h2c_done, ack_h2c})
                2'b10: if (h2c_pending != 8'hFF) h2c_pending <= h2c_pending + 8'd1;
                2'b01: if (h2c_pending != 8'd0)  h2c_pending <= h2c_pending - 8'd1;
                default: ;
            endcase

            // VCH0
            case ({vch0_frame_done, ack_vch0})
                2'b10: if (vch0_pending != 8'hFF) vch0_pending <= vch0_pending + 8'd1;
                2'b01: if (vch0_pending != 8'd0)  vch0_pending <= vch0_pending - 8'd1;
                default: ;
            endcase

            // VCH1
            case ({vch1_frame_done, ack_vch1})
                2'b10: if (vch1_pending != 8'hFF) vch1_pending <= vch1_pending + 8'd1;
                2'b01: if (vch1_pending != 8'd0)  vch1_pending <= vch1_pending - 8'd1;
                default: ;
            endcase

            // VCH2
            case ({vch2_frame_done, ack_vch2})
                2'b10: if (vch2_pending != 8'hFF) vch2_pending <= vch2_pending + 8'd1;
                2'b01: if (vch2_pending != 8'd0)  vch2_pending <= vch2_pending - 8'd1;
                default: ;
            endcase

            // VCH3
            case ({vch3_frame_done, ack_vch3})
                2'b10: if (vch3_pending != 8'hFF) vch3_pending <= vch3_pending + 8'd1;
                2'b01: if (vch3_pending != 8'd0)  vch3_pending <= vch3_pending - 8'd1;
                default: ;
            endcase

            // AUD
            case ({aud_done, ack_aud})
                2'b10: if (aud_pending != 8'hFF) aud_pending <= aud_pending + 8'd1;
                2'b01: if (aud_pending != 8'd0)  aud_pending <= aud_pending - 8'd1;
                default: ;
            endcase

            // PERF
            if (ack_perf && perf_pending != 8'd0)
                perf_pending <= perf_pending - 8'd1;
        end
    end

    // Level 3: VCH0..VCH3 & ADEV0 IRQ Status (W1C, same-cycle event takes priority over clear)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vch0_irq_status  <= 4'd0;
            vch1_irq_status  <= 4'd0;
            vch2_irq_status  <= 4'd0;
            vch3_irq_status  <= 4'd0;
            adev0_irq_status <= 2'd0;
        end else begin
            vch0_irq_status <= vch0_irq_status & ~vch0_irq_status_w1c;
            if (vch0_frame_done)  vch0_irq_status[0] <= 1'b1;
            if (v_overflow_ch[0]) vch0_irq_status[1] <= 1'b1;
            if (v_desc_err_ch[0]) vch0_irq_status[2] <= 1'b1;
            if (v_fifo_err_ch[0]) vch0_irq_status[3] <= 1'b1;

            vch1_irq_status <= vch1_irq_status & ~vch1_irq_status_w1c;
            if (vch1_frame_done)  vch1_irq_status[0] <= 1'b1;
            if (v_overflow_ch[1]) vch1_irq_status[1] <= 1'b1;
            if (v_desc_err_ch[1]) vch1_irq_status[2] <= 1'b1;
            if (v_fifo_err_ch[1]) vch1_irq_status[3] <= 1'b1;

            vch2_irq_status <= vch2_irq_status & ~vch2_irq_status_w1c;
            if (vch2_frame_done)  vch2_irq_status[0] <= 1'b1;
            if (v_overflow_ch[2]) vch2_irq_status[1] <= 1'b1;
            if (v_desc_err_ch[2]) vch2_irq_status[2] <= 1'b1;
            if (v_fifo_err_ch[2]) vch2_irq_status[3] <= 1'b1;

            vch3_irq_status <= vch3_irq_status & ~vch3_irq_status_w1c;
            if (vch3_frame_done)  vch3_irq_status[0] <= 1'b1;
            if (v_overflow_ch[3]) vch3_irq_status[1] <= 1'b1;
            if (v_desc_err_ch[3]) vch3_irq_status[2] <= 1'b1;
            if (v_fifo_err_ch[3]) vch3_irq_status[3] <= 1'b1;

            adev0_irq_status <= adev0_irq_status & ~adev0_irq_status_w1c;
            if (a_done_irq[0]) adev0_irq_status[0] <= 1'b1;
            if (a_xrun_ch[0])  adev0_irq_status[1] <= 1'b1;
        end
    end

    // Level 2: IRQ_TOP (GLOBAL 0x18, W1C)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_top_status <= 32'd0;
        end else begin
            irq_top_status <= irq_top_status & ~irq_top_status_w1c;
            if (vch0_frame_done | vch0_err) irq_top_status[0] <= 1'b1;
            if (vch1_frame_done | vch1_err) irq_top_status[1] <= 1'b1;
            if (vch2_frame_done | vch2_err) irq_top_status[2] <= 1'b1;
            if (vch3_frame_done | vch3_err) irq_top_status[3] <= 1'b1;
            if (aud_done | aud_err)         irq_top_status[4] <= 1'b1;
            if (any_err)                    irq_top_status[5] <= 1'b1;
            if (perf_req)                   irq_top_status[6] <= 1'b1;
            if (h2c_done)                   irq_top_status[7] <= 1'b1;
        end
    end

    // Legacy: REG_IRQ_STATUS (0x24, W1C)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_irq_status <= 32'd0;
        end else begin
            reg_irq_status <= reg_irq_status & ~reg_irq_status_w1c;
            if (h2c_done)       reg_irq_status[0]  <= 1'b1;
            if (c2h_done)       reg_irq_status[1]  <= 1'b1;
            if (v_done_ch[0])   reg_irq_status[4]  <= 1'b1;
            if (v_done_ch[1])   reg_irq_status[5]  <= 1'b1;
            if (v_done_ch[2])   reg_irq_status[6]  <= 1'b1;
            if (v_done_ch[3])   reg_irq_status[7]  <= 1'b1;
            if (h2c_done_ch[1]) reg_irq_status[8]  <= 1'b1;
            if (h2c_done_ch[2]) reg_irq_status[9]  <= 1'b1;
            if (h2c_done_ch[3]) reg_irq_status[10] <= 1'b1;
            if (a_done_irq[0])  reg_irq_status[11] <= 1'b1;
            if (a_done_irq[1])  reg_irq_status[12] <= 1'b1;
            if (a_done_irq[2])  reg_irq_status[13] <= 1'b1;
            if (a_done_irq[3])  reg_irq_status[14] <= 1'b1;
        end
    end

    // Level 1: PCIe MSI Single Vector State Machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            active_source <= SRC_NONE;
            irq_req_valid <= 1'b0;
            irq_req_code  <= 8'd0;
            usr_irq_req   <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    irq_req_valid <= 1'b0;
                    usr_irq_req   <= 1'b0;
                    if (arb_winner != SRC_NONE) begin
                        active_source <= arb_winner;
                        irq_req_code  <= arb_code;
                        irq_req_valid <= 1'b1;
                        usr_irq_req   <= 1'b1;
                        state         <= SEND_MSI;
                    end
                end

                SEND_MSI: begin
                    if (msi_ack) begin
                        irq_req_valid <= 1'b0;
                        usr_irq_req   <= 1'b0;
                        active_source <= SRC_NONE;
                        state         <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
