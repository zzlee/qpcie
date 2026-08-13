# ============================================================================
# Makefile for QPCIe V4L2 & ALSA User-Mode Test Applications
# ============================================================================

CC ?= gcc
CFLAGS ?= -O2 -Wall -I.
LDFLAGS ?= -lm

TARGETS = v4l2_test_app alsa_test_app dmabuf_p2p_test_app

all: $(TARGETS)

v4l2_test_app: v4l2_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ v4l2_test_app.c $(LDFLAGS)

alsa_test_app: alsa_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ alsa_test_app.c $(LDFLAGS)

dmabuf_p2p_test_app: dmabuf_p2p_test_app.c qpcie_control.h
	$(CC) $(CFLAGS) -o $@ dmabuf_p2p_test_app.c $(LDFLAGS)

clean:
	rm -f $(TARGETS) *.o *.yuv *.pcm *.raw

.PHONY: all clean
