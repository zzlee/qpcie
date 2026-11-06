#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/zzlee/vibecoding/sc7f0-dual-video"
cd "$ROOT"

export XILINXD_LICENSE_FILE="2101@192.168.200.112"
export SC7F0_PROJECT_DIR="$ROOT/build/dual-video-26110301-vcu-r1"
export SC7F0_ENABLE_VCU=1
export SC7F0_TIMING_GATE="record"

LOG_DIR="$SC7F0_PROJECT_DIR/rebuild_logs"
mkdir -p "$LOG_DIR"

source /opt/Xilinx/Vivado/2023.2/settings64.sh

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Vivado synthesis & implementation for dual-video-26110301-vcu-r1..." | tee "$LOG_DIR/rebuild.log"

vivado -mode batch -notrace -nojournal \
    -log "$LOG_DIR/vivado.log" \
    -source scripts/impl_sc7f0_dual_video.tcl >> "$LOG_DIR/rebuild.log" 2>&1

EXIT_CODE=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Vivado finished with exit code $EXIT_CODE" | tee -a "$LOG_DIR/rebuild.log"
exit $EXIT_CODE
