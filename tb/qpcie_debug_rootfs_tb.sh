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
# The standalone installer must strip both MMIO services, binaries and presets.
mkdir -p "$WORK/lib/systemd/system-preset"
touch "$WORK/lib/systemd/system-preset/98-qpcie-debugd.preset" \
      "$WORK/lib/systemd/system-preset/98-qpcie-upgrade-daemon.preset" \
      "$WORK/lib/systemd/system/qpcie-upgrade-daemon.service" \
      "$WORK/usr/bin/qpcie_upgrade_daemon"
ln -s /lib/systemd/system/qpcie-upgrade-daemon.service \
    "$WORK/etc/systemd/system/multi-user.target.wants/qpcie-upgrade-daemon.service"
bash "$ROOT/scripts/strip_sc7f0_mmio_services.sh" "$WORK"
if find "$WORK" -iname '*qpcie*' | grep -q .; then
    echo 'FAIL: standalone installer contains MMIO service artifacts' >&2; exit 1
fi
test -f "$WORK/usr/bin/bash" # unrelated files must be preserved
if bash "$ROOT/scripts/strip_sc7f0_mmio_services.sh" / >/dev/null 2>&1; then
    echo 'FAIL: stripper accepted host /' >&2; exit 1
fi
echo 'TB_PASS: rootfs exec opt-in, Bash selection, disable on reuse, installer strips MMIO services/presets, root guards'
