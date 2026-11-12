#!/usr/bin/env python3
"""Focused tests for the single-entry host upgrade path and the packaged boot init.

Four things are proved here, and they are the ones that used to depend on an operator
remembering them:

1. structure  - scripts/upgrade.sh parses, the boot initialiser parses, and the unit's
                ExecStartPre path is the path the recipe installs.  upgrade.sh carries no
                RX-lock / capture-init / encoder / frame-counter gate any more: a flash
                does not require an HDMI source to be attached.
2. ordering   - the card-side initialiser sets subdev pad0, then pad1, then the capture
                node format (the only order that lets sc7f0_vcud queue buffers), uses
                the load-bearing "--set-fmt-video=" spelling, refuses geometries it was
                not told to use, and contains no I2C of any kind.
3. behaviour  - driven against a fake ssh/scp, scripts/upgrade.sh is made to walk real
                failure scenarios: a tampered package never reaches the network, a failed
                VERIFY never reaches COMMIT, COMMIT is issued exactly once and never
                re-issued when its outcome is unclear, a failed warm reset stops the run
                before anything else, a PS that did not actually reboot still fails, and
                the MCU runtime restart is issued exactly once whatever the RX reports.
4. no-HDMI    - with no source attached (hdmi_status unlocked, sc7f0-vcud stuck
                activating, the advisory probe itself failing) the upgrade still exits 0
                and says the capture path was not verified.  Capture acceptance is a
                later, separate stage.

No hardware, no network.  The tar used by the behavioural tests is built by the real
packager and audited by the real strict-ustar checker.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
UPGRADE = REPO / 'scripts' / 'upgrade.sh'
HELPER = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud'
          / 'files/sc7f0-capture-init.sh')
UNIT = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud'
        / 'files/sc7f0-vcud.service')
RECIPE = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud'
          / 'sc7f0-vcud.bb')

HOST_BOOT_ID = '0da5af1d-5cd4-4d22-9a13-5908ad64c5dd'
PS_BOOT_BEFORE = '02750a3d-0981-41ce-bdcc-ac0f82d38684'
PS_BOOT_AFTER = '11111111-2222-3333-4444-555555555555'
EXPECT_HOST_IP = '192.168.190.247'


def sh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True)


class StructureTest(unittest.TestCase):
    def test_upgrade_script_parses(self):
        r = sh('bash', '-n', str(UPGRADE))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_helper_parses_with_sh_and_bash(self):
        for shell in ('sh', 'bash'):
            r = sh(shell, '-n', str(HELPER))
            self.assertEqual(r.returncode, 0, '%s: %s' % (shell, r.stderr))

    def test_unit_execstartpre_matches_recipe_install_path(self):
        unit = UNIT.read_text()
        m = re.search(r'^ExecStartPre=(\S+)$', unit, re.M)
        self.assertIsNotNone(m, 'the unit chains no ExecStartPre')
        path = m.group(1)
        recipe = RECIPE.read_text()
        self.assertIn('SC7F0_CAPTURE_INIT_PATH = "%s"' % path.replace('/usr/lib', '${libdir}'),
                      recipe, 'the recipe does not pin the unit ExecStartPre path')
        self.assertIn('install -m 0755 sc7f0-capture-init.sh ${D}${SC7F0_CAPTURE_INIT_PATH}',
                      recipe)
        self.assertIn('${SC7F0_CAPTURE_INIT_PATH}', recipe.split('FILES:${PN}')[1],
                      'the helper is not in FILES, so do_package would drop it')

    def test_recipe_declares_the_tools_the_helper_calls(self):
        recipe = RECIPE.read_text()
        rdepends = recipe.split('RDEPENDS:${PN} +=')[1].splitlines()[0]
        for tool in ('v4l-utils', 'media-ctl'):
            self.assertIn(tool, rdepends, '%s is not an runtime dependency' % tool)
        self.assertIn('${LDFLAGS}', recipe,
                      'the vcud link line lost ${LDFLAGS}; do_package_qa fails with GNU_HASH')

    def test_remote_helper_does_not_recurse_and_no_call_omits_the_host(self):
        # `ssh sudo -n ...` without a target makes ssh resolve "sudo" as a hostname, and
        # a wrapper written as `rssh() { rssh ...; }` recurses forever. Both look like a
        # network failure at runtime, so they are rejected here instead.
        text = UPGRADE.read_text(encoding='utf-8')
        self.assertIn('rssh() { "${SSH[@]}" "$HOST" "$@"; }', text)
        self.assertNotIn('rssh() { rssh', text)
        for line in text.splitlines():
            if '${SSH[@]}' in line and not line.strip().startswith('SSH') \
                    and 'rssh()' not in line and 'SCP' not in line:
                self.fail('a raw ssh array call must name the target: ' + line)

    @staticmethod
    def _heredoc_lines(text):
        """Line numbers (1-based) that are inside a quoted here-document body."""
        inside, end_tag, lines = False, None, text.splitlines()
        marked = set()
        for n, line in enumerate(lines, 1):
            if inside:
                marked.add(n)
                if line.strip() == end_tag:
                    inside = False
                continue
            m = re.search(r"<<-?'([A-Za-z_]+)'", line)
            if m:
                inside, end_tag = True, m.group(1)
                marked.add(n)
        return marked

    def test_a_quoted_remote_command_never_travels_as_a_ssh_word(self):
        # ssh joins its arguments with spaces and the remote shell re-parses them, so a
        # quoted sc7f0ctl exec argument passed as a command-line word arrives split and
        # its remainder executes on the x86 host.  Measured on the real card: the "card
        # identity" check returned the host kernel and "inactive qpcie-debugd".  Only
        # here-document bodies keep quoting intact.
        lines = UPGRADE.read_text(encoding='utf-8').splitlines()
        heredoc = self._heredoc_lines(UPGRADE.read_text(encoding='utf-8'))
        for n, line in enumerate(lines, 1):
            if n in heredoc or line.lstrip().startswith('#'):
                continue
            self.assertNotIn("exec '", line,
                             'line %d passes a quoted remote command as an ssh word; '
                             'use a here-doc: %s' % (n, line))

    def test_usage_entry_point_documented(self):
        r = sh(str(UPGRADE), '--help')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('./scripts/upgrade.sh <path to upgrade-<VERSION>.tar>', r.stdout)
        self.assertIn('rd@sc7f0-test.local', r.stdout)

    def test_upgrade_does_not_gate_on_hdmi_capture_or_the_encoder(self):
        # Flashing does not require an HDMI source.  Neither RX lock, nor 4K60 timing,
        # nor the packaged initialiser marker, nor sc7f0-vcud state, nor a VIPP probe,
        # nor the raw DMA frame counter may appear in the decision path again - keeping
        # only the RX grep while still waiting for sc7f0-vcud would change nothing.
        text = UPGRADE.read_text(encoding='utf-8')
        code = '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
        for token in ('Signal Locked', 'SC7F0_CAPTURE_INIT', 'OpenMAX', 'ch0_frames',
                      'ch0_drops', '--stream-mmap', '--set-fmt-video',
                      'ActiveState=active', 'sc7f0-vcud=active', 'ExecMainStatus',
                      'RX_LOCK_TIMEOUT', 'CAPTURE_INIT_TIMEOUT', 'hdmi-status-poll',
                      'capture-init-journal', 'card-frame-progress'):
            self.assertNotIn(token, code,
                             '%s is still part of the upgrade decision path' % token)
        # Exactly one bounded wait survives: the mailbox daemon after the warm reset.
        self.assertEqual(1, len(re.findall(r'(?m)^for attempt in ', text)),
                         'only the PS mailbox ready poll may loop')
        self.assertEqual(1, len(re.findall(r'(?m)^\s*sleep ', text)),
                         'the capture path must not be polled, so no extra sleeps')


class HelperOrderingTest(unittest.TestCase):
    def setUp(self):
        self.text = HELPER.read_text()

    def test_no_i2c_anywhere_in_the_packaged_initialiser(self):
        for token in ('i2ctransfer', 'i2c-', 'i2cset', 'i2cget', '/dev/i2c'):
            self.assertNotIn(token, self.text,
                             'the boot initialiser must never reset the MCU (%s)' % token)

    def test_pad_then_node_then_daemon_order(self):
        body = re.sub(r'(?m)^#.*$', '', self.text)
        i_pad0 = body.index('set_pad 0 "$SINK_CODE"')
        i_pad1 = body.index('set_pad 1 "$SOURCE_CODE"')
        i_node = body.index('--set-fmt-video=')
        self.assertLess(i_pad0, i_pad1, 'sink pad must be set before the source pad')
        self.assertLess(i_pad1, i_node, 'the capture node format must follow the graph')

    def test_the_equal_sign_in_set_fmt_video(self):
        # "--set-fmt-video width=..." is accepted by v4l2-ctl and silently ignored.
        code = '\n'.join(l for l in self.text.splitlines() if not l.lstrip().startswith('#'))
        self.assertIsNone(re.search(r'--set-fmt-video\s+width', code),
                          'the space-separated form is silently ignored by v4l2-ctl')
        self.assertIn('--set-fmt-video="width=$WIDTH,height=$HEIGHT', code)

    def test_pads_are_set_in_two_separate_calls(self):
        self.assertEqual(2, self.text.count('set_pad '),
                         'one combined media-ctl call makes both pads RBG888/field Any')

    def test_geometry_is_declared_not_guessed(self):
        self.assertIn('WIDTH=${SC7F0_CAPTURE_WIDTH:-3840}', self.text)
        self.assertIn('HEIGHT=${SC7F0_CAPTURE_HEIGHT:-2160}', self.text)
        self.assertIn('field=none', self.text)
        self.assertIn('0x100e', self.text)   # RBG888_1X24 sink
        self.assertIn('0x2100', self.text)   # VYYUYY8_1X24 source

    def test_nodes_are_resolved_by_entity_not_by_number(self):
        self.assertIn('b0060000.vpss-csc', self.text)
        self.assertIn('resolve_node', self.text)
        # /dev/v4l-subdevN must never be hardcoded in a command.
        for line in self.text.splitlines():
            if line.strip().startswith('#'):
                continue
            self.assertNotIn('/dev/v4l-subdev', line,
                             'subdev numbers are enumeration order, not identity: ' + line)

    def test_planes_zero_is_recorded_not_treated_as_failure(self):
        # "Number of planes : 0" is a vipp reporting quirk; the same state captures a
        # full 12,441,600-byte NV12 frame, so it must never abort the initialiser.
        self.assertIn('Number of planes', self.text)
        tail = self.text.split('Number of planes', 1)[1]
        self.assertNotIn('die ', tail[:400])
        self.assertNotIn('exit 1', tail[:400])

    def test_pass_marker_is_one_contiguous_literal(self):
        # The marker proves the file inside image.ub (--expect-string) and is what the
        # card's own journal shows.  scripts/upgrade.sh no longer waits for it: capture
        # initialisation is not a flash gate.  Its consumption is covered by
        # scripts/tests/test_sc7f0_capture_init_helper.py, so it cannot be split across a
        # printf format and an argument.
        self.assertIn("printf 'SC7F0_CAPTURE_INIT PASS ", self.text)
        self.assertNotIn("grep -q 'SC7F0_CAPTURE_INIT PASS'", UPGRADE.read_text(encoding='utf-8'))

    def test_helper_waits_bounded_before_configuring(self):
        body = re.sub(r'(?m)^#.*$', '', self.text)
        self.assertLess(body.index('rx_locked'), body.index('set_pad 0'),
                        'the graph must not be rewritten before the RX timing is locked')
        self.assertIn('WAIT_TIMEOUT', self.text)


# --------------------------------------------------------------------------- mocks
FAKE_SSH = r"""#!/usr/bin/env python3
import os, re, sys
from pathlib import Path

log = Path(os.environ['FAKE_SSH_LOG'])
text = ' '.join(sys.argv[1:])
try:
    if not sys.stdin.isatty():
        text += '\n' + sys.stdin.read()
except Exception:
    pass
log.write_text(log.read_text() + '\n@@@' + text + '\n')

rel = Path(os.environ['FAKE_RELEASE_DIR'])
scenario = os.environ['FAKE_SCENARIO']
emmc = []
for line in (rel / 'RELEASE.sha256').read_text().splitlines():
    parts = line.split()
    if len(parts) == 2 and Path(parts[1]).name in ('BOOT.BIN', 'image.ub', 'boot.scr'):
        emmc.append('%s  /run/media/BOOT-mmcblk0p1/%s' % (parts[0], Path(parts[1]).name))
emmc_out = '\n'.join(emmc)

def out(s, rc=0):
    sys.stdout.write(s.rstrip('\n') + '\n')
    sys.exit(rc)

if text.strip().endswith('true'):
    out('')
if 'uname -m; hostname; ip -o' in text:
    if scenario == 'host_probe_glued':
        # The IP list is produced with `tr "\n" " "`, so without a terminating echo the
        # boot id and the df value would slide up one line and every later check would
        # read the wrong field.  This is the shape that bug produced.
        out('x86_64\nsc7f0-test\n127.0.0.1 __HOST_IP__ __HOST_BOOT_ID__\n524288')
    out('x86_64\nsc7f0-test\n127.0.0.1 __HOST_IP__ \n__HOST_BOOT_ID__\n524288')
if '--timeout 10 status' in text:
    out('ABI=1 ready=1 card_epoch=0bf769dc card_beat=5263571')
if 'test "$(uname -m)" = aarch64' in text:
    out('6.1.30-xilinx\n__PS_BOOT_BEFORE__\n512')
if 'command -v fuser' in text:
    if scenario == 'idle_busy':
        out('capture node busy:\n  root  1234 /dev/video0', 1)
    out('IDLE_OK')
if 'sc7f0/tmp/upgrade.XXXXXXXX' in text:
    out('/home/rd/sc7f0/tmp/upgrade.AAAAAAAA')
if 'sha256sum -c -' in text:
    out('upgrade-26111204.tar: OK\nhost-tools-src.tar.gz: OK\nhost-driver-src.tar.gz: OK')
if 'cc -O2 -Wall test_app/qpcie_upgrade.c' in text:
    out('0' * 64 + '  qpcie_upgrade')
if '.backup_cli_' in text:
    out('1111  /run/media/BOOT-mmcblk0p1/.backup_cli_x/BOOT.BIN')
if '--package' in text:
    if scenario == 'verify_fail':
        out('ERROR: board refused the bundle', 1)
    out(' -> Upgrade Status    : 0x05 (VERIFIED (awaiting --commit))\nVERIFY_RC=0')
if text.strip().endswith('./qpcie_upgrade --status') or ('--status' in text and 'uname -a' not in text):
    if scenario == 'verify_fail':
        out(' -> Upgrade Status    : 0x00 (IDLE / Ready)', 1)
    out(' -> Hardware Version  : 0x26111204 (Date: 2026/11/12 Rev 04)\n'
        ' -> Upgrade Status    : 0x05 (VERIFIED (awaiting --commit))')
if '--commit' in text:
    if scenario == 'commit_unclear':
        # The transport dies mid-COMMIT: rc 0 but the completion marker never lands.
        out(' -> Sending COMMIT doorbell (eMMC flash with backup+readback)...')
    if scenario == 'commit_fail':
        out(' -> Sending COMMIT doorbell ...\nERROR: COMMIT timed out', 1)
    out(' -> Upgrade Status    : 0x05 (VERIFIED (awaiting --commit))\n'
        ' -> COMMIT reached 0x04\n'
        ' SUCCESS: eMMC upgrade committed and board-verified! Use --reboot to activate.\n'
        'COMMIT_RETURNED')
if '--reboot' in text:
    if scenario == 'reboot_fail':
        out('ERROR: PCIe rescan failed', 1)
    out(' Requesting PS warm reset + PCIe rescan (not board POR)...\nREBOOT_RC=0')
if '--timeout 5 status' in text:
    out('ABI=1 ready=1 card_epoch=11111111 card_beat=12')
if 'i2ctransfer -y 0 w2@0x32 0x06 0x01' in text:
    out('MCU_RESTART_RC=0 elapsed_ms=16 UTC=2026-11-13T00:00:00Z\nMCU_RESTART_RECORDED')
if 'CAPTURE_ADVISORY_START' in text:
    # The single best-effort capture sample.  Whatever it says - an unlocked RX, a vcud
    # stuck in activating, even a probe that fails outright - scripts/upgrade.sh must
    # neither wait for it nor judge the flash by it.
    if scenario in ('no_hdmi', 'advisory_probe_fails'):
        out('CAPTURE_ADVISORY_START\n'
            '--- host sysfs hdmi_status (best effort, not judged) ---\n'
            'Status: No Locked Timing\nReceiver: Xilinx v_hdmi_rx_ss\n'
            '--- card sc7f0-vcud unit state (best effort, not judged) ---\n'
            'ActiveState=activating\nSubState=start\nNRestarts=7\n'
            'sc7f0-capture-init[412]: waiting for RX lock; refusing to configure\n'
            'CAPTURE_ADVISORY_DONE',
            1 if scenario == 'advisory_probe_fails' else 0)
    # Deliberately already locked here too: the MCU restart above must still have been
    # issued, and this one read must not turn into a poll.
    out('CAPTURE_ADVISORY_START\nStatus: Signal Locked\nReceiver: Xilinx v_hdmi_rx_ss\n'
        'Resolution: 3840x2160p\nPixel clock: 594000000 Hz\n'
        'ActiveState=active\nSubState=running\nNRestarts=0\nCAPTURE_ADVISORY_DONE')
if 'uname -a' in text:
    # Post-reboot card state.  Without a source the capture daemon legitimately never
    # reaches active, while the debug/upgrade transport must.
    vcud = 'activating' if scenario in ('no_hdmi', 'advisory_probe_fails') else 'active'
    debugd = 'inactive' if scenario == 'core_service_down' else 'active'
    boot_after = ('__PS_BOOT_BEFORE__' if scenario == 'ps_boot_id_stale'
                  else '__PS_BOOT_AFTER__')
    out(' -> Hardware Version  : 0x26111204 (Date: 2026/11/12 Rev 04)\n'
        ' -> Upgrade Status    : 0x04 (Previous Flash Succeeded)\n'
        'Linux zynqmp 6.1.30-xilinx #1 SMP aarch64 GNU/Linux\n' + boot_after + '\n'
        'qpcie-debugd=' + debugd + '\nqpcie-hdmi-daemon=active\n'
        'qpcie-upgrade-daemon=active\nsc7f0-vcud=' + vcud + '\n' + emmc_out)
if 'sha256sum /run/media/BOOT-mmcblk0p1' in text:
    out(emmc_out)
if 'cat /proc/sys/kernel/random/boot_id' in text and 'uname' not in text:
    out('__HOST_BOOT_ID__')
out('')
"""


def fake_ssh_text():
    return (FAKE_SSH.replace('__HOST_BOOT_ID__', HOST_BOOT_ID)
            .replace('__PS_BOOT_BEFORE__', PS_BOOT_BEFORE)
            .replace('__PS_BOOT_AFTER__', PS_BOOT_AFTER)
            .replace('__HOST_IP__', EXPECT_HOST_IP))


FAKE_SCP = '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
Path(os.environ['FAKE_SSH_LOG']).write_text(
    Path(os.environ['FAKE_SSH_LOG']).read_text() + '\\n@@@scp ' + ' '.join(sys.argv[1:]) + '\\n')
sys.exit(0)
'''


def build_release(root: Path):
    """A real strict-ustar bundle from the real packager, with real manifests."""
    version = '26111204'
    images = root / 'images'
    images.mkdir(parents=True)
    (images / 'BOOT.BIN').write_bytes(b'BOOT' * 4096)
    (images / 'image.ub').write_bytes(b'UBI' * 20000)
    (images / 'boot.scr').write_bytes(b'BOOTSCR' * 512)
    rel = root / 'release-26111204-rtest'
    (rel / 'release').mkdir(parents=True)
    (rel / 'images').mkdir()
    for n in ('BOOT.BIN', 'image.ub', 'boot.scr'):
        shutil.copy2(images / n, rel / 'images' / n)
    bundle = rel / 'release' / ('upgrade-%s.tar' % version)
    r = subprocess.run([sys.executable, str(REPO / 'scripts/package_sc7f0_upgrade.py'),
                        '--images', str(rel / 'images'), '--output', str(bundle)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    (rel / 'host-tools-src.tar.gz').write_bytes(b'\x1f\x8b tools')
    (rel / 'host-driver-src.tar.gz').write_bytes(b'\x1f\x8b driver')
    names = ['release/upgrade-%s.tar' % version, 'host-tools-src.tar.gz',
             'host-driver-src.tar.gz', 'images/BOOT.BIN', 'images/image.ub',
             'images/boot.scr']
    digests = {n: hashlib.sha256((rel / n).read_bytes()).hexdigest() for n in names}
    (rel / 'RELEASE.sha256').write_text(''.join('%s  %s\n' % (h, n) for n, h in digests.items()))
    (rel / 'release.json').write_text(json.dumps(
        {'version': version, 'sha256': digests}, indent=2) + '\n')
    return bundle, rel


class BehaviourTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        cls.bundle, cls.rel = build_release(root)
        cls.bindir = root / 'bin'
        cls.bindir.mkdir()
        (cls.bindir / 'ssh').write_text(fake_ssh_text())
        (cls.bindir / 'scp').write_text(FAKE_SCP)
        os.chmod(cls.bindir / 'ssh', 0o755)
        os.chmod(cls.bindir / 'scp', 0o755)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_entry(self, scenario: str):
        log = Path(self.tmp.name) / ('sshlog-%s' % scenario)
        log.write_text('')
        logs = Path(self.tmp.name) / ('logs-%s' % scenario)
        env = dict(os.environ)
        env.update({'PATH': str(self.bindir) + os.pathsep + os.environ['PATH'],
                    'FAKE_SSH_LOG': str(log),
                    'FAKE_SCENARIO': scenario,
                    'SC7F0_UPGRADE_PS_READY_TIMEOUT': '10',
                    'FAKE_RELEASE_DIR': str(self.rel)})
        r = subprocess.run([str(UPGRADE), str(self.bundle), '--logs', str(logs)],
                           capture_output=True, text=True, env=env, timeout=600)
        transcript = r.stdout + r.stderr
        calls = log.read_text().split('@@@')[1:]
        return r.returncode, transcript, calls, logs

    def commits(self, calls):
        return [c for c in calls if re.search(r'\./qpcie_upgrade --commit', c)]

    def restarts(self, calls):
        return [c for c in calls if 'i2ctransfer -y 0 w2@0x32 0x06 0x01' in c]

    def test_happy_path_restarts_the_mcu_once_even_though_rx_is_locked(self):
        rc, t, calls, _ = self.run_entry('ok')
        self.assertEqual(rc, 0, t[-4000:])
        self.assertIn('UPGRADE_PASS', t)
        self.assertEqual(1, len(self.commits(calls)), 'COMMIT must be issued exactly once')
        self.assertEqual(1, len(self.restarts(calls)),
                         'the MCU runtime restart is unconditional and exactly once')
        self.assertIn('EMMC_READBACK_SHA_PASS', t)
        self.assertIn('EMMC_PERSISTED_ACROSS_REBOOT', t)
        self.assertIn('02750a3d-0981-41ce-bdcc-ac0f82d38684 -> ' + PS_BOOT_AFTER, t)
        # Strict transport options were really used.
        self.assertIn('-o BatchMode=yes -o StrictHostKeyChecking=yes', calls[0])
        # The boot initialiser, not the host, owns the graph: upgrade.sh must not set it.
        self.assertNotIn('--set-fmt-video', ' '.join(c for c in calls
                                                     if 'i2ctransfer' not in c))

    def test_verify_failure_never_reaches_commit(self):
        rc, t, calls, _ = self.run_entry('verify_fail')
        self.assertNotEqual(rc, 0)
        self.assertIn('UPGRADE_FAIL stage=verify', t)
        self.assertEqual(0, len(self.commits(calls)))
        self.assertEqual(0, len(self.restarts(calls)))

    def test_unclear_commit_is_never_retried(self):
        rc, t, calls, _ = self.run_entry('commit_unclear')
        self.assertNotEqual(rc, 0)
        self.assertIn('COMMIT_OUTCOME_UNCLEAR', t)
        self.assertEqual(1, len(self.commits(calls)),
                         'an unclear COMMIT outcome must never cause a second COMMIT')
        self.assertNotIn('UPGRADE_PASS', t)
        self.assertEqual(0, len(self.restarts(calls)))
        self.assertNotIn('--reboot', ' '.join(calls),
                         'no reset may follow an unclear COMMIT')

    def test_failed_commit_stops_before_reboot(self):
        rc, t, calls, _ = self.run_entry('commit_fail')
        self.assertNotEqual(rc, 0)
        self.assertEqual(1, len(self.commits(calls)))
        self.assertNotIn('--reboot', ' '.join(calls))

    def test_failed_warm_reset_stops_before_the_mcu_restart(self):
        rc, t, calls, _ = self.run_entry('reboot_fail')
        self.assertNotEqual(rc, 0)
        self.assertIn('UPGRADE_FAIL stage=warm-reboot', t)
        self.assertEqual(1, len(self.commits(calls)))
        self.assertEqual(0, len(self.restarts(calls)),
                         'no runtime restart may follow a warm reset that failed')

    def test_no_hdmi_source_and_vcud_stuck_activating_still_upgrades(self):
        # Flashing does not require a source.  Unlocked RX + sc7f0-vcud never reaching
        # active must not fail, not time out and not be polled.
        rc, t, calls, _ = self.run_entry('no_hdmi')
        self.assertEqual(rc, 0, t[-4000:])
        self.assertIn('UPGRADE_PASS', t)
        self.assertIn('No Locked Timing', t)
        self.assertIn('ActiveState=activating', t)
        self.assertIn('verdict=NOT_EVALUATED', t)
        self.assertIn('capture NOT verified', t)
        self.assertEqual(1, len(self.commits(calls)))
        # the mandatory MCU runtime restart is never skipped on the strength of "no
        # signal": it still runs, exactly once, before any capture state is read
        self.assertEqual(1, len(self.restarts(calls)))
        restart_at = [i for i, c in enumerate(calls) if 'i2ctransfer -y 0 w2@0x32' in c]
        advisory_at = [i for i, c in enumerate(calls) if 'CAPTURE_ADVISORY_START' in c]
        self.assertEqual(1, len(advisory_at))
        self.assertLess(restart_at[0], advisory_at[0],
                        'the runtime restart must precede the advisory capture read')
        joined = ' '.join(calls)
        self.assertEqual(1, len([c for c in calls if 'CAPTURE_ADVISORY_START' in c]),
                         'the capture state is sampled once, never polled')
        for probe in ('--stream-mmap', 'ch0_frames', 'ch0_drops', '--set-fmt-video'):
            self.assertNotIn(probe, joined, '%s must not be probed during a flash' % probe)

    def test_a_failing_capture_probe_does_not_fail_the_upgrade(self):
        # A transport failure on the advisory read is not evidence about the flash and
        # must never be turned into a capture verdict either.
        rc, t, calls, _ = self.run_entry('advisory_probe_fails')
        self.assertEqual(rc, 0, t[-4000:])
        self.assertIn('UPGRADE_PASS', t)
        self.assertIn('verdict=NOT_EVALUATED', t)
        self.assertEqual(1, len(self.restarts(calls)))
        self.assertEqual(1, len(self.commits(calls)))

    def test_a_stale_ps_boot_id_still_fails_the_run(self):
        # Removing the capture gates must not soften "the PS really restarted".
        rc, t, calls, _ = self.run_entry('ps_boot_id_stale')
        self.assertNotEqual(rc, 0)
        self.assertIn('UPGRADE_FAIL stage=final', t)
        self.assertIn('PS boot id is unchanged', t)
        self.assertNotIn('UPGRADE_PASS', t)
        self.assertEqual(1, len(self.restarts(calls)))

    def test_a_dead_core_service_still_fails_the_run(self):
        # What stays mandatory is the debug/upgrade transport, not the capture daemon.
        rc, t, calls, _ = self.run_entry('core_service_down')
        self.assertNotEqual(rc, 0)
        self.assertIn('UPGRADE_FAIL stage=final', t)
        self.assertIn('qpcie-debugd is not active', t)
        self.assertNotIn('UPGRADE_PASS', t)

    def test_busy_capture_nodes_abort_before_any_transfer(self):
        rc, t, calls, _ = self.run_entry('idle_busy')
        self.assertNotEqual(rc, 0)
        self.assertIn('UPGRADE_FAIL stage=environment', t)
        self.assertEqual([], [c for c in calls if c.startswith('scp')])

    def test_misparsed_host_probe_aborts_instead_of_reading_the_wrong_field(self):
        rc, t, calls, _ = self.run_entry('host_probe_glued')
        self.assertNotEqual(rc, 0)
        self.assertIn('UPGRADE_FAIL stage=environment', t)
        self.assertEqual([], [c for c in calls if c.startswith('scp')])

    def test_a_tampered_package_aborts_before_any_ssh(self):
        # Dropping the capture gates must not soften the digests: a bundle that does not
        # match RELEASE.sha256 stops inside the package audit, before any transfer and
        # before anything touches the card.
        rel = Path(self.tmp.name) / 'tampered' / self.rel.name
        shutil.copytree(self.rel, rel)
        bundle = rel / 'release' / self.bundle.name
        bundle.write_bytes(bundle.read_bytes() + b'tampered')
        log = Path(self.tmp.name) / 'sshlog-tampered'
        log.write_text('')
        env = dict(os.environ)
        env.update({'PATH': str(self.bindir) + os.pathsep + os.environ['PATH'],
                    'FAKE_SSH_LOG': str(log), 'FAKE_SCENARIO': 'ok',
                    'FAKE_RELEASE_DIR': str(rel)})
        r = subprocess.run([str(UPGRADE), str(bundle), '--logs',
                            str(Path(self.tmp.name) / 'logs-tampered')],
                           capture_output=True, text=True, env=env, timeout=300)
        transcript = r.stdout + r.stderr
        self.assertNotEqual(r.returncode, 0, transcript[-3000:])
        self.assertIn('UPGRADE_FAIL stage=package-audit', transcript)
        self.assertNotIn('UPGRADE_PASS', transcript)
        self.assertEqual(0, log.read_text().count('@@@'),
                         'a tampered package must not open a single ssh session')

    def test_dry_run_touches_no_hardware(self):
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + os.environ['PATH']
        env['FAKE_SSH_LOG'] = str(Path(self.tmp.name) / 'sshlog-dry')
        Path(env['FAKE_SSH_LOG']).write_text('')
        env['FAKE_SCENARIO'] = 'ok'
        env['FAKE_RELEASE_DIR'] = str(self.rel)
        logs = Path(self.tmp.name) / 'logs-dry'
        r = subprocess.run([str(UPGRADE), str(self.bundle), '--dry-run',
                            '--logs', str(logs)], capture_output=True, text=True,
                           env=env, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('TAR_STRICT_USTAR_OK', r.stdout)
        self.assertIn('DRY_RUN', r.stdout)
        self.assertEqual(0, Path(env['FAKE_SSH_LOG']).read_text().count('@@@'),
                         'a dry run must not open a single ssh session')


if __name__ == '__main__':
    unittest.main(verbosity=2)
