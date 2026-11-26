# ============================================================================
# Makefile for Linux Kernel PCIe V4L2 & ALSA Driver
# ============================================================================

obj-m += qpcie.o
qpcie-objs := qpcie_main.o qpcie_v4l2.o qpcie_alsa.o qpcie_sysfs.o qpcie_dmabuf.o qpcie_i2c.o qpcie_flash.o qpcie_upgrade.o qpcie_debug.o qpcie_overlay.o
# The KMS path targets the test host's Linux 7 DRM API. Keep older
# out-of-tree capture builds free of its changing atomic/GEM interfaces.
QPCIE_KMS ?= 0
ifeq ($(QPCIE_KMS),1)
ifeq ($(VERSION),7)
ifeq ($(CONFIG_X86_64)$(CONFIG_SYSFS),yy)
ifneq ($(filter y m,$(CONFIG_DRM_GEM_DMA_HELPER)),)
ifneq ($(filter y m,$(CONFIG_DRM_KMS_HELPER)),)
qpcie-objs += qpcie_kms.o
ccflags-y += -DQPCIE_HAVE_KMS
endif
endif
endif
endif
endif

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
