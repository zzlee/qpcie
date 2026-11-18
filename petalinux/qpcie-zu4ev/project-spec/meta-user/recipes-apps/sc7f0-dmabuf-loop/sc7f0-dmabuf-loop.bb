SUMMARY = "SC7F0 card-side zero-copy capture-to-display loop-through bring-up tool"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

# Same single-canonical-source layout as sc7f0-rgb-overlay and qpcie-debugd: the C
# file lives in test_app/ and both the card recipe and the host build it from there.
QPCIE_ROOT := "${THISDIR}/../../../../../.."
FILESEXTRAPATHS:prepend := "${QPCIE_ROOT}/test_app:"
SRC_URI = "file://sc7f0_dmabuf_loop.c"
S = "${WORKDIR}"

DEPENDS += "virtual/kernel libdrm"

do_compile() {
    ${CC} ${CFLAGS} ${CPPFLAGS} -std=c11 -Wall -Wextra -Wshadow \
        -I${STAGING_INCDIR} -I${STAGING_INCDIR}/libdrm \
        sc7f0_dmabuf_loop.c -o sc7f0_dmabuf_loop ${LDFLAGS} -ldrm
}
do_install() {
    install -d ${D}${bindir}
    install -m 0755 sc7f0_dmabuf_loop ${D}${bindir}/sc7f0_dmabuf_loop
}

# No service, no autostart, exactly like sc7f0-rgb-overlay: this tool imports a
# DMA-BUF and page-flips a CRTC, which is a visible display change, and it is only
# meaningful while the SC7F0-RGB-COMPOSITOR fabric is loaded.  It is run by hand
# and by the board-acceptance session, so every invocation is a deliberate one that
# a session log records.
#
# Compile status, stated rather than discovered at build time: the include-path and
# struct-member assumptions were checked on the host against the same libdrm this
# BSP ships (2.4.113, unpacked to build/a1b1-26111602-watch/libdrm-headers) with
#   gcc -std=c11 -Wall -Wextra -Wshadow  ->  no diagnostics
# That is a userspace-header check, not a cross-compile: the first aarch64 build of
# this object is still this recipe's do_compile.  The first version of the file did
# not compile at all, and the four errors were all header-shape guesses:
#   v4l2_plane_pix_format has bytesperline, not stride
#   v4l2_exportbuffer has no .memory field (sc7f0_ps_capture.c is the reference)
#   drmModePlane names crtc_id/fb_id, not crtc/fb
#   drmModeEncoder names possible_crtcs, not the kernel's crtc_mask
# The include flags are ${STAGING_INCDIR} and ${STAGING_INCDIR}/libdrm because those
# are the two layouts upstream libdrm installs into; the earlier
# ${STAGING_INCDIR}/libdrm/include path existed in neither.
