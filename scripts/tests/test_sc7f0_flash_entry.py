#!/usr/bin/env python3
"""Tests for the single SC7F0 flash entry point: scripts/sc7f0_flash.sh.

scripts/upgrade.sh used to be a second host-side flash path holding its own copy of the
post-flash stages (warm reboot, MCU runtime restart, capture advisory, final proof).
Two entry points drift, and the drift that mattered was the MCU runtime restart: the
path that did not issue it left the RX frozen after a PS restart.  upgrade.sh is now
removed and scripts/sc7f0_flash.sh carries the whole sequence, so one command is a
complete flash.  What is guarded here:

1. single entry   - scripts/upgrade.sh stays deleted, the documentation names only
                    scripts/sc7f0_flash.sh, and the packaged boot initialiser still
                    contains no I2C, so no second automatic MCU reset exists anywhere.
2. structure      - bash -n, the documented usage line, and no RX-lock / capture-init /
                    encoder / frame-counter token in the decision path: a flash does not
                    require an HDMI source to be attached.
3. post-flash order - COMMIT -> eMMC readback -> warm reboot -> ready -> version ->
                    PS services -> ONE unconditional MCU runtime restart -> one advisory
                    capture read -> eMMC-persisted + PS boot id changed + host boot id
                    unchanged, read from the script's own control order.
4. offline refusal - --dry-run and a build dir whose release digests do not verify must
                    finish without opening a single ssh session.

Honest scope: the remote half of this flash runs inside ONE `ssh bash -s` here-document,
so per-command behaviour on the card (COMMIT issued exactly once, no COMMIT after a
failed VERIFY) is asserted from the script's control order, not from a fake-ssh driver.
The fake-ssh harness that used to sit here drove upgrade.sh's many separate ssh calls and
cannot observe commands executed inside this single remote script; keeping it would mean
testing a file that no longer exists.  The packaged boot initialiser's own behaviour
(graph pad order, node S_FMT, no I2C) is exercised behaviourally, command by command, by
scripts/tests/test_sc7f0_capture_init_helper.py.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
FLASH = REPO / 'scripts' / 'sc7f0_flash.sh'
OLD_ENTRY = REPO / 'scripts' / 'upgrade.sh'
HELPER = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud'
          / 'files/sc7f0-capture-init.sh')
UNIT = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud'
        / 'files/sc7f0-vcud.service')
RECIPE = (REPO / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/sc7f0-vcud'
          / 'sc7f0-vcud.bb')
DOCS = (REPO / 'docs' / 'sc7f0_build_package_flash.md', REPO / 'AGENTS.md')

MCU_RESTART = 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
# The transaction itself, as opposed to the --dry-run text that advertises it.  Every
# ordering / exactly-once assertion below uses this form so the announcement in the
# dry-run output can never be mistaken for a second transaction.
RESTART_TX = "exec '" + MCU_RESTART + "'"

FAKE_SSH = """#!/usr/bin/env python3
import os, sys
from pathlib import Path
log = Path(os.environ['FAKE_SSH_LOG'])
with log.open('a') as fh:
    fh.write('@@@' + ' '.join(sys.argv[1:]) + '\\n')
sys.exit(0)
"""


def sh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True)


def code_of(text: str) -> str:
    """The script without its comment lines - what actually executes."""
    return '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))


class SingleEntryPointTests(unittest.TestCase):
    def test_the_removed_second_entry_point_stays_removed(self):
        self.assertFalse(OLD_ENTRY.exists(),
                         'scripts/upgrade.sh is back: there must be exactly one flash entry')

    def test_documentation_names_the_flash_script_and_not_the_old_entry(self):
        for doc in DOCS:
            text = doc.read_text(encoding='utf-8')
            self.assertIn('scripts/sc7f0_flash.sh', text,
                          '%s does not document the standard flash entry' % doc.name)
            for line in text.splitlines():
                if re.search(r'(?:^|[\s`(=])\.?/?scripts/upgrade\.sh', line):
                    self.fail('%s still instructs the removed entry point: %s' % (doc.name, line))

    def test_no_packaged_boot_initializer_resets_the_mcu(self):
        # The flash owns the single runtime restart.  If the packaged initialiser grew
        # I2C again, a boot would issue a second reset the flash log never reports.
        text = HELPER.read_text(encoding='utf-8')
        for token in ('i2ctransfer', 'i2cset', 'i2cget', '/dev/i2c'):
            self.assertNotIn(token, code_of(text),
                             'the boot initialiser must never reset the MCU (%s)' % token)

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
            self.assertIn(tool, rdepends, '%s is not a runtime dependency' % tool)
        self.assertIn('${LDFLAGS}', recipe,
                      'the vcud link line lost ${LDFLAGS}; do_package_qa fails with GNU_HASH')


class StructureTests(unittest.TestCase):
    def setUp(self):
        self.text = FLASH.read_text(encoding='utf-8')
        self.code = code_of(self.text)

    def test_flash_script_parses(self):
        r = sh('bash', '-n', str(FLASH))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_usage_entry_point_documented(self):
        r = sh(str(FLASH), '--help')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('sc7f0_flash.sh --build BUILD_DIR', r.stdout)
        self.assertIn('rd@sc7f0-test.local', r.stdout)
        bad = sh(str(FLASH), '--no-such-flag')
        self.assertEqual(bad.returncode, 2, bad.stdout + bad.stderr)
        missing = sh(str(FLASH))
        self.assertEqual(missing.returncode, 2, missing.stdout + missing.stderr)

    def test_dry_run_documents_the_full_post_flash_sequence(self):
        # The dry run is what an operator reads before authorising a write; it must say
        # the MCU runtime restart happens, because that is the step that used to be
        # missing from this entry point.
        with tempfile.TemporaryDirectory() as tmp:
            r = sh(str(FLASH), '--build', tmp, '--dry-run')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(MCU_RESTART, r.stdout)
        self.assertIn('boot id', r.stdout)

    def test_flash_does_not_gate_on_hdmi_capture_or_the_encoder(self):
        for token in ('Signal Locked', 'SC7F0_CAPTURE_INIT', 'OpenMAX', 'ch0_frames',
                      'ch0_drops', '--stream-mmap', '--set-fmt-video', 'ch0_status',
                      'RX_LOCK_TIMEOUT', 'CAPTURE_INIT_TIMEOUT', 'hdmi-status-poll',
                      'card-frame-progress', 'ExecMainStatus'):
            self.assertNotIn(token, self.code,
                             '%s is still part of the flash decision path' % token)

    def test_exactly_one_bounded_wait_survives(self):
        # Only the PS mailbox ready poll may loop; the capture path is never polled.
        self.assertEqual(1, len(re.findall(r'(?m)^for attempt in ', self.text)),
                         'only the PS mailbox ready poll may loop')
        self.assertEqual(1, len(re.findall(r'(?m)^\s+sleep ', self.text)),
                         'the capture path must not be polled, so no extra sleeps')

    def test_single_shot_transactions_appear_once(self):
        for cmd, why in (('./qpcie_upgrade --package', 'VERIFY'),
                         ('./qpcie_upgrade --commit', 'COMMIT'),
                         ('./qpcie_upgrade --reboot', 'warm reset'),
                         (RESTART_TX, 'MCU runtime restart')):
            self.assertEqual(1, self.code.count(cmd), '%s (%s) must be issued once' % (cmd, why))

    def test_the_mcu_restart_is_bounded_and_recorded(self):
        self.assertIn('--timeout 5 ' + RESTART_TX, self.code,
                      'the runtime restart must be one bounded transaction')
        self.assertIn('mcu-restart.done', self.code,
                      'a per-staging marker must refuse a second restart')
        self.assertIn('REFUSE_MCU_RESTART_SECOND', self.code)
        self.assertIn('sc7f0/logs/mcu-restart-history', self.code,
                      'the restart must land in the host-side history file')
        self.assertIn('MCU_RESTART_RC=$MCU_RC', self.code)
        self.assertIn('do NOT retry it here', self.code,
                      'a failed restart is reported, never retried')

    def test_the_x86_host_is_never_rebooted(self):
        for token in ('shutdown', 'systemctl reboot', 'sudo reboot', 'reboot -f'):
            self.assertNotIn(token, self.code)
        self.assertIn('[[ $(</proc/sys/kernel/random/boot_id) == "$BOOT_BEFORE" ]]', self.code,
                      'the host boot id must be re-checked at the end')
        self.assertIn('BOOT_BEFORE=$(</proc/sys/kernel/random/boot_id)', self.code)

    def test_a_quoted_remote_command_never_travels_as_an_ssh_word(self):
        # ssh joins its arguments with spaces and the remote shell re-parses them, so a
        # quoted sc7f0ctl exec argument passed as a command-line word arrives split and
        # its remainder executes on the x86 host.  Only here-document bodies keep
        # quoting intact.
        lines = self.text.splitlines()
        inside, end_tag, heredoc = False, None, set()
        for n, line in enumerate(lines, 1):
            if inside:
                heredoc.add(n)
                if line.strip() == end_tag:
                    inside = False
                continue
            m = re.search(r"<<-?'([A-Za-z_]+)'", line)
            if m:
                inside, end_tag = True, m.group(1)
                heredoc.add(n)
        for n, line in enumerate(lines, 1):
            if n in heredoc or line.lstrip().startswith('#'):
                continue
            self.assertNotIn("exec '", line,
                             'line %d passes a quoted remote command as an ssh word; '
                             'use a here-doc: %s' % (n, line))


class PostFlashOrderTests(unittest.TestCase):
    """The whole point of the merge: one command reaches a usable card."""

    def setUp(self):
        self.code = code_of(FLASH.read_text(encoding='utf-8'))

    def at(self, needle: str) -> int:
        self.assertIn(needle, self.code, 'the flash script no longer contains: ' + needle)
        return self.code.index(needle)

    def test_card_identity_is_probed_before_anything_is_written(self):
        # The stage that proves we are talking to the card (aarch64 + the three daemon
        # units) must run before the first eMMC-touching command.
        identity = self.at('test "$(uname -m)" = aarch64')
        self.assertLess(identity, self.at('./qpcie_upgrade --package'))

    def test_fixed_order_of_the_whole_sequence(self):
        steps = [
            './qpcie_upgrade --package',            # 6  VERIFY
            './qpcie_upgrade --commit',             # 8  COMMIT, exactly once
            'readback.sha256',                      # 9  independent eMMC readback
            'PS_BOOT_BEFORE=',                      #    PS boot id baseline
            './qpcie_upgrade --reboot',             # 10 warm reset, never the host
            "grep -q 'ready=1'",                    #    mailbox daemon back
            'grep -qi "Hardware Version.*0x$PL_VERSION" active-version.log',  # 11 this build is active
            'uname -a; for s in qpcie-debugd',       # 11 PS transport services after boot
            RESTART_TX,                             # 12 exactly one runtime restart
            'CAPTURE_ADVISORY_START',               # 13 one advisory read
            'readback-after-reboot.sha256',         # 14 eMMC still equals the release
            'PS_BOOT_AFTER=',                       #    the PS really restarted
            'FLASH_PASS',
        ]
        positions = [self.at(s) for s in steps]
        self.assertEqual(positions, sorted(positions),
                         'the flash/post-flash order drifted:\n' +
                         '\n'.join('%-46d %s' % (p, s) for p, s in zip(positions, steps)))

    def test_the_restart_is_never_conditioned_on_signal_state(self):
        # A stale "Signal Locked" read is how this step used to be skipped.  Everything
        # that reads capture state must come AFTER the restart, and must not decide.
        restart = self.at(RESTART_TX)
        for probe in ('hdmi_status', 'CAPTURE_ADVISORY_START'):
            self.assertGreater(self.at(probe), restart,
                               '%s must not be read before the mandatory restart' % probe)
        self.assertIn('> capture-advisory.txt 2>&1 || true', self.code,
                      'the advisory read must never be able to fail the flash')
        self.assertIn('verdict=NOT_EVALUATED', self.code)

    def test_the_restart_is_unconditional_in_its_own_branch(self):
        block = self.code[self.at('if [[ -e mcu-restart.done ]]'):self.at('CAPTURE_ADVISORY_START')]
        self.assertEqual(1, block.count(RESTART_TX))
        self.assertNotIn('is-active', block.split('MCU_LOG=mcu-restart.log')[0],
                         'no service or signal state may gate the restart')
        self.assertIn('MCU_RESTART_UNCONDITIONAL_START', block)

    def test_no_reset_of_any_kind_precedes_the_commit(self):
        self.assertLess(self.at('./qpcie_upgrade --package'), self.at('./qpcie_upgrade --commit'))
        commit = self.at('./qpcie_upgrade --commit')
        self.assertLess(commit, self.at('./qpcie_upgrade --reboot'))
        self.assertLess(commit, self.at(RESTART_TX))

    def test_a_rejected_new_module_never_reaches_the_commit(self):
        restore = self.at('New driver rejected; restored old module')
        self.assertLess(self.at('sudo -n rmmod qpcie'), restore)
        self.assertLess(restore, self.at('./qpcie_upgrade --commit'),
                        'the rollback path must stop before any eMMC COMMIT')


class OfflineRefusalTests(unittest.TestCase):
    """Refusals that are provable without a card: nothing may reach the network."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.bindir = root / 'bin'
        self.bindir.mkdir()
        (self.bindir / 'ssh').write_text(FAKE_SSH)
        (self.bindir / 'scp').write_text(FAKE_SSH)
        os.chmod(self.bindir / 'ssh', 0o755)
        os.chmod(self.bindir / 'scp', 0o755)
        self.log = root / 'ssh.log'
        self.log.write_text('')
        self.env = dict(os.environ)
        self.env.update({'PATH': str(self.bindir) + os.pathsep + os.environ['PATH'],
                         'FAKE_SSH_LOG': str(self.log)})

    def tearDown(self):
        self.tmp.cleanup()

    def build_dir(self, *, package_ok=True, digests_match=True):
        out = Path(tempfile.mkdtemp(dir=self.tmp.name))
        version = '26111204'
        (out / 'VERSION').write_text(version + '\n')
        if package_ok:
            (out / 'package.ok').write_text('SC7F0_PACKAGE_PASS\n')
        (out / 'logs').mkdir()
        names = ['upgrade-%s.tar' % version, 'host-tools-src.tar.gz',
                 'host-driver-src.tar.gz', 'images/BOOT.BIN', 'images/image.ub',
                 'images/boot.scr']
        (out / 'images').mkdir()
        for n in names:
            (out / n).parent.mkdir(parents=True, exist_ok=True)
            (out / n).write_bytes(b'x' * 64)
        lines = []
        for n in names:
            digest = subprocess.run(['sha256sum', str(out / n)], capture_output=True,
                                    text=True).stdout.split()[0]
            lines.append('%s  %s\n' % ('0' * 64 if not digests_match else digest, n))
        (out / 'RELEASE.sha256').write_text(''.join(lines))
        return out

    def run_flash(self, out: Path, *flags: str):
        r = subprocess.run([str(FLASH), '--build', str(out), *flags],
                           capture_output=True, text=True, env=self.env, timeout=120,
                           input='YES\n')
        return r.returncode, r.stdout + r.stderr

    def test_dry_run_opens_no_session(self):
        rc, transcript = self.run_flash(self.build_dir(), '--dry-run')
        self.assertEqual(rc, 0, transcript)
        self.assertEqual(0, self.log.read_text().count('@@@'),
                         'a dry run must not open a single ssh session')

    def test_a_build_without_a_passing_package_gate_is_refused(self):
        rc, transcript = self.run_flash(self.build_dir(package_ok=False))
        self.assertNotEqual(rc, 0)
        self.assertIn('Missing successful package gate', transcript)
        self.assertEqual(0, self.log.read_text().count('@@@'))

    def test_release_digest_mismatch_is_refused_before_any_transfer(self):
        rc, _ = self.run_flash(self.build_dir(digests_match=False))
        self.assertNotEqual(rc, 0)
        self.assertEqual(0, self.log.read_text().count('@@@'),
                         'a build whose digests do not verify must not open a session')

    def test_verify_only_still_requires_the_gate_and_opens_no_write(self):
        # --verify-only is the documented no-write path; it must still refuse a build
        # that never passed the package gate, so it cannot be used to skip it.
        rc, transcript = self.run_flash(self.build_dir(package_ok=False), '--verify-only')
        self.assertNotEqual(rc, 0)
        self.assertIn('Missing successful package gate', transcript)


if __name__ == '__main__':
    unittest.main(verbosity=2)
