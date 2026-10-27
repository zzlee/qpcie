#!/usr/bin/env bash
# Offline rootfs installation only. Never opens a watchdog or contacts a card.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FS=$(realpath -e "${1:?Usage: $0 UNPACKED_ROOTFS}")
[[ "$FS" != / && -d "$FS/etc" && -d "$FS/usr" ]] || exit 2
make -C "$ROOT/test_app" sc7f0_ps_watchdog
install -D -m 0755 "$ROOT/test_app/sc7f0_ps_watchdog" "$FS/usr/bin/sc7f0_ps_watchdog"
for entry in "qpcie-debugd:20:30" "qpcie-hdmi-daemon:20:30" "qpcie-upgrade-daemon:180:120"; do
    IFS=: read -r service interval startup <<< "$entry"
    [[ -s "$FS/lib/systemd/system/$service.service" ]] || {
        echo "Required service missing: $service" >&2; exit 1;
    }
    dest="$FS/etc/systemd/system/$service.service.d"
    mkdir -p "$dest"
    printf '[Service]\nType=notify\nNotifyAccess=main\nWatchdogSec=%s\nTimeoutStartSec=%s\nTimeoutStopSec=5\nTimeoutAbortSec=5\nRestart=on-failure\nRestartSec=2\nEnvironment=SC7F0_HEALTH_DIR=/run/sc7f0-health\n' \
        "$interval" "$startup" > "$dest/10-watchdog.conf"
done
install -D -m 0644 \
    "$ROOT/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/qpcie-debugd/files/sc7f0-ps-watchdog.service" \
    "$FS/lib/systemd/system/sc7f0-ps-watchdog.service"
mkdir -p "$FS/etc/systemd/system/multi-user.target.wants" "$FS/etc/systemd/system.conf.d"
ln -sfn /lib/systemd/system/sc7f0-ps-watchdog.service \
    "$FS/etc/systemd/system/multi-user.target.wants/sc7f0-ps-watchdog.service"
# Never have PID1 and our progress-gated guardian race to own /dev/watchdog.
printf '[Manager]\nRuntimeWatchdogSec=0\nRebootWatchdogSec=0\n' \
    > "$FS/etc/systemd/system.conf.d/90-sc7f0-watchdog.conf"
PL_BASE=${SC7F0_PL_BASE_VERSION:-0x26102206}
[[ "$PL_BASE" =~ ^0x[0-9a-fA-F]{8}$ ]] || { echo 'Invalid PL base version' >&2; exit 2; }
printf 'sc7f0-ps-watchdog-20261027-r2\nPL_BASE_VERSION=%s\n' "$PL_BASE" \
    > "$FS/etc/sc7f0-recovery-release"
