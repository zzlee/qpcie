#!/usr/bin/env python3
"""Run the RGB-compositor boot initialiser against the card's own captured output.

The RGB-compositor persona has no VCU, so sc7f0-vcud - which owns the VCU persona's capture
initialiser as an ExecStartPre - is removed from that image.  Nothing else configured the
capture pipeline, and the measured result of that omission is in
build/accept-26111602/card-pipeline.txt: after a cold boot both vpss-csc pads still carry
the driver default

    [fmt:UYVY8_1X16/1280x720 field:none colorspace:rec709]

so the VIPP node offers nothing usable and sc7f0_dmabuf_loop (HDMI RX -> PS DDR -> HDMI TX)
cannot start.  The acceptance session fixed it by hand, and
build/accept-26111602/card-capture-final.txt section A records exactly what worked - two
`media-ctl -V` writes, after which the node advertised RX24 and ten frames streamed at
60.00 fps (331,776,000 bytes).

So this test runs the real script with media-ctl/v4l2-ctl replaced by stubs that replay the
captured card, and asserts the contract that evidence established:

  * both CSC pads end up at RBG888_1X24/3840x2160 field:none, sink pad first;
  * the writes go through `media-ctl -V`, because `v4l2-ctl --set-subdev-fmt code=0x100a`
    returns EINVAL on this card for that code (card-rgbcap.txt steps 2 and 3);
  * the node format is RX24 - not BGRX/XBGR, which the node rejects as an invalid
    pixelformat (card-bgrx.txt) - and is set only after the graph;
  * an unlocked source times out without touching the graph, and a locked-but-different
    timing is reported rather than fitted;
  * the unit's ExecStart is the path the recipe installs, and the recipe is installed only
    for the persona that needs it;
  * nothing here issues I2C.

No hardware, no network.
"""
from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
APP = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps'
       / 'sc7f0-capture-init-rgb')
HELPER = APP / 'files/sc7f0-capture-init-rgb.sh'
UNIT = APP / 'files/sc7f0-capture-init-rgb.service'
RECIPE = APP / 'sc7f0-capture-init-rgb.bb'
BBAPPEND = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-core/images'
            / 'petalinux-image-minimal.bbappend')
FIX = Path(__file__).resolve().parent / 'fixtures'
MEDIA = (FIX / 'sc7f0-card-media-ctl-p-rgb.txt').read_text()
DV_LOCKED = (FIX / 'sc7f0-card-dv-timings-locked.txt').read_text()

# The card's own cold-boot state for this persona.
# The card's own cold-boot state for this persona.  No brackets: the media-ctl
# stub adds them, because that is how the pads appear in `media-ctl -p` output.
COLD_PAD = 'fmt:UYVY8_1X16/1280x720 field:none colorspace:rec709'
WARM_PAD = '[fmt:RBG888_1X24/3840x2160 field:none]'

STUB_MEDIA_CTL = r"""#!/bin/sh
# media-ctl as this card behaves: -p prints the live topology; -V applies one pad format and
# returns 0 only for the code the vpss-csc accepts (RGB888_1X24 and UYVY at 4K are EINVAL -
# the kernel's own name for the accepted code is the misspelling RBG888_1X24).
STATE=$STATE_DIR
printf '%s\n' "$*" >> "$STATE/calls"
if [ "$1" = "-p" ]; then cat "$STATE/media.txt"; exit 0; fi
if [ "$1" = "-V" ]; then
  shift
  SPEC="$*"
  case "$SPEC" in
    *UYVY8_1X16*|*RGB888_1X24*) echo "error: unsupported bus format" >&2; exit 1;;
    *RBG888_1X24*)
      FMT=$(printf '%s' "$SPEC" | sed -n 's/.*\[\(fmt:[^]]*\)\].*/\1/p')
      # Replace only the next remaining default pad, so a script that sets one pad cannot
      # pass the initialiser's own two-pad assertion.
      awk -v cold="$COLD" -v warm="$FMT" '
        BEGIN { lb = "[" cold "]"; wb = "[" warm "]" }
        !done { i = index($0, lb); if (i) { $0 = substr($0, 1, i - 1) wb substr($0, i + length(lb)); done = 1 } }
        { print }' "$STATE/media.txt" > "$STATE/media.new" && mv "$STATE/media.new" "$STATE/media.txt"
      exit 0;;
  esac
  echo "media-ctl stub: unrecognised -V spec: $SPEC" >&2; exit 1
fi
echo "media-ctl stub: unexpected arguments: $*" >&2
exit 1
"""

STUB_V4L2 = r"""#!/bin/sh
# v4l2-ctl as this card behaves. --get-fmt-video reports the driver default (1920/0 YUYV)
# until --set-fmt-video= has been seen with the fourcc the node actually advertises, which
# for this graph is RX24 and nothing else.
STATE=$STATE_DIR
printf '%s\n' "$*" >> "$STATE/calls"
case "$*" in
  *--query-dv-timings*) cat "$STATE/dv.txt"; exit 0;;
  *--set-fmt-video=*)
    printf '%s\n' "$*" >> "$STATE/sets"
    case "$*" in
      *pixelformat=RX24*)
        printf '%s' "$*" | sed -n 's/.*width=\([0-9]*\),height=\([0-9]*\).*/\1x\2/p' \
            > "$STATE/nodeset"; exit 0;;
      *) echo "The pixelformat '$(printf '%s' "$*" | sed -n 's/.*pixelformat=\([A-Z0-9]*\).*/\1/p')' is invalid" >&2
         exit 1;;
    esac;;
  *--get-fmt-video*)
    if [ -f "$STATE/nodeset" ]; then
      WH=$(cat "$STATE/nodeset")
      printf 'Format Video Capture Multiplanar:\n'
      printf '\tWidth/Height      : %s\n' "$(printf '%s' "$WH" | tr 'x' '/')"
      printf "\tPixel Format      : 'RX24' (32-bit XBGR 8-8-8-8)\n"
      printf '\tField             : None\n'
      printf '\tNumber of planes  : 0\n'
    else
      printf "Format Video Capture Multiplanar:\n\tWidth/Height      : 1920/0\n\tPixel Format      : 'YUYV'\n\tNumber of planes  : 0\n"
    fi
    exit 0;;
  *--set-subdev-fmt*)
    # Exactly what the card does for code=0x100a on either pad.
    echo "ioctl: VIDIOC_SUBDEV_S_FMT: failed: Invalid argument" >&2; exit 1;;
esac
exit 0
"""


class CardReplay:
    """A directory whose media-ctl/v4l2-ctl replay the captured RGB persona."""

    def __init__(self, dv_text: str, media_text: str = MEDIA):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        (self.state / 'media.txt').write_text(media_text)
        (self.state / 'dv.txt').write_text(dv_text)
        (self.state / 'calls').write_text('')
        (self.state / 'sets').write_text('')
        bin_ = self.root / 'bin'
        bin_.mkdir()
        (bin_ / 'media-ctl').write_text(STUB_MEDIA_CTL)
        (bin_ / 'v4l2-ctl').write_text(STUB_V4L2)
        for f in bin_.iterdir():
            f.chmod(f.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP)

    def close(self):
        self.tmp.cleanup()

    def run(self, extra_env=None):
        env = dict(os.environ)
        env['PATH'] = str(self.root / 'bin') + os.pathsep + env['PATH']
        env['STATE_DIR'] = str(self.state)
        env['COLD'] = COLD_PAD
        env['SC7F0_RGB_CAPTURE_INIT_WAIT_SEC'] = '3'
        env.update(extra_env or {})
        return subprocess.run(['/bin/sh', str(HELPER)], capture_output=True, text=True,
                              env=env, timeout=120)

    @property
    def calls(self):
        return (self.state / 'calls').read_text()

    @property
    def sets(self):
        return (self.state / 'sets').read_text()

    @property
    def media_after(self):
        return (self.state / 'media.txt').read_text()


def csc_block(text: str) -> str:
    """The media-ctl -p block describing the vpss-csc, as the initialiser scopes it."""
    lines, inside = [], False
    for line in text.splitlines():
        if line.startswith('- entity'):
            name = re.sub(r'^- entity \d+:\s*', '', line)
            name = re.sub(r'\s*\([^)]*\)\s*$', '', name)
            inside = name == 'b0060000.vpss-csc'
            continue
        if inside:
            lines.append(line)
    return '\n'.join(lines)


DV_WRONG = '\n'.join(['\tActive width: 1920', '\tActive height: 1080',
                      '\tFrame format: progressive'])
DV_UNLOCKED = '\n'.join(['\tActive width: 0', '\tActive height: 0',
                         '\tFrame format: progressive'])


class LockedSourceTest(unittest.TestCase):
    def setUp(self):
        self.card = CardReplay(DV_LOCKED)

    def tearDown(self):
        self.card.close()

    def test_it_succeeds_against_the_real_card_output(self):
        r = self.card.run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('SC7F0_RGB_CAPTURE_INIT PASS', r.stdout)
        self.assertIn('rx_locked 3840x2160', r.stdout)

    def test_both_pads_end_up_at_4k_rgb_with_field_none(self):
        self.assertEqual(0, self.card.run().returncode)
        block = csc_block(self.card.media_after)
        self.assertEqual(2, block.count(WARM_PAD), block)
        self.assertNotIn('UYVY8_1X16', block)
        self.assertNotIn('1280x720', block)

    def test_the_graph_is_written_sink_then_source_then_the_node(self):
        r = self.card.run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        writes = [l for l in self.card.calls.splitlines() if l.startswith('-V')]
        self.assertEqual(2, len(writes), writes)
        self.assertIn('"b0060000.vpss-csc":0', writes[0])
        self.assertIn('"b0060000.vpss-csc":1', writes[1])
        for w in writes:
            self.assertIn('fmt:RBG888_1X24/3840x2160 field:none', w)
        node = [l for l in self.card.sets.splitlines() if '--set-fmt-video=' in l]
        self.assertEqual(1, len(node), self.card.sets)
        self.assertIn('width=3840,height=2160,pixelformat=RX24', node[0])
        # The node write must be the last thing: a node format against an unvalidated graph
        # is the -EINVAL/VIDIOC_QBUF failure this ordering exists to avoid.
        self.assertGreater(self.card.calls.index('--set-fmt-video='),
                           self.card.calls.index('-V "b0060000.vpss-csc":1'))

    def test_it_uses_media_ctl_because_v4l2_ctl_cannot_set_this_code(self):
        r = self.card.run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn('set-subdev-fmt', self.card.calls)

    def test_the_node_is_programmed_to_the_fourcc_it_advertises(self):
        self.card.run()
        self.assertIn("pixelformat=RX24", self.card.sets)
        self.assertNotRegex(self.card.sets, r'pixelformat=(BGRX|XBGR)')

    def test_no_i2c_is_ever_attempted(self):
        self.card.run()
        self.assertNotIn('i2c', self.card.calls.lower())


class OnePadOnlyIsNotEnoughTest(unittest.TestCase):
    """A script that set only the sink pad must fail, not report success."""

    def test_the_two_pad_assertion_is_a_real_assertion(self):
        broken = HELPER.read_text().replace('set_pad 0\nset_pad 1', 'set_pad 0')
        self.assertNotEqual(HELPER.read_text(), broken, 'fixture must differ')
        card = CardReplay(DV_LOCKED)
        self.addCleanup(card.close)
        with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False) as fh:
            fh.write(broken)
            path = Path(fh.name)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        env = dict(os.environ)
        env['PATH'] = str(card.root / 'bin') + os.pathsep + env['PATH']
        env['STATE_DIR'] = str(card.state)
        env['COLD'] = COLD_PAD
        env['SC7F0_RGB_CAPTURE_INIT_WAIT_SEC'] = '3'
        r = subprocess.run(['/bin/sh', str(path)], capture_output=True, text=True,
                           env=env, timeout=60)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('FAIL', r.stdout)
        self.assertIn('csc pads are not both', r.stdout)
        self.assertEqual('', card.sets.strip(),
                         'a half-configured graph must not reach the node')


class UnlockedSourceTest(unittest.TestCase):
    def setUp(self):
        self.card = CardReplay(DV_UNLOCKED)

    def tearDown(self):
        self.card.close()

    def test_it_waits_then_refuses_to_configure_anything(self):
        r = self.card.run()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('WAIT_TIMEOUT', r.stdout)
        self.assertIn('want 3840x2160', r.stdout)
        self.assertNotIn('-V', self.card.calls)
        self.assertIn('1280x720', self.card.media_after)


class WrongTimingTest(unittest.TestCase):
    def setUp(self):
        self.card = CardReplay(DV_WRONG)

    def tearDown(self):
        self.card.close()

    def test_a_locked_but_wrong_timing_is_reported_not_fitted(self):
        r = self.card.run()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('1920x1080', r.stdout)
        self.assertEqual('', self.card.sets.strip())


class GeometryOverrideTest(unittest.TestCase):
    """4K60 is an input, not a constant welded into the script."""

    def test_the_target_geometry_is_declared(self):
        card = CardReplay(DV_WRONG)
        self.addCleanup(card.close)
        r = card.run({'SC7F0_CAPTURE_WIDTH': '1920', 'SC7F0_CAPTURE_HEIGHT': '1080'})
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)
        self.assertIn('target=1920x1080', r.stdout)
        self.assertIn('SC7F0_RGB_CAPTURE_INIT PASS', r.stdout)
        self.assertIn('[fmt:RBG888_1X24/1920x1080 field:none]', csc_block(card.media_after))


class PackagingTest(unittest.TestCase):
    """The unit, the script path and the persona gate have to agree."""

    def test_shell_syntax(self):
        subprocess.run(['sh', '-n', str(HELPER)], check=True)

    def test_unit_runs_exactly_the_path_the_recipe_installs(self):
        # ${libdir} is /usr/lib in this build, and the unit has to carry the absolute path
        # systemd needs, so the two spellings are compared through that mapping instead of
        # being hoped equal.
        installed = re.search(r'SC7F0_RGB_CAPTURE_INIT_PATH = "\$\{libdir\}/(.*)"',
                              RECIPE.read_text())
        self.assertIsNotNone(installed, 'recipe must name its install path under ${libdir}')
        path = '/usr/lib/' + installed.group(1)
        self.assertIn('\nExecStart=%s\n' % path, UNIT.read_text())
        # The recipe must install the very file the unit runs, and claim it in FILES, or the
        # package builds and the path is simply absent on the card.
        rel = installed.group(1)
        recipe = RECIPE.read_text()
        self.assertIn('SC7F0_RGB_CAPTURE_INIT_PATH = "${libdir}/%s"' % rel, recipe)
        self.assertIn('install -m 0755 sc7f0-capture-init-rgb.sh ${D}${SC7F0_RGB_CAPTURE_INIT_PATH}',
                      recipe)
        self.assertIn('${SC7F0_RGB_CAPTURE_INIT_PATH}',
                      recipe[recipe.index('FILES:${PN}'):])

    def test_unit_is_an_enabled_oneshot_ordered_only_after_udevd(self):
        unit = UNIT.read_text()
        self.assertIn('Type=oneshot', unit)
        self.assertIn('RemainAfterExit=yes', unit)
        self.assertIn('WantedBy=multi-user.target', unit)
        self.assertIn('After=systemd-udevd.service', unit)
        self.assertIn('systemd_system_unitdir', RECIPE.read_text())
        self.assertIn('SYSTEMD_AUTO_ENABLE = "enable"', RECIPE.read_text())
        # The script's own wait must stay shorter than the unit's timeout, or a timeout is
        # reported by systemd killing the unit instead of by the script.
        wait = int(re.search(r'WAIT_SEC=\$\{[A-Z0-9_]+:-(\d+)\}', HELPER.read_text()).group(1))
        timeout = int(re.search(r'TimeoutStartSec=(\d+)', unit).group(1))
        self.assertLess(wait, timeout)

    def test_recipe_carries_the_tools_the_script_calls(self):
        recipe = RECIPE.read_text()
        for tool in ('v4l-utils', 'media-ctl'):
            self.assertIn(tool, recipe)

    def test_installed_only_for_the_persona_that_needs_it(self):
        bb = BBAPPEND.read_text()
        self.assertIn('sc7f0-capture-init-rgb', bb)
        # The VCU persona must not gain it: its CSC has to stay RGB->YUV for the encoder.
        # So the package may only enter IMAGE_INSTALL through the persona-gated variable.
        self.assertIn('SC7F0_RGB_COMPOSITOR_IMAGE_ADDONS ?= ""', bb)
        install = [l for l in bb.splitlines()
                   if l.startswith('IMAGE_INSTALL') and 'sc7f0-capture-init-rgb' in l]
        self.assertEqual([], install, 'the package must not be named on an IMAGE_INSTALL line')
        gated = [l for l in bb.splitlines()
                 if l.startswith('IMAGE_INSTALL') and 'SC7F0_RGB_COMPOSITOR_IMAGE_ADDONS' in l]
        self.assertEqual(1, len(gated), gated)
        gate = bb[bb.index('SC7F0_RGB_COMPOSITOR_IMAGE_ADDONS ?='):]
        self.assertIn("d.getVar('SC7F0_RGB_COMPOSITOR_ENABLE') == '1'", gate)
        self.assertIn("'sc7f0-capture-init-rgb'", gate)

    def test_the_graph_it_writes_is_the_one_this_card_accepts(self):
        script = HELPER.read_text()
        code = '\n'.join(l.split('#')[0] for l in script.splitlines())
        self.assertIn('RBG888_1X24', code)
        self.assertIn('RX24', code)
        self.assertIn('media-ctl -V', code)
        self.assertNotIn('set-subdev-fmt', code)
        self.assertNotRegex(code, r'pixelformat=(BGRX|XBGR)')
        self.assertNotRegex(code.lower(), r'i2c|i2ctransfer')


if __name__ == '__main__':
    unittest.main(verbosity=2)
