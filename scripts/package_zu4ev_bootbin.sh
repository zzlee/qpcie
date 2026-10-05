#!/bin/bash
# ==============================================================================
# Script to package Two-Stage Tandem PCIe BOOT.BIN for ZU4EV (SC7F0 N1 HDMI2 V11)
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SINGLE_BIT="$ROOT_DIR/build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top.bit"
TANDEM1_BIT="$ROOT_DIR/build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_tandem1.bit"
TANDEM2_BIT="$ROOT_DIR/build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_tandem2.bit"

IMG_DIR="$ROOT_DIR/petalinux/qpcie-zu4ev/images/linux"
BIF_FILE="$IMG_DIR/bootgen.bif"
OUT_BOOTBIN="$IMG_DIR/BOOT.BIN"

BOOTGEN="/opt/Xilinx/Vivado/2023.2/bin/bootgen"
if [ ! -x "$BOOTGEN" ]; then
    BOOTGEN=$(which bootgen 2>/dev/null || true)
fi

if [ -z "$BOOTGEN" ] || [ ! -x "$BOOTGEN" ]; then
    echo "ERROR: bootgen executable not found! Please check Vivado/Vitis installation."
    exit 1
fi

echo "================================================================="
echo " Packaging BOOT.BIN for ZU4EV SC7F0"
echo "================================================================="

# Verify core firmware components exist
for comp in zynqmp_fsbl.elf pmufw.elf bl31.elf u-boot.elf system.dtb; do
    if [ ! -f "$IMG_DIR/$comp" ]; then
        echo "ERROR: Missing required boot component: $IMG_DIR/$comp"
        exit 1
    fi
done

if [ -f "$SINGLE_BIT" ]; then
    echo "[1/3] Using Monolithic Single Bitstream: $SINGLE_BIT"
    cp -v "$SINGLE_BIT" "$IMG_DIR/zu4ev_pcie_card_top.bit"
    cat << EOF > "$BIF_FILE"
// Monolithic Bitstream BIF
the_ROM_image:
{
	[bootloader, destination_cpu=a53-0] images/linux/zynqmp_fsbl.elf
	[pmufw_image] images/linux/pmufw.elf
	[destination_device=pl] images/linux/zu4ev_pcie_card_top.bit
	[destination_cpu=a53-0, exception_level=el-3, trustzone] images/linux/bl31.elf
	[destination_cpu=a53-0, load=0x00100000] images/linux/system.dtb
	[destination_cpu=a53-0, exception_level=el-2] images/linux/u-boot.elf
}
EOF
elif [ -f "$TANDEM1_BIT" ] && [ -f "$TANDEM2_BIT" ]; then
    echo "[1/3] Using Two-Stage Tandem Bitstreams..."
    cp -v "$TANDEM1_BIT" "$IMG_DIR/zu4ev_pcie_card_top_tandem1.bit"
    cp -v "$TANDEM2_BIT" "$IMG_DIR/zu4ev_pcie_card_top_tandem2.bit"
    cat << 'EOF' > "$BIF_FILE"
// Two-Stage Tandem PCIe BIF
the_ROM_image:
{
	[bootloader, destination_cpu=a53-0] images/linux/zynqmp_fsbl.elf
	[pmufw_image] images/linux/pmufw.elf
	[destination_device=pl] images/linux/zu4ev_pcie_card_top_tandem1.bit
	[destination_device=pl] images/linux/zu4ev_pcie_card_top_tandem2.bit
	[destination_cpu=a53-0, exception_level=el-3, trustzone] images/linux/bl31.elf
	[destination_cpu=a53-0, load=0x00100000] images/linux/system.dtb
	[destination_cpu=a53-0, exception_level=el-2] images/linux/u-boot.elf
}
EOF
else
    echo "ERROR: Bitstream files not found!"
    echo "  Expected either: $SINGLE_BIT"
    echo "  Or: $TANDEM1_BIT and $TANDEM2_BIT"
    exit 1
fi

echo "[3/3] Running bootgen to build BOOT.BIN..."
cd "$ROOT_DIR/petalinux/qpcie-zu4ev"
"$BOOTGEN" -arch zynqmp -image "$BIF_FILE" -o "$OUT_BOOTBIN" -w on

echo "================================================================="
echo " SUCCESS: Two-Stage Tandem PCIe BOOT.BIN generated!"
echo " Output File : $OUT_BOOTBIN"
echo " File Size   : $(ls -lh "$OUT_BOOTBIN" | awk '{print $5}')"
echo " SHA256      : $(sha256sum "$OUT_BOOTBIN" | awk '{print $1}')"
echo "================================================================="
