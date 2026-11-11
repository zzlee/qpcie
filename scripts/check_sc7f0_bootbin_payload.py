#!/usr/bin/env python3
"""Prove that a release BOOT.BIN really carries this release's own bitstream.

bootgen is deterministic for identical inputs except for a small build-stamp
inside the PTFH authentication header (observed at 0x950..0x96b, i.e. inside the
first 0x1000 boot-header bytes).  This tool re-renders BOOT.BIN in a scratch
directory from the release's own boot components plus the release's own
fpga/zu4ev_pcie_card_top.bit, and then requires:

  * identical file size,
  * every differing byte to live below 0x1000 (header stamp region),
  * byte-identical payload from 0x1000 to EOF, which is where FSBL, PMUFW, the
    PL bitstream, bl31, dtb and u-boot images sit.

A foreign bitstream can optionally be supplied with --negative-bit; the rebuilt
image must then differ in the payload, otherwise the test proves nothing.

Offline (bootgen only, no card, no Vivado project).

    scripts/check_sc7f0_bootbin_payload.py --release-dir build/sc7f0-capture-26102902-r1 \
        --negative-bit build/sc7f0-capture-26102901-r1/fpga/zu4ev_pcie_card_top.bit
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

COMPONENTS = ("zynqmp_fsbl.elf", "pmufw.elf", "bl31.elf", "u-boot.elf", "system.dtb")
HEADER_BYTES = 0x1000
BOOTGEN_DEFAULT = "/opt/Xilinx/Vivado/2023.2/bin/bootgen"


def render(bootgen: Path, work: Path, bit: Path) -> bytes:
    comps = {name: work / name for name in COMPONENTS}
    for name, dest in comps.items():
        if not dest.is_file():
            raise ValueError(f"missing boot component copy: {name}")
    lines = ["the_ROM_image:", "{",
             f"\t[bootloader, destination_cpu=a53-0] {comps['zynqmp_fsbl.elf']}",
             f"\t[pmufw_image] {comps['pmufw.elf']}",
             f"\t[destination_device=pl] {bit}",
             f"\t[destination_cpu=a53-0, exception_level=el-3, trustzone] {comps['bl31.elf']}",
             f"\t[destination_cpu=a53-0, load=0x00100000] {comps['system.dtb']}",
             f"\t[destination_cpu=a53-0, exception_level=el-2] {comps['u-boot.elf']}", "}"]
    bif = work / "probe.bif"
    bif.write_text("\n".join(lines) + "\n")
    out = work / "BOOT.BIN"
    subprocess.run([str(bootgen), "-arch", "zynqmp", "-image", str(bif), "-o", str(out),
                    "-w", "on"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return out.read_bytes()


def compare(shipped: bytes, probe: bytes) -> tuple[list[int], int]:
    if len(shipped) != len(probe):
        raise ValueError(f"size differs: shipped {len(shipped)} vs rebuilt {len(probe)} "
                         "(bootgen inputs are not the same bytes)")
    diffs = [i for i in range(len(shipped)) if shipped[i] != probe[i]]
    outside = [i for i in diffs if i >= HEADER_BYTES]
    if outside:
        raise ValueError(f"{len(outside)} differing bytes outside the boot header, first at "
                         f"{hex(outside[0])}: the shipped BOOT.BIN is not this bitstream")
    return diffs, len(shipped)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--release-dir", type=Path, required=True)
    p.add_argument("--bootgen", type=Path,
                   default=Path(os.environ.get("SC7F0_BOOTGEN", BOOTGEN_DEFAULT)))
    p.add_argument("--negative-bit", type=Path, default=None,
                   help="foreign bitstream for the sensitivity control")
    a = p.parse_args(argv)
    rel = a.release_dir.resolve()
    bootbin = rel / "images/BOOT.BIN"
    bit = rel / "fpga/zu4ev_pcie_card_top.bit"
    if not a.bootgen.is_file():
        raise SystemExit(f"bootgen not found at {a.bootgen} (set SC7F0_BOOTGEN)")
    shipped = bootbin.read_bytes()
    payload_sha = None
    with tempfile.TemporaryDirectory(prefix="sc7f0-bootbin-") as tmp:
        work = Path(tmp)
        for name in COMPONENTS:
            shutil.copyfile(rel / "images" / name, work / name)
        probe = render(a.bootgen, work, bit.resolve())
        diffs, size = compare(shipped, probe)
        payload_sha = hashlib.sha256(probe[HEADER_BYTES:]).hexdigest()
        print(f"shipped   {bootbin} size={size} sha256={hashlib.sha256(shipped).hexdigest()}")
        print(f"rebuilt   bootgen({' '.join(COMPONENTS)} + {bit}) -> identical payload")
        print(f"header-stamp bytes differing ({len(diffs)}): "
              f"{[hex(i) for i in diffs[:3]]}{'…' if len(diffs) > 3 else ''} all < {hex(HEADER_BYTES)}")
        print(f"payload sha256[{hex(HEADER_BYTES)}:EOF] = {payload_sha}")
        if a.negative_bit is not None:
            neg = render(a.bootgen, work, a.negative_bit.resolve())
            ndiff = sum(1 for i in range(0, min(len(neg), len(probe)), 512)
                        if neg[i:i + 512] != probe[i:i + 512])
            if neg[HEADER_BYTES:] == probe[HEADER_BYTES:]:
                raise ValueError(f"negative control {a.negative_bit} produced an identical payload: "
                                 "the test would prove nothing")
            print(f"negative control {a.negative_bit}: {ndiff} differing 512-B blocks "
                  "(payload is bitstream-sensitive)")
    print(f"BOOTBIN_PAYLOAD_MATCH sha256={hashlib.sha256(shipped).hexdigest()} "
          f"payload_sha256={payload_sha}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(f"BOOTBIN_PAYLOAD_FAIL: bootgen exited {exc.returncode}", file=sys.stderr)
        raise SystemExit(1)
