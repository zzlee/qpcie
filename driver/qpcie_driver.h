/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Header: qpcie_driver.h
 * Description: Linux Kernel Driver Header for Custom PCIe Multi-Channel 2D Video (V4L2)
 *              and AES3 Audio (ALSA) DMA Controller.
 */

#ifndef _QPCIE_DRIVER_H_
#define _QPCIE_DRIVER_H_

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/interrupt.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>

#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-ctrls.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-dma-sg.h>

#include <sound/core.h>
#include <sound/control.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>

#define QPCIE_VENDOR_ID   0x12AB /* Custom PCI Vendor ID */
#define QPCIE_DEVICE_ID   0xE380 /* Custom PCIe DMA Device ID */

#define NUM_VIDEO_CHANNELS 4
#define NUM_AUDIO_CHANNELS 4
#define RING_BUFFER_SIZE   16

/* BAR0 DMA Register Offsets */
#define REG_DMA_CTRL         0x00
#define REG_DMA_STATUS       0x04
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
#define REG_SLICE_HEIGHT     0x78    /* Sub-Frame Slice Height in Lines (0=Full Frame IRQ, >0=Slice IRQ) */

/* 64-Byte 2D Multi-Planar Extended Descriptor Structure */
struct qpcie_dma_desc_2d {
    u64 plane0_src_addr; /* DW0-DW1 : Plane 0 Src Addr (Y / Mono / Audio Buffer) */
    u64 plane0_dst_addr; /* DW2-DW3 : Plane 0 Dst Addr */
    u64 plane1_src_addr; /* DW4-DW5 : Plane 1 Src Addr (U / UV) */
    u64 plane1_dst_addr; /* DW6-DW7 : Plane 1 Dst Addr */
    u64 plane2_src_addr; /* DW8-DW9 : Plane 2 Src Addr (V) */
    u64 plane2_dst_addr; /* DW10-DW11: Plane 2 Dst Addr */

    u16 line_width;       /* DW12: Line Width Bytes (Plane 0) */
    u16 line_count;       /* DW12: Height Lines */
    u16 src_stride;       /* DW13: Src Line Stride (Bytes incl Padding) */
    u16 dst_stride;       /* DW13: Dst Line Stride (Bytes) */

    u16 plane12_line_width;/* DW14: Plane 1/2 Line Width */
    u16 plane12_line_count;/* DW14: Plane 1/2 Height */

    u8  format;           /* DW15: 0x0: 1D, 0x1: 2D Mono, 0x2: NV12M, 0x3: YUV420M */
    u8  plane_count;      /* DW15: 1, 2, or 3 Planes */
    u16 control;          /* DW15: Bit 0: Valid, Bit 1: Is_C2H, Bit 3: IRQ_EN */
} __packed __aligned(64);

/* V4L2 Buffer Wrapper Structure */
struct qpcie_v4l2_buffer {
    struct vb2_v4l2_buffer vb;
    struct list_head       list;
};

/* Video Channel Data Structure */
struct qpcie_v4l2_channel {
    struct qpcie_dev       *qdev;
    int                     channel_id;
    struct video_device     vdev;
    struct v4l2_device      v4l2_dev;
    struct v4l2_ctrl_handler ctrl_handler;
    struct vb2_queue        queue;
    struct mutex            lock;
    spinlock_t              slock;
    struct list_head        active_buffers;
    u32                     width;
    u32                     height;
    u32                     stride;
    u32                     pixelformat;
    u32                     sequence;
};

/* ALSA Audio Channel Data Structure */
struct qpcie_alsa_channel {
    struct qpcie_dev           *qdev;
    int                         channel_id;
    struct snd_card            *card;
    struct snd_pcm             *pcm;
    struct snd_pcm_substream   *substream;
    spinlock_t                  slock;
    u32                         buffer_pos;
    u32                         period_pos;
};

/* Top Device Structure */
struct qpcie_dev {
    struct pci_dev            *pdev;
    void __iomem              *bar0_mmio; /* BAR0: DMA Control */
    void __iomem              *bar1_mmio; /* BAR1: User IP Cores Interconnect */
    int                        irq;

    /* Coherent DMA Ring Buffers */
    struct qpcie_dma_desc_2d  *h2c_ring_virt;
    dma_addr_t                 h2c_ring_dma;
    u16                        h2c_tail;

    struct qpcie_dma_desc_2d  *c2h_ring_virt;
    dma_addr_t                 c2h_ring_dma;
    u16                        c2h_tail;

    /* Subsystem Instances */
    struct qpcie_v4l2_channel  v4l2_ch[NUM_VIDEO_CHANNELS];
    struct qpcie_alsa_channel  alsa_ch[NUM_AUDIO_CHANNELS];
};

/* Subsystem Init & Sub-driver Interfaces */
int  qpcie_v4l2_init(struct qpcie_dev *qdev);
void qpcie_v4l2_remove(struct qpcie_dev *qdev);
void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev);
int  qpcie_v4l2_export_dmabuf(struct qpcie_v4l2_channel *vch, struct v4l2_exportbuffer *exp);

int  qpcie_alsa_init(struct qpcie_dev *qdev);
void qpcie_alsa_remove(struct qpcie_dev *qdev);
void qpcie_alsa_irq_handler(struct qpcie_dev *qdev);

int qpcie_sysfs_init(struct qpcie_dev *qdev);
void qpcie_sysfs_remove(struct qpcie_dev *qdev);

#endif /* _QPCIE_DRIVER_H_ */
