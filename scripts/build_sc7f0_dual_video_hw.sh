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
# Build identity is stamped by scripts/impl_sc7f0_dual_video.tcl immediately
# before synthesis is re-launched. When any one of the three identity variables
# is supplied all three are required, and they are exported to both Vivado
# stages so project creation and re-synthesis cannot disagree. Without them the
# archived R7 behaviour is reproduced exactly.
ID_SET=()
for v in SC7F0_GIT_HASH SC7F0_BUILD_DATE; do
    [[ -n ${!v:-} ]] && ID_SET+=("$v")
done
if [[ ${#ID_SET[@]} -gt 0 ]]; then
    [[ -n ${SC7F0_VERSION:-} ]] && ID_SET+=(SC7F0_VERSION)
    [[ ${#ID_SET[@]} -eq 3 ]] || {
        echo "pinned build identity needs SC7F0_VERSION, SC7F0_GIT_HASH and SC7F0_BUILD_DATE together (have: ${ID_SET[*]})" >&2
        exit 1; }
    [[ $SC7F0_VERSION =~ ^[0-9A-Fa-f]{8}$ ]] || { echo 'SC7F0_VERSION must be 8 hex digits' >&2; exit 1; }
    [[ $SC7F0_GIT_HASH =~ ^[0-9A-Fa-f]{8}$ ]] || { echo 'SC7F0_GIT_HASH must be 8 hex digits' >&2; exit 1; }
    [[ $SC7F0_BUILD_DATE =~ ^20[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])$ ]] || {
        echo 'SC7F0_BUILD_DATE must be YYYYMMDD' >&2; exit 1; }
    : "${SC7F0_GIT_HASH_SOURCE:=commit}"
    [[ $SC7F0_GIT_HASH_SOURCE == commit || $SC7F0_GIT_HASH_SOURCE == dirty-content-fingerprint ]] || {
        echo 'SC7F0_GIT_HASH_SOURCE must be commit or dirty-content-fingerprint' >&2; exit 1; }
    export SC7F0_VERSION SC7F0_GIT_HASH SC7F0_BUILD_DATE SC7F0_GIT_HASH_SOURCE
fi
if [[ "$SC7F0_ENABLE_VCU" != 0 && "$SC7F0_ENABLE_VCU" != 1 ]]; then
    echo "SC7F0_ENABLE_VCU must be 0 or 1" >&2; exit 1
fi
if [[ "$SC7F0_TIMING_GATE" != strict && "$SC7F0_TIMING_GATE" != record ]]; then
    echo "SC7F0_TIMING_GATE must be strict or record" >&2; exit 1
fi
if [[ "${SC7F0_RELEASE_FLOW:-0}" == 1 ]]; then
    # A release is never built with the recorded (non-fatal) gate and never with
    # an unstamped identity. 2026-11-03/10/11 proved both let three different
    # bitstreams ship under one identity.
    [[ "$SC7F0_TIMING_GATE" == strict ]] || {
        echo 'SC7F0_RELEASE_FLOW=1 refuses SC7F0_TIMING_GATE=record; the release gate is strict' >&2; exit 1; }
    [[ ${#ID_SET[@]} -eq 3 ]] || {
        echo 'SC7F0_RELEASE_FLOW=1 requires the pinned SC7F0_VERSION/SC7F0_GIT_HASH/SC7F0_BUILD_DATE identity' >&2; exit 1; }
fi
mkdir -p "$LOGS"
if [[ ${#ID_SET[@]} -eq 3 ]]; then
    printf 'SC7F0_VERSION=%s\nSC7F0_GIT_HASH=%s\nSC7F0_BUILD_DATE=%s\nSC7F0_GIT_HASH_SOURCE=%s\n' \
        "$SC7F0_VERSION" "$SC7F0_GIT_HASH" "$SC7F0_BUILD_DATE" "$SC7F0_GIT_HASH_SOURCE" > "$LOGS/identity.txt"
fi
finish() { local rc=$?; trap - EXIT; printf '%s\n' "$rc" > "$LOGS/build.exit"; exit "$rc"; }
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'XILINXD_LICENSE_FILE=%s\nPROJECT=%s\nSC7F0_PROFILE=full\nSC7F0_VERSION=%s\nSC7F0_ENABLE_VCU=%s\nSC7F0_TIMING_GATE=%s\nSC7F0_GIT_HASH=%s\nSC7F0_BUILD_DATE=%s\nSC7F0_GIT_HASH_SOURCE=%s\nSC7F0_RELEASE_FLOW=%s\nBUILD_EPOCH=%s\n' \
    "$XILINXD_LICENSE_FILE" "$OUT" "$SC7F0_VERSION" "$SC7F0_ENABLE_VCU" "$SC7F0_TIMING_GATE" \
    "${SC7F0_GIT_HASH:-}" "${SC7F0_BUILD_DATE:-}" "${SC7F0_GIT_HASH_SOURCE:-}" "${SC7F0_RELEASE_FLOW:-0}" \
    "${SC7F0_BUILD_EPOCH:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" > "$LOGS/environment.txt"
git rev-parse HEAD > "$LOGS/git-head.txt"
git status --short > "$LOGS/git-status.txt"
# The worktree fingerprint is what makes an uncommitted fix auditable: HEAD
# alone would claim that the bitstream is exactly commit-clean.
{
    printf 'git_head=%s\n' "$(git rev-parse HEAD)"
    printf 'git_branch=%s\n' "$(git rev-parse --abbrev-ref HEAD)"
    printf 'worktree_dirty=%s\n' "$([[ -n $(git status --porcelain -- rtl constraints include test_app scripts petalinux tb driver) ]] && echo yes || echo no)"
    printf 'tracked_diff_sha256=%s\n' "$(git diff HEAD -- rtl constraints include test_app scripts petalinux tb driver | sha256sum | cut -d' ' -f1)"
} > "$LOGS/SOURCE_GIT.txt"
# SC7F0_SOURCE_FINGERPRINT is produced by the release entry point and embedded in
# version-identity.json, so the register identity and the real bytes are tied.
: "${SC7F0_SOURCE_FINGERPRINT:=}"
[[ -z "$SC7F0_SOURCE_FINGERPRINT" || "$SC7F0_SOURCE_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'SC7F0_SOURCE_FINGERPRINT must be a full sha256' >&2; exit 1; }
export SC7F0_SOURCE_FINGERPRINT
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
# A pinned identity must be present in the artifact itself, not only in the
# request. scripts/impl_sc7f0_dual_video.tcl already refuses to export an XSA
# whose synthesis run does not carry the stamps; this closes the loop for the
# case where someone re-runs only the XSA export.
if [[ ${#ID_SET[@]} -eq 3 ]]; then
    [[ -s "$OUT/version-identity.json" ]] || {
        echo "$OUT/version-identity.json missing: the design was never stamped" >&2; exit 1; }
    python3 - "$OUT/version-identity.json" "$SC7F0_VERSION" "$SC7F0_GIT_HASH" "$SC7F0_BUILD_DATE" <<'PY'
import json, sys
from pathlib import Path
rec = json.loads(Path(sys.argv[1]).read_text())
want = {'c_version': '0x' + sys.argv[2].upper(),
        'git_commit_hash_register': '0x' + sys.argv[3].upper(),
        'build_timestamp_register': sys.argv[4]}
bad = {k: (rec.get(k), v) for k, v in want.items() if rec.get(k) != v}
assert not bad, f'stamped identity does not match the requested identity: {bad}'
print('SC7F0_HARDWARE_IDENTITY_MATCH', rec['c_version'], rec['git_commit_hash_register'],
      rec['build_timestamp_register'], 'head=' + rec['git_head'][:8],
      'dirty=' + str(rec['worktree_dirty']))
PY
fi
# The XSA must carry exactly the bitstream this run produced, or the PS build
# would import a description of some other design.
python3 - "$OUT" <<'PY'
import hashlib, sys
from pathlib import Path
from zipfile import ZipFile
out = Path(sys.argv[1])
bit = (out / 'qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.bit').read_bytes()
with ZipFile(out / 'hardware.xsa') as z:
    names = [n for n in z.namelist() if n.endswith('.bit')]
assert len(names) == 1, names
with ZipFile(out / 'hardware.xsa') as z:
    embedded = z.read(names[0])
assert hashlib.sha256(embedded).hexdigest() == hashlib.sha256(bit).hexdigest(), \
    'hardware.xsa does not carry this run\'s bitstream'
print('SC7F0_XSA_BIT_BYTE_MATCH', names[0], hashlib.sha256(bit).hexdigest())
PY
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
    # strict means the shipped whole-design gate passed on these reports; the
    # recorded JSON is the evidence, so a green log line alone is never enough.
    python3 - "$OUT/timing-gate-record.json" <<'PY'
import json, sys
from pathlib import Path
rec = json.loads(Path(sys.argv[1]).read_text())
assert rec.get('pass_gate') is True, f'SC7F0_TIMING_GATE=strict but the recorded gate did not pass: {rec.get("errors")}'
assert not rec.get('errors'), rec['errors']
print('SC7F0_STRICT_GATE_RECORD_PASS margins', rec['margins_ns'], 'bus_skew_min_ns', rec['bus_skew_min_ns'])
PY
    printf 'Hardware gate PASS. Matching PS images/package and deployment remain separate.\n'
fi
