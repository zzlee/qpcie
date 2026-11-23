// ---------------------------------------------------------------------------
// sc7f0_pcie_ext_tag_enable.v
//
// Real "may this function use extended (Request Tag > 31)?" indicator for the
// SC7F0-RGB-COMPOSITOR-2PPC overlay plane, obtained by reading configuration
// space through the PCIe core's cfg_mgmt READ port.
//
// ---------------------------------------------------------------------------
// Register facts, checked against local authoritative sources (not asserted
// from memory):
//
// * /usr/include/linux/pci_regs.h
//       #define PCI_EXP_DEVCTL            0x08   /* Device Control, byte offset
//                                                   inside the PCIe capability */
//       #define PCI_EXP_DEVCTL_RELAX_EN   0x0010 /* Enable relaxed ordering   */
//       #define PCI_EXP_DEVCTL_EXT_TAG    0x0100 /* Extended Tag Field Enable */
//   => the enable is bit 8 of Device Control.  Bit 4 is Relaxed Ordering and
//      must not be mistaken for an authorisation to use tags > 31.
//       #define PCI_EXP_DEVCAP_EXT_TAG    0x00000020 /* Extended tags */
//   => Device Capability (byte offset 0x04) bit 5 says whether this function
//      supports extended tags at all.
//
// * PCIe capability layout: byte base + 0x00 capability header
//   ([7:0] = capability ID, 0x10 for PCI Express, [15:8] = next pointer),
//   base + 0x04 Device Capability, base + 0x08 Device Control (16 bit, lower
//   half of that doubleword), base + 0x0A Device Status.  A capability base is
//   doubleword aligned, so base + 0x08 is a doubleword address and Device
//   Control is its [15:0].
//
// * cfg_mgmt_addr: the core returns the *doubleword* that contains the
//   address, and cfg_mgmt_read_data is that aligned doubleword.  This module
//   therefore drives the doubleword index (byte address >> 2) and decodes with
//   the low two address bits.  What makes a wrong unit impossible to be
//   silently mis-authorising is the ID check itself: every walk address is
//   derived from the capability pointer, so if the unit were wrong the header
//   read would not decode capability ID 0x10 and the walk would end with
//   ext_tag_enable = 0 (fail closed), never with a wrong 1.
//
// * Gate condition uses ONLY signals whose meaning this board design already
//   relies on in hardware: pcie_user_lnk_up (rtl/zu4ev_pcie_card_top.v has
//   assigned pcie_user_rst_n = pcie_user_lnk_up && ~pcie_user_reset since before
//   this profile).  cfg_function_status[0] is deliberately NOT interpreted as a
//   D0 indicator here; the D0 power state has its own
//   cfg_function_power_state port and is not needed for a read-only walk.
//
// ---------------------------------------------------------------------------
// Behaviour
//   * walk: config byte 0x34 (capability pointer, the LOW byte of doubleword
//     0x0D) -> capability linked list -> first capability with ID 0x10 ->
//     Device Capability bit 5 (support) and Device Control bit 4+... = bit 8
//     (enable) -> ext_tag_enable.
//   * refresh: a bounded timer restarts the walk periodically, so a host that
//     sets Extended Tag Field Enable after enumeration is seen; the first walk
//     is attempted continuously until it succeeds.
//   * fail closed: link down, cfg_mgmt timeout, capability pointer 0, end of
//     list, list longer than WALK_BOUND, capability ID mismatch, function that
//     does not report Device Capability.Ext_Tag support, or reset all leave
//     ext_tag_enable = 0.
//   * read only: this block has no cfg_mgmt_write / write_data / byte_enable
//     ports at all, so it cannot modify configuration space.  It gates only the
//     new overlay-plane read requests; the legacy upgrade (H2C) path, the
//     mailbox and the MCU path do not depend on it.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module sc7f0_pcie_ext_tag_enable #(
    // ~1 s at 125 MHz user_clk: 2^17 = 131072 cycles = 1.05 ms per tick, and
    // the refresh counter needs 16 ticks, so a host-side change is picked up
    // within ~17 ms worst case, and the walk itself costs a handful of cycles.
    parameter integer REFRESH_SHIFT   = 17,
    // a cfg_mgmt read that does not complete within 2^MGMT_TO cycles is treated
    // as a failure and retried after the next refresh tick.
    parameter integer MGMT_TO_SHIFT   = 16,
    parameter [7:0]   WALK_BOUND      = 8'd40
)(
    input  wire clk,
    input  wire rst_n,

    input  wire user_lnk_up,                 // trusted link indicator

    // cfg_mgmt read side only
    output reg  [9:0]  cfg_mgmt_addr,        // DOUBLEWORD index
    output reg  [7:0]  cfg_mgmt_function_number,
    output reg         cfg_mgmt_read,
    input  wire [31:0] cfg_mgmt_read_data,
    input  wire        cfg_mgmt_read_write_done,

    output reg         ext_tag_enable,       // registered Device Control[8]
    output reg         devcap_ext_tag,       // Device Capability bit 5
    output reg         walk_done,            // one full successful walk
    output reg         walk_overflow,        // capability list exceeded bound
    output reg         mgmt_timeout          // a read never completed
);
    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_REQ   = 3'd1;
    localparam [2:0] ST_WAIT  = 3'd2;
    localparam [2:0] ST_CAP   = 3'd3;        // decode capability header
    localparam [2:0] ST_DEVCAP= 3'd4;        // decode Device Capability
    localparam [2:0] ST_DEVCTL= 3'd5;        // decode Device Control

    localparam [1:0] PH_PTR    = 2'd0;
    localparam [1:0] PH_CAP    = 2'd1;
    localparam [1:0] PH_DEVCAP = 2'd2;
    localparam [1:0] PH_DEVCTL = 2'd3;

    // Byte addresses of the things we read.  0x34 is the capability pointer and
    // lives in the LOW byte of doubleword 0x0D.
    localparam [9:0] DW_CAP_PTR = 10'h00D;   // byte 0x34 >> 2

    reg  [2:0]  state;
    reg  [1:0]  phase;
    reg  [7:0]  steps;
    reg  [7:0]  cap_dw;                      // current capability header, DW idx
    reg  [9:0]  req_dw;                      // doubleword index to read next
    reg  [1:0]  sub;                         // low address bits of that read
    reg  [31:0] rd_lat;                      // latched on the done cycle
    reg  [REFRESH_SHIFT-1:0] tick;
    reg  [MGMT_TO_SHIFT-1:0] to_cnt;

    wire [31:0] rd_shift = rd_lat >> {sub, 3'b000};
    wire [7:0]  cap_id   = rd_shift[7:0];
    wire [7:0]  cap_next = rd_shift[15:8];

    task start_walk;
        begin
            req_dw        <= DW_CAP_PTR;
            sub           <= 2'b00;
            phase         <= PH_PTR;
            steps         <= 8'd0;
            // Keep ext_tag_enable / devcap_ext_tag glitch-free across periodic
            // refresh walks; only link-down, reset, or a completed/failed walk
            // updates them.
            state         <= ST_REQ;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                    <= ST_IDLE;
            phase                    <= PH_PTR;
            steps                    <= 8'd0;
            cap_dw                   <= 8'd0;
            req_dw                   <= 10'd0;
            sub                      <= 2'b00;
            rd_lat                   <= 32'd0;
            tick                     <= {REFRESH_SHIFT{1'b0}};
            to_cnt                   <= {MGMT_TO_SHIFT{1'b0}};
            cfg_mgmt_addr            <= 10'd0;
            cfg_mgmt_function_number <= 8'd0;
            cfg_mgmt_read            <= 1'b0;
            ext_tag_enable           <= 1'b0;
            devcap_ext_tag           <= 1'b0;
            walk_done                <= 1'b0;
            walk_overflow            <= 1'b0;
            mgmt_timeout             <= 1'b0;
        end else if (!user_lnk_up) begin
            // Losing the link invalidates the result immediately: a different
            // host or a re-enumeration may present a different Device Control.
            state          <= ST_IDLE;
            cfg_mgmt_read  <= 1'b0;
            ext_tag_enable <= 1'b0;
            devcap_ext_tag <= 1'b0;
            walk_done      <= 1'b0;
            walk_overflow  <= 1'b0;
            mgmt_timeout   <= 1'b0;
            steps          <= 8'd0;
        end else begin
            tick <= tick + 1'b1;

            case (state)
                // ----------------------------------------------------------------
                ST_IDLE: begin
                    cfg_mgmt_read <= 1'b0;
                    // Keep trying until one walk completes, then re-run it on
                    // every timer tick (~2^REFRESH_SHIFT user clocks), so a
                    // host that sets Extended Tag Field Enable after
                    // enumeration is observed without any software help here.
                    if (!walk_done || tick == {REFRESH_SHIFT{1'b0}})
                        start_walk;
                end

                // ----------------------------------------------------------------
                ST_REQ: begin
                    cfg_mgmt_addr            <= req_dw;
                    cfg_mgmt_function_number <= 8'd0;     // PF0, as everywhere
                    cfg_mgmt_read            <= 1'b1;     // else in this design
                    to_cnt                   <= {MGMT_TO_SHIFT{1'b0}};
                    state                    <= ST_WAIT;
                end

                // ----------------------------------------------------------------
                ST_WAIT: begin
                    if (cfg_mgmt_read_write_done) begin
                        cfg_mgmt_read <= 1'b0;
                        rd_lat        <= cfg_mgmt_read_data;
                        mgmt_timeout  <= 1'b0;
                        case (phase)
                            PH_PTR: begin
                                // capability pointer = LOW byte of doubleword
                                // 0x0D (bits [15:8] would be byte 0x35)
                                if (cfg_mgmt_read_data[7:0] == 8'd0) begin
                                    // no capability list: nothing to authorise
                                    ext_tag_enable <= 1'b0;
                                    walk_done      <= 1'b0;
                                    state          <= ST_IDLE;
                                end else begin
                                    cap_dw   <= {2'd0, cfg_mgmt_read_data[7:0]}
                                                >> 2;     // byte -> doubleword
                                    req_dw   <= {2'd0, cfg_mgmt_read_data[7:0]}
                                                >> 2;
                                    sub      <= cfg_mgmt_read_data[1:0];
                                    phase    <= PH_CAP;
                                    state    <= ST_REQ;
                                end
                            end
                            PH_CAP:    state <= ST_CAP;
                            PH_DEVCAP: state <= ST_DEVCAP;
                            PH_DEVCTL: state <= ST_DEVCTL;
                            default:   state <= ST_IDLE;
                        endcase
                    end else begin
                        to_cnt <= to_cnt + 1'b1;
                        if (to_cnt == {MGMT_TO_SHIFT{1'b0}} - 1'b1) begin
                            // The core never answered.  Never treat an
                            // unanswered read as authorisation.
                            cfg_mgmt_read  <= 1'b0;
                            mgmt_timeout   <= 1'b1;
                            ext_tag_enable <= 1'b0;
                            walk_done      <= 1'b0;
                            state          <= ST_IDLE;
                        end
                    end
                end

                // ----------------------------------------------------------------
                ST_CAP: begin
                    if (cap_id == 8'h10) begin
                        // PCI Express capability.  Device Capability is the
                        // doubleword right after the header (byte base + 0x04).
                        // Device Capability is the doubleword right after the
                        // header (byte base + 0x04).  A capability base is
                        // doubleword aligned, so that read is itself aligned:
                        // sub stays 0 and the whole word is Device Capability.
                        req_dw   <= cap_dw + 10'd1;
                        sub      <= 2'b00;
                        phase    <= PH_DEVCAP;
                        state    <= ST_REQ;
                    end else if (cap_next == 8'd0) begin
                        ext_tag_enable <= 1'b0;
                        walk_done      <= 1'b0;
                        state          <= ST_IDLE;
                    end else if (steps >= WALK_BOUND) begin
                        ext_tag_enable <= 1'b0;
                        walk_done      <= 1'b0;
                        walk_overflow  <= 1'b1;
                        state          <= ST_IDLE;
                    end else begin
                        steps    <= steps + 8'd1;
                        cap_dw   <= {2'd0, cap_next} >> 2;
                        req_dw   <= {2'd0, cap_next} >> 2;
                        sub      <= cap_next[1:0];
                        phase    <= PH_CAP;
                        state    <= ST_REQ;
                    end
                end

                // ----------------------------------------------------------------
                ST_DEVCAP: begin
                    // Device Capability bit 5 = Extended Tags supported
                    // (PCI_EXP_DEVCAP_EXT_TAG 0x00000020).
                    devcap_ext_tag <= rd_shift[5];
                    if (!rd_shift[5]) begin
                        // This function cannot use tags > 31 at all.
                        ext_tag_enable <= 1'b0;
                        walk_done      <= 1'b0;
                        state          <= ST_IDLE;
                    end else begin
                        // Device Control: byte base + 0x08, i.e. two
                        // doublewords after the header doubleword.
                        req_dw   <= cap_dw + 10'd2;
                        sub      <= 2'b00;
                        phase    <= PH_DEVCTL;
                        state    <= ST_REQ;
                    end
                end

                // ----------------------------------------------------------------
                ST_DEVCTL: begin
                    // Device Control is the lower 16 bits of that doubleword;
                    // Extended Tag Field Enable is bit 8
                    // (PCI_EXP_DEVCTL_EXT_TAG 0x0100).
                    ext_tag_enable <= rd_shift[8];
                    walk_done      <= 1'b1;
                    walk_overflow  <= 1'b0;
                    state          <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
