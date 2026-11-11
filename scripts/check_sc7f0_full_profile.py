#!/usr/bin/env python3
"""Full C2H profile review, distinct from the preserved debug-profile gate.

Requires complete CDC details, extracted reset truth tables/readback-only probe
fanout, exact frozen-vendor matches, bounded I/O roles and positive routed STA.
Does not deploy, rebrand a failed build, or claim zero vendor warnings.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re

from audit_sc7f0_cdc_delta import parse_report
from sc7f0_reset_proof import parse_evidence, prove

# Exact R6 DSP cells, the two guarded audio FIFO BRAMs and vendor lclk_cke[3].
DRC_DETAILS_SHA = 'ec7893c18ee69decb246fc5e04aef081df3e820d7a0c6857095b8d1a5c16c941'
DRC = {'DPIP-2': ('Warning',74), 'DPOP-3': ('Warning',13), 'DPOP-4': ('Warning',30),
       'REQP-1935': ('Warning',2), 'RTSTAT-10': ('Warning',1)}
BASE_CDC_SHA = 'babc386d724c54804b9f4362c7be27f5a11185a09f75545bcea360b3f5ac4827'
# Pinned external inputs from commit-audio-26102702.s8uZ7DyJ's verified manifest.
BASE_XCI_SHA = {
    'vid_phy_controller_0': '98a9e84f0a20187b6d465ef4ad30193b33806a766598e8ec1ec2398ee6ef05af',
    'v_hdmi_rx_ss_0': '3f132ae51e06641eac295850e88e39e83faaa1f39bcb4fbd85b4608431bda493',
}
FIFO_INSTANCES = (
    'u_dma_top/u_axil_reg_space/u_controls/u_fifo',
    'u_dma_top/u_axil_reg_space/u_status/u_fifo',
    'u_dma_top/u_upg_cdc/inst/gen_async_conv.axisc_async_clock_converter_0/xpm_fifo_async_inst',
    'u_dma_top/u_video_req_cdc/u_hdr_fifo',
    'u_dualpath/u_packet_commands/u_fifo', 'u_dualpath/u_packet_completions/u_fifo',
    'u_dualpath/u_tx_cdc/u_headers/u_fifo',
    'u_ps_capture/u_regs/u_config/u_fifo', 'u_ps_capture/u_regs/u_metadata/u_fifo',
    'u_ps_capture/u_tap/u_headers/u_fifo',
)
FIFO_ROOTS = tuple(x + '/gnuram_async_fifo.xpm_fifo_base_inst' for x in FIFO_INSTANCES)
METERS = ('rx_video_clk', 'tx_video_clk', 'dru_clk', 'rx_clk', 'tx_clk', 'rxoutclk', 'txoutclk')
INPUTS = {'hdmi_rx_5v_det', 'hdmi_rx_ddc_scl', 'hdmi_rx_ddc_sda',
          'hdmi_tx_ddc_scl', 'hdmi_tx_ddc_sda', 'hdmi_tx_hpd_in', 'hdmi_tx_refclk_rdy'}
OUTPUTS = {'hdmi_rx_ddc_scl', 'hdmi_rx_ddc_sda', 'hdmi_rx_hpd_out',
           'hdmi_tx_tmds_clk_p', 'user_led_dma_active', 'user_led_pcie_link_up'}
METHOD = {'DPIR-2': ('Warning', 192), 'LUTAR-1': ('Warning', 35),
          'TIMING-9': ('Warning', 1), 'TIMING-18': ('Warning', 12),
          'ULMTCS-1': ('Warning', 1), 'CLKC-11': ('Advisory', 2),
          'CLKC-40': ('Advisory', 2), 'CLKC-56': ('Advisory', 2)}


def identity(row):
    return tuple(row[k] for k in ('rule', 'severity', 'source_clock', 'destination_clock', 'source', 'destination'))


def classify(row, baseline, reset_proofs):
    rule, src, dst = row['rule'], row['source'], row['destination']
    if row['severity'] == 'Info':
        return 'vendor_sync_info' if rule in ('CDC-3', 'CDC-9') else None
    if row['severity'] == 'Critical' and rule in ('CDC-10', 'CDC-12'):
        if dst in reset_proofs and src.endswith('/C'):
            if src[:-1] + 'Q' in reset_proofs[dst]['terms']:
                return 'proved_reset_OR_async_assert_four_stage_release'
        if rule == 'CDC-10' and re.fullmatch(r'u_hdmi_probe/u_pin_levels_cdc/syncstages_ff_reg\[0\]\[(?:2[5-9]|3[01])\]/D', dst):
            return 'approximate_level_three_stage_CSR_readback_only'
        return None
    if row['severity'] != 'Warning':
        return None
    if rule == 'CDC-15':
        for root in FIFO_ROOTS:
            if not src.startswith(root + '/') or not dst.startswith(root + '/'):
                continue
            s, d = src[len(root):], dst[len(root):]
            if (re.fullmatch(r'/gen_sdpram\.xpm_memory_base_inst/gen_wr_a\.gen_word_narrow\.mem_reg_\d+_\d+_\d+_\d+/RAM[A-G](?:_D\d+)?/CLK', s)
                and re.fullmatch(r'/gen_sdpram\.xpm_memory_base_inst/gen_rd_b\.gen_rd_b_synth_template\.gen_rf_narrow_pipe\.doutb_reg_reg\[\d+\]/D', d)):
                return 'explicit_XPM_FIFO_full_empty_FWFT_ownership'
        for meter in METERS:
            root = 'u_hdmi_probe/u_meter_' + meter + '/'
            a = re.fullmatch(re.escape(root) + r'snapshot_test_reg\[(\d+)\]/C', src)
            b = re.fullmatch(re.escape(root) + r'(?:measured_freq_hz|raw_cycle_count)_reg\[(\d+)\]/D', dst)
            if a and b and int(a[1]) < 32 and int(b[1]) < 32:
                return 'held_snapshot_toggle_ack_10ns_constraint'
        # These exact 18-bit GT Wizard1.7.17 paths retain their frozen vendor
        # implementation/configuration and HOLD-before-latch protocol.
        if ('gtwizard_ultrascale_v1_7_17_gthe4_cpll_cal_' in src and
            identity(row) in baseline and src.startswith(('u_pcie_ip/', 'u_vid_phy_controller/'))):
            a = re.fullmatch(r'(.*(?:U_TXOUTCLK_FREQ_COUNTER|U_RXOUTCLK_FREQ_COUNTER))/testclk_cnt_reg\[(\d+)\]/C', src)
            if a and int(a[2]) < 18 and dst == a[1] + '/freq_cnt_o_reg[' + a[2] + ']/D':
                return 'frozen_vendor_CPLL_held_counter'
    if rule == 'CDC-26' and identity(row) in baseline and src.startswith('u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/') and dst.startswith('u_hdmi_rx_ss/inst/v_hdmi_rx/inst/SYS_INST/'):
        return 'exact_frozen_HDMI_RX_FIFO_collision_advisory'
    if rule == 'CDC-6':
        if src == 'u_dma_top/u_zu4ev_upg_diag/pcie_sticky_reg[12:0]/C' and dst == 'u_dma_top/u_zu4ev_upg_diag/u_levels/syncstages_ff_reg[0][12:0]/D':
            return 'independent_sticky_diagnostics'
        if src == 'u_ps_capture/u_regs/u_state/src_ff_reg[1:0]/C' and dst == 'u_ps_capture/u_regs/u_state/syncstages_ff_reg[0][1:0]/D':
            return 'independent_status_NOT_stop_proof_ABI_1_1'
        if src == 'u_ps_capture/u_tap/gray_q_reg[63:0]/C' and dst in ('u_ps_capture/u_regs/u_time/stage0_reg[63:0]/D', 'u_ps_capture/u_tap/u_source_time/stage0_reg[63:0]/D'):
            return 'registered_Gray64_four_stage_with_checked_6ns_skew_delay'
        if identity(row) in baseline and src.startswith('u_vid_phy_controller/inst/'):
            if ('/clock_detector_inst/' in src and '/syncstages_ff_reg[0]' in dst) or ('/slv_reg_0x300_reg[1:0]/C' in src and '/xpm_array_single_DRU_CTRL_in_sync_inst/' in dst):
                return 'exact_frozen_VPHY_frequency_or_independent_control'
    return None


def io_ports(coverage, number, name, next_number):
    pattern = rf'\n{number}\. checking {name} \(\d+\)\n-+\n(.*?)\n{next_number}\.'
    match = re.search(pattern, coverage, re.S)
    if not match:
        raise ValueError('missing detailed I/O section')
    high = re.search(r'There are (\d+) [^\n]*\(HIGH\)\s*\n\n(.*?)(?:\n\n|\Z)', match[1], re.S)
    if not high:
        raise ValueError('missing high I/O endpoint detail')
    ports = high[2].split()
    if len(ports) != int(high[1]) or len(set(ports)) != len(ports):
        raise ValueError('incomplete/duplicate I/O detail')
    return set(ports)


def check(directory, evidence, baseline_file, baseline_ip, safety):
    directory, evidence = Path(directory), Path(evidence)
    if hashlib.sha256(Path(baseline_file).read_bytes()).hexdigest() != BASE_CDC_SHA:
        raise ValueError('frozen baseline CDC hash mismatch')
    _, base_rows = parse_report(Path(baseline_file).read_text())
    baseline = {identity(r) for r in base_rows}
    summary, rows = parse_report((directory / 'cdc.rpt').read_text())
    evidence_text = (evidence / 'netlist.tsv').read_text()
    bindings = [line.split('\t') for line in evidence_text.splitlines() if line.startswith('CHECKPOINT\t')]
    dcp = directory / 'qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_routed.dcp'
    if (len(bindings) != 1 or len(bindings[0]) != 3 or
        Path(bindings[0][1]).resolve() != dcp.resolve() or
        hashlib.sha256(dcp.read_bytes()).hexdigest() != bindings[0][2]):
        raise ValueError('netlist evidence is not bound to this routed checkpoint')
    reset_proofs = prove(*parse_evidence(evidence_text))
    errors = []
    safety = Path(safety)
    if (safety / 'tests.exit').read_text().strip() != '0' or (safety / 'tests.ok').read_text().strip() != 'SC7F0_CAPTURE_SAFETY_PASS':
        raise ValueError('missing actual-IP capture safety evidence')
    for name, marker in (('stop.log', 'SC7F0_STOP_ACK_SIM_GATE_PASS'), ('pipeline.log', 'CAPTURE_PIPELINE_SIM_GATE_PASS')):
        log_text = (safety / name).read_text()
        if marker not in log_text or re.search(r'Error:|Fatal:|ERROR:|FATAL:', log_text):
            raise ValueError('failed actual-IP simulation: ' + name)
    logs = directory.parent / (directory.name + '-logs')
    source_root = logs / 'source'
    repo = Path(__file__).resolve().parents[1]
    sim_entries = (safety / 'INPUTS.sha256').read_text().splitlines()
    expected_sim = {
        'rtl/sc7f0_dp_fifo.v', 'rtl/sc7f0_gray64_sync.v', 'rtl/sc7f0_tap_regs.v',
        'rtl/sc7f0_frame_tap.v', 'rtl/sc7f0_capture_pipeline.v',
        'tb/sc7f0_tap_stop_ack_tb.sv', 'tb/sc7f0_capture_pipeline_tb.sv',
        'scripts/sim_sc7f0_stop_ack.tcl', 'scripts/sim_sc7f0_capture_pipeline.tcl',
        'scripts/test_sc7f0_capture_safety.sh',
    }
    current_ip = directory / 'qpcie_zu4ev_card.srcs/sources_1/ip'
    for ip in ('sc7f0_frmbuf_wr', 'sc7f0_vpss_csc', 'axi_clock_converter_0'):
        expected_sim.add(str((current_ip / ip / (ip+'.xci')).resolve().relative_to(repo)))
    if len(sim_entries) != len(expected_sim) or {line.split('  ', 1)[1] for line in sim_entries} != expected_sim:
        raise ValueError('incomplete/duplicate safety source manifest')
    for line in sim_entries:
        digest, name = line.split('  ', 1)
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or hashlib.sha256((repo/path).read_bytes()).hexdigest() != digest:
            raise ValueError('simulation input drift: ' + name)
    for manifest in ('SOURCE_RTL.sha256', 'SOURCE_BUILD.sha256'):
        entries = (logs / manifest).read_text().splitlines()
        if not entries:
            raise ValueError('empty source manifest')
        for line in entries:
            digest, name = line.split('  ', 1)
            path = Path(name)
            if path.is_absolute() or '..' in path.parts or not re.fullmatch('[0-9a-f]{64}', digest):
                raise ValueError('invalid source manifest entry')
            if any(hashlib.sha256((base / path).read_bytes()).hexdigest() != digest for base in (source_root, repo)):
                raise ValueError('snapshot/live source drift: ' + name)
    # Imported source identity/config is checked, not a broad vendor-IP waiver.
    for ip in ('vid_phy_controller_0', 'v_hdmi_rx_ss_0'):
        base_file = Path(baseline_ip) / ip / (ip + '.xci')
        if hashlib.sha256(base_file.read_bytes()).hexdigest() != BASE_XCI_SHA[ip]:
            raise ValueError('baseline XCI provenance mismatch: ' + ip)
        def params(base):
            return json.loads((Path(base)/ip/(ip+'.xci')).read_text())['ip_inst']['parameters']['component_parameters']
        if params(current_ip) != params(baseline_ip):
            errors.append('frozen vendor IP configuration changed: ' + ip)
    rtl = (source_root / 'rtl/sc7f0_tap_regs.v').read_text()
    if "32'h00010001" not in rtl or 'stop_ack_m<=stop_ack_m+1' not in rtl:
        errors.append('requires ABI1.1 ordered drain barrier, not R5 status sampling')
    classified, unknown = Counter(), []
    for row in rows:
        kind = classify(row, baseline, reset_proofs)
        if kind:
            classified[kind] += 1
        else:
            unknown.append(row)
    if unknown:
        errors.append('unreviewed exact CDC paths: ' + str(len(unknown)))
    if classified['proved_reset_OR_async_assert_four_stage_release'] != 32 or classified['approximate_level_three_stage_CSR_readback_only'] != 7:
        errors.append('critical path coverage differs from reviewed cones')
    if classified['exact_frozen_HDMI_RX_FIFO_collision_advisory'] != 416:
        errors.append('frozen HDMI FIFO path coverage differs')
    drc = (directory / 'drc.rpt').read_text()
    drc_rows = re.findall(r'^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|',drc,re.M)
    drc_total = re.search(r'Violations found:\s*(\d+)',drc)
    if (not drc_total or int(drc_total[1]) != 120 or len(drc_rows) != len(DRC) or
        {r:(s,int(n)) for r,s,n in drc_rows} != DRC or
        hashlib.sha256(drc.partition('2. REPORT DETAILS\n')[2].encode()).hexdigest() != DRC_DETAILS_SHA):
        errors.append('DRC findings/cells differ from exact reviewed R6 scope')
    ip_status = (directory / 'ip_status.rpt').read_text()
    license_rows = [line for line in ip_status.splitlines() if re.match(r'^\|\s*(?:v_hdmi_rx_ss_0|bd_2422_v_hdmi_rx_0)\s*\|',line)]
    if len(license_rows)!=2 or any('Purchased' not in line for line in license_rows) or 'Evaluation' in ip_status or 'Design_Linking' in ip_status:
        errors.append('HDMI purchased-license evidence missing')
    timing = (directory / 'timing_summary.rpt').read_text()
    if not re.search(r'Tool Version\s*:\s*Vivado v\.?2023\.2\b', timing):
        errors.append('unsupported Vivado report version')
    if not re.search(r'Design State\s*:\s*Routed\b', timing):
        errors.append('not routed')
    table = re.search(r'^\s*WNS\(ns\).*WPWS\(ns\).*\n[^\n]*\n([^\n]+)', timing, re.M)
    if not table:
        raise ValueError('missing timing summary')
    values = list(map(float, table[1].split()))
    if len(values) != 12 or not all(map(math.isfinite, values)):
        raise ValueError('invalid timing summary')
    if any(values[i] < 0 for i in (0,4,8)) or any(values[i] != 0 for i in (1,2,5,6,9,10)):
        errors.append('setup/hold/pulse failure')
    coverage = (directory / 'check-timing.rpt').read_text()
    for name in ('no_clock','constant_clock','pulse_width_clock','unconstrained_internal_endpoints','multiple_clock','generated_clocks','loops','latch_loops','partial_input_delay','partial_output_delay'):
        counts = re.findall(r'checking '+name+r' \((\d+)\)', coverage)
        if not counts or any(int(v) for v in counts):
            errors.append('bad/missing coverage: ' + name)
    if io_ports(coverage,5,'no_input_delay',6) != INPUTS or io_ports(coverage,6,'no_output_delay',7) != OUTPUTS:
        errors.append('unreviewed external I/O endpoint')
    methodology = (directory / 'methodology.rpt').read_text()
    method = re.findall(r'^\|\s*([A-Z]+-\d+)\s*\|\s*([^|]+?)\s*\|[^|]*\|\s*(\d+)\s*\|',methodology,re.M)
    total = re.search(r'Violations found:\s*(\d+)',methodology)
    if not total or int(total[1]) != sum(int(r[2]) for r in method) or len({r[0] for r in method}) != len(method):
        raise ValueError('incomplete methodology summary')
    if {rule: (severity, int(count)) for rule, severity, count in method} != METHOD:
        errors.append('methodology inventory differs from exact reviewed profile')
    skew = (directory/'bus-skew.rpt').read_text()
    vals = re.findall(r'^\s*(?:Slow|Fast)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*$',skew,re.M)
    if not vals or '(VIOLATED)' in skew or any(not math.isfinite(float(r[2])) or float(r[2])<0 for r in vals):
        errors.append('skew coverage/failure')
    log = (directory.parent/(directory.name+'-logs')/'impl-console.log').read_text()
    personality = (directory / 'c2h-personality.rpt').read_text().splitlines()
    absent = {'u_hdmi_tx_ss','u_hdmi_tx_video_bridge','u_hdmi_tx_audio_bridge','u_v_tpg',
              'u_audio_pattern_gen','u_tpg_marker_overlay','u_tpg_video_cdc'}
    absent |= {f'u_ch{ch}_loopback_cdc' for ch in (1,2,3)}
    absent |= {prefix+str(ch) for ch in (1,2,3) for prefix in (
        'u_nv12_capture_engine_ch','u_video_req_cdc_ch','u_audio_h2c_fifo_ch','u_audio_stream_engine_ch')}
    present = {'u_hdmi_rx_ss','u_vid_phy_controller','u_ps_capture','u_nv12_capture_engine',
               'u_audio_stream_engine_ch0','u_dualpath','u_h2c_ps_ddr_writer'}
    records = [line.split() for line in personality[:-1]]
    if (not personality or personality[-1] != 'C2H_PERSONALITY_SYNTH_PASS' or
        len(records) != len(absent)+len(present) or
        {r[1] for r in records if r[0]=='ABSENT' and r[2]=='0'} != absent or
        {r[1] for r in records if r[0]=='PRESENT' and int(r[2])>0} != present):
        errors.append('C2H required/forbidden linked-cell audit differs')
    if log.count('SC7F0_CAPTURE_GRAY_CONSTRAINTS_PASS') != 2:
        errors.append('missing pre-opt/post-route Gray checks')
    result = dict(pass_gate=not errors, profile='C2H_ABI1.1', zero_warning_claim=False,
                  margins_ns=dict(WNS=values[0],WHS=values[4],WPWS=values[8]),
                  cdc_summary={k:v for k,v in summary.items()}, reviewed_categories=dict(classified),
                  reset_roots_proved=len(reset_proofs), unknown_paths=unknown[:20], errors=errors,
                  deployment_acceptance='separate matching-image/package and real-card gates required')
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory');p.add_argument('--evidence',required=True)
    p.add_argument('--baseline-cdc',required=True);p.add_argument('--baseline-ip',required=True)
    p.add_argument('--safety',required=True)
    a=p.parse_args()
    try:
        result=check(a.directory,a.evidence,a.baseline_cdc,a.baseline_ip,a.safety)
    except (OSError,ValueError,KeyError,IndexError) as e:
        print(json.dumps({'pass_gate':False,'error':str(e)}));raise SystemExit(2)
    print(json.dumps(result,indent=2));raise SystemExit(0 if result['pass_gate'] else 1)

if __name__=='__main__':main()
