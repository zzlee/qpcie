#!/usr/bin/env bash
# R7 (0x26102901) PS-only build from the scoped-accepted matching XSA, followed by
# production daemon compilation and injection into image.ub.
#
# Scope: hardware-description import + petalinux-build + PS userspace injection.
# This never builds/reflashes PL hardware, never flashes a card, never reboots a
# host or PS, and does not imply package or deployment acceptance
# (hardware.json keeps matching_ps_package_ready=false / deployment_allowed=false).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
ACCEPT=$(realpath "${1:?ACCEPTANCE_DIRECTORY NEW_LOG_DIRECTORY}")
OUT=$(realpath -m "${2:?ACCEPTANCE_DIRECTORY NEW_LOG_DIRECTORY}")
# The R7 candidate must declare the R7 PL base in the injected release marker.
PL_BASE=${SC7F0_PL_BASE_VERSION:-0x26102901}
[[ "$PL_BASE" == "0x26102901" ]] || {
    echo "Refusing to inject a non-R7 PL base version: $PL_BASE" >&2; exit 1; }
IMG_DIR="$ROOT/petalinux/qpcie-zu4ev/images/linux"
[[ ! -e "$OUT" ]] || { echo 'Refusing existing PS build logs' >&2; exit 1; }
mkdir -p "$OUT"
trap 'rc=$?; printf "%s\n" "$rc" > "$OUT/build.exit"' EXIT

# Host-side preflight for the post-build injection stage (runs outside the
# PetaLinux container, exactly as the accepted R6 production injection did).
MKIMAGE=/opt/Xilinx/petalinux/2023.2/components/yocto/buildtools/sysroots/x86_64-petalinux-linux/usr/bin/mkimage
[[ -x "$MKIMAGE" || -n "$(command -v mkimage 2>/dev/null)" ]] || {
    echo 'Injection stage needs mkimage (PetaLinux buildtools or host)' >&2; exit 1; }
[[ -x /opt/Xilinx/Vitis/2023.2/bin/dtc || -n "$(command -v dtc 2>/dev/null)" ]] || {
    echo 'Injection stage needs dtc' >&2; exit 1; }
[[ -n "$(command -v fakeroot 2>/dev/null)" ]] || {
    echo 'Injection stage needs fakeroot' >&2; exit 1; }
[[ -x /opt/Xilinx/Vitis/2023.2/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-gcc ||
   -n "$(command -v aarch64-linux-gnu-gcc 2>/dev/null)" ]] || {
    echo 'Daemon stage needs the aarch64 cross compiler' >&2; exit 1; }

# Scoped R7 hardware acceptance gate. Anything looser stops before PetaLinux.
python3 - "$ACCEPT" <<'PY'
import hashlib, json, sys
from pathlib import Path
from zipfile import ZipFile
p = Path(sys.argv[1]); r = json.loads((p/'hardware.json').read_text())
assert r['profile'] == 'R7_C2H_ABI1.1', r['profile']
assert r['version'] == '0x26102901', r['version']
assert r['hardware_accepted'] is True
assert r['original_debug_profile_exit'] == 1, 'original debug-profile gate must stay rejected'
assert r['matching_ps_package_ready'] is False and r['deployment_allowed'] is False
xsa = (p/'hardware.xsa').read_bytes()
assert hashlib.sha256(xsa).hexdigest() == r['xsa_sha256'], 'accepted XSA drift'
names = [n for n in ZipFile(p/'hardware.xsa').namelist() if n.endswith('.bit')]
assert len(names) == 1, names
with ZipFile(p/'hardware.xsa') as z:
    assert hashlib.sha256(z.read(names[0])).hexdigest() == r['bit_sha256'], 'embedded bit drift'
scoped = (p/'hardware.ok').read_text().strip()
assert scoped == 'SCOPED_R7_HARDWARE_ACCEPTED; NOT SYSTEM/PACKAGE/DEPLOYMENT ACCEPTANCE', scoped
assert json.loads((p/'full-profile-review-after-export.json').read_text())['pass_gate']
print('SCOPED_R7_ACCEPTED_METADATA_PASS 0x26102901; package/deployment remain unaccepted')
PY
sha256sum -c "$ACCEPT/REVIEW_INPUTS_OUTPUTS.sha256" > "$OUT/hardware-review-input-check.log"

# Stage 1: matching hardware-description import + full PetaLinux build.
export SC7F0_REPO_ROOT="$ROOT" SC7F0_ACCEPTED_XSA="$ACCEPT/hardware.xsa" SC7F0_PS_BUILD_LOGS="$OUT"
docker run --rm -i --user "$(id -u):$(id -g)" \
    -e HOME="$HOME" -e USER="${USER:-zzlee}" -e TERM=xterm \
    -e SC7F0_REPO_ROOT -e SC7F0_ACCEPTED_XSA -e SC7F0_PS_BUILD_LOGS \
    -e XILINXD_LICENSE_FILE=2101@192.168.200.112 \
    -v "$HOME:$HOME" -v /opt:/opt \
    -v /etc/timezone:/etc/timezone:ro -v /etc/localtime:/etc/localtime:ro \
    -w "$ROOT/petalinux/qpcie-zu4ev" petalinux:latest bash -s <<'CONTAINER'
set -eo pipefail
source /opt/Xilinx/petalinux/2023.2/settings.sh
set -u
petalinux-config --get-hw-description="$SC7F0_ACCEPTED_XSA" --silentconfig
python3 - <<'PY'
from pathlib import Path
import hashlib,os
p=Path.cwd();root=Path(os.environ['SC7F0_REPO_ROOT']);out=Path(os.environ['SC7F0_PS_BUILD_LOGS']);xsa=Path(os.environ['SC7F0_ACCEPTED_XSA'])
x=list((p/'project-spec/hw-description').glob('*.xsa'))
assert len(x)==1 and hashlib.sha256(x[0].read_bytes()).digest()==hashlib.sha256(xsa.read_bytes()).digest(), 'imported XSA mismatch'
assert (p/'build/tmp').resolve()==p/'build/tmp', 'TMPDIR aliases another project'
conf=(p/'build/conf/bblayers.conf').read_text()
assert '/home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user' not in conf, 'wrong source layer'
assert 'meta-user' in conf, 'missing custom source layer'
files=list((p/'project-spec/meta-user').rglob('*'))
files += [p/'project-spec/configs/config',p/'project-spec/configs/rootfs_config',p/'.petalinux/metadata']
files += [f for d in ('test_app','include') for f in (root/d).glob('*') if f.suffix in ('.c','.h') or f.name=='Makefile']
files=sorted(f for f in set(files) if f.is_file())
(out/'PS_BUILD_INPUTS.sha256').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+str(f)+'\n' for f in files))
(out/'imported-xsa.sha256').write_text(hashlib.sha256(x[0].read_bytes()).hexdigest()+'  '+str(x[0])+'\n')
print('SC7F0_MATCHING_XSA_AND_ISOLATED_PROJECT_PREFLIGHT_PASS',len(files),'PS source inputs')
PY
petalinux-build
sha256sum -c "$SC7F0_PS_BUILD_LOGS/PS_BUILD_INPUTS.sha256" > "$SC7F0_PS_BUILD_LOGS/ps-source-check.log"
sha256sum -c "$SC7F0_PS_BUILD_LOGS/imported-xsa.sha256" > "$SC7F0_PS_BUILD_LOGS/xsa-after-build-check.log"
printf 'Matching PS build completed; firmware/DT/rootfs/package acceptance still required.\n' > "$SC7F0_PS_BUILD_LOGS/build.complete"
CONTAINER

# Stage 2: fresh ARM64 daemons. -B so a header change can never leave a stale
# binary behind for the injection stage to consume.
make -B -C test_app qpcie_upgrade_daemon qpcie_debugd qpcie_hdmi_daemon sc7f0_ps_watchdog \
    > "$OUT/production-daemon-build.log" 2>&1
python3 - <<'PY'
from pathlib import Path
import struct
for name in ('qpcie_upgrade_daemon','qpcie_debugd','qpcie_hdmi_daemon','sc7f0_ps_watchdog'):
    data = (Path('test_app')/name).read_bytes()
    assert data[:4] == b'\x7fELF' and data[4] == 2, name + ' is not a 64-bit ELF'
    assert struct.unpack_from('<H', data, 18)[0] == 183, name + ' is not ARM64'
print('SC7F0_R7_DAEMON_ARM64_PASS qpcie_upgrade_daemon qpcie_debugd qpcie_hdmi_daemon sc7f0_ps_watchdog')
PY
sha256sum test_app/qpcie_upgrade_daemon test_app/qpcie_debugd test_app/qpcie_hdmi_daemon \
    test_app/sc7f0_ps_watchdog > "$OUT/production-daemons.sha256"

# Stage 3: inject the daemons + watchdog release marker into image.ub. The
# published SD-installer directory is never a target for a candidate image.
for f in image.ub rootfs.cpio.gz Image.gz system.dtb; do
    [[ -f "$IMG_DIR/$f" ]] || { echo "Missing PetaLinux output: $IMG_DIR/$f" >&2; exit 1; }
done
# Recorded so the produced artifact states which lab-only privileges it carries.
printf 'SC7F0_PL_BASE_VERSION=%s\nINCLUDE_DEBUG_DAEMON=1\nENABLE_HDMI_DAEMON=1\nENABLE_SC7F0_WATCHDOG=1\nENABLE_DEBUG_EXEC=1 (lab image: root shell over PCIe)\nREL_TARGET_DIR=%s (never a published installer target)\n' \
    "$PL_BASE" "$OUT/.no-release-copy" > "$OUT/production-injection-flags.txt"
sha256sum "$IMG_DIR/image.ub" > "$OUT/image-ub-before-injection.sha256"
cp -L "$IMG_DIR/image.ub" "$OUT/image-before-production-injection.ub"
REL_TARGET_DIR="$OUT/.no-release-copy" INCLUDE_DEBUG_DAEMON=1 ENABLE_DEBUG_EXEC=1 \
    ENABLE_HDMI_DAEMON=1 ENABLE_SC7F0_WATCHDOG=1 SC7F0_PL_BASE_VERSION="$PL_BASE" \
    bash scripts/inject_upgrade_daemon_to_image_ub.sh > "$OUT/production-injection.log" 2>&1
sha256sum "$IMG_DIR/image.ub" > "$OUT/image-ub-after-injection.sha256"
BEFORE_SHA=$(cut -d' ' -f1 "$OUT/image-ub-before-injection.sha256")
AFTER_SHA=$(cut -d' ' -f1 "$OUT/image-ub-after-injection.sha256")
[[ "$BEFORE_SHA" != "$AFTER_SHA" ]] || {
    echo 'image.ub unchanged by injection' >&2; exit 1; }

# Stage 4: read the repacked FIT back and trust those bytes, not the injection
# script's own success banner.
SC7F0_IMG_DIR="$IMG_DIR" SC7F0_PL_BASE_VERSION="$PL_BASE" python3 - <<'PY'
import gzip, os, stat, struct, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path('scripts')))
from check_sc7f0_capture_image import cpio, resolve
from check_sc7f0_ps_watchdog_image import DUMP

img = Path(os.environ['SC7F0_IMG_DIR'])
base = os.environ['SC7F0_PL_BASE_VERSION'].encode()
with tempfile.TemporaryDirectory(prefix='sc7f0-r7-fit-') as t:
    t = Path(t)
    for index, name in ((0, 'kernel.gz'), (1, 'dtb'), (2, 'rootfs.gz')):
        subprocess.run([DUMP, '-T', 'flat_dt', '-p', str(index), '-o', str(t/name),
                        str(img/'image.ub')], check=True, capture_output=True)
    assert (t/'kernel.gz').read_bytes() == (img/'Image.gz').read_bytes(), 'FIT kernel drift'
    assert (t/'dtb').read_bytes() == (img/'system.dtb').read_bytes(), 'FIT dtb drift'
    entries = cpio(gzip.decompress((t/'rootfs.gz').read_bytes()))
    release = resolve(entries, 'etc/sc7f0-recovery-release')[2]
    assert b'PL_BASE_VERSION=' + base + b'\n' in release, release[:120]
    for binary, unit in (('qpcie_upgrade_daemon', 'qpcie-upgrade-daemon.service'),
                         ('qpcie_debugd', 'qpcie-debugd.service'),
                         ('qpcie_hdmi_daemon', 'qpcie-hdmi-daemon.service'),
                         ('sc7f0_ps_watchdog', 'sc7f0-ps-watchdog.service')):
        mode, uid, data = resolve(entries, 'usr/bin/' + binary)
        assert data == (Path('test_app')/binary).read_bytes(), binary + ' is stale in image.ub'
        assert struct.unpack_from('<H', data, 18)[0] == 183, binary + ' is not ARM64'
        assert uid == 0 and stat.S_ISREG(mode) and mode & 0o111, binary
        unit_key = 'lib/systemd/system/' + unit
        assert unit_key in entries and stat.S_ISREG(entries[unit_key][0]), unit
        enabled = 'etc/systemd/system/multi-user.target.wants/' + unit
        assert enabled in entries, (binary, enabled)
        assert resolve(entries, enabled)[2] == entries[unit_key][2], unit
    for monitored in ('qpcie-debugd', 'qpcie-hdmi-daemon', 'qpcie-upgrade-daemon'):
        dropin = 'etc/systemd/system/%s.service.d/10-watchdog.conf' % monitored
        assert dropin in entries and b'WatchdogSec=' in entries[dropin][2], dropin
    manager = 'etc/systemd/system.conf.d/90-sc7f0-watchdog.conf'
    assert manager in entries and b'RuntimeWatchdogSec=0' in entries[manager][2], manager
print('SC7F0_R7_INJECTED_FIT_PASS: R7 PL base declared, four ARM64 daemons byte-exact, units enabled with watchdog drop-ins, kernel/dtb unchanged')
PY

printf 'R7 matching PS build and daemon injection completed with PL base %s; firmware/DT/rootfs/package, capture-image audit and real-card deployment acceptance are still required.\n' \
    "$PL_BASE" > "$OUT/ps-r7-injection.complete"
echo "R7 PS build + injection logs: $OUT"
echo "Next: python3 scripts/check_sc7f0_capture_image.py <release> --project petalinux/qpcie-zu4ev --ps-build $OUT --base-version $PL_BASE"
