#!/usr/bin/env python3
"""Build a deterministic, strict-ustar SC7F0 VERIFY/COMMIT bundle (no flashing).

All three boot files and their SHA-256 manifest are mandatory. No directory
entries, ./ prefixes, links, PAX headers or extra files enter the archive.
"""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import tarfile

NAMES = ("BOOT.BIN", "image.ub", "boot.scr")
MAX_BYTES = 64 * 1024 * 1024


def package(images: Path, output: Path) -> dict:
    contents = {}
    for name in NAMES:
        data = (images / name).read_bytes()
        if not data:
            raise ValueError(f"empty required payload: {name}")
        contents[name] = data
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
    contents["manifest.sha256"] = "".join(f"{hashes[n]}  {n}\n" for n in NAMES).encode()
    if sum(map(len, contents.values())) > MAX_BYTES:
        raise ValueError("unpacked payload exceeds daemon 64 MiB bound")
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in contents.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
    data = stream.getvalue()
    if output.name.endswith(".tar.gz"):
        data = gzip.compress(data, mtime=0)
    elif output.suffix != ".tar":
        raise ValueError("output must end in .tar or .tar.gz")
    if len(data) > MAX_BYTES:
        raise ValueError("archive exceeds DMA staging 64 MiB bound")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Never replace a validated release/rollback file by accident.
    with output.open("xb") as dest:
        dest.write(data)
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        hashes = package(args.images, args.output)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")
    for name, digest in hashes.items():
        print(f"{digest}  {name}")
    print(f"Bundle: {args.output} ({args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
