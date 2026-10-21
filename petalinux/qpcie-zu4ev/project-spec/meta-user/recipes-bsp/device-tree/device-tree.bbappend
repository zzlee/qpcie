FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://system-user.dtsi file://common.dtsi file://vcu.dtsi file://sc6f0-mcu.dtsi file://sc7f0-hdmi-rx.dtsi"

# Explicit opt-in: the debug/HDMI05 hardware has no RX/PHY IRQ routing.
# Set to 1 only when importing/building the matching HDMI06 XSA/bitstream.
SC7F0_HDMI_RX_ENABLE ?= "0"
DTC_PPFLAGS:append = "${@' -DSC7F0_HDMI_RX_ENABLE=1' if d.getVar('SC7F0_HDMI_RX_ENABLE') == '1' else ''}"

require ${@'device-tree-sdt.inc' if d.getVar('SYSTEM_DTFILE') != '' else ''}
