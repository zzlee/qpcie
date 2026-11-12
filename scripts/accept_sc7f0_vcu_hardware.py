#!/usr/bin/env python3
"""Derive the scoped VCU hardware acceptance record from a real build.

Background
----------
scripts/build_sc7f0_matching_ps_vcu.sh refuses to build a PS image unless it is
handed a "hardware acceptance" directory containing hardware.json / hardware.ok /
review.json, so that a device tree can never be built for a PL design that was not
itself reviewed.  Nothing in this repository ever *wrote* those files: they were
produced by hand inside the /home/zzlee/vibecoding/sc7f0-dual-video worktree, which
was deleted on 2026-11-11.  The result was an entry point that could only be run by
someone holding an unreproducible artifact.

This script regenerates the record from build evidence, from reports rather than
from prose:

  * the shipped absolute timing/CDC/skew/methodology gate result
    (scripts/check_sc7f0_timing.py, strict),
  * routed timing margins and zero total-negative-slack,
  * the routed C2H personality audit and the routed Gray-endpoint re-check,
  * exactly one VCU hard macro placed, read out of the utilization report,
  * the bitstream/XSA byte match and the stamped build identity,
  * and a real negative control: the debug profile must still refuse the VCU.

Anything it cannot prove is written as not performed (for example the scoped delta
review against the frozen R7 evidence, when no R7 baseline reports exist on this
machine) instead of being copied from an older record.

Review only.  It never authorises packaging, deployment or a flash, and it writes
matching_ps_package_ready=false and deployment_allowed=false.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import math
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_sc7f0_vcu_delta import placed_counts  # noqa: E402  (reuse the same parser)

RUN_SUB = "qpcie_zu4ev_card.runs/impl_1"
TOP = "zu4ev_pcie_card_top"
TIMING_ROW = re.compile(r"^\s*WNS\(ns\).*WPWS\(ns\).*\n[^\n]*\n([^\n]+)", re.M)
REQUIRED_CONSOLE = (
    "SC7F0_IMPL_VCU 1",
    "SC7F0_VCU_BD_OK",
    "SC7F0_IDENTITY_APPLY",
    "SC7F0_IDENTITY_VERIFIED",
    "SC7F0_GRAY_ROUTED_BEGIN",
    "SC7F0_GRAY_ROUTED_END",
    "SC7F0_VCU_ROUTED_CELL",
    "SC7F0_TIMING_GATE_PASS",
    "SC7F0_DUAL_VIDEO_VIVADO_PASS",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def embedded_bit(xsa: Path) -> tuple[str, bytes]:
    from zipfile import ZipFile
    with ZipFile(xsa) as z:
        names = [n for n in z.namelist() if n.endswith(".bit")]
    if len(names) != 1:
        raise ValueError(f"{xsa}: expected exactly one .bit member, found {names}")
    with ZipFile(xsa) as z:
        return names[0], z.read(names[0])


def routed_margins(timing_summary: Path) -> dict:
    """Design Timing Summary row, using the same column mapping as the gate.

    scripts/check_sc7f0_timing.py maps the 12 numbers of the summary row to
    WNS/values[0], WHS/values[4], WPWS/values[8], the total negative slacks to
    values[1], values[5], values[9] and the failing-endpoint counts to values[3],
    values[7], values[11]. Re-using that mapping keeps the two readers from ever
    disagreeing about which column is which.
    """
    text = timing_summary.read_text()
    if not re.search(r"Design State\s*:\s*Routed\b", text):
        raise ValueError("timing summary is not from the routed design")
    row = TIMING_ROW.search(text)
    if not row:
        raise ValueError("no design timing summary row")
    v = [float(x) for x in row[1].split()]
    if len(v) != 12 or not all(math.isfinite(x) for x in v):
        raise ValueError(f"unexpected timing summary row: {row[1].strip()}")
    return {"WNS": v[0], "WHS": v[4], "WPWS": v[8],
            "TNS": v[1], "THS": v[5], "TPWS": v[9],
            "setup_fail_endpoints": v[3], "hold_fail_endpoints": v[7],
            "pw_fail_endpoints": v[11]}


def debug_profile_negative_control(repo: Path, logs: Path) -> dict:
    """The debug profile must still refuse to build a VCU (real Vivado run)."""
    env = dict(os.environ, SC7F0_PROFILE="debug", SC7F0_ENABLE_VCU="1",
               SC7F0_BUILD_STAGE="ip", SC7F0_PROJECT_DIR=str(logs / "debug-vcu-refusal"))
    proc = subprocess.run(
        ["vivado", "-mode", "batch", "-notrace", "-nojournal",
         "-log", str(logs / "debug-vcu-refusal.vivado.log"),
         "-source", "scripts/build_zu4ev.tcl"],
        cwd=repo, env=env, capture_output=True, text=True)
    logs.joinpath("debug-vcu-refusal.exit").write_text(str(proc.returncode) + "\n")
    combined = proc.stdout + proc.stderr
    logs.joinpath("debug-vcu-refusal.out").write_text(combined)
    refused = "SC7F0_ENABLE_VCU requires SC7F0_PROFILE=full" in combined
    return {"exit": proc.returncode, "refused_as_required": refused,
            "evidence": str(logs / "debug-vcu-refusal.vivado.log")}


def review(project: Path, identity: dict, gate: dict, console: Path | None,
           repo: Path, logs: Path, baseline: Path | None) -> tuple[dict, dict]:
    errors: list[str] = []
    checks: dict[str, object] = {}

    if gate.get("pass_gate") is not True or gate.get("errors"):
        errors.append(f"absolute timing/CDC gate did not pass: {gate.get('errors')}")
    margins = gate.get("margins_ns", {})
    for k in ("WNS", "WHS", "WPWS"):
        if not isinstance(margins.get(k), (int, float)) or margins[k] <= 0:
            errors.append(f"{k}={margins.get(k)} is not strictly positive")
    timing = routed_margins(project / "timing_summary.rpt")
    for k in ("TNS", "THS", "TPWS"):
        if timing[k] != 0:
            errors.append(f"{k}={timing[k]} is not zero")
    for k in ("setup_fail_endpoints", "hold_fail_endpoints", "pw_fail_endpoints"):
        if timing[k] != 0:
            errors.append(f"{k}={timing[k]} endpoints failing")
    checks["routed_margins"] = timing

    skew = (project / "bus-skew.rpt").read_text()
    if "(VIOLATED)" in skew:
        errors.append("bus skew report contains a violation")
    cdc = (project / "cdc.rpt").read_text()
    if re.search(r"^\s*\d+\s+CDC-\d+\s+(?:Critical(?: Warning)?|Error)\b", cdc, re.M):
        errors.append("critical CDC detail present")
    checks["cdc_summary_rows"] = len(re.findall(r"^CDC-\d+\b", cdc, re.M))

    personality = (project / "c2h-personality.rpt").read_text()
    if "C2H_PERSONALITY_SYNTH_PASS" not in personality:
        errors.append("c2h-personality.rpt has no pass marker")
    if not re.search(r"^PRESENT VCU_hard_macro", personality, re.M):
        errors.append("c2h-personality.rpt never proved the VCU hard macro")

    util = (project / "utilization_routed_hierarchical.rpt").read_text()
    placed = placed_counts((project / RUN_SUB / f"{TOP}_utilization_placed.rpt").read_text())
    checks["placed_counts"] = placed
    vcu = placed.get("VCU")
    if not vcu or vcu.get("used") != 1.0:
        errors.append(f"expected exactly one placed VCU hard macro, report says {vcu}")

    xsa = project / "hardware.xsa"
    bit = project / RUN_SUB / f"{TOP}.bit"
    name, embedded = embedded_bit(xsa)
    if hashlib.sha256(embedded).hexdigest() != sha256(bit):
        errors.append("hardware.xsa does not carry this run's bitstream")
    checks["xsa_bit_member"] = name

    version = identity.get("version")
    if not re.fullmatch(r"2[0-9]{7}", str(version)):
        errors.append(f"identity version {version!r} is not an 8-digit release number")
    if identity.get("c_version_register") not in (None, "0x" + str(version)):
        errors.append("stamped C_VERSION does not match the release version")

    if console is not None:
        text = console.read_text()
        missing = [m for m in REQUIRED_CONSOLE if m not in text]
        if missing:
            errors.append("implementation console is missing " + ", ".join(missing))
        checks["console"] = str(console)
    else:
        errors.append("no implementation console supplied; the routed re-check "
                      "and identity markers cannot be confirmed")

    # Real negative control, so the acceptance record proves the guard as well as
    # the positive path.
    control = debug_profile_negative_control(repo, logs)
    checks["debug_profile_negative_control"] = control
    if not (control["exit"] != 0 and control["refused_as_required"]):
        errors.append("the debug profile did not refuse SC7F0_ENABLE_VCU as required")

    if baseline is not None and (baseline / "cdc.rpt").is_file():
        checks["scoped_delta_review"] = {"performed": False,
                                        "reason": "baseline present but the delta "
                                                  "review is a separate command; run "
                                                  "scripts/check_sc7f0_vcu_delta.py"}
    else:
        checks["scoped_delta_review"] = {
            "performed": False,
            "reason": "no frozen R7 (26102901) routed evidence exists on this machine; "
                      "the delta review was deleted with its worktree, so it is reported "
                      "as not performed instead of being copied from an older record"}

    inputs = {str(p): sha256(p) for p in
              (xsa, bit, project / "timing_summary.rpt", project / "cdc.rpt",
               project / "bus-skew.rpt", project / "c2h-personality.rpt",
               project / "utilization_routed_hierarchical.rpt",
               project / RUN_SUB / f"{TOP}_utilization_placed.rpt") if p.is_file()}
    result = {
        "pass_gate": not errors,
        "errors": errors,
        "candidate": f"vcu-release-{version}",
        "generated_by": "scripts/accept_sc7f0_vcu_hardware.py",
        "generated_utc": subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
                                        capture_output=True, text=True).stdout.strip(),
        "summary": {"margins_ns": margins, "placed_counts": placed,
                    "routed": timing, "identity": identity},
        "checks": checks,
        "input_sha256": inputs,
        "review_only": True,
        "publication_signoff": False,
        "deployment_authorized_by_this_report": False,
    }
    hardware = {
        "profile": "VCU_C2H_ABI1.1",
        "version": "0x" + str(version),
        "hardware_candidate": f"vcu-release-{version}",
        "hardware_accepted": not errors,
        "original_debug_profile_exit": control["exit"] if control["refused_as_required"] else 0,
        "matching_ps_package_ready": False,
        "deployment_allowed": False,
        "review_only": True,
        "deployment_authorized_by_this_report": False,
        "xsa_sha256": sha256(xsa),
        "bit_sha256": sha256(bit),
        # Which sources this review actually looked at. Without these two fields an
        # acceptance directory is only proof about bytes; scripts
        # /build_sc7f0_vcu_release.sh --stage ps can then still tell "a real review"
        # apart from "a real review of a different round", which is the failure mode
        # that lets an old SC7F0_HARDWARE_ACCEPTANCE_DIR be reused.
        "source_fingerprint_sha256": identity.get("source_fingerprint_sha256"),
        "git_head": identity.get("git_head"),
        "worktree_dirty": identity.get("worktree_dirty"),
        "generated_by": "scripts/accept_sc7f0_vcu_hardware.py",
        "scoped_delta_review": checks["scoped_delta_review"],
    }
    return result, hardware


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True,
                        help="release fpga directory (reports + hardware.xsa + bit)")
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--gate", type=Path, required=True,
                        help="check_sc7f0_timing.py JSON for this build")
    parser.add_argument("--console", type=Path,
                        help="implementation console log of this build")
    parser.add_argument("--baseline", type=Path,
                        help="frozen R7 evidence directory, when one exists")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        parser.exit(1, f"REFUSING to overwrite {args.out}\n")
    # Input sanity first, with a sentence instead of a traceback: this runs in the
    # middle of the PS stage, and an IsADirectoryError from a mistyped --gate would
    # otherwise look like a hardware rejection.
    for label, path, kind in (("--project", args.project, "dir"),
                              ("--identity", args.identity, "file"),
                              ("--gate", args.gate, "file")):
        if kind == "dir" and not path.is_dir():
            parser.exit(2, f"VCU_ACCEPTANCE_INPUT_ERROR: {label} {path} is not a directory\n")
        if kind == "file" and not path.is_file():
            parser.exit(2, f"VCU_ACCEPTANCE_INPUT_ERROR: {label} {path} is not a readable file\n")
    if args.console is not None and not args.console.is_file():
        parser.exit(2, f"VCU_ACCEPTANCE_INPUT_ERROR: --console {args.console} is not a file\n")
    if args.baseline is not None and not args.baseline.is_dir():
        parser.exit(2, f"VCU_ACCEPTANCE_INPUT_ERROR: --baseline {args.baseline} is not a directory\n")
    project = args.project.resolve()
    try:
        identity = json.loads(args.identity.read_text())
    except (OSError, ValueError) as exc:
        parser.exit(2, f"VCU_ACCEPTANCE_INPUT_ERROR: {args.identity}: {exc}\n")
    # The release identity file names the stamped registers; fold them in so the
    # review records which numbers the hardware will actually report.
    stamped = project / "version-identity.json"
    if stamped.is_file():
        identity.update({k: v for k, v in json.loads(stamped.read_text()).items()
                         if k not in identity})
    try:
        gate = json.loads(args.gate.read_text())
    except (OSError, ValueError) as exc:
        parser.exit(2, f"VCU_ACCEPTANCE_INPUT_ERROR: {args.gate}: {exc}\n")
    logs = args.out.parent / (args.out.name + "-logs")
    logs.mkdir(parents=True, exist_ok=True)
    try:
        result, hardware = review(project, identity, gate, args.console,
                                  args.repo.resolve(), logs, args.baseline)
    except (OSError, ValueError, KeyError, IndexError) as exc:
        # Missing or malformed build evidence is an input problem, not a verdict:
        # saying "rejected" here would blame the hardware for a gap in the record.
        print(f"VCU_ACCEPTANCE_INPUT_ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    args.out.mkdir(parents=True)
    (args.out / "review.json").write_text(json.dumps(result, indent=2) + "\n")
    (args.out / "hardware.json").write_text(json.dumps(hardware, indent=2) + "\n")
    (args.out / "hardware.ok").write_text(
        "SCOPED_VCU_ACCEPTED; NOT SYSTEM/PACKAGE/DEPLOYMENT ACCEPTANCE\n"
        if result["pass_gate"] else "SCOPED_VCU_REJECTED\n")
    manifest = "".join(f"{digest}  {path}\n" for path, digest in result["input_sha256"].items())
    (args.out / "REVIEW_INPUTS_OUTPUTS.sha256").write_text(manifest)
    for err in result["errors"]:
        print("FAIL " + err, file=sys.stderr)
    print(json.dumps({"pass_gate": result["pass_gate"],
                      "version": hardware["version"],
                      "margins_ns": result["summary"]["margins_ns"],
                      "vcu_placed": result["summary"]["placed_counts"].get("VCU"),
                      "scoped_delta_review": hardware["scoped_delta_review"]["performed"]},
                     indent=2))
    print("SCOPED_VCU_ACCEPTED" if result["pass_gate"] else "SCOPED_VCU_REJECTED")
    print("review only: not signoff, not permission to package, deploy or flash")
    return 0 if result["pass_gate"] else 1


if __name__ == "__main__":
    sys.exit(main())
