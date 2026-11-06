#!/bin/bash
# Run one VCU OOC synthesis variant and keep the console log as evidence.
#   ./scripts/run_vcu_ooc.sh <tag> <tclargs...>
set -u
tag="$1"; shift
root=/home/zzlee/vibecoding/sc7f0-dual-video
logdir=/tmp/opencode/sc7f0-vcu/logs
mkdir -p "$logdir"
source /opt/Xilinx/Vivado/2023.2/settings64.sh >/dev/null 2>&1
cd "$root" || exit 1
vivado -mode batch -notrace -nojournal -log /dev/null \
    -source scripts/synth_sc7f0_vcu_bd_ooc.tcl -tclargs "$@" \
    > "$logdir/ooc-$tag-console.log" 2>&1
echo "VIVADO_EXIT=$? tag=$tag args=$*" >> "$logdir/ooc-$tag-console.log"
grep -E "SC7F0_VCU_OOC (RUN_STATUS|UTIL|TIMING|SWEEP)|SC7F0_VCU_OOC_PASS|VIVADO_EXIT" \
    "$logdir/ooc-$tag-console.log" > "$logdir/ooc-$tag-markers.txt" 2>&1
exit 0
