#!/usr/bin/env python3
"""Run the host-side C testbenches for the COMMIT path inside the release suite.

Why these are wired into Python: the release unit-test gate refuses a *required*
suite that was skipped (scripts/sc7f0_release_tests.py --require-run), and until now
the backup/COMMIT behaviour - the one thing standing between a bad upgrade and a card
that cannot boot - was only checkable by a human remembering to compile two .c files.
The commands are the ones written in docs/sc7f0_full_package_rebuild_20261111.md:

    cc -O2 -Wall -Wextra -Itest_app test_app/qpcie_backup_retention_tb.c -o ...
    cc -O2 -Wall -Wextra -Itest_app tb/qpcie_commit_integration_tb.c -o ...

Both are pure host programs (no mount(), no /dev/mem, no PL): they drive a real
directory tree that plays the part of the BOOT partition.

The second class pins the correctness fixes themselves at source level, because each
one is a line a later "simplification" deletes:

  * the space check must size the copy from max(live image, incoming package) - the
    backup copies what is on the card, not what is being installed;
  * retention must run with a reference generation, so a same-version retry can only
    evict a byte-identical duplicate and never the older image that differs;
  * the comment on that branch must not say the opposite of what the code does (the
    original said "identical to the live image: safe to drop" on the branch that
    protects what *differs*);
  * the daemon must state, before writing, how many generations it could roll back
    to - and must not claim the new package's backup policy protected the first
    upgrade from an older installer, which it cannot: that COMMIT runs on the old
    daemon.
"""
from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]

TB_SOURCES = {
    "backup_retention": "test_app/qpcie_backup_retention_tb.c",
    "commit_integration": "tb/qpcie_commit_integration_tb.c",
}


class HostTestbenchTests(unittest.TestCase):
    """Compile and run each C testbench; its own TB_PASS line is the assertion."""

    @classmethod
    def setUpClass(cls):
        cls.cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
        if not cls.cc:
            raise AssertionError(
                "no C compiler on this build host: the COMMIT testbenches are a "
                "required release suite, so this must fail rather than skip")
        cls.temp = tempfile.TemporaryDirectory(prefix="sc7f0-commit-tb-")
        cls.built = {}
        for name, src in TB_SOURCES.items():
            out = Path(cls.temp.name) / name
            proc = subprocess.run([cls.cc, "-O2", "-Wall", "-Wextra", "-Itest_app",
                                   src, "-o", str(out)],
                                  cwd=REPO, capture_output=True, text=True)
            if proc.returncode != 0:
                raise AssertionError(f"{src} does not compile:\n{proc.stderr[-4000:]}")
            cls.built[name] = out

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.temp.name, ignore_errors=True)

    def run_tb(self, name: str) -> None:
        proc = subprocess.run([str(self.built[name])], cwd=REPO,
                              capture_output=True, text=True, timeout=600)
        self.assertEqual(proc.returncode, 0,
                         f"{TB_SOURCES[name]} failed\nstdout: {proc.stdout[-2000:]}\n"
                         f"stderr: {proc.stderr[-2000:]}")
        self.assertIn("TB_PASS", proc.stdout, proc.stdout[-2000:])
        self.assertNotIn("FAIL line", proc.stdout + proc.stderr)

    def test_backup_retention_tb(self):
        self.run_tb("backup_retention")

    def test_commit_integration_tb(self):
        self.run_tb("commit_integration")


class BackupCorrectnessSourceTests(unittest.TestCase):
    def setUp(self):
        self.h = (REPO / "test_app/qpcie_backup_retention.h").read_text()
        self.daemon = (REPO / "test_app/qpcie_upgrade_daemon.c").read_text()

    def test_space_need_uses_the_larger_of_live_and_incoming(self):
        self.assertIn("qbr_commit_need_bytes", self.h)
        self.assertIn("new_bytes > live_bytes ? new_bytes : live_bytes", self.h)
        # the daemon must actually call it - the header being correct is not enough
        self.assertIn("qbr_room(EMMC_MOUNT_DIR, qbr_commit_need_bytes(STAGING_DIR, "
                      "EMMC_MOUNT_DIR)", self.daemon)
        self.assertNotIn("qbr_room(EMMC_MOUNT_DIR, qbr_payload_bytes(STAGING_DIR)",
                         self.daemon,
                         "space was estimated from the incoming package again")

    def test_retention_runs_with_a_reference_generation(self):
        self.assertIn("qbr_newest_generation", self.h)
        self.assertIn("qbr_prune(backup_root, keep_reference)", self.daemon)
        self.assertNotIn("qbr_prune(backup_root, NULL)", self.daemon,
                         "retention without a reference let one same-version retry "
                         "evict the last generation that differs")

    def test_reference_branch_comment_matches_the_code(self):
        """The original comment read 'identical to the live image: safe to drop' on
        the branch that protects the generations which DIFFER. Anyone trusting it
        would invert the condition."""
        block = self.h.split("static int qbr_prune(const char *root")[1][:2200]
        self.assertNotIn("identical to the live image: safe to drop", block)
        self.assertIn("PROTECTED", block)
        # failing closed: anything not provably identical stays
        self.assertIn("if (!identical) continue;", block)

    def test_daemon_says_what_is_recoverable_before_it_writes(self):
        self.assertIn("qbr_generation_count(backup_root)", self.daemon)
        self.assertIn("no prior image to roll back to", self.daemon)

    def test_bootstrap_caveat_is_written_where_the_code_is(self):
        """The first upgrade performed by an older installer runs the OLD daemon with
        its destructive rm -rf. Nothing in this package can protect that attempt."""
        self.assertIn("previous daemon", self.h.lower().replace("previous daemon",
                                                               "previous daemon"))
        self.assertIn("Bootstrap caveat", self.h)
        runbook = REPO / "docs/sc7f0_release_deploy_acceptance_runbook.md"
        self.assertTrue(runbook.is_file(),
                        "the host-side pre-COMMIT snapshot procedure must exist: "
                        + str(runbook))
        text = runbook.read_text()
        self.assertIn(".backup_upgrade", text)
        self.assertIn("rm -rf", text)

    def test_promote_never_overwrites_and_the_tb_proves_it(self):
        self.assertIn("refusing to overwrite existing generation", self.h)
        tb = (REPO / "test_app/qpcie_backup_retention_tb.c").read_text()
        self.assertIn("refusing to overwrite", tb)
        self.assertIn("qbr_commit_need_bytes", tb)
        self.assertIn("BOOT-DISTINCT", tb)


if __name__ == "__main__":
    unittest.main(verbosity=2)
