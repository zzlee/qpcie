#!/usr/bin/env python3
"""Release identity helper: version allocation, worktree fingerprint, manifest.

Why this exists
---------------
The 2026-11 releases shipped three physically different bitstreams under one
identity (Hardware Version 0x26110301 / GIT 0x2BCE1D81, a 2026-10-27 commit),
because the stamps were taken once at project-creation time and never bound to
the re-synthesis or to the source bytes.  The release entry point therefore
fixes one identity per attempt *before* Vivado runs, and records:

  * the allocated 8-digit hardware version (YYMMDDpp) - never reused, checked
    against every artifact directory, packaged tar name and version string that
    already appears in the repository, so a new build cannot silently re-use
    26111101 (the package currently on the test host);
  * a content fingerprint of the actual worktree, so an uncommitted fix is
    described as an uncommitted fix instead of masquerading as a clean HEAD;
  * which value the GIT register carries: the commit hash, or a fingerprint
    derived from the dirty worktree (never both, never ambiguous).

Offline and deterministic.  No hardware, no network.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Directories whose bytes end up in the FPGA bitstream, the PS image or the
# upgrade tooling; a change in any of them must change the fingerprint.
FINGERPRINT_PATHS = (
    "rtl", "constraints", "include", "test_app", "scripts", "tb", "driver",
    "petalinux/qpcie-zu4ev/project-spec",
)
# project-spec/configs is written *by* the PetaLinux stage (petalinux-config pins
# CONFIG_SUBSYSTEM_BOOTARGS_GENERATED, petalinux-build rewrites the file). It is
# hashed byte-for-byte into the PS build logs, so it is excluded here instead of
# being allowed to invalidate the release identity that the FPGA and PS stages
# were judged against.
FINGERPRINT_SKIP_PREFIXES = ("petalinux/qpcie-zu4ev/project-spec/configs/",)

# Release stages own different inputs, and they do not all freeze at the same
# moment: the PS/daemon/packaging sources are still being fixed while the
# multi-hour hardware run is in flight. One fingerprint for everything would
# either block that work or silently go stale, so each scope has its own.
SCOPES = {
    "fpga": ("rtl/", "constraints/", "include/", "tb/", "driver/",
             "scripts/"),
    "ps": ("test_app/", "petalinux/qpcie-zu4ev/project-spec/"),
}
SCOPE_EXCLUDE = {
    "fpga": ("scripts/tests/", "scripts/accept_", "scripts/package_",
             "scripts/deploy_", "scripts/build_sc7f0_matching_", "scripts/install_",
             "scripts/inject_", "scripts/run_", "scripts/sc7f0_release_tests.py",
             "scripts/check_sc7f0_upgrade_tar.py", "scripts/check_sc7f0_release",
             "scripts/check_sc7f0_capture_image.py", "scripts/check_sc7f0_memory_layout",
             "scripts/check_sc7f0_hdmi_dt.py", "scripts/check_sc7f0_vcu_devicetree.py",
             "scripts/check_sc7f0_ps_build_integrity.py", "scripts/check_sc7f0_r7",
             "scripts/check_sc7f0_full_profile.py", "scripts/check_sc7f0_mcu",
             "scripts/check_sc7f0_ps_watchdog_image.py", "scripts/check_sc7f0_bootbin",
             "scripts/accept_sc7f0_debug.py", "scripts/accept_sc7f0_rebind.py",
             "scripts/accept_sc7f0_vcu"),
    "ps": (),
}

# Files that MUST appear in a release source inventory.  `git ls-files -co
# --exclude-standard` follows .gitignore, so a required runner that an ignore
# pattern swallows simply vanishes from the fingerprint and from the snapshot -
# the reset/probe CDC sim had exactly that problem (`.gitignore` `sim_*`).
# Declaring them here turns "missing because ignored" into a hard error instead
# of a silently smaller release.
#
# The two groups mean different things and must not be merged:
#
#   fpga        bytes that physically shape the bitstream, plus the checkers and
#               review policy that grade the round.  These are frozen into
#               SOURCE_FPGA.sha256 and may not change after the freeze.
#   validation  sources nobody synthesises but without which a claim in this
#               release was never tested: the XSim gate runners, their
#               testbenches and the tests that prove the review gate bites.  A
#               negative control nobody can re-run is not evidence, so they are
#               as mandatory as the RTL - but they are frozen into
#               SOURCE_VALIDATION.sha256 and are allowed to be edited while the
#               hardware runs, which is exactly why they are a separate group.
REQUIRED_SOURCE_FILES = {
    "fpga": (
        "constraints/sc7f0_capture_gray.xdc",
        "constraints/sc7f0_async_io.xdc",
        "constraints/zu4ev_pcie_pinout.xdc",
        "scripts/check_sc7f0_capture_gray.tcl",
        "scripts/check_sc7f0_named_constraints.tcl",
        # The reset CDC XSim gate lives inside the fpga fingerprint scope (scripts/*.tcl
        # is not excluded there), so it is required in both groups: "fpga" because its
        # disappearance would silently shrink the fpga fingerprint that the bitstream
        # was graded against, "validation" because it must also appear in
        # SOURCE_VALIDATION.sha256, the manifest that says which evidence sources ship.
        "scripts/sim_sc7f0_reset_cdc.tcl",
        "scripts/impl_sc7f0_dual_video.tcl",
        "scripts/build_zu4ev.tcl",
        "scripts/check_sc7f0_timing.py",
        "scripts/sc7f0_review_policy.py",
        "scripts/gates/sc7f0_cdc_review.json",
        "scripts/gates/sc7f0_drc_review.json",
        "scripts/gates/sc7f0_clock_pair_review.json",
        "rtl/sc7f0_reset_cdc.v",
        "rtl/sc7f0_hdmi_probe.v",
    ),
    "ps": (),
    # Every name below exists in the repository today and is listed by
    # `git ls-files -co --exclude-standard`; the sim_* gitignore rule is relaxed
    # for exactly the two runners named here (.gitignore, section 2).  A handover
    # that invents a plausible runner name is worthless, so scripts/tests/
    # test_sc7f0_two_layer_gates.py::SourceInventoryTests asserts each of these
    # paths exists on disk - a required file that was renamed away is a finding,
    # not a green build.
    "validation": (
        "scripts/run_sc7f0_reset_probe_validation.sh",
        "scripts/sim_sc7f0_reset_cdc.tcl",
        "scripts/sim_sc7f0_probe_tap.tcl",
        "scripts/check_sc7f0_probe_tap_mutation.sh",
        "tb/sc7f0_reset_cdc_tb.sv",
        "tb/sc7f0_hdmi_probe_async_levels_tb.sv",
        "tb/sc7f0_hdmi_probe_tb.sv",
        "scripts/tests/test_sc7f0_reset_probe_structure.py",
        "scripts/tests/test_sc7f0_two_layer_gates.py",
        "scripts/tests/gate_fixtures.py",
        "scripts/tests/fixtures/named_constraints_stub.tcl",
        # The replay wrapper is what lets a constraint added after a round be
        # re-measured on that round's checkpoint without writing into delivered
        # evidence, so it is part of the evidence toolchain, not a scratch script.
        "scripts/replay_sc7f0_named_constraint_hook.tcl",
        "scripts/sc7f0_release_tests.py",
        "scripts/tests/RELEASE_TEST_BASELINE.json",
    ),
}

# Byte-for-byte inputs of the physical bitstream + the checkers that grade the
# round.  Moved out of the build script so the manifest, the release gate and the
# drift classifier cannot each carry their own slightly different list (the
# historical failure was a checker input that no manifest claimed, so editing it
# after the freeze looked like harmless tooling drift).
FPGA_INPUT_GLOBS = (
    "rtl/*", "constraints/*", "scripts/*.tcl", "scripts/gates/*.json",
    "scripts/generate_sc7f0_csr_cdc.py", "scripts/check_sc7f0_timing.py",
    "scripts/sc7f0_review_policy.py", "scripts/check_sc7f0_vcu_delta.py",
    "scripts/audit_sc7f0_cdc_delta.py", "scripts/check_sc7f0_capture_image.py",
    "scripts/check_sc7f0_memory_layout.py", "scripts/check_sc7f0_full_profile.py",
    "scripts/check_sc7f0_capture_gray.tcl", "scripts/check_sc7f0_named_constraints.tcl",
    "scripts/build_sc7f0_dual_video_hw.sh", "scripts/build_sc7f0_vcu_release.sh",
    "scripts/sc7f0_release_id.py",
)
# Host-side validation inputs (never synthesised, always required as evidence).
VALIDATION_SOURCE_GLOBS = (
    "scripts/run_sc7f0_reset_probe_validation.sh", "scripts/sim_sc7f0_reset_cdc.tcl",
    "scripts/sim_sc7f0_probe_tap.tcl", "scripts/check_sc7f0_probe_tap_mutation.sh",
    "tb/sc7f0_reset_cdc_tb.sv", "tb/sc7f0_hdmi_probe_async_levels_tb.sv",
    "tb/sc7f0_hdmi_probe_tb.sv", "scripts/tests/test_sc7f0_reset_probe_structure.py",
    "scripts/tests/test_sc7f0_two_layer_gates.py", "scripts/tests/gate_fixtures.py",
    "scripts/tests/fixtures/named_constraints_stub.tcl",
    "scripts/replay_sc7f0_named_constraint_hook.tcl",
    "scripts/sc7f0_release_tests.py", "scripts/tests/RELEASE_TEST_BASELINE.json",
)


def matches_globs(name: str, globs) -> bool:
    """Segment-wise glob matching: `*` never crosses a `/`.

    fnmatch's `*` does cross directory separators, which silently swept
    scripts/tests/fixtures/*.tcl into "scripts/*.tcl" and would have made editing a
    test fixture after the freeze a BITSTREAM_INPUT drift (a false FATAL, and a
    manifest that claimed fixtures were bitstream inputs). A role manifest has to say
    exactly what it means, so each pattern segment is matched against one path
    segment.
    """
    parts = name.split("/")
    for pattern in globs:
        segs = pattern.split("/")
        if len(segs) != len(parts):
            continue
        if all(fnmatch.fnmatch(s, p) for s, p in zip(parts, segs)):
            return True
    return False


def required_sources_missing(files, scope: str = "fpga") -> list[str]:
    """Pure helper: which required inputs are absent from an inventory list."""
    have = set(files)
    return [name for name in REQUIRED_SOURCE_FILES.get(scope, ()) if name not in have]

VERSION_RE = re.compile(r"\b(2[0-9]{7})\b")
# 8-digit SC7F0 hardware versions are YYMMDDpp and always start with the year
# (26 == 2026 today); VERSION_RE is narrowed by is_plausible_version().
DATE_SEQ_RE = re.compile(r"^(?P<y>\d{2})(?P<m>0[1-9]|1[0-2])(?P<d>0[1-9]|[12]\d|3[01])(?P<p>\d{2})$")


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=repo, check=True,
                          capture_output=True, text=True).stdout


def worktree_dirty(repo: Path) -> bool:
    return bool(git(repo, "status", "--porcelain", "--", *FINGERPRINT_PATHS).strip())


def scope_files(repo: Path, scope: str, require: bool = True) -> list[str]:
    """Files belonging to one release scope ('all', 'fpga' or 'ps')."""
    head = git(repo, "rev-parse", "HEAD").strip()
    files = sorted(p for p in git(repo, "ls-files", "-co", "--exclude-standard",
                                  "--", *FINGERPRINT_PATHS).split() if p)
    files = [f for f in files if not f.startswith(FINGERPRINT_SKIP_PREFIXES)]
    if scope == "all":
        selected = files
    else:
        keep = SCOPES[scope]
        drop = SCOPE_EXCLUDE[scope]
        selected = [f for f in files
                    if any(f.startswith(k) for k in keep)
                    and not any(f.startswith(d) for d in drop)]
    if require:
        # 'all' must contain the fpga inputs too, so check every scope the
        # selection is supposed to cover instead of trusting one scope's view.
        # 'validation' is only demanded of the complete snapshot: the fpga scope
        # deliberately excludes scripts/tests/, so requiring test files there would
        # make every FPGA re-verification fail for a reason that means nothing.
        for check_scope in ("fpga", "ps", "validation") if scope == "all" else (scope,):
            missing = required_sources_missing(selected, check_scope)
            if missing:
                raise ValueError(
                    "release source inventory is incomplete for scope "
                    f"{check_scope}: {', '.join(missing)} - a required input is "
                    "missing or hidden by .gitignore (add a precise '!path' "
                    "exception, never `git add -f` and never a broader ignore)")
    return selected


def source_inventory(repo: Path, scope: str = "all") -> dict:
    """The inventory itself, separately hashable from the bytes it names.

    A content fingerprint goes stale the moment anybody edits a file; the
    *inventory* hash answers a different question - did the release snapshot
    contain the set of inputs it claims to contain - and it is what lets a later
    reader prove that no checker, runner or testbench was quietly left out of
    SOURCE.sha256 to make a dirty tree look clean.
    """
    files = scope_files(repo, scope)
    h = hashlib.sha256()
    for rel in files:
        h.update((rel + "\n").encode())
    groups = {}
    for group, globs in (("fpga_physical_inputs", FPGA_INPUT_GLOBS),
                         ("validation_inputs", VALIDATION_SOURCE_GLOBS)):
        groups[group] = [f for f in files if matches_globs(f, globs)]
    return {"scope": scope, "files": len(files),
            "inventory_sha256": h.hexdigest(),
            "group_counts": {k: len(v) for k, v in groups.items()},
            "required_missing": {name: required_sources_missing(files, name)
                                 for name in REQUIRED_SOURCE_FILES}}


def source_fingerprint(repo: Path, scope: str = "all") -> dict:
    """sha256 over HEAD plus the exact bytes of every tracked/untracked input."""
    head = git(repo, "rev-parse", "HEAD").strip()
    files = scope_files(repo, scope)
    h = hashlib.sha256()
    h.update(("head=" + head + "\n").encode())
    for rel in files:
        path = repo / rel
        if not path.is_file():
            continue
        h.update(("file=" + rel + "\n").encode())
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    return {"git_head": head, "git_head_short8": head[:8].upper(),
            "worktree_dirty": worktree_dirty(repo),
            "scope": scope, "fingerprint_files": len(files),
            "source_fingerprint_sha256": h.hexdigest()}


def known_versions(repo: Path, extra: tuple[str, ...] = (),
                   exclude: tuple[Path, ...] = ()) -> dict[str, str]:
    """Every 8-digit version this repository already claims, with its reason.

    `exclude` is the release directory being created right now: its own name must
    not be counted as a collision, or the allocation would skip a slot for no
    reason other than having been chosen as the output directory.
    """
    known: dict[str, str] = {}

    def excluded(p: Path) -> bool:
        return any(p == e or e in p.parents or p in e.parents for e in exclude)

    def note(version: str, reason: str) -> None:
        known.setdefault(version, reason)

    def scan(glob: str):
        return [p for p in sorted(repo.glob(glob)) if not excluded(p)]

    for v in extra:
        note(v, "operator-supplied in-use version")
    for path in scan("build/*/VERSION"):
        v = path.read_text().strip()
        if VERSION_RE.fullmatch(v):
            note(v, f"build directory {path.parent.name}")
    for path in scan("build/**/upgrade-*.tar"):
        m = re.fullmatch(r"upgrade-(2[0-9]{7})\.tar", path.name)
        if m:
            note(m[1], f"packaged release {path}")
    for path in scan("build/*26*"):
        if not path.is_dir():
            continue        # a loose log file next to the build dirs is not an artifact
        m = re.search(r"(2[0-9]{7})", path.name)
        if m:
            note(m[1], f"artifact directory {path.name}")
    # Documents and scripts record the versions that were really flashed, which
    # is exactly the set a new build must not silently re-use.
    for path in sorted(list(repo.glob("docs/*.md")) + list(repo.glob("scripts/*.sh"))
                       + list(repo.glob("scripts/*.py"))):
        if excluded(path):
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for m in VERSION_RE.finditer(text):
            if is_plausible_version(m[1]):
                note(m[1], f"referenced by {path}")
    return known


def is_plausible_version(v: str) -> bool:
    m = DATE_SEQ_RE.fullmatch(v)
    if not m:
        return False
    return 2000 + int(m["y"]) <= 2099


def allocate_version(repo: Path, when: datetime, extra: tuple[str, ...] = (),
                     exclude: tuple[Path, ...] = ()) -> dict:
    """First unused YYMMDDpp for 'when', checked against every known artifact."""
    day = when.strftime("%y%m%d")
    taken = known_versions(repo, extra, exclude)
    # Revision numbering in this project starts at 01 (26102204, 26110301, ...);
    # 00 has never been used and is not handed out either.
    for seq in range(1, 100):
        candidate = f"{day}{seq:02d}"
        if candidate not in taken:
            return {"version": candidate, "date": when.strftime("%Y%m%d"),
                    "iso": when.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "collisions_avoided": {k: v for k, v in taken.items()
                                           if k.startswith(day)},
                    "known_version_count": len(taken)}
    raise ValueError(f"all 100 revision slots for {day} are already in use")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--out", type=Path, help="write identity JSON here")
    parser.add_argument("--version", default="", help="pin the 8-digit version instead of allocating")
    parser.add_argument("--known-version", action="append", default=[],
                        help="extra version that is already in use (repeatable)")
    parser.add_argument("--exclude", action="append", default=[],
                        help="path (e.g. the release directory being created) whose own "
                             "name must not count as a collision (repeatable)")
    parser.add_argument("--list-known", action="store_true")
    parser.add_argument("--scope", choices=("all", "fpga", "ps"), default="all",
                        help="which release scope the fingerprint covers")
    parser.add_argument("--check-fingerprint", metavar="IDENTITY_JSON",
                        help="exit non-zero unless the current worktree fingerprint, HEAD "
                             "and dirty state still match the recorded identity")
    args = parser.parse_args()
    repo = args.repo.resolve()

    exclude = tuple(Path(p).resolve() for p in args.exclude)
    if args.check_fingerprint:
        rec = json.loads(Path(args.check_fingerprint).read_text())
        field = {"all": "source_fingerprint_sha256",
                 "fpga": "fpga_scope_fingerprint_sha256",
                 "ps": "ps_scope_fingerprint_sha256"}[args.scope]
        if field not in rec:
            print(f"SOURCE_IDENTITY_UNCHECKABLE: {args.check_fingerprint} has no {field}",
                  file=sys.stderr)
            return 4
        cur = source_fingerprint(repo, args.scope)
        drift = {}
        if rec.get("git_head") != cur["git_head"]:
            drift["git_head"] = (rec.get("git_head"), cur["git_head"])
        if rec.get("worktree_dirty") != cur["worktree_dirty"]:
            drift["worktree_dirty"] = (rec.get("worktree_dirty"), cur["worktree_dirty"])
        if rec.get(field) != cur["source_fingerprint_sha256"]:
            drift[field] = (rec.get(field), cur["source_fingerprint_sha256"])
        if args.scope == "all" and "source_inventory_sha256" in rec:
            inv_now = source_inventory(repo, "all")["inventory_sha256"]
            if rec["source_inventory_sha256"] != inv_now:
                drift["source_inventory_sha256"] = (rec["source_inventory_sha256"], inv_now)
        if drift:
            print(f"SOURCE_IDENTITY_DRIFT ({args.scope} scope): the worktree changed after "
                  "this identity was allocated; the old fingerprint may not be reused",
                  file=sys.stderr)
            for k, (was, now) in drift.items():
                print(f"  {k}: recorded {was}  current {now}", file=sys.stderr)
            return 3
        print(f"SOURCE_IDENTITY_STABLE scope={args.scope} files={cur['fingerprint_files']} "
              f"{cur['source_fingerprint_sha256']} head {cur['git_head'][:8]} "
              f"dirty {cur['worktree_dirty']}")
        return 0

    if args.list_known:
        for v, why in sorted(known_versions(repo, tuple(args.known_version), exclude).items()):
            print(f"{v}  {why}")
        return 0

    # One fixed epoch per attempt: the version, the BUILD_TIMESTAMP register and
    # every log timestamp are derived from this instant.
    when = datetime.now(timezone.utc).astimezone()
    identity = allocate_version(repo, when, tuple(args.known_version), exclude)
    if args.version:
        v = args.version
        if not is_plausible_version(v):
            parser.exit(1, f"REFUSING {v}: not a YYMMDDpp version\n")
        taken = known_versions(repo, tuple(args.known_version), exclude)
        if v in taken and taken[v] != "operator-supplied in-use version":
            parser.exit(1, f"REFUSING {v}: already used by {taken[v]}\n")
        identity.update({"version": v, "date": "20" + v[:6], "allocated": False})
    identity["allocated"] = not args.version
    identity.update(source_fingerprint(repo, "all"))
    inv = source_inventory(repo, "all")
    identity["source_inventory_sha256"] = inv["inventory_sha256"]
    identity["source_inventory_files"] = inv["files"]
    # Provenance categories, stated where they are computed.  Nothing here claims
    # the validation sources shaped the bitstream; nothing here pretends they may
    # be omitted from the release either.
    identity["sources"] = {
        "inventory_sha256": inv["inventory_sha256"],
        "inventory_files": inv["files"],
        "group_counts": inv["group_counts"],
        "required_missing": {k: v for k, v in inv["required_missing"].items() if v},
        "frozen_manifests": {
            "SOURCE.sha256": "every input of every scope, untracked files included",
            "SOURCE_FPGA.sha256": "physical bitstream inputs + the checkers/policy "
                                  "that grade the round; byte-identical after the build",
            "SOURCE_VALIDATION.sha256": "host-side validation sources (XSim runners, "
                                        "testbenches, gate tests): not synthesised, "
                                        "required as evidence and hash-verifiable",
        },
        "rule": "a file that shapes the bitstream, grades the round or proves a "
                "claim must appear in one of the three manifests; excluding it from "
                "all three is drift concealment, not tooling work",
    }
    identity["fpga_scope_fingerprint_sha256"] = source_fingerprint(repo, "fpga")[
        "source_fingerprint_sha256"]
    identity["fpga_scope_files"] = source_fingerprint(repo, "fpga")["fingerprint_files"]
    identity["ps_scope_fingerprint_sha256"] = source_fingerprint(repo, "ps")[
        "source_fingerprint_sha256"]
    identity["ps_scope_files"] = source_fingerprint(repo, "ps")["fingerprint_files"]
    # The GIT register either names a real commit or is a content fingerprint of
    # a dirty worktree.  Claiming a clean commit while carrying uncommitted
    # changes is exactly the mislabelling this release flow must make impossible.
    if identity["worktree_dirty"]:
        identity["git_register_value"] = identity["source_fingerprint_sha256"][:8].upper()
        identity["git_register_source"] = "dirty-content-fingerprint"
    else:
        identity["git_register_value"] = identity["git_head_short8"]
        identity["git_register_source"] = "commit"
    text = json.dumps(identity, indent=2, sort_keys=True) + "\n"
    if args.out:
        if args.out.exists():
            parser.exit(1, f"REFUSING to overwrite {args.out}\n")
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
    print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
