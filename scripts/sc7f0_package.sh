#!/usr/bin/env bash
# 2/3: freeze matching BOOT.BIN + image.ub + boot.scr + SHA manifest.
# No hardware access. Never add extra files/directories to the firmware tar.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT= DRY=0
usage() { echo "Usage: $0 --build BUILD_DIR [--dry-run]"; }
while (($#)); do
    case "$1" in
        --build) OUT=${2:?}; shift 2;;
        --dry-run) DRY=1; shift;;
        -h|--help) usage; exit 0;;
        *) usage >&2; exit 2;;
    esac
done
[[ -n $OUT ]] || { usage >&2; exit 2; }
OUT=$(realpath -m "$OUT")
if ((DRY)); then
    printf 'PACKAGE build=%s\nCheck compile gates/hashes; bootgen matching bitstream; strict 4-member ustar + manifest; verify using daemon C parser. No hardware access.\n' "$OUT"
    exit 0
fi
[[ -f $OUT/build.ok && $(<"$OUT/build.ok") == SC7F0_BUILD_PASS ]] || { echo 'Missing successful build gate' >&2; exit 1; }
VERSION=$(<"$OUT/VERSION")
[[ $VERSION =~ ^[0-9]{8}$ ]] || exit 1
BUNDLE="$OUT/upgrade-$VERSION.tar"
[[ ! -e $BUNDLE && ! -e $OUT/package.ok ]] || { echo "Refusing to overwrite packaged release $OUT" >&2; exit 1; }
cd "$ROOT"
mkdir -p build
exec 9>build/.sc7f0-build.lock
flock -n 9 || { echo 'Another build/package is active' >&2; exit 1; }
(cd "$OUT"; sha256sum -c COMPILED.sha256)
sha256sum -c "$OUT/SOURCE.sha256" > "$OUT/logs/package-source-check.log"
python3 - "$OUT" <<'PY'
from pathlib import Path
from zipfile import ZipFile
import sys
p=Path(sys.argv[1])/'fpga'
with ZipFile(p/'hardware.xsa') as z:
    names=[n for n in z.namelist() if n.endswith('.bit')]
    assert len(names)==1 and z.read(names[0])==(p/'zu4ev_pcie_card_top.bit').read_bytes()
PY
set +u
source "${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"
set -u
SC7F0_IMPL_DIR="$OUT/fpga" SC7F0_IMG_DIR="$OUT/images" bash scripts/package_zu4ev_bootbin.sh
python3 scripts/package_sc7f0_upgrade.py --images "$OUT/images" --output "$BUNDLE"
# Exercise exactly the extractor and SHA verifier used by the PS daemon.
VERIFY=$(mktemp -d "$OUT/.verify-XXXXXX")
trap 'rm -rf "$VERIFY"' EXIT
cc -O2 -Itest_app tb/qpcie_archive_verify_tb.c -o "$VERIFY/verify"
mkdir "$VERIFY/files"
"$VERIFY/verify" "$BUNDLE" "$VERIFY/files" --check-manifest
python3 - "$OUT" "$VERSION" <<'PY'
from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1]); version=sys.argv[2]
names=[f'upgrade-{version}.tar','host-driver-src.tar.gz','host-tools-src.tar.gz',
       'images/BOOT.BIN','images/image.ub','images/boot.scr','fpga/hardware.xsa','fpga/zu4ev_pcie_card_top.bit']
data={'version':version,'sha256':{n:hashlib.sha256((p/n).read_bytes()).hexdigest() for n in names}}
(p/'release.json').write_text(json.dumps(data,indent=2)+'\n')
(p/'RELEASE.sha256').write_text(''.join(f'{h}  {n}\n' for n,h in data['sha256'].items()))
PY
printf 'SC7F0_PACKAGE_PASS\n' > "$OUT/package.ok"
printf '\nPACKAGE PASS: %s\nNext: %s/scripts/sc7f0_flash.sh --build %q --host rd@sc7f0-test.local\n' "$BUNDLE" "$ROOT" "$OUT"
