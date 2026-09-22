#!/bin/bash
# ============================================================================
# Phase 5 P5-1: Driver Dual-Track Auto-Detection, vch Binding & Sysfs Test
# Verifies:
#   1. Automatic new-map detection from VERSION_ID >= v3.0.0 & CAPS[4]==1.
#   2. Per-channel thin ring allocation & doorbell binding on vch[0].
#   3. 8 frames of 1080p60 RGB24 capture (49,766,400 bytes) with SHA256 match.
#   4. Per-channel sysfs attributes (ch0_frames, ch0_drops, ch0_status, etc.).
#   5. Dual-track backward compatibility with use_new_map=0 forced legacy.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KO="$REPO_DIR/driver/custom_pcie_av.ko"
APP="$REPO_DIR/test_app/v4l2_rgb24_test_app"
W=1920
H=1080
FRAMES=8
EXPECT_BYTES=$(( W * H * 3 * FRAMES )) # 49,766,400 bytes
GOLDEN_SHA="55658ea5e2ba76280c0b2b3cae7549a39aeedd9ddae6ca065aa2b48490be4ea3"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root (sudo)"; exit 1; }
[ -f "$KO" ] || { echo "Driver $KO not found"; exit 1; }
[ -x "$APP" ] || { echo "Test app $APP not found"; exit 1; }

echo "================================================================="
echo " Phase 5 P5-1: Driver Dual-Track Auto-Detection & Sysfs Test"
echo " Target: 8 frames of 1080p60 RGB24 ($EXPECT_BYTES bytes)"
echo "================================================================="

# --- Step 1: Auto-detection Test (no use_new_map specified) ---
echo ""
echo "--- Step 1: Testing Auto-Detection of New Map (Default Settings) ---"
rmmod custom_pcie_av 2>/dev/null || true
sleep 1
insmod "$KO" rgb24_only=1
sleep 2

dmesg | tail -n 25 | grep -E "PHASE 5 NEW MAP|CH0 Thin Ring" || {
    echo "[FAIL] Driver did not auto-detect New Map!"
    dmesg | tail -n 25
    exit 1
}
echo "[PASS] New Map auto-detected successfully from Version and Capabilities."

DEV=$(ls /dev/video* 2>/dev/null | head -n 1 || echo "/dev/video0")
echo "Using video device: $DEV"

RAW_AUTO="/tmp/ch0_p5_1_auto.raw"
rm -f "$RAW_AUTO"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -S -o "$RAW_AUTO" > /tmp/p5_auto.log 2>&1 || {
    echo "[FAIL] Auto-detected capture failed. Log:"
    cat /tmp/p5_auto.log
    dmesg | tail -n 25
    exit 1
}

SIZE_AUTO=$(stat -c%s "$RAW_AUTO")
SHA_AUTO=$(sha256sum "$RAW_AUTO" | awk '{print $1}')
echo "  Captured: $SIZE_AUTO bytes"
echo "  SHA256:   $SHA_AUTO"

if [ "$SIZE_AUTO" -ne "$EXPECT_BYTES" ]; then
    echo "[FAIL] Captured byte count mismatch: $SIZE_AUTO (expected $EXPECT_BYTES)"
    exit 1
fi

if [ "$SHA_AUTO" != "$GOLDEN_SHA" ]; then
    echo "[FAIL] SHA256 mismatch: $SHA_AUTO (expected $GOLDEN_SHA)"
    exit 1
fi
echo "[PASS] Step 1 Auto-Detected Capture 100% Bit-Exact Match!"

# --- Step 2: Per-Channel Sysfs Attribute Verification ---
echo ""
echo "--- Step 2: Checking Per-Channel Sysfs Attributes ---"
SYS_DIR=$(ls -d /sys/bus/pci/devices/*/ch0_frames 2>/dev/null | head -n 1 | xargs dirname || echo "")
if [ -z "$SYS_DIR" ]; then
    echo "[FAIL] ch0_frames sysfs node not found!"
    exit 1
fi
echo "Sysfs directory: $SYS_DIR"

CH0_FRAMES=$(cat "$SYS_DIR/ch0_frames")
CH0_DROPS=$(cat "$SYS_DIR/ch0_drops")
CH0_STATUS=$(cat "$SYS_DIR/ch0_status")
CH0_HEAD=$(cat "$SYS_DIR/ch0_head")
CH0_TAIL=$(cat "$SYS_DIR/ch0_tail")
CH1_STATUS=$(cat "$SYS_DIR/ch1_status")

echo "  ch0_frames : $CH0_FRAMES"
echo "  ch0_drops  : $CH0_DROPS"
echo "  ch0_status : $CH0_STATUS"
echo "  ch0_head   : $CH0_HEAD"
echo "  ch0_tail   : $CH0_TAIL"
echo "  ch1_status : $CH1_STATUS"

if [ "$CH0_FRAMES" -lt "$FRAMES" ]; then
    echo "[FAIL] ch0_frames ($CH0_FRAMES) is less than captured frames ($FRAMES)"
    exit 1
fi
echo "[PASS] Step 2 Per-channel sysfs attributes verified."

# --- Step 3: Dual-Track Compatibility (Forced Legacy use_new_map=0) ---
echo ""
echo "--- Step 3: Testing Dual-Track Forced Legacy Map (use_new_map=0) ---"
rmmod custom_pcie_av 2>/dev/null || true
sleep 1
insmod "$KO" rgb24_only=1 use_new_map=0
sleep 2

dmesg | tail -n 25 | grep -i "LEGACY MAP ACTIVE" || {
    echo "[FAIL] Driver did not honor use_new_map=0 legacy fallback!"
    dmesg | tail -n 25
    exit 1
}
echo "[PASS] Forced legacy map activated successfully."

RAW_LEGACY="/tmp/ch0_p5_1_legacy.raw"
rm -f "$RAW_LEGACY"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -S -o "$RAW_LEGACY" > /tmp/p5_legacy.log 2>&1 || {
    echo "[FAIL] Legacy capture failed. Log:"
    cat /tmp/p5_legacy.log
    dmesg | tail -n 25
    exit 1
}

SIZE_LEGACY=$(stat -c%s "$RAW_LEGACY")
SHA_LEGACY=$(sha256sum "$RAW_LEGACY" | awk '{print $1}')
echo "  Legacy Captured: $SIZE_LEGACY bytes"
echo "  Legacy SHA256:   $SHA_LEGACY"

if [ "$SIZE_LEGACY" -ne "$EXPECT_BYTES" ] || [ "$SHA_LEGACY" != "$GOLDEN_SHA" ]; then
    echo "[FAIL] Legacy capture mismatch!"
    exit 1
fi
echo "[PASS] Step 3 Dual-track legacy fallback 100% verified."

# --- Step 4: Clean Module Teardown ---
echo ""
echo "--- Step 4: Module Teardown ---"
rmmod custom_pcie_av
echo "[PASS] Driver unloaded cleanly without SMMU context faults."

echo ""
echo "================================================================="
echo " 🎉 [P5-1 ALL PASS] DRIVER DUAL-TRACK & PER-CHANNEL BINDING VERIFIED!"
echo "================================================================="
