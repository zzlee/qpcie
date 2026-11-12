#!/usr/bin/env bash
# SC7F0 single-entry firmware upgrade, run from the development machine.
#
#   ./scripts/upgrade.sh <path to upgrade-<VERSION>.tar> \
#       [--host rd@sc7f0-test.local] [--expect-host-ip 192.168.190.247] \
#       [--release-dir DIR] [--logs DIR] [--expect-pl-version 26111204] [--dry-run]
#
# This is the one supported entry point for a PS/PL firmware update.  It reuses the
# existing upgrade engine (test_app/qpcie_upgrade.c over PCIe, executed on the card by
# qpcie_upgrade_daemon) and does not invent a second flash protocol.
#
# Fixed order, every step a hard gate (docs/sc7f0_build_package_flash.md):
#   1  package-audit   strict-ustar 4 members + in-archive manifest + RELEASE.sha256 /
#                      release.json cross-check (scripts/check_sc7f0_upgrade_tar.py)
#   2  environment     strict host key + BatchMode; x86 host identity and expected
#                      service IP, card identity (aarch64 + 0x800-ABI daemon), idle
#                      (no capture client, no concurrent upgrade), free space both ends
#   3  transfer        one staging directory, digests re-verified on the host
#   4  host-tool       qpcie_upgrade compiled from THIS release's host-tools-src.tar.gz
#   5  backup          current eMMC BOOT.BIN / image.ub / boot.scr copied on-card
#   6  verify          --package; the board must reach Upgrade Status 0x05 VERIFIED
#   7  commit          exactly ONE --commit, and only after 0x05.  An unclear COMMIT
#                      outcome is never retried: it is reported and this script exits 1
#   8  emmc-readback   independent eMMC SHA-256 over the PS mailbox, before any reset
#   9  warm-reboot     --reboot (PS warm reset + PCIe rescan); the x86 host is never
#                      rebooted here; then wait for the 0x800 mailbox daemon ready=1
#   10 mcu-runtime-restart
#                      UNCONDITIONAL and EXACTLY ONCE, never skipped because "RX looks
#                      locked" or "there is no signal":
#                        sudo sc7f0ctl --timeout 5 exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
#                      A NUC1262 runtime restart, not an MCU reflash.  Nothing else in
#                      the system does this: the packaged sc7f0-vcud ExecStartPre
#                      initialiser contains no I2C at all, so no second reset exists.
#   11 capture-advisory
#                      NOT a gate and NOT a wait: hdmi_status and the sc7f0-vcud unit
#                      state are sampled once, best effort, for the log only.  A flash
#                      does not require an HDMI source to be attached, so RX lock,
#                      3840x2160p timing, the packaged SC7F0_CAPTURE_INIT marker,
#                      sc7f0-vcud reaching "active", the encoder journal lines, a VIPP
#                      capture probe and the raw DMA frame counter must never decide the
#                      outcome here.  Capture/encoder acceptance is a separate stage:
#                      host driver + v4l2/GStreamer, after a source is connected.
#   12 final           card PL version, eMMC digests still correct after reboot, PS boot
#                      id CHANGED (the PS really restarted), host boot id UNCHANGED,
#                      qpcie-debugd / qpcie-upgrade-daemon still answering after the boot
#
# The host network driver is NOT built, loaded or reloaded by this script: the upgrade
# runs over the driver that is already loaded.  Matching driver source is uploaded and
# the build command is printed at the end, to be run only after this script exits 0.
#
# Exit status is 0 only when every gating stage above genuinely passed.  A green exit
# means "this exact package was written to eMMC, read back independently, and booted as
# the card's new image with the MCU runtime restart issued"; it makes no claim about
# HDMI source presence, capture or encoder acceptance, none of which is required for a
# flash and none of which is waited for by this script.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOST=rd@sc7f0-test.local
EXPECT_HOST_IP=192.168.190.247
EXPECT_PL_VERSION=26111204
TAR= RELEASE_DIR= LOG_DIR= DRY=0
# Bounded waits.  Overridable so a mock run can exercise the abort paths quickly.
PS_READY_TIMEOUT=${SC7F0_UPGRADE_PS_READY_TIMEOUT:-300}   # sc7f0ctl ready=1 after warm reset
# Deliberately no RX-lock timeout and no capture-init timeout: nothing in the capture
# path is waited for, so an absent HDMI source can never time out an otherwise correct
# flash.  Capture acceptance has its own stage outside this script.
MIN_HOST_FREE_MB=4096
MIN_CARD_FREE_MB=40

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
SSH=(ssh "${SSH_OPTS[@]}")
SCP=(scp "${SSH_OPTS[@]}")
# Every remote command goes through this, so the ssh target can never be omitted and
# the first word of a command can never be mistaken for a hostname.
rssh() { "${SSH[@]}" "$HOST" "$@"; }
# Test-host SC7F0 artifacts live only under /home/rd/sc7f0 (see sc7f0/README.md on the host).
CTL_PROBE=${SC7F0CTL:-/home/rd/sc7f0/bin/sc7f0ctl}

usage() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'USAGE'

Options:
  --host USER@HOST        ssh target                 (default rd@sc7f0-test.local)
  --expect-host-ip IP     refuse a different host    (default 192.168.190.247)
  --expect-pl-version V   PL version the card must report (default 26111204)
  --release-dir DIR       dir with RELEASE.sha256, release.json, host-*-src.tar.gz
                          (default: <tar dir>/.. when that holds them, else <tar dir>)
  --logs DIR              evidence directory         (default build/upgrade-<V>-<stamp>)
  --dry-run               run stage 1 only, print the plan, touch no hardware
  -h, --help              this text
USAGE
}

while (($#)); do
    case "$1" in
        --host) HOST=${2:?}; shift 2;;
        --expect-host-ip) EXPECT_HOST_IP=${2:?}; shift 2;;
        --expect-pl-version) EXPECT_PL_VERSION=${2:?}; shift 2;;
        --release-dir) RELEASE_DIR=${2:?}; shift 2;;
        --logs) LOG_DIR=${2:?}; shift 2;;
        --dry-run) DRY=1; shift;;
        -h|--help) usage; exit 0;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2;;
        *) TAR=$1; shift;;
    esac
done
[[ -n $TAR ]] || { usage >&2; exit 2; }
[[ $HOST =~ ^[A-Za-z0-9_.@-]+$ ]] \
    || { echo "refusing to interpret --host value: $HOST" >&2; exit 2; }

STAGE=arguments
LOG_FILE=
fail() {
    printf '\nUPGRADE_FAIL stage=%s rc=%s msg=%s\n' "$STAGE" "${1:-1}" "${2:-}"
    printf 'UPGRADE_FAIL log=%s\n' "${LOG_FILE:-<not opened>}"
    exit "${1:-1}"
}
step() { STAGE=$1; printf '\n===== STAGE %s %s =====\n' "$STAGE" "$(date -u +%FT%TZ)"; }
ok()   { printf 'STAGE_OK %s rc=0 %s\n' "$STAGE" "${1:-}"; }

# --------------------------------------------------------------------------- stage 0
[[ -f $TAR ]] || { echo "no such upgrade package: $TAR" >&2; exit 2; }
TAR=$(realpath -- "$TAR")
[[ -s $TAR ]] || { echo "upgrade package is empty: $TAR" >&2; exit 2; }
BUNDLE=$(basename -- "$TAR")
[[ $BUNDLE =~ ^upgrade-([0-9]{8})\.tar$ ]] \
    || { echo "package name must be upgrade-<8 digits>.tar, got $BUNDLE" >&2; exit 2; }
VERSION=${BASH_REMATCH[1]}

if [[ -z $RELEASE_DIR ]]; then
    parent=$(dirname -- "$(dirname -- "$TAR")")
    if [[ -f $parent/RELEASE.sha256 && -f $parent/release.json ]]; then RELEASE_DIR=$parent
    else RELEASE_DIR=$(dirname -- "$TAR"); fi
fi
RELEASE_DIR=$(realpath -- "$RELEASE_DIR")
for f in RELEASE.sha256 release.json host-tools-src.tar.gz host-driver-src.tar.gz; do
    [[ -f $RELEASE_DIR/$f ]] || { echo "release dir $RELEASE_DIR is missing $f" >&2; exit 2; }
done

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG_DIR=${LOG_DIR:-$ROOT/build/upgrade-$VERSION-$STAMP}
mkdir -p "$LOG_DIR" || { echo "cannot create $LOG_DIR" >&2; exit 2; }
LOG_FILE=$LOG_DIR/upgrade.log

# One development-machine run at a time; the lock is held for this process' lifetime.
mkdir -p "$ROOT/build"
exec 9>"$ROOT/build/.sc7f0-upgrade.lock"
flock -n 9 || { echo 'another scripts/upgrade.sh is running on this machine' >&2; exit 1; }

exec > >(tee -a "$LOG_FILE") 2>&1
umask 022
printf 'SC7F0_UPGRADE_START %s host=%s bundle=%s version=%s\n' \
    "$STAMP" "$HOST" "$TAR" "$VERSION"
printf 'release_dir=%s log=%s\n' "$RELEASE_DIR" "$LOG_FILE"

# --------------------------------------------------------------------------- stage 1
step package-audit
python3 - "$RELEASE_DIR" "$TAR" "$VERSION" <<'PY' || fail 1 "release digests"
import hashlib, json, sys
from pathlib import Path
rel, tar, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
data = json.loads((rel / 'release.json').read_text())
assert data.get('version') == version, \
    'release.json version %s != package %s' % (data.get('version'), version)
lines = [l.split() for l in (rel / 'RELEASE.sha256').read_text().splitlines() if l.strip()]
assert lines, 'RELEASE.sha256 is empty'
by_path = {n: h for h, n in lines}
by_name = {}
for n, h in by_path.items():
    assert by_name.get(Path(n).name, h) == h, 'RELEASE.sha256 lists %s twice with different digests' % n
    by_name[Path(n).name] = h
assert by_path == data['sha256'], \
    'release.json and RELEASE.sha256 disagree: %s' % (set(by_path.items()) ^ set(data['sha256'].items()))
assert tar.name in by_name, 'RELEASE.sha256 does not record %s' % tar.name
for path, h in by_path.items():
    p = rel / path
    assert p.is_file(), 'RELEASE.sha256 names %s, which is not in the release dir' % path
    assert hashlib.sha256(p.read_bytes()).hexdigest() == h, 'release-dir copy of %s does not match' % path
assert by_name[tar.name] == hashlib.sha256(tar.read_bytes()).hexdigest(), \
    'the upgrade bundle bytes do not match RELEASE.sha256'
print('RELEASE_DIGESTS_CONSISTENT %s manifest_entries=%d' % (tar.name, len(by_path)))
PY
python3 "$ROOT/scripts/check_sc7f0_upgrade_tar.py" "$TAR" --release-dir "$RELEASE_DIR" \
    > "$LOG_DIR/package-audit.txt" 2>&1 || fail 1 "see $LOG_DIR/package-audit.txt"
tail -2 "$LOG_DIR/package-audit.txt"
python3 - "$TAR" "$LOG_DIR/package-members.json" <<'PY' || fail 1 "member digests"
import hashlib, json, sys
from pathlib import Path
blob = Path(sys.argv[1]).read_bytes()
members, off = [], 0
while off + 512 <= len(blob):
    h = blob[off:off + 512]
    if h == bytes(512):
        break
    name = h[0:100].split(b'\0')[0].decode('ascii', 'replace')
    size = int(h[124:136].split(b'\0')[0] or b'0', 8)
    payload = blob[off + 512:off + 512 + size]
    members.append({'name': name, 'size': size,
                    'sha256': hashlib.sha256(payload).hexdigest()})
    off += 512 + ((size + 511) // 512) * 512
assert [m['name'] for m in members] == ['BOOT.BIN', 'image.ub', 'boot.scr', 'manifest.sha256'], \
    [m['name'] for m in members]
Path(sys.argv[2]).write_text(json.dumps(members, indent=2) + '\n')
print('PACKAGE_MEMBERS ' + ' '.join('%s:%d' % (m['name'], m['size']) for m in members))
PY
ok "members=4 digests cross-checked"

if ((DRY)); then
    printf '\nDRY_RUN: package audited; nothing transferred and no hardware touched.\n'
    printf 'Plan: transfer -> host-tool -> backup -> VERIFY(0x05) -> ONE COMMIT -> eMMC SHA\n'
    printf '      -> warm reboot -> ONE unconditional MCU runtime restart -> final\n'
    printf '      (capture state is recorded once as advice; it is never waited for)\n'
    exit 0
fi

# --------------------------------------------------------------------------- stage 2
step environment
rssh true || fail 1 "ssh to $HOST failed (BatchMode + StrictHostKeyChecking=yes)"
HOSTINFO=$(rssh 'uname -m; hostname; ip -o -4 addr show 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | tr "\n" " "; echo; cat /proc/sys/kernel/random/boot_id; df -m --output=avail / | tail -1') \
    || fail 1 "host probe"
HOST_ARCH=$(printf '%s\n' "$HOSTINFO" | sed -n 1p)
HOST_NAME=$(printf '%s\n' "$HOSTINFO" | sed -n 2p)
HOST_IPS=$(printf '%s\n' "$HOSTINFO" | sed -n 3p)
HOST_BOOT_ID=$(printf '%s\n' "$HOSTINFO" | sed -n 4p)
HOST_FREE_MB=$(printf '%s\n' "$HOSTINFO" | sed -n 5p | tr -dc '0-9')
printf 'host name=%s arch=%s ips=%s boot_id=%s free=%sMB\n' \
    "$HOST_NAME" "$HOST_ARCH" "$HOST_IPS" "$HOST_BOOT_ID" "$HOST_FREE_MB"
[[ $HOST_ARCH == x86_64 ]] || fail 1 "the test host is not x86_64"
[[ " $HOST_IPS " == *" $EXPECT_HOST_IP "* ]] \
    || fail 1 "$HOST does not answer on the expected $EXPECT_HOST_IP (got: $HOST_IPS)"
# One field per line, or every later check would read the wrong value.
[[ $(printf '%s\n' "$HOSTINFO" | wc -l) -eq 5 ]] \
    || fail 1 "the host probe did not return 5 lines: $(printf '%s' "$HOSTINFO" | tr '\n' '|')"
[[ $HOST_IPS =~ ([0-9]{1,3}\.){3}[0-9]{1,3} ]] || fail 1 "host probe returned no IPv4 address: '$HOST_IPS'"
[[ $HOST_BOOT_ID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || fail 1 "host probe returned no boot id, got '$HOST_BOOT_ID'"
[[ $HOST_FREE_MB =~ ^[0-9]+$ ]] || fail 1 "host probe returned no free-space number, got '$HOST_FREE_MB'"
(( ${HOST_FREE_MB:-0} >= MIN_HOST_FREE_MB )) \
    || fail 1 "host free ${HOST_FREE_MB}MB is below ${MIN_HOST_FREE_MB}MB"

rssh sudo -n "$CTL_PROBE" --timeout 10 status > "$LOG_DIR/card-status-before.txt" 2>&1 \
    || { cat "$LOG_DIR/card-status-before.txt" >&2; fail 1 "sc7f0ctl status over the loaded driver"; }
cat "$LOG_DIR/card-status-before.txt"
grep -q 'ready=1' "$LOG_DIR/card-status-before.txt" || fail 1 "the card mailbox daemon is not ready"
CARD_ABI=$(sed -n 's/.*ABI=\([0-9a-fA-Fx]*\).*/\1/p' "$LOG_DIR/card-status-before.txt" | head -1)
CARD_EPOCH=$(sed -n 's/.*card_epoch=\([0-9a-fA-F]*\).*/\1/p' "$LOG_DIR/card-status-before.txt" | head -1)
[[ -n $CARD_ABI && -n $CARD_EPOCH ]] || fail 1 "sc7f0ctl status reports no ABI/card_epoch"
printf 'card mailbox ABI=%s card_epoch=%s\n' "$CARD_ABI" "$CARD_EPOCH"

# Everything with quoting inside goes through a here-doc: ssh joins its arguments with
# spaces and the remote shell re-parses them, so a quoted sc7f0ctl exec argument passed
# as a command-line word arrives split, and the remainder runs on the x86 host instead
# of on the card.  That is a false "card identity" result, not a card failure.
rssh bash -s -- "$CTL_PROBE" <<'EOS' > "$LOG_DIR/card-identity-before.txt" 2>&1 \
    || { cat "$LOG_DIR/card-identity-before.txt" >&2; fail 1 "card identity / service check"; }
set -eu
CTL=$1
sudo -n "$CTL" --timeout 20 exec 'set -eu; test "$(uname -m)" = aarch64; uname -r; cat /proc/sys/kernel/random/boot_id; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon; do systemctl is-active --quiet "$s" || { echo "inactive $s"; exit 1; }; done; df -m /run/media/BOOT-mmcblk0p1 | awk "NR==2{print \$4}"'
EOS
cat "$LOG_DIR/card-identity-before.txt"
PS_KERNEL=$(sed -n 1p "$LOG_DIR/card-identity-before.txt")
PS_BOOT_ID_BEFORE=$(sed -n 2p "$LOG_DIR/card-identity-before.txt")
CARD_FREE_MB=$(sed -n 3p "$LOG_DIR/card-identity-before.txt" | tr -dc '0-9')
[[ $PS_BOOT_ID_BEFORE =~ ^[0-9a-f-]{36}$ ]] || fail 1 "unreadable PS boot id"
printf 'card PS kernel=%s boot_id=%s BOOT free=%sMB\n' "$PS_KERNEL" "$PS_BOOT_ID_BEFORE" "$CARD_FREE_MB"
(( ${CARD_FREE_MB:-0} >= MIN_CARD_FREE_MB )) \
    || fail 1 "card BOOT partition free ${CARD_FREE_MB}MB is below ${MIN_CARD_FREE_MB}MB"

# Idle: this entry point refuses to evict somebody else's capture.
rssh bash -s <<'EOS' > "$LOG_DIR/idle-check.txt" 2>&1
set -u
F=$(command -v fuser || true)
[ -n "$F" ] || { echo "fuser is not available on the host; cannot prove the capture nodes are idle"; exit 1; }
busy=0
if "$F" /dev/video0 >/dev/null 2>&1 || "$F" /dev/video1 >/dev/null 2>&1; then
    echo "capture node busy:"; "$F" -v /dev/video0 /dev/video1 2>&1; busy=1
fi
for p in gst-launch-1.0 ffmpeg gst-launch; do
    if pgrep -x "$p" >/dev/null 2>&1; then echo "media process running:"; pgrep -ax "$p"; busy=1; fi
done
[ "$busy" -eq 0 ] || exit 1
echo IDLE_OK
EOS
idle_rc=$?
cat "$LOG_DIR/idle-check.txt"
(( idle_rc == 0 )) || fail 1 "/dev/video0 or /dev/video1 is busy, or a media process is running; stop your own test first (no eviction is performed here)"
ok "host=$HOST_NAME card_epoch=$CARD_EPOCH idle"

# --------------------------------------------------------------------------- stage 3
step transfer
REMOTE=$(rssh bash -s <<'EOS'
set -eu
mkdir -p "$HOME/sc7f0/tmp"
exec 9>"$HOME/sc7f0/tmp/.upgrade.lock"
flock -n 9 || { echo "another upgrade holds $HOME/sc7f0/tmp/.upgrade.lock"; exit 1; }
if ! mkdir "$HOME/sc7f0/tmp/.upgrade.mutex" 2>/dev/null; then
    echo "host upgrade mutex exists: $HOME/sc7f0/tmp/.upgrade.mutex" >&2
    echo "remove it only after confirming that no upgrade is actually running" >&2
    exit 1
fi
mktemp -d "$HOME/sc7f0/tmp/upgrade.XXXXXXXX"
EOS
)
transfer_rc=$?
if (( transfer_rc != 0 )); then printf '%s\n' "$REMOTE" >&2; fail "$transfer_rc" "host lock / staging directory"; fi
REMOTE=$(printf '%s\n' "$REMOTE" | tail -1)
[[ $REMOTE =~ ^/[A-Za-z0-9._/-]+$ && $REMOTE =~ /sc7f0/tmp/upgrade\.[A-Za-z0-9]{8}$ ]] \
    || fail 1 "unexpected staging path: $REMOTE"
printf 'staging=%s\n' "$REMOTE"
printf '%s\n' "$REMOTE" > "$LOG_DIR/staging-path.txt"
HELD_MUTEX=1
release_mutex() {
    if ((HELD_MUTEX)); then
        rssh 'rm -rf -- "$HOME/sc7f0/tmp/.upgrade.mutex"' >/dev/null 2>&1 || true
    fi
}
trap release_mutex EXIT

"${SCP[@]}" -q "$TAR" "$RELEASE_DIR/host-tools-src.tar.gz" "$RELEASE_DIR/host-driver-src.tar.gz" \
    "$RELEASE_DIR/RELEASE.sha256" "$HOST:$REMOTE/" || fail 1 "upload"
rssh bash -s -- "$REMOTE" "$BUNDLE" <<'EOS' > "$LOG_DIR/transfer-verify.txt" 2>&1 \
    || fail 1 "digest re-check on the host"
set -eu
cd "$1"
grep -E "  ($2|host-tools-src\.tar\.gz|host-driver-src\.tar\.gz)$" RELEASE.sha256 | sha256sum -c -
EOS
cat "$LOG_DIR/transfer-verify.txt"
ok "staged in $REMOTE"

# --------------------------------------------------------------------------- stage 4
step host-tool
rssh bash -s -- "$REMOTE" <<'EOS' > "$LOG_DIR/host-tool.log" 2>&1 \
    || { cat "$LOG_DIR/host-tool.log" >&2; fail 1 "qpcie_upgrade build"; }
set -eu
cd "$1"
test "$(uname -m)" = x86_64
tar -xzf host-tools-src.tar.gz
test -f test_app/qpcie_upgrade.c
cc -O2 -Wall test_app/qpcie_upgrade.c -o qpcie_upgrade
sha256sum qpcie_upgrade | tee qpcie_upgrade.sha256
EOS
cat "$LOG_DIR/host-tool.log"
ok "host tool built from this release's own sources"

# --------------------------------------------------------------------------- stage 5
step backup
rssh bash -s -- "$REMOTE" "$CTL_PROBE" <<'EOS' > "$LOG_DIR/backup.log" 2>&1 \
    || { cat "$LOG_DIR/backup.log" >&2; fail 1 "on-card eMMC backup"; }
set -eu
cd "$1"; CTL=$2
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
sudo -n "$CTL" --timeout 60 exec "set -eu; b=/run/media/BOOT-mmcblk0p1; for n in BOOT.BIN image.ub boot.scr; do test -s \$b/\$n; done; d=\$b/.backup_cli_$STAMP; mkdir \$d; for n in BOOT.BIN image.ub boot.scr; do cp \$b/\$n \$d/\$n; done; sync; sha256sum \$d/*"
EOS
grep -q backup_cli_ "$LOG_DIR/backup.log" || fail 1 "backup recorded nothing"
ok "previous eMMC images preserved on-card"

# --------------------------------------------------------------------------- stage 6
step verify
rssh bash -s -- "$REMOTE" "$BUNDLE" <<'EOS' > "$LOG_DIR/verify.log" 2>&1
set -eu
cd "$1"
echo "VERIFY_START $(date -u +%FT%TZ)"
sudo -n ./qpcie_upgrade --package "$2"
echo "VERIFY_RC=0 $(date -u +%FT%TZ)"
EOS
verify_rc=$?
tail -20 "$LOG_DIR/verify.log"
(( verify_rc == 0 )) || fail "$verify_rc" "VERIFY (--package) failed; COMMIT was NOT attempted"
grep -q '^VERIFY_RC=0' "$LOG_DIR/verify.log" || fail 1 "VERIFY did not report completion"

rssh bash -s -- "$REMOTE" <<'EOS' > "$LOG_DIR/verify-status.log" 2>&1
set -eu
cd "$1"
sudo -n ./qpcie_upgrade --status
EOS
status_rc=$?
cat "$LOG_DIR/verify-status.log"
(( status_rc == 0 )) || fail "$status_rc" "--status after VERIFY"
grep -Eq 'Upgrade Status[[:space:]]*:[[:space:]]*0x05' "$LOG_DIR/verify-status.log" \
    || fail 1 "the board did not report Upgrade Status 0x05 VERIFIED; COMMIT is refused"
grep -q 'VERIFIED' "$LOG_DIR/verify-status.log" \
    || fail 1 "upgrade status 0x05 is not the VERIFIED state"
ok "board Upgrade Status = 0x05 VERIFIED"

# --------------------------------------------------------------------------- stage 7
step commit
# Exactly one attempt, ever.  A transport failure in the middle of COMMIT leaves the
# outcome unknown and an unknown COMMIT must never be re-issued, so success here needs
# BOTH a zero exit status and the completion marker echoed after the tool returned.
rssh bash -s -- "$REMOTE" <<'EOS' > "$LOG_DIR/commit.log" 2>&1
set -eu
cd "$1"
if [ -e commit.done ]; then
    echo "this staging directory already holds a COMMIT record; refusing a second COMMIT" >&2
    exit 1
fi
echo "COMMIT_ATTEMPT_1 $(date -u +%FT%TZ)"
sudo -n ./qpcie_upgrade --commit
date -u +%FT%TZ > commit.done
echo COMMIT_RETURNED
EOS
commit_rc=$?
cat "$LOG_DIR/commit.log"
if (( commit_rc != 0 )) || ! grep -q '^COMMIT_RETURNED$' "$LOG_DIR/commit.log"; then
    # Read-only inspection only; this never re-issues --commit.
    rssh bash -s -- "$REMOTE" <<'EOS' > "$LOG_DIR/commit-outcome-probe.log" 2>&1 || true
cd "$1"; sudo -n ./qpcie_upgrade --status || true
EOS
    printf '\nCOMMIT_OUTCOME_UNCLEAR rc=%s\n' "$commit_rc"
    printf 'The COMMIT was issued exactly once and its result is not established.\n'
    printf 'Read-only probe written to %s\n' "$LOG_DIR/commit-outcome-probe.log"
    printf 'Do NOT re-run --commit and do NOT re-run this script expecting it to resume.\n'
    printf 'No reboot, rescan or reset was performed by this script.\n'
    fail 1 "COMMIT outcome unclear; manual inspection required"
fi
grep -Eqi 'COMMIT (reached|SUCCESS)|SUCCESS: eMMC upgrade committed' "$LOG_DIR/commit.log" \
    || fail 1 "the COMMIT transcript carries no success evidence"
ok "one COMMIT, board acknowledged"

# --------------------------------------------------------------------------- stage 8
step emmc-readback
rssh bash -s -- "$REMOTE" "$CTL_PROBE" <<'EOS' > "$LOG_DIR/emmc-readback.txt" 2>&1
set -eu
cd "$1"; CTL=$2
sudo -n "$CTL" --timeout 60 exec 'sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr'
EOS
readback_rc=$?
cat "$LOG_DIR/emmc-readback.txt"
(( readback_rc == 0 )) || fail "$readback_rc" "independent eMMC readback"
python3 - "$RELEASE_DIR" "$LOG_DIR/emmc-readback.txt" <<'PY' || fail 1 "eMMC readback mismatch"
import sys
from pathlib import Path
rel, back = Path(sys.argv[1]), Path(sys.argv[2])
want = {Path(n).name: h for h, n in
        (l.split() for l in (rel / 'RELEASE.sha256').read_text().splitlines()
         if l.strip() and Path(l.split()[1]).name in ('BOOT.BIN', 'image.ub', 'boot.scr'))}
have = {Path(n).name: h for h, n in
        (l.split() for l in back.read_text().splitlines()
         if len(l.split()) == 2 and len(l.split()[0]) == 64)}
assert have == want, ('have %s want %s' % (have, want))
print('EMMC_READBACK_SHA_PASS ' + ' '.join('%s=%s' % (n, have[n][:12]) for n in sorted(have)))
PY
ok "eMMC equals the release digests"

# --------------------------------------------------------------------------- stage 9
step warm-reboot
rssh bash -s -- "$REMOTE" <<'EOS' > "$LOG_DIR/reboot.log" 2>&1
set -eu
cd "$1"
echo "REBOOT_START $(date -u +%FT%TZ)"
sudo -n ./qpcie_upgrade --reboot
echo "REBOOT_RC=0 $(date -u +%FT%TZ)"
EOS
reboot_rc=$?
tail -20 "$LOG_DIR/reboot.log"
(( reboot_rc == 0 )) || fail "$reboot_rc" "--reboot failed; the eMMC is committed but the PS was not reset"
ready=0
for attempt in $(seq 1 $((PS_READY_TIMEOUT / 2))); do
    sleep 2
    if rssh sudo -n "$CTL_PROBE" --timeout 5 status > "$LOG_DIR/ps-ready-poll.txt" 2>&1 \
        && grep -q 'ready=1' "$LOG_DIR/ps-ready-poll.txt"; then
        ready=1
        printf 'PS mailbox ready=1 after %s polls (~%ss)\n' "$attempt" $((attempt * 2))
        break
    fi
done
(( ready == 1 )) || { tail -3 "$LOG_DIR/ps-ready-poll.txt" >&2
    fail 1 "the PS did not come back within ${PS_READY_TIMEOUT}s; inspect the card. This script will NOT reboot the x86 host."; }
cat "$LOG_DIR/ps-ready-poll.txt"
ok "PS warm reset done, 0x800 mailbox daemon ready"

# --------------------------------------------------------------------------- stage 10
step mcu-runtime-restart
# Unconditional by design.  There is deliberately no test of hdmi_status, RX lock, cable
# presence or IT6663 in this stage: reading a stale "Signal Locked" is exactly how this
# step used to get skipped, and skipping it is how the RX stays unfrozen after a PS
# restart.  One bounded transaction, never a second one.
rssh bash -s -- "$REMOTE" "$CTL_PROBE" <<'EOS' > "$LOG_DIR/mcu-restart.log" 2>&1
set -u
cd "$1"; CTL=$2
if [ -e mcu-restart.done ]; then
    echo "this staging directory already holds an MCU restart record; refusing a second one" >&2
    exit 1
fi
echo "MCU_RESTART_UNCONDITIONAL_START $(date -u +%FT%TZ)"
T0=$(date +%s%N)
sudo -n "$CTL" --timeout 5 exec 'i2ctransfer -y 0 w2@0x32 0x06 0x01'
rc=$?
T1=$(date +%s%N)
echo "MCU_RESTART_RC=$rc elapsed_ms=$(( (T1 - T0) / 1000000 )) UTC=$(date -u +%FT%TZ)"
[ "$rc" -eq 0 ] || exit "$rc"
date -u +%FT%TZ > mcu-restart.done
echo "$(date -u +%FT%TZ) staging=$PWD" >> "$HOME/sc7f0/logs/mcu-restart-history"
echo MCU_RESTART_RECORDED
EOS
restart_rc=$?
cat "$LOG_DIR/mcu-restart.log"
(( restart_rc == 0 )) || fail "$restart_rc" "the single MCU runtime restart transaction failed; do not retry it here, report it"
grep -q '^MCU_RESTART_RC=0' "$LOG_DIR/mcu-restart.log" || fail 1 "the MCU restart did not report rc=0"
grep -q '^MCU_RESTART_RECORDED$' "$LOG_DIR/mcu-restart.log" || fail 1 "the MCU restart was not recorded"
ok "exactly one unconditional NUC1262 runtime restart"

# --------------------------------------------------------------------------- stage 11
step capture-advisory
# Deliberately not a gate, and deliberately not a wait.  Whether an HDMI source is
# attached while the firmware is flashed says nothing about the flash: the operator
# connects the source later, and capture/encoder acceptance is its own stage on the host
# (driver + v4l2/GStreamer, docs/sc7f0_build_package_flash.md).  The stage below therefore
#   * reads the capture state ONCE, best effort, with no polling loop and no timeout,
#   * accepts "No Locked Timing", a missing sysfs node or a failed probe as information,
#   * accepts sc7f0-vcud staying activating/failed (with no source the packaged
#     initialiser refuses the geometry by design) as information,
#   * and never runs a VIPP capture probe, never reads the raw DMA frame counter and
#     never returns a verdict about capture.
# Nothing here may be turned back into a gate: the mandatory evidence for "the flash
# itself was written correctly" is stages 1-10 plus the final stage.
rssh bash -s -- "$CTL_PROBE" <<'EOS' > "$LOG_DIR/capture-advisory.txt" 2>&1 || true
CTL=$1
echo "CAPTURE_ADVISORY_START $(date -u +%FT%TZ)"
echo '--- host sysfs hdmi_status (best effort, not judged) ---'
sudo -n cat /sys/bus/pci/devices/0000:03:00.0/hdmi_status 2>&1 | sed -n '1,4p'
echo '--- card sc7f0-vcud unit state (best effort, not judged) ---'
sudo -n "$CTL" --timeout 20 exec 'systemctl show sc7f0-vcud.service -p ActiveState -p SubState -p NRestarts; journalctl -q -b -u sc7f0-vcud.service --no-pager 2>/dev/null | tail -6' 2>&1
echo "CAPTURE_ADVISORY_DONE $(date -u +%FT%TZ)"
EOS
printf -- '--- capture state: advisory only, never a gate ---\n'
cat "$LOG_DIR/capture-advisory.txt"
CAPTURE_STATE=$(grep -Eo 'ActiveState=[a-z-]+' "$LOG_DIR/capture-advisory.txt" 2>/dev/null | head -1)
printf 'CAPTURE_ADVISORY unit_state=%s verdict=NOT_EVALUATED\n' "${CAPTURE_STATE:-unavailable}"
printf 'FIRMWARE UPGRADE OK; capture NOT verified. 升級完成，擷取功能未驗證；連上 HDMI 後另驗。\n'
ok "capture state sampled once, not waited for and not gated"

# --------------------------------------------------------------------------- stage 12
step final
rssh bash -s -- "$REMOTE" "$CTL_PROBE" "$EXPECT_PL_VERSION" <<'EOS' > "$LOG_DIR/final.txt" 2>&1
set -eu
cd "$1"; CTL=$2; WANT=$3
sudo -n ./qpcie_upgrade --status
sudo -n "$CTL" --timeout 30 exec 'uname -a; cat /proc/sys/kernel/random/boot_id; for s in qpcie-debugd qpcie-hdmi-daemon qpcie-upgrade-daemon sc7f0-vcud; do printf "%s=%s\n" "$s" "$(systemctl is-active "$s" || true)"; done'
sudo -n "$CTL" --timeout 60 exec 'sha256sum /run/media/BOOT-mmcblk0p1/BOOT.BIN /run/media/BOOT-mmcblk0p1/image.ub /run/media/BOOT-mmcblk0p1/boot.scr'
EOS
final_rc=$?
cat "$LOG_DIR/final.txt"
(( final_rc == 0 )) || fail "$final_rc" "final verification"
grep -qi "Hardware Version.*0x$EXPECT_PL_VERSION" "$LOG_DIR/final.txt" \
    || fail 1 "the card does not report PL version 0x$EXPECT_PL_VERSION"
grep -q 'sc7f0-vcud=' "$LOG_DIR/final.txt" \
    || printf 'NOTE: the card reported no sc7f0-vcud state; capture is not judged here anyway\n'
# Core transport services only.  sc7f0-vcud is listed above for information and is NOT
# required: with no HDMI source attached the packaged initialiser refuses the geometry by
# design, so the unit legitimately stays activating/failed.  Capture acceptance is the
# operator's next stage, not a flash gate.
grep -q 'qpcie-debugd=active' "$LOG_DIR/final.txt" \
    || fail 1 "qpcie-debugd is not active after the reboot; the debug transport is unhealthy"
grep -q 'qpcie-upgrade-daemon=active' "$LOG_DIR/final.txt" \
    || fail 1 "qpcie-upgrade-daemon is not active after the reboot; the upgrade transport is unhealthy"
PS_BOOT_ID_AFTER=$(grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$LOG_DIR/final.txt" | tail -1)
HOST_BOOT_ID_AFTER=$(rssh cat /proc/sys/kernel/random/boot_id)
[[ -n $PS_BOOT_ID_AFTER && $PS_BOOT_ID_AFTER != "$PS_BOOT_ID_BEFORE" ]] \
    || fail 1 "PS boot id is unchanged ($PS_BOOT_ID_AFTER); the PS warm reset did not happen"
[[ $HOST_BOOT_ID_AFTER == "$HOST_BOOT_ID" ]] \
    || fail 1 "the x86 host boot id changed ($HOST_BOOT_ID -> $HOST_BOOT_ID_AFTER)"
python3 - "$RELEASE_DIR" "$LOG_DIR/final.txt" <<'PY' || fail 1 "eMMC digests after reboot"
import sys
from pathlib import Path
rel, back = Path(sys.argv[1]), Path(sys.argv[2])
want = {Path(n).name: h for h, n in
        (l.split() for l in (rel / 'RELEASE.sha256').read_text().splitlines()
         if l.strip() and Path(l.split()[1]).name in ('BOOT.BIN', 'image.ub', 'boot.scr'))}
have = {Path(n).name: h for h, n in
        (l.split() for l in back.read_text().splitlines()
         if len(l.split()) == 2 and len(l.split()[0]) == 64)}
assert have and have == want, ('have %s want %s' % (have, want))
print('EMMC_PERSISTED_ACROSS_REBOOT')
PY
ok "PL version + core services + boot ids + persistent eMMC digests"

rssh rm -rf -- "$REMOTE" >/dev/null 2>&1 || true
rssh 'rm -rf -- "$HOME/sc7f0/tmp/.upgrade.mutex"' >/dev/null 2>&1 || true
HELD_MUTEX=0
trap - EXIT

printf '\nUPGRADE_PASS version=%s host=%s bundle=%s\n' "$VERSION" "$HOST" "$BUNDLE"
printf '  bundle sha256    : %s\n' "$(sha256sum -- "$TAR" | cut -d' ' -f1)"
printf '  single COMMIT    : %s\n' "$LOG_DIR/commit.log"
printf '  single MCU reset : %s\n' "$LOG_DIR/mcu-restart.log"
printf '  eMMC readback    : %s and %s\n' "$LOG_DIR/emmc-readback.txt" "$LOG_DIR/final.txt"
printf '  capture advisory : %s (information only; never waited for, never a gate)\n' "$LOG_DIR/capture-advisory.txt"
printf '  PS boot id       : %s -> %s (the PS restarted)\n' "$PS_BOOT_ID_BEFORE" "$PS_BOOT_ID_AFTER"
printf '  host boot id     : %s (unchanged; the x86 host was never rebooted)\n' "$HOST_BOOT_ID_AFTER"
cat <<DONE

The matching host driver was deliberately not built or reloaded by this script; the
upgrade ran over the driver that was already loaded.  From now on, and only from now
on, build and install the driver of this same release:
  tar -xzf $RELEASE_DIR/host-driver-src.tar.gz && make -C driver -j4
then install it as docs/sc7f0_build_package_flash.md describes (no -f, no forced
unload).

FIRMWARE UPGRADE PASSED.  升級完成，擷取功能未驗證；連上 HDMI 後另驗。
This script never required, waited for or judged an HDMI source: no RX lock, no
3840x2160p timing, no capture-init journal marker, no sc7f0-vcud "active", no VIPP
capture probe and no raw DMA frame counter.  Capture and encoder acceptance is the next
stage and is run separately (host driver, then v4l2/GStreamer per
docs/sc7f0_build_package_flash.md) once a source is connected.  A green exit here must
never be reported as capture, encoder or 4K60 acceptance.
DONE
printf 'log=%s\n' "$LOG_FILE"
