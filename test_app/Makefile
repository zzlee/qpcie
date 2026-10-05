# ============================================================================
# Makefile for QPCIe V4L2 & ALSA User-Mode Test Applications & Sanity Check
# ============================================================================

CC ?= gcc
CFLAGS ?= -O2 -Wall -I.
LDFLAGS ?= -lm -pthread

# Cross compiler for ZU4EV target daemon
AARCH64_CC ?= $(shell which aarch64-linux-gnu-gcc 2>/dev/null || which /opt/Xilinx/Vitis/2023.2/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-gcc 2>/dev/null || echo aarch64-linux-gnu-gcc)

TARGETS = qpcie_sanity_check qpcie_upgrade qpcie_flash qpcie_a50t_tool qpcie_hdmi_ctl v4l2_test_app v4l2_rgb24_test_app alsa_test_app alsa_loopback_test_app dmabuf_p2p_test_app loopback_test_app

all: $(TARGETS)

qpcie_upgrade: qpcie_upgrade.c
	$(CC) $(CFLAGS) -o $@ qpcie_upgrade.c $(LDFLAGS)

qpcie_upgrade_daemon: qpcie_upgrade_daemon.c
	$(AARCH64_CC) -O2 -Wall -static -o $@ qpcie_upgrade_daemon.c

qpcie_a50t_tool: qpcie_a50t_tool.c
	$(CC) $(CFLAGS) -o $@ qpcie_a50t_tool.c $(LDFLAGS)

qpcie_fw_daemon: qpcie_fw_daemon.c
	$(AARCH64_CC) -O2 -Wall -static -o $@ qpcie_fw_daemon.c

qpcie_hdmi_daemon: qpcie_hdmi_daemon.c qpcie_control.h
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

alsa_test_app: alsa_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ alsa_test_app.c $(LDFLAGS)

alsa_loopback_test_app: alsa_loopback_test_app.c
	$(CC) $(CFLAGS) -o $@ alsa_loopback_test_app.c $(LDFLAGS)

dmabuf_p2p_test_app: dmabuf_p2p_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ dmabuf_p2p_test_app.c $(LDFLAGS)

loopback_test_app: loopback_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ loopback_test_app.c $(LDFLAGS)

clean:
	rm -f $(TARGETS) qpcie_fw_daemon qpcie_hdmi_daemon *.o *.yuv *.pcm *.raw

.PHONY: all clean qpcie_fw_daemon qpcie_hdmi_daemon

