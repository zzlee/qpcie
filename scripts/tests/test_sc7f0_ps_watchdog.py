"""Offline tests: real production parser/helper, no MMIO/watchdog device access."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOOT = Path("/proc/sys/kernel/random/boot_id").read_text().strip()


class WatchdogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="sc7f0-wdt-test-")
        cls.out = Path(cls.build.name)
        cls.guard = cls.out / "guard"
        subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "test_app/sc7f0_ps_watchdog.c"),
                        "-o", str(cls.guard)], check=True)
        helper = cls.out / "helper.c"
        helper.write_text('''#define _GNU_SOURCE
#include "sc7f0_health.h"
int main(void) {
 sc7f0_health_init("debug");
 sc7f0_health_ready();
 for (;;) { sc7f0_health_progress(); usleep(20000); }
}
''')
        cls.helper = cls.out / "helper"
        subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I" + str(ROOT / "test_app"), str(helper),
                        "-o", str(cls.helper)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.now = int(time.monotonic() * 1000)

    def tearDown(self):
        self.tmp.cleanup()

    def packet(self, name, stamp=None, lease=0, boot=BOOT, pid=None):
        p = self.dir / name
        p.write_text(f"SC7F0H1 {boot} {os.getpid() if pid is None else pid} "
                     f"{self.now if stamp is None else stamp} {lease}\n")
        p.chmod(0o600)
        return p

    def healthy(self):
        for name in ("debug", "hdmi", "upgrade"):
            self.packet(name)

    def check(self):
        return subprocess.run([str(self.guard), "--check-health", str(self.dir)],
                              capture_output=True, text=True).returncode == 0

    def test_fresh_all_services(self):
        self.healthy()
        self.assertTrue(self.check())

    def test_missing_service(self):
        self.healthy()
        (self.dir / "debug").unlink()
        self.assertFalse(self.check())

    def test_each_stale_service(self):
        for name, age in (("debug", 46000), ("hdmi", 46000), ("upgrade", 241000)):
            with self.subTest(name=name):
                self.healthy()
                self.packet(name, self.now - age)
                self.assertFalse(self.check())

    def test_wrong_boot_future_invalid_pid_and_extra_data(self):
        for kwargs in ({"boot": "0" * 36}, {"stamp": self.now + 60000},
                       {"pid": 0}, {"pid": 2147483648}):
            with self.subTest(kwargs=kwargs):
                self.healthy()
                self.packet("debug", **kwargs)
                self.assertFalse(self.check())
        self.healthy()
        with (self.dir / "debug").open("a") as f:
            f.write("unexpected")
        self.assertFalse(self.check())

    def test_daemon_exit_keeps_bounded_restart_grace(self):
        self.healthy()
        # Production regression: old PID disappears between systemd ABRT
        # and replacement readiness. Do not latch a system reset at once.
        self.packet("hdmi", pid=2147483647)
        self.assertTrue(self.check())
        self.packet("hdmi", pid=2147483647, stamp=self.now - 46000)
        self.assertFalse(self.check())

    def test_untrusted_or_symlink_health(self):
        self.healthy()
        (self.dir / "debug").chmod(0o666)
        self.assertFalse(self.check())
        self.packet("debug").rename(self.dir / "other")
        (self.dir / "debug").symlink_to(self.dir / "other")
        self.assertFalse(self.check())

    def test_commit_lease_defers_only_other_daemons(self):
        self.packet("upgrade", lease=self.now + 100000)
        self.assertTrue(self.check())
        self.packet("upgrade", stamp=self.now - 241000, lease=self.now + 10000)
        self.assertFalse(self.check())

    def test_expired_or_unbounded_lease_rejected(self):
        self.packet("upgrade", stamp=self.now - 1000, lease=self.now - 1)
        self.assertFalse(self.check())
        self.packet("upgrade", lease=self.now + 300001)
        self.assertFalse(self.check())

    def test_policy_latches_and_startup_grace_is_not_renewed(self):
        src = self.out / "policy.c"
        src.write_text('#define main production_main\n#include "' +
                       str(ROOT / "test_app/sc7f0_ps_watchdog.c") +
                       '''"
#undef main
#include <assert.h>
int main(void) {
 bool latch = false;
 assert(policy_feed(&latch, 1000, false));
 assert(policy_feed(&latch, 119999, false));
 assert(!policy_feed(&latch, 120000, false));
 assert(!policy_feed(&latch, 121000, true));
 latch = false;
 assert(policy_feed(&latch, 999999, true));
 assert(!policy_feed(&latch, 0, true));
 return 0;
}
''')
        binary = self.out / "policy"
        subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror",
                        str(src), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)

    def test_main_loop_notifies_and_publishes(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(str(self.dir / "notify"))
        sock.settimeout(3)
        env = dict(os.environ, NOTIFY_SOCKET=str(self.dir / "notify"),
                   SC7F0_HEALTH_DIR=str(self.dir))
        p = subprocess.Popen([str(self.helper)], env=env)
        try:
            self.assertEqual(sock.recv(200), b"READY=1")
            self.assertEqual(sock.recv(200), b"WATCHDOG=1")
            self.assertEqual(sock.recv(200), b"WATCHDOG=1")
            text = (self.dir / "debug").read_text()
            self.assertIn(BOOT, text)
            self.assertIn(str(p.pid), text)
            # Stop producer: there is no independent notifier/feed thread.
            p.send_signal(19)  # SIGSTOP, local mock only
            sock.settimeout(1.3)
            with self.assertRaises(socket.timeout):
                sock.recv(200)
        finally:
            p.kill()
            p.wait()
            sock.close()

    def test_kernel_and_pmu_policy_is_explicit(self):
        cfg = (ROOT / "petalinux/qpcie-zu4ev/project-spec/meta-user/"
               "recipes-kernel/linux/linux-xlnx/bsp.cfg").read_text()
        self.assertIn("CONFIG_WATCHDOG_NOWAYOUT=y", cfg)
        self.assertIn("CONFIG_WATCHDOG_SYSFS=y", cfg)
        patch = (ROOT / "petalinux/qpcie-zu4ev/project-spec/meta-user/"
                 "recipes-bsp/embeddedsw/pmu-firmware/"
                 "0002-sc7f0-enable-watchdog-srst.patch").read_text()
        self.assertIn("(1U) /* SC7F0: FPD SWDT -> hardware SRST */", patch)


if __name__ == "__main__":
    unittest.main()
