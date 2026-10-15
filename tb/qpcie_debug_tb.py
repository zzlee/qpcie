#!/usr/bin/env python3
"""Native end-to-end simulation only: no PCIe, /dev/mem, eMMC or root.
Real daemon + client communicate over an explicitly selected mmap mailbox.
"""
import mmap
import os
from pathlib import Path
import signal
import shlex
import struct
import subprocess as sp
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(pred, seconds=5):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if pred():
            return
        time.sleep(0.01)
    raise AssertionError("wait timed out")


def main():
    with tempfile.TemporaryDirectory(prefix="qpcie-debug-") as work:
        work = Path(work)
        client, daemon = work / "sc7f0ctl", work / "qpcie_debugd"
        flags = ["-O2", "-g", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "include")]
        flags += shlex.split(os.environ.get("QPCIE_DEBUG_TEST_CFLAGS", ""))
        for src, out in [("sc7f0ctl.c", client), ("qpcie_debugd.c", daemon)]:
            sp.run(["gcc", *flags, str(ROOT / "test_app" / src), "-o", str(out)], check=True)
        memory = work / "mailbox"
        memory.write_bytes(struct.pack("<II", 0x53434442, 1) + bytes(8192 - 8))
        f = memory.open("r+b")
        m = mmap.mmap(f.fileno(), 8192)

        def rd(off):
            return struct.unpack_from("<I", m, off)[0]

        def wr(off, val):
            struct.pack_into("<I", m, off, val)

        def launch(enabled=True, closed_stdio=False, shell="/bin/sh"):
            args = [str(daemon), "--sim", str(memory), "--shell", shell]
            if enabled:
                args += ["--allow-exec"]
            def close_stdio():
                for fd in range(3):
                    os.close(fd)
                signal.signal(signal.SIGCHLD, signal.SIG_IGN)
            p = sp.Popen(args, stdout=sp.DEVNULL, stderr=sp.DEVNULL,
                         preexec_fn=close_stdio if closed_stdio else None)
            wait_for(lambda: rd(8) == 1)
            return p

        def run(op, value=None, rc=0, timeout="5"):
            args = [str(client), "--sim", str(memory), "--timeout", timeout, op]
            if value is not None:
                args.append(value)
            r = sp.run(args, capture_output=True, timeout=60)
            assert r.returncode == rc, (args, r.returncode, r.stdout, r.stderr)
            return r

        d = launch()
        try:
            assert b"ready=1" in run("status").stdout
            assert run("echo", "hello world").stdout == b"hello world\n"
            assert b"LOOPBACK_PASS: 10485760 bytes" in run("loopback", "10485760").stdout
            r = run("exec", "printf 'OUT'; printf 'ERR' >&2; exit 7", rc=7)
            assert r.stdout == b"OUT" and r.stderr == b"ERR"
            run("exec", "kill -TERM $$", rc=143)
            # Exact binary data crosses many response frames; stdout/stderr
            # remain separate. Each block also contains non-word lengths.
            r = run("exec", "python3 -c 'import os; os.write(1, bytes(range(256))*1025); os.write(2,b\"E\"*8193)'")
            assert r.stdout == bytes(range(256)) * 1025 and r.stderr == b"E" * 8193
            run("exec", "sleep 20", rc=124, timeout="0.15")
            assert run("exec", "printf recovered").stdout == b"recovered"
            # Empty and maximum-size echo payload; no power-of-two ring math.
            assert run("echo", "").stdout == b"\n"
            run("echo", "x" * 3072)
            run("exec", "x" * 3072, rc=2)
            run("exec", "true", rc=2, timeout="nan")
            # Cooperative cancellation and process-group cleanup.
            p = sp.Popen([str(client), "--sim", str(memory), "exec", "sleep 20"],
                         stdout=sp.PIPE, stderr=sp.PIPE)
            time.sleep(0.15)
            p.send_signal(signal.SIGINT)
            p.communicate(timeout=6)
            assert p.returncode == 130
            # Exclusive client and card ownership.
            p = sp.Popen([str(client), "--sim", str(memory), "exec", "sleep 1"],
                         stdout=sp.PIPE, stderr=sp.PIPE)
            time.sleep(0.1)
            run("status", rc=125)
            p.communicate(timeout=6)
            assert p.returncode == 0
            second = sp.run([str(daemon), "--sim", str(memory)], capture_output=True)
            assert second.returncode == 125
            # SIGKILL client: daemon notices stale heartbeat and kills descendants.
            marker = work / "must-not-exist"
            p = sp.Popen([str(client), "--sim", str(memory), "exec",
                          f"sleep 4; touch {marker}"], stdout=sp.PIPE, stderr=sp.PIPE)
            wait_for(lambda: rd(0x1c) == rd(0x20))
            time.sleep(0.1)
            p.kill(); p.communicate(timeout=3)
            time.sleep(4.2)
            assert not marker.exists()
            assert run("exec", "printf alive").stdout == b"alive"
            # Daemon restart invalidates epoch; no replay of side effects.
            count = work / "count"
            p = sp.Popen([str(client), "--sim", str(memory), "exec",
                          f"echo once >> {count}; sleep 20"], stdout=sp.PIPE, stderr=sp.PIPE)
            wait_for(count.exists)
            old_epoch = rd(0xc)
            d.terminate(); d.wait(timeout=5)
            d = launch()
            assert rd(0xc) != old_epoch
            p.communicate(timeout=6)
            assert p.returncode == 125
            assert count.read_text() == "once\n"
            assert run("exec", "printf restarted").stdout == b"restarted"
            # Corrupt request length must fail closed without shell execution.
            token = 0x12345678
            wr(0x10, token); wr(0x4c, 123)
            wait_for(lambda: rd(0x14) == token)
            wr(0x24, 1); wr(0x28, 99); wr(0x2c, 0xffffffff)
            wr(0x1c, (rd(0x1c) + 1) & 0xffffffff)
            wait_for(lambda: rd(0x14) == 0)
            assert run("exec", "printf resynced").stdout == b"resynced"
            # Sequence wrap (slot uses equality, not modulo payload arithmetic).
            wr(0x1c, 0xffffffff); wr(0x20, 0xffffffff)
            wr(0x30, 0xffffffff); wr(0x34, 0xffffffff)
            run("echo", "wrap")
            assert rd(0x1c) == 0 and rd(0x30) == 0
            # Standalone daemon with closed stdio and inherited SIGCHLD=IGN:
            # low-numbered pipe fds must not be closed after child dup2().
            d.terminate(); d.wait(timeout=5)
            d = launch(closed_stdio=True)
            r = run("exec", "printf low-out; printf low-err >&2; exit 9", rc=9)
            assert r.stdout == b"low-out" and r.stderr == b"low-err"
            d.terminate(); d.wait(timeout=5)
            d = launch(shell="/bin/bash")
            assert run("exec", 'a=(one two); printf "%s" "${a[1]}"').stdout == b"two"
            # Service defaults to no execution; transport still works.
            d.terminate(); d.wait(timeout=5)
            d = launch(False)
            disabled_marker = work / "disabled-command"
            run("exec", f"touch {disabled_marker}", rc=126)
            assert not disabled_marker.exists()
            run("echo", "disabled-but-connected")
            # Missing/stale daemon READY cannot be mistaken for live attachment.
            d.kill(); d.wait(timeout=5)
            run("exec", "true", rc=125)
            print("TB_PASS: debug RPC loopback, streams, exit, timeout, cancel, exclusivity, disconnect, restart, malformed frames, wrap, opt-in")
        finally:
            if d.poll() is None:
                d.terminate(); d.wait(timeout=5)
            m.close(); f.close()


if __name__ == "__main__":
    main()
