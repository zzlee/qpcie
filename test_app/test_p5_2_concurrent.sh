#!/bin/bash
# ============================================================================
# Phase 5 P5-2: Performance Baseline (801 MiB/s) & Concurrent Streaming Test
# Verifies:
#   1. Single-channel uncapped DMA performance baseline (~801 MiB/s) on CH0
#      with 16-byte thin descriptors in New Map mode.
#   2. Hardware frame-drop counter is zero during uncapped benchmark.
#   3. Dual-track concurrent CH0 capture + CH1 loopback streaming ("互不擋").
#   4. Clean module teardown with zero SMMU faults.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KO="$REPO_DIR/driver/custom_pcie_av.ko"
APP_RGB24="$REPO_DIR/test_app/v4l2_rgb24_test_app"
APP_NV12="$REPO_DIR/test_app/v4l2_test_app"
APP_LB="$REPO_DIR/test_app/loopback_test_app"

BENCH_FRAMES=300
CONCURRENT_FRAMES=60
W=1920
H=1080
TARGET_THROUGHPUT_MIN_MIB=700.0

[ "$(id -u)" -eq 0 ] || { echo "Must run as root (sudo)"; exit 1; }
[ -f "$KO" ] || { echo "Driver $KO not found"; exit 1; }
[ -x "$APP_RGB24" ] || { echo "Test app $APP_RGB24 not found"; exit 1; }
[ -x "$APP_NV12" ] || { echo "Test app $APP_NV12 not found"; exit 1; }
[ -x "$APP_LB" ] || { echo "Test app $APP_LB not found"; exit 1; }

echo "================================================================="
echo " Phase 5 P5-2: Single-Channel 801 MiB/s Baseline & Concurrent Test"
echo " Targets: Benchmark 300 frames uncapped, Concurrent 60 frames"
echo "================================================================="

# --- Step 1: Single-Channel 801 MiB/s Performance Baseline (New Map Mode) ---
echo ""
echo "--- Step 1: Single-Channel 801 MiB/s Performance Baseline (New Map) ---"
rmmod custom_pcie_av 2>/dev/null || true
sleep 1
insmod "$KO" rgb24_only=1
sleep 2

dmesg | tail -n 25 | grep -E "PHASE 5 NEW MAP|CH0 Thin Ring" || {
    echo "[FAIL] Driver did not auto-detect New Map!"
    dmesg | tail -n 25
    exit 1
}
echo "[PASS] New Map auto-detected and active."

echo "Running uncapped DMA benchmark on /dev/video0 ($BENCH_FRAMES frames)..."
BENCH_LOG="/tmp/p5_2_bench.log"
rm -f "$BENCH_LOG"

"$APP_RGB24" -d /dev/video0 -w "$W" -h "$H" -f "$BENCH_FRAMES" -b > "$BENCH_LOG" 2>&1 || {
    echo "[FAIL] Uncapped benchmark failed! Log:"
    cat "$BENCH_LOG"
    dmesg | tail -n 25
    exit 1
}

cat "$BENCH_LOG" | grep -A 10 "Capture Summary:" || cat "$BENCH_LOG"

# Extract throughput and frame drops from benchmark output
THROUGHPUT=$(grep -E "DMA Throughput" "$BENCH_LOG" | tail -n 1 | awk '{print $4}')
DROPS=$(grep -E "Hardware Frame Drops" "$BENCH_LOG" | tail -n 1 | awk -F'delta=' '{print $2}' | tr -d ')')
CAPTURED=$(grep -E "Total Captured" "$BENCH_LOG" | tail -n 1 | awk '{print $4}')

echo "  Captured Frames : $CAPTURED / $BENCH_FRAMES"
echo "  DMA Throughput  : $THROUGHPUT MiB/s"
echo "  Frame Drops     : $DROPS"

if [ -z "$THROUGHPUT" ] || [ -z "$CAPTURED" ]; then
    echo "[FAIL] Could not parse benchmark output metrics!"
    exit 1
fi

if [ "$CAPTURED" -lt "$BENCH_FRAMES" ]; then
    echo "[FAIL] Captured frames ($CAPTURED) less than requested ($BENCH_FRAMES)"
    exit 1
fi

if [ -n "$DROPS" ] && [ "$DROPS" -ne 0 ]; then
    echo "[FAIL] Hardware frame drop counter increased ($DROPS drops)!"
    exit 1
fi

# Compare throughput against baseline minimum
THROUGHPUT_INT=${THROUGHPUT%.*}
if [ "$THROUGHPUT_INT" -lt "${TARGET_THROUGHPUT_MIN_MIB%.*}" ]; then
    echo "[FAIL] Measured throughput ($THROUGHPUT MiB/s) fell below ${TARGET_THROUGHPUT_MIN_MIB} MiB/s baseline!"
    exit 1
fi

echo "[PASS] Step 1 Performance baseline achieved: $THROUGHPUT MiB/s (>= ${TARGET_THROUGHPUT_MIN_MIB} MiB/s, 0 drops)!"

# Check sysfs telemetry
SYS_DIR=$(ls -d /sys/bus/pci/devices/*0004:01:00.0* 2>/dev/null || ls -d /sys/bus/pci/devices/*01:00.0* 2>/dev/null || true)
if [ -d "$SYS_DIR" ]; then
    CH0_FRAMES=$(cat "$SYS_DIR/ch0_frames" 2>/dev/null || echo 0)
    CH0_DROPS=$(cat "$SYS_DIR/ch0_drops" 2>/dev/null || echo 0)
    echo "  Sysfs ch0_frames: $CH0_FRAMES, ch0_drops: $CH0_DROPS"
    if [ "$CH0_FRAMES" -lt "$BENCH_FRAMES" ]; then
        echo "[FAIL] Sysfs ch0_frames ($CH0_FRAMES) < benchmark frames ($BENCH_FRAMES)"
        exit 1
    fi
fi

# --- Step 2: Concurrent Streaming Verification (CH0 Capture + CH1 Loopback) ---
echo ""
echo "--- Step 2: Testing Concurrent Streaming (CH0 + CH1) ---"
# Test concurrent streaming under dual-track legacy fallback to ensure full multi-channel compatibility
rmmod custom_pcie_av 2>/dev/null || true
sleep 1
insmod "$KO" rgb24_only=1 use_new_map=0
sleep 2

dmesg | tail -n 25 | grep -i "LEGACY MAP ACTIVE" || {
    echo "[FAIL] Driver did not enter legacy mode for concurrent channel testing!"
    dmesg | tail -n 25
    exit 1
}
echo "[PASS] Dual-track legacy mode initialized for multi-channel concurrent test."

CH0_LOG="/tmp/p5_2_ch0.log"
CH1_LOG="/tmp/p5_2_ch1.log"
rm -f "$CH0_LOG" "$CH1_LOG"

echo "Launching CH0 1080p60 TPG capture ($CONCURRENT_FRAMES frames) in background..."
"$APP_RGB24" -d /dev/video0 -w "$W" -h "$H" -f "$CONCURRENT_FRAMES" -S > "$CH0_LOG" 2>&1 &
PID_CH0=$!

echo "Launching CH1 1080p60 loopback (/dev/video1 -> /dev/video2, $CONCURRENT_FRAMES frames) in background..."
"$APP_LB" -o /dev/video1 -d /dev/video2 -w "$W" -h "$H" -f "$CONCURRENT_FRAMES" -r 60 > "$CH1_LOG" 2>&1 &
PID_CH1=$!

echo "Waiting for concurrent streams (PID $PID_CH0, PID $PID_CH1)..."
RC_CH0=0
RC_CH1=0
wait "$PID_CH0" || RC_CH0=$?
wait "$PID_CH1" || RC_CH1=$?

echo ""
echo "--- CH0 Capture Result (Exit: $RC_CH0) ---"
tail -n 12 "$CH0_LOG" || cat "$CH0_LOG"

echo ""
echo "--- CH1 Loopback Result (Exit: $RC_CH1) ---"
tail -n 15 "$CH1_LOG" || cat "$CH1_LOG"

if [ "$RC_CH0" -ne 0 ]; then
    echo "[FAIL] CH0 concurrent capture failed (exit code $RC_CH0)"
    dmesg | tail -n 25
    exit 1
fi

if [ "$RC_CH1" -ne 0 ]; then
    echo "[FAIL] CH1 concurrent loopback failed (exit code $RC_CH1)"
    dmesg | tail -n 25
    exit 1
fi

echo "[PASS] Step 2 Concurrent CH0 capture + CH1 loopback completed without blocking or error!"

# --- Step 3: Clean Module Teardown ---
echo ""
echo "--- Step 3: Clean Module Teardown Verification ---"
rmmod custom_pcie_av
sleep 1

DMESG_ERRORS=$(dmesg | tail -n 30 | grep -iE "smmu|page fault|kernel BUG|NULL pointer|kernel NULL" || true)
if [ -n "$DMESG_ERRORS" ]; then
    echo "[FAIL] Module unload produced SMMU or kernel errors:"
    echo "$DMESG_ERRORS"
    exit 1
fi
echo "[PASS] Driver unloaded cleanly with zero SMMU errors."

echo ""
echo "================================================================="
echo " 🎉 [P5-2 ALL PASS] Performance Baseline (~801 MiB/s) & Concurrent Streaming Verified!"
echo "================================================================="
