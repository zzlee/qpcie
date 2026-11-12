`default_nettype none
// ============================================================================
// Reset-domain crossing primitives.
//
// WHY THIS FILE EXISTS
// build/vcu-release-26111103-r1 reported 28 CDC-10 (combinational logic before
// a synchronizer) and 10 CDC-12 (multi-clock fan-in to a synchronizer) critical
// violations.  Every one of them had the same shape:
//
//     xpm_cdc_async_rst #(...) u_x (.src_arst(!a_rst_n || !b_rst_n), ...);
//
// `a_rst_n` and `b_rst_n` come from unrelated clocks (two proc_sys_reset blocks,
// a PS CSR flop, the PCIe IP's user_reset, ...).  OR-ing them before the
// synchronizer puts an un-analysable function of two asynchronous flops on the
// asynchronous preset of the destination's first synchronizer flop.  The preset
// is level sensitive, so a sub-cycle runt on that OR either releases the
// destination chain early (some flops leave reset while their neighbours do not)
// or is missed entirely.  No amount of DEST_SYNC_FF depth fixes it, because the
// glitch is on the synchronizer's own asynchronous input.
//
// THE RULE THESE MODULES ENFORCE
//   1. Each asynchronous reset source crosses into the destination clock through
//      its own xpm_cdc_async_rst.  Assert therefore stays asynchronous (it is
//      seen immediately, never delayed by a synchronizer that needs a clock edge
//      and could miss a short assertion), and release is always synchronous.
//   2. Combination (AND) happens only between signals that are already in the
//      destination clock domain.  A gate over same-domain flops cannot produce a
//      cross-domain race.  It is still re-synchronised once more (u_final) so a
//      runt produced by an asynchronous assert arriving on the same edge as a
//      synchronous release cannot reach the consumers as a momentary release:
//      the last stage only releases after DEST_SYNC_FF clean destination cycles.
//      That last stage is a same-clock path, so it is not a crossing and does not
//      create a new report_cdc object.
//   3. A single-cycle cross-domain event is never used as a reset.  Use
//      sc7f0_event_reset to turn it into a provably wide, in-domain level with a
//      visible busy/ACK, then feed that level as one source here.
//
// CONTRACT / LIMITS (read before instantiating)
//   * SOURCES must be >= 1.  With one source this is exactly xpm_cdc_async_rst.
//   * Minimum source assertion width: an xpm_cdc_async_rst is guaranteed to
//     capture its source only if the source stays asserted long enough for the
//     destination synchronizer to see it.  Do not feed a pulse here; feed a
//     level, or the output of sc7f0_event_reset.  Every source used at board
//     level today is either a proc_sys_reset output, an IP reset/link output, or
//     a sc7f0_event_reset level, all of which satisfy this.
//   * No dependence on start-up order or on a clock that "always runs": if
//     dest_clk is stopped, dest_rst_n is held asserted through the asynchronous
//     assert path and only releases once dest_clk is actually toggling.
//   * dest_rst_n is a plain same-domain level: safe as a synchronous reset, as
//     an asynchronous preset for other flops in dest_clk, or as one entry of
//     another instance's src_rst_n.
// ============================================================================
`timescale 1ns/1ps

module sc7f0_reset_sync #(
    parameter integer SOURCES = 2,
    parameter integer DEST_SYNC_FF = 4
)(
    input  wire                dest_clk,
    // One bit per independent asynchronous reset source, active low.
    input  wire [SOURCES-1:0]  src_rst_n,
    output wire                dest_rst_n
);
    wire [SOURCES-1:0] synced;
    genvar g;
    // generate-for index compared with a parameter: fine in Verilog-2001.
    generate
        for (g = 0; g < SOURCES; g = g + 1) begin : g_src
            xpm_cdc_async_rst #(
                .DEST_SYNC_FF  (DEST_SYNC_FF),
                .RST_ACTIVE_HIGH(0)
            ) u_src_sync (
                .src_arst (src_rst_n[g]),
                .dest_clk (dest_clk),
                .dest_arst(synced[g])
            );
        end
    endgenerate

    // Every term here is already a dest_clk-domain flop output, so this is not a
    // clock-domain crossing; it is re-synchronised once for runt filtering.
    wire combined_n = &synced;
    xpm_cdc_async_rst #(
        .DEST_SYNC_FF   (DEST_SYNC_FF),
        .RST_ACTIVE_HIGH(0)
    ) u_final (
        .src_arst (combined_n),
        .dest_clk (dest_clk),
        .dest_arst(dest_rst_n)
    );
endmodule

// ============================================================================
// Cross-domain *event* -> provably wide in-domain reset level.
//
// The CSR transport (qpcie_csr_cdc / xpm_cdc_pulse) delivers a one-cycle pulse
// in the destination clock.  That is correct for events and fatal for resets: an
// asynchronous preset of another clock domain may or may not see one cycle, and
// using it that way was CDC-10 row
//   u_axil_reg_space/u_controls/dest_event_reg[0]/C
//     -> u_dma_top/u_video_req_cdc/u_wr_reset/arststages_ff_reg[0]/PRE.
//
// Contract:
//   * evt_clk MUST be the clock that produces `evt`.  Capturing a same-domain
//     one-cycle pulse with a normal synchronous flop cannot lose it, which is
//     why this module does not put a synchronizer in front of `evt`.
//   * rst_n stays asserted for at least HOLD_CYCLES evt_clk cycles, so any
//     destination clock slower than evt_clk/HOLD_CYCLES is guaranteed to see it.
//   * pending is a visible "the request was captured and is being applied"
//     level: the requester (or a testbench) can prove the event was not dropped.
//   * Re-triggering while busy simply restarts the hold window; it cannot make
//     the assertion shorter than HOLD_CYCLES.
// ============================================================================
module sc7f0_event_reset #(
    parameter integer WIDTH = 1,
    parameter integer HOLD_CYCLES = 64,
    parameter integer CNT_WIDTH = $clog2(HOLD_CYCLES + 1)
)(
    input  wire             evt_clk,
    input  wire             evt_rst_n,
    input  wire [WIDTH-1:0] evt,
    output wire [WIDTH-1:0] rst_n,
    output wire             pending
);
    // Sized form of the parameter without a SystemVerilog cast (this tree is
    // Verilog-2001).  Implicit truncation is intended: CNT_WIDTH is sized for it.
    wire [CNT_WIDTH-1:0] HOLD_VALUE = HOLD_CYCLES;
    wire [WIDTH-1:0] busy;
    genvar g;
    generate
        for (g = 0; g < WIDTH; g = g + 1) begin : g_hold
            reg [CNT_WIDTH-1:0] count = {CNT_WIDTH{1'b0}};
            reg                 released = 1'b0;
            always @(posedge evt_clk or negedge evt_rst_n) begin
                if (!evt_rst_n) begin
                    count    <= {CNT_WIDTH{1'b0}};
                    released <= 1'b0;
                end else if (evt[g]) begin
                    count    <= HOLD_VALUE;
                    released <= 1'b0;
                end else if (count != {CNT_WIDTH{1'b0}}) begin
                    count    <= count - 1'b1;
                    released <= 1'b0;
                end else begin
                    released <= 1'b1;
                end
            end
            assign rst_n[g] = released;
            assign busy[g]  = evt[g] || (count != {CNT_WIDTH{1'b0}}) || !released;
        end
    endgenerate
    // Visible proof for the requester (and for testbench S3) that the event was
    // captured and is being applied rather than silently dropped.
    assign pending = |busy;
endmodule
