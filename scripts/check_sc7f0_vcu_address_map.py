#!/usr/bin/env python3
"""Compare two Vivado block-design handoffs (XSA files) address map segment by segment.

Purpose in the SC7F0 flow: a new PL revision that adds an IP (for example the
encoder VCU at 0x8008_0000 on M_AXI_HPM0_LPD) must not move any address window
that an already-shipped device tree, driver or daemon is using.  Anything other
than pure additions means the PS-side artifacts of the baseline revision are no
longer valid for the candidate, and a mixed release (candidate bitstream with
baseline PS images) is unsafe.

The `.bda` inside each XSA is JSON; every address segment is a vertex with
master instance/interface (MX/MI), slave instance/interface (SX/SI), segment
name (SS), base (BA) and high (HA).  Segments are keyed by the full
master->slave->segment identity, so a moved window shows up as MOVED and a
re-named window shows up as both REMOVED and ADDED.

Offline, read-only.  Prints a table plus VCU_ADDRESS_MAP_COMPATIBLE /
VCU_ADDRESS_MAP_INCOMPATIBLE and exits non-zero on any change.

    scripts/check_sc7f0_vcu_address_map.py \
        --baseline build/r7-reviewed-acceptance.1793238509/hardware.xsa \
        --candidate build/dual-video-26102902-vcu-r5/hardware.xsa \
        [--allow vcu_0] [--json out.json]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import zipfile


def segments(xsa: Path) -> dict[tuple[str, str, str, str, str], tuple[str, str]]:
    out: dict[tuple[str, str, str, str, str], tuple[str, str]] = {}
    with zipfile.ZipFile(xsa) as z:
        names = [n for n in z.namelist() if n.endswith(".bda")]
        if len(names) != 1:
            raise ValueError(f"{xsa}: expected exactly one .bda, got {names}")
        data = json.loads(z.read(names[0]).decode())
    for vertex in data["graphjs"]["vertices"].values():
        if "BA" not in vertex or "HA" not in vertex:
            continue
        key = (str(vertex.get("MX")), str(vertex.get("MI")), str(vertex.get("SX")),
               str(vertex.get("SI")), str(vertex.get("SS")))
        span = (str(vertex["BA"]).lower(), str(vertex["HA"]).lower())
        if key in out and out[key] != span:
            raise ValueError(f"{xsa}: duplicate segment {key} with two windows {out[key]} {span}")
        out[key] = span
    if not out:
        raise ValueError(f"{xsa}: no address segments found in .bda")
    return out


def label(key: tuple[str, str, str, str, str]) -> str:
    mx, mi, sx, si, ss = key
    return f"{mx}{mi} -> {sx}{si} [{ss}]"


def audit(baseline: Path, candidate: Path) -> dict:
    base, cand = segments(baseline), segments(candidate)
    shared = set(base) & set(cand)
    moved = sorted((k for k in shared if base[k] != cand[k]), key=label)
    removed = sorted(set(base) - set(cand), key=label)
    added = sorted(set(cand) - set(base), key=label)
    return {"baseline": str(baseline), "candidate": str(candidate),
            "baseline_segments": len(base), "candidate_segments": len(cand),
            "unchanged": len(shared) - len(moved),
            "moved": [{"segment": label(k), "baseline": base[k], "candidate": cand[k]} for k in moved],
            "removed": [{"segment": label(k), "baseline": base[k]} for k in removed],
            "added": [{"segment": label(k), "candidate": cand[k]} for k in added],
            "_keys": (base, cand)}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--baseline", type=Path, required=True)
    p.add_argument("--candidate", type=Path, required=True)
    p.add_argument("--allow", action="append", default=[], metavar="SUBSTRING",
                   help="restrict additions to segments whose text contains one of these "
                        "substrings (repeatable); without it any pure addition is allowed")
    p.add_argument("--json", type=Path, default=None, help="write the machine-readable record here")
    a = p.parse_args(argv)
    rec = audit(a.baseline, a.candidate)
    base, cand = rec.pop("_keys")
    print(f"baseline  {rec['baseline']}: {rec['baseline_segments']} segments")
    print(f"candidate {rec['candidate']}: {rec['candidate_segments']} segments")
    print(f"unchanged {rec['unchanged']}  moved {len(rec['moved'])}  "
          f"removed {len(rec['removed'])}  added {len(rec['added'])}")
    for row in rec["moved"]:
        print(f"MOVED   {row['segment']} {row['baseline']} -> {row['candidate']}")
    for row in rec["removed"]:
        print(f"REMOVED {row['segment']} {row['baseline']}")
    for row in rec["added"]:
        print(f"ADDED   {row['segment']} {row['candidate']}")
    unexpected = ([r["segment"] for r in rec["added"]
                   if not any(pat in r["segment"] for pat in a.allow)] if a.allow else [])
    for seg in unexpected:
        print(f"UNEXPECTED_ADD (not covered by --allow) {seg}")
    ok = not rec["moved"] and not rec["removed"] and not unexpected
    rec["compatible"] = ok
    if a.json:
        a.json.write_text(json.dumps(rec, indent=2) + "\n")
    if not ok:
        print("VCU_ADDRESS_MAP_INCOMPATIBLE: baseline PS artifacts are not valid for the candidate")
        return 1
    print(f"VCU_ADDRESS_MAP_COMPATIBLE: every baseline window is byte-identical; "
          f"{len(rec['added'])} segment(s) added only")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
