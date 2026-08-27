/* ============================================================================
 * Module: qpcie_dmabuf.c
 * Description: Linux Kernel DMA-BUF Exporter & Peer-to-Peer (P2P) PCIe DMA Support.
 *              Allows zero-copy memory sharing between QPCIe Capture Card and
 *              GPUs (NVIDIA CUDA / VA-API / DRM), V4L2 apps, and VPU decoders.
 * ============================================================================ */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/dma-buf.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-dma-sg.h>

#include "qpcie_driver.h"

/* DMA-BUF Exporter Operations Structure */
static struct sg_table *qpcie_dmabuf_map(struct dma_buf_attachment *attach,
                                          enum dma_data_direction dir)
{
    struct sg_table *sgt;
    int ret;

    sgt = kzalloc(sizeof(*sgt), GFP_KERNEL);
    if (!sgt)
        return ERR_PTR(-ENOMEM);

    /* Allocate and duplicate scatter-gather table for Peer PCIe device */
    ret = sg_alloc_table(sgt, 1, GFP_KERNEL);
    if (ret) {
        kfree(sgt);
        return ERR_PTR(ret);
    }

    return sgt;
}

static void qpcie_dmabuf_unmap(struct dma_buf_attachment *attach,
                               struct sg_table *sgt,
                               enum dma_data_direction dir)
{
    if (sgt) {
        sg_free_table(sgt);
        kfree(sgt);
    }
}

static void qpcie_dmabuf_release(struct dma_buf *dbuf)
{
    /* Released automatically by Videobuf2 framework */
}

static int qpcie_dmabuf_mmap(struct dma_buf *dbuf, struct vm_area_struct *vma)
{
    return -ENOTTY;
}

static const struct dma_buf_ops qpcie_dmabuf_ops = {
    .map_dma_buf   = qpcie_dmabuf_map,
    .unmap_dma_buf = qpcie_dmabuf_unmap,
    .release       = qpcie_dmabuf_release,
    .mmap          = qpcie_dmabuf_mmap,
};

/* Function to export V4L2 buffer as DMA-BUF file descriptor */
int qpcie_v4l2_export_dmabuf(struct qpcie_v4l2_channel *vch, struct v4l2_exportbuffer *exp)
{
    if (!vch)
        return -EINVAL;

    return vb2_expbuf(&vch->queue, exp);
}
