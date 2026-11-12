#!/usr/bin/env bash
# Assemble, prove and gate the SC7F0 VCU upgrade release. No SSH, no card, no
# flashing, no reboot, no service control. Called by
# scripts/build_sc7f0_vcu_release.sh --stage package, and runnable standalone.
#
#   scripts/package_sc7f0_vcu_release.sh --out build/vcu-release-<version>-r1 \
#                                        --ps-build build/vcu-release-<version>-r1/ps/build-...
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
OUT="" PS_BUILD=""
while (($#)); do
    case "$1" in
        --out) OUT=${2:?}; shift 2;;
        --ps-build) PS_BUILD=${2:?}; shift 2;;
        -h|--help) sed -n '2,8p' "$0"; exit 0;;
        *) echo "unknown argument $1" >&2; exit 2;;
    esac
done
[[ -n "$OUT" && -n "$PS_BUILD" ]] || { echo '--out and --ps-build are required' >&2; exit 2; }
OUT=$(realpath -m "$OUT"); PS_BUILD=$(realpath -m "$PS_BUILD")
VERSION=$(<"$OUT/VERSION")
[[ $VERSION =~ ^2[0-9]{7}$ ]] || { echo "bad VERSION" >&2; exit 1; }
IMG="$OUT/images"; REL="$OUT/release"; GATES="$OUT/gates"
PS_IMG="$ROOT/petalinux/qpcie-zu4ev/images/linux"
mkdir -p "$IMG" "$REL" "$GATES" "$OUT/logs/preflight" "$OUT/ps"
run() { printf '\n$ %s\n' "$*"; "$@"; }
[[ -s "$PS_BUILD/build.exit" && $(<"$PS_BUILD/build.exit") == 0 ]] || {
    echo "matching PS build did not finish cleanly: $PS_BUILD" >&2; exit 1; }
[[ -f "$PS_BUILD/build.complete" && -f "$PS_BUILD/ps-vcu-injection.complete" ]] || {
    echo "matching PS build logs are incomplete: $PS_BUILD" >&2; exit 1; }
[[ -f "$PS_BUILD/rootfs-runtime-content.json" ]] || {
    echo "no rootfs runtime proof in $PS_BUILD" >&2; exit 1; }
# The runtime byte sources are the PS stage's own record; the release gate reads them
# out of $OUT/ps, so carry them over here rather than letting a release ship the
# FIT check without the thing that made it meaningful.
[[ -s "$PS_BUILD/rootfs-binary-sources.json" ]] || {
    echo "no runtime byte-source record in $PS_BUILD (scripts/resolve_recipe_install_output.py "
         "writes rootfs-binary-sources.json in the PS stage)" >&2; exit 1; }
cp "$PS_BUILD/rootfs-runtime-content.json" "$OUT/ps/rootfs-runtime-content.json"
cp "$PS_BUILD/rootfs-binary-sources.json" "$OUT/ps/rootfs-binary-sources.json"
cp "$PS_BUILD/rootfs-runtime-content.log" "$OUT/ps/" 2>/dev/null || true
[[ -f "$GATES/fpga.ok" ]] || { echo "FPGA stage gate is missing" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. The PS image must have been built from exactly this release's XSA.
# ---------------------------------------------------------------------------
python3 - "$OUT" "$PS_BUILD" "$VERSION" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
out, ps, ver = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
xsa = out / 'fpga/hardware.xsa'
want = hashlib.sha256(xsa.read_bytes()).hexdigest()
recorded = re.search(r'([0-9a-f]{64})', (ps / 'imported-xsa.sha256').read_text())[1]
assert recorded == want, ('PS image was built from a different hardware XSA', recorded, want)
marker = (ps / 'rootfs-runtime-content.json').read_text()
assert 'ROOTFS_RUNTIME_CONTENT_PASS' in marker, marker[:400]
out.joinpath('PS_IMAGE_MATCH.json').write_text(json.dumps({
    'ps_image_built_from_this_xsa_sha256': want,
    'ps_image_pl_base_version': '0x' + ver,
    'vcu_address_map': {'performed': False,
                        'reason': 'no baseline (pre-VCU or 26111101) hardware XSA exists on this '
                                  'machine; the address-map-vs-baseline comparison is a B2 '
                                  'precondition and is reported as not performed'},
    'generated_by': 'scripts/package_sc7f0_vcu_release.sh'}, indent=2) + '\n')
print('PS_MATCHED_XSA_PASS', want)
PY

# ---------------------------------------------------------------------------
# 2. BOOT.BIN from this release's bitstream + this PS build's firmware.
# ---------------------------------------------------------------------------
for comp in zynqmp_fsbl.elf pmufw.elf bl31.elf u-boot.elf system.dtb image.ub boot.scr; do
    [[ -s "$PS_IMG/$comp" ]] || { echo "missing PS artifact $PS_IMG/$comp" >&2; exit 1; }
    cp -L "$PS_IMG/$comp" "$IMG/$comp"
done
cp "$OUT/fpga/zu4ev_pcie_card_top.bit" "$IMG/zu4ev_pcie_card_top.bit"
run env SC7F0_IMPL_DIR="$OUT/fpga" SC7F0_IMG_DIR="$IMG" bash scripts/package_zu4ev_bootbin.sh \
    > "$OUT/logs/bootbin-package.log" 2>&1
run python3 scripts/check_sc7f0_bootbin_payload.py --release-dir "$OUT" \
    > "$OUT/logs/bootbin-payload.log" 2>&1
python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
log = (out / 'logs/bootbin-payload.log')
text = log.read_text() if log.is_file() else ''
ok = 'BOOTBIN_PAYLOAD_MATCH' in text or 'BOOT.BIN carries' in text
(out / 'gates/bootbin-payload.json').write_text(json.dumps(
    {'verdict': 'BOOTBIN_PAYLOAD_MATCH' if ok else 'BOOTBIN_PAYLOAD_UNPROVEN',
     'evidence': str(log), 'output_tail': text[-1200:]}, indent=2) + '\n')
sys.exit(0 if ok else 1)
PY

# ---------------------------------------------------------------------------
# 3. Capture-graph audit of the produced FIT (device tree really describes the
#    capture + VCU path that this release's bitstream implements).
# ---------------------------------------------------------------------------
# The audit reads the *built* kernel's .config and System.map out of the release
# images directory (CONFIG_VIDEO_SC7F0_FRAME_TAP=y and the sc7f0_tap_* symbols are
# claims about this image). The PS stage exported them next to its logs; without
# this copy the audit would read whatever an unrelated older build left behind, or
# crash, and either outcome would look like a passing release step.
for f in kernel.config kernel.System.map; do
    [[ -s "$PS_BUILD/$f" ]] || {
        echo "PS build left no $f; the capture-graph audit cannot be run against " \
             "this round's kernel" >&2; exit 1; }
    cp "$PS_BUILD/$f" "$IMG/$f"
done
run python3 scripts/check_sc7f0_capture_image.py "$OUT" \
    --project petalinux/qpcie-zu4ev --ps-build "$PS_BUILD" \
    --base-version "0x$VERSION" > "$OUT/logs/capture-image-audit-after-package.log" 2>&1

# ---------------------------------------------------------------------------
# 4. The four-member upgrade tar + host-side sources.
# ---------------------------------------------------------------------------
BUNDLE="$REL/upgrade-$VERSION.tar"
[[ ! -e "$BUNDLE" ]] || { echo "refusing to overwrite $BUNDLE" >&2; exit 1; }
run python3 scripts/package_sc7f0_upgrade.py --images "$IMG" --output "$BUNDLE"
run python3 scripts/check_sc7f0_upgrade_tar.py "$BUNDLE" --release-dir "$OUT" \
    --json "$GATES/tar-structure.json"
git ls-files -z driver include | tar --null -T - -czf "$OUT/host-driver-src.tar.gz"
tar -czf "$OUT/host-tools-src.tar.gz" test_app/qpcie_upgrade.c test_app/qpcie_sha256.h \
    test_app/sc7f0ctl.c test_app/qpcie_debug_io.h include/qpcie_debug.h
[[ -s "$OUT/source-snapshot.tar.gz" ]] || { echo "no source snapshot" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Manifest, provenance and the release gate (with its negative tests).
# ---------------------------------------------------------------------------
# 4b. The package stage's own unit-test gate, over the bytes that were just
# packaged. It runs here rather than only in the release entry point so a
# standalone packaging run cannot skip it either, and its output is an input to
# scripts/check_sc7f0_release_package.py: a release whose packaging/rootfs/release
# checks were skipped, or ran on other sources, is not deployable.
# SC7F0_CAPTURE_RELEASE makes the real-image mutation suite runnable (the audits
# alone never proved the capture checker can refuse anything).
REQUIRED_TESTS_AT_PACKAGE=${SC7F0_REQUIRED_TESTS_PACKAGE:-test_sc7f0_release_package,test_package_sc7f0_upgrade,test_sc7f0_fit_rootfs,test_sc7f0_ps_runtime_sources,test_sc7f0_backup_retention,test_sc7f0_stop_token_driver}
export SC7F0_CAPTURE_RELEASE="$OUT" SC7F0_CAPTURE_PS_BUILD="$PS_BUILD"
PYTHONDONTWRITEBYTECODE=1 run python3 scripts/sc7f0_release_tests.py \
    --out "$GATES/unit-tests-at-package.json" --require-run "$REQUIRED_TESTS_AT_PACKAGE" \
    || echo "unit-test gate did not pass; the release gate below will refuse the package"


# What changed in the worktree after this release froze its own inputs. Tooling
# (tests, packaging helpers) legitimately keeps evolving during a multi-hour
# build; bitstream or PS inputs may not. The answer is recorded in the release
# instead of being quietly averaged away.
run python3 scripts/sc7f0_source_drift.py --release "$OUT" \
    --json "$GATES/source-drift-at-package.json" || {
    echo "refusing to package: a bitstream input changed after $OUT froze its manifest;" >&2
    echo "see $GATES/source-drift-at-package.json" >&2
    exit 1
}

python3 - "$OUT" "$VERSION" <<'PY'
import hashlib, json, sys
from pathlib import Path
out, ver = Path(sys.argv[1]), sys.argv[2]
names = [f'release/upgrade-{ver}.tar', 'host-driver-src.tar.gz', 'host-tools-src.tar.gz',
         'images/BOOT.BIN', 'images/image.ub', 'images/boot.scr',
         'fpga/hardware.xsa', 'fpga/zu4ev_pcie_card_top.bit',
         'source-snapshot.tar.gz']
digests = {n: hashlib.sha256((out / n).read_bytes()).hexdigest() for n in names}
(out / 'RELEASE.sha256').write_text(''.join(f'{h}  {n}\n' for n, h in digests.items()))
(out / 'release.json').write_text(json.dumps(
    {'version': ver, 'sha256': digests, 'deployable': False,
     'deployable_reason': 'written false here on purpose: only the release gate at the '
                          'end of this script may set it true, and it rewrites this '
                          'field together with gates/package.ok so the two can never '
                          'disagree'}, indent=2) + '\n')
print('MANIFEST', len(digests), 'entries')
PY
python3 - "$OUT" "$PS_BUILD" <<'PY'
import hashlib, json, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
out, ps = Path(sys.argv[1]), Path(sys.argv[2])
ident = json.loads((out / 'identity.json').read_text())
stamped = json.loads((out / 'fpga/version-identity.json').read_text())
gate = json.loads((out / 'gates/timing-gate-record.json').read_text())
prov = {
  'version': ident['version'],
  'git_head': ident['git_head'],
  'git_register': stamped.get('git_commit_hash_register'),
  'git_register_source': stamped.get('git_register_source'),
  'worktree_dirty': ident['worktree_dirty'],
  'source_fingerprint_sha256': ident['source_fingerprint_sha256'],
  'fpga_scope_fingerprint_sha256': ident.get('fpga_scope_fingerprint_sha256'),
  'ps_scope_fingerprint_sha256': ident.get('ps_scope_fingerprint_sha256'),
  'build_epoch_iso': ident.get('iso'),
  'packaged_utc': datetime.now(timezone.utc).isoformat(timespec='seconds'),
  'timing_gate': {'pass_gate': gate.get('pass_gate'), 'margins_ns': gate.get('margins_ns'),
                  'bus_skew_min_ns': gate.get('bus_skew_min_ns')},
  'timing_policy': 'SC7F0_TIMING_GATE=strict; record/off/forced pass/waiver are refused by '
                   'the release entry point',
  'implementation_directives': {k: v for k, v in sorted((__import__('os').environ).items())
                                if k.startswith('SC7F0_') and 'DIRECTIVE' in k or
                                k == 'SC7F0_POST_ROUTE_PHYS_OPT'},
  'ps_build_logs': str(ps),
  'ps_artifacts_sha256': {},
  'evidence': {},
}
drift_path = out / 'gates/source-drift-at-package.json'
if drift_path.is_file():
    drift = json.loads(drift_path.read_text())
    prov['source_drift_after_freeze'] = {
        'verdict': drift['verdict'],
        'manifest_reverification': drift['manifest_reverification'],
        'scope_identity_now_vs_preflight': drift['scope_identity_now_vs_preflight'],
        'drift': {k: v for k, v in drift['drift'].items() if v},
        'rule': drift['rule'],
    }
art = ps / 'ps-artifacts.sha256'
if art.is_file():
    prov['ps_artifacts_sha256'] = dict(reversed(l.split('  ', 1)) for l in
                                       art.read_text().splitlines() if '  ' in l)
for p in sorted(out.rglob('*')):
    if p.is_file() and p.suffix in ('.json', '.rpt', '.log', '.ok') and p.stat().st_size < 40 << 20:
        prov['evidence'][str(p.relative_to(out))] = hashlib.sha256(p.read_bytes()).hexdigest()
(out / 'release-provenance.json').write_text(json.dumps(prov, indent=2, sort_keys=True) + '\n')
print('PROVENANCE', len(prov['evidence']), 'evidence hashes')
PY

run python3 scripts/check_sc7f0_release_package.py --release "$OUT" \
    --json "$GATES/release-gate.json" || true
run python3 scripts/check_sc7f0_release_package.py --release "$OUT" --self-test \
    > "$OUT/logs/release-negative-tests.log" 2>&1 || true
tail -12 "$OUT/logs/release-negative-tests.log" || true

python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
gate = json.loads((out / 'gates/release-gate.json').read_text()) if \
    (out / 'gates/release-gate.json').is_file() else {'deployable': False, 'errors': ['no gate result']}
neg = (out / 'logs/release-negative-tests.log').read_text() if (out / 'logs/release-negative-tests.log').is_file() else ''
neg_ok = 'RELEASE_NEGATIVE_TESTS_PASS' in neg
if gate.get('deployable') and neg_ok:
    (out / 'gates/package.ok').write_text('SC7F0_RELEASE_PACKAGE_PASS\n')
    (out / 'NOT_DEPLOYABLE').unlink(missing_ok=True)
    # Say it in release.json too, in the same breath as gates/package.ok. The field
    # used to be written false by the manifest step and never revisited, so the only
    # truthful reading of every successful release was "not deployable".
    release_json = out / 'release.json'
    rj = json.loads(release_json.read_text())
    rj['deployable'] = True
    rj['deployable_reason'] = (
        'scripts/check_sc7f0_release_package.py passed over this directory at ' +
        str(gate.get('version')) + ' with its negative tests; this is a PACKAGE gate '
        'verdict only. Hardware/deployment acceptance is a separate act: '
        'docs/sc7f0_release_deploy_acceptance_runbook.md, and it has not been '
        'performed by anything that wrote this file.')
    rj['deployable_evidence'] = {
        'release_gate': 'gates/release-gate.json',
        'negative_tests': 'logs/release-negative-tests.log',
        'unit_tests': ['gates/unit-tests.json', 'gates/unit-tests-after-fpga.json',
                       'gates/unit-tests-at-package.json'],
        'hardware_review': 'ps/rootfs-binary-sources.json and fpga/version-identity.json',
    }
    release_json.write_text(json.dumps(rj, indent=2) + '\n')
    print('PACKAGE_GATE_PASS deployable=true (package gate only, no hardware acceptance)')
    sys.exit(0)
reasons = list(gate.get('errors', []))
if not neg_ok:
    reasons.append('negative tests did not all reject: ' + (neg.strip().splitlines()[-1] if neg.strip() else 'no output'))
(out / 'NOT_DEPLOYABLE').write_text(
    'This release failed its own package gate. Do not VERIFY, COMMIT, reboot or deploy it.\n'
    + ''.join(' - ' + r + '\n' for r in reasons))
(out / 'gates/package.failed').write_text('\n'.join(reasons) + '\n')
release_json = out / 'release.json'
if release_json.is_file():
    rj = json.loads(release_json.read_text())
    rj['deployable'] = False
    rj['deployable_reason'] = 'package gate failed; see NOT_DEPLOYABLE / gates/package.failed'
    release_json.write_text(json.dumps(rj, indent=2) + '\n')
print('PACKAGE_GATE_FAIL; NOT_DEPLOYABLE written')
for r in reasons[:10]:
    print('  -', r)
sys.exit(1)
PY
