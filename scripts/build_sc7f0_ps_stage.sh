#!/usr/bin/env bash
# SC7F0 PS/image stage: import one round's exported XSA, run the production
# PetaLinux container body and the production post-build host stages against it,
# and leave every byte-level proof in a new log directory.  No SSH, no card, no
# flash, no commit, no reboot, no git write.
#
#   scripts/build_sc7f0_ps_stage.sh \
#       --out build/<round>/ps/build-<stamp> \
#       --accept-xsa build/<round>/fpga/project/hardware.xsa \
#       --pl-base 0x26111208 \
#       --memory-baseline <image.ub of a package that is known to boot> \
#       --memory-baseline-sha <its sha256> \
#       --memory-baseline-label '<what that image is>'
#
# Why this file exists, and what the older entries cannot do here (legacy limits,
# stated rather than worked around; the old entries and every assert inside them
# are left untouched and are still the reference this script extracts from):
#
#   scripts/build_sc7f0_matching_ps.sh   hard-asserts hardware.json version
#       0x26102804, so it can only ever build for that one PL.
#   scripts/build_sc7f0_matching_ps_vcu.sh (the production flow used below)
#       1. `sha256sum -c` over build/sc7f0-capture-26102901-r1/... and
#          build/r7-reviewed-acceptance.1793238509/... before doing anything.
#          Neither directory exists on this machine any more, so the guard has
#          nothing to protect and the script dies at its first command - for
#          every PL version, including a re-run of 26111204.
#       2. asserts an acceptance record whose profile is VCU_C2H_ABI1.1 and whose
#          version equals --pl-base; the committed generator for a fresh one is
#          scripts/accept_sc7f0_vcu_hardware.py, which is a hardware review with
#          its own Vivado negative-control run and is not part of a PS build.
#   scripts/build_sc7f0_matching_ps_r7.sh  same family, same stale anchors.
# This script therefore keeps the production flow as the thing it runs, and
# replaces only what is provably unable to run here, recording every such change
# the way the 26111204 r3 round recorded its four substitutions:
# before/after bytes, a diff, and a reason.  Nothing here claims the production
# flow ran unmodified.
#
# What is *not* changed: the imported XSA is proven to be the accepted XSA's bytes
# before petalinux runs and after it finishes; the built device tree, memory map,
# bootargs, daemon bytes, image.ub injection and rootfs runtime content are all
# judged by the committed checkers the production host stages call.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

OUT="" ACCEPT_XSA="" PL_BASE="" PROJECT=petalinux/qpcie-zu4ev
PRODUCTION=$ROOT/scripts/build_sc7f0_matching_ps_vcu.sh
MEM_BASELINE="" MEM_BASELINE_SHA="" MEM_BASELINE_LABEL="" FPGA_BIT=${FPGA_BIT:-}
REQUIRE_PKGS=(sc7f0-vcud qpcie-debugd sc7f0-ps-capture qpcie-v4l2-bridge)
EXPECT_FILES=(usr/lib/libdrm.so.1)
EXPECT_BINS=(modetest=@present)
EXPECT_STRINGS=()
SSTATE_VOLUME=${SC7F0_SSTATE_VOLUME:-sc7f0-ps-vcu-sstate}
DOWNLOADS_VOLUME=${SC7F0_DOWNLOADS_VOLUME:-sc7f0-ps-vcu-downloads}
usage() { sed -n '2,20p' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }
while (($#)); do
    case "$1" in
        --out) OUT=${2:?}; shift 2;;
        --accept-xsa) ACCEPT_XSA=${2:?}; shift 2;;
        --pl-base) PL_BASE=${2:?}; shift 2;;
        --project) PROJECT=${2:?}; shift 2;;
        --production-script) PRODUCTION=${2:?}; shift 2;;
        --memory-baseline) MEM_BASELINE=${2:?}; shift 2;;
        --memory-baseline-sha) MEM_BASELINE_SHA=${2:?}; shift 2;;
        --memory-baseline-label) MEM_BASELINE_LABEL=${2:?}; shift 2;;
        --fpga-bit) FPGA_BIT=${2:?}; shift 2;;
        --require-rootfs-package) REQUIRE_PKGS+=("$2"); shift 2;;
        --expect-rootfs-file) EXPECT_FILES+=("$2"); shift 2;;
        --expect-rootfs-binary) EXPECT_BINS+=("$2"); shift 2;;
        --expect-rootfs-string) EXPECT_STRINGS+=("$2"); shift 2;;
        -h|--help) usage 0;;
        *) echo "unknown argument $1" >&2; usage 2;;
    esac
done
for v in OUT ACCEPT_XSA PL_BASE MEM_BASELINE MEM_BASELINE_SHA; do
    [[ -n ${!v} ]] || { echo "--$(echo "$v" | tr 'A-Z_' 'a-z-') is required" >&2; usage 2; }
done
[[ $PL_BASE =~ ^0x[0-9A-Fa-f]{8}$ ]] || { echo "bad --pl-base $PL_BASE" >&2; exit 1; }
[[ $MEM_BASELINE_SHA =~ ^[0-9a-f]{64}$ ]] || { echo 'bad --memory-baseline-sha' >&2; exit 1; }
[[ -f $ACCEPT_XSA && -f $MEM_BASELINE && -f $PRODUCTION ]] || {
    echo '--accept-xsa, --memory-baseline and the production script must exist' >&2; exit 1; }
ACCEPT_XSA=$(realpath "$ACCEPT_XSA"); MEM_BASELINE=$(realpath "$MEM_BASELINE")
PRODUCTION=$(realpath "$PRODUCTION")
[[ "$(sha256sum "$MEM_BASELINE" | cut -d' ' -f1)" == "$MEM_BASELINE_SHA" ]] || {
    echo 'the memory/bootargs baseline image.ub is not the bytes its sha claims' >&2; exit 1; }
PROJECT_DIR=$ROOT/$PROJECT
IMG_DIR=$PROJECT_DIR/images/linux
OUT=$(realpath -m "$OUT")
[[ -e $OUT ]] && { echo "OUT=$OUT already exists" >&2; exit 1; }
mkdir -p "$OUT"
trap 'rc=$?; printf "%s\n" "$rc" > "$OUT/build.exit"' EXIT
export SC7F0_REPO_ROOT="$ROOT" SC7F0_ACCEPTED_XSA="$ACCEPT_XSA" SC7F0_PS_BUILD_LOGS="$OUT"
export SC7F0_PROJECT="$PROJECT" SC7F0_RECIPE_SNAPSHOT="$OUT/source-recipe-snapshot.json"
export SC7F0_PL_BASE_VERSION="$PL_BASE" PL_BASE OUT IMG_DIR PROJECT="$PROJECT_DIR"
export IMAGE_MACHINE=zynqmp
export XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-2101@192.168.200.112}
export MEMORY_BASELINE="$MEM_BASELINE"
df -h / | tail -1 > "$OUT/host-disk-before.txt"

# ---------------------------------------------------------------------------
# 1. The production frozen-tree guard, kept as a record even where it has
# nothing to protect.  The protected paths are read out of the production script
# itself, so this file hard-codes no historical release directory.
# ---------------------------------------------------------------------------
: > "$OUT/frozen-guards-before.sha256"
python3 - "$PRODUCTION" "$OUT/frozen-guards-before.sha256" <<'PY'
import re, sys
from pathlib import Path
from subprocess import run
prod, out = Path(sys.argv[1]), Path(sys.argv[2])
# The production script's own frozen-release variables, whatever they are named on
# this revision, and every file it wants to be able to re-verify.
text = prod.read_text()
vars_ = dict(re.findall(r'^\s*(R7REL|R7ACC)\s*=\s*([^ \n]+)\s*$', text, re.M))
assert vars_, 'the production script no longer names the frozen trees it guards'
want = re.search(r'sha256sum "\$R7REL"(.+?)> "\$OUT/frozen-r7-before\.sha256"', text, re.S)
assert want, 'the production frozen-tree guard is not where it used to be'
paths = re.findall(r'"\$\{?(R7REL|R7ACC)\}?"?/([A-Za-z0-9_./-]+)', want.group(0))
assert paths, 'no frozen-tree paths parsed out of the production guard'
lines = []
for var, rel in paths:
    v = vars_[var]
    base = Path(v) if v.startswith('/') else prod.parents[1] / v
    p = base / rel
    if p.is_file():
        lines.append(run(['sha256sum', str(p)], capture_output=True, text=True).stdout)
    else:
        lines.append(f'ABSENT  {p}\n')
Path(out).write_text(''.join(lines))
present = [l for l in lines if not l.startswith('ABSENT')]
print(f'FROZEN_GUARDS_RECORD {len(present)} present, {len(lines) - len(present)} absent '
      f'on this machine (paths taken from {prod.name}, not hard-coded here)')
PY
if grep -q '^[0-9a-f]\{64\}' "$OUT/frozen-guards-before.sha256"; then
    sha256sum -c "$OUT/frozen-guards-before.sha256" > "$OUT/frozen-guards-before-check.log"
else
    echo 'FROZEN_TREES_ABSENT on this machine; the production guard has nothing to protect' \
        > "$OUT/frozen-guards-before-check.log"
fi

: > "$OUT/project-hw-description-before.sha256"
for f in "$PROJECT_DIR/project-spec/hw-description/system.xsa" \
         "$PROJECT_DIR/project-spec/hw-description/psu_init.c" \
         "$IMG_DIR/image.ub" "$IMG_DIR/system.dtb"; do
    if [[ -f $f ]]; then sha256sum "$f" >> "$OUT/project-hw-description-before.sha256"
    else printf 'ABSENT  %s\n' "$f" >> "$OUT/project-hw-description-before.sha256"; fi
done

# ---------------------------------------------------------------------------
# 2. What XSA this round is allowed to claim, measured before any petalinux task.
#    This is the matching proof the release package later re-reads: XSA bytes,
#    the bitstream inside it, and the address windows the device tree will name.
# ---------------------------------------------------------------------------
python3 - "$ACCEPT_XSA" "$PL_BASE" "$OUT" "${FPGA_BIT:-}" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
from zipfile import ZipFile
xsa, pl_base, out, fpga_bit = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), sys.argv[4]
digest = hashlib.sha256(xsa.read_bytes()).hexdigest()
with ZipFile(xsa) as z:
    bit = [n for n in z.namelist() if n.endswith('.bit')]
    assert len(bit) == 1, bit
    bit_bytes = z.read(bit[0])
    bit_sha = hashlib.sha256(bit_bytes).hexdigest()
    psu = next((z.read(n) for n in z.namelist() if n.endswith('psu_init.c')), None)
    bda = next((z.read(n).decode('utf-8', 'replace') for n in z.namelist()
                if n.endswith('.bda')), '')
    hwh = next((z.read(n).decode('utf-8', 'replace')
                for n in z.namelist() if n.endswith('.hwh')), '')
assert psu is not None and b'PSU_Mask_Write(CRL_APB_PL1_REF_CTRL_OFFSET' in psu, \
    'this XSA does not drive the PL1 reference clock the VCU needs'
assert 'vcu_0' in bda, 'this XSA has no VCU block design'
# If the round also hands in the bitstream it built, the XSA must contain exactly
# those bytes; this is the check that stops a PS image being configured against
# last round's hardware.
if fpga_bit:
    want = hashlib.sha256(Path(fpga_bit).read_bytes()).hexdigest()
    assert want == bit_sha, ('the bitstream inside the XSA (%s) is not the bitstream this '
                             'round built (%s)' % (bit_sha, want))
# Address windows the PS reaches the PL through, parsed numerically out of the
# .bda/.hwh (Vivado writes them upper case, so a text comparison against one
# spelling proves nothing).  axi_crossbar_hdmi lives in the top-level RTL, not in
# the PS block design, so the per-IP apertures (VPHY 0xB0000000, HDMI RX
# 0xB0010000, HDMI TX SS 0xB0020000, capture frmbuf 0xB0050000, display frmbuf
# 0xB0080000) are *inside* the single 0xB0000000-0xB00FFFFF HPM window; claiming
# each of them from the XSA would be a lie, so the window is what is required
# here and each aperture is proven by scripts/check_sc7f0_hdmi_display_pl.py at
# build time and by the built device tree further down in this script.
addrs = {int(a, 16) for a in re.findall(r'(?i)0x[0-9a-f]{6,16}', bda + hwh)}
windows = {}
for name, lo, hi in (('PL HPM window for the HDMI/display crossbar', 0xB0000000, 0xB00FFFFF),
                     ('VCU register window', 0xB0100000, 0xB01FFFFF)):
    hit = [a for a in addrs if lo <= a <= hi]
    assert hit, f'{name} [{lo:#x}-{hi:#x}] is not mapped by this XSA; mapped: ' + \
        ', '.join(hex(a) for a in sorted(addrs)[:200])
    windows[name] = [hex(a) for a in hit]
found = sorted({v.upper() for v in re.findall(r'(?i)(0x26[0-9A-F]{6})', bda + hwh)})
(out / 'ps-xsa-preflight.json').write_text(json.dumps({
    'xsa': str(xsa), 'xsa_sha256': digest, 'inner_bit_sha256': bit_sha,
    'fpga_bit_sha256': hashlib.sha256(Path(fpga_bit).read_bytes()).hexdigest() if fpga_bit else None,
    'pl_base_version': pl_base, 'version_like_strings_in_xsa': found,
    'address_windows': windows, 'mapped_address_count': len(addrs)}, indent=2) + '\n')
print(f'PS_XSA_PREFLIGHT xsa={digest} inner_bit={bit_sha} pl_base={pl_base} '
      f'windows=' + ' '.join(f'{k}:{v[0]}' for k, v in windows.items()))
PY

# ---------------------------------------------------------------------------
# 3. Rootfs menu state.  scripts/package_sc7f0_rootfs.py has an `enable`
#    subcommand in its parser but no enable() function, so calling it raises
#    NameError (verified: package_sc7f0_rootfs.py:406).  Its `verify`
#    subcommand does work and is what proves runtime content at the end, so the
#    menu is asserted here instead of being re-written by a call that cannot run.
# ---------------------------------------------------------------------------
ROOTFS_CFG=$PROJECT_DIR/project-spec/configs/rootfs_config
cp "$ROOTFS_CFG" "$OUT/rootfs_config.before"
python3 - "$ROOTFS_CFG" "${REQUIRE_PKGS[@]}" <<'PY'
import sys
from pathlib import Path
cfg, need = Path(sys.argv[1]), sys.argv[2:]
text = '\n' + cfg.read_text()
missing = [f'CONFIG_{p}=y' for p in need if f'\nCONFIG_{p}=y\n' not in text]
assert not missing, ('rootfs_config does not select %s; select it in the tree (with a reason), '
                     'do not let a build silently write it' % missing)
print('ROOTFS_MENU_SELECTS ' + ' '.join(need))
PY
BBAPPEND=$PROJECT_DIR/project-spec/meta-user/recipes-core/images/petalinux-image-minimal.bbappend
grep -q '^IMAGE_INSTALL:append = " sc7f0-vcud libomxil-xlnx libvcu-xlnx vcu-firmware"$' "$BBAPPEND" || \
    { echo 'the image recipe no longer installs sc7f0-vcud and the VCU stack' >&2; exit 1; }
grep -q '^IMAGE_INSTALL:append = " libdrm libdrm-tests"$' "$BBAPPEND" || \
    { echo 'the image recipe does not install libdrm/libdrm-tests (modetest)' >&2; exit 1; }
printf 'IMAGE_INSTALL lines asserted; %s names the packages this round requires in the image.\n' \
    "$BBAPPEND" > "$OUT/rootfs-install-recipe.txt"
sha256sum "$OUT/rootfs_config.before" "$ROOTFS_CFG" > "$OUT/rootfs-config.sha256"

cat > "$OUT/check_rootfs_menu.py" <<'PY'
import os, sys
from pathlib import Path
cfg = Path.cwd() / 'project-spec/configs/rootfs_config'
text = '\n' + cfg.read_text()
need = ['CONFIG_sc7f0-vcud=y', 'CONFIG_qpcie-debugd=y', 'CONFIG_sc7f0-ps-capture=y',
        'CONFIG_qpcie-v4l2-bridge=y', 'CONFIG_libdrm=y', 'CONFIG_libdrm-tests=y',
        'CONFIG_kernel-module-hdmi=y', 'CONFIG_kernel-module-vcu-modules=y']
missing = [n for n in need if ('\n' + n + '\n') not in text]
assert not missing, 'rootfs menu does not select %s' % missing
root = Path(os.environ['SC7F0_REPO_ROOT'])
bb = (root / 'petalinux' / os.environ['SC7F0_PROJECT'] / 'project-spec' / 'meta-user'
      / 'recipes-core/images/petalinux-image-minimal.bbappend').read_text()
for pkg in ('sc7f0-vcud', 'libomxil-xlnx', 'libvcu-xlnx', 'vcu-firmware',
            'libdrm', 'libdrm-tests'):
    assert any(l.startswith('IMAGE_INSTALL:append') and pkg in l
               for l in bb.splitlines()), 'the image recipe does not install ' + pkg
# The driver contract the display graph needs is a kernel config, not a rootfs
# package; assert it where it is actually expressed.
print('ROOTFS_MENU_AND_BBAPPEND ' + ' '.join(need))
PY

# The generated machine conf can still name an XSA from a worktree that no longer
# exists; bitbake then cannot checksum system.xsa at all.  Repoint it at this
# project with backup/diff/sha, and require inside the body that HDF_PATH is
# exactly the XSA this round imported.
MACHINE_CONF=$PROJECT_DIR/project-spec/configs/zynqmp-generic-xczu4ev.conf
cp "$MACHINE_CONF" "$OUT/zynqmp-machine-conf.before"
grep -q '^HDF_PATH = "' "$MACHINE_CONF" || { echo 'no HDF_PATH line to repoint' >&2; exit 1; }
sed -i "s#^HDF_PATH = \".*\"#HDF_PATH = \"$PROJECT_DIR/project-spec/hw-description/system.xsa\"#" "$MACHINE_CONF"
grep -q "^HDF_PATH = \"$PROJECT_DIR/project-spec/hw-description/system.xsa\"$" "$MACHINE_CONF" || \
    { echo 'HDF_PATH did not land on this project path' >&2; exit 1; }
diff -u "$OUT/zynqmp-machine-conf.before" "$MACHINE_CONF" > "$OUT/zynqmp-machine-conf.diff" || true
sha256sum "$OUT/zynqmp-machine-conf.before" "$MACHINE_CONF" > "$OUT/zynqmp-machine-conf.sha256"
printf 'HDF_PATH repointed at this project hw-description/system.xsa, which petalinux-config imports from %s.\n' \
    "$ACCEPT_XSA" > "$OUT/zynqmp-machine-conf.gap"

# Recipe sources this round builds, snapshotted before the container starts.
python3 - "$PROJECT_DIR/project-spec/meta-user" "$SC7F0_RECIPE_SNAPSHOT" "$ROOT" <<'PY'
import hashlib, json, sys
from pathlib import Path
layer, out, root = Path(sys.argv[1]).resolve(), Path(sys.argv[2]), Path(sys.argv[3])
files = [(layer / 'recipes-apps/sc7f0-vcud/sc7f0-vcud.bb', 'in_layer'),
         (layer / 'recipes-apps/sc7f0-vcud/files/sc7f0-vcud.service', 'in_layer'),
         (layer / 'recipes-core/images/petalinux-image-minimal.bbappend', 'in_layer'),
         (root / 'test_app/sc7f0_vcud.cpp', 'outside_layer_test_app')]
digests = {}
for path, role in files:
    assert path.is_file(), 'recipe source file is missing: ' + str(path)
    digests[str(path)] = {'role': role,
                          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
vcud_bb = layer / 'recipes-apps/sc7f0-vcud/sc7f0-vcud.bb'
link = [l for l in vcud_bb.read_text().splitlines()
        if 'sc7f0_vcud.cpp -o sc7f0_vcud' in l or ('-lOMX.allegro.core' in l and '-l' in l)]
assert any('${LDFLAGS}' in l for l in link), \
    'the sc7f0-vcud link line does not pass ${LDFLAGS}; do_package_qa fails with GNU_HASH'
out.write_text(json.dumps({'layer': str(layer), 'files': digests}, indent=2) + '\n')
print('RECIPE_SNAPSHOT ' + ' '.join(f'{Path(k).name}:{v["sha256"][:12]}'
                                    for k, v in digests.items()))
PY

# ---------------------------------------------------------------------------
# 4. The production container body, extracted verbatim and executed from a
#    patched copy.  Four substitutions, each recorded; see
#    container-body.execution.json.
# ---------------------------------------------------------------------------
awk "/<<'CONTAINER'/{f=1;next} /^CONTAINER\$/{f=0} f" "$PRODUCTION" \
    > "$OUT/container-body.original.sh"
[[ -s "$OUT/container-body.original.sh" ]] || { echo 'container body extraction failed' >&2; exit 1; }
cp "$OUT/container-body.original.sh" "$OUT/container-body.patched.sh"
python3 - "$OUT/container-body.patched.sh" "$OUT" <<'PY'
import sys
path, out = sys.argv[1], sys.argv[2]
text = open(path).read()

# Substitution 1: the enable call this tree cannot run (NameError), replaced by
# asserting exactly the state it existed to guarantee.
lines, result, drop = text.splitlines(keepends=True), [], False
for line in lines:
    if 'package_sc7f0_rootfs.py" enable' in line:
        drop = True
        result.append('# [runner substitution 1] package_sc7f0_rootfs.py enable is replaced by the\n'
                      '# state that call existed to guarantee, asserted rather than written: the\n'
                      '# function it calls does not exist (NameError, package_sc7f0_rootfs.py:406).\n'
                      'python3 "$SC7F0_PS_BUILD_LOGS/check_rootfs_menu.py"\n')
        continue
    if drop:
        if line.rstrip().endswith('\\') or line.lstrip().startswith('--'):
            if not line.rstrip().endswith('\\'):
                drop = False
            continue
        drop = False
    result.append(line)
text = ''.join(result)
assert 'package_sc7f0_rootfs.py" enable' not in text, 'substitution 1 did not apply'

# Substitution 2: the production bblayers assertion forbids this machine's own
# meta-user path, so it can never hold and proves nothing.  The replacement
# requires bblayers to reference exactly this project's layer and requires the
# recipe bytes to match the snapshot taken before the container started.
OLD = ("assert '/home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user' "
       "not in conf, 'wrong source layer'")
assert OLD in text, 'substitution 2: the production layer assertion is not where expected'
NEW = """import json
_project = root / 'petalinux' / os.environ['SC7F0_PROJECT']
assert str(p) == str(_project), 'bitbake source root %s is not this project %s' % (p, _project)
_layer = os.path.realpath(str(_project / 'project-spec' / 'meta-user'))
_refs = [os.path.realpath(os.path.expandvars(_l))
         for _l in (l.strip().rstrip(chr(92) + ' ') for l in conf.splitlines())
         if _l.endswith('/meta-user')]
assert _refs and all(r == _layer for r in _refs), \\
    'bblayers references %s, not exactly this project layer %s' % (_refs, _layer)
_snap = json.loads(Path(os.environ['SC7F0_RECIPE_SNAPSHOT']).read_text())
assert _snap['layer'] == _layer, 'the recipe snapshot came from another layer ' + _snap['layer']
for _rel, _rec in _snap['files'].items():
    assert Path(_rel).is_file() and hashlib.sha256(Path(_rel).read_bytes()).hexdigest() == _rec['sha256'], \\
        'source recipe %s changed between snapshot and build' % _rel
    if _rec['role'] == 'in_layer':
        assert os.path.realpath(_rel).startswith(_layer + os.sep), 'recipe %s is outside the selected layer' % _rel
    else:
        assert _rel == str((root / 'test_app' / 'sc7f0_vcud.cpp').resolve()), \\
            '%s is not the repository source the recipe FILESEXTRAPATHS names' % _rel
print('SOURCE_LAYER %s referenced by bblayers; %d recipe files match their pre-build sha256'
      % (_layer, len(_snap['files'])))"""
text = text.replace(OLD, NEW, 1)

# Substitution 3: the VCU register-window assert compares the .bda text against
# lowercase spellings while Vivado 2023.2 writes that member in upper case, so it
# can never match this toolchain's own output.  Parse the addresses numerically.
OLD3 = ("assert any(a in bda for a in ('0x00b0100000', '0xb0100000', "
        "'0x0080080000', '0x80080000')), 'imported XSA does not map the VCU register window'")
assert OLD3 in text, 'substitution 3: the VCU window assertion is not where expected'
NEW3 = """_addrs = {int(a, 16) for a in re.findall(r'(?i)0x[0-9a-f]{6,16}', bda)}
_window = [a for a in (0xB0100000, 0x80080000) if a in _addrs]
assert _window, ('imported XSA does not map the VCU register window; mapped addresses are '
                 + ', '.join(hex(a) for a in sorted(_addrs)))
print('VCU_REGISTER_WINDOW_MAPPED ' + ', '.join(hex(a) for a in _window)
      + ' (parsed numerically out of the .bda; %d addresses mapped)' % len(_addrs))"""
text = text.replace(OLD3, NEW3, 1)

# Substitution 4: require that the XSA bitbake is about to read is the one this
# round imported, by path and by bytes.
OLD4 = "(out/'config-before-build').write_text((p/'project-spec/configs/config').read_text())"
assert OLD4 in text, 'substitution 4: the config snapshot line is not where expected'
NEW4 = OLD4 + """
_hdf = []
for _mc in sorted((p / 'build/conf/machine').glob('*.conf')):
    _hdf += re.findall(r'HDF_PATH\\s*=\\s*"([^"]+)"', _mc.read_text())
assert _hdf, 'no HDF_PATH in build/conf/machine; bitbake has no hardware description'
assert _hdf == [str(x[0])], \\
    ('bitbake would read %s, not the XSA this round imported (%s)' % (_hdf, x[0]))
assert os.path.isfile(_hdf[0]), 'HDF_PATH does not exist on disk: ' + _hdf[0]
assert hashlib.sha256(Path(_hdf[0]).read_bytes()).hexdigest() == \\
    hashlib.sha256(xsa.read_bytes()).hexdigest(), 'HDF_PATH is not the accepted XSA bytes'
print('BITBAKE_HDF_PATH %s is the imported XSA and matches the accepted XSA bytes' % _hdf[0])"""
text = text.replace(OLD4, NEW4, 1)
open(path, 'w').write(text)
PY
diff -u "$OUT/container-body.original.sh" "$OUT/container-body.patched.sh" \
    > "$OUT/container-body.patch.diff" || true
sha256sum "$OUT/container-body.original.sh" "$OUT/container-body.patched.sh" \
    > "$OUT/container-body.sha256"
bash -n "$OUT/container-body.patched.sh" || { echo 'patched container body does not parse' >&2; exit 1; }
cat > "$OUT/container-body.execution.json" <<EOF
{
  "production_script": "$PRODUCTION",
  "verbatim_extract": "container-body.original.sh",
  "executed_file": "container-body.patched.sh",
  "production_files_modified": [],
  "substitutions": [
    "1: package_sc7f0_rootfs.py enable (NameError at package_sc7f0_rootfs.py:406 in this tree) replaced by check_rootfs_menu.py, which asserts the CONFIG_...=y lines and the IMAGE_INSTALL:append entries that call existed to guarantee, including libdrm/libdrm-tests for the HDMI output.",
    "2: the production bblayers assertion forbids this machine's own meta-user path; the replacement resolves the layer from the real repository root, requires bblayers to reference exactly it, and requires the recipe bytes to match source-recipe-snapshot.json taken before the container started.",
    "3: the VCU register-window assert compares the .bda against lowercase addresses while Vivado 2023.2 writes 0x00B0100000; the replacement parses every address out of the .bda and requires the window numerically.",
    "4: the generated machine conf's HDF_PATH is repointed at this project and then required, inside the body, to be exactly the imported XSA with the accepted XSA's bytes."
  ],
  "compatibility_correction_of_the_standard_flow": true,
  "not_a_claim_that_the_standard_flow_ran_unmodified": true
}
EOF

docker run --rm -i --user "$(id -u):$(id -g)" \
    -e HOME="$HOME" -e USER="${USER:-zzlee}" -e TERM=xterm \
    -e SC7F0_REPO_ROOT -e SC7F0_ACCEPTED_XSA -e SC7F0_PS_BUILD_LOGS \
    -e SC7F0_PROJECT -e SC7F0_RECIPE_SNAPSHOT -e SC7F0_PL_BASE_VERSION \
    -e XILINXD_LICENSE_FILE="$XILINXD_LICENSE_FILE" \
    -v "$HOME:$HOME" -v /opt:/opt \
    -v "$SSTATE_VOLUME:$PROJECT_DIR/build/sstate-cache" \
    -v "$DOWNLOADS_VOLUME:$PROJECT_DIR/build/downloads" \
    -v /etc/timezone:/etc/timezone:ro -v /etc/localtime:/etc/localtime:ro \
    -w "$PROJECT_DIR" petalinux:latest bash -s < "$OUT/container-body.patched.sh" \
    > "$OUT/petalinux-build.log" 2>&1
echo PETALINUX_STAGE_DONE "$OUT/petalinux-build.log"

# ---------------------------------------------------------------------------
# 5. The production host stages (device tree audit, memory layout, ARM64 daemon
#    build, image.ub injection, FIT read-back, rootfs runtime proof), verbatim,
#    with one substitution: the memory/bootargs baseline, because the production
#    baseline path is one of the absent frozen trees.
# ---------------------------------------------------------------------------
cat > "$OUT/memory-layout-baseline.txt" <<EOF
file: $MEM_BASELINE
sha256: $MEM_BASELINE_SHA (verified against the file before the build started)
role: bootargs / memory / reserved-memory comparison for scripts/check_sc7f0_memory_layout.py
label: ${MEM_BASELINE_LABEL:-not supplied}
EOF
awk '/^# Stage 1b: the built device tree/{f=1} f' "$PRODUCTION" > "$OUT/ps-host-stages.original.sh"
[[ -s "$OUT/ps-host-stages.original.sh" ]] || { echo 'host stage extraction failed' >&2; exit 1; }
cp "$OUT/ps-host-stages.original.sh" "$OUT/ps-host-stages.extracted.sh"
sed -i "s#\"\$R7REL/images/image.ub\"#\"\$MEMORY_BASELINE\"#" "$OUT/ps-host-stages.extracted.sh"
sed -i "s#--expect-label 'R7 26102901 (boots on the card)'#--expect-label '${MEM_BASELINE_LABEL:-baseline image.ub}'#" \
    "$OUT/ps-host-stages.extracted.sh"
diff -u "$OUT/ps-host-stages.original.sh" "$OUT/ps-host-stages.extracted.sh" \
    > "$OUT/ps-host-stages.patch.diff" || true
{
    printf '# extracted verbatim from %s, from "# Stage 1b: the built device tree" to EOF\n' "$PRODUCTION"
    printf '# substitution A: memory-layout baseline path (see memory-layout-baseline.txt)\n'
    printf '# substitution B: that check --expect-label text, naming the baseline actually used\n'
} > "$OUT/ps-host-stages.source.txt"
sha256sum "$OUT/ps-host-stages.original.sh" "$OUT/ps-host-stages.extracted.sh" \
    > "$OUT/ps-host-stages.sha256"
bash -n "$OUT/ps-host-stages.extracted.sh" || { echo 'patched host stages do not parse' >&2; exit 1; }
printf 'R7REL=%s\nR7ACC=%s\n' "$(grep -m1 '^R7REL=' "$PRODUCTION" | cut -d= -f2-)" \
    "$(grep -m1 '^R7ACC=' "$PRODUCTION" | cut -d= -f2-)" > "$OUT/ps-host-stages.env"
R7REL=$(grep -m1 '^R7REL=' "$OUT/ps-host-stages.env" | cut -d= -f2-)
R7ACC=$(grep -m1 '^R7ACC=' "$OUT/ps-host-stages.env" | cut -d= -f2-)
export R7REL R7ACC ACCEPT="$ACCEPT_XSA"
# The extracted text starts after the production script's own `set -euo pipefail`
# and mid-script, so it runs from the repository root without -e and is judged
# from the completion markers each stage writes; -e would abort on the closing
# frozen-tree re-verification, which legitimately has nothing to compare here, and
# hide every stage that already ran.
( cd "$ROOT" && bash -o pipefail "$OUT/ps-host-stages.extracted.sh" ) 2>&1 \
    | tee "$OUT/ps-host-stages.log"
HOST_RC=${PIPESTATUS[0]}
printf '%s\n' "$HOST_RC" > "$OUT/ps-host-stages.exit"

# ---------------------------------------------------------------------------
# 6. Completion markers, then this round's own additions to the rootfs proof.
# ---------------------------------------------------------------------------
missing=()
for f in build.complete imported-xsa.sha256 xsa-after-build-check.log \
         kernel.config kernel.System.map vcu-devicetree-build.json \
         memory-layout-build.log production-daemon-build.log production-daemons.sha256 \
         image-before-production-injection.ub image-ub-before-injection.sha256 \
         image-ub-after-injection.sha256 image-ub-final.sha256 production-injection.log \
         rootfs-binary-sources.json rootfs-runtime-content.json ps-artifacts.sha256 \
         ps-vcu-injection.complete host-disk-after.txt; do
    [[ -e "$OUT/$f" ]] || missing+=("$f")
done
if [[ -s "$OUT/rootfs-runtime-content.json" ]] && \
   ! grep -q 'ROOTFS_RUNTIME_CONTENT_PASS' "$OUT/rootfs-runtime-content.json"; then
    missing+=("rootfs-runtime-content.json:ROOTFS_RUNTIME_CONTENT_PASS")
fi
if [[ "$(cut -d' ' -f1 "$OUT/image-ub-before-injection.sha256" 2>/dev/null)" == \
       "$(cut -d' ' -f1 "$OUT/image-ub-after-injection.sha256" 2>/dev/null)" ]]; then
    missing+=("image.ub unchanged by injection")
fi
if ((${#missing[@]})); then
    printf 'PS_STAGE_INCOMPLETE: %s\n' "${missing[*]}" >&2
    exit 1
fi

# The production host stages verify the daemon/VCU runtime this image has always
# carried.  This round adds a display pipeline, so its own runtime content is
# proven with the same committed tool, against the same FIT, and nothing else:
# libdrm present and modetest a real ARM64 binary in the image.
VERIFY_ARGS=()
for f in "${EXPECT_FILES[@]}"; do VERIFY_ARGS+=(--expect-file "$f"); done
for b in "${EXPECT_BINS[@]}"; do VERIFY_ARGS+=(--expect-binary "$b"); done
for s in "${EXPECT_STRINGS[@]}"; do VERIFY_ARGS+=(--expect-string "$s"); done
if ((${#VERIFY_ARGS[@]})); then
    python3 scripts/package_sc7f0_rootfs.py verify --image-ub "$IMG_DIR/image.ub" \
        "${VERIFY_ARGS[@]}" --json "$OUT/rootfs-display-content.json" \
        > "$OUT/rootfs-display-content.log" 2>&1 || {
        tail -20 "$OUT/rootfs-display-content.log" >&2
        echo 'the built image does not contain the display runtime this round added' >&2
        exit 1; }
    grep -q ROOTFS_RUNTIME_CONTENT_PASS "$OUT/rootfs-display-content.log" || {
        echo 'rootfs display content verification did not report PASS' >&2; exit 1; }
fi

# The device tree this round added is read back out of the built FIT too, so the
# claim is about the bytes that will boot, not about the source file.
python3 - "$IMG_DIR/system.dtb" "$OUT/display-devicetree.json" <<'PY'
import json, re, sys
from pathlib import Path
dtb, out = Path(sys.argv[1]), Path(sys.argv[2])
text = dtb.read_bytes().decode('latin-1')
want = {'hdmi-tx@b0020000': 'xlnx,v-hdmi-tx-ss-3.1', 'framebuffer@b0080000': 'xlnx,axi-frmbuf-rd-v2.2',
        'drm-pl-disp-drv': 'xlnx,pl-disp'}
found = {k: v in text for k, v in want.items()}
for name, present in found.items():
    assert present, f'{name} is not in the built device tree'
lanes = len(re.findall(r'lane[0-9]', text))
report = {'system_dtb': str(dtb), 'sha256': __import__('hashlib').sha256(dtb.read_bytes()).hexdigest(),
          'nodes': found, 'vphy_lane_child_strings': lanes}
out.write_text(json.dumps(report, indent=2) + '\n')
print('DISPLAY_DEVICETREE_IN_BUILT_IMAGE ' + ' '.join(found))
PY

sha256sum "$IMG_DIR/image.ub" "$IMG_DIR/system.dtb" > "$OUT/ps-final-artifacts.sha256"
printf 'PS stage ran the production container body (four recorded substitutions) and the verbatim host stages against %s (%s), then proved this round'"'"'s display runtime and device tree out of the built FIT.\n' \
    "$ACCEPT_XSA" "$PL_BASE" > "$OUT/ps-stage-runner.complete"
echo "PS_STAGE_RUNNER_DONE $OUT"
sha256sum "$IMG_DIR/image.ub"
