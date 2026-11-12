#!/usr/bin/env python3
"""Fail-closed two-layer gate for the complete routed SC7F0 build.

Layer A - correctness, must be empty, never policy-negotiable
    setup/hold/WPWS margins and TNS, bus-skew violations, DRC Error/Critical,
    critical CDC (CDC-5/7/10/12/13 or any Critical/Error detail, including a new
    Critical that this file has never seen), uncovered HIGH-severity endpoints,
    a design state that does not prove the design was routed, and any report
    that cannot be parsed.  Unknown severities and unknown counts are Layer A
    failures, because "the file exists and has words in it" is not a result.

    Margin arithmetic, spelled out because it was misread in the handover: a
    margin of exactly 0.000 ns is legal (met, no slack) and only a negative margin
    fails, while every TNS column must be exactly 0.000 - a total negative slack of
    0 with 0 failing endpoints is what "closed" means, it is not a missing result.
    NaN/inf are rejected by isfinite, and a missing summary row raises.

Layer B - itemised review, every Warning/Advisory must be carried by evidence
    scripts/gates/sc7f0_cdc_review.json, sc7f0_drc_review.json,
    sc7f0_clock_pair_review.json classify each CDC / methodology / DRC finding by
    rule + exact root + source/dest structure, and each claim is re-verified
    against *this* round's reports (report_exceptions coverage, bus skew,
    report_clock_interaction and the named-constraint coverage manifest that the
    implementation hook regenerates).  A vendor Warning is not ignored in bulk
    and not whitelisted by root-name prefix alone; a finding with no entry, a
    duplicate entry, an entry that matched nothing, or prose-only evidence all
    fail.  Items still needing work (RX-DDC first stage without ASYNC_REG, the
    TX TMDS pad, LUTAR-1, TIMING-9/18, RTSTAT-10) are declared
    NEEDS_STRUCTURAL_REVIEW / BLOCKED and keep the gate red until reviewed.

`pass_gate` is the conjunction of both layers, so the release path cannot pass
while a finding is unreviewed, and Layer A cannot be relaxed by editing a policy
file.  Passing is necessary, NOT sufficient, for hardware acceptance.
"""
import json
import math
from pathlib import Path
import re
import sys

try:
    import sc7f0_review_policy as review
except ModuleNotFoundError:  # loaded by importlib/exec from another directory
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import sc7f0_review_policy as review

# Retained for the legacy structural unit test (tb/sc7f0_timing_gate_tb.py) and
# as a readable list of the three originally reviewed FIFO roots.  The
# authoritative per-root review list, with evidence, is
# scripts/gates/sc7f0_cdc_review.json - scripts/tests/test_sc7f0_two_layer_gates.py
# fails if a legacy root loses its policy entry, so the two cannot drift apart.
FIFO_ROOTS = (
    'u_dma_top/u_axil_reg_space/u_controls/u_fifo/gnuram_async_fifo.xpm_fifo_base_inst',
    'u_dma_top/u_axil_reg_space/u_status/u_fifo/gnuram_async_fifo.xpm_fifo_base_inst',
    'u_dma_top/u_upg_cdc/inst/gen_async_conv.axisc_async_clock_converter_0/xpm_fifo_async_inst/gnuram_async_fifo.xpm_fifo_base_inst',
)


def reviewed_crossing(rule, src, dest):
    """Legacy narrow structural matcher, kept so its negative cases stay testable."""
    if rule == 'CDC-6':
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
    match = re.fullmatch(r'(u_pcie_ip/.*/gtwizard_ultrascale_v1_7_17_gthe4_cpll_cal_tx_i/U_TXOUTCLK_FREQ_COUNTER)/testclk_cnt_reg\[(\d+)\]/C', src)
    if match and int(match[2]) < 18 and dest == match[1] + '/freq_cnt_o_reg[' + match[2] + ']/D':
        return 'vendor_CPLL_held_counter'
    return None


def design_state(timing: str) -> str:
    """Vivado's own words for how far implementation got, read from the report header.

    An earlier version of this gate asked for the literal 'Routed', which is what
    Vivado writes when implementation ends at route_design. With post-route physical
    optimization the same - or a strictly better - design reports 'Physopt postRoute',
    and the gate then rejected a fully routed design (r3/26111103: 179530/179530 nets
    fully routed, 0 nets with routing errors). Anything that is not provably at or
    after routing - and anything unrecognised - stays a failure, so this list can
    only ever be widened by a deliberate edit, never by a report that merely looks
    friendly.
    """
    match = re.search(r'Design State\s*:\s*(.+?)\s*$', timing, re.M)
    if not match:
        raise ValueError('timing report has no Design State header')
    return match.group(1)


# States that are at or after route_design. 'Physopt preRoute' is deliberately absent:
# place-mode phys_opt runs before routing and its timing says nothing about routing.
POST_ROUTE_DESIGN_STATES = ('Routed', 'Physopt postRoute', 'Fully Routed')
PRE_ROUTE_DESIGN_STATES = ('Synthesized', 'Optimized', 'Placed', 'Physopt preRoute')

# report_cdc rules that describe a structural CDC defect, independent of how a
# particular report labels the severity. A round that files CDC-13 as a Warning
# (or a future rule in this family) still fails Layer A: severity relabelled is
# exactly how a Critical defect would otherwise reach Layer B, and Layer B is
# policy-editable while Layer A is not.
ALWAYS_CRITICAL_CDC_RULES = ('CDC-5', 'CDC-7', 'CDC-10', 'CDC-12', 'CDC-13')

# report_methodology rules that are correctness facts, not review opinions.
# TIMING-3 is an invalid clock source on a GT site; TIMING-24 means a timing
# exception the round declared was overridden by a more specific one, i.e. the
# max delay the CDC plan relies on is not in effect. Neither may be waived by a
# Layer B ledger entry, because the ledger would only be restating the same
# assumption that the report already contradicted.
ALWAYS_FATAL_METHODOLOGY_RULES = {
    'TIMING-3': 'invalid GT clock pair (methodology)',
    'TIMING-24': 'declared CDC max delay overridden by a more specific exception',
}


def classify_design_state(state):
    """Return None when `state` proves the design was routed, else the gate error."""
    if state in POST_ROUTE_DESIGN_STATES:
        return None
    if state in PRE_ROUTE_DESIGN_STATES:
        return f'timing report is not routed (Design State: {state})'
    return (f'timing report Design State {state!r} is not a known post-route state; '
            'refusing to assume the design was routed - check the Vivado version/flow '
            'and add the state only if it is genuinely at or after route_design')


def _read(directory, name, required=True):
    path = Path(directory) / name
    if not path.is_file():
        if required:
            raise ValueError(f'missing report {name}')
        return None
    return path.read_text(errors='ignore')


def parse_cdc(text):
    """Return (summary_counts, detail_rows, raw_row_count).

    Summary rows look like `CDC-15  Warning  4614  Clock enable ...`; detail rows
    are the fixed-width `Row ID Severity Description Depth Exception Src Dst`
    table written by `report_cdc -details`.  Columns are separated by at least two
    spaces, so an empty Exception column cannot shift the source/destination
    fields into the wrong slot.
    """
    rows = []
    for line in text.splitlines():
        if not re.match(r'\s*\d+\s+CDC-\d+\s', line):
            continue
        stripped = line.strip()
        tokens = re.split(r'\s{2,}', stripped)
        exception = src = dest = ''
        if len(tokens) >= 8:
            rule, severity = tokens[1], tokens[2]
            exception, src, dest = tokens[-3], tokens[-2], tokens[-1]
        elif len(tokens) == 7:
            rule, severity = tokens[1], tokens[2]
            src, dest = tokens[-2], tokens[-1]
        else:
            # Column alignment collapsed (hand-made or copy-pasted report): take
            # the endpoints from the ends and recover the exception phrase, so an
            # unaligned report is read instead of being mistaken for "no detail
            # rows" - which would look like a summary/detail mismatch.
            narrow = stripped.split()
            if len(narrow) < 6:
                continue
            rule, severity = narrow[1], narrow[2]
            src, dest = narrow[-2], narrow[-1]
            middle = ' '.join(narrow[3:-2])
            for phrase in ('Max Delay Datapath Only', 'Asynch Clock Groups',
                           'False Path', 'Min Delay', 'Multicycle', 'None'):
                if phrase in middle:
                    exception = phrase
                    break
        rows.append({'rule': rule, 'severity': severity, 'exception': exception.strip(),
                     'src': src.strip(), 'dest': dest.strip()})
    summary = re.findall(r'^(CDC-\d+)\s+([A-Za-z ]+?)\s+(\d+)\s', text, re.M)
    counts = {rule: (severity.strip(), int(count)) for rule, severity, count in summary}
    return counts, rows, len(re.findall(r'^CDC-\d+\b[^\n]*', text, re.M))


def parse_drc_report(text):
    """Split report_drc into header total, summary table and detail section."""
    total = re.search(r'Violations found:\s*(\d+)', text)
    if not total:
        raise ValueError('DRC report has no "Violations found" total')
    total = int(total.group(1))
    summary = re.findall(r'^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|',
                         text, re.M)
    if total and not summary:
        raise ValueError('DRC report declares violations but has no summary table')
    marker = re.search(r'^2\.\s+REPORT DETAILS', text, re.M)
    if not marker:
        raise ValueError('DRC report has no REPORT DETAILS section (Max violations or '
                         'a truncated report hides findings)')
    return total, {rule: (severity.strip(), int(count))
                   for rule, severity, count in summary}, text[marker.end():]


def high_uncovered_ports(coverage: str):
    """Ports check_timing still lists as HIGH.

    A HIGH section is `(HIGH)` followed by a blank line and one port per line,
    so the list ends at the first blank line; anything that looks like prose, a
    rule heading or a number is not a port name.
    """
    ports = []
    for match in re.finditer(r'\(HIGH\)\n\n((?:(?!^\s)[^\n]*\n)+)', coverage, re.M):
        for line in match.group(1).splitlines():
            token = line.strip()
            if not token or ' ' in token or token.startswith(('-', '=', 'There')):
                continue
            if token[0].isdigit() or token.endswith((':', ')')):
                continue
            ports.append(token)
    return ports


def check(directory, policy_dir=None):
    directory = Path(directory)
    errors = []           # Layer A: correctness, plus anything unparseable
    timing = _read(directory, 'timing_summary.rpt')
    coverage = _read(directory, 'check-timing.rpt')
    cdc = _read(directory, 'cdc.rpt')
    methodology = _read(directory, 'methodology.rpt')
    skew = _read(directory, 'bus-skew.rpt')
    state = design_state(timing)
    state_error = classify_design_state(state)
    if state_error:
        errors.append(state_error)
    table = re.search(r'^\s*WNS\(ns\).*WPWS\(ns\).*\n[^\n]*\n([^\n]+)', timing, re.M)
    if not table:
        raise ValueError('missing design timing summary')
    values = [float(x) for x in table[1].split()]
    if len(values) != 12 or not all(math.isfinite(x) for x in values):
        raise ValueError('invalid design timing summary')
    margins = dict(zip(('WNS', 'WHS', 'WPWS'), (values[0], values[4], values[8])))
    tns = dict(zip(('TNS', 'THS', 'TPWS'), (values[1], values[5], values[9])))
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
    uncovered_high = high_uncovered_ports(coverage)
    uncovered_high_found = bool(re.search(r'There are [1-9]\d* [^\n]*\(HIGH\)', coverage))
    if uncovered_high_found:
        errors.append('uncovered HIGH-severity endpoint')
    cdc_counts, cdc_rows, raw_summary_lines = parse_cdc(cdc)
    summary_rows = re.findall(r'^(CDC-\d+)\s+([A-Za-z ]+?)\s+(\d+)\s', cdc, re.M)
    if not summary_rows or len({rule for rule, _, _ in summary_rows}) != len(summary_rows):
        raise ValueError('missing/malformed/duplicate CDC summary')
    if raw_summary_lines != len(summary_rows):
        raise ValueError('CDC summary line count does not match the parsed rules')
    critical_cdc = []
    for rule, (severity, count) in cdc_counts.items():
        if not count:
            continue
        if rule in ALWAYS_CRITICAL_CDC_RULES:
            finding = rule + ' ' + severity + '=' + str(count)
            if not review.is_critical_severity(severity):
                finding += (' (this rule is critical by definition; a report that '
                            'files it as ' + severity + ' is misclassified)')
            errors.append(finding)
            critical_cdc.append(finding)
            continue
        if (not review.is_non_critical_severity(severity)
                or (severity.lower() == 'info' and rule not in ('CDC-3', 'CDC-9'))):
            finding = rule + ' ' + severity + '=' + str(count)
            errors.append(finding)
            critical_cdc.append(finding)
    if re.search(r'^\s*\d+\s+CDC-\d+\s+(?:Critical(?: Warning)?|Error)\b', cdc, re.M):
        finding = 'critical CDC detail (even if missing from summary)'
        errors.append(finding)
        critical_cdc.append(finding)
    # Account for EVERY warning in the detailed report. Summary-only reports,
    # new/custom CE crossings and unexpected array synchronizers fail closed.
    detail_counts = {}
    for row in cdc_rows:
        if row['severity'].strip().lower() in ('warning', 'advisory'):
            detail_counts[row['rule']] = detail_counts.get(row['rule'], 0) + 1
    expected_details = {rule: count for rule, (severity, count) in cdc_counts.items()
                        if severity.strip().lower() in ('warning', 'advisory') and count}
    if detail_counts != expected_details:
        errors.append('missing/incomplete detailed CDC warnings')

    # ---- Layer A: DRC is mandatory (AGENTS.md) and its report must be whole ----
    drc_text = _read(directory, 'drc.rpt', required=False)
    drc_summary = {}
    drc_parsed = {}
    if drc_text is None:
        errors.append('missing DRC report (report_drc is required by AGENTS.md; '
                      'a build that never reports DRC cannot be graded)')
    else:
        drc_total, drc_summary, drc_details = parse_drc_report(drc_text)
        drc_parsed, drc_parse_errors = review.parse_drc(drc_details, drc_total)
        errors.extend('DRC: ' + e for e in drc_parse_errors)
        if sum(count for _, count in drc_summary.values()) != drc_total:
            raise ValueError('DRC summary rows do not sum to "Violations found"')
        for rule, (severity, count) in drc_summary.items():
            if rule not in drc_parsed:
                raise ValueError(f'DRC summary rule {rule} has no detail block')
            if drc_parsed[rule]['count'] != count:
                raise ValueError(f'DRC rule {rule}: summary says {count}, details show '
                                 f"{drc_parsed[rule]['count']}")
            if drc_parsed[rule]['severity'].lower() != severity.lower():
                raise ValueError(f'DRC rule {rule}: summary severity {severity} != '
                                 f"detail {drc_parsed[rule]['severity']}")
            if count and review.is_critical_severity(severity):
                errors.append(f'DRC {rule} {severity}={count}')
            elif count and not review.is_non_critical_severity(severity):
                # A severity word this gate has never seen is not "probably fine":
                # it is unread, so no allow-list below may be trusted for it.
                errors.append(f'DRC {rule} severity {severity!r} is not a severity this '
                              'gate recognises (error / critical warning / warning / '
                              'advisory / info): the finding is unclassified, not '
                              'accepted')

    if 'REPORT SUMMARY' not in methodology:
        raise ValueError('missing methodology summary')
    method_rows = re.findall(
        r'^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|', methodology, re.M)
    total = re.search(r'Violations found:\s*(\d+)', methodology)
    if not total or int(total[1]) != sum(int(row[2]) for row in method_rows):
        raise ValueError('missing/incomplete methodology summary')
    methodology_summary = {rule: (severity.strip(), int(count))
                           for rule, severity, count in method_rows}
    critical_methodology = []
    for rule, (severity, count) in methodology_summary.items():
        if count and rule in ALWAYS_FATAL_METHODOLOGY_RULES:
            finding = (rule + ' ' + severity + '=' + str(count) + ' ('
                       + ALWAYS_FATAL_METHODOLOGY_RULES[rule] + ')')
            errors.append(finding)
            critical_methodology.append(finding)
        elif count and review.is_critical_severity(severity):
            finding = rule + ' ' + severity + '=' + str(count)
            errors.append(finding)
            critical_methodology.append(finding)
    skew_values = re.findall(r'^\s*(?:Slow|Fast)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*$', skew, re.M)
    if not skew_values:
        raise ValueError('missing bus-skew summary (expected XPM FIFO constraints)')
    skew_min = min(float(row[2]) for row in skew_values)
    if not math.isfinite(skew_min) or skew_min < 0 or '(VIOLATED)' in skew:
        errors.append('bus-skew failure')

    # ------------------------------ Layer B ------------------------------
    layer_b = []
    cdc_ledger, drc_ledger, method_ledger, pair_ledger, io_ledger = {}, {}, {}, {}, {}
    classified = []
    pairs = []
    pair_rows = {}
    reports = {'cdc.rpt': cdc, 'methodology.rpt': methodology, 'bus-skew.rpt': skew,
               'check-timing.rpt': coverage, 'drc.rpt': drc_text or ''}
    for name in ('clock-interaction.rpt', 'exceptions-ignored.rpt',
                 'exceptions-scope-override.rpt', 'exceptions-coverage.rpt', 'io.rpt',
                 'utilization_routed_hierarchical.rpt'):
        text = _read(directory, name, required=False)
        reports[name] = text if text is not None else ''
        if text is None:
            layer_b.append(f'Layer B evidence report {name} was never produced')
    if reports['clock-interaction.rpt']:
        pair_rows = review.parse_clock_interaction(reports['clock-interaction.rpt'])
    manifest = {'items': {}}
    try:
        manifest = review.load_coverage_manifest(
            directory / 'named-constraint-evidence.json', directory / 'cdc.rpt')
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        layer_b.append(str(exc))
    else:
        # cdc.rpt alone is not this round: methodology, DRC, check_timing, bus skew,
        # clock interaction and the exception audit are read too, and each of them
        # must carry the same round binding or one round's evidence can be graded
        # against another round's reports.
        layer_b.extend(review.verify_report_binding(manifest, directory))
    policy_root = Path(policy_dir) if policy_dir else Path(__file__).resolve().parent / 'gates'
    policies = {}
    for name, kind in (('sc7f0_cdc_review.json', 'cdc'),
                       ('sc7f0_drc_review.json', 'drc'),
                       ('sc7f0_clock_pair_review.json', 'clock_pair')):
        try:
            policies[kind] = review.load_policy(policy_root / name, kind)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            layer_b.append(f'review policy {name} cannot be loaded: {exc}')
            policies[kind] = None
    cdc_policy = policies['cdc']
    drc_policy = policies['drc']
    pair_policy = policies['clock_pair']
    if cdc_policy is not None:
        warnings = [row for row in cdc_rows
                    if row['severity'].strip().lower() in ('warning', 'advisory')]
        cdc_ledger, cdc_errors = review.review_rows(warnings, cdc_policy['items'],
                                                   manifest, pair_rows, reports)
        layer_b.extend(cdc_errors)
    if drc_policy is not None and drc_parsed:
        drc_ledger, drc_errors = review.review_drc(drc_parsed, drc_policy['items'])
        layer_b.extend(drc_errors)
    elif drc_policy is not None and drc_text is not None:
        drc_ledger = {'clean': {'status': 'REVIEWED_SAFE', 'count': 0,
                                'note': 'report_drc found no violations'}}
    if pair_policy is not None:
        pairs = review.methodology_clock_pairs(methodology)
        # Layer A "clean" for reclassification purposes means no critical CDC, no
        # uncovered endpoint and no critical methodology fact other than the pair
        # under review: an independent clock pair is only a methodology artefact
        # once every crossing between them is proven structurally clean.
        critical_other = [e for e in critical_methodology
                          if not e.startswith(('TIMING-6 ', 'TIMING-7 '))]
        layer_a_clean = (not critical_cdc and not uncovered_high_found
                         and not critical_other)
        classified, pair_errors, pair_ledger = review.review_methodology_clock_pairs(
            pairs, pair_policy['items'], pair_rows, manifest, reports, layer_a_clean)
        layer_b.extend(pair_errors)
    if pair_policy is not None:
        covered = {entry['rule'] for entry in classified}
        method_rows = [{'rule': rule, 'severity': severity, 'src': '', 'dest': '',
                        'exception': ''}
                       for rule, (severity, count) in sorted(methodology_summary.items())
                       if count and review.is_non_critical_severity(severity)
                       for _ in range(count)]
        # TIMING-6/7 are Critical Warnings handled by the clock-pair policy; the
        # methodology ledger must not also demand an ordinary entry for them.
        method_rows = [row for row in method_rows if row['rule'] not in covered]
        method_ledger, method_errors = review.review_rows(
            method_rows, pair_policy.get('methodology_items', []),
            manifest, pair_rows, reports)
        layer_b.extend(method_errors)
        io_ledger, io_errors = review.review_io(
            (cdc_policy or {}).get('io_items', []), manifest, reports)
        layer_b.extend(io_errors)
        if cdc_policy is not None and drc_policy is not None:
            layer_b.extend(review.review_manifest_coverage(
                [cdc_policy['items'], drc_policy['items'], pair_policy['items'],
                 pair_policy.get('methodology_items', []),
                 cdc_policy.get('io_items', [])], manifest))

    # A TIMING-6/7 Critical Warning is only removed from the Layer A verdict when
    # every finding of that rule was individually classified: the same number of
    # policy-reviewed pairs as the summary reports, the same number of detail
    # findings, and the same clock-pair set.  Removing the whole rule because one of
    # its pairs was reviewed would demote an unknown second pair into Layer B, which
    # is policy-editable - exactly what the docstring forbids.  Every other Critical
    # stays fatal, unconditionally.
    classified_by_rule = {}
    for entry in classified:
        classified_by_rule.setdefault(entry['rule'], []).append(
            tuple(sorted(entry['clocks'])))
    detail_pairs_by_rule = {}
    for pair in pairs:
        detail_pairs_by_rule.setdefault(pair['rule'], []).append(
            tuple(sorted(pair['clocks'])))

    def fully_classified(error_text):
        match = re.match(r'(TIMING-\d+) Critical Warning=(\d+)$', error_text)
        if not match or match.group(1) not in ('TIMING-6', 'TIMING-7'):
            return False
        rule, count = match.group(1), int(match.group(2))
        reviewed = classified_by_rule.get(rule, [])
        reported = detail_pairs_by_rule.get(rule, [])
        return (len(reviewed) == len(reported) == count
                and sorted(reviewed) == sorted(reported))

    layer_a_errors = [e for e in errors if not fully_classified(e)]

    result = dict(pass_gate=not layer_a_errors and not layer_b,
                  design_state=state, margins_ns=margins, tns_ns=tns,
                  coverage=counts, cdc={rule: count for rule, (_, count) in cdc_counts.items()},
                  drc={rule: count for rule, (_, count) in drc_summary.items()},
                  methodology={rule: count for rule, (_, count) in methodology_summary.items()},
                  uncovered_high_ports=sorted(set(uncovered_high)),
                  cdc_review=cdc_ledger, drc_review=drc_ledger,
                  methodology_review=method_ledger, clock_pair_review=pair_ledger,
                  io_review=io_ledger,
                  classified_by_policy=classified,
                  bus_skew_min_ns=skew_min,
                  layer_a_errors=layer_a_errors, layer_b_errors=layer_b,
                  pass_layer_a=not layer_a_errors, pass_layer_b=not layer_b,
                  errors=layer_a_errors + layer_b)
    return result


def is_warning(severity: str) -> bool:
    return severity.strip().lower() == 'warning'


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    policies = [a.split('=', 1)[1] for a in sys.argv[1:] if a.startswith('--policies=')]
    try:
        result = check(args[0], policies[0] if policies else None)
    except (OSError, ValueError, IndexError, json.JSONDecodeError) as exc:
        print('TIMING_GATE_FAIL: ' + str(exc), file=sys.stderr)
        sys.exit(2)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['pass_gate'] else 1)
