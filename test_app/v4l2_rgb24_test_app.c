// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * QPCIe V4L2 RGB24 capture test application.
 * Supports 1920x1080, 3840x2160, and 4096x2160 resolutions in packed RGB24 (3 bytes/pixel).
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <linux/videodev2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_DEVICE          "/dev/video0"
#define DEFAULT_WIDTH           1920U
#define DEFAULT_HEIGHT          1080U
#define DEFAULT_BUFFERS         8U
#define DEFAULT_FRAMES          120U
#define DEFAULT_BENCHMARK_FRAMES 600U
#define BENCHMARK_WARMUP_FRAMES 8U
#define MAX_ERROR_FRAMES        10U

#define V4L2_CID_QPCIE_PACER_ENABLE (V4L2_CID_USER_BASE + 0x1000)
#define V4L2_CID_QPCIE_TPG_MOTION_SPEED (V4L2_CID_USER_BASE + 0x1001)
#define V4L2_CID_QPCIE_FRAME_DROP_COUNT (V4L2_CID_USER_BASE + 0x1002)

struct plane_map {
    void *addr;
    size_t length;
};

struct mapped_buffer {
    struct plane_map plane[1];
};

static int xioctl(int fd, unsigned long request, void *arg)
{
    int ret;
    do {
        ret = ioctl(fd, request, arg);
    } while (ret < 0 && errno == EINTR);
    return ret;
}

static double monotonic_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static uint64_t fnv1a64(const uint8_t *data, size_t length)
{
    uint64_t hash = UINT64_C(1469598103934665603);
    const uint64_t *p64 = (const uint64_t *)data;
    size_t n64 = length / 8;
    size_t i;

    for (i = 0; i < n64; i++) {
        hash ^= p64[i];
        hash *= UINT64_C(1099511628211);
    }
    for (i = n64 * 8; i < length; i++) {
        hash ^= data[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static int tpg_pattern_menu_value(int pattern)
{
    switch (pattern) {
    case 0: return 0;  /* Pass-through maps to Color Bars in the driver. */
    case 1: return 1;  /* Horizontal Ramp */
    case 2: return 2;  /* Vertical Ramp */
    case 9: return 3;  /* Xilinx Color Bars */
    case 10: return 4; /* Xilinx Zone Plate */
    default: return -1;
    }
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "  -d <dev>     Video device (default: %s)\n"
            "  -w <width>   Frame width: 1920, 3840, or 4096 (default: %u)\n"
            "  -h <height>  Frame height: 1080 or 2160 (default: %u)\n"
            "  -f <frames>  Frame count (default: %u, benchmark: %u)\n"
            "  -n <bufs>    MMAP buffer count 2..8 (default: %u)\n"
            "  -p <pattern> TPG pattern: 0, 1, 2, 9 (color bars), or 10 (zone plate)\n"
            "  -b           Run uncapped DMA benchmark\n"
            "  -S           Use a static ramp and require every frame to match frame 0\n"
            "  -o <file>    Dump raw RGB24 frames to file\n"
            "  -P           Probe supported formats and exit\n"
            "  -H           Show this help\n",
            prog, DEFAULT_DEVICE, DEFAULT_WIDTH, DEFAULT_HEIGHT,
            DEFAULT_FRAMES, DEFAULT_BENCHMARK_FRAMES, DEFAULT_BUFFERS);
}

int main(int argc, char **argv)
{
    const char *device = DEFAULT_DEVICE;
    const char *output_name = NULL;
    FILE *output = NULL;
    uint32_t width = DEFAULT_WIDTH;
    uint32_t height = DEFAULT_HEIGHT;
    uint32_t num_buffers = DEFAULT_BUFFERS;
    uint32_t frame_target = DEFAULT_FRAMES;
    int frames_set = 0;
    int pattern = 9;
    int benchmark_mode = 0;
    int static_verify = 0;
    int probe_only = 0;
    int fd = -1;
    int rc = EXIT_FAILURE;
    int opt;
    uint32_t stride;
    uint64_t frame_bytes;
    struct mapped_buffer *buffers = NULL;
    struct v4l2_capability cap;
    struct v4l2_format fmt;
    struct v4l2_requestbuffers req;
    struct v4l2_control ctrl;
    uint32_t captured = 0;
    uint32_t seq_errors = 0;
    uint32_t expected_sequence = 0;
    uint32_t frame_drop_start = 0;
    uint32_t frame_drop_end = 0;
    uint64_t reference_hash = 0;
    int have_reference_hash = 0;
    int sequence_violation = 0;
    double start_ms = 0.0, end_ms = 0.0;
    double bench_start_ms = 0.0;
    uint32_t bench_frames = 0;
    uint32_t i;

    while ((opt = getopt(argc, argv, "d:w:h:f:n:p:bSo:PH")) != -1) {
        switch (opt) {
        case 'd': device = optarg; break;
        case 'w': width = strtoul(optarg, NULL, 0); break;
        case 'h': height = strtoul(optarg, NULL, 0); break;
        case 'f': frame_target = strtoul(optarg, NULL, 0); frames_set = 1; break;
        case 'n': num_buffers = strtoul(optarg, NULL, 0); break;
        case 'p': pattern = strtol(optarg, NULL, 0); break;
        case 'b': benchmark_mode = 1; break;
        case 'S': static_verify = 1; break;
        case 'o': output_name = optarg; break;
        case 'P': probe_only = 1; break;
        case 'H': usage(argv[0]); return EXIT_SUCCESS;
        default: usage(argv[0]); return EXIT_FAILURE;
        }
    }

    if (benchmark_mode && !frames_set)
        frame_target = DEFAULT_BENCHMARK_FRAMES;

    if (!((width == 1920 && height == 1080) ||
          (width == 3840 && height == 2160) ||
          (width == 4096 && height == 2160))) {
        fprintf(stderr, "[ERROR] Only 1920x1080, 3840x2160, and 4096x2160 are supported\n");
        return EXIT_FAILURE;
    }

    /* 128-byte stride alignment */
    stride = (width * 3 + 127) & ~127;
    frame_bytes = (uint64_t)stride * height;

    printf("=================================================================\n"
           " QPCIe Video TPG -> RGB24 Capture Test Application\n"
           " Device: %s, Resolution: %ux%u, Stride: %u Bytes\n"
           " Format: V4L2_PIX_FMT_RGB24 (Packed 24-bit RGB, 1 Plane)\n"
           " Frames: %u, Frame Size: %" PRIu64 " Bytes (%.2f MiB)\n"
           " Mode: %s%s\n"
           "=================================================================\n",
           device, width, height, stride, frame_target,
           frame_bytes, (double)frame_bytes / (1024.0 * 1024.0),
           benchmark_mode ? "Uncapped DMA Benchmark" : "Hardware Paced (60 FPS)",
           static_verify ? ", Static-frame integrity verification" : "");

    fd = open(device, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        perror("open video device");
        return EXIT_FAILURE;
    }

    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        perror("VIDIOC_QUERYCAP");
        goto out;
    }
    printf("[PASS] Driver: %s, Card: %s, Bus: %s\n",
           cap.driver, cap.card, cap.bus_info);

    if (probe_only) {
        struct v4l2_fmtdesc fmtdesc;
        memset(&fmtdesc, 0, sizeof(fmtdesc));
        fmtdesc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        printf("--- Enumerating Supported Formats ---\n");
        while (xioctl(fd, VIDIOC_ENUM_FMT, &fmtdesc) == 0) {
            printf("  [%u] FourCC: %.4s (%s)\n",
                   fmtdesc.index, (char *)&fmtdesc.pixelformat, fmtdesc.description);
            fmtdesc.index++;
        }
        rc = EXIT_SUCCESS;
        goto out;
    }

    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    fmt.fmt.pix_mp.width = width;
    fmt.fmt.pix_mp.height = height;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_RGB24;
    fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT RGB24");
        goto out;
    }

    if (fmt.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_RGB24 ||
        fmt.fmt.pix_mp.num_planes != 1) {
        fprintf(stderr, "[FAIL] Driver did not accept V4L2_PIX_FMT_RGB24 / 1-plane\n");
        goto out;
    }
    printf("[PASS] Configured V4L2_PIX_FMT_RGB24: %ux%u, Plane 0 Size: %u, BytesPerLine: %u\n",
           fmt.fmt.pix_mp.width, fmt.fmt.pix_mp.height,
           fmt.fmt.pix_mp.plane_fmt[0].sizeimage,
           fmt.fmt.pix_mp.plane_fmt[0].bytesperline);

    /* Color Bars retain a dynamic phase in this 4-PPC v_tpg configuration.
     * Static verification therefore uses a deterministic ramp, exercising the
     * same RGB24 capture path without treating intended pattern motion as DMA
     * corruption. */
    if (static_verify && pattern != 1 && pattern != 2) {
        printf("[INFO] Static verification uses TPG Horizontal Ramp (pattern 1)\n");
        pattern = 1;
    }

    /* The V4L2 menu has compact values while the TPG uses Xilinx IDs. */
    pattern = tpg_pattern_menu_value(pattern);
    if (pattern < 0) {
        fprintf(stderr, "[ERROR] Unsupported TPG pattern; use 0, 1, 2, 9, or 10\n");
        goto out;
    }

    /* Set TPG pattern */
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = V4L2_CID_TEST_PATTERN;
    ctrl.value = pattern;
    if (xioctl(fd, VIDIOC_S_CTRL, &ctrl) < 0) {
        perror("VIDIOC_S_CTRL pattern");
    } else {
        printf("[PASS] Video TPG pattern configured\n");
    }

    if (static_verify) {
        memset(&ctrl, 0, sizeof(ctrl));
        ctrl.id = V4L2_CID_QPCIE_TPG_MOTION_SPEED;
        ctrl.value = 0;
        if (xioctl(fd, VIDIOC_S_CTRL, &ctrl) < 0) {
            perror("VIDIOC_S_CTRL motion speed");
            goto out;
        }
    }

    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = V4L2_CID_QPCIE_FRAME_DROP_COUNT;
    if (xioctl(fd, VIDIOC_G_CTRL, &ctrl) < 0) {
        perror("VIDIOC_G_CTRL frame drop count");
        goto out;
    }
    frame_drop_start = ctrl.value;

    /* Pacer control */
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = V4L2_CID_QPCIE_PACER_ENABLE;
    ctrl.value = benchmark_mode ? 0 : 1;
    if (xioctl(fd, VIDIOC_S_CTRL, &ctrl) < 0) {
        perror("VIDIOC_S_CTRL pacer");
    }

    /* REQBUFS */
    memset(&req, 0, sizeof(req));
    req.count = num_buffers;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2) {
        perror("VIDIOC_REQBUFS");
        goto out;
    }
    buffers = calloc(req.count, sizeof(*buffers));
    if (!buffers) goto out;

    for (i = 0; i < req.count; i++) {
        struct v4l2_buffer buf;
        struct v4l2_plane planes[1];
        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = req.type;
        buf.memory = req.memory;
        buf.index = i;
        buf.length = 1;
        buf.m.planes = planes;
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF");
            goto out;
        }
        buffers[i].plane[0].length = planes[0].length;
        buffers[i].plane[0].addr = mmap(NULL, planes[0].length,
                                       PROT_READ | PROT_WRITE,
                                       MAP_SHARED, fd,
                                       planes[0].m.mem_offset);
        if (buffers[i].plane[0].addr == MAP_FAILED) {
            perror("mmap");
            goto out;
        }
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF");
            goto out;
        }
    }
    printf("[PASS] Mapped and queued %u RGB24 buffers\n", req.count);

    if (output_name) {
        output = fopen(output_name, "wb");
        if (!output) {
            perror("open output file");
            goto out;
        }
        printf("[INFO] Dumping frames to %s\n", output_name);
    }

    {
        enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
            perror("VIDIOC_STREAMON");
            goto out;
        }
    }
    printf("[PASS] STREAMON: Starting Capture...\n");
    start_ms = monotonic_ms();

    while (captured < frame_target) {
        fd_set readfds;
        struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
        struct v4l2_buffer buf;
        struct v4l2_plane planes[1];
        int ready;

        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);
        ready = select(fd + 1, &readfds, NULL, NULL, &timeout);
        if (ready <= 0) {
            fprintf(stderr, "[FAIL] select() timeout on frame %u\n", captured);
            goto streamoff;
        }

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = 1;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            perror("VIDIOC_DQBUF");
            goto streamoff;
        }

        if (benchmark_mode && captured == BENCHMARK_WARMUP_FRAMES) {
            bench_start_ms = monotonic_ms();
            bench_frames = 0;
        }

        if (buf.flags & V4L2_BUF_FLAG_ERROR) {
            /* Publish was rejected / buffer returned in error state.  Never
             * count these as captured frames: with error-buffer recycling
             * they would inflate the measured FPS to CPU speed. */
            seq_errors++;
            if (seq_errors <= 5 || (seq_errors % 100) == 0)
                fprintf(stderr,
                        "[WARN] frame %u: ERROR-state buffer (index=%u seq=%u): hardware ring pathology\n",
                        captured, buf.index, buf.sequence);
            if (seq_errors >= MAX_ERROR_FRAMES) {
                fprintf(stderr, "[FAIL] too many ERROR-state frames (%u); aborting\n", seq_errors);
                rc = EXIT_FAILURE;
                goto streamoff;
            }
        } else {
            if (buf.sequence != expected_sequence) {
                fprintf(stderr,
                        "[FAIL] sequence jump at frame %u: got=%u expected=%u\n",
                        captured, buf.sequence, expected_sequence);
                sequence_violation = 1;
            }
            expected_sequence = buf.sequence + 1;

            if (static_verify || captured < 5 || (captured % 30 == 0)) {
                uint64_t hash = fnv1a64((const uint8_t *)buffers[buf.index].plane[0].addr,
                                        buffers[buf.index].plane[0].length);

                if (static_verify) {
                    if (!have_reference_hash) {
                        reference_hash = hash;
                        have_reference_hash = 1;
                    } else if (hash != reference_hash) {
                        fprintf(stderr,
                                "[FAIL] static-frame mismatch at frame %u: got=0x%016" PRIx64 " expected=0x%016" PRIx64 "\n",
                                captured, hash, reference_hash);
                        sequence_violation = 1;
                        rc = EXIT_FAILURE;
                        goto streamoff;
                    }
                }

                if (captured < 5 || (captured % 30 == 0)) {
                    const uint8_t *p = (const uint8_t *)buffers[buf.index].plane[0].addr;
                    printf("[Frame %4u] seq=%u, bytes=%u, R0=0x%02X G0=0x%02X B0=0x%02X, hash=0x%016" PRIx64 "\n",
                           captured, buf.sequence, planes[0].bytesused,
                           p[0], p[1], p[2], hash);
                }
            }

            if (output) {
                fwrite(buffers[buf.index].plane[0].addr, 1,
                       buffers[buf.index].plane[0].length, output);
            }

            captured++;
            if (benchmark_mode && captured > BENCHMARK_WARMUP_FRAMES)
                bench_frames++;
        }

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF requeue");
            goto streamoff;
        }
    }

    if (static_verify)
        printf("[PASS] Static-frame integrity: %u frame hashes match 0x%016" PRIx64 "\n",
               captured, reference_hash);

    end_ms = monotonic_ms();
    rc = EXIT_SUCCESS;

streamoff:
    {
        enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        xioctl(fd, VIDIOC_STREAMOFF, &type);
    }

    if (rc == EXIT_SUCCESS && captured > 0) {
        double elapsed_sec = (end_ms - start_ms) / 1000.0;
        double fps = captured / elapsed_sec;
        double total_mib = (double)captured * frame_bytes / (1024.0 * 1024.0);
        double mib_s = total_mib / elapsed_sec;

        printf("=================================================================\n"
               " Capture Summary:\n"
               "   Total Captured : %u frames\n"
               "   Elapsed Time   : %.3f seconds\n"
               "   Average FPS    : %.2f FPS\n"
               "   DMA Throughput : %.2f MiB/s (%.2f Gbps)\n"
               "=================================================================\n",
               captured, elapsed_sec, fps, mib_s, mib_s * 8.0 / 1024.0);

        if (benchmark_mode && bench_frames > 0) {
            double bench_sec = (end_ms - bench_start_ms) / 1000.0;
            double b_fps = bench_frames / bench_sec;
            double b_mib_s = ((double)bench_frames * frame_bytes / (1024.0 * 1024.0)) / bench_sec;
            printf(" Benchmark Steady-State:\n"
                   "   Frames         : %u\n"
                   "   Steady FPS     : %.2f FPS\n"
                   "   Throughput     : %.2f MiB/s (%.2f Gbps)\n"
                   "=================================================================\n",
                   bench_frames, b_fps, b_mib_s, b_mib_s * 8.0 / 1024.0);
        }
    }

    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = V4L2_CID_QPCIE_FRAME_DROP_COUNT;
    if (xioctl(fd, VIDIOC_G_CTRL, &ctrl) < 0) {
        perror("VIDIOC_G_CTRL frame drop count");
        rc = EXIT_FAILURE;
    } else {
        frame_drop_end = ctrl.value;
        printf(" Hardware Frame Drops : %u -> %u (delta=%u)\n",
               frame_drop_start, frame_drop_end,
               frame_drop_end - frame_drop_start);
        if (frame_drop_end != frame_drop_start) {
            fprintf(stderr, "[FAIL] hardware frame-drop counter increased\n");
            rc = EXIT_FAILURE;
        }
    }

    if (sequence_violation || seq_errors) {
        fprintf(stderr,
                "[FAIL] streaming integrity: %u sequence violation(s), %u ERROR-state frame(s)\n",
                sequence_violation, seq_errors);
        rc = EXIT_FAILURE;
    }

out:
    if (output) fclose(output);
    if (buffers) {
        for (i = 0; i < req.count; i++) {
            if (buffers[i].plane[0].addr)
                munmap(buffers[i].plane[0].addr, buffers[i].plane[0].length);
        }
        free(buffers);
    }
    if (fd >= 0) close(fd);
    return rc;
}
