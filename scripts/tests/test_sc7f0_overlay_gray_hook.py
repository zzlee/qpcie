#!/usr/bin/env python3
"""The RGB profile must be able to produce its own Layer-B evidence.

What was wrong (found by review of the source, not by a failing build):

* ``scripts/check_sc7f0_timing.py`` grades Layer A (timing / check_timing / CDC /
  methodology / bus skew / DRC) and Layer B (the named-exception coverage manifest
  plus six more reports) out of ONE directory.
* The only producer of that chain was ``scripts/impl_sc7f0_dual_video.tcl``
  (report stage, hook ``source`` at the end), and the only script that calls it,
  ``scripts/build_sc7f0_dual_video_hw.sh``, pins ``SC7F0_PROFILE=full``.
* ``scripts/build_zu4ev.tcl`` - the entry an ``SC7F0_PROFILE=rgb_compositor`` route
  actually uses - wrote six reports, never wrote ``drc.rpt``, and never sourced
  ``scripts/check_sc7f0_named_constraints.tcl``.  An RGB round therefore answered its
  own gate with "missing DRC report" plus six "Layer B evidence report ... was never
  produced", and no amount of routing could have produced the coverage manifest.

These tests do not run Vivado.  They check the wiring, and they run the routed
re-check (``scripts/check_sc7f0_overlay_gray.tcl``) against a stubbed Vivado object
resolver (``scripts/tests/fixtures/overlay_gray_stub.tcl``) - NONPHYSICAL, and a PASS
from here is explicitly NOT routed coverage.  Its value is the negative direction:
the check has to refuse when the exception is absent, when the vendor's 1000 ns
fallback for a manually instantiated XPM is what is really in force, when a sampling
path is not a direct FF-to-FF, or when ``report_bus_skew`` has no row for it.
"""
from __future__ import annotations

import hashlib
import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / "scripts" / "build_zu4ev.tcl"
CHAIN = REPO / "scripts" / "report_sc7f0_implementation_evidence.tcl"
CHECK = REPO / "scripts" / "check_sc7f0_overlay_gray.tcl"
STUB = REPO / "scripts" / "tests" / "fixtures" / "overlay_gray_stub.tcl"
XDC_STUB = REPO / "scripts" / "tests" / "fixtures" / "overlay_gray_xdc_stub.tcl"
XDC = REPO / "constraints" / "sc7f0_overlay_gray.xdc"
HOOK = REPO / "scripts" / "check_sc7f0_named_constraints.tcl"
GATE = REPO / "scripts" / "check_sc7f0_timing.py"
LEGACY_IMPL = REPO / "scripts" / "impl_sc7f0_dual_video.tcl"


def run_stub(mode: str):
    proc = subprocess.run(["tclsh", str(STUB), mode, str(CHECK)],
                          capture_output=True, text=True, cwd=str(REPO))
    return proc.returncode, proc.stdout + proc.stderr


def run_xdc(mode: str):
    """NONPHYSICAL: drive the XDC's own guard through a stubbed object resolver."""
    proc = subprocess.run(["tclsh", str(XDC_STUB), mode, str(XDC)],
                          capture_output=True, text=True, cwd=str(REPO))
    return proc.returncode, proc.stdout + proc.stderr


class EvidenceChainIsWired(unittest.TestCase):
    """The hook must be reachable from the profile that needs it."""

    @classmethod
    def setUpClass(cls):
        cls.build = BUILD.read_text()
        cls.chain = CHAIN.read_text()

    def test_build_zu4ev_sets_the_report_dir_and_sources_the_chain(self):
        self.assertIn("set ::env(SC7F0_REPORT_DIR) [file normalize $project_dir]",
                      self.build)
        self.assertIn("source ./scripts/report_sc7f0_implementation_evidence.tcl",
                      self.build)

    def test_chain_sources_the_layer_b_producer_after_report_cdc(self):
        self.assertIn("source $sc7f0_ev_hook", self.chain)
        self.assertIn("check_sc7f0_named_constraints.tcl", self.chain)
        # the manifest binds itself to cdc.rpt by hash, so the order is load-bearing
        self.assertLess(self.chain.index("report_cdc -details"),
                        self.chain.index("source $sc7f0_ev_hook"))

    def test_every_report_the_gate_reads_is_written_by_the_chain(self):
        names = set(re.findall(r"'([\w.-]+\.rpt)'", GATE.read_text()))
        self.assertGreaterEqual(len(names), 11, names)
        missing = [n for n in sorted(names)
                   if ("-file $sc7f0_ev_out/" + n) not in self.chain]
        self.assertEqual([], missing,
                         "scripts/check_sc7f0_timing.py reads reports the shared "
                         "chain does not write")

    def test_reports_are_taken_once_not_twice(self):
        # the six reports this flow used to write inline are now produced by the
        # chain; leaving both would double the cost and let the flags drift apart
        for cmd in ("report_cdc", "report_methodology", "report_bus_skew",
                    "check_timing", "report_timing_summary"):
            self.assertNotIn(f"{cmd} -file $project_dir", self.build)
            self.assertNotIn(f"{cmd} -delay_type min_max -report_unconstrained "
                             f"-file $project_dir", self.build)

    def test_legacy_full_profile_entry_is_untouched(self):
        legacy = LEGACY_IMPL.read_text()
        self.assertIn("source scripts/check_sc7f0_named_constraints.tcl", legacy)
        self.assertIn("report_drc -file $out/drc.rpt", legacy)

    def test_chain_refuses_to_run_inside_a_proc(self):
        # the hook creates its record arrays in the caller's scope
        self.assertIn('if {[info level] != 0}', self.chain)


class OverlayGrayConstraintIsNamed(unittest.TestCase):
    """The writer's three 300 MHz Gray counters need their own named exception."""

    @classmethod
    def setUpClass(cls):
        cls.xdc = XDC.read_text()
        cls.build = BUILD.read_text()

    def test_xdc_names_both_endpoints_and_both_exception_kinds(self):
        self.assertIn("u_overlay_writer/u_(frames|beats|errf)/src_gray_ff_reg",
                      self.xdc)
        self.assertIn("dest_graysync_ff_reg\\[0\\]\\[[0-9]+\\]", self.xdc)
        self.assertIn("set_max_delay -datapath_only 3.333", self.xdc)
        self.assertIn("set_bus_skew 3.333", self.xdc)

    def test_nothing_is_false_pathed_or_grouped_away(self):
        for banned in ("set_false_path", "set_clock_groups", "set_clock_translation"):
            self.assertNotIn(banned, self.xdc)

    def test_period_is_the_real_source_period_not_the_vendor_fallback(self):
        # 300 MHz source => 3.333 ns; the vendor file's fallback is 1000 ns, which
        # would bound nothing.  The XDC has to say which one it is using.
        self.assertIn("1000", self.xdc)          # documented, as the thing avoided
        self.assertNotIn("set_max_delay -datapath_only 1000", self.xdc)

    def test_applied_only_for_the_profile_that_contains_the_writer(self):
        """The writer's Gray crossings are applied by full Tcl, not by a mounted .xdc.

        Measured, not theorised: mounting constraints/sc7f0_overlay_gray.xdc made the
        managed read_xdc reader drop its guard with
            [Designutils 20-1307] Command 'if' is not supported
        (rgb-fullimpl-26111333-20261113T204036Z logs/build_full26111333.log:3796-3797),
        i.e. the file stayed mounted, the guard vanished, and a -from/-to that
        resolves empty would have widened the exception to the whole device.  The
        substance of this test is unchanged - the application must be conditional on
        the profile that contains u_overlay_writer, and must not be silent - but it is
        now asserted on scripts/impl_pre_opt_sc7f0.tcl +
        scripts/apply_sc7f0_overlay_cdc.tcl, where a failed guard calls `error`.
        """
        self.assertNotIn("add_files -fileset constrs_1 ./constraints/sc7f0_overlay_gray.xdc",
                         self.build, "a guarded overlay XDC must not be mounted again")
        self.assertIn("STEPS.OPT_DESIGN.TCL.PRE [file normalize scripts/impl_pre_opt_sc7f0.tcl]",
                      self.build)
        pre = (REPO / "scripts" / "impl_pre_opt_sc7f0.tcl").read_text()
        self.assertIn("apply_sc7f0_overlay_cdc.tcl", pre)
        self.assertIn("SC7F0_RGB_COMPOSITOR", pre,
                      "the overlay application must be conditional on the RGB profile")
        apply_tcl = (REPO / "scripts" / "apply_sc7f0_overlay_cdc.tcl").read_text()
        self.assertIn("SC7F0_OVERLAY_GRAY_MISSING", apply_tcl,
                      "a crossing that does not resolve 32 sources and 32 first stages must stop the run")
        self.assertIn("set_bus_skew", apply_tcl)

    def test_routed_recheck_is_sourced_for_the_rgb_profile(self):
        self.assertIn("source ./scripts/check_sc7f0_overlay_gray.tcl", self.build)


class RoutedRecheckHasTeeth(unittest.TestCase):
    """NONPHYSICAL: the stub resolver proves the check cannot be satisfied by luck."""

    def test_compliant_fixture_passes(self):
        rc, out = run_stub("ok")
        self.assertEqual(0, rc, out)
        self.assertIn("STUB_VERDICT=PASS", out)
        self.assertIn("SC7F0_OVERLAY_GRAY_CHECK_PASS", out)

    def test_each_failure_mode_is_named_not_silent(self):
        for mode, code in (("missing_src", "SC7F0_OVERLAY_GRAY_MISSING"),
                           ("missing_dst", "SC7F0_OVERLAY_GRAY_MISSING"),
                           ("not_timed", "SC7F0_OVERLAY_GRAY_NOT_TIMED"),
                           ("swapped", "SC7F0_OVERLAY_GRAY_MAPPING"),
                           ("logic", "SC7F0_OVERLAY_GRAY_LOGIC"),
                           ("fallback_req", "SC7F0_OVERLAY_GRAY_NOT_EFFECTIVE"),
                           ("no_skew_row", "SC7F0_OVERLAY_GRAY_SKEW_UNMEASURED"),
                           ("skew_violated", "SC7F0_OVERLAY_GRAY_SKEW_VIOLATED")):
            rc, out = run_stub(mode)
            self.assertIn(code, out, f"{mode} did not raise its own error code")
            self.assertNotIn("CHECK_PASS", out, f"{mode} still reported a pass")

    def test_the_hook_itself_is_still_the_manifest_producer(self):
        # this file must not become a second, weaker manifest producer
        self.assertNotIn("named-constraint-evidence.json", CHECK.read_text())


class PreflightGuardAndReportNames(unittest.TestCase):
    """The LOW findings from the fresh review, all in the hook layer.

    NONPHYSICAL again: nothing here runs Vivado, and no PASS below is routed
    coverage.  What they do protect is the two ways a named exception can be worth
    nothing while the run still looks clean - a query that reads a report name no
    producer writes, and a ``-from``/``-to`` collection that resolved to nothing.
    """

    @classmethod
    def setUpClass(cls):
        cls.xdc = XDC.read_text()
        cls.build = BUILD.read_text()
        cls.hook = HOOK.read_text()

    def test_the_dpram_row_query_reads_the_name_the_producers_write(self):
        # both producers (impl_sc7f0_dual_video.tcl and the shared evidence chain)
        # write clock-networks.rpt; sc7f0_count returns -1 for a file that does not
        # exist, which used to land in the manifest as a count of a DPRAM row
        self.assertIn('sc7f0_count "$out_dir/clock-networks.rpt"', self.hook)
        self.assertNotIn("clock_networks.rpt", self.hook)
        # the replay harness and the unit fixture must ask for the same real name,
        # otherwise the hook is tested against a report no round ever produces
        self.assertNotIn("clock_networks.rpt",
                        (REPO / "scripts" / "replay_sc7f0_named_constraint_hook.tcl").read_text())
        self.assertIn('write clock-networks.rpt',
                      (REPO / "scripts" / "tests" / "fixtures" /
                       "named_constraints_stub.tcl").read_text())

    def test_the_xdc_refuses_to_apply_an_empty_collection(self):
        # an empty -from/-to is not "no constraint": the exception then covers every
        # endpoint of the device.  The guard has to run BEFORE either command.
        for probe in ("llength $sc7f0_ovw_s] != 32", "llength $sc7f0_ovw_d] != 32",
                      "llength $ovw_gray_src] != 96", "llength $ovw_gray_dst] != 96"):
            self.assertIn(probe, self.xdc, probe)
        self.assertLess(self.xdc.index('error "SC7F0_OVERLAY_GRAY_MISSING'),
                        self.xdc.index("\nset_max_delay -datapath_only 3.333"),
                        "the guard runs after the exception, which is too late")

    def test_the_guard_actually_fires_and_only_applies_when_named(self):
        # NONPHYSICAL: stub resolver, no implementation.  The point is the direction of
        # the failure, which no amount of post-route checking can repair.
        for mode in ("empty", "short", "union_only"):
            rc, out = run_xdc(mode)
            self.assertEqual(1, rc, f"{mode} was accepted: {out}")
            self.assertIn("SC7F0_OVERLAY_GRAY_MISSING", out, mode)
            self.assertIn("APPLIED 0", out,
                          f"{mode} still applied an exception over an empty or short collection")
        rc, out = run_xdc("good")
        self.assertEqual(0, rc, out)
        self.assertIn("APPLIED 2", out, out)
        self.assertIn("value=3.333 from=96 to=96", out, out)

    def test_the_comments_state_what_is_measured_and_what_is_not(self):
        # the vendor's scoped xpm_cdc_gray file does size itself from a clock on an IP
        # port with a documented 1000 ns fallback, but whether it attaches to a
        # hand-instantiated XPM was never established here, and neither is the old
        # claim that control flow is ignored inside XDC.
        self.assertIn("NOT established by this file", self.xdc)
        self.assertNotIn("Vivado ignores those commands in XDC", self.xdc)
        self.assertIn("DOES evaluate ordinary Tcl control flow", self.xdc)
        self.assertIn("the exception then applies over EVERY endpoint of the device", self.xdc)
        self.assertNotIn("where if/foreach are ignored", self.build)
        self.assertNotIn("so they fall\n    # back to 1000 ns", self.build)
        self.assertIn("not established here", self.build)

    def test_the_capture_gray_opt_pre_hook_still_runs_first(self):
        """The capture Gray check must still be the first thing OPT_DESIGN runs.

        STEPS.OPT_DESIGN.TCL.PRE now points at scripts/impl_pre_opt_sc7f0.tcl because
        the overlay application needed full Tcl (see the mount test); that wrapper may
        only ADD the overlay step after the capture check - it may not replace, reorder
        or re-implement it.  check_sc7f0_capture_gray.tcl itself is unmodified.
        """
        self.assertIn("STEPS.OPT_DESIGN.TCL.PRE [file normalize scripts/impl_pre_opt_sc7f0.tcl]",
                      self.build)
        pre = (REPO / "scripts" / "impl_pre_opt_sc7f0.tcl").read_text()
        self.assertIn("check_sc7f0_capture_gray.tcl", pre)
        self.assertIn("source", pre, "the wrapper must source the capture check, not re-implement it")
        self.assertLess(pre.index("check_sc7f0_capture_gray.tcl"),
                        pre.index("apply_sc7f0_overlay_cdc.tcl"),
                        "the capture Gray check runs before the overlay application")
        capture_path = REPO / "scripts" / "check_sc7f0_capture_gray.tcl"
        capture = capture_path.read_text()
        # Byte identity, not a keyword: this is the same hash the file carries in the
        # frozen input manifests of rounds 26111331/26111333/26111334/26111335
        # (hwsource-*.sha256), so the capture check that every one of those rounds
        # executed is the file on disk now.
        self.assertEqual(
            "6bdfad08bdff16eef9fbe0436524e116a410142679c1f806a9f783f5a1f13d3d",
            hashlib.sha256(capture.encode()).hexdigest(),
            "check_sc7f0_capture_gray.tcl must stay byte-identical to the version every "
            "measured round ran; the wrapper may only call it, not edit it")
        # Quantitative teeth, each one quoted from the file rather than summarised:
        self.assertIn("[llength $capture_gray_source] != 64", capture)
        self.assertIn('error "Expected exactly 64 Gray source FFs"', capture)
        self.assertIn('foreach tail {u_tap/u_source_time u_regs/u_time}', capture,
                      "both 64+64 Gray endpoint groups must still be checked")
        self.assertIn('error "Expected 64 Gray stage0 FFs: $tail"', capture)
        self.assertIn('error "Missing timed Gray endpoints: $tail"', capture)
        self.assertIn("-max_paths 64 -nworst 1", capture)
        self.assertIn('error "Gray bit mapping is not direct: $start -> $end"', capture,
                      "bit-for-bit gray_q_reg[n] -> stage0_reg[n] mapping is required")
        self.assertIn('error "Combinational logic in Gray sampling path: $start -> $end"', capture)
        self.assertIn("abs([get_property REQUIREMENT $path] - 6.000) > 0.001", capture,
                      "the 6.000 ns max delay must be measured in force on every endpoint")
        self.assertIn('error "Duplicate Gray endpoints: $tail"', capture)
        self.assertIn("SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS", capture)
        self.assertEqual(capture.count("error "), 7, capture.count("error "))


if __name__ == "__main__":
    unittest.main(verbosity=2)
