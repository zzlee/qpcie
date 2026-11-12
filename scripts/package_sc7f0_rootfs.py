#!/usr/bin/env python3
"""Rootfs package control + image-content proof for SC7F0 PS builds.

Two jobs, both fail-closed:

  enable   - turn the CONFIG_ entries for the runtime packages a release needs
             on in project-spec/configs/rootfs_config. Entries that the config
             does not (yet) list are appended, and the caller is told, because a
             missing entry is how a package silently stays out of the image.

  verify   - read a *built* rootfs (rootfs.cpio.gz, or the rootfs inside a
             repacked image.ub FIT) and prove the runtime components are really
             inside it: byte-exact binaries against the build tree, ARM64 ELF,
             systemd units present, units enabled, ExecStart pointing at the
             in-image path, required vendor libraries present, and nothing
             starting out of the eMMC BOOT partition.

Finding a file in a staging directory is not evidence. Only the unpacked image
counts, which is why the default input is image.ub.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_sc7f0_capture_image import cpio, resolve  # noqa: E402

FIT_MAGIC = 0x27051956
ARM64_ELF_MACHINE = 183
FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def _u32(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 4], "big")


def _cstr(b: bytes, o: int) -> str:
    end = b.index(b"\0", o)
    return b[o:end].decode("utf-8", "replace")


def fdt_tree(fdt: bytes) -> list[tuple[tuple[str, ...], str, bytes]]:
    """Minimal flat-device-tree walk: yields (path, property, value).

    Written here instead of shelling out to a device-tree tool because the caller
    must never hand a built image to a program that could rewrite it (an earlier
    version of this gate passed image.ub to mkimage, which *patches* in place).
    """
    if _u32(fdt, 0) != FDT_MAGIC:
        raise ValueError("FIT sub-image table is not a flat device tree")
    totalsize, off_struct, off_strings = _u32(fdt, 4), _u32(fdt, 8), _u32(fdt, 12)
    if totalsize > len(fdt) or off_struct >= len(fdt) or off_strings >= len(fdt):
        raise ValueError("flat device tree header is out of range")
    out, stack, o = [], [], off_struct
    while o < off_struct + _u32(fdt, 36):
        token = _u32(fdt, o); o += 4
        if token == FDT_NOP:
            continue
        if token == FDT_END:
            break
        if token == FDT_BEGIN_NODE:
            name = _cstr(fdt, o)
            o += len(name) + 1
            o += (-o) % 4
            stack.append(name.split("@")[0])   # root node is named ""
            continue
        if token == FDT_END_NODE:
            stack.pop()
            continue
        if token == FDT_PROP:
            length, nameoff = _u32(fdt, o), _u32(fdt, o + 4)
            o += 8
            value = fdt[o:o + length]
            o += length + (-length) % 4
            out.append(("/" + "/".join(s for s in stack if s),
                       _cstr(fdt, off_strings + nameoff), value))
            continue
        raise ValueError("unknown device-tree token %d at %d" % (token, o))
    return out


def fit_subimages(image_ub: Path) -> dict[str, dict]:
    """Name -> {type, compression, data} for every sub-image of a FIT, read-only.

    PetaLinux produces both shapes of this file: a bare FIT blob (device tree at
    byte 0) and a u-Boot legacy wrapper (64-byte header, then the tree). The
    sub-image data-offsets are counted from the start of the tree in the wrapped
    case and from byte 0 in the bare case, so each candidate base is validated
    against the file and only a base whose ramdisk really parses is accepted.

    The ramdisk is located by name and type, never by positional index, so a build
    that orders its images differently cannot make this gate read the kernel and
    call it a rootfs.
    """
    data = image_ub.read_bytes()
    if len(data) < 64:
        raise ValueError("%s is too small to be a FIT image" % image_ub)
    magic = _u32(data, 0)
    if magic == FDT_MAGIC:
        fdt, bases, shape = data, (0, 64), "bare FIT"
    elif magic == FIT_MAGIC:
        # A u-Boot wrapper does not reliably carry its own header length where a
        # reader might guess one, so the device tree locates itself: its totalsize
        # field says how long it is, and the payload offsets count from its start.
        if len(data) < 72 or _u32(data, 64) != FDT_MAGIC:
            raise ValueError("%s has a u-Boot magic but no flat device tree at byte 64"
                             % image_ub)
        dtb_len = _u32(data, 68)
        if not 16 <= dtb_len <= len(data) - 64:
            raise ValueError("%s device tree claims %d bytes inside a %d byte file"
                             % (image_ub, dtb_len, len(data)))
        fdt, bases, shape = data[64:64 + dtb_len], (64,), "u-Boot wrapped FIT"
    else:
        raise ValueError("%s starts with %08x: neither a u-Boot legacy image nor a "
                         "flat device tree" % (image_ub, magic))
    if _u32(fdt, 0) != FDT_MAGIC:
        raise ValueError("%s: sub-image table is not a device tree" % shape)
    props: dict[tuple[str, str], bytes] = {}
    tree = fdt_tree(fdt)
    for path, name, value in tree:
        props[(path, name)] = value
    names = sorted({p.split("/")[2] for p, _, _ in tree
                    if len(p.split("/")) == 3 and p.split("/")[1] == "images"})
    found: dict[str, dict] = {}
    for name in names:
        path = "/images/" + name
        item = {"type": props.get((path, "type"), b"").split(b"\0")[0].decode(),
                "compression": props.get((path, "compression"), b"\0").split(b"\0")[0].decode()}
        blob = props.get((path, "data"))
        if blob is not None:
            item["data"] = blob
            found[name] = item
            continue
        if (path, "data-offset") not in props or (path, "data-size") not in props:
            raise ValueError("sub-image %s has neither inline data nor data-offset" % name)
        item["offset"] = _u32(bytes(props[(path, "data-offset")]), 0)
        item["size"] = _u32(bytes(props[(path, "data-size")]), 0)
        # Every base that keeps the slice inside the file is kept as a candidate;
        # the ramdisk below decides which one is real by parsing it. Picking the
        # first in-range base without checking would let a wrong base quietly
        # produce a plausible-looking but wrong rootfs table.
        item["candidates"] = [(base, data[base + item["offset"]:base + item["offset"] + item["size"]])
                              for base in bases
                              if 0 <= base + item["offset"] < base + item["offset"] + item["size"] <= len(data)]
        if not item["candidates"]:
            raise ValueError("sub-image %s offset %d+%d does not fit the file with any "
                             "base of %s" % (name, item["offset"], item["size"], bases))
        item["offset_base"], item["data"] = item["candidates"][0]
        found[name] = item
    ramdisks = [n for n, i in found.items() if i.get("type") == "ramdisk"]
    if len(ramdisks) != 1:
        raise ValueError("expected exactly one ramdisk sub-image, found %s"
                         % sorted(found, key=lambda n: found[n].get("type", "")))
    rd = found[ramdisks[0]]
    reason = None
    for base, blob in rd.get("candidates", [(rd.get("offset_base"), rd["data"])]):
        try:
            entries = cpio(_ramdisk_bytes(blob))
        except Exception as exc:                      # malformed stream at this base
            reason = exc
            continue
        if entries:
            rd["offset_base"], rd["data"] = base, blob
            rd.pop("candidates", None)
            return found
        reason = ValueError("cpio archive is empty")
    raise ValueError("the ramdisk of %s does not parse with any offset base %s: %s"
                     % (image_ub, [b for b, _ in rd.get("candidates", [])], reason))
    return found


def _ramdisk_bytes(blob: bytes) -> bytes:
    """Unwrap gzip and/or a nested u-Boot legacy ramdisk image to plain cpio bytes.

    Real images need the loosest possible reading here: PetaLinux stores the ramdisk
    with compression "none" while the bytes are really a gzip stream, and older
    flows wrapped it in another u-Boot header. Each layer is therefore accepted only
    when what follows looks like gzip or a newc cpio magic - a header field is never
    trusted on its own, because the vendor header does not keep a header length
    where a reader might guess one.
    """
    import gzip
    cpio_magic = (b"070701", b"070702")
    for _ in range(6):
        if blob[:6] in cpio_magic:
            return blob
        if blob[:2] == b"\x1f\x8b":
            blob = gzip.decompress(blob)
            continue
        if len(blob) > 64 and _u32(blob, 0) == FIT_MAGIC:
            for cut in (64, _u32(blob, 4)):
                if 64 <= cut <= len(blob) and (blob[cut:cut + 2] == b"\x1f\x8b"
                                               or blob[cut:cut + 6] in cpio_magic):
                    blob = blob[cut:]
                    break
            else:
                raise ValueError("nested u-Boot ramdisk header does not point at gzip "
                                 "or cpio data")
            continue
        raise ValueError("ramdisk is neither gzip nor a newc cpio archive (starts %s)"
                         % blob[:8].hex())
    raise ValueError("ramdisk is wrapped in too many layers to resolve")


def unpack_rootfs(image_ub: Path, work: Path) -> dict:
    """Return the cpio entry table of the rootfs carried inside a FIT image.ub.

    The release image is only ever opened for reading. Everything extracted goes
    under the caller's private temporary directory.
    """
    images = fit_subimages(image_ub)
    ramdisks = [n for n, i in images.items() if i.get("type") == "ramdisk"]
    if len(ramdisks) != 1:
        raise ValueError("expected exactly one ramdisk sub-image, found %s"
                         % sorted(images, key=lambda n: images[n].get("type", "")))
    blob = images[ramdisks[0]].get("data")
    if blob is None:
        raise ValueError("ramdisk sub-image has no extractable data")
    (work / "ramdisk.raw").write_bytes(blob)
    entries = cpio(_ramdisk_bytes(blob))
    if not entries:
        raise ValueError("ramdisk decompressed to an empty cpio archive")
    return entries


def is_arm64_elf(data: bytes) -> bool:
    return data[:4] == b"\x7fELF" and data[4] == 2 and \
        struct.unpack_from("<H", data, 18)[0] == ARM64_ELF_MACHINE


def verify(image_ub: Path, expect_bins: dict[str, Path], expect_units: list[str],
           expect_files: list[str], enabled_units: list[str],
           expect_strings: list[tuple[str, bytes]] | None = None,
           expect_sizes: list[tuple[str, int]] | None = None) -> dict:
    errors: list[str] = []
    report = {"image": str(image_ub), "entries": 0, "binaries": {},
              "units": {}, "files": {}}
    with tempfile.TemporaryDirectory(prefix="sc7f0-rootfs-") as t:
        try:
            entries = unpack_rootfs(image_ub, Path(t))
        except Exception as exc:
            # A gate that raises is not a gate: report the reason and fail. The cpio
            # reader asserts, a truncated image can raise anything, and the caller
            # must still get ROOTFS_RUNTIME_CONTENT_FAIL with a readable reason.
            report["errors"] = ["cannot read the rootfs out of %s: %s: %s"
                                % (image_ub, type(exc).__name__, exc)]
            report["verdict"] = "ROOTFS_RUNTIME_CONTENT_FAIL"
            return report
    report["entries"] = len(entries)
    for name, source in expect_bins.items():
        key = "usr/bin/" + name
        if key not in entries:
            errors.append(f"{key} is not in the image rootfs")
            continue
        mode, uid, data = resolve(entries, key)
        if source is None:
            # Presence-only expectation: the binary is compiled inside the image
            # build (bitbake recipe), so there is no build-tree twin to compare.
            report["binaries"][name] = {"size": len(data), "arm64": is_arm64_elf(data),
                                       "byte_exact_vs_build_tree": "not applicable",
                                       "uid": uid, "executable": bool(mode & 0o111),
                                       "regular": stat.S_ISREG(mode)}
            if not is_arm64_elf(data):
                errors.append(f"{key} is not an ARM64 ELF")
            if not mode & 0o111 or not stat.S_ISREG(mode):
                errors.append(f"{key} is not a regular executable (mode {oct(mode)})")
            continue
        want = source.read_bytes()
        report["binaries"][name] = {
            "size": len(data), "arm64": is_arm64_elf(data),
            "byte_exact_vs_build_tree": data == want, "uid": uid,
            "executable": bool(mode & 0o111), "regular": stat.S_ISREG(mode)}
        if data != want:
            errors.append(f"{key} differs from the binary this build produced")
        if not is_arm64_elf(data):
            errors.append(f"{key} is not an ARM64 ELF")
        if not mode & 0o111:
            errors.append(f"{key} is not executable (mode {oct(mode)})")
        if not stat.S_ISREG(mode):
            errors.append(f"{key} is not a regular file (mode {oct(mode)})")
    for unit in expect_units:
        key = "lib/systemd/system/" + unit
        if key not in entries:
            errors.append(f"unit {unit} is not installed in the image")
            continue
        _, _, body = resolve(entries, key)
        text = body.decode("utf-8", "replace")
        execs = re.findall(r"^ExecStart=(.*)$", text, re.M)
        report["units"][unit] = {"exec_start": execs}
        for line in execs:
            if "/run/media/" in line or "/tmp/" in line or "/mnt/" in line:
                errors.append(f"{unit} ExecStart runs {line!r}: a boot-partition or "
                              "tmp loose file, not the binary inside this image")
            elif not line.strip().startswith("/usr/bin/"):
                errors.append(f"{unit} ExecStart {line!r} is not an in-image path")
    for unit in enabled_units:
        key = "etc/systemd/system/multi-user.target.wants/" + unit
        if key not in entries:
            errors.append(f"{unit} is installed but not enabled for boot")
            continue
        enable_mode, _, raw = entries[key]
        if not stat.S_ISLNK(enable_mode):
            errors.append(f"{unit} enable entry is mode {oct(enable_mode)}, not a symlink: "
                          "a copied file does not make a unit start at boot")
            continue
        target = raw.decode("utf-8", "replace").strip()
        if "systemd/system/" not in target:
            errors.append(f"{unit} enable symlink points at {target!r}, "
                          "not at the installed unit file")
            continue
        # A dangling symlink looks enabled in the table but boots nothing, so the
        # target has to exist in this same image. Absolute targets are rooted at the
        # cpio root (which has no leading component); relative ones resolve against
        # the wants directory, exactly as systemd would.
        from posixpath import normpath
        if target.startswith("/"):
            rel = normpath(target[1:])
        else:
            # relative links are written from the wants directory, e.g.
            # ../../lib/systemd/system/x.service, so resolve against its parent
            rel = normpath("etc/systemd/system/" + target)
        if rel not in entries:
            errors.append(f"{unit} is enabled through a dangling symlink {target!r}: "
                          f"{rel} is not in this image")
            continue
        report["units"].setdefault(unit, {})["enabled_via"] = target
        report["units"][unit].setdefault("enabled", True)
    for f in expect_files:
        if f not in entries:
            errors.append(f"required runtime file {f} is not in the image")
        else:
            report["files"][f] = entries[f][0]
    # A recipe-compiled binary cannot be pinned byte-for-byte to a build-tree
    # rebuild (different flags, different sysroot), so a fix that lives inside the
    # binary is proved by a literal the new code is required to carry. This is how
    # "the shipped daemon really has the backup-retention policy" is checked.
    for path, needle in expect_strings or []:
        if path not in entries:
            errors.append(f"{path} is not in the image, so {needle[:60]!r} cannot be proven")
            continue
        _, _, body = resolve(entries, path)
        report.setdefault("strings", {})[path] = {
            needle.decode("utf-8", "replace"): needle in body}
        if needle not in body:
            errors.append(f"{path} does not contain {needle[:80]!r}: the fix this release "
                          "claims is not in the binary that will actually run")
    # OE deletes $D after packaging, so for a recipe-installed binary the durable
    # install record is packagedata's FILES_INFO size. Comparing it here means
    # "present" is never just "a file with that name exists": it must be the file
    # this build packaged, and together with --expect-string the identity is pinned
    # without pretending a rebuild is byte-identical.
    for path, want in expect_sizes or []:
        if path not in entries:
            errors.append(f"{path} is not in the image, so its packagedata size "
                          f"({want} bytes) cannot be checked")
            continue
        _, _, body = resolve(entries, path)
        report.setdefault("sizes", {})[path] = {
            "image_bytes": len(body), "packagedata_bytes": want,
            "match": len(body) == want}
        if len(body) != want:
            errors.append(f"{path} is {len(body)} bytes but OE packagedata says {want}: "
                          "the image carries some other build of this binary")
    report["errors"] = errors
    report["verdict"] = "ROOTFS_RUNTIME_CONTENT_PASS" if not errors else "ROOTFS_RUNTIME_CONTENT_FAIL"
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("enable")
    e.add_argument("--rootfs-config", type=Path, required=True)
    e.add_argument("--package", action="append", default=[], required=True)
    e.add_argument("--json", type=Path)
    v = sub.add_parser("verify")
    v.add_argument("--image-ub", type=Path, required=True)
    v.add_argument("--expect-binary", action="append", default=[],
                   metavar="NAME=PATH", help="rootfs /usr/bin/NAME must equal PATH")
    v.add_argument("--expect-unit", action="append", default=[])
    v.add_argument("--enabled-unit", action="append", default=[])
    v.add_argument("--expect-file", action="append", default=[],
                   help="path relative to the rootfs root, e.g. usr/lib/libOMX.allegro.core.so")
    v.add_argument("--expect-string", action="append", default=[],
                   metavar="PATH=LITERAL",
                   help="bytes PATH inside the image must contain LITERAL (proves a fix "
                        "is in a recipe-compiled binary that cannot be byte-compared)")
    v.add_argument("--expect-size", action="append", default=[],
                   metavar="PATH=BYTES",
                   help="PATH inside the image must be exactly BYTES long (OE "
                        "packagedata FILES_INFO size, the durable install record)")
    v.add_argument("--json", type=Path)
    args = parser.parse_args()

    if args.cmd == "enable":
        result = enable(args.rootfs_config, args.package)
        text = json.dumps(result, indent=2) + "\n"
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(text)
        print("ROOTFS_PACKAGES_ENABLED", " ".join(args.package))
        if result["enabled_appended"]:
            print("APPENDED (they were absent from rootfs_config):",
                  " ".join(result["enabled_appended"]))
        return 0

    expect_bins = {}
    for item in args.expect_binary:
        name, _, path = item.partition("=")
        if path == "@present":
            # compiled by the image build itself; require presence + ARM64 only
            expect_bins[name] = None
            continue
        if not path or not Path(path).is_file():
            parser.exit(1, f"bad --expect-binary {item!r} (PATH must exist or be @present)\n")
        expect_bins[name] = Path(path)
    expect_files_list = args.expect_file
    expect_strings: list[tuple[str, bytes]] = []
    for item in args.expect_string:
        path, sep, literal = item.partition("=")
        if not sep or not literal:
            parser.exit(1, f"bad --expect-string {item!r} (want PATH=LITERAL)\n")
        expect_strings.append((path.lstrip("/"), literal.encode()))
    expect_sizes: list[tuple[str, int]] = []
    for item in args.expect_size:
        path, sep, size = item.partition("=")
        if not sep or not size.strip().isdigit():
            parser.exit(1, f"bad --expect-size {item!r} (want PATH=BYTES)\n")
        expect_sizes.append((path.lstrip("/"), int(size)))
    report = verify(args.image_ub, expect_bins, args.expect_unit, expect_files_list,
                    args.enabled_unit, expect_strings, expect_sizes)
    text = json.dumps(report, indent=2) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(text)
    for err in report["errors"]:
        print("FAIL " + err, file=sys.stderr)
    print(report["verdict"])
    return 0 if report["verdict"] == "ROOTFS_RUNTIME_CONTENT_PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
