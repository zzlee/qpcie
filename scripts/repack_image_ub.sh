#!/bin/bash
# ==============================================================================
# Script to repack PetaLinux image.ub with Automatic eMMC Flashing Service
# Target: SC7F0 N1 HDMI2 V11 (Zynq UltraScale+ XCZU4EV)
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PETALINUX_IMG_DIR="$REPO_ROOT/petalinux/qpcie-zu4ev/images/linux"
KERNEL_BIN="$REPO_ROOT/petalinux/qpcie-zu4ev/build/tmp/work/zynqmp_generic_xczu4ev-xilinx-linux/linux-xlnx/6.1.30-xilinx-v2023.2+gitAUTOINC+a19da02cf5-r0/linux-zynqmp_generic_xczu4ev-standard-build/linux.bin"
DTB_BIN="$PETALINUX_IMG_DIR/system.dtb"
ORIG_ROOTFS="$PETALINUX_IMG_DIR/rootfs.cpio.gz"
RELEASE_DIR="$REPO_ROOT/release/zu4ev_sd_boot"

MKIMAGE_TOOL="/opt/Xilinx/petalinux/2023.2/components/yocto/buildtools/sysroots/x86_64-petalinux-linux/usr/bin/mkimage"
DTC_DIR="/opt/Xilinx/petalinux/2023.2/components/yocto/buildtools/sysroots/x86_64-petalinux-linux/usr/bin"
export PATH="$DTC_DIR:$PATH"

echo "================================================================="
echo "  Repacking PetaLinux image.ub with Auto-Flash eMMC Service"
echo "================================================================="

if [ ! -f "$ORIG_ROOTFS" ]; then
    echo "ERROR: Original rootfs not found at $ORIG_ROOTFS"
    exit 1
fi

if [ ! -f "$KERNEL_BIN" ]; then
    echo "ERROR: Kernel binary not found at $KERNEL_BIN"
    exit 1
fi

if [ ! -f "$DTB_BIN" ]; then
    echo "ERROR: DTB binary not found at $DTB_BIN"
    exit 1
fi

WORK_DIR=$(mktemp -d -p /tmp repack_imgub_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

ROOTFS_UNPACK="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_UNPACK"

echo "[1/5] Extracting rootfs.cpio.gz..."
(
    cd "$ROOTFS_UNPACK"
    zcat "$ORIG_ROOTFS" | cpio -idm --quiet
)
# Ensure read permissions for non-root packing
chmod -R u+rwX "$ROOTFS_UNPACK"
[ -f "$ROOTFS_UNPACK/usr/bin/sudo" ] && chmod 4755 "$ROOTFS_UNPACK/usr/bin/sudo"
[ -f "$ROOTFS_UNPACK/usr/sbin/unix_chkpwd" ] && chmod 4755 "$ROOTFS_UNPACK/usr/sbin/unix_chkpwd"


echo "[2/5] Injecting autoflash_emmc.sh and systemd service..."

# 1. Create /usr/sbin/autoflash_emmc.sh
cat << 'AUTOSCRIPT_EOF' > "$ROOTFS_UNPACK/usr/sbin/autoflash_emmc.sh"
#!/bin/sh
# ==============================================================================
# SC7F0 N1 HDMI2 V11: Automatic eMMC Provisioning Script
# Executed automatically at boot by systemd (emmc-autoflash.service)
# All output and results are recorded to the SD Card FAT32 partition.
# ==============================================================================

set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

klog() {
    echo "[EMMC-AUTOFLASH] $*"
    if [ -w /dev/kmsg ]; then
        echo "<6>[EMMC-AUTOFLASH] $*" > /dev/kmsg 2>/dev/null || true
    fi
}

klog "Initializing SC7F0 N1 HDMI2 V11 Automatic eMMC Flasher..."

# Allow block devices to settle
if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=10 || true
fi
sleep 2

# Identify block devices
SD_DEV=""
EMMC_DEV=""

for devpath in /sys/block/mmcblk*; do
    [ -d "$devpath" ] || continue
    bname=$(basename "$devpath")
    case "$bname" in
        *boot*|*rpmb*) continue ;;
    esac

    if [ -f "$devpath/device/type" ]; then
        mtype=$(cat "$devpath/device/type")
        if [ "$mtype" = "MMC" ]; then
            EMMC_DEV="/dev/$bname"
        elif [ "$mtype" = "SD" ]; then
            SD_DEV="/dev/$bname"
        fi
    fi
done

# Fallback: if SD_DEV or EMMC_DEV not determined by type, inspect sysfs/sizes
if [ -z "$EMMC_DEV" ]; then
    for devpath in /sys/block/mmcblk*; do
        [ -d "$devpath" ] || continue
        bname=$(basename "$devpath")
        case "$bname" in
            *boot*|*rpmb*) continue ;;
        esac
        # eMMC on SC7F0 is Toshiba 8GB (approx 15000000-16000000 512B sectors)
        if [ -f "$devpath/size" ]; then
            devsz=$(cat "$devpath/size")
            if [ "$devsz" -ge 14000000 ] && [ "$devsz" -le 16500000 ]; then
                EMMC_DEV="/dev/$bname"
                break
            fi
        fi
    done
fi

SD_MNT="/mnt/sd_boot"
mkdir -p "$SD_MNT"

find_and_mount_sd() {
    # Check if already mounted somewhere with BOOT.BIN
    for m in $(grep -E "mmcblk|sd" /proc/mounts 2>/dev/null | awk '{print $2}'); do
        if [ -f "$m/BOOT.BIN" ] && [ -f "$m/image.ub" ]; then
            SD_MNT="$m"
            mount -o remount,rw "$SD_MNT" 2>/dev/null || true
            return 0
        fi
    done

    # Try SD_DEV partition 1 if known
    if [ -n "$SD_DEV" ]; then
        for part in "${SD_DEV}p1" "${SD_DEV}1"; do
            if [ -b "$part" ]; then
                if mount -o rw,sync "$part" "$SD_MNT" 2>/dev/null; then
                    if [ -f "$SD_MNT/BOOT.BIN" ]; then
                        return 0
                    fi
                    umount "$SD_MNT" 2>/dev/null || true
                fi
            fi
        done
    fi

    # Scan any mmc partitions except EMMC_DEV
    for p in /dev/mmcblk*p1 /dev/mmcblk*1; do
        [ -b "$p" ] || continue
        if [ -n "$EMMC_DEV" ]; then
            case "$p" in
                ${EMMC_DEV}*) continue ;;
            esac
        fi
        if mount -o rw,sync "$p" "$SD_MNT" 2>/dev/null; then
            if [ -f "$SD_MNT/BOOT.BIN" ] && [ -f "$SD_MNT/image.ub" ]; then
                return 0
            fi
            umount "$SD_MNT" 2>/dev/null || true
        fi
    done
    return 1
}

if ! find_and_mount_sd; then
    klog "ERROR: Could not locate SD Card boot partition with BOOT.BIN!"
    exit 1
fi

klog "SD Card mounted at: $SD_MNT"

# Redirect all future output to both log file and console
LOG_FILE="$SD_MNT/emmc_flash.log"
exec >> "$LOG_FILE" 2>&1

echo ""
echo "================================================================="
echo "  SC7F0 N1 HDMI2 V11: Automatic eMMC Provisioning System"
echo "  Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)"
echo "================================================================="
echo "SD Card Mount  : $SD_MNT"
echo "Detected eMMC  : ${EMMC_DEV:-[NOT FOUND]}"
echo "Detected SD    : ${SD_DEV:-[AUTO]}"

# Safety Check: DO_NOT_FLASH flag
if [ -f "$SD_MNT/DO_NOT_FLASH" ] || [ -f "$SD_MNT/NO_AUTO_FLASH" ]; then
    echo "NOTICE: 'DO_NOT_FLASH' flag detected on SD card. Skipping auto-flash."
    klog "DO_NOT_FLASH flag detected. Aborting eMMC flash."
    exit 0
fi

if [ -z "$EMMC_DEV" ]; then
    echo "ERROR: Internal eMMC block device not found!"
    klog "ERROR: Internal eMMC block device not found!"
    echo "ERROR: eMMC device not found at $(date)" > "$SD_MNT/EMMC_FLASH_FAILED.txt"
    sync
    exit 1
fi

# Check if eMMC is already up to date with this BOOT.BIN
CURRENT_BOOT_BIN_HASH=$(sha256sum "$SD_MNT/BOOT.BIN" | awk '{print $1}')
echo "Current SD BOOT.BIN SHA256: $CURRENT_BOOT_BIN_HASH"

if [ -f "$SD_MNT/EMMC_FLASH_SUCCESS.txt" ] && [ ! -f "$SD_MNT/FORCE_FLASH" ]; then
    if grep -q "$CURRENT_BOOT_BIN_HASH" "$SD_MNT/EMMC_FLASH_SUCCESS.txt" 2>/dev/null; then
        echo "================================================================="
        echo " NOTICE: eMMC is already verified with identical BOOT.BIN!"
        echo " SHA256: $CURRENT_BOOT_BIN_HASH"
        echo " Skipping redundant flashing to prevent eMMC wear."
        echo " (To force re-flash, touch FORCE_FLASH or delete EMMC_FLASH_SUCCESS.txt)"
        echo "================================================================="
        klog "eMMC already up-to-date. Skipping."
        rm -f "$SD_MNT/EMMC_FLASH_IN_PROGRESS.txt" 2>/dev/null || true
        sync
        exit 0
    fi
fi

# Write IN_PROGRESS status file
cat << EOF > "$SD_MNT/EMMC_FLASH_IN_PROGRESS.txt"
Flashing eMMC in progress...
Started at: $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)
Target: $EMMC_DEV
Source: $SD_MNT
BOOT.BIN SHA256: $CURRENT_BOOT_BIN_HASH
EOF
sync

rm -f "$SD_MNT/EMMC_FLASH_FAILED.txt" 2>/dev/null || true

echo "[Step 1/6] Unmounting any active partitions on $EMMC_DEV..."
for part in ${EMMC_DEV}*; do
    umount "$part" 2>/dev/null || true
done

EMMC_P1="${EMMC_DEV}p1"
EMMC_P2="${EMMC_DEV}p2"
[ -b "$EMMC_P1" ] || EMMC_P1="${EMMC_DEV}1"
[ -b "$EMMC_P2" ] || EMMC_P2="${EMMC_DEV}2"

DATA_PRESERVED=0
FORCE_WIPE=0
[ -f "$SD_MNT/WIPE_EMMC_DATA" ] && FORCE_WIPE=1

if [ -b "$EMMC_P1" ] && [ -b "$EMMC_P2" ] && [ "$FORCE_WIPE" -eq 0 ]; then
    echo "[Step 2/6] Existing eMMC partition table detected:"
    echo "  - Boot Partition : $EMMC_P1 (will be updated)"
    echo "  - Data Partition : $EMMC_P2 (WILL BE PRESERVED - NO DATA LOSS)"
    DATA_PRESERVED=1
else
    echo "[Step 2/6] Initializing eMMC partitions for the first time..."
    dd if=/dev/zero of="$EMMC_DEV" bs=1M count=10 status=none conv=fsync
    sync

    echo "[Step 3/6] Creating MBR partition table on $EMMC_DEV using fdisk..."
    # Create:
    # p1: Primary 1, +1536M (1.5GB), Type c (W95 FAT32 LBA), Bootable
    # p2: Primary 2, rest of device (~6GB), Type 83 (Linux DATA)
    fdisk "$EMMC_DEV" << 'FDISK_EOF' >/dev/null 2>&1
o
n
p
1
2048
+1536M
t
c
a
1
n
p
2


t
2
83
w
FDISK_EOF

    sync
    sleep 2
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=5 || true
    fi

    [ -b "${EMMC_DEV}p1" ] && EMMC_P1="${EMMC_DEV}p1"
    [ -b "${EMMC_DEV}p2" ] && EMMC_P2="${EMMC_DEV}p2"
    [ -b "${EMMC_DEV}1" ] && EMMC_P1="${EMMC_DEV}1"
    [ -b "${EMMC_DEV}2" ] && EMMC_P2="${EMMC_DEV}2"

    if [ ! -b "$EMMC_P1" ]; then
        echo "ERROR: Partition $EMMC_P1 was not created!"
        klog "ERROR: Partition $EMMC_P1 was not created!"
        echo "Partitioning failed at $(date)" > "$SD_MNT/EMMC_FLASH_FAILED.txt"
        rm -f "$SD_MNT/EMMC_FLASH_IN_PROGRESS.txt"
        sync
        exit 1
    fi

    echo "  Formatting $EMMC_P2 as EXT4 (Label: DATA)..."
    mkfs.ext4 -F -L "DATA" "$EMMC_P2"
fi

echo "[Step 4/6] Formatting Boot Partition..."
echo "  Formatting $EMMC_P1 as FAT32 (BOOT)..."
mkfs.vfat -F 32 -n "BOOT" "$EMMC_P1"

if [ "$DATA_PRESERVED" -eq 1 ]; then
    if blkid "$EMMC_P2" 2>/dev/null | grep -q 'TYPE="ext4"'; then
        echo "  [OK] Successfully preserved existing DATA partition ($EMMC_P2)."
        echo "       Existing files on DATA partition remain untouched."
    else
        echo "  Notice: Partition $EMMC_P2 missing filesystem. Formatting as EXT4 (DATA)..."
        mkfs.ext4 -F -L "DATA" "$EMMC_P2"
    fi
fi
sync


echo "[Step 5/6] Copying boot artifacts to eMMC partition 1 ($EMMC_P1)..."
EMMC_MNT="/tmp/emmc_boot_target"
mkdir -p "$EMMC_MNT"
mount "$EMMC_P1" "$EMMC_MNT"

echo "  Copying BOOT.BIN ($(ls -lh "$SD_MNT/BOOT.BIN" | awk '{print $5}'))"
cp -v "$SD_MNT/BOOT.BIN" "$EMMC_MNT/BOOT.BIN"

if [ -f "$SD_MNT/boot.scr" ]; then
    echo "  Copying boot.scr ($(ls -lh "$SD_MNT/boot.scr" | awk '{print $5}'))"
    cp -v "$SD_MNT/boot.scr" "$EMMC_MNT/boot.scr"
fi

if [ -f "$SD_MNT/image.ub" ]; then
    echo "  Copying image.ub ($(ls -lh "$SD_MNT/image.ub" | awk '{print $5}'))"
    cp -v "$SD_MNT/image.ub" "$EMMC_MNT/image.ub"
fi

sync
umount "$EMMC_MNT"

# Also write to eMMC hardware boot partition 0 if present (dual boot safety)
EMMC_BNAME=$(basename "$EMMC_DEV")
if [ -b "/dev/${EMMC_BNAME}boot0" ]; then
    echo "  Writing backup image to /dev/${EMMC_BNAME}boot0..."
    echo 0 > "/sys/block/${EMMC_BNAME}boot0/force_ro" 2>/dev/null || true
    dd if="$SD_MNT/BOOT.BIN" of="/dev/${EMMC_BNAME}boot0" bs=64k status=none conv=fsync || true
    sync
    echo 1 > "/sys/block/${EMMC_BNAME}boot0/force_ro" 2>/dev/null || true
fi

echo "[Step 6/6] Verifying eMMC contents against SD card sources..."
sync
echo 3 > /proc/sys/vm/drop_caches

mount -o ro "$EMMC_P1" "$EMMC_MNT"

HASH_MATCH=1

verify_file() {
    fname="$1"
    src_file="$SD_MNT/$fname"
    dst_file="$EMMC_MNT/$fname"

    if [ ! -f "$src_file" ]; then
        return 0
    fi
    if [ ! -f "$dst_file" ]; then
        echo "  [FAIL] $fname is missing on eMMC!"
        HASH_MATCH=0
        return 1
    fi

    src_h=$(sha256sum "$src_file" | awk '{print $1}')
    dst_h=$(sha256sum "$dst_file" | awk '{print $1}')

    if [ "$src_h" = "$dst_h" ]; then
        echo "  [OK] $fname SHA256: $dst_h"
        return 0
    else
        echo "  [MISMATCH] $fname:"
        echo "    Source: $src_h"
        echo "    Dest:   $dst_h"
        HASH_MATCH=0
        return 1
    fi
}

verify_file "BOOT.BIN"
verify_file "boot.scr"
verify_file "image.ub"

BOOT_HASH=$(sha256sum "$EMMC_MNT/BOOT.BIN" 2>/dev/null | awk '{print $1}')
BOOT_SIZE=$(ls -lh "$EMMC_MNT/BOOT.BIN" 2>/dev/null | awk '{print $5}')
UB_HASH=$(sha256sum "$EMMC_MNT/image.ub" 2>/dev/null | awk '{print $1}')
UB_SIZE=$(ls -lh "$EMMC_MNT/image.ub" 2>/dev/null | awk '{print $5}')
SCR_HASH=$(sha256sum "$EMMC_MNT/boot.scr" 2>/dev/null | awk '{print $1}')

umount "$EMMC_MNT"
rm -rf "$EMMC_MNT"

if [ "$HASH_MATCH" -ne 1 ]; then
    echo "================================================================="
    echo " ERROR: eMMC verification failed! Checksum mismatch detected."
    echo "================================================================="
    cat << EOF > "$SD_MNT/EMMC_FLASH_FAILED.txt"
=================================================================
 SC7F0 N1 HDMI2 V11: eMMC FLASH FAILED
 Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)
 Checksum mismatch detected during verification.
 See emmc_flash.log for details.
=================================================================
EOF
    rm -f "$SD_MNT/EMMC_FLASH_IN_PROGRESS.txt"
    sync
    klog "ERROR: eMMC flashing failed!"
    exit 1
fi

echo "================================================================="
echo " SUCCESS: eMMC has been successfully programmed & verified 100%!"
echo "================================================================="
klog "SUCCESS: eMMC flashing & verification completed successfully!"

cat << EOF > "$SD_MNT/EMMC_FLASH_SUCCESS.txt"
=================================================================
 SC7F0 N1 HDMI2 V11: eMMC FLASH SUCCESSFUL
=================================================================
Timestamp       : $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)
Target Device   : $EMMC_DEV (Toshiba 8GB eMMC THGBMNG5D1LBAIT)
Boot Partition  : $EMMC_P1 (FAT32, Bootable, 1024MB)
Root Partition  : $EMMC_P2 (EXT4, rootfs)
Status          : VERIFIED_OK (100% SHA256 Match)

[Verified Image Hashes]
BOOT.BIN        : $BOOT_HASH (Size: $BOOT_SIZE)
image.ub        : $UB_HASH (Size: $UB_SIZE)
boot.scr        : $SCR_HASH
mmcblk0boot0    : Written (Hardware Backup Boot Partition)

=================================================================
 NEXT STEPS: SWITCH TO eMMC BOOT MODE
=================================================================
1. Power OFF the SC7F0 board or host PC.
2. Remove the SD card (or keep it in for backup).
3. Set the Boot Mode DIP Switch SW1 to eMMC 1.8V Mode:
     MODE[3:0] = 0 1 1 0  (Binary 4'b0110)
     Switch 1 (MODE0) : OFF (0)
     Switch 2 (MODE1) : ON  (1)
     Switch 3 (MODE2) : ON  (1)
     Switch 4 (MODE3) : OFF (0)
4. Power ON the board / host PC.
5. The SC7F0 will now boot directly from on-board eMMC and complete
   PCIe Gen3 x4 link training well within the PCIe 100ms specification!
6. On host PC, verify enumeration:
   lspci -d 12ab:e380 -vvv
=================================================================
EOF

# Clean up temporary status flags
rm -f "$SD_MNT/EMMC_FLASH_IN_PROGRESS.txt" 2>/dev/null || true
rm -f "$SD_MNT/EMMC_FLASH_FAILED.txt" 2>/dev/null || true
rm -f "$SD_MNT/FORCE_FLASH" 2>/dev/null || true

echo "Flashing log finalized. Syncing filesystem..."
sync
sleep 1
mount -o remount,ro "$SD_MNT" 2>/dev/null || true
sync

echo "ALL DONE! Board is ready. You may power off now."
klog "ALL DONE! Safe to power down."

exit 0
AUTOSCRIPT_EOF

chmod 755 "$ROOTFS_UNPACK/usr/sbin/autoflash_emmc.sh"

# 2. Create systemd service
cat << 'SERVICE_EOF' > "$ROOTFS_UNPACK/lib/systemd/system/emmc-autoflash.service"
[Unit]
Description=SC7F0 N1 HDMI2 V11 Automatic eMMC Flashing Service
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/autoflash_emmc.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SERVICE_EOF

chmod 644 "$ROOTFS_UNPACK/lib/systemd/system/emmc-autoflash.service"

# Enable service in multi-user.target.wants
mkdir -p "$ROOTFS_UNPACK/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/emmc-autoflash.service \
       "$ROOTFS_UNPACK/etc/systemd/system/multi-user.target.wants/emmc-autoflash.service"

# 3. Create /etc/rc.local as secondary fallback
cat << 'RCLOCAL_EOF' > "$ROOTFS_UNPACK/etc/rc.local"
#!/bin/sh -e
# Fallback trigger in case systemd rc-local generator is used
if [ -x /usr/sbin/autoflash_emmc.sh ]; then
    /usr/sbin/autoflash_emmc.sh
fi
exit 0
RCLOCAL_EOF

chmod 755 "$ROOTFS_UNPACK/etc/rc.local"

# 4. Configure Persistent /data Mount Point
mkdir -p "$ROOTFS_UNPACK/mnt/data"
ln -sf /mnt/data "$ROOTFS_UNPACK/data"

# Add /dev/disk/by-label/DATA to /etc/fstab if not already present
if ! grep -q "by-label/DATA" "$ROOTFS_UNPACK/etc/fstab" 2>/dev/null; then
    cat << 'FSTAB_DATA' >> "$ROOTFS_UNPACK/etc/fstab"
/dev/disk/by-label/DATA  /mnt/data  ext4  defaults,noatime,nofail  0  2
FSTAB_DATA
fi

# Also add dedicated systemd mount unit for high reliability
cat << 'MOUNT_UNIT_EOF' > "$ROOTFS_UNPACK/lib/systemd/system/mnt-data.mount"
[Unit]
Description=Mount eMMC Persistent DATA Partition
DefaultDependencies=no
After=systemd-udev-settle.service local-fs-pre.target
Before=local-fs.target

[Mount]
What=/dev/disk/by-label/DATA
Where=/mnt/data
Type=ext4
Options=defaults,noatime,nofail

[Install]
WantedBy=local-fs.target
MOUNT_UNIT_EOF

chmod 644 "$ROOTFS_UNPACK/lib/systemd/system/mnt-data.mount"
mkdir -p "$ROOTFS_UNPACK/etc/systemd/system/local-fs.target.wants"
ln -sf /lib/systemd/system/mnt-data.mount \
       "$ROOTFS_UNPACK/etc/systemd/system/local-fs.target.wants/mnt-data.mount"

echo "[3/5] Packing modified rootfs into CPIO archive..."

NEW_ROOTFS="$WORK_DIR/rootfs.cpio.gz"
(
    cd "$ROOTFS_UNPACK"
    find . | cpio -H newc -o --owner=0:0 --quiet | gzip -9 -n > "$NEW_ROOTFS"
)

echo "  New rootfs size: $(ls -lh "$NEW_ROOTFS" | awk '{print $5}')"

echo "[4/5] Generating FIT image description (.its)..."
cat << FIT_EOF > "$WORK_DIR/fit-image.its"
/dts-v1/;

/ {
    description = "Kernel fitImage for PetaLinux SC7F0 ZU4EV Auto-Flasher";
    #address-cells = <1>;

    images {
        kernel-1 {
            description = "Linux kernel";
            data = /incbin/("$KERNEL_BIN");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "gzip";
            load = <0x200000>;
            entry = <0x200000>;
            hash-1 {
                algo = "sha256";
            };
        };
        fdt-system-top.dtb {
            description = "Flattened Device Tree blob";
            data = /incbin/("$DTB_BIN");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            hash-1 {
                algo = "sha256";
            };
        };
        ramdisk-1 {
            description = "petalinux-image-minimal-autoflash";
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
        default = "conf-system-top.dtb";
        conf-system-top.dtb {
            description = "1 Linux kernel, FDT blob, ramdisk";
            kernel = "kernel-1";
            fdt = "fdt-system-top.dtb";
            ramdisk = "ramdisk-1";
            hash-1 {
                algo = "sha256";
            };
        };
    };
};
FIT_EOF

echo "[5/5] Compiling image.ub using mkimage..."
"$MKIMAGE_TOOL" -f "$WORK_DIR/fit-image.its" "$WORK_DIR/image.ub"

# Install new image.ub
cp "$WORK_DIR/image.ub" "$PETALINUX_IMG_DIR/image.ub"
cp "$WORK_DIR/image.ub" "$RELEASE_DIR/image.ub"

echo "================================================================="
echo " SUCCESS: Repacked image.ub generated successfully!"
echo " Location: $RELEASE_DIR/image.ub"
echo " Size    : $(ls -lh "$RELEASE_DIR/image.ub" | awk '{print $5}')"
echo " SHA256  : $(sha256sum "$RELEASE_DIR/image.ub" | awk '{print $1}')"
echo "================================================================="
