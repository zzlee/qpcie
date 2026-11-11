/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * host_pkt_dma_test.c - Standalone PL Packet DMA unit test (Host x86_64)
 *
 * Receive-side peer of test_app/sc7f0_pkt_dma_test.cpp. It is the verification
 * half of a pure Packet DMA transport unit test:
 *
 *   Card PS DDR slot -> PL Packet Reader (AXI HP1) -> PCIe C2H Stream
 *                    -> Host V4L2 ring buffer (/dev/video1) -> THIS PROGRAM
 *
 * No VCU, no OpenMAX, no HDMI RX, no GStreamer, no decoder: every buffer that
 * the driver hands up is verified to the byte.
 *
 * Verification per buffer:
 *   1. bytesused >= 32 and 16-byte aligned
 *   2. magic   == 0x504B5454 ("PKTT")
 *   3. seq     == previous seq + 1        (gap => lost/reordered slot)
 *   4. length  == bytesused               (truncation / stale length)
 *   5. crc32   == IEEE 802.3 CRC32 over offset 20 .. bytesused-1
 *   6. EVERY byte of offset 20 .. bytesused-1 == deterministic PRNG byte
 *      generated from the header seed (not just the CRC - a CRC collision or a
 *      header-only corruption must still be caught)
 *
 * Any failure prints a [DATA CORRUPTION] line naming the byte index, the
 * expected and the actual value.
 *
 * The header/payload ABI below is shared with sc7f0_pkt_dma_test.cpp; the PRNG
 * and CRC32 implementations must stay bit-identical on both sides.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#if !defined(__BYTE_ORDER__) || (__BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__)
#error "This test exchanges little-endian 32-bit payload words; little-endian host required."
#endif

#define PKT_MAGIC        0x504B5454u   /* "PKTT" */
#define PKT_HDR_BYTES    32u
#define PKT_PAYLOAD_OFF  20u
#define PKT_ALIGN        16u

#define DEF_DEVICE       "/dev/video1"
#define DEF_BUFFERS      16
#define DEF_BUFFER_SIZE  (4u * 1024u * 1024u)   /* 4 MiB, matches driver comp_size */

/* --------------------------------------------------------------------------
 * Deterministic generators - byte-identical to sc7f0_pkt_dma_test.cpp
 * ------------------------------------------------------------------------ */
static inline uint32_t prng_next(uint32_t *s)
{
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

static uint32_t crc32_table[256];
static int crc32_table_ready = 0;

static void crc32_init(void)
{
    uint32_t i;
    for (i = 0; i < 256; i++) {
        uint32_t rem = i;
        int j;
        for (j = 0; j < 8; j++)
            rem = (rem & 1) ? ((rem >> 1) ^ 0xEDB88320u) : (rem >> 1);
        crc32_table[i] = rem;
    }
    crc32_table_ready = 1;
}

static uint32_t crc32_calc(const uint8_t *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    size_t i;

    if (!crc32_table_ready)
        crc32_init();
    for (i = 0; i < len; i++)
        crc = (crc >> 8) ^ crc32_table[(crc ^ data[i]) & 0xFF];
    return crc ^ 0xFFFFFFFFu;
}

/* --------------------------------------------------------------------------
 * State
 * ------------------------------------------------------------------------ */
struct mmap_info {
    void  *start;
    size_t len;
};

struct rx_stats {
    uint64_t bufs;             /* buffers dequeued (any state)            */
    uint64_t verified;         /* buffers that passed every check         */
    uint64_t bytes;            /* payload bytes verified                  */
    uint64_t empty;            /* bytesused == 0 (driver error completion) */
    uint64_t too_short;
    uint64_t bad_magic;
    uint64_t seq_gaps;
    uint64_t len_mismatch;
    uint64_t crc_fails;
    uint64_t payload_fails;
    uint64_t bad_bytes;        /* total individual wrong bytes            */
    uint64_t dqbuf_errors;
    uint64_t win_bufs;
    uint64_t win_bytes;
    uint64_t win_crc_try;
    uint64_t win_crc_ok;
};

static volatile sig_atomic_t g_stop = 0;

static void sig_handler(int sig)
{
    (void)sig;
    g_stop = 1;
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int xioctl(int fd, unsigned long request, void *arg, const char *what)
{
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    if (r == -1)
        fprintf(stderr, "[PKT-RX ERROR] %s failed: %s\n", what, strerror(errno));
    return r;
}

/* --------------------------------------------------------------------------
 * Command line
 * ------------------------------------------------------------------------ */
struct rx_config {
    const char *device;
    unsigned int buffers;
    unsigned int buf_size;
    uint64_t count;            /* 0 == unlimited */
    double seconds;            /* 0 == unlimited */
    int exit_on_corrupt;
    int skip_payload_compare;
};

static void usage(const char *argv0)
{
    printf("Usage: %s [device] [options]\n"
           "  device                 V4L2 node (default %s)\n"
           "  --device <path>        same as positional device\n"
           "  --buffers <N>          MMAP buffers to request (default %u)\n"
           "  --buffer-size <bytes>  plane size per buffer (default %u)\n"
           "  --count <N>            stop after N verified packets (default 0 = forever)\n"
           "  --seconds <sec>        stop after N seconds (default 0 = forever)\n"
           "  --exit-on-corrupt      stop at the first corrupted packet\n"
           "  --no-payload-compare   CRC only (skip the per-byte PRNG check)\n"
           "  -h | --help            this text\n",
           argv0, DEF_DEVICE, DEF_BUFFERS, DEF_BUFFER_SIZE);
}

static int parse_args(int argc, char **argv, struct rx_config *cfg)
{
    int i;

    cfg->device = DEF_DEVICE;
    cfg->buffers = DEF_BUFFERS;
    cfg->buf_size = DEF_BUFFER_SIZE;
    cfg->count = 0;
    cfg->seconds = 0.0;
    cfg->exit_on_corrupt = 0;
    cfg->skip_payload_compare = 0;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

        if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            usage(argv[0]);
            return 1;
        }
#define NEED_VAL()                                                    \
        do {                                                          \
            if (!v) {                                                 \
                fprintf(stderr, "ERROR: %s needs a value\n", a);      \
                return -1;                                            \
            }                                                         \
            i++;                                                      \
        } while (0)

        if (!strcmp(a, "--device")) {
            NEED_VAL();
            cfg->device = v;
        } else if (!strcmp(a, "--buffers")) {
            NEED_VAL();
            cfg->buffers = (unsigned int)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--buffer-size")) {
            NEED_VAL();
            cfg->buf_size = (unsigned int)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--count")) {
            NEED_VAL();
            cfg->count = strtoull(v, NULL, 0);
        } else if (!strcmp(a, "--seconds")) {
            NEED_VAL();
            cfg->seconds = strtod(v, NULL);
        } else if (!strcmp(a, "--exit-on-corrupt")) {
            cfg->exit_on_corrupt = 1;
        } else if (!strcmp(a, "--no-payload-compare")) {
            cfg->skip_payload_compare = 1;
        } else if (a[0] == '-') {
            fprintf(stderr, "ERROR: unknown option '%s'\n", a);
            usage(argv[0]);
            return -1;
        } else {
            cfg->device = a;
        }
#undef NEED_VAL
    }

    if (cfg->buffers < 2)
        cfg->buffers = 2;
    if (cfg->buf_size < 65536u)
        cfg->buf_size = 65536u;
    return 0;
}

/* --------------------------------------------------------------------------
 * Buffer verification
 * ------------------------------------------------------------------------ */
/* Returns 1 when the buffer is bit-exact, 0 when anything mismatched.
 * 'expect_seq' is updated on success so the caller sees a strict chain. */
static int verify_buffer(const uint8_t *p, uint32_t used, struct rx_stats *st,
                         uint64_t *expect_seq, int detailed, int payload_compare,
                         int *crc_ok_out)
{
    uint32_t magic, seq, length, seed, hdr_crc;
    uint32_t crc;
    int ok = 1;

    *crc_ok_out = 0;

    if (used < PKT_HDR_BYTES) {
        st->too_short++;
        if (detailed)
            printf("[DATA CORRUPTION] seq~%" PRIu64 " bytesused=%u < %u header bytes\n",
                   *expect_seq, used, PKT_HDR_BYTES);
        return 0;
    }

    memcpy(&magic,  p + 0x00, 4);
    memcpy(&seq,    p + 0x04, 4);
    memcpy(&length, p + 0x08, 4);
    memcpy(&seed,   p + 0x0C, 4);
    memcpy(&hdr_crc, p + 0x10, 4);

    if (magic != PKT_MAGIC) {
        st->bad_magic++;
        if (detailed)
            printf("[DATA CORRUPTION] bad magic at byte 0: got 0x%08x want 0x%08x "
                   "(bytesused=%u)\n", magic, PKT_MAGIC, used);
        ok = 0;
    }

    if ((uint64_t)seq != *expect_seq) {
        st->seq_gaps++;
        if (detailed)
            printf("[SEQ DISCONTINUITY] seq=%u expected=%" PRIu64 " (delta=%" PRId64 ") "
                   "len=%u\n", seq, *expect_seq,
                   (int64_t)seq - (int64_t)*expect_seq, length);
        ok = 0;
    }
    *expect_seq = (uint64_t)seq + 1ULL;

    if (length != used) {
        st->len_mismatch++;
        if (detailed)
            printf("[DATA CORRUPTION] length field mismatch: header length=%u "
                   "bytesused=%u (truncation or overrun) seq=%u\n", length, used, seq);
        /* Trust bytesused, it is what actually landed in host RAM - but a
         * header that disagrees with the driver-reported length IS a failure:
         * either the payload was truncated or a stale header survived. */
        ok = 0;
    }

    if (used & (PKT_ALIGN - 1u)) {
        st->len_mismatch++;
        if (detailed)
            printf("[DATA CORRUPTION] bytesused=%u is not 16-byte aligned seq=%u\n",
                   used, seq);
        ok = 0;
    }

    /* One pass: CRC over [20, used) and, unless disabled, the byte-exact PRNG
     * expansion of the very same range. */
    crc = crc32_calc(p + PKT_PAYLOAD_OFF, (size_t)used - PKT_PAYLOAD_OFF);
    if (crc != hdr_crc) {
        st->crc_fails++;
        if (detailed)
            printf("[DATA CORRUPTION] CRC32 MISMATCH seq=%u len=%u: "
                   "header crc=0x%08x computed=0x%08x\n", seq, used, hdr_crc, crc);
        ok = 0;
    } else {
        *crc_ok_out = 1;
    }

    if (payload_compare) {
        uint32_t s = seed | 1u;
        uint32_t off;
        uint32_t first_bad = 0;
        uint32_t first_exp = 0, first_act = 0;
        uint32_t nbad = 0;

        for (off = PKT_PAYLOAD_OFF; off + 4u <= used; off += 4u) {
            uint32_t want = prng_next(&s);
            uint32_t got;
            memcpy(&got, p + off, 4);
            if (got != want) {
                int b;
                for (b = 0; b < 4; b++) {
                    uint8_t wb = (uint8_t)(want >> (8 * b));
                    uint8_t gb = (uint8_t)(got >> (8 * b));
                    if (wb != gb) {
                        nbad++;
                        if (!first_bad) {
                            first_bad = off + (uint32_t)b;
                            first_exp = wb;
                            first_act = gb;
                        }
                    }
                }
            }
        }

        if (nbad) {
            st->payload_fails++;
            st->bad_bytes += nbad;
            if (detailed)
                printf("[DATA CORRUPTION] PAYLOAD BYTE MISMATCH seq=%u len=%u: "
                       "%u byte(s) wrong, first at byte %u expected 0x%02x actual 0x%02x "
                       "(seed=0x%08x)\n", seq, used, nbad, first_bad,
                       first_exp, first_act, seed);
            ok = 0;
        }
    }

    return ok;
}

/* --------------------------------------------------------------------------
 * V4L2 setup (single-planar and multi-planar capture both supported)
 * ------------------------------------------------------------------------ */
/* Best-effort format negotiation: ask for a 4 MiB plane so the transmitter can
 * ship 1 MiB packets. The qpcie driver sizes the ch1 ring itself (comp_size =
 * 4 MiB in qpcie_queue_setup) and overwrites whatever we request, so a refusal
 * here is not fatal - map_buffers() maps the length the driver actually gave. */
static void negotiate_format(int fd, int mplane, unsigned int size)
{
    struct v4l2_format fmt;

    memset(&fmt, 0, sizeof(fmt));
    fmt.type = mplane ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                      : V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (mplane) {
        fmt.fmt.pix_mp.width       = 3840;
        fmt.fmt.pix_mp.height      = 2160;
        fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_H264;
        fmt.fmt.pix_mp.field       = V4L2_FIELD_NONE;
        fmt.fmt.pix_mp.colorspace  = V4L2_COLORSPACE_REC709;
        fmt.fmt.pix_mp.num_planes  = 1;
        fmt.fmt.pix_mp.plane_fmt[0].sizeimage = size;
        if (xioctl(fd, VIDIOC_S_FMT, &fmt, "VIDIOC_S_FMT(mplane)") < 0)
            printf("[PKT-RX WARN] S_FMT(mplane) refused, using driver geometry\n");
        else
            printf("[PKT-RX] format: %ux%u fourcc=%.4s planes=%u sizeimage=%u\n",
                   fmt.fmt.pix_mp.width, fmt.fmt.pix_mp.height,
                   (char *)&fmt.fmt.pix_mp.pixelformat, fmt.fmt.pix_mp.num_planes,
                   fmt.fmt.pix_mp.plane_fmt[0].sizeimage);
    } else {
        fmt.fmt.pix.width       = 3840;
        fmt.fmt.pix.height      = 2160;
        fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_H264;
        fmt.fmt.pix.field       = V4L2_FIELD_NONE;
        fmt.fmt.pix.colorspace  = V4L2_COLORSPACE_REC709;
        fmt.fmt.pix.sizeimage   = size;
        if (xioctl(fd, VIDIOC_S_FMT, &fmt, "VIDIOC_S_FMT") < 0)
            printf("[PKT-RX WARN] S_FMT refused, using driver geometry\n");
        else
            printf("[PKT-RX] format: %ux%u fourcc=%.4s sizeimage=%u\n",
                   fmt.fmt.pix.width, fmt.fmt.pix.height,
                   (char *)&fmt.fmt.pix.pixelformat, fmt.fmt.pix.sizeimage);
    }
}

static int reqbufs_mmap(int fd, int mplane, unsigned int *count)
{
    struct v4l2_requestbuffers req;

    memset(&req, 0, sizeof(req));
    req.count  = *count;
    req.type   = mplane ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                        : V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;

    if (xioctl(fd, VIDIOC_REQBUFS, &req, "VIDIOC_REQBUFS") < 0)
        return -1;
    if (req.count < 2) {
        fprintf(stderr, "[PKT-RX ERROR] only %u buffers granted\n", req.count);
        return -1;
    }
    *count = req.count;
    return 0;
}

static int map_buffers(int fd, int mplane, struct mmap_info *maps, unsigned int n,
                       size_t *mapped_out)
{
    unsigned int i;
    size_t mapped = 0;

    for (i = 0; i < n; i++) {
        struct v4l2_buffer buf;
        struct v4l2_plane planes[VIDEO_MAX_PLANES];
        void *addr;

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type   = mplane ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                            : V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index  = i;
        if (mplane) {
            buf.m.planes = planes;
            buf.length   = 1;
        }

        if (xioctl(fd, VIDIOC_QUERYBUF, &buf, "VIDIOC_QUERYBUF") < 0)
            return -1;

        if (mplane) {
            if (!buf.m.planes[0].length) {
                fprintf(stderr, "[PKT-RX ERROR] buffer %u plane 0 length 0\n", i);
                return -1;
            }
            maps[i].len = buf.m.planes[0].length;
            addr = mmap(NULL, maps[i].len, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                        buf.m.planes[0].m.mem_offset);
        } else {
            maps[i].len = buf.length;
            addr = mmap(NULL, maps[i].len, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                        buf.m.offset);
        }
        if (addr == MAP_FAILED) {
            fprintf(stderr, "[PKT-RX ERROR] mmap buffer %u (%zu bytes) failed: %s\n",
                    i, maps[i].len, strerror(errno));
            return -1;
        }
        maps[i].start = addr;
        mapped += maps[i].len;
    }
    *mapped_out = mapped;
    return 0;
}

static int qbuf(int fd, int mplane, unsigned int idx)
{
    struct v4l2_buffer buf;
    struct v4l2_plane planes[VIDEO_MAX_PLANES];

    memset(&buf, 0, sizeof(buf));
    memset(planes, 0, sizeof(planes));
    buf.type   = mplane ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                        : V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    buf.index  = idx;
    if (mplane) {
        buf.m.planes = planes;
        buf.length   = 1;
    }
    return xioctl(fd, VIDIOC_QBUF, &buf, "VIDIOC_QBUF");
}

/* --------------------------------------------------------------------------
 * Buffer hex dump on anomaly
 *
 * A bytesused == 0 completion means the driver lost/errored the transfer, and a
 * verification failure means bytes arrived damaged. In both cases the only way
 * to tell "nothing was written into this MMAP buffer" apart from "the packet
 * landed at a non-zero offset / under a different tag" is to look at what the
 * mapping actually contains: dump the head of the buffer in dwords and scan the
 * whole mapping for the packet markers DPC1 (0x44504331, the card-side slot
 * tag) and PKTT (0x504B5454, the packet header magic).
 * ------------------------------------------------------------------------ */
#define DUMP_HEAD_BYTES  1024u                       /* bytes dumped per event */
#define DUMP_HEAD_ROWS   (DUMP_HEAD_BYTES / 16u)     /* 4 dwords per row       */
#define DUMP_BUDGET      64u                         /* cap stdout per run     */
#define PKT_TAG_DPC1     0x44504331u                 /* "DPC1" */
#define PKT_TAG_PKTT     0x504B5454u                 /* "PKTT" */

static void dump_buffer_debug(const char *tag, unsigned int idx, uint32_t used,
                              const struct mmap_info *mi, size_t buf_size)
{
    static unsigned int budget = DUMP_BUDGET;
    static int budget_note = 0;
    const uint32_t *dw;
    size_t nwords, scan_words, i;
    unsigned int row;

    if (!mi || !mi->start)
        return;

    if (!budget) {
        if (!budget_note) {
            printf("[PKT-RX %s] dump budget (%u events) exhausted, "
                   "further dumps suppressed\n", tag, DUMP_BUDGET);
            budget_note = 1;
        }
        return;
    }
    budget--;

    dw = (const uint32_t *)mi->start;
    nwords = mi->len / 4;
    scan_words = buf_size ? (buf_size / 4) : nwords;
    if (scan_words > nwords)
        scan_words = nwords;          /* never read past the end of the mapping */

    printf("[PKT-RX %s] buf=%u used=%u maps[start]=%p len=%zu:\n",
           tag, idx, used, mi->start, mi->len);

    for (row = 0; row < DUMP_HEAD_ROWS && (size_t)(row * 4) < nwords; row++) {
        uint32_t a = 0, b = 0, c = 0, d = 0;

        if ((size_t)(row * 4 + 0) < nwords) a = dw[row * 4 + 0];
        if ((size_t)(row * 4 + 1) < nwords) b = dw[row * 4 + 1];
        if ((size_t)(row * 4 + 2) < nwords) c = dw[row * 4 + 2];
        if ((size_t)(row * 4 + 3) < nwords) d = dw[row * 4 + 3];
        printf("[PKT-RX %s-DEBUG] +0x%03x: %08x %08x %08x %08x\n",
               tag, row * 16, a, b, c, d);
    }

    /* Did the payload land somewhere else in this buffer? */
    for (i = 0; i < scan_words; i++) {
        if (dw[i] == PKT_TAG_DPC1) {
            printf("[PKT-RX FOUND-DPC1] buf=%u at word index %zu "
                   "(byte offset 0x%zx)\n", idx, i, i * 4);
        }
        if (dw[i] == PKT_TAG_PKTT && i != 0) {
            printf("[PKT-RX FOUND-PKTT] buf=%u at word index %zu "
                   "(byte offset 0x%zx)\n", idx, i, i * 4);
        }
    }
    fflush(stdout);
}

/* --------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    struct rx_config cfg;
    struct rx_stats st;
    struct mmap_info *maps = NULL;
    struct sigaction sa;
    int fd = -1;
    int mplane = 0;
    unsigned int nbufs;
    int rc = 0;
    int detail_budget = 40;      /* detailed corruption reports before muting */
    uint64_t expect_seq = 0;
    int have_expect = 0;
    uint64_t t_start, t_report;
    double t_limit = 0.0;

    crc32_init();
    memset(&st, 0, sizeof(st));

    {
        int pr = parse_args(argc, argv, &cfg);
        if (pr < 0)
            return 2;
        if (pr > 0)
            return 0;
    }

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sig_handler;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    fd = open(cfg.device, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "[PKT-RX ERROR] cannot open %s: %s\n", cfg.device,
                strerror(errno));
        return 1;
    }

    {
        struct v4l2_capability cap;
        uint32_t caps;

        if (xioctl(fd, VIDIOC_QUERYCAP, &cap, "VIDIOC_QUERYCAP") < 0) {
            rc = 1;
            goto out_close;
        }
        caps = (cap.device_caps != 0) ? cap.device_caps : cap.capabilities;
        printf("[PKT-RX] %s: driver=%s card=%s caps=0x%08x\n", cfg.device,
               cap.driver, cap.card, caps);

        if (!(caps & V4L2_CAP_STREAMING)) {
            fprintf(stderr, "[PKT-RX ERROR] %s does not support streaming\n",
                    cfg.device);
            rc = 1;
            goto out_close;
        }
        if (caps & V4L2_CAP_VIDEO_CAPTURE_MPLANE) {
            mplane = 1;
        } else if (caps & V4L2_CAP_VIDEO_CAPTURE) {
            mplane = 0;
        } else {
            fprintf(stderr, "[PKT-RX ERROR] %s is not a capture node "
                            "(caps=0x%08x): need V4L2_CAP_VIDEO_CAPTURE[_MPLANE]\n",
                    cfg.device, caps);
            rc = 1;
            goto out_close;
        }
        printf("[PKT-RX] using %s capture, %u x %u bytes MMAP buffers\n",
               mplane ? "multi-planar" : "single-planar", cfg.buffers, cfg.buf_size);
    }

    nbufs = cfg.buffers;
    negotiate_format(fd, mplane, cfg.buf_size);
    if (reqbufs_mmap(fd, mplane, &nbufs) != 0) {
        rc = 1;
        goto out_close;
    }
    if (nbufs != cfg.buffers)
        printf("[PKT-RX] driver adjusted buffer count: %u -> %u\n",
               cfg.buffers, nbufs);

    maps = calloc(nbufs, sizeof(*maps));
    if (!maps) {
        perror("[PKT-RX ERROR] calloc");
        rc = 1;
        goto out_close;
    }
    {
        size_t mapped = 0;
        if (map_buffers(fd, mplane, maps, nbufs, &mapped) != 0) {
            rc = 1;
            goto out_close;
        }
        printf("[PKT-RX] mapped %u buffers, %.1f MiB total\n", nbufs,
               (double)mapped / (1024.0 * 1024.0));
    }

    {
        unsigned int i;
        for (i = 0; i < nbufs; i++) {
            if (qbuf(fd, mplane, i) != 0) {
                rc = 1;
                goto out_close;
            }
        }
    }

    {
        enum v4l2_buf_type type = mplane ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                                         : V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (xioctl(fd, VIDIOC_STREAMON, &type, "VIDIOC_STREAMON") < 0) {
            rc = 1;
            goto out_close;
        }
        printf("[PKT-RX] STREAMON, waiting for Packet DMA traffic on %s "
               "(start sc7f0_pkt_dma_test on the card)... (Ctrl-C to stop)\n",
               cfg.device);
    }

    t_start = t_report = now_ns();
    if (cfg.seconds > 0.0)
        t_limit = (double)cfg.seconds;

    while (!g_stop) {
        struct pollfd pfd;
        struct v4l2_buffer buf;
        struct v4l2_plane planes[VIDEO_MAX_PLANES];
        uint32_t used;
        const uint8_t *p;
        int detailed;
        int ok;
        int crc_ok;
        uint64_t tnow;

        memset(&pfd, 0, sizeof(pfd));
        pfd.fd = fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, 250) < 0) {
            if (errno == EINTR)
                continue;
            perror("[PKT-RX ERROR] poll");
            rc = 1;
            break;
        }

        if (!(pfd.revents & POLLIN)) {
            /* Idle: still let the 1 Hz report run so a stall is visible. */
            goto periodic;
        }

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));
        buf.type   = mplane ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                            : V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (mplane) {
            buf.m.planes = planes;
            buf.length   = 1;
        }

        if (xioctl(fd, VIDIOC_DQBUF, &buf, "VIDIOC_DQBUF") < 0) {
            if (errno == EAGAIN || errno == EINTR)
                goto periodic;
            if (errno == EPIPE || errno == ENODEV || errno == ETIMEDOUT) {
                printf("[PKT-RX WARN] DQBUF reported %s (card reset / overrun)\n",
                       strerror(errno));
                st.dqbuf_errors++;
                goto periodic;
            }
            st.dqbuf_errors++;
            goto periodic;
        }

        if (buf.index >= nbufs || !maps[buf.index].start) {
            printf("[PKT-RX WARN] DQBUF returned bogus index %u (max %u)\n",
                   buf.index, nbufs - 1);
            st.dqbuf_errors++;
            continue;
        }

        used = mplane ? buf.m.planes[0].bytesused : buf.bytesused;
        st.bufs++;
        st.win_bufs++;

        if (used == 0) {
            /* The driver exports 0 bytes for a lost/errored completion: a drop,
             * not a corruption. Dump the mapping first - if the packet really
             * arrived, it is visible here at some offset of this buffer. */
            dump_buffer_debug("EMPTY-DEBUG", buf.index, used,
                              &maps[buf.index], (size_t)cfg.buf_size);
            st.empty++;
            if (qbuf(fd, mplane, buf.index) != 0) {
                rc = 1;
                break;
            }
            goto periodic;
        }

        p = (const uint8_t *)maps[buf.index].start;
        /* Detail budget is spent only on failures: a clean run must not burn
         * the first 40 hex dumps, otherwise a corruption that shows up later
         * is reported without any diagnostic bytes. */
        detailed = (detail_budget > 0);

        if (!have_expect) {
            /* First packet of the session anchors the chain: seq may legitimately
             * start anywhere the transmitter happened to be. */
            uint32_t s0;
            if (used >= 8) {
                memcpy(&s0, p + 0x04, 4);
                expect_seq = s0;
                have_expect = 1;
                printf("[PKT-RX] sequence chain anchored at seq=%u\n", s0);
            }
        }

        ok = verify_buffer(p, used, &st, &expect_seq, detailed,
                           !cfg.skip_payload_compare, &crc_ok);
        st.win_crc_try++;
        st.win_crc_ok += (uint64_t)crc_ok;
        if (ok) {
            st.verified++;
            st.bytes += used;
            st.win_bytes += used;
        } else {
            if (detail_budget > 0)
                detail_budget--;
            dump_buffer_debug("CORRUPT-DEBUG", buf.index, used,
                              &maps[buf.index], (size_t)cfg.buf_size);
            if (cfg.exit_on_corrupt) {
                fprintf(stderr, "[PKT-RX FATAL] stopping at first corrupted packet "
                                "(--exit-on-corrupt)\n");
                qbuf(fd, mplane, buf.index);
                rc = 7;
                break;
            }
        }

        if (qbuf(fd, mplane, buf.index) != 0) {
            rc = 1;
            break;
        }

periodic:
        tnow = now_ns();
        if (tnow - t_report >= 1000000000ULL) {
            double win = (double)(tnow - t_report) / 1e9;
            double el = (double)(tnow - t_start) / 1e9;
            double pass = st.bufs ? (100.0 * (double)st.verified / (double)st.bufs)
                                  : 100.0;
            double crc_rate = st.win_crc_try
                ? (100.0 * (double)st.win_crc_ok / (double)st.win_crc_try)
                : 100.0;
            printf("[PKT-RX] rx=%" PRIu64 " pkts/s %.2f MB/s "
                   "crc-pass=%.2f%% (%" PRIu64 "/%" PRIu64 " win) "
                   "ok=%" PRIu64 " corrupt=%" PRIu64
                   " gaps=%" PRIu64 " empty=%" PRIu64
                   " | pass=%.2f%% avg=%.2f MB/s\n",
                   (uint64_t)((double)st.win_bufs / win),
                   (double)st.win_bytes / win / (1024.0 * 1024.0),
                   crc_rate, st.win_crc_ok, st.win_crc_try,
                   st.verified,
                   st.crc_fails + st.payload_fails + st.bad_magic +
                       st.too_short + st.len_mismatch,
                   st.seq_gaps, st.empty,
                   pass, (double)st.bytes / el / (1024.0 * 1024.0));
            fflush(stdout);
            st.win_bufs = 0;
            st.win_bytes = 0;
            st.win_crc_try = 0;
            st.win_crc_ok = 0;
            t_report = tnow;
        }

        /* Terminate on buffers dequeued, not buffers verified: if the card
         * drops or corrupts packets, st.verified can never reach --count and
         * the test would hang forever waiting for packets that will not come. */
        if (cfg.count && st.bufs >= cfg.count) {
            printf("[PKT-RX] reached --count %" PRIu64 " buffers (%" PRIu64
                   " verified), stopping\n", cfg.count, st.verified);
            break;
        }
        if (t_limit > 0.0 && ((double)(tnow - t_start) / 1e9) >= t_limit) {
            printf("[PKT-RX] reached --seconds %.3f, stopping\n", t_limit);
            break;
        }
    }

    {
        enum v4l2_buf_type type = mplane ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                                         : V4L2_BUF_TYPE_VIDEO_CAPTURE;
        (void)xioctl(fd, VIDIOC_STREAMOFF, &type, "VIDIOC_STREAMOFF");
    }

    {
        double el = (double)(now_ns() - t_start) / 1e9;
        uint64_t corrupt = st.crc_fails + st.payload_fails + st.bad_magic +
                           st.too_short + st.len_mismatch;
        double pass;
        if (el <= 0.0)
            el = 1e-9;
        pass = st.bufs ? (100.0 * (double)st.verified / (double)st.bufs) : 0.0;

        printf("\n[PKT-RX] ==================== RECEIVE SUMMARY ====================\n");
        printf("[PKT-RX] buffers dequeued   : %" PRIu64 "\n", st.bufs);
        printf("[PKT-RX] fully verified     : %" PRIu64 " (%.3f%% pass)\n",
               st.verified, st.bufs ? pass : 0.0);
        printf("[PKT-RX] verified bytes     : %" PRIu64 " (%.2f MiB)\n",
               st.bytes, (double)st.bytes / (1024.0 * 1024.0));
        printf("[PKT-RX] elapsed            : %.3f s\n", el);
        printf("[PKT-RX] average throughput : %.2f MB/s @ %.0f pps\n",
               (double)st.bytes / el / (1024.0 * 1024.0),
               (double)st.verified / el);
        printf("[PKT-RX] CRC failures       : %" PRIu64 "\n", st.crc_fails);
        printf("[PKT-RX] payload byte errs  : %" PRIu64 " packets, %" PRIu64 " bytes\n",
               st.payload_fails, st.bad_bytes);
        printf("[PKT-RX] bad magic          : %" PRIu64 "\n", st.bad_magic);
        printf("[PKT-RX] length mismatches  : %" PRIu64 "\n", st.len_mismatch);
        printf("[PKT-RX] too short (<%u)    : %" PRIu64 "\n", PKT_HDR_BYTES,
               st.too_short);
        printf("[PKT-RX] sequence gaps      : %" PRIu64 "\n", st.seq_gaps);
        printf("[PKT-RX] empty (0-byte) bufs: %" PRIu64 "\n", st.empty);
        printf("[PKT-RX] DQBUF errors       : %" PRIu64 "\n", st.dqbuf_errors);
        printf("[PKT-RX] last seq verified  : %" PRIu64 "\n",
               expect_seq ? expect_seq - 1 : 0);
        if (corrupt == 0 && st.seq_gaps == 0 && st.bufs > 0)
            printf("[PKT-RX] RESULT: PASS - 100%% bit-exact over %" PRIu64
                   " packets\n", st.verified);
        else if (st.bufs == 0)
            printf("[PKT-RX] RESULT: NO DATA - the card never transmitted anything\n");
        else
            printf("[PKT-RX] RESULT: FAIL - %" PRIu64 " corrupted packet(s), "
                   "%" PRIu64 " sequence gap(s)\n", corrupt, st.seq_gaps);
        printf("[PKT-RX] ============================================================\n");
        fflush(stdout);

        if (rc == 0) {
            if (st.bufs == 0)
                rc = 8;
            else if (corrupt != 0 || st.seq_gaps != 0)
                rc = 7;
        }
    }

out_close:
    free(maps);
    if (fd >= 0)
        close(fd);
    return rc;
}
