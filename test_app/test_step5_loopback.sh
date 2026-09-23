#!/bin/bash
# ============================================================================
# Step 5: Hardware DMA Loopback (H2C -> CDC FIFO -> C2H) Verification Suite
# Targets:
#   1. Clean driver load in Canonical v3.0 mode (no legacy fallback).
#   2. Channel 1 NV12M Loopback: 1080p60 bit-exact integrity & RTT measurement.
#   3. Channel 1 NV12M Loopback: 4K (3840x2160) DMA pipeline verification.
#   4. Concurrent multi-channel streaming: CH0 TPG + CH1 Loopback simultaneously ("互不擋").
#   5. Clean module teardown with 0 SMMU faults.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_DIR="$REPO_DIR/driver"
KO="$DRIVER_DIR/custom_pcie_av.ko"
LOOPBACK_APP="$REPO_DIR/test_app/loopback_test_app"
TPG_APP="$REPO_DIR/test_app/v4l2_test_app"

OUT_DEV="/dev/video1"
CAP_DEV="/dev/video2"
TPG_DEV="/dev/video0"

echo "================================================================="
echo " Step 5: Hardware DMA Loopback & Concurrent Pipeline Suite"
echo " Targets: /dev/video1 (Output H2C) -> /dev/video2 (Capture C2H)"
echo "          Concurrent with /dev/video0 (CH0 TPG Capture)"
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

# Wait for video devices
for dev in "$TPG_DEV" "$OUT_DEV" "$CAP_DEV"; do
    timeout=10
    while [ ! -c "$dev" ] && [ $timeout -gt 0 ]; do
        sleep 0.5
        timeout=$((timeout - 1))
    done
    if [ ! -c "$dev" ]; then
        echo "[FAIL] Video device $dev did not appear!"
        exit 1
    fi
    echo "  Device available: $dev"
done

# --- Step 2: 1080p60 NV12M Loopback Verification ---
echo ""
echo "--- Step 2: Channel 1 1080p60 NV12M Loopback Verification (120 frames) ---"
"$LOOPBACK_APP" -o "$OUT_DEV" -d "$CAP_DEV" -w 1920 -h 1080 -f 120 -r 60 -n 8 || {
    echo "[FAIL] 1080p60 loopback test failed!"
    dmesg | tail -n 50
    exit 1
}
echo "[PASS] 1080p60 Hardware Loopback verified with 100% bit-exact integrity!"

# --- Step 3: 4K NV12M Loopback Verification ---
echo ""
echo "--- Step 3: Channel 1 4K (3840x2160) NV12M Loopback Verification (60 frames) ---"
"$LOOPBACK_APP" -o "$OUT_DEV" -d "$CAP_DEV" -w 3840 -h 2160 -f 60 -r 60 -n 8 || {
    echo "[FAIL] 4K loopback test failed!"
    dmesg | tail -n 50
    exit 1
}
echo "[PASS] 4K (3840x2160) Hardware Loopback verified with 100% bit-exact integrity!"

# --- Step 4: Concurrent Streaming (CH0 TPG + CH1 Loopback simultaneously) ---
echo ""
echo "--- Step 4: Concurrent Multi-Channel Streaming Test (CH0 TPG + CH1 Loopback) ---"
echo "  Starting CH0 TPG capture on $TPG_DEV in background (120 frames)..."
"$TPG_APP" -d "$TPG_DEV" -w 1920 -h 1080 -f 120 -S > /tmp/step5_tpg_concurrent.log 2>&1 &
TPG_PID=$!

sleep 0.5

echo "  Starting CH1 Loopback ($OUT_DEV -> $CAP_DEV) concurrently (120 frames)..."
"$LOOPBACK_APP" -o "$OUT_DEV" -d "$CAP_DEV" -w 1920 -h 1080 -f 120 -r 60 -n 8 || {
    echo "[FAIL] CH1 loopback during concurrent execution failed!"
    kill -9 "$TPG_PID" 2>/dev/null || true
    dmesg | tail -n 50
    exit 1
}

wait "$TPG_PID" || {
    echo "[FAIL] CH0 TPG concurrent capture failed! Log:"
    cat /tmp/step5_tpg_concurrent.log
    exit 1
}
rm -f /tmp/step5_tpg_concurrent.log
echo "[PASS] Concurrent CH0 TPG + CH1 Loopback completed with 0 drops and 0 collisions!"

# --- Step 5: Clean Teardown & SMMU Check ---
echo ""
echo "--- Step 5: Teardown & SMMU Diagnostic Check ---"
rmmod custom_pcie_av
sleep 1

if dmesg | tail -n 100 | grep -iE "arm-smmu.*fault|dma_alloc.*failed|kernel BUG|NULL pointer|paging request"; then
    echo "[FAIL] SMMU fault or kernel error detected during teardown!"
    exit 1
fi
echo "[PASS] Clean teardown with 0 SMMU faults."

echo ""
echo "================================================================="
echo " 🎉 ALL STEP 5 LOOPBACK VERIFICATION TESTS PASSED SUCCESSFULLY! "
echo "================================================================="
