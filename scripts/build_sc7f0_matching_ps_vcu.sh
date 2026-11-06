#!/usr/bin/env bash
# VCU (VCU_C2H_ABI1.1) PS-only build from the scoped-accepted matching XSA,
# followed by production daemon compilation and injection into image.ub.
#
# Copy of the accepted scripts/build_sc7f0_matching_ps_r7.sh with three changes:
#   * the acceptance gate is the VCU profile (VCU_C2H_ABI1.1) and the injected
#     release marker must declare the PL base the acceptance directory itself
#     records (SC7F0_PL_BASE_VERSION: 0x26102902 or 0x26110301);
#   * the hardware-description import is verified to carry the VCU (psu_init
#     programs CRL_APB_PL1_REF_CTRL, the .bda maps the VCU register window) and the
#     built device tree is re-read with scripts/check_sc7f0_vcu_devicetree.py;
#   * bitstream/YAML boot artifacts are never written here, and the frozen R7
#     release + R7 acceptance trees are snapshotted before and re-verified after,
#     because this step does rewrite the shared PetaLinux project's
#     project-spec/hw-description (the R7 acceptance keeps its own XSA copy, so the
#     R7 image stays reproducible from that directory).
#
# Scope: hardware-description import + petalinux-build + PS userspace injection.
# Never builds or reflashes PL hardware, never flashes a card, never reboots a host
# or PS, and does not imply package or deployment acceptance (hardware.json keeps
# matching_ps_package_ready=false / deployment_allowed=false until the packaging
# step re-derives them from this build's logs).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
ACCEPT=$(realpath "${1:?ACCEPTANCE_DIRECTORY NEW_LOG_DIRECTORY}")
OUT=$(realpath -m "${2:?ACCEPTANCE_DIRECTORY NEW_LOG_DIRECTORY}")
# The VCU candidate must declare the VCU PL base in the injected release marker.
# Every supported base is an accepted VCU_C2H_ABI1.1 hardware candidate: 0x26102902
# (dual-video-26102902-vcu-r5) and 0x26110301 (dual-video-26110301-vcu-r1).  The
# acceptance directory handed in below has to record exactly this version, so the
# pair (acceptance dir, PL base) can never be mixed.
PL_BASE=${SC7F0_PL_BASE_VERSION:-0x26102902}
case "$PL_BASE" in
    0x26102902|0x26110301) ;;
    *) echo "Refusing to inject an unsupported PL base version: $PL_BASE "\
           "(accepted VCU bases: 0x26102902, 0x26110301)" >&2; exit 1 ;;
esac
IMG_DIR="$ROOT/petalinux/qpcie-zu4ev/images/linux"
PROJECT="$ROOT/petalinux/qpcie-zu4ev"
R7REL=build/sc7f0-capture-26102901-r1
R7ACC=build/r7-reviewed-acceptance.1793238509
# sstate-cache and downloads live on docker volumes (Docker Root Dir is on a
# 160 GB disk; the root filesystem holding build/tmp has ~16 GB free).  Mounting
# them at their configured paths keeps SSTATE_DIR/DL_DIR themselves - and every
# task signature derived from them - unchanged.
SSTATE_VOLUME=${SC7F0_SSTATE_VOLUME:-sc7f0-ps-vcu-sstate}
DOWNLOADS_VOLUME=${SC7F0_DOWNLOADS_VOLUME:-sc7f0-ps-vcu-downloads}
[[ ! -e "$OUT" ]] || { echo 'Refusing existing PS build logs' >&2; exit 1; }
mkdir -p "$OUT"
trap 'rc=$?; printf "%s\n" "$rc" > "$OUT/build.exit"' EXIT

# Host-side preflight for the post-build injection stage (runs outside the
# PetaLinux container, exactly as the accepted R6/R7 production injection did).
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
docker volume inspect "$SSTATE_VOLUME" >/dev/null
docker volume inspect "$DOWNLOADS_VOLUME" >/dev/null
df -h / | tail -1 > "$OUT/host-disk-before.txt"

# Frozen-tree guard: nothing below may write inside an existing release.
sha256sum "$R7REL"/VERSION "$R7REL"/build.ok "$R7REL"/package.ok \
          "$R7REL"/RELEASE.sha256 "$R7REL"/COMPILED.sha256 "$R7REL"/release.json \
          "$R7REL"/upgrade-26102901.tar "$R7REL"/images/BOOT.BIN "$R7REL"/images/image.ub \
          "$R7REL"/fpga/zu4ev_pcie_card_top.bit \
          "$R7ACC"/hardware.xsa "$R7ACC"/hardware.json "$R7ACC"/hardware.ok \
          > "$OUT/frozen-r7-before.sha256"
sha256sum -c "$OUT/frozen-r7-before.sha256" > "$OUT/frozen-r7-before-check.log"

# The pre-existing hardware description is recorded so the project transition this
# step performs is auditable in both directions.  psu_init.c is only listed when it
# exists: PetaLinux 2023.2 does not unpack it into project-spec anymore, and a
# sha256sum over a vanished leftover used to kill the run silently under set -e.
: > "$OUT/project-hw-description-before.sha256"
for f in "$PROJECT/project-spec/hw-description/system.xsa" \
         "$PROJECT/project-spec/hw-description/psu_init.c" \
         "$PROJECT/images/linux/image.ub" "$PROJECT/images/linux/system.dtb"; do
    if [[ -f $f ]]; then sha256sum "$f" >> "$OUT/project-hw-description-before.sha256"
    else printf 'ABSENT  %s\n' "$f" >> "$OUT/project-hw-description-before.sha256"; fi
done
sha256sum "$ACCEPT/REVIEW_INPUTS_OUTPUTS.sha256" | sed 's#.*  ##' >/dev/null
sha256sum -c "$ACCEPT/REVIEW_INPUTS_OUTPUTS.sha256" > "$OUT/hardware-review-input-check.log"

# Scoped VCU hardware acceptance gate. Anything looser stops before PetaLinux.
python3 - "$ACCEPT" "$PL_BASE" <<'PY'
import hashlib, json, sys
from pathlib import Path
from zipfile import ZipFile
p = Path(sys.argv[1]); pl_base = sys.argv[2]
r = json.loads((p/'hardware.json').read_text())
assert r['profile'] == 'VCU_C2H_ABI1.1', r['profile']
# The acceptance directory is what decides which PL base this build may declare:
# the accepted hardware version and the injected release marker have to be the same
# number, whichever candidate (0x26102902 r5, 0x26110301 r1, ...) is handed in.
assert r['version'] == pl_base, (r['version'], pl_base)
assert r['hardware_accepted'] is True
assert r['original_debug_profile_exit'] == 1, 'original debug-profile gate must stay rejected'
assert r['matching_ps_package_ready'] is False and r['deployment_allowed'] is False, \
    'a pre-accepted package/deployment flag would make this build circular'
assert r['review_only'] is True and r['deployment_authorized_by_this_report'] is False
xsa = (p/'hardware.xsa').read_bytes()
assert hashlib.sha256(xsa).hexdigest() == r['xsa_sha256'], 'accepted XSA drift'
names = [n for n in ZipFile(p/'hardware.xsa').namelist() if n.endswith('.bit')]
assert len(names) == 1, names
with ZipFile(p/'hardware.xsa') as z:
    assert hashlib.sha256(z.read(names[0])).hexdigest() == r['bit_sha256'], 'embedded bit drift'
scoped = (p/'hardware.ok').read_text().strip()
assert scoped == 'SCOPED_VCU_HARDWARE_ACCEPTED; NOT SYSTEM/PACKAGE/DEPLOYMENT ACCEPTANCE', scoped
review = json.loads((p/'review.json').read_text())
assert review['pass_gate'] is True and review['errors'] == [], review['errors']
# The scoped delta signoff stored in this directory must be the one that reviewed
# the very candidate this directory accepted.
assert review['candidate'] == r['hardware_candidate'], \
    (review['candidate'], r['hardware_candidate'])
m = review['summary']['margins_ns']
assert m['WNS'] > 0 and m['WHS'] > 0 and m['TNS'] == 0 and m['THS'] == 0, m
assert review['summary']['placed_counts']['VCU']['used'] == 1.0
for rel, digest in review['input_sha256'].items():
    assert hashlib.sha256(Path(rel).read_bytes()).hexdigest() == digest, rel
print(f'SCOPED_VCU_ACCEPTED_METADATA_PASS {pl_base} ({r["hardware_candidate"]}); '
      'package/deployment remain unaccepted')
PY

# Stage 1: matching hardware-description import + full PetaLinux build.
export SC7F0_REPO_ROOT="$ROOT" SC7F0_ACCEPTED_XSA="$ACCEPT/hardware.xsa" SC7F0_PS_BUILD_LOGS="$OUT"
docker run --rm -i --user "$(id -u):$(id -g)" \
    -e HOME="$HOME" -e USER="${USER:-zzlee}" -e TERM=xterm \
    -e SC7F0_REPO_ROOT -e SC7F0_ACCEPTED_XSA -e SC7F0_PS_BUILD_LOGS \
    -e XILINXD_LICENSE_FILE=2101@192.168.200.112 \
    -v "$HOME:$HOME" -v /opt:/opt \
    -v "$SSTATE_VOLUME:$PROJECT/build/sstate-cache" \
    -v "$DOWNLOADS_VOLUME:$PROJECT/build/downloads" \
    -v /etc/timezone:/etc/timezone:ro -v /etc/localtime:/etc/localtime:ro \
    -w "$PROJECT" petalinux:latest bash -s <<'CONTAINER'
set -eo pipefail
source /opt/Xilinx/petalinux/2023.2/settings.sh
set -u
petalinux-config --get-hw-description="$SC7F0_ACCEPTED_XSA" --silentconfig
# A hardware-description import owns CONFIG_SUBSYSTEM_BOOTARGS_GENERATED, and the
# encoder-VCU import added a global "cma=1000M" to it.  This card's low DDR bank
# is already committed (dau_fpga 256 MB no-map + 992 MB reusable shared-dma-pool
# + root=/dev/ram0), and that single bootarg is what kept the 26102902 image from
# reaching PS userspace.  Pin the card-validated bootargs here, and again in
# system-user.dtsi, so no future import can silently move the memory layout.
BASELINE_BOOTARGS='earlycon console=ttyPS0,115200 clk_ignore_unused root=/dev/ram0 rw'
sed -i "s|^CONFIG_SUBSYSTEM_BOOTARGS_GENERATED=.*|CONFIG_SUBSYSTEM_BOOTARGS_GENERATED=\"$BASELINE_BOOTARGS\"|" project-spec/configs/config
grep -q "^CONFIG_SUBSYSTEM_BOOTARGS_GENERATED=\"$BASELINE_BOOTARGS\"$" project-spec/configs/config \
    || { echo 'could not pin CONFIG_SUBSYSTEM_BOOTARGS_GENERATED' >&2; exit 1; }
echo "BOOTARGS_PINNED $BASELINE_BOOTARGS"
python3 - <<'PY'
from pathlib import Path
import hashlib,os,re
p=Path.cwd();root=Path(os.environ['SC7F0_REPO_ROOT']);out=Path(os.environ['SC7F0_PS_BUILD_LOGS']);xsa=Path(os.environ['SC7F0_ACCEPTED_XSA'])
x=list((p/'project-spec/hw-description').glob('*.xsa'))
assert len(x)==1 and hashlib.sha256(x[0].read_bytes()).digest()==hashlib.sha256(xsa.read_bytes()).digest(), 'imported XSA mismatch'
assert (p/'build/tmp').resolve()==p/'build/tmp', 'TMPDIR aliases another project'
conf=(p/'build/conf/bblayers.conf').read_text()
assert '/home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user' not in conf, 'wrong source layer'
assert 'meta-user' in conf, 'missing custom source layer'
# The imported handoff must actually carry the VCU, or this build would just be a
# rebuilt R7 image with a candidate label.  psu_init is read out of the XSA itself:
# PetaLinux 2023.2 no longer unpacks psu_init.c into project-spec/hw-description,
# so a file sitting there is a leftover from some earlier import and proves nothing
# (that is exactly how the r2 audit recorded its clock evidence, see the incident
# note).  The post-build stage below pins the copy the FSBL was really compiled
# from instead.
psu=None
from zipfile import ZipFile
with ZipFile(x[0]) as z:
    for n in z.namelist():
        if n.endswith('psu_init.c'):
            psu=z.read(n)
assert psu is not None, 'imported XSA carries no psu_init.c'
assert b'PSU_Mask_Write(CRL_APB_PL1_REF_CTRL_OFFSET' in psu, \
    'imported psu_init.c never writes CRL_APB.PL1_REF_CTRL -> VCU pll_ref_clk would be dead'
tuple_=re.search(rb'\(0XFF5E00C4,\s*0x([0-9A-Fa-f]{1,8})U\s*,\s*0x([0-9A-Fa-f]{1,8})U\)', psu)
assert tuple_, 'no (OFFSET, MASK, VALUE) record for CRL_APB.PL1_REF_CTRL @ 0XFF5E00C4'
mask, val = int(tuple_[1], 16), int(tuple_[2], 16)
assert val & (1 << 24), 'CRL_APB_PL1_REF_CTRL CLKACT (bit 24) is clear: 0x%08x' % val
div0, div1, srcsel = (val >> 8) & 0x3F, (val >> 16) & 0x3F, val & 0x7
assert div0 and div1, 'pl_clk1 has a zero divider: 0x%08x' % val
mhz = 1500.0 / div0 / div1 if srcsel == 2 else float('nan')
assert 33.0 < mhz < 33.7, 'pl_clk1 %.3f MHz is not the ~33.33 MHz VCU pll_ref_clk' % mhz
print('VCU_PL1_REF_CTRL 0xFF5E00C4 mask=0x%08x value=0x%08x CLKACT=1 SRCSEL=%d '
      'DIVISOR0=%d DIVISOR1=%d -> pl_clk1 ~= %.3f MHz (VCU pll_ref_clk)'
      % (mask, val, srcsel, div0, div1, mhz))
(out/'accepted-psu_init.c.sha256').write_text(
    hashlib.sha256(psu).hexdigest()+'  psu_init.c member of '+str(xsa)+'\n')
(out/'accepted-psu_init.c').write_bytes(psu)
# petalinux-build rewrites project-spec/configs/config, and it puts the generated
# "cma=1000M" back no matter what the import-time pin said.  Keep a copy of the
# config as configured so the post-build check can tell that one churned line
# apart from a real edit to the project.
(out/'config-before-build').write_text((p/'project-spec/configs/config').read_text())
bda=None
from zipfile import ZipFile
with ZipFile(x[0]) as z:
    for n in z.namelist():
        if n.endswith('.bda'): bda=z.read(n).decode('utf-8', 'replace')
assert bda and 'vcu_0' in bda, 'imported XSA has no vcu_0 block design'
assert any(a in bda for a in ('0x00b0100000', '0xb0100000', '0x0080080000', '0x80080000')), 'imported XSA does not map the VCU register window'
files=list((p/'project-spec/meta-user').rglob('*'))
files += [p/'project-spec/configs/config',p/'project-spec/configs/rootfs_config',p/'.petalinux/metadata']
files += [f for d in ('test_app','include') for f in (root/d).glob('*') if f.suffix in ('.c','.h') or f.name=='Makefile']
files=sorted(f for f in set(files) if f.is_file())
(out/'PS_BUILD_INPUTS.sha256').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+str(f)+'\n' for f in files))
(out/'imported-xsa.sha256').write_text(hashlib.sha256(x[0].read_bytes()).hexdigest()+'  '+str(x[0])+'\n')
print('SC7F0_MATCHING_XSA_AND_ISOLATED_PROJECT_PREFLIGHT_PASS',len(files),'PS source inputs; VCU present in the imported handoff')
PY
petalinux-build
# The FSBL/PMU that ship inside BOOT.BIN are compiled from the psu_init unpacked
# out of the imported XSA.  Pin those copies (not the project-spec leftovers) and
# prove the VCU clock record survived into them.  Only the per-platform copies
# under *_plat/ count: the FSBL source tree also carries vendor board examples
# (zcu102, som) whose psu_init has nothing to do with this card.
python3 - <<'PY'
import hashlib, os, re
from pathlib import Path
out = Path(os.environ['SC7F0_PS_BUILD_LOGS'])
accepted = (out/'accepted-psu_init.c').read_text()
want = hashlib.sha256((out/'accepted-psu_init.c').read_bytes()).hexdigest()
TRIPLE = re.compile(r'\(\s*(0X[0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)U\s*,\s*0x([0-9A-Fa-f]+)U\s*\)')
accepted_triples = set(TRIPLE.findall(accepted))
assert len(accepted_triples) > 500, 'accepted psu_init carries too few register writes'
hits = sorted(f for f in Path('build/tmp/work').rglob('psu_init.c')
              if '_plat' in str(f))
assert hits, 'no per-platform psu_init.c unpacked by the build'
rows, checked = [], 0
for f in hits:
    text = f.read_text()
    digest = hashlib.sha256(f.read_bytes()).hexdigest()
    rows.append(f'{digest}  {f}')
    assert digest == want, f'{f} is not the accepted XSA psu_init ({digest} != {want})'
    got = set(TRIPLE.findall(text))
    assert got == accepted_triples, (
        f'{f} programs a different register set: '
        f'{len(got - accepted_triples)} extra / {len(accepted_triples - got)} missing')
    checked += 1
assert checked >= 2 and any('fsbl-firmware_plat' in str(f) for f in hits), \
    'the FSBL platform copy of psu_init.c was never built'
(out/'fsbl-psu_init.sha256').write_text('\n'.join(rows) + '\n')
print(f'FSBL_PSU_INIT_MATCHES_ACCEPTED_XSA {want} '
      f'({checked} platform copies, {len(accepted_triples)} register writes identical)')
PY
# Every user-owned PS source input must be byte-stable across the build.  The one
# line petalinux-build is allowed to rewrite is the auto-generated bootargs, and
# only because the device-tree pin below overrules it - checked separately.
python3 - <<'PY'
import hashlib, os
from pathlib import Path
root = Path(os.environ['SC7F0_REPO_ROOT']); out = Path(os.environ['SC7F0_PS_BUILD_LOGS'])
before = (out/'config-before-build').read_text().splitlines()
after = (root/'petalinux/qpcie-zu4ev/project-spec/configs/config').read_text().splitlines()
key = lambda lines: [l for l in lines if not l.startswith('CONFIG_SUBSYSTEM_BOOTARGS_GENERATED=')]
assert key(before) == key(after), 'petalinux-build changed configs/config beyond the generated bootargs'
changed = [(b, a) for b, a in zip(before, after) if b != a]
(out/'bootargs-regenerated.txt').write_text(
    'petalinux-build rewrote the generated bootargs; the device tree pin below is what counts\n'
    + ''.join(f'before: {b}\nafter : {a}\n' for b, a in changed))
print(f'CONFIG_STABLE_APART_FROM_GENERATED_BOOTARGS ({len(changed)} line(s) regenerated by the build)')
bad = []
for line in (out/'PS_BUILD_INPUTS.sha256').read_text().splitlines():
    digest, path = line.split('  ', 1)
    f = Path(path)
    if f.name == 'config' and 'project-spec/configs' in str(f):
        continue
    if not f.is_file() or hashlib.sha256(f.read_bytes()).hexdigest() != digest:
        bad.append(str(f))
assert not bad, 'PS source input drifted during the build: ' + ', '.join(bad)
print('PS_BUILD_INPUTS_STABLE every user-owned PS source input is byte-identical after the build')
PY
sha256sum -c "$SC7F0_PS_BUILD_LOGS/imported-xsa.sha256" > "$SC7F0_PS_BUILD_LOGS/xsa-after-build-check.log"
printf 'Matching PS build completed; firmware/DT/rootfs/boot firmware/package acceptance still required.\n' > "$SC7F0_PS_BUILD_LOGS/build.complete"
CONTAINER

# Stage 1b: the built device tree must describe the hardware VCU, and the capture
# graph must have survived the hardware-description swap (host-side, read-only).
python3 scripts/check_sc7f0_vcu_devicetree.py "$IMG_DIR/system.dtb" \
    --require-capture-nodes --json "$OUT/vcu-devicetree-build.json" \
    > "$OUT/vcu-devicetree-build.log" 2>&1
tail -2 "$OUT/vcu-devicetree-build.log"

# Stage 1b.1: the PS memory layout must still be the one that boots on the card.
# The 26102902 first boot proved that a regenerated bootarg can kill userspace
# while every other artifact stays byte-identical, so this is a hard gate on the
# build, and it is repeated on the packaged release.
python3 scripts/check_sc7f0_memory_layout.py --baseline "$R7REL/images/image.ub" \
    --candidate "$IMG_DIR/system.dtb" --expect-label 'R7 26102901 (boots on the card)' \
    > "$OUT/memory-layout-build.log" 2>&1 || {
    tail -20 "$OUT/memory-layout-build.log" >&2
    echo 'PS memory layout drifted from the card-validated baseline; refusing to inject or release' >&2
    exit 1; }
tail -1 "$OUT/memory-layout-build.log"
df -h / | tail -1 > "$OUT/host-disk-after.txt"

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
print('SC7F0_VCU_DAEMON_ARM64_PASS qpcie_upgrade_daemon qpcie_debugd qpcie_hdmi_daemon sc7f0_ps_watchdog')
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
with tempfile.TemporaryDirectory(prefix='sc7f0-vcu-fit-') as t:
    t = Path(t)
    for index, name in ((0, 'kernel.gz'), (1, 'dtb'), (2, 'rootfs.gz')):
        subprocess.run([DUMP, '-T', 'flat_dt', '-p', str(index), '-o', str(t/name),
                        str(img/'image.ub')], check=True, capture_output=True)
    assert (t/'kernel.gz').read_bytes() == (img/'Image.gz').read_bytes(), 'FIT kernel drift'
    assert (t/'dtb').read_bytes() == (img/'system.dtb').read_bytes(), 'FIT dtb drift'
    # The repacked FIT must still carry the hardware VCU description.
    dtb = subprocess.run(['/opt/Xilinx/Vitis/2023.2/bin/dtc', '-I', 'dtb', '-O', 'dts',
                          str(t/'dtb')], check=True, capture_output=True, text=True).stdout
    assert ('b0100000' in dtb or '80080000' in dtb), 'FIT dtb lost the VCU register window during injection'
    entries = cpio(gzip.decompress((t/'rootfs.gz').read_bytes()))
    release = resolve(entries, 'etc/sc7f0-recovery-release')[2]
    assert b'PL_BASE_VERSION=' + base + b'\n' in release, release[:120]
    assert 'etc/systemd/system/multi-user.target.wants/sc7f0-vcud.service' not in entries, \
        'an optional VCU daemon must not enter the board-required health set'
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
print('SC7F0_VCU_INJECTED_FIT_PASS: VCU PL base declared, hardware VCU dtb intact, four ARM64 '
      'daemons byte-exact, units enabled with watchdog drop-ins, kernel/dtb unchanged, no vcud unit')
PY
sha256sum "$IMG_DIR/image.ub" > "$OUT/image-ub-final.sha256"
# Record the PS artifacts AFTER injection: image.ub is the injected FIT, the other
# components are the ones this build produced, which is exactly what a release must
# be able to re-verify.
sha256sum "$IMG_DIR/image.ub" "$IMG_DIR/system.dtb" "$IMG_DIR/Image.gz" \
    "$IMG_DIR/rootfs.cpio.gz" "$IMG_DIR/boot.scr" "$IMG_DIR/zynqmp_fsbl.elf" \
    "$IMG_DIR/pmufw.elf" "$IMG_DIR/bl31.elf" "$IMG_DIR/u-boot.elf" \
    > "$OUT/ps-artifacts.sha256"

# Frozen R7 trees must still be byte-identical after all of this.
sha256sum -c "$OUT/frozen-r7-before.sha256" > "$OUT/frozen-r7-after-check.log"
printf 'R7 release %s and R7 acceptance %s byte-identical after the VCU PS build\n' \
    "$R7REL" "$R7ACC" >> "$OUT/frozen-r7-after-check.log"

printf 'VCU matching PS build and daemon injection completed with PL base %s; firmware/DT/rootfs/package, capture-image audit and real-card deployment acceptance are still required.\n' \
    "$PL_BASE" > "$OUT/ps-vcu-injection.complete"
echo "VCU PS build + injection logs: $OUT"
sha256sum "$IMG_DIR/image.ub"
echo "Next: python3 scripts/check_sc7f0_capture_image.py <release> --project petalinux/qpcie-zu4ev --ps-build $OUT --base-version $PL_BASE"
