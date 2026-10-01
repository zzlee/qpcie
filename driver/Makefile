# ============================================================================
# Makefile for Linux Kernel PCIe V4L2 & ALSA Driver
# ============================================================================

obj-m += qpcie.o
qpcie-objs := qpcie_main.o qpcie_v4l2.o qpcie_alsa.o qpcie_sysfs.o qpcie_dmabuf.o qpcie_i2c.o qpcie_flash.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
