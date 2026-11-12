#!/usr/bin/env python3
"""Run the packaged card initialiser against the card's own captured tool output.

The first release-26111204-r2 image shipped an initialiser that resolved media entities
by awk field 4.  On this card the capture node entity is literally

    - entity 1: video-capture output 0 (1 pad, 1 link)

so field 4 is only "video-capture" and the lookup silently found nothing: every boot the
ExecStartPre logged "entity video-capture output 0 not in the media controller" and the
encoder never started (build/deploy-r2-20261112/logs/01 and /02).  A reviewer reading the
script cannot see that, because nothing in the script says what the card prints.

These tests therefore run the real script, with media-ctl/v4l2-ctl replaced by stubs that
replay text captured read-only from the card, and assert the whole contract:

  * the cold-boot graph (vpss-csc pads at 1280x720) is rewritten to 3840x2160 in the one
    order that works, sink pad first, then source pad, both field=none;
  * the capture node format is set only after the graph, with the "=" spelling;
  * a non-4K60 locked timing is refused rather than fitted;
  * an unlocked source times out and exits non-zero without touching the graph;
  * the script never issues I2C.

No hardware, no network.
"""
from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HELPER = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud'
          / 'files/sc7f0-capture-init.sh')
FIX = Path(__file__).resolve().parent / 'fixtures'
MEDIA = (FIX / 'sc7f0-card-media-ctl-p.txt').read_text()
DV_LOCKED = (FIX / 'sc7f0-card-dv-timings-locked.txt').read_text()
NODE_NV12 = (FIX / 'sc7f0-card-video0-nv12.txt').read_text()

STUB_V4L2 = """#!/bin/sh
# Replay of the card's v4l2-ctl, plus a transcript of what the initialiser asked for.
STATE=__STATE__
LOG="$STATE/calls"
printf '%s\\n' "$*" >> "$LOG"
case "$*" in
  *--query-dv-timings*)
    cat "$STATE/dv.txt"
    exit 0;;
  *--set-subdev-fmt*)
    printf 'SET-SUBDEV %s\\n' "$*" >> "$STATE/sets"
    PAD=$(printf '%s' "$*" | sed -n 's/.*pad=\\([0-9]\\).*/\\1/p')
    WH=$(printf '%s' "$*" | sed -n 's/.*width=\\([0-9]*\\),height=\\([0-9]*\\).*/\\1x\\2/p')
    if [ "$PAD" = 0 ]; then
      sed "s#\\[fmt:RBG888_1X24/1280x720 field:none colorspace:rec709\\]#[fmt:RBG888_1X24/$WH field:none colorspace:rec709]#" \\
          "$STATE/media.txt" > "$STATE/media.new" && mv "$STATE/media.new" "$STATE/media.txt"
    else
      sed "s#\\[fmt:VYYUYY8_1X24/1280x720 field:none colorspace:rec709\\]#[fmt:VYYUYY8_1X24/$WH field:none colorspace:rec709]#" \\
          "$STATE/media.txt" > "$STATE/media.new" && mv "$STATE/media.new" "$STATE/media.txt"
    fi
    exit 0;;
  *--set-fmt-video=*)
    printf 'SET-VIDEO %s\\n' "$*" >> "$STATE/sets"
    printf '%s' "$*" | sed -n 's/.*width=\\([0-9]*\\),height=\\([0-9]*\\).*/\\1x\\2/p' > "$STATE/nodeset"
    exit 0;;
  *--get-fmt-video*)
    if [ -f "$STATE/nodeset" ]; then
      WH=$(cat "$STATE/nodeset")
      printf 'Format Video Capture Multiplanar:\\n'
      printf '\\tWidth/Height      : %s\\n' "$(printf '%s' "$WH" | tr 'x' '/')"
      printf "\\tPixel Format      : 'NV12' (Y/UV 4:20)\\n"
      printf '\\tField             : None\\n'
      printf '\\tNumber of planes  : 0\\n'
    else
      printf 'Format Video Capture Multiplanar:\\n\\tWidth/Height      : 1920/0\\n\\tPixel Format      : %s\\n\\tNumber of planes  : 0\\n' "'YUYV'"
    fi
    exit 0;;
esac
exit 0
"""

STUB_MEDIA_CTL = """#!/bin/sh
# The helper only ever runs `media-ctl -p`; replay the live media controller table.
if [ "$1" = "-p" ]; then cat "$STATE_DIR/media.txt"; else cat "$1"; fi
"""


class CardReplay:
    """A directory whose media-ctl/v4l2-ctl replay the captured card, tracking calls."""

    def __init__(self, dv_text: str):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        (self.state / 'media.txt').write_text(MEDIA)
        (self.state / 'dv.txt').write_text(dv_text)
        (self.state / 'nv12.txt').write_text(NODE_NV12)
        (self.state / 'calls').write_text('')
        (self.state / 'sets').write_text('')
        bin_ = self.root / 'bin'
        bin_.mkdir()
        (bin_ / 'media-ctl').write_text(STUB_MEDIA_CTL)
        (bin_ / 'v4l2-ctl').write_text(
            STUB_V4L2.replace('__STATE__', str(self.state)))
        for f in bin_.iterdir():
            f.chmod(f.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP)

    def close(self):
        self.tmp.cleanup()

    def run(self, extra_env=None):
        env = dict(os.environ)
        env['PATH'] = str(self.root / 'bin') + os.pathsep + env['PATH']
        env['STATE_DIR'] = str(self.state)
        env['SC7F0_CAPTURE_INIT_WAIT_SEC'] = '3'
        env.update(extra_env or {})
        r = subprocess.run(['/bin/sh', str(HELPER)], capture_output=True, text=True,
                           env=env, timeout=120)
        return r

    @property
    def calls(self):
        return (self.state / 'calls').read_text()

    @property
    def sets(self):
        return (self.state / 'sets').read_text()

    @property
    def media_after(self):
        return (self.state / 'media.txt').read_text()


class LockedSourceTest(unittest.TestCase):
    def setUp(self):
        self.card = CardReplay(DV_LOCKED)

    def tearDown(self):
        self.card.close()

    def test_the_initialiser_succeeds_against_the_real_card_output(self):
        r = self.card.run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('SC7F0_CAPTURE_INIT PASS', r.stdout)
        self.assertIn('video=/dev/video0', r.stdout)
        self.assertIn('rx_locked 3840x2160', r.stdout)

    def test_entity_names_with_spaces_resolve(self):
        r = self.card.run()
        self.assertNotIn('not in the media controller', r.stdout + r.stderr)

    def test_graph_then_node_order_and_exact_arguments(self):
        r = self.card.run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        sets = self.card.sets.splitlines()
        pad0 = [l for l in sets if l.startswith('SET-SUBDEV') and 'pad=0' in l]
        pad1 = [l for l in sets if l.startswith('SET-SUBDEV') and 'pad=1' in l]
        node = [l for l in sets if l.startswith('SET-VIDEO')]
        self.assertEqual(1, len(pad0), sets)
        self.assertEqual(1, len(pad1), sets)
        self.assertEqual(1, len(node), sets)
        self.assertIn('pad=0,width=3840,height=2160,code=0x100e,field=none', pad0[0])
        self.assertIn('pad=1,width=3840,height=2160,code=0x2100,field=none', pad1[0])
        self.assertIn('--set-fmt-video=width=3840,height=2160,pixelformat=NV12', node[0])
        self.assertLess(sets.index(pad0[0]), sets.index(pad1[0]), 'sink before source')
        self.assertLess(sets.index(pad1[0]), sets.index(node[0]), 'graph before node format')
        self.assertNotIn('--set-fmt-video ', node[0])

    def test_pads_end_up_at_4k_with_field_none(self):
        self.assertEqual(0, self.card.run().returncode)
        after = self.card.media_after
        self.assertIn('[fmt:RBG888_1X24/3840x2160 field:none colorspace:rec709]', after)
        self.assertIn('[fmt:VYYUYY8_1X24/3840x2160 field:none colorspace:rec709]', after)
        self.assertNotIn('1280x720', after)

    def test_no_i2c_is_ever_attempted(self):
        self.card.run()
        self.assertNotIn('i2c', self.card.calls.lower())


class UnlockedSourceTest(unittest.TestCase):
    def setUp(self):
        self.card = CardReplay('\n'.join([
            '\tActive width: 0', '\tActive height: 0', '\tFrame format: progressive']))

    def tearDown(self):
        self.card.close()

    def test_it_waits_then_refuses_to_configure_anything(self):
        r = self.card.run()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('WAIT_TIMEOUT', r.stdout)
        self.assertIn('want 3840x2160', r.stdout)
        self.assertEqual('', self.card.sets.strip(),
                         'an unlocked source must not have its graph rewritten')
        self.assertIn('1280x720', self.card.media_after)


class WrongTimingTest(unittest.TestCase):
    def setUp(self):
        self.card = CardReplay('\n'.join([
            '\tActive width: 1920', '\tActive height: 1080',
            '\tFrame format: progressive']))

    def tearDown(self):
        self.card.close()

    def test_a_locked_but_wrong_timing_is_reported_not_fitted(self):
        r = self.card.run()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('1920x1080', r.stdout)
        self.assertEqual('', self.card.sets.strip())


class GeometryOverrideTest(unittest.TestCase):
    """The initialiser is 4K60 by default, not by magic: the target is an input."""

    def setUp(self):
        self.card = CardReplay('\n'.join([
            '\tActive width: 1920', '\tActive height: 1080',
            '\tFrame format: progressive']))

    def tearDown(self):
        self.card.close()

    def test_the_target_geometry_is_declared(self):
        r = self.card.run({'SC7F0_CAPTURE_WIDTH': '1920', 'SC7F0_CAPTURE_HEIGHT': '1080'})
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)
        self.assertIn('target=1920x1080', r.stdout)
        self.assertIn('SC7F0_CAPTURE_INIT PASS', r.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
