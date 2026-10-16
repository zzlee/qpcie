# ============================================================================
# Makefile for Linux Kernel PCIe V4L2 & ALSA Driver
# ============================================================================

obj-m += qpcie.o
qpcie-objs := qpcie_main.o qpcie_v4l2.o qpcie_alsa.o qpcie_sysfs.o qpcie_dmabuf.o qpcie_i2c.o qpcie_flash.o qpcie_upgrade.o

# A50T and ZU4EV use different BAR1 crossbar layouts. Never probe the TPG
# using the ZU4EV offset on A50T: 0x3000 is its front-end I2C controller.
ifeq ($(QPCIE_A50T),1)
ccflags-y += -DQPCIE_A50T_BAR1
endif

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
