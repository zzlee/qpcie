#!/usr/bin/env bash
# Prove what the SC7F0 PS really exposes as a display, using only the kernel DRM
# sysfs interface, upstream libdrm's modetest and read-only PL status registers.
# Read-only unless --mode is given.
#
#   scripts/verify_sc7f0_hdmi_tx_drm.sh                     # enumerate + gate
#   scripts/verify_sc7f0_hdmi_tx_drm.sh --mode 3840x2160-60 --hold 45
#   scripts/verify_sc7f0_hdmi_tx_drm.sh --mode 1024x768-60 --fourcc AR24
#
# Three things this script used to get wrong, each measured on the card on
# 2026-11-16 (build/g6g8-20261116T110140Z/03,04,05,06):
#
# 1. TRANSPORT.  ssh(1) joins its argv into ONE remote command string without
#    quoting, so `ssh host bash -s -- "$CTL" "$T" "$cmd"` delivers "$cmd" split
#    on every space and executed on the x86 host at that ';'.  Verified:
#    `ssh h bash -s -- a b "echo one; echo 'two words'"` arrives as argc=4.  The
#    card command therefore travels base64-encoded (shell-safe alphabet) and is
#    decoded on the host into a single argv element of `sc7f0ctl exec`.
# 2. CARD SELECTION.  On the RGB-compositor image the DRM device's driver link
#    is `xlnx-pl-disp` (device `drm-pl-disp-drv`), not `xlnx_drm`, so the old
#    exact-match sed found no card and the script refused to run at all.
# 3. MODETEST OPEN SYNTAX.  This image's modetest takes a MODULE name: `-M xlnx`
#    works, `-D /dev/dri/card0` prints "no device found" and then probes every
#    built-in driver name, i.e. it tested nothing while looking like a failure.
#    The open arguments are now probed, not assumed.
#
# The fourcc is likewise read out, not hardcoded: this persona's plane advertises
# AB24/AR24 (v_frmbuf_rd_rgb HAS_RGBA8/HAS_BGRA8), so the previous default RG24
# (RGB888) named a format the reader no longer implements.  --fourcc overrides and
# is checked against the plane before anything is attempted.
#
# Two gates were meant to refuse a modeset instead of letting the card take a
# synchronous external abort:
#   * the connector must report `connected` and at least one mode - with the sink
#     HPD low, xlnx_drm_hdmi's detect says disconnected,
#     drm_helper_probe_single_connector_modes() jumps to `exit` before
#     drm_add_modes_noedid(), so there is no mode to set;  this one stays.
#   * the VTC window at TX_SS+0x10000 had to answer.  THIS GATE IS NOW WRONG and
#     was demoted to advisory on 2026-11-17.  Its premise ("a DECERR at
#     TX_SS+0x10000 means the address segment is broken, therefore a modeset
#     would fault") is contradicted by three measurements:
#       - gate-level simulation of the DEPLOYED netlists routes 0xB0030000 to the
#         outer crossbar's M10, and the subsystem's own inner crossbar routes
#         +0x10000 to v_tc, on read and on write (docs/
#         sc7f0_txfix_26111701_findings.md sec.9);
#       - the TX SS's video clock (phy_tx_video_clk, fabric probe
#         0xA000069C) is 0 Hz until a commit programs the VPHY TX PLL, and v_tc's
#         clk is that same net - so the VTC cannot answer before a modeset;
#       - Xilinx's own driver refuses to read the VTC in exactly that state
#         (xv_hdmitxss.c:2408 "VTC version is not available for reading as
#         HDMI TX Video Clock is not ready", gated on IsStreamUp).
#     So "VTC aborts" and "tx_video_clk is 0" are the SAME observation, and using
#     it to block the only action that can ever raise that clock is circular.
#     The gate now blocks only on the combination that would actually fault:
#     tx_video_clk is running and the VTC still refuses.  --force still skips
#     everything.
#
# One more practical measurement, 2026-11-17: opening and closing a DRM master on
# this image costs 31.04 s by itself (modetest -M xlnx -c alone), because every
# release runs drm_fb_helper_restore_fbdev_mode_unlocked() and that commit waits
# 3 x 10 s for a flip_done that never arrives.  A candidate-probing loop that
# opens the device four times therefore cannot finish inside the card mailbox
# timeout and used to report "modetest opened no DRM device" - a transport
# artifact, not a display verdict.  The probe now stops at the first candidate
# that opens, and --mt-open / SC7F0_MT_OPEN states it outright.
#
# No private kernel driver or daemon writes anything; register reads use the
# image's own /usr/bin/peek and are strictly reads.  A peek that hits a bus error
# dies by SIGBUS in userspace and never reaches the kernel.  VPHY BANK_SELECT is
# deliberately untouched: writing a PHY control register to read a status
# register would disturb a PHY that is carrying live RX video.  Nothing is
# written on the x86 host outside --out and the only card-side files are
# /tmp/*.log (tmpfs).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
HOST=${SC7F0_TEST_HOST:-rd@sc7f0-test.local}
CTL=${SC7F0CTL:-/home/rd/sc7f0/bin/sc7f0ctl}
OUT=${OUT:-$ROOT/build/hdmi-tx-drm-verify-$(date -u +%Y%m%dT%H%M%SZ)}
MODE="" FOURCC="" HOLD=45 CARD="" CONNECTOR="" CRTC="" FORCE=0 MT_OPEN_OVERRIDE=${SC7F0_MT_OPEN:-}
TXSS_BASE=${TXSS_BASE:-0xB0020000}
VPHY_BASE=${VPHY_BASE:-0xB0000000}
PROBE_PINS=${PROBE_PINS:-0xA00006A0}      # BAR0 0x6A0, sc7f0_hdmi_probe pin levels
PROBE_CLKS=${PROBE_CLKS:-0xA0000680}      # BAR0 0x680, sc7f0_probe clock monitor base
VTC_OFFSET=${VTC_OFFSET:-0x10000}         # TXSS_VTC_OFFSET used by the driver
IRQ_NAME=${IRQ_NAME:-xilinx-hdmitxss}
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print} NR>1 && !/^#/ {exit}' "$0"; }
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
        --txss-base) TXSS_BASE=${2:?}; shift 2;;
        --vphy-base) VPHY_BASE=${2:?}; shift 2;;
        --probe-pins) PROBE_PINS=${2:?}; shift 2;;
        --probe-clks) PROBE_CLKS=${2:?}; shift 2;;
        --mt-open) MT_OPEN_OVERRIDE=${2:?}; shift 2;;
        --force) FORCE=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "unknown argument $1" >&2; exit 2;;
    esac
done
[[ -e $OUT ]] && { echo "OUT=$OUT already exists" >&2; exit 1; }
mkdir -p "$OUT"
fail() { printf '\nDRM_VERIFY_FAIL: %s\nlogs: %s\n' "$1" "$OUT" >&2; exit 1; }
verdict() { printf '\nDRM_VERIFY_%s: %s\nlogs: %s\n' "$1" "$2" "$OUT"; }
# rexec <outfile> <timeout> <card command>: base64 transport, see note 1.
rexec() {
    local file=$1 t=$2 cmd=$3 b64
    b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')
    rssh bash -s -- "$CTL" "$t" "$b64" > "$file" 2>&1 <<'EOS'
set -eu
CTL=$1; T=$2; B64=$3
sudo -n "$CTL" --timeout "$T" exec "$(printf '%s' "$B64" | base64 -d)"
EOS
}
rssh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }
# irqsum <file> <name> first|last : sum only the per-CPU columns of an
# /proc/interrupts line (stops at the first non-numeric field, so the GIC SPI
# number is never counted as an interrupt).
irqsum() {
    awk -v n="$2" -v w="$3" 'index($0, n) && $0 ~ /^[ ]*[0-9]+:/ {
            gsub(/,/, ""); s = 0
            for (i = 2; i <= NF; i++) { if ($i ~ /^[0-9]+$/) s += $i; else break }
            if (w == "first") { print s; exit }
            last = s
        } END { if (w != "first") print last + 0 }' "$1" 2>/dev/null
}
bit() { case "${1:-}" in 0x[0-9a-fA-F]*) [ $(( $1 & $2 )) -ne 0 ] && { echo 1; return; } ;; esac
          echo 0; }

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

# --- transaction 1: enumerate DRM devices; select the PL display card --------
read -r -d '' ENUM <<'EOF' || true
for c in /sys/class/drm/card*; do
  [ -d "$c" ] || continue
  case "$(basename "$c")" in *-*|render*|event*) continue;; esac
  d=$(readlink -f "$c/device/driver" 2>/dev/null)
  printf 'CARD %s driver=%s device=%s\n' "$(basename "$c")" "${d##*/}" \
    "$(basename "$(readlink -f "$c/device" 2>/dev/null)")"
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
# xlnx_drm (aggregate), xlnx-pl-disp (the component that registers the minor on
# this image) and xlnx-drm are all the PL display; anything else is not.
XLNX_CARD=${CARD:-$(awk '$1 == "CARD" { split($3, a, "=");
    if (a[2] == "xlnx_drm" || a[2] == "xlnx-pl-disp" || a[2] == "xlnx-drm") print $2 }' \
    "$OUT/drm-enumeration.txt" | head -1)}
if [[ -z $XLNX_CARD ]]; then
    rexec "$OUT/dmesg-drm.txt" 25 \
        'dmesg | grep -iE "xlnx|drm|hdmi|vphy|frmbuf|retimer|pl-disp" | tail -n 120' || true
    cat "$OUT/dmesg-drm.txt" 2>/dev/null
    fail "no DRM card is driven by the PL display driver (cards seen: $(awk '$1=="CARD"{print $2"="$3}' "$OUT/drm-enumeration.txt" | tr '\n' ' ')); the kernel's own reason is in dmesg-drm.txt"
fi
XLNX_DRV=$(awk -v c="$XLNX_CARD" '$1 == "CARD" && $2 == c { split($3, a, "="); print a[2]; exit }' \
    "$OUT/drm-enumeration.txt")
printf 'XLNX_DRM_CARD=%s driver=%s (selected from the sysfs driver link, not assumed)\n' \
    "$XLNX_CARD" "$XLNX_DRV" | tee "$OUT/card-selected.txt"

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
MODE_COUNT=$(grep -cE '^[[:space:]]+[0-9]+x[0-9]+' "$OUT/connector-detail.txt" || true)

# --- transaction 3: how does modetest actually open this device? -------------
# One candidate costs ~31 s (see header), so this loop must stop at the first
# hit, and it is skippable entirely with --mt-open.
if [[ -n $MT_OPEN_OVERRIDE ]]; then
    printf 'modetest_open=%s (given by --mt-open/SC7F0_MT_OPEN, not probed)\n' \
        "$MT_OPEN_OVERRIDE" | tee "$OUT/modetest-open.txt"
    MT_OPEN=$MT_OPEN_OVERRIDE
else
TMPL='command -v modetest >/dev/null || { echo "modetest is NOT in this image"; exit 3; }
for a in "-M xlnx" "-M __DRV__" "-M xlnx_drm"; do
  if modetest $a -c >/dev/null 2>&1; then echo "OPEN_OK $a"; break; fi
done
echo CANDIDATES_DONE'
CMD=${TMPL//__DRV__/$XLNX_DRV}
CMD=${CMD//__CARD__/$XLNX_CARD}
rexec "$OUT/modetest-open-probe.txt" 90 "$CMD" || true
grep -q 'modetest is NOT in this image' "$OUT/modetest-open-probe.txt" && \
    fail "modetest (libdrm-tests) is missing from the running image"
MT_OPEN=$(sed -n 's/^OPEN_OK //p' "$OUT/modetest-open-probe.txt" | head -1)
[[ -n $MT_OPEN ]] || fail "modetest opened no DRM device within the mailbox timeout (one open costs ~31 s on this image); re-run with --mt-open '-M xlnx' if that is the right spellling"
printf 'modetest_open=%s (probed, not assumed)\n' "$MT_OPEN" | tee "$OUT/modetest-open.txt"
fi

# --- transaction 4: topology -------------------------------------------------
# -c AND -p: this image's modetest prints "Connectors:" only for -c, and
# CRTCs/planes only for -p, so asking for one silently loses half the topology.
TMPL='modetest __OPEN__ -c -p 2>&1 | head -n 260'
# 30 s is not enough: one open/close of this device costs 31.04 s measured, because
# releasing the DRM master re-runs drm_fb_helper_restore_fbdev_mode_unlocked() and
# that commit waits 3 x 10 s for a flip_done that never arrives.
rexec "$OUT/modetest-query.txt" 120 "${TMPL//__OPEN__/$MT_OPEN}" || true
cat "$OUT/modetest-query.txt"
grep -qiE 'connectors:|CRTCs:|planes:' "$OUT/modetest-query.txt" || \
    fail "modetest returned no DRM topology; see modetest-query.txt"

CONN_LINE=$(awk '/^Connectors:/{f=1;next} f && $1 ~ /^[0-9]+$/{print; exit}' "$OUT/modetest-query.txt")
CONN_ID=${CONNECTOR:-$(awk '{print $1}' <<<"$CONN_LINE")}
CONN_STATUS=$(awk '{print $3}' <<<"$CONN_LINE")
CRTC_ID=${CRTC:-$(awk '/^CRTCs:/{f=1;next} f && $1 ~ /^[0-9]+$/{print $1; exit}' "$OUT/modetest-query.txt")}
PLANE_ID=$(awk '/^Planes:/{f=1;next} f && $1 ~ /^[0-9]+$/{print $1; exit}' "$OUT/modetest-query.txt")
PLANE_FMTS=$(sed -n 's/^[[:space:]]*formats: //p' "$OUT/modetest-query.txt" | head -1)
[[ -n $FOURCC ]] || FOURCC=$(tr ' ' '\n' <<<"$PLANE_FMTS" | grep -v '^$' | head -1 || true)
printf 'connector=%s status=%s crtc=%s plane=%s plane_formats=[%s] fourcc=%s modes=%s\n' \
    "${CONN_ID:-none}" "${CONN_STATUS:-unknown}" "${CRTC_ID:-none}" "${PLANE_ID:-none}" \
    "$PLANE_FMTS" "${FOURCC:-none}" "$MODE_COUNT" | tee "$OUT/topology.txt"
# a fourcc the reader does not implement is a certain failure; say so now
if [[ -n ${FOURCC:-} && -n $PLANE_FMTS ]] && ! grep -qw -- "$FOURCC" <<<"$PLANE_FMTS"; then
    fail "fourcc $FOURCC is not advertised by plane ${PLANE_ID:-?}; this persona's plane carries [$PLANE_FMTS]"
fi

# --- transaction 5: read-only hardware evidence ------------------------------
# Absolute addresses are computed on the card with shell arithmetic because
# /usr/bin/peek takes one address, not an expression.  Output is
# "<label> <addr> = <value>|BUS_ERROR(...)".
read -r -d '' HW <<'EOF' || true
rd(){ lbl=$1; addr=$2; o=$(peek "$addr" 2>/dev/null); rc=$?
  a=$(printf '0x%08X' "$addr")
  if [ "$rc" -ne 0 ] || [ -z "$o" ]; then echo "$lbl $a = BUS_ERROR(rc=$rc)"; else echo "$lbl $a = $o"; fi; }
B=__TXSS__; V=__VPHY__; P=__PINS__; C=__CLKS__
echo "== HDMI TX SS $B (v_hdmi_tx_ss) =="
rd version   $((B + 0x000))
rd pio_id    $((B + 0x0040))
rd pio_ctrl  $((B + 0x0044))
rd pio_sta   $((B + 0x0050))
rd pio_in    $((B + 0x0064))   # bit2 = HPD = sink cable detect
rd pio_evt   $((B + 0x0068))   # latched HPD edges
rd alias64   $((B + 0x1064))   # must differ from pio_in; equal means A[12] is lost
rd vtc       $((B + __VTCOFF__))
rd vtc_ctl   $((B + __VTCOFF__ + 0x000))
rd vtc_ver   $((B + __VTCOFF__ + 0x010))   # the VTC's own version, not the TX SS ID
rd vtc_a1000 $((B + __VTCOFF__ + 0x1000))  # equal to vtc means <=4 KiB alias up there
rd vtc_a8000 $((B + __VTCOFF__ + 0x8000))
rd vtc_alo   $((B + __VTCOFF__ - 0x4))     # last word of the LOWER slice
rd vtc_end   $((B + 0x20000))
echo "== VPHY $V (read-only, BANK_SELECT untouched) =="
rd version   $((V + 0x000))
rd pll_lock  $((V + 0x018))    # CPLL1..3 = 0x7, QPLL0/1 = 0x10/0x20
rd tx_init   $((V + 0x01C))    # TX reset request per channel
rd tx_initst $((V + 0x020))    # TX reset-done status
rd tx_status $((V + 0x078))    # bank selected: advisory only
rd intr_sts  $((V + 0x11C))
rd clkdet_st $((V + 0x204))
rd clkdet_rx $((V + 0x210))    # measured reference-clock frequency
echo "== fabric probe pin levels $P =="
rd probe_pins $P               # bit10 = raw sink HPD pin, bits12/13 = TX DDC
echo "== fabric clock monitor $C (rtl/axil_reg_space.v: BAR0 0x80..0x9C) =="
rd probe_version  $((C + 0x00))
rd rx_clk         $((C + 0x04))
rd rxoutclk       $((C + 0x0C))
rd rx_video_clk   $((C + 0x10))
rd tx_clk         $((C + 0x14))
rd txoutclk       $((C + 0x18))
rd tx_video_clk   $((C + 0x1C))   # == v_hdmi_tx_ss video_clk == phy_tx_video_clk
echo "== __IRQ__ interrupt lines =="
grep -w __IRQ__ /proc/interrupts || echo "  no __IRQ__ line"
EOF
CMD=${HW//__TXSS__/$TXSS_BASE}
CMD=${CMD//__VPHY__/$VPHY_BASE}
CMD=${CMD//__PINS__/$PROBE_PINS}
CMD=${CMD//__CLKS__/$PROBE_CLKS}
CMD=${CMD//__VTCOFF__/$VTC_OFFSET}
CMD=${CMD//__IRQ__/$IRQ_NAME}
rexec "$OUT/tx-hw-state-before.txt" 30 "$CMD" || true
cat "$OUT/tx-hw-state-before.txt"

# "<label> <addr> = <value>" -> the value is the last field (BUS_ERROR(...)
# carries parentheses, so never hardcode a column number).
hwval() { awk -v l="$1" '$1 == l {print $NF; exit}' "$OUT/tx-hw-state-before.txt"; }
VTC_VAL=$(hwval vtc)
VTC_OK=1; [[ $VTC_VAL == BUS_ERROR* || -z $VTC_VAL ]] && VTC_OK=0
PIO_IN=$(hwval pio_in)
RAW_PINS=$(hwval probe_pins)
HPD_HW=$(bit "$PIO_IN" 4)
RAW_HPD=$(bit "$RAW_PINS" 1024)
ALIAS64=$(hwval alias64)
ALIASED=0; [[ -n ${PIO_IN:-} && "$ALIAS64" == "$PIO_IN" ]] && ALIASED=1
VTC_VER=$(hwval vtc_ver); VTC_A1000=$(hwval vtc_a1000); VTC_ALO=$(hwval vtc_alo)
TXSS_ID_VAL=$(hwval version)
# The clock monitor is what makes the VTC reading interpretable.  Values are Hz
# as measured by the fabric's own counter, printed in hex by peek.
hertz() { local v; v=$(hwval "$1"); case "${v:-}" in 0x*) printf '%d' "$v";; *) printf '%s' "${v:-?}";; esac; }
TX_VIDEO_CLK=$(hertz tx_video_clk); TXOUTCLK=$(hertz txoutclk); TX_CLK=$(hertz tx_clk)
RX_VIDEO_CLK=$(hertz rx_video_clk); RXOUTCLK=$(hertz rxoutclk); RX_CLK=$(hertz rx_clk)
TX_VIDEO_CLK_UP=0; [[ ${TX_VIDEO_CLK:-0} =~ ^[0-9]+$ ]] && (( TX_VIDEO_CLK > 1000000 )) && TX_VIDEO_CLK_UP=1
printf 'clock monitor: rx_clk=%s rxoutclk=%s rx_video=%s | tx_clk=%s txoutclk=%s tx_video_clk=%s Hz\n' \
    "$RX_CLK" "$RXOUTCLK" "$RX_VIDEO_CLK" "$TX_CLK" "$TXOUTCLK" "$TX_VIDEO_CLK"
printf '  -> phy_tx_video_clk (v_hdmi_tx_ss video_clk, which is also what clocks v_tc) is %s\n' \
    "$([[ $TX_VIDEO_CLK_UP == 1 ]] && echo RUNNING || echo '0 Hz: no TX link has been programmed yet')"
# Two distinct failure shapes, both measured on 26111601: the whole upper 64 KiB
# DECERRing (bus error), and the upper half reading back the LOWER half (awaddr[16]
# / araddr[16] dropped, so 0xB0030000 is 0xB0020000).  They need different words.
VTC_ALIASED_TO_LOWER=0
[[ -n ${VTC_VAL:-} && -n ${TXSS_ID_VAL:-} && "$VTC_VAL" == "$TXSS_ID_VAL" ]] && VTC_ALIASED_TO_LOWER=1
VTC_ALIAS_4K=0
[[ -n ${VTC_VAL:-} && -n ${VTC_A1000:-} && "$VTC_VAL" == "$VTC_A1000" ]] && VTC_ALIAS_4K=1
printf 'VTC window decode: %s+%s=%s | own version=%s | +0x1000=%s | -0x4 (lower slice)=%s | TX SS id=%s\n' \
    "$TXSS_BASE" "$VTC_OFFSET" "${VTC_VAL:-?}" "${VTC_VER:-?}" "${VTC_A1000:-?}" \
    "${VTC_ALO:-?}" "${TXSS_ID_VAL:-?}"
printf '  -> %s; +0x000 vs +0x1000 %s\n' \
    "$([[ $VTC_ALIASED_TO_LOWER == 1 ]] && echo 'ALIASED ONTO THE LOWER SLICE (subsystem address bit 16 is not being delivered)' || echo 'upper half does not read back as the lower half')" \
    "$([[ $VTC_ALIAS_4K == 1 ]] && echo 'equal (reads as a 4 KiB alias, though two registers can also legitimately hold the same value - the window dump below is the decisive check)' || echo 'differ, so no alias at 4 KiB')"

if [[ -z $MODE ]]; then
    verdict ENUMERATION_ONLY "add --mode to attempt a pattern; connector=${CONN_ID:-?} status=${CONN_STATUS:-unknown} crtc=${CRTC_ID:-?} plane=${PLANE_ID:-?} formats=[$PLANE_FMTS]"
    printf 'TX cable detect: pio_in=%s hpd=%s | raw HPD pin(%s)=%s hpd=%s\n' \
        "${PIO_IN:-?}" "$HPD_HW" "$PROBE_PINS" "${RAW_PINS:-?}" "$RAW_HPD"
    if [[ $VTC_OK == 1 ]]; then VTC_READ="reachable"
    elif [[ $TX_VIDEO_CLK_UP == 1 ]]; then VTC_READ="UNREACHABLE WITH THE VIDEO CLOCK RUNNING - a real decode defect"
    else VTC_READ="refused as expected: v_tc is clocked by phy_tx_video_clk (${TX_VIDEO_CLK:-?} Hz), and xv_hdmitxss.c:2408 refuses to read it in that state too"; fi
    printf 'VTC window (%s+%s) = %s -> %s\n' "$TXSS_BASE" "$VTC_OFFSET" "${VTC_VAL:-?}" "$VTC_READ"
    printf 'TX SS address decode: pio_in=%s at+0x1064=%s -> %s\n' \
        "${PIO_IN:-?}" "${ALIAS64:-?}" \
        "$([[ $ALIASED == 1 ]] && echo 'ALIASED (high address bits not delivered)' || echo 'no alias observed at +0x1064')"
    exit 0
fi
[[ -n $CONN_ID && -n $CRTC_ID ]] || \
    fail "--mode needs a connector and a crtc; neither could be read from modetest-query.txt (use --connector/--crtc)"

# --- gate 1: the sink has to exist -------------------------------------------
if [[ $CONN_STATUS != connected || ${MODE_COUNT:-0} -eq 0 ]]; then
    { printf 'mode_not_set=%s\n' "$MODE"
      printf 'connector_status=%s modes=%s cable_detect_pio_in=%s hpd=%s raw_hpd_pin=%s\n' \
        "${CONN_STATUS:-unknown}" "${MODE_COUNT:-0}" "${PIO_IN:-?}" "$HPD_HW" "$RAW_HPD"
      printf 'raw_hpd_pin_probe=%s value=%s\n' "$PROBE_PINS" "${RAW_PINS:-?}"; } > "$OUT/no-sink.txt"
    verdict BLOCKED_NO_SINK "connector ${CONN_ID:-?} is ${CONN_STATUS:-unknown} with ${MODE_COUNT:-0} modes, so \"$MODE\" cannot be set: the sink is not presenting HPD (raw probe pin bit10 = $RAW_HPD, TX SS PIO_IN[2] = $HPD_HW). Attach a display to the SC7F0 HDMI OUT and confirm +5V on pin 18 - that is a physical check, not a driver verdict."
    exit 0
fi
# --- gate 2: the VTC may only block the modeset when it SHOULD answer --------
# See the header: with phy_tx_video_clk at 0 Hz the VTC cannot answer and Xilinx
# refuses to read it, so refusing the modeset there is circular.  The one case
# that really would fault is a running video clock plus a refusing VTC.
if [[ $VTC_OK == 0 && $FORCE == 0 ]]; then
    if [[ $TX_VIDEO_CLK_UP == 1 ]]; then
        verdict BLOCKED_VTC_UNREACHABLE "$TXSS_BASE+$VTC_OFFSET takes a bus error even though phy_tx_video_clk is ${TX_VIDEO_CLK} Hz, so the slave should answer and XV_HdmiTxSs_Start() would write there. This is a genuine address/decode defect, not the clock-off state. --force overrides at your own risk."
        exit 0
    fi
    printf 'VTC_ADVISORY_NOT_A_GATE %s+%s takes a bus error while phy_tx_video_clk=%s Hz; v_tc is clocked by that net and xv_hdmitxss.c:2408 refuses to read the VTC for the same reason, so this is the pre-stream-up state and NOT a reason to skip the modeset.\n' \
        "$TXSS_BASE" "$VTC_OFFSET" "${TX_VIDEO_CLK:-?}" | tee "$OUT/vtc-advisory.txt"
fi

# --- transaction 5b: the two 64 KiB TX slices, word by word, before a modeset --
# Why a window dump instead of "peek one VTC register and compare to a datasheet
# offset": 26111601 proved the defect was in the WRITE address path (the subsystem's
# S_AXI_CPU_IN_awaddr[16] had no net at all), and a single read cannot see that.  A
# modeset is the only writer this persona has for the VTC window: XV_HdmiTxSs_Start()
# calls XVtc_Reset() and XVtc_Config(), so after a real 3840x2160 mode the upper slice
# must contain words the driver just wrote.  Snapshotting both slices before and
# after, and diffing, answers "did writes reach 0xB0030000" without this script
# writing anything itself, and without assuming which offset the IP keeps the active
# size in (xlnx_vtc.c puts it at +0x60 as hactive[15:0]|vactive[31:16]; xv_tc is the
# same IP family, but the assertion here is "something the driver wrote landed in the
# upper slice", which is map-independent).
WINDOW_N=${WINDOW_N:-48}
read -r -d '' DUMP <<'EOF' || true
dump(){ b=$1; tag=$2; i=0; while [ "$i" -lt __N__ ]; do a=$((b + i * 4)); v=$(peek $(printf '0x%08X' $a) 2>/dev/null) || v=BUS_ERROR; echo "$tag +$(printf 0x%03X $((i * 4))) = $v"; i=$((i + 1)); done; }
dump __TXSS__ lower
dump $((__TXSS__ + __VTCOFF__)) upper
EOF
CMDD=${DUMP//__N__/$WINDOW_N}
CMDD=${CMDD//__TXSS__/$TXSS_BASE}
CMDD=${CMDD//__VTCOFF__/$VTC_OFFSET}
rexec "$OUT/vtc-window-before.txt" 90 "$CMDD" || true
if [[ -s $OUT/vtc-window-before.txt ]]; then
    LOWER_ERR=$(grep -c 'BUS_ERROR' "$OUT/vtc-window-before.txt" || true)
    printf 'window snapshot before modeset: %s words/slice, %s bus errors, file %s\n' \
        "$WINDOW_N" "$LOWER_ERR" "$OUT/vtc-window-before.txt"
else
    echo "window snapshot before modeset returned nothing (transport?)"
fi

# --- transaction 6: one bounded fixed-pattern pass ---------------------------
CARD_LOG=/tmp/modetest-$(date -u +%Y%m%dT%H%M%SZ).log
IRQ_BEFORE=$(irqsum "$OUT/tx-hw-state-before.txt" "$IRQ_NAME" first)
# nohup + background: the mailbox exec returns in bounded time while the pattern
# holder keeps running; modetest's stdin is a bounded sleep, so it clears the mode
# by itself after __HOLD__ seconds instead of leaving a private DRM master behind.
TMPL='nohup sh -c '"'"'sleep __HOLD__ | modetest __OPEN__ -s __CONN__@__CRTC__:__MODE__@__FCC__'"'"' > __LOG__ 2>&1 &
sleep 2
echo "modetest_running=$(pgrep -f modetest | head -1) log=__LOG__"'
CMD=${TMPL//__HOLD__/$HOLD}
CMD=${CMD//__OPEN__/$MT_OPEN}
CMD=${CMD//__CONN__/$CONN_ID}
CMD=${CMD//__CRTC__/$CRTC_ID}
CMD=${CMD//__MODE__/$MODE}
CMD=${CMD//__FCC__/$FOURCC}
CMD=${CMD//__LOG__/$CARD_LOG}
rexec "$OUT/modetest-pattern-start.txt" 25 "$CMD" || fail "pattern start exec failed (transport)"
cat "$OUT/modetest-pattern-start.txt"
printf 'pattern %s@%s on connector=%s crtc=%s card=%s for %ss; card log: %s\n' \
    "$MODE" "$FOURCC" "$CONN_ID" "$CRTC_ID" "$XLNX_CARD" "$HOLD" "$CARD_LOG"

# --- transaction 6b: is the TX link actually up WHILE the pattern is running? --
# This is the observation the whole VTC question turns on: mode -> VPHY TX PLL
# programmed -> phy_tx_video_clk non-zero -> VTC reachable -> stream up.  If the
# clock is still 0 after a commit, the blocker is the VPHY/clock path and no
# amount of address-map work will help.
sleep $(( HOLD / 4 ))
read -r -d '' DURING <<'EOF' || true
rd(){ lbl=$1; addr=$2; o=$(peek "$addr" 2>/dev/null); rc=$?
  a=$(printf '0x%08X' "$addr")
  if [ "$rc" -ne 0 ] || [ -z "$o" ]; then echo "$lbl $a = BUS_ERROR(rc=$rc)"; else echo "$lbl $a = $o"; fi; }
B=__TXSS__; V=__VPHY__; C=__CLKS__
rd tx_video_clk $((C + 0x1C)); rd txoutclk $((C + 0x18)); rd tx_clk $((C + 0x14))
rd pll_lock  $((V + 0x018)); rd tx_init $((V + 0x01C)); rd tx_initst $((V + 0x020))
rd tx_status $((V + 0x078)); rd intr_sts $((V + 0x11C)); rd clkdet_st $((V + 0x204))
rd clkdet_tx $((V + 0x20C)); rd clkdet_rx $((V + 0x210))
rd pio_sta   $((B + 0x0050)); rd pio_in $((B + 0x0064)); rd vtc $((B + __VTCOFF__))
EOF
CMDD=${DURING//__TXSS__/$TXSS_BASE}
CMDD=${CMDD//__VPHY__/$VPHY_BASE}
CMDD=${CMDD//__CLKS__/$PROBE_CLKS}
CMDD=${CMDD//__VTCOFF__/$VTC_OFFSET}
rexec "$OUT/tx-hw-state-during.txt" 30 "$CMDD" || true
cat "$OUT/tx-hw-state-during.txt"
dval() { awk -v l="$1" '$1 == l {print $NF; exit}' "$OUT/tx-hw-state-during.txt"; }
D_TX_VIDEO=$(dval tx_video_clk); D_PLL_LOCK=$(dval pll_lock); D_TX_INIT=$(dval tx_init)
D_TX_STATUS=$(dval tx_status); D_VTC=$(dval vtc)
printf 'during pattern %s: tx_video_clk=%s (was %s) | VPHY pll_lock=%s (was %s) tx_init=%s (was %s) tx_status=%s | VTC+%s=%s (was %s)\n' \
    "$MODE" "${D_TX_VIDEO:-?}" "${TX_VIDEO_CLK:-?}" "${D_PLL_LOCK:-?}" "$(hwval pll_lock)" \
    "${D_TX_INIT:-?}" "$(hwval tx_init)" "${D_TX_STATUS:-?}" "$VTC_OFFSET" "${D_VTC:-?}" "${VTC_VAL:-?}"
if [[ -n ${D_TX_VIDEO:-} && ${D_TX_VIDEO} != BUS_ERROR* ]] && (( $(printf '%d' "$D_TX_VIDEO" 2>/dev/null || echo 0) > 1000000 )); then
    printf 'TX_LINK_UP the commit raised phy_tx_video_clk to %s; the VTC aperture is now expected to answer.\n' "$D_TX_VIDEO"
else
    printf 'TX_LINK_STILL_DOWN after a real modeset of %s phy_tx_video_clk is still %s and VPHY TX_INIT is still %s (0x80808080 = PLL_GTRESET asserted on CH1..CH4): the commit never brought the VPHY TX lanes out of reset, so the video-timing chain cannot run. That is a VPHY/commit-path blocker, not an address-map one.\n' "$MODE" "${D_TX_VIDEO:-?}" "${D_TX_INIT:-?}"
fi

# --- transaction 7: read back while it is up, then after it released ---------
sleep $((HOLD / 3))
CMDD=${DUMP//__N__/$WINDOW_N}
CMDD=${CMDD//__TXSS__/$TXSS_BASE}
CMDD=${CMDD//__VTCOFF__/$VTC_OFFSET}
rexec "$OUT/vtc-window-during.txt" 90 "$CMDD" || true
if [[ -s $OUT/vtc-window-before.txt && -s $OUT/vtc-window-during.txt ]]; then
    # diff, not join: the words are positional, and a changed word must be visible
    # with its own offset label rather than matched on a key that can repeat.
    diff "$OUT/vtc-window-before.txt" "$OUT/vtc-window-during.txt" \
        | grep -E '^[<>]' > "$OUT/vtc-window-changed.txt" || true
    UPPER_CHANGED=$(grep -c '^> upper' "$OUT/vtc-window-changed.txt" 2>/dev/null || true)
    LOWER_CHANGED=$(grep -c '^> lower' "$OUT/vtc-window-changed.txt" 2>/dev/null || true)
    printf 'after modeset %s: upper-slice(0x%s..+0x%s) words changed=%s, lower-slice words changed=%s\n' \
        "$MODE" "$TXSS_BASE" "$VTC_OFFSET" "${UPPER_CHANGED:-0}" "${LOWER_CHANGED:-0}"
    if [[ ${UPPER_CHANGED:-0} -gt 0 ]]; then
        printf 'VTC_WRITE_DECODE_OK the modeset wrote through the upper 64 KiB slice: XVtc_Reset() and XVtc_Config() landed inside 0x%s+%s, which is exactly the half 26111601 could not write (S_AXI_CPU_IN_awaddr[16] had no net).\n' "$TXSS_BASE" "$VTC_OFFSET"
        grep -E '^> upper' "$OUT/vtc-window-changed.txt" | head -12 | sed 's/^/    /'
    else
        printf 'VTC_WRITE_DECODE_UNPROVEN no word in the upper slice changed across the modeset. Either the write channel still does not select the VTC segment, or this mode was already active and the driver re-wrote identical values - re-run with a different --mode before reading anything into it.\n'
    fi
    grep -E '^< lower' "$OUT/vtc-window-changed.txt" 2>/dev/null | head -6 | sed 's/^/    lower_also_changed /' || true
fi
sleep $(( HOLD - HOLD / 3 + 3 ))
TMPL='for n in /sys/class/drm/__CARD__-*; do
  [ -d "$n" ] || continue
  echo "$(basename "$n") status=$(cat "$n/status") enabled=$(cat "$n/enabled") first_mode=$(cut -d" " -f1 "$n/modes" | head -1)"
done
echo "--- __IRQ__ lines:"; grep -w __IRQ__ /proc/interrupts || echo none
echo "--- modetest output so far:"; cat __LOG__ 2>/dev/null'
CMD=${TMPL//__CARD__/$XLNX_CARD}
CMD=${CMD//__IRQ__/$IRQ_NAME}
CMD=${CMD//__LOG__/$CARD_LOG}
rexec "$OUT/modetest-pattern-state.txt" 25 "$CMD" || true
cat "$OUT/modetest-pattern-state.txt"

sleep $((HOLD / 2 + 3))
read -r -d '' HW2 <<'EOF' || true
rd(){ lbl=$1; addr=$2; o=$(peek "$addr" 2>/dev/null); rc=$?
  a=$(printf '0x%08X' "$addr")
  if [ "$rc" -ne 0 ] || [ -z "$o" ]; then echo "$lbl $a = BUS_ERROR(rc=$rc)"; else echo "$lbl $a = $o"; fi; }
echo "--- modetest final output:"; cat __LOG__ 2>/dev/null
echo "--- __IRQ__ lines:"; grep -w __IRQ__ /proc/interrupts || echo none
echo "--- TX SS / VPHY after:"
B=__TXSS__; V=__VPHY__; C=__CLKS__
rd pio_in $((B + 0x0064)); rd vtc $((B + __VTCOFF__)); rd pll_lock $((V + 0x018))
rd tx_init $((V + 0x01C)); rd tx_initst $((V + 0x020)); rd tx_status $((V + 0x078))
rd tx_video_clk $((C + 0x1C)); rd txoutclk $((C + 0x18))
echo "--- dmesg tail:"; dmesg | tail -n 40
EOF
CMD=${HW2//__IRQ__/$IRQ_NAME}
CMD=${CMD//__LOG__/$CARD_LOG}
CMD=${CMD//__TXSS__/$TXSS_BASE}
CMD=${CMD//__VPHY__/$VPHY_BASE}
CMD=${CMD//__CLKS__/$PROBE_CLKS}
CMD=${CMD//__VTCOFF__/$VTC_OFFSET}
rexec "$OUT/modetest-pattern-final.txt" 30 "$CMD" || true
cat "$OUT/modetest-pattern-final.txt"

IRQ_AFTER=$(irqsum "$OUT/modetest-pattern-final.txt" "$IRQ_NAME" last)
{
    printf 'card=%s driver=%s connector=%s crtc=%s plane=%s mode=%s fourcc=%s hold=%ss boot_id=%s\n' \
        "$XLNX_CARD" "$XLNX_DRV" "${CONN_ID:-?}" "${CRTC_ID:-?}" "${PLANE_ID:-?}" \
        "$MODE" "${FOURCC:-?}" "$HOLD" "$BOOT_ID"
    printf 'modetest_open=%s\n' "$MT_OPEN"
    printf '%s_irq before=%s after=%s delta=%s\n' "$IRQ_NAME" "${IRQ_BEFORE:-?}" "${IRQ_AFTER:-?}" \
        "$(( ${IRQ_AFTER:-0} - ${IRQ_BEFORE:-0} ))"
    printf 'tx_video_clk before=%s during=%s after=%s | VPHY pll_lock before=%s during=%s | tx_init before=%s during=%s | VTC+%s before=%s during=%s\n' \
        "${TX_VIDEO_CLK:-?}" "${D_TX_VIDEO:-?}" "$(awk '$1=="tx_video_clk"{print $NF; exit}' "$OUT/modetest-pattern-final.txt" 2>/dev/null)" \
        "$(hwval pll_lock)" "${D_PLL_LOCK:-?}" "$(hwval tx_init)" "${D_TX_INIT:-?}" \
        "$VTC_OFFSET" "${VTC_VAL:-?}" "${D_VTC:-?}"
    printf 'A mode being set and the connector reporting it is NOT proof that a person\n'
    printf 'saw light on the HDMI TX display; that human check is a separate required step.\n'
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
printf '\nDRM_VERIFY_DONE logs=%s\n' "$OUT"
