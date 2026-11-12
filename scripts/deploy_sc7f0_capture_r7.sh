#!/usr/bin/env bash
# Complete R7 capture package (0x26102901) only; one COMMIT, real PS boot proof.
# Derived from scripts/deploy_sc7f0_capture_r6.sh. No MCU operation, no host
# reboot, no arbitrary MMIO, no active-stream reset, no automatic retry.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=$(realpath "${1:?RELEASE_DIR [HOST]}")
HOST=${2:-rd@sc7f0-test.local}
VERSION=26102901
PACKAGE="upgrade-$VERSION.tar"
[[ $HOST != -* ]]
[[ $(<"$OUT/VERSION") == "$VERSION" ]] || { echo "VERSION mismatch: expected $VERSION" >&2; exit 1; }
[[ $(<"$OUT/build.ok") == SC7F0_BUILD_PASS ]]
[[ $(<"$OUT/package.ok") == SC7F0_PACKAGE_PASS ]]
[[ -s "$OUT/$PACKAGE" ]]
cd "$ROOT"
mkdir -p "$OUT/deployment"
sha256sum -c "$OUT/SOURCE.sha256" > "$OUT/deployment/source-check.log"
(cd "$OUT"; sha256sum -c RELEASE.sha256) > "$OUT/deployment/release-check.log"
grep -q SC7F0_CAPTURE_IMAGE_AUDIT_PASS "$OUT/logs/capture-image-audit-after-package.log"
[[ ! -e "$OUT/deployment/commit-issued" ]] || { echo 'COMMIT already issued: do not rerun' >&2; exit 1; }
sha256sum "${BASH_SOURCE[0]}" > "$OUT/deployment/deployment-tool.sha256"
REMOTE=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" 'mkdir -p "$HOME/sc7f0/tmp" && mktemp -d "$HOME/sc7f0/tmp/capture-r7.XXXXXXXX"')
[[ $REMOTE =~ ^/[a-zA-Z0-9_./-]+$ ]]
printf '%s\n' "$REMOTE" > "$OUT/deployment/remote-path"
scp "$OUT/$PACKAGE" "$OUT/host-driver-src.tar.gz" "$OUT/host-tools-src.tar.gz" "$OUT/RELEASE.sha256" "$HOST:$REMOTE/"
# A local intent marker prevents blindly repeating this deployment after an
# interrupted SSH session. It intentionally exists even if pre-COMMIT fails;
# inspect remote evidence and make an explicit new attempt only if not issued.
printf 'Deployment attempt started; inspect remote commit-issued before any retry.\n' > "$OUT/deployment/commit-issued"
ssh "$HOST" bash -s -- "$REMOTE" <<'REMOTE_SCRIPT' 2>&1 | tee "$OUT/deployment/deploy.log"
set -euo pipefail
DIR=$1
cd "$DIR"
exec 9>"$HOME/sc7f0/tmp/.upgrade.lock"
flock -n 9 || { echo 'Another upgrade active'; exit 1; }
[[ $(uname -r) == 7.0.0-38-generic && $(uname -m) == x86_64 ]]
HOST_BEFORE=$(</proc/sys/kernel/random/boot_id)
printf '%s\n' "$HOST_BEFORE" > host-boot-id-before
# Check exactly the uploaded bytes before extraction/build.
grep -E '  (upgrade-26102901.tar|host-driver-src.tar.gz|host-tools-src.tar.gz)$' RELEASE.sha256 | sha256sum -c -
tar -xzf host-tools-src.tar.gz
tar -xzf host-driver-src.tar.gz
cc -O2 -Wall -Wextra -Werror -Iinclude test_app/sc7f0ctl.c -o sc7f0ctl
cc -O2 -Wall -Wextra -Werror test_app/qpcie_upgrade.c -o qpcie_upgrade
make -C "/lib/modules/$(uname -r)/build" M="$DIR/driver" KCFLAGS=-Werror modules > host-driver-build.log 2>&1
[[ $(modinfo -F vermagic driver/qpcie.ko) == "$(uname -r) "* ]]
CTL="$DIR/sc7f0ctl"
UPG="$DIR/qpcie_upgrade"
PS_BEFORE=$(sudo -n "$CTL" --timeout 10 exec 'cat /proc/sys/kernel/random/boot_id')
[[ $PS_BEFORE =~ ^[0-9a-f-]{36}$ ]]
printf '%s\n' "$PS_BEFORE" > ps-boot-id-before
sudo -n "$CTL" --timeout 30 exec 'dmesg | tail -n 120' > ps-dmesg-before.log
sudo -n "$UPG" --status | tee hardware-before.log
# Gate: upgrade engine must be idle, and the card must not already run R7.
grep -qi 'IDLE / Ready' hardware-before.log || { echo 'Upgrade engine not IDLE before attempt; aborting with zero writes' >&2; exit 1; }
! grep -qi 'Hardware Version.*0x26102901' hardware-before.log || { echo 'Active version already 0x26102901: inspect prior evidence, do not re-flash' >&2; exit 1; }
sudo -n "$CTL" --timeout 10 exec 'set -eu; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon sc7f0-ps-watchdog; do systemctl is-active --quiet "$s"; done; sc7f0_ps_watchdog --check-health /run/sc7f0-health'
WP_ACTIVE=0
if systemctl --user is-active --quiet wireplumber; then
    systemctl --user stop wireplumber
    WP_ACTIVE=1
fi
trap 'if ((WP_ACTIVE)); then systemctl --user start wireplumber || true; fi' EXIT
# No force-kill, forced unload or active buffer reclamation.
for video in /dev/video*; do
    if [[ -c $video ]] && sudo -n fuser "$video"; then echo "Active capture client: $video" >&2; exit 1; fi
done
cards=$(python3 - <<'PY'
from pathlib import Path
import re
for line in Path('/proc/asound/cards').read_text().splitlines():
 m=re.match(r'^\s*(\d+)\s+\[[^]]*qpcie[^]]*\]',line,re.I)
 if m:print(m[1])
PY
)
[[ -n $cards ]]
for card in $cards; do
    for dev in /dev/snd/pcmC"$card"* /dev/snd/controlC"$card"; do
        if [[ -c $dev ]] && sudo -n fuser "$dev"; then echo "Active card audio client: $dev" >&2; exit 1; fi
    done
done
printf 'CLIENTS_QUIESCED\n' > quiesced
sudo -n "$UPG" --package upgrade-26102901.tar | tee verify.log
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
sudo -n "$CTL" --timeout 30 exec "set -eu; b=/run/media/BOOT-mmcblk0p1; d=\$b/.backup_cli_$STAMP; test ! -e \$d; mkdir \$d; for n in BOOT.BIN image.ub boot.scr; do test -s \$b/\$n; cp \$b/\$n \$d/\$n; done; sync; sha256sum \$d/*" | tee emmc-backup.log
INSTALLED=$(modinfo -n qpcie)
cp "$INSTALLED" module-before.ko
[[ ! -f $HOME/qpcie.ko ]] || cp "$HOME/qpcie.ko" home-module-before.ko
sudo -n modprobe videobuf2-v4l2
sudo -n modprobe videobuf2-dma-sg
sudo -n rmmod qpcie
if ! sudo -n insmod driver/qpcie.ko; then
    sudo -n insmod module-before.ko
    echo 'New module failed; restored old module, no COMMIT' >&2; exit 1
fi
sudo -n install -D -m 0644 driver/qpcie.ko "/lib/modules/$(uname -r)/extra/qpcie.ko"
sudo -n depmod -a
cp driver/qpcie.ko "$HOME/qpcie.ko"
# Exactly one call. Any nonzero/connection-loss outcome is ambiguous: STOP.
printf 'ONE_COMMIT_CALL\n' > commit-issued
set +e
sudo -n "$UPG" --commit > commit.log 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > commit.exit
cat commit.log
[[ $rc == 0 ]] || { echo 'COMMIT uncertain/failed; never retry automatically' >&2; exit 1; }
sudo -n "$CTL" --timeout 30 exec 'sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr' > readback.sha256
python3 - <<'PY'
from pathlib import Path
expected={Path(n).name:h for h,n in (s.split() for s in Path('RELEASE.sha256').read_text().splitlines()) if n in ('images/BOOT.BIN','images/image.ub','images/boot.scr')}
actual={Path(n).name:h for h,n in (s.split() for s in Path('readback.sha256').read_text().splitlines())}
assert set(expected)=={'BOOT.BIN','image.ub','boot.scr'} and actual==expected,(actual,expected)
print('INDEPENDENT_EMMC_SHA_PASS')
PY
# This is PS warm reboot via daemon/PSCI/PMU, NOT POR or MCU reset.
set +e
sudo -n "$UPG" --reboot > reboot.log 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > reboot.exit
ready=0
end=$((SECONDS+180))
while ((SECONDS<end)); do
    if sudo -n "$CTL" --timeout 2 status > mailbox-status.log 2>&1 && grep -q 'ready=1' mailbox-status.log; then
        PS_AFTER=$(sudo -n "$CTL" --timeout 3 exec 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
        if [[ $PS_AFTER =~ ^[0-9a-f-]{36}$ && $PS_AFTER != "$PS_BEFORE" ]]; then
            if sudo -n "$UPG" --status > hardware-after.log 2>&1 && grep -qi 'Hardware Version.*0x26102901' hardware-after.log; then
                printf '%s\n' "$PS_AFTER" > ps-boot-id-after
                ready=1;break
            fi
        fi
    fi
    sleep 2
done
[[ $ready == 1 ]] || { echo 'No new PS boot/version proof; do not reboot host or retry COMMIT' >&2; exit 1; }
# Reprobe after FPGA replacement: old qdev capabilities must not survive it.
sudo -n rmmod qpcie
sudo -n insmod driver/qpcie.ko
sudo -n "$UPG" --status | tee active-version.log
sudo -n "$CTL" --timeout 30 exec 'set -eu; uname -a; cat /proc/sys/kernel/random/boot_id; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon sc7f0-ps-watchdog; do printf "$s="; systemctl is-active "$s"; done; sc7f0_ps_watchdog --check-health /run/sc7f0-health; cat /etc/sc7f0-recovery-release; ls -l /dev/video* /dev/media*; sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr' | tee ps-after.log
sudo -n "$CTL" --timeout 30 exec 'dmesg | tail -n 150' > ps-dmesg-after.log
printf '%s\n' "$(</proc/sys/kernel/random/boot_id)" > host-boot-id-after
cmp host-boot-id-before host-boot-id-after
printf 'SC7F0_R7_DEPLOY_PASS: single COMMIT, independent eMMC SHA, changed PS boot ID, unchanged host boot ID; runtime capture acceptance still required\n' | tee deployment.ok
REMOTE_SCRIPT
# Retrieval does not perform any hardware action or repeat an upgrade request.
scp -r "$HOST:$REMOTE" "$OUT/deployment/remote-evidence"
