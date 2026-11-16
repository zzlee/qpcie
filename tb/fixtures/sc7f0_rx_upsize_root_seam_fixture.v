`timescale 1ns / 1ps
// ============================================================================
// tb/fixtures/sc7f0_rx_upsize_root_seam_fixture.v  (NEW file, simulation only)
//
// Root-seam fixture for the SC7F0-RGB COMPOSITOR RX ready contract.
//
// WHY THIS FILE EXISTS.  rtl/zu4ev_pcie_card_top.v drives the 2 PPC -> 4 PPC
// width adapter and hands the published beat to rtl/sc7f0_capture_pipeline.v,
// which has NO ready output at all ("RX is an observer input: no connection can
// propagate downstream READY to RX", rtl/sc7f0_capture_pipeline.v:3).  Round H
// compiled that seam with rx_ss_video_up_tready declared and never driven -
// logs/build_full26111403.log:1214 "[Synth 8-3848] Net rx_ss_video_up_tready in
// module/entity zu4ev_pcie_card_top does not have driver" at the wire declaration
// (H snapshot line 1202).  An adapter unit test cannot see that: its testbench
// drives m_axis_tready itself, so the unit test passes while the product path is
// broken.  These two fixtures reproduce the ROOT seam, not an idealised sink.
//
// HOW IT STAYS HONEST.  The block between the VERBATIM markers is a byte-for-byte
// copy of the production root's RGB branch (wire declarations, the ready
// assignment, and the sc7f0_ppc_upsize instantiation, including its port list).
// scripts/check_sc7f0_rx_upsize_seam_static.py compares every non-comment line of
// each fixture against the CURRENT rtl/zu4ev_pcie_card_top.v and fails the gate
// if the production wiring differs, so this fixture cannot drift into testing
// something the product does not do.
//
//   sc7f0_rx_upsize_root_seam_pos  - the repaired seam: rx_ss_video_up_tready is
//                                    assigned constant 1 (the documented sink
//                                    contract for an unpausable observer).
//   sc7f0_rx_upsize_root_seam_h    - the round H baseline: the same block with the
//                                    assignment absent, so the wire stays undriven
//                                    and reads 'Z' here in simulation.  Synthesis
//                                    resolves an undriven net to a constant
//                                    ([Synth 8-3848] then a tie), which is the
//                                    behaviour the round H netlist measurement
//                                    (M5) characterises; either way out_room goes
//                                    false after the first published beat.
//
// Simulation-only: nothing here is added to any synthesis fileset.
// ============================================================================

// -----------------------------------------------------------------------------
// Repaired seam (production root after the one-line ready assignment).
// -----------------------------------------------------------------------------
module sc7f0_rx_upsize_root_seam_pos (
    // Fixture-only port list.  The names inside the VERBATIM block below are the
    // root's own signal names; these ports are the harness handles for them.
    input  wire        phy_rx_video_clk,   // root: 2 PPC RX video clock
    input  wire        rx_video_rst,       // root: active-high RX video reset
    input  wire [47:0] rx_ss_video_tdata,  // root: RX subsystem 2 PPC beat
    input  wire        rx_ss_video_tvalid,
    input  wire        rx_ss_video_tlast,  // root: end of line
    input  wire        rx_ss_video_tuser   // root: start of frame
);
    // Root declaration lives at rtl/zu4ev_pcie_card_top.v:1017 and is driven by
    // the adapter itself; kept here so the verbatim instance below resolves.
    wire rx_ss_video_tready;

    // ---- BEGIN VERBATIM rtl/zu4ev_pcie_card_top.v SC7F0_RGB_COMPOSITOR branch
    wire [95:0] rx_ss_video_up_tdata;
    wire        rx_ss_video_up_tvalid, rx_ss_video_up_tready;
    wire        rx_ss_video_up_tlast,  rx_ss_video_up_tuser;
    wire        rx_up_odd_line_sticky, rx_up_out_stall_sticky;
    wire [31:0] rx_up_odd_line_count,  rx_up_out_stall_count;
    assign rx_ss_video_up_tready = 1'b1;
    sc7f0_ppc_upsize #(.PPC_IN(2), .PPC_OUT(4)) u_rx_ppc_upsize (
        .clk(phy_rx_video_clk), .rst_n(!rx_video_rst),
        .s_axis_tdata(rx_ss_video_tdata), .s_axis_tvalid(rx_ss_video_tvalid),
        .s_axis_tlast(rx_ss_video_tlast), .s_axis_tuser(rx_ss_video_tuser),
        .s_axis_tready(rx_ss_video_tready),
        .m_axis_tdata(rx_ss_video_up_tdata), .m_axis_tvalid(rx_ss_video_up_tvalid),
        .m_axis_tready(rx_ss_video_up_tready), .m_axis_tlast(rx_ss_video_up_tlast),
        .m_axis_tuser(rx_ss_video_up_tuser),
        .odd_line_sticky(rx_up_odd_line_sticky), .odd_line_count(rx_up_odd_line_count),
        .output_stall_sticky(rx_up_out_stall_sticky),
        .output_stall_count(rx_up_out_stall_count));
    // ---- END VERBATIM
endmodule

// -----------------------------------------------------------------------------
// Round H baseline: identical seam with the ready assignment missing.  This is
// the wiring that produced H's [Synth 8-3848] warning, kept as a compiling
// negative control so the gate proves the test can actually see the defect.
// -----------------------------------------------------------------------------
module sc7f0_rx_upsize_root_seam_h (
    input  wire        phy_rx_video_clk,
    input  wire        rx_video_rst,
    input  wire [47:0] rx_ss_video_tdata,
    input  wire        rx_ss_video_tvalid,
    input  wire        rx_ss_video_tlast,
    input  wire        rx_ss_video_tuser
);
    wire rx_ss_video_tready;

    // ---- BEGIN VERBATIM rtl/zu4ev_pcie_card_top.v SC7F0_RGB_COMPOSITOR branch
    wire [95:0] rx_ss_video_up_tdata;
    wire        rx_ss_video_up_tvalid, rx_ss_video_up_tready;
    wire        rx_ss_video_up_tlast,  rx_ss_video_up_tuser;
    wire        rx_up_odd_line_sticky, rx_up_out_stall_sticky;
    wire [31:0] rx_up_odd_line_count,  rx_up_out_stall_count;
    sc7f0_ppc_upsize #(.PPC_IN(2), .PPC_OUT(4)) u_rx_ppc_upsize (
        .clk(phy_rx_video_clk), .rst_n(!rx_video_rst),
        .s_axis_tdata(rx_ss_video_tdata), .s_axis_tvalid(rx_ss_video_tvalid),
        .s_axis_tlast(rx_ss_video_tlast), .s_axis_tuser(rx_ss_video_tuser),
        .s_axis_tready(rx_ss_video_tready),
        .m_axis_tdata(rx_ss_video_up_tdata), .m_axis_tvalid(rx_ss_video_up_tvalid),
        .m_axis_tready(rx_ss_video_up_tready), .m_axis_tlast(rx_ss_video_up_tlast),
        .m_axis_tuser(rx_ss_video_up_tuser),
        .odd_line_sticky(rx_up_odd_line_sticky), .odd_line_count(rx_up_odd_line_count),
        .output_stall_sticky(rx_up_out_stall_sticky),
        .output_stall_count(rx_up_out_stall_count));
    // ---- END VERBATIM
endmodule
