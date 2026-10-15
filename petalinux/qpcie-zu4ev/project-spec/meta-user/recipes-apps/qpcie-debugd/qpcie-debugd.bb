SUMMARY = "SC7F0 opt-in PCIe debug execution daemon"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

# Keep one copy of the protocol and daemon sources in the repository.
QPCIE_ROOT := "${THISDIR}/../../../../../.."
FILESEXTRAPATHS:prepend := "${THISDIR}/files:${QPCIE_ROOT}/test_app:${QPCIE_ROOT}/include:"
SRC_URI = "file://qpcie_debugd.c file://qpcie_debug_io.h file://qpcie_debug.h file://qpcie-debugd.service"
S = "${WORKDIR}"
inherit systemd
SYSTEMD_SERVICE:${PN} = "qpcie-debugd.service"
SYSTEMD_AUTO_ENABLE = "enable"
RDEPENDS:${PN} += "bash"

do_compile() {
    ${CC} ${CFLAGS} ${CPPFLAGS} -I${S} qpcie_debugd.c -o qpcie_debugd ${LDFLAGS}
}
do_install() {
    install -d ${D}${bindir} ${D}${systemd_system_unitdir}
    install -m 0755 qpcie_debugd ${D}${bindir}/qpcie_debugd
    install -m 0644 qpcie-debugd.service ${D}${systemd_system_unitdir}/
    # No /etc/default/qpcie-debugd shipped: execution is disabled by default.
}
