SRCREV = "c9a0ee31b2a14cbcfcb56ca369037319b4ad4847"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

EMBEDDEDSW_SRCURI += "file://0001-Fixed-vproc-ip-issues.patch \
            file://0002-feat-fsbl-add-Si5341-clock-generator-configuration.patch \
            file://0004-feat-fsbl-support-two-stage-tandem-bitstream-loading.patch \
            file://0005-fix-fsbl-zzlab-env-baseaddr-macro.patch \
            file://0006-silence-fsbl-prints.patch \
            "
# NOTE 2026-10-08: 0003 retired — io_read fix folded into 0002.

