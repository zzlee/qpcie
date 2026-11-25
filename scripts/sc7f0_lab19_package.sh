#!/usr/bin/env bash
# Lab PS-only update. Do not run bootgen or synthesize: boot chain remains the
# exact eMMC rollback payload. Production build gates are not applicable markers.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd);B=$(realpath "${1:?rootfs build}");F=$(realpath "${2:?verified 26112419 release-lab directory}");P=$B/src/petalinux/qpcie-zu4ev/images/linux;V=$(cat "$B/VERSION");[[ $V =~ ^[0-9]{8}$ && $V != 26112419 && $(cat "$B/PL_VERSION") == 26112419 && ! -e $B/release ]];(cd "$P";sha256sum -c "$B/ps-images.sha256");(cd "$F";sha256sum -c RELEASE.sha256;sha256sum -c - <<'SUM'
3851cdc9c4b9ca43de20c7fe59a970f6c2fab44af10968a726eb264bb245c06b  images/BOOT.BIN
14c14ececc4b35eb6ac10253f06a0f3dad10b7750d7283a7892676288df3bad6  images/boot.scr
7509397654d5ba8a00ea8b1c9ca7ff9a845afab391fca0f72cb467b0b13f23b3  fpga/hardware.xsa
4d7b869d119287b12b5691431a9084cc6974f2573155c50b64ff682cb3e2e7e2  fpga/zu4ev_pcie_card_top.bit
SUM
);python3 "$ROOT/scripts/package_sc7f0_rootfs.py" verify --image-ub "$P/image.ub" --expect-binary sc7f0_vcud=@present --expect-binary modetest=@present --enabled-unit sc7f0-vcud.service --enabled-unit sc7f0-modetest.service --expect-file etc/default/sc7f0-vcud --expect-file usr/lib/sc7f0/sc7f0-tx-modeset --expect-string "etc/sc7f0-ps-release=$V" --expect-string 'usr/bin/sc7f0_vcud=/dev/sc7f0-stage2' --json "$B/logs/packaged-content.json"
PYTHONPATH="$ROOT/scripts" python3 - "$P/image.ub" "$V" "$B/logs" <<'VERIFY_STAGE'
import hashlib, json, sys, tempfile
from pathlib import Path
sys.path.insert(0, 'scripts' if Path('scripts').is_dir() else str(Path(sys.argv[0]).parent))
from package_sc7f0_rootfs import unpack_rootfs, resolve, is_arm64_elf
with tempfile.TemporaryDirectory() as t:
    files=unpack_rootfs(Path(sys.argv[1]),Path(t))
modules=[n for n in files if n.endswith('/stage2.ko')]
assert len(modules)==1, modules
payload=resolve(files,modules[0])[2]
assert is_arm64_elf(payload) and b'sc7f0,packet-reader-hp1-v2' in payload
assert resolve(files,'etc/sc7f0-ps-release')[2].decode().strip()==sys.argv[2]
assert not any('sc7f0-vcud.service.d/' in n or n.endswith('/mv.so') for n in files)
Path(sys.argv[3], 'stage-module.json').write_text(json.dumps({'path':modules[0], 'sha256':hashlib.sha256(payload).hexdigest()})+'\n')
VERIFY_STAGE
D=$B/release;mkdir -p "$D"/{images,logs,fpga};cp "$F"/images/{BOOT.BIN,boot.scr} "$D/images/";cp "$F"/fpga/{hardware.xsa,zu4ev_pcie_card_top.bit} "$D/fpga/";cp "$F/LAB-ONLY.md" "$B"/{VERSION,PL_VERSION} "$D/";cp "$P/image.ub" "$D/images/";cd "$ROOT";find driver include -type f \( -name '*.c' ! -name '*.mod.c' -o -name '*.h' -o -name '*.inc' -o -name Makefile \) -print0|sort -z|tar -czf "$D/host-driver-src.tar.gz" --null -T -;tar czf "$D/host-tools-src.tar.gz" test_app/{qpcie_upgrade.c,qpcie_sha256.h,sc7f0_kms.c,sc7f0_kms_ball.c,sc7f0_record_trace.c};python3 scripts/package_sc7f0_upgrade.py --images "$D/images" --output "$D/upgrade-$V.tar";mkdir "$D/verify";cc -O2 -Itest_app tb/qpcie_archive_verify_tb.c -o "$B/verify-tar";"$B/verify-tar" "$D/upgrade-$V.tar" "$D/verify" --check-manifest;cd "$D";python3 - <<'PY'
import json,hashlib,pathlib
p=pathlib.Path;v=p('VERSION').read_text().strip();files=['upgrade-'+v+'.tar','host-driver-src.tar.gz','host-tools-src.tar.gz','images/BOOT.BIN','images/image.ub','images/boot.scr','fpga/hardware.xsa','fpga/zu4ev_pcie_card_top.bit','LAB-ONLY.md','PL_VERSION','VERSION'];h={f:hashlib.sha256(p(f).read_bytes()).hexdigest() for f in files};p('release.json').write_text(json.dumps(dict(version=v,pl_version='26112419',qualification='room-temperature lab only',sha256=h),indent=2)+'\n');p('RELEASE.sha256').write_text(''.join(s+'  '+f+'\n' for f,s in h.items())+hashlib.sha256(p('release.json').read_bytes()).hexdigest()+'  release.json\n')
PY
sha256sum -c RELEASE.sha256;echo SC7F0_PACKAGE_PASS >package.ok
