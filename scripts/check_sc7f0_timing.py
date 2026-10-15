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


# Narrow reviewed structures, NOT clock exceptions or a blanket TIMING-9 waiver.
# Data crosses FIFOs under synchronized Gray-pointer/empty/full protection.
FIFO_ROOTS = (
    'u_dma_top/u_axil_reg_space/u_controls/u_fifo/gnuram_async_fifo.xpm_fifo_base_inst',
    'u_dma_top/u_axil_reg_space/u_status/u_fifo/gnuram_async_fifo.xpm_fifo_base_inst',
    'u_dma_top/u_upg_cdc/inst/gen_async_conv.axisc_async_clock_converter_0/xpm_fifo_async_inst/gnuram_async_fifo.xpm_fifo_base_inst',
)


def reviewed_crossing(rule, src, dest):
    if rule == 'CDC-6':
        # These are independent sticky flags, never a coherent numeric bus.
        root = 'u_dma_top/u_zu4ev_upg_diag/'
        if src == root + 'pcie_sticky_reg[12:0]/C' and dest == root + 'u_levels/syncstages_ff_reg[0][12:0]/D':
            return 'independent_sticky_flags'
    if rule != 'CDC-15':
        return None
    for root in FIFO_ROOTS:
        if src.startswith(root + '/') and dest.startswith(root + '/'):
            return 'XPM_FIFO'
    markers = (
        '/U_CMD6_WR/U_WR_FIFO/SUBCORE_FIFO.xsdbm_v3_0_0_wrfifo_inst/inst_fifo_gen/',
        '/U_CMD6_RD/U_RD_FIFO/SUBCORE_FIFO.xsdbm_v3_0_0_rdfifo_inst/inst_fifo_gen/',
    )
    if (src.startswith('dbg_hub/') and dest.startswith('dbg_hub/')
            and any(marker in src and marker in dest for marker in markers)
            and src.split('/inst_fifo_gen/')[0] == dest.split('/inst_fifo_gen/')[0]):
        return 'vendor_debug_hub_FIFO'
    # GT Wizard 1.7.17 disables testclk_en through two synchronizers, then
    # waits 16 ref-clock cycles in HOLD before latching this 18-bit counter.
    match = re.fullmatch(r'(u_pcie_ip/.*/gtwizard_ultrascale_v1_7_17_gthe4_cpll_cal_tx_i/U_TXOUTCLK_FREQ_COUNTER)/testclk_cnt_reg\[(\d+)\]/C', src)
    if match and int(match[2]) < 18 and dest == match[1] + '/freq_cnt_o_reg[' + match[2] + ']/D':
        return 'vendor_CPLL_held_counter'
    return None


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
    for name in ('no_clock', 'constant_clock', 'pulse_width_clock', 'unconstrained_internal_endpoints',
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
    cdc_rows = re.findall(r'^(CDC-\d+)\s+([A-Za-z ]+?)\s+(\d+)\s', cdc, re.M)
    raw_rows = re.findall(r'^CDC-\d+\b[^\n]*', cdc, re.M)
    cdc_counts = {rule: int(count) for rule, severity, count in cdc_rows}
    if not cdc_rows or len(cdc_rows) != len(raw_rows) or len(cdc_counts) != len(cdc_rows):
        raise ValueError('missing/malformed/duplicate CDC summary')
    for rule, severity, count in cdc_rows:
        if int(count) and (severity not in ('Info', 'Warning') or rule in ('CDC-5', 'CDC-7')
                           or (severity == 'Info' and rule not in ('CDC-3', 'CDC-9'))):
            errors.append(rule + ' ' + severity + '=' + count)
    if re.search(r'^\s*\d+\s+CDC-\d+\s+(?:Critical(?: Warning)?|Error)\b', cdc, re.M):
        errors.append('critical CDC detail (even if missing from summary)')
    # Account for EVERY warning in the detailed report. Summary-only reports,
    # new/custom CE crossings and unexpected array synchronizers fail closed.
    detail_counts = {}
    reviewed = {}
    unreviewed = []
    for line in cdc.splitlines():
        match = re.match(r'\s*\d+\s+(CDC-\d+)\s+Warning\s+', line)
        if not match:
            continue
        rule = match[1]
        detail_counts[rule] = detail_counts.get(rule, 0) + 1
        src, dest = line.split()[-2:]
        kind = reviewed_crossing(rule, src, dest)
        if kind:
            reviewed[kind] = reviewed.get(kind, 0) + 1
        else:
            unreviewed.append([rule, src, dest])
    expected_details = {rule: int(count) for rule, severity, count in cdc_rows
                        if severity == 'Warning' and int(count)}
    if detail_counts != expected_details:
        errors.append('missing/incomplete detailed CDC warnings')
    if unreviewed:
        errors.append('unreviewed CDC warnings: ' + str(len(unreviewed)))
    if 'REPORT SUMMARY' not in methodology:
        raise ValueError('missing methodology summary')
    method_rows = re.findall(
        r'^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|', methodology, re.M)
    total = re.search(r'Violations found:\s*(\d+)', methodology)
    if not total or int(total[1]) != sum(int(row[2]) for row in method_rows):
        raise ValueError('missing/incomplete methodology summary')
    for rule, severity, count in method_rows:
        if int(count) and (severity in ('Critical Warning', 'Error') or rule not in ('DPIR-2', 'LUTAR-1', 'TIMING-9')):
            errors.append(rule + ' ' + severity + '=' + count)
        if rule == 'TIMING-9' and int(count):
            # Vivado emits this aggregate warning for the legitimate held-data
            # structures above as well. Permit it ONLY with complete path-level
            # accounting, no unknown paths, and all other CDC/clock gates intact.
            if int(count) != 1 or not reviewed or unreviewed or detail_counts != expected_details:
                errors.append('TIMING-9 without complete reviewed CDC evidence')
    skew_values = re.findall(r'^\s*(?:Slow|Fast)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*$', skew, re.M)
    if not skew_values:
        raise ValueError('missing bus-skew summary (expected XPM FIFO constraints)')
    skew_min = min(float(row[2]) for row in skew_values)
    if not math.isfinite(skew_min) or skew_min < 0 or '(VIOLATED)' in skew:
        errors.append('bus-skew failure')
    result = dict(pass_gate=not errors, margins_ns=margins, coverage=counts,
                  cdc=cdc_counts, reviewed_cdc=reviewed, unreviewed_cdc=unreviewed[:10],
                  bus_skew_min_ns=skew_min, errors=errors)
    return result


if __name__ == '__main__':
    try:
        result = check(sys.argv[1])
    except (OSError, ValueError, IndexError) as exc:
        print('TIMING_GATE_FAIL: ' + str(exc), file=sys.stderr)
        sys.exit(2)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['pass_gate'] else 1)
