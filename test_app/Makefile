# ============================================================================
# Makefile for QPCIe V4L2 & ALSA User-Mode Test Applications & Sanity Check
# ============================================================================

CC ?= gcc
CFLAGS ?= -O2 -Wall -I.
LDFLAGS ?= -lm -pthread

# Cross compiler for ZU4EV target daemon
AARCH64_CC ?= $(shell which aarch64-linux-gnu-gcc 2>/dev/null || which /opt/Xilinx/Vitis/2023.2/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-gcc 2>/dev/null || echo aarch64-linux-gnu-gcc)
AARCH64_CXX ?= $(shell which aarch64-linux-gnu-g++ 2>/dev/null || which /opt/Xilinx/Vitis/2023.2/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-g++ 2>/dev/null || echo aarch64-linux-gnu-g++)

PETALINUX_SYSROOTS ?= ../petalinux/qpcie-zu4ev/build/tmp/sysroots-components
VCU_INC ?= $(PETALINUX_SYSROOTS)/zynqmp_generic_xczu4ev/libomxil-xlnx/usr/include/vcu-omx-il
VCU_LIB ?= $(PETALINUX_SYSROOTS)/zynqmp_generic_xczu4ev/libomxil-xlnx/usr/lib
VCU_ALLEGRO_LIB ?= $(PETALINUX_SYSROOTS)/cortexa72-cortexa53/libvcu-xlnx/usr/lib

TARGETS = sc7f0ctl qpcie_sanity_check qpcie_upgrade qpcie_dma_diag qpcie_ddr_verify qpcie_stage_push qpcie_flash qpcie_a50t_tool qpcie_hdmi_ctl v4l2_test_app v4l2_rgb24_test_app v4l2_capture_verify alsa_test_app alsa_loopback_test_app dmabuf_p2p_test_app loopback_test_app

all: $(TARGETS)

sc7f0ctl: sc7f0ctl.c qpcie_debug_io.h ../include/qpcie_debug.h
	$(CC) $(CFLAGS) -I../include -o $@ sc7f0ctl.c

qpcie_debugd: qpcie_debugd.c qpcie_debug_io.h sc7f0_health.h ../include/qpcie_debug.h
	$(AARCH64_CC) -O2 -Wall -Wextra -I../include -static -o $@ qpcie_debugd.c

sc7f0_vcud: sc7f0_vcud.cpp
	$(AARCH64_CXX) -O2 -Wall -Wextra -I$(VCU_INC) -L$(VCU_LIB) -L$(VCU_ALLEGRO_LIB) -Wl,-rpath-link=$(VCU_ALLEGRO_LIB) -o $@ sc7f0_vcud.cpp -lOMX.allegro.core -lOMX.allegro.video_encoder -lpthread

qpcie_upgrade: qpcie_upgrade.c
	$(CC) $(CFLAGS) -o $@ qpcie_upgrade.c $(LDFLAGS)

qpcie_dma_diag: qpcie_dma_diag.c
	$(CC) $(CFLAGS) -o $@ qpcie_dma_diag.c

qpcie_ddr_verify: qpcie_ddr_verify.c
	$(CC) $(CFLAGS) -o $@ qpcie_ddr_verify.c

qpcie_stage_push: qpcie_stage_push.c
	$(CC) $(CFLAGS) -o $@ qpcie_stage_push.c

sc7f0_ps_watchdog: sc7f0_ps_watchdog.c sc7f0_health.h
	$(AARCH64_CC) -O2 -Wall -Wextra -static -o $@ sc7f0_ps_watchdog.c

qpcie_upgrade_daemon: qpcie_upgrade_daemon.c sc7f0_health.h qpcie_file_transaction.h qpcie_commit_helpers.h qpcie_archive_verify.h
	$(AARCH64_CC) -O2 -Wall -static -o $@ qpcie_upgrade_daemon.c

qpcie_a50t_tool: qpcie_a50t_tool.c
	$(CC) $(CFLAGS) -o $@ qpcie_a50t_tool.c $(LDFLAGS)

qpcie_fw_daemon: qpcie_fw_daemon.c
	$(AARCH64_CC) -O2 -Wall -static -o $@ qpcie_fw_daemon.c

qpcie_hdmi_daemon: qpcie_hdmi_daemon.c qpcie_control.h qpcie_hdmi_audio.h sc7f0_health.h
	$(AARCH64_CC) -O2 -Wall -static -o $@ qpcie_hdmi_daemon.c

qpcie_flash: qpcie_flash.c
	$(CC) $(CFLAGS) -o $@ qpcie_flash.c $(LDFLAGS)

qpcie_hdmi_ctl: qpcie_hdmi_ctl.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ qpcie_hdmi_ctl.c $(LDFLAGS)

qpcie_sanity_check: qpcie_sanity_check.c

	$(CC) $(CFLAGS) -o $@ qpcie_sanity_check.c $(LDFLAGS)

v4l2_test_app: v4l2_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ v4l2_test_app.c $(LDFLAGS)

v4l2_rgb24_test_app: v4l2_rgb24_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ v4l2_rgb24_test_app.c $(LDFLAGS)

v4l2_capture_verify: v4l2_capture_verify.c
	$(CC) $(CFLAGS) -std=c11 -Wextra -o $@ $<

# PetaLinux capture app; standard V4L2/VB2, no host-private source controls.
sc7f0_ps_capture: sc7f0_ps_capture.c
	$(AARCH64_CC) -O2 -std=c11 -Wall -Wextra -static -o $@ $<

alsa_test_app: alsa_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ alsa_test_app.c $(LDFLAGS)

alsa_loopback_test_app: alsa_loopback_test_app.c
	$(CC) $(CFLAGS) -o $@ alsa_loopback_test_app.c $(LDFLAGS)

dmabuf_p2p_test_app: dmabuf_p2p_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ dmabuf_p2p_test_app.c $(LDFLAGS)

loopback_test_app: loopback_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ loopback_test_app.c $(LDFLAGS)

clean:
	rm -f $(TARGETS) sc7f0_ps_capture qpcie_debugd qpcie_fw_daemon qpcie_hdmi_daemon *.o *.yuv *.pcm *.raw

.PHONY: all clean qpcie_fw_daemon qpcie_hdmi_daemon
