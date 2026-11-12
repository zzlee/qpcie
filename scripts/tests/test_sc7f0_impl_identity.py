#!/usr/bin/env python3
"""Run the Vivado identity procedures of scripts/impl_sc7f0_dual_video.tcl under tclsh.

The identity stamp is the reason a release can be named at all, and the procedures
that apply and verify it live in a Vivado-only script, so nobody ever ran them
outside a four-hour build - which is exactly how `incr -1 i` (Tcl reads that as
"increase the variable called -1 by i") survived long enough to abort a real
synthesis run after synthesis had already finished.

This test slices the pure-Tcl procedures out of the build script and exercises them
against a synthetic synthesis run directory: correct run script + run log pass, and
every way the identity can drift (stale version define, missing generic, synthesis
that never bound the parameter) must fail with SC7F0_IDENTITY_MISMATCH.

Needs only /usr/bin/tclsh, no Vivado and no licence.
"""
from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
IMPL = REPO / "scripts" / "impl_sc7f0_dual_video.tcl"
PROCS = ("sc7f0_identity_from_env", "sc7f0_apply_identity", "sc7f0_run_property",
         "sc7f0_require_stamp", "sc7f0_verify_identity", "sc7f0_record_identity")

# A completed synthesis run directory from this repository, if one is present. The
# procedures are checked against it as well as against synthetic records, because
# the whole point of the verifier is to read what Vivado really writes.
REAL_RUN = next(iter(sorted(REPO.glob("build/*-*/fpga/project"))), None)


def extract_procs() -> str:
    """Return the text of the named procs from the build script.

    Slicing (rather than duplicating) is deliberate: the test then always exercises
    the code the build actually runs. The slice ends at the first column-0 '}'.
    """
    text = IMPL.read_text()
    out = []
    for name in PROCS:
        m = re.search(r"^proc " + name + r" \{[^}]*\} \{$", text, re.M)
        if not m:
            continue
        end = text.index("\n}\n", m.start()) + 3
        out.append(text[m.start():end])
    return "\n".join(out)


def synth_dir(work: Path, version: str = "26111102", git: str = "D2253D57",
              date: str = "20261111", *, bind_version: bool = True,
              drop_generic: str | None = None) -> Path:
    """A synthesis run directory in the shape Vivado actually writes.

    Verified against build/vcu-release-26111102-r1: the version travels in
    `set_property generic C_VERSION=32'h..` (unbraced) and the two stamps in
    `set_property verilog_define {...} [current_fileset]`, alongside the profile
    define that identity stamping must preserve.
    """
    run = work / "qpcie_zu4ev_card.runs" / "synth_1"
    run.mkdir(parents=True, exist_ok=True)
    generics = ["C_VERSION=32'h" + version]
    defines = ["GIT_COMMIT_HASH_DEF=32'h" + git, "BUILD_TIMESTAMP_DEF=32'h" + date,
               "SC7F0_C2H_ONLY=1"]
    if drop_generic:
        generics = [g for g in generics if not g.startswith(drop_generic)]
        defines = [d for d in defines if not d.startswith(drop_generic)]
    lines = ["# Vivado synthesis run script (test fixture)"]
    if defines:
        lines.append("set_property verilog_define {" + " ".join(defines) +
                     "} [current_fileset]")
    for g in generics:
        lines.append("set_property generic " + g + " [current_fileset]")
    (run / "zu4ev_pcie_card_top.tcl").write_text("\n".join(lines) + "\n")
    dec = int(version, 16)
    log = ["Information: [Synth 8-5431] Parsing Verilog header file \"definesvh\"",
           "INFO: [Device 21-403] Loading part xcau20p-flva2104-2-i"]
    if bind_version:
        log.append("\tParameter C_VERSION bound to: %d - type: integer" % dec)
        log.append("\tParameter C_VERSION bound to: 32'b%s " % format(dec, "032b"))
    (run / "runme.log").write_text("\n".join(log) + "\n")
    return run


def run_tcl(body: str) -> subprocess.CompletedProcess:
    return subprocess.run(["/usr/bin/tclsh"], input=extract_procs() + "\n" + body,
                          capture_output=True, text=True, timeout=120)


def tcl_call(expr: str) -> subprocess.CompletedProcess:
    """Evaluate one Tcl expression, turning a raised error into a non-zero exit.

    tclsh reading a script from stdin behaves like an interactive shell: an error is
    printed and the process still exits 0. Without this wrapper every negative case
    here would look like a pass.
    """
    return run_tcl('if {[catch {%s} err]} { puts "CATCH: $err"; exit 1 } '
                   'else { puts "RESULT: $err"; exit 0 }' % expr)


class ImplIdentityTclTests(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="sc7f0-identity-tcl-"))

    def tearDown(self):
        shutil.rmtree(self.work, ignore_errors=True)

    def test_procs_are_extractable(self):
        src = extract_procs()
        for name in PROCS:
            if name == "sc7f0_apply_identity":
                continue          # needs Vivado's get_filesets; not testable in tclsh
            self.assertIn("proc " + name, src, name)

    def test_verifier_reads_a_real_synthesis_run(self):
        """Against this repository's own completed synth_1, if one exists."""
        if not REAL_RUN or not (REAL_RUN / "qpcie_zu4ev_card.runs" / "synth_1").is_dir():
            self.skipTest("no completed synthesis run directory in build/ to read")
        import json
        stamped = REAL_RUN / "version-identity.json"
        release_id = REAL_RUN.parent / "identity.json"
        if stamped.is_file():
            ident = json.loads(stamped.read_text())
            want = (ident["c_version"][2:], ident["git_commit_hash_register"][2:],
                    ident["build_timestamp_register"])
        elif (REAL_RUN.parent / "identity.json").is_file() or \
                (REAL_RUN.parent.parent / "identity.json").is_file():
            # synthesis finished but the build died before recording the identity:
            # the release record still states what the run was stamped with
            import json
            for cand in (REAL_RUN.parent / "identity.json",
                         REAL_RUN.parent.parent / "identity.json"):
                if cand.is_file():
                    ident = json.loads(cand.read_text())
                    break
            want = (ident["version"], ident["git_register_value"], ident["date"])
        else:
            self.skipTest("completed run carries no identity record to check against")
        r = tcl_call('sc7f0_verify_identity "%s" {%s %s %s}' % (REAL_RUN, *want))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("SC7F0_IDENTITY_VERIFIED", r.stdout)
        # and the same real artifacts must refuse a version they do not carry
        r = tcl_call('sc7f0_verify_identity "%s" {26110301 2BCE1D81 20261027}' % REAL_RUN)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("SC7F0_IDENTITY_MISMATCH", r.stdout + r.stderr)

    def test_verifier_notices_a_stale_register_next_to_a_correct_version(self):
        """The exact 2026-11-03 failure: right version, ten-day-old GIT register."""
        synth_dir(self.work, version="26111102", git="2BCE1D81")
        r = tcl_call('sc7f0_verify_identity "%s" {26111102 D2253D57 20261111}' % self.work)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("GIT_COMMIT_HASH_DEF", r.stdout + r.stderr)
        self.assertIn("2BCE1D81", r.stdout + r.stderr)

    def test_verifier_ignores_a_stamp_that_only_appears_in_a_comment(self):
        run = synth_dir(self.work, git="2BCE1D81")
        tcl = run / "zu4ev_pcie_card_top.tcl"
        tcl.write_text("# GIT_COMMIT_HASH_DEF=32'hD2253D57 BUILD_TIMESTAMP_DEF=32'h20261111\n"
                       + tcl.read_text())
        r = tcl_call('sc7f0_verify_identity "%s" {26111102 D2253D57 20261111}' % self.work)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("SC7F0_IDENTITY_MISMATCH", r.stdout + r.stderr)

    def test_build_script_is_syntactically_complete_tcl(self):
        """Cheap guard for the brace trap that lives in this file's own subject.

        A lone brace in a comment, or a braced regex word containing '}', silently
        ends a proc body early and only explodes when Vivado reaches it. `info
        complete` says so without running anything.
        """
        script = ('set fh [open "%s" r]; set t [read $fh]; close $fh\n'
                  'puts "FILE_COMPLETE [info complete $t]"\n' % IMPL)
        r = run_tcl(script)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("FILE_COMPLETE 1", r.stdout, r.stdout + r.stderr)
        text = IMPL.read_text()
        for name in PROCS:
            m = re.search(r"^proc " + name + r" \{[^}]*\} \{$", text, re.M)
            if not m:
                continue
            end = text.index("\n}\n", m.start()) + 2
            # the slice goes through a file, never through shell or Tcl quoting
            probe = self.work / (name + ".tcl")
            probe.write_text(text[m.start():end])
            r = run_tcl('set fh [open "%s" r]; set t [read $fh]; close $fh\n'
                        'puts "PROC_COMPLETE %s [info complete $t]"\n' % (probe, name))
            self.assertIn("PROC_COMPLETE " + name + " 1", r.stdout,
                          "%s body does not balance: %s" % (name, r.stdout + r.stderr))

    def test_no_broken_incr_or_set_in_the_build_script(self):
        # 'incr -1 i' parses as "incr the variable named -1 by i" and only fails at
        # run time, hours into a build. Catch the family statically.
        for lineno, line in enumerate(IMPL.read_text().splitlines(), 1):
            code = line.split("#")[0]
            self.assertNotIn("incr -", code, "line %d: %s" % (lineno, line.strip()))
            self.assertNotRegex(code, r"\bset\s+-?\d+\s+\w", "line %d: %s" % (lineno, line.strip()))
            self.assertNotRegex(code, r"\bexpr\s+\w\s*[\+\-]\s*1\s*i\b",
                                "line %d: %s" % (lineno, line.strip()))

    def test_identity_from_env_is_all_or_nothing(self):
        base = 'global env; unset -nocomplain env(SC7F0_VERSION) env(SC7F0_GIT_HASH) ' \
               'env(SC7F0_BUILD_DATE)\n'
        r = run_tcl(base + 'puts "[sc7f0_identity_from_env]"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "", "unset identity must mean 'stamp nothing'")
        r = tcl_call(base + 'set env(SC7F0_VERSION) 26111102; sc7f0_identity_from_env')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("together", r.stdout + r.stderr)
        r = tcl_call(base + 'set env(SC7F0_VERSION) 26111102; set env(SC7F0_GIT_HASH) '
                            'D2253D57; set env(SC7F0_BUILD_DATE) 20261111; '
                            'sc7f0_identity_from_env')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip(), "RESULT: 26111102 D2253D57 20261111")
        r = tcl_call(base + 'set env(SC7F0_VERSION) 26; set env(SC7F0_GIT_HASH) '
                            'D2253D57; set env(SC7F0_BUILD_DATE) 20261111; '
                            'sc7f0_identity_from_env')
        self.assertIn("8 hex digits", r.stdout)

    def test_verify_accepts_a_real_synthesis_record(self):
        synth_dir(self.work)
        r = tcl_call('sc7f0_verify_identity "%s" {26111102 D2253D57 20261111}' % self.work)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("SC7F0_IDENTITY_VERIFIED", r.stdout)

    def test_verify_rejects_a_stale_version(self):
        synth_dir(self.work, version="26110301")      # the archived project's version
        r = tcl_call('sc7f0_verify_identity "%s" {26111102 D2253D57 20261111}' % self.work)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("SC7F0_IDENTITY_MISMATCH", r.stdout + r.stderr)

    def test_verify_rejects_a_missing_generic(self):
        synth_dir(self.work, drop_generic="BUILD_TIMESTAMP_DEF")
        r = tcl_call('sc7f0_verify_identity "%s" {26111102 D2253D57 20261111}' % self.work)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("BUILD_TIMESTAMP_DEF", r.stdout + r.stderr)

    def test_verify_rejects_synthesis_that_never_bound_the_parameter(self):
        synth_dir(self.work, bind_version=False)
        r = tcl_call('sc7f0_verify_identity "%s" {26111102 D2253D57 20261111}' % self.work)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("never bound C_VERSION", r.stdout + r.stderr)

    def test_verify_demands_the_run_artifacts(self):
        r = tcl_call('sc7f0_verify_identity "%s" {26111102 D2253D57 20261111}' % self.work)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("identity proof missing", r.stdout + r.stderr)

    def test_record_identity_writes_the_record(self):
        synth_dir(self.work)
        r = tcl_call('sc7f0_record_identity "%s" {26111102 D2253D57 20261111} '
                     'dirty-content-fingerprint' % self.work)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # the procedure writes next to the run directory; accept any json it produced
        produced = list(self.work.rglob("*.json")) + list(self.work.rglob("*identity*"))
        self.assertTrue(produced, "no identity record was written: %s" % r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
