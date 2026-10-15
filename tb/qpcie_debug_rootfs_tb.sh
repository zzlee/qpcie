#!/usr/bin/env bash
# File-only packaging regression; no root/device access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/etc" "$WORK/usr/bin"
ENABLE_DEBUG_EXEC=1 bash "$ROOT/scripts/install_debug_rootfs.sh" "$WORK" >/dev/null
grep -qx 'DEBUG_EXEC_ARGS=--allow-exec' "$WORK/etc/default/qpcie-debugd"
grep -qx 'DEBUG_SHELL=/bin/sh' "$WORK/etc/default/qpcie-debugd"
test "$(stat -c %a "$WORK/etc/default/qpcie-debugd")" = 600
# A recipe-installed Bash should be selected for the explicit lab image.
touch "$WORK/usr/bin/bash"
ENABLE_DEBUG_EXEC=1 bash "$ROOT/scripts/install_debug_rootfs.sh" "$WORK" >/dev/null
grep -qx 'DEBUG_SHELL=/bin/bash' "$WORK/etc/default/qpcie-debugd"
# Reusing an enabled rootfs without the opt-in must DISABLE execution.
ENABLE_DEBUG_EXEC=0 bash "$ROOT/scripts/install_debug_rootfs.sh" "$WORK" >/dev/null
grep -qx 'DEBUG_EXEC_ARGS=' "$WORK/etc/default/qpcie-debugd"
test "$(readlink "$WORK/etc/systemd/system/multi-user.target.wants/qpcie-debugd.service")" = /lib/systemd/system/qpcie-debugd.service
grep -qx 'KillMode=control-group' "$WORK/lib/systemd/system/qpcie-debugd.service"
if bash "$ROOT/scripts/install_debug_rootfs.sh" / >/dev/null 2>&1; then
    echo 'FAIL: accepted host / as unpacked rootfs' >&2; exit 1
fi
echo 'TB_PASS: rootfs explicit exec opt-in, Bash selection, disable on reuse, service, root guard'
