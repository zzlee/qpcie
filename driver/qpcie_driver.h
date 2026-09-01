/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Header: qpcie_driver.h
 * Description: Linux Kernel Driver Header for Custom PCIe Multi-Channel 2D Video (V4L2)
 *              and AES3 Audio (ALSA) DMA Controller.
 */

#ifndef _QPCIE_DRIVER_H_
#define _QPCIE_DRIVER_H_

#include <linux/version.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/interrupt.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>
#include <linux/kthread.h>
#include <linux/hrtimer.h>
#include <linux/spinlock.h>
#include <linux/sched.h>
#include <uapi/linux/sched/types.h>

#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-ctrls.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-dma-sg.h>
#include <media/videobuf2-dma-contig.h>

#include <sound/core.h>
#include <sound/control.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>

/* Standard Linux Kernel Version Conditional Handling (LINUX_VERSION_CODE) */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 19, 0)
    /* Linux Kernel < 5.19 (e.g. Tegra 5.15.148) uses PCI_IRQ_LEGACY */
    #ifndef PCI_IRQ_INTX
        #define PCI_IRQ_INTX PCI_IRQ_LEGACY
    #endif
#else
    /* Linux Kernel >= 5.19 uses PCI_IRQ_INTX */
    #ifndef PCI_IRQ_LEGACY
        #define PCI_IRQ_LEGACY PCI_IRQ_INTX
    #endif
#endif

#define QPCIE_VENDOR_ID   0x12AB /* Custom PCI Vendor ID */
#define QPCIE_DEVICE_ID   0xE380 /* Custom PCIe DMA Device ID */

#define NUM_VIDEO_NODES    7
#define NUM_VIDEO_CHANNELS 4
#define NUM_AUDIO_CHANNELS 4
#define RING_BUFFER_SIZE   16

/* Private V4L2 control used only for controlled DMA throughput testing. */
#define V4L2_CID_QPCIE_PACER_ENABLE (V4L2_CID_USER_BASE + 0x1000)

/* BAR0 DMA Register Offsets */
#define REG_DMA_CTRL         0x00
#define REG_DMA_STATUS       0x04
#define DMA_CTRL_RUN         BIT(0)
#define DMA_CTRL_RESET       BIT(1)
#define DMA_CTRL_AUDIO_RUN   BIT(2)
#define REG_H2C_RING_ADDR_L  0x08
#define REG_H2C_RING_ADDR_H  0x0C
#define REG_H2C_RING_CFG     0x10
#define REG_C2H_RING_ADDR_L  0x14
#define REG_C2H_RING_ADDR_H  0x18
#define REG_C2H_RING_CFG     0x1C
#define REG_IRQ_CTRL         0x20
#define REG_IRQ_STATUS       0x24
#define REG_COMPLETED_H2C    0x28
#define REG_COMPLETED_C2H    0x2C
#define REG_VERSION_ID       0x30
#define REG_GIT_COMMIT_HASH  0x34
#define REG_BUILD_TIMESTAMP  0x38
#define REG_HARDWARE_CAPS    0x3C
#define REG_PACER_CTRL       0x74    /* Video Pacer Bypass Control (0=Bypass, 1=Enable) */
#define REG_VIDEO_SUB_RESET  0x84    /* Bit0: TPG-only reset, Bit1: NV12 engine reset */
#define REG_TPG_SOF_COUNT    0x88    /* Free-running TPG start-of-frame counter (RO) */
#define REG_TPG_EOL_COUNT    0x8C    /* Free-running line-end (TLAST) counter (RO) */
#define REG_TPG_BEAT_COUNT   0x90    /* Free-running valid-beat counter (RO) */
#define REG_SLICE_HEIGHT     0x78    /* Sub-Frame Slice Height in Lines (0=Full Frame IRQ, >0=Slice IRQ) */
#define REG_VIDEO_ERRORS     0x7C    /* AXI-video framing/configuration error count */
#define REG_VIDEO_CTRL       0x80    /* Bit 0: reset TPG and video CDC FIFO */

/* Hardware Performance Monitor Registers (BAR0 Offsets 0xA0..0xDC) */
#define REG_PERF_CTRL               0xA0 /* Bit 0: Enable, Bit 1: Reset (W1C) */
#define REG_PERF_CYCLES_L           0xA4 /* Clocks while enabled [31:0] */
#define REG_PERF_CYCLES_H           0xA8 /* Clocks while enabled [63:32] */
#define REG_PERF_TLP_COUNT          0xAC /* Total TLPs transmitted */
#define REG_PERF_PAYLOAD_BYTES_L    0xB0 /* Total payload bytes [31:0] */
#define REG_PERF_PAYLOAD_BYTES_H    0xB4 /* Total payload bytes [63:32] */
#define REG_PERF_TX_ACTIVE_CYCLES   0xB8 /* Cycles when tx_tvalid && tx_tready */
#define REG_PERF_TX_IDLE_CYCLES     0xBC /* Cycles when !tx_tvalid */
#define REG_PERF_TREADY_STALL_CYCLES 0xC0 /* Cycles when tx_tvalid && !tx_tready (PCIe backpressure) */
#define REG_PERF_INTER_TLP_GAP      0xC4 /* Idle cycles between TLPs when FIFO is non-empty */
#define REG_PERF_TLP_128B_COUNT     0xC8 /* Count of 128B TLPs */
#define REG_PERF_TLP_256B_COUNT     0xCC /* Count of 256B TLPs */
#define REG_PERF_SPLIT_4K_COUNT     0xD0 /* Count of 4KB boundary splits */
#define REG_PERF_MAX_QUEUE_DEPTH    0xD4 /* Peak CDC FIFO depth */
#define REG_PERF_IDLE_CDC_EMPTY     0xD8 /* Idle cycles due to empty CDC FIFO */
#define REG_PERF_IDLE_NO_REQ        0xDC /* Idle cycles with no DMA request */

#define DMA_STATUS_VIDEO_TX_IDLE    BIT(8) /* Channel-0 CDC and requester drained */
#define DMA_STATUS_DESC_IDLE        BIT(9) /* Descriptor fetch FSM quiescent */

/* Scatter-Gather Page Table & Status Registers (BAR0 Offsets 0xE0..0xEC) */
#define REG_SG_PT_CTRL              0xE0 /* Page Table Target Address [10:0] */
#define REG_SG_PT_DATA_LO           0xE4 /* Physical Address [31:0] */
#define REG_SG_PT_DATA_HI           0xE8 /* Physical Address [63:32] (Bit 31: 0=Y, 1=UV) */
#define REG_SG_STATUS               0xEC /* Current Page Indexes [31:16]=UV, [15:0]=Y */

#define QPCIE_SG_MODE_MMIO          1    /* Mode 1: CPU writes REG_SG_PT_DATA_LO/HI into BRAM */
#define QPCIE_SG_MODE_HOST_FETCH    2    /* Mode 2: FPGA Active PCIe MRd Linked Page Table Fetch */

#define DESC_CTRL_SG_MODE           0x10 /* Bit 4: Scatter-Gather Multi-Page Table Mode (MMIO BRAM) */
#define DESC_CTRL_SG_MMIO_MODE      0x10 /* Bit 4: SG Mode with MMIO BRAM Page Table */
#define DESC_CTRL_SG_FETCH_MODE     0x20 /* Bit 5: SG Mode with FPGA Host MRd Linked Page Table Fetch */
#define DESC_CTRL_CHANNEL_SHIFT     6    /* Bits 7:6: video channel, independent of IRQ enable */
#define DESC_CTRL_CHANNEL_MASK      GENMASK(7, 6)

#define QPCIE_MAX_PAGE_SLOTS_Y      8    /* Up to 2040 SGL segments (Gigabytes) */
#define QPCIE_MAX_PAGE_SLOTS_UV     4    /* Up to 1020 SGL segments (Gigabytes) */

/* 128-Bit Variable-Length SGL Entry Structure (16 Bytes Wire Format) */
struct __packed qpcie_sgl_entry {
    u64 phys_addr;   /* Bytes 0..7   : DW0-DW1 (Physical base address) */
    u32 len_bytes;   /* Bytes 8..11  : DW2     (Contiguous length in bytes) */
    u32 flags;       /* Bytes 12..15 : DW3     (Bit 0: Chain Pointer, Bit 1: Last Segment) */
};

#define SGL_FLAG_CHAIN_PTR          BIT(0) /* Points to next 4KB SGL slot */
#define SGL_FLAG_LAST_SEG           BIT(1) /* End of current planar payload */

/* 64-Byte 2D Multi-Planar Extended Descriptor Structure (Hardware Wire Format) */
struct __packed qpcie_dma_desc_64b {
    u64 plane0_src_addr; /* Bytes 0..7   : DW0-DW1 (Src Buffer Phys Addr) */
    u64 plane0_dst_addr; /* Bytes 8..15  : DW2-DW3 (Dst Buffer Phys Addr) */
    u64 plane1_src_addr; /* Bytes 16..23 : DW4-DW5 */
    u64 plane1_dst_addr; /* Bytes 24..31 : DW6-DW7 */
    u64 plane2_src_addr; /* Bytes 32..39 : DW8-DW9 */
    u64 plane2_dst_addr; /* Bytes 40..47 : DW10-DW11 */
    u16 line_width;      /* Bytes 48..49 : DW12[15:0] (Line Width Bytes, e.g. 4096) */
    u16 line_count;      /* Bytes 50..51 : DW12[31:16] (Total Lines, e.g. 1) */
    u16 src_stride;      /* Bytes 52..53 : DW13[15:0] (Src Line Stride Bytes) */
    u16 dst_stride;      /* Bytes 54..55 : DW13[31:16] (Dst Line Stride Bytes) */
    u16 plane12_width;   /* Bytes 56..57 : DW14[15:0] */
    u16 plane12_count;   /* Bytes 58..59 : DW14[31:16] */
    union {
        struct {
            u8 format : 4;
            u8 plane_count : 4;
            u8 control;
            u16 reserved;
        };
        u32 dw15_raw;
    };
};

/* Compatibility Typedef */
#define qpcie_dma_desc_2d qpcie_dma_desc_64b

struct qpcie_dev;

struct qpcie_v4l2_buffer {
    struct vb2_v4l2_buffer vb;
    struct list_head list;
    void *y_slots_virt;
    dma_addr_t y_slots_dma;
    void *uv_slots_virt;
    dma_addr_t uv_slots_dma;
    bool sgl_logged;
};

struct qpcie_v4l2_channel {
    int channel_id;
    struct qpcie_dev *qdev;
    struct video_device vdev;
    struct v4l2_device v4l2_dev;
    struct vb2_queue queue;
    struct v4l2_ctrl_handler ctrl_handler;
    struct mutex lock;
    spinlock_t slock;
    struct list_head pending_buffers;
    struct list_head active_buffers;
    u32 sequence;
    u32 width;
    u32 height;
    u32 stride;
    u32 pixelformat;
    u32 current_slice_idx;
    u32 error_count_start;
    bool pacer_enable;
    enum v4l2_buf_type buf_type;
};

struct qpcie_alsa_channel {
    int channel_id;
    struct qpcie_dev *qdev;
    struct snd_card *card;
    struct snd_pcm *pcm;
    struct snd_pcm_substream *substream;
    spinlock_t slock;
    u32 buffer_pos;
    u32 period_pos;
    u32 pattern_id;
    u32 volume;
};

struct qpcie_dev {
    struct pci_dev *pdev;
    void __iomem *bar0_mmio;
    void __iomem *bar1_mmio;

    int irq;
    bool v4l2_registered;

    /* Saved MPS state when probe had to raise it for 256-byte MWr. */
    bool mps_modified;
    int ep_mps_saved;
    int rp_mps_saved;

    /* Descriptor Ring Buffer Handles */
    struct qpcie_dma_desc_2d *h2c_ring_virt;
    dma_addr_t h2c_ring_dma;
    u32 h2c_tail;

    struct qpcie_dma_desc_2d *c2h_ring_virt;
    dma_addr_t c2h_ring_dma;
    u32 c2h_tail;
    spinlock_t ring_lock;

    /* Subsystem Devices */
    struct v4l2_device v4l2_dev;
    struct qpcie_v4l2_channel v4l2_ch[NUM_VIDEO_NODES];
    struct qpcie_alsa_channel alsa_ch[NUM_AUDIO_CHANNELS];

    struct snd_card *card;
    struct snd_pcm *pcm;

    /* Scatter-Gather Linked Page Table Fetch Mode */
    int sg_fetch_mode; /* 1: MMIO BRAM, 2: Host Active MRd Fetch */

    /* One-shot TPG pacing (fixed frame-rate mode).  The kthread re-arms
     * AP_START at the target rate while V4L2 streaming is active; the TPG
     * idles between frames, so it is never frozen mid-frame. */
    struct task_struct *tpg_pace_task;
    bool tpg_pace_run;
    u32 tpg_fps;
    spinlock_t tpg_lock;
};

/* Submodule Function Declarations */
int qpcie_v4l2_init(struct qpcie_dev *qdev);
void qpcie_v4l2_remove(struct qpcie_dev *qdev);
void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev);
void qpcie_dma_soft_reset(struct qpcie_dev *qdev);

int qpcie_alsa_init(struct qpcie_dev *qdev);
void qpcie_alsa_remove(struct qpcie_dev *qdev);
void qpcie_alsa_irq_handler(struct qpcie_dev *qdev);

int qpcie_sysfs_init(struct qpcie_dev *qdev);
void qpcie_sysfs_remove(struct qpcie_dev *qdev);

int qpcie_v4l2_export_dmabuf(struct qpcie_v4l2_channel *vch, struct v4l2_exportbuffer *exp);

#endif /* _QPCIE_DRIVER_H_ */
