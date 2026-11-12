#!/bin/sh
# SC7F0 card-side capture initialisation, run as sc7f0-vcud.service ExecStartPre.
#
# Why this exists (2026-11-12 field evidence, docs/sc7f0_build_package_flash.md
# "燒錄後必要步驟" ②/②b and docs/sc7f0_26111204_flash_gstreamer_acceptance_20261112.md
# §13.2): after a cold boot the vpss-csc pads keep the driver default 1280x720 and the
# VIPP capture node carries no format, so sc7f0_vcud dies in a
# "Initial VIDIOC_QBUF: Invalid argument" restart loop and /dev/video1 on the host
# produces nothing.  The required order is hard and fixed:
#
#   subdev pad0 (sink) -> subdev pad1 (source) -> /dev/video node S_FMT -> start daemon
#
# Doing the node format before the graph, or starting the daemon first, reproduces the
# QBUF failure.  This script performs exactly that order and nothing else.
#
# Deliberately NOT done here:
#   * no I2C / no NUC1262 MCU runtime restart.  The MCU runtime restart (bus 0,
#     0x32, reg 0x06=0x01) is a host-side, exactly-once, post-boot action owned by the
#     host upgrade entry point (scripts/upgrade.sh).  Repeating it from here would make
#     "exactly one reset per upgrade" unverifiable.
#   * no guessed geometry.  This round is explicitly 3840x2160p60 only; a different
#     locked timing is reported and refused rather than silently fitted, because a
#     silently wrong graph is exactly the failure this script exists to remove.
#   * no unit/binary changes, no writes to /etc, no persistent state.
#
# Failure is normal and cheap: exiting non-zero makes systemd skip ExecStart, so the
# daemon is never launched against a bad graph; the unit's Restart=always/RestartSec=5
# simply runs this script again after the HDMI source (or the host's one MCU restart)
# has produced a locked timing.

set -u

TAG=SC7F0_CAPTURE_INIT
CSC_ENTITY=${SC7F0_CSC_ENTITY:-b0060000.vpss-csc}
RX_ENTITY=${SC7F0_RX_ENTITY:-b0010000.hdmi-rx}
VIDEO_ENTITY=${SC7F0_VIDEO_ENTITY:-video-capture output 0}
# Locked-timing wait budget.  Must stay below the unit's TimeoutStartSec (60) so a
# timeout is reported by *this* script, not by systemd SIGKILLing the service.
WAIT_SEC=${SC7F0_CAPTURE_INIT_WAIT_SEC:-45}
POLL_SEC=2
WIDTH=${SC7F0_CAPTURE_WIDTH:-3840}
HEIGHT=${SC7F0_CAPTURE_HEIGHT:-2160}
# V4L2 media-bus codes, spelled numerically on purpose: the symbolic names are
# rejected by this kernel's VIDIOC_SUBDEV_S_FMT in some call forms (logs/46,55).
SINK_CODE=0x100e    # MEDIA_BUS_FMT_RGB888_1X24
SOURCE_CODE=0x2100  # MEDIA_BUS_FMT_YUYV8_1X24 (VYYUYY8_1X24 on this sink)
CAPTURE_FORMAT=NV12

log() { printf '%s %s\n' "$TAG" "$*"; }
die() { log "FAIL $*"; exit 1; }

command -v media-ctl >/dev/null 2>&1 || die "media-ctl missing from the image"
command -v v4l2-ctl  >/dev/null 2>&1 || die "v4l2-ctl missing from the image"

# Resolve every node from the media controller by platform entity name rather than
# hardcoding /dev/v4l-subdevN: the numbering is enumeration order, not identity.
MP=$(media-ctl -p 2>/dev/null) || die "media-ctl -p failed; no media controller"

# Entity names are NOT one word. On this card the capture node entity is literally
# "video-capture output 0" (2026-11-12, build/deploy-r2-20261112/logs/02), so field 4 of
# the header line is only "video-capture" and a field-based match silently finds nothing
# - which is how the first r2 image failed its own ExecStartPre. A name is therefore the
# text between "- entity <n>: " and the trailing pad/link parenthetical.
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
# No [ -e "$node" ] pre-check: these names came out of the kernel's own media controller
# enumeration, and every use below is a v4l2 call that dies with the failing node's name
# if the node is not actually there.  A second, weaker test would only invite the reader
# to believe the failure was already handled.
log "nodes csc=$CSC rx=$RX video=$VIDEO target=${WIDTH}x${HEIGHT}"

# ---------------------------------------------------------------------------
# 1. Wait (bounded) for a locked RX timing before touching the graph.  Writing a
#    graph against an unlocked RX is what leaves the pipeline in a state where the
#    node format and the link validation disagree.
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
            *) die "RX reports ${W}x${H} non-progressive; this round is progressive-only" ;;
        esac
        locked=1
        log "rx_locked ${W}x${H}"
        break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$POLL_SEC"
done
if [ "$locked" -ne 1 ]; then
    # Not a bug and not a reason to start the daemon: the source is simply not
    # presenting ${WIDTH}x${HEIGHT} yet (or the host has not issued its single MCU
    # runtime restart).  systemd retries this ExecStartPre.
    log "WAIT_TIMEOUT rx timing is '${W:-none}x${H:-none}', want ${WIDTH}x${HEIGHT}, budget ${WAIT_SEC}s"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Graph: sink pad first, source pad second, in TWO separate calls.  One combined
#    `media-ctl -V` sets both pads to RBG888 with field "Any" and the link then
#    validates to -EPIPE (logs/31 vs the combined form).
# ---------------------------------------------------------------------------
set_pad() {
    pad=$1 code=$2
    v4l2-ctl -d "$CSC" --set-subdev-fmt "pad=$pad,width=$WIDTH,height=$HEIGHT,code=$code,field=none" >/dev/null 2>&1 \
        || die "set-subdev-fmt pad=$pad code=$code on $CSC failed"
}
set_pad 0 "$SINK_CODE"
set_pad 1 "$SOURCE_CODE"

# Re-read the media controller: $MP is a snapshot taken before the writes, and asserting
# against it would either always fail (cold boot, pads still 1280x720) or always pass
# (already-configured boot).  The card's own current table is the only honest check.
MP=$(media-ctl -p 2>/dev/null) || die "media-ctl -p failed after setting the pads"
BLOCK=$(entity_block "$CSC_ENTITY")
printf '%s\n' "$BLOCK" | grep -q "fmt:RBG888_1X24/${WIDTH}x${HEIGHT} field:none" \
    || die "csc sink pad did not land on RBG888_1X24/${WIDTH}x${HEIGHT} field:none"
printf '%s\n' "$BLOCK" | grep -q "fmt:VYYUYY8_1X24/${WIDTH}x${HEIGHT} field:none" \
    || die "csc source pad did not land on VYYUYY8_1X24/${WIDTH}x${HEIGHT} field:none"
log "graph_ok ${CSC_ENTITY} pad0=RBG888_1X24 pad1=VYYUYY8_1X24 field:none"

# ---------------------------------------------------------------------------
# 3. VIPP capture node format, after the graph and before the daemon.
#    The "=" in --set-fmt-video= is load-bearing: the space-separated form is
#    accepted and silently ignored.
# ---------------------------------------------------------------------------
v4l2-ctl -d "$VIDEO" --set-fmt-video="width=$WIDTH,height=$HEIGHT,pixelformat=$CAPTURE_FORMAT" >/dev/null 2>&1 \
    || die "--set-fmt-video on $VIDEO failed"
G=$(v4l2-ctl -d "$VIDEO" --get-fmt-video 2>/dev/null) \
    || die "--get-fmt-video on $VIDEO failed"
printf '%s\n' "$G" | grep -q "Width/Height *: *${WIDTH}/${HEIGHT}" \
    || die "$VIDEO did not accept ${WIDTH}x${HEIGHT}; got: $(printf '%s\n' "$G" | grep 'Width/Height')"
printf '%s\n' "$G" | grep -q "Pixel Format *: *'$CAPTURE_FORMAT'" \
    || die "$VIDEO did not accept $CAPTURE_FORMAT"
# "Number of planes : 0" is a vipp reporting quirk, NOT a failure: the same state
# captures a full 12,441,600-byte NV12 frame (logs/55).  It is recorded, never asserted.
log "node_ok ${VIDEO} ${WIDTH}x${HEIGHT} ${CAPTURE_FORMAT} $(printf '%s\n' "$G" | awk -F: '/Number of planes/ {gsub(/ /,"",$2); print "planes="$2}')"
# One contiguous literal, so the same token proves both the file inside image.ub
# (scripts/package_sc7f0_rootfs.py --expect-string) and the journal line the host
# upgrade entry point waits for.
printf 'SC7F0_CAPTURE_INIT PASS graph and capture node ready for sc7f0_vcud\n'
exit 0
