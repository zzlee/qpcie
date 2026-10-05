#!/bin/bash
# Write NUC100 firmware via Nu-Link2 + OpenOCD
# DANGER: only run with a known-good image AFTER a backup (mcu_read.sh).
# Usage: ./mcu_write.sh <firmware.bin>
set -e
[ -n "$1" ] || { echo "usage: $0 <firmware.bin>"; exit 2; }
[ -f "$1" ] || { echo "not found: $1"; exit 2; }
echo "About to program $1. Press Ctrl-C now to abort, or Enter to continue."
read -r _
openocd -f "$(dirname "$0")/nuc100.cfg" \
  -c "init; halt; program $1 verify reset exit 0x0" 2>&1 | tail -8
