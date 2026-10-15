#!/usr/bin/env bash
# File-only cleanup of the STANDALONE INSTALLER rootfs, never the production
# target_emmc image. MMIO daemons must not start during SD provisioning.
set -euo pipefail
ROOTFS="$(realpath -e "${1:?Usage: strip_sc7f0_mmio_services.sh UNPACKED_ROOTFS}")"
[[ "$ROOTFS" != / && -d "$ROOTFS/etc" && -d "$ROOTFS/usr" ]] || {
    echo "Refusing invalid/host root filesystem" >&2; exit 1;
}
for service in qpcie-debugd qpcie-upgrade-daemon; do
    rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/$service.service" \
          "$ROOTFS/etc/systemd/system/$service.service" \
          "$ROOTFS/lib/systemd/system/$service.service" \
          "$ROOTFS/usr/lib/systemd/system/$service.service" \
          "$ROOTFS/lib/systemd/system-preset/98-$service.preset" \
          "$ROOTFS/usr/lib/systemd/system-preset/98-$service.preset"
done
rm -f "$ROOTFS/usr/bin/qpcie_debugd" "$ROOTFS/usr/bin/qpcie_upgrade_daemon" \
      "$ROOTFS/etc/default/qpcie-debugd"
