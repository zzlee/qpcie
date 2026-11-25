SUMMARY = "SC7F0 HP1 packet reader DMA-BUF staging importer"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"
inherit module
SRC_URI = "file://Makefile file://stage2.c"
S = "${WORKDIR}"
KERNEL_MODULE_AUTOLOAD += "stage2"
