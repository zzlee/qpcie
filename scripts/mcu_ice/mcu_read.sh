#!/bin/bash
# Read NUC100 flash backup via Nu-Link2 + OpenOCD (read-only, safe first step)
# Usage: ./mcu_read.sh [output.bin]   (default: mcu_backup_$(date).bin)
# NUC100LE3AN = 128KB APROM (0x00000000-0x0001FFFF)
set -e
OUT="${1:-mcu_backup_$(date +%Y%m%d_%H%M%S).bin}"
openocd -f "$(dirname "$0")/nuc100.cfg" \
  -c "init; halt; dump_image $OUT 0x0 0x20000; resume; shutdown" 2>&1 | tail -5
ls -la "$OUT"
