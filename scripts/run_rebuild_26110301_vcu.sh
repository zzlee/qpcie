#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/zzlee/vibecoding/sc7f0-dual-video"
cd "$ROOT"

export XILINXD_LICENSE_FILE="2101@192.168.200.112"
export SC7F0_PROJECT_DIR="$ROOT/build/dual-video-26110301-vcu-r1"
export SC7F0_ENABLE_VCU=1
export SC7F0_TIMING_GATE="record"

# Timing closure knobs (consumed by scripts/impl_sc7f0_dual_video.tcl).
# The 2026-11-11 rebuild missed capture_clk_300m by -0.116 ns / TNS -4.956 ns on
# 79 endpoints with every other clock group positive; the worst path was 77%
# route delay across 9 logic levels, so it is closed with implementation effort
# (explorational place, aggressive phys-opt, timing-driven explore route plus
# post-route phys-opt) instead of rewriting the 300 MHz capture RTL.
export SC7F0_PLACE_DIRECTIVE="Explore"
export SC7F0_PHYS_OPT_DIRECTIVE="AggressiveExplore"
export SC7F0_ROUTE_DIRECTIVE="Explore"
export SC7F0_POST_ROUTE_PHYS_OPT="AggressiveExplore"
export SC7F0_RESET_IMPL=1

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
