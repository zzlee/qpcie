SRCREV = "c9a0ee31b2a14cbcfcb56ca369037319b4ad4847"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

EMBEDDEDSW_SRCURI += "file://0001-Fixed-vproc-ip-issues.patch \
            file://0002-feat-fsbl-add-Si5341-clock-generator-configuration.patch \
            file://0003-fix-correct-pointer-arithmetic-in-io_read_reg_u32.patch \
            "
