#!/usr/bin/env python3
"""Re-read a SC7F0 candidate image.ub after daemon injection, from its bytes.

scripts/build_sc7f0_matching_ps_vcu.sh (and the R7/R6 builders before it) inject
the four production ARM64 daemons plus the release marker into the FIT produced by
PetaLinux, and then verify the repacked image.  This is that verification, kept as
a standalone tool so a release step can re-derive it at any time instead of
trusting a log line written by the builder:

  * image.ub still equals the hash the builder recorded,
  * the FIT kernel and dtb are byte-identical to the build's Image.gz / system.dtb
    (injection must repack, never substitute),
  * the dtb inside the FIT still decodes the hardware VCU window,
  * etc/sc7f0-recovery-release declares the requested PL_BASE_VERSION,
  * every one of the four daemons in the rootfs is byte-identical to the ARM64
    binary on disk, mode 0755-ish, uid 0, with its unit enabled and its
    WatchdogSec= drop-in present, while RuntimeWatchdogSec=0 keeps the real
    supervision in the daemon health files,
  * no optional VCU daemon unit is wired into the board-required health set.

Offline, read-only.  Exit 0 prints VCU_INJECTED_FIT_READBACK_PASS.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_sc7f0_capture_image import cpio, resolve          # noqa: E402
from check_sc7f0_ps_watchdog_image import DUMP               # noqa: E402

DAEMONS = (('qpcie_upgrade_daemon', 'qpcie-upgrade-daemon.service'),
           ('qpcie_debugd', 'qpcie-debugd.service'),
           ('qpcie_hdmi_daemon', 'qpcie-hdmi-daemon.service'),
           ('sc7f0_ps_watchdog', 'sc7f0-ps-watchdog.service'))
MONITORED = ('qpcie-debugd', 'qpcie-hdmi-daemon', 'qpcie-upgrade-daemon')


def fit_component(img: Path, index: int, dest: Path) -> None:
    subprocess.run([DUMP, '-T', 'flat_dt', '-p', str(index), '-o', str(dest), str(img)],
                   check=True, capture_output=True)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--project', type=Path, default=Path('petalinux/qpcie-zu4ev'))
    ap.add_argument('--ps-build', type=Path, default=None,
                    help='matching PS build log directory (checks image-ub-final.sha256)')
    ap.add_argument('--base-version', default='0x26102902')
    ap.add_argument('--vcu-reg', type=lambda s: int(s, 0), default=0xB0100000)
    ap.add_argument('--dtc', default='/opt/Xilinx/Vitis/2023.2/bin/dtc')
    args = ap.parse_args(argv)

    base = args.base_version.lower()
    assert re.fullmatch(r'0x[0-9a-f]{8}', base), 'malformed --base-version'
    img_dir = args.project.resolve() / 'images/linux'
    img = img_dir / 'image.ub'
    assert img.is_file(), f'missing {img}'
    digest = hashlib.sha256(img.read_bytes()).hexdigest()
    if args.ps_build:
        record = Path(args.ps_build).resolve() / 'image-ub-final.sha256'
        if record.is_file():
            want = record.read_text().split()[0]
            assert want == digest, ('image.ub changed after the build recorded it', want, digest)
            print(f'IMAGE_UB_HASH_MATCHES_BUILD {digest}')
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='sc7f0-fit-readback-') as t:
        t = Path(t)
        for index, name in ((0, 'kernel.gz'), (1, 'dtb'), (2, 'rootfs.gz')):
            fit_component(img, index, t / name)
        assert (t / 'kernel.gz').read_bytes() == (img_dir / 'Image.gz').read_bytes(), \
            'FIT kernel drift'
        dtb = (t / 'dtb').read_bytes()
        assert dtb == (img_dir / 'system.dtb').read_bytes(), 'FIT dtb drift'
        dts = subprocess.run([args.dtc, '-I', 'dtb', '-O', 'dts', str(t / 'dtb')],
                             check=True, capture_output=True, text=True).stdout
        assert format(args.vcu_reg, 'x') in dts, \
            'the FIT device tree does not decode the VCU register window'
        print(f'FIT_COMPONENTS_INTACT kernel/dtb byte-exact, dtb decodes 0x{args.vcu_reg:x}')
        entries = cpio(gzip.decompress((t / 'rootfs.gz').read_bytes()))
        release = resolve(entries, 'etc/sc7f0-recovery-release')[2]
        assert b'PL_BASE_VERSION=' + base.encode() + b'\n' in release, release[:160]
        assert 'etc/systemd/system/multi-user.target.wants/sc7f0-vcud.service' not in entries, \
            'an optional VCU daemon must not enter the board-required health set'
        for binary, unit in DAEMONS:
            mode, uid, data = resolve(entries, 'usr/bin/' + binary)
            source = repo / 'test_app' / binary
            if source.is_file():
                assert data == source.read_bytes(), binary + ' is stale in image.ub'
            assert data[:4] == b'\x7fELF' and data[4] == 2, binary + ' is not a 64-bit ELF'
            assert int.from_bytes(data[18:20], 'little') == 183, binary + ' is not ARM64'
            assert uid == 0 and stat.S_ISREG(mode) and mode & 0o111, binary
            unit_key = 'lib/systemd/system/' + unit
            assert unit_key in entries and stat.S_ISREG(entries[unit_key][0]), unit
            enabled = 'etc/systemd/system/multi-user.target.wants/' + unit
            assert enabled in entries, (binary, enabled)
            assert resolve(entries, enabled)[2] == entries[unit_key][2], unit
            print(f'DAEMON_OK {binary} sha256={hashlib.sha256(data).hexdigest()} unit={unit}')
        for monitored in MONITORED:
            dropin = 'etc/systemd/system/%s.service.d/10-watchdog.conf' % monitored
            assert dropin in entries and b'WatchdogSec=' in entries[dropin][2], dropin
        manager = 'etc/systemd/system.conf.d/90-sc7f0-watchdog.conf'
        assert manager in entries and b'RuntimeWatchdogSec=0' in entries[manager][2], manager
        print('WATCHDOG_SUPERVISION_INTACT three monitored units, RuntimeWatchdogSec=0')
    print(f'VCU_INJECTED_FIT_READBACK_PASS PL base {base} declared, FIT components byte-exact, '
          f'VCU dtb intact, four ARM64 daemons current, units enabled with watchdog drop-ins, '
          f'no vcud unit')
    return 0


if __name__ == '__main__':
    sys.exit(main())
