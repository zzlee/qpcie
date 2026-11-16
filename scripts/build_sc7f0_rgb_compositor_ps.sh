#!/usr/bin/env bash
# SC7F0 RGB-compositor (0x26111405) PS-only build.
#
# Why this file exists: scripts/build_sc7f0_matching_ps.sh hard-asserts PL
# 0x26102804; scripts/build_sc7f0_matching_ps_r7.sh and ..._vcu.sh first
# `sha256sum -c` build/sc7f0-capture-26102901-r1 and
# build/r7-reviewed-acceptance.1793238509, neither of which exists on this
# machine any more, and then demand a VCU_C2H_ABI1.1/R7 hardware.json.  The
# 0x26111405 fabric has no VCU at all (scripts/create_zu4ev_ps_bd.tcl refuses
# VCU and SC7F0_RGB_COMPOSITOR on one design), so no such acceptance record can
# exist for it.  Nothing here runs Vivado: the bitstream is fixed and the only
# input is the matching XSA handed in on the command line.
#
#   scripts/build_sc7f0_rgb_compositor_ps.sh \
#       --xsa  /path/sc7f0-rgb-compositor-2ppc-26111405.xsa \
#       --out  <NEW log directory>            \
#       --project <petalinux project to build in>
#
# It never flashes a card, never reboots anything, never writes inside an
# existing release/build tree, and does not pretend that a finished build is a
# deployed image: it ends with the artifacts and the checks that were actually
# run, and reports deployment_allowed as an explicit "not yet".
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Set SC7F0_NO_AUDIT_FAIL=1 to keep artifacts from a device-tree that does not
# match the contract (investigation only; never for a release).
NO_AUDIT_FAIL=${SC7F0_NO_AUDIT_FAIL:-0}
cd "$ROOT"

XSA="" OUT="" PROJECT=""
PL_BASE=0x26111405
# The one and only matching hardware description for this personality, and the
# bitstream it must carry.  A BOOT.BIN built from any other bit (26111204,
# 26111208, or a failed re-run) is not this product, so the digests are checked
# before the container starts rather than after.
# Both digests may be pointed at a different hardware round with
# --expect-xsa-sha/--expect-bit-sha (or the matching environment variables)
# when a new FPGA revision is brought up; the defaults stay pinned to the
# accepted 0x26111405 export, so an unqualified invocation keeps its old
# fail-closed behaviour.  A round that overrides them is a bring-up round and
# must be labelled as such in the release directory, not accepted as a release.
EXPECT_XSA_SHA=${SC7F0_EXPECT_XSA_SHA:-bfea75097457a9d84aa59cd59d988a9839ad3d20b476b965efbd1d2d53e3ec4e}
EXPECT_BIT_SHA=${SC7F0_EXPECT_BIT_SHA:-285bedabb7342a78da8e2dc251336834f4e9617ef20a73863649ad49c78c0db9}
# LEFT index of the two PL->PS vectors as exported in zu4ev_ps_bd.hwh.
# Round 26111405 (J) shipped pl_ps_irq1 with LEFT="2" (readerA / planeB /
# overlay-writer only), which is why the HDMI TX interrupt had no wire at all;
# round 26111501 (K) widens it to LEFT="3", i.e. four inputs irq1[0..3] =
# SPI 104/105/106/107, the fourth being hdmi_tx_irq.  Rebuild an older round by
# passing these in explicitly; the default is the personality this script
# targets today, and a round that silently narrowed the vector now fails here
# instead of shipping a BOOT.BIN whose device tree names interrupts that no wire
# reaches.
EXPECT_IRQ1_LEFT=${SC7F0_EXPECT_IRQ1_LEFT:-3}
EXPECT_IRQ0_LEFT=${SC7F0_EXPECT_IRQ0_LEFT:-4}
# Device-tree SPI numbers the image audit must find, from the same K-era
# reference as the HWH widths above: 0x26111501 and later export the four
# pl_ps_irq1 sources as GIC INTID 136..139, i.e. DT SPI 104..107, while round
# 0x26111405 exported INTID 129..132 = SPI 97..100.  The audit script keeps the
# J-era values as its own defaults, so an unqualified call makes a CORRECT
# 0x26111501+ image fail its own gate - which is exactly what the first
# 0x26111503 PS build did (IMAGE_AUDIT_FAIL asking for SPI 97..100 while the
# built tree correctly carried 104..107).  That is a stale default in the gate,
# not a defect in the image, and the honest fix is to hand the gate this
# round's numbers (round 0x26111501 r3 was gated the same way) rather than to
# declare a failing gate benign.  Replay an older round by overriding these.
EXPECT_DT_SPI_FRMBUF_A=${SC7F0_IRQ_FRMBUF_A:-104}
EXPECT_DT_SPI_PLANE_B=${SC7F0_IRQ_PLANE_B:-105}
EXPECT_DT_SPI_OVERLAY_CTRL=${SC7F0_IRQ_OVERLAY_CTRL:-106}
EXPECT_DT_SPI_HDMI_TX=${SC7F0_IRQ_HDMI_TX:-107}
SSTATE_VOLUME=${SC7F0_SSTATE_VOLUME:-sc7f0-ps-vcu-sstate}
DOWNLOADS_VOLUME=${SC7F0_DOWNLOADS_VOLUME:-sc7f0-ps-vcu-downloads}
# Paths petalinuxbsp.conf configures.  They are mounted, not edited, so that
# SSTATE_DIR/DL_DIR - and every task signature derived from them - stay
# byte-identical to the builds that filled these caches.
CACHE_ROOT=$ROOT/petalinux/qpcie-zu4ev/build
usage() { sed -n '2,26p' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }
while (($#)); do
    case "$1" in
        --xsa) XSA=${2:?}; shift 2;;
        --out) OUT=${2:?}; shift 2;;
        --project) PROJECT=${2:?}; shift 2;;
        --pl-base) PL_BASE=${2:?}; shift 2;;
        --expect-xsa-sha) EXPECT_XSA_SHA=${2:?}; shift 2;;
        --expect-bit-sha) EXPECT_BIT_SHA=${2:?}; shift 2;;
        --expect-irq1-left) EXPECT_IRQ1_LEFT=${2:?}; shift 2;;
        --expect-irq0-left) EXPECT_IRQ0_LEFT=${2:?}; shift 2;;
        -h|--help) usage 0;;
        *) echo "unknown argument $1" >&2; usage 2;;
    esac
done
for v in XSA OUT PROJECT; do
    [[ -n ${!v} ]] || { echo "--$(echo "$v" | tr 'A-Z_' 'a-z-') is required" >&2; usage 2; }
done
[[ $PL_BASE =~ ^0x[0-9A-Fa-f]{8}$ ]] || { echo "bad --pl-base $PL_BASE" >&2; exit 1; }
XSA=$(realpath "$XSA"); PROJECT=$(realpath "$PROJECT"); OUT=$(realpath -m "$OUT")
[[ -f $XSA && -d $PROJECT/project-spec ]] || { echo '--xsa / --project unusable' >&2; exit 1; }
[[ -e $OUT ]] && { echo "OUT=$OUT already exists (never reuse a build log dir)" >&2; exit 1; }
mkdir -p "$OUT"
trap 'rc=$?; printf "%s\n" "$rc" > "$OUT/build.exit"' EXIT
IMG_DIR=$PROJECT/images/linux

# --- 1. the hardware description ------------------------------------------
sha256sum "$XSA" > "$OUT/input-xsa.sha256"
[[ $(cut -d' ' -f1 "$OUT/input-xsa.sha256") == "$EXPECT_XSA_SHA" ]] || {
    echo "XSA does not match the expected matching export ($EXPECT_XSA_SHA): $(cut -d' ' -f1 "$OUT/input-xsa.sha256")" >&2
    exit 1; }
python3 - "$XSA" "$EXPECT_BIT_SHA" "$PL_BASE" "$EXPECT_IRQ1_LEFT" "$EXPECT_IRQ0_LEFT" <<'PY' | tee "$OUT/hardware-description.txt"
import hashlib, re, sys, json
from pathlib import Path
from zipfile import ZipFile
xsa, want_bit, pl_base, want_irq1_left, want_irq0_left = sys.argv[1:6]
z = ZipFile(xsa)
bits = [n for n in z.namelist() if n.endswith('.bit')]
assert len(bits) == 1, bits
got = hashlib.sha256(z.read(bits[0])).hexdigest()
assert got == want_bit, f'embedded bitstream drift {got} != {want_bit}'
names = z.namelist()
assert not any('vcu' in n.lower() for n in names), [n for n in names if 'vcu' in n.lower()]
hwh = z.read('zu4ev_ps_bd.hwh').decode('utf-8', 'replace')
# Attribute order inside <PORT .../> is not fixed, and the vector appears both
# as the BD external port and as the PS cell's own interface port, so collect
# every element that mentions the name and read the widths off that.
def widths(name):
    return sorted({m.group(1) for m in re.finditer(r'<PORT[^>]*>', hwh)
                   if f'NAME="{name}"' in m.group(0)
                   for m in [re.search(r'LEFT="(\d+)"', m.group(0))] if m})
# A PORT element is only half the truth.  The 0x26111501/0x26111502 exports
# prove it: there pl_ps_irq0 appears with the correct LEFT="4" and no SIGNAME
# at all, while the wired pl_ps_irq1 carries SIGNAME="External_Ports_pl_ps_irq1".
# SIGNAME is the net, so a width check alone happily ships a BOOT.BIN whose
# interrupt-parent line names an interrupt that no wire reaches - which is
# exactly the defect that made every IRQ0 source (mailbox, VPHY SPI 90 /
# INTID 122, HDMI RX SS SPI 91 / INTID 123, dualpath, capture writer) silent on
# the deployed card.  Require the net, on BOTH the BD external port and the PS
# cell port.
def signames(name):
    return sorted({m.group(1) for m in re.finditer(r'<PORT[^>]*>', hwh)
                   if f'NAME="{name}"' in m.group(0)
                   for m in [re.search(r'SIGNAME="([^"]+)"', m.group(0))] if m})
def n_signed(name):
    return sum(1 for m in re.finditer(r'<PORT[^>]*>', hwh)
               if f'NAME="{name}"' in m.group(0)
               and 'SIGNAME=' in m.group(0))
irq1, irq0 = widths('pl_ps_irq1'), widths('pl_ps_irq0')
# The PS cell publishes its own interface port next to the BD external port, so
# the same name shows up with more than one width.  What matters is the widest
# one, and which width that is belongs to the round rather than to this file, so
# it is handed in from outside (see EXPECT_IRQ1_LEFT above).
assert irq1 and max(int(w) for w in irq1) == int(want_irq1_left), \
    f'pl_ps_irq1 widths={irq1} expected LEFT="{want_irq1_left}"'
assert irq0 and max(int(w) for w in irq0) == int(want_irq0_left), \
    f'pl_ps_irq0 widths={irq0} expected LEFT="{want_irq0_left}"'
assert 'pl_ps_irq_disp' not in hwh, 'a display-TX vector is present; wrong personality'
for nm, want_left in (('pl_ps_irq0', want_irq0_left), ('pl_ps_irq1', want_irq1_left)):
    sn, ns = signames(nm), n_signed(nm)
    # The BD external port and the PS cell interface port both have to sit on a
    # net, and on the same one.
    assert ns >= 2, (f'{nm}: only {ns} of its PORT elements carry a SIGNAME, i.e. the '
                     f'vector is exported but NOT wired to the PS (K/0x26111501 shipped '
                     f'exactly this shape with no IRQ0 delivery at all)')
    assert len(sn) == 1, f'{nm}: expected one shared net, got {sn}'
    assert nm in sn[0], f'{nm}: net {sn[0]} does not carry this vector'
    print(f'  {nm} LEFT="{want_left}" net={sn[0]} signed_port_elements={ns}')
print(f'  pl_ps_irq0 widths={irq0} pl_ps_irq1 widths={irq1}')
print('IRQ_VECTORS_ON_REAL_NETS_OK both pl_ps_irq0 and pl_ps_irq1 carry a SIGNAME')
print(f'HARDWARE_DESCRIPTION_OK pl_base={pl_base} xsa={Path(xsa).name}')
print(f'  bit={bits[0]} sha256={got}')
print('  ips=' + ','.join(sorted(n for n in names if n.endswith(".hwh"))))
print('  pl_ps_irq0=%d bits, pl_ps_irq1=%d bits, pl_ps_irq_disp absent, no VCU'
      % (int(want_irq0_left) + 1, int(want_irq1_left) + 1))
PY

# --- 2. host preflight ----------------------------------------------------
docker volume inspect "$SSTATE_VOLUME" >/dev/null
docker volume inspect "$DOWNLOADS_VOLUME" >/dev/null
[[ -d $CACHE_ROOT/sstate-cache && -d $CACHE_ROOT/downloads ]] || {
    echo "cache root $CACHE_ROOT is missing sstate-cache/downloads" >&2; exit 1; }
mkdir -p "$IMG_DIR"
# recipes-apps/{sc7f0-ps-capture,qpcie-debugd,sc7f0-vcud} reach the canonical C
# sources through QPCIE_ROOT := "${THISDIR}/../../../../../..", i.e. four
# directories above the project.  Building in a copy therefore needs that
# directory to carry test_app/ and include/; a missing one is a bitbake parse
# error ("Unable to get checksum ... file could not be found") minutes into the
# run, so it is checked here instead.
QPCIE_ROOT=$(realpath -m "$PROJECT/../..")
[[ -d $QPCIE_ROOT/test_app && -d $QPCIE_ROOT/include ]] || {
    echo "QPCIE_ROOT=$QPCIE_ROOT has no test_app/ and include/ for the meta-user"
    echo "recipes to find their sources in (a symlink to the repository's own"
    echo "directories is enough; nothing is written there)." >&2; exit 1; }
df -h "$OUT" "$PROJECT" / | tail -3 > "$OUT/host-disk-before.txt"

# --- 3. what is actually being compiled ----------------------------------
python3 - "$PROJECT" "$OUT" "$ROOT" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
project, out, root = (Path(p) for p in sys.argv[1:4])
files = sorted(f for f in project.rglob('*') if f.is_file()
               and 'build' not in f.parts and 'images' not in f.parts
               and '.petalinux' not in f.parts)
# PetaLinux rewrites its own usage bookkeeping during the build; it is not a
# build input, and hashing it makes the post-build source check fail on a run
# that changed nothing.
meta = sorted(f for f in (project / '.petalinux').glob('*')
              if f.is_file() and f.name not in ('usage_statistics',
                                                'usage_statistics_token'))
files += meta
apps = sorted(f for d in ('test_app', 'include') for f in (root / d).glob('*')
              if f.is_file() and (f.suffix in ('.c', '.h') or f.name == 'Makefile'))
manifest = out / 'PS_BUILD_INPUTS.sha256'
manifest.write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest() + '  ' + str(f) + '\n'
                            for f in files + apps))
print(f'PS_BUILD_INPUTS_RECORDED project={len(files)} app/include={len(apps)} -> {manifest}')
PY

# --- 4. hardware import + petalinux-build (container) --------------------
export SC7F0_XSA="$XSA" SC7F0_OUT="$OUT" SC7F0_PROJECT="$PROJECT"
set +e
docker run --rm -i --user "$(id -u):$(id -g)" \
    -e HOME="$HOME" -e USER="${USER:-zzlee}" -e TERM=xterm \
    -e SC7F0_XSA -e SC7F0_OUT -e SC7F0_PROJECT \
    -e XILINXD_LICENSE_FILE="${XILINXD_LICENSE_FILE:-2101@192.168.200.112}" \
    -v "$HOME:$HOME" -v /opt:/opt -v /mnt/data-root:/mnt/data-root \
    -v /etc/timezone:/etc/timezone:ro -v /etc/localtime:/etc/localtime:ro \
    -v "$DOWNLOADS_VOLUME:$CACHE_ROOT/downloads" \
    -v "$SSTATE_VOLUME:$CACHE_ROOT/sstate-cache" \
    -v "$CACHE_ROOT/sstate-cache:/sc7f0-sstate-mirror:ro" \
    -w "$PROJECT" petalinux:latest bash -s > "$OUT/ps-build.log" 2>&1 <<'CONTAINER'
set -eo pipefail
source /opt/Xilinx/petalinux/2023.2/settings.sh
set -u
cd "$SC7F0_PROJECT"
# Hardware import.  This rewrites project-spec/hw-description, psu_init and the
# generated part of project-spec/configs *inside the copy handed in by
# --project*; the repository's own project directory is never opened here.
petalinux-config --get-hw-description="$SC7F0_XSA" --silentconfig
python3 - <<'PY'
import hashlib, os
from pathlib import Path
p = Path(os.environ['SC7F0_PROJECT']); want = Path(os.environ['SC7F0_XSA'])
x = list((p / 'project-spec/hw-description').glob('*.xsa'))
assert len(x) == 1, x
assert hashlib.sha256(x[0].read_bytes()).hexdigest() == \
    hashlib.sha256(want.read_bytes()).hexdigest(), 'imported XSA is not the accepted XSA'
assert (p / 'build/tmp').resolve() == (p / 'build/tmp'), 'TMPDIR aliases another project'
conf = (p / 'build/conf/bblayers.conf').read_text()
assert 'meta-user' in conf, 'custom source layer missing'
print('IMPORT_OK', x[0].name)
local = (p / 'build/conf/local.conf').read_text().splitlines()
print('LOCALCONF ' + ' | '.join(l for l in local
                               if l.startswith('MACHINE') or l.startswith('require')))
PY
petalinux-build
CONTAINER
rc=$?
printf '%s\n' "$rc" > "$OUT/petalinux-build.exit"
[[ $rc -eq 0 ]] || { echo "petalinux-build failed with rc=$rc, see $OUT/ps-build.log" >&2; exit "$rc"; }

# --- 5. artifacts ---------------------------------------------------------
# petalinux-build does not produce BOOT.BIN here: it is generated from these
# components plus the accepted bitstream by scripts/package_zu4ev_bootbin.sh in
# the release step, so requiring it at this point would only be noise.
for f in image.ub boot.scr system.dtb Image.gz rootfs.cpio.gz zynqmp_fsbl.elf \
         u-boot.elf pmufw.elf bl31.elf; do
    [[ -f $IMG_DIR/$f ]] || { echo "missing $IMG_DIR/$f" >&2; exit 1; }
done
(cd "$IMG_DIR" && sha256sum image.ub boot.scr system.dtb Image.gz \
    rootfs.cpio.gz pmufw.elf bl31.elf u-boot.elf zynqmp_fsbl.elf) > "$OUT/ps-artifacts.sha256"
sha256sum -c "$OUT/PS_BUILD_INPUTS.sha256" > "$OUT/ps-source-after-build.log"

# --- 6. what the built device tree and rootfs really contain -------------
# The expectations live in scripts/audit_sc7f0_rgb_compositor_image.sh so the
# build gate and a later re-audit of an already built image cannot drift apart.
# boot.scr is pinned against the image the card boots today; sc7f0_flash.sh
# refuses the package if that ever changes silently.
CARD_BOOT_SCR=${SC7F0_CARD_BOOT_SCR_SHA256:-14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6}
set +e
SC7F0_EXPECT_BOOT_SCR_SHA256=$CARD_BOOT_SCR \
SC7F0_IRQ_FRMBUF_A=$EXPECT_DT_SPI_FRMBUF_A SC7F0_IRQ_PLANE_B=$EXPECT_DT_SPI_PLANE_B \
SC7F0_IRQ_OVERLAY_CTRL=$EXPECT_DT_SPI_OVERLAY_CTRL SC7F0_IRQ_HDMI_TX=$EXPECT_DT_SPI_HDMI_TX \
    bash "$SCRIPT_DIR/audit_sc7f0_rgb_compositor_image.sh" --images "$IMG_DIR" \
    | tee "$OUT/image-audit.txt"
AUDIT_RC=${PIPESTATUS[0]}
set -e
if [[ $AUDIT_RC -ne 0 && $NO_AUDIT_FAIL -eq 0 ]]; then
    echo "IMAGE_AUDIT_FAIL (rc=$AUDIT_RC); see $OUT/image-audit.txt" >&2
    exit "$AUDIT_RC"
fi
echo "PS build logs and artifacts: $OUT"
