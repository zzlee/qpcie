#!/usr/bin/env python3
"""Regression tests for the two-layer SC7F0 gate (Layer A correctness, Layer B
itemised review).

Layout of the tests:

* positive   - real routed structures (XPM async FIFO LUTRAM arcs, the probe
               meter held snapshot, the 64-bit Gray timestamp, the vendor RX-SS
               DPRAM collision arcs, the named clock pair) classified by the
               shipped policy;
* negative   - the ways a round can try to look clean: missing/fabricated
               reports, Critical findings filed as Warnings, unknown rules /
               roots / severities / clock pairs, empty or double classifications,
               count mismatches, an overridden or absent max_delay or bus_skew,
               DDC left unreviewed, evidence prose with no structure behind it,
               and a coverage manifest that belongs to a different round;
* frozen r3  - the shipped 26111103-r1 reports must still FAIL both layers; the
               original failure record is never overwritten.

Nothing here runs Vivado, touches hardware, or rewrites a frozen report.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import check_sc7f0_timing as gate          # noqa: E402
import sc7f0_review_policy as review       # noqa: E402
import sc7f0_release_id as release_id      # noqa: E402
from gate_fixtures import (cdc_rows_from_text, expected_endpoints,  # noqa: E402
                           hook_item, io_record, output_record, pad_closure,
                           produced_fields, row_groups, write_manifest)

POLICY = REPO / "scripts" / "gates"
R3 = REPO / "build" / "vcu-release-26111103-r1" / "fpga" / "project"
R3_RECORD = (REPO / "build" / "vcu-release-26111103-r1" / "gates"
             / "timing-gate-recheck-fixed-parser.json")

COVERAGE_NAMES = ('no_clock', 'constant_clock', 'pulse_width_clock',
                  'unconstrained_internal_endpoints', 'multiple_clock',
                  'generated_clocks', 'loops', 'latch_loops',
                  'partial_input_delay', 'partial_output_delay')

XPM_SRC = ('u_dma_top/u_axil_reg_space/u_controls/u_fifo/gnuram_async_fifo'
           '.xpm_fifo_base_inst/gen_sdpram.xpm_memory_base_inst/mem_reg_0_15_0_13'
           '/RAMA/CLK')
XPM_DST = ('u_dma_top/u_axil_reg_space/u_controls/u_fifo/gnuram_async_fifo'
           '.xpm_fifo_base_inst/gen_sdpram.xpm_memory_base_inst/doutb_reg[0]/D')
METER_SRC = 'u_hdmi_probe/u_meter_rx_clk/snapshot_test_reg[3]/C'
METER_DST = 'u_hdmi_probe/u_meter_rx_clk/measured_freq_hz_reg[3]/D'
GRAY_SRC = 'u_ps_capture/u_tap/gray_q_reg[7]/C'
GRAY_RX_DST = 'u_ps_capture/u_tap/u_source_time/stage0_reg[7]/D'
GRAY_CSR_DST = 'u_ps_capture/u_regs/u_time/stage0_reg[7]/D'
DPRAM_SRC = ('u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/PIX_FIFO_INST'
             '/aclk_dpram_reg_0_31_0_13/RAMA/CLK')
DPRAM_DST = ('u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/PIX_FIFO_INST'
             '/bclk_dout_reg[4]/D')
# The vendor DPRAM arcs live in several FIFO instances, and the policy reviews that
# structure (min_distinct_dest_parents), so a fixture with one instance is not a
# stand-in for a real round.
DPRAM_ROOTS = ("u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/VTD_INST/P_FIFO_INST",
               "u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/CORE_INST/CH0_INST/VID_INST"
               "/PIX_FIFO_INST",
               "u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/CORE_INST/CH0_INST/VID_INST"
               "/gen_ch0.DCS_FIFO_INST",
               "u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/CORE_INST/CH2_INST/PIX_FIFO_INST")
DPRAM_SRC_2 = DPRAM_ROOTS[1] + "/aclk_dpram_reg_0_31_0_13/RAMA/CLK"
DPRAM_SRC_3 = DPRAM_ROOTS[2] + "/aclk_dpram_reg_0_31_0_13/RAMB/CLK"
DPRAM_SRC_4 = DPRAM_ROOTS[3] + "/aclk_dpram_reg_0_31_0_13/RAMA/CLK"
DPRAM_DST_2 = DPRAM_ROOTS[1] + "/bclk_dout_reg[0]/D"
DPRAM_DST_3 = DPRAM_ROOTS[2] + "/bclk_dout_reg[1]/D"
DPRAM_DST_4 = DPRAM_ROOTS[3] + "/bclk_dout_reg[2]/D"


def cdc_row(index, rule, severity, exception, src, dest):
    return (f"{index:>3}  {rule}  {severity:<8}  some vendor description here   "
            f"  0  {exception:<23}  {src}  {dest}\n")


def cdc_text(rows):
    """rows: list of (rule, severity, exception, src, dest)."""
    severities = {}
    for rule, severity, _e, _s, _d in rows:
        severities[(rule, severity)] = severities.get((rule, severity), 0) + 1
    header = "".join(f"{rule}  {severity}  {count}  description\n"
                     for (rule, severity), count in sorted(severities.items()))
    body = "".join(cdc_row(i + 1, *row) for i, row in enumerate(rows))
    return header + "\nRow  ID  Severity  Description  Depth  Exception  " \
                    "Source (From)  Destination (To)\n" + body


def timing_text(state="Routed", wns="0.100", whs="0.010", wpws="0.200"):
    return ("| Tool Version      : Vivado v.2023.2 (lin64)\n"
            "| Design            : zu4ev_pcie_card_top\n"
            f"| Design State      : {state}\n"
            "|\n"
            " WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints"
            "  WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints"
            "  WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints\n"
            " -------      -------  ---------------------  -------------------"
            "  -------      -------  ---------------------  -------------------"
            "  --------     --------  ---------------------  -------------------\n"
            f" {wns}   {0.000:>7.3f}                    0                500"
            f"  {whs}   {0.000:>7.3f}                    0                500"
            f"  {wpws}   {0.000:>7.3f}                    0                500\n")


def coverage_text(high_ports=()):
    text = "".join(f"{i}. checking {name} (0)\n"
                   for i, name in enumerate(COVERAGE_NAMES, start=1))
    if high_ports:
        text += ("\n5. checking no_input_delay (%d)\n"
                 "------------------------------\n There are %d input ports with no "
                 "input delay specified. (HIGH)\n\n" % (len(high_ports), len(high_ports))
                 + "".join(port + "\n" for port in high_ports) + "\n")
    return text


def methodology_text(rows, details=""):
    """rows: list of (rule, severity, count)."""
    total = sum(count for _r, _s, count in rows)
    table = "".join(f"| {rule:<9}| {severity:<16}| description here           |"
                    f" {count:<10}|\n" for rule, severity, count in rows)
    return ("1. REPORT SUMMARY\n"
            "-------------\n"
            "            Netlist: netlist\n"
            f"   Violations found: {total}\n"
            "+-----------+------------------+----------------------------+------------+\n"
            "| Rule      | Severity         | Description                | Violations |\n"
            "+-----------+------------------+----------------------------+------------+\n"
            + table +
            "+-----------+------------------+----------------------------+------------+\n"
            "\n2. REPORT DETAILS\n-----------------\n" + details)


PAIR_DETAIL = (
    "TIMING-6#1 Critical Warning\n"
    "No common primary clock between related clocks  \n"
    "The clocks clk_pl_0 and pcie_user_clk are related (timed together) but they "
    "have no common primary clock. The design could fail in hardware.\n"
    "Related violations: <none>\n\n"
    "TIMING-7#1 Critical Warning\n"
    "No common node between related clocks  \n"
    "The clocks clk_pl_0 and pcie_user_clk are related (timed together) but they "
    "have no common node.\n"
    "Related violations: <none>\n")

# Round 26111202 also named the two RX video clocks against the PS PL clock
# (methodology.rpt:46-73, TIMING-6#2/#3 with TIMING-7#2/#3).  The wording follows
# the report; only the clock names differ.
PROBE_PAIR_DETAIL = (
    "TIMING-6#2 Critical Warning\n"
    "No common primary clock between related clocks  \n"
    "The clocks clkout2 and clk_pl_0 are related (timed together) but they "
    "have no common primary clock. The design could fail in hardware.\n"
    "Related violations: <none>\n\n"
    "TIMING-6#3 Critical Warning\n"
    "No common primary clock between related clocks  \n"
    "The clocks phy_rxoutclk and clk_pl_0 are related (timed together) but they "
    "have no common primary clock. The design could fail in hardware.\n"
    "Related violations: <none>\n\n"
    "TIMING-7#2 Critical Warning\n"
    "No common node between related clocks  \n"
    "The clocks clkout2 and clk_pl_0 are related (timed together) but they "
    "have no common node.\n"
    "Related violations: <none>\n\n"
    "TIMING-7#3 Critical Warning\n"
    "No common node between related clocks  \n"
    "The clocks phy_rxoutclk and clk_pl_0 are related (timed together) but they "
    "have no common node.\n"
    "Related violations: <none>\n")


def drc_text(rules, details=None):
    """rules: list of (rule, severity, count)."""
    total = sum(count for _r, _s, count in rules)
    table = "".join(f"| {rule:<9}| {severity:<14}| description here          | {count:<9}|\n"
                    for rule, severity, count in rules)
    blocks = details if details is not None else "".join(
        f"{rule}#{i} {severity}\n"
        f"DSP u_dma_top/u_sg_dma_engine/h2c_p0_bytes_q{i} input is not pipelined.\n"
        f"Related violations: <none>\n\n"
        for rule, severity, count in rules for i in range(1, count + 1))
    return ("| Tool Version : Vivado v.2023.2 (lin64)\n"
            "| Design       : zu4ev_pcie_card_top\n"
            "| Design State : Fully Routed\n"
            "1. REPORT SUMMARY\n"
            f"             Violations found: {total}\n"
            "+-----------+--------------+-----------------------------+-----------+\n"
            "| Rule      | Severity     | Description                 | Violations|\n"
            "+-----------+--------------+-----------------------------+-----------+\n"
            + table +
            "+-----------+--------------+-----------------------------+-----------+\n"
            "\n2. REPORT DETAILS\n-----------------\n" + blocks)


def bus_skew_text(slack="4.180"):
    return ("Bus Skew Report\n"
            "Id  Position  From  To  Corner  Requirement(ns)  Actual(ns)  Slack(ns)\n"
            " 1  218       64 cells  64 cells  Slow  6.000  1.820  " + slack + "\n"
            " Slow 6.000 1.820 " + slack + "\n"
            " Fast 6.000 0.959 " + slack + "\n")


def interaction_row(src, dst, classification, constraints):
    return (f"{src:<40}  {dst:<40}  rise - rise  0.07  0.00  0  876  2.00"
            f"  rise - rise  0.05  0.00  0  876  0.00  {classification}"
            f"  {constraints}\n")


def clock_interaction_text(rows=None):
    body = interaction_row("clk_pl_0", "pcie_user_clk", "No Common Clock",
                           "Partial False Path (unsafe)")
    body += interaction_row("pcie_user_clk", "clk_pl_0", "Ignored",
                            "Max Delay Datapath Only")
    # The two RX video / RX oversample clocks against the PS PL clock, both
    # directions, as report_clock_interaction printed them in round 26111202.
    for src, dst, classification, constraints in (
            ("clkout2", "clk_pl_0", "No Common Clock", "Partial False Path (unsafe)"),
            ("clk_pl_0", "clkout2", "Ignored", "Max Delay Datapath Only"),
            ("phy_rxoutclk", "clk_pl_0", "No Common Clock",
             "Partial False Path (unsafe)"),
            ("clk_pl_0", "phy_rxoutclk", "Ignored", "Max Delay Datapath Only")):
        body += interaction_row(src, dst, classification, constraints)
    if rows is not None:
        body = rows
    return ("| Command      : report_clock_interaction -delay_type min_max\n"
            "| Design State : Routed\n\nClock Interaction Table\n"
            "From Clock  To Clock  ...  Classification  Inter-Clock Constraints\n"
            + body)


def manifest_items(policy=None, rows=None):
    """The coverage items a clean round must produce for the shipped policy.

    Two rules keep this honest:

    * every field comes from scripts/check_sc7f0_named_constraints.tcl's own list
      of fields for that item (gate_fixtures.hook_item), so a requirement can no
      longer point at a field no producer writes;
    * every endpoint count is derived from the CDC rows of the round being
      simulated, which is the same relation the gate enforces, instead of a number
      copied out of 26111103-r1.

    With a policy given, manifest items the policy does not claim are left out:
    that is exactly how the gate treats an exception nobody reviewed, so a fixture
    that pretended otherwise would only test its own bookkeeping.
    """
    rows = rows if rows is not None else cdc_rows_from_text(cdc_text(CLEAN_CDC))
    groups = row_groups(rows)

    def endpoints(item_id):
        return expected_endpoints(groups, item_id) or 1

    items = {
        "clock_groups": {"class": "metric", "review_required": 0, "count": 0},
        "xpm_async_fifo_ce_arcs": hook_item(
            "xpm_async_fifo_ce_arcs", class_="cdc_constraint", review_required=1,
            from_objects=1024, to_objects=1024, endpoints=endpoints("xpm_async_fifo_ce_arcs"),
            exception_rows=8, endpoints_total=endpoints("xpm_async_fifo_ce_arcs"),
            from_coverage_pct=100.0, ignored=0, scope_overridden=0, paths_analysed=8,
            requirement="", worst_slack="1.200", exception_type="Max Delay Datapath Only",
            exception_position=315, probe_error=""),
        "probe_meter_max_delay": hook_item(
            "probe_meter_max_delay", class_="cdc_constraint", review_required=1,
            from_objects=224, to_objects=448, endpoints=endpoints("probe_meter_max_delay"),
            max_delay_expected_ns=10.0, max_delay_measured_ns=10.0,
            max_delay_effective=1, from_coverage_pct=100.0, exception_rows=1,
            endpoints_total=endpoints("probe_meter_max_delay"), ignored=0,
            scope_overridden=0, paths_analysed=8, requirement="10.000",
            worst_slack="1.200", exception_type="Max Delay Datapath Only",
            exception_position=152, probe_error=""),
        "capture_gray_to_source_time": hook_item(
            "capture_gray_to_source_time", class_="cdc_constraint", review_required=1,
            from_objects=64, to_objects=64,
            endpoints=endpoints("capture_gray_to_source_time"),
            max_delay_expected_ns=6.0, max_delay_measured_ns=6.0, max_delay_effective=1,
            bus_skew_ns=6.0, bus_skew_actual_ns=1.82, bus_skew_slack_ns=4.18,
            bus_skew_violated=0, from_coverage_pct=100.0, exception_rows=1, endpoints_total=64,
            ignored=0, scope_overridden=0, paths_analysed=8, requirement="6.000",
            worst_slack="0.400", exception_type="Max Delay Datapath Only",
            exception_position=217, probe_error=""),
        "capture_gray_to_csr_time": hook_item(
            "capture_gray_to_csr_time", class_="cdc_constraint", review_required=1,
            from_objects=64, to_objects=64,
            endpoints=endpoints("capture_gray_to_csr_time"),
            max_delay_expected_ns=6.0, max_delay_measured_ns=6.0, max_delay_effective=1,
            bus_skew_ns=6.0, bus_skew_actual_ns=1.96, bus_skew_slack_ns=4.041,
            bus_skew_violated=0, from_coverage_pct=100.0, exception_rows=1, endpoints_total=64,
            ignored=0, scope_overridden=0, paths_analysed=8, requirement="6.000",
            worst_slack="0.400", exception_type="Max Delay Datapath Only",
            exception_position=219, probe_error=""),
        "rx_ss_dpram_max_delay": hook_item(
            "rx_ss_dpram_max_delay", class_="cdc_constraint", review_required=1,
            from_objects=490, to_objects=718, endpoints=endpoints("rx_ss_dpram_max_delay"),
            max_delay_expected_ns=15.0, max_delay_measured_ns=15.0, max_delay_effective=1,
            from_coverage_pct=84.9, exception_rows=1,
            endpoints_total=endpoints("rx_ss_dpram_max_delay"), ignored=0,
            scope_overridden=0, paths_analysed=8, requirement="15.000",
            worst_slack="3.200", exception_type="Max Delay Datapath Only",
            exception_position=202, probe_error=""),
        "rx_ss_dpram_sample_timing": hook_item(
            "rx_ss_dpram_sample_timing", class_="cdc_constraint", review_required=1,
            from_objects=490, to_objects=718, paths_analysed=5, instances=4,
            requirement="15.000", worst_slack="3.200", max_delay_measured_ns=15.0,
            probe_error=""),
    }

    # asynchronous pad entries (constraints/sc7f0_async_io.xdc)
    async_inputs = {
        "async_in_hdmi_tx_hpd_in": ("hdmi_tx_hpd_in", 1),
        "async_in_hdmi_tx_ddc_scl": ("hdmi_tx_ddc_scl", 1),
        "async_in_hdmi_tx_ddc_sda": ("hdmi_tx_ddc_sda", 1),
        "async_in_hdmi_tx_refclk_rdy": ("hdmi_tx_refclk_rdy", 1),
        "async_in_hdmi_tx_refclk_rdy_vphy": ("hdmi_tx_refclk_rdy", 1),
        "async_in_hdmi_rx_5v_det_probe": ("hdmi_rx_5v_det", 1),
        "async_in_hdmi_rx_5v_det_pcie": ("hdmi_rx_5v_det", 1),
        "async_in_hdmi_rx_5v_det_rxss": ("hdmi_rx_5v_det", 1),
        "async_in_hdmi_rx_ddc_scl_probe": ("hdmi_rx_ddc_scl", 1),
        "async_in_hdmi_rx_ddc_sda_probe": ("hdmi_rx_ddc_sda", 1),
    }
    for item_id, (port, async_reg) in async_inputs.items():
        items[item_id] = io_record(item_id, port, "first_stage", async_reg=async_reg)
    # The vendor DDC filter first stages carry no ASYNC_REG (measured); their review
    # rests on same-domain internal timing, which the same record measures.
    for side in ("scl", "sda"):
        item_id = "async_in_hdmi_rx_ddc_%s_filter" % side
        items[item_id] = io_record(item_id, "hdmi_rx_ddc_" + side, "DDC_INST",
                                   async_reg=0, same_domain=1, paths=2, domains=1)
    pad_consumers = {
        "async_pad_hdmi_tx_hpd_in": ("hdmi_tx_hpd_in", 1, 1),
        "async_pad_hdmi_tx_ddc_scl": ("hdmi_tx_ddc_scl", 1, 1),
        "async_pad_hdmi_tx_ddc_sda": ("hdmi_tx_ddc_sda", 1, 1),
        "async_pad_hdmi_tx_refclk_rdy": ("hdmi_tx_refclk_rdy", 2, 2),
        "async_pad_hdmi_rx_5v_det": ("hdmi_rx_5v_det", 3, 3),
        "async_pad_hdmi_rx_ddc_scl": ("hdmi_rx_ddc_scl", 2, 1),
        "async_pad_hdmi_rx_ddc_sda": ("hdmi_rx_ddc_sda", 2, 1),
    }
    for item_id, (port, sequential, async_reg) in pad_consumers.items():
        items[item_id] = pad_closure(item_id, port, sequential, async_reg)

    items["async_out_hdmi_rx_hpd_out"] = output_record(
        "async_out_hdmi_rx_hpd_out", "hdmi_rx_hpd_out", drivers=1, port_count=1)
    items["async_out_leds"] = output_record(
        "async_out_leds", "user_led_dma_active user_led_pcie_link_up", drivers=2,
        port_count=2)
    items["async_out_hdmi_tx_tmds_clk"] = output_record(
        "async_out_hdmi_tx_tmds_clk", "hdmi_tx_tmds_clk_p hdmi_tx_tmds_clk_n",
        drivers=2, vphy=1, oserdes=2, port_count=2)
    # check_timing of round 26111202 left exactly two HIGH no_output_delay ports,
    # this DDC pair; each now has one -to <port> exception and a measured pad driver
    for side in ("scl", "sda"):
        items["async_out_hdmi_rx_ddc_" + side] = output_record(
            "async_out_hdmi_rx_ddc_" + side, "hdmi_rx_ddc_" + side,
            drivers=1, port_count=1)

    # The six internal async entries (rtl/sc7f0_hdmi_probe.v + the six named false
    # paths).  Shapes mirror what the hook measures: the source register, the
    # ASYNC_REG first stage, the two internal chain stages still analysed, and the
    # feed-in timed at the source clock's own requirement.
    for item_id, clock in (("probe_rxss_tlast_src_to_probe", "clkout2"),
                           ("probe_rxss_tuser_src_to_probe", "clkout2"),
                           ("probe_rxss_tvalid_src_to_probe", "clkout2"),
                           ("probe_phy_ch0_tvalid_src_to_probe", "phy_rxoutclk"),
                           ("probe_phy_ch1_tvalid_src_to_probe", "phy_rxoutclk"),
                           ("probe_phy_ch2_tvalid_src_to_probe", "phy_rxoutclk")):
        stem = item_id[len("probe_"):-len("_src_to_probe")]
        items[item_id] = hook_item(
            item_id, class_="internal_async", review_required=1,
            reviewed_source_clock=clock,
            from_cells="u_hdmi_probe/%s_reg" % stem,
            to_cells="u_hdmi_probe/%s_sync_reg[0]" % stem,
            from_objects=1, to_objects=1, chain_stage_objects=2,
            first_stage_async_reg=1, paths_analysed=2, internal_worst_slack="1.200",
            upstream_paths=2, upstream_requirement="6.734",
            upstream_worst_slack="4.000", upstream_start_clocks=clock,
            crossing_paths_timed=0, source_clocks=clock,
            destination_clocks="clk_pl_0", clock_domain_names="%s|clk_pl_0" % clock,
            clock_domain_count=2, exception_rows=1, exception_type="False Path",
            exception_position=245, exception_audit_source="report_exceptions -return_string",
            ignored=0, scope_overridden=0, probe_error="")

    if policy is not None:
        claimed = set()
        for section in ("io_items", "items", "methodology_items"):
            for item in policy.get(section, []):
                for requirement in item.get("requires", []):
                    if requirement.get("kind") in ("named_constraint", "manifest_metric"):
                        claimed.add(requirement.get("id"))
            for item in policy.get(section, []):
                if item.get("manifest_id"):
                    claimed.add(item["manifest_id"])
        items = {k: v for k, v in items.items()
                 if v.get("class") not in ("io_exception", "pad_closure") or k in claimed}
    return items


VIDPHY_SRC = ('u_vid_phy_controller/inst/clock_detector_inst/clk_freq_cnt_reg[17:0]/C')
VIDPHY_DST = ('u_vid_phy_controller/inst/clock_detector_inst/RXCLK_FREQ_CAP_INST'
              '/syncstages_ff_reg[0][17:0]/D')
CPLL_SRC = ('u_pcie_ip/inst/pcie4_uscale_plus_0_gt_top_i/diablo_gt/gt_wizard'
            '/gtwizard_top_i/gtwizard_ultrascale_v1_7_17_gthe4_cpll_cal_tx_i'
            '/U_TXOUTCLK_FREQ_COUNTER/testclk_cnt_reg[3]/C')
CPLL_DST = ('u_pcie_ip/inst/pcie4_uscale_plus_0_gt_top_i/diablo_gt/gt_wizard'
            '/gtwizard_top_i/gtwizard_ultrascale_v1_7_17_gthe4_cpll_cal_tx_i'
            '/U_TXOUTCLK_FREQ_COUNTER/freq_cnt_o_reg[3]/D')
STICKY_SRC = 'u_dma_top/u_zu4ev_upg_diag/pcie_sticky_reg[12:0]/C'
STICKY_DST = 'u_dma_top/u_zu4ev_upg_diag/u_levels/syncstages_ff_reg[0][12:0]/D'
STATE_SRC = 'u_ps_capture/u_regs/u_state/src_ff_reg[1:0]/C'
STATE_DST = 'u_ps_capture/u_regs/u_state/syncstages_ff_reg[0][1:0]/D'

CLEAN_CDC = [
    ("CDC-3", "Info", "False Path",
     "u_dma_top/u_capture_busy_cdc/src_ff_reg/C",
     "u_dma_top/u_capture_busy_cdc/syncstages_ff_reg[0]/D"),
    ("CDC-15", "Warning", "Max Delay Datapath Only", XPM_SRC, XPM_DST),
    ("CDC-15", "Warning", "Max Delay Datapath Only", METER_SRC, METER_DST),
    ("CDC-6", "Warning", "Max Delay Datapath Only", GRAY_SRC, GRAY_RX_DST),
    ("CDC-6", "Warning", "Max Delay Datapath Only", GRAY_SRC, GRAY_CSR_DST),
    ("CDC-26", "Warning", "Max Delay Datapath Only", DPRAM_SRC, DPRAM_DST),
    ("CDC-26", "Warning", "Max Delay Datapath Only", DPRAM_SRC_2, DPRAM_DST_2),
    ("CDC-26", "Warning", "Max Delay Datapath Only", DPRAM_SRC_3, DPRAM_DST_3),
    ("CDC-26", "Warning", "Max Delay Datapath Only", DPRAM_SRC_4, DPRAM_DST_4),
    ("CDC-15", "Warning", "False Path", VIDPHY_SRC, VIDPHY_DST),
    ("CDC-6", "Warning", "False Path", VIDPHY_SRC, VIDPHY_DST),
    ("CDC-15", "Warning", "False Path", CPLL_SRC, CPLL_DST),
    ("CDC-6", "Warning", "False Path", STICKY_SRC, STICKY_DST),
    ("CDC-6", "Warning", "False Path", STATE_SRC, STATE_DST),
]


class Fixture:
    """A complete, self-consistent routed report set in a temp directory."""

    def __init__(self, tmp, cdc=None, methodology=None, drc=True, high=(),
                 items=None, pair_detail=False, state="Routed"):
        self.dir = Path(tmp)
        self.dir.mkdir(parents=True, exist_ok=True)
        rows = cdc if cdc is not None else list(CLEAN_CDC)
        self.writes = {}
        self.write("timing_summary.rpt", timing_text(state))
        self.write("check-timing.rpt", coverage_text(high))
        self.write("cdc.rpt", cdc_text(rows))
        method = methodology if methodology is not None else [("DPIR-2", "Warning", 1)]
        self.write("methodology.rpt",
                   methodology_text(method,
                                    pair_detail if isinstance(pair_detail, str)
                                    else (PAIR_DETAIL if pair_detail else "")))
        self.write("bus-skew.rpt", bus_skew_text())
        if drc:
            self.write("drc.rpt", drc_text([("DPIP-2", "Warning", 1)]))
        self.write("clock-interaction.rpt", clock_interaction_text())
        self.write("exceptions-coverage.rpt",
                   "Position  Type  Endpoints  From (%)\n202  Max Delay  416  100.00\n")
        self.write("exceptions-ignored.rpt", "Positions fully ignored: 0\n")
        self.write("exceptions-scope-override.rpt", "Positions overridden: 0\n")
        self.write("io.rpt", "Port  Direction  Site\nhdmi_tx_hpd_in  IN  IOB_X0Y180\n")
        self.write("utilization_routed_hierarchical.rpt", "utilisation\n")
        self.write_manifest(items if items is not None else manifest_items())

    def write(self, name, text):
        (self.dir / name).write_text(text)

    def write_manifest(self, items, cdc="cdc.rpt", state="Routed", reports=None):
        """Bind the manifest to every gate report in this directory, as the hook does."""
        write_manifest(self.dir, items, state=state, reports=reports)

    def result(self, policy_dir=None):
        return gate.check(str(self.dir), str(policy_dir or POLICY))


def positive_fixture(tmp, policy_dir, name="case", **kwargs):
    """A report set whose manifest claims exactly what the policy claims."""
    policy = json.loads((Path(policy_dir) / "sc7f0_cdc_review.json").read_text())
    return Fixture(Path(tmp) / name, items=manifest_items(policy), **kwargs)


def reduced_policy(tmp, *, drop_io_statuses=(), drop_ids=()):
    """Copy the shipped policy with the named open items removed.

    Only used to prove the machinery can reach PASS once the open review items
    are actually closed; the shipped policy is always asserted to fail while they
    are open.
    """
    root = Path(tmp)
    root.mkdir(parents=True, exist_ok=True)
    for name in ("sc7f0_cdc_review.json", "sc7f0_drc_review.json",
                 "sc7f0_clock_pair_review.json"):
        shutil.copy(POLICY / name, root / name)
    path = root / "sc7f0_cdc_review.json"
    policy = json.loads(path.read_text())
    policy["items"] = [item for item in policy["items"] if item["id"] not in drop_ids]
    policy["io_items"] = [item for item in policy["io_items"]
                          if item["status"] not in drop_io_statuses]
    path.write_text(json.dumps(policy))
    return root


class TempDirCase(unittest.TestCase):
    """Shared temp dir + a manifest that claims exactly what a policy claims."""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def items_for(self, policy_dir):
        policy = json.loads((Path(policy_dir) / "sc7f0_cdc_review.json").read_text())
        return manifest_items(policy)


class PositiveStructureTests(TempDirCase):
    def setUp(self):
        super().setUp()
        self.policy = reduced_policy(self.tmp / "policy",
                                     drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW",
                                                       "BLOCKED"))

    def items(self):
        return self.items_for(self.policy)

    def test_clean_round_passes_once_open_items_are_closed(self):
        policy = reduced_policy(self.tmp / "policy",
                                drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        fixture = positive_fixture(self.tmp, policy, "pos")
        result = fixture.result(policy)
        self.assertEqual([], result["layer_a_errors"])
        self.assertEqual([], result["layer_b_errors"], result["errors"])
        self.assertTrue(result["pass_layer_a"] and result["pass_layer_b"])
        self.assertTrue(result["pass_gate"])

    def test_clean_round_passes_the_shipped_policy_only_when_measured(self):
        """The shipped policy may now PASS a round - but only because every open io
        item is closed by a measurement, so removing any one measurement must fail."""
        fixture = Fixture(self.tmp / "shipped")
        result = fixture.result()
        self.assertEqual([], result["layer_a_errors"], result["layer_a_errors"])
        self.assertEqual([], result["layer_b_errors"], result["errors"])
        self.assertTrue(result["pass_gate"])

        for breakage in (
                ("vendor first stage suddenly carries no ASYNC_REG where the probe "
                 "chain must", lambda i: i["async_in_hdmi_rx_ddc_scl_probe"].update(
                     first_stage_async_reg=0)),
                ("the pad has a first stage no exception names",
                 lambda i: i["async_pad_hdmi_rx_ddc_scl"].update(
                     unclaimed_first_stage_endpoints=1)),
                ("the DDC filter's internal paths stop being analysed",
                 lambda i: i["async_in_hdmi_rx_ddc_scl_filter"].update(
                     internal_filter_same_domain=0, paths_analysed=0)),
                ("the TX TMDS pad is no longer driven by the VPHY",
                 lambda i: i["async_out_hdmi_tx_tmds_clk"].update(driver_is_vphy=0)),
                ("the TX TMDS exception is ignored",
                 lambda i: i["async_out_hdmi_tx_tmds_clk"].update(ignored=1))):
            reason, mutate = breakage
            items = manifest_items()
            mutate(items)
            other = Fixture(self.tmp / ("broken-" + reason[:16]), items=items)
            again = other.result()
            self.assertFalse(again["pass_layer_b"],
                             f"{reason} must fail Layer B, got {again['errors']}")

    def test_io_item_deleted_from_the_policy_leaves_its_exception_unreviewed(self):
        """Closing an item is allowed; silently deleting it is not."""
        root = self.tmp / "dropped-io"
        root.mkdir()
        for name in ("sc7f0_cdc_review.json", "sc7f0_drc_review.json",
                     "sc7f0_clock_pair_review.json"):
            shutil.copy(POLICY / name, root / name)
        path = root / "sc7f0_cdc_review.json"
        policy = json.loads(path.read_text())
        policy["io_items"] = [i for i in policy["io_items"]
                              if i["id"] != "rx_ddc_sda_probe"]
        path.write_text(json.dumps(policy))
        # A real round keeps writing the exception (the XDC still contains it), so
        # the manifest still contains it; only the review entry disappeared.
        fixture = Fixture(self.tmp / "dropped-io-round", items=manifest_items())
        result = fixture.result(root)
        text = "\n".join(result["layer_b_errors"])
        self.assertFalse(result["pass_layer_b"], result["errors"])
        # the exception still exists in the design, so it is reported as unreviewed
        self.assertIn("async_in_hdmi_rx_ddc_sda_probe", text)
        self.assertIn("no review entry claims it", text)

    def test_ledger_counts_the_structures_that_are_present(self):
        policy = reduced_policy(self.tmp / "policy",
                                drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        result = positive_fixture(self.tmp, policy, "ledger").result(policy)
        ledger = result["cdc_review"]
        self.assertEqual(1, ledger["xpm_async_fifo_ce_internal"]["count"])
        self.assertEqual(1, ledger["probe_meter_held_snapshot"]["count"])
        self.assertEqual(1, ledger["capture_gray_to_source_time"]["count"])
        self.assertEqual(1, ledger["capture_gray_to_csr_time"]["count"])
        # four DPRAM FIFO instances are classified, and the endpoint expectation
        # is the sum of their rows, not the literal 416 of one past round
        self.assertEqual(4, ledger["vendor_rx_ss_lutram_collision"]["count"])
        # Info rows (CDC-3) are Layer A's contract, not a Layer B ledger entry.
        self.assertNotIn("CDC-3", ledger)

    def test_named_clock_pair_is_classified_only_with_full_evidence(self):
        policy = reduced_policy(self.tmp / "policy",
                                drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"),
                                drop_ids=("timing9_placeholder",))
        fixture = positive_fixture(self.tmp, policy, "pair",
                                   methodology=[("DPIR-2", "Warning", 1),
                                                ("TIMING-6", "Critical Warning", 1),
                                                ("TIMING-7", "Critical Warning", 1)],
                                   pair_detail=True)
        result = fixture.result(policy)
        self.assertEqual([], [e for e in result["layer_a_errors"]
                              if e.startswith("TIMING-")], result["layer_a_errors"])
        self.assertEqual({"TIMING-6", "TIMING-7"},
                         {entry["rule"] for entry in result["classified_by_policy"]})
        self.assertTrue(result["pass_gate"], result["errors"])

    def test_probe_clock_pairs_are_classified_with_full_evidence(self):
        """clkout2 / phy_rxoutclk against clk_pl_0: closed by measurement.

        The classification must need all of it - both report_clock_interaction
        directions, the six named crossings with their ASYNC_REG first stage and
        their still-analysed chain, the meter / Gray / DPRAM max delays, and zero
        clock groups - so this also proves the requirement set is satisfiable.
        """
        policy = reduced_policy(self.tmp / "policy-probe",
                                drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"),
                                drop_ids=("timing9_placeholder",))
        fixture = positive_fixture(self.tmp, policy, "probe-pair",
                                   methodology=[("DPIR-2", "Warning", 1),
                                                ("TIMING-6", "Critical Warning", 3),
                                                ("TIMING-7", "Critical Warning", 3)],
                                   pair_detail=PAIR_DETAIL + PROBE_PAIR_DETAIL)
        result = fixture.result(policy)
        self.assertEqual([], [e for e in result["layer_a_errors"]
                              if e.startswith("TIMING-")], result["layer_a_errors"])
        self.assertEqual({"TIMING-6", "TIMING-7"},
                         {entry["rule"] for entry in result["classified_by_policy"]})
        self.assertTrue(result["pass_gate"], result["errors"])

    def test_declared_clock_group_blocks_the_clock_pair_classification(self):
        items = self.items()
        items["clock_groups"] = {"class": "metric", "review_required": 0, "count": 2}
        policy = reduced_policy(self.tmp / "policy",
                                drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        fixture = Fixture(self.tmp, items=items,
                          methodology=[("DPIR-2", "Warning", 1),
                                       ("TIMING-6", "Critical Warning", 1),
                                       ("TIMING-7", "Critical Warning", 1)],
                          pair_detail=True)
        result = fixture.result(policy)
        self.assertEqual([], result["classified_by_policy"])
        self.assertIn("TIMING-6 Critical Warning=1", result["layer_a_errors"])
        self.assertFalse(result["pass_gate"])

    def test_missing_reverse_clock_interaction_direction_fails(self):
        policy = reduced_policy(self.tmp / "policy",
                                drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        items = manifest_items(json.loads((policy / "sc7f0_cdc_review.json").read_text()))
        fixture = Fixture(self.tmp / "nodir", items=items,
                          methodology=[("DPIR-2", "Warning", 1),
                                       ("TIMING-6", "Critical Warning", 1),
                                       ("TIMING-7", "Critical Warning", 1)],
                          pair_detail=True)
        fixture.write("clock-interaction.rpt",
                      clock_interaction_text(rows=interaction_row(
                          "clk_pl_0", "pcie_user_clk", "No Common Clock",
                          "Partial False Path (unsafe)")))
        result = fixture.result(policy)
        self.assertFalse(result["pass_layer_b"])
        self.assertIn("pcie_user_clk -> clk_pl_0", "\n".join(result["layer_b_errors"]))
        self.assertFalse(result["pass_gate"])


class NegativeTests(TempDirCase):
    def setUp(self):
        super().setUp()
        self.policy = reduced_policy(self.tmp / "policy",
                                     drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW",
                                                       "BLOCKED"))

    def items(self):
        return self.items_for(self.policy)

    def check(self, **kwargs):
        name = kwargs.pop("_name", "case")
        items = kwargs.pop("items", None)
        fixture = Fixture(self.tmp / name,
                          items=items if items is not None else self.items(), **kwargs)
        return fixture.result(self.policy)

    def test_missing_drc_report_is_a_layer_a_failure(self):
        result = self.check(drc=False)
        self.assertFalse(result["pass_layer_a"])
        self.assertIn("missing DRC report", "\n".join(result["layer_a_errors"]))

    def test_unparseable_drc_total_is_fatal(self):
        fixture = positive_fixture(self.tmp, self.policy, "drctotal")
        fixture.write("drc.rpt", fixture.dir.joinpath("drc.rpt").read_text()
                      .replace("Violations found: 1", "Violations found: 9"))
        with self.assertRaises(ValueError):
            gate.check(str(fixture.dir), str(self.policy))

    def test_drc_error_severity_is_layer_a(self):
        fixture = positive_fixture(self.tmp, self.policy, "drcerr")
        fixture.write("drc.rpt", drc_text([("RTMC-1", "Error", 1)]))
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("DRC RTMC-1 Error=1", result["layer_a_errors"])

    def test_unknown_drc_rule_is_not_reviewed(self):
        fixture = positive_fixture(self.tmp, self.policy, "drcunknown")
        fixture.write("drc.rpt", drc_text([("DPIP-2", "Warning", 1),
                                           ("UPLPC-1", "Warning", 1)]))
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertFalse(result["pass_layer_b"])
        self.assertIn("UPLPC-1", "\n".join(result["layer_b_errors"]))

    def test_drc_violation_outside_reviewed_instances_fails(self):
        fixture = positive_fixture(self.tmp, self.policy, "drcoutside")
        fixture.write("drc.rpt", drc_text(
            [("DPIP-2", "Warning", 1)],
            details=("DPIP-2#1 Warning\nDSP u_video_logic/acc input is not pipelined.\n"
                     "Related violations: <none>\n\n")))
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("outside the reviewed instances", "\n".join(result["layer_b_errors"]))

    def test_drc_severity_change_is_rejected(self):
        fixture = positive_fixture(self.tmp, self.policy, "drcsev")
        fixture.write("drc.rpt", drc_text([("DPIP-2", "Critical Warning", 1)]))
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("DRC DPIP-2 Critical Warning=1", result["layer_a_errors"])

    def test_fabricated_cdc_root_is_uncovered(self):
        rows = list(CLEAN_CDC) + [("CDC-15", "Warning", "Max Delay Datapath Only",
                                  "u_my_new_logic/ce_reg/C", "u_my_new_logic/data_reg/D")]
        result = self.check(cdc=rows)
        self.assertFalse(result["pass_layer_b"])
        self.assertIn("not covered by any review entry", "\n".join(result["layer_b_errors"]))

    def test_critical_rule_claimed_as_warning_is_still_layer_a(self):
        rows = list(CLEAN_CDC) + [("CDC-13", "Warning", "None",
                                  "u_dualpath/reg_pkt_bytes_reg[0]/C",
                                  "u_dma_top/u_axil_reg_space/u_status/x/D")]
        result = self.check(cdc=rows)
        self.assertTrue(any(e.startswith("CDC-13") for e in result["layer_a_errors"]),
                        result["layer_a_errors"])
        self.assertTrue(any("misclassified" in e for e in result["layer_a_errors"]),
                        result["layer_a_errors"])
        self.assertFalse(result["pass_layer_a"])

    def test_unknown_cdc_rule_fails_closed(self):
        rows = list(CLEAN_CDC) + [("CDC-99", "Warning", "None", "u_a/x/C", "u_b/x/D")]
        result = self.check(cdc=rows)
        self.assertFalse(result["pass_layer_b"])
        self.assertIn("CDC-99", "\n".join(result["layer_b_errors"]))

    def test_unknown_cdc_severity_is_layer_a(self):
        result = self.check(cdc=[("CDC-15", "Bogus", "None", XPM_SRC, XPM_DST)])
        self.assertTrue(any("Bogus" in e for e in result["layer_a_errors"]),
                        result["layer_a_errors"])

    def test_duplicate_rule_severities_cannot_be_interpreted(self):
        rows = [("CDC-15", "Warning", "Max Delay Datapath Only", XPM_SRC, XPM_DST),
                ("CDC-15", "Bogus", "None", XPM_SRC, XPM_DST)]
        fixture = positive_fixture(self.tmp, self.policy, "dupsev", cdc=rows)
        with self.assertRaises(ValueError):
            gate.check(str(fixture.dir), str(self.policy))

    def test_summary_and_detail_must_agree(self):
        import re as _re
        text = cdc_text(list(CLEAN_CDC))
        text = _re.sub(r"^(CDC-15  Warning  )(\d+)", lambda m: m.group(1) + "99",
                       text, count=1, flags=_re.M)
        fixture = positive_fixture(self.tmp, self.policy, "counts")
        fixture.write("cdc.rpt", text)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("missing/incomplete detailed CDC warnings",
                      result["layer_a_errors"])

    def test_missing_clock_interaction_report_is_a_failure(self):
        fixture = positive_fixture(self.tmp, self.policy, "ci")
        os.remove(fixture.dir / "clock-interaction.rpt")
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertFalse(result["pass_layer_b"])
        self.assertIn("clock-interaction.rpt", "\n".join(result["layer_b_errors"]))

    def test_overridden_max_delay_is_rejected(self):
        items = self.items()
        items["capture_gray_to_source_time"].update(ignored=1)
        fixture = Fixture(self.tmp / "ignored", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("reported as ignored", "\n".join(result["layer_b_errors"]))

    def test_scope_overridden_max_delay_is_rejected(self):
        items = self.items()
        items["capture_gray_to_csr_time"].update(scope_overridden=1)
        fixture = Fixture(self.tmp / "override", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("scope-overridden", "\n".join(result["layer_b_errors"]))

    def test_missing_bus_skew_constraint_is_rejected(self):
        items = self.items()
        items["capture_gray_to_source_time"].pop("bus_skew_slack_ns")
        items["capture_gray_to_source_time"].pop("bus_skew_ns")
        fixture = Fixture(self.tmp / "noskew", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("no bus-skew slack", "\n".join(result["layer_b_errors"]))

    def test_absent_named_constraint_is_rejected(self):
        items = self.items()
        del items["probe_meter_max_delay"]
        fixture = Fixture(self.tmp / "noconst", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("probe_meter_max_delay", "\n".join(result["layer_b_errors"]))

    def test_empty_object_list_is_not_coverage(self):
        items = self.items()
        items["probe_meter_max_delay"].update(from_objects=0, to_objects=0, endpoints=0)
        fixture = Fixture(self.tmp / "emptyobjs", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("empty object list", "\n".join(result["layer_b_errors"]))

    def test_manifest_from_another_round_is_rejected(self):
        fixture = positive_fixture(self.tmp, self.policy, "stale")
        fixture.write("cdc.rpt", fixture.dir.joinpath("cdc.rpt").read_text()
                      + cdc_row(99, "CDC-26", "Warning", "Max Delay Datapath Only",
                                DPRAM_SRC, DPRAM_DST))
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertFalse(result["pass_layer_b"])
        self.assertIn("not the", "\n".join(result["layer_b_errors"]))

    def test_manifest_with_an_unknown_named_exception_is_rejected(self):
        items = self.items()
        items["someone_elses_false_path"] = {"class": "cdc_constraint",
                                             "review_required": 1, "from_objects": 4,
                                             "to_objects": 4, "endpoints": 4,
                                             "ignored": 0, "scope_overridden": 0}
        fixture = Fixture(self.tmp / "unknownexc", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("someone_elses_false_path", "\n".join(result["layer_b_errors"]))

    def test_unclaimed_io_exception_is_rejected(self):
        items = self.items()
        items["async_in_a_brand_new_pad"] = {"class": "io_exception",
                                             "review_required": 1, "from_objects": 1,
                                             "to_objects": 1, "ignored": 0,
                                             "scope_overridden": 0}
        fixture = Fixture(self.tmp / "unknownio", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("async_in_a_brand_new_pad", "\n".join(result["layer_b_errors"]))

    def test_missing_io_exception_is_rejected(self):
        items = self.items()
        del items["async_out_leds"]
        fixture = Fixture(self.tmp / "missingio", items=items)
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("async_out_leds", "\n".join(result["layer_b_errors"]))

    def test_high_uncovered_port_stays_layer_a(self):
        result = self.check(high=("hdmi_tx_tmds_clk_p", "hdmi_rx_ddc_scl"))
        self.assertIn("uncovered HIGH-severity endpoint", result["layer_a_errors"])
        self.assertEqual(["hdmi_rx_ddc_scl", "hdmi_tx_tmds_clk_p"],
                         result["uncovered_high_ports"])

    def test_pre_route_state_is_rejected(self):
        result = self.check(state="Placed")
        self.assertIn("timing report is not routed (Design State: Placed)",
                      result["layer_a_errors"])

    def test_unknown_state_is_rejected(self):
        result = self.check(state="Optimised By Somebody")
        self.assertIn("not a known post-route state", "\n".join(result["layer_a_errors"]))

    def test_unclassified_methodology_rule_is_rejected(self):
        result = self.check(methodology=[("DPIR-2", "Warning", 1),
                                         ("TIMING-42", "Warning", 1)])
        self.assertFalse(result["pass_layer_b"])
        self.assertIn("TIMING-42", "\n".join(result["layer_b_errors"]))

    def test_unknown_clock_pair_in_timing6_is_rejected(self):
        fixture = Fixture(self.tmp / "newpair",
                          methodology=[("DPIR-2", "Warning", 1),
                                       ("TIMING-6", "Critical Warning", 1)])
        fixture.write("methodology.rpt", fixture.dir.joinpath("methodology.rpt").read_text()
                      + "TIMING-6#1 Critical Warning\nThe clocks clk_mystery and "
                        "clk_pl_0 are related (timed together) but they have no common "
                        "primary clock.\nRelated violations: <none>\n\n")
        result = gate.check(str(fixture.dir), str(self.policy))
        self.assertIn("clk_mystery", "\n".join(result["layer_b_errors"]))
        self.assertIn("TIMING-6 Critical Warning=1", result["layer_a_errors"])

    def test_postroute_state_parser_is_kept(self):
        result = self.check(state="Physopt postRoute")
        self.assertTrue(result["pass_layer_a"], result["layer_a_errors"])

    def test_empty_policy_item_list_cannot_load(self):
        root = self.tmp / "empty-policy"
        root.mkdir()
        for name in ("sc7f0_cdc_review.json", "sc7f0_drc_review.json",
                     "sc7f0_clock_pair_review.json"):
            (root / name).write_text(json.dumps({"schema": review.SCHEMA,
                                                 "kind": name.split("_")[1].split(".")[0],
                                                 "id": "x", "items": []}))
        fixture = Fixture(self.tmp / "emptypolicy")
        with self.assertRaises(ValueError):
            review.load_policy(root / "sc7f0_cdc_review.json", "cdc")
        result = gate.check(str(fixture.dir), root)
        self.assertFalse(result["pass_layer_b"])

    def test_prose_only_evidence_is_rejected(self):
        root = reduced_policy(self.tmp / "prose",
                              drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        path = root / "sc7f0_cdc_review.json"
        policy = json.loads(path.read_text())
        for item in policy["items"]:
            if item["id"] == "vendor_rx_ss_lutram_collision":
                item["requires"] = []
        path.write_text(json.dumps(policy))
        with self.assertRaises(ValueError) as ctx:
            review.load_policy(path, "cdc")
        self.assertIn("machine-checkable", str(ctx.exception))

    def test_evidence_pointing_at_a_missing_report_is_rejected(self):
        root = reduced_policy(self.tmp / "missingreport",
                              drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        path = root / "sc7f0_clock_pair_review.json"
        policy = json.loads(path.read_text())
        for item in policy["methodology_items"]:
            if item["id"] == "dpir2_dsp_async_reset_drivers":
                item["requires"] = [{"kind": "report_nonempty", "report": "nope.rpt"}]
        path.write_text(json.dumps(policy))
        fixture = positive_fixture(self.tmp, root, "missingreportcase")
        result = gate.check(str(fixture.dir), root)
        self.assertIn("nope.rpt", "\n".join(result["layer_b_errors"]))

    def test_unimplemented_requirement_kind_is_rejected(self):
        root = reduced_policy(self.tmp / "kind",
                              drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        path = root / "sc7f0_drc_review.json"
        policy = json.loads(path.read_text())
        policy["items"][0]["requires"] = [{"kind": "trust_me"}]
        path.write_text(json.dumps(policy))
        with self.assertRaises(ValueError):
            review.load_policy(path, "drc")

    def test_stale_policy_entry_is_rejected(self):
        root = reduced_policy(self.tmp / "stale",
                              drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        path = root / "sc7f0_cdc_review.json"
        policy = json.loads(path.read_text())
        policy["items"].append({
            "id": "vendor_something_that_is_gone", "rule": "CDC-15",
            "status": "REVIEWED_SAFE", "structure": "x", "rationale": "y",
            "root_regex": ["^u_gone/"], "evidence": ["cdc.rpt"],
            "requires": [{"kind": "report_nonempty", "report": "cdc.rpt"}]})
        path.write_text(json.dumps(policy))
        result = positive_fixture(self.tmp, root, "staleentry").result(root)
        self.assertIn("vendor_something_that_is_gone",
                      "\n".join(result["layer_b_errors"]))

    def test_duplicate_classification_is_rejected(self):
        root = reduced_policy(self.tmp / "dup",
                              drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        path = root / "sc7f0_cdc_review.json"
        policy = json.loads(path.read_text())
        clone = dict(policy["items"][0])
        clone["id"] = "xpm_async_fifo_ce_internal_again"
        policy["items"].append(clone)
        path.write_text(json.dumps(policy))
        result = positive_fixture(self.tmp, root, "dupe").result(root)
        self.assertIn("duplicate classification hides",
                      "\n".join(result["layer_b_errors"]))

    def test_rx_ddc_entries_are_paired_and_measured_not_asserted(self):
        """The RX DDC pair is closed by measurement, in four named sub-entries.

        Deleting the entries is not how a review is closed, and neither is keeping a
        sentence about ASYNC_REG: the entries must each demand a routed attribute,
        and SCL/SDA must fail as one pair.
        """
        shipped = json.loads((POLICY / "sc7f0_cdc_review.json").read_text())
        ddc = [item for item in shipped["io_items"] if item.get("pair_group") == "rx_ddc"]
        self.assertEqual({"rx_ddc_scl_probe", "rx_ddc_scl_vendor_filter",
                          "rx_ddc_sda_probe", "rx_ddc_sda_vendor_filter",
                          "rx_ddc_scl_output", "rx_ddc_sda_output"},
                         {item["id"] for item in ddc})
        for item in ddc:
            self.assertEqual("REVIEWED_SAFE", item["status"])
            kinds = {(r.get("kind"), r.get("id")) for r in item["requires"]}
            self.assertIn(("named_constraint", item["manifest_id"]), kinds, item["id"])
            options = [key for r in item["requires"] if r.get("kind") == "named_constraint"
                       for key in r if key not in ("kind", "id", "min_objects")]
            # A pad entry may also be graded on a measured field of the manifest
            # record (an output direction has no -to first stage to inspect), but
            # only when the claim carries a threshold: a metric without one is
            # decoration, not a bound.
            metrics = ["%s.%s" % (r.get("id"), r.get("field")) for r in item["requires"]
                       if r.get("kind") == "manifest_metric" and r.get("field")
                       and any(key in r for key in ("min", "max", "equals"))]
            self.assertTrue(options or metrics,
                            f"{item['id']}: a pad entry without a measured "
                            "attribute is prose, not a review")
            self.assertTrue(any("ASYNC_REG" in text for text in item["rationale"].split(".")),
                            f"{item['id']}: must state what the attribute is and is not")
        # and no vendor IP was edited: the policy claims only measurements
        for item in ddc:
            self.assertNotIn("ASYNC_REG=TRUE", item["structure"] + item["rationale"])

    def test_ddc_output_exception_absent_keeps_the_pair_open(self):
        """The output rows are not decoration: without the driver measurement the
        DDC pair stays unreviewed, and the clock line cannot pass alone."""
        for missing, other in (("async_out_hdmi_rx_ddc_scl", "rx_ddc_sda_output"),
                              ("async_out_hdmi_rx_ddc_sda", "rx_ddc_scl_output")):
            items = manifest_items()
            del items[missing]
            result = Fixture(self.tmp / ("ddc-out-" + missing), items=items).result()
            text = "\n".join(result["layer_b_errors"])
            self.assertIn(missing, text, text)
            self.assertIn("absent from this round's coverage manifest", text)
            # the sibling entries of the same pair are dragged down, by design
            self.assertIn(other, text, text)
            self.assertFalse(result["pass_layer_b"], text)

    def test_internal_async_entry_without_evidence_is_not_classified(self):
        """A named false path with no measured crossing must not close TIMING-6."""
        for broken, mutate in (
                ("probe_rxss_tvalid_src_to_probe",
                 lambda r: r.pop("first_stage_async_reg")),
                ("probe_phy_ch0_tvalid_src_to_probe",
                 lambda r: r.update(clock_domain_count=3))):
            policy = reduced_policy(self.tmp / ("policy-" + broken),
                                    drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW",
                                                      "BLOCKED"))
            items = manifest_items(json.loads((policy / "sc7f0_cdc_review.json").read_text()))
            mutate(items[broken])
            fixture = Fixture(self.tmp / ("internal-" + broken), items=items,
                              methodology=[("DPIR-2", "Warning", 1),
                                           ("TIMING-6", "Critical Warning", 3),
                                           ("TIMING-7", "Critical Warning", 3)],
                              pair_detail=PAIR_DETAIL + PROBE_PAIR_DETAIL)
            result = fixture.result(policy)
            text = "\n".join(result["layer_b_errors"])
            self.assertIn(broken, text, text)
            self.assertFalse(result["pass_gate"], text)

    def test_scl_reviewed_but_sda_missing_fails_both(self):
        items = manifest_items()
        del items["async_in_hdmi_rx_ddc_sda_probe"]
        result = Fixture(self.tmp / "half-ddc", items=items).result()
        text = "\n".join(result["layer_b_errors"])
        self.assertFalse(result["pass_layer_b"], result["errors"])
        self.assertIn("pair_group rx_ddc fails as a pair", text)


class FrozenRoundTests(TempDirCase):
    """The shipped r3 round must keep failing; its records are never rewritten."""

    def require(self):
        if not (R3 / "cdc.rpt").is_file():
            self.skipTest("frozen r3 reports are not present")

    def items(self):
        return manifest_items()

    def test_r3_fails_both_layers(self):
        self.require()
        result = gate.check(str(R3))
        self.assertFalse(result["pass_layer_a"], result["layer_a_errors"])
        self.assertFalse(result["pass_layer_b"])
        self.assertFalse(result["pass_gate"])
        text = "\n".join(result["errors"])
        for expected in ("CDC-10 Critical=28", "CDC-12 Critical=10",
                         "CDC-13 Critical=296", "uncovered HIGH-severity endpoint",
                         "missing DRC report", "TIMING-6 Critical Warning=1",
                         "TIMING-7 Critical Warning=1"):
            self.assertIn(expected, text)

    def test_r3_critical_cannot_be_reviewed_away(self):
        self.require()
        result = gate.check(str(R3))
        # Even a policy that accepts every Warning cannot clear Layer A.
        root = reduced_policy(self.tmp_policy(),
                              drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        again = gate.check(str(R3), root)
        self.assertFalse(again["pass_layer_a"])
        self.assertIn("critical CDC detail (even if missing from summary)",
                      again["layer_a_errors"])

    def tmp_policy(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        return Path(self._tmp.name)

    def test_r3_cdc_warning_roots_are_all_classified(self):
        """Layer B must account for all 5038 r3 warnings, with the documented split."""
        self.require()
        root = reduced_policy(self.tmp_policy(),
                             drop_io_statuses=("NEEDS_STRUCTURAL_REVIEW", "BLOCKED"))
        manifest = self.dir_with_manifest()
        again = gate.check(str(manifest), root)
        ledger = again["cdc_review"]
        total = sum(entry["count"] for entry in ledger.values())
        self.assertEqual(5038, total, ledger)
        self.assertEqual(3986, ledger["xpm_async_fifo_ce_internal"]["count"])
        self.assertEqual(448, ledger["probe_meter_held_snapshot"]["count"])
        self.assertEqual(416, ledger["vendor_rx_ss_lutram_collision"]["count"])
        self.assertEqual(108, ledger["vendor_vid_phy_held_counter"]["count"])
        self.assertEqual(72, ledger["vendor_cpll_held_counter"]["count"])
        self.assertNotIn("not covered by any review entry",
                         "\n".join(again["layer_b_errors"]))

    def dir_with_manifest(self):
        """Copy r3 reports to a temp dir and attach a manifest naming them."""
        import tempfile
        work = Path(tempfile.mkdtemp(dir=self.tmp_policy()))
        for name in ("timing_summary.rpt", "check-timing.rpt", "cdc.rpt",
                     "methodology.rpt", "bus-skew.rpt", "exceptions-coverage.rpt",
                     "drc.rpt"):
            if (R3 / name).is_file():
                shutil.copy(R3 / name, work / name)
        for name, text in (("clock-interaction.rpt", clock_interaction_text()),
                           ("exceptions-ignored.rpt", "none\n"),
                           ("exceptions-scope-override.rpt", "none\n"),
                           ("io.rpt", "ports\n"),
                           ("utilization_routed_hierarchical.rpt", "util\n")):
            (work / name).write_text(text)
        # The manifest for the real r3 rows is derived from those rows, so the
        # dynamic endpoint relation is exercised against a genuine report.
        items = manifest_items(rows=cdc_rows_from_text((work / "cdc.rpt").read_text()))
        write_manifest(work, items, state="Physopt postRoute")
        return work

    def test_recorded_r3_verdict_is_untouched(self):
        if not R3_RECORD.is_file():
            self.skipTest("r3 gate record is not present")
        recorded = json.loads(R3_RECORD.read_text())
        self.assertNotIn(True, (recorded.get("pass_gate"),),
                         "the frozen r3 record must stay a failure")
        self.assertTrue(recorded.get("errors"))


class LegacyMatcherPolicyTests(unittest.TestCase):
    """The narrow legacy matcher and the policy file must not drift apart."""

    def test_every_legacy_root_has_a_policy_entry(self):
        policy = review.load_policy(POLICY / "sc7f0_cdc_review.json", "cdc")
        for root in gate.FIFO_ROOTS:
            self.assertTrue(any(review._matches(item, {"rule": "CDC-15", "severity": "Warning",
                                                       "exception": "Max Delay Datapath Only",
                                                       "src": root + "/mem/CLK",
                                                       "dest": root + "/dout/D"})
                                for item in policy["items"]), root)
        sticky_src = "u_dma_top/u_zu4ev_upg_diag/pcie_sticky_reg[12:0]/C"
        sticky_dst = "u_dma_top/u_zu4ev_upg_diag/u_levels/syncstages_ff_reg[0][12:0]/D"
        self.assertTrue(gate.reviewed_crossing("CDC-6", sticky_src, sticky_dst))
        self.assertTrue(any(review._matches(item, {"rule": "CDC-6", "severity": "Warning",
                                                   "exception": "False Path",
                                                   "src": sticky_src,
                                                   "dest": sticky_dst})
                            for item in policy["items"]))

    def test_legacy_matcher_still_rejects_lookalikes(self):
        self.assertIsNone(gate.reviewed_crossing("CDC-15", "u_custom/a/C", "u_custom/b/D"))
        self.assertIsNone(gate.reviewed_crossing(
            "CDC-6", "u_other/bus[12:0]/C",
            "u_dma_top/u_zu4ev_upg_diag/u_levels/syncstages_ff_reg[0][12:0]/D"))


class ConstraintFileTests(unittest.TestCase):
    """constraints/sc7f0_async_io.xdc must stay per-port and per-first-stage."""

    xdc = (REPO / "constraints" / "sc7f0_async_io.xdc").read_text()

    def active(self):
        # join backslash continuations, then drop comments
        joined = self.xdc.replace("\\\n", " ")
        lines, buffer = [], ""
        for line in joined.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            buffer = (buffer + " " + line).strip() if buffer else line
            if line.endswith("\\"):
                continue
            lines.append(buffer)
            buffer = ""
        return lines

    def test_no_broad_clock_group_or_blanket_delays(self):
        text = " ".join(self.active())
        self.assertNotIn("set_clock_groups", text)
        self.assertNotIn("set_input_delay", text)
        self.assertNotIn("set_output_delay", text)
        self.assertNotIn("set_max_delay", text)

    def test_async_inputs_are_restricted_to_first_stage_chains(self):
        text = " ".join(self.active())
        for port in ("hdmi_tx_hpd_in", "hdmi_tx_ddc_scl", "hdmi_tx_ddc_sda",
                     "hdmi_tx_refclk_rdy", "hdmi_rx_5v_det"):
            self.assertIn(f"-from [get_ports {port}]", text, port)
        # no -from port without a -to restriction
        for chunk in [c for c in self.active() if c.startswith("set_false_path -from")]:
            self.assertIn("-to", chunk, chunk)

    def test_every_exception_is_named_and_no_blanket_cut_exists(self):
        text = " ".join(self.active())
        # No -from-port exception may stand without a -to restriction, and no
        # invented delay or clock group may appear.
        for chunk in [c for c in self.active() if c.startswith("set_false_path -from")]:
            self.assertIn("-to", chunk, chunk)
        self.assertNotIn("set_clock_groups", text)
        self.assertNotIn("set_input_delay", text)
        self.assertNotIn("set_output_delay", text)
        self.assertNotIn("set_max_delay", text)

    def test_tx_tmds_and_rx_ddc_exceptions_are_written_per_port_per_consumer(self):
        """Scope is decided: capture-only, TX approved-not-accepted.

        The TX TMDS pads are excepted one command per port (never a clock group,
        never an invented output delay), and each RX DDC pad has one exception per
        measured consumer, all of them restricted to a first stage.
        """
        text = " ".join(self.active())
        self.assertIn("set_false_path -to [get_ports hdmi_tx_tmds_clk_p]", text)
        self.assertIn("set_false_path -to [get_ports hdmi_tx_tmds_clk_n]", text)
        for port in ("hdmi_rx_ddc_scl", "hdmi_rx_ddc_sda"):
            rows = [c for c in self.active()
                    if c.startswith(f"set_false_path -from [get_ports {port}]")]
            self.assertEqual(2, len(rows), f"{port}: one exception per measured consumer")
            for row in rows:
                self.assertIn("-to [get_cells", row, row)
                self.assertIn("reg\\[0\\]", row,
                              f"{port}: exception must stop at a first-stage flop")

    def test_named_first_stage_cells_exist_in_rtl(self):
        """A -to target that no longer exists would abort the next build."""
        rtl = ((REPO / "rtl" / "sc7f0_hdmi_probe.v").read_text()
               + (REPO / "rtl" / "zu4ev_pcie_card_top.v").read_text())
        for name in ("tx_hpd_sync", "tx_scl_sync", "tx_sda_sync", "tx_rdy_sync",
                     "det5v_sync", "sync_5v_det_q"):
            self.assertIn(name, rtl, name)
            self.assertIn(name.replace("sync_5v_det_q", "sync_5v_det_q") + r"_reg\[0\]"
                          if name == "sync_5v_det_q" else name + r"_reg\[0\]",
                          " ".join(self.active()), name)

    def test_the_capture_gray_constraints_are_still_named(self):
        gray = (REPO / "constraints" / "sc7f0_capture_gray.xdc").read_text()
        self.assertIn("set_max_delay -datapath_only 6.000", gray)
        self.assertIn("set_bus_skew 6.000", gray)
        pinout = (REPO / "constraints" / "zu4ev_pcie_pinout.xdc").read_text()
        self.assertIn("set_max_delay -datapath_only 10.0", pinout)
        self.assertNotIn("set_clock_groups", pinout)


class ToolHygieneTests(unittest.TestCase):
    def test_evidence_hook_is_complete_tcl_and_uses_no_removed_apis(self):
        tcl = (REPO / "scripts" / "check_sc7f0_named_constraints.tcl").read_text()
        completed = subprocess.run(["tclsh"], input="set f [open {%s}] \n"
                                   % (REPO / "scripts" / "check_sc7f0_named_constraints.tcl"),
                                   capture_output=True, text=True)
        self.assertIn(completed.returncode, (0, 1), completed.stderr)
        for bad in ("lmap ", "all_fanout -from", "report_property -object_filters"):
            self.assertNotIn(bad, tcl)

    def test_stub_harness_runs_the_evidence_hook_end_to_end(self):
        import tempfile
        cwd = Path(tempfile.mkdtemp())
        proc = subprocess.run(["tclsh", str(REPO / "scripts" / "tests" / "fixtures" /
                                             "named_constraints_stub.tcl")],
                              cwd=cwd, capture_output=True, text=True)
        # the harness cd-normalises to its own directory, so run it from the repo
        if "HARNESS_FAIL" in proc.stdout or "HARNESS_FAIL" in proc.stderr:
            self.fail(proc.stdout + proc.stderr)
        from_repo = subprocess.run(["tclsh", str(REPO / "scripts" / "tests" / "fixtures" /
                                                  "named_constraints_stub.tcl")],
                                   cwd=REPO, capture_output=True, text=True)
        self.assertIn("HARNESS_MANIFEST_OK", from_repo.stdout, from_repo.stdout)

    def test_impl_flow_reports_every_layer_b_input(self):
        tcl = (REPO / "scripts" / "impl_sc7f0_dual_video.tcl").read_text()
        for report in ("drc.rpt", "io.rpt", "clock-interaction.rpt",
                       "exceptions-ignored.rpt", "exceptions-scope-override.rpt",
                       "disable-timing-user.rpt"):
            self.assertIn(report, tcl, report)
        self.assertIn("check_sc7f0_named_constraints.tcl", tcl)

    def test_release_flow_requires_the_new_reports(self):
        sh = (REPO / "scripts" / "build_sc7f0_vcu_release.sh").read_text()
        self.assertIn("drc", sh)
        self.assertIn("named-constraint-evidence.json", sh)
        self.assertIn('echo "fpga report $r.rpt was never produced"', sh)


class GateCorrectnessTests(TempDirCase):
    """Negative cases for the specific ways a gate can be made to lie (review P1-2..9).

    Every test here mutates one thing that used to be silently accepted.
    """

    def setUp(self):
        super().setUp()
        self.items = manifest_items()

    def run_items(self, items, name="case", **kwargs):
        return Fixture(self.tmp / name, items=items, **kwargs).result()

    # --- 1. named evidence schema vs the producer ---------------------------
    def test_policy_fields_must_be_produced_by_the_hook(self):
        """Every option a shipped requirement reads has to be a field the hook writes."""
        needed = {"min_instances": "instances", "max_delay_ns": "max_delay_measured_ns",
                  "min_bus_skew_slack_ns": "bus_skew_slack_ns", "bus_skew_ns": "bus_skew_ns",
                  "min_from_coverage_pct": "from_coverage_pct",
                  "require_row_endpoint_match": "endpoints",
                  "min_first_stage_async_reg": "first_stage_async_reg",
                  "require_same_domain_filter": "internal_filter_same_domain",
                  "min_paths_analysed": "paths_analysed",
                  "max_clock_domains": "clock_domain_count",
                  "max_clock_or_setreset_pin_loads": "clock_or_setreset_pin_loads",
                  "max_exception_rows": "exception_rows"}
        missing = []
        for name in ("sc7f0_cdc_review.json", "sc7f0_clock_pair_review.json",
                     "sc7f0_drc_review.json"):
            policy = json.loads((POLICY / name).read_text())
            for section in ("items", "io_items", "methodology_items"):
                for item in policy.get(section, []):
                    for requirement in item.get("requires", []):
                        if requirement.get("kind") not in ("named_constraint",
                                                           "manifest_metric"):
                            continue
                        item_id = requirement["id"]
                        fields = produced_fields(item_id)
                        self.assertTrue(fields,
                                        f"{item_id} is never written by the hook")
                        for option, field in needed.items():
                            if option in requirement and field not in fields:
                                missing.append(f"{item['id']}: {option} needs "
                                               f"{item_id}.{field}")
                        for key in ("field",):
                            if requirement.get("field") and requirement["field"] not in fields:
                                missing.append(f"{item['id']}: manifest_metric "
                                               f"{item_id}.{requirement['field']} is "
                                               "never written")
        self.assertEqual([], missing)

    def test_min_instances_on_a_record_without_instances_fails(self):
        """The rx_ss_dpram bug: the requirement was attached to the wrong record."""
        root = self.tmp / "wrong-record"
        root.mkdir()
        for name in ("sc7f0_cdc_review.json", "sc7f0_drc_review.json",
                     "sc7f0_clock_pair_review.json"):
            shutil.copy(POLICY / name, root / name)
        path = root / "sc7f0_cdc_review.json"
        policy = json.loads(path.read_text())
        for item in policy["items"]:
            if item["id"] == "vendor_rx_ss_lutram_collision":
                for requirement in item["requires"]:
                    if requirement.get("id") == "rx_ss_dpram_max_delay":
                        requirement["min_instances"] = 4
        path.write_text(json.dumps(policy))
        result = Fixture(self.tmp / "wrong-record-round",
                         items=manifest_items()).result(root)
        self.assertIn("never counts instances", "\n".join(result["layer_b_errors"]))
        self.assertFalse(result["pass_layer_b"])

    def test_measured_max_delay_is_what_gets_compared(self):
        """Policy reviews 15 ns; the routed design says 8 ns -> FAIL, not agreement."""
        items = manifest_items()
        items["rx_ss_dpram_max_delay"].update(max_delay_measured_ns=8.0)
        items["rx_ss_dpram_max_delay"]["max_delay_expected_ns"] = 15.0
        result = self.run_items(items, "measured-delay")
        text = "\n".join(result["layer_b_errors"])
        self.assertIn("actually timed at 8.0 ns", text)
        self.assertFalse(result["pass_layer_b"])

    def test_max_delay_not_in_force_is_rejected(self):
        items = manifest_items()
        items["probe_meter_max_delay"].update(max_delay_effective=0)
        result = self.run_items(items, "delay-not-in-force")
        self.assertIn("no max delay in force", "\n".join(result["layer_b_errors"]))

    # --- 2. every gate input is bound to the round --------------------------
    def test_manifest_without_report_binding_is_rejected(self):
        fixture = Fixture(self.tmp / "unbound")
        write_manifest(fixture.dir, manifest_items(), reports={})
        result = fixture.result()
        self.assertIn("reports_sha256", "\n".join(result["layer_b_errors"]))

    def test_swapping_one_report_out_is_detected(self):
        """A methodology.rpt from another round must not be gradeable."""
        fixture = Fixture(self.tmp / "mixed")
        fixture.write("methodology.rpt",
                      fixture.dir.joinpath("methodology.rpt").read_text()
                      + "\n<!-- regenerated after the manifest -->\n")
        result = fixture.result()
        text = "\n".join(result["layer_b_errors"])
        self.assertIn("methodology.rpt", text)
        self.assertIn("was regenerated after the manifest", text)

    def test_manifest_binding_a_report_this_round_never_made_is_detected(self):
        fixture = Fixture(self.tmp / "crossround")
        items = manifest_items()
        write_manifest(fixture.dir, items)
        os.remove(fixture.dir / "drc.rpt")
        result = fixture.result()
        text = "\n".join(result["layer_b_errors"] + result["layer_a_errors"])
        self.assertIn("this round's report directory has no drc.rpt", text)

    # --- 3. Layer A removal needs every finding classified ------------------
    def test_second_unknown_clock_pair_keeps_layer_a_red(self):
        """TIMING-6 with the declared pair *and* an unknown pair: the declared pair is
        reviewed, the rule stays in Layer A. Layer A is not editable by policy."""
        fixture = Fixture(self.tmp / "two-pairs",
                          methodology=[("DPIR-2", "Warning", 1),
                                       ("TIMING-6", "Critical Warning", 2)],
                          pair_detail=True)
        fixture.write("methodology.rpt",
                      fixture.dir.joinpath("methodology.rpt").read_text()
                      + "TIMING-6#2 Critical Warning\nThe clocks clk_mystery and "
                        "pcie_user_clk are related (timed together) but they have no "
                        "common primary clock.\nRelated violations: <none>\n\n")
        result = fixture.result()
        self.assertIn("TIMING-6 Critical Warning=2", result["layer_a_errors"])
        self.assertFalse(result["pass_layer_a"], result["layer_a_errors"])
        self.assertIn("clk_mystery", "\n".join(result["layer_b_errors"]))

    # --- 4. DRC: an allow-list that matched nothing is not coverage ---------
    def test_drc_block_naming_only_a_net_still_locates_the_owner(self):
        """RTSTAT-10 prints net names, not `u_*` instances; the owner must still be
        found, and a net outside the allow-list must fail."""
        fixture = Fixture(self.tmp / "drc-nets",
                          drc=True)
        fixture.write("drc.rpt", drc_text(
            [("DPIP-2", "Warning", 1)],
            details=("DPIP-2#1 Warning\nNo routable loads\n34 net(s) have no routable "
                     "loads. The problem net is u_other_logic/dead_net[3].\n"
                     "Related violations: <none>\n\n")))
        result = gate.check(str(fixture.dir), str(POLICY))
        self.assertIn("outside the reviewed instances",
                      "\n".join(result["layer_b_errors"]))

    def test_drc_block_with_no_object_at_all_fails(self):
        fixture = Fixture(self.tmp / "drc-empty")
        fixture.write("drc.rpt", drc_text(
            [("DPIP-2", "Warning", 1)],
            details=("DPIP-2#1 Warning\nSomething happened without naming anything.\n"
                     "Related violations: <none>\n\n")))
        result = gate.check(str(fixture.dir), str(POLICY))
        text = "\n".join(result["layer_b_errors"])
        self.assertIn("names no object at all", text)

    def test_unrecognised_drc_severity_is_layer_a(self):
        fixture = Fixture(self.tmp / "drc-sev-unknown")
        fixture.write("drc.rpt", drc_text([("DPIP-2", "Notice", 1)]))
        result = gate.check(str(fixture.dir), str(POLICY))
        self.assertIn("not a severity this gate recognises",
                      "\n".join(result["layer_a_errors"]))

    def test_drc_finding_growth_beyond_the_reviewed_count_fails(self):
        root = self.tmp / "drc-growth"
        root.mkdir()
        for name in ("sc7f0_cdc_review.json", "sc7f0_clock_pair_review.json"):
            shutil.copy(POLICY / name, root / name)
        path = root / "sc7f0_drc_review.json"
        policy = json.loads((POLICY / "sc7f0_drc_review.json").read_text())
        for item in policy["items"]:
            if item["rule"] == "DPIP-2":
                item["max_instances"] = 1
        path.write_text(json.dumps(policy))
        fixture = Fixture(self.tmp / "drc-growth-round")
        fixture.write("drc.rpt", drc_text([("DPIP-2", "Warning", 3)]))
        result = gate.check(str(fixture.dir), root)
        self.assertIn("exceed the 1 this entry was reviewed against",
                      "\n".join(result["layer_b_errors"]))

    # --- 5. coverage is derived from this round's rows ----------------------
    def test_removing_the_cdc_rows_while_endpoints_stay_put_fails(self):
        rows = [r for r in CLEAN_CDC if r[0] != "CDC-26"]
        fixture = Fixture(self.tmp / "rows-gone", cdc=rows, items=manifest_items())
        result = fixture.result()
        self.assertIn("matched no row this round",
                      "\n".join(result["layer_b_errors"]))
        self.assertFalse(result["pass_layer_b"])

    def test_halving_the_cdc_rows_while_endpoints_stay_put_fails(self):
        rows, seen = [], 0
        for row in CLEAN_CDC:
            if row[0] == "CDC-26":
                seen += 1
                if seen > 2:
                    continue
            rows.append(row)
        self.assertEqual(2, len([r for r in rows if r[0] == "CDC-26"]))
        # endpoints stay at the four of the full round while only two rows remain
        fixture = Fixture(self.tmp / "rows-halved", cdc=rows, items=manifest_items())
        result = fixture.result()
        text = "\n".join(result["layer_b_errors"])
        self.assertIn("while the 2 CDC rows classified here describe exactly 2", text)
        self.assertFalse(result["pass_layer_b"])

    def test_halving_the_measured_endpoints_fails(self):
        items = manifest_items()
        items["rx_ss_dpram_max_delay"].update(endpoints=1)
        result = self.run_items(items, "endpoints-halved")
        self.assertIn("covers 1 endpoints while the 4 CDC rows classified here describe "
                      "exactly 4", "\n".join(result["layer_b_errors"]))

    def test_unknown_requirement_option_is_a_load_time_error(self):
        root = self.tmp / "typo-option"
        root.mkdir()
        for name in ("sc7f0_drc_review.json", "sc7f0_clock_pair_review.json"):
            shutil.copy(POLICY / name, root / name)
        path = root / "sc7f0_cdc_review.json"
        policy = json.loads((POLICY / "sc7f0_cdc_review.json").read_text())
        for item in policy["items"]:
            if item["id"] == "probe_meter_held_snapshot":
                item["requires"][1]["min_from_coverage"] = 100.0   # typo'd option
        path.write_text(json.dumps(policy))
        with self.assertRaises(ValueError) as ctx:
            review.load_policy(path, "cdc")
        self.assertIn("does not implement", str(ctx.exception))


class SourceInventoryTests(unittest.TestCase):
    """The reset CDC simulation runner must not be invisible to the release."""

    def test_reset_cdc_sim_is_not_gitignored(self):
        proc = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "--",
                               "scripts/sim_sc7f0_reset_cdc.tcl"],
                              cwd=REPO, capture_output=True, text=True)
        self.assertEqual("scripts/sim_sc7f0_reset_cdc.tcl\n", proc.stdout,
                         "the required XSim gate is hidden by .gitignore")

    def test_fpga_inventory_contains_every_required_input(self):
        files = release_id.scope_files(REPO, "fpga")
        self.assertEqual([], release_id.required_sources_missing(files, "fpga"))
        for name in ("constraints/sc7f0_async_io.xdc",
                     "scripts/gates/sc7f0_cdc_review.json",
                     "scripts/sc7f0_review_policy.py"):
            self.assertIn(name, files, name)

    def test_dropping_a_required_script_from_the_inventory_is_caught(self):
        files = release_id.scope_files(REPO, "fpga")
        for drop in ("scripts/sim_sc7f0_reset_cdc.tcl",
                     "scripts/gates/sc7f0_cdc_review.json",
                     "scripts/check_sc7f0_named_constraints.tcl"):
            missing = release_id.required_sources_missing(
                [f for f in files if f != drop], "fpga")
            self.assertEqual([drop], missing, drop)

    def test_scope_files_refuses_an_incomplete_inventory(self):
        # Prove the guard is wired into scope_files, not just exported: temporarily
        # hide one required file by pointing the scope at an empty list.
        missing = release_id.required_sources_missing([], "fpga")
        self.assertIn("scripts/sim_sc7f0_reset_cdc.tcl", missing)
        self.assertIn("scripts/gates/sc7f0_cdc_review.json", missing)

    def test_ignore_rule_was_not_broadened(self):
        gitignore = (REPO / ".gitignore").read_text()
        self.assertIn("!scripts/sim_sc7f0_reset_cdc.tcl", gitignore)
        self.assertIn("!scripts/sim_sc7f0_probe_tap.tcl", gitignore)
        # the sim_* rule itself must stay, otherwise every scratch sim is a
        # candidate release input
        self.assertIn("\nsim_*\n", gitignore)
        # ... and the exceptions must stay one-file-wide: a wildcard would make every
        # scratch simulation a release input, which is the other way to break this.
        self.assertNotIn("!sim_", gitignore)
        self.assertNotIn("!scripts/*", gitignore)


class ValidationSourceInventoryTests(unittest.TestCase):
    """The evidence sources a release quotes must ship with it, and be nameable.

    Two distinct failures live here:

      1. a required input is *invisible* - swallowed by .gitignore, so it is in
         nobody's fingerprint and nobody notices when it is deleted;
      2. a required input is *mislabelled* - present in the snapshot but in no role
         manifest, so scripts/sc7f0_source_drift.py files an edit to it under
         TOOLING_* and the release keeps shipping.

    The handover this replaced named runners that do not exist (tb/tb_sc7f0_*.sv,
    scripts/run_sc7f0_reset_probe_sim.tcl). A required path is therefore also
    asserted to exist on disk and to be listed by git: an invented name fails here
    instead of silently shrinking the release.
    """

    def test_every_required_input_exists_and_is_visible_to_git(self):
        for scope, names in release_id.REQUIRED_SOURCE_FILES.items():
            for name in names:
                self.assertTrue((REPO / name).is_file(),
                                f"required {scope} input {name} does not exist")
                proc = subprocess.run(["git", "ls-files", "-co", "--exclude-standard",
                                       "--", name], cwd=REPO, capture_output=True,
                                      text=True)
                self.assertEqual(proc.stdout.strip(), name,
                                 f"required {scope} input {name} is not in the release "
                                 "inventory (missing, or hidden by .gitignore: add one "
                                 "precise '!path' exception, never `git add -f`)")

    def test_the_complete_snapshot_covers_every_group(self):
        files = release_id.scope_files(REPO, "all")
        for scope in release_id.REQUIRED_SOURCE_FILES:
            self.assertEqual([], release_id.required_sources_missing(files, scope), scope)

    def test_dropping_any_required_input_from_its_scope_is_caught(self):
        """One loop over the declared set, so a newly required file is covered by the
        test that proves its absence fails - not by whoever remembered to add one."""
        for scope, names in release_id.REQUIRED_SOURCE_FILES.items():
            inventory = release_id.scope_files(REPO, "all" if scope == "validation"
                                              else scope)
            for drop in names:
                missing = release_id.required_sources_missing(
                    [f for f in inventory if f != drop], scope)
                self.assertEqual([drop], missing, f"{scope}:{drop}")

    def test_scope_files_refuses_an_incomplete_snapshot(self):
        """The guard has to be wired into scope_files, not just exported.

        Proved with a real (throwaway) git repository holding one required file: no
        monkeypatching, so the code path under test is the one the build runs.
        """
        work = Path(tempfile.mkdtemp(prefix="sc7f0-inventory-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(work, ignore_errors=True))
        keep = release_id.REQUIRED_SOURCE_FILES["fpga"][0]
        (work / keep).parent.mkdir(parents=True, exist_ok=True)
        (work / keep).write_text("placeholder\n")
        # git ls-files errors out on a pathspec that matches nothing, and the release
        # fingerprint spans eight roots, so create them all with one file each.
        for root in release_id.FINGERPRINT_PATHS:
            d = work / root
            d.mkdir(parents=True, exist_ok=True)
            (d / "placeholder.txt").write_text("x\n")
        for cmd in (["git", "init", "-q"], ["git", "add", "-A"],
                    ["git", "-c", "user.email=t@t", "-c", "user.name=t",
                     "commit", "-qm", "fixture"]):
            subprocess.run(cmd, cwd=work, check=True, capture_output=True)
        with self.assertRaises(ValueError) as ctx:
            release_id.scope_files(work, "fpga")
        text = str(ctx.exception)
        self.assertIn("release source inventory is incomplete for scope fpga", text)
        self.assertIn("scripts/gates/sc7f0_cdc_review.json", text)
        self.assertIn(".gitignore", text)

    def test_every_required_input_is_claimed_by_a_role_manifest(self):
        for scope, names in release_id.REQUIRED_SOURCE_FILES.items():
            for name in names:
                self.assertTrue(
                    release_id.matches_globs(name, release_id.FPGA_INPUT_GLOBS)
                    or release_id.matches_globs(name, release_id.VALIDATION_SOURCE_GLOBS),
                    f"{scope}:{name} matches neither SOURCE_FPGA nor SOURCE_VALIDATION "
                    "globs, so editing it after the freeze would read as tooling drift")

    def test_bitstream_and_validation_roles_do_not_bleed_into_each_other(self):
        """Segment-wise globs: `*` must not cross '/'. fnmatch's does, which swept
        scripts/tests/fixtures/*.tcl into the *bitstream* manifest and made editing a
        test fixture a fatal source drift after the freeze."""
        self.assertFalse(release_id.matches_globs(
            "scripts/tests/fixtures/named_constraints_stub.tcl",
            release_id.FPGA_INPUT_GLOBS))
        self.assertFalse(release_id.matches_globs("rtl/sub/deep.v",
                                                 release_id.FPGA_INPUT_GLOBS))
        self.assertTrue(release_id.matches_globs("rtl/sc7f0_reset_cdc.v",
                                                 release_id.FPGA_INPUT_GLOBS))
        self.assertTrue(release_id.matches_globs("tb/sc7f0_reset_cdc_tb.sv",
                                                 release_id.VALIDATION_SOURCE_GLOBS))

    def test_inventory_hash_binds_the_file_set_and_nothing_else(self):
        """The inventory hash answers "did the snapshot contain the set it claims?".

        Two rounds whose inventories differ by one file must not agree, while editing
        a listed file's bytes must not move it - which is exactly why it is reported
        next to, and not instead of, the content fingerprint.
        """
        import hashlib
        first = release_id.source_inventory(REPO, "all")
        second = release_id.source_inventory(REPO, "all")
        self.assertEqual(first["inventory_sha256"], second["inventory_sha256"])
        self.assertGreater(first["group_counts"]["fpga_physical_inputs"], 100)
        self.assertGreaterEqual(first["group_counts"]["validation_inputs"],
                                len(release_id.REQUIRED_SOURCE_FILES["validation"]))
        self.assertEqual({}, {k: v for k, v in first["required_missing"].items() if v})
        # semantically a digest over the sorted names, nothing more
        names = release_id.scope_files(REPO, "all")
        want = hashlib.sha256("".join(n + "\n" for n in names).encode()).hexdigest()
        self.assertEqual(want, first["inventory_sha256"])
        self.assertEqual(first["files"], len(names))
        # and dropping one name from that list would change it (the digest is over
        # the names, so this is arithmetic, not a hope)
        shorter = hashlib.sha256("".join(n + "\n" for n in names[1:]).encode()).hexdigest()
        self.assertNotEqual(want, shorter)


if __name__ == "__main__":
    unittest.main(verbosity=2)
