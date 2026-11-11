#!/usr/bin/env python3
"""Gate the PS memory layout of a built/packaged image against a known-good card image.

Why this exists: importing the 0x26102902 encoder XSA silently regenerated
CONFIG_SUBSYSTEM_BOOTARGS_GENERATED with an extra ``cma=1000M``.  Nothing in the
offline audit noticed, the release passed, one COMMIT was issued, and the card
came back with a healthy PL (version register 0x26102902) but no PS userspace at
all (mailbox ``ready=0``, no heartbeat, PS DDR buffer register 0).  That card's
low DDR bank is 0x0-0x7ff00000 with dau_fpga 256 MB no-map plus 992 MB of
reusable shared-dma-pool regions and a root=/dev/ram0 initrd; a second, global
1 GB CMA request has no business being added underneath that.

The gate compares only the properties that decide whether Linux can live:

  * /chosen bootargs
  * every /memory node's reg
  * the whole /reserved-memory subtree (node set, reg, no-map, compatible)

Anything else in the tree (phandle churn, new PL peripherals) is deliberately
ignored, so the gate stays meaningful across hardware revisions.

Exit 0 prints MEMORY_LAYOUT_PASS.  A candidate whose bootargs differ, whose
memory banks differ, or whose reservation map differs exits nonzero.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sc7f0_fdt import cells, largest_tree, text  # noqa: E402


def load(path: Path) -> dict:
    if path.suffix == '.dtb':
        from sc7f0_fdt import walk
        return walk(path.read_bytes())
    return largest_tree(path.read_bytes())


def subtree(nodes: dict, prefix: str) -> dict[str, dict[str, bytes]]:
    return {k: v for k, v in nodes.items() if k == prefix or k.startswith(prefix + '/')}


def bootargs(nodes: dict) -> str:
    chosen = nodes.get('/chosen', {})
    return text(chosen.get('bootargs', b''))


def compare(baseline: dict, candidate: dict, expect_bootargs: str | None) -> list[str]:
    problems = []
    want_bootargs = expect_bootargs if expect_bootargs is not None else bootargs(baseline)
    got_bootargs = bootargs(candidate)
    if got_bootargs != want_bootargs:
        problems.append(f'bootargs drifted\n    baseline: {want_bootargs}\n    candidate: {got_bootargs}')

    mem_nodes = {k: v for k, v in baseline.items() if k.startswith('/memory')}
    for path in sorted(mem_nodes):
        if path not in candidate:
            problems.append(f'{path} missing from the candidate tree')
        elif candidate[path].get('reg') != mem_nodes[path].get('reg'):
            problems.append(f'{path}:reg {cells(mem_nodes[path]["reg"])} -> {cells(candidate[path].get("reg", b""))}')
    for path in sorted(k for k in candidate if k.startswith('/memory')):
        if path not in baseline:
            problems.append(f'{path} added by the candidate (memory bank appeared)')

    base_res, cand_res = subtree(baseline, '/reserved-memory'), subtree(candidate, '/reserved-memory')
    for path in sorted(set(base_res) | set(cand_res)):
        if path not in cand_res:
            problems.append(f'{path} removed from the reservation map')
        elif path not in base_res:
            problems.append(f'{path} added to the reservation map')
        elif base_res[path] != cand_res[path]:
            for key in sorted(set(base_res[path]) | set(cand_res[path])):
                # phandles renumber every time the tree changes and say nothing
                # about where memory lives, so they are not part of the layout.
                if key == 'phandle':
                    continue
                if base_res[path].get(key) != cand_res[path].get(key):
                    problems.append(f'{path}:{key} {base_res[path].get(key)} -> {cand_res[path].get(key)}')
    if not base_res:
        problems.append('baseline carries no /reserved-memory subtree; nothing was proven')
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--baseline', required=True, type=Path,
                    help='known-good image.ub or .dtb (the release that boots on the card)')
    ap.add_argument('--candidate', required=True, type=Path,
                    help='image.ub or .dtb under audit')
    ap.add_argument('--expect-bootargs', default=None,
                    help='override the expected bootargs instead of the baseline copy')
    ap.add_argument('--expect-label', default='baseline')
    args = ap.parse_args(argv)

    baseline, candidate = load(args.baseline), load(args.candidate)
    problems = compare(baseline, candidate, args.expect_bootargs)

    vcu = sorted(k for k in candidate if '/vcu@' in k or '/al5e@' in k)
    print(f'baseline          : {args.baseline}')
    print(f'candidate         : {args.candidate}')
    print(f'bootargs          : {bootargs(candidate)}')
    print(f'memory nodes      : {sorted(k for k in candidate if k.startswith("/memory"))}')
    print(f'reservations      : {len(subtree(candidate, "/reserved-memory"))} nodes, '
          f'{len(subtree(baseline, "/reserved-memory"))} in baseline')
    print(f'vcu/encoder nodes : {len(vcu)} (informational, not gated here)')
    if problems:
        print(f'MEMORY_LAYOUT_FAIL: {len(problems)} difference(s) vs {args.expect_label}')
        for item in problems:
            print(f'  - {item}')
        return 1
    print(f'MEMORY_LAYOUT_PASS bootargs, memory banks and the reservation map all match '
          f'{args.expect_label}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
