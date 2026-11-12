#!/usr/bin/env bash
# Deploy the SC7F0 VCU capture package (0x26102902): one COMMIT, real PS boot proof.
# Derived from scripts/deploy_sc7f0_capture_r7.sh. No MCU operation, no host
# reboot, no arbitrary MMIO, no active-stream reset, no automatic retry.
#
# Added for this revision, because a VCU release can be staged before a matching
# PetaLinux build exists: the offline preflight below must prove that images/
# really were built from this release's own hardware.xsa (same bytes) and that the
# injected rootfs declares PL_BASE_VERSION=0x26102902.  A release carrying a
# baseline (R7 0x26102901) PS image is refused before any SSH session opens, so a
# VCU bitstream can never be committed to a card behind a device tree that has no
# VCU reference clock or register window.
#
# Usage:
#   scripts/deploy_sc7f0_capture_vcu.sh [--preflight-only] RELEASE_DIR [HOST]
#   SC7F0_PS_BUILD_DIR=build/ps-matching-<rev>.<stamp>   (matching PS build logs)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREFLIGHT_ONLY=0
if [[ ${1:-} == --preflight-only ]]; then PREFLIGHT_ONLY=1; shift; fi
OUT=$(realpath "${1:?RELEASE_DIR [HOST]}")
HOST=${2:-rd@sc7f0-test.local}
VERSION=${SC7F0_VERSION:-$(cat "$OUT/VERSION")}
PL_BASE=0x$VERSION
PACKAGE="upgrade-$VERSION.tar"
PS_BUILD=${SC7F0_PS_BUILD_DIR:-}

# --------------------------------------------------------------------------- #
# Offline preflight.  Local files only; nothing here touches the card.
# --------------------------------------------------------------------------- #
[[ $HOST != -* ]]
[[ $(<"$OUT/VERSION") == "$VERSION" ]] || { echo "VERSION mismatch: expected $VERSION" >&2; exit 1; }
[[ $(<"$OUT/build.ok") == SC7F0_BUILD_PASS ]]
[[ $(<"$OUT/package.ok") == SC7F0_PACKAGE_PASS ]]
[[ -s "$OUT/$PACKAGE" ]]
[[ ! -e "$OUT/NOT_DEPLOYABLE" ]] || {
    echo "Refusing to deploy: $OUT/NOT_DEPLOYABLE present:" >&2
    sed 's/^/    /' "$OUT/NOT_DEPLOYABLE" >&2; exit 1; }
python3 - "$OUT/release.json" "$OUT/PS_IMAGE_MATCH.json" "$VERSION" <<'PY'
import json, sys
from pathlib import Path
rel = json.loads(Path(sys.argv[1]).read_text())
ver = sys.argv[3]
assert rel['version'] == ver, (rel['version'], ver)
assert rel.get('deployable') is True, rel.get('not_deployable_reason', rel)
if Path(sys.argv[2]).exists():
    match = json.loads(Path(sys.argv[2]).read_text())
    assert match['deployable'] is True, match
    assert match['ps_image_pl_base_version'] == '0x' + ver, match
print('RELEASE_METADATA_DEPLOYABLE_PASS 0x' + ver)
PY
cd "$ROOT"
mkdir -p "$OUT/deployment"
# Strict archive structure must still hold for the bytes we are about to ship.
python3 "$ROOT/scripts/check_sc7f0_upgrade_tar.py" "$OUT/$PACKAGE" \
    --release-dir "$OUT" --json "$OUT/deployment/tar-structure-preflight.json" >/dev/null
sha256sum -c "$OUT/SOURCE.sha256" > "$OUT/deployment/source-check.log"
(cd "$OUT"; sha256sum -c RELEASE.sha256) > "$OUT/deployment/release-check.log"

# The decisive PL/PS match gate: the PS image must have been built from exactly
# this release's hardware XSA, and its injected release marker must say 0x26102902.
[[ -n "$PS_BUILD" ]] || {
    echo "SC7F0_PS_BUILD_DIR must point at the PetaLinux build logs for 0x26102902" >&2; exit 1; }
PS_BUILD=$(realpath "$PS_BUILD")
[[ $(<"$PS_BUILD/build.exit") == 0 && -f "$PS_BUILD/build.complete" ]] || {
    echo "matching PS build incomplete: $PS_BUILD" >&2; exit 1; }
python3 - "$PS_BUILD" "$OUT/fpga/hardware.xsa" <<'PY'
import hashlib, re, sys
from pathlib import Path
ps, xsa = Path(sys.argv[1]), Path(sys.argv[2])
recorded = re.search(r'([0-9a-f]{64})', (ps / 'imported-xsa.sha256').read_text())[1]
want = hashlib.sha256(xsa.read_bytes()).hexdigest()
assert recorded == want, ('PS image was built from a different hardware XSA',
                          recorded, want)
print('PS_MATCHED_XSA_PASS image.ub built from', xsa)
PY
grep -q "SC7F0_CAPTURE_IMAGE_AUDIT_PASS.*PL base $PL_BASE" \
    "$OUT/logs/capture-image-audit-after-package.log" || {
    echo "no capture-image audit pass for PL base $PL_BASE in $OUT/logs" >&2; exit 1; }
grep -q 'VCU_ADDRESS_MAP_COMPATIBLE\|pl_ps_address_map_compatible.*true' \
    "$OUT/logs/preflight/address-map.log" "$OUT/PS_IMAGE_MATCH.json" 2>/dev/null || {
    echo 'PL address-map compatibility vs the shipped baseline was never proven' >&2; exit 1; }
if (( PREFLIGHT_ONLY )); then
    printf 'SC7F0_VCU_PREFLIGHT_PASS %s: release is metadata-, archive-, source- and PS-match clean\n' "$VERSION"
    exit 0
fi

# --------------------------------------------------------------------------- #
# One deployment attempt against the card.
# --------------------------------------------------------------------------- #
[[ ! -e "$OUT/deployment/commit-issued" ]] || { echo 'COMMIT already issued: do not rerun' >&2; exit 1; }
sha256sum "${BASH_SOURCE[0]}" > "$OUT/deployment/deployment-tool.sha256"
REMOTE=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" 'mkdir -p "$HOME/sc7f0/tmp" && mktemp -d "$HOME/sc7f0/tmp/capture-vcu.XXXXXXXX"')
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
grep -E '  (upgrade-26102902.tar|host-driver-src.tar.gz|host-tools-src.tar.gz)$' RELEASE.sha256 | sha256sum -c -
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
# Gate: upgrade engine must be idle, and the card must not already run 0x26102902.
grep -qi 'IDLE / Ready' hardware-before.log || { echo 'Upgrade engine not IDLE before attempt; aborting with zero writes' >&2; exit 1; }
! grep -qi 'Hardware Version.*0x26102902' hardware-before.log || { echo 'Active version already 0x26102902: inspect prior evidence, do not re-flash' >&2; exit 1; }
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
sudo -n "$UPG" --package upgrade-26102902.tar | tee verify.log
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
            if sudo -n "$UPG" --status > hardware-after.log 2>&1 && grep -qi 'Hardware Version.*0x26102902' hardware-after.log; then
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
# VCU readiness is reported, never assumed: the encoder is only usable once the
# PS device tree of a matching build exposes it.
sudo -n "$CTL" --timeout 30 exec 'set -eu; uname -a; cat /proc/sys/kernel/random/boot_id; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon sc7f0-ps-watchdog; do printf "$s="; systemctl is-active "$s"; done; sc7f0_ps_watchdog --check-health /run/sc7f0-health; cat /etc/sc7f0-recovery-release; ls -l /dev/video* /dev/media*; ls -l /dev/vcu /sys/firmware/devicetree/base 2>/dev/null | grep -i -m8 vcu || printf "no VCU device-tree exposure\n"; sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr' | tee ps-after.log
sudo -n "$CTL" --timeout 30 exec 'dmesg | tail -n 150' > ps-dmesg-after.log
printf '%s\n' "$(</proc/sys/kernel/random/boot_id)" > host-boot-id-after
cmp host-boot-id-before host-boot-id-after
printf 'SC7F0_VCU_DEPLOY_PASS: single COMMIT, independent eMMC SHA, changed PS boot ID, unchanged host boot ID; runtime capture and encoder acceptance still required\n' | tee deployment.ok
REMOTE_SCRIPT
# Retrieval does not perform any hardware action or repeat an upgrade request.
scp -r "$HOST:$REMOTE" "$OUT/deployment/remote-evidence"
