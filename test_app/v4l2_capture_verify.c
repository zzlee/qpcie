// SPDX-License-Identifier: GPL-2.0-or-later
// Bounded MMAP multi-planar capture. Checks every DQBUF and dumps one full frame.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BUFFERS 4
#define PLANES 2
#define CID_PACER (V4L2_CID_USER_BASE + 0x1000)
#define CID_SOURCE (V4L2_CID_USER_BASE + 0x1004)

static int xioctl(int fd, unsigned long cmd, void *arg)
{
    int rc;
    do { rc = ioctl(fd, cmd, arg); } while (rc < 0 && errno == EINTR);
    return rc;
}

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    // DEVICE FORMAT(RGB/NV12/NV16) SOURCE(hdmi/tpg) FRAMES [DUMP]
    if (argc < 5 || argc > 6) {
        fprintf(stderr, "Usage: %s DEVICE RGB|NV12|NV16 hdmi|tpg FRAMES [DUMP]\n", argv[0]);
        return 2;
    }
    uint32_t fourcc;
    unsigned np;
    if (!strcmp(argv[2], "RGB")) { fourcc = V4L2_PIX_FMT_RGB24; np = 1; }
    else if (!strcmp(argv[2], "NV12")) { fourcc = V4L2_PIX_FMT_NV12M; np = 2; }
    else if (!strcmp(argv[2], "NV16")) { fourcc = V4L2_PIX_FMT_NV16M; np = 2; }
    else return 2;
    int source;
    if (!strcmp(argv[3], "hdmi")) source = 2;
    else if (!strcmp(argv[3], "tpg")) source = 1;
    else return 2;
    char *end;
    long frames = strtol(argv[4], &end, 10);
    if (*end || frames < 1 || frames > 100000) return 2;
    int fd = open(argv[1], O_RDWR | O_NONBLOCK);
    if (fd < 0) { perror("open"); return 1; }
    void *memory[BUFFERS][PLANES] = {{0}};
    size_t length[BUFFERS][PLANES] = {{0}};
    int streaming = 0, result = 1;
    unsigned completed = 0;
    uint64_t total_bytes = 0;
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    struct v4l2_control ctrl = {.id = CID_SOURCE, .value = source};
    if (xioctl(fd, VIDIOC_S_CTRL, &ctrl)) { perror("source"); goto cleanup; }
    ctrl.id = CID_PACER; ctrl.value = source == 1;
    if (xioctl(fd, VIDIOC_S_CTRL, &ctrl)) { perror("pacer"); goto cleanup; }
    struct v4l2_format fmt = {.type = type};
    fmt.fmt.pix_mp.width = 3840;
    fmt.fmt.pix_mp.height = 2160;
    fmt.fmt.pix_mp.pixelformat = fourcc;
    fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt)) { perror("S_FMT"); goto cleanup; }
    if (fmt.fmt.pix_mp.pixelformat != fourcc || fmt.fmt.pix_mp.num_planes != np ||
        fmt.fmt.pix_mp.width != 3840 || fmt.fmt.pix_mp.height != 2160) {
        fprintf(stderr, "Unexpected negotiated format\n"); goto cleanup;
    }
    for (unsigned p = 0; p < np; ++p) {
        unsigned rows = p && fourcc == V4L2_PIX_FMT_NV12M ? 1080 : 2160;
        unsigned stride = fourcc == V4L2_PIX_FMT_RGB24 ? 11520 : 3840;
        if (fmt.fmt.pix_mp.plane_fmt[p].bytesperline != stride ||
            fmt.fmt.pix_mp.plane_fmt[p].sizeimage != stride * rows) {
            fprintf(stderr, "Incorrect plane %u stride/size\n", p); goto cleanup;
        }
        printf("Plane %u stride=%u size=%u\n", p, stride, stride * rows);
    }
    struct v4l2_requestbuffers request = {.count = BUFFERS, .type = type, .memory = V4L2_MEMORY_MMAP};
    if (xioctl(fd, VIDIOC_REQBUFS, &request) || request.count < BUFFERS) { perror("REQBUFS"); goto cleanup; }
    for (unsigned i = 0; i < BUFFERS; ++i) {
        struct v4l2_plane planes[PLANES] = {{0}};
        struct v4l2_buffer buf = {.index = i, .type = type, .memory = V4L2_MEMORY_MMAP,
                                  .length = np, .m.planes = planes};
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf)) { perror("QUERYBUF"); goto cleanup; }
        for (unsigned p = 0; p < np; ++p) {
            length[i][p] = planes[p].length;
            memory[i][p] = mmap(NULL, planes[p].length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, planes[p].m.mem_offset);
            if (memory[i][p] == MAP_FAILED) { memory[i][p] = NULL; perror("mmap"); goto cleanup; }
            memset(memory[i][p], 0xa5, planes[p].length);
        }
        if (xioctl(fd, VIDIOC_QBUF, &buf)) { perror("QBUF"); goto cleanup; }
    }
    double start = now();
    if (xioctl(fd, VIDIOC_STREAMON, &type)) { perror("STREAMON"); goto cleanup; }
    streaming = 1;
    uint32_t last_sequence = 0;
    while (completed < (unsigned)frames) {
        struct pollfd pollfd = {.fd = fd, .events = POLLIN};
        int rc;
        do { rc = poll(&pollfd, 1, 5000); } while (rc < 0 && errno == EINTR);
        if (rc <= 0 || (pollfd.revents & (POLLERR | POLLNVAL))) { fprintf(stderr, "Capture poll failed/timeout\n"); goto cleanup; }
        struct v4l2_plane planes[PLANES] = {{0}};
        struct v4l2_buffer buf = {.type = type, .memory = V4L2_MEMORY_MMAP, .length = np, .m.planes = planes};
        if (xioctl(fd, VIDIOC_DQBUF, &buf)) { if (errno == EAGAIN) continue; perror("DQBUF"); goto cleanup; }
        if (buf.index >= BUFFERS || buf.length != np || (buf.flags & V4L2_BUF_FLAG_ERROR) ||
            (completed && buf.sequence != last_sequence + 1)) {
            fprintf(stderr, "Invalid buffer/sequence/error flag\n"); goto cleanup;
        }
        last_sequence = buf.sequence;
        FILE *dump = NULL;
        if (argc == 6 && completed == (unsigned)frames - 1) {
            dump = fopen(argv[5], "wb");
            if (!dump) { perror("dump"); goto cleanup; }
        }
        for (unsigned p = 0; p < np; ++p) {
            unsigned size = fmt.fmt.pix_mp.plane_fmt[p].sizeimage;
            if (planes[p].bytesused != size || planes[p].data_offset || size > length[buf.index][p]) {
                fprintf(stderr, "Invalid plane %u bytesused=%u expected=%u offset=%u\n", p, planes[p].bytesused, size, planes[p].data_offset);
                if (dump) fclose(dump);
                goto cleanup;
            }
            total_bytes += size;
            if (dump && fwrite(memory[buf.index][p], 1, size, dump) != size) { perror("dump write"); fclose(dump); goto cleanup; }
        }
        if (dump && fclose(dump)) { perror("dump close"); goto cleanup; }
        ++completed;
        if (xioctl(fd, VIDIOC_QBUF, &buf)) { perror("requeue"); goto cleanup; }
    }
    double elapsed = now() - start;
    printf("PASS: %s %s frames=%u elapsed=%.3fs fps=%.3f payload=%.3f GB/s bytes=%llu\n",
           argv[2], argv[3], completed, elapsed, completed / elapsed,
           total_bytes / elapsed / 1e9, (unsigned long long)total_bytes);
    result = 0;
cleanup:
    if (streaming && xioctl(fd, VIDIOC_STREAMOFF, &type)) { perror("STREAMOFF"); result = 1; }
    for (unsigned i = 0; i < BUFFERS; ++i)
        for (unsigned p = 0; p < np; ++p)
            if (memory[i][p]) munmap(memory[i][p], length[i][p]);
    close(fd);
    return result;
}
