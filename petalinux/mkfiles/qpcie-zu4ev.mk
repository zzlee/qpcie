ifeq ($(PETALINUX_MAKE_READY),1)

AT=@
XSA_DIR?=$(abspath ../../build/sc7f0.xsa)
DATE_LOG=time.build

TANDEM1_BIT?=$(abspath ../../build/qpcie_zu4ev_proj/qpcie_zu4ev_card.runs/impl_1/zu4ev_pcie_card_top_tandem1.bit)

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
	${AT} if [ -f "$(TANDEM1_BIT)" ]; then \
		echo "Using ZU4EV Tandem Stage 1 bitstream: $(TANDEM1_BIT)"; \
		cp "$(TANDEM1_BIT)" images/linux/system.bit; \
	elif [ -f project-spec/hw-description/*.bit ]; then \
		echo "Using hardware description bitstream"; \
		cp project-spec/hw-description/*.bit images/linux/system.bit; \
	else \
		bitstream=$$(find build/tmp/deploy/images -type f -name '*.bit' 2>/dev/null | sort | head -n 1); \
		if [ -n "$$bitstream" ]; then \
			echo "Using deployed bitstream: $$bitstream"; \
			cp "$$bitstream" images/linux/system.bit; \
		fi; \
	fi
	${AT} if [ -f images/linux/system.bit ]; then \
		FPGA_OPT="--fpga images/linux/system.bit"; \
	else \
		FPGA_OPT=""; \
	fi; \
	petalinux-package --boot --force \
		--fsbl images/linux/zynqmp_fsbl.elf \
		--pmufw images/linux/pmufw.elf \
		$$FPGA_OPT \
		--atf images/linux/bl31.elf \
		--u-boot images/linux/u-boot.elf
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
