// ============================================================================
// xpm_cdc_handshake_sim.v
//
// Behavioral (simulation-only) replacement for the Xilinx XPM xpm_cdc_handshake
// primitive. Implements the classic 4-phase level handshake across clock
// domains with 2-ff synchronizers:
//
//   src domain                          dest domain
//   ----------                          -----------
//   src_send + src_in  ===============> dest_req + dest_out
//   src_rcv  <========================  dest_ack
//
//   DEST_EXT_HSK=1: dest_req stays high until the destination acknowledges
//                   with dest_ack; src_rcv follows the synced ack.
//   DEST_EXT_HSK=0: internal auto-ack; dest_req is a one-cycle pulse and
//                   src_rcv follows the synced dest_req.
//
// Data is captured at the source edge and re-synchronized into the
// destination domain with a 2-ff chain; dest_out is latched when the request
// is detected so it stays stable through the whole handshake.
//
// NOT SYNTHESIZABLE - use the real XPM library for implementation.
//
// Matches every xpm_cdc_handshake instance in custom_pcie_dma_top.v
// (WIDTH=241, DEST_EXT_HSK=1).
// ============================================================================

module xpm_cdc_handshake #(
    parameter integer WIDTH       = 1,
    parameter integer DEST_EXT_HSK = 0
)(
    input  wire             src_clk,
    input  wire             src_send,
    input  wire [WIDTH-1:0] src_in,
    output wire             src_rcv,
    input  wire             dest_clk,
    output wire             dest_req,
    output wire [WIDTH-1:0] dest_out,
    input  wire             dest_ack
);

    // ---------------- src clock domain -------------------------------------
    reg [WIDTH-1:0]   data_q   = {WIDTH{1'b0}};   // captured source data
    reg               send_q   = 1'b0;            // request outstanding
    reg               ack_s0   = 1'b0;            // sync of dest_ack / dest_req
    reg               ack_s1   = 1'b0;

    // ---------------- dest clock domain ------------------------------------
    reg               req_s0   = 1'b0;            // sync of send_q
    reg               req_s1   = 1'b0;
    reg [WIDTH-1:0]   data_s0  = {WIDTH{1'b0}};   // 2-ff data sync
    reg [WIDTH-1:0]   data_s1  = {WIDTH{1'b0}};
    reg [WIDTH-1:0]   dout_q   = {WIDTH{1'b0}};
    reg               dest_req_q = 1'b0;

    wire ack_in = DEST_EXT_HSK ? dest_ack : dest_req_q;
    assign src_rcv = ack_s1 && send_q;

    // 4-phase source FSM: wait for ack to clear send_q, then accept new data
    always @(posedge src_clk) begin
        ack_s0 <= ack_in;
        ack_s1 <= ack_s0;
        if (src_rcv) begin
            send_q <= 1'b0;
        end else if (src_send && !send_q) begin
            data_q <= src_in;
            send_q <= 1'b1;
        end
    end

    // destination: assert dest_req on synced request edge, latch synced data,
    // release dest_req only after the source has dropped the request.
    always @(posedge dest_clk) begin
        req_s0   <= send_q;
        req_s1   <= req_s0;
        data_s0  <= data_q;
        data_s1  <= data_s0;
        if (req_s1 && !dest_req_q) begin
            dout_q     <= data_s1;
            dest_req_q <= 1'b1;
        end else if (!req_s1 && dest_req_q) begin
            dest_req_q <= 1'b0;
        end
    end

    assign dest_req = dest_req_q;
    assign dest_out = dout_q;

endmodule