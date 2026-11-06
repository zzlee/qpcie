#!/usr/bin/env bash
# Fresh hardware build only. No SSH, packaging, flashing, MCU access or reboot.
# Supply XILINXD_LICENSE_FILE in the environment; never rewrite global settings.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${XILINXD_LICENSE_FILE:?Set the operator-provided Vivado license endpoint}"
OUT=$(realpath -m "${1:?Usage: XILINXD_LICENSE_FILE=PORT@HOST bash $0 NEW_PROJECT_DIR}")
LOGS="${OUT}-logs"
[[ ! -e "$OUT" && ! -e "$LOGS/SOURCE_RTL.sha256" ]] || {
    echo 'Refusing to overwrite an existing hardware build' >&2; exit 1;
}
# Opt-in VCU and hardware revision stay operator-controlled. The defaults are the
# frozen R7 values, so an unset environment reproduces the R7 build unchanged.
: "${SC7F0_VERSION:=26102901}"
: "${SC7F0_ENABLE_VCU:=0}"
: "${SC7F0_TIMING_GATE:=strict}"
if [[ "$SC7F0_ENABLE_VCU" != 0 && "$SC7F0_ENABLE_VCU" != 1 ]]; then
    echo "SC7F0_ENABLE_VCU must be 0 or 1" >&2; exit 1
fi
if [[ "$SC7F0_TIMING_GATE" != strict && "$SC7F0_TIMING_GATE" != record ]]; then
    echo "SC7F0_TIMING_GATE must be strict or record" >&2; exit 1
fi
mkdir -p "$LOGS"
finish() { local rc=$?; trap - EXIT; printf '%s\n' "$rc" > "$LOGS/build.exit"; exit "$rc"; }
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'XILINXD_LICENSE_FILE=%s\nPROJECT=%s\nSC7F0_PROFILE=full\nSC7F0_VERSION=%s\nSC7F0_ENABLE_VCU=%s\nSC7F0_TIMING_GATE=%s\n' \
    "$XILINXD_LICENSE_FILE" "$OUT" "$SC7F0_VERSION" "$SC7F0_ENABLE_VCU" "$SC7F0_TIMING_GATE" > "$LOGS/environment.txt"
git rev-parse HEAD > "$LOGS/git-head.txt"
git status --short > "$LOGS/git-status.txt"
find rtl constraints -type f \( -name '*.v' -o -name '*.sv' -o -name '*.xdc' \) -print0 |
    sort -z | xargs -0 sha256sum > "$LOGS/SOURCE_RTL.sha256"
sha256sum scripts/build_sc7f0_dual_video_hw.sh scripts/build_zu4ev.tcl \
    scripts/create_zu4ev_ps_bd.tcl scripts/create_sc7f0_hdmi_crossbar.tcl \
    scripts/impl_sc7f0_dual_video.tcl scripts/check_sc7f0_timing.py \
    scripts/generate_sc7f0_csr_cdc.py scripts/create_sc7f0_frmbuf_ip.tcl \
    scripts/create_sc7f0_vpss_csc_ip.tcl scripts/check_sc7f0_capture_gray.tcl \
    scripts/check_sc7f0_vcu_bd.tcl scripts/check_sc7f0_vcu_delta.py > "$LOGS/SOURCE_BUILD.sha256"
# Preserve exact inputs, including untracked new RTL, without changing the tree.
python3 - "$LOGS" <<'PY'
from pathlib import Path
import hashlib,shutil,sys
p=Path(sys.argv[1])
for manifest in ['SOURCE_RTL.sha256','SOURCE_BUILD.sha256']:
    for line in (p/manifest).read_text().splitlines():
        digest,name=line.split('  ',1); src=Path(name)
        assert not src.is_absolute() and '..' not in src.parts
        dst=p/'source'/src; dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,dst)
        assert hashlib.sha256(dst.read_bytes()).hexdigest()==digest,name
PY
set +u
source "${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"
set -u
export SC7F0_PROJECT_DIR="$OUT" SC7F0_PROFILE=full SC7F0_VERSION SC7F0_ENABLE_VCU SC7F0_TIMING_GATE
# All IPs are generated fresh under the supplied license environment. Do not
# reuse R1's Design_Linking netlists after restoring access to the license server.
SC7F0_BUILD_STAGE=ip vivado -mode batch -notrace -nojournal \
    -log "$LOGS/ip-vivado.log" -source scripts/build_zu4ev.tcl > "$LOGS/ip-console.log" 2>&1
grep -q IP_GENERATION_COMPLETE "$LOGS/ip-console.log"
vivado -mode batch -notrace -nojournal -log "$LOGS/impl-vivado.log" \
    -source scripts/impl_sc7f0_dual_video.tcl > "$LOGS/impl-console.log" 2>&1
grep -q SC7F0_DUAL_VIDEO_VIVADO_PASS "$LOGS/impl-console.log"
sha256sum -c "$LOGS/SOURCE_RTL.sha256" > "$LOGS/source-rtl-check.log"
sha256sum -c "$LOGS/SOURCE_BUILD.sha256" > "$LOGS/source-build-check.log"
test -s "$OUT/hardware.xsa"
test -s "$OUT/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.bit"
sha256sum "$OUT/hardware.xsa" \
    "$OUT/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.bit" > "$LOGS/HARDWARE.sha256"
# This does NOT satisfy the full PS-image/package build.ok gate.
if [[ "$SC7F0_TIMING_GATE" == record ]]; then
    # The shipped whole-design gate was recorded, not waived: the scoped delta
    # review against the frozen R7 evidence is the authoritative verdict.
    printf 'Hardware stage PASS with SC7F0_TIMING_GATE=record.\n' > "$LOGS/hardware.ok"
    printf 'Whole-design timing/CDC gate recorded to %s/timing-gate-record.json.\n' "$OUT" >> "$LOGS/hardware.ok"
    printf 'scripts/check_sc7f0_vcu_delta.py against the frozen R7 baseline must PASS before use.\n' >> "$LOGS/hardware.ok"
    printf 'Matching PS images/package and deployment remain separate.\n' >> "$LOGS/hardware.ok"
    printf 'Hardware stage PASS (recorded gate); scoped delta review and PS images remain.\n'
else
    printf 'SC7F0_DUAL_VIDEO_VIVADO_PASS\n' > "$LOGS/hardware.ok"
    printf 'Hardware gate PASS. Matching PS images/package and deployment remain separate.\n'
fi
