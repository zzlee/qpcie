#!/usr/bin/env python3
"""Run as root on the PCIe Host AFTER approved firmware04/driver installation.
No firmware upload, PCIe reset, eMMC write or Host reboot. Restarts only the
PS debug service and writes/removes a private PS /tmp fixture for cleanup tests.
"""
import errno
import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import struct
import subprocess as sp
import sys
import time

if not __debug__:
    raise SystemExit('Assertions must be enabled; do not use python -O')
if os.geteuid() != 0 or len(sys.argv) != 3 or sys.argv[2] != '--run':
    raise SystemExit('Usage: sudo python3 accept_sc7f0_debug.py CLIENT --run')
client = str(Path(sys.argv[1]).resolve())
node = '/dev/qpcie-debug-0000:03:00.0'
base = [client, '--device', node]
started = time.monotonic()


def log(name, **data):
    print(json.dumps(dict(test=name, elapsed=round(time.monotonic()-started, 3), **data)), flush=True)


def call(args, rc=0, budget=120):
    result = sp.run(base + args, capture_output=True, timeout=budget)
    assert result.returncode == rc, (args, result.returncode, result.stdout[:500], result.stderr[:500])
    return result


def execute(command, rc=0, timeout='10'):
    return call(['--timeout', timeout, 'exec', command], rc)


def status():
    result = call(['status'])
    fields = dict(re.findall(rb'(\w+)=([0-9a-f]+)', result.stdout))
    assert fields.get(b'ABI') == b'1' and fields.get(b'ready') == b'1', result.stdout
    return fields


def expect_errno(fn, expected):
    try:
        fn()
    except OSError as exc:
        assert exc.errno == expected, exc
    else:
        raise AssertionError('expected errno ' + str(expected))


info = os.stat(node)
assert stat.S_ISCHR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == 0
fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)
try:
    assert struct.unpack('<I', os.pread(fd, 4, 0))[0] == 0x53434442
    assert struct.unpack('<I', os.pread(fd, 4, 4))[0] == 1
    expect_errno(lambda: os.pwrite(fd, bytes(4), 0), errno.EPERM)
    expect_errno(lambda: os.pwrite(fd, bytes(4), 0x1000), errno.EPERM)
    expect_errno(lambda: os.pread(fd, 1, 0), errno.EINVAL)
    expect_errno(lambda: os.pread(fd, 4, 0x2000), errno.EINVAL)
    result = call(['status'], rc=125)
    assert b'busy' in result.stderr.lower(), result.stderr
finally:
    os.close(fd)
log('root-only-exclusive-bounded-MMIO', result='PASS')

first = status()
time.sleep(0.15)
second = status()
assert first[b'card_beat'] != second[b'card_beat']
log('daemon-heartbeat', result='PASS', status={k.decode(): v.decode() for k,v in second.items()})

r = execute('uname -a; id')
assert b'aarch64' in r.stdout and b'uid=0' in r.stdout, r.stdout
log('PS-Linux-command', result='PASS', stdout=r.stdout.decode(errors='replace'))
r = execute('a=(one two); [[ ${#a[@]} -eq 2 ]]; printf "%s\\n" "${a[1]}"')
assert r.stdout == b'two\n', r.stdout
r = execute('printf OUT; printf ERR >&2; exit 7', rc=7)
assert r.stdout == b'OUT' and r.stderr == b'ERR', (r.stdout, r.stderr)
log('Bash-stdout-stderr-exit7', result='PASS')

# PetaLinux BusyBox head may omit -c; plain dd is supported by this image.
r = execute('dd if=/dev/zero bs=1024 count=64 2>/dev/null; { dd if=/dev/zero bs=1024 count=32 2>/dev/null; } >&2')
assert r.stdout == bytes(65536) and r.stderr == bytes(32768)
log('binary-streams-backpressure', result='PASS', stdout_bytes=len(r.stdout), stderr_bytes=len(r.stderr))

r = call(['loopback', '10485760'], budget=300)
assert b'LOOPBACK_PASS: 10485760 bytes' in r.stdout
log('random-loopback-10MiB', result='PASS', stdout=r.stdout.decode().strip())

execute('sleep 10', rc=124, timeout='1')
assert execute('printf AFTER_TIMEOUT').stdout == b'AFTER_TIMEOUT'
log('timeout124-and-next-command', result='PASS')

p = sp.Popen(base + ['exec', 'printf "RUNNING\\n"; sleep 30; printf BAD'], stdout=sp.PIPE, stderr=sp.PIPE)
assert select.select([p.stdout], [], [], 5)[0], 'cancel test never started'
assert p.stdout.readline() == b'RUNNING\n'
p.send_signal(signal.SIGINT)
out, err = p.communicate(timeout=8)
assert p.returncode == 130 and b'BAD' not in out, (p.returncode, out, err)
assert execute('printf AFTER_CANCEL').stdout == b'AFTER_CANCEL'
log('Ctrl-C-cancellation-and-next-command', result='PASS')

fixture = '/tmp/sc7f0-debug-acceptance-' + str(os.getpid())
command = 'printf A > ' + fixture + '; printf "%s\\n" "$$"; sleep 30; printf B >> ' + fixture
p = sp.Popen(base + ['exec', command], stdout=sp.PIPE, stderr=sp.PIPE)
assert select.select([p.stdout], [], [], 5)[0], 'disconnect test never started'
ps_pid = int(p.stdout.readline().strip())
p.kill()
p.communicate(timeout=5)
time.sleep(4.5)
execute('test "$(cat ' + fixture + ')" = A && ! kill -0 -- -' + str(ps_pid))
execute('rm -f ' + fixture)
log('client-death-cleanup-no-replay', result='PASS', PS_process_group=ps_pid)

old_epoch = status()[b'card_epoch']
r = sp.run(base + ['exec', 'systemctl --no-block restart qpcie-debugd.service'], capture_output=True, timeout=15)
assert r.returncode in (0, 125), (r.returncode, r.stderr)
end = time.monotonic() + 15
while time.monotonic() < end:
    r = call(['status'])
    if b'ready=1' in r.stdout:
        fields = dict(re.findall(rb'(\w+)=([0-9a-f]+)', r.stdout))
        if fields.get(b'card_epoch') != old_epoch:
            break
    time.sleep(0.2)
else:
    raise AssertionError('PS debug service did not restart')
assert execute('printf AFTER_RESTART').stdout == b'AFTER_RESTART'
log('daemon-restart-new-epoch-and-reconnect', result='PASS')

r = execute('sha256sum /usr/bin/qpcie_debugd; stat -c "%u:%g %a" /etc/default/qpcie-debugd; systemctl is-active qpcie-debugd.service; systemctl is-active qpcie-upgrade-daemon.service; dmesg | tail -n 40')
lines = r.stdout.decode(errors='replace').splitlines()
assert len(lines) >= 4 and re.fullmatch(r'[0-9a-f]{64}  /usr/bin/qpcie_debugd', lines[0]), lines[:4]
assert lines[1:4] == ['0:0 600', 'active', 'active'], lines[:4]
log('PS-final-diagnostics', result='PASS', stdout=r.stdout.decode(errors='replace'))
log('TB_PASS hardware-debug-channel', result='PASS')
