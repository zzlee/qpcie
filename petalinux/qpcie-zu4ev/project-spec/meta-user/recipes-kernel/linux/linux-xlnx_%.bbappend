FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " file://bsp.cfg file://sc7f0-v4l2-capture.cfg file://0001-sc7f0-vipp-frame-tap.patch file://0002-sc7f0-vcu-debug-probe.patch file://sc7f0-frame-tap.c file://sc7f0-frame-tap.h"
KERNEL_FEATURES:append = " bsp.cfg sc7f0-v4l2-capture.cfg"

do_patch:append() {
    install -m 0644 ${WORKDIR}/sc7f0-frame-tap.c ${S}/drivers/media/platform/xilinx/
    install -m 0644 ${WORKDIR}/sc7f0-frame-tap.h ${S}/drivers/media/platform/xilinx/
}
