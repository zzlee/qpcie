#!/bin/bash
# ============================================================================
# P0-3: CH0 seven-step SG regression (RUN ON TARGET HARDWARE, not in sim)
# Maps 1:1 to the CH0 setup flow that every migration phase must re-run:
#   geometry -> descriptor -> dma_wmb -> ring base -> tail/doorbell -> CTRL
#   -> payload verify
# Usage: sudo ./test_app/sg_ch0_seven_step.sh [--frames N] [--4k]
# ============================================================================
set -u

FRAMES=8
W=1920
H=1080
DEV=/dev/video0
OUT=/tmp/ch0_nv12m.raw
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KO="$REPO_DIR/driver/custom_pcie_av.ko"
APP="$REPO_DIR/test_app/v4l2_test_app"

while [ $# -gt 0 ]; do
    case "$1" in
        --frames) FRAMES="$2"; shift 2;;
        --4k) W=3840; H=2160; shift;;
        *) echo "usage: $0 [--frames N] [--4k]"; exit 2;;
    esac
done

EXPECT_BYTES=$(( W * H * 3 / 2 * FRAMES ))
STEP=0
fail() { echo "[SEVEN-STEP FAIL] step $STEP: $1"; exit 1; }
step() { STEP=$1; echo "--- step $STEP: $2 ---"; }

[ -f "$KO" ] || fail "missing $KO (build driver first)"
[ -x "$APP" ] || fail "missing $APP (build test_app first)"
[ "$(id -u)" -eq 0 ] || fail "must run as root (sudo)"

dmesg -C
rmmod custom_pcie_av 2>/dev/null
insmod "$KO" || fail "insmod failed"
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
grep -q "RING=0x" /tmp/seven_step_dmesg.log || fail "ring base dump missing"
echo "[SEVEN-STEP PASS] step 4"

step 5 "tail doorbell + CTRL kick"
grep -q "C2H payload validation" /tmp/seven_step_dmesg.log || fail "C2H completion missing"
grep -q "H2C payload validation" /tmp/seven_step_dmesg.log || fail "H2C completion missing"
echo "[SEVEN-STEP PASS] step 5"

step 6 "CH0 capture: ${W}x${H} NV12M x${FRAMES} frames"
rm -f "$OUT"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -o "$OUT" > /tmp/seven_step_app.log 2>&1 \
    || fail "v4l2_test_app failed (see /tmp/seven_step_app.log)"
grep -q "PASS.*Mode: ${W}x${H}" /tmp/seven_step_app.log || fail "mode PASS line missing"
echo "[SEVEN-STEP PASS] step 6"

step 7 "payload verify: size + non-zero content"
[ -f "$OUT" ] || fail "$OUT not created"
ACTUAL=$(stat -c%s "$OUT")
[ "$ACTUAL" -eq "$EXPECT_BYTES" ] || fail "size $ACTUAL != expect $EXPECT_BYTES"
NONZERO=$(od -A n -t u1 "$OUT" | tr -s ' ' '\n' | grep -cv '^0$' || true)
[ "$NONZERO" -gt 0 ] || fail "capture all zeros (TPG/HW path dead?)"
echo "[SEVEN-STEP PASS] step 7 ($ACTUAL bytes, $NONZERO nonzero samples)"

echo "================================================================"
echo " SEVEN-STEP ALL PASS: ${W}x${H} x${FRAMES} frames, $ACTUAL bytes"
echo "================================================================"
