#!/bin/sh
# ==============================================================================
# Script to flash eMMC on SC7F0 N1 HDMI2 V11 from SD Card running Linux
# Run this script on the SC7F0 board via serial UART console or SSH
# ==============================================================================
set -e

echo "================================================================="
echo "  SC7F0 N1 HDMI2 V11: Automatic eMMC Provisioning Tool"
echo "================================================================="

# 1. Identify SD Card (Source) and eMMC (Target)
EMMC_DEV=""
SD_DEV=""

for devpath in /sys/block/mmcblk*; do
    [ -d "$devpath" ] || continue
    bname=$(basename "$devpath")
    # Skip hardware boot partitions like mmcblk0boot0
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

if [ -z "$EMMC_DEV" ]; then
    echo "ERROR: On-board eMMC (type MMC) not found in /sys/block/!"
    exit 1
fi

echo "  Detected Internal eMMC : $EMMC_DEV"
if [ -n "$SD_DEV" ]; then
    echo "  Detected Boot SD Card  : $SD_DEV"
fi

# 2. Locate source boot files (BOOT.BIN, boot.scr, image.ub)
SRC_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/BOOT.BIN" ] && [ -f "$SCRIPT_DIR/image.ub" ]; then
    SRC_DIR="$SCRIPT_DIR"
elif [ -f "/run/media/*1/BOOT.BIN" ]; then
    SRC_DIR=$(dirname /run/media/*1/BOOT.BIN | head -n 1)
elif [ -n "$SD_DEV" ]; then
    TEMP_SD_MNT="/tmp/sd_boot_src"
    mkdir -p "$TEMP_SD_MNT"
    # Find FAT32 partition on SD Card
    if [ -b "${SD_DEV}p1" ]; then
        mount -o ro "${SD_DEV}p1" "$TEMP_SD_MNT" 2>/dev/null || true
    elif [ -b "${SD_DEV}1" ]; then
        mount -o ro "${SD_DEV}1" "$TEMP_SD_MNT" 2>/dev/null || true
    fi
    if [ -f "$TEMP_SD_MNT/BOOT.BIN" ]; then
        SRC_DIR="$TEMP_SD_MNT"
    fi
fi

if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/BOOT.BIN" ]; then
    echo "ERROR: Could not locate source BOOT.BIN and image.ub!"
    echo "Please ensure the SD card boot partition is mounted or run this script from the SD card directory."
    exit 1
fi

echo "  Source Artifacts Path  : $SRC_DIR"
echo "  Source BOOT.BIN Size   : $(ls -lh "$SRC_DIR/BOOT.BIN" | awk '{print $5}')"
echo "================================================================="

# 3. Safety Confirmation
printf "Proceed with writing to on-board eMMC (%s)? [y/N]: " "$EMMC_DEV"
read ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Operation cancelled."; exit 0 ;;
esac

# 4. Unmount any active partitions on eMMC
echo "[1/5] Unmounting any active partitions on $EMMC_DEV..."
umount ${EMMC_DEV}* 2>/dev/null || true

# 5. Partition eMMC (Partition 1: FAT32 ~1GB, Partition 2: EXT4 remainder)
echo "[2/5] Creating MBR partition table on $EMMC_DEV..."
dd if=/dev/zero of="$EMMC_DEV" bs=1M count=10 status=none

parted -s "$EMMC_DEV" mklabel msdos
parted -s "$EMMC_DEV" mkpart primary fat32 2048s 2099199s
parted -s "$EMMC_DEV" set 1 boot on
parted -s "$EMMC_DEV" mkpart primary ext4 2099200s 100%

# Allow kernel to reread partition table
partprobe "$EMMC_DEV" 2>/dev/null || sleep 2

EMMC_P1="${EMMC_DEV}p1"
EMMC_P2="${EMMC_DEV}p2"
[ -b "$EMMC_P1" ] || EMMC_P1="${EMMC_DEV}1"
[ -b "$EMMC_P2" ] || EMMC_P2="${EMMC_DEV}2"

# 6. Format Partitions
echo "[3/5] Formatting eMMC partitions..."
mkfs.vfat -F 32 -n "BOOT" "$EMMC_P1"
mkfs.ext4 -F -L "rootfs" "$EMMC_P2" >/dev/null 2>&1 || true

# 7. Copy Boot Artifacts to eMMC FAT32 partition
echo "[4/5] Copying boot artifacts to eMMC partition 1 ($EMMC_P1)..."
EMMC_MNT="/tmp/emmc_boot_target"
mkdir -p "$EMMC_MNT"
mount "$EMMC_P1" "$EMMC_MNT"

cp -v "$SRC_DIR/BOOT.BIN" "$EMMC_MNT/BOOT.BIN"
[ -f "$SRC_DIR/boot.scr" ] && cp -v "$SRC_DIR/boot.scr" "$EMMC_MNT/boot.scr"
[ -f "$SRC_DIR/image.ub" ] && cp -v "$SRC_DIR/image.ub" "$EMMC_MNT/image.ub"

sync

# 8. SHA256 Verification
SRC_HASH=$(sha256sum "$SRC_DIR/BOOT.BIN" | awk '{print $1}')
DST_HASH=$(sha256sum "$EMMC_MNT/BOOT.BIN" | awk '{print $1}')

umount "$EMMC_MNT"
rm -rf "$EMMC_MNT"

# Also write to eMMC hardware boot partition 0 if present (dual-safety)
EMMC_BNAME=$(basename "$EMMC_DEV")
if [ -b "/dev/${EMMC_BNAME}boot0" ]; then
    echo "  Writing backup image to /dev/${EMMC_BNAME}boot0..."
    echo 0 > "/sys/block/${EMMC_BNAME}boot0/force_ro" 2>/dev/null || true
    dd if="$SRC_DIR/BOOT.BIN" of="/dev/${EMMC_BNAME}boot0" bs=64k status=none || true
    sync
    echo 1 > "/sys/block/${EMMC_BNAME}boot0/force_ro" 2>/dev/null || true
fi

if [ "$SRC_HASH" != "$DST_HASH" ]; then
    echo "================================================================="
    echo " ERROR: SHA256 Checksum Mismatch! Flash failed."
    echo " Source: $SRC_HASH"
    echo " Dest:   $DST_HASH"
    echo "================================================================="
    exit 1
fi

echo "================================================================="
echo " SUCCESS: eMMC has been successfully programmed & verified!"
echo " SHA256 Checksum: $DST_HASH (Verified OK)"
echo "================================================================="
echo ""
echo " NEXT STEPS:"
echo " 1. Power OFF the SC7F0 board or host system."
echo " 2. Set the Boot Mode DIP Switch (SW1) to eMMC 1.8V mode:"
echo "      MODE[3:0] = 0 1 1 0  (Binary 4'b0110)"
echo "      Switch 1: OFF (0)"
echo "      Switch 2: ON  (1)"
echo "      Switch 3: ON  (1)"
echo "      Switch 4: OFF (0)"
echo " 3. Remove the SD Card (optional)."
echo " 4. Install SC7F0 into the host PCIe slot and power on."
echo " 5. Verify PCIe enumeration on host: lspci -d 12ab:e380 -vvv"
echo "================================================================="
