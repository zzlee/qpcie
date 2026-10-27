#!/usr/bin/env bash
# 1/3: regressions + FPGA/PS compilation. No SSH, flashing or reboot.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION= OUT= DRY=0
usage() { echo "Usage: $0 --version YYMMDDpp --out BUILD_DIR [--dry-run]"; }
while (($#)); do
    case "$1" in
        --version) VERSION=${2:?}; shift 2;;
        --out) OUT=${2:?}; shift 2;;
        --dry-run) DRY=1; shift;;
        -h|--help) usage; exit 0;;
        *) usage >&2; exit 2;;
    esac
done
[[ $VERSION =~ ^[0-9]{8}$ && -n $OUT ]] || { usage >&2; exit 2; }
((16#$VERSION >= 16#26102204)) || { echo 'Requires rev04+ format ABI' >&2; exit 2; }
OUT=$(realpath -m "$OUT")
if ((DRY)); then
    printf 'BUILD version=0x%s output=%s\nRun RTL/Python/AXI/CDC/4K60 regressions; Vivado timing/DRC/skew gates; PetaLinux; compile ARM daemons. No hardware access.\n' "$VERSION" "$OUT"
    exit 0
fi
[[ ! -e $OUT ]] || { echo "Refusing to overwrite $OUT; choose a fresh directory" >&2; exit 1; }
cd "$ROOT"
mkdir -p build
exec 9>build/.sc7f0-build.lock
flock -n 9 || { echo 'Another build/package is active' >&2; exit 1; }
mkdir -p "$OUT"/{logs,fpga,images}
exec > >(tee "$OUT/logs/build.log") 2>&1
trap 's=$?; echo "$s" > "$OUT/build.exit"; exit "$s"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$VERSION" > "$OUT/VERSION"
# Include untracked new RTL too, but never generated kernel .mod.c files.
find rtl constraints tb driver include test_app scripts petalinux/qpcie-zu4ev/project-spec/meta-user -type f \
    \( -name '*.v' -o -name '*.sv' -o -name '*.xdc' -o -name '*.c' -o -name '*.h' -o -name '*.tcl' -o -name '*.sh' -o -name '*.py' -o -name '*.bb' -o -name '*.bbappend' -o -name '*.cfg' -o -name '*.patch' -o -name '*.dtsi' -o -name '*.service' -o -name Makefile \) \
    ! -name '*.mod.c' -print0 | sort -z | xargs -0 sha256sum > "$OUT/SOURCE.sha256"
set +u
source "${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"
set -u
python3 scripts/generate_sc7f0_csr_cdc.py --check
SC7F0_NV_TEST_OUT="$OUT/unit/nv-formats" bash scripts/test_sc7f0_nv_formats.sh | tee "$OUT/logs/unit.log"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests
mkdir -p /tmp/opencode
python3 tb/qpcie_archive_verify_tb.py
cc -O2 -Wall -Wextra -Itest_app tb/qpcie_hdmi_audio_tb.c -o "$OUT/hdmi-audio-parser-test"
"$OUT/hdmi-audio-parser-test"
for test in sim_zu4ev_ps_axi_protocol sim_sc7f0_csr_cdc test_sc7f0_cdc test_sc7f0_audio; do
    vivado -mode batch -log "$OUT/logs/$test.vivado.log" -journal "$OUT/logs/$test.jou" \
        -source "scripts/$test.tcl" > "$OUT/logs/$test.log" 2>&1
done
for format in RGB NV12 NV16; do
    unset SC7F0_TEST_NV12 SC7F0_TEST_NV16
    case "$format" in NV12) export SC7F0_TEST_NV12=1;; NV16) export SC7F0_TEST_NV16=1;; esac
    vivado -mode batch -log "$OUT/logs/live-$format.vivado.log" -journal "$OUT/logs/live-$format.jou" \
        -source scripts/test_sc7f0_live_video.tcl > "$OUT/logs/live-$format.log" 2>&1
    grep -q 'TB_PASS: live 4K60' "$OUT/logs/live-$format.log"
done
export SC7F0_VERSION="$VERSION"
vivado -mode batch -log "$OUT/logs/fpga.vivado.log" -journal "$OUT/logs/fpga.jou" \
    -source scripts/build_sc7f0_hdmi_08.tcl > "$OUT/logs/fpga.log" 2>&1
grep -q '^HDMI08_BUILD_PASS' "$OUT/logs/fpga.log"
PROJ=build/qpcie_zu4ev_live_proj
! grep -q 'VIOLATED' "$PROJ/bus_skew.rpt"
cp "$PROJ"/{timing_summary,cdc,drc,bus_skew}.rpt "$OUT/fpga/"
cp "$PROJ/qpcie_zu4ev_live.runs/impl_1/zu4ev_pcie_card_top.bit" "$OUT/fpga/"
cp "$PROJ/qpcie_zu4ev_live.runs/impl_1/zu4ev_pcie_card_top_utilization_placed.rpt" "$OUT/fpga/"
cp hw_platform/sc7f0-hdmi08.xsa "$OUT/fpga/hardware.xsa"
python3 - "$OUT" <<'PY'
from pathlib import Path
from zipfile import ZipFile
import sys
p=Path(sys.argv[1])/'fpga'
with ZipFile(p/'hardware.xsa') as z:
    names=[n for n in z.namelist() if n.endswith('.bit')]
    assert len(names)==1 and z.read(names[0])==(p/'zu4ev_pcie_card_top.bit').read_bytes()
PY
make -C petalinux/qpcie-zu4ev hw-desc linux XSA_DIR="$OUT/fpga/hardware.xsa"
make -B -C test_app qpcie_upgrade_daemon qpcie_debugd qpcie_hdmi_daemon
# Build the deployable PS FIT with all three services enabled; never publish
# into release/zu4ev_sd_installer or overwrite a validated release directory.
REL_TARGET_DIR="$OUT/.no-release-copy" INCLUDE_DEBUG_DAEMON=1 ENABLE_DEBUG_EXEC=1 ENABLE_HDMI_DAEMON=1 \
    ENABLE_SC7F0_WATCHDOG=1 SC7F0_PL_BASE_VERSION="0x$VERSION" \
    bash scripts/inject_upgrade_daemon_to_image_ub.sh
for f in image.ub boot.scr zynqmp_fsbl.elf pmufw.elf bl31.elf u-boot.elf system.dtb; do
    cp -L "petalinux/qpcie-zu4ev/images/linux/$f" "$OUT/images/$f"
done
# Matched host driver sources are built against the test host's own kernel.
git ls-files -z driver include | tar --null -T - -czf "$OUT/host-driver-src.tar.gz"
tar -czf "$OUT/host-tools-src.tar.gz" test_app/qpcie_upgrade.c test_app/qpcie_sha256.h
sha256sum -c "$OUT/SOURCE.sha256" > "$OUT/logs/source-check.log"
(cd "$OUT"; sha256sum fpga/*.bit fpga/*.xsa images/* host-*.tar.gz > COMPILED.sha256)
printf 'SC7F0_BUILD_PASS\n' > "$OUT/build.ok"
printf '\nBUILD PASS: %s\nNext: %s/scripts/sc7f0_package.sh --build %q\n' "$OUT" "$ROOT" "$OUT"
