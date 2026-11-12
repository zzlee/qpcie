#!/usr/bin/env python3
"""The strict gate must recognise a routed design without taking anyone's word for it.

Why this exists: round 26111103 routed cleanly (179530/179530 nets fully routed, 0 nets
with routing errors) and was rejected with "timing report is not routed", because the
checker only accepted the literal Design State "Routed". With post-route physical
optimisation Vivado writes "Physopt postRoute" for the same - better - design.

The fix is an allow-list, not a looser pattern: anything not provably at or after
route_design stays a failure, and an unrecognised Vivado wording fails too, so a
report can never talk its way past this check.
"""
from __future__ import annotations

from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import check_sc7f0_timing as gate  # noqa: E402

PASS_FIXTURE = REPO / "build/qpcie_zu4ev_proj"           # archived, passes strict
R3_REPORT = (REPO / "build/vcu-release-26111103-r1/fpga/project/timing_summary.rpt")


def header(state: str) -> str:
    return ("| Tool Version      : Vivado v.2023.2 (lin64)\n"
            "| Design            : zu4ev_pcie_card_top\n"
            f"| Design State      : {state}\n"
            "| Temperature Grade : E\n")


class DesignStateTests(unittest.TestCase):
    def test_reads_the_state_out_of_the_report_header(self):
        self.assertEqual(gate.design_state(header("Physopt postRoute")),
                         "Physopt postRoute")

    def test_missing_header_is_an_error_not_a_pass(self):
        with self.assertRaises(ValueError):
            gate.design_state("| Design            : zu4ev_pcie_card_top\n")

    def test_post_route_states_pass(self):
        for state in ("Routed", "Physopt postRoute"):
            self.assertIsNone(gate.classify_design_state(state), state)

    def test_pre_route_states_fail(self):
        for state in ("Synthesized", "Optimized", "Placed", "Physopt preRoute"):
            error = gate.classify_design_state(state)
            self.assertIsNotNone(error, state)
            self.assertIn("not routed", error)
            self.assertIn(state, error)

    def test_unknown_state_fails_closed(self):
        error = gate.classify_design_state("Quantum Optimised")
        self.assertIsNotNone(error)
        self.assertIn("not a known post-route state", error)

    def test_real_routed_fixture_reads_as_routed(self):
        if not (PASS_FIXTURE / "timing_summary.rpt").is_file():
            self.skipTest("archived routed report set is not present")
        state = gate.design_state((PASS_FIXTURE / "timing_summary.rpt").read_text())
        self.assertIsNone(gate.classify_design_state(state), state)

    def test_physopt_postroute_build_is_recognised(self):
        """The exact report that round 26111103 was rejected for."""
        if not R3_REPORT.is_file():
            self.skipTest("no 26111103 routed report to check against")
        state = gate.design_state(R3_REPORT.read_text(errors="ignore"))
        self.assertEqual(state, "Physopt postRoute")
        self.assertIsNone(gate.classify_design_state(state))

    def test_whole_gate_still_passes_its_passing_fixture(self):
        """Guard: relaxing the state check must not have relaxed anything else.

        The archived fixture predates two deliberate tightenings: report_drc is
        now a mandatory Layer A input (AGENTS.md; B1 review P1-6 - the flow never
        produced drc.rpt) and every Warning/Advisory needs an itemised review
        ledger (Layer B). So the archived report set must fail *only* on those
        missing inputs; any other error means the relaxation leaked.
        """
        if not (PASS_FIXTURE / "cdc.rpt").is_file():
            self.skipTest("archived routed report set is not present")
        result = gate.check(PASS_FIXTURE)
        self.assertEqual("Routed", result["design_state"])
        margins = result["margins_ns"]
        self.assertTrue(margins["WNS"] >= 0 and margins["WHS"] >= 0
                        and margins["WPWS"] >= 0, margins)
        allowed = {'missing DRC report (report_drc is required by AGENTS.md; a build '
                   'that never reports DRC cannot be graded)',
                   'missing/incomplete detailed CDC warnings'}
        unexpected = [e for e in result["layer_a_errors"] if e not in allowed]
        self.assertEqual([], unexpected,
                         "Layer A gained an error beyond the new mandatory inputs")
        self.assertIn('missing DRC report', "\n".join(result["layer_a_errors"]))
        self.assertFalse(result["pass_layer_b"],
                         "a report set with no Layer B evidence must not pass Layer B")


if __name__ == "__main__":
    unittest.main(verbosity=2)
