// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * QPCIe V4L2 Hardware DMA Loopback Test Suite (H2C -> FPGA Loopback -> C2H)
 *
 * Transmits deterministic NV12M frames to /dev/video1 (Output node),
 * FPGA loops back the stream, captures from /dev/video2 (Capture node),
 * and verifies 100% bit-exact data integrity, RTT latency, and bidirectional throughput.
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <linux/videodev2.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_OUT_DEV   "/dev/video1"
#define DEFAULT_CAP_DEV   "/dev/video2"
#define DEFAULT_WIDTH     3840U
#define DEFAULT_HEIGHT    2160U
#define DEFAULT_BUFFERS   8U
#define DEFAULT_FRAMES    600U
#define NV12_PLANES       2U

struct plane_map {
    void *addr;
    size_t length;
};

struct v4l2_buf_entry {
    struct plane_map plane[NV12_PLANES];
};

struct loopback_ctx {
    const char *out_dev;
    const char *cap_dev;
    int out_fd;
    int cap_fd;
    unsigned int width;
    unsigned int height;
    unsigned int num_buffers;
    unsigned int frame_target;
    int benchmark_mode;
    double target_fps;

    size_t y_size;
    size_t uv_size;
    size_t total_frame_bytes;

    struct v4l2_buf_entry *out_bufs;
    struct v4l2_buf_entry *cap_bufs;

    volatile int stop;
    unsigned int tx_frames;
    unsigned int rx_frames;
    unsigned int data_errors;

    double min_rtt_us;
    double max_rtt_us;
    double sum_rtt_us;
    unsigned int rtt_count;

    pthread_t tx_thread;
    pthread_mutex_t lock;
};

static int xioctl(int fd, unsigned long request, void *arg)
{
    int ret;
    do {
        ret = ioctl(fd, request, arg);
    } while (ret < 0 && errno == EINTR);
    return ret;
}

static double monotonic_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000.0 + ts.tv_nsec / 1000.0;
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

static void fill_frame_pattern(uint8_t *y_plane, uint8_t *uv_plane,
                               size_t y_size, size_t uv_size,
                               uint32_t seq, double send_us)
{
    uint32_t *y32 = (uint32_t *)y_plane;
    uint32_t *uv32 = (uint32_t *)uv_plane;
    size_t i;
    uint32_t seed = 0xA5A50000 + seq;

    /* Embed sequence and timestamp in first 16 bytes */
    y32[0] = seq;
    memcpy(&y32[1], &send_us, sizeof(double));
    y32[3] = 0x55AA55AA;

    for (i = 4; i < y_size / 4; i++) {
        seed = seed * 1103515245 + 12345;
        y32[i] = seed;
    }

    for (i = 0; i < uv_size / 4; i++) {
        seed = seed * 1103515245 + 12345;
        uv32[i] = seed;
    }
}

static int verify_frame_pattern(const uint8_t *y_plane, const uint8_t *uv_plane,
                                size_t y_size, size_t uv_size,
                                uint32_t expected_seq, double *send_us_out)
{
    const uint32_t *y32 = (const uint32_t *)y_plane;
    const uint32_t *uv32 = (const uint32_t *)uv_plane;
    size_t i;
    int errors = 0;
    uint32_t seq = y32[0];
    double send_us = 0.0;
    uint32_t seed = 0xA5A50000 + seq;

    memcpy(&send_us, &y32[1], sizeof(double));
    if (send_us_out)
        *send_us_out = send_us;

    if (seq != expected_seq) {
        fprintf(stderr, "[FAIL] Sequence mismatch: Expected %u, Got %u\n", expected_seq, seq);
        errors++;
    }

    if (y32[3] != 0x55AA55AA) {
        fprintf(stderr, "[FAIL] Magic signature mismatch: Got 0x%08X\n", y32[3]);
        errors++;
    }

    for (i = 4; i < y_size / 4; i++) {
        seed = seed * 1103515245 + 12345;
        if (y32[i] != seed) {
            if (errors < 5)
                fprintf(stderr, "[FAIL] Y plane data mismatch at DW %zu: Exp 0x%08X, Got 0x%08X\n",
                        i, seed, y32[i]);
            errors++;
        }
    }

    for (i = 0; i < uv_size / 4; i++) {
        seed = seed * 1103515245 + 12345;
        if (uv32[i] != seed) {
            if (errors < 5)
                fprintf(stderr, "[FAIL] UV plane data mismatch at DW %zu: Exp 0x%08X, Got 0x%08X\n",
                        i, seed, uv32[i]);
            errors++;
        }
    }

    return errors;
}

static void *tx_worker(void *arg)
{
    struct loopback_ctx *ctx = (struct loopback_ctx *)arg;
    struct v4l2_buffer buf;
    struct v4l2_plane planes[NV12_PLANES];
    double interval_us = 1000000.0 / ctx->target_fps;
    double next_send_us = monotonic_us();

    while (!ctx->stop && ctx->tx_frames < ctx->frame_target) {
        if (!ctx->benchmark_mode) {
            double now = monotonic_us();
            if (now < next_send_us)
                usleep((useconds_t)(next_send_us - now));
            next_send_us += interval_us;
        }

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = NV12_PLANES;
        buf.m.planes = planes;

        if (xioctl(ctx->out_fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) {
                usleep(100);
                continue;
            }
            perror("VIDIOC_DQBUF (TX)");
            break;
        }

        double send_us = monotonic_us();
        fill_frame_pattern(ctx->out_bufs[buf.index].plane[0].addr,
                           ctx->out_bufs[buf.index].plane[1].addr,
                           ctx->y_size, ctx->uv_size,
                           ctx->tx_frames, send_us);

        planes[0].bytesused = ctx->y_size;
        planes[1].bytesused = ctx->uv_size;

        if (xioctl(ctx->out_fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF (TX)");
            break;
        }

        ctx->tx_frames++;
    }

    return NULL;
}

static int init_v4l2_node(int fd, enum v4l2_buf_type type, unsigned int width,
                          unsigned int height, unsigned int num_buffers,
                          struct v4l2_buf_entry **bufs_out, size_t *y_sz, size_t *uv_sz)
{
    struct v4l2_capability cap;
    struct v4l2_format fmt;
    struct v4l2_requestbuffers req;
    struct v4l2_buf_entry *bufs;
    unsigned int i, p;

    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        perror("VIDIOC_QUERYCAP");
        return -1;
    }

    memset(&fmt, 0, sizeof(fmt));
    fmt.type = type;
    fmt.fmt.pix_mp.width = width;
    fmt.fmt.pix_mp.height = height;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12M;
    fmt.fmt.pix_mp.num_planes = NV12_PLANES;
    fmt.fmt.pix_mp.plane_fmt[0].bytesperline = width;
    fmt.fmt.pix_mp.plane_fmt[0].sizeimage = (size_t)width * height;
    fmt.fmt.pix_mp.plane_fmt[1].bytesperline = width;
    fmt.fmt.pix_mp.plane_fmt[1].sizeimage = (size_t)width * height / 2;

    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT");
        return -1;
    }

    *y_sz = fmt.fmt.pix_mp.plane_fmt[0].sizeimage;
    *uv_sz = fmt.fmt.pix_mp.plane_fmt[1].sizeimage;

    memset(&req, 0, sizeof(req));
    req.count = num_buffers;
    req.type = type;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2) {
        perror("VIDIOC_REQBUFS");
        return -1;
    }

    bufs = calloc(req.count, sizeof(*bufs));
    if (!bufs)
        return -1;

    for (i = 0; i < req.count; i++) {
        struct v4l2_plane planes[NV12_PLANES];
        struct v4l2_buffer buf;

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = type;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = NV12_PLANES;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF");
            free(bufs);
            return -1;
        }

        for (p = 0; p < NV12_PLANES; p++) {
            bufs[i].plane[p].length = planes[p].length;
            bufs[i].plane[p].addr = mmap(NULL, planes[p].length,
                                         PROT_READ | PROT_WRITE, MAP_SHARED,
                                         fd, planes[p].m.mem_offset);
            if (bufs[i].plane[p].addr == MAP_FAILED) {
                perror("mmap plane");
                free(bufs);
                return -1;
            }
        }
    }

    *bufs_out = bufs;
    return 0;
}

static void print_usage(const char *prog)
{
    printf("Usage: %s [options]\n\n"
           "Options:\n"
           "  -o, --out-dev DEV      V4L2 Video Output node (default %s)\n"
           "  -d, --cap-dev DEV      V4L2 Video Capture node (default %s)\n"
           "  -w, --width WIDTH      Frame width (1920 or 3840, default %u)\n"
           "  -h, --height HEIGHT    Frame height (1080 or 2160, default %u)\n"
           "  -f, --frames COUNT     Total frames to transfer (default %u)\n"
           "  -r, --fps RATE         Pacer target frame rate (default 60)\n"
           "  -b, --benchmark        Uncapped benchmark mode (maximum DMA rate)\n"
           "  -n, --buffers COUNT    VB2 buffers per node (default %u)\n"
           "  -H, --help             Show this help\n",
           prog, DEFAULT_OUT_DEV, DEFAULT_CAP_DEV, DEFAULT_WIDTH,
           DEFAULT_HEIGHT, DEFAULT_FRAMES, DEFAULT_BUFFERS);
}

int main(int argc, char **argv)
{
    struct loopback_ctx ctx;
    int opt;
    unsigned int i;
    double start_time_us, end_time_us, total_sec;
    double tx_throughput_mibs, rx_throughput_mibs, total_throughput_mibs;

    memset(&ctx, 0, sizeof(ctx));
    ctx.out_dev = DEFAULT_OUT_DEV;
    ctx.cap_dev = DEFAULT_CAP_DEV;
    ctx.width = DEFAULT_WIDTH;
    ctx.height = DEFAULT_HEIGHT;
    ctx.frame_target = DEFAULT_FRAMES;
    ctx.num_buffers = DEFAULT_BUFFERS;
    ctx.target_fps = 60.0;
    ctx.benchmark_mode = 0;
    ctx.min_rtt_us = 1e9;
    ctx.max_rtt_us = 0.0;
    ctx.sum_rtt_us = 0.0;
    pthread_mutex_init(&ctx.lock, NULL);

    static const struct option options[] = {
        {"out-dev", required_argument, NULL, 'o'},
        {"cap-dev", required_argument, NULL, 'd'},
        {"width", required_argument, NULL, 'w'},
        {"height", required_argument, NULL, 'h'},
        {"frames", required_argument, NULL, 'f'},
        {"fps", required_argument, NULL, 'r'},
        {"benchmark", no_argument, NULL, 'b'},
        {"buffers", required_argument, NULL, 'n'},
        {"help", no_argument, NULL, 'H'},
        {NULL, 0, NULL, 0}
    };

    while ((opt = getopt_long(argc, argv, "o:d:w:h:f:r:bn:H", options, NULL)) != -1) {
        switch (opt) {
        case 'o': ctx.out_dev = optarg; break;
        case 'd': ctx.cap_dev = optarg; break;
        case 'w': ctx.width = (unsigned int)strtoul(optarg, NULL, 10); break;
        case 'h': ctx.height = (unsigned int)strtoul(optarg, NULL, 10); break;
        case 'f': ctx.frame_target = (unsigned int)strtoul(optarg, NULL, 10); break;
        case 'r': ctx.target_fps = strtod(optarg, NULL); break;
        case 'b': ctx.benchmark_mode = 1; break;
        case 'n': ctx.num_buffers = (unsigned int)strtoul(optarg, NULL, 10); break;
        case 'H':
        default:
            print_usage(argv[0]);
            return (opt == 'H') ? EXIT_SUCCESS : EXIT_FAILURE;
        }
    }

    printf("=================================================================\n"
           " QPCIe Full-Duplex Hardware Video Loopback Test (H2C -> C2H)\n"
           " Output Node : %s (Host -> H2C DMA)\n"
           " Capture Node: %s (FPGA Loopback -> C2H DMA)\n"
           " Resolution  : %ux%u NV12M, Frames: %u\n"
           " Mode        : %s\n"
           "=================================================================\n",
           ctx.out_dev, ctx.cap_dev, ctx.width, ctx.height, ctx.frame_target,
           ctx.benchmark_mode ? "UNCAPPED DMA BENCHMARK" : "PACED 60 FPS STREAMING");

    ctx.out_fd = open(ctx.out_dev, O_RDWR | O_NONBLOCK);
    if (ctx.out_fd < 0) {
        perror("Open output device");
        return EXIT_FAILURE;
    }

    ctx.cap_fd = open(ctx.cap_dev, O_RDWR | O_NONBLOCK);
    if (ctx.cap_fd < 0) {
        perror("Open capture device");
        close(ctx.out_fd);
        return EXIT_FAILURE;
    }

    if (init_v4l2_node(ctx.out_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
                       ctx.width, ctx.height, ctx.num_buffers,
                       &ctx.out_bufs, &ctx.y_size, &ctx.uv_size) < 0) {
        fprintf(stderr, "[FAIL] Failed to initialize Output Node\n");
        return EXIT_FAILURE;
    }

    if (init_v4l2_node(ctx.cap_fd, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
                       ctx.width, ctx.height, ctx.num_buffers,
                       &ctx.cap_bufs, &ctx.y_size, &ctx.uv_size) < 0) {
        fprintf(stderr, "[FAIL] Failed to initialize Capture Node\n");
        return EXIT_FAILURE;
    }

    ctx.total_frame_bytes = ctx.y_size + ctx.uv_size;

    /* Pre-fill and queue all Output buffers */
    for (i = 0; i < ctx.num_buffers; i++) {
        struct v4l2_plane planes[NV12_PLANES];
        struct v4l2_buffer buf;
        double now_us = monotonic_us();

        fill_frame_pattern(ctx.out_bufs[i].plane[0].addr,
                           ctx.out_bufs[i].plane[1].addr,
                           ctx.y_size, ctx.uv_size,
                           i, now_us);

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = NV12_PLANES;
        buf.m.planes = planes;
        planes[0].bytesused = ctx.y_size;
        planes[1].bytesused = ctx.uv_size;

        if (xioctl(ctx.out_fd, VIDIOC_QBUF, &buf) < 0) {
            perror("Initial Output VIDIOC_QBUF");
            return EXIT_FAILURE;
        }
        ctx.tx_frames++;
    }

    /* Queue all Capture buffers */
    for (i = 0; i < ctx.num_buffers; i++) {
        struct v4l2_plane planes[NV12_PLANES];
        struct v4l2_buffer buf;

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = NV12_PLANES;
        buf.m.planes = planes;

        if (xioctl(ctx.cap_fd, VIDIOC_QBUF, &buf) < 0) {
            perror("Initial Capture VIDIOC_QBUF");
            return EXIT_FAILURE;
        }
    }

    /* STREAMON on both nodes */
    enum v4l2_buf_type out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    enum v4l2_buf_type cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

    if (xioctl(ctx.out_fd, VIDIOC_STREAMON, &out_type) < 0) {
        perror("Output VIDIOC_STREAMON");
        return EXIT_FAILURE;
    }
    if (xioctl(ctx.cap_fd, VIDIOC_STREAMON, &cap_type) < 0) {
        perror("Capture VIDIOC_STREAMON");
        return EXIT_FAILURE;
    }

    start_time_us = monotonic_us();

    /* Launch TX Worker thread */
    pthread_create(&ctx.tx_thread, NULL, tx_worker, &ctx);

    /* Main RX Loop */
    while (ctx.rx_frames < ctx.frame_target) {
        struct v4l2_plane planes[NV12_PLANES];
        struct v4l2_buffer buf;
        double recv_us, send_us, rtt_us;
        int err;

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = NV12_PLANES;
        buf.m.planes = planes;

        if (xioctl(ctx.cap_fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) {
                usleep(100);
                continue;
            }
            perror("Capture VIDIOC_DQBUF");
            break;
        }

        recv_us = monotonic_us();
        err = verify_frame_pattern(ctx.cap_bufs[buf.index].plane[0].addr,
                                   ctx.cap_bufs[buf.index].plane[1].addr,
                                   ctx.y_size, ctx.uv_size,
                                   ctx.rx_frames, &send_us);
        if (err > 0)
            ctx.data_errors += err;

        rtt_us = recv_us - send_us;
        if (rtt_us > 0) {
            if (rtt_us < ctx.min_rtt_us) ctx.min_rtt_us = rtt_us;
            if (rtt_us > ctx.max_rtt_us) ctx.max_rtt_us = rtt_us;
            ctx.sum_rtt_us += rtt_us;
            ctx.rtt_count++;
        }

        if (ctx.rx_frames == 0 ||
            ctx.rx_frames % (ctx.benchmark_mode ? 100U : 30U) == 0 ||
            ctx.rx_frames == ctx.frame_target - 1) {
            uint64_t y_h = fnv1a64(ctx.cap_bufs[buf.index].plane[0].addr, ctx.y_size);
            uint64_t uv_h = fnv1a64(ctx.cap_bufs[buf.index].plane[1].addr, ctx.uv_size);
            printf("[FRAME %4u] seq=%4u RTT=%.2f ms Y-hash=%016" PRIx64 " UV-hash=%016" PRIx64 " [%s]\n",
                   ctx.rx_frames + 1, ctx.rx_frames, rtt_us / 1000.0,
                   y_h, uv_h, (err == 0) ? "PASS" : "FAIL");
        }

        ctx.rx_frames++;

        if (ctx.rx_frames < ctx.frame_target) {
            if (xioctl(ctx.cap_fd, VIDIOC_QBUF, &buf) < 0) {
                perror("Capture VIDIOC_QBUF requeue");
                break;
            }
        }
    }

    end_time_us = monotonic_us();
    ctx.stop = 1;
    pthread_join(ctx.tx_thread, NULL);

    xioctl(ctx.out_fd, VIDIOC_STREAMOFF, &out_type);
    xioctl(ctx.cap_fd, VIDIOC_STREAMOFF, &cap_type);

    total_sec = (end_time_us - start_time_us) / 1000000.0;
    tx_throughput_mibs = (ctx.tx_frames * (double)ctx.total_frame_bytes) / (total_sec * 1024.0 * 1024.0);
    rx_throughput_mibs = (ctx.rx_frames * (double)ctx.total_frame_bytes) / (total_sec * 1024.0 * 1024.0);
    total_throughput_mibs = tx_throughput_mibs + rx_throughput_mibs;

    printf("\n================ QPCIe Loopback Performance Report ================\n");
    printf(" Transferred Frames   : TX: %u / RX: %u (Target: %u)\n", ctx.tx_frames, ctx.rx_frames, ctx.frame_target);
    printf(" Elapsed Time         : %.3f seconds (FPS: %.2f)\n", total_sec, ctx.rx_frames / total_sec);
    printf(" H2C Write Throughput : %.2f MiB/s (%.2f Gbps)\n", tx_throughput_mibs, tx_throughput_mibs * 8.0 / 1000.0);
    printf(" C2H Read Throughput  : %.2f MiB/s (%.2f Gbps)\n", rx_throughput_mibs, rx_throughput_mibs * 8.0 / 1000.0);
    printf(" Bidirectional Total  : %.2f MiB/s (%.2f Gbps)\n", total_throughput_mibs, total_throughput_mibs * 8.0 / 1000.0);
    printf("---------------- Round-Trip Latency (RTT) Statistics ---------------\n");
    printf(" Min Latency          : %.3f ms (%.1f us)\n", ctx.min_rtt_us / 1000.0, ctx.min_rtt_us);
    printf(" Avg Latency          : %.3f ms (%.1f us)\n", (ctx.sum_rtt_us / ctx.rtt_count) / 1000.0, ctx.sum_rtt_us / ctx.rtt_count);
    printf(" Max Latency          : %.3f ms (%.1f us)\n", ctx.max_rtt_us / 1000.0, ctx.max_rtt_us);
    printf(" Data Mismatch Errors : %u\n", ctx.data_errors);
    printf(" Verification Status  : %s\n", (ctx.data_errors == 0 && ctx.rx_frames == ctx.frame_target) ? "🎉 [100% BIT-EXACT MATCH PASS]" : "❌ [FAILED]");
    printf("===================================================================\n");

    close(ctx.out_fd);
    close(ctx.cap_fd);

    return (ctx.data_errors == 0 && ctx.rx_frames == ctx.frame_target) ? EXIT_SUCCESS : EXIT_FAILURE;
}
