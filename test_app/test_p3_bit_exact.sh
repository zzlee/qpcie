#!/bin/bash
# ============================================================================
# P3-2: CH0 1080p60 Bit-Exact Verification between Legacy & New Thin Paths
# Compares 8 frames of 1920x1080 RGB24 (49,766,400 bytes) byte-for-byte.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KO="$REPO_DIR/driver/custom_pcie_av.ko"
APP="$REPO_DIR/test_app/v4l2_rgb24_test_app"
DEV="/dev/video0"
FRAMES=8
W=1920
H=1080
EXPECT_BYTES=$(( W * H * 3 * FRAMES )) # 49,766,400 bytes

RAW_LEGACY="/tmp/ch0_legacy_1080p.raw"
RAW_NEW="/tmp/ch0_new_1080p.raw"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root (sudo)"; exit 1; }
[ -f "$KO" ] || { echo "Driver $KO not found"; exit 1; }
[ -x "$APP" ] || { echo "Test app $APP not found"; exit 1; }

echo "================================================================="
echo " Phase 3 P3-2: CH0 1080p60 Bit-Exact Byte-Level Verification"
echo " Comparing: Legacy 64B Descriptors vs New 16B Thin Descriptors"
echo " Expected payload per run: $EXPECT_BYTES bytes ($FRAMES frames)"
echo "================================================================="

# --- STEP 1: Capture on Legacy Path (use_new_map=0) ---
echo ""
echo "--- Step 1: Capture 8 frames using LEGACY descriptor path ---"
rmmod custom_pcie_av 2>/dev/null || true
insmod "$KO" rgb24_only=1 use_new_map=0
sleep 1

rm -f "$RAW_LEGACY"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -o "$RAW_LEGACY" > /tmp/p3_legacy.log 2>&1 || {
    echo "[FAIL] Legacy capture failed. Log:"
    cat /tmp/p3_legacy.log
    exit 1
}

SIZE_LEGACY=$(stat -c%s "$RAW_LEGACY")
if [ "$SIZE_LEGACY" -ne "$EXPECT_BYTES" ]; then
    echo "[FAIL] Legacy file size mismatch: $SIZE_LEGACY (expected $EXPECT_BYTES)"
    exit 1
fi
SHA_LEGACY=$(sha256sum "$RAW_LEGACY" | awk '{print $1}')
echo "  Legacy Path Captured: $SIZE_LEGACY bytes"
echo "  Legacy Payload SHA256: $SHA_LEGACY"

# --- STEP 2: Capture on New Thin Path (use_new_map=1) ---
echo ""
echo "--- Step 2: Capture 8 frames using NEW Thin Descriptor path ---"
rmmod custom_pcie_av 2>/dev/null || true
insmod "$KO" rgb24_only=1 use_new_map=1
sleep 1

dmesg | tail -n 15 | grep -i "NEW MAP" || true

rm -f "$RAW_NEW"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -o "$RAW_NEW" > /tmp/p3_new.log 2>&1 || {
    echo "[FAIL] New thin path capture failed. Log:"
    cat /tmp/p3_new.log
    exit 1
}

SIZE_NEW=$(stat -c%s "$RAW_NEW")
if [ "$SIZE_NEW" -ne "$EXPECT_BYTES" ]; then
    echo "[FAIL] New thin path file size mismatch: $SIZE_NEW (expected $EXPECT_BYTES)"
    exit 1
fi
SHA_NEW=$(sha256sum "$RAW_NEW" | awk '{print $1}')
echo "  New Path Captured:    $SIZE_NEW bytes"
echo "  New Payload SHA256:    $SHA_NEW"

# --- STEP 3: Bit-Exact Byte-by-Byte Verification ---
echo ""
echo "--- Step 3: Bit-exact byte-by-byte comparison ---"
if cmp -s "$RAW_LEGACY" "$RAW_NEW"; then
    echo "================================================================="
    echo " 🎉 [P3-2 ALL PASS] BIT-EXACT MATCH CONFIRMED!"
    echo " 49,766,400 bytes are 100% IDENTICAL across all 8 frames!"
    echo " SHA256: $SHA_NEW"
    echo "================================================================="
else
    DIFF_COUNT=$(cmp -l "$RAW_LEGACY" "$RAW_NEW" | wc -l)
    echo "[FAIL] Byte mismatch detected between legacy and new paths ($DIFF_COUNT differing bytes)"
    exit 1
fi
