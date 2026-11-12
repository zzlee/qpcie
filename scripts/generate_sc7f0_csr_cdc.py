#!/usr/bin/env python3
"""Generate the explicit, width-checked dual-clock wrapper for axil_reg_space.

The authoritative bank and all AXI responses remain on the independent PS
clock. Only DMA controls/events and telemetry cross domains. Run --check in
regressions to detect drift after adding/changing register-bank ports.
"""
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'rtl/axil_reg_space.v'
OUTPUT = ROOT / 'rtl/qpcie_csr_reg_space.v'
EVENTS = set('''reg_irq_status_w1c perf_reset pt_y_wr_en pt_uv_wr_en
h2c_fifo_wr_en_ch1 h2c_fifo_wr_en_ch2 h2c_fifo_wr_en_ch3
out_irq_top_status_w1c out_vch0_irq_status_w1c out_vch1_irq_status_w1c
out_adev0_irq_status_w1c out_adev0_xrun_inject out_global_reset_pulse'''.split())
LOCAL_OUTPUTS = set('''out_hdmi_ipc_cmd out_hdmi_ipc_arg out_hdmi_ipc_status
out_hdmi_ipc_doorbell out_ddr_read_request out_ddr_read_offset out_probe_ctrl'''.split())
# LOCAL_* means: this port is already produced in / consumed by the wrapper's
# `clk` domain, which is the PS AXI-Lite clock (pl_clk0 at board level: in
# rtl/custom_pcie_dma_top.v, u_axil_reg_space is instantiated with .clk(pl_clk0)).
# LOCAL ports are wired straight to the authoritative bank and MUST NOT be packed
# into src_level/src_status, because qpcie_csr_cdc / qpcie_status_cdc put their
# source side on `pcie_clk` (pcie_user_clk).
#
# Adding a name here is a claim about hardware, not a convenience: you must be
# able to point at the always block that produces it and show it is clocked by
# the same net as the bank's `clk`.  A wrong entry silently turns a real
# cross-domain path into an unconstrained in-domain read; that is exactly how the
# 296 CDC-13 criticals in build/vcu-release-26111103-r1 appeared.  A missing entry
# silently routes a same-domain word through the async FIFO, which per-bit
# synchronizes a multi-bit counter and makes a 64-bit BAR0 pair torn across two
# FIFO snapshots.
#
# in_pkt_* (Packet DMA telemetry): produced by `always @(posedge csr_clk)` in
# rtl/sc7f0_dualpath.v, and rtl/zu4ev_pcie_card_top.v drives .csr_clk(pl_clk0) --
# the very same clock as this bank's `clk`.  Same domain, so a read is inherently
# word-coherent and no synchronizer is needed or wanted.  They were briefly
# misclassified as PCIe-domain telemetry; that regression is what CDC-13 counted.
#
# Deliberate semantic consequence, recorded so it is not an unexplained drift:
# LOCAL inputs are NOT gated by `csr_online`.  With the PCIe link down, BAR0
# 0xC0..0xE4 now return the real Packet DMA counters instead of reading 0, so the
# host can see whether packets were submitted before the mailbox is up.  Every
# non-LOCAL input keeps reading 0 while offline, exactly as before.
LOCAL_INPUT_DOMAIN = {
    'in_probe_*': 'PS probe registers (sc7f0_hdmi_probe), clocked by clk/pl_clk0',
    'in_pkt_*': 'Packet DMA counters, always @(posedge csr_clk) with csr_clk == pl_clk0 == bank clk',
}
LOCAL_INPUTS = set('''in_probe_version in_probe_rx_clk_freq in_probe_dru_clk_freq in_probe_rxoutclk_freq
in_probe_rx_video_clk_freq in_probe_tx_clk_freq in_probe_txoutclk_freq in_probe_tx_video_clk_freq
in_probe_pins in_probe_pulse_cnt1 in_probe_ddc_cnt in_probe_irq_cnt
in_probe_ch0_beats in_probe_ch1_beats in_probe_ch2_beats in_probe_rx_video_sof
in_probe_rx_video_eol in_probe_rx_video_pix in_probe_raw_rx_clk in_probe_raw_dru_clk
in_probe_raw_rxoutclk in_probe_raw_rx_video_clk in_probe_raw_refclk100
in_pkt_submit_cnt in_pkt_done_cnt in_pkt_err_cnt in_pkt_msi_cnt
in_pkt_bytes_lo in_pkt_bytes_hi in_pkt_fsm_state in_pkt_last_len
in_pkt_last_pts_lo in_pkt_last_pts_hi'''.split())
UPGRADE = {'out_dma_upg_ctrl': 'pcie_upg_ctrl',
           'out_dma_upg_size': 'pcie_upg_size',
           'out_dma_upg_host_addr': 'pcie_upg_host_addr'}


def generate():
    text = SOURCE.read_text()
    match = re.search(r'module axil_reg_space #\((.*?)\)\((.*?)\n\);', text, re.S)
    if not match:
        raise ValueError('Cannot parse register-bank interface')
    params, interface = match.groups()
    plain = re.sub(r'//[^\n]*', '', interface)
    ports = []
    direction = width = None
    for item in plain.split(','):
        item = item.strip()
        if not item:
            continue
        m = re.fullmatch(r'(input|output)\s+(?:wire\s+|reg\s+)?(\[[^]]+\])?\s*(\w+)', item)
        if m:
            direction, width, name = m.groups()
            width = width or ''
        else:
            if not re.fullmatch(r'\w+', item) or direction is None:
                raise ValueError(f'Unrecognized port: {item!r}')
            name = item
        ports.append((direction, width, name))
    assert len({p[2] for p in ports}) == len(ports)
    directions = {name: direction for direction, _, name in ports}
    # A classification list that no longer matches the bank is worse than no
    # list: an unrecognised name silently falls back into the default bucket.
    # Fail loudly instead, and never let a LOCAL claim attach to a port that is
    # not an input of the authoritative bank.
    for name in sorted(LOCAL_INPUTS):
        assert directions.get(name) == 'input', \
            f'LOCAL_INPUTS entry {name!r} is not an input of axil_reg_space'
    for name in sorted(LOCAL_OUTPUTS | set(UPGRADE)):
        assert directions.get(name) == 'output', \
            f'LOCAL/UPGRADE output {name!r} is not an output of axil_reg_space'
    assert EVENTS <= set(directions), \
        'EVENTS contains a name that is not a register-bank port'
    widths = {name: (int(width[1:-1].split(':')[0]) + 1 if width else 1)
              for _, width, name in ports}
    levels, events, statuses = [], [], []
    for direction, width, name in ports:
        if name.startswith('s_axil_') or name in {'clk', 'rst_n', 'cdc_write_ready', 'cdc_write_commit'}:
            continue
        if direction == 'output':
            if name.startswith('out_dma_upg_') or name in LOCAL_OUTPUTS:
                continue
            (events if name in EVENTS else levels).append(name)
        elif not name.startswith(('in_dma_upg_', 'in_ddr_read_')):
            if name not in LOCAL_INPUTS:
                statuses.append(name)
    assert EVENTS == set(events), 'Every pulse must have explicit event semantics'
    level_sources = ['csr_' + p for p in levels] + list(UPGRADE)
    level_targets = levels + list(UPGRADE.values())
    level_width = sum(widths[p] for p in levels + list(UPGRADE))
    event_width = sum(widths[p] for p in events)
    status_width = sum(32 if p == 'in_adev0_xrun' else widths[p] for p in statuses)
    assert max(level_width + event_width, status_width) <= 4096
    out = ['// Generated by scripts/generate_sc7f0_csr_cdc.py; do not edit by hand.',
           '// Ordered configuration/events to PCIe; coherent telemetry back to PS.',
           '`timescale 1ns / 1ps',
           'module qpcie_csr_reg_space #(' + params + ')(\n' +
           re.sub(r'\boutput reg\b', 'output wire', interface) + ',',
           '    input wire pcie_clk, pcie_rst_n,',
           '    output wire [31:0] pcie_upg_ctrl, pcie_upg_size,',
           '    output wire [63:0] pcie_upg_host_addr', ');', '']
    # cdc_write_ready/commit are an implementation detail, not wrapper ports.
    out[3] = re.sub(r'\n\s*input\s+wire\s+cdc_write_ready,', '', out[3])
    out[3] = re.sub(r'\n\s*output\s+wire\s+cdc_write_commit,', '', out[3])
    out += ['    wire csr_ready, csr_commit, csr_online;']
    for direction, width, name in ports:
        if name in levels + events:
            out.append(f'    wire {width} csr_{name};')
        elif name in statuses and name != 'in_adev0_xrun':
            out.append(f'    wire {width} status_{name};')
    out += ['    wire ps_ready_pcie, pcie_ready_ps, status_valid;',
            '    // Controls, telemetry and xrun lifecycle share one peer reset',
            '    // synchronizer per domain. No reset fan-out/reconvergence.',
            '    wire xrun_reset = !ps_ready_pcie || !pcie_rst_n;',
            '    reg [31:0] xrun_count = 32\'d0;',
            '    always @(posedge pcie_clk or posedge xrun_reset)',
            '        if (xrun_reset) xrun_count <= 32\'d0;',
            '        else if (in_adev0_xrun) xrun_count <= xrun_count + 1\'b1;',
            '    wire [31:0] status_xrun_count;',
            '    reg [31:0] last_xrun_count = 32\'d0;',
            '    always @(posedge clk or negedge rst_n)',
            '        if (!rst_n) last_xrun_count <= 32\'d0;',
            '        else if (!pcie_ready_ps) last_xrun_count <= 32\'d0;',
            '        else if (csr_online && status_valid) last_xrun_count <= status_xrun_count;',
            '    wire status_in_adev0_xrun = csr_online && status_valid && pcie_ready_ps &&',
            '                              (status_xrun_count != last_xrun_count);', '']
    out += [f'    wire [{level_width-1}:0] level_word;',
            f'    wire [{event_width-1}:0] event_word;',
            f'    qpcie_csr_cdc #(.LEVEL_WIDTH({level_width}), .EVENT_WIDTH({event_width})) u_controls (',
            '        .src_clk(clk), .src_rst_n(rst_n),',
            '        .dest_clk(pcie_clk), .dest_rst_n(pcie_rst_n),',
            '        .src_commit(csr_commit), .src_ready(csr_ready), .src_online(csr_online),',
            '        .src_peer_ready(pcie_ready_ps), .dest_peer_ready(ps_ready_pcie),',
            '        .src_level({' + ', '.join(level_sources) + '}),',
            '        .src_event({' + ', '.join('csr_' + p for p in events) + '}),',
            '        .dest_level(level_word), .dest_event(event_word)', '    );',
            '    assign {' + ', '.join(level_targets) + '} = level_word;',
            '    assign {' + ', '.join(events) + '} = event_word;', '',
            f'    wire [{status_width-1}:0] status_word;',
            f'    qpcie_status_cdc #(.WIDTH({status_width})) u_status (',
            '        .src_clk(pcie_clk), .src_rst_n(pcie_rst_n), .src_peer_ready(ps_ready_pcie),',
            '        .dest_clk(clk), .dest_rst_n(rst_n), .dest_online(csr_online),',
            '        .src_status({' + ', '.join('xrun_count' if p == 'in_adev0_xrun' else p for p in statuses) + '}),',
            '        .dest_status(status_word), .dest_valid(status_valid)', '    );',
            '    assign {' + ', '.join('status_xrun_count' if p == 'in_adev0_xrun' else 'status_' + p for p in statuses) +
            f'}} = csr_online ? status_word : {status_width}\'d0;', '',
            '    axil_reg_space #(.C_VERSION(C_VERSION), .NUM_VIDEO_CH(NUM_VIDEO_CH),',
            '        .NUM_AUDIO_CH(NUM_AUDIO_CH), .CDC_ENABLE(1)) u_bank (']
    conns = []
    for direction, width, name in ports:
        target = name
        if name in levels + events:
            target = 'csr_' + name
        elif name in statuses:
            target = 'status_' + name
        elif name == 'cdc_write_ready':
            target = 'csr_ready'
        elif name == 'cdc_write_commit':
            target = 'csr_commit'
        conns.append(f'        .{name}({target})')
    out += [',\n'.join(conns), '    );', 'endmodule', '']
    return '\n'.join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = generate()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != output:
            raise SystemExit('CSR CDC wrapper is stale; regenerate it')
    else:
        OUTPUT.write_text(output)
        print(OUTPUT)


if __name__ == '__main__':
    main()
