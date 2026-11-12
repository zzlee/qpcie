#!/usr/bin/env python3
"""Name the byte source of every PS runtime this release ships - or fail loudly.

Why this exists
---------------
scripts/build_sc7f0_matching_ps_vcu.sh used to prove "the binary inside image.ub is
this build's binary" with

    find petalinux/qpcie-zu4ev/build/tmp/work -name <binary> | head -1

`head -1` keeps whatever `find` walks first, and when nothing was found the check
silently degraded to `@present` - presence only.  Both halves were wrong here:

* `tmp/work/<pn>/<pv>/image/` is deleted by OE after packaging, so the "compare
  file" usually does not exist at all.  What survives a build - and what the
  packaging step actually consumed - is OE's own packagedata record,
  `tmp/pkgdata/<machine>/runtime/<pn>`, whose `FILES_INFO:<pn>` line lists every
  installed path with its size.  That is the deterministic install output.
* the four injected daemons (`qpcie_upgrade_daemon`, `qpcie_debugd`,
  `qpcie_hdmi_daemon`, `sc7f0_ps_watchdog`) are not installed from a recipe at all
  at image-build time: scripts/inject_upgrade_daemon_to_image_ub.sh,
  scripts/install_debug_rootfs.sh and scripts/install_sc7f0_watchdog_rootfs.sh
  `install` them out of test_app/, from the ARM64 cross-build the PS stage just ran
  with `make -B` (sha256 recorded in production-daemons.sha256).  For those the
  byte source is that file, and byte-exact comparison is available - so `@present`
  was never necessary for them.

For `qpcie_debugd` the degradation mattered: the shipped image was measured to
carry a pre-0x800 mailbox debugd, and "the file exists" cannot distinguish 0x800
from 0x400.  Hence `--expect-string` ABI banners on top (test_app/qpcie_debugd.c
carries QPCIE_DEBUGD_ABI_BANNER, which the compiler is forced to keep).

Rules:

  * every named runtime must get a byte source (`cross-build`) or an OE packagedata
    record (`recipe-packagedata`).  Anything else exits non-zero.
  * a recipe whose packagedata exists in more than one machine directory with
    different sizes for the same file is AMBIGUOUS: the in-image bytes could not be
    attributed, and picking one by walk order is the bug this tool replaces.
  * `--allow-present NAME=<reason>` exists so an exception can be *documented*.  It
    is never implied, it is echoed into the JSON, and scripts
    /check_sc7f0_release_package.py reports every release that used it.

Read-only.  Never runs bitbake, never touches a card.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import struct
import sys
from pathlib import Path

FILES_INFO = re.compile(r'^FILES_INFO:(\S+):\s*(.*)$')


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def is_arm64_elf(data: bytes) -> bool:
    return (len(data) > 20 and data[:4] == b"\x7fELF" and data[4] == 2
            and struct.unpack_from("<H", data, 18)[0] == 183)


def packagedata_records(pkgdata_root: Path, pn: str) -> list[dict]:
    """FILES_INFO of package `pn` from every machine's packagedata directory."""
    out = []
    if not pkgdata_root.is_dir():
        return out
    for machine_dir in sorted(p for p in pkgdata_root.iterdir() if p.is_dir()):
        for suffix in (".packaged", ""):
            record = machine_dir / "runtime" / (pn + suffix)
            if not record.is_file():
                continue
            files = {}
            for line in record.read_text(errors="replace").splitlines():
                m = FILES_INFO.match(line.strip())
                if not m:
                    continue
                # FILES_INFO is a python dict literal written by OE ({path: size}).
                # It is parsed with ast.literal_eval, never eval(), and anything that
                # is not a {str: int} mapping raises: a packagedata line that cannot be
                # read must not silently mean "this binary has no install record".
                import ast
                try:
                    parsed = ast.literal_eval(m.group(2))
                    files.update({k: int(v) for k, v in parsed.items()})
                except (ValueError, TypeError, AttributeError) as exc:
                    raise ValueError(f"{record}: unreadable FILES_INFO for package "
                                     f"{m.group(1)}: {exc}") from exc
            if files:
                out.append({"record": str(record), "machine": machine_dir.name,
                            "flavour": "packaged" if suffix else "unpacked",
                            "files": files})
    return out


def resolve_recipe(pkgdata_root: Path, name: str, pn: str) -> dict:
    rec = {"binary": name, "kind": "recipe-packagedata", "recipe": pn}
    try:
        records = packagedata_records(pkgdata_root, pn)
    except ValueError as exc:
        rec.update({"status": "UNRESOLVED", "reason": str(exc)})
        return rec
    per_size: dict[tuple[str, int], list[str]] = {}
    for r in records:
        for path, size in r["files"].items():
            if path.rstrip("/").endswith("/" + name):
                per_size.setdefault((path, size), []).append(r["record"])
    if not per_size:
        rec.update({"status": "UNRESOLVED",
                    "reason": f"no packagedata record under {pkgdata_root} installs "
                              f"{name} (searched FILES_INFO of {pn} in every machine "
                              "directory). Either the recipe never ran or the binary "
                              "is not in its package; presence is not proof."})
        return rec
    if len(per_size) > 1:
        rec.update({"status": "AMBIGUOUS",
                    "reason": f"{len(per_size)} packagedata records install {name} "
                              "with different sizes: "
                              + "; ".join(f"{p}={s} ({', '.join(r)})"
                                          for (p, s), r in sorted(per_size.items()))})
        return rec
    (path, size), records_for_it = next(iter(per_size.items()))
    rec.update({"status": "RESOLVED", "install_path": path.lstrip("/"),
                "size": size,
                "packagedata": sorted(set(records_for_it))})
    return rec


def resolve_cross_build(repo: Path, name: str, rel: str, require_arm64: bool) -> dict:
    rec = {"binary": name, "kind": "cross-build", "source": rel}
    path = (repo / rel).resolve()
    rec["source_abs"] = str(path)
    if not path.is_file() or path.stat().st_size == 0:
        rec.update({"status": "UNRESOLVED",
                    "reason": f"{rel} does not exist: this stage must build it "
                              "(make -B -C test_app ...) before claiming the image "
                              "carries it"})
        return rec
    data = path.read_bytes()
    rec.update({"status": "RESOLVED", "size": len(data), "sha256": sha256(path),
                "arm64": is_arm64_elf(data)})
    if require_arm64 and not rec["arm64"]:
        rec.update({"status": "UNRESOLVED",
                    "reason": f"{rel} is not an ARM64 ELF; a host-compiled binary "
                              "proves nothing about the card and must not be "
                              "compared against the image"})
    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project", type=Path, default=Path("petalinux/qpcie-zu4ev"))
    ap.add_argument("--repo", type=Path, default=Path("."))
    ap.add_argument("--cross-build", action="append", default=[], metavar="NAME=REL_PATH",
                    help="binary the PS stage cross-built itself, installed into the "
                         "rootfs by this repository's injection scripts")
    ap.add_argument("--recipe", action="append", default=[], metavar="NAME=PN",
                    help="binary installed by bitbake recipe PN; resolved through OE "
                         "packagedata FILES_INFO")
    ap.add_argument("--allow-present", action="append", default=[], metavar="NAME=REASON",
                    help="document an exception (every use is reported by the release "
                         "gate); never implied")
    ap.add_argument("--json", type=Path)
    ap.add_argument("--shell", type=Path,
                    help="write --expect-binary / --expect-size pairs into a bash array")
    ap.add_argument("--array", default="ROOTFS_EXPECT")
    args = ap.parse_args()

    repo = args.repo.resolve()
    pkgdata = args.project.resolve() / "build/tmp/pkgdata"
    allowed = {}
    for item in args.allow_present:
        name, _, reason = item.partition("=")
        if not reason.strip():
            ap.exit(2, f"--allow-present {item!r} wants NAME=REASON\n")
        allowed[name.strip()] = reason.strip()

    pairs: list[tuple[str, str]] = []      # (--expect-binary arguments)
    sizes: list[tuple[str, str]] = []      # (--expect-size arguments)
    records, bad = [], []
    named = set()
    for item in args.cross_build:
        name, _, rel = item.partition("=")
        name, rel = name.strip(), rel.strip()
        if not rel:
            ap.exit(2, f"--cross-build {item!r} wants NAME=REL_PATH\n")
        named.add(name)
        rec = resolve_cross_build(repo, name, rel, require_arm64=True)
        records.append(rec)
        if rec["status"] == "RESOLVED":
            pairs.append((name, rec["source_abs"]))
        elif name in allowed:
            rec["present_allowed_reason"] = allowed[name]
            rec["status"] = "PRESENT_ONLY"
            pairs.append((name, "@present"))
        else:
            bad.append(rec)
    for item in args.recipe:
        name, _, pn = item.partition("=")
        name, pn = name.strip(), pn.strip()
        if not pn:
            ap.exit(2, f"--recipe {item!r} wants NAME=PN\n")
        named.add(name)
        rec = resolve_recipe(pkgdata, name, pn)
        records.append(rec)
        if rec["status"] == "RESOLVED":
            sizes.append((rec["install_path"], str(rec["size"])))
            pairs.append((name, "@present"))
            rec["note"] = ("bytes are not retained by OE after packaging, so the "
                           "binding is packagedata size + in-binary literals + unit "
                           "ExecStart; see --expect-size and --expect-string")
        elif name in allowed:
            rec["present_allowed_reason"] = allowed[name]
            rec["status"] = "PRESENT_ONLY"
            pairs.append((name, "@present"))
        else:
            bad.append(rec)

    stray = sorted(set(allowed) - named)
    if stray:
        ap.exit(2, "--allow-present names are not in --names: "
                  + ", ".join(stray) + "\n")

    report = {"binaries": records, "presence_only": sorted(allowed),
              "packagedata_root": str(pkgdata),
              "rule": "every named runtime gets a byte source (cross-build) or an OE "
                      "packagedata install record; @present only when a caller "
                      "documented why, and the release gate reports it"}
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(text)
    if args.shell:
        lines = [f"{args.array}=()"]
        for name, path in pairs:
            lines.append(f'{args.array}+=(--expect-binary {shlex.quote(name + "=" + path)})')
        for path, size in sizes:
            lines.append(f'{args.array}+=(--expect-size {shlex.quote(path + "=" + size)})')
        args.shell.parent.mkdir(parents=True, exist_ok=True)
        args.shell.write_text("\n".join(lines) + "\n")
    for rec in records:
        print(f"{rec['status']:14} {rec['binary']:24} {rec['kind']:22} "
              + (f"sha={rec['sha256'][:16]} size={rec['size']}" if rec.get("sha256")
                 else f"size={rec.get('size', '-')} path={rec.get('install_path', '-')}"
                 if rec.get("install_path") else rec.get("reason", "")[:110]))
    for rec in bad:
        print("RUNTIME_BYTE_SOURCE_UNRESOLVED " + rec["binary"] + ": " + rec["reason"],
              file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
