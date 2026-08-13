# ============================================================================
# Makefile for Linux Kernel PCIe V4L2 & ALSA Driver
# ============================================================================

obj-m += custom_pcie_av.o
custom_pcie_av-objs := qpcie_main.o qpcie_v4l2.o qpcie_alsa.o qpcie_sysfs.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
