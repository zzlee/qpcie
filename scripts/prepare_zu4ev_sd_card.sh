#!/bin/bash
# ==============================================================================
# Helper Script to format and flash SD Card for ZU4EV (SC7F0 N1 HDMI2 V11)
# ==============================================================================
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: sudo $0 <sd_device>"
    echo "Example: sudo $0 /dev/sdb"
    exit 1
fi

DEV="$1"

if [ ! -b "$DEV" ]; then
    echo "ERROR: Device '$DEV' is not a valid block device!"
    exit 1
fi

if [[ "$DEV" =~ (nvme0n1|sda)$ ]]; then
    echo "CRITICAL: Refusing to format primary host drive ($DEV)!"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTBIN="$SCRIPT_DIR/BOOT.BIN"
BOOTSCR="$SCRIPT_DIR/boot.scr"
IMAGEUB="$SCRIPT_DIR/image.ub"

for f in "$BOOTBIN" "$BOOTSCR" "$IMAGEUB"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing required file $f"
        exit 1
    fi
done

echo "================================================================="
echo "  WARNING: ALL DATA ON $DEV WILL BE COMPLETELY DESTROYED!"
echo "================================================================="
read -p "Are you sure you want to format and burn to $DEV? (type 'yes' to proceed): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted by user."
    exit 0
fi

echo "[1/4] Unmounting existing partitions on $DEV..."
sudo umount ${DEV}* 2>/dev/null || true

echo "[2/4] Partitioning $DEV (Partition 1: FAT32 Boot)..."
sudo parted -s "$DEV" mklabel msdos
sudo parted -s "$DEV" mkpart primary fat32 2048s 100%
sudo parted -s "$DEV" set 1 boot on

# Determine partition name (e.g., /dev/sdb1 or /dev/mmcblk0p1)
if [[ "$DEV" =~ [0-9]$ ]]; then
    PART1="${DEV}p1"
else
    PART1="${DEV}1"
fi

# Wait for kernel to register partition
sleep 2

echo "[3/4] Formatting $PART1 as FAT32..."
sudo mkfs.vfat -F 32 -n "BOOT" "$PART1"

echo "[4/4] Copying Boot Artifacts to $PART1..."
MOUNT_DIR=$(mktemp -d)
sudo mount "$PART1" "$MOUNT_DIR"

sudo cp -v "$BOOTBIN" "$MOUNT_DIR/BOOT.BIN"
sudo cp -v "$BOOTSCR" "$MOUNT_DIR/boot.scr"
sudo cp -v "$IMAGEUB" "$MOUNT_DIR/image.ub"

sync
sudo umount "$MOUNT_DIR"
rm -rf "$MOUNT_DIR"

echo "================================================================="
echo " SUCCESS: SD Card created successfully on $DEV!"
echo " Insert SD Card into SC7F0 and configure Boot Mode switch to SD."
echo "================================================================="
