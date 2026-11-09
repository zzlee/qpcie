// SPDX-License-Identifier: GPL-2.0-only
/*
 * SC7F0 VCU Video Encoder & Packet DMA Bridge Daemon (sc7f0_vcud)
 *
 * Runs on ZU4EV ARM64 Linux (Card PS).
 * Bridges:
 *   1. V4L2 VIPP /dev/video0 (NV12 input from HDMI RX) via DMA-BUF zero-copy
 *   2. VCU Hard IP (H.264 hardware encoder) via OpenMAX IL (OMX.allegro.h264.hardware.encoder)
 *   3. Shared BRAM Mailbox @ 0xA0002100 (vcu_encoder_config from Host V4L2 driver)
 *   4. Shared BRAM Host Ring @ 0xA0002200 (Host buffer credits from Host V4L2 queue)
 *   5. PL Packet C2H DMA @ 0xB0040000 (Multi-GB/s posted writes + MSI interrupts to Host)
 *
 * Zero-Copy Architecture:
 *   - V4L2 VIPP writes raw NV12 directly to PS DDR.
 *   - V4L2 exports buffer file descriptors using VIDIOC_EXPBUF (dmafd).
 *   - OpenMAX IL imports dmafd on port 0 using OMX_ALG_BUF_DMA and OMX_UseBuffer.
 *   - VCU Hard IP reads NV12 directly from DDR over AXI bus with ZERO CPU copies.
 *   - Encoded compressed bitstreams (~10KB - 100KB) are transferred across PCIe via PL Packet DMA.
 *   - A card-side hardware output pacer decouples the encoder from the link:
 *     FillBufferDone only queues the Access Unit and instantly recycles the
 *     OpenMAX buffer, while a dedicated pacer thread meters the stream out to
 *     the Packet DMA engine at the capture cadence (60Hz) using absolute
 *     CLOCK_MONOTONIC deadlines. See "Card-Side Hardware Output Pacer" below.
 *
 * Safety: NEVER opens /dev/watchdog; encoder faults stop/restart without card reset.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <semaphore.h>

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>
#include <vector>

extern "C" {
#include <OMX_Core.h>
#include <OMX_Component.h>
#include <OMX_Types.h>
#include <OMX_Video.h>
#include <OMX_VideoExt.h>
#include <OMX_ComponentExt.h>
#include <OMX_IndexExt.h>
#include <OMX_IndexAlg.h>
#include <OMX_IVCommonAlg.h>
#include <OMX_VideoAlg.h>
}

/* Physical Address Map on Card PS */
#define PL_CSR_PACKET_ADDR      0xB0040000ULL
#define PL_CSR_PACKET_SIZE      0x1000ULL       /* 4 KiB */
#define PL_SHARED_BRAM_ADDR     0xA0002000ULL
#define PL_SHARED_BRAM_SIZE     0x2000ULL       /* 8 KiB */
#define DDR_STAGING_BUF_ADDR    0x50000000ULL   /* cma,qdmabuf reserved pool */
#define DDR_STAGING_BUF_SIZE    (64 * 1024 * 1024ULL) /* 64 MiB */

/* PL Packet DMA CSR Offsets (from 0xB0040000) */
#define REG_PKT_MAGIC           0x000   /* 0x44505631 ("DPV1") */
#define REG_PKT_VERSION         0x004   /* 0x00010000 */
#define REG_PKT_STATUS          0x008   /* [1]=packet_ready, [3]=packet_valid, [5:4]=busy */
#define REG_PKT_DOORBELL_PUSH   0x014   /* Write 1: push packet_stage into command FIFO */
#define REG_PKT_DOORBELL_POP    0x018   /* Write 1: pop packet_done */
#define REG_PKT_CLOCK_HZ        0x01c   /* 150,000,000 */
#define REG_PKT_DROPS           0x020
#define REG_PKT_STAGE_BASE      0x080   /* 24 words (768 bits) command staging */
#define REG_PKT_PROBE_SUBMIT    0x100   /* Submissions counter */
#define REG_PKT_PROBE_DONE      0x104   /* Completions counter */
#define REG_PKT_PROBE_ERR       0x108   /* Errors counter */
#define REG_PKT_PROBE_MSI       0x10C   /* MSI interrupts sent counter */
#define REG_PKT_PROBE_BYTES_LO  0x110
#define REG_PKT_PROBE_BYTES_HI  0x114
#define REG_PKT_PROBE_FSM       0x118   /* FSM state */
#define REG_PKT_PROBE_LAST_LEN  0x11C   /* Last payload length */
#define REG_PKT_PROBE_LAST_PTS_LO 0x120
#define REG_PKT_PROBE_LAST_PTS_HI 0x124
#define REG_PKT_DONE_BASE       0x240   /* 16 words (512 bits) completion record */

/* Shared BRAM Mailbox Offsets (from 0xA0002000) */
#define MAILBOX_VCU_CFG_OFFSET  0x100   /* Physical 0xA0002100 */
#define MAILBOX_VCU_RING_OFFSET 0x200   /* Physical 0xA0002200 */

#define QPCIE_VCU_CFG_MAGIC     0x56435543 /* "VCUC" */
#define QPCIE_VCU_RING_MAGIC    0x56435552 /* "VCUR" */
#define QPCIE_VCU_RING_SIZE     16

#define VCU_WIDTH               3840
#define VCU_HEIGHT              2160
#define NUM_IN_BUFFERS          8
#define NUM_OUT_BUFFERS         8

struct __attribute__((packed)) qpcie_vcu_encoder_config {
    uint32_t magic;                /* 0x00: "VCUC" */
    uint32_t version;              /* 0x04: 1 */
    uint32_t config_seq;           /* 0x08: monotonic incrementing */
    uint32_t codec_type;           /* 0x0C: 0=H.264, 1=HEVC */

    /* Rate Control */
    uint32_t bitrate_mode;         /* 0x10: 0=VBR, 1=CBR, 2=CQ */
    uint32_t bitrate;              /* 0x14: Target bitrate in bps */
    uint32_t bitrate_peak;         /* 0x18: Peak bitrate in bps */
    uint32_t frame_rc_enable;      /* 0x1C: Frame RC */
    uint32_t mb_rc_enable;         /* 0x20: MB/CTU RC */
    uint32_t const_quality;        /* 0x24: Constant Quality QP (0..51) */

    /* GOP Structure */
    uint32_t gop_size;             /* 0x28: GOP size */
    uint32_t b_frames;             /* 0x2C: Consecutive B-frames */
    uint32_t force_idr;            /* 0x30: 1=Generate IDR */
    uint32_t repeat_seq_header;    /* 0x34: 1=Repeat SPS/PPS on IDR */
    uint32_t header_mode;          /* 0x38: 0=Separate, 1=Joined */

    /* H.264 Specific */
    uint32_t h264_profile;         /* 0x3C */
    uint32_t h264_level;           /* 0x40 */
    uint32_t h264_entropy_mode;    /* 0x44 */
    uint32_t h264_min_qp;          /* 0x48 */
    uint32_t h264_max_qp;          /* 0x4C */
    uint32_t h264_i_qp;            /* 0x50 */
    uint32_t h264_p_qp;            /* 0x54 */
    uint32_t h264_b_qp;            /* 0x58 */
    uint32_t h264_cpb_size;        /* 0x5C */
    uint32_t h264_loop_filter_mode;/* 0x60 */
    uint32_t h264_8x8_transform;   /* 0x64 */

    /* HEVC Specific */
    uint32_t hevc_profile;         /* 0x68 */
    uint32_t hevc_level;           /* 0x6C */
    uint32_t hevc_tier;            /* 0x70 */
    uint32_t hevc_min_qp;          /* 0x74 */
    uint32_t hevc_max_qp;          /* 0x78 */
    uint32_t hevc_i_qp;            /* 0x7C */
    uint32_t hevc_p_qp;            /* 0x80 */
    uint32_t hevc_b_qp;            /* 0x84 */
    uint32_t hevc_loop_filter_mode;/* 0x88 */
    uint32_t hevc_refresh_type;    /* 0x8C */
    uint32_t hevc_strong_smoothing;/* 0x90 */
    uint32_t hevc_const_intra_pred;/* 0x94 */
    uint32_t hevc_wavefront;       /* 0x98 */

    /* Slicing & Resilience */
    uint32_t slice_mode;           /* 0x9C */
    uint32_t slice_max_bytes;      /* 0xA0 */
    uint32_t slice_max_mb;         /* 0xA4 */
    uint32_t intra_refresh_mb;     /* 0xA8 */

    /* Status & Feedback to Host */
    uint32_t ps_ack_seq;           /* 0xAC: PS writes matching config_seq */
    uint32_t ps_encoder_status;    /* 0xB0: 1=Encoding, 0=Idle, <0=Error */
    uint32_t ps_fps_actual;        /* 0xB4: Actual FPS * 100 */
    uint32_t ps_bitrate_actual;    /* 0xB8: Actual bitrate in bps */

    /* Card-side Hardware Output Pacer (Host writes, Card reads) */
    uint32_t pacer_enable;         /* 0xBC: 1=Enable hardware pacer, 0=Direct push */
    uint32_t pacer_buffer_frames;  /* 0xC0: Buffer depth in frames before pacing starts (default: 8, range: 0..30) */
};

/* Mailbox offsets of the two pacer knobs. The Host driver mirrors the whole
 * struct word-by-word into BAR0 QPCIE_BAR0_VCU_CFG_OFFSET (physical
 * 0xA0002100), so these must stay exactly where the layout above puts them:
 *   BAR0 0x21BC / PS 0xA00021BC -> pacer_enable       (+0xBC)
 *   BAR0 0x21C0 / PS 0xA00021C0 -> pacer_buffer_frames (+0xC0)
 * Mirror of QPCIE_VCU_CFG_PACER_{ENABLE,BUFFER_FRAMES}_OFFSET in
 * driver/qpcie_driver.h; the Host side pins the same values with BUILD_BUG_ON. */
#define VCU_CFG_PACER_ENABLE_OFFSET        0xBC
#define VCU_CFG_PACER_BUFFER_FRAMES_OFFSET 0xC0

static_assert(offsetof(struct qpcie_vcu_encoder_config, pacer_enable) ==
              VCU_CFG_PACER_ENABLE_OFFSET,
              "pacer_enable must live at mailbox offset 0xBC (host/driver ABI)");
static_assert(offsetof(struct qpcie_vcu_encoder_config, pacer_buffer_frames) ==
              VCU_CFG_PACER_BUFFER_FRAMES_OFFSET,
              "pacer_buffer_frames must live at mailbox offset 0xC0 (host/driver ABI)");

struct __attribute__((packed)) qpcie_vcu_buffer_slot {
    uint64_t host_phys_addr;    /* 0x00: Host physical address for payload */
    uint64_t host_comp_addr;    /* 0x08: Host physical address for 64B DPC1 record */
    uint32_t host_buf_len;      /* 0x10: Buffer capacity in bytes */
    uint32_t host_buf_id;       /* 0x14: VB2 buffer index / cookie */
    uint32_t flags;             /* 0x18 */
    uint32_t reserved;          /* 0x1C */
};

/* WARNING: instances of this struct live in PL BRAM, mapped from /dev/mem as
 * Device memory (nGnRE). They must only ever be touched with plain volatile
 * loads/stores - see host_ring_bump_dropped() for the one place that needs an
 * update-in-place. */
struct __attribute__((packed)) qpcie_vcu_host_ring {
    uint32_t magic;             /* 0x00: "VCUR" */
    uint32_t version;           /* 0x04: 1 */
    uint32_t ring_size;         /* 0x08: 16 */
    uint32_t host_head;         /* 0x0C: Host increments upon QBUF */
    uint32_t ps_tail;           /* 0x10: PS increments after submitting Packet DMA */
    uint32_t dropped_count;     /* 0x14 */
    uint32_t reserved[10];      /* 0x18..0x3C */
    struct qpcie_vcu_buffer_slot slots[QPCIE_VCU_RING_SIZE]; /* 512 bytes */
};

struct h264_stream_frame {
    size_t offset;
    size_t length;
    bool is_idr;
};

struct h264_stream {
    uint8_t *data;
    size_t total_size;
    struct h264_stream_frame *frames;
    uint32_t num_frames;
};

/* Forward declarations */
struct vcud_ctx;

template<typename T>
static void initHeader(T& header) {
    memset(&header, 0, sizeof(T));
    header.nSize = sizeof(header);
    header.nVersion.s.nVersionMajor = OMX_VERSION_MAJOR;
    header.nVersion.s.nVersionMinor = OMX_VERSION_MINOR;
    header.nVersion.s.nRevision = OMX_VERSION_REVISION;
    header.nVersion.s.nStep = OMX_VERSION_STEP;
}

/* ==========================================================================
 * Card-Side Hardware Output Pacer - queue types
 * ========================================================================== */
#define PACER_QUEUE_CAPACITY        32             /* AUs held in flight      */
#define PACER_DEFAULT_BUFFER_FRAMES 8              /* Host driver default     */
#define PACER_MIN_BUFFER_FRAMES     1
#define PACER_MAX_BUFFER_FRAMES     30             /* mailbox control is 0..30 */
#define PACER_LATE_RESYNC_NS        100000000ULL   /* 100ms late -> re-anchor */
#define PACER_QUEUE_TICK_NS         50000000ULL    /* cond wait granularity   */
#define PACER_PRIME_TIMEOUT_NS      1000000000ULL  /* never stall priming >1s */
#define PACER_PTS_MIN_INTERVAL_NS   500000ULL      /* below: bogus PTS delta   */
#define PACER_PTS_MAX_INTERVAL_NS   250000000ULL   /* above: bogus PTS delta   */

/* One encoded Access Unit parked in the pacer queue. The payload is already
 * self contained: the cached SPS/PPS pair has been stitched in front of any
 * IDR that the encoder emitted without sequence parameters. */
struct pacer_frame {
    std::vector<uint8_t> payload;
    uint64_t pts_us{0};      /* raw HDMI RX capture timestamp ( microseconds)  */
    uint32_t flags{0};       /* Packet DMA AU flags                            */
    bool is_idr{false};
    bool has_sps{false};
};

/* Bounded SPSC ring: producer = OpenMAX FillBufferDone callback thread,
 * consumer = pacer thread. head/tail are monotonically increasing counters so
 * "empty" and "full" stay unambiguous (count = tail - head). */
struct pacer_state {
    struct pacer_frame frames[PACER_QUEUE_CAPACITY];
    uint32_t head{0};
    uint32_t tail{0};

    pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t  cv  = PTHREAD_COND_INITIALIZER;   /* re-inited on CLOCK_MONOTONIC */

    /* Telemetry: written by both threads, read by the 1 Hz stats printer. */
    std::atomic<uint32_t> depth{0};
    std::atomic<uint32_t> peak_depth{0};
    std::atomic<uint32_t> queued{0};
    std::atomic<uint32_t> queue_full_drops{0};
    std::atomic<uint32_t> flushed{0};
    std::atomic<uint32_t> resyncs{0};
    std::atomic<uint32_t> anchors{0};
};

/* Global runtime context */
struct vcud_ctx {
    int mem_fd;
    volatile uint8_t *csr_base;
    volatile uint8_t *bram_base;
    volatile uint8_t *ddr_staging;

    volatile struct qpcie_vcu_encoder_config *vcu_cfg;
    volatile struct qpcie_vcu_host_ring *host_ring;

    bool live_mode;
    bool pattern_mode;
    const char *h264_file;
    struct h264_stream h264_st;
    uint32_t target_fps;
    uint32_t max_frames;

    /* Live DMA-BUF V4L2 & OpenMAX State */
    int v4l2_fd;
    enum v4l2_buf_type v4l2_type;
    int dma_fds[NUM_IN_BUFFERS];
    OMX_HANDLETYPE hEncoder;
    sem_t semState;
    OMX_BUFFERHEADERTYPE* inHeaders[NUM_IN_BUFFERS];
    OMX_BUFFERHEADERTYPE* outHeaders[NUM_OUT_BUFFERS];

    uint32_t local_ack_seq;
    uint64_t frame_seq;
    std::atomic<uint64_t> total_bytes_sent{0};
    std::atomic<uint32_t> frames_sent{0};
    std::atomic<uint32_t> frames_dropped{0};

    std::vector<uint8_t> cached_sps_pps;
    bool need_idr_on_connect{true};
    bool was_host_connected{false};
    /* IDR synchronisation guard: becomes true once an AU that carries an IDR
     * slice (or at least an SPS) has actually been handed to the host since the
     * last (re)connection. Until then plain P-frame AUs are dropped so a cold
     * host decoder never receives a reference-less picture. */
    bool has_streamed_idr{false};
    uint32_t pre_idr_drops{0};
    /* Consecutive callback ticks where the host ring reported head == tail (no
     * usable host buffer). host_head / ps_tail are monotonically increasing
     * counters that never wrap back to 0 on streamoff, so "head == 0 &&
     * tail == 0" can only be true once per process lifetime. Counting matches
     * instead lets us detect a real host stall / stream stop and re-arm the IDR
     * gate. Reset to 0 on every tick where head != tail. */
    uint32_t head_tail_match_count{0};
    uint64_t last_idr_req_ns{0};
    /* Timestamp of the last drop-triggered self-heal IDR request (ns). throttles
     * the recovery path independently of the 100ms limit inside
     * request_idr_keyframe(). */
    uint64_t last_drop_heal_ns{0};

    const char *dump_path{nullptr};
    FILE *dump_fp{nullptr};
    FILE *crc_fp{nullptr};
    uint32_t dump_max_frames{0};
    uint32_t dump_frames_count{0};

    std::mutex dma_mutex;
    /* Serialises the non-atomic update-in-place of BRAM mailbox fields that
     * more than one PS thread writes. Leaf lock: never acquired while another
     * mutex is held. */
    std::mutex bram_mailbox_mutex;

    /* ---- Card-side hardware output pacer (see pacer_state above) ----------
     * state_mutex guards the stream synchronisation state that both the
     * producer (queue-full self-heal) and the pacer thread (host ring gate,
     * IDR bookkeeping, drop recovery) touch. The producer only ever takes it
     * with try_to_lock, so a DMA submission in progress can never stall the
     * OpenMAX callback. */
    struct pacer_state pacer;
    std::mutex state_mutex;
    pthread_t pacer_thread{};
    bool pacer_thread_started{false};
    std::atomic<bool> pacer_running{false};
    std::atomic<bool> pacer_stop_req{false};
    /* Set by the pacer thread when a fresh host session appears: it discards
     * the queued pre-IDR backlog and re-primes / re-anchors the meter. */
    std::atomic<bool> pacer_reprime{false};
    /* Command line overrides; negative/zero means "follow the mailbox". */
    int pacer_enable_cli{-1};
    int pacer_depth_cli{0};
};

static volatile sig_atomic_t g_stop = 0;
static void sig_handler(int sig) {
    (void)sig;
    g_stop = 1;
}

static inline uint32_t csr_read32(struct vcud_ctx *ctx, uint32_t offset) {
    return *(volatile uint32_t *)(ctx->csr_base + offset);
}

static inline void csr_write32(struct vcud_ctx *ctx, uint32_t offset, uint32_t val) {
    *(volatile uint32_t *)(ctx->csr_base + offset) = val;
}

static uint64_t get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

/* Submit variable-length Packet DMA job to sc7f0_ps_packet_reader */
static int submit_packet_dma(struct vcud_ctx *ctx,
                             uint64_t src_phys, uint64_t dst_phys,
                             uint32_t len, uint32_t cap,
                             uint64_t comp_phys, uint64_t pts,
                             uint64_t seq, uint32_t flags)
{
    std::lock_guard<std::mutex> lock(ctx->dma_mutex);

    /* Drain any completed packet entries in local FIFO to prevent queue saturation */
    while (csr_read32(ctx, REG_PKT_STATUS) & 0x08) {
        csr_write32(ctx, REG_PKT_DOORBELL_POP, 1);
    }

    /* Check engine readiness */
    uint32_t status = csr_read32(ctx, REG_PKT_STATUS);
    if (!(status & 0x02)) { /* packet_ready (bit 1) */
        int timeout_us = 10000;
        while (!(status & 0x02) && timeout_us > 0) {
            if (status & 0x08)
                csr_write32(ctx, REG_PKT_DOORBELL_POP, 1);
            usleep(50);
            timeout_us -= 50;
            status = csr_read32(ctx, REG_PKT_STATUS);
        }
        if (!(status & 0x02)) {
            fprintf(stderr, "[VCUD] Packet DMA not ready (status=0x%08x)\n", status);
            return -EBUSY;
        }
    }

    /* 768-bit (24 32-bit words) descriptor staging */
    volatile uint32_t *stage = (volatile uint32_t *)(ctx->csr_base + REG_PKT_STAGE_BASE);

    stage[0] = (uint32_t)(src_phys & 0xFFFFFFFF);        /* csrc[31:0] */
    stage[1] = (uint32_t)(src_phys >> 32);               /* csrc[63:32] */
    stage[2] = (uint32_t)(dst_phys & 0xFFFFFFFF);        /* cdst[31:0] */
    stage[3] = (uint32_t)(dst_phys >> 32);               /* cdst[63:32] */
    stage[4] = len;                                      /* clen */
    stage[5] = cap;                                      /* ccap */
    stage[6] = (uint32_t)(comp_phys & 0xFFFFFFFF);       /* ccomp[31:0] */
    stage[7] = (uint32_t)(comp_phys >> 32);              /* ccomp[63:32] */
    stage[8] = (uint32_t)(pts & 0xFFFFFFFF);             /* PTS[31:0] */
    stage[9] = (uint32_t)(pts >> 32);                    /* PTS[63:32] */
    stage[10] = (uint32_t)(seq & 0xFFFFFFFF);            /* seq[31:0] */
    stage[11] = (uint32_t)(seq >> 32);                   /* seq[63:32] */
    stage[12] = 0;
    stage[13] = 0;
    stage[14] = 0;
    stage[15] = 0;
    stage[16] = flags;                                   /* flags */
    stage[17] = 0;
    stage[18] = 0;
    stage[19] = 0;
    stage[20] = 0;
    stage[21] = 0;
    stage[22] = 0;
    stage[23] = 0;

    __sync_synchronize();

    /* Ring doorbell: write 1 to 0xB0040014 */
    csr_write32(ctx, REG_PKT_DOORBELL_PUSH, 1);

    return 0;
}

static uint32_t calc_crc32(const uint8_t *data, size_t len) {
    static uint32_t table[256];
    static bool have_table = false;
    if (!have_table) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t rem = i;
            for (int j = 0; j < 8; j++) {
                if (rem & 1) rem = (rem >> 1) ^ 0xEDB88320;
                else rem >>= 1;
            }
            table[i] = rem;
        }
        have_table = true;
    }
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        crc = (crc >> 8) ^ table[(crc & 0xFF) ^ data[i]];
    }
    return crc ^ 0xFFFFFFFF;
}

struct h264_nal_info {
    bool has_sps;
    bool has_pps;
    bool is_idr;
    size_t sps_pos;
    size_t idr_pos;
};

static struct h264_nal_info scan_h264_nals(const uint8_t *data, size_t len) {
    struct h264_nal_info info = {false, false, false, len, len};
    for (size_t i = 0; i + 3 < len; i++) {
        if (data[i] == 0 && data[i+1] == 0) {
            size_t sc_len = 0;
            if (data[i+2] == 1) {
                sc_len = 3;
            } else if (i + 4 < len && data[i+2] == 0 && data[i+3] == 1) {
                sc_len = 4;
            }
            if (sc_len > 0) {
                uint8_t nal_type = data[i + sc_len] & 0x1F;
                if (nal_type == 7) {
                    info.has_sps = true;
                    if (info.sps_pos == len) info.sps_pos = i;
                } else if (nal_type == 8) {
                    info.has_pps = true;
                } else if (nal_type == 5) {
                    info.is_idr = true;
                    if (info.idr_pos == len) info.idr_pos = i;
                }
                i += (sc_len - 1);
            }
        }
    }
    return info;
}

/* Request an instant decoding refresh from the VCU. The locked variant must be
 * used by callers that already hold ctx->state_mutex (the pacer thread), the
 * wrapper serialises the remaining callers (config sync thread == main thread,
 * producer thread). Rate limited to one request per 100ms. */
static void request_idr_keyframe_locked(struct vcud_ctx *ctx) {
    if (!ctx || !ctx->hEncoder) return;
    uint64_t now = get_time_ns();
    if (now - ctx->last_idr_req_ns < 100000000ULL) { /* at most once per 100ms */
        return;
    }
    ctx->last_idr_req_ns = now;

    OMX_ALG_VIDEO_CONFIG_INSERT insertIdr;
    initHeader(insertIdr);
    insertIdr.nPortIndex = 1;
    OMX_ERRORTYPE err = OMX_SetConfig(ctx->hEncoder,
                                      (OMX_INDEXTYPE)OMX_ALG_IndexConfigVideoInsertInstantaneousDecodingRefresh,
                                      &insertIdr);
    if (err == OMX_ErrorNone) {
        printf("[VCUD] Triggered on-demand IDR keyframe insertion\n");
    } else {
        fprintf(stderr, "[VCUD WARNING] Failed to trigger IDR: 0x%08x\n", (unsigned)err);
    }
}

static void request_idr_keyframe(struct vcud_ctx *ctx) {
    std::lock_guard<std::mutex> lock(ctx->state_mutex);
    request_idr_keyframe_locked(ctx);
}

/* A delivered-or-not AU never reached the host decoder, so the downstream
 * reference chain is broken: ask for an IDR so the decoder recovers on the next
 * frame instead of waiting a full GOP. Caller must hold ctx->state_mutex.
 *
 * 掉禎自癒間隔限制為 1 秒，避免 Host 短暫飢餓時引發 IDR 暴風雪:
 * request_idr_keyframe_locked() only rate-limits itself to 1 request/100ms, so
 * while the host ring stays stalled every dropped frame (30..60/s) would
 * otherwise punch a new IDR through every 100ms - ~10 huge keyframes per second,
 * flooding the log and burning VCU bandwidth. Gate the drop-driven recovery path
 * on our own 1s interval instead.
 *
 * Only worth doing once we have actually streamed an IDR to some host: while
 * nobody has ever connected (offline standby / host ring never started) there is
 * no downstream reference chain to recover, so asking the VCU for IDR after every
 * dropped frame just floods the log. */
static void request_idr_drop_heal_locked(struct vcud_ctx *ctx, uint64_t now) {
    if (!ctx->has_streamed_idr)
        return;
    if (now - ctx->last_drop_heal_ns < 1000000000ULL)
        return;
    ctx->last_drop_heal_ns = now;
    request_idr_keyframe_locked(ctx);
}

/* Check for configuration updates from Host V4L2 driver */
static void handle_config_sync(struct vcud_ctx *ctx) {
    if (!ctx->vcu_cfg)
        return;

    uint32_t host_seq = ctx->vcu_cfg->config_seq;
    if (host_seq != ctx->local_ack_seq && ctx->vcu_cfg->magic == QPCIE_VCU_CFG_MAGIC) {
        printf("[VCUD] Host V4L2 Config Update: seq=%u -> %u\n", ctx->local_ack_seq, host_seq);
        printf("       Codec: %s, Bitrate Mode: %u, Bitrate: %u bps, Peak: %u bps\n",
               ctx->vcu_cfg->codec_type == 0 ? "H.264 (AVC)" : "H.265 (HEVC)",
               ctx->vcu_cfg->bitrate_mode,
               ctx->vcu_cfg->bitrate,
               ctx->vcu_cfg->bitrate_peak);
        printf("       GOP: %u, B-frames: %u, Force IDR: %u, Repeat Header: %u\n",
               ctx->vcu_cfg->gop_size,
               ctx->vcu_cfg->b_frames,
               ctx->vcu_cfg->force_idr,
               ctx->vcu_cfg->repeat_seq_header);
        printf("       Card pacer: enable=%u buffer_frames=%u (takeover applies from the next AU)\n",
               ctx->vcu_cfg->pacer_enable,
               ctx->vcu_cfg->pacer_buffer_frames);

        if (ctx->vcu_cfg->force_idr) {
            request_idr_keyframe(ctx);
            ctx->vcu_cfg->force_idr = 0;
        }

        if (ctx->vcu_cfg->bitrate > 0) {
            OMX_VIDEO_CONFIG_BITRATETYPE br;
            initHeader(br);
            br.nPortIndex = 1;
            uint32_t kbps = ctx->vcu_cfg->bitrate;
            if (kbps > 100000) kbps /= 1000;
            br.nEncodeBitrate = kbps;
            OMX_ERRORTYPE bErr = OMX_SetConfig(ctx->hEncoder, OMX_IndexConfigVideoBitrate, &br);
            if (bErr == OMX_ErrorNone) {
                printf("[VCUD] Dynamically updated target bitrate to %u kbps\n", br.nEncodeBitrate);
            }
        }

        ctx->local_ack_seq = host_seq;
        ctx->vcu_cfg->ps_ack_seq = host_seq;
        ctx->vcu_cfg->ps_encoder_status = 1; /* Running */
        __sync_synchronize();
    }
}

/* ==========================================================================
 * Card-Side Hardware Output Pacer
 * ==========================================================================
 *
 * Problem: OMX_FillBufferDone() used to run the whole PCIe delivery path
 * (DDR staging copy + Packet DMA submit + host ring bookkeeping + drop
 * recovery) inline, and only re-armed the buffer with OMX_FillThisBuffer()
 * once the link had accepted the frame. Every stall on the PCIe side (host
 * ring exhausted, DMA engine busy, host streamoff) therefore backed up into
 * the VCU output queue and from there into the encoder itself: encode FPS
 * collapsed onto the delivery rate and a ~40ms IDR AU pushed the whole
 * pipeline out of the 60Hz cadence.
 *
 * Fix: decouple producer and consumer.
 *
 *   VCU IP --FillBufferDone--> [ pacer queue, 32 AUs ] --pacer thread--> Packet DMA
 *
 * The callback now only scans the NALs, stitches the cached SPS/PPS in front of
 * a header-less IDR, copies the AU plus its raw capture timestamp into the queue
 * and immediately recycles pBuffer, so the hardware encoder always has
 * NUM_OUT_BUFFERS slots in flight and never waits for PCIe DMA.
 *
 * The pacer thread meters the stream out:
 *   pacer_enable == 0 : direct push, one DMA per queued AU, no waiting.
 *   pacer_enable == 1 : (Host default) accumulate pacer_buffer_frames first, then
 *                       anchor the schedule on the first transmitted frame and
 *                       wake at absolute CLOCK_MONOTONIC deadlines derived from
 *                       the per-frame PTS deltas (fallback 16.666ms @ 60Hz).
 *                       Falling behind by more than 100ms re-anchors instead of
 *                       firing a burst.
 *
 * Locking: pacer.mtx guards the ring only and is held for the duration of one
 * memcpy, never across DMA. state_mutex guards the stream synchronisation state;
 * the producer takes it with try_to_lock only, so the callback can never block
 * behind a DMA submission. bram_mailbox_mutex serialises the non-atomic
 * read-modify-write of the host ring drop counter (see host_ring_bump_dropped);
 * it is a leaf lock, never held while taking any other lock.
 * ========================================================================== */

static inline uint32_t pacer_depth_now(const struct pacer_state *q) {
    return q->tail - q->head;
}

static inline struct timespec ns_to_timespec(uint64_t ns) {
    struct timespec ts;
    ts.tv_sec = (time_t)(ns / 1000000000ULL);
    ts.tv_nsec = (long)(ns % 1000000000ULL);
    return ts;
}

/* Resolve the live pacer settings. The mailbox is authoritative once the Host
 * V4L2 driver has published its config (magic "VCUC"); that driver initialises
 * pacer_enable=1 / pacer_buffer_frames=8, which are also our defaults for a card
 * that has never talked to a host. The command line can pin either value for
 * bring-up. Depth is clamped to the documented 1..30 range so the 32 slot queue
 * always keeps headroom. */
static void pacer_get_config(struct vcud_ctx *ctx, bool *out_enable, uint32_t *out_depth) {
    bool enable = true;
    uint32_t depth = PACER_DEFAULT_BUFFER_FRAMES;

    if (ctx->pacer_enable_cli >= 0) {
        enable = (ctx->pacer_enable_cli != 0);
    } else if (ctx->vcu_cfg && ctx->vcu_cfg->magic == QPCIE_VCU_CFG_MAGIC) {
        enable = (ctx->vcu_cfg->pacer_enable != 0);
    }

    if (ctx->pacer_depth_cli > 0) {
        depth = (uint32_t)ctx->pacer_depth_cli;
    } else if (ctx->vcu_cfg && ctx->vcu_cfg->magic == QPCIE_VCU_CFG_MAGIC) {
        depth = ctx->vcu_cfg->pacer_buffer_frames;
    }

    if (depth < PACER_MIN_BUFFER_FRAMES) depth = PACER_MIN_BUFFER_FRAMES;
    if (depth > PACER_MAX_BUFFER_FRAMES) depth = PACER_MAX_BUFFER_FRAMES;

    *out_enable = enable;
    *out_depth = depth;
}

/* --------------------------------------------------------------------------
 * dropped_count lives in PL BRAM: ctx->host_ring is a /dev/mem mapping of the
 * shared mailbox at physical 0xA0002000, i.e. Device memory (nGnRE). ARMv8-A
 * forbids atomic read-modify-write accesses (LDXR/STXR exclusives, the LSE
 * LDADD/SWP family) on Device memory: the core takes an External abort /
 * alignment fault and Linux kills the offending thread with SIGBUS (signal 7).
 * __sync_fetch_and_add() on this field used to lower to
 * __aarch64_ldadd4_sync(base+0x14, 1) and took vcu_pacer down on the first
 * drop, so the counter is now updated with a plain volatile read + volatile
 * write, serialised by a mutex that lives in normal PS memory.
 *
 * Rules for anything reached through ctx->bram_base / ctx->csr_base:
 *   - plain volatile loads and stores only
 *   - no __sync_fetch_and_add/and/or, no __atomic_*, no std::atomic<> view
 *   - __sync_synchronize() (a bare DMB/DSB barrier) stays legal: it accesses
 *     no memory at all
 * -------------------------------------------------------------------------- */
static void host_ring_bump_dropped(struct vcud_ctx *ctx) {
    volatile struct qpcie_vcu_host_ring *ring = ctx->host_ring;

    if (!ring || ring->magic != QPCIE_VCU_RING_MAGIC)
        return;

    /* The Host V4L2 driver may clear this field from PCIe side; a read-modify-
     * write keeps that behaviour instead of shadowing the link with a purely
     * local count. The lock only ever spans three device accesses, so it adds
     * no measurable latency to the FillBufferDone callback, and it is released
     * before the caller goes anywhere near state_mutex. */
    std::lock_guard<std::mutex> lock(ctx->bram_mailbox_mutex);

    uint32_t cur = ring->dropped_count;   /* volatile load  -> plain ldr */
    ring->dropped_count = cur + 1;        /* volatile store -> plain str */
    __sync_synchronize();
}

/* Producer side, runs on the OpenMAX FillBufferDone callback thread. */
static void pacer_submit_au(struct vcud_ctx *ctx, const uint8_t *payload, size_t len,
                            uint64_t pts_us) {
    struct pacer_state *q = &ctx->pacer;

    pthread_mutex_lock(&q->mtx);

    /* Shutting down, or the pacer never came up: drop on the floor. Under no
     * circumstances may the encoder wait for us. */
    if (!ctx->pacer_running.load(std::memory_order_relaxed) || g_stop) {
        pthread_mutex_unlock(&q->mtx);
        return;
    }

    struct h264_nal_info nal = scan_h264_nals(payload, len);

    /* Cache the parameter set pair that precedes an IDR so a header-less IDR AU
     * can still be made self contained before it hits the wire. */
    if (nal.has_sps && nal.idr_pos <= len && nal.idr_pos > nal.sps_pos) {
        ctx->cached_sps_pps.assign(payload + nal.sps_pos, payload + nal.idr_pos);
    }

    size_t prefix_len = 0;
    if (nal.is_idr && !nal.has_sps && !ctx->cached_sps_pps.empty()) {
        prefix_len = ctx->cached_sps_pps.size();
    }

    if (pacer_depth_now(q) >= PACER_QUEUE_CAPACITY) {
        pthread_mutex_unlock(&q->mtx);

        /* The link cannot drain as fast as the VCU produces. Drop the NEWEST AU
         * rather than an older queued one, so the reference chain of everything
         * already committed to the host stays intact. */
        ctx->frames_dropped++;
        host_ring_bump_dropped(ctx);
        uint32_t d = ++q->queue_full_drops;
        if (d == 1 || (d % 30) == 0) {
            printf("[VCUD PACER] Output queue full (%u AUs), dropped %u byte AU (total %u)\n",
                   PACER_QUEUE_CAPACITY, (unsigned)len, d);
        }
        /* Non-blocking: skip the recovery request if the pacer owns the lock. */
        std::unique_lock<std::mutex> sl(ctx->state_mutex, std::try_to_lock);
        if (sl.owns_lock())
            request_idr_drop_heal_locked(ctx, get_time_ns());
        return;
    }

    struct pacer_frame *fr = &q->frames[q->tail % PACER_QUEUE_CAPACITY];
    fr->payload.clear();   /* keeps capacity: steady state allocates nothing */
    if (prefix_len > 0)
        fr->payload.insert(fr->payload.end(),
                           ctx->cached_sps_pps.data(),
                           ctx->cached_sps_pps.data() + prefix_len);
    fr->payload.insert(fr->payload.end(), payload, payload + len);
    fr->pts_us  = pts_us;
    fr->is_idr  = nal.is_idr;
    fr->has_sps = nal.has_sps;
    fr->flags   = (nal.is_idr || nal.has_sps) ? 0x05 : 0x03; /* AU_START|AU_END (|KEYFRAME) */
    q->tail++;

    uint32_t depth = pacer_depth_now(q);
    q->depth.store(depth);
    if (depth > q->peak_depth.load())
        q->peak_depth.store(depth);
    q->queued++;

    pthread_cond_signal(&q->cv);
    pthread_mutex_unlock(&q->mtx);
}

/* Consumer side: hand one Access Unit to the host through Packet DMA. Only ever
 * called from the pacer thread.
 *
 * The state_mutex critical section covers the stream synchronisation state and
 * the host ring credit decision only; the DDR staging copy and the Packet DMA
 * submission run unlocked so a slow or stalled link never keeps the main thread
 * out of request_idr_keyframe() / handle_config_sync(). ps_tail, frame_seq, the
 * staging buffer and the dump files have exactly one writer (this thread). */
static void pacer_deliver_au(struct vcud_ctx *ctx, const uint8_t *data, size_t total_len,
                             const struct pacer_frame *meta) {
    uint64_t now = get_time_ns();
    bool deliverable = false;
    uint64_t host_dst = 0;
    uint64_t host_comp = 0;
    uint32_t host_cap = 0;
    uint32_t tail = 0;

    if (ctx->host_ring && ctx->host_ring->magic == QPCIE_VCU_RING_MAGIC) {
        std::unique_lock<std::mutex> sl(ctx->state_mutex);
        uint32_t head = ctx->host_ring->host_head;
        tail = ctx->host_ring->ps_tail;

        if (head != tail) {
            ctx->head_tail_match_count = 0;
            if (!ctx->was_host_connected) {
                ctx->was_host_connected = true;
                /* Fresh host session: decoder starts cold, block every AU until an
                 * IDR/SPS carrying AU makes it through the stream. */
                ctx->has_streamed_idr = false;
                ctx->pre_idr_drops = 0;
                request_idr_keyframe_locked(ctx);
                /* Let the pacer rebuild its buffer target and re-anchor so the
                 * ramp-up after a reconnect never bursts. */
                ctx->pacer_reprime.store(true);
                printf("[VCUD] Host connected! Requested initial IDR keyframe, "
                       "stalling stream until IDR/SPS\n");
                if (ctx->dump_path) {
                    if (ctx->dump_fp) { fclose(ctx->dump_fp); ctx->dump_fp = nullptr; }
                    if (ctx->crc_fp) { fclose(ctx->crc_fp); ctx->crc_fp = nullptr; }
                    ctx->dump_fp = fopen(ctx->dump_path, "wb");
                    char crc_path[512];
                    snprintf(crc_path, sizeof(crc_path), "%s.crc", ctx->dump_path);
                    ctx->crc_fp = fopen(crc_path, "w");
                    if (ctx->crc_fp) {
                        fprintf(ctx->crc_fp, "frame,len,crc32\n");
                        fflush(ctx->crc_fp);
                    }
                    ctx->dump_frames_count = 0;
                    printf("[VCUD] Started synchronized stream dump to %s (max_frames=%u)\n",
                           ctx->dump_path, ctx->dump_max_frames);
                }
            }

            /* --- IDR synchronisation guard -------------------------------
             * Right after the host (re)connects its decoder holds no SPS/PPS
             * and no reference frames. Shipping it a leading P-frame AU that
             * carries neither SPS/PPS nor an IDR slice corrupts the decoder
             * (grey/green output, error concealment storms). Keep the gate
             * closed until we actually see an IDR or SPS in the AU. */
            bool stream_gate_open = true;
            if (!ctx->has_streamed_idr) {
                if (meta->is_idr || meta->has_sps) {
                    ctx->has_streamed_idr = true;
                    printf("[VCUD] First IDR/SPS received after connect! Streaming unlocked\n");
                } else {
                    stream_gate_open = false;
                    ctx->pre_idr_drops++;
                    if (ctx->pre_idr_drops == 1 || (ctx->pre_idr_drops % 30) == 0) {
                        printf("[VCUD] Stream sync: dropping pre-IDR P-frame AU "
                               "(%u bytes, %u dropped so far)\n",
                               (unsigned)total_len, ctx->pre_idr_drops);
                    }
                }
            }

            uint32_t slot_idx = tail % QPCIE_VCU_RING_SIZE;
            volatile struct qpcie_vcu_buffer_slot *slot = &ctx->host_ring->slots[slot_idx];

            host_dst  = slot->host_phys_addr;
            host_comp = slot->host_comp_addr;
            host_cap  = slot->host_buf_len;

            deliverable = stream_gate_open && host_dst && host_comp && host_cap >= total_len;
        } else {
            /* When head == tail, host buffer queue is momentarily busy/empty.
             * A single tick of head == tail is normal 1-frame jitter and must NOT
             * mark the host disconnected (that would cause disastrous IDR insertion
             * storms), so require a sustained stall before re-arming the gate.
             *
             * host_head and ps_tail are monotonically increasing counters and are
             * never zeroed on streamoff, so the old "head == 0 && tail == 0" test
             * could only ever fire once per process lifetime: after a stream restart
             * the gate stayed open and the host decoder was fed orphan P-frames with
             * no reference picture (corrupted output). */
            if (++ctx->head_tail_match_count >= 15) {
                if (ctx->was_host_connected) {
                    ctx->was_host_connected = false;
                    ctx->has_streamed_idr = false;
                    /* 主機飢餓或停止串流達 15 幀（~250ms），標記主機已離線，
                     * 下次恢復時必須重新請求 IDR 並關閉門禁 */
                }
            }
        }
        sl.unlock();
    }

    bool sent = false;
    if (deliverable) {
        /* Copy compressed NAL bitstream into DDR staging buffer */
        uint8_t *staging = (uint8_t *)ctx->ddr_staging;
        memcpy(staging, data, total_len);

        /* 16-byte align length as required by packet reader */
        uint32_t aligned_len = (uint32_t)((total_len + 15) & ~(size_t)15U);
        if (aligned_len > host_cap)
            aligned_len = host_cap & ~15U;
        if (aligned_len > total_len)
            memset(staging + total_len, 0, aligned_len - total_len);

        /* pts_us is the untouched HDMI RX capture timestamp that travelled with
         * the AU from V4L2 DQBUF through OpenMAX into the pacer queue. The
         * pacer only decides *when* an AU leaves the card, it never rewrites the
         * instant it is stamped with; re-timing it here would destroy the capture
         * timeline and inject PTS jitter (an IDR AU takes ~40ms, a P AU ~0.5ms).
         * 1us == 150 ticks @ 150MHz hardware clock. */
        uint64_t pts_150mhz = meta->pts_us * 150;

        int ret = submit_packet_dma(ctx,
                                    DDR_STAGING_BUF_ADDR,
                                    host_dst,
                                    aligned_len,
                                    host_cap,
                                    host_comp,
                                    pts_150mhz,
                                    ctx->frame_seq,
                                    meta->flags);
        if (ret == 0) {
            __sync_synchronize();
            ctx->host_ring->ps_tail = tail + 1;
            ctx->frame_seq++;
            ctx->frames_sent++;
            ctx->total_bytes_sent += aligned_len;
            sent = true;

            if (ctx->dump_fp && (ctx->dump_max_frames == 0 || ctx->dump_frames_count < ctx->dump_max_frames)) {
                fwrite(staging, 1, aligned_len, ctx->dump_fp);
                fflush(ctx->dump_fp);
                uint32_t crc = calc_crc32(staging, aligned_len);
                if (ctx->crc_fp) {
                    fprintf(ctx->crc_fp, "%u,%u,0x%08X\n", ctx->dump_frames_count, aligned_len, crc);
                    fflush(ctx->crc_fp);
                }
                ctx->dump_frames_count++;
                if (ctx->dump_max_frames > 0 && ctx->dump_frames_count >= ctx->dump_max_frames) {
                    printf("[VCUD] Verification dump completed: %u frames written to %s\n",
                           ctx->dump_frames_count, ctx->dump_path);
                    fclose(ctx->dump_fp);
                    ctx->dump_fp = nullptr;
                    if (ctx->crc_fp) { fclose(ctx->crc_fp); ctx->crc_fp = nullptr; }
                }
            }
        }
    }

    if (!sent) {
        while (csr_read32(ctx, REG_PKT_STATUS) & 0x08) {
            csr_write32(ctx, REG_PKT_DOORBELL_POP, 1);
        }
        ctx->frames_dropped++;
        host_ring_bump_dropped(ctx);
        /* Self-heal: this AU never reached the host, so the downstream decoder
         * just lost its reference chain (grey/green artefacts until the next GOP
         * IDR). Ask the VCU to insert an IDR on the very next frame so the
         * decoder recovers immediately instead of waiting a full GOP. */
        std::lock_guard<std::mutex> sl(ctx->state_mutex);
        request_idr_drop_heal_locked(ctx, now);
    }
}

static void *pacer_thread_main(void *arg) {
    struct vcud_ctx *ctx = (struct vcud_ctx *)arg;
    struct pacer_state *q = &ctx->pacer;
    const uint64_t nominal_interval_ns = ctx->target_fps ?
        (1000000000ULL / (uint64_t)ctx->target_fps) : 16666667ULL;

    pthread_setname_np(pthread_self(), "vcu_pacer");

    /* Best effort RT scheduling: an absolute deadline is only as accurate as the
     * scheduler's willingness to wake us on it, and the card also runs the V4L2
     * capture loop, OMX worker threads and the Packet DMA busy-wait. Without
     * CAP_SYS_NICE this silently stays SCHED_OTHER, which is not an error. */
    struct sched_param sp;
    sp.sched_priority = 20;
    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp) == 0)
        printf("[VCUD PACER] Scheduler: SCHED_FIFO priority 20\n");
    else
        printf("[VCUD PACER] Scheduler: SCHED_OTHER (SCHED_FIFO unavailable, pacing jitter may grow under load)\n");

    bool anchored = false;         /* schedule clocked against next_target_ns   */
    bool first_after_anchor = false; /* the anchor AU leaves at the anchor instant */
    bool have_prev_pts = false;
    uint64_t next_target_ns = 0;
    uint64_t prev_pts_us = 0;
    uint64_t prime_start_ns = 0;
    bool cfg_enable = false;
    uint32_t cfg_depth = PACER_DEFAULT_BUFFER_FRAMES;
    std::vector<uint8_t> scratch;  /* stable dequeue staging, no per-frame alloc */

    pacer_get_config(ctx, &cfg_enable, &cfg_depth);
    printf("[VCUD PACER] Thread online: mode=%s buffer_frames=%u capacity=%u interval=%" PRIu64 " ns\n",
           cfg_enable ? "paced 60Hz" : "direct push", cfg_depth,
           PACER_QUEUE_CAPACITY, nominal_interval_ns);

    while (!ctx->pacer_stop_req.load(std::memory_order_acquire)) {
        bool prev_enable = cfg_enable;
        uint32_t prev_depth = cfg_depth;
        pacer_get_config(ctx, &cfg_enable, &cfg_depth);
        if (cfg_enable != prev_enable || cfg_depth != prev_depth) {
            /* Live retune: the host rewrites the mailbox through
             * V4L2_CID_QPCIE_VCU_PACER_{ENABLE,BUFFER_FRAMES} at any time and the
             * new value takes effect on the next AU. */
            printf("[VCUD PACER] Config: mode=%s buffer_frames=%u\n",
                   cfg_enable ? "paced 60Hz" : "direct push", cfg_depth);
        }
        if (!cfg_enable) {
            /* Direct push: pacing state is meaningless, re-prime when it returns. */
            anchored = false;
            prime_start_ns = 0;
        }

        /* --- 1. wait for work (bounded, so mailbox changes stay responsive) --- */
        uint64_t wake_ns = get_time_ns() + PACER_QUEUE_TICK_NS;
        if (cfg_enable && anchored && next_target_ns > get_time_ns() && next_target_ns < wake_ns)
            wake_ns = next_target_ns;
        struct timespec wts = ns_to_timespec(wake_ns);

        pthread_mutex_lock(&q->mtx);
        /* Single bounded wait per outer iteration: the deadline is recomputed at
         * the top of every pass, so an expired abstime can never turn into a
         * busy spin the way a re-armed while-loop would. */
        if (pacer_depth_now(q) == 0 && !ctx->pacer_stop_req.load(std::memory_order_relaxed))
            pthread_cond_timedwait(&q->cv, &q->mtx, &wts);

        if (ctx->pacer_stop_req.load(std::memory_order_relaxed)) {
            pthread_mutex_unlock(&q->mtx);
            break;
        }

        /* --- 2. fresh host session: flush the stale pre-IDR backlog --- */
        if (ctx->pacer_reprime.exchange(false)) {
            uint32_t flushed = pacer_depth_now(q);
            q->head = q->tail;
            q->depth.store(0);
            if (flushed > 0) {
                q->flushed += flushed;
                printf("[VCUD PACER] Host session reset: discarded %u queued pre-IDR AUs, re-priming\n",
                       flushed);
            }
            anchored = false;
            prime_start_ns = 0;
        }

        /* --- 3. priming: accumulate the configured buffer depth first --- */
        if (cfg_enable && !anchored) {
            uint64_t now = get_time_ns();
            if (prime_start_ns == 0)
                prime_start_ns = now;
            uint64_t budget = (uint64_t)cfg_depth * nominal_interval_ns;
            if (budget < PACER_PRIME_TIMEOUT_NS)
                budget = PACER_PRIME_TIMEOUT_NS;

            bool ready = (pacer_depth_now(q) >= cfg_depth);
            if (!ready) {
                struct timespec pts_wait = ns_to_timespec(get_time_ns() + PACER_QUEUE_TICK_NS);
                pthread_cond_timedwait(&q->cv, &q->mtx, &pts_wait);
                ready = (pacer_depth_now(q) >= cfg_depth);
            }
            if (!ready && (get_time_ns() - prime_start_ns) >= budget) {
                printf("[VCUD PACER] Priming budget exhausted at %u/%u AUs, anchoring anyway\n",
                       pacer_depth_now(q), cfg_depth);
                ready = true;
            }
            if (!ready) {
                /* Still filling the buffer: nothing leaves the card yet. */
                pthread_mutex_unlock(&q->mtx);
                continue;
            }

            /* Anchor the meter on this instant; the first AU leaves immediately. */
            next_target_ns = get_time_ns();
            anchored = true;
            first_after_anchor = true;
            have_prev_pts = false;
            prime_start_ns = 0;
            q->anchors++;
            printf("[VCUD PACER] Primed %u/%u AUs, schedule anchored (target_depth=%u)\n",
                   pacer_depth_now(q), cfg_depth, cfg_depth);
        }

        /* --- 4. dequeue into the thread-local scratch buffer --- */
        if (pacer_depth_now(q) == 0) {
            pthread_mutex_unlock(&q->mtx);
            continue;
        }
        struct pacer_frame *fr = &q->frames[q->head % PACER_QUEUE_CAPACITY];
        size_t len = fr->payload.size();
        if (len == 0) {
            q->head++;
            q->depth.store(pacer_depth_now(q));
            pthread_mutex_unlock(&q->mtx);
            continue;
        }
        scratch.resize(len);
        memcpy(scratch.data(), fr->payload.data(), len);

        struct pacer_frame meta;
        meta.pts_us  = fr->pts_us;
        meta.flags   = fr->flags;
        meta.is_idr  = fr->is_idr;
        meta.has_sps = fr->has_sps;
        q->head++;
        q->depth.store(pacer_depth_now(q));
        pthread_mutex_unlock(&q->mtx);

        /* --- 5. schedule the absolute transmit deadline --- */
        if (cfg_enable) {
            if (first_after_anchor) {
                /* Anchor AU leaves at the anchor instant itself. */
                first_after_anchor = false;
            } else {
                /* Derive the cadence from the capture timeline: the PTS delta of
                 * consecutive AUs is the truthful frame period (59.94Hz NTSC and
                 * friends stay exact). Fall back to the nominal 1e9/target_fps
                 * (16.666ms @ 60Hz) whenever no usable delta is available. */
                uint64_t interval_ns = nominal_interval_ns;
                if (have_prev_pts && meta.pts_us > prev_pts_us) {
                    uint64_t delta_ns = (meta.pts_us - prev_pts_us) * 1000ULL;
                    if (delta_ns >= PACER_PTS_MIN_INTERVAL_NS && delta_ns <= PACER_PTS_MAX_INTERVAL_NS)
                        interval_ns = delta_ns;
                }
                next_target_ns += interval_ns;
            }
            if (meta.pts_us != 0) {
                prev_pts_us = meta.pts_us;
                have_prev_pts = true;
            }

            uint64_t now = get_time_ns();
            if (next_target_ns <= now) {
                /* Late. A small slip is simply absorbed (send now), but a deep hole
                 * must re-anchor, otherwise every backlogged AU would fire back to
                 * back and hammer the link with a burst. */
                uint64_t late_ns = now - next_target_ns;
                if (late_ns > PACER_LATE_RESYNC_NS) {
                    uint32_t r = ++q->resyncs;
                    if (r == 1 || (r % 30) == 0) {
                        printf("[VCUD PACER] %.1f ms behind schedule, re-anchoring (resyncs=%u)\n",
                               (double)late_ns / 1e6, r);
                    }
                    next_target_ns = now;
                }
            } else {
                struct timespec ts = ns_to_timespec(next_target_ns);
                int sret;
                /* Absolute sleep: no cumulative drift, and a signal (SIGINT) wakes us
                 * without breaking the cadence. */
                while ((sret = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL)) == EINTR) {
                    if (g_stop || ctx->pacer_stop_req.load(std::memory_order_relaxed))
                        break;
                    if (get_time_ns() >= next_target_ns)
                        break;
                }
            }
        }

        /* --- 6. deliver --- */
        pacer_deliver_au(ctx, scratch.data(), len, &meta);
    }

    printf("[VCUD PACER] Thread offline (queued=%u sent=%u drops=%u full=%u flushed=%u resyncs=%u anchors=%u peak=%u)\n",
           q->queued.load(), ctx->frames_sent.load(), ctx->frames_dropped.load(),
           q->queue_full_drops.load(), q->flushed.load(), q->resyncs.load(),
           q->anchors.load(), q->peak_depth.load());
    return nullptr;
}

static int pacer_start(struct vcud_ctx *ctx) {
    if (ctx->pacer_thread_started)
        return 0;

    if (pthread_mutex_init(&ctx->pacer.mtx, NULL) != 0) {
        perror("[VCUD ERROR] pthread_mutex_init pacer");
        return -1;
    }
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    /* Absolute queue waits on CLOCK_MONOTONIC: NTP/step adjustments on the real
     * time clock must never stretch or squeeze the 60Hz cadence. */
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    if (pthread_cond_init(&ctx->pacer.cv, &ca) != 0) {
        pthread_condattr_destroy(&ca);
        pthread_mutex_destroy(&ctx->pacer.mtx);
        perror("[VCUD ERROR] pthread_cond_init pacer");
        return -1;
    }
    pthread_condattr_destroy(&ca);

    ctx->pacer.head = ctx->pacer.tail = 0;
    ctx->pacer.depth.store(0);
    ctx->pacer_stop_req.store(false);
    ctx->pacer_reprime.store(false);
    ctx->pacer_running.store(true);

    if (pthread_create(&ctx->pacer_thread, NULL, pacer_thread_main, ctx) != 0) {
        perror("[VCUD ERROR] pthread_create pacer");
        ctx->pacer_running.store(false);
        pthread_cond_destroy(&ctx->pacer.cv);
        pthread_mutex_destroy(&ctx->pacer.mtx);
        return -1;
    }
    ctx->pacer_thread_started = true;
    return 0;
}

/* Idempotent: safe to call from run_live_loop() and again from main(). */
static void pacer_stop(struct vcud_ctx *ctx) {
    if (!ctx->pacer_thread_started)
        return;

    ctx->pacer_stop_req.store(true);
    pthread_mutex_lock(&ctx->pacer.mtx);
    pthread_cond_broadcast(&ctx->pacer.cv);
    pthread_mutex_unlock(&ctx->pacer.mtx);

    pthread_join(ctx->pacer_thread, NULL);
    ctx->pacer_thread_started = false;
    ctx->pacer_running.store(false);

    /* Nobody produces any more (OpenMAX is torn down afterwards): free the
     * queued bitstreams so the daemon does not hold megabytes until exit. */
    pthread_mutex_lock(&ctx->pacer.mtx);
    for (uint32_t i = 0; i < PACER_QUEUE_CAPACITY; i++) {
        ctx->pacer.frames[i].payload.clear();
        ctx->pacer.frames[i].payload.shrink_to_fit();
    }
    ctx->pacer.head = ctx->pacer.tail = 0;
    ctx->pacer.depth.store(0);
    pthread_mutex_unlock(&ctx->pacer.mtx);

    /* Deliberately no pthread_mutex_destroy()/pthread_cond_destroy(): OpenMAX
     * can still fire FillBufferDone between this point and the component state
     * transition, and a producer that already entered pacer_submit_au() may be
     * about to signal the condition variable. The primitives live in the
     * process-lifetime ctx, so leaving them initialised is the race-free
     * choice; pacer_running==false keeps that late producer from queueing. */
}

/* OpenMAX IL Callbacks */
static OMX_ERRORTYPE omx_event_handler(OMX_HANDLETYPE hComponent, OMX_PTR pAppData,
                                       OMX_EVENTTYPE eEvent, OMX_U32 nData1, OMX_U32 nData2, OMX_PTR pEventData)
{
    (void)hComponent; (void)pEventData;
    struct vcud_ctx *ctx = (struct vcud_ctx *)pAppData;
    if (eEvent == OMX_EventCmdComplete) {
        if (nData1 == OMX_CommandStateSet) {
            sem_post(&ctx->semState);
        }
    } else if (eEvent == OMX_EventError) {
        fprintf(stderr, "[VCUD OMX ERROR] EventError: 0x%08x Data2: 0x%08x\n",
                (unsigned)nData1, (unsigned)nData2);
    }
    return OMX_ErrorNone;
}

static OMX_ERRORTYPE omx_empty_buffer_done(OMX_HANDLETYPE hComponent, OMX_PTR pAppData,
                                          OMX_BUFFERHEADERTYPE* pBuffer)
{
    (void)hComponent;
    struct vcud_ctx *ctx = (struct vcud_ctx *)pAppData;
    int idx = (int)(uintptr_t)pBuffer->pAppPrivate;

    /* Re-queue buffer back to VIPP V4L2 queue */
    struct v4l2_plane planes[1];
    memset(planes, 0, sizeof(planes));
    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type = ctx->v4l2_type;
    b.memory = V4L2_MEMORY_MMAP;
    b.index = (uint32_t)idx;
    if (ctx->v4l2_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
        b.length = 1;
        b.m.planes = planes;
    }
    if (ioctl(ctx->v4l2_fd, VIDIOC_QBUF, &b) < 0) {
        perror("[VCUD V4L2] QBUF in EmptyBufferDone");
    }
    return OMX_ErrorNone;
}

/* OpenMAX FillBufferDone: producer side of the card-side hardware pacer.
 *
 * This callback must be as short as humanly possible - it is the only thing
 * standing between the VCU Hard IP and its next output buffer. It therefore
 * performs nothing but:
 *   1. NAL scan of the Access Unit (and SPS/PPS caching / re-stitching),
 *   2. one memcpy of the compressed AU + its raw capture timestamp into the
 *      bounded pacer queue (pacer.mtx, held for the copy only),
 *   3. waking the pacer thread,
 *   4. immediate recycling of pBuffer.
 * Host ring credits, DDR staging, Packet DMA submission, IDR gating and drop
 * recovery all live in the pacer thread now, so PCIe back-pressure can no
 * longer delay OMX_FillThisBuffer(): the encoder runs at full hardware rate
 * and is completely decoupled from the link. */
static OMX_ERRORTYPE omx_fill_buffer_done(OMX_HANDLETYPE hComponent, OMX_PTR pAppData,
                                         OMX_BUFFERHEADERTYPE* pBuffer)
{
    struct vcud_ctx *ctx = (struct vcud_ctx *)pAppData;

    if (pBuffer->nFilledLen > 0 && !g_stop) {
        /* Prefer the OpenMAX output timestamp, which is propagated from the
         * V4L2 DQBUF capture timestamp (HDMI RX sampling time, microseconds)
         * attached to the input buffer in run_live_loop(). Using the local
         * encode-completion time (get_time_ns()) destroys the capture timeline
         * and injects large PTS jitter, because an IDR AU takes ~40ms while a
         * P AU takes ~0.5ms. Fall back to now/1000 only when the component
         * reports no timestamp (0). */
        uint64_t pts_us = (pBuffer->nTimeStamp > 0) ?
                          (uint64_t)pBuffer->nTimeStamp : (get_time_ns() / 1000);

        pacer_submit_au(ctx, pBuffer->pBuffer + pBuffer->nOffset,
                        (size_t)pBuffer->nFilledLen, pts_us);
    }

    /* Recycle output buffer back to OpenMAX encoder immediately: no PCIe wait. */
    if (!g_stop) {
        pBuffer->nFilledLen = 0;
        OMX_FillThisBuffer(hComponent, pBuffer);
    }

    return OMX_ErrorNone;
}

/* Run Live DMA-BUF Zero-Copy Streaming Loop */
static int run_live_loop(struct vcud_ctx *ctx) {
    printf("[VCUD] Initializing Live DMA-BUF Zero-Copy Pipeline...\n");

    // 1. Open VIPP /dev/video0
    ctx->v4l2_fd = open("/dev/video0", O_RDWR | O_NONBLOCK);
    if (ctx->v4l2_fd < 0) {
        perror("[VCUD ERROR] Cannot open /dev/video0");
        return -1;
    }

    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    ioctl(ctx->v4l2_fd, VIDIOC_QUERYCAP, &cap);
    uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps : cap.capabilities;
    ctx->v4l2_type = (caps & V4L2_CAP_VIDEO_CAPTURE_MPLANE) ?
                     V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE : V4L2_BUF_TYPE_VIDEO_CAPTURE;

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = NUM_IN_BUFFERS;
    req.type = ctx->v4l2_type;
    req.memory = V4L2_MEMORY_MMAP;
    if (ioctl(ctx->v4l2_fd, VIDIOC_REQBUFS, &req) < 0) {
        perror("[VCUD ERROR] VIDIOC_REQBUFS failed");
        close(ctx->v4l2_fd);
        return -1;
    }

    for (int i = 0; i < NUM_IN_BUFFERS; i++) {
        struct v4l2_exportbuffer eb;
        memset(&eb, 0, sizeof(eb));
        eb.type = ctx->v4l2_type;
        eb.index = (uint32_t)i;
        eb.plane = 0;
        eb.flags = O_CLOEXEC | O_RDWR;
        if (ioctl(ctx->v4l2_fd, VIDIOC_EXPBUF, &eb) < 0) {
            perror("[VCUD ERROR] VIDIOC_EXPBUF failed");
            close(ctx->v4l2_fd);
            return -1;
        }
        ctx->dma_fds[i] = eb.fd;
    }
    printf("[VCUD] V4L2 VIPP buffers allocated (%d buffers, DMA-BUF exported)\n", NUM_IN_BUFFERS);

    // 2. Initialize OpenMAX IL
    OMX_ERRORTYPE err = OMX_Init();
    if (err != OMX_ErrorNone) {
        fprintf(stderr, "[VCUD ERROR] OMX_Init failed: 0x%x\n", err);
        close(ctx->v4l2_fd);
        return -1;
    }

    sem_init(&ctx->semState, 0, 0);
    OMX_CALLBACKTYPE callbacks = {
        .EventHandler = omx_event_handler,
        .EmptyBufferDone = omx_empty_buffer_done,
        .FillBufferDone = omx_fill_buffer_done,
    };

    const char *comp_name = "OMX.allegro.h264.hardware.encoder";
    err = OMX_GetHandle(&ctx->hEncoder, (OMX_STRING)comp_name, ctx, &callbacks);
    if (err != OMX_ErrorNone) {
        fprintf(stderr, "[VCUD ERROR] OMX_GetHandle failed: 0x%x\n", err);
        OMX_Deinit();
        close(ctx->v4l2_fd);
        return -1;
    }

    // Set input port format
    OMX_VIDEO_PARAM_PORTFORMATTYPE inFormat;
    initHeader(inFormat);
    inFormat.nPortIndex = 0;
    OMX_GetParameter(ctx->hEncoder, OMX_IndexParamVideoPortFormat, &inFormat);
    inFormat.eColorFormat = OMX_COLOR_FormatYUV420SemiPlanar; // NV12
    inFormat.xFramerate = ctx->target_fps << 16;
    OMX_SetParameter(ctx->hEncoder, OMX_IndexParamVideoPortFormat, &inFormat);

    // Set input port definition
    OMX_PARAM_PORTDEFINITIONTYPE inPort;
    initHeader(inPort);
    inPort.nPortIndex = 0;
    OMX_GetParameter(ctx->hEncoder, OMX_IndexParamPortDefinition, &inPort);
    inPort.format.video.nFrameWidth = VCU_WIDTH;
    inPort.format.video.nFrameHeight = VCU_HEIGHT;
    inPort.format.video.nStride = VCU_WIDTH;
    inPort.format.video.nSliceHeight = VCU_HEIGHT;
    inPort.format.video.xFramerate = ctx->target_fps << 16;
    inPort.nBufferCountActual = NUM_IN_BUFFERS;
    OMX_SetParameter(ctx->hEncoder, OMX_IndexParamPortDefinition, &inPort);
    OMX_GetParameter(ctx->hEncoder, OMX_IndexParamPortDefinition, &inPort);
    size_t inBufSize = inPort.nBufferSize;

    // Set buffer mode for Port 0 -> DMA-BUF!
    OMX_ALG_PORT_PARAM_BUFFER_MODE modeIn;
    initHeader(modeIn);
    modeIn.nPortIndex = 0;
    modeIn.eMode = OMX_ALG_BUF_DMA;
    OMX_SetParameter(ctx->hEncoder, (OMX_INDEXTYPE)OMX_ALG_IndexPortParamBufferMode, &modeIn);

    // Set output port format
    OMX_VIDEO_PARAM_PORTFORMATTYPE outFormat;
    initHeader(outFormat);
    outFormat.nPortIndex = 1;
    OMX_GetParameter(ctx->hEncoder, OMX_IndexParamVideoPortFormat, &outFormat);
    outFormat.eCompressionFormat = OMX_VIDEO_CodingAVC;
    outFormat.xFramerate = ctx->target_fps << 16;
    OMX_SetParameter(ctx->hEncoder, OMX_IndexParamVideoPortFormat, &outFormat);

    // Configure Profile and Level: AVC High Profile, Level 5.1
    OMX_VIDEO_PARAM_PROFILELEVELTYPE profLvl;
    initHeader(profLvl);
    profLvl.nPortIndex = 1;
    profLvl.eProfile = OMX_VIDEO_AVCProfileHigh;
    profLvl.eLevel = (OMX_U32)OMX_VIDEO_AVCLevel51;
    err = OMX_SetParameter(ctx->hEncoder, OMX_IndexParamVideoProfileLevelCurrent, &profLvl);
    if (err == OMX_ErrorNone) {
        printf("[VCUD] AVC Profile/Level set to High / Level 5.1\n");
    } else {
        fprintf(stderr, "[VCUD WARNING] SetProfileLevel failed: 0x%08x\n", (unsigned)err);
    }

    // Configure AVC Parameters (CABAC, etc.)
    OMX_VIDEO_PARAM_AVCTYPE avcParam;
    initHeader(avcParam);
    avcParam.nPortIndex = 1;
    if (OMX_GetParameter(ctx->hEncoder, OMX_IndexParamVideoAvc, &avcParam) == OMX_ErrorNone) {
        avcParam.eProfile = OMX_VIDEO_AVCProfileHigh;
        avcParam.eLevel = OMX_VIDEO_AVCLevel51;
        avcParam.bEntropyCodingCABAC = OMX_TRUE;
        err = OMX_SetParameter(ctx->hEncoder, OMX_IndexParamVideoAvc, &avcParam);
        if (err == OMX_ErrorNone) {
            printf("[VCUD] AVC High Profile, Level 5.1, CABAC enabled\n");
        } else {
            fprintf(stderr, "[VCUD WARNING] SetParameter VideoAvc failed: 0x%08x\n", (unsigned)err);
        }
    }

    // Disable Filler Data to prevent bandwidth explosion
    OMX_ALG_VIDEO_PARAM_FILLER_DATA fillerParam;
    initHeader(fillerParam);
    fillerParam.nPortIndex = 1;
    fillerParam.bDisableFillerData = OMX_TRUE;
    err = OMX_SetParameter(ctx->hEncoder, (OMX_INDEXTYPE)OMX_ALG_IndexParamVideoFillerData, &fillerParam);
    if (err == OMX_ErrorNone) {
        printf("[VCUD] Filler data disabled\n");
    }

    // Disable Prefetch Buffer (direct DMA-BUF path)
    OMX_ALG_VIDEO_PARAM_PREFETCH_BUFFER prefetchParam;
    initHeader(prefetchParam);
    prefetchParam.nPortIndex = 1;
    prefetchParam.bEnablePrefetchBuffer = OMX_FALSE;
    err = OMX_SetParameter(ctx->hEncoder, (OMX_INDEXTYPE)OMX_ALG_IndexParamVideoPrefetchBuffer, &prefetchParam);
    if (err == OMX_ErrorNone) {
        printf("[VCUD] Prefetch buffer disabled\n");
    }

    // Output port definition
    OMX_PARAM_PORTDEFINITIONTYPE outPort;
    initHeader(outPort);
    outPort.nPortIndex = 1;
    OMX_GetParameter(ctx->hEncoder, OMX_IndexParamPortDefinition, &outPort);
    outPort.format.video.nFrameWidth = VCU_WIDTH;
    outPort.format.video.nFrameHeight = VCU_HEIGHT;
    outPort.format.video.xFramerate = ctx->target_fps << 16;
    outPort.nBufferCountActual = NUM_OUT_BUFFERS;
    OMX_SetParameter(ctx->hEncoder, OMX_IndexParamPortDefinition, &outPort);
    OMX_GetParameter(ctx->hEncoder, OMX_IndexParamPortDefinition, &outPort);
    size_t outBufSize = outPort.nBufferSize;

    // Set buffer mode for Port 1 -> NORMAL
    OMX_ALG_PORT_PARAM_BUFFER_MODE modeOut;
    initHeader(modeOut);
    modeOut.nPortIndex = 1;
    modeOut.eMode = OMX_ALG_BUF_NORMAL;
    OMX_SetParameter(ctx->hEncoder, (OMX_INDEXTYPE)OMX_ALG_IndexPortParamBufferMode, &modeOut);

    // Configure periodic IDR frequency (GOP / Keyframe interval)
    OMX_ALG_VIDEO_PARAM_INSTANTANEOUS_DECODING_REFRESH idrParam;
    initHeader(idrParam);
    idrParam.nPortIndex = 1;
    idrParam.nInstantaneousDecodingRefreshFrequency = 30; /* Every 30 frames (0.5 sec @ 60fps) */
    err = OMX_SetParameter(ctx->hEncoder, (OMX_INDEXTYPE)OMX_ALG_IndexParamVideoInstantaneousDecodingRefresh, &idrParam);
    if (err != OMX_ErrorNone) {
        fprintf(stderr, "[VCUD WARNING] SetParameter IDR failed: 0x%08x\n", (unsigned)err);
    } else {
        printf("[VCUD] Periodic IDR enabled: frequency = %u frames\n", idrParam.nInstantaneousDecodingRefreshFrequency);
    }

    // Configure Low-Delay P GOP Mode (PG252 low latency)
    OMX_ALG_VIDEO_PARAM_GOP_CONTROL gopCtrl;
    initHeader(gopCtrl);
    gopCtrl.nPortIndex = 1;
    gopCtrl.eGopControlMode = OMX_ALG_GOP_MODE_LOW_DELAY_P;
    gopCtrl.eGdrMode = OMX_ALG_GDR_OFF;
    err = OMX_SetParameter(ctx->hEncoder, (OMX_INDEXTYPE)OMX_ALG_IndexParamVideoGopControl, &gopCtrl);
    if (err != OMX_ErrorNone) {
        fprintf(stderr, "[VCUD WARNING] SetParameter GopControl failed: 0x%08x\n", (unsigned)err);
    } else {
        printf("[VCUD] Low-delay P GOP mode enabled\n");
    }

    // Configure 4 Slices for parallel hardware encode
    OMX_ALG_VIDEO_PARAM_SLICES slices;
    initHeader(slices);
    slices.nPortIndex = 1;
    slices.nNumSlices = 4;
    slices.nSlicesSize = 0;
    slices.bDependentSlices = OMX_FALSE;
    err = OMX_SetParameter(ctx->hEncoder, (OMX_INDEXTYPE)OMX_ALG_IndexParamVideoSlices, &slices);
    if (err != OMX_ErrorNone) {
        fprintf(stderr, "[VCUD WARNING] SetParameter Slices failed: 0x%08x\n", (unsigned)err);
    } else {
        printf("[VCUD] Slices enabled: %d slices\n", (int)slices.nNumSlices);
    }

    // Target Bitrate: 25000 kbps (25 Mbps CBR) - Allegro OpenMAX expects kbps!
    OMX_VIDEO_PARAM_BITRATETYPE bitrateParam;
    initHeader(bitrateParam);
    bitrateParam.nPortIndex = 1;
    bitrateParam.eControlRate = OMX_Video_ControlRateConstant;
    bitrateParam.nTargetBitrate = 25000; /* 25 Mbps in kbps */
    err = OMX_SetParameter(ctx->hEncoder, OMX_IndexParamVideoBitrate, &bitrateParam);
    if (err == OMX_ErrorNone) {
        printf("[VCUD] Target Bitrate set to %u kbps (25 Mbps)\n", bitrateParam.nTargetBitrate);
    }

    // 3. State transition: Loaded -> Idle
    OMX_SendCommand(ctx->hEncoder, OMX_CommandStateSet, OMX_StateIdle, NULL);

    for (int i = 0; i < NUM_IN_BUFFERS; i++) {
        err = OMX_UseBuffer(ctx->hEncoder, &ctx->inHeaders[i], 0, ctx, inBufSize, (OMX_U8*)(uintptr_t)ctx->dma_fds[i]);
        if (err != OMX_ErrorNone) {
            fprintf(stderr, "[VCUD ERROR] OMX_UseBuffer input %d failed: 0x%x\n", i, err);
            return -1;
        }
        ctx->inHeaders[i]->pAppPrivate = (void*)(uintptr_t)i;
    }

    for (int j = 0; j < NUM_OUT_BUFFERS; j++) {
        err = OMX_AllocateBuffer(ctx->hEncoder, &ctx->outHeaders[j], 1, ctx, outBufSize);
        if (err != OMX_ErrorNone) {
            fprintf(stderr, "[VCUD ERROR] OMX_AllocateBuffer output %d failed: 0x%x\n", j, err);
            return -1;
        }
    }

    sem_wait(&ctx->semState);

    // 4. State transition: Idle -> Executing
    OMX_SendCommand(ctx->hEncoder, OMX_CommandStateSet, OMX_StateExecuting, NULL);
    sem_wait(&ctx->semState);
    printf("[VCUD] OpenMAX VCU Hard IP Encoder Executing (Level 5.2 Auto, DMA-BUF Zero-Copy)\n");

    /* Start the card-side output pacer BEFORE the encoder is handed any output
     * buffer: FillBufferDone may fire as soon as the first OMX_FillThisBuffer
     * completes, and it must always have a running consumer to queue into. */
    if (pacer_start(ctx) < 0) {
        fprintf(stderr, "[VCUD ERROR] Cannot start card-side output pacer\n");
        return -1;
    }

    // Prime output buffers
    for (int j = 0; j < NUM_OUT_BUFFERS; j++) {
        OMX_FillThisBuffer(ctx->hEncoder, ctx->outHeaders[j]);
    }

    // Queue input buffers to V4L2
    for (int i = 0; i < NUM_IN_BUFFERS; i++) {
        struct v4l2_plane planes[1];
        memset(planes, 0, sizeof(planes));
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = ctx->v4l2_type;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = (uint32_t)i;
        if (ctx->v4l2_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
            b.length = 1;
            b.m.planes = planes;
        }
        if (ioctl(ctx->v4l2_fd, VIDIOC_QBUF, &b) < 0) {
            perror("[VCUD ERROR] Initial VIDIOC_QBUF");
            return -1;
        }
    }

    // Start V4L2 STREAMON
    if (ioctl(ctx->v4l2_fd, VIDIOC_STREAMON, &ctx->v4l2_type) < 0) {
        perror("[VCUD ERROR] VIDIOC_STREAMON");
        return -1;
    }
    printf("[VCUD] Live V4L2 STREAMON active! Streaming across PCIe Packet DMA...\n");

    if (ctx->vcu_cfg) {
        ctx->vcu_cfg->ps_encoder_status = 1; /* Running */
    }

    uint64_t t_last_stat = get_time_ns();
    uint32_t stat_frames_last = 0;
    uint64_t stat_bytes_last = 0;

    // 5. Main Capture Loop
    while (!g_stop && (ctx->max_frames == 0 || ctx->frames_sent < ctx->max_frames)) {
        handle_config_sync(ctx);

        struct pollfd pfd = { .fd = ctx->v4l2_fd, .events = POLLIN, .revents = 0 };
        int prc = poll(&pfd, 1, 100);
        if (prc < 0) {
            if (errno == EINTR) continue;
            perror("[VCUD] V4L2 poll error");
            break;
        }
        if (prc == 0) continue;

        struct v4l2_plane planes[1];
        memset(planes, 0, sizeof(planes));
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = ctx->v4l2_type;
        b.memory = V4L2_MEMORY_MMAP;
        if (ctx->v4l2_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
            b.length = 1;
            b.m.planes = planes;
        }
        if (ioctl(ctx->v4l2_fd, VIDIOC_DQBUF, &b) < 0) {
            if (errno == EAGAIN) continue;
            perror("[VCUD] VIDIOC_DQBUF error");
            break;
        }

        uint32_t idx = b.index;
        ctx->inHeaders[idx]->nFilledLen = (ctx->v4l2_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) ?
                                          planes[0].bytesused : b.bytesused;
        ctx->inHeaders[idx]->nOffset = 0;
        ctx->inHeaders[idx]->nTimeStamp = b.timestamp.tv_sec * 1000000ULL + b.timestamp.tv_usec;

        /* Feed to VCU IP (Zero-copy DDR read) */
        err = OMX_EmptyThisBuffer(ctx->hEncoder, ctx->inHeaders[idx]);
        if (err != OMX_ErrorNone) {
            fprintf(stderr, "[VCUD] OMX_EmptyThisBuffer error: 0x%x\n", err);
            break;
        }

        /* Periodic Telemetry & Probes every second */
        uint64_t now = get_time_ns();
        if (now - t_last_stat >= 1000000000ULL) {
            double elapsed_s = (double)(now - t_last_stat) / 1e9;
            uint32_t cur_frames = ctx->frames_sent.load();
            uint64_t cur_bytes = ctx->total_bytes_sent.load();
            double fps = (double)(cur_frames - stat_frames_last) / elapsed_s;
            double mbps = ((double)(cur_bytes - stat_bytes_last) * 8.0) / (elapsed_s * 1000000.0);

            uint32_t p_sub = csr_read32(ctx, REG_PKT_PROBE_SUBMIT);
            uint32_t p_done = csr_read32(ctx, REG_PKT_PROBE_DONE);
            uint32_t p_err = csr_read32(ctx, REG_PKT_PROBE_ERR);
            uint32_t p_msi = csr_read32(ctx, REG_PKT_PROBE_MSI);
            uint32_t p_fsm = csr_read32(ctx, REG_PKT_PROBE_FSM);

            printf("[LIVE STAT] Sent: %u (%.1f FPS, %.2f Mbps, drops: %u) | DMA Probes: SUB=%u DONE=%u MSI=%u ERR=%u FSM=0x%02x\n",
                   cur_frames, fps, mbps, ctx->frames_dropped.load(),
                   p_sub, p_done, p_msi, p_err, p_fsm & 0xFF);

            bool pace_on; uint32_t pace_depth;
            pacer_get_config(ctx, &pace_on, &pace_depth);
            printf("[PACER STAT] mode=%s target=%u depth=%u/%u peak=%u queued=%u full_drops=%u "
                   "flushed=%u resyncs=%u anchors=%u\n",
                   pace_on ? "paced" : "direct", pace_depth,
                   ctx->pacer.depth.load(), pace_depth,
                   ctx->pacer.peak_depth.load(), ctx->pacer.queued.load(),
                   ctx->pacer.queue_full_drops.load(), ctx->pacer.flushed.load(),
                   ctx->pacer.resyncs.load(), ctx->pacer.anchors.load());

            if (ctx->vcu_cfg) {
                ctx->vcu_cfg->ps_fps_actual = (uint32_t)(fps * 100);
                ctx->vcu_cfg->ps_bitrate_actual = (uint32_t)(mbps * 1000000);
            }

            t_last_stat = now;
            stat_frames_last = cur_frames;
            stat_bytes_last = cur_bytes;
        }
    }

    printf("[VCUD] Live loop terminating. Total sent: %u, Drops: %u\n",
           ctx->frames_sent.load(), ctx->frames_dropped.load());

    /* Stop the pacer first: after this point no producer can queue, and the
     * OpenMAX teardown below never races a consumer that is still poking the
     * Packet DMA engine or the host ring. */
    pacer_stop(ctx);

    // Teardown
    ioctl(ctx->v4l2_fd, VIDIOC_STREAMOFF, &ctx->v4l2_type);
    for (int i = 0; i < NUM_IN_BUFFERS; i++) close(ctx->dma_fds[i]);
    close(ctx->v4l2_fd);

    OMX_SendCommand(ctx->hEncoder, OMX_CommandStateSet, OMX_StateIdle, NULL);
    sem_wait(&ctx->semState);
    OMX_SendCommand(ctx->hEncoder, OMX_CommandStateSet, OMX_StateLoaded, NULL);
    for (int i = 0; i < NUM_IN_BUFFERS; i++) OMX_FreeBuffer(ctx->hEncoder, 0, ctx->inHeaders[i]);
    for (int j = 0; j < NUM_OUT_BUFFERS; j++) OMX_FreeBuffer(ctx->hEncoder, 1, ctx->outHeaders[j]);
    sem_wait(&ctx->semState);
    OMX_FreeHandle(ctx->hEncoder);
    OMX_Deinit();

    return 0;
}

int main(int argc, char **argv) {
    setlinebuf(stdout);
    setlinebuf(stderr);
    printf("=== SC7F0 VCU Video Encoder & Packet DMA Daemon (sc7f0_vcud) ===\n");

    struct vcud_ctx ctx{};
    ctx.target_fps = 60;
    ctx.live_mode = true; /* Default to true zero-copy live mode */

    bool daemon_mode = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("Usage: %s [options]\n"
                   "  --live, -l          Run in live VIPP capture + VCU hardware encode mode (default)\n"
                   "  --daemon, -d        Detach into background daemon mode\n"
                   "  --pattern, -p       Run in test pattern generation mode\n"
                   "  --h264, -f <file>   Broadcast pre-encoded H.264 file\n"
                   "  --fps <N>           Target streaming framerate (default: 60)\n"
                   "  --frames <N>        Exit after sending N frames (default: infinite)\n"
                   "  --pacer <0|1>       Override the card-side output pacer (default: follow the\n"
                   "                      host mailbox word 0xBC, which the host driver sets to 1)\n"
                   "  --pacer-frames <N>  Override the pacer pre-buffer depth, 1..30 (default: follow\n"
                   "                      the host mailbox word 0xC0, which the host driver sets to 8)\n",
                   argv[0]);
            return 0;
        } else if (!strcmp(argv[i], "--daemon") || !strcmp(argv[i], "-d")) {
            daemon_mode = true;
        } else if (!strcmp(argv[i], "--live") || !strcmp(argv[i], "-l")) {
            ctx.live_mode = true;
            ctx.pattern_mode = false;
        } else if (!strcmp(argv[i], "--pattern") || !strcmp(argv[i], "-p")) {
            ctx.pattern_mode = true;
            ctx.live_mode = false;
        } else if ((!strcmp(argv[i], "--h264") || !strcmp(argv[i], "-f")) && i + 1 < argc) {
            ctx.h264_file = argv[++i];
            ctx.live_mode = false;
        } else if (!strcmp(argv[i], "--fps") && i + 1 < argc) {
            ctx.target_fps = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
            ctx.max_frames = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--dump") && i + 1 < argc) {
            ctx.dump_path = argv[++i];
        } else if (!strcmp(argv[i], "--dump-frames") && i + 1 < argc) {
            ctx.dump_max_frames = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--pacer") && i + 1 < argc) {
            ctx.pacer_enable_cli = atoi(argv[++i]) ? 1 : 0;
        } else if (!strcmp(argv[i], "--pacer-frames") && i + 1 < argc) {
            ctx.pacer_depth_cli = atoi(argv[++i]);
            if (ctx.pacer_depth_cli < 0)
                ctx.pacer_depth_cli = 0;
        }
    }

    if (daemon_mode) {
        int log_fd = open("/tmp/sc7f0_vcud.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (daemon(1, 0) < 0) {
            perror("[VCUD ERROR] daemon() failed");
            return 1;
        }
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sig_handler;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    /* Open /dev/mem to access PL CSRs and shared BRAM */
    ctx.mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (ctx.mem_fd < 0) {
        perror("[VCUD ERROR] Cannot open /dev/mem");
        return 1;
    }

    /* 1. Map PL CSR Packet DMA registers @ 0xB0040000 (4KB) */
    ctx.csr_base = (volatile uint8_t *)mmap(NULL, PL_CSR_PACKET_SIZE, PROT_READ | PROT_WRITE,
                                            MAP_SHARED, ctx.mem_fd, PL_CSR_PACKET_ADDR);
    if (ctx.csr_base == MAP_FAILED) {
        perror("[VCUD ERROR] Cannot map PL CSR Packet DMA");
        close(ctx.mem_fd);
        return 1;
    }

    /* 2. Map PL Shared BRAM @ 0xA0002000 (8KB) */
    ctx.bram_base = (volatile uint8_t *)mmap(NULL, PL_SHARED_BRAM_SIZE, PROT_READ | PROT_WRITE,
                                             MAP_SHARED, ctx.mem_fd, PL_SHARED_BRAM_ADDR);
    if (ctx.bram_base == MAP_FAILED) {
        perror("[VCUD ERROR] Cannot map Shared BRAM");
        munmap((void *)ctx.csr_base, PL_CSR_PACKET_SIZE);
        close(ctx.mem_fd);
        return 1;
    }

    /* 3. Map DDR Staging Buffer @ 0x50000000 (8MB) */
    ctx.ddr_staging = (volatile uint8_t *)mmap(NULL, 8 * 1024 * 1024, PROT_READ | PROT_WRITE,
                                               MAP_SHARED, ctx.mem_fd, DDR_STAGING_BUF_ADDR);
    if (ctx.ddr_staging == MAP_FAILED) {
        perror("[VCUD ERROR] Cannot map DDR Staging buffer");
        munmap((void *)ctx.bram_base, PL_SHARED_BRAM_SIZE);
        munmap((void *)ctx.csr_base, PL_CSR_PACKET_SIZE);
        close(ctx.mem_fd);
        return 1;
    }

    /* Verify PL Packet DMA Controller Magic */
    uint32_t magic = csr_read32(&ctx, REG_PKT_MAGIC);
    uint32_t version = csr_read32(&ctx, REG_PKT_VERSION);
    printf("[VCUD] Hardware Packet DMA detected: Magic=0x%08x (\"%c%c%c%c\"), Version=0x%08x\n",
           magic,
           (magic >> 0) & 0xFF, (magic >> 8) & 0xFF,
           (magic >> 16) & 0xFF, (magic >> 24) & 0xFF,
           version);

    if (magic != 0x44505631) { /* "DPV1" */
        fprintf(stderr, "[VCUD WARNING] Unexpected Packet DMA magic (expected 0x44505631)\n");
    }

    ctx.vcu_cfg = (volatile struct qpcie_vcu_encoder_config *)(ctx.bram_base + MAILBOX_VCU_CFG_OFFSET);
    ctx.host_ring = (volatile struct qpcie_vcu_host_ring *)(ctx.bram_base + MAILBOX_VCU_RING_OFFSET);

    printf("[VCUD] Shared BRAM Mailbox mapped:\n"
           "       vcu_encoder_config @ 0xA000%04x (magic=0x%08x)\n"
           "       vcu_host_ring      @ 0xA000%04x (magic=0x%08x)\n",
           MAILBOX_VCU_CFG_OFFSET, ctx.vcu_cfg->magic,
           MAILBOX_VCU_RING_OFFSET, ctx.host_ring->magic);

    int ret = 0;
    if (ctx.live_mode) {
        ret = run_live_loop(&ctx);
    } else {
        printf("[VCUD] Fallback mode not selected; running live mode.\n");
        ret = run_live_loop(&ctx);
    }

    /* Always safe: run_live_loop() stops the pacer on its orderly exit, this
     * only catches the early error returns so no pacer thread can outlive the
     * /dev/mem mappings it writes through. */
    pacer_stop(&ctx);

    if (ctx.vcu_cfg)
        ctx.vcu_cfg->ps_encoder_status = 0; /* Stopped */

    /* Cleanup */
    munmap((void *)ctx.ddr_staging, 8 * 1024 * 1024);
    munmap((void *)ctx.bram_base, PL_SHARED_BRAM_SIZE);
    munmap((void *)ctx.csr_base, PL_CSR_PACKET_SIZE);
    close(ctx.mem_fd);

    printf("[VCUD] Daemon cleanly shutdown.\n");
    return ret;
}
