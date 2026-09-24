#!/bin/bash
# ==============================================================================
# Helper Script to format and prepare SD Card for ZU4EV (SC7F0 N1 HDMI2 V11)
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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")"

# Search for release artifacts
SRC_DIR=""
for cand in "$SCRIPT_DIR" "$REPO_ROOT/release/zu4ev_sd_boot" "$SCRIPT_DIR/release/zu4ev_sd_boot"; do
    if [ -f "$cand/BOOT.BIN" ] && [ -f "$cand/image.ub" ]; then
        SRC_DIR="$cand"
        break
    fi
done

if [ -z "$SRC_DIR" ]; then
    echo "ERROR: Could not locate BOOT.BIN and image.ub in $SCRIPT_DIR or $REPO_ROOT/release/zu4ev_sd_boot"
    exit 1
fi

BOOTBIN="$SRC_DIR/BOOT.BIN"
BOOTSCR="$SRC_DIR/boot.scr"
IMAGEUB="$SRC_DIR/image.ub"
FLASHEMMC="$SRC_DIR/flash_emmc.sh"

echo "================================================================="
echo "  SC7F0 N1 HDMI2 V11: SD Card Image Flashing Tool"
echo "  Source Directory: $SRC_DIR"
echo "  Target Device   : $DEV"
echo "================================================================="
read -p "WARNING: ALL DATA ON $DEV WILL BE WIPED! Proceed? (type 'yes'): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted by user."
    exit 0
fi

echo "[1/4] Unmounting any active partitions on $DEV..."
sudo umount ${DEV}* 2>/dev/null || true

echo "[2/4] Creating MBR partition on $DEV..."
sudo dd if=/dev/zero of="$DEV" bs=1M count=10 status=none conv=fsync

sudo parted -s "$DEV" mklabel msdos
sudo parted -s "$DEV" mkpart primary fat32 2048s 100%
sudo parted -s "$DEV" set 1 boot on

sync
sleep 2

# Determine partition name (e.g., /dev/sdb1 or /dev/mmcblk0p1)
if [[ "$DEV" =~ [0-9]$ ]]; then
    PART1="${DEV}p1"
else
    PART1="${DEV}1"
fi

echo "[3/4] Formatting $PART1 as FAT32 (BOOT)..."
sudo mkfs.vfat -F 32 -n "BOOT" "$PART1"

echo "[4/4] Copying Boot Artifacts to SD Card..."
MOUNT_DIR=$(mktemp -d -p /tmp sd_mnt_XXXXXX)
sudo mount "$PART1" "$MOUNT_DIR"

echo "  Copying BOOT.BIN ($(ls -lh "$BOOTBIN" | awk '{print $5}'))"
sudo cp -v "$BOOTBIN" "$MOUNT_DIR/BOOT.BIN"

if [ -f "$BOOTSCR" ]; then
    echo "  Copying boot.scr ($(ls -lh "$BOOTSCR" | awk '{print $5}'))"
    sudo cp -v "$BOOTSCR" "$MOUNT_DIR/boot.scr"
fi

echo "  Copying image.ub ($(ls -lh "$IMAGEUB" | awk '{print $5}'))"
sudo cp -v "$IMAGEUB" "$MOUNT_DIR/image.ub"

if [ -f "$FLASHEMMC" ]; then
    sudo cp -v "$FLASHEMMC" "$MOUNT_DIR/flash_emmc.sh"
    sudo chmod +x "$MOUNT_DIR/flash_emmc.sh"
fi

# Clean up any leftover status files from previous runs
sudo rm -f "$MOUNT_DIR/EMMC_FLASH_SUCCESS.txt" \
           "$MOUNT_DIR/EMMC_FLASH_FAILED.txt" \
           "$MOUNT_DIR/EMMC_FLASH_IN_PROGRESS.txt" \
           "$MOUNT_DIR/emmc_flash.log"

sync
sudo umount "$MOUNT_DIR"
rm -rf "$MOUNT_DIR"

echo "================================================================="
echo " SUCCESS: SD Card created successfully on $PART1!"
echo ""
echo " ZERO-TOUCH AUTOMATIC eMMC FLASH PROCEDURE:"
echo " 1. Insert this SD Card into the SC7F0 board."
echo " 2. Set SW1 Boot Mode to SD Card Mode (MODE[3:0] = 1110):"
echo "      Switch 1 (MODE0) : OFF (0)"
echo "      Switch 2 (MODE1) : ON  (1)"
echo "      Switch 3 (MODE2) : ON  (1)"
echo "      Switch 4 (MODE3) : ON  (1)"
echo " 3. Power ON the board."
echo " 4. Wait ~30-45 seconds (Linux boots and automatically flashes eMMC)."
echo " 5. Power OFF the board and remove the SD card."
echo " 6. Check the SD card on your PC to verify 'EMMC_FLASH_SUCCESS.txt'!"
echo " 7. Set SW1 Boot Mode to eMMC Mode (MODE[3:0] = 0110):"
echo "      Switch 1 (MODE0) : OFF (0)"
echo "      Switch 2 (MODE1) : ON  (1)"
echo "      Switch 3 (MODE2) : ON  (1)"
echo "      Switch 4 (MODE3) : OFF (0)"
echo " 8. Power ON the board to run permanently from eMMC!"
echo "================================================================="
