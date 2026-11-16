#!/usr/bin/env bash
# Prove what the SC7F0 PS really exposes as a display, using only the kernel DRM
# sysfs interface and upstream libdrm's modetest.  Read-only unless --pattern.
#
#   scripts/verify_sc7f0_hdmi_tx_drm.sh
#   scripts/verify_sc7f0_hdmi_tx_drm.sh --connector 92 --crtc 85 \
#       --mode 3840x2160-60 --fourcc RG24 --hold 45
#
# Why not just /dev/dri/card0: once the PL pipeline is described the ZynqMP can
# expose more than one DRM device, and the one that matters is whichever card is
# driven by xlnx_drm (the xlnx,pl-disp CRTC plus the HDMI TX encoder).  The card
# is chosen from /sys/class/drm/card*/device/driver and the connector from
# card*-HDMI-A-* beneath it, so "card0" can never quietly stand in for the real
# HDMI output.
#
# Each card-side action is one bounded sc7f0ctl exec (AGENTS.md).  A transport
# failure is reported as a transport failure and is never read as "no display".
#
# --mode/--fourcc run, on the card:
#     sleep <hold> | modetest -D /dev/dri/cardN -s <conn>@<crtc>:<mode>@<fourcc>
# modetest blocks in getchar() after setting the mode and calls clear_mode() when
# stdin reaches EOF (tests/modetest/modetest.c tail), so tying stdin to a bounded
# sleep shows the pattern for exactly <hold> seconds and then releases DRM master
# instead of leaving a private holder behind.  xlnx_pl_disp exposes one plane
# format (xlnx,vformat), so the fourcc must be the one the device tree names;
# modetest's default XR24 would be rejected.
#
# No private kernel driver, daemon or MMIO accessor is involved; nothing is
# written on the x86 host outside --out, and the only card-side file is
# /tmp/modetest-*.log (tmpfs).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
HOST=${SC7F0_TEST_HOST:-rd@sc7f0-test.local}
CTL=${SC7F0CTL:-/home/rd/sc7f0/bin/sc7f0ctl}
OUT=${OUT:-$ROOT/build/hdmi-tx-drm-verify-$(date -u +%Y%m%dT%H%M%SZ)}
MODE="" FOURCC=RG24 HOLD=45 CARD="" CONNECTOR="" CRTC=""
while (($#)); do
    case "$1" in
        --host) HOST=${2:?}; shift 2;;
        --ctl) CTL=${2:?}; shift 2;;
        --out) OUT=${2:?}; shift 2;;
        --mode) MODE=${2:?}; shift 2;;
        --fourcc) FOURCC=${2:?}; shift 2;;
        --hold) HOLD=${2:?}; shift 2;;
        --card) CARD=${2:?}; shift 2;;
        --connector) CONNECTOR=${2:?}; shift 2;;
        --crtc) CRTC=${2:?}; shift 2;;
        -h|--help) sed -n '2,32p' "$0"; exit 0;;
        *) echo "unknown argument $1" >&2; exit 2;;
    esac
done
[[ -e $OUT ]] && { echo "OUT=$OUT already exists" >&2; exit 1; }
mkdir -p "$OUT"
fail() { printf '\nDRM_VERIFY_FAIL: %s\nlogs: %s\n' "$1" "$OUT" >&2; exit 1; }
# rexec <outfile> <timeout> <card command>: the command travels as one argument of
# the remote shell, so no nested quoting layer can split it (the second flash entry
# point that used to sit in scripts/ is exactly how that bug was found).
rexec() {
    local file=$1 t=$2 cmd=$3
    rssh bash -s -- "$CTL" "$t" "$cmd" > "$file" 2>&1 <<'EOS'
set -eu
CTL=$1; T=$2; shift 2
sudo -n "$CTL" --timeout "$T" exec "$1"
EOS
}
rssh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

rssh true >"$OUT/ssh-probe.log" 2>&1 || \
    fail "cannot reach $HOST: transport failure, which says nothing about the display"
rssh sudo -n "$CTL" --timeout 10 status > "$OUT/card-status.txt" 2>&1 || \
    fail "sc7f0ctl status failed; mailbox/transport problem, not a display problem"
grep -q 'ready=1' "$OUT/card-status.txt" || fail "card mailbox daemon is not ready"
BOOT_ID=$(rssh bash -s -- "$CTL" <<'EOS' | tail -1
sudo -n "$1" --timeout 20 exec 'cat /proc/sys/kernel/random/boot_id'
EOS
) || fail "could not read the PS boot id (transport)"
printf 'boot_id=%s\n' "$BOOT_ID" | tee "$OUT/boot-id.txt"

# --- transaction 1: enumerate DRM devices; select the xlnx_drm card ----------
read -r -d '' ENUM <<'EOF' || true
for c in /sys/class/drm/card*; do
  [ -d "$c" ] || continue
  case "$(basename "$c")" in *-*|render*|event*) continue;; esac
  d=$(readlink -f "$c/device/driver" 2>/dev/null)
  printf 'CARD %s driver=%s\n' "$(basename "$c")" "${d##*/}"
  for n in "$c"/*-*; do
    [ -d "$n" ] || continue
    printf '  CONNECTOR %s status=%s enabled=%s dpms=%s modes=[%s]\n' \
      "$(basename "$n")" "$(cat "$n/status" 2>/dev/null)" "$(cat "$n/enabled" 2>/dev/null)" \
      "$(cat "$n/dpms" 2>/dev/null)" "$(cut -d' ' -f1 "$n/modes" 2>/dev/null | tr '\n' ' ')"
  done
done
ls -l /dev/dri 2>/dev/null
EOF
rexec "$OUT/drm-enumeration.txt" 25 "$ENUM" || \
    fail "DRM enumeration exec failed (transport)"
cat "$OUT/drm-enumeration.txt"
XLNX_CARD=${CARD:-$(sed -n 's/^CARD \(card[0-9]*\) driver=xlnx_drm$/\1/p' \
    "$OUT/drm-enumeration.txt" | head -1)}
if [[ -z $XLNX_CARD ]]; then
    rexec "$OUT/dmesg-drm.txt" 25 \
        'dmesg | grep -iE "xlnx|drm|hdmi|vphy|frmbuf|retimer|pl-disp" | tail -n 120' || true
    cat "$OUT/dmesg-drm.txt" 2>/dev/null
    fail "no DRM card is driven by xlnx_drm (cards seen: $(sed -n 's/^CARD \(card[0-9]*\) driver=\(.*\)$/\1=\2/p' "$OUT/drm-enumeration.txt" | tr '\n' ' ')); the kernel's own reason is in dmesg-drm.txt"
fi
printf 'XLNX_DRM_CARD=%s (selected from sysfs driver link, not assumed)\n' "$XLNX_CARD" \
    | tee "$OUT/card-selected.txt"

# --- transaction 2: connector detail under that card -------------------------
TMPL='for n in /sys/class/drm/__CARD__-*; do
  [ -d "$n" ] || continue
  echo "CONNECTOR $(basename "$n")"
  echo "  status=$(cat "$n/status") enabled=$(cat "$n/enabled") dpms=$(cat "$n/dpms")"
  echo "  modes:"; sed "s/^/    /" "$n/modes"
done'
rexec "$OUT/connector-detail.txt" 25 "${TMPL//__CARD__/$XLNX_CARD}" || \
    fail "connector detail exec failed (transport)"
cat "$OUT/connector-detail.txt"

# --- transaction 3: upstream modetest, query only ----------------------------
TMPL='command -v modetest >/dev/null || { echo "modetest is NOT in this image"; exit 3; }
modetest -D __NODE__ -c -p 2>&1 | head -n 120'
rexec "$OUT/modetest-query.txt" 30 "${TMPL//__NODE__/\/dev\/dri\/$XLNX_CARD}" || true
cat "$OUT/modetest-query.txt"
grep -q 'modetest is NOT in this image' "$OUT/modetest-query.txt" && \
    fail "modetest (libdrm-tests) is missing from the running image"
grep -qiE 'connectors:|CRTCs:|planes:' "$OUT/modetest-query.txt" || \
    fail "modetest returned no DRM topology; see modetest-query.txt"

if [[ -z $MODE ]]; then
    printf '\nDRM_VERIFY_ENUMERATION_ONLY (add --mode/--connector/--crtc to set a pattern)\n'
    printf 'connector and crtc ids for the next step are in %s/modetest-query.txt\n' "$OUT"
    exit 0
fi
[[ -n $CONNECTOR && -n $CRTC ]] || \
    fail "--mode needs --connector <id> and --crtc <id> read out of modetest-query.txt; refusing to guess ids"

# --- transaction 4: one bounded fixed-pattern pass ---------------------------
CARD_LOG=/tmp/modetest-$(date -u +%Y%m%dT%H%M%SZ).log
# nohup + background: the mailbox exec returns in bounded time while the pattern
# holder keeps running; modetest's stdin is a bounded sleep, so it clears the mode
# by itself after __HOLD__ seconds.
TMPL='nohup sh -c '"'"'sleep __HOLD__ | modetest -D __NODE__ -s __CONN__@__CRTC__:__MODE__@__FCC__'"'"' > __LOG__ 2>&1 &
sleep 2
echo "modetest_running=$(pgrep -f '"'"'modetest -D'"'"' | head -1) log=__LOG__"'
CMD=${TMPL//__HOLD__/$HOLD}
CMD=${CMD//__NODE__/\/dev\/dri\/$XLNX_CARD}
CMD=${CMD//__CONN__/$CONNECTOR}
CMD=${CMD//__CRTC__/$CRTC}
CMD=${CMD//__MODE__/$MODE}
CMD=${CMD//__FCC__/$FOURCC}
CMD=${CMD//__LOG__/$CARD_LOG}
rexec "$OUT/modetest-pattern-start.txt" 25 "$CMD" || fail "pattern start exec failed (transport)"
cat "$OUT/modetest-pattern-start.txt"
printf 'pattern %s@%s on connector=%s crtc=%s card=%s for %ss; card log: %s\n' \
    "$MODE" "$FOURCC" "$CONNECTOR" "$CRTC" "$XLNX_CARD" "$HOLD" "$CARD_LOG"

# --- transaction 5: read back while it is up, then after it released ---------
sleep $((HOLD / 2))
TMPL='for n in /sys/class/drm/__CARD__-*; do
  [ -d "$n" ] || continue
  echo "$(basename "$n") status=$(cat "$n/status") enabled=$(cat "$n/enabled") first_mode=$(cut -d" " -f1 "$n/modes" | head -1)"
done
echo "--- modetest output so far:"; cat __LOG__ 2>/dev/null'
CMD=${TMPL//__CARD__/$XLNX_CARD}
CMD=${CMD//__LOG__/$CARD_LOG}
rexec "$OUT/modetest-pattern-state.txt" 25 "$CMD" || true
cat "$OUT/modetest-pattern-state.txt"

sleep $((HOLD / 2 + 3))
TMPL='echo "--- modetest final output:"; cat __LOG__ 2>/dev/null
echo "--- dmesg tail:"; dmesg | tail -n 40'
rexec "$OUT/modetest-pattern-final.txt" 25 "${TMPL//__LOG__/$CARD_LOG}" || true
cat "$OUT/modetest-pattern-final.txt"

{
    printf 'card=%s connector=%s crtc=%s mode=%s fourcc=%s hold=%ss boot_id=%s\n' \
        "$XLNX_CARD" "$CONNECTOR" "$CRTC" "$MODE" "$FOURCC" "$HOLD" "$BOOT_ID"
    printf 'A mode being set and the connector reporting it is NOT proof that a person\n'
    printf 'saw light on the HDMI TX display; that human check is a separate required step.\n'
} > "$OUT/summary.txt"
printf '\nDRM_VERIFY_DONE logs=%s\n' "$OUT"
