#!/usr/bin/env python3
"""Counterexamples for the five evidence-producer defects of round 26111202.

The Layer-B gate can only be as good as the manifest that
scripts/check_sc7f0_named_constraints.tcl writes, and in
build/vcu-release-26111202-r1 that manifest was wrong five times over
(docs/sc7f0_full_build_26111202.md 5.2, T1..T5):

  T1  pad closure reported `to_objects = 0` for seven pads while the same
      manifest recorded a non-zero `endpoint_count` for the same pad - the pin ->
      cell -> sequential enumeration silently returned nothing;
  T2  a `probe_error` containing a raw newline made the whole file unparseable,
      so 30+ Layer B entries were graded "absent from this round's coverage
      manifest";
  T3  the ignored / scope-override audit was read from the report directory and
      never written there, so every entry said "missing .tmp-exceptions-...";
  T4  `report_bus_skew` has no -from/-to in 2023.2; the swallowed "Unknown
      option '-from'" turned into bus_skew_violated = 0;
  T5  `"design_state": ""`.

Each test drives the tclsh stub harness (scripts/tests/fixtures/
named_constraints_stub.tcl, which mocks 2023.2 collection semantics) through one
scenario and asserts two things at once: the failure is *named* and the manifest
survives as parseable JSON with a FAIL verdict.  Nothing here runs Vivado, and
the frozen 26111202-r1 / 26111103-r1 evidence is only ever read.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "scripts/tests"))

import sc7f0_review_policy as review       # noqa: E402
import check_sc7f0_timing as gate          # noqa: E402
from gate_fixtures import produced_fields  # noqa: E402

STUB = REPO / "scripts" / "tests" / "fixtures" / "named_constraints_stub.tcl"
HOOK = REPO / "scripts" / "check_sc7f0_named_constraints.tcl"
BUS_SKEW_FIXTURE = REPO / "scripts" / "tests" / "fixtures" / "bus_skew_report_excerpt.rpt"

POST_ROUTE_STATES = ("Routed", "Physopt postRoute", "Fully Routed")


class HookRun:
    """One stub-harness run: its log, its manifest, and its report directory."""

    def __init__(self, scenario, workdir):
        self.scenario = scenario
        self.dir = Path(workdir) / "reports"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.cwd = Path(workdir) / "cwd"
        self.cwd.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env["SC7F0_REPORT_DIR"] = str(self.dir)
        env["SC7F0_STUB_SCENARIO"] = scenario
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        self.proc = subprocess.run(["tclsh", str(STUB)], cwd=self.cwd, env=env,
                                   capture_output=True, text=True, timeout=120)
        self.log = self.proc.stdout + self.proc.stderr
        self.path = self.dir / "named-constraint-evidence.json"

    @property
    def items(self):
        return self.manifest["items"]

    def item(self, item_id):
        return self.items[item_id]

    def error_text(self):
        return "\n".join(str(problem) for problem in self.manifest["hook_problems"])

    def expect(self, condition, message):
        if not condition:
            raise AssertionError(f"{self.scenario}: {message}\n--- harness log ---\n"
                                 f"{self.log[-3000:]}")

    # --- assertions every scenario shares ---------------------------------
    def check_common(self):
        self.expect("HARNESS_FAIL" not in self.log, f"stub harness crashed:\n{self.log}")
        self.expect(self.path.is_file(), "the hook must always write the manifest")
        raw = self.path.read_text()
        try:
            self.manifest = json.loads(raw)
        except ValueError as exc:            # T2: this used to lose the whole file
            raise AssertionError(f"{self.scenario}: manifest is not valid JSON: {exc}\n"
                                 f"{raw[:400]}") from None
        self.raw = raw
        # the verdict must agree with the problem list, and a problem must fail
        problems = self.manifest["hook_problems"]
        expect_verdict = "PASS" if not problems else "FAIL"
        self.expect(self.manifest["hook_verdict"] == expect_verdict,
                    f"verdict {self.manifest['hook_verdict']!r} with {len(problems)} "
                    "problems")
        # a coverage failure must also abort the flow, not just be noted: the
        # hook raises, and the harness reports that raise instead of a clean run
        aborted = "HARNESS_EXPECTED_COVERAGE_FAILURE" in self.log
        self.expect(aborted == bool(problems),
                    "the hook must raise exactly when the verdict is FAIL: "
                    f"aborted={aborted} problems={len(problems)}")
        # no scratch may ever be written next to the process' working directory
        self.expect(not list(self.cwd.glob(".tmp-*")) and not list(self.cwd.glob("hook-scratch")),
                    "scratch appeared in the working directory")
        self.expect("HARNESS_SCRATCH_IN_CWD" not in self.log,
                    "the harness saw scratch in the working directory")
        # report dir is recorded as an absolute path
        self.expect(Path(self.manifest["report_dir"]).is_absolute(),
                    "report_dir must be absolute")
        # every report the hook hashed must still match the bytes on disk
        for name, digest in self.manifest["reports_sha256"].items():
            path = self.dir / name
            self.expect(path.is_file(), f"manifest binds {name}, which does not exist")
            self.expect(hashlib.sha256(path.read_bytes()).hexdigest() == digest,
                        f"manifest binds {name} to a digest that is not this file")
        # the gate reads the same binding; it must not report a hole
        errors = review.verify_report_binding(self.manifest, self.dir,
                                             review.GATE_REPORT_NAMES)
        unbound = [e for e in errors if "does not bind" in e or "different round" in e]
        self.expect(not unbound, f"report binding incomplete: {unbound}")

    def expect_items_parseable(self):
        """Every item must carry only fields the producer really writes."""
        for item_id, record in self.items.items():
            allowed = produced_fields(item_id)
            extra = sorted(set(record) - allowed)
            self.expect(not extra, f"{item_id} carries fields the schema extractor "
                                   f"cannot find in the hook: {extra}")


class ScenarioCase(unittest.TestCase):
    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workdir = Path(self._tmp.name)

    def run_scenario(self, scenario):
        run = HookRun(scenario, self.workdir / scenario)
        run.check_common()
        run.expect_items_parseable()
        return run


class PositiveBaselineTests(ScenarioCase):
    def test_clean_round_is_parseable_and_passes(self):
        run = self.run_scenario("clean")
        self.assertEqual(run.manifest["hook_verdict"], "PASS", run.log)
        self.assertEqual(run.manifest["hook_problems"], [])
        self.assertEqual(run.manifest["hook_section_errors"], 0)
        # T5: the state is the string this round's own report carries
        self.assertEqual(run.manifest["design_state"], "Physopt postRoute")
        self.assertEqual(run.manifest["design_state_source"], "timing_summary.rpt")
        # the producer and the gate must read the same words out of the same file
        self.assertEqual(run.manifest["design_state"],
                         gate.design_state((run.dir / "timing_summary.rpt").read_text()))
        self.assertIsNone(gate.classify_design_state(run.manifest["design_state"]))

    def test_pad_closure_measures_first_stage_cells(self):
        run = self.run_scenario("clean")
        for item_id, item in run.items.items():
            if item.get("class") != "pad_closure":
                continue
            self.assertGreater(item["endpoint_count"], 0, item)
            self.assertGreater(item["to_objects"], 0, item)
            self.assertEqual(item["sequential_endpoint_count"], item["to_objects"])
            self.assertEqual(item["first_stage_resolution_method"],
                             "all_fanout -endpoints_only -only_cells")
            self.assertIn("FDRE", item["first_stage_ref_families"])
            self.assertEqual(item["unclaimed_first_stage_endpoints"], 0)
            self.assertEqual(item["first_stage_endpoints_missing_async_reg"], 0)

    def test_first_stage_loads_and_clock_domains_are_measured(self):
        run = self.run_scenario("clean")
        io = [i for i in run.items.values() if i.get("class") == "io_exception"
              and i.get("first_stage_cells")]
        self.assertTrue(io)
        for item in io:
            self.assertGreater(item["internal_load_count"], 0, item)
            self.assertEqual(item["internal_load_clock_domains"], "clk_pl_0")
            self.assertEqual(item["clock_domain_count"], 1, item)
            self.assertEqual(item["internal_filter_same_domain"], 1, item)

    def test_bus_skew_is_located_by_its_named_root(self):
        run = self.run_scenario("clean")
        item = run.item("capture_gray_to_source_time")
        self.assertEqual(item["bus_skew_measured"], 1)
        self.assertEqual(float(item["bus_skew_ns"]), 6.0)
        self.assertEqual(float(item["bus_skew_actual_ns"]), 1.776)
        self.assertEqual(float(item["bus_skew_slack_ns"]), 4.224)
        self.assertEqual(int(item["bus_skew_position"]), 218)
        self.assertEqual(item["bus_skew_report_source"], "report_bus_skew -return_string")
        self.assertEqual(item["bus_skew_violated"], 0)
        # the fixture is the 26111202-r1 report shape; the csr row is a second
        # constraint over the same From expression, so the To expression has to
        # discriminate it instead of matching the first row
        csr = run.item("capture_gray_to_csr_time")
        self.assertEqual(int(csr["bus_skew_position"]), 220)
        self.assertEqual(float(csr["bus_skew_slack_ns"]), 4.139)

    def test_exception_audit_needs_no_scratch_when_return_string_works(self):
        run = self.run_scenario("clean")
        self.assertEqual(run.manifest["hook_scratch_files"], [])
        source = run.item("async_in_hdmi_rx_5v_det_probe")["exception_audit_source"]
        for mode in ("report_exceptions -return_string",
                     "report_exceptions -coverage -return_string",
                     "report_exceptions -ignored -return_string",
                     "report_exceptions -scope_override -return_string"):
            self.assertIn(mode, source)


class T1PadClosureTests(ScenarioCase):
    def test_zero_sequential_first_stage_is_a_named_failure(self):
        run = self.run_scenario("pad_zero_sequential")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        pads = [i for i in run.items.values() if i.get("class") == "pad_closure"]
        self.assertTrue(pads)
        for item in pads:
            self.assertGreater(item["endpoint_count"], 0, item)
            self.assertEqual(item["to_objects"], 0, item)
            self.assertIn("0 sequential first-stage cells", item["probe_error"])
            self.assertIn("endpoint(s)", item["probe_error"])
        self.assertIn("0 sequential first-stage cells", run.error_text())
        # the round cannot be graded clean even though the file parsed
        self.assertNotEqual(run.manifest["hook_verdict"], "PASS")

    def test_clock_and_setreset_pin_loads_are_recorded_not_assumed(self):
        run = self.run_scenario("clock_pin_load")
        pad = run.item("async_pad_hdmi_rx_5v_det")
        self.assertEqual(pad["clock_or_setreset_pin_loads"], 1)
        self.assertIn("S", pad["endpoint_pin_names"].split("|"))
        self.assertEqual(run.item("async_in_hdmi_rx_5v_det_probe")
                         ["clock_or_setreset_pin_loads"], 1)


class T2ManifestEncodingTests(ScenarioCase):
    def test_error_with_control_characters_still_parses_and_still_fails(self):
        run = self.run_scenario("newline_error")
        error = run.item("async_in_hdmi_rx_5v_det_probe")["probe_error"]
        # decoded, the message keeps everything Vivado printed ...
        for token in ("\n", "\r", "\t", '"', "\\", "\x07"):
            self.assertIn(token, error, repr(error))
        # ... while the file itself contains no raw control character outside
        # the structural newlines (that is what made the round unparseable)
        body = run.raw.replace("\n", "")
        for ch in body:
            self.assertGreaterEqual(ord(ch), 0x20, f"raw {ord(ch):#x} in manifest")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        self.assertIn("query error", run.error_text())
        self.assertNotEqual(run.manifest["hook_verdict"], "PASS")

    def test_escaping_survives_a_malicious_object_name(self):
        # the writer must be able to quote a value that contains both a quote
        # and a backslash without breaking out of its JSON string
        run = self.run_scenario("newline_error")
        self.assertIn("hook_problems", run.manifest)
        self.assertTrue(run.manifest["hook_problems"])


class T3ReportPathTests(ScenarioCase):
    def test_scratch_fallback_lives_under_the_report_dir(self):
        run = self.run_scenario("no_return_string")
        names = run.manifest["hook_scratch_files"]
        self.assertTrue(names, "the fallback was expected to write scratch")
        scratch = run.dir / "hook-scratch"
        self.assertTrue(scratch.is_dir())
        for name in names:
            self.assertTrue((scratch / name).is_file(), name)
        self.assertNotIn("hook-scratch", names)
        source = run.item("async_in_hdmi_rx_5v_det_probe")["exception_audit_source"]
        self.assertIn("scratch", source)
        self.assertEqual(run.manifest["hook_verdict"], "PASS", run.log)

    def code_only(self, text):
        """Code lines only: the hook documents the old defects in comments."""
        return "\n".join(line for line in text.splitlines()
                          if not line.strip().startswith("#"))

    def test_the_hook_never_names_the_old_relative_scratch_again(self):
        code = self.code_only(HOOK.read_text())
        # no derived report path is built against a bare variable or the cwd any
        # more; every scratch file goes through sc7f0_scratch_file, which is
        # anchored to the absolute report directory
        self.assertIn("file join $::sc7f0_scratch", code)
        self.assertIn("file normalize $::env(SC7F0_REPORT_DIR)", code)
        for stale in ("/.tmp", "\"$::env(SC7F0_REPORT_DIR)/", "set plain \"",
                      "set cover \"", "set file \"$"):
            self.assertNotIn(stale, code, stale)


class T4BusSkewTests(ScenarioCase):
    def test_missing_named_root_is_reported_as_not_measured(self):
        run = self.run_scenario("bus_skew_root_missing")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        for item_id in ("capture_gray_to_source_time", "capture_gray_to_csr_time"):
            item = run.item(item_id)
            self.assertEqual(int(item.get("bus_skew_measured", 0)), 0, item)
            self.assertIn("bus skew was NOT measured", item["probe_error"])
        self.assertIn("bus skew was NOT measured", run.error_text())

    def test_bus_skew_does_not_need_the_unsupported_scoped_signature(self):
        # 2023.2's report_bus_skew has no -from/-to: the hook must not lose the
        # measurement because of it, and must say which source it used.
        text = HOOK.read_text()
        self.assertNotIn("report_bus_skew -from", text)
        run = self.run_scenario("bus_skew_bad_signature")
        item = run.item("capture_gray_to_source_time")
        self.assertEqual(item["bus_skew_report_source"], "this round's bus-skew.rpt")
        self.assertEqual(int(item["bus_skew_measured"]), 1)
        self.assertEqual(float(item["bus_skew_actual_ns"]), 1.776)
        self.assertEqual(run.manifest["hook_verdict"], "PASS", run.log)


class T5DesignStateTests(ScenarioCase):
    def test_missing_state_fails_instead_of_being_written_empty(self):
        run = self.run_scenario("empty_design_state")
        self.assertEqual(run.manifest["design_state"], "")
        self.assertEqual(run.manifest["design_state_source"], "")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        self.assertIn("cannot prove it was routed", run.error_text())
        # the live design object is cross-checked but never trusted alone
        joined = " ".join(run.manifest["design_state_evidence"])
        self.assertIn("current_design", joined)

    def test_placed_state_is_rejected(self):
        run = self.run_scenario("placed_design_state")
        self.assertEqual(run.manifest["design_state"], "Placed")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        self.assertIn("not a known post-route state", run.error_text())
        self.assertNotIn(run.manifest["design_state"], POST_ROUTE_STATES)


class NegativeObjectTests(ScenarioCase):
    def test_zero_objects_fail_and_do_not_look_empty_happy(self):
        run = self.run_scenario("zero_objects")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        reviewed = [i for i in run.items.values()
                    if int(i.get("review_required", 0))]
        self.assertTrue(reviewed)
        for item in reviewed:
            if item.get("class") == "metric":
                continue
            self.assertIn("resolved to 0/0 objects", run.error_text())
            break
        self.assertIn("empty object list", run.error_text())


def _nested_requirements(node, found):
    """Every requirement dict in a policy file that grades from-coverage."""
    if isinstance(node, dict):
        if "min_from_coverage_pct" in node:
            found.append(node)
        for value in node.values():
            _nested_requirements(value, found)
    elif isinstance(node, list):
        for value in node:
            _nested_requirements(value, found)
    return found


class CoverageColumnTests(ScenarioCase):
    """T6, found because T1..T5 finally made the manifest readable.

    report_exceptions -coverage is a column-aligned table whose columns are not a
    fixed number of tokens apart: an exception with no -from pins prints
    `221  False Path  false  false              2 ports  2        100.00`, which
    shifts every later column.  The hook used to take [lindex $fields 7] and
    [lindex $fields 8] as "endpoints" and "From (%)", which produced the word
    "cells"; scripts/sc7f0_review_policy.py then did float("cells") and the whole
    Layer B gate aborted (`could not convert string to float: 'cells'`).  The
    hook now slices the row at the offsets the report's own header declares.
    """

    def test_coverage_values_come_from_the_report_columns(self):
        run = self.run_scenario("clean")
        item = run.item("capture_gray_to_source_time")
        self.assertEqual(float(item["from_coverage_pct"]), 100.0, item)
        self.assertEqual(float(item["to_coverage_pct"]), 33.33, item)
        self.assertEqual(int(item["endpoints"]), 64, item)
        self.assertEqual(item["coverage_from_column"], "64 cells", item)
        # the raw row travels with the number, so a reviewer can audit it
        self.assertIn("100.00", item["coverage_row"])

    def test_no_coverage_field_is_ever_a_non_numeric_string(self):
        for scenario in ("clean", "coverage_blank_from", "coverage_no_header",
                         "real_routed_shape"):
            run = self.run_scenario(scenario)
            for item_id, item in run.items.items():
                for field in ("from_coverage_pct", "to_coverage_pct", "endpoints"):
                    value = item.get(field)
                    if value is None:
                        continue
                    try:
                        float(value)
                    except (TypeError, ValueError):
                        self.fail(f"{scenario}/{item_id}.{field} = {value!r} would "
                                  "abort scripts/sc7f0_review_policy.py")

    def test_no_coverage_header_fails_closed(self):
        run = self.run_scenario("coverage_no_header")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        self.assertIn("no column header", run.error_text())
        for item in run.items.values():
            self.assertNotIn("from_coverage_pct", item,
                             "an unreadable column must not become a value")

    def test_a_blank_from_column_is_unknown_not_zero(self):
        run = self.run_scenario("coverage_blank_from")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        self.assertIn("from coverage is unknown", run.error_text())
        item = run.item("capture_gray_to_source_time")
        self.assertNotIn("from_coverage_pct", item)
        self.assertEqual(int(item["endpoints"]), 2, item)

    def test_the_production_policy_can_read_a_produced_manifest(self):
        """The gate must be able to grade the manifest, not crash on it."""
        run = self.run_scenario("clean")
        found = _nested_requirements(json.loads(
            (REPO / "scripts" / "gates" / "sc7f0_cdc_review.json").read_text()), [])
        self.assertTrue(found, "the shipped policy is expected to grade from-coverage")
        for requirement in found:
            item_id = requirement.get("id", "capture_gray_to_source_time")
            errors = []
            try:
                review._check_named_constraint(item_id, requirement, run.manifest,
                                               errors)
            except Exception as exc:                       # noqa: BLE001
                self.fail(f"the policy crashed on the producer's own manifest: {exc}")


class UnsetPropertyValueTests(ScenarioCase):
    """An unset property is one empty value, not a query error.

    Measured on the routed 26111202 checkpoint: `get_property ASYNC_REG` over the
    two ddc synchroniser cells answers `{} 1`, and over the stage-0 cell alone it
    answers the empty string.  The first revision of the repaired hook read that
    empty string as "0 values for 1 object" and raised a false query error on
    async_in_hdmi_rx_ddc_scl_filter, async_in_hdmi_rx_ddc_sda_filter and
    async_out_hdmi_rx_hpd_out (build/hook-repair-26111203-r1/sections.txt).
    """

    def test_unset_property_on_one_object_is_recorded_not_refused(self):
        run = self.run_scenario("real_routed_shape")
        for item in run.items.values():
            self.assertNotIn("returned 0 value", str(item.get("probe_error", "")),
                             "an unset property must not become a query error")
        scl = run.item("async_pad_hdmi_rx_ddc_scl")
        # honest classification: the first stage exists, and the stage that does
        # not carry ASYNC_REG is counted, not hidden
        self.assertEqual(scl["sequential_endpoint_count"], scl["to_objects"])
        self.assertLess(scl["async_reg_endpoint_count"], scl["sequential_endpoint_count"])
        self.assertEqual(scl["first_stage_endpoints_missing_async_reg"], 1)

    def test_a_short_collection_answer_still_fails(self):
        """The opposite half: a genuinely partial result must not pass."""
        run = self.run_scenario("short_property_result")
        self.assertEqual(run.manifest["hook_verdict"], "FAIL")
        self.assertIn("returned 1 value(s) for 2 object(s)", run.error_text())
        named = [i for i in run.items.values()
                 if "returned 1 value(s) for 2 object(s)" in str(i.get("probe_error", ""))]
        self.assertTrue(named, "the failing item must name itself")


class OutputDirectionExceptionTests(ScenarioCase):
    """`set_false_path -to <port>` has no -from side, and the hook had to learn that.

    Before this the output branch of the io loop never queried the exception at all:
    it measured the pad driver and stopped, so deleting an async_out_* line from
    constraints/sc7f0_async_io.xdc changed nothing in the manifest.  Round 26111202
    left exactly two HIGH no-output-delay ports (the RX DDC pair), which is what put
    those two rows in the XDC - and rows nobody can prove are gone are not a review.
    """

    ITEMS = ("async_out_hdmi_rx_ddc_scl", "async_out_hdmi_rx_ddc_sda",
             "async_out_hdmi_rx_hpd_out", "async_out_leds",
             "async_out_hdmi_tx_tmds_clk")

    def test_clean_round_proves_the_output_exception_exists(self):
        run = self.run_scenario("clean")
        self.assertEqual("PASS", run.manifest["hook_verdict"], run.log)
        for item_id in self.ITEMS:
            record = run.item(item_id)
            self.assertNotIn("", [str(record.get("exception_position", ""))],
                             f"{item_id}: {record}")
            self.assertEqual("False Path", record["exception_type"], record)
            self.assertGreaterEqual(int(record["pad_driver_cells"]), 1, record)
            self.assertEqual(0, int(record["ignored"]), record)
            self.assertEqual(0, int(record["scope_overridden"]), record)
            # a from-less exception must record its missing From coverage as
            # not-applicable, never as 0 % and never as a coverage failure
            self.assertIn("not applicable", str(record.get("exception_from_coverage",
                                                           "")), record)
            self.assertEqual("", str(record.get("probe_error", "")), record)

    def test_a_deleted_output_exception_is_a_named_failure(self):
        run = self.run_scenario("output_exception_missing")
        self.assertEqual("FAIL", run.manifest["hook_verdict"], run.log)
        for item_id in self.ITEMS:
            record = run.item(item_id)
            self.assertIn("named output-direction constraint", str(record["probe_error"]),
                          f"{item_id}: {record}")
        # and the input side is untouched by this rule: the two checks stay separate
        for item_id, record in run.items.items():
            if item_id.startswith("async_in_"):
                self.assertNotIn("named output-direction constraint",
                                 str(record.get("probe_error", "")), item_id)


class InternalAsyncEntryTests(ScenarioCase):
    """The six probe crossings that round 26111202 filed as CDC-10 Critical.

    The fix has two halves that must both be measurable: a register in the source
    clock, and one exception written from that register to chain[0] only. Each
    scenario below breaks exactly one half of the claim and the hook must say so -
    otherwise the entry would be a policy file asserting its own shape.
    """

    ITEMS = {
        "probe_rxss_tlast_src_to_probe": "clkout2",
        "probe_rxss_tuser_src_to_probe": "clkout2",
        "probe_rxss_tvalid_src_to_probe": "clkout2",
        "probe_phy_ch0_tvalid_src_to_probe": "phy_rxoutclk",
        "probe_phy_ch1_tvalid_src_to_probe": "phy_rxoutclk",
        "probe_phy_ch2_tvalid_src_to_probe": "phy_rxoutclk",
    }

    def test_clean_round_measures_every_internal_entry(self):
        run = self.run_scenario("clean")
        self.assertEqual(run.manifest["hook_verdict"], "PASS", run.log)
        found = {i: v for i, v in run.items.items()
                 if v.get("class") == "internal_async"}
        self.assertEqual(sorted(self.ITEMS), sorted(found),
                         "the hook must produce exactly the reviewed internal entries")
        for item_id, record in found.items():
            self.assertEqual(1, int(record["from_objects"]), record)
            self.assertEqual(1, int(record["to_objects"]), record)
            self.assertEqual(2, int(record["chain_stage_objects"]),
                             f"{item_id}: stages [1] and [2] must be resolvable")
            self.assertEqual(1, int(record["first_stage_async_reg"]), record)
            self.assertGreaterEqual(int(record["paths_analysed"]), 2,
                                    f"{item_id}: the chain itself must stay timed")
            self.assertEqual(self.ITEMS[item_id], record["source_clocks"],
                             f"{item_id}: the source register must sit in the clock "
                             "report_cdc named for its launch flop")
            self.assertEqual("clk_pl_0", record["destination_clocks"], record)
            self.assertEqual(2, int(record["clock_domain_count"]), record)
            self.assertEqual("False Path", record["exception_type"], record)
            self.assertEqual(1, int(record["exception_rows"]),
                             f"{item_id}: one exception per crossing")
            self.assertEqual(0, int(record["ignored"]), record)
            self.assertEqual(0, int(record["scope_overridden"]), record)
            self.assertGreaterEqual(int(record["upstream_paths"]), 1, record)
            self.assertAlmostEqual(6.734, float(record["upstream_requirement"]),
                                   places=3,
                                   msg="the feed-in must be timed at the source "
                                       "clock's own requirement")
            self.assertEqual("", str(record.get("probe_error", "")), record)

    def test_a_source_register_in_the_wrong_clock_is_named(self):
        """The exact 26111202 shape: the capture flopped into pl_clk0."""
        run = self.run_scenario("probe_source_wrong_clock")
        self.assertEqual("FAIL", run.manifest["hook_verdict"])
        for item_id, clock in self.ITEMS.items():
            record = run.item(item_id)
            self.assertIn("is clocked by clk_pl_0", str(record["probe_error"]), record)
            self.assertIn(f"reviews the {clock} domain", str(record["probe_error"]),
                          record)
        # and only these six: the reviewed max-delay items are untouched
        self.assertNotIn("capture_gray", run.error_text())

    def test_a_chain_without_async_reg_is_recorded_as_zero_not_hidden(self):
        run = self.run_scenario("probe_no_async_reg")
        for item_id in self.ITEMS:
            self.assertEqual(0, int(run.item(item_id)["first_stage_async_reg"]),
                             f"{item_id}: the attribute is the whole claim")

    def test_the_shipped_policy_refuses_a_chain_without_async_reg(self):
        """The gate must fail it, not merely record it."""
        run = self.run_scenario("probe_no_async_reg")
        policy = json.loads((REPO / "scripts" / "gates" /
                             "sc7f0_clock_pair_review.json").read_text())
        requirements = []
        for item in policy["items"]:
            for requirement in item.get("requires", []):
                if requirement.get("kind") == "named_constraint" and \
                        requirement.get("id") in self.ITEMS and \
                        requirement.get("min_first_stage_async_reg"):
                    requirements.append(requirement)
        self.assertTrue(requirements, "the shipped policy must demand ASYNC_REG "
                                      "on every internal entry")
        errors = []
        for requirement in requirements:
            review._check_named_constraint(requirement["id"], requirement,
                                           run.manifest, errors)
        self.assertEqual(len(requirements), len(errors),
                         f"expected one rejection per entry, got {errors}")
        for message in errors:
            self.assertIn("ASYNC_REG", message)

    def test_an_exception_that_swallowed_the_chain_is_named(self):
        """-from <clock> instead of -from <flop>: the chain stops being analysed."""
        run = self.run_scenario("probe_chain_excepted")
        self.assertEqual("FAIL", run.manifest["hook_verdict"])
        for item_id in self.ITEMS:
            record = run.item(item_id)
            self.assertEqual(0, int(record["paths_analysed"]), record)
            self.assertIn("broader than the named entry", str(record["probe_error"]),
                          record)

    def test_an_unanalysed_feed_in_is_named(self):
        run = self.run_scenario("probe_upstream_untimed")
        self.assertEqual("FAIL", run.manifest["hook_verdict"])
        for item_id in self.ITEMS:
            record = run.item(item_id)
            self.assertEqual(0, int(record["upstream_paths"]), record)
            self.assertIn("not analysed", str(record["probe_error"]), record)

    def test_a_max_delay_where_a_false_path_was_reviewed_is_named(self):
        """An entry that drifted into a different exception type is not the same
        claim, even while it still cuts the crossing."""
        run = self.run_scenario("probe_exception_not_false_path")
        self.assertEqual("FAIL", run.manifest["hook_verdict"])
        for item_id in self.ITEMS:
            record = run.item(item_id)
            self.assertEqual("Max Delay", record["exception_type"], record)
            self.assertIn("not the False Path", str(record["probe_error"]), record)


FRESH_MANIFEST = REPO / "build" / "hook-repair-26111203-r1" / "reports" / \
    "named-constraint-evidence.json"
FROZEN_MANIFEST = REPO / "build" / "vcu-release-26111202-r1" / "fpga" / "project" / \
    "named-constraint-evidence.json"


class LiveEvidenceTests(unittest.TestCase):
    """Bind the suite to the one read-only routed-checkpoint run, if present.

    This is the only place the suite touches a real Vivado product; it never runs
    Vivado, it only re-reads the artefacts that run left behind.
    """

    def test_routed_checkpoint_manifest_parses_and_is_complete(self):
        if not FRESH_MANIFEST.exists():
            self.skipTest(f"{FRESH_MANIFEST} is produced by a Vivado run")
        manifest = json.loads(FRESH_MANIFEST.read_text())
        self.assertEqual(manifest["hook_section_errors"], 0,
                         "every named section has to have run")
        self.assertEqual(manifest["hook_scratch_files"], [],
                         "-return_string leaves no scratch behind")
        self.assertTrue(manifest["design_state"].strip())
        self.assertIsNone(gate.classify_design_state(manifest["design_state"]))
        self.assertEqual(manifest["hook_verdict"], "FAIL",
                         "the 26111202 design is broken; the tool may not hide it")
        pads = [i for i in manifest["items"].values()
                if i.get("class") == "pad_closure"]
        self.assertEqual(len(pads), 7)
        for pad in pads:
            # T1: the same record can no longer say 1 object in and 0 out while
            # its own endpoint_count says otherwise
            self.assertGreater(pad["endpoint_count"], 0, pad)
            self.assertEqual(pad["to_objects"], pad["endpoint_count"], pad)
            self.assertGreater(pad["to_objects"], 0, pad)
        skew = [i for i in manifest["items"].values() if "bus_skew_measured" in i]
        self.assertTrue(skew)
        for item in skew:
            self.assertEqual(item["bus_skew_measured"], 1, item)
            self.assertEqual(item["bus_skew_report_source"],
                             "report_bus_skew -return_string")
        self.assertEqual(len(manifest["reports_sha256"]), len(review.GATE_REPORT_NAMES))
        produced = produced_fields("async_pad_hdmi_rx_5v_det")
        self.assertIn("endpoint_count", produced)
        for pad in pads:
            self.assertTrue(set(pad) <= set(produced) | {"probe_error"},
                            f"{pad} carries fields the producer does not declare")

    def test_frozen_round_manifest_is_still_untouched_and_unparsable(self):
        if not FROZEN_MANIFEST.exists():
            self.skipTest("round 26111202 evidence is a build artefact")
        with self.assertRaises(json.JSONDecodeError):
            json.loads(FROZEN_MANIFEST.read_text())


def code_only(text):
    """Code lines only: the hook documents the defects it fixes in comments."""
    return "\n".join(line for line in text.splitlines()
                      if not line.strip().startswith("#"))


class HookApiDisciplineTests(unittest.TestCase):
    """The hook must only ask the tool in ways 2023.2 documents."""

    def setUp(self):
        self.text = HOOK.read_text()
        self.code = code_only(self.text)

    def test_no_api_that_this_repository_already_misused(self):
        for bad in ("lmap ", "all_fanout -from", "report_property -object_filters",
                    "report_bus_skew -from", "report_bus_skew -to",
                    "get_cells -quiet -of $", "get_pins -quiet -of $",
                    "get_property REF_NAME $cells refs"):
            self.assertNotIn(bad, self.code, bad)

    def test_documented_forms_are_used(self):
        for good in ("all_fanout -flat -endpoints_only -only_cells",
                     "get_cells -quiet -of_objects",
                     "-return_string", "REF_PIN_NAME", "ASYNC_REG"):
            self.assertIn(good, self.code, good)

    def test_script_is_a_complete_tcl_program(self):
        proc = subprocess.run(["tclsh"], input="set f [open {%s}]; set d [read $f]; "
                              "close $f; puts \"info_complete=[info complete $d]\""
                              % HOOK, capture_output=True, text=True)
        self.assertIn("info_complete=1", proc.stdout, proc.stdout + proc.stderr)

    def test_bus_skew_fixture_is_the_round_report_shape(self):
        text = BUS_SKEW_FIXTURE.read_text()
        self.assertIn("2. Bus Skew Report Per Constraint", text)
        self.assertIn("Actual Bus Skew:", text)
        self.assertIn("Slack (MET) :", text)


class CallerScopeNameTests(ScenarioCase):
    """Round 26111204: the hook lives in its CALLER's scope, not its own.

    `source scripts/check_sc7f0_named_constraints.tcl` runs at level #0, so every
    array the hook creates is created in the calling session.  In the production
    flow that caller is scripts/impl_sc7f0_dual_video.tcl, whose top level runs
    `foreach a {Default Explore AggressiveExplore AddRetime
    ExploreWithAggressiveHoldFix}` (line 379) when SC7F0_POST_ROUTE_PHYS_OPT is
    set, leaving a global SCALAR named `a` behind (= "AggressiveExplore", printed
    as SC7F0_TIMING_TUNED at build/vcu-release-26111204-r1/fpga/project-logs/
    impl-vivado.log:3284).  The hook's per-item record array had the same name, so
    every `array set a` raised

        can't set "a(values)": variable isn't array

    inside the item's own `catch`, and 18 of that round's 20 items were written as
    "item query aborted" instead of measured (impl-vivado.log:5749-5808, and
    named-constraint-evidence.json hook_section_errors = 18).  These tests replay
    that caller scope: the colliding name must not cost a single measurement, and
    any other name the caller occupies must be REFUSED BY NAME instead of turning
    into bogus measurements.
    """

    ITEMS = ("probe_rxss_tlast_src_to_probe", "probe_rxss_tuser_src_to_probe",
             "probe_rxss_tvalid_src_to_probe", "probe_phy_ch0_tvalid_src_to_probe",
             "probe_phy_ch1_tvalid_src_to_probe", "probe_phy_ch2_tvalid_src_to_probe")

    def run_with_caller_scope(self, scalars, scenario="clean"):
        """Replay the caller's global scope, then run the stub which sources the
        hook at #0 (so the pollution is exactly where production puts it)."""
        tag = "caller-scope-" + "-".join(scalars)
        workdir = self.workdir / tag
        rdir = workdir / "reports"
        rdir.mkdir(parents=True, exist_ok=True)
        cwd = workdir / "cwd"
        cwd.mkdir(parents=True, exist_ok=True)
        driver = workdir / "caller-scope-driver.tcl"
        driver.write_text(
            "# the caller's own global scope, left behind by the top level of\n"
            "# scripts/impl_sc7f0_dual_video.tcl, then the stub (which sources the\n"
            "# hook with `uplevel #0`, exactly as the implementation hook does).\n"
            + "".join(f"set {name} AggressiveExplore\n" for name in scalars)
            + f"source {STUB}\n")
        env = dict(os.environ)
        env["SC7F0_STUB_SCENARIO"] = scenario
        env["SC7F0_REPORT_DIR"] = str(rdir)
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        proc = subprocess.run(["tclsh", str(driver)], cwd=cwd, env=env,
                              capture_output=True, text=True, timeout=180)
        log = proc.stdout + proc.stderr
        return workdir, rdir, cwd, driver, proc, log

    def test_the_caller_leaves_a_global_scalar_named_a(self):
        """Pins the evidence: the collision source is still the production flow."""
        text = (REPO / "scripts" / "impl_sc7f0_dual_video.tcl").read_text()
        self.assertIn("foreach a {Default Explore AggressiveExplore", text,
                      "if this loop is ever renamed, the 26111204 counterexample "
                      "below must be re-derived, not silently dropped")

    def test_a_colliding_caller_scalar_costs_no_measurement(self):
        workdir, rdir, cwd, driver, proc, log = self.run_with_caller_scope(["a"])
        self.assertNotIn("variable isn't array", log, log[-3000:])
        manifest_path = rdir / "named-constraint-evidence.json"
        self.assertTrue(manifest_path.is_file(), log[-3000:])
        raw = manifest_path.read_text()
        self.assertNotIn("variable isn't array", raw)
        manifest = json.loads(raw)
        self.assertEqual(0, manifest["hook_section_errors"], manifest["hook_problems"])
        self.assertEqual([], manifest["hook_problems"])
        self.assertEqual("PASS", manifest["hook_verdict"])
        # the six internal entries: real numbers, not the caller's string
        found = {i: v for i, v in manifest["items"].items()
                 if v.get("class") == "internal_async"}
        self.assertEqual(sorted(self.ITEMS), sorted(found))
        for item_id, record in found.items():
            self.assertEqual("", str(record.get("probe_error", "")), record)
            self.assertEqual(1, int(record["from_objects"]), record)
            self.assertEqual(1, int(record["to_objects"]), record)
            self.assertEqual(1, int(record["first_stage_async_reg"]), record)
            self.assertEqual("False Path", record["exception_type"], record)
            self.assertGreaterEqual(int(record["paths_analysed"]), 2, record)
        # a different record and a different loop (io_exception) is measured too,
        # i.e. the fix is not one lucky field in one loop
        for item_id in ("async_in_hdmi_tx_hpd_in", "async_in_hdmi_rx_ddc_scl_probe",
                        "async_in_hdmi_rx_5v_det_rxss"):
            record = manifest["items"][item_id]
            self.assertEqual("io_exception", record["class"], record)
            self.assertEqual("", str(record.get("probe_error", "")), record)
            self.assertGreaterEqual(int(record["to_objects"]), 1, record)
            self.assertGreaterEqual(int(record["first_stage_async_reg"]), 1, record)
        # and the pad-closure loop (a third record array) still measures too
        closure = [v for v in manifest["items"].values()
                   if v.get("class") == "pad_closure"]
        self.assertTrue(closure)
        for record in closure:
            self.assertEqual("", str(record.get("probe_error", "")), record)

    def test_a_caller_scalar_on_another_record_name_is_refused_by_name(self):
        """The guard must fail loudly, never default-pass."""
        for name in ("rec", "drec", "sc7f0_async_prop"):
            workdir, rdir, cwd, driver, proc, log = self.run_with_caller_scope([name])
            self.assertIn(f"SC7F0_NAMED_EVIDENCE_SCOPE_CONFLICT {name}", log,
                          f"{name}: {log[-2000:]}")
            self.assertNotEqual(0, proc.returncode,
                                f"{name}: the hook must not run on a colliding name")
            self.assertFalse((rdir / "named-constraint-evidence.json").is_file(),
                             f"{name}: a refused run must not leave a manifest "
                             "that could be graded as this round's coverage")


if __name__ == "__main__":
    unittest.main(verbosity=2)
