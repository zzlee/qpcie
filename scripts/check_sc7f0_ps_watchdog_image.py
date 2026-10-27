#!/usr/bin/env python3
"""Offline FIT/rootfs audit. Never executes target binaries or opens devices."""
import argparse
import gzip
import hashlib
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
DTC = "/opt/Xilinx/Vitis/2023.2/bin/dtc"
DUMP = "/opt/Xilinx/petalinux/2023.2/components/yocto/buildtools/sysroots/x86_64-petalinux-linux/usr/bin/dumpimage"


def cpio(data):
    entries = {}
    off = 0
    while True:
        h = data[off:off + 110]
        assert h[:6] == b"070701", "not newc"
        size = int(h[54:62], 16)
        namesize = int(h[94:102], 16)
        rawname = data[off + 110:off + 110 + namesize]
        assert rawname.endswith(b"\0")
        name = str(PurePosixPath(rawname[:-1].decode()))
        off = (off + 110 + namesize + 3) & ~3
        if name == "TRAILER!!!":
            break
        assert off + size <= len(data)
        assert not name.startswith("/") and ".." not in PurePosixPath(name).parts
        entries[name] = (int(h[14:22], 16), int(h[22:30], 16), data[off:off + size])
        off = (off + size + 3) & ~3
    return entries


def resolve(entries, path):
    pending, done, links = list(PurePosixPath(path).parts), [], 0
    while pending:
        part = pending.pop(0)
        if part in ("/", ".", ""):
            continue
        if part == "..":
            if done:
                done.pop()
            continue
        key = "/".join(done + [part])
        entry = entries.get(key)
        if entry and stat.S_ISLNK(entry[0]):
            links += 1
            assert links <= 40
            target = entry[2].decode()
            if target.startswith("/"):
                done = []
            pending = list(PurePosixPath(target).parts) + pending
        else:
            done.append(part)
    return entries["/".join(done)]


def audit(build):
    bit = (build / "fpga/zu4ev_pcie_card_top.bit").read_bytes()
    with ZipFile(build / "fpga/hardware.xsa") as z:
        names = [n for n in z.namelist() if n.endswith(".bit")]
        assert len(names) == 1 and z.read(names[0]) == bit
    assert (build / "images/zu4ev_pcie_card_top.bit").read_bytes() == bit
    cfg = (build / "images/kernel.config").read_text()
    for opt in ("CONFIG_WATCHDOG=y", "CONFIG_CADENCE_WATCHDOG=y",
                "CONFIG_WATCHDOG_NOWAYOUT=y", "CONFIG_WATCHDOG_SYSFS=y"):
        assert opt in cfg
    dts = subprocess.run([DTC, "-I", "dtb", "-O", "dts",
                          str(build / "images/system.dtb")],
                         check=True, capture_output=True, text=True).stdout
    node = re.search(r"watchdog@fd4d0000\s*\{([^}]+)\}", dts).group(1)
    assert 'status = "okay";' in node and "reset-on-timeout;" in node
    assert "EmCfgInit" in (build / "logs/pmufw.nm").read_text()
    with tempfile.TemporaryDirectory(prefix="sc7f0-fit-audit-") as tmp:
        payload = Path(tmp) / "ramdisk.gz"
        subprocess.run([DUMP, "-T", "flat_dt", "-p", "2", "-o", str(payload),
                        str(build / "images/image.ub")], check=True, capture_output=True)
        entries = cpio(gzip.decompress(payload.read_bytes()))
        for name in ("qpcie_debugd", "qpcie_hdmi_daemon",
                     "qpcie_upgrade_daemon", "sc7f0_ps_watchdog"):
            mode, uid, data = resolve(entries, "usr/bin/" + name)
            assert stat.S_ISREG(mode) and mode & 0o111 and uid == 0
            assert data[:4] == b"\x7fELF" and int.from_bytes(data[18:20], "little") == 183
            assert data == (ROOT / "test_app" / name).read_bytes(), name + " stale"
        for service, seconds in (("qpcie-debugd", 20), ("qpcie-hdmi-daemon", 20),
                                 ("qpcie-upgrade-daemon", 180)):
            unit = resolve(entries, f"etc/systemd/system/{service}.service.d/10-watchdog.conf")[2].decode()
            assert "Type=notify" in unit and f"WatchdogSec={seconds}\n" in unit
            assert "SC7F0_HEALTH_DIR=/run/sc7f0-health" in unit
        guardian = resolve(entries, "lib/systemd/system/sc7f0-ps-watchdog.service")[2].decode()
        assert "ExecStart=/usr/bin/sc7f0_ps_watchdog --run" in guardian
        assert "Restart=no" in guardian and "RefuseManualStop=yes" in guardian
        enabled = entries["etc/systemd/system/multi-user.target.wants/sc7f0-ps-watchdog.service"]
        assert stat.S_ISLNK(enabled[0])
        manager = resolve(entries, "etc/systemd/system.conf.d/90-sc7f0-watchdog.conf")[2]
        assert b"RuntimeWatchdogSec=0" in manager
        release = resolve(entries, "etc/sc7f0-recovery-release")[2].decode()
        assert release.startswith("sc7f0-ps-watchdog-20261027-r2\n")
    print("PS_WATCHDOG_IMAGE_AUDIT_PASS: FIT binaries, notifications, single WDT owner, kernel/DT, PMU EM, frozen PL")
    print("PL bit SHA256:", hashlib.sha256(bit).hexdigest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    audit(parser.parse_args().build.resolve())
