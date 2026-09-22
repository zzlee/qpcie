#!/bin/bash
# ============================================================================
# Phase 4 P4-1: Three-Level Interrupt Architecture & Hardware Capture Test
# Verifies:
#   1. Legacy Map (use_new_map=0) IRQ handling & 8-frame 1080p60 capture.
#   2. New Map (use_new_map=1) Three-Level IRQ dispatch & 8-frame capture.
#   3. Exact interrupt firing check via /proc/interrupts.
#   4. 100% Bit-exact byte-level comparison between legacy and new map.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KO="$REPO_DIR/driver/custom_pcie_av.ko"
APP="$REPO_DIR/test_app/v4l2_rgb24_test_app"
W=1920
H=1080
FRAMES=8
EXPECT_BYTES=$(( W * H * 3 * FRAMES )) # 49,766,400 bytes

RAW_LEGACY="/tmp/ch0_p4_legacy_1080p.raw"
RAW_NEW="/tmp/ch0_p4_new_1080p.raw"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root (sudo)"; exit 1; }
[ -f "$KO" ] || { echo "Driver $KO not found"; exit 1; }
[ -x "$APP" ] || { echo "Test app $APP not found"; exit 1; }

get_irq_count() {
    local irq_num
    irq_num=$(grep "qpcie" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' || echo "")
    if [ -n "$irq_num" ]; then
        grep "qpcie" /proc/interrupts | awk '{s=0; for (i=2; i<=NF-2; i++) s+=$i; print s}'
    else
        echo 0
    fi
}

echo "================================================================="
echo " Phase 4 P4-1: Three-Level Interrupt & Capture Verification"
echo " Target: 8 frames of 1080p60 RGB24 ($EXPECT_BYTES bytes)"
echo "================================================================="

# --- STEP 1: Legacy Path (use_new_map=0) ---
echo ""
echo "--- Step 1: Testing Legacy Map Interrupt & Capture ---"
rmmod custom_pcie_av 2>/dev/null || true
insmod "$KO" rgb24_only=1 use_new_map=0
sleep 2

DEV=$(ls /dev/video* 2>/dev/null | head -n 1 || echo "/dev/video0")
echo "Using video device: $DEV"
IRQ_BEFORE=$(get_irq_count)

rm -f "$RAW_LEGACY"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -S -o "$RAW_LEGACY" > /tmp/p4_legacy.log 2>&1 || {
    echo "[FAIL] Legacy capture failed. Log:"
    cat /tmp/p4_legacy.log
    dmesg | tail -n 25
    exit 1
}

IRQ_AFTER=$(get_irq_count)
IRQ_DELTA=$(( IRQ_AFTER - IRQ_BEFORE ))
SIZE_LEGACY=$(stat -c%s "$RAW_LEGACY")

echo "  Legacy Path Captured: $SIZE_LEGACY bytes"
echo "  Legacy Path Interrupts Fired: $IRQ_DELTA"
if [ "$SIZE_LEGACY" -ne "$EXPECT_BYTES" ]; then
    echo "[FAIL] Legacy file size mismatch: $SIZE_LEGACY (expected $EXPECT_BYTES)"
    exit 1
fi
if [ "$IRQ_DELTA" -lt "$FRAMES" ]; then
    echo "[FAIL] Legacy interrupt count $IRQ_DELTA is less than frames $FRAMES"
    exit 1
fi
SHA_LEGACY=$(sha256sum "$RAW_LEGACY" | awk '{print $1}')
echo "  Legacy SHA256: $SHA_LEGACY"
echo "[PASS] Step 1 Legacy IRQ & Capture OK"

# --- STEP 2: New Map 3-Level Interrupt Path (use_new_map=1) ---
echo ""
echo "--- Step 2: Testing Phase 4 Three-Level Interrupt & Capture ---"
rmmod custom_pcie_av 2>/dev/null || true
insmod "$KO" rgb24_only=1 use_new_map=1
sleep 2

DEV=$(ls /dev/video* 2>/dev/null | head -n 1 || echo "/dev/video0")
echo "Using video device: $DEV"
dmesg | tail -n 15 | grep -i "NEW MAP" || true
IRQ_BEFORE=$(get_irq_count)

rm -f "$RAW_NEW"
"$APP" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" -S -o "$RAW_NEW" > /tmp/p4_new.log 2>&1 || {
    echo "[FAIL] New 3-Level Interrupt capture failed. Log:"
    cat /tmp/p4_new.log
    dmesg | tail -n 25
    exit 1
}

IRQ_AFTER=$(get_irq_count)
IRQ_DELTA=$(( IRQ_AFTER - IRQ_BEFORE ))
SIZE_NEW=$(stat -c%s "$RAW_NEW")

echo "  New Path Captured:    $SIZE_NEW bytes"
echo "  New Path Interrupts Fired: $IRQ_DELTA"
if [ "$SIZE_NEW" -ne "$EXPECT_BYTES" ]; then
    echo "[FAIL] New path file size mismatch: $SIZE_NEW (expected $EXPECT_BYTES)"
    exit 1
fi
if [ "$IRQ_DELTA" -lt "$FRAMES" ]; then
    echo "[FAIL] New path interrupt count $IRQ_DELTA is less than frames $FRAMES"
    exit 1
fi
SHA_NEW=$(sha256sum "$RAW_NEW" | awk '{print $1}')
echo "  New SHA256:    $SHA_NEW"
echo "[PASS] Step 2 Three-Level IRQ & Capture OK"

# --- STEP 3: Bit-Exact Byte-by-Byte Verification ---
echo ""
echo "--- Step 3: Bit-exact byte-by-byte comparison ---"
if cmp -s "$RAW_LEGACY" "$RAW_NEW"; then
    echo "================================================================="
    echo " 🎉 [P4-1 ALL PASS] THREE-LEVEL INTERRUPT & BIT-EXACT VERIFIED!"
    echo " 49,766,400 bytes are 100% IDENTICAL across all 8 frames!"
    echo " SHA256: $SHA_NEW"
    echo "================================================================="
else
    echo "[FAIL] Byte mismatch detected between legacy and new paths"
    echo "  Legacy SHA256: $SHA_LEGACY"
    echo "  New SHA256:    $SHA_NEW"
    exit 1
fi
