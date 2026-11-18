#!/usr/bin/env python3
"""Offline audit of the A1 (RX -> PS DDR RGBX8) and B1 (SOF genlock) RTL facts.

Why this exists
---------------
Both halves of the 26111602 round are the kind of change that looks finished in
the diff and is wrong in a way only the board would reveal:

  A1  the writer that fills the compositor's background has to produce the exact
      byte order Plane-A's ``vplane0`` format (``abgr8888`` / ``AB24``) expects,
      on a geometry the PS HP1 port can actually carry, and the Host capture path
      (``/dev/video0`` RGB3 4K60 over PCIe C2H) has to be left completely alone.
      "It elaborates" says nothing about any of that.
  B1  a compositor that locks on the wrong frame start is not visibly broken - it
      composites a frame that is one frame stale, which is exactly the defect
      pitfall 16 of the reference project (SC6F0_SDIFB_详细设计文档.md §5.4.5)
      exists to describe.  The RTL also has to keep forwarding the background
      while it is not locked, and that property is invisible in a netlist.

So the facts are asserted here, in the repository, before hours of Vivado.  Every
comparison is whitespace-normalised, so reformatting a file cannot silently
disable a check.  Read-only; exit 0 prints A1B1_RTL_PASS.

The runtime counterpart of this audit is
``scripts/sim_sc7f0_rgb_compositor.tcl`` (genlock + RGBX repack testbenches, real
XPM libraries), which is what actually proves the behaviour; this file only
guards against the facts drifting apart again.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT_DEFAULT = Path(__file__).resolve().parent.parent
WS = re.compile(r'\s+')


def norm(s: str) -> str:
    return WS.sub(' ', s)


def read(root: Path, rel: str) -> str:
    p = root / rel
    if not p.exists():
        raise SystemExit(f'A1B1_RTL_FAIL missing file {rel}')
    return norm(p.read_text(encoding='utf-8', errors='replace'))


class Audit:
    def __init__(self) -> None:
        self.problems: list[str] = []
        self.checks = 0

    def contains(self, label: str, hay: str, *needles: str) -> None:
        self.checks += 1
        missing = [n for n in needles if norm(n) not in hay]
        if missing:
            self.problems.append(f'{label}: missing {missing!r}')

    def absent(self, label: str, hay: str, *needles: str) -> None:
        self.checks += 1
        found = [n for n in needles if norm(n) in hay]
        if found:
            self.problems.append(f'{label}: must not contain {found!r}')


def audit_a1(root: Path, a: Audit) -> None:
    pipe = read(root, 'rtl/sc7f0_capture_pipeline.v')
    wrap = read(root, 'rtl/sc7f0_ps_frmbuf_writer.v')
    ip = read(root, 'scripts/create_sc7f0_frmbuf_ip.tcl')
    build = read(root, 'scripts/build_zu4ev.tcl')
    psbd = read(root, 'scripts/create_zu4ev_ps_bd.tcl')
    top = read(root, 'rtl/zu4ev_pcie_card_top.v')

    # ---- the pipeline routes through the persona wrapper --------------------
    # One instance name (`u_writer`) in both personalities, so nothing outside
    # this file has to know which writer was chosen.
    a.contains('capture_pipeline', pipe,
               'sc7f0_ps_frmbuf_writer u_writer', '(SC7F0_RGB_COMPOSITOR)')
    a.absent('capture_pipeline no longer instantiates the IP directly', pipe,
             'sc7f0_frmbuf_wr #(')

    # ---- the wrapper: NV12 by default, RGBX only under the define -----------
    a.contains('writer_wrapper', wrap,
               '`ifdef SC7F0_RGB_COMPOSITOR',
               'sc7f0_frmbuf_wr_rgbx u_frmbuf_wr_rgbx',
               '`else', 'sc7f0_frmbuf_wr u_frmbuf_wr')
    # The RGB branch feeds the CSC's 24-bit stream straight into the writer.  A fabric
    # repack to 32 bits per pixel was this round's first attempt; the writer's video
    # input is three bytes per pixel and pads to the memory word itself, so a repack
    # would have misaligned every pixel after the first.
    a.contains('writer feeds the IP directly', wrap,
               '.s_axis_video_TDATA  (s_axis_video_TDATA),',
               '.s_axis_video_TVALID (s_axis_video_TVALID),')
    a.absent('writer has no fabric RGBX repack', wrap, 'rgbx_pack')

    # ---- why the memory shape needs no repack --------------------------------
    # Plane A reads abgr8888, memory bytes R,G,B,A.  v_frmbuf_wr configured HAS_RGBX8
    # puts R,G,B,X in memory, which is that same layout with the alpha nibble unused,
    # and it builds the fourth byte itself from a three-byte-per-pixel input.  Both
    # facts are asserted above; nothing in the fabric reshuffles colour bytes.

    # ---- framebuffer IP geometry and its guards ----------------------------
    a.contains('frmbuf_ip rgbx', ip,
               'proc create_sc7f0_frmbuf_wr_rgbx_ip {}',
               '-module_name sc7f0_frmbuf_wr_rgbx',
               'CONFIG.HAS_RGBX8 {1}', 'CONFIG.HAS_BGRX8 {0}', 'CONFIG.HAS_RGB8 {0}',
               'CONFIG.HAS_Y_UV8_420 {0}', 'CONFIG.SAMPLES_PER_CLOCK {4}',
               'CONFIG.AXIMM_DATA_WIDTH {256}',
               'sc7f0_frmbuf_apply_ip_config [get_ips sc7f0_frmbuf_wr_rgbx]',
               'generate_target all [get_ips sc7f0_frmbuf_wr_rgbx]')
    a.contains('frmbuf_ip refuses a wrong RGBX geometry', ip,
               'SC7F0_RGBX_FRMBUF_NO_FORMAT', 'SC7F0_RGBX_FRMBUF_EXTRA_FORMAT',
               'SC7F0_RGBX_FRMBUF_BAD_PPC', 'SC7F0_RGBX_FRMBUF_BAD_AXIMM',
               'SC7F0_RGBX_FRMBUF_CFG')
    # HAS_RGBX8 versus HAS_BGRX8 is the one place a future editor would "fix" wrongly,
    # so the whole chain is written down where the IP is built.
    a.contains('frmbuf_ip documents the RGBX byte-order chain', ip,
               'XILINX_FRMBUF_FMT_RGBX8', 'DRM_FORMAT_XBGR8888',
               'XILINX_FRMBUF_FMT_BGRX8', 'DRM_FORMAT_XRGB8888', 'AB24')

    # ---- build wiring ------------------------------------------------------
    a.contains('build_zu4ev builds the RGBX writer only for the persona', build,
               'if {$rgb_enable} { create_sc7f0_frmbuf_wr_rgbx_ip }',
               'lappend verilog_defs SC7F0_RGB_COMPOSITOR=1')

    # ---- the HP1 facts the geometry rests on -------------------------------
    a.contains('ps_bd HP1 is 128-bit at 300 MHz', psbd,
               'CONFIG.DATA_WIDTH {128} CONFIG.ADDR_WIDTH {49}',
               'CONFIG.FREQ_HZ {300000000}] $hp1',
               'create_bd_port -dir I -type clk -freq_hz 300000000 dp_mem_clk',
               'CONFIG.ASSOCIATED_BUSIF S_AXI_HP1_FPD')
    # 128 bit x 300 MHz = 4.8 GB/s against the 1.99 GB/s a 4K60 RGBX8 plane
    # needs; the writer itself stays native 256-bit and sc7f0_capture_width does
    # the conversion, which is the arrangement that already met timing.
    a.contains('capture width converter still lands the writer on HP1', pipe,
               'sc7f0_capture_width')

    # ---- the Host capture path must be untouched ---------------------------
    a.contains('host RGB888 gearbox still present and unchanged in geometry', top,
               'sc7f0_rgb24_axis_pack #(.NATIVE_PPC(2), .FIFO_DEPTH(1024)) u_rgb24_pack')
    a.contains('host C2H engine still present', top, 'sc7f0_rgb24_c2h_engine')
    a.contains('ps capture is the only persona writer user', top,
               'sc7f0_capture_pipeline u_ps_capture')
    a.absent('the persona writer is not wired into the PCIe DMA chain', top,
             'sc7f0_ps_frmbuf_writer u_dma')


def audit_b1(root: Path, a: Audit) -> None:
    blend = read(root, 'rtl/sc7f0_alpha_blend_2ppc.v')
    comp = read(root, 'rtl/sc7f0_rgb_compositor.v')
    ctrl = read(root, 'rtl/sc7f0_rgb_overlay_ctrl.v')
    top = read(root, 'rtl/zu4ev_pcie_card_top.v')

    a.contains('blend genlock states', blend,
               'GL_SEEK_OVL', 'GL_WAIT_VSOF', 'GL_LOCKED',
               'OVERLAY_STARVE_LIMIT', 'ovl_starve')
    a.contains('blend status outputs', blend,
               'output wire [1:0] gl_state', 'output reg [2:0] gl_drop_reason',
               'output reg [31:0] gl_lock_count',
               'output reg [31:0] base_passthru_beats',
               'output reg [31:0] lock_lost_count')
    # The property that matters most: forwarding plane A must never depend on the
    # overlay being present, or the compositor starves the background source -
    # pitfall 16.  Structurally, base_only may not mention the overlay at all.
    a.contains('blend forwards plane A without the overlay', blend,
               'wire base_only = !is_locked && !lock_fire && b_valid && stage0_free;')
    a.absent('blend never gates plane A on the overlay', blend,
             'base_only && o_valid', 'base_only && !o_empty')
    # Locking requires both heads at a frame start, and only from a not-locked
    # state; the seek state parks in GL_WAIT_VSOF when the overlay arrives first.
    a.contains('blend lock requires a dual frame start', blend,
               'wire lock_fire = pair_sof && pair_ready && !is_locked;',
               'gl_state_q <= GL_WAIT_VSOF;')
    # A bounded give-up, so a dead overlay cannot hold the TX forever.
    a.contains('blend gives up on overlay starvation', blend,
               'GL_SEEK_OVL;', 'lock_lost_count <= lock_lost_count + 32\'d1;')
    # TLAST here is end of LINE, not end of frame: the comment that says so is
    # load-bearing, because "matched TLAST means a new frame" was the trap.
    a.contains('blend treats TLAST as end of line', blend, 'end of line')

    a.contains('compositor exports genlock status', comp,
               'output wire [1:0] blend_gl_state',
               'output wire [2:0] blend_drop_reason',
               'output wire [31:0] blend_lock_count',
               'output wire [31:0] blend_base_passthru',
               '.gl_state (blend_gl_state)')

    a.contains('overlay CSR exposes the genlock', ctrl,
               "12'h07C", "12'h080", "12'h084",
               'blend_gl_seeking', 'blend_gl_wait_vsof',
               'gl_lock_count_c', 'gl_passthru_c')
    # One-hot levels and Gray-coded counters cross domains; a raw 2-bit state
    # vector may never be synchronised as a vector.
    a.contains('overlay CSR crosses the status safely', ctrl,
               'xpm_cdc_single', 'xpm_cdc_gray')
    a.absent('overlay CSR never crosses the raw 2-bit state vector', ctrl,
             'xpm_cdc_gray #(DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .WIDTH(2))')

    a.contains('top expands the state to one-hot for the crossing', top,
               'wire blend_gl_seeking = (blend_gl_state == 2\'d0);',
               'wire blend_gl_wait_vsof = (blend_gl_state == 2\'d1);',
               '.blend_gl_seeking(blend_gl_seeking)',
               '.blend_gl_wait_vsof(blend_gl_wait_vsof)')
    a.absent('top does not hand the binary state vector to the CDC', top,
             '.gl_state_q (blend_gl_state)')


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=str(ROOT_DEFAULT))
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()

    a = Audit()
    audit_a1(root, a)
    audit_b1(root, a)

    print(f'A1B1_AUDIT root={root} checks={a.checks}')
    for p in a.problems:
        print(f'A1B1_AUDIT_PROBLEM {p}')
    if a.problems:
        print('A1B1_RTL_FAIL')
        return 1
    print('A1B1_RTL_PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
