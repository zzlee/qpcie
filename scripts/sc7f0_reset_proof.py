"""Validate extracted reset truth tables and diagnostic-only synchronizer fanout."""
from itertools import product
import re

RESET_ROOTS = (
    'u_capture_reset', 'u_dma_top/u_video_fifo_reset',
    'u_dma_top/u_video_req_cdc/u_rd_reset', 'u_dma_top/u_video_req_cdc/u_wr_reset',
    'u_dp_mem_reset', 'u_dualpath/u_packet_commands/u_read_reset',
    'u_dualpath/u_packet_commands/u_reset', 'u_dualpath/u_packet_completions/u_read_reset',
    'u_dualpath/u_packet_completions/u_reset', 'u_dualpath/u_packet_reset',
    'u_dualpath/u_tx_cdc/u_headers/u_read_reset', 'u_dualpath/u_tx_cdc/u_headers/u_reset',
    'u_dualpath/u_tx_cdc/u_reset', 'u_hdmi_rx_video_cdc_fifo/u_reset',
    'u_ps_capture/u_regs/u_config/u_read_reset', 'u_ps_capture/u_regs/u_config/u_reset',
    'u_ps_capture/u_regs/u_csc_reset', 'u_ps_capture/u_regs/u_metadata/u_read_reset',
    'u_ps_capture/u_regs/u_metadata/u_reset', 'u_ps_capture/u_regs/u_writer_reset',
    'u_ps_capture/u_tap/u_headers/u_read_reset', 'u_ps_capture/u_tap/u_headers/u_reset',
    'u_ps_capture/u_tap/u_pixels/u_read_reset', 'u_ps_capture/u_tap/u_pixels/u_reset',
    'u_rx_video_reset',
)
# Named request polarity, not a generic approval for all FF inputs.
POLARITY = {
    'u_100m_reset/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N/Q': 0,
    'u_300m_reset/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N/Q': 0,
    'u_pcie_ip/inst/user_lnk_up_reg/Q': 0,
    'u_pcie_ip/inst/user_reset_reg/Q': 1,
    'video_engine_reset_sync_reg[1]/Q': 1,
    'video_pipeline_reset_sync_reg[1]/Q': 1,
    'u_dma_top/u_axil_reg_space/u_controls/dest_event_reg[0]/Q': 1,
    'u_dma_top/u_axil_reg_space/u_controls/dest_level_reg[1820]/Q': 1,
    'u_ps_capture/u_regs/reset_n_reg[0]/Q': 0,
    'u_ps_capture/u_regs/reset_n_reg[1]/Q': 0,
    'u_capture_reset/arststages_ff_reg[3]/Q': 1,
    'u_dp_mem_reset/arststages_ff_reg[3]/Q': 1,
    'u_dualpath/u_packet_reset/arststages_ff_reg[3]/Q': 1,
    'u_rx_video_reset/arststages_ff_reg[3]/Q': 1,
}


def parse_evidence(text):
    graph, roots, stages, probes, ports = {}, {}, {}, {}, {}
    lines = text.splitlines()
    if not lines or lines[-1] != 'END\t25':
        raise ValueError('missing complete export marker')
    for line in lines:
        row = line.split('\t')
        kind = row[0]
        if kind in ('CONST', 'TERM', 'LUT'):
            if row[1] in graph:
                raise ValueError('duplicate graph net')
            graph[row[1]] = row
        elif kind == 'RESET':
            if len(row) != 4 or row[1] in roots:
                raise ValueError('invalid reset root')
            roots[row[1]] = row[2:]
        elif kind == 'STAGE':
            key = (row[1], int(row[2]))
            if len(row) != 5 or key in stages:
                raise ValueError('invalid stage')
            stages[key] = row[3:]
        elif kind == 'PROBE':
            probes.setdefault(int(row[1]), []).append(row[2])
        elif kind == 'PORT':
            if len(row) != 5 or row[1] in ports:
                raise ValueError('invalid physical port')
            ports[row[1]] = row[2:]
        elif kind == 'CHECKPOINT':
            if len(row) != 3:
                raise ValueError('invalid checkpoint binding')
        elif kind != 'END':
            raise ValueError('unknown evidence row')
    return graph, roots, stages, probes, ports


def leaves(graph, net, visiting=None):
    visiting = set() if visiting is None else set(visiting)
    if net in visiting:
        raise ValueError('combinational loop')
    visiting.add(net)
    row = graph[net]
    if row[0] == 'TERM':
        return {row[2]}
    if row[0] == 'CONST':
        return set()
    if row[0] != 'LUT':
        raise ValueError('unknown graph kind')
    result = set()
    for child in row[4:]:
        result |= leaves(graph, child, visiting)
    return result


def evaluate(graph, net, values):
    row = graph[net]
    if row[0] == 'CONST':
        if row[2] not in ('GND', 'VCC'):
            raise ValueError('invalid constant')
        return int(row[2] == 'VCC')
    if row[0] == 'TERM':
        if row[3] not in ('FDRE', 'FDPE', 'FDCE', 'FDSE'):
            raise ValueError('invalid leaf primitive')
        return values[row[2]]
    match = re.fullmatch(r'LUT([1-6])', row[2])
    init = re.fullmatch(r"(\d+)'h([0-9A-Fa-f]+)", row[3])
    if not match or not init or len(row[4:]) != int(match[1]) or int(init[1]) != 2 ** int(match[1]):
        raise ValueError('invalid LUT shape')
    index = sum(evaluate(graph, child, values) << bit for bit, child in enumerate(row[4:]))
    return (int(init[2], 16) >> index) & 1


PORTS = {
    'hdmi_rx_5v_det': ['IN', 'A12', 'LVCMOS33'],
    'hdmi_rx_ddc_scl': ['INOUT', 'D14', 'LVCMOS33'],
    'hdmi_rx_ddc_sda': ['INOUT', 'C13', 'LVCMOS33'],
    'hdmi_tx_ddc_scl': ['INOUT', 'F12', 'LVCMOS33'],
    'hdmi_tx_ddc_sda': ['INOUT', 'E12', 'LVCMOS33'],
    'hdmi_tx_hpd_in': ['IN', 'G14', 'LVCMOS33'],
    'hdmi_tx_refclk_rdy': ['IN', 'G13', 'LVCMOS33'],
    'hdmi_rx_hpd_out': ['OUT', 'B12', 'LVCMOS33'],
    'hdmi_tx_tmds_clk_p': ['OUT', 'AH6', 'LVDS'],
    'user_led_dma_active': ['OUT', 'F16', 'LVCMOS33'],
    'user_led_pcie_link_up': ['OUT', 'G15', 'LVCMOS33'],
}


def prove(graph, roots, stages, probes, ports):
    if ports != PORTS:
        raise ValueError('physical GPIO/clock role differs')
    expected = {root + '/arststages_ff_reg[0]/PRE' for root in RESET_ROOTS}
    if set(roots) != expected or len(stages) != 100:
        raise ValueError('reset endpoint coverage differs')
    proofs = {}
    for target, (preset, clock) in roots.items():
        prefix = target.rsplit('/', 2)[0]
        for bit in range(4):
            d, ce = stages[(target, bit)]
            if graph[ce] != ['CONST', ce, 'VCC']:
                raise ValueError('reset CE not constant enabled')
            if bit == 0:
                if graph[d] != ['CONST', d, 'GND']:
                    raise ValueError('stage0 D not inactive reset level')
            elif graph[d][0] != 'TERM' or graph[d][2] != f'{prefix}/arststages_ff_reg[{bit-1}]/Q':
                raise ValueError('reset release path not direct')
        terms = sorted(leaves(graph, preset))
        if not terms or len(terms) > 8 or set(terms) - POLARITY.keys():
            raise ValueError('unknown assertion request: ' + str(set(terms) - POLARITY.keys()))
        for bits in product((0, 1), repeat=len(terms)):
            values = dict(zip(terms, bits))
            expected_assertion = int(any(values[p] == POLARITY[p] for p in terms))
            if evaluate(graph, preset, values) != expected_assertion:
                raise ValueError('assertion is not OR of declared requests: ' + target)
        proofs[target] = {'terms': terms, 'truth_combinations': 2 ** len(terms), 'clock_net': clock}
    if set(probes) != set(range(25, 32)):
        raise ValueError('diagnostic bit coverage differs')
    for bit, endpoints in probes.items():
        if endpoints != [f'u_dma_top/u_axil_reg_space/u_bank/s_axil_rdata_reg[{bit}]/D']:
            raise ValueError('diagnostic signal reaches non-readback endpoint')
    return proofs
