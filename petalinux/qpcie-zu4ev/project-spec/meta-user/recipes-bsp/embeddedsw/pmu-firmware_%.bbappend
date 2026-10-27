FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

EMBEDDEDSW_SRCURI += "file://0001-Fixed-vproc-issues.patch file://0002-sc7f0-enable-watchdog-srst.patch"
# meta-xilinx-tools assigns SRC_URI from EMBEDDEDSW_SRCURI; appending
# SRC_URI here can be silently overwritten and reuse the old PMU binary.
# ENABLE_RECOVERY stays disabled: FPD SWDT uses EM_ACTION_SRST directly,
# not an APU-only graceful recovery that requires a responsive ATF/Linux.

