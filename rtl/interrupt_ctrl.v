// ============================================================================
// Module: interrupt_ctrl
// Description: PCIe DMA Interrupt Controller.
//              Manages MSI / MSI-X / Legacy Interrupt triggers upon DMA completion.
// ============================================================================

`timescale 1ns / 1ps

module interrupt_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // Interrupt enable & status from Register Space
    input  wire [31:0] reg_irq_ctrl,   // bit 0: H2C IE, bit 1: C2H IE
    input  wire [31:0] reg_irq_status_w1c,
    output reg  [31:0] reg_irq_status, // bit 0: H2C IRQ, bit 1: C2H IRQ

    // Completion triggers from DMA Engines
    input  wire        h2c_done,
    input  wire        c2h_done,
    input  wire [3:0]  v_done_ch,
    input  wire [3:1]  h2c_done_ch,

    // Interface to RQ TX Encoder (MSI Interrupt Msg TLP)
    output reg         irq_req_valid,
    output reg  [7:0]  irq_req_code,
    input  wire        irq_req_ack,

    // Dedicated physical IRQ pin output
    output reg         usr_irq_req,
    input  wire        usr_irq_ack
);

    localparam IDLE     = 2'b00;
    localparam SEND_MSI = 2'b01;

    reg [1:0] state;

    // Completion events are counted, not dropped: while an earlier MSI is
    // still waiting for cfg_interrupt_rdy, further frame completions must
    // survive so every buffer completion eventually raises one IRQ.
    reg [7:0] h2c_pending;
    reg [7:0] c2h_pending;
    wire      h2c_send = (h2c_pending != 8'd0) && reg_irq_ctrl[0];
    wire      c2h_send = (h2c_pending == 8'd0) &&
                         (c2h_pending != 8'd0) && reg_irq_ctrl[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            reg_irq_status <= 32'd0;
            irq_req_valid  <= 1'b0;
            irq_req_code   <= 8'd0;
            usr_irq_req    <= 1'b0;
            h2c_pending    <= 8'd0;
            c2h_pending    <= 8'd0;
        end else begin
            // Single owner for sticky status; software clear is W1C and
            // same-cycle completion events take priority over a clear.
            reg_irq_status <= reg_irq_status & ~reg_irq_status_w1c;
            if (h2c_done) reg_irq_status[0] <= 1'b1;
            if (c2h_done) reg_irq_status[1] <= 1'b1;
            if (v_done_ch[0]) reg_irq_status[4] <= 1'b1;
            if (v_done_ch[1]) reg_irq_status[5] <= 1'b1;
            if (v_done_ch[2]) reg_irq_status[6] <= 1'b1;
            if (v_done_ch[3]) reg_irq_status[7] <= 1'b1;
            if (h2c_done_ch[1]) reg_irq_status[8] <= 1'b1;
            if (h2c_done_ch[2]) reg_irq_status[9] <= 1'b1;
            if (h2c_done_ch[3]) reg_irq_status[10] <= 1'b1;

            // Completion accounting (saturating at 255).
            if (h2c_done && !h2c_send && (h2c_pending != 8'hFF))
                h2c_pending <= h2c_pending + 8'd1;
            else if (!h2c_done && h2c_send)
                h2c_pending <= h2c_pending - 8'd1;

            if (c2h_done && !c2h_send && (c2h_pending != 8'hFF))
                c2h_pending <= c2h_pending + 8'd1;
            else if (!c2h_done && c2h_send)
                c2h_pending <= c2h_pending - 8'd1;

            case (state)
                IDLE: begin
                    irq_req_valid <= 1'b0;
                    if (h2c_send || c2h_send) begin
                        irq_req_valid <= 1'b1;
                        irq_req_code  <= h2c_send ? 8'h01 : 8'h02;
                        usr_irq_req   <= 1'b1;
                        state         <= SEND_MSI;
                    end
                end

                SEND_MSI: begin
                    if (irq_req_ack || usr_irq_ack) begin
                        irq_req_valid <= 1'b0;
                        usr_irq_req   <= 1'b0;
                        state         <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
