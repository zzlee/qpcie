#!/usr/bin/env python3
"""Tests for the PS runtime byte-source resolver, plus the rules it replaced.

scripts/resolve_recipe_install_output.py exists because the PS stage used to prove
"the binary inside image.ub is this build's binary" with

    find petalinux/qpcie-zu4ev/build/tmp/work -name <binary> | head -1

which (a) picked by filesystem walk order when several builds existed and (b) fell
back to presence-only verification when it found nothing - which was always, because
bitbake deletes the recipe's $D after packaging. The measured consequence: the
shipped image carried a pre-0x800 mailbox qpcie_debugd and every gate said OK.

These tests build the trees instead of trusting a live one, so they always run:

  * one install output            -> RESOLVED, with its digest;
  * two different outputs         -> AMBIGUOUS (never resolved by picking one);
  * none                          -> UNRESOLVED, and the CLI exits non-zero;
  * a documented --allow-present  -> PRESENT_ONLY *and* listed in presence_only, so
                                     scripts/check_sc7f0_release_package.py can see
                                     the exception and refuse or report it;
  * --allow-present for a binary nobody asked about -> argument error;
  * OE packagedata FILES_INFO     -> parsed into (path, size), ambiguity detected;
  * a host-compiled (non-ARM64) cross-build -> refused, because comparing the image
                                               against an x86 binary proves nothing.

The second class pins the *source-level* rules: the PS build script must not go back
to `find ... | head-1` / `@present`, and qpcie_debugd must keep the ABI banner that
makes the 0x800 claim checkable inside the shipped bytes.
"""
from __future__ import annotations

import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import resolve_recipe_install_output as resolver  # noqa: E402

ARM64_HEADER = (b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9 + (2).to_bytes(2, "little")
                + (183).to_bytes(2, "little") + b"\0" * 40)
X86_HEADER = (b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9 + (2).to_bytes(2, "little")
              + (62).to_bytes(2, "little") + b"\0" * 40)


def write_exec(path: Path, body: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def packagedata(root: Path, machine: str, pn: str, files: dict, packaged: bool = True):
    d = root / "build/tmp/pkgdata" / machine / "runtime"
    d.mkdir(parents=True, exist_ok=True)
    body = f"PN: {pn}\nPV: 1.0\nPR: r0\n"
    body += "FILES_INFO:%s: %s\n" % (pn, files)
    (d / (pn + (".packaged" if packaged else ""))).write_text(body)


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sc7f0-ps-runtime-sources-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_a_single_packaged_install_output_is_resolved(self):
        packagedata(self.root, "mach-x", "sc7f0-vcud",
                    {"/usr/bin/sc7f0_vcud": len(ARM64_HEADER) + 3})
        rec = resolver.resolve_recipe(self.root / "build/tmp/pkgdata", "sc7f0_vcud",
                                      "sc7f0-vcud")
        self.assertEqual(rec["status"], "RESOLVED", rec)
        self.assertEqual(rec["install_path"], "usr/bin/sc7f0_vcud")
        self.assertEqual(rec["size"], len(ARM64_HEADER) + 3)

    def test_two_different_packaged_sizes_are_ambiguous_not_chosen(self):
        """The old code took `head -1`; two machines disagreeing is a finding."""
        packagedata(self.root, "mach-a", "sc7f0-vcud", {"/usr/bin/sc7f0_vcud": 100})
        packagedata(self.root, "mach-b", "sc7f0-vcud", {"/usr/bin/sc7f0_vcud": 200})
        rec = resolver.resolve_recipe(self.root / "build/tmp/pkgdata", "sc7f0_vcud",
                                      "sc7f0-vcud")
        self.assertEqual(rec["status"], "AMBIGUOUS", rec)
        self.assertIn("different sizes", rec["reason"])

    def test_missing_packagedata_is_unresolved(self):
        packagedata(self.root, "mach-x", "other-recipe", {"/usr/bin/other": 10})
        rec = resolver.resolve_recipe(self.root / "build/tmp/pkgdata", "sc7f0_vcud",
                                      "sc7f0-vcud")
        self.assertEqual(rec["status"], "UNRESOLVED", rec)
        self.assertIn("packagedata", rec["reason"])

    def test_malformed_files_info_fails_closed_rather_than_executing(self):
        d = self.root / "build/tmp/pkgdata/mach-x/runtime"
        d.mkdir(parents=True)
        (d / "sc7f0-vcud").write_text("PN: sc7f0-vcud\nFILES_INFO:sc7f0-vcud: __import__('os')\n")
        rec = resolver.resolve_recipe(self.root / "build/tmp/pkgdata", "sc7f0_vcud",
                                      "sc7f0-vcud")
        self.assertEqual(rec["status"], "UNRESOLVED", rec)
        self.assertIn("unreadable FILES_INFO", rec["reason"])

    def test_cross_build_must_be_arm64(self):
        write_exec(self.root / "test_app/qpcie_debugd", X86_HEADER + b"x86")
        rec = resolver.resolve_cross_build(self.root, "qpcie_debugd",
                                           "test_app/qpcie_debugd", require_arm64=True)
        self.assertEqual(rec["status"], "UNRESOLVED", rec)
        self.assertIn("ARM64", rec["reason"])

    def test_cross_build_records_its_digest(self):
        write_exec(self.root / "test_app/qpcie_debugd", ARM64_HEADER + b"arm")
        rec = resolver.resolve_cross_build(self.root, "qpcie_debugd",
                                           "test_app/qpcie_debugd", require_arm64=True)
        self.assertEqual(rec["status"], "RESOLVED", rec)
        self.assertEqual(rec["size"], len(ARM64_HEADER) + 3)
        self.assertRegex(rec["sha256"], r"^[0-9a-f]{64}$")

    def test_absent_cross_build_is_unresolved(self):
        rec = resolver.resolve_cross_build(self.root, "qpcie_debugd",
                                           "test_app/qpcie_debugd", require_arm64=True)
        self.assertEqual(rec["status"], "UNRESOLVED", rec)


class CliTests(unittest.TestCase):
    """The CLI is what the build script runs, so its exit codes are the gate."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sc7f0-ps-runtime-cli-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "petalinux/qpcie-zu4ev"
        (self.project / "build/tmp").mkdir(parents=True)
        self.out = self.root / "out.json"
        self.shell = self.root / "out.sh"

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(REPO / "scripts/resolve_recipe_install_output.py"),
             "--project", str(self.project), "--repo", str(self.root),
             "--json", str(self.out), "--shell", str(self.shell), *args],
            cwd=REPO, capture_output=True, text=True)

    def test_unresolved_runtime_fails_the_run(self):
        proc = self.run_cli("--recipe", "sc7f0_vcud=sc7f0-vcud")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("RUNTIME_BYTE_SOURCE_UNRESOLVED", proc.stderr)
        report = json.loads(self.out.read_text())
        self.assertEqual(report["binaries"][0]["status"], "UNRESOLVED")

    def test_presence_only_must_be_documented_and_is_reported(self):
        proc = self.run_cli("--recipe", "sc7f0_vcud=sc7f0-vcud",
                            "--allow-present", "sc7f0_vcud=fixture only")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        report = json.loads(self.out.read_text())
        self.assertEqual(report["presence_only"], ["sc7f0_vcud"])
        self.assertEqual(report["binaries"][0]["present_allowed_reason"], "fixture only")
        self.assertIn("sc7f0_vcud=@present", self.shell.read_text())

    def test_allow_present_for_an_unrequested_binary_is_an_argument_error(self):
        proc = self.run_cli("--recipe", "sc7f0_vcud=sc7f0-vcud",
                            "--allow-present", "qpcie_debugd=leftover from an old call")
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("not in --names", proc.stderr + proc.stdout)

    def test_resolved_cross_build_is_emitted_as_a_byte_comparison(self):
        write_exec(self.root / "test_app/qpcie_upgrade_daemon", ARM64_HEADER + b"daem")
        proc = self.run_cli("--cross-build",
                            "qpcie_upgrade_daemon=test_app/qpcie_upgrade_daemon")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        shell = self.shell.read_text()
        self.assertIn("--expect-binary", shell)
        self.assertIn("qpcie_upgrade_daemon=", shell)
        self.assertNotIn("@present", shell)

    def test_recipe_runtime_emits_the_packagedata_size(self):
        packagedata(self.project, "mach-x", "sc7f0-vcud", {"/usr/bin/sc7f0_vcud": 4242})
        proc = self.run_cli("--recipe", "sc7f0_vcud=sc7f0-vcud")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("--expect-size usr/bin/sc7f0_vcud=4242", self.shell.read_text())


class PsBuildScriptRulesTests(unittest.TestCase):
    """Pin the rules in the file that had them, so a later 'simplification' fails."""

    def setUp(self):
        self.ps = (REPO / "scripts/build_sc7f0_matching_ps_vcu.sh").read_text()

    def test_no_find_head_one_for_in_image_binaries(self):
        self.assertNotIn("-name \"$1\" \\\n", self.ps)
        for line in self.ps.splitlines():
            if line.lstrip().startswith("#"):
                continue          # the comment explaining why this is forbidden
            if "find" in line and "head -1" in line:
                self.fail("in-image binary resolved by walk order again: " + line)

    def test_no_silent_present_fallback(self):
        self.assertNotIn('"$1=@present"', self.ps,
                         "presence-only fallback is back; it is what hid the pre-0x800 "
                         "qpcie_debugd")

    def test_the_resolver_is_called(self):
        self.assertIn("resolve_recipe_install_output.py", self.ps)
        self.assertIn("rootfs-binary-sources.json", self.ps)

    def test_debugd_abi_string_is_required_inside_the_image(self):
        self.assertIn("--expect-string 'usr/bin/qpcie_debugd=qpcie_debugd mailbox "
                      "ABI h2c=0x800'", self.ps)

    def test_daemon_byte_sources_are_tied_to_the_recorded_sha(self):
        self.assertIn("production-daemons.sha256", self.ps)
        self.assertIn("DAEMON_BYTE_SOURCES_MATCH_RECORDED_SHA", self.ps)

    def test_kernel_evidence_is_exported_for_the_capture_audit(self):
        """scripts/check_sc7f0_capture_image.py reads images/kernel.config and
        images/kernel.System.map; nothing in the VCU flow used to write them."""
        self.assertIn("kernel.System.map", self.ps)
        self.assertIn("KERNEL_EVIDENCE", self.ps)


class DebugdAbiTests(unittest.TestCase):
    def setUp(self):
        self.src = (REPO / "test_app/qpcie_debugd.c").read_text()
        self.header = (REPO / "include/qpcie_debug.h").read_text()

    def test_header_still_describes_the_0x800_window(self):
        self.assertIn("#define DB_H2C_DATA     0x800", self.header)
        self.assertIn("#define DB_C2H_DATA     0x1000", self.header)

    def test_banner_exists_and_is_compile_time_guarded(self):
        self.assertIn("qpcie_debugd mailbox ABI h2c=", self.src)
        self.assertIn("#if DB_H2C_DATA != 0x800 || DB_C2H_DATA != 0x1000", self.src)
        self.assertIn("__attribute__((used))", self.src)

    def test_package_gate_still_looks_for_the_retention_literal(self):
        ps = (REPO / "scripts/build_sc7f0_matching_ps_vcu.sh").read_text()
        daemon = (REPO / "test_app/qpcie_upgrade_daemon.c").read_text()
        needle = "COMMIT: refused, no room for a backup generation"
        self.assertIn(needle, ps)
        self.assertIn(needle, daemon)


if __name__ == "__main__":
    unittest.main(verbosity=2)
