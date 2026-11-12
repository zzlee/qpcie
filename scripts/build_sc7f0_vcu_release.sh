#!/usr/bin/env bash
# =============================================================================
# SC7F0 dual-video + VCU full release build: FPGA -> matching PS -> upgrade pkg.
#
# This is the reproducible entry point for the November dual-video/VCU work.
# The October trio (scripts/sc7f0_build.sh / sc7f0_package.sh / sc7f0_flash.sh)
# builds the hdmi08 flow and never mentions the VCU, so it is NOT an entry point
# for a VCU release; scripts/run_rebuild_26110301_vcu.sh pointed at a deleted
# worktree and set SC7F0_TIMING_GATE=record. Both facts are why this script
# exists.
#
#   scripts/build_sc7f0_vcu_release.sh --out build/vcu-release-<version>-r1
#   scripts/build_sc7f0_vcu_release.sh --out ... --stage fpga        # hardware only
#   scripts/build_sc7f0_vcu_release.sh --out ... --stage ps          # after fpga
#   scripts/build_sc7f0_vcu_release.sh --out ... --stage package     # after ps
#
# Guarantees enforced here (all fail closed, none of them configurable off):
#   * one fixed build epoch and one identity, allocated before Vivado runs and
#     never re-used from an earlier artifact;
#   * SC7F0_TIMING_GATE=strict and SC7F0_ENABLE_VCU=1 always, for a release;
#   * the identity is applied by the script that re-launches synthesis and is
#     read back out of the synthesis run directory;
#   * hardware.xsa carries byte-identical bitstream, and the PS image is built
#     from that exact XSA;
#   * the packaged image.ub is unpacked and inspected, so a runtime component
#     that only exists in a staging directory is a build failure;
#   * no SSH, no card access, no flashing, no reboot, no service control.
# =============================================================================
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

OUT="" STAGE=all VERSION="" KNOWN=() FPGA_PROJECT="" PS_LOGS=""
usage() {
    cat <<'EOF'
Usage: scripts/build_sc7f0_vcu_release.sh --out RELEASE_DIR
       [--stage all|preflight|fpga|ps|package] [--version YYMMDDpp]
       [--known-version VERSION]... [--fpga-project DIR] [--ps-build-logs DIR]
Environment: XILINXD_LICENSE_FILE (required for the FPGA stage),
             SC7F0_SSTATE_VOLUME / SC7F0_DOWNLOADS_VOLUME (PS stage),
             SC7F0_HARDWARE_ACCEPTANCE_DIR (PS stage, else derived from this build)
EOF
}
while (($#)); do
    case "$1" in
        --out) OUT=${2:?}; shift 2;;
        --stage) STAGE=${2:?}; shift 2;;
        --version) VERSION=${2:?}; shift 2;;
        --known-version) KNOWN+=("$2"); shift 2;;
        --fpga-project) FPGA_PROJECT=${2:?}; shift 2;;
        --ps-build-logs) PS_LOGS=${2:?}; shift 2;;
        -h|--help) usage; exit 0;;
        *) usage >&2; exit 2;;
    esac
done
[[ -n "$OUT" && $STAGE =~ ^(all|preflight|fpga|ps|package)$ ]] || { usage >&2; exit 2; }
OUT=$(realpath -m "$OUT")
# A release directory is written once, in order. preflight must start from an
# empty directory (so an old identity can never be reused), while the later
# stages are required to run inside the directory preflight created - otherwise
# the FPGA, PS and package stages would have nowhere to prove they belong to the
# same identity.
if [[ $STAGE == preflight || $STAGE == all ]]; then
    [[ ! -e "$OUT" || -z "$(ls -A "$OUT" 2>/dev/null)" ]] || {
        echo "Refusing to reuse a non-empty release directory: $OUT" >&2; exit 1; }
else
    [[ -s "$OUT/identity.json" && -s "$OUT/VERSION" ]] || {
        echo "$OUT has no identity.json/VERSION; run --stage preflight first" >&2; exit 1; }
    [[ $(<"$OUT/VERSION") =~ ^2[0-9]{7}$ ]] || { echo "bad VERSION in $OUT" >&2; exit 1; }
fi
mkdir -p "$OUT"/{logs,fpga,ps,images,release,gates}
exec 9>build/.sc7f0-build.lock
flock -n 9 || { echo 'Another build/package is active' >&2; exit 1; }
BUILD_LOG="$OUT/logs/release.log"
exec > >(tee -a "$BUILD_LOG") 2>&1
printf '\n===== %s stage=%s out=%s =====\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STAGE" "$OUT" >> "$BUILD_LOG"
finish_release() {
    local s=$?
    trap - EXIT
    printf '%s\n' "$s" > "$OUT/build.exit"
    (( s == 0 )) && return 0
    # A failed round must not look releasable to the next pair of hands, or to a
    # script globbing build/*-r*/: say so inside the directory, with the reason.
    {
        printf 'STAGE %s FAILED rc=%s at %s\n' "$STAGE" "$s" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'This directory is not a release. No stage gate passed, so nothing here\n'
        printf 'may be packaged, deployed or flashed. See logs/release.log and gates/.\n'
    } > "$OUT/NOT_DEPLOYABLE"
    printf 'stage=%s rc=%s\n' "$STAGE" "$s" > "$OUT/gates/stage-failure.txt"
    printf '\nSTAGE %s FAILED rc=%s (see %s)\n' "$STAGE" "$s" "$BUILD_LOG" >&2
    printf 'NOT_DEPLOYABLE recorded in %s\n' "$OUT" >&2
    exit "$s"
}
trap finish_release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- implementation-effort knobs --------------------------------------------
# capture_clk_300m is a placement/routing margin problem (the 2026-11-11 attempt
# missed it by -0.116 ns / TNS -4.956 ns over 79 endpoints, worst path 77 % route
# delay across 9 logic levels). Effort knobs are how it was closed; they are not
# a gate relaxation and they are recorded in the release provenance.
: "${SC7F0_PLACE_DIRECTIVE:=Explore}"
: "${SC7F0_PHYS_OPT_DIRECTIVE:=AggressiveExplore}"
: "${SC7F0_ROUTE_DIRECTIVE:=Explore}"
: "${SC7F0_POST_ROUTE_PHYS_OPT:=AggressiveExplore}"
export SC7F0_PLACE_DIRECTIVE SC7F0_PHYS_OPT_DIRECTIVE SC7F0_ROUTE_DIRECTIVE SC7F0_POST_ROUTE_PHYS_OPT
# The release flow is strict, always. Anything else is rejected by the hardware
# stage as well; repeating it here keeps the intent legible.
export SC7F0_ENABLE_VCU=1 SC7F0_TIMING_GATE=strict SC7F0_RELEASE_FLOW=1

# No resume. A release round starts from a fresh synthesis of the bytes it names,
# or it is not a release round. scripts/impl_sc7f0_dual_video.tcl honours
# SC7F0_IMPL_RESUME=postroute (that is how a debugging round reuses a DCP), and the
# version-identity fingerprint check would usually catch the mismatch afterwards -
# "usually" is not a release rule, and leaving the knob wired made the entry point
# look like it supported resuming. Refuse it where the release is launched.
if [[ -n ${SC7F0_IMPL_RESUME:-} ]]; then
    {
        printf 'REFUSING SC7F0_IMPL_RESUME=%s: a release round runs fresh synthesis' "$SC7F0_IMPL_RESUME"
        printf ' -> route -> strict gate -> matching PS -> package from the sources its\n'
        printf ' identity names. scripts/impl_sc7f0_dual_video.tcl keeps the resume knob\n'
        printf ' for diagnostics on a DCP; that path cannot produce this release and must\n'
        printf ' not be reachable from here.\n'
    } >&2
    exit 1
fi

run_do() { printf '\n$ %s\n' "$*"; "$@"; }

# Which suites each stage must actually have executed. scripts
# /sc7f0_release_tests.py turns a required test that was skipped, or never collected,
# into REQUIRED_TEST_NOT_EXECUTED and a FAIL verdict - "0 unexpected failures" was
# never the same statement as "the gate ran" (13 routed-profile mutations, 3 capture
# mutations and 9 device-tree tests were silently skipped while the suite printed OK).
# The R6-pinned audit (test_sc7f0_routed_profile_mutations, whose baseline is the
# 26102702 frozen SHA set) is deliberately NOT required here: resurrecting a pinned
# old-profile byte comparison as this round's gate would grade a new profile with an
# old round's numbers. The equivalent protection for this profile is
# test_sc7f0_two_layer_gates + test_sc7f0_release_package, which run always.
REQUIRED_TESTS_PREFLIGHT=test_sc7f0_release_package,test_sc7f0_fit_rootfs,test_sc7f0_impl_identity,test_sc7f0_timing_state,test_sc7f0_csr_wrapper,test_package_sc7f0_upgrade,test_sc7f0_stop_token_driver,test_sc7f0_two_layer_gates,test_sc7f0_reset_probe_structure,test_sc7f0_capture_gray_constraints,test_sc7f0_ps_runtime_sources,test_sc7f0_backup_retention
REQUIRED_TESTS_FPGA=test_sc7f0_hdmi_dt,test_sc7f0_capture_gray_constraints
REQUIRED_TESTS_PACKAGE=test_sc7f0_release_package,test_package_sc7f0_upgrade,test_sc7f0_fit_rootfs,test_sc7f0_ps_runtime_sources,test_sc7f0_backup_retention,test_sc7f0_stop_token_driver

# No stage may run on a source tree that drifted from the identity it declares.
# Without this, editing a build script after preflight would let a bitstream be
# shipped under a fingerprint that describes some other tree.
#
# The scopes freeze at different moments on purpose: the FPGA scope (rtl,
# constraints, IP/implementation Tcl) must be identical to what preflight hashed
# before a multi-hour run starts, while the PS/daemon/packaging scope is still
# under repair during that run. The PS scope therefore gets its own recorded
# fingerprint when the PS stage begins ($OUT/ps/identity-ps.json), which the
# package stage then re-verifies. Nothing is checked against a stale value.
verify_identity_current() {
    local scope=$1 file=${2:-"$OUT/identity.json"}
    run_do python3 scripts/sc7f0_release_id.py --scope "$scope" \
        --check-fingerprint "$file" --exclude "$OUT" --known-version "$(cat "$OUT/VERSION")"
}

# ---------------------------------------------------------------------------
# Stage: preflight - identity, source snapshot, local tests.
# ---------------------------------------------------------------------------
stage_preflight() {
    local idargs=(--out "$OUT/identity.json" --exclude "$OUT")
    [[ -n "$VERSION" ]] && idargs+=(--version "$VERSION")
    local k
    for k in ${KNOWN[@]+"${KNOWN[@]}"}; do idargs+=(--known-version "$k"); done
    # The package currently on the test host may not be rebuilt under the same
    # number by accident; the operator passes it in with --known-version.
    run_do python3 scripts/sc7f0_release_id.py "${idargs[@]}"
    python3 - "$OUT/identity.json" <<'PY'
import json, sys
from pathlib import Path
i = json.loads(Path(sys.argv[1]).read_text())
for k in ('version', 'date', 'iso', 'git_register_value', 'git_register_source',
          'source_fingerprint_sha256', 'worktree_dirty', 'git_head'):
    assert k in i, k
print('IDENTITY', i['version'], i['date'], 'register', i['git_register_value'],
      '(' + i['git_register_source'] + ')', 'head', i['git_head'][:8],
      'dirty', i['worktree_dirty'])
PY
    cp "$OUT/identity.json" "$OUT/logs/identity.json"

    # Traceable snapshot of every input that can change a bit, a rootfs or the
    # upgrade tooling - including untracked files, which is where a "fix" that
    # is not in git tends to hide.
    python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
out.joinpath('VERSION').write_text(json.loads((out/'identity.json').read_text())['version'] + '\n')
PY
    git ls-files -co --exclude-standard -- rtl constraints include test_app scripts tb \
        driver petalinux/qpcie-zu4ev/project-spec | sort > "$OUT/SOURCE.files"
    xargs -a "$OUT/SOURCE.files" -d '\n' sha256sum > "$OUT/SOURCE.sha256"
    # Three manifests, three different claims, all computed from the SAME list the
    # release identity hashed (scripts/sc7f0_release_id.py owns both the file set and
    # the globs, so the build script cannot quietly keep a shorter list):
    #   SOURCE.sha256            everything, untracked included
    #   SOURCE_FPGA.sha256       bytes that shape the bitstream + the checkers/policy
    #                            that grade the round (must stay byte-identical)
    #   SOURCE_VALIDATION.sha256 host-side evidence: XSim runners, testbenches, the
    #                            tests that prove the gate bites. Never synthesised,
    #                            never omittable.
    python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, 'scripts')
import sc7f0_release_id as rid
out = Path(sys.argv[1])
lines = out.joinpath('SOURCE.sha256').read_text().splitlines()
table = {}
for line in lines:
    digest, name = line.split('  ', 1)
    table[name] = line
names = sorted(table)


def write(manifest: str, globs, label: str) -> None:
    keep = sorted(n for n in names if rid.matches_globs(n, globs))
    assert keep, f'no {label} inputs matched the manifest'
    out.joinpath(manifest).write_text('\n'.join(table[n] for n in keep) + '\n')
    print(f'{label.upper()}_INPUT_MANIFEST {len(keep)} files -> {manifest}')


write('SOURCE_FPGA.sha256', rid.FPGA_INPUT_GLOBS, 'fpga')
write('SOURCE_VALIDATION.sha256', rid.VALIDATION_SOURCE_GLOBS, 'validation')
# The declared required inputs must be reachable through one of the manifests.
# Dropping a checker or a testbench from every manifest is how a build/checker input
# gets excluded so that editing it later looks like harmless tooling drift.
covered = set()
for manifest in ('SOURCE_FPGA.sha256', 'SOURCE_VALIDATION.sha256'):
    covered |= {l.split('  ', 1)[1] for l in out.joinpath(manifest).read_text().splitlines()}
for scope in ('fpga', 'ps', 'validation'):
    missing = [n for n in rid.REQUIRED_SOURCE_FILES[scope]
               if n not in names or n not in covered]
    assert not missing, (f'required {scope} inputs are absent from the worktree or from '
                         f'every role manifest (which is how an input is hidden from the '
                         f'drift classifier): ' + ', '.join(missing))
# The snapshot is a superset of the identity file set by design: it also hashes
# petalinux/.../project-spec/configs, which petalinux-build itself rewrites (the
# identity excludes it on purpose; scripts/sc7f0_source_drift.py separates the two
# so a policy exclusion is never mistaken for a removed input).
assert set(names) >= set(rid.scope_files(Path('.'), 'all')), (
    'the snapshot list is missing files the release identity hashed')
print(f'REQUIRED_INPUTS_COVERED {len(names)} snapshot files, '
      f'{len(covered)} role-tagged')
PY
    test -s "$OUT/SOURCE_FPGA.sha256"
    test -s "$OUT/SOURCE_VALIDATION.sha256"
    tar -czf "$OUT/source-snapshot.tar.gz" -T "$OUT/SOURCE.files"
    sha256sum "$OUT/source-snapshot.tar.gz" > "$OUT/source-snapshot.tar.gz.sha256"
    echo "SNAPSHOT $(wc -l < "$OUT/SOURCE.files") files ($(wc -l < "$OUT/SOURCE_FPGA.sha256") FPGA inputs), $(du -h "$OUT/source-snapshot.tar.gz" | cut -f1)"

    # Local gates first: a cheap failure beats hours of Vivado. Each later stage
    # syntax-checks the tools it owns, so a not-yet-written PS/package helper can
    # never block the long hardware run and can never skip its own check either.
    run_do python3 scripts/generate_sc7f0_csr_cdc.py --check
    run_do python3 -m py_compile scripts/sc7f0_release_id.py scripts/check_sc7f0_timing.py \
        scripts/sc7f0_review_policy.py scripts/sc7f0_release_tests.py \
        scripts/sc7f0_source_drift.py scripts/sc7f0_review_policy.py \
        scripts/resolve_recipe_install_output.py scripts/package_sc7f0_rootfs.py \
        scripts/check_sc7f0_release_package.py scripts/check_sc7f0_capture_image.py \
        scripts/check_sc7f0_ps_build_integrity.py scripts/accept_sc7f0_vcu_hardware.py \
        scripts/check_sc7f0_vcu_delta.py scripts/audit_sc7f0_cdc_delta.py \
        scripts/check_sc7f0_memory_layout.py
    bash -n scripts/build_sc7f0_vcu_release.sh scripts/build_sc7f0_dual_video_hw.sh \
        scripts/build_sc7f0_matching_ps_vcu.sh scripts/package_sc7f0_vcu_release.sh \
        scripts/package_zu4ev_bootbin.sh scripts/inject_upgrade_daemon_to_image_ub.sh \
        scripts/install_debug_rootfs.sh scripts/install_sc7f0_watchdog_rootfs.sh \
        scripts/run_sc7f0_reset_probe_validation.sh scripts/check_sc7f0_probe_tap_mutation.sh
    # The Layer B policies are code: they must at least be valid JSON with the
    # schema the gate expects, and the evidence hook must be complete Tcl. Failing
    # here is free; finding out after a route is not.
    python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'scripts')
import sc7f0_review_policy as review
for name, kind in (('sc7f0_cdc_review.json', 'cdc'), ('sc7f0_drc_review.json', 'drc'),
                   ('sc7f0_clock_pair_review.json', 'clock_pair')):
    policy = review.load_policy(Path('scripts/gates') / name, kind)
    print(f'POLICY_OK {name} kind={kind} items={len(policy["items"])}')
PY
    for tcl in scripts/check_sc7f0_named_constraints.tcl scripts/impl_sc7f0_dual_video.tcl \
               scripts/check_sc7f0_capture_gray.tcl scripts/build_zu4ev.tcl; do
        if printf 'set f [open %s r]; set t [read $f]; close $f; if {![info complete $t]} {puts {TCL_SYNTAX_INCOMPLETE}}; exit 0\n' "$tcl" \
                | tclsh | grep -q TCL_SYNTAX_INCOMPLETE; then
            echo "TCL_SYNTAX_INCOMPLETE $tcl" >&2
            exit 1
        fi
    done
    echo 'TCL_PARSE_OK'
    python3 - <<'PY'
from pathlib import Path
import ast
for py in ('scripts/sc7f0_release_id.py', 'scripts/check_sc7f0_timing.py',
           'scripts/sc7f0_review_policy.py',
           'scripts/check_sc7f0_vcu_delta.py', 'scripts/audit_sc7f0_cdc_delta.py'):
    ast.parse(Path(py).read_text(), filename=py)
print('LOCAL_SYNTAX_PASS (fpga stage tools)')
PY
    PYTHONDONTWRITEBYTECODE=1 run_do python3 scripts/sc7f0_release_tests.py \
        --out "$OUT/gates/unit-tests.json" --require-run "$REQUIRED_TESTS_PREFLIGHT"
    printf 'SC7F0_PREFLIGHT_PASS\n' > "$OUT/gates/preflight.ok"
}

# ---------------------------------------------------------------------------
# Stage: fpga - real synthesis + implementation, strict gate, byte-matched XSA.
# ---------------------------------------------------------------------------
stage_fpga() {
    : "${XILINXD_LICENSE_FILE:?Set the operator-provided Vivado license endpoint}"
    verify_identity_current fpga
    [[ -f "$OUT/identity.json" && -f "$OUT/gates/preflight.ok" ]] || {
        echo 'run --stage preflight first' >&2; exit 1; }
    local proj=${FPGA_PROJECT:-"$OUT/fpga/project"}
    export SC7F0_VERSION SC7F0_GIT_HASH SC7F0_BUILD_DATE SC7F0_GIT_HASH_SOURCE SC7F0_SOURCE_FINGERPRINT
    SC7F0_VERSION=$(python3 -c "import json;print(json.load(open('$OUT/identity.json'))['version'])")
    SC7F0_GIT_HASH=$(python3 -c "import json;print(json.load(open('$OUT/identity.json'))['git_register_value'])")
    SC7F0_BUILD_DATE=$(python3 -c "import json;print(json.load(open('$OUT/identity.json'))['date'])")
    SC7F0_GIT_HASH_SOURCE=$(python3 -c "import json;print(json.load(open('$OUT/identity.json'))['git_register_source'])")
    SC7F0_SOURCE_FINGERPRINT=$(python3 -c "import json;print(json.load(open('$OUT/identity.json'))['source_fingerprint_sha256'])")
    echo "FPGA identity: C_VERSION=0x$SC7F0_VERSION GIT=0x$SC7F0_GIT_HASH DATE=$SC7F0_BUILD_DATE source=$SC7F0_GIT_HASH_SOURCE"
    run_do bash scripts/build_sc7f0_dual_video_hw.sh "$proj"
    cp "$proj/hardware.xsa" "$OUT/fpga/hardware.xsa"
    cp "$proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.bit" "$OUT/fpga/zu4ev_pcie_card_top.bit"
    cp "$proj/version-identity.json" "$OUT/fpga/version-identity.json"
    cp "$proj/timing-gate-record.json" "$OUT/gates/timing-gate-record.json"
    # Every report the two-layer gate reads must be present, or the gate would
    # silently lose an input (the historical failure mode: no drc.rpt at all).
    for r in timing_summary check-timing cdc bus-skew methodology utilization_routed_hierarchical \
             exceptions-coverage exceptions-all exceptions-ignored exceptions-scope-override \
             exceptions-summary drc io clock-interaction clock-networks disable-timing-user \
             c2h-personality ip_status; do
        [[ -f "$proj/$r.rpt" ]] || { echo "fpga report $r.rpt was never produced" >&2; exit 1; }
        cp "$proj/$r.rpt" "$OUT/fpga/"
    done
    [[ -f "$proj/named-constraint-evidence.json" ]] || {
        echo 'named-constraint coverage manifest is missing: Layer B has no inputs' >&2; exit 1; }
    cp "$proj/named-constraint-evidence.json" "$OUT/fpga/named-constraint-evidence.json"
    # Keep the review policy that produced the verdict next to the verdict, so a
    # later reader can tell which claims were made and cannot re-grade old
    # reports with today's policy. The validator module is part of that policy:
    # changing how a requirement is checked changes the verdict as much as
    # editing a status field would.
    mkdir -p "$OUT/gates/policy"
    cp scripts/gates/sc7f0_cdc_review.json scripts/gates/sc7f0_drc_review.json \
       scripts/gates/sc7f0_clock_pair_review.json "$OUT/gates/policy/"
    cp scripts/sc7f0_review_policy.py "$OUT/gates/policy/sc7f0_review_policy.py"
    (cd scripts/gates && sha256sum sc7f0_cdc_review.json sc7f0_drc_review.json \
        sc7f0_clock_pair_review.json) > "$OUT/gates/policy.sha256"
    sha256sum scripts/sc7f0_review_policy.py | sed 's# .*#  sc7f0_review_policy.py#' \
        >> "$OUT/gates/policy.sha256"
    cp -f "$proj"-logs/*.log "$proj"-logs/*.sha256 "$proj"-logs/*.txt "$OUT/logs/" 2>/dev/null || true
    python3 scripts/check_sc7f0_timing.py "$OUT/fpga" \
        --policies="$OUT/gates/policy" > "$OUT/gates/timing-gate-recheck.json"
    python3 - "$OUT" <<'PY'
import hashlib, json, sys
from pathlib import Path
from zipfile import ZipFile
out = Path(sys.argv[1])
gate = json.loads((out / 'gates/timing-gate-recheck.json').read_text())
assert gate['pass_gate'] is True, gate['errors']
ident = json.loads((out / 'fpga/version-identity.json').read_text())
want = json.loads((out / 'identity.json').read_text())
assert ident['c_version'] == '0x' + want['version'], (ident, want)
assert ident['source_fingerprint_sha256'] == want['source_fingerprint_sha256'], \
    'the built design carries a different source fingerprint than this release declares'
bit = (out / 'fpga/zu4ev_pcie_card_top.bit').read_bytes()
with ZipFile(out / 'fpga/hardware.xsa') as z:
    names = [n for n in z.namelist() if n.endswith('.bit')]
    assert len(names) == 1 and z.read(names[0]) == bit, 'XSA/bit byte drift'
(out / 'fpga/HARDWARE.sha256').write_text(
    ''.join(f'{hashlib.sha256((out/"fpga"/n).read_bytes()).hexdigest()}  {n}\n'
            for n in ('hardware.xsa', 'zu4ev_pcie_card_top.bit')))
(out / 'gates/fpga.ok').write_text('SC7F0_FPGA_STAGE_PASS\n')
print('FPGA_STAGE_PASS', ident['c_version'], 'WNS', gate['margins_ns']['WNS'],
      'bit', hashlib.sha256(bit).hexdigest()[:16])
PY
    (cd "$ROOT" && sha256sum --quiet -c "$OUT/SOURCE_FPGA.sha256") \
        > "$OUT/logs/source-fpga-check-after-build.log"
    # The device-tree/IP consistency checks can only be judged against the IP of
    # the build that just finished, so they run here and are required to execute.
    local ipd="$proj/qpcie_zu4ev_card.srcs/sources_1/ip"
    if [[ -d $ipd ]]; then
        SC7F0_TEST_XCI_DIR="$ipd" \
        SC7F0_TEST_DTC="${SC7F0_TEST_DTC:-/opt/Xilinx/Vitis/2023.2/bin/dtc}" \
            run_do python3 scripts/sc7f0_release_tests.py \
                --out "$OUT/gates/unit-tests-after-fpga.json" \
                --require-run "$REQUIRED_TESTS_FPGA"
    else
        echo "generated IP directory missing under $proj; device-tree checks cannot be judged" >&2
        exit 1
    fi
    echo "FPGA inputs are byte-identical to the release snapshot: $OUT/SOURCE_FPGA.sha256"
    echo "FPGA stage complete: $OUT/fpga"
}

# ---------------------------------------------------------------------------
# Stage: ps - acceptance record from this build, then the matching PS image.
# ---------------------------------------------------------------------------
stage_ps() {
    mkdir -p "$OUT/ps"
    local psid="$OUT/ps/identity-ps.json"
    if [[ -e $psid ]]; then
        echo "$psid already exists; the PS scope is already frozen for this release" >&2
        exit 1
    fi
    # PS scope is frozen now (not at preflight): the sources it covers may still
    # have been repaired while the hardware stage ran.
    run_do python3 scripts/sc7f0_release_id.py --scope ps --out "$psid" \
        --version "$(cat "$OUT/VERSION")" --exclude "$OUT" \
        --known-version "$(cat "$OUT/VERSION")" --known-version 26111101 \
        --known-version 26110301 --known-version 26111001
    run_do verify_identity_current ps "$psid"
    PS_LOGS=${PS_LOGS:-"$OUT/ps/build-$(date -u +%Y%m%dT%H%M%SZ)"}
    local acc=${SC7F0_HARDWARE_ACCEPTANCE_DIR:-"$OUT/fpga/hardware-acceptance"}
    if [[ ! -d $acc ]]; then
        run_do python3 scripts/accept_sc7f0_vcu_hardware.py \
            --project "$OUT/fpga" --identity "$OUT/identity.json" \
            --gate "$OUT/gates/timing-gate-recheck.json" --out "$acc"
    fi
    # An acceptance directory handed in from outside is a claim about THIS round, so
    # it is checked against this round before a single petalinux task runs. Without
    # this, pointing SC7F0_HARDWARE_ACCEPTANCE_DIR at last week's review made the PS
    # stage bless a device tree for hardware that is not the one in $OUT/fpga - the
    # record would be real, complete, and about something else.
    run_do python3 - "$OUT" "$acc" <<'PY'
import hashlib, json, sys
from pathlib import Path
from zipfile import ZipFile
out, acc = Path(sys.argv[1]), Path(sys.argv[2])
version = out.joinpath('VERSION').read_text().strip()
ident = json.loads((out / 'identity.json').read_text())
stamped = json.loads((out / 'fpga/version-identity.json').read_text())
xsa = (out / 'fpga/hardware.xsa').read_bytes()
bit = (out / 'fpga/zu4ev_pcie_card_top.bit').read_bytes()
def sha(b): return hashlib.sha256(b).hexdigest()
for name in ('hardware.json', 'hardware.ok', 'review.json', 'REVIEW_INPUTS_OUTPUTS.sha256'):
    assert (acc / name).is_file(), f'{acc}/{name} is missing: not an acceptance directory'
hw = json.loads((acc / 'hardware.json').read_text())
errors = []
if hw.get('version') != '0x' + version:
    errors.append(f'acceptance record is for {hw.get("version")}, this release is 0x{version}')
if hw.get('xsa_sha256') != sha(xsa):
    errors.append('acceptance record was written for a different hardware.xsa')
if hw.get('bit_sha256') != sha(bit):
    errors.append('acceptance record was written for a different bitstream')
with ZipFile(out / 'fpga/hardware.xsa') as z:
    inner = [n for n in z.namelist() if n.endswith('.bit')]
    assert len(inner) == 1 and sha(z.read(inner[0])) == sha(bit), 'XSA/bit drift'
# The fingerprint, when the record carries one, is the strongest of the three: it is
# what makes "reviewed" mean "reviewed against the bytes this round froze".
recorded_fp = hw.get('source_fingerprint_sha256') or \
    json.loads((acc / 'review.json').read_text()).get('summary', {}).get('identity', {}) \
    .get('source_fingerprint_sha256')
if recorded_fp is not None and recorded_fp != ident['source_fingerprint_sha256']:
    errors.append('acceptance record names a different source fingerprint than this '
                  'release (it reviewed other sources)')
if (acc / 'hardware.ok').read_text().strip().startswith('SCOPED_VCU_REJECTED'):
    errors.append('the acceptance record is a rejection')
for name, want in (('hardware.xsa', sha(xsa)),
                   ('zu4ev_pcie_card_top.bit', sha(bit))):
    for line in (acc / 'REVIEW_INPUTS_OUTPUTS.sha256').read_text().splitlines():
        digest, _, claimed = line.partition('  ')
        if claimed.strip().endswith(name) and digest.strip() != want:
            errors.append(f'{acc.name}/REVIEW_INPUTS_OUTPUTS.sha256 does not match the '
                          f'artifacts this release carries ({name})')
assert not errors, '\n  '.join(['EXTERNAL_HARDWARE_ACCEPTANCE_DOES_NOT_BELONG_TO_THIS_ROUND:'] + errors) + \
    '\nGenerate it from this round instead: scripts/accept_sc7f0_vcu_hardware.py '\
    '--project $OUT/fpga --identity $OUT/identity.json --gate $OUT/gates/'\
    'timing-gate-recheck.json --out $OUT/fpga/hardware-acceptance'
print('HARDWARE_ACCEPTANCE_BELONGS_TO_THIS_ROUND', acc, hw['version'],
      'fingerprint', (recorded_fp or 'not recorded in the record')[:12])
PY
    run_do env SC7F0_PL_BASE_VERSION=0x$(cat "$OUT/VERSION") \
        SC7F0_SSTATE_VOLUME="${SC7F0_SSTATE_VOLUME:-sc7f0-ps-vcu-sstate}" \
        SC7F0_DOWNLOADS_VOLUME="${SC7F0_DOWNLOADS_VOLUME:-sc7f0-ps-vcu-downloads}" \
        bash scripts/build_sc7f0_matching_ps_vcu.sh "$acc" "$PS_LOGS"
    cp "$PS_LOGS/ps-artifacts.sha256" "$OUT/ps/artifacts.sha256" 2>/dev/null || true
    printf 'SC7F0_PS_STAGE_PASS\n' > "$OUT/gates/ps.ok"
    echo "PS stage complete: $PS_LOGS"
}

# ---------------------------------------------------------------------------
# Stage: package - BOOT.BIN, 4-member upgrade tar, provenance, negative tests.
# ---------------------------------------------------------------------------
stage_package() {
    verify_identity_current fpga
    verify_identity_current ps "$OUT/ps/identity-ps.json"
    [[ -f "$OUT/gates/ps.ok" ]] || { echo 'run --stage ps first' >&2; exit 1; }
    run_do env SC7F0_REQUIRED_TESTS_PACKAGE="$REQUIRED_TESTS_PACKAGE" \
        bash scripts/package_sc7f0_vcu_release.sh --out "$OUT" --ps-build "$PS_LOGS"
    printf 'SC7F0_RELEASE_PACKAGE_PASS\n' > "$OUT/package.ok"
    echo "Package complete: $OUT/release"
}

case "$STAGE" in
    preflight) stage_preflight;;
    fpga) stage_fpga;;
    ps) stage_ps;;
    package) stage_package;;
    all) stage_preflight; stage_fpga; stage_ps; stage_package;;
esac
printf '\nSC7F0_VCU_RELEASE_STAGE %s OK  release=%s\n' "$STAGE" "$OUT"
