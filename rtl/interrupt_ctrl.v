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
    output reg  [31:0] reg_irq_status, // bit 0: H2C IRQ, bit 1: C2H IRQ

    // Completion triggers from DMA Engines
    input  wire        h2c_done,
    input  wire        c2h_done,

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            reg_irq_status <= 32'd0;
            irq_req_valid  <= 1'b0;
            irq_req_code   <= 8'd0;
            usr_irq_req    <= 1'b0;
        end else begin
            // Track IRQ status flags
            if (h2c_done) reg_irq_status[0] <= 1'b1;
            if (c2h_done) reg_irq_status[1] <= 1'b1;

            case (state)
                IDLE: begin
                    irq_req_valid <= 1'b0;
                    if ((h2c_done && reg_irq_ctrl[0]) || (c2h_done && reg_irq_ctrl[1])) begin
                        irq_req_valid <= 1'b1;
                        irq_req_code  <= (h2c_done) ? 8'h01 : 8'h02;
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
