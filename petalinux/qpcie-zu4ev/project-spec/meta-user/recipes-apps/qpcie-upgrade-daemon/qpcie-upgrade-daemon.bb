SUMMARY = "QPCIe SC7F0 In-System Firmware Upgrade Daemon"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

QPCIE_ROOT := "${THISDIR}/../../../../../.."
FILESEXTRAPATHS:prepend := "${THISDIR}/files:${QPCIE_ROOT}/test_app:${QPCIE_ROOT}/include:"
SRC_URI = " \
    file://qpcie_upgrade_daemon.c \
    file://sc7f0_health.h \
    file://qpcie_file_transaction.h \
    file://qpcie_commit_helpers.h \
    file://qpcie_archive_verify.h \
    file://qpcie_sha256.h \
    file://qpcie_backup_retention.h \
    file://qpcie-upgrade-daemon.service \
"
S = "${WORKDIR}"

inherit systemd
SYSTEMD_SERVICE:${PN} = "qpcie-upgrade-daemon.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_compile() {
    ${CC} ${CFLAGS} ${CPPFLAGS} -Wall -I${S} qpcie_upgrade_daemon.c -o qpcie_upgrade_daemon ${LDFLAGS}
}

do_install() {
    install -d ${D}${bindir} ${D}${systemd_system_unitdir}
    install -m 0755 qpcie_upgrade_daemon ${D}${bindir}/qpcie_upgrade_daemon
    install -m 0644 qpcie-upgrade-daemon.service ${D}${systemd_system_unitdir}/qpcie-upgrade-daemon.service
}
