// SPDX-License-Identifier: GPL-2.0-only
// Standard PS V4L2 capture/EXPBUF verifier. No PCIe-private controls or MMIO.
// Configure the media graph first. EOF timestamps are never relabelled SOF.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define NBUF 4
#define NPLANE 2
struct plane { void *addr; size_t length; int dmafd; };
static volatile sig_atomic_t interrupted;
static void on_signal(int sig) { (void)sig; interrupted = 1; }
static int ctl(int fd, unsigned long cmd, void *p)
{
    int r;
    do { r = ioctl(fd, cmd, p); } while (r < 0 && errno == EINTR && !interrupted);
    return r;
}
static int number(const char *s, unsigned low, unsigned high, unsigned *v)
{
    char *end; errno = 0;
    unsigned long n = strtoul(s, &end, 10);
    if (errno || !*s || *end || n < low || n > high) return -1;
    *v = (unsigned)n; return 0;
}
static uint64_t timestamp_ns(const struct timeval *t)
{
    if (t->tv_sec < 0 || t->tv_usec < 0 || t->tv_usec >= 1000000) return 0;
    return (uint64_t)t->tv_sec * 1000000000ULL + (uint64_t)t->tv_usec * 1000;
}
static uint32_t fingerprint(const unsigned char *p, size_t n)
{
    // Only after STREAMOFF, never spend a full-frame checksum in the DQ loop.
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
static void usage(const char *name)
{
    fprintf(stderr, "Usage: %s DEVICE NV12|NV12M WIDTH HEIGHT FRAMES [DUMP]\n"
            "Media graph must already be configured. Exports every MMAP plane as DMA-BUF;\n"
            "checks all buffers, sequence and monotonic timestamps. Saves final frame\n"
            "after STREAMOFF. Does not claim SOF timestamp or VCU import validation.\n", name);
}
int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--help")) { usage(argv[0]); return 0; }
    if (argc < 6 || argc > 7) { usage(argv[0]); return 2; }
    unsigned width, height, frames;
    if (number(argv[3], 64, 4096, &width) || number(argv[4], 64, 2160, &height) ||
        number(argv[5], 2, 100000, &frames) || width % 16 || height % 2) {
        fprintf(stderr, "Invalid geometry/count\n"); return 2;
    }
    uint32_t fourcc;
    unsigned np;
    if (!strcmp(argv[2], "NV12")) { fourcc = V4L2_PIX_FMT_NV12; np = 1; }
    else if (!strcmp(argv[2], "NV12M")) { fourcc = V4L2_PIX_FMT_NV12M; np = 2; }
    else { usage(argv[0]); return 2; }
    struct sigaction sa = { .sa_handler = on_signal };
    sigemptyset(&sa.sa_mask); sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL);
    int fd = open(argv[1], O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { perror("open capture"); return 1; }
    struct plane buffers[NBUF][NPLANE];
    memset(buffers, 0, sizeof(buffers));
    for (unsigned i = 0; i < NBUF; i++)
        for (unsigned p = 0; p < NPLANE; p++) buffers[i][p].dmafd = -1;
    unsigned completed = 0, exports = 0;
    unsigned char *snapshot[NPLANE] = {0};
    size_t snapshot_size[NPLANE] = {0};
    uint32_t sizeimage[NPLANE] = {0}, stride[NPLANE] = {0};
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    int streaming = 0, allocated = 0, result = 1;
    uint32_t last_seq = 0, source_flags = 0;
    uint64_t first_ts = 0, last_ts = 0, bytes = 0;
    struct v4l2_capability cap = {0};
    if (ctl(fd, VIDIOC_QUERYCAP, &cap)) { perror("QUERYCAP"); goto cleanup; }
    uint32_t caps = cap.capabilities & V4L2_CAP_DEVICE_CAPS ? cap.device_caps : cap.capabilities;
    if (!(caps & V4L2_CAP_STREAMING)) { fprintf(stderr, "Not streaming capture\n"); goto cleanup; }
    if (caps & V4L2_CAP_VIDEO_CAPTURE_MPLANE) type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    else if (!(caps & V4L2_CAP_VIDEO_CAPTURE) || np != 1) {
        fprintf(stderr, "Unsupported capture type/plane count\n"); goto cleanup;
    }
    int multi = type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    struct v4l2_format fmt = {.type = type};
    if (multi) {
        fmt.fmt.pix_mp.width = width; fmt.fmt.pix_mp.height = height;
        fmt.fmt.pix_mp.pixelformat = fourcc; fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
        fmt.fmt.pix_mp.num_planes = np;
    } else {
        fmt.fmt.pix.width = width; fmt.fmt.pix.height = height;
        fmt.fmt.pix.pixelformat = fourcc; fmt.fmt.pix.field = V4L2_FIELD_NONE;
    }
    if (ctl(fd, VIDIOC_S_FMT, &fmt)) { perror("S_FMT (configure media graph first)"); goto cleanup; }
    if ((multi && (fmt.fmt.pix_mp.width != width || fmt.fmt.pix_mp.height != height ||
                   fmt.fmt.pix_mp.pixelformat != fourcc || fmt.fmt.pix_mp.num_planes != np ||
                   fmt.fmt.pix_mp.field != V4L2_FIELD_NONE)) ||
        (!multi && (fmt.fmt.pix.width != width || fmt.fmt.pix.height != height ||
                    fmt.fmt.pix.pixelformat != fourcc || fmt.fmt.pix.field != V4L2_FIELD_NONE))) {
        fprintf(stderr, "Unexpected negotiated geometry/format/field\n"); goto cleanup;
    }
    for (unsigned p = 0; p < np; p++) {
        stride[p] = multi ? fmt.fmt.pix_mp.plane_fmt[p].bytesperline : fmt.fmt.pix.bytesperline;
        sizeimage[p] = multi ? fmt.fmt.pix_mp.plane_fmt[p].sizeimage : fmt.fmt.pix.sizeimage;
        uint64_t minimum = (uint64_t)stride[p] * (p ? height / 2 : height);
        if (np == 1) minimum += minimum / 2;
        if (stride[p] < width || minimum > sizeimage[p]) {
            fprintf(stderr, "Invalid plane layout %u\n", p); goto cleanup;
        }
        printf("PLANE index=%u stride=%u sizeimage=%u\n", p, stride[p], sizeimage[p]);
    }
    struct v4l2_requestbuffers req = {.count = NBUF, .type = type, .memory = V4L2_MEMORY_MMAP};
    if (ctl(fd, VIDIOC_REQBUFS, &req)) { perror("REQBUFS"); goto cleanup; }
    allocated = 1;
    if (req.count < NBUF) { fprintf(stderr, "Need at least %u buffers\n", NBUF); goto cleanup; }
    for (unsigned i = 0; i < NBUF; i++) {
        struct v4l2_plane planes[NPLANE] = {{0}};
        struct v4l2_buffer b = {.type = type, .memory = V4L2_MEMORY_MMAP, .index = i};
        if (multi) { b.length = np; b.m.planes = planes; }
        if (ctl(fd, VIDIOC_QUERYBUF, &b)) { perror("QUERYBUF"); goto cleanup; }
        if (multi && b.length != np) { fprintf(stderr, "QUERYBUF plane count\n"); goto cleanup; }
        for (unsigned p = 0; p < np; p++) {
            struct plane *bp = &buffers[i][p];
            bp->length = multi ? planes[p].length : b.length;
            off_t offset = multi ? planes[p].m.mem_offset : b.m.offset;
            if (bp->length < sizeimage[p]) { fprintf(stderr, "Short allocated plane\n"); goto cleanup; }
            bp->addr = mmap(NULL, bp->length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, offset);
            if (bp->addr == MAP_FAILED) { bp->addr = NULL; perror("mmap"); goto cleanup; }
            memset(bp->addr, 0xa5, bp->length);
            struct v4l2_exportbuffer eb = {.type = type, .index = i, .plane = p, .flags = O_CLOEXEC | O_RDWR};
            if (ctl(fd, VIDIOC_EXPBUF, &eb)) { perror("EXPBUF"); goto cleanup; }
            if (eb.fd < 0) { fprintf(stderr, "Invalid exported DMA-BUF fd\n"); goto cleanup; }
            bp->dmafd = eb.fd; exports++;
        }
        if (ctl(fd, VIDIOC_QBUF, &b)) { perror("QBUF"); goto cleanup; }
    }
    if (ctl(fd, VIDIOC_STREAMON, &type)) { perror("STREAMON"); goto cleanup; }
    streaming = 1;
    while (completed < frames && !interrupted) {
        struct pollfd f = {.fd = fd, .events = POLLIN};
        int rc = poll(&f, 1, 5000);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0 || (f.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            fprintf(stderr, "Capture poll error/5s timeout\n"); goto cleanup;
        }
        struct v4l2_plane planes[NPLANE] = {{0}};
        struct v4l2_buffer b = {.type = type, .memory = V4L2_MEMORY_MMAP};
        if (multi) { b.length = np; b.m.planes = planes; }
        if (ctl(fd, VIDIOC_DQBUF, &b)) { if (errno == EAGAIN) continue; perror("DQBUF"); goto cleanup; }
        uint64_t ts = timestamp_ns(&b.timestamp);
        uint32_t src = b.flags & V4L2_BUF_FLAG_TSTAMP_SRC_MASK;
        if (b.index >= NBUF || (multi && b.length != np) || (b.flags & V4L2_BUF_FLAG_ERROR) ||
            (b.flags & V4L2_BUF_FLAG_TIMESTAMP_MASK) != V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC ||
            !ts || (src != 0 && src != V4L2_BUF_FLAG_TSTAMP_SRC_SOE) ||
            (completed && (b.sequence != last_seq + 1u || ts <= last_ts || src != source_flags))) {
            fprintf(stderr, "Invalid buffer/sequence/timestamp/error flag\n"); goto cleanup;
        }
        if (!completed) { first_ts = ts; source_flags = src; }
        last_ts = ts; last_seq = b.sequence;
        for (unsigned p = 0; p < np; p++) {
            size_t used = multi ? planes[p].bytesused : b.bytesused;
            size_t offset = multi ? planes[p].data_offset : 0;
            struct plane *bp = &buffers[b.index][p];
            if (used > bp->length || offset > used || used - offset != sizeimage[p]) {
                fprintf(stderr, "Invalid bytesused/offset plane %u\n", p); goto cleanup;
            }
            bytes += used - offset;
            if (completed == frames - 1) {
                snapshot_size[p] = used - offset;
                snapshot[p] = malloc(snapshot_size[p]);
                if (!snapshot[p]) { perror("snapshot allocation"); goto cleanup; }
                memcpy(snapshot[p], (unsigned char *)bp->addr + offset, snapshot_size[p]);
            }
        }
        fprintf(stderr, "FRAME n=%u sequence=%u timestamp_ns=%llu flags=0x%x\n",
                completed, b.sequence, (unsigned long long)ts, b.flags);
        completed++;
        if (completed < frames && ctl(fd, VIDIOC_QBUF, &b)) { perror("requeue"); goto cleanup; }
    }
    if (interrupted) { result = 130; goto cleanup; }
    result = 0;
cleanup:
    // A failed STREAMOFF must never be followed by a successful PASS summary.
    if (streaming && ctl(fd, VIDIOC_STREAMOFF, &type)) { perror("STREAMOFF"); result = 1; }
    for (unsigned i = 0; i < NBUF; i++) for (unsigned p = 0; p < NPLANE; p++) {
        if (buffers[i][p].dmafd >= 0) close(buffers[i][p].dmafd);
        if (buffers[i][p].addr) munmap(buffers[i][p].addr, buffers[i][p].length);
    }
    if (allocated) {
        struct v4l2_requestbuffers release = {.count = 0, .type = type, .memory = V4L2_MEMORY_MMAP};
        if (ctl(fd, VIDIOC_REQBUFS, &release)) { perror("REQBUFS release"); result = 1; }
    }
    close(fd);
    if (!result && argc == 7) {
        FILE *dump = fopen(argv[6], "wb");
        if (!dump) { perror("dump open"); result = 1; }
        else {
            for (unsigned p = 0; p < np; p++)
                if (fwrite(snapshot[p], 1, snapshot_size[p], dump) != snapshot_size[p]) result = 1;
            if (fclose(dump)) result = 1;
            if (result) fprintf(stderr, "Dump write/close failed\n");
        }
    }
    if (!result) {
        for (unsigned p = 0; p < np; p++)
            printf("SNAPSHOT plane=%u bytes=%zu fnv1a32=%08x\n", p, snapshot_size[p], fingerprint(snapshot[p], snapshot_size[p]));
        printf("CAPTURE_PASS frames=%u bytes=%llu timestamp_fps=%.6f dmabuf_exports=%u timestamp_source=%s vcu_import_verified=false\n",
               completed, (unsigned long long)bytes, (completed - 1) * 1e9 / (double)(last_ts - first_ts), exports,
               source_flags == V4L2_BUF_FLAG_TSTAMP_SRC_SOE ? "SOE" : "EOF");
    }
    for (unsigned p = 0; p < NPLANE; p++) free(snapshot[p]);
    return result;
}
