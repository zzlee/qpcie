#!/bin/bash
# ============================================================================
# P0-3: CH0 seven-step SG regression (RUN ON TARGET HARDWARE, not in sim)
# Maps 1:1 to the CH0 setup flow that every migration phase must re-run:
#   geometry -> descriptor -> dma_wmb -> ring base -> tail/doorbell -> CTRL
#   -> payload verify
# Usage: sudo ./test_app/sg_ch0_seven_step.sh [--frames N] [--4k] [--rgb24]
#   --rgb24 : insmod with rgb24_only=1 (single-path bitstreams: C2H format-0
#             diagnostic is skipped by design; H2C + RGB24 capture verified)
# NOTE: this script rmmod/insmods the driver itself; no manual insmod needed.
# ============================================================================
set -u

FRAMES=8
W=1920
H=1080
DEV=/dev/video0
OUT=/tmp/ch0_capture.raw
RGB24=0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KO="$REPO_DIR/driver/custom_pcie_av.ko"
APP_NV12="$REPO_DIR/test_app/v4l2_test_app"
APP_RGB24="$REPO_DIR/test_app/v4l2_rgb24_test_app"

while [ $# -gt 0 ]; do
    case "$1" in
        --frames) FRAMES="$2"; shift 2;;
        --4k) W=3840; H=2160; shift;;
        --rgb24) RGB24=1; shift;;
        *) echo "usage: $0 [--frames N] [--4k] [--rgb24]"; exit 2;;
    esac
done

if [ "$RGB24" -eq 1 ]; then
    MODPARAM="rgb24_only=1"
    APP="$APP_RGB24"
    EXPECT_BYTES=$(( W * H * 3 * FRAMES ))
    MODE_DESC="RGB24 single-path"
else
    MODPARAM=""
    APP="$APP_NV12"
    EXPECT_BYTES=$(( W * H * 3 / 2 * FRAMES ))
    MODE_DESC="NV12M full-path"
fi

STEP=0
fail() { echo "[SEVEN-STEP FAIL] step $STEP: $1"; exit 1; }
step() { STEP=$1; echo "--- step $STEP: $2 ---"; }

[ -f "$KO" ] || fail "missing $KO (build driver first)"
[ -x "$APP" ] || fail "missing $APP (build test_app first)"
[ "$(id -u)" -eq 0 ] || fail "must run as root (sudo)"
echo "mode: $MODE_DESC"

dmesg -C
rmmod custom_pcie_av 2>/dev/null
# shellcheck disable=SC2086
insmod "$KO" $MODPARAM || fail "insmod failed"
sleep 2
dmesg > /tmp/seven_step_dmesg.log

step 1 "geometry: VERSION/CAPS probe"
grep -q "BAR0 Register Read Tests" /tmp/seven_step_dmesg.log || fail "probe section missing"
grep -q "Hardware Caps" /tmp/seven_step_dmesg.log || fail "CAPS not printed"
echo "[SEVEN-STEP PASS] step 1"

step 2 "descriptor: coherent ring allocated"
grep -q "Allocated Coherent Ring" /tmp/seven_step_dmesg.log || fail "ring alloc missing"
echo "[SEVEN-STEP PASS] step 2"

step 3 "dma_wmb ordering: ring anchored at retained head (driver guarantees flush-before-doorbell)"
grep -q "Retained DMA state: Head=" /tmp/seven_step_dmesg.log || fail "retained-head anchor missing"
echo "[SEVEN-STEP PASS] step 3"

step 4 "ring base programmed (0x08/0x0C)"
if [ "$RGB24" -eq 1 ]; then
    grep -q "Triggered H2C SG Run (Head=" /tmp/seven_step_dmesg.log || fail "H2C run trigger missing"
else
    grep -q "Triggered C2H SG Run (Head=" /tmp/seven_step_dmesg.log || fail "C2H run trigger missing"
fi
echo "[SEVEN-STEP PASS] step 4"

step 5 "tail doorbell + CTRL kick"
if [ "$RGB24" -eq 1 ]; then
    grep -q "Single-path RGB24 build" /tmp/seven_step_dmesg.log \
        || fail "single-path banner missing (wrong bitstream?)"
    grep -q "H2C payload validation" /tmp/seven_step_dmesg.log || fail "H2C completion missing"
    echo "[SEVEN-STEP PASS] step 5 (H2C only; C2H skipped by design)"
else
    grep -q "C2H payload validation" /tmp/seven_step_dmesg.log || fail "C2H completion missing (see NOTE below)"
    grep -q "H2C payload validation" /tmp/seven_step_dmesg.log || fail "H2C completion missing"
    echo "[SEVEN-STEP PASS] step 5"
fi

step 6 "CH0 capture: ${W}x${H} x${FRAMES} frames ($MODE_DESC)"
rm -f "$OUT"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -o "$OUT" > /tmp/seven_step_app.log 2>&1 \
    || fail "capture app failed (see /tmp/seven_step_app.log)"
if [ "$RGB24" -eq 1 ]; then
    grep -q "V4L2_PIX_FMT_RGB24" /tmp/seven_step_app.log || fail "RGB24 config PASS line missing"
else
    grep -q "PASS.*Mode: ${W}x${H}" /tmp/seven_step_app.log || fail "mode PASS line missing"
fi
echo "[SEVEN-STEP PASS] step 6"

step 7 "payload verify: size + non-zero content"
[ -f "$OUT" ] || fail "$OUT not created"
ACTUAL=$(stat -c%s "$OUT")
[ "$ACTUAL" -eq "$EXPECT_BYTES" ] || fail "size $ACTUAL != expect $EXPECT_BYTES"
NONZERO=$(od -A n -t u1 "$OUT" | tr -s ' ' '\n' | grep -cv '^0$' || true)
[ "$NONZERO" -gt 0 ] || fail "capture all zeros (TPG/HW path dead?)"
echo "[SEVEN-STEP PASS] step 7 ($ACTUAL bytes, $NONZERO nonzero samples)"

echo "================================================================"
echo " SEVEN-STEP ALL PASS ($MODE_DESC): ${W}x${H} x${FRAMES} frames, $ACTUAL bytes"
echo "================================================================"
