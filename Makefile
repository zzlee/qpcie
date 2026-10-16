# ==============================================================================
# Top-Level Makefile for QPCIe Project
# Supports: Host Linux Driver, Test Applications, Vivado FPGA Builds,
# and ZU4EV SC7F0 PetaLinux 2023.2 Project.
# ==============================================================================

SHELL := /bin/bash

.PHONY: all help driver test_app clean \
        fpga-zu4ev-hdmi-ip fpga-zu4ev-hdmi-synth test-sc7f0-hdmi \
        fpga-zu4ev fpga-a50t \
        petalinux-hw-desc petalinux-all petalinux-bootimage \
        petalinux-device-tree petalinux-fsbl petalinux-uboot \
        petalinux-kernel petalinux-rootfs petalinux-config petalinux-clean

# Default target: build host driver and test applications
all: driver test_app

help:
	@echo "================================================================="
	@echo " QPCIe Multi-Channel Video & Audio PCIe DMA Build System"
	@echo "================================================================="
	@echo " Host Software Targets:"
	@echo "   make all                   Build Linux driver and test apps"
	@echo "   make driver                Compile qpcie.ko"
	@echo "   make test_app              Compile all test applications"
	@echo "   make clean                 Clean driver and test app binaries"
	@echo ""
	@echo " FPGA Bitstream Targets:"
	@echo "   make fpga-zu4ev            Build ZU4EV Tandem PCIe bitstreams"
	@echo "   make fpga-a50t             Build Artix-7 A50T bitstream"
	@echo "   make fpga-zu4ev-hdmi-ip     Generate isolated experimental HDMI05 IP"
	@echo "   make fpga-zu4ev-hdmi-synth  Synthesize experimental HDMI05 (no flash/export)"
	@echo "   make test-sc7f0-hdmi       Test V11 pin map, DDC pads and XPM stream bridges"
	@echo ""
	@echo " PetaLinux (ZU4EV SC7F0) Targets:"
	@echo "   make petalinux-hw-desc     Import XSA & configure PetaLinux"
	@echo "   make petalinux-all         Build full PetaLinux kernel & BOOT.BIN"
	@echo "   make petalinux-bootimage   Package BOOT.BIN with Tandem Stage 1"
	@echo "   make petalinux-device-tree Build device tree only"
	@echo "   make petalinux-fsbl        Build ZynqMP FSBL only"
	@echo "   make petalinux-uboot       Build U-Boot only"
	@echo "   make petalinux-kernel      Build Linux kernel only"
	@echo "   make petalinux-rootfs      Build RootFS only"
	@echo "   make petalinux-config      Open PetaLinux menuconfig"
	@echo "   make petalinux-clean       Clean PetaLinux build artifacts"
	@echo "================================================================="

# Host Driver & Apps
driver:
	$(MAKE) -C driver

test_app:
	$(MAKE) -C test_app

clean:
	$(MAKE) -C driver clean
	$(MAKE) -C test_app clean

# FPGA Builds
fpga-zu4ev:
	./scripts/build_zu4ev.sh

fpga-zu4ev-hdmi-ip:
	SC7F0_PROFILE=full SC7F0_BUILD_STAGE=ip bash ./scripts/build_zu4ev.sh

fpga-zu4ev-hdmi-synth:
	SC7F0_PROFILE=full SC7F0_BUILD_STAGE=synth bash ./scripts/build_zu4ev.sh

test-sc7f0-hdmi:
	mkdir -p build/sc7f0-hdmi-tests
	tclsh scripts/test_sc7f0_hdmi_pins.tcl
	iverilog -g2012 -s sc7f0_ddc_iobuf_tb -o build/sc7f0-hdmi-tests/ddc.vvp rtl/sc7f0_ddc_iobuf.v tb/sc7f0_ddc_iobuf_tb.sv
	vvp build/sc7f0-hdmi-tests/ddc.vvp
	source /opt/Xilinx/Vivado/2023.2/settings64.sh && vivado -mode batch -source scripts/sim_sc7f0_hdmi_bridges.tcl -log build/sc7f0-hdmi-tests/bridges.log -journal build/sc7f0-hdmi-tests/bridges.jou
	source /opt/Xilinx/Vivado/2023.2/settings64.sh && vivado -mode batch -source scripts/sim_sc7f0_hdmi_control.tcl -log build/sc7f0-hdmi-tests/control.log -journal build/sc7f0-hdmi-tests/control.jou

fpga-a50t:
	./scripts/build_a50t.sh

# PetaLinux Targets (automatically dispatches via Docker container)
petalinux-hw-desc:
	$(MAKE) -C petalinux/qpcie-zu4ev hw-desc

petalinux-all:
	$(MAKE) -C petalinux/qpcie-zu4ev all

petalinux-bootimage:
	$(MAKE) -C petalinux/qpcie-zu4ev bootimage

petalinux-device-tree:
	$(MAKE) -C petalinux/qpcie-zu4ev device-tree

petalinux-fsbl:
	$(MAKE) -C petalinux/qpcie-zu4ev fsbl

petalinux-uboot:
	$(MAKE) -C petalinux/qpcie-zu4ev uboot

petalinux-kernel:
	$(MAKE) -C petalinux/qpcie-zu4ev kernel

petalinux-rootfs:
	$(MAKE) -C petalinux/qpcie-zu4ev rootfs

petalinux-config:
	$(MAKE) -C petalinux/qpcie-zu4ev config

petalinux-clean:
	$(MAKE) -C petalinux/qpcie-zu4ev clean
