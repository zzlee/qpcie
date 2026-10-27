#!/usr/bin/env python3
"""DEVELOPMENT USER ONLY: systemd watchdog test with real debugd --sim.
No root, /dev/mem, PCIe, card, eMMC or watchdog device is accessed.
"""
import json
import os
from pathlib import Path
import signal
import struct
import subprocess as sp
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}",
               DBUS_SESSION_BUS_ADDRESS=f"unix:path=/run/user/{os.getuid()}/bus")
    def ctl(*args):
        return sp.run(["systemctl", "--user", *args], check=True,
                      capture_output=True, text=True, env=env, timeout=10).stdout
    unit = f"sc7f0-offline-watchdog-test-{os.getpid()}.service"
    with tempfile.TemporaryDirectory(prefix="sc7f0-systemd-mock-") as tmp:
        tmp = Path(tmp)
        binary, memory, health = tmp / "debugd", tmp / "mailbox", tmp / "health"
        sp.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror",
                "-I" + str(ROOT / "include"),
                str(ROOT / "test_app/qpcie_debugd.c"), "-o", str(binary)], check=True)
        memory.write_bytes(struct.pack("<II", 0x53434442, 1) + bytes(8192 - 8))
        health.mkdir(mode=0o700)

        def state():
            return dict(line.split("=", 1) for line in ctl("show", unit,
                        "-p", "MainPID", "-p", "ActiveState", "-p", "NRestarts").splitlines())

        def wait(predicate, timeout=10):
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                s = state()
                if predicate(s):
                    return s
                time.sleep(0.1)
            raise AssertionError(state())

        try:
            sp.run(["systemd-run", "--user", "--unit=" + unit,
                    "--property=Type=notify", "--property=NotifyAccess=main",
                    "--property=WatchdogSec=3s", "--property=WatchdogSignal=SIGKILL",
                    "--property=Restart=on-failure", "--property=RestartSec=100ms",
                    "--property=TimeoutStopSec=1s",
                    "--setenv=SC7F0_HEALTH_DIR=" + str(health),
                    str(binary), "--sim", str(memory)], check=True,
                   capture_output=True, text=True, env=env, timeout=10)
            first = wait(lambda s: s["ActiveState"] == "active" and int(s["MainPID"]) > 1)
            pid = int(first["MainPID"])
            time.sleep(1.2)
            assert state()["MainPID"] == str(pid), state()
            assert state()["NRestarts"] == "0", state()
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            assert cmdline[:3] == [str(binary).encode(), b"--sim", str(memory).encode()]
            os.kill(pid, signal.SIGSTOP)  # ONLY verified local mmap-file mock
            after = wait(lambda s: s["ActiveState"] == "active" and
                         int(s["NRestarts"]) >= 1 and int(s["MainPID"]) not in (0, pid))
            wait(lambda _: (health / "debug").exists() and
                 f" {after['MainPID']} " in (health / "debug").read_text())
            print(json.dumps({"test": "local-user-systemd-mock", "old_pid": pid,
                              "new_pid": int(after["MainPID"]),
                              "restarts": int(after["NRestarts"]), "hardware_access": False}))
        finally:
            ctl("stop", unit)
            sp.run(["systemctl", "--user", "reset-failed", unit],
                   capture_output=True, env=env, timeout=10)


if __name__ == "__main__":
    main()
