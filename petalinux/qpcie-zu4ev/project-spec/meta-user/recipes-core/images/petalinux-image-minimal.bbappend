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
