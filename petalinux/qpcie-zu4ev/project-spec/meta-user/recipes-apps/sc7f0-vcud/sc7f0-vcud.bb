SUMMARY = "SC7F0 VCU H.264 encoder -> Packet DMA bridge daemon"
DESCRIPTION = "Card-side daemon that takes the VIPP NV12 capture, encodes it on the \
VCU hard macro through OpenMAX IL and streams the access units to the host over the \
PL Packet C2H DMA. This is product runtime, not a debug tool: without it /dev/video1 \
on the host produces nothing. It was missing from the rootfs entirely - the copy that \
made today's capture work ran as a loose file on the eMMC BOOT partition, so a release \
without this recipe could not reproduce it after a reflash. Verified against the \
shipped image (build/sc7f0-ps-watchdog-20261027-r2-release/images/image.ub, unpacked \
by scripts/package_sc7f0_rootfs.py): usr/lib/libOMX.allegro.*.so, \
usr/lib/liballegro_*.so, usr/bin/omx_encoder and lib/firmware/al5d*.fw / al5e*.fw are \
already present, so the OMX/VCU runtime itself is not the gap; sc7f0_vcud and its \
unit file are, and the RDEPENDS below only make that dependency explicit instead of \
inheriting it from whatever else happened to pull the encoder in."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

# One canonical source, following the existing qpcie-debugd recipe layout.
QPCIE_ROOT := "${THISDIR}/../../../../../.."
FILESEXTRAPATHS:prepend := "${THISDIR}/files:${QPCIE_ROOT}/test_app:"
SRC_URI = "file://sc7f0_vcud.cpp file://sc7f0-vcud.service file://sc7f0-capture-init.sh"
S = "${WORKDIR}"

# The capture-initialisation helper is referenced by absolute path from the unit's
# ExecStartPre, so the two spellings are pinned to one variable.
SC7F0_CAPTURE_INIT_PATH = "${libdir}/sc7f0/sc7f0-capture-init.sh"

# libomxil-xlnx   : libOMX.allegro.core / libOMX.allegro.video_encoder + OMX headers
# libvcu-xlnx     : liballegro_encode/.decode (the Allegro core the OMX IL wrapper calls)
# vcu-firmware    : al5e*.fw / al5d*.fw, loaded by the encoder core on first use
# v4l-utils       : /usr/bin/v4l2-ctl, used by the ExecStartPre capture initialiser
# media-ctl       : /usr/bin/media-ctl, used to resolve subdev nodes by entity name
# Without the last two the unit's ExecStartPre would fail on the card even though the
# image "boots", which is precisely the class of gap this recipe exists to close.
DEPENDS  = "libomxil-xlnx libvcu-xlnx"
RDEPENDS:${PN} += "libomxil-xlnx libvcu-xlnx vcu-firmware v4l-utils media-ctl"

inherit systemd
SYSTEMD_SERVICE:${PN} = "sc7f0-vcud.service"
SYSTEMD_AUTO_ENABLE = "enable"

EXTRA_OEMAKE = ""

do_compile() {
    ${CXX} ${CXXFLAGS} ${CPPFLAGS} -std=c++17 -Wall -Wextra \
        -I${STAGING_INCDIR}/vcu-omx-il \
        sc7f0_vcud.cpp -o sc7f0_vcud \
        -L${STAGING_LIBDIR} -lOMX.allegro.core -lOMX.allegro.video_encoder -lpthread ${LDFLAGS}
    # The helper runs as PID 1's child before the daemon; a syntax error there is a
    # silent boot-time failure, so it is a build failure instead.
    sh -n sc7f0-capture-init.sh
    grep -q '^ExecStartPre=${SC7F0_CAPTURE_INIT_PATH}$' sc7f0-vcud.service \
        || { echo "sc7f0-vcud.service does not chain ${SC7F0_CAPTURE_INIT_PATH}" >&2; exit 1; }
}

do_install() {
    install -d ${D}${bindir} ${D}${systemd_system_unitdir} ${D}${libdir}/sc7f0
    install -m 0755 sc7f0_vcud ${D}${bindir}/sc7f0_vcud
    install -m 0644 sc7f0-vcud.service ${D}${systemd_system_unitdir}/
    install -m 0755 sc7f0-capture-init.sh ${D}${SC7F0_CAPTURE_INIT_PATH}
}

FILES:${PN} += "${systemd_system_unitdir}/sc7f0-vcud.service ${SC7F0_CAPTURE_INIT_PATH}"
