SUMMARY = "SC7F0 RGB-compositor overlay/plane bring-up tool"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

# Same single-canonical-source layout as sc7f0-ps-capture and qpcie-debugd: the
# file lives in test_app/ and the card and the host build it from there.
QPCIE_ROOT := "${THISDIR}/../../../../../.."
FILESEXTRAPATHS:prepend := "${QPCIE_ROOT}/test_app:"
SRC_URI = "file://sc7f0_rgb_overlay.c"
S = "${WORKDIR}"

inherit systemd

DEPENDS += "virtual/kernel"

do_compile() {
    ${CC} ${CFLAGS} ${CPPFLAGS} -std=c11 -Wall -Wextra sc7f0_rgb_overlay.c -o sc7f0_rgb_overlay ${LDFLAGS}
}
do_install() {
    install -d ${D}${bindir}
    install -m 0755 sc7f0_rgb_overlay ${D}${bindir}/sc7f0_rgb_overlay
}

# No service and no autostart, on purpose.  The overlay controller, Reader-B and
# the blend enable are only meaningful while the SC7F0-RGB-COMPOSITOR-2PPC
# fabric (PL base 0x26111405) is loaded, and every write this tool makes is an
# explicit subcommand so a session log records what the hardware was asked to
# do.  A unit that ran it at boot would arm planes nobody verified.
#
# It needs /dev/mem, which this kernel has (CONFIG_DEVMEM=y, CONFIG_STRICT_DEVMEM
# is not set for this BSP); the apertures it touches are the ones the device tree
# declares in sc7f0-rgb-compositor.dtsi:
#   0xB0080000 plane-a (xlnx,axi-frmbuf-rd, SPI 97)
#   0xB0090000 plane-b (yuan,sc7f0-rgb-plane-b, SPI 98, reset-gpios = <&gpio 81>)
#   0xB00A0000 overlay-ctrl (yuan,sc7f0-rgb-overlay-ctrl, SPI 99)
