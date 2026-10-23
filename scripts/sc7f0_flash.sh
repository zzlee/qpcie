#!/usr/bin/env bash
# 3/3: host-driver build + PS backup + VERIFY -> COMMIT -> card-only POR.
# The SSH target is x86. All card Linux commands use sc7f0ctl exec.
set -euo pipefail
OUT= HOST=rd@sc7f0-test.local YES=0 VERIFY_ONLY=0 DRY=0
usage() { echo "Usage: $0 --build BUILD_DIR [--host rd@sc7f0-test.local] [--yes | --verify-only] [--dry-run]"; }
while (($#)); do
    case "$1" in
        --build) OUT=${2:?}; shift 2;;
        --host) HOST=${2:?}; shift 2;;
        --yes) YES=1; shift;;
        --verify-only) VERIFY_ONLY=1; shift;;
        --dry-run) DRY=1; shift;;
        -h|--help) usage; exit 0;;
        *) usage >&2; exit 2;;
    esac
done
[[ -n $OUT && $HOST != -* ]] || { usage >&2; exit 2; }
OUT=$(realpath -m "$OUT")
if ((DRY)); then
    printf 'FLASH build=%s host=%s verify_only=%s\nCheck release SHA; check real PS services via sc7f0ctl exec; compile matched host driver; board VERIFY.\n' "$OUT" "$HOST" "$VERIFY_ONLY"
    ((VERIFY_ONLY)) || echo 'Then back up eMMC/host module; install driver; COMMIT; read back SHA; card-only POR/rescan; assert version and unchanged x86 boot ID.'
    exit 0
fi
[[ -f $OUT/package.ok && $(<"$OUT/package.ok") == SC7F0_PACKAGE_PASS ]] || { echo 'Missing successful package gate' >&2; exit 1; }
VERSION=$(<"$OUT/VERSION")
[[ $VERSION =~ ^[0-9]{8}$ ]] || exit 1
(cd "$OUT"; sha256sum -c RELEASE.sha256)
if ((!VERIFY_ONLY && !YES)); then
    read -r -p "Write card eMMC and restart CARD PS only on $HOST (0x$VERSION)? Type YES: " answer
    [[ $answer == YES ]] || { echo 'Cancelled'; exit 1; }
fi
REMOTE=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" 'mktemp -d "$HOME/sc7f0-upgrade.XXXXXXXX"')
[[ $REMOTE =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Unexpected remote path' >&2; exit 1; }
scp "$OUT/upgrade-$VERSION.tar" "$OUT/host-driver-src.tar.gz" "$OUT/host-tools-src.tar.gz" "$OUT/RELEASE.sha256" "$HOST:$REMOTE/"
# All operations share one remote lock. A failed VERIFY never reaches COMMIT.
ssh "$HOST" bash -s -- "$REMOTE" "$VERSION" "$VERIFY_ONLY" <<'REMOTE_SCRIPT' 2>&1 | tee "$OUT/logs/flash.log"
set -euo pipefail
DIR=$1 VERSION=$2 VERIFY_ONLY=$3
CTL="$HOME/sc7f0ctl"
exec 9>"$HOME/.sc7f0-upgrade.lock"
flock -n 9 || { echo 'Another upgrade is active'; exit 1; }
cd "$DIR"
echo "Remote logs/backups: $DIR"
[[ $(uname -m) == x86_64 ]]
BOOT_BEFORE=$(</proc/sys/kernel/random/boot_id)
printf '%s\n' "$BOOT_BEFORE" > host-boot-id-before
sudo -n "$CTL" status
sudo -n "$CTL" exec 'set -eu; test "$(uname -m)" = aarch64; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon; do systemctl is-active --quiet "$s" || exit 1; done; ps -ef | grep qpcie'
# Verify exactly the uploaded artifacts before unpacking/building on x86.
grep -E '  (upgrade-[0-9]+\.tar|host-driver-src\.tar\.gz|host-tools-src\.tar\.gz)$' RELEASE.sha256 | sha256sum -c -
tar -xzf host-tools-src.tar.gz
cc -O2 -Wall test_app/qpcie_upgrade.c -o qpcie_upgrade
if ((!VERIFY_ONLY)); then
    if fuser /dev/video0 2>/dev/null; then
        echo 'Capture is active; stop preview/capture before flashing' >&2; exit 1
    fi
    tar -xzf host-driver-src.tar.gz
    make -C driver -j4
    [[ $(modinfo -F vermagic driver/qpcie.ko) == "$(uname -r) "* ]]
fi
sudo -n ./qpcie_upgrade --package "upgrade-$VERSION.tar" | tee verify.log
sudo -n "$CTL" exec 'tail -n 15 /var/log/messages'
if ((VERIFY_ONLY)); then
    echo 'VERIFIED only: no eMMC write, driver installation or reboot performed.'
    exit 0
fi
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
sudo -n "$CTL" exec "set -eu; b=/run/media/BOOT-mmcblk0p1; test -s \$b/BOOT.BIN; d=\$b/.backup_cli_$STAMP; mkdir \$d; for n in BOOT.BIN image.ub boot.scr; do cp \$b/\$n \$d/\$n; done; sync; sha256sum \$d/*"
INSTALLED=$(modinfo -n qpcie)
cp "$INSTALLED" module-before.ko
[[ ! -f $HOME/qpcie.ko ]] || cp "$HOME/qpcie.ko" home-module-before.ko
# rmmod, NOT modprobe -r: keep the vb2 dependencies loaded. Restore on failure.
systemctl --user stop wireplumber
trap 'systemctl --user start wireplumber || true' EXIT
sudo -n modprobe videobuf2-v4l2
sudo -n modprobe videobuf2-dma-sg
sudo -n rmmod qpcie
if ! sudo -n insmod driver/qpcie.ko; then
    sudo -n insmod module-before.ko
    echo 'New driver rejected; restored old module. Firmware not committed.' >&2
    exit 1
fi
sudo -n install -D -m 0644 driver/qpcie.ko "/lib/modules/$(uname -r)/extra/qpcie.ko"
sudo -n depmod -a
cp driver/qpcie.ko "$HOME/qpcie.ko"
sudo -n ./qpcie_upgrade --commit | tee commit.log
# Independent post-COMMIT readback over the PS mailbox, before any reboot.
sudo -n "$CTL" exec 'sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr' > readback.sha256
python3 - <<'PY'
from pathlib import Path
expected={Path(n).name:h for h,n in (line.split() for line in Path('RELEASE.sha256').read_text().splitlines()) if n.startswith('images/')}
actual={Path(n).name:h for h,n in (line.split() for line in Path('readback.sha256').read_text().splitlines())}
assert actual==expected, (actual,expected)
print('EMMC_READBACK_SHA_PASS')
PY
sudo -n ./qpcie_upgrade --reboot | tee reboot.log
ready=0
for attempt in $(seq 1 45); do
    if sudo -n "$CTL" status > ps-status.log 2>&1 && grep -q 'ready=1' ps-status.log; then ready=1; break; fi
    sleep 2
done
[[ $ready == 1 ]] || { echo 'PS did not resume; inspect PCIe/card boot. Do NOT reboot the x86 host automatically.' >&2; exit 1; }
sudo -n ./qpcie_upgrade --status | tee active-version.log
grep -qi "Hardware Version.*0x$VERSION" active-version.log
sudo -n "$CTL" exec 'uname -a; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon; do systemctl is-active --quiet "$s" || exit 1; done; ps -ef | grep qpcie'
[[ $(</proc/sys/kernel/random/boot_id) == "$BOOT_BEFORE" ]]
echo "FLASH_PASS: active=0x$VERSION; eMMC hashes verified; x86 boot ID unchanged."
echo 'Capture/display acceptance is a separate test; a successful flash alone is not image success.'
REMOTE_SCRIPT
