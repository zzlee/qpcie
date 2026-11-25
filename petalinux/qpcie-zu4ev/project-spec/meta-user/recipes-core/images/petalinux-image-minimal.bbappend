# SC7F0 release runtime for the VCU card path.
#
# These four packages are what made the 2026-11 card "work" without being part of
# any image: sc7f0_vcud ran as a loose 81,408-byte file on the eMMC BOOT partition
# (/run/media/BOOT-mmcblk0p1/sc7f0_vcud), its OpenMAX libraries were not in the
# rootfs at all, and the 0x800 mailbox qpcie_debugd was pushed into RAM by the host
# after every boot. A plain reboot therefore could not reproduce the running state,
# and no upgrade tar contained them.
#
# Listing them in the image recipe (rather than pushing files after boot or editing
# BOOT-partition copies) is what makes them part of image.ub, which the release
# package then ships and scripts/sc7f0_rootfs_packages.py verify re-reads out of the
# FIT. qpcie-debugd and sc7f0-ps-capture are already pulled in through
# meta-user/conf/user-rootfsconfig.
IMAGE_INSTALL:append = " sc7f0-vcud libomxil-xlnx libvcu-xlnx vcu-firmware"

# HDMI output bring-up needs a KMS userspace, and the only one this project uses is
# upstream libdrm's own modetest.  libdrm is not currently in this image at all
# (project-spec/configs/rootfs_config read "# CONFIG_libdrm is not set" before this
# line existed), so without it there is no way to enumerate the xlnx,pl-disp ->
# v-hdmi-tx-ss DRM card or drive a fixed pattern from the card itself.
#
# modetest is not a private tool: it is upstream libdrm's tests/modetest, and the
# libdrm recipe's default PACKAGECONFIG already carries "tests install-test-programs"
# with FILES:${PN}-tests = "${bindir}/*", so libdrm-tests is what ships
# /usr/bin/modetest.  The meta-petalinux libdrm bbappend only patches modetest for
# Xilinx fourcc formats; it does not add a display daemon.
#
# A separate IMAGE_INSTALL line keeps the existing sc7f0-vcud line byte-identical,
# which scripts/build_sc7f0_matching_ps_vcu.sh and the 26111204 r3 runner match
# exactly.  Presence is proven out of the built FIT afterwards with
# scripts/package_sc7f0_rootfs.py verify (--expect-file usr/lib/libdrm.so.1 and
# --expect-binary modetest=@present), not from this line.
IMAGE_INSTALL:append = " libdrm libdrm-tests"

# The RGB-compositor personality has no VCU in the fabric (scripts/
# create_zu4ev_ps_bd.tcl refuses VCU and SC7F0_RGB_COMPOSITOR on one design).
# sc7f0-vcud is a systemd service that opens the encoder/decoder registers and
# libvcu-xlnx/libomxil-xlnx only make sense next to it, so shipping them on
# this image means a service that can never be satisfied on every boot.  The
# sc7f0-vcud IMAGE_INSTALL line above is deliberately left byte-identical,
# because scripts/build_sc7f0_matching_ps_vcu.sh and the 26111204 r3 runner
# match it as text; ':remove' is applied when IMAGE_INSTALL is finally read,
# which is after every :append in this file, so it wins without editing that
# line.  For every other personality SC7F0_RGB_COMPOSITOR_VCU_REMOVE stays
# empty and IMAGE_INSTALL is unchanged.
SC7F0_RGB_COMPOSITOR_VCU_REMOVE ?= ""
python __anonymous() {
    if d.getVar('SC7F0_RGB_COMPOSITOR_ENABLE') == '1' and d.getVar('SC7F0_VCU_ENABLE') != '1':
        d.setVar('SC7F0_RGB_COMPOSITOR_VCU_REMOVE',
                 'sc7f0-vcud libomxil-xlnx libvcu-xlnx vcu-firmware')
}
IMAGE_INSTALL:remove = "${SC7F0_RGB_COMPOSITOR_VCU_REMOVE}"

# The 0x26111405 personality has no VCU service to replace, but it does need a
# way to talk to the blocks that no kernel driver owns: the overlay controller at
# 0xB00A0000, Reader-B at 0xB0090000, and the blend/alpha controls.  The card has
# no network (&gem0 is disabled in system-user.dtsi) and its BusyBox has no
# base64/uudecode, so a diagnostic binary cannot be pushed onto a running card;
# the only way it can be present when it is needed is to ship in the image.
# Kept on its own IMAGE_INSTALL line so every line above stays byte-identical.
IMAGE_INSTALL:append = " sc7f0-rgb-overlay"

# A1's acceptance needs the capture buffer and the display plane to be the SAME
# buffer, which only a program that does VIDIOC_EXPBUF -> drmPrimeFDToHandle ->
# drmModeAddFB2 -> drmModePageFlip can show; modetest allocates its own framebuffers
# and therefore proves nothing about the capture path.  Shipped unconditionally for
# the same reason as sc7f0-rgb-overlay (the card has no network and no base64, so a
# diagnostic that is not in the image cannot be used), and it is inert unless run.
IMAGE_INSTALL:append = " sc7f0-dmabuf-loop"

# Nothing in the RGB persona configures the capture graph any more.  The VCU persona gets
# that from sc7f0-vcud.service's ExecStartPre, and sc7f0-vcud is exactly what the :remove
# above takes away, so on this persona a cold boot leaves both vpss-csc pads at the driver
# default UYVY8_1X16/1280x720 and the VIPP node unconfigurable - the state recorded in
# build/accept-26111602/card-pipeline.txt, which the 26111602 acceptance session repaired by
# hand with two `media-ctl -V` writes before RGB capture worked
# (build/accept-26111602/card-capture-final.txt section A).  sc7f0-capture-init-rgb ships
# that sequence as a boot unit so a reboot reproduces it without a human; it is installed
# only for the persona that needs it, because on the VCU persona the same pads must stay
# RGB->YUV for the encoder.  Same ':remove'-style ordering argument as above: this runs
# after every :append in the file, and every line above stays byte-identical.
SC7F0_RGB_COMPOSITOR_IMAGE_ADDONS ?= ""
python __anonymous() {
    if d.getVar('SC7F0_RGB_COMPOSITOR_ENABLE') == '1' and d.getVar('SC7F0_VCU_ENABLE') != '1':
        d.setVar('SC7F0_RGB_COMPOSITOR_IMAGE_ADDONS', 'sc7f0-capture-init-rgb')
}
IMAGE_INSTALL:append = " ${SC7F0_RGB_COMPOSITOR_IMAGE_ADDONS}"

# Always ship qpcie-upgrade-daemon and qpcie-debugd natively in the image so
# `petalinux-build` produces a complete, PCIe-upgradable image.ub directly
# without needing inject_upgrade_daemon_to_image_ub.sh.
IMAGE_INSTALL:append = " qpcie-upgrade-daemon qpcie-debugd"

# SC7F0 has no RJ45 ethernet port: mask network/nfs services to avoid boot
# delays, and enable root autologin on ttyPS0 for serial console debug.
sc7f0_no_network_and_autologin() {
    rm -f ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants/systemd-network-generator.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants/systemd-resolved.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/nfs-*.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/remote-fs.target \
          ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/rpcbind.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/sockets.target.wants/systemd-networkd.socket \
          ${IMAGE_ROOTFS}/etc/systemd/system/sockets.target.wants/rpcbind.socket \
          ${IMAGE_ROOTFS}/etc/systemd/system/sockets.target.wants/sshd.socket \
          ${IMAGE_ROOTFS}/etc/systemd/system/dbus-org.freedesktop.network1.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/dbus-org.freedesktop.resolve1.service \
          ${IMAGE_ROOTFS}/etc/systemd/system/dbus-org.freedesktop.timesync1.service
    mkdir -p ${IMAGE_ROOTFS}/etc/systemd/system
    for svc in networking.service systemd-networkd.service systemd-networkd-wait-online.service \
               systemd-network-generator.service systemd-resolved.service systemd-timesyncd.service \
               nfs-common.service nfs-statd.service nfs-mountd.service rpcbind.service; do
        ln -sfn /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/$svc
    done
    mkdir -p ${IMAGE_ROOTFS}/etc/systemd/system/serial-getty@ttyPS0.service.d
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear %%I $TERM\n' \
        > ${IMAGE_ROOTFS}/etc/systemd/system/serial-getty@ttyPS0.service.d/autologin.conf
}
ROOTFS_POSTPROCESS_COMMAND += "sc7f0_no_network_and_autologin; "
