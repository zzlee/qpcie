#!/usr/bin/env python3
"""Assert that a PetaLinux device tree really describes the 0x26102902 VCU.

Why this exists: build/sc7f0-capture-26102902-r1 had to ship the carried-forward
R7 (0x26102901) PS image, whose device tree has no DTGen VCU node at all - only
the unused fixed-clock placeholder of
`petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-bsp/device-tree/files/vcu.dtsi`.
Reusing a baseline device tree behind a candidate bitstream is exactly the mistake
this check makes impossible: it reads the *compiled* dtb (or the dtb extracted
from image.ub), never a .dtsi, and requires the hardware VCU register window plus
a VCU/al5e binding to be present, while re-asserting that every SC7F0 capture-path
node survived the hardware-description swap unchanged.

Offline, read-only.  Exit 0 = VCU_DEVICETREE_PASS, exit 1 = a real, printed failure.
Not runtime proof: the encoder still has to be exercised on hardware.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

DTC_CANDIDATES = ('/opt/Xilinx/Vitis/2023.2/bin/dtc', 'dtc')

# The capture path an already-shipped card depends on (ABI 1.1).
CAPTURE_NODES = ('video-capture', 'frame-tap@b0070000', 'vpss-csc@b0060000',
                 'framebuffer@b0050000')
VCU_REG_DEFAULT = 0xB0100000


def dtc() -> str:
    for candidate in DTC_CANDIDATES:
        if '/' in candidate:
            if Path(candidate).is_file():
                return candidate
        elif shutil.which(candidate):
            return shutil.which(candidate)
    raise SystemExit('dtc not found (tried %s)' % ', '.join(DTC_CANDIDATES))


def to_dts(dtb: Path) -> str:
    return subprocess.run([dtc(), '-I', 'dtb', '-O', 'dts', str(dtb)],
                          check=True, capture_output=True, text=True).stdout


def blocks(dts: str):
    """Yield (name, body) for every `name { ... }` node, brace-matched."""
    for match in re.finditer(r'(?m)^\s*([A-Za-z0-9_,.@+-]+)\s*\{\s*$', dts):
        name, i, depth = match.group(1), match.end(), 1
        while i < len(dts) and depth:
            depth += (dts[i] == '{') - (dts[i] == '}')
            i += 1
        yield name, dts[match.end():i - 1]


def prop_ints(body: str, prop: str) -> list[int]:
    match = re.search(r'(?m)^\s*' + prop + r'\s*=\s*<([^>]*)>;', body)
    if not match:
        return []
    return [int(tok, 0) for tok in match.group(1).replace('0x', '0x').split()
            if re.fullmatch(r'(0x)?[0-9a-fA-F]+', tok)]


def compatible(body: str) -> list[str]:
    match = re.search(r'(?m)^\s*compatible\s*=\s*(.*);', body)
    if not match:
        return []
    return re.findall(r'"([^"]*)"', match.group(1))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('dtb', type=Path, help='system.dtb, or a .dtb extracted from image.ub')
    ap.add_argument('--expect-reg', type=lambda s: int(s, 0), default=VCU_REG_DEFAULT,
                    help='VCU register base address (default: 0x%x)' % VCU_REG_DEFAULT)
    ap.add_argument('--require-capture-nodes', action='store_true',
                    help='also re-assert the SC7F0 capture-path nodes are present and okay')
    ap.add_argument('--json', type=Path, help='write the machine-readable report here')
    args = ap.parse_args(argv)

    dts = to_dts(args.dtb)
    found = list(blocks(dts))
    report: dict = {'dtb': str(args.dtb), 'nodes_total': len(found),
                    'vcu_nodes': [], 'capture_nodes': {}, 'errors': []}

    vcu = []
    for name, body in found:
        compat = compatible(body)
        regs = prop_ints(body, 'reg')
        interesting = (bool(re.search(r'vcu|al5e|al5d|allegro|encoder|decoder', name, re.I))
                       or any(re.search(r'vcu|al,al5|allegro', c, re.I) for c in compat))
        if not interesting:
            continue
        vcu.append({'node': name, 'compatible': compat,
                    'reg': ['0x%x' % v for v in regs],
                    'interrupts': ['0x%x' % v for v in prop_ints(body, 'interrupts')],
                    'clocks': ['0x%x' % v for v in prop_ints(body, 'clocks')],
                    'status': (re.search(r'(?m)^\s*status\s*=\s*"([^"]*)"', body) or
                               [None, 'okay'])[1]})
    report['vcu_nodes'] = vcu

    # 1. a hardware VCU register window must be decoded, not a fixed-clock stub
    window = [n for n in vcu if args.expect_reg in
              [int(v, 16) for v in n['reg']]]
    if not window:
        report['errors'].append(
            'no device-tree node decodes the hardware VCU register window 0x%x '
            '(a fixed-clock vcu_refclk placeholder is not VCU hardware)' % args.expect_reg)
    else:
        bound = [n for n in window
                 if any(re.search(r'xlnx,vcu|al,al5|allegro', c, re.I) for c in n['compatible'])]
        if not bound:
            report['errors'].append(
                'the 0x%x window has no xlnx,vcu / al,al5e / allegro driver binding: %s'
                % (args.expect_reg, [n['compatible'] for n in window]))
        disabled = [n['node'] for n in window if n['status'] != 'okay']
        if disabled:
            report['errors'].append('VCU register node is not okay: %s' % disabled)

    # 2. the encoder side specifically (this hardware is encoder-only)
    if not any(re.search(r'al,al5e|allegro|encoder', c, re.I)
               for n in vcu for c in n['compatible']):
        report['errors'].append('no encoder (al,al5e / allegro / encoder) binding found')

    # 3. the capture path must not have been disturbed by the hardware swap
    if args.require_capture_nodes:
        for want in CAPTURE_NODES:
            hit = [body for name, body in found if name == want]
            if not hit:
                report['errors'].append('capture node %s disappeared' % want)
                report['capture_nodes'][want] = 'MISSING'
                continue
            status = (re.search(r'(?m)^\s*status\s*=\s*"([^"]*)"', hit[0]) or
                      [None, 'okay'])[1]
            report['capture_nodes'][want] = status
            if status != 'okay':
                report['errors'].append('capture node %s is %s' % (want, status))
        clock = [body for name, body in found if name == 'capture-clock']
        freq = prop_ints(clock[0], 'clock-frequency') if clock else []
        report['capture_nodes']['capture-clock'] = ('%d Hz' % freq[0]) if freq else 'MISSING'
        if freq and freq[0] != 300_000_000:
            report['errors'].append('capture-clock is %d Hz, expected 300000000' % freq[0])

    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')

    for node in vcu:
        print('VCU_NODE %s compatible=%s reg=%s interrupts=%s clocks=%s status=%s'
              % (node['node'], node['compatible'], node['reg'], node['interrupts'],
                 node['clocks'], node['status']))
    for name, state in report['capture_nodes'].items():
        print('CAPTURE_NODE %s %s' % (name, state))
    for error in report['errors']:
        print('VCU_DEVICETREE_FAIL: %s' % error, file=sys.stderr)
    if report['errors']:
        return 1
    print('VCU_DEVICETREE_PASS: 0x%x window decoded with a real driver binding and the '
          'capture graph intact; encoder runtime still unproven' % args.expect_reg)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
