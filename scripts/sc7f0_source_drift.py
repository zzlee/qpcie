#!/usr/bin/env python3
"""Classify drift between a frozen release snapshot and the current worktree.

Why this exists: a long Vivado build runs for hours while the PS image, the
packaging tools and the daemon are still being fixed. That is only acceptable if
everyone can see, afterwards, exactly which bytes went into the bitstream and which
did not. This tool answers that from the release directory alone:

  frozen per-file manifest  <release>/SOURCE.sha256            (preflight)
  bitstream input manifests <release>/SOURCE_FPGA.sha256  (release entry freeze)
                            <release>/fpga/project-logs/SOURCE_RTL.sha256   (hw stage)
                            <release>/fpga/project-logs/SOURCE_BUILD.sha256 (hw stage)

Every difference is classified:

  BITSTREAM_INPUT_*  a file that the build actually consumed changed, or a new file
                     appeared where the build's file glob would have picked it up on
                     the next run. The release can no longer be re-produced from this
                     tree -> the only correct answer is a new full build, not a
                     re-recorded fingerprint.
  PS_INPUT_*         test_app/ and petalinux/qpcie-zu4ev/project-spec/, which the PS
                     stage freezes separately into ps/identity-ps.json.
  TOOLING_*          release/verification tooling that is neither of the above.

Nothing here ever rewrites a manifest; it only reports. Exit code is non-zero when
bitstream inputs drifted.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sc7f0_release_id as rid  # the release identity scope rules, imported, never copied

SCOPES = {
    "fpga": ("rtl/", "constraints/", "include/", "tb/", "driver/", "scripts/"),
    "ps": ("test_app/", "petalinux/qpcie-zu4ev/project-spec/"),
}
OTHER_SCOPE = ("scripts/", "docs/", "tb/", "Makefile")


def scope_of(path: str) -> str:
    for name, prefixes in SCOPES.items():
        if path.startswith(prefixes):
            return name
    return "other"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def current_tree(root: Path) -> dict[str, str]:
    """Exactly the file set the preflight freeze hashed: the release identity tool's
    own scope list, so the two sides can never drift apart by construction."""
    return {name: sha(root / name) for name in rid.scope_files(root, "all")
            if (root / name).is_file()}


def load_manifest(path: Path) -> dict[str, str]:
    table = {}
    if not path.is_file():
        return table
    for line in path.read_text().splitlines():
        digest, _, name = line.partition("  ")
        if name:
            table[name.strip().lstrip("*")] = digest.strip()
    return table


def interpret(release: Path, verdict: str, verify: dict) -> dict:
    """Say what a verdict means for THIS directory, because FATAL reads differently
    when the round never produced a bitstream.

    A FATAL verdict always blocks packaging. But for a round that the strict gate
    stopped before write_hw_principal, nothing built can have lost its provenance -
    there is no artifact to be untraceable - whereas for a round that did export an
    XSA/bit, FATAL means those bytes are no longer reproducible and must be rebuilt.
    """
    artifacts = {name: (release / rel).is_file()
                 for name, rel in (("hardware_xsa", "fpga/hardware.xsa"),
                                   ("bitstream", "fpga/zu4ev_pcie_card_top.bit"),
                                   ("boot_bin", "images/BOOT.BIN"),
                                   ("image_ub", "images/image.ub"))}
    built = [name for name, seen in artifacts.items() if seen]
    mismatched = {k: v["mismatched_or_missing"] for k, v in verify.items()
                  if v["mismatched_or_missing"]}
    if verdict == "SOURCE_DRIFT_BITSTREAM_FATAL" and not built:
        meaning = ("BLOCKS PACKAGING, and there is no artifact whose provenance is in "
                   "question: this round exported no XSA/bit/BOOT.BIN/image.ub, so the "
                   "manifests describe a build that was never completed. The fix is a "
                   "new frozen round that records the current versions of these files, "
                   "not a re-hash of this one.")
    elif verdict == "SOURCE_DRIFT_BITSTREAM_FATAL":
        meaning = ("BLOCKS PACKAGING: artifacts " + ", ".join(built) + " exist but this "
                   "tree can no longer reproduce them. Rebuild in a new round.")
    elif verdict == "SOURCE_DRIFT_TOOLING_ONLY":
        meaning = ("Packaging may proceed; the release must carry this record so it "
                   "states what changed after its own freeze.")
    else:
        meaning = "Worktree matches the frozen release inputs."
    return {"artifacts_present": artifacts, "round_exported_anything": bool(built),
            "manifests_with_mismatch": mismatched, "meaning": meaning}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    release = args.release.resolve()
    root = Path.cwd()          # run from the repository root, like every other gate

    frozen = load_manifest(release / "SOURCE.sha256")
    if not frozen:
        print("no frozen per-file manifest in " + str(release), file=sys.stderr)
        return 2
    bitstream = {}
    for m in [release / "SOURCE_FPGA.sha256",
              release / "fpga/project-logs/SOURCE_RTL.sha256",
              release / "fpga/project-logs/SOURCE_BUILD.sha256"]:
        found = load_manifest(m)
        if not found:
            print("MISSING_BITSTREAM_MANIFEST " + str(m), file=sys.stderr)
            return 2
        bitstream.update({k: v for k, v in found.items()})
    now = current_tree(root)

    # 1. authoritative re-check: does the tree still hash to the build's own lists?
    verify = {}
    for label, table in (("SOURCE_FPGA.sha256", load_manifest(release / "SOURCE_FPGA.sha256")),
                         ("fpga/project-logs/SOURCE_RTL.sha256",
                          load_manifest(release / "fpga/project-logs/SOURCE_RTL.sha256")),
                         ("fpga/project-logs/SOURCE_BUILD.sha256",
                          load_manifest(release / "fpga/project-logs/SOURCE_BUILD.sha256"))):
        bad = [n for n, d in table.items() if now.get(n) != d]
        verify[label] = {"files": len(table), "mismatched_or_missing": bad}

    changed = {n: (frozen[n], now[n]) for n in sorted(frozen) if n in now and now[n] != frozen[n]}
    added = sorted(n for n in now if n not in frozen)
    # The preflight snapshot hashes the whole project-spec tree, while the release
    # identity deliberately skips petalinux/.../configs/ because petalinux-config and
    # petalinux-build rewrite those files themselves (they are hashed into the PS
    # build logs instead). Sorting "missing" from "excluded by policy" keeps the two
    # from being confused - a policy exclusion is documented, a removal is not.
    missing = sorted(n for n in frozen if n not in now)
    policy_excluded, removed = [], []
    for name in missing:
        if (root / name).is_file():
            policy_excluded.append(name)
        else:
            removed.append(name)

    buckets: dict[str, list[str]] = {
        "BITSTREAM_INPUT_CHANGED": sorted(n for n in changed if n in bitstream),
        "BITSTREAM_INPUT_REMOVED": sorted(n for n in removed if n in bitstream),
        "NEW_BITSTREAM_SHAPED_FILE": sorted(n for n in added
                                            if n.startswith(("rtl/", "constraints/"))),
        "PS_INPUT_CHANGED": sorted(n for n in changed if scope_of(n) == "ps"),
        "PS_INPUT_ADDED": sorted(n for n in added if scope_of(n) == "ps"),
        "PS_INPUT_REMOVED": sorted(n for n in removed if scope_of(n) == "ps"),
        "POLICY_EXCLUDED_FROM_IDENTITY_STILL_ON_DISK": policy_excluded,
        "TOOLING_CHANGED": sorted(n for n in changed if scope_of(n) not in ("ps",)
                                  and n not in bitstream),
        "TOOLING_ADDED": sorted(n for n in added if n not in bitstream
                                and not n.startswith(("rtl/", "constraints/"))
                                and scope_of(n) != "ps"),
        "TOOLING_REMOVED": sorted(n for n in removed
                                  if n not in bitstream and not n.startswith(("rtl/", "constraints/"))
                                  and scope_of(n) != "ps"),
    }
    fatal = (buckets["BITSTREAM_INPUT_CHANGED"] + buckets["BITSTREAM_INPUT_REMOVED"]
             + buckets["NEW_BITSTREAM_SHAPED_FILE"])
    any_verify_fail = [k for k, v in verify.items() if v["mismatched_or_missing"]]
    verdict = ("SOURCE_DRIFT_BITSTREAM_FATAL" if fatal or any_verify_fail
               else "SOURCE_DRIFT_TOOLING_ONLY" if any(buckets.values()) else "SOURCE_DRIFT_CLEAN")

    # Scope identities are recomputed with scripts/sc7f0_release_id.py itself, i.e.
    # with the same exclusions the release was judged by at preflight. Those
    # exclusions only ever cover release/verification tooling; the bitstream inputs
    # are re-hashed byte for byte above and are never excluded from anything.
    identity = {}
    p = release / "identity.json"
    if p.is_file():
        ident = json.loads(p.read_text())
        for scope in ("all", "fpga", "ps"):
            fresh = rid.source_fingerprint(root, scope)
            recorded = ident.get("source_fingerprint_sha256" if scope == "all"
                                 else scope + "_scope_fingerprint_sha256")
            identity[scope] = {"recorded_at_preflight": recorded,
                               "now": fresh["source_fingerprint_sha256"],
                               "files": fresh["fingerprint_files"],
                               "stable": recorded == fresh["source_fingerprint_sha256"]}

    report = {
        "release": str(release),
        "frozen_manifest_files": len(frozen),
        "bitstream_input_manifest_files": len(bitstream),
        "manifest_reverification": verify,
        "drift": buckets,
        "scope_identity_now_vs_preflight": identity,
        "verdict": verdict,
        "rule": "BITSTREAM_INPUT_* or a failing manifest re-verification means this "
                "tree no longer reproduces the built bitstream; the release must be "
                "rebuilt in a new round instead of re-recording a fingerprint.",
        "interpretation": interpret(release, verdict, verify),
    }
    text = json.dumps(report, indent=2) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(text)
    for k, v in buckets.items():
        if v:
            print(f"{k} {len(v)}")
            for n in v[:12]:
                print("    " + n)
            if len(v) > 12:
                print("    ... %d more" % (len(v) - 12))
    for label, res in identity.items():
        print("SCOPE_IDENTITY %-5s recorded=%s now=%s files=%d %s" % (
            label, str(res["recorded_at_preflight"])[:12], res["now"][:12], res["files"],
            "STABLE" if res["stable"] else "DRIFT"))
    for label, res in verify.items():
        print("MANIFEST_VERIFY %s files=%d %s" % (
            label, res["files"], "OK" if not res["mismatched_or_missing"]
            else "MISMATCH " + ", ".join(res["mismatched_or_missing"][:5]))
        )
    print(verdict)
    return 0 if verdict != "SOURCE_DRIFT_BITSTREAM_FATAL" else 1


if __name__ == "__main__":
    sys.exit(main())
