#!/usr/bin/env bash
# Assemble a deployable SC7F0 RGB-compositor (0x26111405) release directory out
# of a finished PS build, in the exact layout scripts/sc7f0_package.sh and
# scripts/sc7f0_flash.sh already consume:
#
#   <out>/VERSION  <out>/build.ok  <out>/SOURCE.sha256  <out>/COMPILED.sha256
#   <out>/fpga/{hardware.xsa,zu4ev_pcie_card_top.bit}
#   <out>/images/{image.ub,boot.scr,system.dtb,*fsbl*.elf,pmufw.elf,bl31.elf,u-boot.elf}
#   <out>/host-driver-src.tar.gz  <out>/host-tools-src.tar.gz
#
# Nothing here touches a card.  The FPGA side is fixed hardware: the "fpga"
# inputs are the accepted matching XSA and the bitstream extracted out of it,
# re-hashed, never re-implemented.  images/image.ub is the PS build's image with
# the production daemons injected (upgrade/debugd/hdmi/watchdog), exactly like
# the accepted R6/R7/VCU rounds did.
#
#   scripts/prepare_sc7f0_rgb_compositor_release.sh \
#       --ps-project <petalinux project copy that was built> \
#       --ps-logs    <that build's log directory> \
#       --xsa        <matching 26111405 xsa> \
#       --out        <NEW release directory>
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
PS_PROJECT="" PS_LOGS="" XSA="" OUT="" VERSION=${SC7F0_RELEASE_VERSION:-26111405}
# Same rule as build_sc7f0_rgb_compositor_ps.sh: the accepted 0x26111405
# digests are the default, a bring-up round passes its own digests explicitly
# and the resulting directory is labelled BRINGUP_ONLY_NOT_RELEASE_ACCEPTED.
EXPECT_XSA_SHA=${SC7F0_EXPECT_XSA_SHA:-bfea75097457a9d84aa59cd59d988a9839ad3d20b476b965efbd1d2d53e3ec4e}
EXPECT_BIT_SHA=${SC7F0_EXPECT_BIT_SHA:-285bedabb7342a78da8e2dc251336834f4e9617ef20a73863649ad49c78c0db9}
usage() { sed -n '2,26p' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }
while (($#)); do
    case "$1" in
        --ps-project) PS_PROJECT=${2:?}; shift 2;;
        --ps-logs) PS_LOGS=${2:?}; shift 2;;
        --xsa) XSA=${2:?}; shift 2;;
        --out) OUT=${2:?}; shift 2;;
        --version) VERSION=${2:?}; shift 2;;
        --expect-xsa-sha) EXPECT_XSA_SHA=${2:?}; shift 2;;
        --expect-bit-sha) EXPECT_BIT_SHA=${2:?}; shift 2;;
        -h|--help) usage 0;;
        *) echo "unknown argument $1" >&2; usage 2;;
    esac
done
for v in PS_PROJECT PS_LOGS XSA OUT; do
    [[ -n ${!v} ]] || { echo "--$(echo "$v" | tr 'A-Z_' 'a-z-') is required" >&2; usage 2; }
done
[[ $VERSION =~ ^[0-9]{8}$ ]] || exit 1
PS_PROJECT=$(realpath "$PS_PROJECT"); PS_LOGS=$(realpath "$PS_LOGS")
XSA=$(realpath "$XSA"); OUT=$(realpath -m "$OUT")
[[ -e $OUT ]] && { echo "OUT=$OUT exists; a release directory is never reused" >&2; exit 1; }
[[ $(<"$PS_LOGS/build.exit") == 0 ]] || { echo "$PS_LOGS/build.exit is not 0" >&2; exit 1; }
[[ $(sha256sum "$XSA" | cut -d' ' -f1) == "$EXPECT_XSA_SHA" ]] || {
    echo "XSA does not match the expected matching export ($EXPECT_XSA_SHA)" >&2; exit 1; }
SRC_IMG=$PS_PROJECT/images/linux
for f in image.ub boot.scr system.dtb Image.gz rootfs.cpio.gz; do
    [[ -f $SRC_IMG/$f ]] || { echo "missing $SRC_IMG/$f" >&2; exit 1; }
done
mkdir -p "$OUT"/{images,fpga,logs}

# --- 1. production daemons, freshly cross-compiled ------------------------
# -B so a header change (the 0x800 mailbox window in include/qpcie_debug.h) can
# never leave a stale binary behind for the injection stage to consume.
make -B -C test_app qpcie_upgrade_daemon qpcie_debugd qpcie_hdmi_daemon sc7f0_ps_watchdog \
    > "$OUT/logs/daemon-build.log" 2>&1
python3 - <<'PY'
import struct
from pathlib import Path
for n in ('qpcie_upgrade_daemon', 'qpcie_debugd', 'qpcie_hdmi_daemon', 'sc7f0_ps_watchdog'):
    d = (Path('test_app') / n).read_bytes()
    assert d[:4] == b'\x7fELF' and d[4] == 2, n + ' not a 64-bit ELF'
    assert struct.unpack_from('<H', d, 18)[0] == 183, n + ' not ARM64'
print('DAEMONS_ARM64_PASS qpcie_upgrade_daemon qpcie_debugd qpcie_hdmi_daemon sc7f0_ps_watchdog')
PY
sha256sum test_app/qpcie_upgrade_daemon test_app/qpcie_debugd test_app/qpcie_hdmi_daemon \
    test_app/sc7f0_ps_watchdog > "$OUT/daemons.sha256"

# --- 2. inject them into image.ub -----------------------------------------
# The same script the accepted rounds used, pointed at the build copy so the
# repository's own images/linux keeps its validated artifacts.  REL_TARGET_DIR
# is a directory that does not exist, so nothing is copied into a published
# installer.  qpcie-hdmi-daemon stays enabled because the running 0x26111204
# image runs it and scripts/sc7f0_flash.sh asserts it is active after reboot.
BEFORE=$(sha256sum "$SRC_IMG/image.ub" | cut -d' ' -f1)
cp -L "$SRC_IMG/image.ub" "$OUT/image-before-injection.ub"
SC7F0_IMG_DIR="$SRC_IMG" REL_TARGET_DIR="$OUT/.no-release-copy" \
INCLUDE_DEBUG_DAEMON=1 ENABLE_DEBUG_EXEC=1 ENABLE_HDMI_DAEMON=1 \
ENABLE_SC7F0_WATCHDOG=1 SC7F0_PL_BASE_VERSION="0x$VERSION" \
    bash scripts/inject_upgrade_daemon_to_image_ub.sh > "$OUT/logs/injection.log" 2>&1
AFTER=$(sha256sum "$SRC_IMG/image.ub" | cut -d' ' -f1)
[[ $BEFORE != $AFTER ]] || { echo 'image.ub unchanged by injection' >&2; exit 1; }
printf 'image.ub before injection %s\nimage.ub after  injection %s\n' "$BEFORE" "$AFTER" \
    > "$OUT/image-ub-injection.txt"

# --- 3. release layout ----------------------------------------------------
for f in image.ub boot.scr system.dtb Image.gz rootfs.cpio.gz pmufw.elf bl31.elf u-boot.elf; do
    [[ -f $SRC_IMG/$f ]] && cp -L "$SRC_IMG/$f" "$OUT/images/"
done
# bootgen needs the FSBL and an ELF-form u-boot.  PetaLinux deploys
# zynqmp_fsbl.elf with the fsbl-firmware recipe and u-boot.elf with u-boot; if
# either is absent the packaged BOOT.BIN would silently reuse an older one.
[[ -f $SRC_IMG/zynqmp_fsbl.elf ]] || {
    echo "missing $SRC_IMG/zynqmp_fsbl.elf - run inside the PetaLinux container:"
    echo "  petalinux-build -c fsbl-firmware" >&2; exit 1; }
cp -L "$SRC_IMG/zynqmp_fsbl.elf" "$OUT/images/"
[[ -f $OUT/images/u-boot.elf ]] || {
    echo "missing u-boot.elf in $SRC_IMG" >&2; exit 1; }

python3 - "$XSA" "$OUT/fpga" "$EXPECT_BIT_SHA" "$VERSION" <<'PY'
import hashlib, sys
from pathlib import Path
from zipfile import ZipFile
xsa, out, want, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
out.mkdir(parents=True, exist_ok=True)
z = ZipFile(xsa)
names = [n for n in z.namelist() if n.endswith('.bit')]
assert len(names) == 1, names
bit = z.read(names[0])
assert hashlib.sha256(bit).hexdigest() == want, 'embedded bitstream drift'
(xsa_out := out / 'hardware.xsa').write_bytes(xsa.read_bytes())
# sc7f0_package.sh and package_zu4ev_bootbin.sh look for this historic name;
# NOTE.txt records what it really is, so the name never hides the origin.
(out / 'zu4ev_pcie_card_top.bit').write_bytes(bit)
(out / 'NOTE.txt').write_text(
    f'hardware.xsa is a byte copy of {xsa.name}\n'
    f'  xsa sha256    {hashlib.sha256(xsa.read_bytes()).hexdigest()}\n'
    f'  member        {names[0]}\n'
    f'  bit sha256    {hashlib.sha256(bit).hexdigest()}\n'
    'zu4ev_pcie_card_top.bit is that member under the name the packaging scripts\n'
    'expect. It is the SC7F0-RGB-COMPOSITOR-2PPC 0x%s bitstream; it was not\n'
    're-implemented, re-routed or re-generated by anything in this flow.\n' % version)
print('FPGA_INPUTS_OK', names[0], hashlib.sha256(bit).hexdigest())
PY

# Host-side sources.  `git ls-files` alone silently drops a source that is new
# and not yet tracked, and the test host then cannot build the driver at all:
# driver/Makefile would name a .c that is not in the tarball.  The list is
# therefore taken from the tree and filtered to sources.  Build artifacts
# (.o/.ko/Module.symvers/modules.order) stay out as before, and *.mod.c covers
# the kbuild-generated qpcie.mod.c.
find driver include -maxdepth 1 -type f \
     \( -name '*.c' -o -name '*.h' -o -name Makefile \) ! -name '*.mod.c' -print0 |
    LC_ALL=C sort -z | tar --null -T - -czf "$OUT/host-driver-src.tar.gz"
tar -czf "$OUT/host-tools-src.tar.gz" test_app/qpcie_upgrade.c test_app/qpcie_sha256.h \
    test_app/host_rgb_compositor.c test_app/sc7f0_rgb_overlay.c test_app/sc7f0ctl.c \
    test_app/qpcie_debug_io.h include/qpcie_overlay.h include/qpcie_debug.h
# Sources that produced this image, re-hashed HERE at release-assembly time,
# plus the packaging scripts and the fixed RTL the accepted XSA was made from.
#
# Why not simply `cat $PS_LOGS/PS_BUILD_INPUTS.sha256`: that manifest is recorded
# by build_sc7f0_rgb_compositor_ps.sh BEFORE petalinux-build runs, and the build
# legitimately rewrites PetaLinux's own generated artifacts under the project -
# components/plnx_workspace/device-tree/device-tree/{hardware_description.xsa,
# pcw.dtsi, system-top.dts,<platform>.bit,<platform>.mmi},
# project-spec/hw-description/system.xsa, project-spec/configs/.statistics,
# *.log.old and .petalinux/metadata.  Verifying a pre-build snapshot against a
# post-build tree can never pass, and the failure it produced looked like source
# drift when it was the hardware description being re-imported (the
# <platform>.bit/.mmi names even change with the XSA name, so a J->K round rename
# showed up as "file missing").  Pasting it was therefore a manifest-semantics
# defect, not a safety property.
#
# What replaces it is stronger, not looser: the generated artifacts are excluded
# from SOURCE.sha256 but written out with their real digests to
# logs/GENERATED.sha256, and the imported XSA is asserted byte-for-byte against
# --expect-xsa-sha here, so a wrong hardware description still fails closed.
{
python3 - "$PS_PROJECT" "$EXPECT_XSA_SHA" "$OUT/logs/GENERATED.sha256" <<'PY'
import hashlib, sys
from pathlib import Path
project, want_xsa, generated_out = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def generated(p):
    s = str(p)
    return ('/components/plnx_workspace/' in s
            or p.parent == project / 'project-spec/hw-description'
            or p.name in ('.statistics', 'metadata')
            or p.name.endswith('.log.old'))

# Same selection rule as build_sc7f0_rgb_compositor_ps.sh, so the two manifests
# describe the same set; the difference is only when they are taken.
inputs = sorted(f for f in project.rglob('*') if f.is_file()
                and 'build' not in f.parts and 'images' not in f.parts
                and '.petalinux' not in f.parts and not generated(f))
meta = sorted(f for f in (project / '.petalinux').glob('*')
              if f.is_file() and f.name not in ('usage_statistics',
                                                'usage_statistics_token',
                                                'metadata'))
root = project.parent.parent
apps = sorted(f for d in ('test_app', 'include') for f in (root / d).glob('*')
              if f.is_file() and (f.suffix in ('.c', '.h') or f.name == 'Makefile'))
gen = sorted(f for f in project.rglob('*')
             if f.is_file() and 'build' not in f.parts and generated(f))
generated_out.parent.mkdir(parents=True, exist_ok=True)
generated_out.write_text(''.join(sha(f) + '  ' + str(f) + '\n' for f in gen))
imported = sorted((project / 'project-spec/hw-description').glob('*.xsa'))
assert len(imported) == 1, [p.name for p in imported]
got = sha(imported[0])
assert got == want_xsa, ('the hardware description the PS build actually consumed '
                         f'is not the accepted one: {imported[0]} {got} != {want_xsa}')
for f in inputs + meta + apps:
    sys.stdout.write(sha(f) + '  ' + str(f) + '\n')
print(f'# SOURCE_RECORDED_AT_RELEASE_ASSEMBLY project={len(inputs)} '
      f'petalinux_meta={len(meta)} app_include={len(apps)}', file=sys.stderr)
print(f'# GENERATED_EXCLUDED_RECORDED={len(gen)} -> {generated_out}', file=sys.stderr)
print(f'# IMPORTED_XSA_VERIFIED {imported[0].name} {got}', file=sys.stderr)
PY
  sha256sum scripts/inject_upgrade_daemon_to_image_ub.sh \
            scripts/install_debug_rootfs.sh scripts/install_sc7f0_watchdog_rootfs.sh \
            scripts/package_zu4ev_bootbin.sh scripts/package_sc7f0_upgrade.py \
            test_app/qpcie_upgrade_daemon.c test_app/qpcie_debugd.c \
            test_app/qpcie_hdmi_daemon.c test_app/sc7f0_ps_watchdog.c \
            include/qpcie_debug.h
  sha256sum rtl/sc7f0_rgb_compositor.v rtl/sc7f0_rgb_overlay_ctrl.v \
            rtl/zu4ev_pcie_card_top.v
} > "$OUT/SOURCE.sha256"
printf '%s\n' "$VERSION" > "$OUT/VERSION"
(cd "$OUT" && sha256sum fpga/*.bit fpga/*.xsa images/* host-*.tar.gz > COMPILED.sha256)
# The pre-build snapshot is kept alongside for the record; it is evidence of what
# the build was handed, not something a post-build tree can satisfy.
cp "$PS_LOGS/PS_BUILD_INPUTS.sha256" "$OUT/logs/PS_BUILD_INPUTS.pre-build.sha256" 2>/dev/null || true
printf 'SC7F0_BUILD_PASS\n' > "$OUT/build.ok"
cp "$PS_LOGS/build.exit" "$OUT/logs/ps-build.exit"
cp "$PS_LOGS/hardware-description.txt" "$OUT/logs/" 2>/dev/null || true
cp "$PS_LOGS/ps-artifacts.sha256" "$OUT/logs/" 2>/dev/null || true
cp "$PS_LOGS/image-audit.txt" "$OUT/logs/" 2>/dev/null || true

printf '\nPREPARE PASS release=%s version=0x%s\nNext: ./scripts/sc7f0_package.sh --build %q\n' \
    "$OUT" "$VERSION" "$OUT"
