#!/usr/bin/env bash
# Compatibility alias: always run the full gated FPGA/XSA + PS build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "$ROOT/scripts/sc7f0_build.sh" "$@"
