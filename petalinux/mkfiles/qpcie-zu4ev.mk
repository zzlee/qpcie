ifeq ($(PETALINUX_MAKE_READY),1)

AT=@
XSA_DIR?=$(abspath ../../build/sc7f0.xsa)
DATE_LOG=time.build

TANDEM1_BIT?=$(abspath ../../build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_tandem1.bit)
TANDEM2_BIT?=$(abspath ../../build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_tandem2.bit)

.NOTPARALLEL: all
all: linux bootimage

hw-desc:
	${AT} test -f "$(XSA_DIR)" || test -d "$(XSA_DIR)" || { echo "ERROR: XSA not found at $(XSA_DIR)"; exit 1; }
	${AT} petalinux-config --get-hw-description=$(XSA_DIR) --silentconfig

linux:
	${AT} echo "petalinux-build [START]" >> ${DATE_LOG} && \
	date >> ${DATE_LOG} && \
	petalinux-build && \
	echo "petalinux-build [DONE]" >> ${DATE_LOG} && \
	date >> ${DATE_LOG}

bootimage:
	${AT} mkdir -p images/linux
	${AT} if [ -f "$(TANDEM1_BIT)" ] && [ -f "$(TANDEM2_BIT)" ]; then \
		echo "Packaging Two-Stage Tandem PCIe Boot Image (Stage 1 + Stage 2)..."; \
		cp "$(TANDEM1_BIT)" images/linux/zu4ev_pcie_card_top_tandem1.bit; \
		cp "$(TANDEM2_BIT)" images/linux/zu4ev_pcie_card_top_tandem2.bit; \
		printf '// Two-Stage Tandem PCIe BIF\nthe_ROM_image:\n{\n\t[fsbl_config] a53_x64\n\t[bootloader, destination_cpu=a53-0] images/linux/zynqmp_fsbl.elf\n\t[pmufw_image] images/linux/pmufw.elf\n\t[destination_device=pl] images/linux/zu4ev_pcie_card_top_tandem1.bit\n\t[destination_device=pl] images/linux/zu4ev_pcie_card_top_tandem2.bit\n\t[destination_cpu=a53-0, exception_level=el-3, trustzone] images/linux/bl31.elf\n\t[destination_cpu=a53-0, exception_level=el-2] images/linux/u-boot.elf\n}\n' > images/linux/bootgen_tandem.bif; \
		petalinux-package --boot --bif images/linux/bootgen_tandem.bif --force; \
	elif [ -f "$(TANDEM1_BIT)" ]; then \
		echo "Using Single Tandem Stage 1 bitstream: $(TANDEM1_BIT)"; \
		cp "$(TANDEM1_BIT)" images/linux/system.bit; \
		petalinux-package --boot --force \
			--fsbl images/linux/zynqmp_fsbl.elf \
			--pmufw images/linux/pmufw.elf \
			--fpga images/linux/system.bit \
			--atf images/linux/bl31.elf \
			--u-boot images/linux/u-boot.elf; \
	else \
		echo "Using default deployed bitstream..."; \
		petalinux-package --boot --force \
			--fsbl images/linux/zynqmp_fsbl.elf \
			--pmufw images/linux/pmufw.elf \
			--atf images/linux/bl31.elf \
			--u-boot images/linux/u-boot.elf; \
	fi
	${AT} ls -lh images/linux/BOOT.BIN

device-tree:
	${AT} petalinux-build -c device-tree -x clean && \
	petalinux-build -c device-tree

fsbl:
	${AT} petalinux-build -c fsbl-firmware -x clean && \
	petalinux-build -c fsbl-firmware

uboot:
	${AT} petalinux-build -c u-boot-xlnx -x clean && \
	petalinux-build -c u-boot-xlnx

kernel:
	${AT} petalinux-build -c kernel

rootfs:
	${AT} petalinux-build -c rootfs

config:
	${AT} petalinux-config

kernel-config:
	${AT} petalinux-config -c kernel

rootfs-config:
	${AT} petalinux-config -c rootfs

clean:
	${AT} petalinux-build -x cleanall && \
	$(RM) -rf images/linux/*

mrproper:
	${AT} petalinux-build -x mrproper -f

.PHONY: all hw-desc linux bootimage device-tree fsbl uboot kernel rootfs config kernel-config rootfs-config clean mrproper

else
include $(dir $(lastword $(MAKEFILE_LIST)))petalinux-dispatch.mk
endif
