FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://system-user.dtsi file://common.dtsi file://vcu.dtsi file://sc6f0-mcu.dtsi file://sc7f0-hdmi-rx.dtsi file://sc7f0-ps-capture.dtsi file://sc7f0-hdmi-tx.dtsi file://sc7f0-rgb-compositor.dtsi file://sc7f0-memory-layout.dtsi"

# Explicit opt-in: the debug/HDMI05 hardware has no RX/PHY IRQ routing.
# Set to 1 only when importing/building the matching HDMI06 XSA/bitstream.
SC7F0_HDMI_RX_ENABLE ?= "0"
DTC_PPFLAGS:append = "${@' -DSC7F0_HDMI_RX_ENABLE=1' if d.getVar('SC7F0_HDMI_RX_ENABLE') == '1' else ''}"

SC7F0_PS_CAPTURE_ENABLE ?= "0"
DTC_PPFLAGS:append = "${@' -DSC7F0_PS_CAPTURE_ENABLE=1' if d.getVar('SC7F0_PS_CAPTURE_ENABLE') == '1' else ''}"

# Opt-in HDMI OUTPUT personality: only a bitstream built with SC7F0_DISPLAY_TX=1
# has the TX subsystem, the display frmbuf reader and the frame-tap reset bit 2.
SC7F0_HDMI_TX_ENABLE ?= "0"
DTC_PPFLAGS:append = "${@' -DSC7F0_HDMI_TX_ENABLE=1' if d.getVar('SC7F0_HDMI_TX_ENABLE') == '1' else ''}"

# SC7F0-RGB-COMPOSITOR-2PPC (0x26111405): replaces the single-plane display
# reader with two v_frmbuf_rd planes + alpha blend, adds the plane-B reader and
# the overlay ingress/plane-writer windows, and drops the VCU description.  It
# is a *personality* of the display tree, so it is meaningless without the two
# flags above; the guard below is what keeps a mistaken combination from
# producing a device tree that describes a bitstream that does not exist.
SC7F0_RGB_COMPOSITOR_ENABLE ?= "0"
DTC_PPFLAGS:append = "${@' -DSC7F0_RGB_COMPOSITOR_ENABLE=1' if d.getVar('SC7F0_RGB_COMPOSITOR_ENABLE') == '1' else ''}"

python __anonymous() {
    if d.getVar("SC7F0_PS_CAPTURE_ENABLE") == "1" and d.getVar("SC7F0_HDMI_RX_ENABLE") != "1":
        bb.fatal("PS capture requires the matching HDMI IRQ-enabled hardware")
    # sc7f0-hdmi-tx.dtsi appends its TX lanes after the RX lanes of
    # &sc7f0_vphy and consumes sc7f0_capture_clk / sc7f0_frame_tap, so it is
    # meaningful only inside a tree that already enables both stages.
    if d.getVar("SC7F0_HDMI_TX_ENABLE") == "1" and d.getVar("SC7F0_PS_CAPTURE_ENABLE") != "1":
        bb.fatal("HDMI TX display requires the capture hardware (shared 300 MHz reader clock and frame-tap reset controller)")
    if d.getVar("SC7F0_RGB_COMPOSITOR_ENABLE") == "1" and d.getVar("SC7F0_HDMI_TX_ENABLE") != "1":
        bb.fatal("the RGB compositor personality is the display tree with two planes; enable the HDMI TX personality with it")
}

require ${@'device-tree-sdt.inc' if d.getVar('SYSTEM_DTFILE') != '' else ''}
