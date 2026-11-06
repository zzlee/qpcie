/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef SC7F0_FRAME_TAP_H
#define SC7F0_FRAME_TAP_H
#include <linux/err.h>
#include <linux/kconfig.h>
struct device;
struct vb2_v4l2_buffer;
struct sc7f0_frame_tap;
#if IS_ENABLED(CONFIG_VIDEO_SC7F0_FRAME_TAP) || defined(SC7F0_TAP_IMPLEMENTATION)
struct sc7f0_frame_tap *sc7f0_tap_get(struct device *dev);
int sc7f0_tap_credit(struct sc7f0_frame_tap *tap, unsigned int n);
int sc7f0_tap_prepare(struct sc7f0_frame_tap *tap);
int sc7f0_tap_finish(struct sc7f0_frame_tap *tap, struct vb2_v4l2_buffer *buf);
/* Fail-stop: may wait indefinitely if hardware cannot retire an owned frame.
 * Call BEFORE downstream stream-off, DMA reset/terminate or VB2 buffer return. */
void sc7f0_tap_quiesce(struct sc7f0_frame_tap *tap);
void sc7f0_tap_abort(struct sc7f0_frame_tap *tap);
#else
static inline struct sc7f0_frame_tap *sc7f0_tap_get(struct device *dev) { return NULL; }
static inline int sc7f0_tap_credit(struct sc7f0_frame_tap *t, unsigned int n) { return 0; }
static inline int sc7f0_tap_prepare(struct sc7f0_frame_tap *t) { return 0; }
static inline int sc7f0_tap_finish(struct sc7f0_frame_tap *t, struct vb2_v4l2_buffer *b) { return 0; }
static inline void sc7f0_tap_quiesce(struct sc7f0_frame_tap *t) {}
static inline void sc7f0_tap_abort(struct sc7f0_frame_tap *t) {}
#endif
#endif
