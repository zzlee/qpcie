// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * QPCIe Stage-2 V4L2 tester: one 1920x1080@60 NV12M MMAP capture channel.
 * The FPGA source is Xilinx TPG YUV444; RTL performs only 2x2 chroma
 * subsampling and writes separate Y and UV planes through PCIe DMA.
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

#define DEFAULT_DEVICE  "/dev/video0"
#define DEFAULT_WIDTH   1920U
#define DEFAULT_HEIGHT  1080U
#define DEFAULT_BUFFERS 4U
#define DEFAULT_FRAMES           120U
#define DEFAULT_BENCHMARK_FRAMES 600U
#define BENCHMARK_WARMUP_FRAMES  8U
#define NV12_PLANES              2U
#define NV12_FRAME_BYTES         (DEFAULT_WIDTH * DEFAULT_HEIGHT * 3U / 2U)
#define NV12_MWR_PAYLOAD_BYTES   128U
#define NV12_MWR_PER_FRAME       (NV12_FRAME_BYTES / NV12_MWR_PAYLOAD_BYTES)

/* Must match the private control ID in driver/qpcie_driver.h. */
#define V4L2_CID_QPCIE_PACER_ENABLE (V4L2_CID_USER_BASE + 0x1000)

struct plane_map {
    void *addr;
    size_t length;
};

struct mapped_buffer {
    struct plane_map plane[NV12_PLANES];
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
    size_t i;
    for (i = 0; i < length; i++) {
        hash ^= data[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void byte_range(const uint8_t *data, size_t length,
                       uint8_t *minimum, uint8_t *maximum)
{
    size_t i;
    uint8_t lo = 255, hi = 0;
    for (i = 0; i < length; i++) {
        if (data[i] < lo) lo = data[i];
        if (data[i] > hi) hi = data[i];
    }
    *minimum = lo;
    *maximum = hi;
}

static void usage(const char *program)
{
    printf("QPCIe NV12M V4L2 capture tester\n"
           "Usage: %s [options]\n"
           "  -d, --dev DEVICE       video node (default %s)\n"
           "  -f, --frames COUNT     frames to capture (default %u)\n"
           "  -p, --pattern ID       TPG ID: 1 ramp, 9 color bars, 10 zone plate\n"
           "  -r, --fps FPS          requested rate (fixed to 60)\n"
           "  -o, --out FILE         save first frame as contiguous NV12\n"
           "  -b, --benchmark        disable the 60 FPS pacer and measure maximum DMA rate\n"
           "      --probe            control-plane probe only, no STREAMON\n"
           "      --help             show this help\n",
           program, DEFAULT_DEVICE, DEFAULT_FRAMES);
}

int main(int argc, char **argv)
{
    const char *device = DEFAULT_DEVICE;
    const char *output_name = NULL;
    unsigned int frame_target = DEFAULT_FRAMES;
    unsigned int width = DEFAULT_WIDTH, height = DEFAULT_HEIGHT;
    int pattern = 9, fps = 60, probe_only = 0;
    int benchmark_mode = 0, frames_set = 0;
    int fd = -1, opt, rc = EXIT_FAILURE;
    struct v4l2_capability cap;
    struct v4l2_fmtdesc desc;
    struct v4l2_format fmt;
    struct v4l2_streamparm parm;
    struct v4l2_control ctrl;
    struct v4l2_requestbuffers req;
    struct mapped_buffer *buffers = NULL;
    FILE *output = NULL;
    unsigned int i, p, captured = 0, data_errors = 0;
    uint64_t first_y_hash = 0, first_uv_hash = 0;
    unsigned int expected_sequence = 0;
    double start_ms, benchmark_start_ms = 0.0, last_frame_ms = 0.0, end_ms;

    static const struct option options[] = {
        {"dev", required_argument, NULL, 'd'},
        {"frames", required_argument, NULL, 'f'},
        {"pattern", required_argument, NULL, 'p'},
        {"fps", required_argument, NULL, 'r'},
        {"width", required_argument, NULL, 'w'},
        {"height", required_argument, NULL, 'h'},
        {"out", required_argument, NULL, 'o'},
        {"benchmark", no_argument, NULL, 'b'},
        {"probe", no_argument, NULL, 'P'},
        {"help", no_argument, NULL, 'H'},
        {NULL, 0, NULL, 0}
    };

    while ((opt = getopt_long(argc, argv, "d:f:p:r:w:h:o:b", options, NULL)) != -1) {
        switch (opt) {
        case 'd': device = optarg; break;
        case 'f': frame_target = strtoul(optarg, NULL, 0); frames_set = 1; break;
        case 'p': pattern = strtol(optarg, NULL, 0); break;
        case 'r': fps = strtol(optarg, NULL, 0); break;
        case 'w': width = strtoul(optarg, NULL, 0); break;
        case 'h': height = strtoul(optarg, NULL, 0); break;
        case 'o': output_name = optarg; break;
        case 'b': benchmark_mode = 1; break;
        case 'P': probe_only = 1; break;
        case 'H': usage(argv[0]); return EXIT_SUCCESS;
        default: usage(argv[0]); return EXIT_FAILURE;
        }
    }

    if (benchmark_mode && !frames_set)
        frame_target = DEFAULT_BENCHMARK_FRAMES;

    printf("=================================================================\n"
           " QPCIe YUV444 -> NV12M Capture Test%s\n"
           " Device: %s, Mode: %ux%u%s, Frames: %u, Memory: MMAP\n"
           "=================================================================\n",
           benchmark_mode ? " [UNCAPPED DMA BENCHMARK]" : "",
           device, width, height,
           benchmark_mode ? " uncapped" : "@60", frame_target);

    fd = open(device, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        perror("open video device");
        goto out;
    }

    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        perror("VIDIOC_QUERYCAP");
        goto out;
    }
    printf("[CAP] driver=%s card=%s bus=%s\n", cap.driver, cap.card, cap.bus_info);
    {
        uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ?
                        cap.device_caps : cap.capabilities;
        if (!(caps & V4L2_CAP_VIDEO_CAPTURE_MPLANE) ||
            !(caps & V4L2_CAP_STREAMING)) {
            fprintf(stderr, "[FAIL] CAPTURE_MPLANE/STREAMING not supported\n");
            goto out;
        }
    }

    memset(&desc, 0, sizeof(desc));
    desc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_ENUM_FMT, &desc) < 0 ||
        desc.pixelformat != V4L2_PIX_FMT_NV12M) {
        perror("VIDIOC_ENUM_FMT NV12M");
        goto out;
    }
    printf("[PASS] Format[0]: %c%c%c%c (NV12M)\n",
           desc.pixelformat & 0xff, (desc.pixelformat >> 8) & 0xff,
           (desc.pixelformat >> 16) & 0xff, (desc.pixelformat >> 24) & 0xff);

    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    fmt.fmt.pix_mp.width = width;
    fmt.fmt.pix_mp.height = height;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12M;
    fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT");
        goto out;
    }
    if (fmt.fmt.pix_mp.width != DEFAULT_WIDTH ||
        fmt.fmt.pix_mp.height != DEFAULT_HEIGHT ||
        fmt.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_NV12M ||
        fmt.fmt.pix_mp.num_planes != NV12_PLANES) {
        fprintf(stderr, "[FAIL] Driver did not select fixed 1920x1080 NV12M/2-plane mode\n");
        goto out;
    }
    printf("[PASS] Mode: %ux%u NV12M planes=%u Y=%u UV=%u bytes\n",
           fmt.fmt.pix_mp.width, fmt.fmt.pix_mp.height,
           fmt.fmt.pix_mp.num_planes,
           fmt.fmt.pix_mp.plane_fmt[0].sizeimage,
           fmt.fmt.pix_mp.plane_fmt[1].sizeimage);

    memset(&parm, 0, sizeof(parm));
    parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    parm.parm.capture.timeperframe.numerator = 1;
    parm.parm.capture.timeperframe.denominator = fps;
    if (xioctl(fd, VIDIOC_S_PARM, &parm) < 0) {
        perror("VIDIOC_S_PARM");
        goto out;
    }
    printf("[PASS] Frame interval: %u/%u s\n",
           parm.parm.capture.timeperframe.numerator,
           parm.parm.capture.timeperframe.denominator);

    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = V4L2_CID_TEST_PATTERN;
    ctrl.value = pattern == 9 ? 3 : pattern == 10 ? 4 : pattern;
    if (xioctl(fd, VIDIOC_S_CTRL, &ctrl) < 0 ||
        xioctl(fd, VIDIOC_G_CTRL, &ctrl) < 0) {
        perror("TPG VIDIOC_S/G_CTRL");
        goto out;
    }
    printf("[PASS] TPG menu value=%d (hardware pattern %d)\n", ctrl.value, pattern);

    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.id = V4L2_CID_QPCIE_PACER_ENABLE;
    ctrl.value = benchmark_mode ? 0 : 1;
    if (xioctl(fd, VIDIOC_S_CTRL, &ctrl) < 0 ||
        xioctl(fd, VIDIOC_G_CTRL, &ctrl) < 0 ||
        ctrl.value != (benchmark_mode ? 0 : 1)) {
        perror("QPCIe pacer VIDIOC_S/G_CTRL");
        goto out;
    }
    printf("[PASS] Hardware frame pacer: %s\n",
           ctrl.value ? "enabled (60 FPS)" : "disabled (uncapped benchmark)");

    if (probe_only) {
        printf("[PASS] Control-plane probe complete; STREAMON was not issued.\n");
        rc = EXIT_SUCCESS;
        goto out;
    }

    if (!frame_target ||
        (benchmark_mode && frame_target <= BENCHMARK_WARMUP_FRAMES)) {
        fprintf(stderr, "Frame count must be non-zero and benchmark count must exceed %u warm-up frames\n",
                BENCHMARK_WARMUP_FRAMES);
        goto out;
    }

    memset(&req, 0, sizeof(req));
    req.count = DEFAULT_BUFFERS;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2) {
        perror("VIDIOC_REQBUFS MMAP");
        goto out;
    }
    buffers = calloc(req.count, sizeof(*buffers));
    if (!buffers) goto out;

    for (i = 0; i < req.count; i++) {
        struct v4l2_buffer buf;
        struct v4l2_plane planes[NV12_PLANES];
        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = req.type;
        buf.memory = req.memory;
        buf.index = i;
        buf.length = NV12_PLANES;
        buf.m.planes = planes;
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF");
            goto out;
        }
        for (p = 0; p < NV12_PLANES; p++) {
            buffers[i].plane[p].length = planes[p].length;
            buffers[i].plane[p].addr = mmap(NULL, planes[p].length,
                                             PROT_READ | PROT_WRITE,
                                             MAP_SHARED, fd,
                                             planes[p].m.mem_offset);
            if (buffers[i].plane[p].addr == MAP_FAILED) {
                buffers[i].plane[p].addr = NULL;
                perror("mmap plane");
                goto out;
            }
        }
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF initial");
            goto out;
        }
    }
    printf("[PASS] Allocated and queued %u contiguous NV12M MMAP buffers\n", req.count);

    if (output_name) {
        output = fopen(output_name, "wb");
        if (!output) {
            perror("open output");
            goto out;
        }
    }

    {
        enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
            perror("VIDIOC_STREAMON");
            goto out;
        }
    }
    printf("[PASS] STREAMON; capturing...\n");
    start_ms = monotonic_ms();

    while (captured < frame_target) {
        fd_set readfds;
        struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
        struct v4l2_buffer buf;
        struct v4l2_plane planes[NV12_PLANES];
        uint64_t y_hash, uv_hash;
        uint8_t y_min, y_max, uv_min, uv_max;
        int ready;

        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);
        ready = select(fd + 1, &readfds, NULL, NULL, &timeout);
        if (ready <= 0) {
            if (ready == 0) fprintf(stderr, "[FAIL] frame timeout\n");
            else perror("select");
            break;
        }

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = NV12_PLANES;
        buf.m.planes = planes;
        if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) continue;
            perror("VIDIOC_DQBUF");
            break;
        }

        captured++;
        if (planes[0].bytesused != DEFAULT_WIDTH * DEFAULT_HEIGHT ||
            planes[1].bytesused != DEFAULT_WIDTH * DEFAULT_HEIGHT / 2) {
            fprintf(stderr, "[FAIL] frame %u payload Y=%u UV=%u\n",
                    captured, planes[0].bytesused, planes[1].bytesused);
            data_errors++;
        }
        if (captured > 1 && buf.sequence != expected_sequence) {
            fprintf(stderr, "[FAIL] sequence jump: got=%u expected=%u\n",
                    buf.sequence, expected_sequence);
            data_errors++;
        }
        expected_sequence = buf.sequence + 1;
        last_frame_ms = buf.timestamp.tv_sec * 1000.0 +
                        buf.timestamp.tv_usec / 1000.0;
        if (benchmark_mode && captured == BENCHMARK_WARMUP_FRAMES)
            benchmark_start_ms = last_frame_ms;

        if (captured == 1) {
            y_hash = fnv1a64(buffers[buf.index].plane[0].addr,
                             planes[0].bytesused);
            uv_hash = fnv1a64(buffers[buf.index].plane[1].addr,
                              planes[1].bytesused);
            first_y_hash = y_hash;
            first_uv_hash = uv_hash;
            byte_range(buffers[buf.index].plane[0].addr, planes[0].bytesused,
                       &y_min, &y_max);
            byte_range(buffers[buf.index].plane[1].addr, planes[1].bytesused,
                       &uv_min, &uv_max);
            printf("[FRAME 1] seq=%u Y-hash=%016" PRIx64 " UV-hash=%016" PRIx64
                   " Y-range=%u..%u UV-range=%u..%u\n",
                   buf.sequence, y_hash, uv_hash, y_min, y_max, uv_min, uv_max);
            if (y_min == y_max || uv_min == uv_max) {
                fprintf(stderr, "[FAIL] color-bars planes have no sample variation\n");
                data_errors++;
            }
            if (output) {
                fwrite(buffers[buf.index].plane[0].addr, 1, planes[0].bytesused, output);
                fwrite(buffers[buf.index].plane[1].addr, 1, planes[1].bytesused, output);
                fflush(output);
                printf("[PASS] Saved first contiguous NV12 frame to %s\n", output_name);
            }
        } else if (!benchmark_mode) {
            y_hash = fnv1a64(buffers[buf.index].plane[0].addr,
                             planes[0].bytesused);
            uv_hash = fnv1a64(buffers[buf.index].plane[1].addr,
                              planes[1].bytesused);
            if (y_hash != first_y_hash || uv_hash != first_uv_hash) {
                fprintf(stderr,
                        "[FAIL] static color-bars changed at frame %u: Y=%016" PRIx64
                        " UV=%016" PRIx64 "\n", captured, y_hash, uv_hash);
                data_errors++;
            }
        }

        if (captured == 1 ||
            captured % (benchmark_mode ? 100U : 30U) == 0)
            printf("[FRAME %u] index=%u seq=%u timestamp=%ld.%06ld\n",
                   captured, buf.index, buf.sequence,
                   (long)buf.timestamp.tv_sec, (long)buf.timestamp.tv_usec);

        if (captured < frame_target && xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF requeue");
            break;
        }
    }
    end_ms = benchmark_mode ? last_frame_ms : monotonic_ms();

    {
        enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        if (xioctl(fd, VIDIOC_STREAMOFF, &type) < 0)
            perror("VIDIOC_STREAMOFF");
    }

    if (captured) {
        unsigned int measured_frames = captured;
        double rate_start_ms = start_ms;
        double elapsed_s, measured_fps, mib_s;

        if (benchmark_mode && captured > BENCHMARK_WARMUP_FRAMES) {
            measured_frames -= BENCHMARK_WARMUP_FRAMES;
            rate_start_ms = benchmark_start_ms;
        }
        elapsed_s = (end_ms - rate_start_ms) / 1000.0;
        measured_fps = measured_frames / elapsed_s;
        mib_s = measured_frames * (double)NV12_FRAME_BYTES /
                elapsed_s / (1024.0 * 1024.0);

        printf("=================================================================\n"
               " Captured: %u/%u frames\n"
               " Measured: %u frames in %.3f s, %.3f FPS\n"
               " DMA payload write throughput: %.2f MiB/s\n",
               captured, frame_target, measured_frames, elapsed_s,
               measured_fps, mib_s);
        if (benchmark_mode) {
            double mwr_per_s = measured_frames * (double)NV12_MWR_PER_FRAME /
                               elapsed_s;
            printf(" 128-byte PCIe MWr rate: %.3f million requests/s\n"
                   " Warm-up excluded: %u frames\n",
                   mwr_per_s / 1000000.0, BENCHMARK_WARMUP_FRAMES);
        }
        printf(" Data errors: %u\n"
               "=================================================================\n",
               data_errors);

        if (captured == frame_target && data_errors == 0 &&
            ((benchmark_mode && measured_fps >= 60.0) ||
             (!benchmark_mode && measured_fps >= 59.0 && measured_fps <= 61.0)))
            rc = EXIT_SUCCESS;
        else
            fprintf(stderr, "[FAIL] NV12 correctness or DMA rate requirement not met\n");
    }

out:
    if (output) fclose(output);
    if (buffers) {
        for (i = 0; i < req.count; i++) {
            for (p = 0; p < NV12_PLANES; p++) {
                if (buffers[i].plane[p].addr)
                    munmap(buffers[i].plane[p].addr,
                           buffers[i].plane[p].length);
            }
        }
        free(buffers);
    }
    if (fd >= 0) close(fd);
    return rc;
}
