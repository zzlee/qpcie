// SPDX-License-Identifier: GPL-2.0-only
// Native userspace API model only; not evidence of a working kernel or DMA.
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static void *maps[8];
static unsigned nmap, np, bytes[2], count, exports, closes, unmapped;
static int multi;
static int fault(const char *s)
{
    const char *f = getenv("CAPTURE_MODEL_FAULT");
    return f && !strcmp(s, f);
}
int __wrap_open(const char *p, int flags, ...)
{
    assert(!strcmp(p, "/dev/v4l2-model")); (void)flags;
    multi = getenv("CAPTURE_MODEL_MPLANE") != NULL;
    return 42;
}
int __wrap_close(int fd)
{
    assert(fd == 42 || (fd >= 100 && fd < 108));
    if (fd >= 100) closes++;
    return 0;
}
void *__wrap_mmap(void *a, size_t len, int prot, int flags, int fd, off_t off)
{
    (void)a; (void)prot; (void)flags; (void)off; assert(fd == 42 && nmap < 8);
    maps[nmap] = malloc(len); assert(maps[nmap]); return maps[nmap++];
}
int __wrap_munmap(void *p, size_t len)
{
    (void)len;
    for (unsigned i = 0; i < nmap; i++) if (maps[i] == p) {
        free(p); maps[i] = NULL; unmapped++; return 0;
    }
    assert(!"unknown mapping"); return -1;
}
int __wrap_poll(struct pollfd *p, nfds_t n, int timeout)
{
    assert(n == 1 && p->fd == 42 && timeout > 0);
    if (fault("timeout")) return 0;
    p->revents = POLLIN; return 1;
}
int __wrap_ioctl(int fd, unsigned long cmd, ...)
{
    assert(fd == 42);
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
    if (cmd == VIDIOC_QUERYCAP) {
        struct v4l2_capability *c = arg;
        c->capabilities = V4L2_CAP_DEVICE_CAPS;
        c->device_caps = V4L2_CAP_STREAMING | (multi ? V4L2_CAP_VIDEO_CAPTURE_MPLANE : V4L2_CAP_VIDEO_CAPTURE);
    } else if (cmd == VIDIOC_S_FMT) {
        struct v4l2_format *f = arg;
        unsigned width = multi ? f->fmt.pix_mp.width : f->fmt.pix.width;
        unsigned height = multi ? f->fmt.pix_mp.height : f->fmt.pix.height;
        uint32_t fmt = multi ? f->fmt.pix_mp.pixelformat : f->fmt.pix.pixelformat;
        np = fmt == V4L2_PIX_FMT_NV12M ? 2 : 1;
        bytes[0] = width * height * (np == 1 ? 3 : 2) / 2;
        bytes[1] = width * height / 2;
        if (multi) {
            f->fmt.pix_mp.num_planes = np;
            for (unsigned p = 0; p < np; p++) {
                f->fmt.pix_mp.plane_fmt[p].bytesperline = width;
                f->fmt.pix_mp.plane_fmt[p].sizeimage = bytes[p];
            }
            if (fault("format")) f->fmt.pix_mp.height++;
        } else {
            f->fmt.pix.bytesperline = width; f->fmt.pix.sizeimage = bytes[0];
            if (fault("format")) f->fmt.pix.height++;
        }
    } else if (cmd == VIDIOC_REQBUFS) {
        struct v4l2_requestbuffers *r = arg;
        if (!r->count) { assert(closes == exports && unmapped == nmap); }
    } else if (cmd == VIDIOC_QUERYBUF) {
        struct v4l2_buffer *b = arg;
        if (multi) for (unsigned p = 0; p < np; p++) b->m.planes[p].length = bytes[p];
        else b->length = bytes[0];
    } else if (cmd == VIDIOC_EXPBUF) {
        struct v4l2_exportbuffer *e = arg;
        if (fault("export")) { errno = ENOTTY; return -1; }
        e->fd = 100 + exports++;
    } else if (cmd == VIDIOC_STREAMON || cmd == VIDIOC_QBUF) {
        return 0;
    } else if (cmd == VIDIOC_DQBUF) {
        struct v4l2_buffer *b = arg;
        b->index = count % 4; b->sequence = count;
        b->flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
        if (getenv("CAPTURE_MODEL_SOE")) b->flags |= V4L2_BUF_FLAG_TSTAMP_SRC_SOE;
        unsigned us = count * 16667;
        b->timestamp.tv_sec = 100 + us / 1000000; b->timestamp.tv_usec = us % 1000000;
        if (fault("sequence") && count) b->sequence++;
        if (fault("timestamp") && count) b->timestamp.tv_usec = 0;
        if (fault("source")) b->flags |= 0x20000;
        if (fault("error")) b->flags |= V4L2_BUF_FLAG_ERROR;
        for (unsigned p = 0; p < np; p++) {
            if (multi) b->m.planes[p].bytesused = bytes[p] - fault("short");
            else b->bytesused = bytes[0] - fault("short");
            memset(maps[b->index * np + p], (int)(16 + count + p), bytes[p]);
        }
        count++;
    } else if (cmd == VIDIOC_STREAMOFF) {
        if (fault("streamoff")) { errno = EIO; return -1; }
    } else {
        assert(!"unexpected ioctl");
    }
    return 0;
}
