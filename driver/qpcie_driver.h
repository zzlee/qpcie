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

#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-ctrls.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-dma-sg.h>

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
    u32 plane0_stride;   /* DW12: Plane 0 Stride Bytes */
    u32 plane1_stride;   /* DW13: Plane 1 Stride Bytes */
    u32 plane2_stride;   /* DW14: Plane 2 Stride Bytes */
    u32 line_count;      /* DW15: Total Lines per Frame */

    /* Legacy / Compatibility Descriptor Fields */
    u32 line_width;
    u32 src_stride;
    u32 dst_stride;
    u32 format;
    u32 plane_count;
    u32 control;
};

struct qpcie_dev;

struct qpcie_v4l2_buffer {
    struct vb2_v4l2_buffer vb;
    struct list_head list;
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
    struct list_head active_buffers;
    u32 sequence;
    u32 width;
    u32 height;
    u32 stride;
    u32 pixelformat;
    u32 current_slice_idx;
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
};

struct qpcie_dev {
    struct pci_dev *pdev;
    void __iomem *bar0_mmio;
    void __iomem *bar1_mmio;

    int irq;

    /* Descriptor Ring Buffer Handles */
    struct qpcie_dma_desc_2d *h2c_ring_virt;
    dma_addr_t h2c_ring_dma;
    u32 h2c_tail;

    struct qpcie_dma_desc_2d *c2h_ring_virt;
    dma_addr_t c2h_ring_dma;
    u32 c2h_tail;

    /* Subsystem Devices */
    struct v4l2_device v4l2_dev;
    struct qpcie_v4l2_channel v4l2_ch[NUM_VIDEO_CHANNELS];
    struct qpcie_alsa_channel alsa_ch[NUM_AUDIO_CHANNELS];

    struct snd_card *card;
    struct snd_pcm *pcm;
};

/* Submodule Function Declarations */
int qpcie_v4l2_init(struct qpcie_dev *qdev);
void qpcie_v4l2_remove(struct qpcie_dev *qdev);
void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev);

int qpcie_alsa_init(struct qpcie_dev *qdev);
void qpcie_alsa_remove(struct qpcie_dev *qdev);
void qpcie_alsa_irq_handler(struct qpcie_dev *qdev);

int qpcie_sysfs_init(struct qpcie_dev *qdev);
void qpcie_sysfs_remove(struct qpcie_dev *qdev);

int qpcie_v4l2_export_dmabuf(struct qpcie_v4l2_channel *vch, struct v4l2_exportbuffer *exp);

#endif /* _QPCIE_DRIVER_H_ */
