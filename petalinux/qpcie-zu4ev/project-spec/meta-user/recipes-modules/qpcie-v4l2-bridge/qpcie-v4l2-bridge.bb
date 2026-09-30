SUMMARY = "QPCIe V4L2 Bridge Driver for Xilinx HDMI RX Subsystem"
SECTION = "PETALINUX/modules"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://COPYING;md5=838c366f69b72c5df05c96dff79b35f2"

inherit module

SRC_URI = "file://Makefile \
           file://qpcie_v4l2_bridge.c \
           file://COPYING \
          "

S = "${WORKDIR}"

# Autoload module on boot
KERNEL_MODULE_AUTOLOAD += "qpcie_v4l2_bridge"
