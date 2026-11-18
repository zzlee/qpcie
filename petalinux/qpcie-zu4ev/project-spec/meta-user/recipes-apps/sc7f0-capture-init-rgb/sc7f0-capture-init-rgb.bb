SUMMARY = "SC7F0 RGB-compositor boot-time capture graph initialisation"
DESCRIPTION = "Installs the card-side script that configures the RGB-compositor persona's \
capture pipeline at boot - vpss-csc both pads to RBG888_1X24/3840x2160 field:none, then \
the VIPP capture node to RX24 (32-bit XBGR 8-8-8-8) - and the systemd unit that runs it \
once. This persona has no VCU, so sc7f0-vcud (which owns the equivalent initialiser as its \
ExecStartPre on the VCU persona) is removed from the image by \
recipes-core/images/petalinux-image-minimal.bbappend, and without this package nothing in \
the image ever writes the CSC pads. The measured consequence is recorded in \
build/accept-26111602/card-pipeline.txt: after a cold boot both pads still carry the driver \
default UYVY8_1X16/1280x720, the capture node advertises nothing usable, and HDMI RX -> PS \
DDR -> HDMI TX (sc7f0_dmabuf_loop) cannot start. The 26111602 acceptance session fixed that \
by hand (build/accept-26111602/card-capture-final.txt section A: two media-ctl -V writes, \
then the node advertised RX24 and ten frames streamed at 60.00 fps, 331,776,000 bytes). \
Shipping it as a unit is what makes a reboot reproduce it."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

# Same file layout as sc7f0-vcud, whose capture initialiser this replaces on this persona;
# both live under recipes-apps/<pn>/files and travel only as SRC_URI files.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://sc7f0-capture-init-rgb.sh file://sc7f0-capture-init-rgb.service"
S = "${WORKDIR}"

# Referenced by absolute path from the unit's ExecStart, so the two spellings are pinned to
# one variable instead of being compared as text by hand.
SC7F0_RGB_CAPTURE_INIT_PATH = "${libdir}/sc7f0/sc7f0-capture-init-rgb.sh"

# v4l2-ctl  : --query-dv-timings (locked-timing wait) and --set-fmt-video/--get-fmt-video
# media-ctl : the only spelling of VIDIOC_SUBDEV_S_FMT this card accepts for
#             RBG888_1X24 - v4l2-ctl --set-subdev-fmt code=0x100a returns EINVAL on both
#             pads (build/accept-26111602/card-rgbcap.txt steps 2 and 3) - and the -p
#             re-read the script asserts the pads against.
# Missing either one makes the unit fail on every boot while the image still "boots", which
# is the class of gap this recipe exists to close.
RDEPENDS:${PN} += "v4l-utils media-ctl"

inherit systemd
SYSTEMD_SERVICE:${PN} = "sc7f0-capture-init-rgb.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_compile() {
    # The unit runs this as PID 1's child at boot, so a shell error here is a silent
    # boot-time failure. Make it a build failure instead.
    sh -n sc7f0-capture-init-rgb.sh
    grep -q '^ExecStart=${SC7F0_RGB_CAPTURE_INIT_PATH}$' sc7f0-capture-init-rgb.service \
        || { echo "sc7f0-capture-init-rgb.service does not run ${SC7F0_RGB_CAPTURE_INIT_PATH}" >&2; exit 1; }
    # The two spellings that were measured to fail on this card must not come back:
    # v4l2-ctl for the subdev format, and a BGRX/XBGR fourcc that the node rejects.
    # Comments are stripped first: the script deliberately *documents* the spellings that
    # were measured to fail, and a grep over comments would reject its own explanation.
    sed 's/#.*//' sc7f0-capture-init-rgb.sh > code-only.sh
    if grep -q 'set-subdev-fmt' code-only.sh; then
        echo "sc7f0-capture-init-rgb.sh uses v4l2-ctl --set-subdev-fmt, which this card" >&2
        echo "rejects with EINVAL for RBG888_1X24; the accepted spelling is media-ctl -V" >&2
        exit 1
    fi
    if grep -qE "pixelformat=(BGRX|XBGR)" code-only.sh; then
        echo "the capture node rejects BGRX/XBGR; the advertised RGB fourcc is RX24" >&2
        exit 1
    fi
    # No I2C here: the NUC1262 runtime restart is a host-side, exactly-once action owned by
    # scripts/sc7f0_flash.sh, and repeating it from a boot service would make "exactly one
    # reset per flash" unverifiable.
    if grep -qi 'i2c' code-only.sh; then
        echo "sc7f0-capture-init-rgb.sh must not touch I2C" >&2
        exit 1
    fi
}

do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}${libdir}/sc7f0
    install -m 0644 sc7f0-capture-init-rgb.service ${D}${systemd_system_unitdir}/
    install -m 0755 sc7f0-capture-init-rgb.sh ${D}${SC7F0_RGB_CAPTURE_INIT_PATH}
}

FILES:${PN} += "${systemd_system_unitdir}/sc7f0-capture-init-rgb.service ${SC7F0_RGB_CAPTURE_INIT_PATH}"
