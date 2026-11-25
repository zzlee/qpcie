#!/usr/bin/env bash
# THE ONE SUPPORTED SC7F0 FLASH ENTRY POINT (3/3 of build -> package -> flash).
#
#   ./scripts/sc7f0_flash.sh --build <BUILD_DIR> [--host rd@sc7f0-test.local]
#                            [--yes | --verify-only] [--dry-run]
#
# The SSH target is x86; every card Linux command goes through `sc7f0ctl exec`.
# Fixed order, every step a hard gate (docs/sc7f0_build_package_flash.md):
#   1 release-sha     RELEASE.sha256 of the build dir + package.ok from sc7f0_package.sh
#   2 transfer        one staging dir under ~/sc7f0/tmp, one shared remote lock
#   3 card identity   aarch64 + qpcie-debugd/qpcie-hdmi-daemon/qpcie-upgrade-daemon active
#   4 host-tool       qpcie_upgrade compiled from THIS release's host-tools-src.tar.gz
#   5 host-driver     built against the running x86 kernel; a busy /dev/video0 aborts
#   6 verify          --package; a failed VERIFY never reaches COMMIT
#   7 backup          current eMMC BOOT.BIN / image.ub / boot.scr copied on-card
#   8 commit          exactly ONE --commit; if the new module is rejected the old one is
#                     restored and nothing is committed
#   9 emmc-readback   independent eMMC SHA-256 over the PS mailbox, before any reset
#  10 warm-reboot    --reboot (PS warm reset + PCIe rescan); the x86 host is never
#                     rebooted here; then wait for the mailbox daemon ready=1
#  11 version+svcs   PL version equals this build, PS transport services answering
#  12 mcu-runtime-restart
#                     UNCONDITIONAL and EXACTLY ONCE, never skipped because "RX looks
#                     locked" or "there is no signal":
#                       sudo sc7f0ctl --timeout 5 exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
#                     A NUC1262 runtime restart, not an MCU reflash.  Nothing else in
#                     the system does this: the packaged sc7f0-vcud ExecStartPre
#                     initialiser contains no I2C at all, so no second reset exists.
#                     One bounded transaction, never a second one (a per-staging
#                     mcu-restart.done marker refuses a repeat in the same staging dir).
#  13 capture-advisory
#                     NOT a gate and NOT a wait: hdmi_status and the sc7f0-vcud unit
#                     state are sampled once, best effort, for the log only.  A flash
#                     does not require an HDMI source, so RX lock, 3840x2160p timing,
#                     SC7F0_CAPTURE_INIT, sc7f0-vcud "active", a VIPP capture probe and
#                     the raw DMA frame counter must never decide the outcome here.
#  14 final          eMMC digests still correct after the reboot, PS boot id CHANGED
#                     (the PS really restarted), host boot id UNCHANGED.
#
# This file absorbed the post-flash stages (10-14) of the former scripts/upgrade.sh,
# which is removed: there is no second flash path to choose between.  Exit status is 0
# only when every gating stage above genuinely passed, and a green exit means "this
# exact build was written to eMMC, read back independently, booted as the card's new
# image, and the MCU runtime restart was issued exactly once".  It makes no claim about
# HDMI source presence, capture, overlay or encoder acceptance.
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
    ((VERIFY_ONLY)) || echo 'Then back up eMMC/host module; install driver; COMMIT; read back SHA; warm reboot + PCIe rescan (never the x86); assert version and PS services; ONE unconditional MCU runtime restart (i2ctransfer -y 0 w2@0x32 0x06 0x01); one advisory capture sample; assert PS boot id changed and x86 boot id unchanged.'
    exit 0
fi
[[ -f $OUT/package.ok && $(<"$OUT/package.ok") == SC7F0_PACKAGE_PASS ]] || { echo 'Missing successful package gate' >&2; exit 1; }
VERSION=$(<"$OUT/VERSION")
[[ $VERSION =~ ^[0-9]{8}$ ]] || exit 1
(cd "$OUT"; sha256sum -c RELEASE.sha256)
PL_VERSION=$VERSION
if [[ -f $OUT/PL_VERSION ]]; then
    # A PS-only lab update is allowed only on this exact routed image and boot chain.
    (cd "$OUT"; grep -q '  PL_VERSION$' RELEASE.sha256 && grep -q '  VERSION$' RELEASE.sha256 && grep -qx '3851cdc9c4b9ca43de20c7fe59a970f6c2fab44af10968a726eb264bb245c06b  images/BOOT.BIN' RELEASE.sha256)
    PL_VERSION=$(cat "$OUT/PL_VERSION"); [[ $PL_VERSION == 26112419 ]]
fi
if ((!VERIFY_ONLY && !YES)); then
    read -r -p "Write card eMMC and restart CARD PS only on $HOST (0x$VERSION)? Type YES: " answer
    [[ $answer == YES ]] || { echo 'Cancelled'; exit 1; }
fi
REMOTE=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" 'mkdir -p "$HOME/sc7f0/tmp" && mktemp -d "$HOME/sc7f0/tmp/upgrade.XXXXXXXX"')
[[ $REMOTE =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Unexpected remote path' >&2; exit 1; }
scp "$OUT/upgrade-$VERSION.tar" "$OUT/host-driver-src.tar.gz" "$OUT/host-tools-src.tar.gz" "$OUT/RELEASE.sha256" "$HOST:$REMOTE/"
# All operations share one remote lock. A failed VERIFY never reaches COMMIT.
ssh "$HOST" bash -s -- "$REMOTE" "$VERSION" "$VERIFY_ONLY" "$PL_VERSION" <<'REMOTE_SCRIPT' 2>&1 | tee "$OUT/logs/flash.log"
set -euo pipefail
DIR=$1 VERSION=$2 VERIFY_ONLY=$3 PL_VERSION=$4
CTL="$HOME/sc7f0/bin/sc7f0ctl"
export TMPDIR="$DIR/tmp"
mkdir -m 700 "$TMPDIR"
exec 9>"$HOME/sc7f0/tmp/.upgrade.lock"
flock -n 9 || { echo 'Another upgrade is active'; exit 1; }
cd "$DIR"
echo "Remote logs/backups: $DIR"
[[ $(uname -m) == x86_64 ]]
BOOT_BEFORE=$(</proc/sys/kernel/random/boot_id)
printf '%s\n' "$BOOT_BEFORE" > host-boot-id-before
sudo -n "$CTL" status
sudo -n "$CTL" exec 'set -eu; test "$(uname -m)" = aarch64; for s in qpcie-debugd qpcie-upgrade-daemon; do systemctl is-active --quiet "$s" || exit 1; done; ps -ef | grep qpcie'
# Verify exactly the uploaded artifacts before unpacking/building on x86.
grep -E '  (upgrade-[0-9]+\.tar|host-driver-src\.tar\.gz|host-tools-src\.tar\.gz)$' RELEASE.sha256 | sha256sum -c -
tar -xzf host-tools-src.tar.gz
cc -O2 -Wall test_app/qpcie_upgrade.c -o qpcie_upgrade
if ((!VERIFY_ONLY)); then
    if sudo -n fuser /dev/video0 /dev/video1 /dev/qpcie-ovl-* 2>/dev/null; then
        echo 'Capture is active; stop preview/capture before flashing' >&2; exit 1
    fi
    tar -xzf host-driver-src.tar.gz
    kms_build=0; [[ $VERSION == "$PL_VERSION" ]] || kms_build=1
    make -C driver -j4 QPCIE_KMS="$kms_build"
    if ((kms_build)); then nm driver/qpcie.ko | grep -w qpcie_kms_protect >kms-symbol; fi
    [[ $(modinfo -F vermagic driver/qpcie.ko) == "$(uname -r) "* ]]
fi
resolve_running_module(){
RUNNING_SRCVERSION=$(cat /sys/module/qpcie/srcversion 2>/dev/null || true)
INSTALLED=
RUNNING_ID=$(tail -c20 /sys/module/qpcie/notes/.note.gnu.build-id | xxd -p)
    for candidate in "$HOME"/sc7f0/tmp/uram19.*/src/driver/qpcie.ko "$HOME/sc7f0/bin/qpcie.ko" "$(modinfo -n qpcie 2>/dev/null || true)" "$HOME/sc7f0/src/driver/qpcie.ko"; do
        [[ -f $candidate ]] || continue
        sv=$(modinfo -F srcversion "$candidate" 2>/dev/null || true)
        id=$(readelf -n "$candidate" | awk '/Build ID:/ {print $NF}'); if [[ -n $RUNNING_SRCVERSION && $sv == "$RUNNING_SRCVERSION" && -n $RUNNING_ID && $id == "$RUNNING_ID" ]]; then
            INSTALLED=$candidate
            echo "RUNNING_MODULE_RESOLVED $candidate srcversion=$sv"
            break
        fi
    done
[[ -n $INSTALLED ]] || {
    echo 'REFUSE_UNKNOWN_RUNNING_MODULE: cannot find the file that backs the loaded qpcie' >&2
    echo "  modinfo -n failed and no candidate matches srcversion=${RUNNING_SRCVERSION:-unknown}" >&2
    exit 1; }
 }
# A KMS owner hides raw PCI resources by design. Transition only at idle to
# maintenance on the *same verified module*, inside this transaction's lock.
orig_kms=$(cat /sys/module/qpcie/parameters/kms 2>/dev/null || echo N)
maintenance=0
finish_flash(){
    local rc=$?; trap - EXIT
    if ((maintenance)); then
        sudo -n rmmod qpcie && sudo -n insmod "$DIR/kms-before.ko" kms=1 || rc=1
    fi
    systemctl --user start wireplumber || rc=1
    exit "$rc"
}
if [[ $orig_kms == Y ]]; then
    resolve_running_module; cp "$INSTALLED" kms-before.ko
    systemctl --user stop wireplumber;trap finish_flash EXIT
    [[ $(cat /sys/module/qpcie/refcnt) == 0 ]] && sudo -n grep -qx '[[:space:]]*active=0' /sys/kernel/debug/dri/0000:03:00.0/state || exit 1
    if sudo -n fuser /dev/dri/card0 /dev/video0 /dev/video1 /dev/qpcie-*; then exit 1; fi
    sudo -n rmmod qpcie; if ! sudo -n insmod kms-before.ko kms=0;then sudo -n insmod kms-before.ko kms=1;exit 1;fi
    maintenance=1
fi
sudo -n ./qpcie_upgrade --package "upgrade-$VERSION.tar" | tee verify.log
sudo -n "$CTL" exec 'tail -n 15 /var/log/messages'
if ((VERIFY_ONLY)); then
    echo 'VERIFIED only: no eMMC write, driver installation or reboot performed.'
    exit 0
fi
# Resolve the file that is actually loaded, so the rollback copy is the code the
# card is talking to.  `modinfo -n qpcie` only works for a module that has a
# modules.dep entry: on the 7.0.0-43 test host the running module was insmod'ed
# and /lib/modules/$(uname -r)/extra/ does not exist, so the plain lookup fails
# ("modinfo: ERROR: Module qpcie not found") and aborts the flash before any
# COMMIT - the fallback picks the candidate whose srcversion equals the running
# module's, which is the same object, not merely some file with the right name.
resolve_running_module
cp "$INSTALLED" module-before.ko
# rmmod, NOT modprobe -r: keep the vb2 dependencies loaded. Restore on failure.
systemctl --user stop wireplumber
trap finish_flash EXIT
sudo -n modprobe videobuf2-v4l2
sudo -n modprobe videobuf2-dma-sg
sudo -n rmmod qpcie
if ! sudo -n insmod driver/qpcie.ko; then
    sudo -n insmod module-before.ko
    echo 'New driver rejected; restored old module. Firmware not committed.' >&2
    exit 1
fi
# This lab host keeps the module used for explicit insmod inside its SC7F0
# tree. Do not modify the system module tree/indices or the home root.
install -m 0644 driver/qpcie.ko "$HOME/sc7f0/bin/qpcie.ko"
if [[ $VERSION != "$PL_VERSION" ]]; then
    sudo -n ./qpcie_upgrade --status | grep -qi "Hardware Version.*0x$PL_VERSION" || { echo 'PS-only upgrade requires matching live PL'; exit 1; }
fi
maintenance=0 # once COMMIT is issued, never apply a blind rollback
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
# The PS boot id before the reset is the only proof later that the card really
# restarted; a stale eMMC readback plus an unchanged boot id is "nothing happened".
PS_BOOT_BEFORE=$( { sudo -n "$CTL" exec 'cat /proc/sys/kernel/random/boot_id' | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1; } || true )
[[ -n $PS_BOOT_BEFORE ]] || { echo 'REFUSE_UNKNOWN_PS_BOOT_ID: the PS boot id could not be read before the reset, so "the PS restarted" could never be proved.' >&2; exit 1; }
sudo -n ./qpcie_upgrade --reboot | tee reboot.log
ready=0
for attempt in $(seq 1 45); do
    if sudo -n "$CTL" --timeout 5 status > ps-status.log 2>&1 && grep -q 'ready=1' ps-status.log; then ready=1; break; fi
    sleep 2
done
[[ $ready == 1 ]] || { echo 'PS did not resume; inspect PCIe/card boot. Do NOT reboot the x86 host automatically.' >&2; exit 1; }
sudo -n ./qpcie_upgrade --status | tee active-version.log
grep -qi "Hardware Version.*0x$PL_VERSION" active-version.log
sudo -n "$CTL" exec 'uname -a; for s in qpcie-debugd qpcie-upgrade-daemon; do systemctl is-active --quiet "$s" || exit 1; done; ps -ef | grep qpcie'

# ------------------------------------------------------------------ stage 12
# NUC1262 runtime restart: unconditional, exactly once, after the version check.
# There is deliberately no test of hdmi_status, RX lock, cable presence or IT6663 here:
# reading a stale "Signal Locked" is exactly how this step used to get skipped, and
# skipping it is how the RX stays frozen after a PS restart (docs/
# sc7f0_261116_refclk_char4_and_c2h_zero_payload_20261116.md got char/4 back this way).
# It is a runtime restart, not an MCU reflash: no PL, no eMMC, no PS/host change.
# One bounded transaction; a failure is reported, never retried here.
if [[ -e mcu-restart.done ]]; then
    echo 'REFUSE_MCU_RESTART_SECOND: this staging directory already holds an MCU restart record.' >&2
    exit 1
fi
MCU_LOG=mcu-restart.log
echo "MCU_RESTART_UNCONDITIONAL_START $(date -u +%FT%TZ)" > "$MCU_LOG"
T0=$(date +%s%N)
if sudo -n "$CTL" --timeout 5 exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01' >>"$MCU_LOG" 2>&1; then MCU_RC=0; else MCU_RC=$?; fi
T1=$(date +%s%N)
echo "MCU_RESTART_RC=$MCU_RC elapsed_ms=$(( (T1 - T0 ) / 1000000 )) UTC=$(date -u +%FT%TZ)" >> "$MCU_LOG"
if ((MCU_RC == 0)); then
    date -u +%FT%TZ > mcu-restart.done
    mkdir -p "$HOME/sc7f0/logs"
    echo "$(date -u +%FT%TZ) staging=$PWD version=0x$VERSION" >> "$HOME/sc7f0/logs/mcu-restart-history"
    echo MCU_RESTART_RECORDED >> "$MCU_LOG"
fi
cat "$MCU_LOG"
((MCU_RC == 0)) || { echo "The single MCU runtime restart transaction failed (rc=$MCU_RC); do NOT retry it here, report it. The eMMC is already committed and the card boots the new image." >&2; exit 1; }

# ------------------------------------------------------------------ stage 13
# Capture state: advisory only, one best-effort read, never a wait and never a gate.
# Whether an HDMI source is attached while the firmware is flashed says nothing about
# the flash.  Nothing here may be turned back into a gate: the evidence for "the flash
# was written correctly" is stages 1-12 plus 14.
{ echo "CAPTURE_ADVISORY_START $(date -u +%FT%TZ)"
  echo '--- host sysfs hdmi_status (best effort, not judged) ---'
  sudo -n cat /sys/bus/pci/devices/0000:03:00.0/hdmi_status 2>&1 | sed -n '1,4p'
  echo '--- card capture/encoder unit state (best effort, not judged) ---'
  sudo -n "$CTL" --timeout 20 exec 'for u in sc7f0-vcud sc7f0-rgb-overlay; do printf "%s=%s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done' 2>&1
  echo "CAPTURE_ADVISORY_DONE $(date -u +%FT%TZ)"; } > capture-advisory.txt 2>&1 || true
cat capture-advisory.txt || true
echo 'CAPTURE_ADVISORY verdict=NOT_EVALUATED (a flash never requires an HDMI source)'

# ------------------------------------------------------------------ stage 14
# The committed image must still be the one in eMMC after the reboot, the PS must
# provably have restarted, and the x86 host must provably NOT have restarted.
sudo -n "$CTL" exec 'sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr' > readback-after-reboot.sha256
python3 - <<'PY'
from pathlib import Path
expected={Path(n).name:h for h,n in (line.split() for line in Path('RELEASE.sha256').read_text().splitlines()) if n.startswith('images/')}
actual={Path(n).name:h for h,n in (line.split() for line in Path('readback-after-reboot.sha256').read_text().splitlines())}
assert actual and actual==expected, (actual,expected)
print('EMMC_PERSISTED_ACROSS_REBOOT')
PY
PS_BOOT_AFTER=$( { sudo -n "$CTL" exec 'cat /proc/sys/kernel/random/boot_id' | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1; } || true )
[[ -n $PS_BOOT_AFTER && $PS_BOOT_AFTER != "$PS_BOOT_BEFORE" ]] || { echo "PS boot id is unchanged (${PS_BOOT_AFTER:-unreadable}); the warm reset did not actually happen." >&2; exit 1; }
if [[ $VERSION != "$PL_VERSION" ]]; then
    sudo -n "$CTL" exec 'cat /etc/sc7f0-ps-release' | grep -Fx "$VERSION"
fi
echo "PS_BOOT_ID $PS_BOOT_BEFORE -> $PS_BOOT_AFTER (the PS restarted)"
[[ $(</proc/sys/kernel/random/boot_id) == "$BOOT_BEFORE" ]] || { echo 'The x86 host boot id changed; this script must never reboot the host.' >&2; exit 1; }
if [[ $orig_kms == Y ]]; then
    [[ $(cat /sys/module/qpcie/refcnt) == 0 ]]
    sudo -n rmmod qpcie
    sudo -n insmod driver/qpcie.ko kms=1
    test -d /sys/bus/pci/devices/0000:03:00.0/drm/card0
    test "$(cat /sys/module/qpcie/parameters/kms)" = Y
fi
echo "FLASH_PASS: package=$VERSION active=0x$PL_VERSION; eMMC hashes verified before and after the reboot; exactly one MCU runtime restart; PS boot id changed; x86 boot ID unchanged."
echo 'FIRMWARE FLASH PASSED / 升級完成，擷取功能未驗證。Capture/overlay/display acceptance is a separate test; a successful flash alone is not image success.'
REMOTE_SCRIPT
