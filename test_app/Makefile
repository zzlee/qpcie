# ============================================================================
# Makefile for QPCIe V4L2 & ALSA User-Mode Test Applications & Sanity Check
# ============================================================================

CC ?= gcc
CFLAGS ?= -O2 -Wall -I.
LDFLAGS ?= -lm -pthread

TARGETS = qpcie_sanity_check v4l2_test_app alsa_test_app alsa_loopback_test_app dmabuf_p2p_test_app loopback_test_app

all: $(TARGETS)

qpcie_sanity_check: qpcie_sanity_check.c
	$(CC) $(CFLAGS) -o $@ qpcie_sanity_check.c $(LDFLAGS)

v4l2_test_app: v4l2_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ v4l2_test_app.c $(LDFLAGS)

alsa_test_app: alsa_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ alsa_test_app.c $(LDFLAGS)

alsa_loopback_test_app: alsa_loopback_test_app.c
	$(CC) $(CFLAGS) -o $@ alsa_loopback_test_app.c $(LDFLAGS)

dmabuf_p2p_test_app: dmabuf_p2p_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ dmabuf_p2p_test_app.c $(LDFLAGS)

loopback_test_app: loopback_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ loopback_test_app.c $(LDFLAGS)

clean:
	rm -f $(TARGETS) *.o *.yuv *.pcm *.raw

.PHONY: all clean
