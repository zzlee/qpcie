// SPDX-License-Identifier: GPL-2.0-only
/*
 * sc7f0_pkt_dma_test.cpp - Standalone PL Packet DMA unit test (Card PS, ARM64)
 *
 * Pure transport-layer exerciser for the C2H compressed-stream path:
 *
 *     Card PS DDR staging slot  ->  PL Packet Reader (AXI HP1 read)
 *                               ->  PCIe C2H Stream (posted writes + MSI)
 *                               ->  Host V4L2 ring buffer (/dev/video1)
 *
 * It deliberately touches NOTHING else: no VCU, no OpenMAX, no HDMI RX, no
 * GStreamer. The only variables left in the experiment are the Packet DMA
 * descriptor protocol, the 16-slot host ring credit exchange and the PCIe
 * payload integrity itself. The peer of this program is
 * test_app/host_pkt_dma_test.c, which performs byte-exact verification
 * (header + IEEE 802.3 CRC32 + full deterministic payload expansion) on the
 * host. Together they give a 100% bit-level pass/fail statement about the
 * Packet DMA path for random and corner-case packet sizes.
 *
 * Packet image in the DDR staging slot (also the image the host receives):
 *
 *   offset 0x00  uint32 magic    = 0x504B5454 ("PKTT")
 *   offset 0x04  uint32 seq      = 0,1,2,... (only successfully submitted
 *                                             packets consume a seq, so the
 *                                             host can assert strict continuity)
 *   offset 0x08  uint32 length   = total packet bytes, 16-byte aligned
 *   offset 0x0C  uint32 seed     = PRNG seed for the payload
 *   offset 0x10  uint32 crc32    = IEEE 802.3 CRC32 over offset 20..length-1
 *   offset 0x14  .. payload     = deterministic PRNG bytes from (seed | 1)
 *
 * The 32-byte header keeps the reserved[3] tail for ABI documentation only:
 * the payload starts at offset 20 and overwrites it, exactly as the CRC field
 * position requires. Both ends of this test agree on that layout - do not
 * "fix" it on one side only.
 *
 * Hardware/ABI references (kept identical to sc7f0_vcud, the production
 * daemon, so this test exercises the real path and not a private one):
 *   PL CSR Packet DMA   0xB0040000  (4 KiB)
 *   PL Shared BRAM      0xA0002000  (8 KiB), host ring at +0x200
 *   DDR staging ring    0x50000000  (16 MiB = 16 slots x 1 MiB)
 *   768-bit descriptor  @ REG_PKT_STAGE_BASE (0x080), doorbell @ 0x014
 *
 * /dev/mem is mapped with O_SYNC exactly like sc7f0_vcud: the resulting
 * write-combine mapping is what the production daemon writes its staging
 * payload through, and the PL reads that DDR over the non-coherent HP1 port,
 * so a writeback-cached mapping here would test a configuration the product
 * never uses (and would race the DMA).
 *
 * Exclusivity: this tool owns the Packet DMA doorbell, the 16 host ring slots
 * and the 16 MiB staging ring. Stop sc7f0_vcud before running it - two
 * publishers on one ring corrupt each other's slots, and a corruption report
 * in that state says nothing about the DMA.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* --------------------------------------------------------------------------
 * Physical address map (Card PS) - same values as sc7f0_vcud.cpp
 * ------------------------------------------------------------------------ */
#define PL_CSR_PACKET_ADDR      0xB0040000ULL
#define PL_CSR_PACKET_SIZE      0x1000ULL       /* 4 KiB  */
#define PL_SHARED_BRAM_ADDR     0xA0002000ULL
#define PL_SHARED_BRAM_SIZE     0x2000ULL       /* 8 KiB  */
#define DDR_STAGING_BUF_ADDR    0x50000000ULL   /* cma,qdmabuf reserved pool */

#define STAGING_SLOT_SIZE       (1024ULL * 1024ULL)     /* 1 MiB per slot        */
#define STAGING_NUM_SLOTS       16                      /* 1 per host ring slot  */
#define STAGING_RING_SIZE       (STAGING_SLOT_SIZE * STAGING_NUM_SLOTS) /* 16 MiB */

/* PL Packet DMA CSR offsets */
#define REG_PKT_MAGIC           0x000   /* 0x44505631 ("DPV1") */
#define REG_PKT_VERSION         0x004
#define REG_PKT_STATUS          0x008   /* bit1=packet_ready, bit3=done FIFO non-empty */
#define REG_PKT_DOORBELL_PUSH   0x014
#define REG_PKT_DOORBELL_POP    0x018
#define REG_PKT_CLOCK_HZ        0x01c   /* 150,000,000 */
#define REG_PKT_DROPS           0x020
#define REG_PKT_STAGE_BASE      0x080   /* 24 words (768 bits) command staging */
#define REG_PKT_PROBE_SUBMIT    0x100
#define REG_PKT_PROBE_DONE      0x104
#define REG_PKT_PROBE_ERR       0x108
#define REG_PKT_PROBE_MSI       0x10C
#define REG_PKT_PROBE_BYTES_LO  0x110
#define REG_PKT_PROBE_BYTES_HI  0x114
#define REG_PKT_PROBE_FSM       0x118
#define REG_PKT_PROBE_LAST_LEN  0x11C

#define PKT_CSR_MAGIC_VALUE     0x44505631u   /* "DPV1" */
#define PKT_STATUS_READY        0x02u  /* packet_ready: engine accepts a job  */
#define PKT_STATUS_DONE_VALID   0x08u  /* completion FIFO holds an unpopped record */

/* Shared BRAM mailbox */
#define MAILBOX_VCU_RING_OFFSET 0x200   /* Physical 0xA0002200 */
#define QPCIE_VCU_RING_MAGIC    0x56435552u  /* "VCUR" */
#define QPCIE_VCU_RING_SIZE     16

/* --------------------------------------------------------------------------
 * Packet image ABI - MUST stay byte-identical to host_pkt_dma_test.c
 * ------------------------------------------------------------------------ */
#define PKT_MAGIC               0x504B5454u   /* "PKTT" */
#define PKT_HDR_BYTES           32u
#define PKT_PAYLOAD_OFF         20u
#define PKT_ALIGN               16u
/* Smallest legal packet.
 * The CRC/payload region is [PKT_PAYLOAD_OFF, length), so a 16-byte packet has
 * no region at all and cannot carry the crc field the receiver is required to
 * check. Both halves of this test therefore treat 32 bytes (full header + 12
 * payload bytes) as the real lower boundary; the transmitter clamps shorter
 * requests up to it and prints a notice instead of silently dropping them. */
#define PKT_MIN_LEN             PKT_HDR_BYTES

struct pkt_header {
    uint32_t magic;         /* 0x00: 0x504B5454 "PKTT" */
    uint32_t seq;           /* 0x04: monotonically increasing, +1 per sent pkt */
    uint32_t length;        /* 0x08: total bytes, 16-byte aligned */
    uint32_t seed;          /* 0x0C: payload PRNG seed */
    uint32_t crc32;         /* 0x10: IEEE 802.3 CRC32 over [20, length) */
    uint32_t reserved[3];   /* 0x14..0x1F: vestigial - payload starts at 20 */
};

/* Host ring as published by the host V4L2 driver into PL BRAM.
 * Instances live in Device memory: plain volatile accesses only. */
struct __attribute__((packed)) qpcie_vcu_buffer_slot {
    uint64_t host_phys_addr;    /* 0x00 */
    uint64_t host_comp_addr;    /* 0x08: 64-byte DPC1 completion record */
    uint32_t host_buf_len;      /* 0x10 */
    uint32_t host_buf_id;       /* 0x14 */
    uint32_t flags;             /* 0x18 */
    uint32_t reserved;          /* 0x1C */
};

struct __attribute__((packed)) qpcie_vcu_host_ring {
    uint32_t magic;             /* 0x00: "VCUR" */
    uint32_t version;           /* 0x04 */
    uint32_t ring_size;         /* 0x08: 16 */
    uint32_t host_head;         /* 0x0C: host increments on QBUF */
    uint32_t ps_tail;           /* 0x10: PS increments before ringing the DMA */
    uint32_t dropped_count;     /* 0x14 */
    uint32_t reserved[10];      /* 0x18..0x3F */
    struct qpcie_vcu_buffer_slot slots[QPCIE_VCU_RING_SIZE];
};

/* --------------------------------------------------------------------------
 * Deterministic generators (identical on both sides of the test)
 * ------------------------------------------------------------------------ */
static inline uint32_t prng_next(uint32_t *s)
{
    /* xorshift32: never reaches 0 from a non-zero seed, so no degenerate
     * all-zero payload is possible. */
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

static uint32_t crc32_table[256];
static bool crc32_table_ready = false;

static void crc32_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t rem = i;
        for (int j = 0; j < 8; j++)
            rem = (rem & 1) ? ((rem >> 1) ^ 0xEDB88320u) : (rem >> 1);
        crc32_table[i] = rem;
    }
    crc32_table_ready = true;
}

/* IEEE 802.3 (reflected, poly 0xEDB88320, init FFFFFFFF, final xor) */
static uint32_t crc32_calc(const uint8_t *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    if (!crc32_table_ready)
        crc32_init();
    for (size_t i = 0; i < len; i++)
        crc = (crc >> 8) ^ crc32_table[(crc ^ data[i]) & 0xFF];
    return crc ^ 0xFFFFFFFFu;
}

/* Fill [PKT_PAYLOAD_OFF, length) with the deterministic PRNG stream.
 * length is 16-byte aligned and PKT_PAYLOAD_OFF is 4-byte aligned, so the
 * region is always an exact number of little-endian 32-bit words. */
static void payload_fill(uint8_t *buf, uint32_t length, uint32_t seed)
{
    uint32_t st = seed | 1u;
    uint32_t off;

    if (length < PKT_PAYLOAD_OFF + 4u)
        return;                 /* degenerate request: no room for payload */
    /* Round the region down to whole words; a 16-byte-aligned length always
     * lands exactly on a word boundary. */
    for (off = PKT_PAYLOAD_OFF; off + 4u <= length; off += 4u) {
        uint32_t w = prng_next(&st);
        memcpy(buf + off, &w, 4);
    }
}

static void packet_build(uint8_t *buf, uint32_t seq, uint32_t length, uint32_t seed)
{
    uint32_t v;
    size_t region;

    v = PKT_MAGIC;     memcpy(buf + 0x00, &v, 4);
    v = seq;           memcpy(buf + 0x04, &v, 4);
    v = length;        memcpy(buf + 0x08, &v, 4);
    v = seed;          memcpy(buf + 0x0C, &v, 4);
    v = 0;             memcpy(buf + 0x10, &v, 4);

    payload_fill(buf, length, seed);

    /* Saturating, never wrapping: length is >= PKT_MIN_LEN on every real path,
     * but a hand-made length below PKT_PAYLOAD_OFF must not turn the region
     * size into 2^64-4. */
    region = (length > PKT_PAYLOAD_OFF) ? ((size_t)length - PKT_PAYLOAD_OFF) : 0;
    v = crc32_calc(buf + PKT_PAYLOAD_OFF, region);
    memcpy(buf + 0x10, &v, 4);
}

/* --------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------ */
static volatile sig_atomic_t g_stop = 0;
static void sig_handler(int sig)
{
    (void)sig;
    g_stop = 1;
}

static inline uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void sleep_until_ns(uint64_t deadline)
{
    for (;;) {
        uint64_t n = now_ns();
        uint64_t d;
        struct timespec ts;

        if (n >= deadline || g_stop)
            return;
        d = deadline - n;
        ts.tv_sec = (time_t)(d / 1000000000ULL);
        ts.tv_nsec = (long)(d % 1000000000ULL);
        if (nanosleep(&ts, NULL) == 0 || errno != EINTR)
            return;
    }
}

static inline uint32_t align16_up(uint32_t v)
{
    return (v + (PKT_ALIGN - 1u)) & ~(PKT_ALIGN - 1u);
}

/* --------------------------------------------------------------------------
 * Command line
 * ------------------------------------------------------------------------ */
enum test_mode {
    MODE_RANDOM = 0,
    MODE_SWEEP,
    MODE_CORNER,
    MODE_FIXED,
};

struct test_config {
    uint32_t count;         /* 0 == infinite */
    enum test_mode mode;
    uint32_t min_size;
    uint32_t max_size;
    uint32_t fixed_size;
    uint32_t rate_pps;      /* 0 == unlimited */
    uint32_t seed;          /* length-selection + payload seed base */
    uint32_t slot_timeout_ms;
};

static const uint32_t sweep_sizes[] = {
    16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
    65536, 131072, 262144, 524288, 1048576
};

static const uint32_t corner_sizes[] = {
    16, 240, 256, 272, 512, 4080, 4096, 4112, 8192, 65520, 65536
};

static void usage(const char *argv0)
{
    printf("Usage: %s [options]\n"
           "  --count <N>          packets to send (default 1000, 0 = infinite)\n"
           "  --mode <mode>        random | sweep | corner | fixed | fixed:<bytes>\n"
           "  --size <bytes>       fixed-mode length (alias of --mode fixed:<bytes>)\n"
           "  --min-size <bytes>   random-mode lower bound (default 16; 32 = smallest legal)\n"
           "  --max-size <bytes>   random-mode upper bound (default 1048576)\n"
           "  --rate <pps>         max packets/second (default 0 = full speed)\n"
           "  --seed <n>           length/payload seed base (default 0x5EED1234)\n"
           "  --slot-timeout-ms <ms>  give up after N ms without a host slot (default 5000)\n"
           "  -h | --help          this text\n"
           "\n"
           "Stop sc7f0_vcud first: this tool needs the Packet DMA doorbell, the\n"
           "host ring and the DDR staging ring to itself.\n"
           "\n"
           "Sweep lengths: 32(=16 clamped) 32 64 ... 1048576 (powers of two)\n"
           "Corner lengths: 32(=16) 240 256 272 512 4080 4096 4112 8192 65520 65536\n",
           argv0);
}

static int parse_mode(const char *s, struct test_config *cfg)
{
    if (!strcmp(s, "random")) {
        cfg->mode = MODE_RANDOM;
    } else if (!strcmp(s, "sweep")) {
        cfg->mode = MODE_SWEEP;
    } else if (!strcmp(s, "corner")) {
        cfg->mode = MODE_CORNER;
    } else if (!strcmp(s, "fixed")) {
        cfg->mode = MODE_FIXED;
    } else if (!strncmp(s, "fixed:", 6)) {
        unsigned long v = strtoul(s + 6, NULL, 0);
        cfg->mode = MODE_FIXED;
        cfg->fixed_size = (uint32_t)v;
    } else {
        return -1;
    }
    return 0;
}

static int parse_args(int argc, char **argv, struct test_config *cfg)
{
    int i;
    uint32_t req_min, req_fixed;

    cfg->count = 1000;
    cfg->mode = MODE_RANDOM;
    cfg->min_size = 16;
    cfg->max_size = 1048576;
    cfg->fixed_size = 4096;
    cfg->rate_pps = 0;
    cfg->seed = 0x5EED1234u;
    cfg->slot_timeout_ms = 5000;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

        if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            usage(argv[0]);
            return 1;
        }
#define NEED_VAL()                                                    \
    do {                                                              \
        if (!v) {                                                     \
            fprintf(stderr, "ERROR: %s needs a value\n", a);          \
            return -1;                                                \
        }                                                             \
        i++;                                                          \
    } while (0)

        if (!strcmp(a, "--count")) {
            NEED_VAL();
            cfg->count = (uint32_t)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--mode")) {
            NEED_VAL();
            if (parse_mode(v, cfg) != 0) {
                fprintf(stderr, "ERROR: unknown mode '%s'\n", v);
                return -1;
            }
        } else if (!strcmp(a, "--size") || !strcmp(a, "--fixed")) {
            NEED_VAL();
            cfg->mode = MODE_FIXED;
            cfg->fixed_size = (uint32_t)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--min-size")) {
            NEED_VAL();
            cfg->min_size = (uint32_t)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--max-size")) {
            NEED_VAL();
            cfg->max_size = (uint32_t)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--rate")) {
            NEED_VAL();
            cfg->rate_pps = (uint32_t)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--seed")) {
            NEED_VAL();
            cfg->seed = (uint32_t)strtoul(v, NULL, 0);
        } else if (!strcmp(a, "--slot-timeout-ms")) {
            NEED_VAL();
            cfg->slot_timeout_ms = (uint32_t)strtoul(v, NULL, 0);
        } else {
            fprintf(stderr, "ERROR: unknown option '%s'\n", a);
            usage(argv[0]);
            return -1;
        }
#undef NEED_VAL
    }

    req_min = cfg->min_size;
    req_fixed = cfg->fixed_size;

    if (cfg->min_size < PKT_MIN_LEN)
        cfg->min_size = PKT_MIN_LEN;
    cfg->min_size = align16_up(cfg->min_size);
    cfg->max_size = cfg->max_size & ~(PKT_ALIGN - 1u);
    if (cfg->max_size > (uint32_t)STAGING_SLOT_SIZE)
        cfg->max_size = (uint32_t)STAGING_SLOT_SIZE;
    if (cfg->min_size > cfg->max_size)
        cfg->min_size = cfg->max_size;

    if (cfg->mode == MODE_FIXED) {
        cfg->fixed_size = align16_up(cfg->fixed_size);
        if (cfg->fixed_size < PKT_MIN_LEN)
            cfg->fixed_size = PKT_MIN_LEN;
        if (cfg->fixed_size > (uint32_t)STAGING_SLOT_SIZE)
            cfg->fixed_size = (uint32_t)STAGING_SLOT_SIZE;
    }

    if (req_min < PKT_MIN_LEN || req_fixed < PKT_MIN_LEN)
        printf("[PKT-TX] NOTE: payload/CRC region starts at offset %u, so the smallest "
               "legal packet is %u bytes - requests below that are tested as %u\n",
               PKT_PAYLOAD_OFF, PKT_MIN_LEN, PKT_MIN_LEN);
    return 0;
}

/* Pick the next packet length. Returns 0 when the schedule is exhausted
 * (only possible in finite-count fixed schedules that filtered everything). */
static uint32_t next_length(const struct test_config *cfg, uint64_t *lfsr,
                            size_t *cursor)
{
    switch (cfg->mode) {
    case MODE_FIXED:
        return cfg->fixed_size;

    case MODE_SWEEP: {
        size_t n = sizeof(sweep_sizes) / sizeof(sweep_sizes[0]);
        for (size_t k = 0; k < n; k++) {
            uint32_t l = sweep_sizes[(*cursor)++ % n];
            if (l < PKT_MIN_LEN)
                l = PKT_MIN_LEN;    /* sub-header length is not expressible */
            if (l >= cfg->min_size && l <= cfg->max_size)
                return l;
        }
        return 0;
    }

    case MODE_CORNER: {
        size_t n = sizeof(corner_sizes) / sizeof(corner_sizes[0]);
        for (size_t k = 0; k < n; k++) {
            uint32_t l = align16_up(corner_sizes[(*cursor)++ % n]);
            if (l < PKT_MIN_LEN)
                l = PKT_MIN_LEN;
            if (l >= cfg->min_size && l <= cfg->max_size)
                return l;
        }
        return 0;
    }

    case MODE_RANDOM:
    default: {
        uint64_t span_blocks, r;
        /* xorshift64* for the length stream: independent from the payload PRNG */
        uint64_t x = *lfsr;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        *lfsr = x;
        r = x * 2685821657736338717ULL;

        span_blocks = (uint64_t)((cfg->max_size - cfg->min_size) / PKT_ALIGN) + 1ULL;
        return cfg->min_size + (uint32_t)((r % span_blocks) * PKT_ALIGN);
    }
    }
}

/* --------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------ */
struct stats {
    uint64_t sent;
    uint64_t bytes;
    uint64_t no_slot;
    uint64_t too_big;
    uint64_t dma_busy;
    uint64_t hw_err_events;
    uint64_t last_len;
};

int main(int argc, char **argv)
{
    struct test_config cfg;
    struct stats st;
    int mem_fd = -1;
    int rc = 0;
    volatile uint8_t *csr = NULL;
    volatile uint8_t *bram = NULL;
    volatile uint8_t *ddr = NULL;
    volatile struct qpcie_vcu_host_ring *ring = NULL;
    uint32_t probe_err_base, probe_submit_base;
    uint64_t lfsr;
    size_t cursor = 0;
    uint64_t t_start, t_report, deadline = 0;
    uint64_t interval_ns = 0;
    uint32_t seq = 0;
    uint32_t sent_in_window = 0;
    uint64_t bytes_in_window = 0;
    uint32_t consecutive_no_slot = 0;

    crc32_init();

    {
        int pr = parse_args(argc, argv, &cfg);
        if (pr < 0)
            return 2;
        if (pr > 0)
            return 0;
    }

    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = sig_handler;
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
    }

    printf("[PKT-TX] SC7F0 Packet DMA unit test (Card PS)\n");
    printf("[PKT-TX] mode=%s count=%u min=%u max=%u fixed=%u rate=%s seed=0x%08x\n",
           cfg.mode == MODE_RANDOM ? "random" :
           cfg.mode == MODE_SWEEP  ? "sweep"  :
           cfg.mode == MODE_CORNER ? "corner" : "fixed",
           cfg.count, cfg.min_size, cfg.max_size, cfg.fixed_size,
           cfg.rate_pps ? "limited" : "full-speed", cfg.seed);

    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("[PKT-TX ERROR] Cannot open /dev/mem");
        return 1;
    }

    csr = (volatile uint8_t *)mmap(NULL, PL_CSR_PACKET_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, mem_fd, (off_t)PL_CSR_PACKET_ADDR);
    if (csr == MAP_FAILED) {
        perror("[PKT-TX ERROR] Cannot map PL CSR Packet DMA @0xB0040000");
        close(mem_fd);
        return 1;
    }

    bram = (volatile uint8_t *)mmap(NULL, PL_SHARED_BRAM_SIZE, PROT_READ | PROT_WRITE,
                                    MAP_SHARED, mem_fd, (off_t)PL_SHARED_BRAM_ADDR);
    if (bram == MAP_FAILED) {
        perror("[PKT-TX ERROR] Cannot map PL Shared BRAM @0xA0002000");
        munmap((void *)csr, PL_CSR_PACKET_SIZE);
        close(mem_fd);
        return 1;
    }

    ddr = (volatile uint8_t *)mmap(NULL, (size_t)STAGING_RING_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, mem_fd, (off_t)DDR_STAGING_BUF_ADDR);
    if (ddr == MAP_FAILED) {
        perror("[PKT-TX ERROR] Cannot map DDR staging ring @0x50000000");
        munmap((void *)bram, PL_SHARED_BRAM_SIZE);
        munmap((void *)csr, PL_CSR_PACKET_SIZE);
        close(mem_fd);
        return 1;
    }

#define CSR_R32(off)     (*(volatile uint32_t *)(csr + (off)))
#define CSR_W32(off, vv) (*(volatile uint32_t *)(csr + (off)) = (uint32_t)(vv))

    {
        uint32_t magic = CSR_R32(REG_PKT_MAGIC);
        uint32_t version = CSR_R32(REG_PKT_VERSION);
        printf("[PKT-TX] Packet DMA CSR: magic=0x%08x (\"%c%c%c%c\") version=0x%08x\n",
               magic,
               (magic >> 0) & 0xFF, (magic >> 8) & 0xFF,
               (magic >> 16) & 0xFF, (magic >> 24) & 0xFF,
               version);
        if (magic != PKT_CSR_MAGIC_VALUE)
            printf("[PKT-TX WARNING] unexpected Packet DMA magic (expected 0x44505631 "
                   "\"DPV1\") - PL bitstream mismatch?\n");
    }

    ring = (volatile struct qpcie_vcu_host_ring *)(bram + MAILBOX_VCU_RING_OFFSET);
    printf("[PKT-TX] host ring @0x%08llx: magic=0x%08x version=%u ring_size=%u "
           "host_head=%u ps_tail=%u\n",
           (unsigned long long)(PL_SHARED_BRAM_ADDR + MAILBOX_VCU_RING_OFFSET),
           ring->magic, ring->version, ring->ring_size, ring->host_head, ring->ps_tail);

    if (ring->magic != QPCIE_VCU_RING_MAGIC) {
        fprintf(stderr, "[PKT-TX ERROR] host ring magic 0x%08x != 0x56435552 (\"VCUR\").\n"
                        "              The host V4L2 driver has not published its ring:\n"
                        "              load qpcie with c2h_only=1 and open /dev/video1\n"
                        "              (run test_app/host_pkt_dma_test first).\n",
                ring->magic);
        rc = 3;
        goto out;
    }

    probe_err_base = CSR_R32(REG_PKT_PROBE_ERR);
    probe_submit_base = CSR_R32(REG_PKT_PROBE_SUBMIT);
    lfsr = (uint64_t)(cfg.seed ? cfg.seed : 0x5EED1234u) * 0x9E3779B97F4A7C15ULL | 1ULL;
    if (cfg.rate_pps)
        interval_ns = 1000000000ULL / (uint64_t)cfg.rate_pps;

    memset(&st, 0, sizeof(st));
    t_start = t_report = now_ns();
    if (interval_ns)
        deadline = t_start;

    printf("[PKT-TX] baseline probes: submit=%u err=%u drops=%u\n",
           probe_submit_base, probe_err_base, CSR_R32(REG_PKT_DROPS));
    printf("[PKT-TX] streaming... (Ctrl-C to stop and print statistics)\n");

    while (!g_stop) {
        uint32_t len, tail, head, slot_idx, host_cap, seed;
        uint32_t status;
        uint64_t slot_wait_start;
        /* Latched slot descriptor fields: MUST be read before ps_tail is advanced
         * (see the latch below), never re-read from the slot afterwards. */
        uint64_t dst_phys, comp_phys;
        volatile struct qpcie_vcu_buffer_slot *slot;
        uint8_t *slot_buf;
        uint64_t slot_phys;

        if (cfg.count && seq >= cfg.count)
            break;

        /* --- acquire a host ring credit ---------------------------------
         * host_head/ps_tail are monotonically increasing counters; a slot is
         * available exactly while (int32)(host_head - ps_tail) > 0.  A credit
         * only counts as usable once the host has actually written the slot
         * descriptor fields (they land in BRAM a few AXI writes before host_head,
         * but a driver without a completion ring would legitimately leave
         * host_comp_addr at 0, so bound the wait instead of spinning forever). */
        tail = ring->ps_tail;
        head = ring->host_head;
        slot_wait_start = now_ns();
        for (;;) {
            int have_credit = ((int32_t)(head - tail) > 0);

            if (have_credit) {
                volatile struct qpcie_vcu_buffer_slot *s =
                    &ring->slots[tail % QPCIE_VCU_RING_SIZE];
                if (s->host_phys_addr && s->host_comp_addr && s->host_buf_len)
                    break;
            }
            if (g_stop) {
                rc = 0;
                goto summary;
            }
            usleep(50);
            tail = ring->ps_tail;
            head = ring->host_head;
            if (cfg.slot_timeout_ms &&
                (now_ns() - slot_wait_start) > (uint64_t)cfg.slot_timeout_ms * 1000000ULL) {
                st.no_slot++;
                if (++consecutive_no_slot >= 5) {
                    fprintf(stderr, "[PKT-TX ERROR] no usable host ring slot for %u ms "
                                    "(head=%u tail=%u). Host stopped capturing, or no "
                                    "DPC1 completion ring published?\n",
                            cfg.slot_timeout_ms, head, tail);
                    rc = 4;
                    goto summary;
                }
            }
        }
        consecutive_no_slot = 0;

        slot_idx = tail % QPCIE_VCU_RING_SIZE;
        slot = &ring->slots[slot_idx];

        /* --- latch the slot descriptor NOW, before ps_tail is advanced ----
         * Writing ring->ps_tail into BRAM releases this slot to the host: the
         * 5 GHz host CPU can observe it within ~1 us, retire the buffer and
         * re-queue it (DQBUF/QBUF), overwriting host_phys_addr /
         * host_comp_addr / host_buf_len with the *next* frame's addresses while
         * we are still building the descriptor. Reading those fields after
         * ps_tail++ therefore yields a torn or stale address and the host
         * reports "VCU slot X DPC1 mismatch" and stalls.
         * Same ordering as sc7f0_vcud.cpp: latch first, publish the credit last.
         * Once latched, the slot must never be dereferenced again this iteration. */
        dst_phys  = slot->host_phys_addr;
        comp_phys = slot->host_comp_addr;
        host_cap  = slot->host_buf_len;
        __sync_synchronize();     /* order the latched reads before ps_tail++ */

        if (!dst_phys || !comp_phys || !host_cap) {
            /* Credit vanished between the availability poll and the latch:
             * drop this round without consuming a seq and without publishing
             * ps_tail, so the host never sees a slot we did not transmit. */
            st.no_slot++;
            if (st.no_slot <= 5 || (st.no_slot % 100) == 0)
                fprintf(stderr, "[PKT-TX WARN] slot %u latched empty "
                                "(dst=0x%lx comp=0x%lx cap=%u) [n=%" PRIu64 "]\n",
                        slot_idx, (unsigned long)dst_phys,
                        (unsigned long)comp_phys, host_cap, st.no_slot);
            continue;
        }

        len = next_length(&cfg, &lfsr, &cursor);
        if (len == 0) {
            printf("[PKT-TX] length schedule exhausted (every entry outside "
                   "[--min-size, --max-size]), stopping\n");
            break;
        }
        if (len > host_cap) {
            st.too_big++;
            if (st.too_big > 4096) {
                fprintf(stderr, "[PKT-TX ERROR] requested length > host buffer capacity "
                                "(%u > %u) for %" PRIu64 " packets: lower --max-size "
                                "or --size\n", len, host_cap, st.too_big);
                rc = 6;
                goto summary;
            }
            /* Do NOT consume a seq: the host must see a gap-free sequence. */
            continue;
        }

        /* Debug trace for the first few packets: the exact values that are about
         * to be staged into the descriptor. Printed only once len is known and
         * validated, so dst/comp/cap/len all belong to this transmission. */
        if (seq < 5)
            printf("[PKT-TX DEBUG] seq=%u slot=%u: dst_phys=0x%llx comp_phys=0x%llx "
                   "host_cap=%u len=%u\n",
                   seq, slot_idx, (unsigned long long)dst_phys,
                   (unsigned long long)comp_phys, host_cap, len);

        /* --- make sure the engine can actually take the job FIRST ---------
         * This runs before the credit is published: bailing out after
         * ps_tail++ would hand the host a slot that nothing is ever
         * transmitted into, and it costs only a CSR read when the engine is
         * idle anyway. */
        while (CSR_R32(REG_PKT_STATUS) & PKT_STATUS_DONE_VALID)
            CSR_W32(REG_PKT_DOORBELL_POP, 1);   /* keep the done FIFO draining */

        status = CSR_R32(REG_PKT_STATUS);
        if (!(status & PKT_STATUS_READY)) {
            int timeout_us = 20000;
            while (!(status & PKT_STATUS_READY) && timeout_us > 0 && !g_stop) {
                if (status & PKT_STATUS_DONE_VALID)
                    CSR_W32(REG_PKT_DOORBELL_POP, 1);
                usleep(50);
                timeout_us -= 50;
                status = CSR_R32(REG_PKT_STATUS);
            }
            if (!(status & PKT_STATUS_READY)) {
                st.dma_busy++;
                if (st.dma_busy <= 5 || (st.dma_busy % 100) == 0)
                    fprintf(stderr, "[PKT-TX WARN] Packet DMA not ready "
                                    "(status=0x%08x fsm=0x%08x) #%" PRIu64 "\n",
                            status, CSR_R32(REG_PKT_PROBE_FSM), st.dma_busy);
                continue;
            }
        }

        /* --- build the packet in this slot's private 1 MiB DDR staging slot */
        slot_buf = (uint8_t *)ddr + (size_t)slot_idx * (size_t)STAGING_SLOT_SIZE;
        slot_phys = DDR_STAGING_BUF_ADDR + (uint64_t)slot_idx * STAGING_SLOT_SIZE;
        seed = (seq * 0x9E3779B1u) ^ 0xA53C9EF7u ^ cfg.seed;
        packet_build(slot_buf, seq, len, seed);
        __sync_synchronize();

        /* --- 768-bit (24 x 32-bit) descriptor staging, identical to sc7f0_vcud *
         * Uses only the values latched above: the slot belongs to the host from
         * here on, so slot->host_phys_addr / host_comp_addr are off limits. */
        {
            volatile uint32_t *stage = (volatile uint32_t *)(csr + REG_PKT_STAGE_BASE);
            uint64_t pts_ticks = (now_ns() / 1000ULL) * 150ULL;
            int w;

            for (w = 0; w < 24; w++)
                stage[w] = 0;

            stage[0]  = (uint32_t)(slot_phys & 0xFFFFFFFFu);   /* csrc[31:0]   */
            stage[1]  = (uint32_t)(slot_phys >> 32);           /* csrc[63:32]  */
            /* Descriptor layout is fixed by the RTL, and is byte-for-byte the
             * same one sc7f0_vcud.cpp programs (see its staging block):
             *   rtl/sc7f0_dualpath_regs.v maps stage[i] directly onto
             *   cmd_data[i*32+:32], and rtl/sc7f0_ps_packet_reader.v decodes
             *     csrc  = cmd_data[63:0]     -> stage[0..1]  source DDR addr
             *     cdst  = cmd_data[127:64]   -> stage[2..3]  payload dest
             *     clen  = cmd_data[159:128]  -> stage[4]
             *     ccap  = cmd_data[191:160]  -> stage[5]
             *     ccomp = cmd_data[255:192]  -> stage[6..7]  64B record dest
             * cdst is used as tx_addr for every data chunk, ccomp is the tx_addr
             * of the RECORD state, so swapping the two DMA's the packet payload
             * into the driver's 64B-per-slot completion ring. */
            stage[2]  = (uint32_t)(dst_phys & 0xFFFFFFFFu);    /* cdst[31:0]   */
            stage[3]  = (uint32_t)(dst_phys >> 32);            /* cdst[63:32]  */
            stage[4]  = len;                                   /* clen         */
            stage[5]  = host_cap;                              /* ccap         */
            stage[6]  = (uint32_t)(comp_phys & 0xFFFFFFFFu);   /* ccomp[31:0]  */
            stage[7]  = (uint32_t)(comp_phys >> 32);           /* ccomp[63:32] */
            /* PTS travels in the hardware timebase: 1 us == 150 ticks @ 150 MHz
             * (REG_PKT_CLOCK_HZ), which is what qpcie_v4l2_node_done() divides
             * by 150 to rebuild nanoseconds. Raw microseconds would scale every
             * vb2 timestamp by 150x. */
            stage[8]  = (uint32_t)(pts_ticks & 0xFFFFFFFFu);
            stage[9]  = (uint32_t)(pts_ticks >> 32);
            stage[10] = seq;                                   /* seq[31:0]    */
            stage[11] = 0;                                     /* seq[63:32]   */
            stage[16] = 0;                                     /* flags        */

            /* Debug trace: read the staged descriptor back before the doorbell,
             * to prove the 64-bit dst/comp addresses reached the staging regs. */
            if (seq < 5)
                printf("[PKT-TX DEBUG] stage[2..3](dst)=0x%08x_%08x "
                       "stage[6..7](comp)=0x%08x_%08x\n",
                       stage[3], stage[2], stage[7], stage[6]);

            __sync_synchronize();

            CSR_W32(REG_PKT_DOORBELL_PUSH, 1);
            __sync_synchronize();
        }

        /* --- hand the credit back AFTER ringing the doorbell -------------
         * ps_tail is the credit the host uses to retire and re-queue this
         * buffer (DQBUF/QBUF), so publishing it is the last step of the
         * handshake.  Publishing it before the descriptor reached the staging
         * registers let the 5 GHz host see the credit released, recycle the
         * slot into the next QBUF, and republish host_phys_addr /
         * host_comp_addr while the FPGA had not even started the DMA yet - the
         * transfer then lands in (or completes into) a buffer the host already
         * handed to another frame.  Ordering: stage fully written -> barrier ->
         * doorbell -> barrier -> ps_tail visible in BRAM (read-back drains the
         * posted write).  The slot descriptor fields themselves were latched
         * above, so nothing here dereferences the slot again. */
        ring->ps_tail = tail + 1;
        __sync_synchronize();
        {
            volatile uint32_t committed = ring->ps_tail;
            (void)committed;    /* read-back: drain the posted BRAM write */
        }
        __sync_synchronize();

        st.sent++;
        st.bytes += len;
        seq++;
        sent_in_window++;
        bytes_in_window += len;

        /* --- live hardware error probe ---------------------------------- */
        {
            uint32_t err = CSR_R32(REG_PKT_PROBE_ERR);
            uint32_t last_len = CSR_R32(REG_PKT_PROBE_LAST_LEN);
            st.last_len = last_len;
            if (err != probe_err_base) {
                st.hw_err_events += (uint32_t)(err - probe_err_base);
                probe_err_base = err;
                fprintf(stderr, "[PKT-TX HW-ERROR] REG_PKT_PROBE_ERR=%u "
                                "seq=%u len=%u last_len=%u status=0x%08x fsm=0x%08x\n",
                        err, seq - 1, len, last_len,
                        CSR_R32(REG_PKT_STATUS), CSR_R32(REG_PKT_PROBE_FSM));
            }
        }

        /* --- rate limit + 1 Hz status line ------------------------------ */
        if (interval_ns) {
            deadline += interval_ns;
            sleep_until_ns(deadline);
        }

        {
            uint64_t t = now_ns();
            if (t - t_report >= 1000000000ULL) {
                double win_s = (double)(t - t_report) / 1e9;
                double mbps = (double)bytes_in_window / win_s / (1024.0 * 1024.0);
                printf("[PKT-TX] pkts=%" PRIu64 " (%.0f pps) %.2f MB/s "
                       "len=%u err=%" PRIu64 " no-slot=%" PRIu64
                       " busy=%" PRIu64 " tail=%u head=%u last_len=%u\n",
                       st.sent, (double)sent_in_window / win_s, mbps, len,
                       st.hw_err_events, st.no_slot, st.dma_busy,
                       ring->ps_tail, ring->host_head, (unsigned)st.last_len);
                fflush(stdout);
                sent_in_window = 0;
                bytes_in_window = 0;
                t_report = t;
            }
        }
    }

summary:
    {
        uint64_t t = now_ns();
        double el = (double)(t - t_start) / 1e9;
        if (el <= 0.0)
            el = 1e-9;

        printf("\n[PKT-TX] ==================== TRANSMIT SUMMARY ====================\n");
        printf("[PKT-TX] packets sent      : %" PRIu64 "\n", st.sent);
        printf("[PKT-TX] bytes sent        : %" PRIu64 " (%.2f MiB)\n",
               st.bytes, (double)st.bytes / (1024.0 * 1024.0));
        printf("[PKT-TX] elapsed           : %.3f s\n", el);
        printf("[PKT-TX] average throughput: %.2f MB/s @ %.0f pps\n",
               (double)st.bytes / el / (1024.0 * 1024.0), (double)st.sent / el);
        printf("[PKT-TX] HW error events   : %" PRIu64 "\n", st.hw_err_events);
        printf("[PKT-TX] slot timeouts     : %" PRIu64 " (no host credit)\n", st.no_slot);
        printf("[PKT-TX] oversize rejects  : %" PRIu64 "\n", st.too_big);
        printf("[PKT-TX] DMA not-ready     : %" PRIu64 "\n", st.dma_busy);
        printf("[PKT-TX] ring head=%u tail=%u dropped=%u\n",
               ring->host_head, ring->ps_tail, ring->dropped_count);
        printf("[PKT-TX] PL probes: submit=%u done=%u err=%u msi=%u drops=%u "
               "fsm=0x%08x last_len=%u\n",
               CSR_R32(REG_PKT_PROBE_SUBMIT), CSR_R32(REG_PKT_PROBE_DONE),
               CSR_R32(REG_PKT_PROBE_ERR), CSR_R32(REG_PKT_PROBE_MSI),
               CSR_R32(REG_PKT_DROPS), CSR_R32(REG_PKT_PROBE_FSM),
               CSR_R32(REG_PKT_PROBE_LAST_LEN));
        printf("[PKT-TX] =============================================================\n");
        fflush(stdout);

        if (st.hw_err_events)
            rc = 5;
    }

out:
    if (ddr)
        munmap((void *)ddr, (size_t)STAGING_RING_SIZE);
    if (bram)
        munmap((void *)bram, PL_SHARED_BRAM_SIZE);
    if (csr)
        munmap((void *)csr, PL_CSR_PACKET_SIZE);
    if (mem_fd >= 0)
        close(mem_fd);
    return rc;
}
