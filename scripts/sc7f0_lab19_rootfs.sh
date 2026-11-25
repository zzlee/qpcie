#!/usr/bin/env bash
# Compile PS software only. Input is the exact lab-dispositioned 26112419 XSA.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); XSA=$(realpath "${1:?supply lab19 XSA}"); OUT=$(realpath -m "${2:?supply fresh output}"); VERSION=${3:?new PS revision}
[[ $VERSION =~ ^[0-9]{8}$ && $VERSION != 26112419 && ! -e $OUT ]]
echo "7509397654d5ba8a00ea8b1c9ca7ff9a845afab391fca0f72cb467b0b13f23b3  $XSA" | sha256sum -c -
mkdir -p "$OUT/src/petalinux" "$OUT/logs";cp -a "$ROOT"/{test_app,include} "$OUT/src/";P=$OUT/src/petalinux/qpcie-zu4ev;mkdir "$P";cp -a "$ROOT/petalinux/qpcie-zu4ev/"{.petalinux,project-spec} "$P/"
printf '%s\n' "$VERSION" >"$OUT/VERSION";printf '26112419\n' >"$OUT/PL_VERSION";printf '%s\n' "$VERSION" >"$P/project-spec/meta-user/recipes-apps/sc7f0-vcud/files/sc7f0-ps-release"
C=$HOME/qpcie/petalinux/qpcie-zu4ev/build
(cd "$OUT/src";find . -type f ! -name '*.xsa' -print0|sort -z|xargs -0 sha256sum) >"$OUT/ps-input.sha256"
docker run --rm -i --user "$(id -u):$(id -g)" -e HOME -e USER -e TERM=xterm -e XSA="$XSA" -e XILINXD_LICENSE_FILE="${XILINXD_LICENSE_FILE:-2101@192.168.200.112}" -v "$HOME:$HOME" -v /opt:/opt -v /mnt/data-root:/mnt/data-root -v "sc7f0-ps-vcu-downloads:$C/downloads" -v "sc7f0-ps-vcu-sstate:$C/sstate-cache" -v "$C/sstate-cache:/sc7f0-sstate-mirror:ro" -w "$P" petalinux:latest bash -s >"$OUT/logs/ps-build.log" 2>&1 <<'CONTAINER'
set -eo pipefail
source /opt/Xilinx/petalinux/2023.2/settings.sh
petalinux-config --get-hw-description="$XSA" --silentconfig
cmp "$XSA" project-spec/hw-description/system.xsa
# Generated machine configs can retain the absolute path of a different worktree.
# Resolve the HDF used by bitbake, not merely the file copied by petalinux-config.
machine=build/conf/machine/zynqmp-generic-xczu4ev.conf
hdf=$(sed -n 's/^HDF_PATH = "\(.*\)"/\1/p' "$machine")
hdf=${hdf//'${TOPDIR}'/$PWD/build};cmp "$XSA" "$hdf"
petalinux-build
cmp "$XSA" components/plnx_workspace/device-tree/device-tree/hardware_description.xsa
CONTAINER
(cd "$P/images/linux";sha256sum image.ub rootfs.cpio.gz system.dtb boot.scr) >"$OUT/ps-images.sha256"
