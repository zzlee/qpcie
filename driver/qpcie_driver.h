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
#include <linux/delay.h>
#include <linux/workqueue.h>
#include <linux/i2c.h>
#include <linux/mutex.h>
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

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
    #define qpcie_hrtimer_init(timer, fn, clkid, mode) \
        hrtimer_setup(timer, fn, clkid, mode)
#else
    #define qpcie_hrtimer_init(timer, fn, clkid, mode) \
        do { \
            hrtimer_init(timer, clkid, mode); \
            (timer)->function = (fn); \
        } while (0)
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
    #define BIN_ATTR_ARG const struct bin_attribute *
#else
    #define BIN_ATTR_ARG struct bin_attribute *
#endif

#define QPCIE_VENDOR_ID   0x12AB /* Custom PCI Vendor ID */
#define QPCIE_DEVICE_ID   0xE380 /* Custom PCIe DMA Device ID */

#define NUM_VIDEO_NODES    7
#define NUM_VIDEO_CHANNELS 4
#define NUM_AUDIO_CHANNELS 4
#define RING_BUFFER_SIZE   128

/* Per-channel IRQ status bits in REG_IRQ_STATUS (Offset 0x24) */
#define IRQ_STATUS_H2C_GLOBAL       BIT(0)
#define IRQ_STATUS_C2H_GLOBAL       BIT(1)
#define IRQ_STATUS_C2H_CH(ch)       BIT(4 + (ch)) /* Bits 4..7: C2H Ch0..Ch3 */
#define IRQ_STATUS_H2C_CH(ch)       BIT(7 + (ch)) /* Bits 8..10: H2C Ch1..Ch3 */
#define IRQ_STATUS_AUDIO            BIT(11)       /* Bit 11: Audio Ch0 Period Done */
#define IRQ_STATUS_AUDIO_CH(ch)     BIT(11 + (ch))/* Bits 11..14: Audio Ch0..Ch3 Period Done */
#define IRQ_STATUS_AUDIO_MASK       (BIT(11) | BIT(12) | BIT(13) | BIT(14))
#define IRQ_STATUS_CHANNEL_MASK     0x000007F0    /* Bits 4..10 */
#define IRQ_STATUS_ALL_MASK         0x00007FF3    /* Bits 0..1, 4..14 */

/* BAR0 Offsets (PS + PCIe host shared, pl_clk0 domain) */
#define BAR0_OFFSET_ENV             0x1000  /* zzlab_env_ctrl: version/platform/board */

/* BAR1 Offsets (PCIe host only) */
#define BAR1_OFFSET_ENV             0x0000  /* DEPRECATED: DECERR hole since C_VERSION 26100805; use BAR0_OFFSET_ENV */
#define BAR1_OFFSET_AUDIO_GEN       0x1000
#define BAR1_OFFSET_EDID            0x2000
#define BAR1_OFFSET_TPG             0x3000
#define BAR1_OFFSET_I2C             0x4000
#define BAR1_OFFSET_SPI_FLASH       0x5000

/* I2C Master Registers (BAR1 Offset 0x3000) */
#define REG_I2C_PRER_LO             0x00
#define REG_I2C_PRER_HI             0x04
#define REG_I2C_CTR                 0x08
#define REG_I2C_TXR                 0x0C
#define REG_I2C_RXR                 0x0C
#define REG_I2C_CR                  0x10
#define REG_I2C_SR                  0x14

#define I2C_CTR_EN                  BIT(7)
#define I2C_CTR_IEN                 BIT(6)

#define I2C_CR_STA                  BIT(7)
#define I2C_CR_STO                  BIT(6)
#define I2C_CR_RD                   BIT(5)
#define I2C_CR_WR                   BIT(4)
#define I2C_CR_ACK                  BIT(3)
#define I2C_CR_IACK                 BIT(0)

#define I2C_SR_RXACK                BIT(7)
#define I2C_SR_BUSY                 BIT(6)
#define I2C_SR_AL                   BIT(5)
#define I2C_SR_TIP                  BIT(1)
#define I2C_SR_IF                   BIT(0)

/* SPI Flash & ICAP Registers (BAR1 Offset 0x4000) */
#define REG_SPI_CR                  0x00
#define REG_SPI_SR                  0x04
#define REG_SPI_TXD                 0x08
#define REG_SPI_RXD                 0x0C
#define REG_ICAP_CMD                0x20
#define REG_ICAP_STATUS             0x24

#define SPI_CR_CS_N                 BIT(0)
#define SPI_CR_SPI_EN               BIT(1)
#define SPI_SR_BUSY                 BIT(0)
#define SPI_SR_RX_VALID             BIT(1)
#define ICAP_MAGIC_RELOAD           0x52454C4F

/* Private V4L2 controls for QPCIe TPG capture diagnostics. */
#define V4L2_CID_QPCIE_PACER_ENABLE     (V4L2_CID_USER_BASE + 0x1000)
#define V4L2_CID_QPCIE_TPG_MOTION_SPEED (V4L2_CID_USER_BASE + 0x1001)
#define V4L2_CID_QPCIE_FRAME_DROP_COUNT (V4L2_CID_USER_BASE + 0x1002)
#define V4L2_CID_QPCIE_TPG_OVERLAY      (V4L2_CID_USER_BASE + 0x1003)

/* BAR0 DMA Register Offsets */
#define REG_DMA_CTRL         0x00
#define REG_DMA_STATUS       0x04
#define DMA_CTRL_RUN         BIT(0)
#define DMA_CTRL_RESET       BIT(1)
#define DMA_CTRL_AUDIO_RUN   BIT(2)
#define DMA_CTRL_AUDIO_RUN_CH(ch) BIT(2 + (ch))
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
#define REG_AUDIO_DMA_ADDR_L 0x48    /* Audio Ch0 Host Buffer Phys Addr Low [31:0] */
#define REG_AUDIO_DMA_ADDR_H 0x4C    /* Audio Ch0 Host Buffer Phys Addr High [63:32] */
#define REG_AUDIO_DMA_CFG    0x94    /* [15:0]=buf_size_bytes, [31:16]=period_size_bytes */
#define REG_AUDIO_DMA_PTR    0x98    /* Current hardware write pointer in bytes (RO) */

/* Multi-Channel Audio C2H DMA & H2C Playback Registers (0x100..0x160) */
#define REG_AUDIO_DMA_ADDR_CH_L(ch) (0x100 + ((ch) * 0x10))
#define REG_AUDIO_DMA_ADDR_CH_H(ch) (0x104 + ((ch) * 0x10))
#define REG_AUDIO_DMA_CFG_CH(ch)    (0x108 + ((ch) * 0x10))
#define REG_AUDIO_DMA_PTR_CH(ch)    (0x10C + ((ch) * 0x10))

#define REG_AUDIO_H2C_DATA_CH(ch)   (0x150 + (((ch) - 1) * 0x04))
#define REG_AUDIO_H2C_STATUS        0x15C
#define REG_AUDIO_LOOPBACK_CTRL     0x160

#define H2C_FIFO_COUNT_CH(st, ch)   (((st) >> (((ch) - 1) * 8)) & 0xFF)
#define H2C_FIFO_FULL_CH(st, ch)    (((st) >> (24 + ((ch) - 1))) & 0x01)
#define H2C_FIFO_EMPTY_CH(st, ch)   (((st) >> (28 + ((ch) - 1))) & 0x01)
#define REG_PACER_CTRL       0x74    /* Video Pacer Bypass Control (0=Bypass, 1=Enable) */
#define REG_VIDEO_SUB_RESET  0x84    /* Bit0: TPG-only reset, Bit1: NV12 engine reset */
#define REG_TPG_SOF_COUNT    0x88    /* Free-running TPG start-of-frame counter (RO) */
#define REG_TPG_EOL_COUNT    0x8C    /* Free-running line-end (TLAST) counter (RO) */
#define REG_TPG_BEAT_COUNT   0x90    /* Free-running valid-beat counter (RO) */
#define REG_SLICE_HEIGHT     0x78    /* Sub-Frame Slice Height in Lines (0=Full Frame IRQ, >0=Slice IRQ) */
#define REG_VIDEO_ERRORS     0x7C    /* Ch0 capture engine frame-drop count */
#define REG_VIDEO_CTRL       0x80    /* Bit 0: reset TPG and video CDC FIFO */
#define REG_VIDEO_OVERLAY    0x88    /* Bit 0: diagnostic marker overlay enable */

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

/* Phase 2/3 New Register Map Offsets */
#define REG_NEW_GLOBAL_ID           0x00
#define REG_NEW_GLOBAL_VERSION      0x04
#define REG_NEW_GLOBAL_CAPS         0x08
#define REG_NEW_GLOBAL_GITHASH      0x0C
#define REG_NEW_GLOBAL_BUILDTIME    0x10
#define REG_NEW_GLOBAL_RESET        0x14
#define REG_NEW_GLOBAL_IRQ_TOP      0x18
#define REG_NEW_GLOBAL_TIMESTAMP_L  0x1C
#define REG_NEW_GLOBAL_TIMESTAMP_H  0x20
#define REG_NEW_GLOBAL_IRQ_STATUS   0x24
#define REG_NEW_GLOBAL_DMA_STATUS   0x28

/* Debug Block (0x900 - 0x9FF) */
#define REG_NEW_DEBUG_BASE          0x900
#define REG_NEW_DEBUG_LOOPBACK_CTRL 0x900
#define REG_NEW_DEBUG_PATTERN_GEN   0x904
#define REG_NEW_DEBUG_PACER_OVERRIDE 0x908
#define REG_NEW_DEBUG_LAST_WDATA    0x90C
#define REG_NEW_DEBUG_LAST_WADDR    0x910

/* Video Channel Blocks (0x100 + n*0x100) */
#define REG_VCH_BASE(n)             (0x100 * (1 + (n)))
#define REG_VCH_OFFSET_CTRL         0x00
#define REG_VCH_OFFSET_STATUS       0x04
#define REG_VCH_OFFSET_WIDTH        0x08
#define REG_VCH_OFFSET_HEIGHT       0x0C
#define REG_VCH_OFFSET_STRIDE0      0x10
#define REG_VCH_OFFSET_STRIDE1      0x14
#define REG_VCH_OFFSET_OVERLAY      0x18
#define REG_VCH_OFFSET_RING0_BASE_L 0x20
#define REG_VCH_OFFSET_RING0_BASE_H 0x24
#define REG_VCH_OFFSET_RING0_CFG    0x28
#define REG_VCH_OFFSET_RING0_HEAD   0x2C
#define REG_VCH_OFFSET_RING1_BASE_L 0x30
#define REG_VCH_OFFSET_RING1_BASE_H 0x34
#define REG_VCH_OFFSET_RING1_CFG    0x38
#define REG_VCH_OFFSET_RING1_HEAD   0x3C
#define REG_VCH_OFFSET_FRAMES       0x60
#define REG_VCH_OFFSET_DROPS        0x64
#define REG_VCH_OFFSET_IRQ_STATUS   0x70

#define REG_VCH_CTRL(n)             (REG_VCH_BASE(n) + REG_VCH_OFFSET_CTRL)
#define REG_VCH_STATUS(n)           (REG_VCH_BASE(n) + REG_VCH_OFFSET_STATUS)
#define REG_VCH_WIDTH(n)            (REG_VCH_BASE(n) + REG_VCH_OFFSET_WIDTH)
#define REG_VCH_HEIGHT(n)           (REG_VCH_BASE(n) + REG_VCH_OFFSET_HEIGHT)
#define REG_VCH_STRIDE0(n)          (REG_VCH_BASE(n) + REG_VCH_OFFSET_STRIDE0)
#define REG_VCH_STRIDE1(n)          (REG_VCH_BASE(n) + REG_VCH_OFFSET_STRIDE1)
#define REG_VCH_OVERLAY(n)          (REG_VCH_BASE(n) + REG_VCH_OFFSET_OVERLAY)
#define REG_VCH_RING0_BASE_L(n)     (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING0_BASE_L)
#define REG_VCH_RING0_BASE_H(n)     (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING0_BASE_H)
#define REG_VCH_RING0_CFG(n)        (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING0_CFG)
#define REG_VCH_RING0_HEAD(n)       (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING0_HEAD)
#define REG_VCH_RING1_BASE_L(n)     (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING1_BASE_L)
#define REG_VCH_RING1_BASE_H(n)     (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING1_BASE_H)
#define REG_VCH_RING1_CFG(n)        (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING1_CFG)
#define REG_VCH_RING1_HEAD(n)       (REG_VCH_BASE(n) + REG_VCH_OFFSET_RING1_HEAD)
#define REG_VCH_FRAMES(n)           (REG_VCH_BASE(n) + REG_VCH_OFFSET_FRAMES)
#define REG_VCH_DROPS(n)            (REG_VCH_BASE(n) + REG_VCH_OFFSET_DROPS)
#define REG_VCH_IRQ_STATUS(n)       (REG_VCH_BASE(n) + REG_VCH_OFFSET_IRQ_STATUS)

/* Legacy / CH0 Aliases */
#define REG_VCH0_CTRL               REG_VCH_CTRL(0)
#define REG_VCH0_STATUS             REG_VCH_STATUS(0)
#define REG_VCH0_WIDTH              REG_VCH_WIDTH(0)
#define REG_VCH0_HEIGHT             REG_VCH_HEIGHT(0)
#define REG_VCH0_STRIDE0            REG_VCH_STRIDE0(0)
#define REG_VCH0_STRIDE1            REG_VCH_STRIDE1(0)
#define REG_VCH0_RING0_BASE_L       REG_VCH_RING0_BASE_L(0)
#define REG_VCH0_RING0_BASE_H       REG_VCH_RING0_BASE_H(0)
#define REG_VCH0_RING0_CFG          REG_VCH_RING0_CFG(0)
#define REG_VCH0_RING0_HEAD         REG_VCH_RING0_HEAD(0)
#define REG_VCH0_RING1_BASE_L       REG_VCH_RING1_BASE_L(0)
#define REG_VCH0_RING1_BASE_H       REG_VCH_RING1_BASE_H(0)
#define REG_VCH0_RING1_CFG          REG_VCH_RING1_CFG(0)
#define REG_VCH0_RING1_HEAD         REG_VCH_RING1_HEAD(0)
#define REG_VCH0_FRAMES             REG_VCH_FRAMES(0)
#define REG_VCH0_DROPS              REG_VCH_DROPS(0)
#define REG_VCH0_IRQ_STATUS         REG_VCH_IRQ_STATUS(0)

/* Phase 4 P4-2: Audio DEV0 Block (New Map: 0x500 - 0x5A8) */
#define REG_ADEV0_CTRL              0x500  /* [0]=enable, [8]=irq_en, [31]=xrun_inject */
#define REG_ADEV0_STATUS            0x504  /* [0]=running (RO), [1]=xrun (W1C sticky) */
#define REG_ADEV0_RATE              0x508  /* Sample rate in Hz (e.g. 48000) */
#define REG_ADEV0_PERIOD_BYTES      0x50C  /* Period size in bytes */
#define REG_ADEV0_BUFFER_BYTES      0x510  /* Circular buffer size in bytes */
#define REG_ADEV0_POSITION          0x514  /* RO: current HW write pointer (bytes) */
#define REG_ADEV0_RING0_BASE_L      0x520  /* Host circular buffer DMA phys addr [31:0] */
#define REG_ADEV0_RING0_BASE_H      0x524  /* Host circular buffer DMA phys addr [63:32] */
#define REG_ADEV0_RING0_CFG         0x528  /* Ring config (reserved) */
#define REG_ADEV0_PTR               0x5A4  /* RO: alias of POSITION */
#define REG_ADEV0_IRQ_STATUS        0x5A8  /* [0]=period_done, [1]=xrun (all W1C) */

/* IRQ_TOP bits for Audio DEV0 */
#define IRQ_TOP_AUD                 BIT(4) /* Audio DEV0 event (period done or xrun) */
#define IRQ_TOP_ERR                 BIT(5) /* Any error event */

/* HDMI RX Status / Primary Registers (0x0600 - 0x060C) */
#define REG_HDMI_RX_STATUS          0x0600
#define REG_HDMI_RX_WIDTH           0x0604
#define REG_HDMI_RX_HEIGHT          0x0608
#define REG_HDMI_RX_PIXEL_CLK       0x060C

#define HDMI_RX_STATUS_5V_DET       BIT(0)
#define HDMI_RX_STATUS_HPD          BIT(1)
#define HDMI_RX_STATUS_LNK_LOCK     BIT(2)
#define HDMI_RX_STATUS_STREAM_UP    BIT(3)

/* HDMI TX Status / Control Registers (0x0610 - 0x0620) */
#define REG_HDMI_TX_CTRL            0x0610
#define REG_HDMI_TX_RES             0x0614
#define REG_HDMI_TX_FPS             0x0618
#define REG_HDMI_TX_STATUS          0x0620

/* HDMI Inter-Processor Mailbox Registers (0x0630 - 0x063C) */
#define REG_HDMI_IPC_CMD            0x0630
#define REG_HDMI_IPC_ARG            0x0634
#define REG_HDMI_IPC_STATUS         0x0638
#define REG_HDMI_IPC_DOORBELL       0x063C

/* Detailed DV Timings & InfoFrames from xilinx-hdmirxss (0x0640 - 0x0664) */
#define REG_HDMI_RX_HFP             0x0640 /* Horizontal Front Porch */
#define REG_HDMI_RX_HSW             0x0644 /* Horizontal Sync Width */
#define REG_HDMI_RX_HBP             0x0648 /* Horizontal Back Porch */
#define REG_HDMI_RX_VFP             0x064C /* Vertical Front Porch */
#define REG_HDMI_RX_VSW             0x0650 /* Vertical Sync Width */
#define REG_HDMI_RX_VBP             0x0654 /* Vertical Back Porch */
#define REG_HDMI_RX_POLARITIES      0x0658 /* Bit 0: VSync Pos, Bit 1: HSync Pos */
#define REG_HDMI_RX_STANDARDS       0x065C /* Standards (e.g. V4L2_DV_BT_STD_CEA861) */
#define REG_HDMI_RX_COLOR_FMT       0x0660 /* Colorspace, Quantization, YCbCr Enc */
#define REG_HDMI_RX_AUDIO_FMT       0x0664 /* [15:0]=SampleRateHz, [23:16]=Channels, [31:24]=BitDepth */

/* Scatter-Gather Page Table & Status Registers (BAR0 Offsets 0xE0..0xEC) */
#define REG_SG_PT_CTRL              0xE0 /* Page Table Target Address [10:0] */
#define REG_SG_PT_DATA_LO           0xE4 /* Physical Address [31:0] */
#define REG_SG_PT_DATA_HI           0xE8 /* Physical Address [63:32] (Bit 31: 0=Y, 1=UV) */
#define REG_SG_STATUS               0xEC /* Current Page Indexes [31:16]=UV, [15:0]=Y */

#define QPCIE_SG_MODE_MMIO          1    /* Legacy MMIO BRAM mode */
#define QPCIE_SG_MODE_HOST_FETCH    2    /* Active Host MRd Fetch mode */

/* 128-Bit Variable-Length SGL Entry Structure (16 Bytes Canonical Wire Format) */
struct __packed qpcie_sgl_entry {
    u64 phys_addr;   /* Bytes 0..7   : DW0-DW1 (Physical base address) */
    u32 len_bytes;   /* Bytes 8..11  : DW2     (Contiguous length in bytes) */
    u32 flags;       /* Bytes 12..15 : DW3     (Bit 0: Chain Pointer, Bit 1: Last Segment) */
};

#define qpcie_dma_desc_16b qpcie_sgl_entry

#define SGL_FLAG_CHAIN_PTR          BIT(0) /* Points to next 4KB SGL slot */
#define SGL_FLAG_LAST_SEG           BIT(1) /* End of current planar payload */

struct qpcie_dev;

struct qpcie_v4l2_buffer {
    struct vb2_v4l2_buffer vb;
    struct list_head list;
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
    u32 stride1;
    u32 pixelformat;
    u32 current_slice_idx;
    u32 error_count_start;
    bool pacer_enable;
    bool overlay_enable;
    enum v4l2_buf_type buf_type;
    /* Canonical v3.0: Per-channel register block & thin descriptor rings */
    u32 ch_reg_base;
    struct qpcie_dma_desc_16b *thin_ring_virt;
    dma_addr_t thin_ring_dma;
    u32 thin_ring_tail;
    u32 thin_ring_head;
    /* RING1 for UV plane in multi-plane mode */
    struct qpcie_dma_desc_16b *thin_ring1_virt;
    dma_addr_t thin_ring1_dma;
    u32 thin_ring1_tail;
    u32 thin_ring1_head;
    /* HDMI RX Telemetry Tracking & Polling Worker (Channel 0) */
    u32 last_rx_status;
    u32 last_rx_res;
    struct delayed_work hdmi_monitor_work;
    bool hdmi_monitor_running;
};

struct qpcie_alsa_channel {
    int channel_id;
    struct qpcie_dev *qdev;
    struct snd_card *card;
    struct snd_pcm *pcm_play;              /* Device 0 on Cards 1..3 */
    struct snd_pcm *pcm_cap;               /* Device 0 on Card 0, Device 1 on Cards 1..3 */
    struct snd_pcm_substream *play_substream;
    struct snd_pcm_substream *cap_substream;
    spinlock_t slock;
    u32 play_buffer_pos;
    u32 cap_buffer_pos;
    struct hrtimer play_timer;
    bool play_timer_active;
    snd_pcm_uframes_t play_hw_ptr;
    snd_pcm_uframes_t play_period_accum;
    u32 pattern_id;
    u32 volume;
};

struct qpcie_dev {
    struct pci_dev *pdev;
    void __iomem *bar0_mmio;
    void __iomem *bar1_mmio;

    int irq;
    bool v4l2_registered;
    bool alsa_registered;

    /* Saved MPS state when probe had to raise it for 256-byte MWr. */
    bool mps_modified;
    int ep_mps_saved;
    int rp_mps_saved;

    spinlock_t ring_lock;
    atomic_t streaming_count;

    /* Canonical v3.0 Register Map & Thin Descriptor Handles */
    struct qpcie_sgl_entry *thin_ring_virt;
    dma_addr_t thin_ring_dma;
    u32 thin_ring_tail;
    u32 thin_ring_head;

    /* Software in-flight counters for the shared descriptor ring.  The
     * ring-full check must use these (invariant: published >= completed),
     * never a hardware head pointer readback, because the FPGA fetch-ahead
     * can run the head pointer all the way up to the tail and falsely
     * trigger a "full" condition at the wrap boundary. */
    u32 ring_published;
    u32 ring_completed;
    u32 ring_rejects;

    /* Subsystem Devices */
    struct v4l2_device v4l2_dev;
    struct qpcie_v4l2_channel v4l2_ch[NUM_VIDEO_NODES];
    unsigned int v4l2_node_count;
    struct qpcie_alsa_channel alsa_ch[NUM_AUDIO_CHANNELS];
    unsigned int alsa_channel_count;

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

    /* I2C Adapter for Front-End I2C (IT68051, TLV320ADC3101) */
    struct i2c_adapter i2c_adap;
    struct mutex i2c_lock;
    bool i2c_registered;

    /* SPI Flash Lock */
    struct mutex flash_lock;
};

/* Submodule Function Declarations */
int qpcie_v4l2_init(struct qpcie_dev *qdev);
void qpcie_v4l2_remove(struct qpcie_dev *qdev);
void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev);
void qpcie_v4l2_node_done(struct qpcie_dev *qdev, int node_idx);
void qpcie_v4l2_check_source_change(struct qpcie_v4l2_channel *vch);
void qpcie_dma_soft_reset(struct qpcie_dev *qdev);
void qpcie_reprogram_rings(struct qpcie_dev *qdev);

int qpcie_alsa_init(struct qpcie_dev *qdev);
void qpcie_alsa_remove(struct qpcie_dev *qdev);
void qpcie_alsa_irq_handler(struct qpcie_dev *qdev, u32 status);

int qpcie_i2c_init(struct qpcie_dev *qdev);
void qpcie_i2c_remove(struct qpcie_dev *qdev);
int qpcie_it68051_get_status(struct qpcie_dev *qdev, u32 *width, u32 *height, u32 *fps, bool *locked);

int qpcie_flash_init(struct qpcie_dev *qdev);
void qpcie_flash_remove(struct qpcie_dev *qdev);

int qpcie_sysfs_init(struct qpcie_dev *qdev);
void qpcie_sysfs_remove(struct qpcie_dev *qdev);

int qpcie_upgrade_init(struct qpcie_dev *qdev);
void qpcie_upgrade_remove(struct qpcie_dev *qdev);

int qpcie_v4l2_export_dmabuf(struct qpcie_v4l2_channel *vch, struct v4l2_exportbuffer *exp);

#endif /* _QPCIE_DRIVER_H_ */
