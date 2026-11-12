#!/usr/bin/env python3
"""Synthetic pass/fail regression for the fail-closed Layer A correctness gate.

Layer B (the itemised review ledger) is deliberately out of scope here: it needs
a coverage manifest and the shipped policy, which keeps every open review item
red. scripts/tests/test_sc7f0_two_layer_gates.py covers Layer B, and it covers
these same Layer A mutations with the two-layer verdict.
"""
import importlib.util
from pathlib import Path
import tempfile
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('gate', Path(__file__).resolve().parents[1] / 'scripts/check_sc7f0_timing.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

coverage_names = ('no_clock', 'constant_clock', 'pulse_width_clock', 'unconstrained_internal_endpoints',
                  'multiple_clock', 'generated_clocks', 'loops', 'latch_loops',
                  'partial_input_delay', 'partial_output_delay')
reports = {
    'timing_summary.rpt': 'Design State : Routed\n WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints\n -----\n 0.4 0 0 1000 0.01 0 0 1000 0.2 0 0 1000\n',
    'check-timing.rpt': '\n'.join('checking ' + name + ' (0)' for name in coverage_names),
    'cdc.rpt': 'CDC-3 Info 10 1-bit synchronized\nCDC-15 Warning 40 XPM FIFO clock enables\n' + ''.join(
        f'{i+1} CDC-15 Warning Clock enable controlled 0 Max Delay Datapath Only {gate.FIFO_ROOTS[0]}/mem_reg[{i}]/CLK {gate.FIFO_ROOTS[0]}/dout_reg[{i}]/D\n'
        for i in range(40)),
    'methodology.rpt': 'REPORT SUMMARY\nViolations found: 2\n| LUTAR-1 | Warning | local async reset | 2 |\n',
    'bus-skew.rpt': ' Slow 8.000 0.500 7.500\n Fast 8.000 0.100 7.900\n',
    'drc.rpt': ('| Design State : Fully Routed\n1. REPORT SUMMARY\n'
                '             Violations found: 0\n\n2. REPORT DETAILS\n'
                '-----------------\nReport DRC: Checked rule decks\n'),
}

with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)

    def run(changes=None, passed=False):
        for name, content in (reports | (changes or {})).items():
            (directory / name).write_text(content)
        try:
            # Layer A only: Layer B needs a per-round coverage manifest, and the
            # shipped policy is intentionally red while the DDC/TX review is open.
            result = gate.check(directory)['pass_layer_a']
        except ValueError:
            result = False
        assert result == passed, changes

    run(passed=True)
    run({'timing_summary.rpt': reports['timing_summary.rpt'].replace('0.4 0', '-0.1 -0.1')})
    run({'timing_summary.rpt': reports['timing_summary.rpt'].replace('0.01', '-0.001')})
    run({'timing_summary.rpt': reports['timing_summary.rpt'].replace('0.2 0', '-0.2 -0.2')})
    run({'timing_summary.rpt': reports['timing_summary.rpt'].replace('Routed', 'Fully Placed')})
    run({'timing_summary.rpt': reports['timing_summary.rpt'].replace('0.4', 'nan')})
    for name in coverage_names:
        run({'check-timing.rpt': reports['check-timing.rpt'].replace(name + ' (0)', name + ' (1)')})
    run({'check-timing.rpt': 'checking no_clock (0)'})
    run({'check-timing.rpt': reports['check-timing.rpt'] + '\nThere are 2 ports with missing input delays (HIGH)'})
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-1 Critical 1 unknown\n'})
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-1 Critical Warning 1 unknown\n'})
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-1 Critical malformed\n'})
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-1 Undefined 1 unknown severity\n'})
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-99 Info 1 unknown rule\n'})
    run({'cdc.rpt': reports['cdc.rpt'] + '99 CDC-1 Critical Unknown 0 None u_raw/C u_raw/D\n'})
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-3 Info 10 duplicate summary\n'})
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-5 Warning 1 missing ASYNC_REG\n'})
    run({'cdc.rpt': ''})
    run({'methodology.rpt': 'REPORT SUMMARY\nViolations found: 1\n| TIMING-3 | Critical Warning | invalid GT root | 1 |\n'})
    run({'methodology.rpt': 'REPORT SUMMARY\nViolations found: 1\n| TIMING-24 | Warning | overridden CDC max delay | 1 |\n'})
    run({'methodology.rpt': 'REPORT SUMMARY\nViolations found: 1\n'})
    run({'bus-skew.rpt': reports['bus-skew.rpt'].replace('7.500', '-0.001')})
    run({'bus-skew.rpt': ''})
    # Aggregate TIMING-9 is allowed only with complete, individually scoped
    # reviewed FIFO/held-data paths, never with a generic custom CE crossing.
    timing9 = 'REPORT SUMMARY\nViolations found: 1\n| TIMING-9 | Warning | aggregate CDC | 1 |\n'
    run({'methodology.rpt': timing9}, passed=True)
    run({'methodology.rpt': timing9, 'cdc.rpt': reports['cdc.rpt'].split('1 CDC-15')[0]})
    # A CDC-15 row on an unknown structure is no longer a Layer A fact: Layer A
    # only grades correctness, and an unknown *Warning* is exactly what the Layer
    # B ledger exists to classify. It must still be refused there, so prove the
    # shipped ledger rejects a fabricated FIFO root and accepts the real one.
    policy = gate.review.load_policy(
        Path(__file__).resolve().parents[1] / 'scripts/gates/sc7f0_cdc_review.json')

    def covered(rule, src, dest):
        row = {'rule': rule, 'severity': 'Warning', 'exception': 'Max Delay Datapath Only',
               'src': src, 'dest': dest}
        _ledger, errs = gate.review.review_rows([row], policy['items'],
                                                {'items': {}}, {}, {})
        return not any('not covered by any review entry' in e for e in errs)

    assert covered('CDC-15', gate.FIFO_ROOTS[0] + '/mem_reg[0]/CLK',
                   gate.FIFO_ROOTS[0] + '/dout_reg[0]/D')
    assert not covered('CDC-15', 'u_custom_raw_bus/mem_reg[0]/CLK',
                       'u_custom_raw_bus/dout_reg[0]/D')
    # TIMING-9 is an aggregate warning: it hides detail, so it is never a Layer A
    # pass-or-fail fact. It must stay an *open* item in the shipped methodology
    # ledger, whatever its count, otherwise a second aggregate warning would be
    # waved through by the same entry that covered the first.
    pair_policy = gate.review.load_policy(
        Path(__file__).resolve().parents[1] / 'scripts/gates/sc7f0_clock_pair_review.json',
        expect='clock_pair')

    def methodology_reviewed(rule):
        row = {'rule': rule, 'severity': 'Warning', 'exception': '', 'src': '', 'dest': ''}
        _ledger, errs = gate.review.review_rows([row], pair_policy['methodology_items'],
                                                {'items': {}}, {}, {})
        return not errs

    assert not methodology_reviewed('TIMING-9'), 'aggregate CDC must stay unreviewed'
    assert not methodology_reviewed('TIMING-18'), 'overridden constraint must stay open'
    assert not methodology_reviewed('TIMING-99'), 'an unseen rule must never be accepted'
    run({'cdc.rpt': reports['cdc.rpt'].replace('Warning 40', 'Warning 39')})
    # TIMING-6 as a *Warning* is the clk_pl_0/pcie_user_clk methodology artefact:
    # Layer A does not grade it, the clock-pair policy owns it, and it stays red
    # there until both interaction directions and the named constraints are proven.
    run({'methodology.rpt': 'REPORT SUMMARY\nViolations found: 1\n'
                            '| TIMING-6 | Warning | unreviewed clock rule | 1 |\n'},
        passed=True)
    assert not methodology_reviewed('TIMING-6'), 'TIMING-6 must stay an open review item'
    # The same rule filed Critical (round 26111103) is a Layer A failure and no
    # ledger entry may erase it while structural CDC findings remain.
    run({'methodology.rpt': 'REPORT SUMMARY\nViolations found: 1\n'
                            '| TIMING-6 | Critical Warning | clk_pl_0 pcie_user_clk | 1 |\n'})
    flags = 'u_dma_top/u_zu4ev_upg_diag/'
    flags_src = flags + 'pcie_sticky_reg[12:0]/C'
    flags_dst = flags + 'u_levels/syncstages_ff_reg[0][12:0]/D'
    flag_detail = '41 CDC-6 Warning Multi-bit synchronized 3 False Path ' + flags_src + ' ' + flags_dst + '\n'
    run({'cdc.rpt': reports['cdc.rpt'] + flag_detail})  # unsummarized detail
    run({'cdc.rpt': reports['cdc.rpt'] + 'CDC-6 Warning 1 independent flags\n' + flag_detail}, passed=True)
    assert gate.reviewed_crossing('CDC-6', flags_src, flags_dst)
    assert not gate.reviewed_crossing('CDC-6', 'u_other/bus[12:0]/C', flags_dst)
    for direction in ('RD', 'WR'):
        name = direction.lower()
        hub = f'dbg_hub/inst/U_CMD6_{direction}/U_{direction}_FIFO/SUBCORE_FIFO.xsdbm_v3_0_0_{name}fifo_inst/inst_fifo_gen/'
        assert gate.reviewed_crossing('CDC-15', hub + 'mem/CLK', hub + 'dout/D')
        assert not gate.reviewed_crossing('CDC-15', 'u_fake/' + hub + 'mem/CLK', hub + 'dout/D')
    assert gate.reviewed_crossing('CDC-15', 'u_custom/a/C', 'u_custom/b/D') is None
    cpll = 'u_pcie_ip/inst/cal/gtwizard_ultrascale_v1_7_17_gthe4_cpll_cal_tx_i/U_TXOUTCLK_FREQ_COUNTER'
    assert gate.reviewed_crossing('CDC-15', cpll + '/testclk_cnt_reg[17]/C', cpll + '/freq_cnt_o_reg[17]/D')
    assert not gate.reviewed_crossing('CDC-15', cpll + '/testclk_cnt_reg[18]/C', cpll + '/freq_cnt_o_reg[18]/D')
    assert not gate.reviewed_crossing('CDC-15', cpll + '/testclk_cnt_reg[1]/C', cpll + '/freq_cnt_o_reg[2]/D')
    run({'bus-skew.rpt': reports['bus-skew.rpt'] + 'Slack (VIOLATED) : -0.000ns\n'})
print('TB_PASS Layer A rejects negative setup/hold/pulse/skew, incomplete coverage, '
      'invalid/unknown CDC severities, DRC gaps and unclassifiable clock rules; '
      'the shipped review ledgers still refuse unknown and aggregate findings')
