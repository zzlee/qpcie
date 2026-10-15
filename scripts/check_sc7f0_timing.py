#!/usr/bin/env python3
"""Fail-closed gate for the complete routed SC7F0 debug build, not just BRAM.

Vendor XPM FIFO CE/LUTRAM warnings still require source-level review; passing
this gate is necessary, NOT sufficient, for publication or hardware acceptance.
"""
import json
import math
from pathlib import Path
import re
import sys


def check(directory):
    directory = Path(directory)
    errors = []
    timing = (directory / 'timing_summary.rpt').read_text()
    coverage = (directory / 'check-timing.rpt').read_text()
    cdc = (directory / 'cdc.rpt').read_text()
    methodology = (directory / 'methodology.rpt').read_text()
    skew = (directory / 'bus-skew.rpt').read_text()
    if not re.search(r'Design State\s*:\s*Routed\b', timing):
        errors.append('timing report is not routed')
    table = re.search(r'^\s*WNS\(ns\).*WPWS\(ns\).*\n[^\n]*\n([^\n]+)', timing, re.M)
    if not table:
        raise ValueError('missing design timing summary')
    values = [float(x) for x in table[1].split()]
    if len(values) != 12 or not all(math.isfinite(x) for x in values):
        raise ValueError('invalid design timing summary')
    margins = dict(zip(('WNS', 'WHS', 'WPWS'), (values[0], values[4], values[8])))
    if any(x < 0 for x in margins.values()) or any(values[i] != 0 for i in (1, 2, 5, 6, 9, 10)):
        errors.append('setup/hold/pulse-width failure')
    counts = {}
    for name in ('no_clock', 'constant_clock', 'unconstrained_internal_endpoints',
                 'multiple_clock', 'generated_clocks', 'loops', 'latch_loops',
                 'partial_input_delay', 'partial_output_delay'):
        matches = re.findall(r'checking ' + name + r' \((\d+)\)', coverage)
        if not matches:
            raise ValueError('missing check_timing check: ' + name)
        counts[name] = max(map(int, matches))
        if counts[name]:
            errors.append(name + '=' + str(counts[name]))
    # Async PERST#/human LEDs may lack delays only if fully excepted. No
    # synchronous I/O endpoint may be hidden by that classification.
    if re.search(r'There are [1-9]\d* [^\n]*\(HIGH\)', coverage):
        errors.append('uncovered HIGH-severity endpoint')
    cdc_rows = re.findall(r'^(CDC-\d+)\s+(\w+)\s+(\d+)\s', cdc, re.M)
    if not cdc_rows:
        raise ValueError('missing CDC summary')
    cdc_counts = {rule: int(count) for rule, severity, count in cdc_rows}
    for rule, severity, count in cdc_rows:
        if int(count) and (severity == 'Critical' or rule in ('CDC-5', 'CDC-7')):
            errors.append(rule + ' ' + severity + '=' + count)
    if 'REPORT SUMMARY' not in methodology:
        raise ValueError('missing methodology summary')
    method_rows = re.findall(
        r'^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|', methodology, re.M)
    total = re.search(r'Violations found:\s*(\d+)', methodology)
    if not total or int(total[1]) != sum(int(row[2]) for row in method_rows):
        raise ValueError('missing/incomplete methodology summary')
    for rule, severity, count in method_rows:
        if int(count) and (severity in ('Critical Warning', 'Error') or rule in ('TIMING-9', 'TIMING-24')):
            errors.append(rule + ' ' + severity + '=' + count)
    skew_values = re.findall(r'^\s*(?:Slow|Fast)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*$', skew, re.M)
    if not skew_values:
        raise ValueError('missing bus-skew summary (expected XPM FIFO constraints)')
    skew_min = min(float(row[2]) for row in skew_values)
    if not math.isfinite(skew_min) or skew_min < 0:
        errors.append('bus-skew failure')
    result = dict(pass_gate=not errors, margins_ns=margins, coverage=counts,
                  cdc=cdc_counts, bus_skew_min_ns=skew_min, errors=errors)
    return result


if __name__ == '__main__':
    try:
        result = check(sys.argv[1])
    except (OSError, ValueError, IndexError) as exc:
        print('TIMING_GATE_FAIL: ' + str(exc), file=sys.stderr)
        sys.exit(2)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['pass_gate'] else 1)
