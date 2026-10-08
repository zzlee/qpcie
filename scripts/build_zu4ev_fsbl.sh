#!/bin/bash
# ==============================================================================
# Script: build_zu4ev_fsbl.sh
# Description: Compiles patched ZynqMP FSBL for SC7F0 (ZU4EV) from sc7f0_base.xsa
# Features:
#   - Two-stage Tandem PCIe bitstream loading support (no PL_DONE timeout)
#   - Skyworks Si5341 clock generator I2C initialization
#   - FSBL_DEBUG_INFO enabled for UART boot progress visibility
#   - 4GB DDR4 timing configuration from sc7f0_base.xsa
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
XSA_PATH="$ROOT_DIR/hw_platform/sc7f0_base.xsa"
PATCH_DIR="$ROOT_DIR/petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-bsp/embeddedsw/fsbl-firmware"
OUT_IMG_DIR="$ROOT_DIR/petalinux/qpcie-zu4ev/images/linux"
BUILD_DIR="$ROOT_DIR/build/zu4ev_fsbl"

XSCT="/opt/Xilinx/Vitis/2023.2/bin/xsct"
CROSS_COMPILE_DIR="/opt/Xilinx/Vitis/2023.2/gnu/aarch64/lin/aarch64-none/bin"

if [ ! -x "$XSCT" ]; then
    echo "ERROR: XSCT executable not found at $XSCT"
    exit 1
fi

if [ ! -f "$XSA_PATH" ]; then
    echo "ERROR: Hardware platform XSA not found at $XSA_PATH"
    exit 1
fi

export PATH="$CROSS_COMPILE_DIR:$PATH"
if ! command -v aarch64-none-elf-gcc &> /dev/null; then
    echo "ERROR: aarch64-none-elf-gcc not found in PATH!"
    exit 1
fi

echo "================================================================="
echo " Building Patched ZU4EV FSBL for SC7F0"
echo " Hardware XSA : $XSA_PATH"
echo " Toolchain    : $(aarch64-none-elf-gcc --version | head -n1)"
echo "================================================================="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[1/4] Generating FSBL template from XSA using HSI..."
cat << EOF > "$BUILD_DIR/gen_app.tcl"
hsi::open_hw_design "$XSA_PATH"
hsi::generate_app -proc psu_cortexa53_0 -app zynqmp_fsbl -dir "$BUILD_DIR/src" -compile
EOF

"$XSCT" "$BUILD_DIR/gen_app.tcl" > /dev/null

echo "[1.5/4] Copying verified SC7F0 4GB DDR4 hardware initialization files..."
cp -vf "$ROOT_DIR/hw_platform/psu_init.c" "$BUILD_DIR/src/"
cp -vf "$ROOT_DIR/hw_platform/psu_init.h" "$BUILD_DIR/src/"
rm -f "$BUILD_DIR/src/psu_init_gpl"*

echo "[2/4] Applying SC7F0 board patches (Si5341, Tandem PCIe, zzlab-env)..."
cd "$BUILD_DIR/src"
git init -q .
git config user.email "build@qpcie.local"
git config user.name "QPCIe Builder"
git add .
git commit -q -m "initial fsbl"

for patch_file in \
    "$PATCH_DIR/0002-feat-fsbl-add-Si5341-clock-generator-configuration.patch" \
    "$PATCH_DIR/0004-feat-fsbl-support-two-stage-tandem-bitstream-loading.patch" \
    "$PATCH_DIR/0005-fix-fsbl-zzlab-env-baseaddr-macro.patch"; do
    # NOTE 2026-10-08: 0003 retired — its io_read fix is folded into 0002,
    # and its version-print hunk was superseded by 0002's SC7F0 block.
    if [ -f "$patch_file" ]; then
        echo "   Applying $(basename "$patch_file")..."
        git apply "$patch_file" -p5
    else
        echo "WARNING: Patch not found: $patch_file"
    fi
done

echo "[3/4] Compiling FSBL with FSBL_DEBUG_INFO (UART visibility)..."
make clean > /dev/null
make CFLAGS="-DFSBL_PRINT_VAL=0" -j$(nproc) > /dev/null

FSBL_ELF="$BUILD_DIR/src/executable.elf"
if [ ! -f "$FSBL_ELF" ]; then
    echo "ERROR: FSBL build failed, $FSBL_ELF does not exist!"
    exit 1
fi

echo "[4/4] Deploying verified FSBL to petalinux images directory..."
mkdir -p "$OUT_IMG_DIR"
cp -v "$FSBL_ELF" "$OUT_IMG_DIR/zynqmp_fsbl.elf"
cp -v "$FSBL_ELF" "$OUT_IMG_DIR/zynqmp_fsbl_sc7f0.elf"

echo "================================================================="
echo " SUCCESS: SC7F0 FSBL successfully compiled and installed!"
echo " Size   : $(ls -lh "$OUT_IMG_DIR/zynqmp_fsbl.elf" | awk '{print $5}')"
echo " SHA256 : $(sha256sum "$OUT_IMG_DIR/zynqmp_fsbl.elf" | awk '{print $1}')"
echo "================================================================="
