#!/bin/bash
# ==============================================================================
# Script: inject_upgrade_daemon_to_image_ub.sh
# Description: Injects qpcie_upgrade_daemon into PetaLinux rootfs and repacks image.ub
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMG_DIR="$ROOT_DIR/petalinux/qpcie-zu4ev/images/linux"
TARGET_DAEMON="$ROOT_DIR/test_app/qpcie_upgrade_daemon"
ROOTFS_BASE="$IMG_DIR/rootfs.cpio.gz"
KERNEL_GZ="$IMG_DIR/Image.gz"
DTB="$IMG_DIR/system.dtb"
OUT_IMGUB="$IMG_DIR/image.ub"
REL_TARGET_DIR="$ROOT_DIR/release/zu4ev_sd_installer/target_emmc"

MKIMAGE="/opt/Xilinx/petalinux/2023.2/components/yocto/buildtools/sysroots/x86_64-petalinux-linux/usr/bin/mkimage"
[ -x "$MKIMAGE" ] || MKIMAGE=$(which mkimage 2>/dev/null || true)

DTC="/opt/Xilinx/Vitis/2023.2/bin/dtc"
[ -x "$DTC" ] || DTC=$(which dtc 2>/dev/null || true)
export PATH="$(dirname "$DTC"):$PATH"

if [ ! -f "$TARGET_DAEMON" ]; then
    echo "Building qpcie_upgrade_daemon..."
    make -C "$ROOT_DIR/test_app" qpcie_upgrade_daemon
fi

if [ ! -f "$ROOTFS_BASE" ] || [ ! -f "$KERNEL_GZ" ] || [ ! -f "$DTB" ]; then
    echo "ERROR: Missing required files in $IMG_DIR!"
    exit 1
fi

WORK_DIR="/tmp/inject_daemon_$$"
mkdir -p "$WORK_DIR/rootfs"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "================================================================="
echo " Injecting qpcie_upgrade_daemon into PetaLinux image.ub"
echo "================================================================="

echo "[1/4] Unpacking rootfs.cpio.gz..."
cd "$WORK_DIR/rootfs"
zcat "$ROOTFS_BASE" | fakeroot cpio -idm --quiet

echo "[2/4] Installing daemon and systemd service..."
cp -v "$TARGET_DAEMON" "$WORK_DIR/rootfs/usr/bin/qpcie_upgrade_daemon"
chmod 755 "$WORK_DIR/rootfs/usr/bin/qpcie_upgrade_daemon"

cat << 'EOF' > "$WORK_DIR/rootfs/lib/systemd/system/qpcie-upgrade-daemon.service"
[Unit]
Description=QPCIe SC7F0 In-System Firmware Upgrade Daemon
After=local-fs.target systemd-udevd.service
Wants=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/qpcie_upgrade_daemon
Restart=always
RestartSec=3
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$WORK_DIR/rootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/qpcie-upgrade-daemon.service \
       "$WORK_DIR/rootfs/etc/systemd/system/multi-user.target.wants/qpcie-upgrade-daemon.service"

echo "[3/4] Repacking rootfs.cpio.gz..."
NEW_ROOTFS="$WORK_DIR/rootfs_with_daemon.cpio.gz"
cd "$WORK_DIR/rootfs"
fakeroot bash -c "find . | cpio -H newc -o --quiet | gzip -9 > '$NEW_ROOTFS'"

echo "[4/4] Building image.ub FIT image with mkimage..."
cat << EOF > "$WORK_DIR/fit_image.its"
/dts-v1/;

/ {
    description = "QPCIe SC7F0 Production Image with Firmware Upgrade Daemon";
    #address-cells = <1>;

    images {
        kernel-1 {
            description = "ARM64 Linux Kernel";
            data = /incbin/("$KERNEL_GZ");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "gzip";
            load = <0x00200000>;
            entry = <0x00200000>;
            hash-1 {
                algo = "sha256";
            };
        };

        fdt-1 {
            description = "Flattened Device Tree Blob";
            data = /incbin/("$DTB");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            load = <0x00100000>;
            hash-1 {
                algo = "sha256";
            };
        };

        ramdisk-1 {
            description = "Petalinux Production RootFS with Upgrade Daemon";
            data = /incbin/("$NEW_ROOTFS");
            type = "ramdisk";
            arch = "arm64";
            os = "linux";
            compression = "none";
            hash-1 {
                algo = "sha256";
            };
        };
    };

    configurations {
        default = "conf-1";
        conf-1 {
            description = "QPCIe Production Boot";
            kernel = "kernel-1";
            fdt = "fdt-1";
            ramdisk = "ramdisk-1";
            hash-1 {
                algo = "sha256";
            };
        };
    };
};
EOF

"$MKIMAGE" -f "$WORK_DIR/fit_image.its" "$OUT_IMGUB" > /dev/null

echo "  -> New image.ub generated: $(ls -lh "$OUT_IMGUB" | awk '{print $5}')"
echo "  -> SHA256: $(sha256sum "$OUT_IMGUB" | awk '{print $1}')"

if [ -d "$REL_TARGET_DIR" ]; then
    cp -v "$OUT_IMGUB" "$REL_TARGET_DIR/image.ub"
fi

echo "================================================================="
echo " SUCCESS: image.ub repacked with qpcie_upgrade_daemon service!"
echo "================================================================="
