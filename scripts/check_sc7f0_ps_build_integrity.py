#!/usr/bin/env python3
"""Re-check a matching-PS build log directory after the build finished.

`sha256sum -c PS_BUILD_INPUTS.sha256` is the wrong tool for a PetaLinux project:
petalinux-build rewrites project-spec/configs/config on every run (it puts the
auto-generated ``cma=1000M`` bootarg back even when the import pinned it), so the
naive check either fails on every good build or has to be dropped.  This splits
the two concerns:

  * every user-owned PS source input must be byte-identical to what was snapshotted
    before the build;
  * configs/config may only differ in CONFIG_SUBSYSTEM_BOOTARGS_GENERATED, and the
    build log must have recorded what was regenerated.

The device tree that actually ships is gated separately
(scripts/check_sc7f0_memory_layout.py), which is the check that matters: the
regenerated bootarg is harmless once the pinned chosen node overrules it.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ps-build', required=True, type=Path)
    args = ap.parse_args(argv)

    ps = args.ps_build.resolve()
    drifted, skipped = [], []
    for line in (ps / 'PS_BUILD_INPUTS.sha256').read_text().splitlines():
        digest, path = line.split('  ', 1)
        f = Path(path)
        if f.name == 'config' and f.parent.name == 'configs':
            skipped.append(str(f))
            continue
        if not f.is_file() or hashlib.sha256(f.read_bytes()).hexdigest() != digest:
            drifted.append(str(f))
    if drifted:
        print(f'PS_SOURCES_DRIFT {len(drifted)} file(s) changed during or after the build')
        for f in drifted:
            print(f'  - {f}')
        return 1

    before_path = ps / 'config-before-build'
    if not before_path.is_file():
        # Builds made before the bootargs regeneration was characterised recorded
        # no config snapshot.  Replay them with the original blanket check: if the
        # hardware import of that era left configs/config untouched, that is the
        # correct expectation and old releases must keep auditing unchanged.
        for line in (ps / 'PS_BUILD_INPUTS.sha256').read_text().splitlines():
            digest, path = line.split('  ', 1)
            f = Path(path)
            if not f.is_file() or hashlib.sha256(f.read_bytes()).hexdigest() != digest:
                print(f'PS_SOURCES_DRIFT {f} changed during or after the build')
                return 1
        print(f'PS_BUILD_INTEGRITY_PASS legacy mode (no config snapshot in {ps.name}): '
              f'every PS source input byte-identical')
        return 0

    before = before_path.read_text().splitlines()
    config_path = next(p for p in Path.cwd().glob(
        'petalinux/*/project-spec/configs/config'))
    after = config_path.read_text().splitlines()
    keep = lambda lines: [l for l in lines if not l.startswith('CONFIG_SUBSYSTEM_BOOTARGS_GENERATED=')]
    if keep(before) != keep(after):
        print('PS_CONFIG_DRIFT configs/config changed beyond the generated bootargs line')
        for b, a in zip(before, after):
            if b != a and not b.startswith('CONFIG_SUBSYSTEM_BOOTARGS_GENERATED='):
                print(f'  before: {b}\n  after : {a}')
        return 1
    regen = (ps / 'bootargs-regenerated.txt')
    assert regen.is_file(), 'build log has a config snapshot but does not record the regenerated bootargs'
    print(f'PS_BUILD_INTEGRITY_PASS {len(skipped)} auto-generated config exempted, '
          f'all other PS source inputs byte-identical, configs/config stable apart from '
          f'the regenerated bootargs line')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
