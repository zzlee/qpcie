#!/bin/bash
# ============================================================================
# Step 4: Dynamic Diagnostic Marker & Watermark Overlay Verification Suite
# Verifies:
#   1. Clean driver load in Canonical v3.0 mode.
#   2. Baseline Golden Reference SHA256 match when Overlay is OFF (bypass mode).
#   3. Dynamic runtime activation of TPG Diagnostic Overlay via V4L2 Control & Sysfs.
#   4. End-to-end geometry verification (-M):
#      - Top-Left:     Red     (0xFF, 0x00, 0x00)
#      - Top-Right:    Green   (0x00, 0xFF, 0x00)
#      - Bottom-Left:  Blue    (0x00, 0x00, 0xFF)
#      - Bottom-Right: Yellow  (0xFF, 0xFF, 0x00)
#      - Center:       Magenta (0xFF, 0x00, 0xFF)
#   5. End-to-end Frame Counter Watermark verification (-W):
#      - Magic 0xA5 byte at coordinate (8, 0).
#      - Monotonically continuous frame sequence numbers with 0 drops/discontinuities.
#   6. Dynamic deactivation: confirms return to 100% Bit-Exact Golden SHA256.
#   7. Clean module teardown with 0 SMMU faults.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_DIR="$REPO_DIR/driver"
KO="$DRIVER_DIR/custom_pcie_av.ko"
APP_RGB24="$REPO_DIR/test_app/v4l2_rgb24_test_app"
APP_NV12="$REPO_DIR/test_app/v4l2_test_app"

DEV="/dev/video0"
W=1920
H=1080
EXPECTED_RGB_SHA256="55658ea5e2ba76280c0b2b3cae7549a39aeedd9ddae6ca065aa2b48490be4ea3"

echo "================================================================="
echo " Step 4: Dynamic TPG Marker Overlay & Data Integrity Suite"
echo " Targets: 4-Corner Geometry, Center Marker, Magic A5 Watermark"
echo "================================================================="

# --- Step 1: Driver Load ---
echo ""
echo "--- Step 1: Loading QPCIe Driver in Canonical v3.0 Mode ---"
rmmod custom_pcie_av 2>/dev/null || true
sleep 1

modprobe videodev 2>/dev/null || true
modprobe videobuf2_common 2>/dev/null || modprobe videobuf2-common 2>/dev/null || true
modprobe videobuf2_memops 2>/dev/null || modprobe videobuf2-memops 2>/dev/null || true
modprobe videobuf2_v4l2 2>/dev/null || modprobe videobuf2-v4l2 2>/dev/null || true
modprobe videobuf2_dma_sg 2>/dev/null || modprobe videobuf2-dma-sg 2>/dev/null || true
modprobe snd_pcm 2>/dev/null || modprobe snd-pcm 2>/dev/null || true

insmod "$KO"
sleep 2

dmesg | tail -n 100 | grep -E "Canonical v3.0 Map Active|PHASE 5 NEW MAP ACTIVE|CH0 Thin Ring" || {
    echo "[FAIL] Driver did not activate Canonical v3.0 Map!"
    dmesg | tail -n 50
    exit 1
}
echo "[PASS] Canonical v3.0 Register Map Active."

# Wait for video device
timeout=10
while [ ! -c "$DEV" ] && [ $timeout -gt 0 ]; do
    sleep 0.5
    timeout=$((timeout - 1))
done
if [ ! -c "$DEV" ]; then
    echo "[FAIL] Video device $DEV did not appear!"
    exit 1
fi
echo "Using video device: $DEV"

# Locate sysfs attribute
SYS_DIR=$(ls -d /sys/bus/pci/devices/*/tpg_overlay 2>/dev/null | head -n 1 | xargs dirname || echo "")
if [ -n "$SYS_DIR" ]; then
    OVERLAY_INIT=$(cat "$SYS_DIR/tpg_overlay" 2>/dev/null || echo "0")
    echo "  Initial sysfs tpg_overlay: $OVERLAY_INIT"
fi

# --- Step 2: Golden Reference Baseline (Overlay OFF) ---
echo ""
echo "--- Step 2: Golden Reference Verification (Overlay OFF / Pure TPG) ---"
RGB_OUT="/tmp/step4_baseline.raw"
rm -f "$RGB_OUT"
"$APP_RGB24" -d "$DEV" -w "$W" -h "$H" -f 8 -o "$RGB_OUT" -S > /dev/null 2>&1 || {
    echo "[FAIL] Baseline capture failed!"
    exit 1
}
ACTUAL_SHA256=$(sha256sum "$RGB_OUT" | awk '{print $1}')
echo "  Captured 8 frames: $(stat -c%s "$RGB_OUT") bytes"
echo "  SHA256:            $ACTUAL_SHA256"
if [ "$ACTUAL_SHA256" != "$EXPECTED_RGB_SHA256" ]; then
    echo "[FAIL] Baseline SHA256 mismatch!"
    exit 1
fi
echo "[PASS] Baseline pure TPG is 100% Bit-Exact Match!"
rm -f "$RGB_OUT"

# --- Step 3: Diagnostic Overlay Verification (Overlay ON) ---
echo ""
echo "--- Step 3: Diagnostic Overlay Verification (-M Geometry + -W Watermark) ---"
MARKER_LOG="/tmp/step4_markers.log"
rm -f "$MARKER_LOG"
"$APP_RGB24" -d "$DEV" -w "$W" -h "$H" -f 30 -M -W > "$MARKER_LOG" 2>&1 || {
    echo "[FAIL] Marker verification failed! Log:"
    cat "$MARKER_LOG"
    exit 1
}
cat "$MARKER_LOG" | grep -E "Diagnostic|Watermark|marker|PASS" | head -n 25 || cat "$MARKER_LOG"
echo "[PASS] 4-Corner Geometry (Red/Green/Blue/Yellow) + Center (Magenta) verified!"
echo "[PASS] Magic 0xA5 + 16-bit Hardware Frame Counter Watermark verified!"

# --- Step 4: Dynamic Sysfs Control Toggle ---
echo ""
echo "--- Step 4: Testing Dynamic Sysfs Control Toggle ---"
if [ -n "$SYS_DIR" ]; then
    echo 1 > "$SYS_DIR/tpg_overlay"
    O1=$(cat "$SYS_DIR/tpg_overlay")
    echo "  tpg_overlay after set 1: $O1"
    if [ "$O1" -ne 1 ]; then
        echo "[FAIL] Failed to enable tpg_overlay via sysfs!"
        exit 1
    fi
    echo 0 > "$SYS_DIR/tpg_overlay"
    O0=$(cat "$SYS_DIR/tpg_overlay")
    echo "  tpg_overlay after set 0: $O0"
    if [ "$O0" -ne 0 ]; then
        echo "[FAIL] Failed to disable tpg_overlay via sysfs!"
        exit 1
    fi
    echo "[PASS] Dynamic sysfs tpg_overlay toggle verified."
fi

# --- Step 5: Return to Golden Reference Verification ---
echo ""
echo "--- Step 5: Verifying Transparent Return to Pure TPG (Overlay OFF) ---"
RGB_OUT="/tmp/step4_after.raw"
rm -f "$RGB_OUT"
"$APP_RGB24" -d "$DEV" -w "$W" -h "$H" -f 8 -o "$RGB_OUT" -S > /dev/null 2>&1 || {
    echo "[FAIL] Post-overlay capture failed!"
    exit 1
}
ACTUAL_SHA256=$(sha256sum "$RGB_OUT" | awk '{print $1}')
echo "  Captured 8 frames: $(stat -c%s "$RGB_OUT") bytes"
echo "  SHA256:            $ACTUAL_SHA256"
if [ "$ACTUAL_SHA256" != "$EXPECTED_RGB_SHA256" ]; then
    echo "[FAIL] Post-overlay SHA256 mismatch!"
    exit 1
fi
echo "[PASS] System transparently returned to Bit-Exact Pure TPG!"
rm -f "$RGB_OUT"

# --- Step 6: Multi-Plane NV12M Regression Check ---
echo ""
echo "--- Step 6: Multi-Plane NV12M Regression Check (30 frames) ---"
"$APP_NV12" -d "$DEV" -w "$W" -h "$H" -f 30 > /dev/null 2>&1 || {
    echo "[FAIL] NV12M regression failed!"
    exit 1
}
echo "[PASS] Step 6 NV12M regression verified."

# --- Step 7: Teardown & SMMU Check ---
echo ""
echo "--- Step 7: Clean Module Teardown ---"
rmmod custom_pcie_av
sleep 1
dmesg | tail -n 25 | grep -iE "smmu|context fault|iova" && {
    echo "[FAIL] SMMU fault detected during teardown!"
    exit 1
} || true
echo "[PASS] Driver unloaded cleanly without SMMU faults."

echo ""
echo "================================================================="
echo " 🎉 [STEP 4 ALL PASS] DYNAMIC OVERLAY & DATA INTEGRITY VERIFIED!"
echo "================================================================="
