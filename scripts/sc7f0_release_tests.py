#!/usr/bin/env python3
"""Release unit-test gate: run the repo suite, fail on anything NEW.

The repository carries pre-existing failures that belong to other subsystems
(the NUC1262 MCU image artifacts, and the IP/.xci consistency tests that read a
Vivado output directory which no longer exists on this machine).  Silently
skipping them would weaken the release gate, and letting them block it would
hide real regressions behind noise.  So the suite is always run in full and the
verdict is comparative:

  * any test that fails without being listed in the baseline  -> gate FAILS;
  * any baseline test that suddenly passes                    -> gate FAILS
    (a stale baseline is itself a finding);
  * every baseline entry carries the reason it is tolerated.

Baseline: scripts/tests/RELEASE_TEST_BASELINE.json
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "scripts/tests/RELEASE_TEST_BASELINE.json"
CASE = re.compile(r"^(FAIL|ERROR): (\S+) \(([^)]+)\)")
SKIPPED = re.compile(r"^[a-zA-Z0-9_]+ \(([^)]+)\) ... skipped ")
RUN_LINE = re.compile(r"^[a-zA-Z0-9_]+ \(([^)]+)\) ... ")


def source_identity() -> dict:
    """Which bytes this test run judged.

    A green unit-test JSON is worthless if a later reader cannot tell whether it
    describes the round being shipped or some earlier tree, so every run records the
    same fingerprints scripts/sc7f0_release_id.py stamps the release with (computed by
    that module, never re-derived here). scripts/check_sc7f0_release_package.py then
    refuses a release whose unit-test evidence names other sources.
    """
    sys.path.insert(0, str(ROOT / "scripts"))
    import sc7f0_release_id as rid
    out: dict = {}
    for scope in ("all", "fpga", "ps"):
        fp = rid.source_fingerprint(ROOT, scope)
        key = ("source_fingerprint_sha256" if scope == "all"
               else scope + "_scope_fingerprint_sha256")
        out[key] = fp["source_fingerprint_sha256"]
        out[scope + "_fingerprint_files"] = fp["fingerprint_files"]
        out["git_head"] = fp["git_head"]
        out["worktree_dirty"] = fp["worktree_dirty"]
    return out


def run_suite() -> dict:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    proc = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"],
                          cwd=ROOT, capture_output=True, text=True, env=env)
    text = proc.stdout + proc.stderr
    bad = {}
    skipped, ran = set(), set()
    for line in text.splitlines():
        m = CASE.match(line)
        if m:
            bad[m.group(3)] = f"{m.group(1)}"
            continue
        s = SKIPPED.match(line)
        if s:
            skipped.add(s.group(1))
            continue
        r = RUN_LINE.match(line)
        if r:
            ran.add(r.group(1))
    summary = re.search(r"^(Ran \d+ tests.*|OK|FAILED.*)$", text, re.M)
    return {"returncode": proc.returncode, "summary": summary.group(1) if summary else "?",
            "failures": sorted(bad), "reasons": bad, "skipped": sorted(skipped),
            "ran": sorted(ran), "output_tail": text[-4000:]}


def main() -> int:
    out = None
    args = sys.argv[1:]
    require_run = []
    if "--out" in args:
        i = args.index("--out")
        out = Path(args[i + 1])
    if "--require-run" in args:
        i = args.index("--require-run")
        require_run = args[i + 1].split(",")
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {"tolerated": {}}
    result = run_suite()
    tolerated = baseline.get("tolerated", {})
    unexpected = [t for t in result["failures"] if t not in tolerated]
    stale = [t for t in tolerated if t not in result["failures"] and result["returncode"] == 0]
    # A gate that is silently skipped is not a gate. The release flow names the
    # checks that must really have executed with the inputs of this build.
    never_ran = []
    for needle in require_run:
        matched = [t for t in result["ran"] + result["failures"] if needle in t]
        if not matched:
            never_ran.append(needle + " (no test executed)")
        else:
            never_ran += [t for t in matched if t in result["skipped"]]
    result["require_run"] = require_run
    result["required_tests_not_executed"] = never_ran
    result["unexpected_failures"] = unexpected
    result["stale_baseline_entries"] = stale
    result["baseline_file"] = str(BASELINE)
    result["baseline_reasons"] = {t: tolerated[t] for t in sorted(tolerated) if t in result["failures"]}
    # Which sources this verdict was computed over, and exactly which tests were
    # tolerated rather than passed. The release gate re-checks both: the fingerprint
    # so an old round's green JSON cannot be reused, and the tolerated set so a
    # subsystem that is merely *out of scope* (the NUC1262 MCU image audit) can never
    # be read back as evidence that it was tested.
    sources_error = None
    try:
        result["sources"] = source_identity()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sources_error = f"{type(exc).__name__}: {exc}"
        result["sources"] = {"error": sources_error}
    result["tolerated"] = sorted(tolerated)
    result["verdict"] = ("UNIT_TESTS_GATE_PASS"
                         if not unexpected and not stale and not never_ran and not sources_error
                         else "UNIT_TESTS_GATE_FAIL")
    if sources_error:
        print("UNIT_TEST_SOURCES_UNIDENTIFIED " + sources_error, file=sys.stderr)
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2) + "\n")
    print(result["summary"])
    for t in unexpected:
        print("UNEXPECTED " + t + "  " + result["reasons"][t])
    for t in stale:
        print("STALE_BASELINE (now passing, remove from baseline) " + t)
    for t in never_ran:
        print("REQUIRED_TEST_NOT_EXECUTED " + t)
    print(result["verdict"] + f" tolerated={len(tolerated)} failures={len(result['failures'])} "
          f"skipped={len(result['skipped'])} ran={len(result['ran'])}")
    if result["verdict"] != "UNIT_TESTS_GATE_PASS" and "--report-only" not in args:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
