#!/bin/bash
# ============================================================================
# Step 3: SGL Stride & NV12M Multi-Plane Release Verification Suite
# Verifies:
#   1. Loading QPCIe driver in Canonical v3.0 mode with Dual Thin Ring (RING0 + RING1).
#   2. Standard NV12M multi-planar capture (1920x1080 @ 60fps, standard stride 1920).
#   3. Padded Stride NV12M capture (1920x1080 @ 60fps, padded stride 2048).
#   4. Uncapped DMA NV12M benchmark (300 frames).
#   5. RGB24 regression verification (8 frames 1080p60 bit-exact SHA256 match).
#   6. Clean module teardown with 0 SMMU faults.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_DIR="$REPO_DIR/driver"
KO="$DRIVER_DIR/custom_pcie_av.ko"
APP_NV12="$REPO_DIR/test_app/v4l2_test_app"
APP_RGB24="$REPO_DIR/test_app/v4l2_rgb24_test_app"
APP_LB="$REPO_DIR/test_app/loopback_test_app"

DEV="/dev/video0"
W=1920
H=1080
PAD_STRIDE=2048
FRAMES=60
BENCH_FRAMES=300
RGB_FRAMES=8
EXPECTED_RGB_SHA256="55658ea5e2ba76280c0b2b3cae7549a39aeedd9ddae6ca065aa2b48490be4ea3"

echo "================================================================="
echo " Step 3: SGL Stride & NV12M Multi-Plane Verification Suite"
echo " Targets: NV12M Dual-Ring, Padded Stride (2048), RGB24 Regression"
echo "================================================================="

# --- Step 1: Driver Load ---
echo ""
echo "--- Step 1: Loading QPCIe Driver in Canonical v3.0 Mode ---"
rmmod custom_pcie_av 2>/dev/null || true
sleep 1

# Ensure required kernel modules are present
modprobe videobuf2_common 2>/dev/null || modprobe videobuf2-common 2>/dev/null || true
modprobe videobuf2_memops 2>/dev/null || modprobe videobuf2-memops 2>/dev/null || true
modprobe videobuf2_v4l2 2>/dev/null || modprobe videobuf2-v4l2 2>/dev/null || true
modprobe videobuf2_dma_sg 2>/dev/null || modprobe videobuf2-dma-sg 2>/dev/null || true

insmod "$KO"
sleep 2

dmesg | tail -n 25 | grep -i "NEW MAP ACTIVE" || {
    echo "[FAIL] Driver did not activate Canonical v3.0 Map!"
    dmesg | tail -n 25
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

# --- Step 2: Standard NV12M Capture (Stride = Width = 1920) ---
echo ""
echo "--- Step 2: Standard NV12M Capture ($W x $H, Stride $W, $FRAMES frames) ---"
NV12_LOG="/tmp/step3_nv12_std.log"
rm -f "$NV12_LOG"
"$APP_NV12" -d "$DEV" -w "$W" -h "$H" -f "$FRAMES" > "$NV12_LOG" 2>&1 || {
    echo "[FAIL] Standard NV12M capture failed. Log:"
    cat "$NV12_LOG"
    exit 1
}
cat "$NV12_LOG" | grep -E "Summary|Captured|FPS|PASS" || cat "$NV12_LOG"
echo "[PASS] Step 2 Standard NV12M capture verified."

# --- Step 3: Padded Stride NV12M Capture (Width = 1920, Stride = 2048) ---
echo ""
echo "--- Step 3: Padded Stride NV12M Capture ($W x $H, Padded Stride $PAD_STRIDE, $FRAMES frames) ---"
STRIDE_LOG="/tmp/step3_nv12_stride.log"
rm -f "$STRIDE_LOG"
"$APP_NV12" -d "$DEV" -w "$W" -h "$H" -s "$PAD_STRIDE" -f "$FRAMES" > "$STRIDE_LOG" 2>&1 || {
    echo "[FAIL] Padded Stride NV12M capture failed. Log:"
    cat "$STRIDE_LOG"
    exit 1
}
cat "$STRIDE_LOG" | grep -E "Summary|Captured|FPS|PASS" || cat "$STRIDE_LOG"
echo "[PASS] Step 3 Padded Stride NV12M capture verified."

# --- Step 4: Uncapped DMA Benchmark (300 frames NV12M) ---
echo ""
echo "--- Step 4: Uncapped DMA Benchmark ($BENCH_FRAMES frames NV12M) ---"
BENCH_LOG="/tmp/step3_bench.log"
rm -f "$BENCH_LOG"
"$APP_NV12" -d "$DEV" -w "$W" -h "$H" -f "$BENCH_FRAMES" -b > "$BENCH_LOG" 2>&1 || {
    echo "[FAIL] Benchmark failed. Log:"
    cat "$BENCH_LOG"
    exit 1
}
cat "$BENCH_LOG" | grep -A 8 "Summary" || cat "$BENCH_LOG"
THROUGHPUT=$(grep -E "Throughput|Throughput:" "$BENCH_LOG" | tail -n 1 | awk '{print $(NF-1)}' || echo "0")
echo "  Measured Throughput : $THROUGHPUT MiB/s"
echo "[PASS] Step 4 NV12M Benchmark completed."

# --- Step 5: RGB24 Regression Verification (8 frames bit-exact) ---
echo ""
echo "--- Step 5: RGB24 Regression Verification ($RGB_FRAMES frames) ---"
RGB_OUT="/tmp/step3_rgb24.raw"
rm -f "$RGB_OUT"
"$APP_RGB24" -d "$DEV" -w "$W" -h "$H" -f "$RGB_FRAMES" -o "$RGB_OUT" -S > /dev/null 2>&1 || {
    echo "[FAIL] RGB24 capture failed!"
    exit 1
}
ACTUAL_SIZE=$(stat -c%s "$RGB_OUT" 2>/dev/null || echo 0)
EXPECTED_SIZE=$((W * H * 3 * RGB_FRAMES))
if [ "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]; then
    echo "[FAIL] Size mismatch: $ACTUAL_SIZE bytes (expected $EXPECTED_SIZE)"
    exit 1
fi
ACTUAL_SHA256=$(sha256sum "$RGB_OUT" | awk '{print $1}')
echo "  Captured: $ACTUAL_SIZE bytes"
echo "  SHA256:   $ACTUAL_SHA256"
if [ "$ACTUAL_SHA256" != "$EXPECTED_RGB_SHA256" ]; then
    echo "[FAIL] SHA256 mismatch!"
    exit 1
fi
echo "[PASS] Step 5 RGB24 Regression 100% Bit-Exact Match!"
rm -f "$RGB_OUT"

# --- Step 6: Sysfs Telemetry & Clean Teardown ---
echo ""
echo "--- Step 6: Checking Sysfs Telemetry & Clean Module Teardown ---"
SYS_DIR=$(ls -d /sys/bus/pci/devices/*/ch0_frames 2>/dev/null | head -n 1 | xargs dirname || echo "")
if [ -n "$SYS_DIR" ]; then
    CH0_FRAMES=$(cat "$SYS_DIR/ch0_frames" 2>/dev/null || echo 0)
    CH0_DROPS=$(cat "$SYS_DIR/ch0_drops" 2>/dev/null || echo 0)
    echo "  ch0_frames : $CH0_FRAMES"
    echo "  ch0_drops  : $CH0_DROPS"
    if [ "$CH0_DROPS" -ne 0 ]; then
        echo "[FAIL] Hardware frame drops detected: $CH0_DROPS"
        exit 1
    fi
    echo "[PASS] Sysfs telemetry verified (0 drops)."
fi

rmmod custom_pcie_av
sleep 1
dmesg | tail -n 25 | grep -iE "smmu|context fault|iova" && {
    echo "[FAIL] SMMU fault detected during teardown!"
    exit 1
} || true
echo "[PASS] Driver unloaded cleanly without SMMU faults."

echo ""
echo "================================================================="
echo " 🎉 [STEP 3 ALL PASS] SGL STRIDE & NV12M MULTI-PLANE VERIFIED!"
echo "================================================================="
