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
};

struct __attribute__((packed)) qpcie_vcu_buffer_slot {
    uint64_t host_phys_addr;    /* 0x00: Host physical address for payload */
    uint64_t host_comp_addr;    /* 0x08: Host physical address for 64B DPC1 record */
    uint32_t host_buf_len;      /* 0x10: Buffer capacity in bytes */
    uint32_t host_buf_id;       /* 0x14: VB2 buffer index / cookie */
    uint32_t flags;             /* 0x18 */
    uint32_t reserved;          /* 0x1C */
};

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

static void request_idr_keyframe(struct vcud_ctx *ctx) {
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

static OMX_ERRORTYPE omx_fill_buffer_done(OMX_HANDLETYPE hComponent, OMX_PTR pAppData,
                                         OMX_BUFFERHEADERTYPE* pBuffer)
{
    struct vcud_ctx *ctx = (struct vcud_ctx *)pAppData;

    if (pBuffer->nFilledLen > 0 && !g_stop) {
        uint64_t now = get_time_ns();
        uint8_t *payload = pBuffer->pBuffer + pBuffer->nOffset;
        size_t len = pBuffer->nFilledLen;

        /* Scan NAL units in payload */
        struct h264_nal_info nal_info = scan_h264_nals(payload, len);

        /* Cache SPS/PPS if found */
        if (nal_info.has_sps && nal_info.idr_pos <= len && nal_info.idr_pos > nal_info.sps_pos) {
            ctx->cached_sps_pps.assign(payload + nal_info.sps_pos, payload + nal_info.idr_pos);
        }

        /* Check if Host queue has ready buffer credit */
        bool sent = false;
        if (ctx->host_ring && ctx->host_ring->magic == QPCIE_VCU_RING_MAGIC) {
            uint32_t head = ctx->host_ring->host_head;
            uint32_t tail = ctx->host_ring->ps_tail;

            if (head != tail) {
                ctx->head_tail_match_count = 0;
                if (!ctx->was_host_connected) {
                    ctx->was_host_connected = true;
                    /* Fresh host session: decoder starts cold, block every AU until an
                     * IDR/SPS carrying AU makes it through the stream. */
                    ctx->has_streamed_idr = false;
                    ctx->pre_idr_drops = 0;
                    request_idr_keyframe(ctx);
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
                    if (nal_info.is_idr || nal_info.has_sps) {
                        ctx->has_streamed_idr = true;
                        printf("[VCUD] First IDR/SPS received after connect! Streaming unlocked\n");
                    } else {
                        /* Drop like any other undeliverable frame (sent stays false) */
                        stream_gate_open = false;
                        ctx->pre_idr_drops++;
                        if (ctx->pre_idr_drops == 1 || (ctx->pre_idr_drops % 30) == 0) {
                            printf("[VCUD] Stream sync: dropping pre-IDR P-frame AU "
                                   "(%u bytes, %u dropped so far)\n",
                                   (unsigned)len, ctx->pre_idr_drops);
                        }
                    }
                }

                uint32_t slot_idx = tail % QPCIE_VCU_RING_SIZE;
                volatile struct qpcie_vcu_buffer_slot *slot = &ctx->host_ring->slots[slot_idx];

                uint64_t host_dst = slot->host_phys_addr;
                uint64_t host_comp = slot->host_comp_addr;
                uint32_t host_cap = slot->host_buf_len;

                /* Check if we need to prepend cached SPS/PPS */
                size_t prefix_len = 0;
                if (nal_info.is_idr && !nal_info.has_sps && !ctx->cached_sps_pps.empty()) {
                    prefix_len = ctx->cached_sps_pps.size();
                }

                size_t total_len = prefix_len + len;

                if (stream_gate_open && host_dst && host_comp && host_cap >= total_len) {
                    /* Copy compressed NAL bitstream into DDR staging buffer */
                    uint8_t *staging = (uint8_t *)ctx->ddr_staging;
                    if (prefix_len > 0) {
                        memcpy(staging, ctx->cached_sps_pps.data(), prefix_len);
                    }
                    memcpy(staging + prefix_len, payload, len);

                    /* 16-byte align length as required by packet reader */
                    uint32_t aligned_len = (total_len + 15) & ~15U;
                    if (aligned_len > host_cap)
                        aligned_len = host_cap & ~15U;
                    if (aligned_len > total_len)
                        memset(staging + total_len, 0, aligned_len - total_len);

                    /* Prefer the OpenMAX output timestamp, which is propagated from the
                     * V4L2 DQBUF capture timestamp (HDMI RX sampling time, microseconds)
                     * attached to the input buffer in run_live_loop(). Using the local
                     * encode-completion time (get_time_ns()) destroys the capture timeline
                     * and injects large PTS jitter, because an IDR AU takes ~40ms while a
                     * P AU takes ~0.5ms. Fall back to now/1000 only when the component
                     * reports no timestamp (0). 1us == 150 ticks @ 150MHz hardware clock. */
                    uint64_t pts_us = (pBuffer->nTimeStamp > 0) ? (uint64_t)pBuffer->nTimeStamp : (now / 1000);
                    uint64_t pts_150mhz = pts_us * 150;
                    uint32_t flags = (nal_info.is_idr || nal_info.has_sps) ? 0x05 : 0x03; /* AU_START | AU_END | (KEYFRAME) */

                    int ret = submit_packet_dma(ctx,
                                                DDR_STAGING_BUF_ADDR,
                                                host_dst,
                                                aligned_len,
                                                host_cap,
                                                host_comp,
                                                pts_150mhz,
                                                ctx->frame_seq,
                                                flags);
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
        }

        if (!sent) {
            while (csr_read32(ctx, REG_PKT_STATUS) & 0x08) {
                csr_write32(ctx, REG_PKT_DOORBELL_POP, 1);
            }
            ctx->frames_dropped++;
            if (ctx->host_ring && ctx->host_ring->magic == QPCIE_VCU_RING_MAGIC) {
                ctx->host_ring->dropped_count++;
            }

            /* Self-heal: this AU never reached the host, so the downstream decoder
             * just lost its reference chain (grey/green artefacts until the next GOP
             * IDR). Ask the VCU to insert an IDR on the very next frame so the
             * decoder recovers immediately instead of waiting a full GOP.
             *
             * 掉禎自癒間隔限制為 1 秒，避免 Host 短暫飢餓時引發 IDR 暴風雪:
             * request_idr_keyframe() only rate-limits itself to 1 request/100ms, so
             * while the host ring stays stalled every dropped frame (30..60/s) would
             * otherwise punch a new IDR through every 100ms - ~10 huge keyframes per
             * second, flooding the log and burning VCU bandwidth. Gate the drop-driven
             * recovery path on our own 1s interval instead.
             *
             * Only worth doing once we have actually streamed an IDR to some host:
             * while nobody has ever connected (offline standby / host ring never
             * started) there is no downstream reference chain to recover, so asking
             * the VCU for IDR after every dropped frame just floods the log. */
            if (ctx->has_streamed_idr &&
                (now - ctx->last_drop_heal_ns >= 1000000000ULL)) {
                ctx->last_drop_heal_ns = now;
                request_idr_keyframe(ctx);
            }
        }
    }

    /* Recycle output buffer back to OpenMAX encoder */
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
                   "  --frames <N>        Exit after sending N frames (default: infinite)\n",
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
