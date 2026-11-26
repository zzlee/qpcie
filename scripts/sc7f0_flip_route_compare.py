#!/usr/bin/env python3
"""Compare two routed Vivado reports; report facts, never grant a waiver."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def inspect(root):
    cdc = root / 'cdc.rpt'
    timing = root / 'timing_summary.rpt'
    util, = root.glob('*.runs/impl_1/*utilization_placed.rpt')
    counts, rows = {}, []
    src = dst = None
    for line in cdc.read_text().splitlines():
        if line.startswith('Source Clock:'):
            src = line.partition(':')[2].strip()
        elif line.startswith('Destination Clock:'):
            dst = line.partition(':')[2].strip()
        elif m := re.match(r'^(CDC-\d+)\s+\w+\s+(\d+)\s+', line):
            counts[m[1]] = int(m[2])
        elif m := re.match(r'^\s*\d+\s+(CDC-\d+)\s+(\w+)\s+', line):
            if not (src and dst):
                raise ValueError('CDC detail lacks clocks')
            a, b = line.split()[-2:]
            rows.append((m[1], m[2], src, dst, a, b))
    if Counter(r[0] for r in rows) != counts:
        raise ValueError(f'{cdc}: detail/summary count mismatch')
    text = timing.read_text()
    summary = re.search(r'^\s*WNS\(ns\).*?^[ \t]*(-?\d+(?:\.\d+)?(?:[ \t]+-?\d+(?:\.\d+)?){11})[ \t]*$',
                        text, re.M | re.S)
    if not summary or 'Design State      : Routed' not in text:
        raise ValueError(f'not a routed timing report: {timing}')
    fields = ('wns tns setup_failing setup_total whs ths hold_failing hold_total '
              'wpws tpws pw_failing pw_total').split()
    metrics = dict(zip(fields, map(float, summary[1].split())))
    paths = []
    for chunk in re.split(r'(?m)^Slack \(', text)[1:]:
        m = re.match(r'(?:MET|VIOLATED)\)\s*:\s*([-\d.]+)ns', chunk)
        if not m:
            continue
        item = {'slack_ns': float(m[1])}
        for key in ('Source', 'Destination', 'Path Group', 'Path Type', 'Requirement', 'Data Path Delay'):
            match = re.search(r'(?m)^\s*' + key + r':\s*(.+)$', chunk)
            item[key] = match[1].strip() if match else None
        paths.append(item)
    worst = {kind: sorted((p for p in paths if (p['Path Type'] or '').startswith(kind)),
                          key=lambda p: p['slack_ns'])[:8] for kind in ('Setup', 'Hold')}
    if not all(worst.values()):
        raise ValueError('incomplete setup/hold detail')
    resources = {}
    for line in util.read_text().splitlines():
        parts = [p.strip() for p in line.strip().strip('|').split('|')]
        if parts[0] in ('CLB LUTs', 'CLB Registers', 'Block RAM Tile', 'URAM', 'DSPs'):
            resources[parts[0]] = dict(used=parts[1], available=parts[-2], percent=parts[-1])
    if len(resources) != 5:
        raise ValueError('incomplete placed resource report')
    return dict(root=str(root), sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (cdc, timing, util)}, timing=metrics, worst=worst, placed_resources=resources,
                cdc_counts=counts), Counter(rows)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('baseline', type=Path)
    ap.add_argument('candidate', type=Path, nargs='?')
    args = ap.parse_args()
    base, before = inspect(args.baseline)
    out = dict(baseline=base, baseline_critical=[r for r in before.elements() if r[1]=='Critical'])
    if args.candidate:
        cand, after = inspect(args.candidate)
        out.update(candidate=cand, added=list((after-before).elements()), removed=list((before-after).elements()))
    print(json.dumps(out, indent=2))
