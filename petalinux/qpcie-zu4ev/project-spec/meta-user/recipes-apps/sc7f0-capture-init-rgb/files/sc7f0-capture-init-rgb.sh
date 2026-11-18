#!/bin/sh
# SC7F0 RGB-compositor capture initialisation, run once at boot.
#
# Why this is a unit of its own and not part of sc7f0-vcud.service:
# the RGB-compositor persona has no VCU (scripts/create_zu4ev_ps_bd.tcl refuses VCU and
# SC7F0_RGB_COMPOSITOR on one design), so sc7f0-vcud is removed from that image by
# recipes-core/images/petalinux-image-minimal.bbappend.  Its ExecStartPre
# (recipes-apps/sc7f0-vcud/files/sc7f0-capture-init.sh) therefore never runs there, and
# nothing else in the image configures the capture graph.  The consequence is exactly the
# one documented for the VCU card in docs/sc7f0_build_package_flash.md "燒錄後必要步驟":
# after a cold boot the vpss-csc pads keep the driver default 1280x720 UYVY8_1X16, the
# VIPP node advertises nothing usable, and any consumer - sc7f0_dmabuf_loop for
# A1's HDMI RX -> PS DDR -> HDMI TX loop-through, or a manual v4l2-ctl capture - fails in
# VIDIOC_QBUF/STREAMON.  Before this unit, the only reason capture worked after a flash
# was that the acceptance session ran `media-ctl -V` by hand
# (build/accept-26111602/card-capture-final.txt section A: two media-ctl -V writes, then
# the node advertised RX24 and a 10-frame capture produced 331,776,000 bytes of real
# image data at 60.00 fps).  A reboot losing that is precisely what this unit exists to
# remove.
#
# The graph on this persona is
#   b0010000.hdmi-rx -> b0070000.frame-tap -> b0060000.vpss-csc -> video-capture output 0
# and the two writes that matter are the CSC's own pads (the frame-tap already carries
# RBG888_1X24/3840x2160 because it forwards the RX subdev's format):
#
#   "b0060000.vpss-csc":0 [fmt:RBG888_1X24/3840x2160 field:none]   sink
#   "b0060000.vpss-csc":1 [fmt:RBG888_1X24/3840x2160 field:none]   source
#
# With that graph the VIPP advertises exactly one fourcc, RX24 (V4L2_PIX_FMT_XBGR32,
# 32-bit XBGR 8-8-8-8), which is what the downstream consumers expect.  Two spellings
# that look equivalent and are NOT, both measured on this card:
#   * `v4l2-ctl --set-subdev-fmt code=0x100a` (RGB888_1X24) fails with EINVAL on both
#     pads, while `media-ctl -V` with the symbolic fmt:RBG888_1X24 succeeds (rc=0) -
#     build/accept-26111602/card-rgbcap.txt steps 2/3 versus card-capture-final.txt A.
#   * the fourcc is RX24; `BGRX`/`XBGR` are rejected as "pixelformat ... is invalid"
#     (build/accept-26111602/card-bgrx.txt), so it is never guessed here.
#
# Order is fixed: wait for a locked RX timing, sink pad, source pad, then the node.
# Doing the node format before the graph reproduces the QBUF failure the VCU image hit.
#
# Deliberately absent: no I2C and no NUC1262 runtime restart (that is a host-side,
# exactly-once action owned by scripts/sc7f0_flash.sh); no guessed geometry (a locked
# timing that is not the target is reported and refused, not silently fitted); no writes
# to /etc and no persistent state.
#
# Failure is cheap and normal: a non-zero exit leaves the graph untouched, and the next
# boot (or a manual run) tries again once the source is locked.

set -u

TAG=SC7F0_RGB_CAPTURE_INIT
CSC_ENTITY=${SC7F0_CSC_ENTITY:-b0060000.vpss-csc}
RX_ENTITY=${SC7F0_RX_ENTITY:-b0010000.hdmi-rx}
VIDEO_ENTITY=${SC7F0_VIDEO_ENTITY:-video-capture output 0}
# The only media-bus code this persona's vpss-csc accepts, in the only spelling that is
# accepted (see the header).  Kept as a variable so a future format change is one line.
BUS_FMT=RBG888_1X24
CAPTURE_FORMAT=RX24
WIDTH=${SC7F0_CAPTURE_WIDTH:-3840}
HEIGHT=${SC7F0_CAPTURE_HEIGHT:-2160}
# Budget for the locked-timing wait.  Two things set it: it must stay below the unit's
# TimeoutStartSec (240) so a timeout is reported by this script rather than by systemd
# killing it, and it has to outlast the real boot ordering on this board - the HDMI source
# and the NUC1262 do not necessarily produce a locked 4K60 timing in the first few seconds,
# and this unit blocks nothing else at boot (its consumers are started by hand afterwards),
# so waiting long is cheap and giving up early is not.
WAIT_SEC=${SC7F0_RGB_CAPTURE_INIT_WAIT_SEC:-120}
POLL_SEC=2

log() { printf '%s %s\n' "$TAG" "$*"; }
die() { log "FAIL $*"; exit 1; }

command -v media-ctl >/dev/null 2>&1 || die "media-ctl missing from the image"
command -v v4l2-ctl  >/dev/null 2>&1 || die "v4l2-ctl missing from the image"

MP=$(media-ctl -p 2>/dev/null) || die "media-ctl -p failed; no media controller"

# Entity names are not one word - the capture node is literally "video-capture output 0"
# - so a name is the text between "- entity <n>: " and the trailing pad/link
# parenthetical.  Field-based matching is what made the first r2 image's initialiser find
# nothing on this card (see scripts/tests/test_sc7f0_capture_init_helper.py).
resolve_node() {
    printf '%s\n' "$MP" | awk -v want="$1" '
        $1 == "-" && $2 == "entity" {
            name = $0
            sub(/^[[:space:]]*- entity [0-9]+:[[:space:]]*/, "", name)
            sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", name)
            cur = name
            next
        }
        cur == want && $1 == "device" && $2 == "node" && $3 == "name" { print $4; exit }
    '
}

# The block of `media-ctl -p` describing one entity, for format assertions.
entity_block() {
    printf '%s\n' "$MP" | awk -v want="$1" '
        $1 == "-" && $2 == "entity" {
            name = $0
            sub(/^[[:space:]]*- entity [0-9]+:[[:space:]]*/, "", name)
            sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", name)
            if (name == want) { inside = 1; next }
            if (inside) exit
        }
        inside { print }
    '
}

CSC=$(resolve_node "$CSC_ENTITY")
RX=$(resolve_node "$RX_ENTITY")
VIDEO=$(resolve_node "$VIDEO_ENTITY")
[ -n "$CSC" ]   || die "entity $CSC_ENTITY not in the media controller"
[ -n "$RX" ]    || die "entity $RX_ENTITY not in the media controller"
[ -n "$VIDEO" ] || die "entity $VIDEO_ENTITY not in the media controller"
log "nodes csc=$CSC rx=$RX video=$VIDEO target=${WIDTH}x${HEIGHT} fmt=${BUS_FMT}->${CAPTURE_FORMAT}"

# ---------------------------------------------------------------------------
# 1. Wait (bounded) for the locked timing before touching anything.  Writing a 4K graph
#    against an unlocked RX leaves the node format and the link validation disagreeing.
# ---------------------------------------------------------------------------
deadline=$(( $(date +%s) + WAIT_SEC ))
locked=0
while :; do
    T=$(v4l2-ctl -d "$RX" --query-dv-timings 2>/dev/null)
    W=$(printf '%s\n' "$T" | awk -F: '/Active width/ {gsub(/ /,"",$2); print $2}')
    H=$(printf '%s\n' "$T" | awk -F: '/Active height/ {gsub(/ /,"",$2); print $2}')
    if [ "$W" = "$WIDTH" ] && [ "$H" = "$HEIGHT" ]; then
        case "$T" in
            *"Frame format: progressive"*) ;;
            *) die "RX reports ${W}x${H} non-progressive; this persona is progressive-only" ;;
        esac
        locked=1
        log "rx_locked ${W}x${H}"
        break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$POLL_SEC"
done
if [ "$locked" -ne 1 ]; then
    log "WAIT_TIMEOUT rx timing is '${W:-none}x${H:-none}', want ${WIDTH}x${HEIGHT}, budget ${WAIT_SEC}s"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. The CSC's two pads, sink first, in two separate media-ctl invocations.
# ---------------------------------------------------------------------------
set_pad() {
    pad=$1
    media-ctl -V "\"${CSC_ENTITY}\":${pad} [fmt:${BUS_FMT}/${WIDTH}x${HEIGHT} field:none]" \
        >/dev/null 2>&1 \
        || die "media-ctl -V ${CSC_ENTITY}:${pad} fmt:${BUS_FMT}/${WIDTH}x${HEIGHT} failed"
}
set_pad 0
set_pad 1

# Re-read the media controller.  $MP is a snapshot from before the writes, so asserting
# against it would either always fail (cold boot) or always pass (already configured).
MP=$(media-ctl -p 2>/dev/null) || die "media-ctl -p failed after setting the pads"
BLOCK=$(entity_block "$CSC_ENTITY")
WANT="fmt:${BUS_FMT}/${WIDTH}x${HEIGHT} field:none"
# No closing bracket in the pattern on purpose.  A configured pad prints
# "[fmt:RBG888_1X24/3840x2160 field:none]" (build/accept-26111602/card-capture-final.txt
# section A), but the driver default on these same pads carries a trailing colorspace
# ("[fmt:UYVY8_1X16/1280x720 field:none colorspace:rec709]", card-pipeline.txt), and a pad
# that is otherwise configured correctly must not fail the boot because the kernel chose to
# print a colorspace it also accepts.
printf '%s\n' "$BLOCK" | grep -c "$WANT" | grep -q "^2$" \
    || die "csc pads are not both [$WANT]: $(printf '%s\n' "$BLOCK" | grep 'fmt:' | tr '\n' ' ')"
log "graph_ok ${CSC_ENTITY} pad0=pad1=${BUS_FMT}/${WIDTH}x${HEIGHT} field:none"

# ---------------------------------------------------------------------------
# 3. The VIPP node, after the graph.  The "=" in --set-fmt-video= is load-bearing: the
#    space-separated form is accepted and silently ignored.
# ---------------------------------------------------------------------------
v4l2-ctl -d "$VIDEO" --set-fmt-video="width=$WIDTH,height=$HEIGHT,pixelformat=$CAPTURE_FORMAT" \
    >/dev/null 2>&1 || die "--set-fmt-video on $VIDEO failed"
G=$(v4l2-ctl -d "$VIDEO" --get-fmt-video 2>/dev/null) || die "--get-fmt-video on $VIDEO failed"
printf '%s\n' "$G" | grep -q "Width/Height *: *${WIDTH}/${HEIGHT}" \
    || die "$VIDEO did not accept ${WIDTH}x${HEIGHT}; got $(printf '%s\n' "$G" | grep 'Width/Height')"
printf '%s\n' "$G" | grep -q "Pixel Format *: *'$CAPTURE_FORMAT'" \
    || die "$VIDEO did not accept $CAPTURE_FORMAT; got $(printf '%s\n' "$G" | grep 'Pixel Format')"
# "Number of planes : 0" is a vipp reporting quirk, not a failure (the same state streams
# full 3840x2160x4 frames), so it is recorded and never asserted.
log "node_ok ${VIDEO} ${WIDTH}x${HEIGHT} ${CAPTURE_FORMAT} $(printf '%s\n' "$G" | awk -F: '/Number of planes/ {gsub(/ /,"",$2); print "planes="$2}')"
printf 'SC7F0_RGB_CAPTURE_INIT PASS graph and capture node ready for sc7f0_dmabuf_loop\n'
exit 0
