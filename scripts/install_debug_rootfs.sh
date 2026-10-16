#!/usr/bin/env bash
# Install into an UNPACKED rootfs only. Never accesses a device or flashes.
# Usage: scripts/install_debug_rootfs.sh ROOTFS
# ENABLE_DEBUG_EXEC=1 explicitly opts this lab image into root command execution.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${1:?Usage: install_debug_rootfs.sh UNPACKED_ROOTFS}"
ROOTFS="$(realpath -e "$ROOTFS")"
[[ "$ROOTFS" != / ]] || { echo "Refusing host root filesystem" >&2; exit 1; }
[[ -d "$ROOTFS/etc" && -d "$ROOTFS/usr" ]] || { echo "Not an unpacked rootfs" >&2; exit 1; }
# Always rebuild to avoid injecting a stale daemon after a header change.
make -C "$ROOT_DIR/test_app" qpcie_debugd qpcie_hdmi_daemon
install -D -m 0755 "$ROOT_DIR/test_app/qpcie_debugd" "$ROOTFS/usr/bin/qpcie_debugd"
install -D -m 0755 "$ROOT_DIR/test_app/qpcie_hdmi_daemon" "$ROOTFS/usr/bin/qpcie_hdmi_daemon"
install -D -m 0644 \
    "$ROOT_DIR/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-apps/qpcie-debugd/files/qpcie-debugd.service" \
    "$ROOTFS/lib/systemd/system/qpcie-debugd.service"
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /lib/systemd/system/qpcie-debugd.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/qpcie-debugd.service"
# Resolve symlinks as the TARGET root would, not against the build host.
# Yocto update-alternatives uses absolute links (e.g. /bin/bash.bash);
# a normal `test -f ROOTFS/bin/bash` follows those into the host filesystem.
rootfs_regular_file() {
    local remaining="${1#/}" current="$ROOTFS" part link links=0
    while [[ -n "$remaining" ]]; do
        if [[ "$remaining" == */* ]]; then
            part="${remaining%%/*}"; remaining="${remaining#*/}"
        else
            part="$remaining"; remaining=
        fi
        case "$part" in
            ''|.) continue ;;
            ..) [[ "$current" == "$ROOTFS" ]] || current="${current%/*}"; continue ;;
        esac
        if [[ -L "$current/$part" ]]; then
            if (( ++links > 40 )); then return 1; fi
            link="$(readlink "$current/$part")" || return 1
            if [[ "$link" == /* ]]; then current="$ROOTFS"; link="${link#/}"; fi
            remaining="$link${remaining:+/$remaining}"
        else
            current="$current/$part"
        fi
    done
    [[ -f "$current" ]]
}
if [[ "${ENABLE_DEBUG_EXEC:-0}" == 1 ]]; then
    mkdir -p "$ROOTFS/etc/default"
    DEBUG_SHELL=/bin/sh
    for shell in /bin/bash /usr/bin/bash; do
        if rootfs_regular_file "$shell"; then DEBUG_SHELL="$shell"; break; fi
    done
    printf 'DEBUG_EXEC_ARGS=--allow-exec\nDEBUG_SHELL=%s\n' "$DEBUG_SHELL" > "$ROOTFS/etc/default/qpcie-debugd"
    chmod 0600 "$ROOTFS/etc/default/qpcie-debugd"
    echo "WARNING: this lab image permits root shell commands over PCIe."
else
    # Explicitly turn execution off, including when reusing an existing rootfs.
    mkdir -p "$ROOTFS/etc/default"
    printf 'DEBUG_EXEC_ARGS=\nDEBUG_SHELL=/bin/sh\n' > "$ROOTFS/etc/default/qpcie-debugd"
    chmod 0600 "$ROOTFS/etc/default/qpcie-debugd"
fi
