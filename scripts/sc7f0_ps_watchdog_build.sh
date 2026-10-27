#!/usr/bin/env bash
# PS-only software build/package using the already signed-off frozen rev06 PL.
# No SSH, PCIe access, reset, watchdog open, flashing, MCU or FPGA rebuild.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE="$ROOT/build/sc7f0-audio-26102206-r5"
OUT=
while (($#)); do
    case "$1" in
        --out) OUT=${2:?}; shift 2;;
        --base) BASE=${2:?}; shift 2;;
        *) echo "Usage: $0 --out FRESH_DIRECTORY [--base FROZEN_REV06_BUILD]" >&2; exit 2;;
    esac
done
[[ -n "$OUT" ]] || exit 2
OUT=$(realpath -m "$OUT")
BASE=$(realpath -e "$BASE")
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
[[ $(<"$BASE/VERSION") == 26102206 && -s "$BASE/package.ok" ]] || exit 1
cd "$ROOT"
exec 9>build/.sc7f0-build.lock
flock -n 9 || { echo "Another build/package is running" >&2; exit 1; }
mkdir -p "$OUT"/{logs,fpga,images,rollback}
exec > >(tee "$OUT/logs/build.log") 2>&1
trap 'r=$?; echo "$r" > "$OUT/build.exit"; exit "$r"' EXIT
(cd "$BASE"; sha256sum -c RELEASE.sha256)
cp "$BASE/fpga/"{hardware.xsa,zu4ev_pcie_card_top.bit} "$OUT/fpga/"
cp "$BASE/images/"{BOOT.BIN,image.ub,boot.scr} "$OUT/rollback/"
cmp "$OUT/fpga/hardware.xsa" petalinux/qpcie-zu4ev/project-spec/hw-description/system.xsa
(cd "$OUT"; sha256sum fpga/* rollback/* > BASELINE.sha256)
find test_app include scripts petalinux/qpcie-zu4ev/project-spec/meta-user -type f \
    \( -name '*.c' -o -name '*.h' -o -name '*.sh' -o -name '*.py' -o -name '*.bb' \
       -o -name '*.bbappend' -o -name '*.patch' -o -name '*.cfg' -o -name '*.dtsi' \
       -o -name '*.service' -o -name Makefile \) ! -name '*.mod.c' -print0 | sort -z > "$OUT/SOURCE.files0"
xargs -0 sha256sum < "$OUT/SOURCE.files0" > "$OUT/SOURCE.sha256"
tar --null -T "$OUT/SOURCE.files0" -czf "$OUT/source-snapshot.tar.gz"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests > "$OUT/logs/python-tests.log" 2>&1
python3 tb/qpcie_debug_tb.py > "$OUT/logs/debug-rpc-test.log" 2>&1
bash tb/qpcie_debug_rootfs_tb.sh > "$OUT/logs/debug-rootfs-test.log" 2>&1
make -C petalinux/qpcie-zu4ev linux > "$OUT/logs/petalinux.log" 2>&1
grep -q 'all succeeded' "$OUT/logs/petalinux.log"
make -B -C test_app qpcie_debugd qpcie_hdmi_daemon qpcie_upgrade_daemon sc7f0_ps_watchdog > "$OUT/logs/daemon-build.log" 2>&1
REL_TARGET_DIR="$OUT/.no-publish" INCLUDE_DEBUG_DAEMON=1 ENABLE_DEBUG_EXEC=1 \
    ENABLE_HDMI_DAEMON=1 ENABLE_SC7F0_WATCHDOG=1 \
    bash scripts/inject_upgrade_daemon_to_image_ub.sh > "$OUT/logs/inject.log" 2>&1
for f in image.ub boot.scr zynqmp_fsbl.elf pmufw.elf bl31.elf u-boot.elf system.dtb Image.gz; do
    cp -L "petalinux/qpcie-zu4ev/images/linux/$f" "$OUT/images/$f"
done
cp petalinux/qpcie-zu4ev/build/tmp/work/*/linux-xlnx/*/linux-zynqmp_generic_xczu4ev-standard-build/.config "$OUT/images/kernel.config"
cp petalinux/qpcie-zu4ev/build/tmp/work/*/pmu-firmware/*/temp/log.do_patch "$OUT/logs/pmufw-do-patch.log"
grep -q "Applying patch '0002-sc7f0-enable-watchdog-srst.patch'" "$OUT/logs/pmufw-do-patch.log"
/opt/Xilinx/Vitis/2023.2/gnu/microblaze/lin/bin/mb-nm "$OUT/images/pmufw.elf" > "$OUT/logs/pmufw.nm"
SC7F0_IMPL_DIR="$OUT/fpga" SC7F0_IMG_DIR="$OUT/images" bash scripts/package_zu4ev_bootbin.sh > "$OUT/logs/bootgen.log" 2>&1
python3 scripts/check_sc7f0_ps_watchdog_image.py "$OUT" | tee "$OUT/logs/image-audit.log"
BUNDLE="$OUT/upgrade-ps-watchdog-20261027-r2.tar"
python3 scripts/package_sc7f0_upgrade.py --images "$OUT/images" --output "$BUNDLE" > "$OUT/logs/package.log"
python3 scripts/package_sc7f0_upgrade.py --images "$OUT/rollback" --output "$OUT/rollback-26102206.tar" >> "$OUT/logs/package.log"
cc -O2 -Wall -Wextra -Werror -Itest_app tb/qpcie_archive_verify_tb.c -o "$OUT/archive-verify"
mkdir "$OUT/.verify"
"$OUT/archive-verify" "$BUNDLE" "$OUT/.verify" --check-manifest > "$OUT/logs/archive-check.log"
rm -rf "$OUT/.verify"
cp "$BASE/host-driver-src.tar.gz" "$OUT/"
tar -czf "$OUT/host-tools-src.tar.gz" test_app/qpcie_upgrade.c test_app/qpcie_sha256.h
sha256sum -c "$OUT/SOURCE.sha256" > "$OUT/logs/source-check.log"
python3 - "$OUT" <<'PY'
import hashlib, json, sys
from pathlib import Path
p = Path(sys.argv[1])
names = ['upgrade-ps-watchdog-20261027-r2.tar', 'rollback-26102206.tar',
         'host-driver-src.tar.gz', 'host-tools-src.tar.gz', 'source-snapshot.tar.gz']
names += [str(f.relative_to(p)) for folder in ('images', 'fpga', 'rollback')
          for f in sorted((p / folder).iterdir()) if f.is_file()]
hashes = {n: hashlib.sha256((p / n).read_bytes()).hexdigest() for n in names}
(p / 'RELEASE.sha256').write_text(''.join(f'{h}  {n}\n' for n, h in hashes.items()))
(p / 'release.json').write_text(json.dumps({
    'ps_release': 'sc7f0-ps-watchdog-20261027-r2', 'pl_version': '0x26102206',
    'pl_rebuilt': False, 'mcu_flashed': False, 'hardware_validated': False,
    'audio_acceptance': False, 'sha256': hashes}, indent=2) + '\n')
PY
printf 'SC7F0_PS_WATCHDOG_BUILD_PASS\n' > "$OUT/build.ok"
printf 'SC7F0_PS_WATCHDOG_PACKAGE_PASS\n' > "$OUT/package.ok"
printf '%s\n' "$OUT" > build/.sc7f0-ps-watchdog-release
printf 'PS-only release ready for OFFLINE review / later cold-boot acceptance: %s\n' "$OUT"
