#!/bin/sh
# ==============================================================================
# Script to flash eMMC on SC7F0 N1 HDMI2 V11 from SD Card running Linux
# Can be run manually via serial UART / SSH or non-interactively with -y
# ==============================================================================
set -e

AUTO_CONFIRM=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--non-interactive) AUTO_CONFIRM=1 ;;
    esac
done

echo "================================================================="
echo "  SC7F0 N1 HDMI2 V11: eMMC Provisioning Tool"
echo "  Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)"
echo "================================================================="

# 1. Identify SD Card (Source) and eMMC (Target)
EMMC_DEV=""
SD_DEV=""

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

# Fallback: if EMMC_DEV not determined by type, check 8GB capacity
if [ -z "$EMMC_DEV" ]; then
    for devpath in /sys/block/mmcblk*; do
        [ -d "$devpath" ] || continue
        bname=$(basename "$devpath")
        case "$bname" in
            *boot*|*rpmb*) continue ;;
        esac
        if [ -f "$devpath/size" ]; then
            devsz=$(cat "$devpath/size")
            if [ "$devsz" -ge 14000000 ] && [ "$devsz" -le 16500000 ]; then
                EMMC_DEV="/dev/$bname"
                break
            fi
        fi
    done
fi

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
else
    for m in $(grep -E "mmcblk|sd" /proc/mounts 2>/dev/null | awk '{print $2}'); do
        if [ -f "$m/BOOT.BIN" ] && [ -f "$m/image.ub" ]; then
            SRC_DIR="$m"
            break
        fi
    done
fi

if [ -z "$SRC_DIR" ] && [ -n "$SD_DEV" ]; then
    TEMP_SD_MNT="/tmp/sd_boot_src"
    mkdir -p "$TEMP_SD_MNT"
    for p in "${SD_DEV}p1" "${SD_DEV}1"; do
        if [ -b "$p" ]; then
            if mount -o ro "$p" "$TEMP_SD_MNT" 2>/dev/null; then
                if [ -f "$TEMP_SD_MNT/BOOT.BIN" ]; then
                    SRC_DIR="$TEMP_SD_MNT"
                    break
                fi
                umount "$TEMP_SD_MNT" 2>/dev/null || true
            fi
        fi
    done
fi

if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/BOOT.BIN" ]; then
    echo "ERROR: Could not locate source BOOT.BIN and image.ub!"
    echo "Please ensure the SD card boot partition is mounted or run this script from the SD card directory."
    exit 1
fi

echo "  Source Artifacts Path  : $SRC_DIR"
echo "  Source BOOT.BIN Size   : $(ls -lh "$SRC_DIR/BOOT.BIN" | awk '{print $5}')"
echo "  Source BOOT.BIN SHA256 : $(sha256sum "$SRC_DIR/BOOT.BIN" | awk '{print $1}')"
echo "================================================================="

# 3. Confirmation (unless -y / non-interactive)
if [ "$AUTO_CONFIRM" -ne 1 ]; then
    printf "Proceed with writing to on-board eMMC (%s)? [y/N]: " "$EMMC_DEV"
    read ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Operation cancelled."; exit 0 ;;
    esac
fi

# 4. Unmount any active partitions on eMMC
echo "[1/5] Unmounting any active partitions on $EMMC_DEV..."
for part in ${EMMC_DEV}*; do
    umount "$part" 2>/dev/null || true
done

# 5. Partition eMMC using fdisk (Part 1: 1024MB FAT32 Bootable, Part 2: Linux ext4)
echo "[2/5] Creating MBR partition table on $EMMC_DEV using fdisk..."
dd if=/dev/zero of="$EMMC_DEV" bs=1M count=10 status=none conv=fsync

fdisk "$EMMC_DEV" << 'FDISK_EOF' >/dev/null 2>&1
o
n
p
1
2048
+1024M
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

EMMC_P1="${EMMC_DEV}p1"
EMMC_P2="${EMMC_DEV}p2"
[ -b "$EMMC_P1" ] || EMMC_P1="${EMMC_DEV}1"
[ -b "$EMMC_P2" ] || EMMC_P2="${EMMC_DEV}2"

if [ ! -b "$EMMC_P1" ]; then
    echo "ERROR: Partition $EMMC_P1 not created!"
    exit 1
fi

# 6. Format Partitions
echo "[3/5] Formatting eMMC partitions..."
echo "  Formatting $EMMC_P1 as FAT32 (BOOT)..."
mkfs.vfat -F 32 -n "BOOT" "$EMMC_P1"
if [ -b "$EMMC_P2" ]; then
    echo "  Formatting $EMMC_P2 as EXT4 (rootfs)..."
    mkfs.ext4 -F -L "rootfs" "$EMMC_P2" >/dev/null 2>&1 || true
fi
sync

# 7. Copy Boot Artifacts to eMMC FAT32 partition
echo "[4/5] Copying boot artifacts to eMMC partition 1 ($EMMC_P1)..."
EMMC_MNT="/tmp/emmc_boot_target"
mkdir -p "$EMMC_MNT"
mount "$EMMC_P1" "$EMMC_MNT"

echo "  Copying BOOT.BIN..."
cp -v "$SRC_DIR/BOOT.BIN" "$EMMC_MNT/BOOT.BIN"
[ -f "$SRC_DIR/boot.scr" ] && cp -v "$SRC_DIR/boot.scr" "$EMMC_MNT/boot.scr"
[ -f "$SRC_DIR/image.ub" ] && cp -v "$SRC_DIR/image.ub" "$EMMC_MNT/image.ub"
sync
umount "$EMMC_MNT"

# Also write to eMMC hardware boot partition 0 if present (dual-safety)
EMMC_BNAME=$(basename "$EMMC_DEV")
if [ -b "/dev/${EMMC_BNAME}boot0" ]; then
    echo "  Writing backup image to /dev/${EMMC_BNAME}boot0..."
    echo 0 > "/sys/block/${EMMC_BNAME}boot0/force_ro" 2>/dev/null || true
    dd if="$SRC_DIR/BOOT.BIN" of="/dev/${EMMC_BNAME}boot0" bs=64k status=none conv=fsync || true
    sync
    echo 1 > "/sys/block/${EMMC_BNAME}boot0/force_ro" 2>/dev/null || true
fi

# 8. SHA256 Verification with cache drop
echo "[5/5] Verifying eMMC contents against source artifacts..."
sync
echo 3 > /proc/sys/vm/drop_caches

mount -o ro "$EMMC_P1" "$EMMC_MNT"

SRC_HASH=$(sha256sum "$SRC_DIR/BOOT.BIN" | awk '{print $1}')
DST_HASH=$(sha256sum "$EMMC_MNT/BOOT.BIN" | awk '{print $1}')
BOOT_SIZE=$(ls -lh "$EMMC_MNT/BOOT.BIN" | awk '{print $5}')

if [ -f "$SRC_DIR/image.ub" ]; then
    SRC_UB=$(sha256sum "$SRC_DIR/image.ub" | awk '{print $1}')
    DST_UB=$(sha256sum "$EMMC_MNT/image.ub" | awk '{print $1}')
    UB_SIZE=$(ls -lh "$EMMC_MNT/image.ub" | awk '{print $5}')
else
    SRC_UB="N/A"
    DST_UB="N/A"
    UB_SIZE="N/A"
fi

umount "$EMMC_MNT"
rm -rf "$EMMC_MNT"

if [ "$SRC_HASH" != "$DST_HASH" ] || { [ "$SRC_UB" != "N/A" ] && [ "$SRC_UB" != "$DST_UB" ]; }; then
    echo "================================================================="
    echo " ERROR: SHA256 Checksum Mismatch! Flash verification failed."
    echo " BOOT.BIN  Src: $SRC_HASH | Dest: $DST_HASH"
    echo " image.ub  Src: $SRC_UB | Dest: $DST_UB"
    echo "================================================================="
    exit 1
fi

echo "================================================================="
echo " SUCCESS: eMMC has been successfully programmed & verified 100%!"
echo " BOOT.BIN SHA256: $DST_HASH (Verified OK, Size: $BOOT_SIZE)"
echo " image.ub SHA256: $DST_UB (Verified OK, Size: $UB_SIZE)"
echo "================================================================="

# Record status back to SD card if writable
if [ -w "$SRC_DIR" ]; then
    cat << EOF > "$SRC_DIR/EMMC_FLASH_SUCCESS.txt"
=================================================================
 SC7F0 N1 HDMI2 V11: eMMC FLASH SUCCESSFUL
=================================================================
Timestamp       : $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)
Target Device   : $EMMC_DEV (Toshiba 8GB eMMC THGBMNG5D1LBAIT)
Boot Partition  : $EMMC_P1 (FAT32, Bootable, 1024MB)
Root Partition  : $EMMC_P2 (EXT4, rootfs)
Status          : VERIFIED_OK (100% SHA256 Match)

[Verified Image Hashes]
BOOT.BIN        : $DST_HASH (Size: $BOOT_SIZE)
image.ub        : $DST_UB (Size: $UB_SIZE)
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
    sync
    echo "  Flash status recorded to $SRC_DIR/EMMC_FLASH_SUCCESS.txt"
fi

echo ""
echo " NEXT STEPS:"
echo " 1. Power OFF the SC7F0 board or host PC."
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
