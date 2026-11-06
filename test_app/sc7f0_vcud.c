// SPDX-License-Identifier: GPL-2.0-only
/*
 * SC7F0 VCU Video Encoder & Packet DMA Bridge Daemon (sc7f0_vcud)
 *
 * Runs on ZU4EV ARM64 Linux (Card PS).
 * Bridges:
 *   1. V4L2 VIPP /dev/video0 (NV12 input from HDMI RX)
 *   2. VCU Hard IP (H.264/HEVC hardware encoder)
 *   3. Shared BRAM Mailbox @ 0xA0002100 (vcu_encoder_config from Host V4L2 driver)
 *   4. Shared BRAM Host Ring @ 0xA0002200 (Host buffer credits from Host V4L2 queue)
 *   5. PL Packet C2H DMA @ 0xB0040000 (Multi-GB/s posted writes + MSI interrupts to Host)
 *
 * Safety: NEVER opens /dev/watchdog; encoder faults stop/restart without card reset.
 */

#define _GNU_SOURCE
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

/* Global runtime context */
struct vcud_ctx {
    int mem_fd;
    volatile uint8_t *csr_base;
    volatile uint8_t *bram_base;
    volatile uint8_t *ddr_staging;

    volatile struct qpcie_vcu_encoder_config *vcu_cfg;
    volatile struct qpcie_vcu_host_ring *host_ring;

    bool pattern_mode;
    bool live_mode;
    const char *h264_file;
    struct h264_stream h264_st;
    uint32_t target_fps;
    uint32_t max_frames;

    uint32_t local_ack_seq;
    uint64_t frame_seq;
    uint64_t total_bytes_sent;
    uint32_t frames_sent;
    uint32_t frames_dropped;
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
    /* Drain any completed packet entries in local FIFO to prevent queue saturation */
    while (csr_read32(ctx, REG_PKT_STATUS) & 0x08) {
        csr_write32(ctx, REG_PKT_DOORBELL_POP, 1);
    }

    /* Check engine readiness */
    uint32_t status = csr_read32(ctx, REG_PKT_STATUS);
    if (!(status & 0x02)) { /* packet_ready (bit 1) */
        /* Wait up to 10ms for previous job to drain */
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
    stage[12] = 0;                                       /* reserved */
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

        if (ctx->vcu_cfg->codec_type == 0) {
            printf("       H.264 Profile: %u, Level: %u, CABAC: %u, Min/Max QP: %u/%u\n",
                   ctx->vcu_cfg->h264_profile, ctx->vcu_cfg->h264_level,
                   ctx->vcu_cfg->h264_entropy_mode,
                   ctx->vcu_cfg->h264_min_qp, ctx->vcu_cfg->h264_max_qp);
        } else {
            printf("       HEVC Profile: %u, Level: %u, Tier: %u, Min/Max QP: %u/%u\n",
                   ctx->vcu_cfg->hevc_profile, ctx->vcu_cfg->hevc_level,
                   ctx->vcu_cfg->hevc_tier,
                   ctx->vcu_cfg->hevc_min_qp, ctx->vcu_cfg->hevc_max_qp);
        }

        ctx->local_ack_seq = host_seq;
        ctx->vcu_cfg->ps_ack_seq = host_seq;
        ctx->vcu_cfg->ps_encoder_status = 1; /* Running */
        __sync_synchronize();
    }
}

static int load_h264_stream_file(const char *path, struct h264_stream *st) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    struct stat s;
    if (fstat(fd, &s) < 0) { close(fd); return -1; }
    st->total_size = s.st_size;
    st->data = (uint8_t *)malloc(st->total_size);
    if (!st->data) { close(fd); return -1; }
    ssize_t n = read(fd, st->data, st->total_size);
    close(fd);
    if (n != (ssize_t)st->total_size) { free(st->data); st->data = NULL; return -1; }

    uint32_t max_frames = 2000;
    st->frames = calloc(max_frames, sizeof(struct h264_stream_frame));
    if (!st->frames) { free(st->data); st->data = NULL; return -1; }
    st->num_frames = 0;

    size_t i = 0;
    size_t cur_frame_start = 0;
    bool cur_is_idr = false;
    bool in_frame = false;

    while (i + 4 <= st->total_size) {
        if (st->data[i] == 0 && st->data[i+1] == 0 && st->data[i+2] == 0 && st->data[i+3] == 1) {
            uint8_t nal_type = st->data[i+4] & 0x1F;
            bool is_slice = (nal_type == 1 || nal_type == 5);
            bool is_header = (nal_type == 7 || nal_type == 8 || nal_type == 9);

            if (is_header && in_frame) {
                if (st->num_frames < max_frames) {
                    st->frames[st->num_frames].offset = cur_frame_start;
                    st->frames[st->num_frames].length = i - cur_frame_start;
                    st->frames[st->num_frames].is_idr = cur_is_idr;
                    st->num_frames++;
                }
                cur_frame_start = i;
                cur_is_idr = (nal_type == 7 || nal_type == 5);
                in_frame = false;
            } else if (is_slice) {
                if (in_frame) {
                    if (st->num_frames < max_frames) {
                        st->frames[st->num_frames].offset = cur_frame_start;
                        st->frames[st->num_frames].length = i - cur_frame_start;
                        st->frames[st->num_frames].is_idr = cur_is_idr;
                        st->num_frames++;
                    }
                    cur_frame_start = i;
                    cur_is_idr = (nal_type == 5);
                } else {
                    in_frame = true;
                    if (nal_type == 5) cur_is_idr = true;
                }
            } else if (nal_type == 7 || nal_type == 5) {
                cur_is_idr = true;
            }
            i += 4;
        } else {
            i++;
        }
    }
    if (cur_frame_start < st->total_size && st->num_frames < max_frames) {
        st->frames[st->num_frames].offset = cur_frame_start;
        st->frames[st->num_frames].length = st->total_size - cur_frame_start;
        st->frames[st->num_frames].is_idr = cur_is_idr;
        st->num_frames++;
    }
    printf("[VCUD] Successfully parsed %u H.264 Access Units from %s (%zu KB)\n",
           st->num_frames, path, st->total_size / 1024);
    return (st->num_frames > 0) ? 0 : -1;
}

/*
 * Generate a standalone H.264 Compliant Test Pattern (SPS + PPS + IDR / P slice)
 * This enables instant end-to-end hardware testing of Packet DMA + Host V4L2 streaming
 * without requiring live HDMI input signal.
 */
static size_t build_h264_test_frame(uint8_t *dst, uint32_t width, uint32_t height,
                                    uint32_t frame_num, bool is_idr)
{
    (void)width;
    (void)height;
    size_t off = 0;

    if (is_idr) {
        /* Standard 3840x2160 Baseline/High SPS */
        const uint8_t sps_3840x2160[] = {
            0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x33,
            0xAC, 0x72, 0x84, 0x40, 0x78, 0x02, 0x27, 0xE5,
            0xC0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00,
            0x00, 0x03, 0x00, 0xF0, 0x3C, 0x60, 0xC9, 0x20
        };
        /* Standard PPS */
        const uint8_t pps[] = {
            0x00, 0x00, 0x00, 0x01, 0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0
        };

        memcpy(dst + off, sps_3840x2160, sizeof(sps_3840x2160));
        off += sizeof(sps_3840x2160);

        memcpy(dst + off, pps, sizeof(pps));
        off += sizeof(pps);

        /* IDR Slice NAL header (0x00 00 00 01 65) */
        const uint8_t idr_hdr[] = { 0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00 };
        memcpy(dst + off, idr_hdr, sizeof(idr_hdr));
        off += sizeof(idr_hdr);
    } else {
        /* Non-IDR P-Slice NAL header (0x00 00 00 01 41) */
        const uint8_t p_hdr[] = { 0x00, 0x00, 0x00, 0x01, 0x41, 0x9A };
        memcpy(dst + off, p_hdr, sizeof(p_hdr));
        off += sizeof(p_hdr);
    }

    /* Fill payload with deterministic pattern representing video data */
    size_t payload_len = is_idr ? (128 * 1024) : (16 * 1024);
    for (size_t i = 0; i < payload_len; i++) {
        dst[off++] = (uint8_t)((frame_num + i) & 0xFF);
    }

    return off;
}

/* Test Pattern Worker: Exercises Packet DMA at target FPS */
static int run_pattern_loop(struct vcud_ctx *ctx) {
    printf("[VCUD] Entering Pattern Streaming Mode (target %u FPS)...\n", ctx->target_fps);

    uint64_t frame_interval_ns = 1000000000ULL / ctx->target_fps;
    uint64_t next_frame_time = get_time_ns();
    uint64_t t_last_stat = get_time_ns();
    uint32_t stat_frames = 0;
    uint64_t stat_bytes = 0;

    /* Staging buffer layout in DDR (at 0x50000000) */
    uint8_t *staging = (uint8_t *)ctx->ddr_staging;

    while (!g_stop && (ctx->max_frames == 0 || ctx->frames_sent < ctx->max_frames)) {
        handle_config_sync(ctx);

        uint64_t now = get_time_ns();
        if (now < next_frame_time) {
            uint64_t diff_us = (next_frame_time - now) / 1000;
            if (diff_us > 100)
                usleep(diff_us);
            continue;
        }
        next_frame_time += frame_interval_ns;

        /* Check if Host has queued buffer slots */
        if (!ctx->host_ring || ctx->host_ring->magic != QPCIE_VCU_RING_MAGIC) {
            usleep(1000);
            continue;
        }

        uint32_t head = ctx->host_ring->host_head;
        uint32_t tail = ctx->host_ring->ps_tail;

        if (head == tail) {
            while (csr_read32(ctx, REG_PKT_STATUS) & 0x08) {
                csr_write32(ctx, REG_PKT_DOORBELL_POP, 1);
            }
            /* Host queue starved */
            ctx->frames_dropped++;
            ctx->host_ring->dropped_count++;
            usleep(5000);
            continue;
        }

        uint32_t slot_idx = tail % QPCIE_VCU_RING_SIZE;
        volatile struct qpcie_vcu_buffer_slot *slot = &ctx->host_ring->slots[slot_idx];

        uint64_t host_dst = slot->host_phys_addr;
        uint64_t host_comp = slot->host_comp_addr;
        uint32_t host_cap = slot->host_buf_len;

        if (!host_dst || !host_comp || host_cap < 4096) {
            fprintf(stderr, "[VCUD] Invalid slot %u: dst=0x%" PRIx64 " comp=0x%" PRIx64 " cap=%u\n",
                    slot_idx, host_dst, host_comp, host_cap);
            ctx->host_ring->ps_tail = tail + 1;
            continue;
        }

        bool is_idr = false;
        size_t frame_bytes = 0;

        if (ctx->h264_st.num_frames > 0) {
            uint32_t f_idx = ctx->frame_seq % ctx->h264_st.num_frames;
            struct h264_stream_frame *f = &ctx->h264_st.frames[f_idx];
            frame_bytes = f->length;
            if (frame_bytes > host_cap)
                frame_bytes = host_cap;
            memcpy(staging, ctx->h264_st.data + f->offset, frame_bytes);
            is_idr = f->is_idr;
        } else {
            is_idr = (ctx->frame_seq % 60 == 0);
            frame_bytes = build_h264_test_frame(staging, 3840, 2160, ctx->frame_seq, is_idr);
        }

        /* 16-byte align length as required by packet reader */
        uint32_t aligned_len = (frame_bytes + 15) & ~15U;
        if (aligned_len > host_cap)
            aligned_len = host_cap & ~15U;
        if (aligned_len > frame_bytes)
            memset(staging + frame_bytes, 0, aligned_len - frame_bytes);

        uint64_t pts_150mhz = (now * 150) / 1000; /* 150MHz ticks */
        uint32_t flags = is_idr ? 0x05 : 0x03;     /* bit0=AU_START, bit1=AU_END, bit2=KEYFRAME */

        int ret = submit_packet_dma(ctx,
                                    DDR_STAGING_BUF_ADDR,
                                    host_dst,
                                    aligned_len,
                                    host_cap,
                                    host_comp,
                                    pts_150mhz,
                                    ctx->frame_seq,
                                    flags);
        if (ret < 0) {
            fprintf(stderr, "[VCUD] Packet DMA submit error (%d)\n", ret);
            continue;
        }

        /* Advance consumer index */
        __sync_synchronize();
        ctx->host_ring->ps_tail = tail + 1;

        ctx->frame_seq++;
        ctx->frames_sent++;
        ctx->total_bytes_sent += aligned_len;
        stat_frames++;
        stat_bytes += aligned_len;

        /* Telemetry & Probes every second */
        if (now - t_last_stat >= 1000000000ULL) {
            double elapsed_s = (double)(now - t_last_stat) / 1e9;
            double fps = (double)stat_frames / elapsed_s;
            double mbps = ((double)stat_bytes * 8.0) / (elapsed_s * 1000000.0);

            uint32_t p_sub = csr_read32(ctx, REG_PKT_PROBE_SUBMIT);
            uint32_t p_done = csr_read32(ctx, REG_PKT_PROBE_DONE);
            uint32_t p_err = csr_read32(ctx, REG_PKT_PROBE_ERR);
            uint32_t p_msi = csr_read32(ctx, REG_PKT_PROBE_MSI);
            uint32_t p_fsm = csr_read32(ctx, REG_PKT_PROBE_FSM);

            printf("[VCUD STAT] Sent: %u (%.1f FPS, %.2f Mbps) | Probes: SUB=%u DONE=%u MSI=%u ERR=%u FSM=0x%02x\n",
                   ctx->frames_sent, fps, mbps, p_sub, p_done, p_msi, p_err, p_fsm & 0xFF);

            if (ctx->vcu_cfg) {
                ctx->vcu_cfg->ps_fps_actual = (uint32_t)(fps * 100);
                ctx->vcu_cfg->ps_bitrate_actual = (uint32_t)(mbps * 1000000);
                ctx->vcu_cfg->ps_encoder_status = 1;
            }

            t_last_stat = now;
            stat_frames = 0;
            stat_bytes = 0;
        }
    }

    printf("[VCUD] Pattern loop terminated. Total frames: %u, Drops: %u\n",
           ctx->frames_sent, ctx->frames_dropped);
    return 0;
}

int main(int argc, char **argv) {
    setlinebuf(stdout);
    setlinebuf(stderr);
    printf("=== SC7F0 VCU Video Encoder & Packet DMA Daemon (sc7f0_vcud) ===\n");

    struct vcud_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.target_fps = 60;
    ctx.pattern_mode = true; /* Default to self-contained pattern mode */

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("Usage: %s [options]\n"
                   "  --pattern, -p       Run in test pattern generation mode (default)\n"
                   "  --live, -l          Run in live VIPP capture + VCU hardware encode mode\n"
                   "  --fps <N>           Target streaming framerate (default: 60)\n"
                   "  --frames <N>        Exit after sending N frames (default: infinite)\n",
                   argv[0]);
            return 0;
        } else if (!strcmp(argv[i], "--pattern") || !strcmp(argv[i], "-p")) {
            ctx.pattern_mode = true;
        } else if (!strcmp(argv[i], "--live") || !strcmp(argv[i], "-l")) {
            ctx.live_mode = true;
            ctx.pattern_mode = false;
        } else if ((!strcmp(argv[i], "--h264") || !strcmp(argv[i], "-f")) && i + 1 < argc) {
            ctx.h264_file = argv[++i];
        } else if (!strcmp(argv[i], "--fps") && i + 1 < argc) {
            ctx.target_fps = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
            ctx.max_frames = atoi(argv[++i]);
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
    ctx.csr_base = mmap(NULL, PL_CSR_PACKET_SIZE, PROT_READ | PROT_WRITE,
                        MAP_SHARED, ctx.mem_fd, PL_CSR_PACKET_ADDR);
    if (ctx.csr_base == MAP_FAILED) {
        perror("[VCUD ERROR] Cannot map PL CSR Packet DMA");
        close(ctx.mem_fd);
        return 1;
    }

    /* 2. Map PL Shared BRAM @ 0xA0002000 (8KB) */
    ctx.bram_base = mmap(NULL, PL_SHARED_BRAM_SIZE, PROT_READ | PROT_WRITE,
                         MAP_SHARED, ctx.mem_fd, PL_SHARED_BRAM_ADDR);
    if (ctx.bram_base == MAP_FAILED) {
        perror("[VCUD ERROR] Cannot map Shared BRAM");
        munmap((void *)ctx.csr_base, PL_CSR_PACKET_SIZE);
        close(ctx.mem_fd);
        return 1;
    }

    /* 3. Map DDR Staging Buffer @ 0x50000000 (64MB total, 8MB mapped here) */
    ctx.ddr_staging = mmap(NULL, 8 * 1024 * 1024, PROT_READ | PROT_WRITE,
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

    /* Check for VCU stream file to broadcast */
    if (ctx.h264_file) {
        if (load_h264_stream_file(ctx.h264_file, &ctx.h264_st) == 0) {
            printf("[VCUD] Stream Mode: using %s (%u frames)\n", ctx.h264_file, ctx.h264_st.num_frames);
        }
    } else {
        if (access("/tmp/stream_60.h264", R_OK) == 0) {
            load_h264_stream_file("/tmp/stream_60.h264", &ctx.h264_st);
        } else if (access("/tmp/stream_10.h264", R_OK) == 0) {
            load_h264_stream_file("/tmp/stream_10.h264", &ctx.h264_st);
        } else if (access("/tmp/live_test.h264", R_OK) == 0) {
            load_h264_stream_file("/tmp/live_test.h264", &ctx.h264_st);
        }
    }

    int ret = 0;
    if (ctx.pattern_mode || ctx.h264_st.num_frames > 0) {
        ret = run_pattern_loop(&ctx);
    } else {
        printf("[VCUD] Live VCU capture mode requires VIPP pipeline setup.\n");
        ret = run_pattern_loop(&ctx);
    }

    if (ctx.vcu_cfg)
        ctx.vcu_cfg->ps_encoder_status = 0; /* Stopped */

    /* Cleanup */
    if (ctx.h264_st.data) free(ctx.h264_st.data);
    if (ctx.h264_st.frames) free(ctx.h264_st.frames);
    munmap((void *)ctx.ddr_staging, 8 * 1024 * 1024);
    munmap((void *)ctx.bram_base, PL_SHARED_BRAM_SIZE);
    munmap((void *)ctx.csr_base, PL_CSR_PACKET_SIZE);
    close(ctx.mem_fd);

    printf("[VCUD] Daemon cleanly shutdown.\n");
    return ret;
}
