#!/usr/bin/env python3
"""Strict-ustar structural audit of an SC7F0 VERIFY/COMMIT upgrade bundle.

The on-card daemon parses this archive itself, so the packaging contract is
structural, not just "it untars": exactly the four expected members, in order,
as regular files with uid/gid 0, mode 0644, mtime 0, POSIX "ustar\0" / "00"
magic, correct header checksums, no PAX/GNU extensions, no directory or link
entries, no './' prefixes and a proper two-block zero terminator.  Payload
SHA-256 digests are recomputed from the archive bytes and compared against
in-archive manifest.sha256 and, when given, against a release manifest
(RELEASE.sha256 or release.json).

Offline by design: no hardware, no card, no network.

Exit 0 with TAR_STRICT_USTAR_OK on success; every failure names the member.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

REQUIRE_ORDER = ("BOOT.BIN", "image.ub", "boot.scr", "manifest.sha256")
MAX_BYTES = 64 * 1024 * 1024


def _oct(field: bytes) -> int:
    return int(field.split(b"\x00")[0].strip() or b"0", 8)


def read_members(blob: bytes) -> list[dict]:
    """Parse a raw tar stream into verified header records plus payload digests."""
    members: list[dict] = []
    off = 0
    n = len(blob)
    while off + 512 <= n:
        header = blob[off:off + 512]
        if header == bytes(512):
            break
        name = header[0:100].split(b"\x00")[0].decode("ascii", "replace")
        if header[257:263] != b"ustar\x00" or header[263:265] != b"00":
            raise ValueError(f"{name}: not strict ustar (magic={header[257:265]!r})")
        stated = _oct(header[148:156])
        computed = (sum(header[0:148]) + 8 * 0x20 + sum(header[156:512])) & 0o777777
        if stated != computed:
            raise ValueError(f"{name}: header checksum {oct(stated)} != {oct(computed)}")
        typeflag = header[156:157]
        if typeflag != b"0":
            raise ValueError(f"{name}: typeflag {typeflag!r} is not a regular file")
        size = _oct(header[124:136])
        payload = blob[off + 512: off + 512 + size]
        if len(payload) != size:
            raise ValueError(f"{name}: truncated payload ({len(payload)} < {size})")
        members.append({
            "name": name,
            "size": size,
            "mode": _oct(header[100:108]),
            "uid": _oct(header[108:116]),
            "gid": _oct(header[116:124]),
            "mtime": _oct(header[136:148]),
            "uname": header[265:297].split(b"\x00")[0].decode("ascii", "replace"),
            "gname": header[297:329].split(b"\x00")[0].decode("ascii", "replace"),
            "linkname": header[157:257].split(b"\x00")[0].decode("ascii", "replace"),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "data": payload,
        })
        off += 512 + ((size + 511) // 512) * 512
    trailer = blob[off:]
    # POSIX/GNU tar pads the stream to a 10 KiB record after the two zero-block
    # end-of-archive marker, so the trailer is 1024..N zero bytes, never shorter
    # and never containing anything but zeros.
    if len(trailer) < 1024 or len(trailer) % 512 or trailer != bytes(len(trailer)):
        raise ValueError(f"archive does not end with >=2 zero blocks of padding "
                         f"(got {len(trailer)} bytes, nonzero={trailer != bytes(len(trailer))})")
    if len(blob) % 10240:
        raise ValueError(f"archive length {len(blob)} is not a multiple of the 10240-byte tar record")
    return members


def audit(archive: Path, release_dir: Path | None) -> dict:
    blob = archive.read_bytes()
    if len(blob) > MAX_BYTES:
        raise ValueError(f"archive {len(blob)} B exceeds daemon staging bound {MAX_BYTES} B")
    members = read_members(blob)
    names = [m["name"] for m in members]
    if names != list(REQUIRE_ORDER):
        raise ValueError(f"member list {names} != required {list(REQUIRE_ORDER)}")
    for m in members:
        if m["name"].startswith("./") or "/" in m["name"]:
            raise ValueError(f"{m['name']}: path prefix not allowed")
        if m["mode"] != 0o644:
            raise ValueError(f"{m['name']}: mode {oct(m['mode'])} != 0o644")
        if (m["uid"], m["gid"]) != (0, 0):
            raise ValueError(f"{m['name']}: uid/gid {m['uid']}/{m['gid']} != 0/0")
        if m["mtime"] != 0:
            raise ValueError(f"{m['name']}: mtime {m['mtime']} != 0 (non-deterministic)")
        if m["linkname"]:
            raise ValueError(f"{m['name']}: link name present")
        if not m["size"]:
            raise ValueError(f"{m['name']}: empty payload")
    digest = {m["name"]: m["sha256"] for m in members}
    manifest = {}
    for line in next(m for m in members if m["name"] == "manifest.sha256")["data"].decode().splitlines():
        if not line.strip():
            continue
        sha, name = line.split()
        manifest[name] = sha
    if manifest != {k: digest[k] for k in ("BOOT.BIN", "image.ub", "boot.scr")}:
        raise ValueError(f"in-archive manifest does not match payloads: {manifest}")
    total = sum(len(m["data"]) for m in members)
    if total > MAX_BYTES:
        raise ValueError(f"unpacked payload {total} B exceeds 64 MiB bound")
    checked: list[str] = []
    if release_dir is not None:
        rel = release_dir / "RELEASE.sha256"
        if rel.is_file():
            lines = [l.split() for l in rel.read_text().splitlines() if l.strip()]
            want = {Path(name).name: h for h, name in lines
                    if Path(name).name in ("BOOT.BIN", "image.ub", "boot.scr")}
            for name in ("BOOT.BIN", "image.ub", "boot.scr"):
                if want.get(name) != digest[name]:
                    raise ValueError(f"RELEASE.sha256 {name} {want.get(name)} != archive {digest[name]}")
            checked.append("RELEASE.sha256")
        rj = release_dir / "release.json"
        if rj.is_file():
            data = json.loads(rj.read_text())
            want = {Path(name).name: h for name, h in data["sha256"].items()}
            blob_sha = hashlib.sha256(blob).hexdigest()
            for name in ("BOOT.BIN", "image.ub", "boot.scr", archive.name):
                if name in want and want[name] != (digest.get(name) or blob_sha):
                    raise ValueError(f"release.json {name} mismatch")
            checked.append("release.json")
    return {"archive": str(archive), "bytes": len(blob),
            "sha256": hashlib.sha256(blob).hexdigest(),
            "members": [{"name": m["name"], "size": m["size"], "sha256": m["sha256"],
                         "mode": oct(m["mode"]), "uid": m["uid"], "gid": m["gid"],
                         "mtime": m["mtime"], "uname": m["uname"], "gname": m["gname"]}
                        for m in members],
            "unpacked_bytes": total,
            "trailing_zero_bytes": len(blob) - 512 * len(members)
            - sum(((m["size"] + 511) // 512) * 512 for m in members),
            "cross_checked_with": checked}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("archive", type=Path)
    p.add_argument("--release-dir", type=Path, default=None,
                   help="also cross-check the payload hashes against RELEASE.sha256 / release.json")
    p.add_argument("--json", nargs="?", const="-", default=None, metavar="PATH",
                   help="write the full audit record as JSON to PATH, or - for stdout")
    a = p.parse_args(argv)
    try:
        rec = audit(a.archive, a.release_dir)
    except (OSError, ValueError, KeyError, AssertionError) as exc:
        print(f"TAR_STRICT_USTAR_FAIL: {exc}", file=sys.stderr)
        return 1
    if a.json is not None:
        text = json.dumps(rec, indent=2) + "\n"
        if a.json == "-":
            print(text)
        else:
            Path(a.json).write_text(text)
    for m in rec["members"]:
        print(f"member {m['name']}: size={m['size']} mode={m['mode']} uid={m['uid']} "
              f"gid={m['gid']} mtime={m['mtime']} uname={m['uname']} sha256={m['sha256']}")
    print(f"archive {rec['archive']} bytes={rec['bytes']} sha256={rec['sha256']} "
          f"unpacked={rec['unpacked_bytes']} cross_checked={','.join(rec['cross_checked_with']) or 'none'}")
    print(f"TAR_STRICT_USTAR_OK members={len(rec['members'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
