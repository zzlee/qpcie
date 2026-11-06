#!/bin/sh
# SC7F0 4K60 NV12 PS capture helper (runs ON THE BOARD, pushed by the acceptance
# driver as one bounded transaction).
#
#   sc7f0_ps_capture_4k60.sh [FRAMES] [DUMPFILE]
#
# Sets the vpss-csc subdev formats the 4K60 NV12 path needs (sink RGB888, source
# NV12, field=none, pad0 before pad1 - the boot default is 1280x720 and the media
# controller's default Field=Any makes STREAMON fail with -EPIPE, see
# docs/sc7f0_r7_signal_recovery_4k60_20261029.md), then captures with the shipped
# sc7f0_ps_capture app.  Subdev node numbers are resolved from sysfs, never
# hardcoded, because a new hardware description can renumber them.
#
# No hdmi-rx/timing writes, no source/EDID changes, no resets, no module reloads.
set -u
FRAMES=${1:-8}
DUMP=${2:-/tmp/ps-vcu-capture.nv12}
RBG=0x100e      # MEDIA_BUS_FMT_RBG888_1X24
Y420=0x2100     # MEDIA_BUS_FMT_VYYUYY8_1X24

for n in /sys/class/video4linux/v4l-subdev*; do
    [ -r "$n/name" ] || continue
    name=$(cat "$n/name")
    dev=/dev/$(basename "$n")
    case "$name" in
        *vpss-csc*)  CSC=$dev  ;;
        *hdmi-rx*)   RX=$dev   ;;
        *frame-tap*) TAP=$dev  ;;
    esac
done
echo "SUBDEVS csc=${CSC:-none} tap=${TAP:-none} rx=${RX:-none}"
[ -n "${CSC:-}" ] || { echo "NO_VPSS_CSC_SUBDEV"; exit 3; }

echo "### vpss-csc pad0 sink RBG888 3840x2160 field=none"
v4l2-ctl -d "$CSC" --set-subdev-fmt pad=0,width=3840,height=2160,code=$RBG,field=none
echo "rc_pad0=$?"
echo "### vpss-csc pad1 source VYYUYY8 3840x2160 field=none"
v4l2-ctl -d "$CSC" --set-subdev-fmt pad=1,width=3840,height=2160,code=$Y420,field=none
echo "rc_pad1=$?"

echo "### graph formats"
for d in ${RX:-} ${TAP:-} ${CSC:-}; do
    [ -n "$d" ] || continue
    for p in 0 1; do
        out=$(v4l2-ctl -d "$d" --get-subdev-fmt $p 2>&1)
        [ -n "$out" ] || continue
        echo "-- $d pad$p:"
        echo "$out" | grep -E "Width/Height|Mediabus|Field"
    done
done

echo "### RX timing still reported by the hdmi-rx subdev"
[ -n "${RX:-}" ] && v4l2-ctl -d "$RX" --query-dv-timings 2>&1 | grep -E "Pixelclock|Width|Height|VRate|Type|Business|HDB"

dm=$(dmesg | wc -l)
echo "DMESG_MARK=$dm"
echo "### capture: sc7f0_ps_capture /dev/video0 NV12 3840 2160 $FRAMES $DUMP"
rm -f "$DUMP"
t0=$(date +%s%N)
sc7f0_ps_capture /dev/video0 NV12 3840 2160 "$FRAMES" "$DUMP"
rc=$?
t1=$(date +%s%N)
echo "CAPTURE_EXIT=$rc"
echo "CAPTURE_WALL_MS=$(( (t1 - t0) / 1000000 ))"
ls -l "$DUMP" 2>&1
sha256sum "$DUMP" 2>&1
echo "### new dmesg since the mark"
dmesg | tail -n +$((dm + 1))
echo "TAP_FLAG_WARN_COUNT=$(dmesg | tail -n +$((dm + 1)) | grep -c 'Capture source=')"
echo "DMESG_ERROR_COUNT=$(dmesg | tail -n +$((dm + 1)) | grep -c -iE 'error|fail|warn')"
echo PS_CAPTURE_4K60_DONE
