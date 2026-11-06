SUMMARY = "SC7F0 standard V4L2 capture and DMA-BUF export verifier"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

# One canonical source, following the existing qpcie-debugd recipe layout.
QPCIE_ROOT := "${THISDIR}/../../../../../.."
FILESEXTRAPATHS:prepend := "${QPCIE_ROOT}/test_app:"
SRC_URI = "file://sc7f0_ps_capture.c"
S = "${WORKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${CPPFLAGS} -std=c11 -Wall -Wextra sc7f0_ps_capture.c -o sc7f0_ps_capture ${LDFLAGS}
}
do_install() {
    install -d ${D}${bindir}
    install -m 0755 sc7f0_ps_capture ${D}${bindir}/sc7f0_ps_capture
}
# No service/autostart: capture is explicit and the media graph must be ready.
