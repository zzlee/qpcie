// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Driver: qpcie_v4l2.c
 * Description: Video4Linux2 Multi-Planar Capture Driver for Custom PCIe 2D DMA.
 *              Supports Memory-Mapped (MMAP), User Pointer (USERPTR),
 *              DMA-BUF Import (DMABUF), and Export Buffer (EXPBUF).
 */

#include "qpcie_driver.h"
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <media/v4l2-event.h>

/*
 * Validation-only knob: force every V4L2 H2C/C2H NV12 plane through the
 * 4KiB host SGL fetch path even when the DMA API maps each plane to a single
 * contiguous IOVA segment (nents == 1).  Default 0 keeps the direct-DMA path.
 */
static bool force_sgl_fetch;
module_param(force_sgl_fetch, bool, 0644);
MODULE_PARM_DESC(force_sgl_fetch,
                 "Force 4KiB host SGL fetch tables for V4L2 DMA validation");

static const struct v4l2_file_operations qpcie_v4l2_fops = {
    .owner          = THIS_MODULE,
    .open           = v4l2_fh_open,
    .release        = vb2_fop_release,
    .read           = vb2_fop_read,
    .poll           = vb2_fop_poll,
    .mmap           = vb2_fop_mmap,
    .unlocked_ioctl = video_ioctl2,
};

static int qpcie_vidioc_querycap(struct file *file, void *priv, struct v4l2_capability *cap)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    strscpy(cap->driver, "qpcie-v4l2", sizeof(cap->driver));
    if (vch && vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE)
        strscpy(cap->card, "QPCIe NV12M Video Output", sizeof(cap->card));
    else
        strscpy(cap->card, "QPCIe NV12M Video Capture", sizeof(cap->card));
    strscpy(cap->bus_info, "PCIe:custom-dma", sizeof(cap->bus_info));
    return 0;
}

static int qpcie_vidioc_enum_fmt_vid_cap_mplane(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
    if (f->index != 0)
        return -EINVAL;
    f->pixelformat = V4L2_PIX_FMT_NV12M;
    return 0;
}

struct qpcie_video_mode {
    u32 width;
    u32 height;
};

static const struct qpcie_video_mode qpcie_video_modes[] = {
    { 1920, 1080 },
    { 3840, 2160 },
};

static const struct qpcie_video_mode *qpcie_find_video_mode(u32 width,
                                                              u32 height)
{
    const struct qpcie_video_mode *best = &qpcie_video_modes[0];
    u32 best_distance = U32_MAX;
    unsigned int i;

    for (i = 0; i < ARRAY_SIZE(qpcie_video_modes); i++) {
        const struct qpcie_video_mode *mode = &qpcie_video_modes[i];
        u32 width_delta = width > mode->width ? width - mode->width :
                                                    mode->width - width;
        u32 height_delta = height > mode->height ? height - mode->height :
                                                       mode->height - height;
        u32 distance = width_delta + height_delta;

        if (distance < best_distance) {
            best = mode;
            best_distance = distance;
        }
    }
    return best;
}

static void qpcie_fill_pix_format(struct v4l2_pix_format_mplane *pix,
                                  const struct qpcie_video_mode *mode)
{
    memset(pix, 0, sizeof(*pix));
    pix->width = mode->width;
    pix->height = mode->height;
    pix->pixelformat = V4L2_PIX_FMT_NV12M;
    pix->field = V4L2_FIELD_NONE;
    pix->colorspace = V4L2_COLORSPACE_REC709;
    pix->num_planes = 2;
    pix->plane_fmt[0].bytesperline = mode->width;
    pix->plane_fmt[0].sizeimage = mode->width * mode->height;
    pix->plane_fmt[1].bytesperline = mode->width;
    pix->plane_fmt[1].sizeimage = mode->width * (mode->height / 2);
}

static u32 qpcie_tpg_pattern_id(int menu_value)
{
    if (menu_value == 0)
        return 9;  /* Pass-through is unavailable without a TPG input stream. */
    if (menu_value == 3)
        return 9;  /* Color Bars */
    if (menu_value == 4)
        return 10; /* Zone Plate */
    return menu_value;
}

static int qpcie_program_tpg(struct qpcie_v4l2_channel *vch, u32 pattern_id,
                             bool reset_pipeline)
{
    struct qpcie_dev *qdev = vch->qdev;
    void __iomem *tpg;
    u32 rb_width, rb_height, rb_pattern, rb_format;

    if (!qdev || !qdev->bar0_mmio || !qdev->bar1_mmio)
        return -ENODEV;

    tpg = qdev->bar1_mmio + (vch->channel_id * 0x100);
    if (reset_pipeline) {
        iowrite32(1, qdev->bar0_mmio + REG_VIDEO_CTRL);
        if (ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL) != 1)
            return -EIO;
        usleep_range(1000, 2000);
        iowrite32(0, qdev->bar0_mmio + REG_VIDEO_CTRL);
        if (ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL) != 0)
            return -EIO;
        usleep_range(1000, 2000);
    }

    iowrite32(vch->height, tpg + 0x10);
    iowrite32(vch->width, tpg + 0x18);
    iowrite32(pattern_id, tpg + 0x20);
    iowrite32(1, tpg + 0x40);    /* XVIDC_CSF_YCRCB_444 */
    /* Hold TPG idle until STREAMON */
    iowrite32(0x00, tpg + 0x00);

    rb_width = ioread32(tpg + 0x18);
    rb_height = ioread32(tpg + 0x10);
    rb_pattern = ioread32(tpg + 0x20);
    rb_format = ioread32(tpg + 0x40);

    dev_info(&qdev->pdev->dev,
             "TPG%u configured: %ux%u YUV444 pattern=%u format=%u\n",
             vch->channel_id, rb_width, rb_height, rb_pattern, rb_format);
    if (rb_width != vch->width || rb_height != vch->height ||
        rb_pattern != pattern_id || rb_format != 1) {
        dev_err(&qdev->pdev->dev,
                "TPG%u BAR1 configuration readback mismatch\n",
                vch->channel_id);
        return -EIO;
    }
    return 0;
}

/* ------------------------------------------------------------------
 * Linux Driver Pacer: Re-arms AP_START at high-precision 60.000 Hz
 * using Real-Time FIFO scheduling and absolute high-resolution timers.
 * ------------------------------------------------------------------ */
static int qpcie_tpg_pace_thread(void *data)
{
    struct qpcie_dev *qdev = data;
    u64 period_ns = div_u64(NSEC_PER_SEC, qdev->tpg_fps ? qdev->tpg_fps : 60);
    ktime_t next_ktime = ktime_get();

    /* Elevate to real-time FIFO priority to prevent preemption under 4K load */
    sched_set_fifo(current);
    set_freezable();

    while (!kthread_should_stop()) {
        unsigned long flags;

        if (READ_ONCE(qdev->tpg_pace_run) && qdev->bar1_mmio) {
            spin_lock_irqsave(&qdev->tpg_lock, flags);
            iowrite32(0x01, qdev->bar1_mmio + 0x0000 + 0x00); /* AP_START */
            spin_unlock_irqrestore(&qdev->tpg_lock, flags);
        }

        next_ktime = ktime_add_ns(next_ktime, period_ns);
        set_current_state(TASK_INTERRUPTIBLE);
        schedule_hrtimeout(&next_ktime, HRTIMER_MODE_ABS);
        __set_current_state(TASK_RUNNING);

        if (kthread_should_stop())
            break;

        /* If system fell behind by more than 1 period, advance to current time */
        if (ktime_after(ktime_get(), next_ktime))
            next_ktime = ktime_get();
    }
    return 0;
}

static int qpcie_tpg_pace_start(struct qpcie_dev *qdev)
{
    qdev->tpg_pace_run = true;
    qdev->tpg_pace_task = kthread_run(qpcie_tpg_pace_thread, qdev,
                                      "qpcie-tpg-pace");
    if (IS_ERR(qdev->tpg_pace_task)) {
        int ret = PTR_ERR(qdev->tpg_pace_task);

        qdev->tpg_pace_task = NULL;
        qdev->tpg_pace_run = false;
        return ret;
    }
    return 0;
}

static void qpcie_tpg_pace_stop(struct qpcie_dev *qdev)
{
    if (qdev->tpg_pace_task) {
        qdev->tpg_pace_run = false;
        kthread_stop(qdev->tpg_pace_task);
        qdev->tpg_pace_task = NULL;
    }
}

static int qpcie_vidioc_g_fmt_vid_cap_mplane(struct file *file, void *priv,
                                              struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    struct qpcie_video_mode mode = { vch->width, vch->height };

    qpcie_fill_pix_format(&f->fmt.pix_mp, &mode);
    return 0;
}

static int qpcie_vidioc_try_fmt_vid_cap_mplane(struct file *file, void *priv,
                                                struct v4l2_format *f)
{
    const struct qpcie_video_mode *mode;

    mode = qpcie_find_video_mode(f->fmt.pix_mp.width,
                                 f->fmt.pix_mp.height);
    qpcie_fill_pix_format(&f->fmt.pix_mp, mode);
    return 0;
}

static int qpcie_vidioc_s_fmt_vid_cap_mplane(struct file *file, void *priv,
                                              struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    const struct qpcie_video_mode *mode;
    struct v4l2_ctrl *pattern_ctrl;
    u32 pattern_id;
    u32 old_width, old_height, old_stride, old_pixelformat;
    int ret;

    mode = qpcie_find_video_mode(f->fmt.pix_mp.width,
                                 f->fmt.pix_mp.height);
    if (vb2_is_busy(&vch->queue))
        return -EBUSY;

    old_width = vch->width;
    old_height = vch->height;
    old_stride = vch->stride;
    old_pixelformat = vch->pixelformat;
    vch->width = mode->width;
    vch->height = mode->height;
    vch->pixelformat = V4L2_PIX_FMT_NV12M;
    vch->stride = mode->width;

    pattern_ctrl = v4l2_ctrl_find(&vch->ctrl_handler,
                                  V4L2_CID_TEST_PATTERN);
    if (pattern_ctrl) {
        pattern_id = qpcie_tpg_pattern_id(pattern_ctrl->val);
        ret = qpcie_program_tpg(vch, pattern_id, true);
        if (ret) {
            vch->width = old_width;
            vch->height = old_height;
            vch->stride = old_stride;
            vch->pixelformat = old_pixelformat;
            return ret;
        }
    }

    qpcie_fill_pix_format(&f->fmt.pix_mp, mode);
    return 0;
}

static int qpcie_vidioc_g_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    if (a->type != vch->buf_type)
        return -EINVAL;

    if (a->type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) {
        a->parm.output.capability = V4L2_CAP_TIMEPERFRAME;
        a->parm.output.timeperframe.numerator = 1;
        a->parm.output.timeperframe.denominator = 60;
    } else {
        a->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
        a->parm.capture.timeperframe.numerator = 1;
        a->parm.capture.timeperframe.denominator = 60;
    }

    return 0;
}

static int qpcie_vidioc_s_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    if (a->type != vch->buf_type)
        return -EINVAL;

    if (a->type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) {
        a->parm.output.capability = V4L2_CAP_TIMEPERFRAME;
        a->parm.output.timeperframe.numerator = 1;
        a->parm.output.timeperframe.denominator = 60;
    } else {
        a->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
        a->parm.capture.timeperframe.numerator = 1;
        a->parm.capture.timeperframe.denominator = 60;
    }

    dev_info(&vch->qdev->pdev->dev,
             "V4L2 channel %u (%s) configured for %ux%u@60 NV12M\n",
             vch->channel_id,
             (vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) ? "Output" : "Capture",
             vch->width, vch->height);
    return 0;
}

static int qpcie_vidioc_enum_framesizes(struct file *file, void *priv, struct v4l2_frmsizeenum *fsize)
{
    if (fsize->pixel_format != V4L2_PIX_FMT_NV12M)
        return -EINVAL;

    if (fsize->index >= ARRAY_SIZE(qpcie_video_modes))
        return -EINVAL;

    fsize->type = V4L2_FRMSIZE_TYPE_DISCRETE;
    fsize->discrete.width = qpcie_video_modes[fsize->index].width;
    fsize->discrete.height = qpcie_video_modes[fsize->index].height;
    return 0;
}

static const struct v4l2_fract supported_frameintervals[] = {
    { 1, 60 },
};

static int qpcie_vidioc_enum_frameintervals(struct file *file, void *priv, struct v4l2_frmivalenum *fival)
{
    if (fival->pixel_format != V4L2_PIX_FMT_NV12M)
        return -EINVAL;

    if (fival->index >= ARRAY_SIZE(supported_frameintervals))
        return -EINVAL;
    if ((fival->width != 1920 || fival->height != 1080) &&
        (fival->width != 3840 || fival->height != 2160))
        return -EINVAL;

    fival->type = V4L2_FRMIVAL_TYPE_DISCRETE;
    fival->discrete = supported_frameintervals[fival->index];
    return 0;
}

static int qpcie_vidioc_subscribe_event(struct v4l2_fh *fh,
                                        const struct v4l2_event_subscription *sub)
{
    switch (sub->type) {
    case V4L2_EVENT_FRAME_SYNC:
        return v4l2_event_subscribe(fh, sub, 16, NULL);
    case V4L2_EVENT_CTRL:
        return v4l2_ctrl_subscribe_event(fh, sub);
    default:
        return -EINVAL;
    }
}

static const struct v4l2_ioctl_ops qpcie_v4l2_ioctl_ops = {
    .vidioc_querycap                = qpcie_vidioc_querycap,
    .vidioc_enum_fmt_vid_cap        = qpcie_vidioc_enum_fmt_vid_cap_mplane,
    .vidioc_g_fmt_vid_cap_mplane    = qpcie_vidioc_g_fmt_vid_cap_mplane,
    .vidioc_try_fmt_vid_cap_mplane  = qpcie_vidioc_try_fmt_vid_cap_mplane,
    .vidioc_s_fmt_vid_cap_mplane    = qpcie_vidioc_s_fmt_vid_cap_mplane,

    .vidioc_enum_fmt_vid_out        = qpcie_vidioc_enum_fmt_vid_cap_mplane,
    .vidioc_g_fmt_vid_out_mplane    = qpcie_vidioc_g_fmt_vid_cap_mplane,
    .vidioc_try_fmt_vid_out_mplane  = qpcie_vidioc_try_fmt_vid_cap_mplane,
    .vidioc_s_fmt_vid_out_mplane    = qpcie_vidioc_s_fmt_vid_cap_mplane,

    .vidioc_enum_framesizes         = qpcie_vidioc_enum_framesizes,
    .vidioc_enum_frameintervals     = qpcie_vidioc_enum_frameintervals,

    .vidioc_g_parm                  = qpcie_vidioc_g_parm,
    .vidioc_s_parm                  = qpcie_vidioc_s_parm,

    /* Videobuf2 Buffer Management IOCTLs (MMAP, USERPTR, DMABUF) */
    .vidioc_reqbufs                 = vb2_ioctl_reqbufs,
    .vidioc_querybuf                = vb2_ioctl_querybuf,
    .vidioc_qbuf                    = vb2_ioctl_qbuf,
    .vidioc_dqbuf                   = vb2_ioctl_dqbuf,
    .vidioc_prepare_buf             = vb2_ioctl_prepare_buf,
    .vidioc_create_bufs             = vb2_ioctl_create_bufs,

    /* DMA-BUF Export Buffer IOCTL */
    .vidioc_expbuf                  = vb2_ioctl_expbuf,

    /* Sub-Frame Low-Latency Slice DMA V4L2 Event Subscription */
    .vidioc_subscribe_event         = qpcie_vidioc_subscribe_event,
    .vidioc_unsubscribe_event       = v4l2_event_unsubscribe,

    .vidioc_streamon                = vb2_ioctl_streamon,
    .vidioc_streamoff               = vb2_ioctl_streamoff,
};

/* Videobuf2 Queue Operations */
static int qpcie_queue_setup(struct vb2_queue *vq,
                            unsigned int *nbuffers, unsigned int *nplanes,
                            unsigned int sizes[], struct device *alloc_devs[])
{
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vq);
    unsigned int y_size = vch->stride * vch->height;
    unsigned int uv_size = vch->stride * (vch->height / 2);

    if (*nplanes) {
        if (*nplanes != 2 || sizes[0] < y_size || sizes[1] < uv_size)
            return -EINVAL;
        return 0;
    }

    *nplanes = 2;
    sizes[0] = y_size;
    sizes[1] = uv_size;
    *nbuffers = clamp_t(unsigned int, *nbuffers, 2, RING_BUFFER_SIZE / 2);
    return 0;
}

static int qpcie_buf_prepare(struct vb2_buffer *vb)
{
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    int i;

    /* Validate plane size for MMAP, USERPTR, and DMABUF memory modes */
    for (i = 0; i < vb->num_planes; i++) {
        unsigned long size = (i == 0) ? (vch->stride * vch->height) :
                             (vch->pixelformat == V4L2_PIX_FMT_YUV420M) ? ((vch->stride / 2) * (vch->height / 2)) :
                             (vch->stride * (vch->height / 2));

        if (vb2_plane_size(vb, i) < size) {
            v4l2_err(&vch->qdev->v4l2_dev,
                     "Plane %d size %lu < required %lu\n",
                     i, vb2_plane_size(vb, i), size);
            return -EINVAL;
        }
        vb2_set_plane_payload(vb, i, size);
    }
    return 0;
}

static int qpcie_buf_init(struct vb2_buffer *vb)
{
    struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
    struct qpcie_v4l2_buffer *buf = container_of(vbuf, struct qpcie_v4l2_buffer, vb);
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    struct qpcie_dev *qdev = vch->qdev;

    buf->sgl_logged = false;

    buf->y_slots_virt = dma_alloc_coherent(&qdev->pdev->dev,
                                           QPCIE_MAX_PAGE_SLOTS_Y * 4096,
                                           &buf->y_slots_dma, GFP_KERNEL);
    if (!buf->y_slots_virt)
        return -ENOMEM;

    buf->uv_slots_virt = dma_alloc_coherent(&qdev->pdev->dev,
                                            QPCIE_MAX_PAGE_SLOTS_UV * 4096,
                                            &buf->uv_slots_dma, GFP_KERNEL);
    if (!buf->uv_slots_virt) {
        dma_free_coherent(&qdev->pdev->dev, QPCIE_MAX_PAGE_SLOTS_Y * 4096,
                          buf->y_slots_virt, buf->y_slots_dma);
        buf->y_slots_virt = NULL;
        return -ENOMEM;
    }
    dev_dbg(&qdev->pdev->dev,
             "SGL alloc ch%u %s: y=%pad/%uK uv=%pad/%uK\n",
             vch->channel_id,
             vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE ?
             "H2C" : "C2H",
             &buf->y_slots_dma, QPCIE_MAX_PAGE_SLOTS_Y * 4,
             &buf->uv_slots_dma, QPCIE_MAX_PAGE_SLOTS_UV * 4);
    return 0;
}

static void qpcie_buf_cleanup(struct vb2_buffer *vb)
{
    struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
    struct qpcie_v4l2_buffer *buf = container_of(vbuf, struct qpcie_v4l2_buffer, vb);
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    struct qpcie_dev *qdev = vch->qdev;

    if (buf->y_slots_virt) {
        dma_free_coherent(&qdev->pdev->dev, QPCIE_MAX_PAGE_SLOTS_Y * 4096,
                          buf->y_slots_virt, buf->y_slots_dma);
        buf->y_slots_virt = NULL;
    }
    if (buf->uv_slots_virt) {
        dma_free_coherent(&qdev->pdev->dev, QPCIE_MAX_PAGE_SLOTS_UV * 4096,
                          buf->uv_slots_virt, buf->uv_slots_dma);
        buf->uv_slots_virt = NULL;
    }
}

/*
 * Build a 4KiB-slot host SGL table for one NV12 plane.
 *
 * Every SGL entry is capped at the next 4KiB boundary of its IOVA so the
 * hardware page-table walker never crosses a page boundary inside a single
 * entry.  A slot holds at most 255 data entries; entry index 255 is reserved
 * for the chain pointer to the next slot.  The last data entry of the plane
 * carries SGL_FLAG_LAST_SEG.
 *
 * Returns 0 on success (with the data-entry and chain counts filled in) or a
 * negative error when the plane cannot fit within @max_slots; on error the
 * table contents are undefined and must not be published.
 */
static int qpcie_build_variable_sgl(struct device *dev, struct scatterlist *sgl,
                                    unsigned int nents,
                                    struct qpcie_sgl_entry *slots_virt,
                                    dma_addr_t slots_dma, unsigned int max_slots,
                                    unsigned int *data_entries_out,
                                    unsigned int *chain_count_out)
{
    struct scatterlist *sg;
    struct qpcie_sgl_entry *slot_ptr = slots_virt;
    unsigned int i;
    unsigned int cur_slot = 0;
    unsigned int cur_entry = 0;
    unsigned int data_entries = 0;
    unsigned int chain_count = 0;
    u64 remaining;

    *data_entries_out = 0;
    *chain_count_out = 0;

    memset(slots_virt, 0, max_slots * 4096);

    for_each_sg(sgl, sg, nents, i) {
        u64 chunk_addr = sg_dma_address(sg);
        u64 chunk_len = sg_dma_len(sg);

        remaining = chunk_len;
        while (remaining > 0) {
            u64 bytes_to_4k;
            u32 entry_len;

            if (cur_entry == 255) {
                /* Slot full: link to the next slot via entry index 255. */
                if (cur_slot + 1 >= max_slots) {
                    dev_err(dev,
                            "SGL table overflow: plane needs more than %u entries (%u data, %u chains)\n",
                            max_slots * 255, data_entries, chain_count);
                    return -ENOSPC;
                }
                slot_ptr[255].phys_addr = (u64)(slots_dma + (cur_slot + 1) * 4096);
                slot_ptr[255].len_bytes = 0;
                slot_ptr[255].flags     = SGL_FLAG_CHAIN_PTR;
                chain_count++;
                cur_slot++;
                slot_ptr = (struct qpcie_sgl_entry *)((u8 *)slots_virt + cur_slot * 4096);
                cur_entry = 0;
            }

            /* Never let a single entry cross a 4KiB IOVA boundary. */
            bytes_to_4k = 4096 - (chunk_addr & 0xFFF);
            entry_len = (remaining < bytes_to_4k) ? (u32)remaining : (u32)bytes_to_4k;

            slot_ptr[cur_entry].phys_addr = chunk_addr;
            slot_ptr[cur_entry].len_bytes = entry_len;
            slot_ptr[cur_entry].flags     = 0;
            cur_entry++;
            data_entries++;
            chunk_addr += entry_len;
            remaining  -= entry_len;
        }
    }

    if (data_entries == 0) {
        dev_err(dev, "SGL table build: empty plane (nents=%u)\n", nents);
        return -EINVAL;
    }

    /* Mark the final data entry of the plane as the last segment. */
    slot_ptr[cur_entry - 1].flags |= SGL_FLAG_LAST_SEG;

    *data_entries_out = data_entries;
    *chain_count_out = chain_count;
    return 0;
}

static int qpcie_publish_buffer(struct qpcie_v4l2_channel *vch,
                                struct qpcie_v4l2_buffer *buf)
{
    struct vb2_buffer *vb = &buf->vb.vb2_buf;
    struct qpcie_dev *qdev = vch->qdev;
    struct qpcie_dma_desc_2d *desc;
    struct sg_table *sgt0, *sgt1;
    dma_addr_t plane0_dma, plane1_dma;
    const char *dir = vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE ?
                      "H2C" : "C2H";
    unsigned int y_entries = 0, y_chains = 0;
    unsigned int uv_entries = 0, uv_chains = 0;
    bool host_sgl;
    u32 control;
    u32 tail;
    int ret;

    tail = qdev->h2c_tail;
    desc = &qdev->h2c_ring_virt[tail];
    memset(desc, 0, sizeof(*desc));

    desc->line_width      = vch->width;
    desc->line_count      = vch->height;
    desc->src_stride      = vch->width;
    desc->dst_stride      = vch->stride;
    desc->plane12_width   = vch->width;
    desc->plane12_count   = vch->height / 2;
    desc->format          = 0x2; /* NV12M */
    desc->plane_count     = 2;

    sgt0 = vb2_dma_sg_plane_desc(vb, 0);
    sgt1 = vb2_dma_sg_plane_desc(vb, 1);
    if (WARN_ON(!sgt0 || !sgt1))
        return -EINVAL;

    plane0_dma = sg_dma_address(sgt0->sgl);
    plane1_dma = sg_dma_address(sgt1->sgl);

    host_sgl = force_sgl_fetch || sgt0->nents > 1 || sgt1->nents > 1;
    if (host_sgl) {
        ret = qpcie_build_variable_sgl(&qdev->pdev->dev, sgt0->sgl, sgt0->nents,
                                       (struct qpcie_sgl_entry *)buf->y_slots_virt,
                                       buf->y_slots_dma, QPCIE_MAX_PAGE_SLOTS_Y,
                                       &y_entries, &y_chains);
        if (ret) {
            dev_err(&qdev->pdev->dev,
                    "SGL ch%u %s buf%u: Y plane table build failed (%d); buffer rejected\n",
                    vch->channel_id, dir, vb->index, ret);
            return ret;
        }
        ret = qpcie_build_variable_sgl(&qdev->pdev->dev, sgt1->sgl, sgt1->nents,
                                       (struct qpcie_sgl_entry *)buf->uv_slots_virt,
                                       buf->uv_slots_dma, QPCIE_MAX_PAGE_SLOTS_UV,
                                       &uv_entries, &uv_chains);
        if (ret) {
            dev_err(&qdev->pdev->dev,
                    "SGL ch%u %s buf%u: UV plane table build failed (%d); buffer rejected\n",
                    vch->channel_id, dir, vb->index, ret);
            return ret;
        }

        if (vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) {
            control = 0x09 | (vch->channel_id << DESC_CTRL_CHANNEL_SHIFT) |
                      DESC_CTRL_SG_FETCH_MODE;
            desc->plane0_src_addr = buf->y_slots_dma;
            desc->plane1_src_addr = buf->uv_slots_dma;
        } else {
            control = 0x0B | (vch->channel_id << DESC_CTRL_CHANNEL_SHIFT) |
                      DESC_CTRL_SG_FETCH_MODE;
            desc->plane0_dst_addr = buf->y_slots_dma;
            desc->plane1_dst_addr = buf->uv_slots_dma;
        }
        desc->control = control;

        if (!buf->sgl_logged) {
            struct qpcie_sgl_entry *y_entries_p = buf->y_slots_virt;
            struct qpcie_sgl_entry *uv_entries_p = buf->uv_slots_virt;
            unsigned int y_log_nents = min_t(unsigned int, y_entries, 8);
            unsigned int uv_log_nents = min_t(unsigned int, uv_entries, 8);
            unsigned int i;

            dev_info(&qdev->pdev->dev,
                     "SGL ch%u %s buf%u: host SGL fetch enabled (force=%d) Y nents=%u/%u entries=%u chains=%u slot=%pad | UV nents=%u/%u entries=%u chains=%u slot=%pad ctrl=0x%02x\n",
                     vch->channel_id, dir, vb->index, force_sgl_fetch,
                     sgt0->nents, sgt0->orig_nents, y_entries, y_chains,
                     &buf->y_slots_dma,
                     sgt1->nents, sgt1->orig_nents, uv_entries, uv_chains,
                     &buf->uv_slots_dma, control);
            for (i = 0; i < y_log_nents; i++)
                dev_info(&qdev->pdev->dev,
                         "  Y[%u] addr=0x%016llx len=%u flags=0x%x\n",
                         i, y_entries_p[i].phys_addr,
                         y_entries_p[i].len_bytes, y_entries_p[i].flags);
            for (i = 0; i < uv_log_nents; i++)
                dev_info(&qdev->pdev->dev,
                         " UV[%u] addr=0x%016llx len=%u flags=0x%x\n",
                         i, uv_entries_p[i].phys_addr,
                         uv_entries_p[i].len_bytes, uv_entries_p[i].flags);
            buf->sgl_logged = true;
        }
    } else {
        if (vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) {
            control = 0x09 | (vch->channel_id << DESC_CTRL_CHANNEL_SHIFT);
            desc->plane0_src_addr = plane0_dma;
            desc->plane1_src_addr = plane1_dma;
        } else {
            control = 0x0B | (vch->channel_id << DESC_CTRL_CHANNEL_SHIFT);
            desc->plane0_dst_addr = plane0_dma;
            desc->plane1_dst_addr = plane1_dma;
        }
        desc->control = control;

        if (!buf->sgl_logged) {
            dev_info(&qdev->pdev->dev,
                     "DMA ch%u %s buf%u: direct DMA (Y nents=%u IOVA=%pad, UV nents=%u IOVA=%pad); host SGL fetch disabled\n",
                     vch->channel_id, dir, vb->index,
                     sgt0->nents, &plane0_dma, sgt1->nents, &plane1_dma);
            buf->sgl_logged = true;
        }
    }

    /* The completion IRQ can arrive immediately after the doorbell, so make
     * the matching VB2 buffer visible before publishing the descriptor. */
    spin_lock(&vch->slock);
    list_add_tail(&buf->list, &vch->active_buffers);
    spin_unlock(&vch->slock);

    /* Descriptor data must be globally visible before publishing the shared
     * hardware-ring tail doorbell. */
    dma_wmb();
    qdev->h2c_tail = (tail + 1) % RING_BUFFER_SIZE;
    qdev->c2h_tail = qdev->h2c_tail;
    iowrite32((qdev->h2c_tail << 16) | RING_BUFFER_SIZE,
              qdev->bar0_mmio + REG_H2C_RING_CFG);
    ioread32(qdev->bar0_mmio + REG_H2C_RING_CFG);

    return 0;
}

static void qpcie_buf_queue(struct vb2_buffer *vb)
{
    struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
    struct qpcie_v4l2_buffer *buf =
        container_of(vbuf, struct qpcie_v4l2_buffer, vb);
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    struct qpcie_dev *qdev = vch->qdev;
    struct qpcie_v4l2_channel *out_vch, *cap_vch;
    struct qpcie_v4l2_buffer *out_buf, *cap_buf;
    unsigned long flags;
    int ret;

    if (vch->channel_id == 0) {
        spin_lock_irqsave(&qdev->ring_lock, flags);
        ret = qpcie_publish_buffer(vch, buf);
        spin_unlock_irqrestore(&qdev->ring_lock, flags);
        if (ret) {
            dev_err(&qdev->pdev->dev,
                    "V4L2 ch%u buf%u: descriptor publish rejected (%d)\n",
                    vch->channel_id, buf->vb.vb2_buf.index, ret);
            vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_ERROR);
        }
        return;
    }

    out_vch = &qdev->v4l2_ch[(vch->channel_id * 2) - 1];
    cap_vch = &qdev->v4l2_ch[vch->channel_id * 2];

    spin_lock_irqsave(&qdev->ring_lock, flags);
    list_add_tail(&buf->list, &vch->pending_buffers);
    while (!list_empty(&out_vch->pending_buffers) &&
           !list_empty(&cap_vch->pending_buffers)) {
        out_buf = list_first_entry(&out_vch->pending_buffers,
                                   struct qpcie_v4l2_buffer, list);
        cap_buf = list_first_entry(&cap_vch->pending_buffers,
                                   struct qpcie_v4l2_buffer, list);
        list_del(&out_buf->list);
        list_del(&cap_buf->list);

        /* Publish the H2C half before the C2H half.  The FPGA descriptor
         * pipeline blocks on the shared SGL fetch of the C2H descriptor until
         * its table is consumed by the capture engine, and the capture engine
         * only consumes SGL entries as it writes loopback input -- which the
         * H2C DMA produces.  H2C-first lets the H2C frame stream start so the
         * C2H SGL fetch can drain and complete; C2H-first deadlocks the whole
         * descriptor pipeline (observed: zero completions, head never advances). */
        ret = qpcie_publish_buffer(out_vch, out_buf);
        if (ret) {
            /* Reject both halves: the C2H partner was never published. */
            spin_unlock_irqrestore(&qdev->ring_lock, flags);
            dev_err(&qdev->pdev->dev,
                    "V4L2 ch%u loopback: output buf%u publish rejected (%d); dropping pair\n",
                    vch->channel_id, out_buf->vb.vb2_buf.index, ret);
            vb2_buffer_done(&out_buf->vb.vb2_buf, VB2_BUF_STATE_ERROR);
            vb2_buffer_done(&cap_buf->vb.vb2_buf, VB2_BUF_STATE_ERROR);
            return;
        }
        if (qpcie_publish_buffer(cap_vch, cap_buf)) {
            /* Output already in the ring; only the C2H half is rejected. */
            spin_unlock_irqrestore(&qdev->ring_lock, flags);
            dev_err(&qdev->pdev->dev,
                    "V4L2 ch%u loopback: capture buf%u publish rejected; dropping capture\n",
                    vch->channel_id, cap_buf->vb.vb2_buf.index);
            vb2_buffer_done(&cap_buf->vb.vb2_buf, VB2_BUF_STATE_ERROR);
            return;
        }
    }
    spin_unlock_irqrestore(&qdev->ring_lock, flags);
}

static void qpcie_return_all_buffers(struct qpcie_v4l2_channel *vch,
                                       enum vb2_buffer_state state)
{
    struct qpcie_dev *qdev = vch->qdev;

    for (;;) {
        struct qpcie_v4l2_buffer *buf;
        unsigned long flags;

        spin_lock_irqsave(&qdev->ring_lock, flags);
        if (list_empty(&vch->pending_buffers)) {
            spin_unlock_irqrestore(&qdev->ring_lock, flags);
            break;
        }
        buf = list_first_entry(&vch->pending_buffers,
                               struct qpcie_v4l2_buffer, list);
        list_del(&buf->list);
        spin_unlock_irqrestore(&qdev->ring_lock, flags);
        vb2_buffer_done(&buf->vb.vb2_buf, state);
    }

    for (;;) {
        struct qpcie_v4l2_buffer *buf;

        spin_lock_irq(&vch->slock);
        if (list_empty(&vch->active_buffers)) {
            spin_unlock_irq(&vch->slock);
            break;
        }
        buf = list_first_entry(&vch->active_buffers,
                               struct qpcie_v4l2_buffer, list);
        list_del(&buf->list);
        spin_unlock_irq(&vch->slock);
        vb2_buffer_done(&buf->vb.vb2_buf, state);
    }
}

static int qpcie_start_streaming(struct vb2_queue *vq, unsigned int count)
{
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vq);
    struct qpcie_dev *qdev = vch->qdev;
    u32 pacer_ctrl;
    int ret;

    if (count < 2) {
        qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
        return -ENOBUFS;
    }

    vch->sequence = 0;
    vch->current_slice_idx = 0;
    vch->error_count_start = ioread32(qdev->bar0_mmio + REG_VIDEO_ERRORS);
    iowrite32(0, qdev->bar0_mmio + REG_VIDEO_CTRL);
    ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
    iowrite32(0, qdev->bar0_mmio + REG_SLICE_HEIGHT);
    iowrite32(vch->pacer_enable ? 1 : 0,
              qdev->bar0_mmio + REG_PACER_CTRL);

    /* Only Channel 0 uses the Video Test Pattern Generator (TPG0).
     * Channels 1 and 2 are dedicated hardware loopback and user streaming. */
    if (vch->channel_id == 0) {
        struct v4l2_ctrl *pattern_ctrl;
        u32 pattern_id;

        pattern_ctrl = v4l2_ctrl_find(&vch->ctrl_handler,
                                      V4L2_CID_TEST_PATTERN);
        pattern_id = qpcie_tpg_pattern_id(pattern_ctrl ? pattern_ctrl->val : 3);

        iowrite32(1, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        usleep_range(1000, 2000);
        iowrite32(0, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        usleep_range(1000, 2000);

        if (qpcie_program_tpg(vch, pattern_id, false)) {
            qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
            return -EIO;
        }
    }

    pacer_ctrl = ioread32(qdev->bar0_mmio + REG_PACER_CTRL);
    if (!!(pacer_ctrl & BIT(0)) != vch->pacer_enable) {
        dev_err(&qdev->pdev->dev,
                "NV12M pacer readback mismatch: requested=%u readback=0x%08x\n",
                vch->pacer_enable, pacer_ctrl);
        qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
        return -EIO;
    }
    dma_wmb();
    /* Reset for one PCIe clock, then count the complete streaming window. */
    iowrite32(0x03, qdev->bar0_mmio + REG_PERF_CTRL);
    ioread32(qdev->bar0_mmio + REG_PERF_CTRL);
    iowrite32(DMA_CTRL_RUN, qdev->bar0_mmio + REG_DMA_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_CTRL);

    /* Start TPG AFTER DMA is enabled so frame 1 starts cleanly without FIFO backpressure */
    if (vch->channel_id == 0) {
        if (vch->pacer_enable) {
            ret = qpcie_tpg_pace_start(qdev);
            if (ret) {
                dev_err(&qdev->pdev->dev,
                        "Cannot start TPG pacing kthread: %d\n", ret);
                iowrite32(0, qdev->bar0_mmio + REG_DMA_CTRL);
                qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
                return ret;
            }
        } else {
            void __iomem *tpg = qdev->bar1_mmio + 0x000;
            iowrite32(0x81, tpg + 0x00); /* Continuous AUTO_RESTART */
        }
    }

    dev_info(&qdev->pdev->dev,
             "NV12M STREAMON (Ch%u %s): %u buffers, ring tail=%u, mode=%ux%u %s (pacer=0x%08x)\n",
             vch->channel_id,
             (vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) ? "Output" : "Capture",
             count, qdev->h2c_tail, vch->width, vch->height,
             vch->pacer_enable ? "60 FPS paced" :
                                 "uncapped DMA benchmark",
             pacer_ctrl);
    return 0;
}

static void qpcie_stop_streaming(struct vb2_queue *vq)
{
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vq);
    struct qpcie_dev *qdev = vch->qdev;
    unsigned long timeout = jiffies + msecs_to_jiffies(500);
    bool drained = false;
    u32 head;

    if (vch->channel_id == 0) {
        void __iomem *tpg = qdev->bar1_mmio + 0x000;
        /* Halt pacing and stop TPG before draining DMA */
        qpcie_tpg_pace_stop(qdev);
        iowrite32(0x00, tpg + 0x00);
    }
    iowrite32(0, qdev->bar0_mmio + REG_PACER_CTRL);
    /* Stop fetching descriptors. Queued descriptors are cancelled below;
     * only already-buffered PCIe writes must drain before mappings return. */
    iowrite32(0, qdev->bar0_mmio + REG_DMA_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    do {
        u32 status = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);

        if (status & DMA_STATUS_VIDEO_TX_IDLE) {
            drained = true;
            break;
        }
        usleep_range(1000, 2000);
    } while (time_before(jiffies, timeout));

    /* Freeze the video engine and its CDC FIFO before cancelling descriptors.
     * STREAMON releases this reset after new mappings have been queued. */
    iowrite32(1, qdev->bar0_mmio + REG_VIDEO_CTRL);
    ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
    usleep_range(1000, 2000);
    timeout = jiffies + msecs_to_jiffies(500);
    do {
        u32 status = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);

        if ((status & (DMA_STATUS_VIDEO_TX_IDLE |
                       DMA_STATUS_DESC_IDLE)) ==
            (DMA_STATUS_VIDEO_TX_IDLE | DMA_STATUS_DESC_IDLE))
            break;
        usleep_range(1000, 2000);
    } while (time_before(jiffies, timeout));

    qpcie_dma_soft_reset(qdev);

    /* Cancel descriptors that were queued for frames the stopped TPG will
     * never produce. Rebase both producer pointers to the hardware consumer. */
    head = ioread32(qdev->bar0_mmio + 0x40) & 0xffff;
    qdev->h2c_tail = head;
    qdev->c2h_tail = head;
    iowrite32((head << 16) | RING_BUFFER_SIZE,
              qdev->bar0_mmio + REG_H2C_RING_CFG);
    ioread32(qdev->bar0_mmio + REG_H2C_RING_CFG);

    /* Freeze counters after all channel-0 writes have retired. */
    iowrite32(0, qdev->bar0_mmio + REG_PERF_CTRL);
    ioread32(qdev->bar0_mmio + REG_PERF_CTRL);
    synchronize_irq(qdev->irq);
    {
        u32 errors = ioread32(qdev->bar0_mmio + REG_VIDEO_ERRORS);

        if (!drained)
            dev_err(&qdev->pdev->dev,
                    "NV12M STREAMOFF timed out while draining DMA\n");
        if (errors != vch->error_count_start)
            dev_err(&qdev->pdev->dev,
                    "NV12M video protocol errors increased: %u -> %u\n",
                    vch->error_count_start, errors);
        dev_info(&qdev->pdev->dev,
                 "NV12M STREAMOFF: drained=%u head=%u tail=%u video_errors=%u\n",
                 drained, head, head, errors);
    }
    qpcie_return_all_buffers(vch, VB2_BUF_STATE_ERROR);
}

static const struct vb2_ops qpcie_vb2_ops = {
    .queue_setup    = qpcie_queue_setup,
    .buf_init       = qpcie_buf_init,
    .buf_cleanup    = qpcie_buf_cleanup,
    .buf_prepare    = qpcie_buf_prepare,
    .buf_queue      = qpcie_buf_queue,
    .start_streaming = qpcie_start_streaming,
    .stop_streaming = qpcie_stop_streaming,
};

/* V4L2 Control Framework Integration (V4L2_CID_TEST_PATTERN) */
static const char * const qpcie_tpg_pattern_strings[] = {
    "Pass-through",
    "Horizontal Ramp",
    "Vertical Ramp",
    "Color Bars",
    "Zone Plate",
    NULL
};

static int qpcie_s_ctrl(struct v4l2_ctrl *ctrl)
{
    struct qpcie_v4l2_channel *vch = container_of(ctrl->handler, struct qpcie_v4l2_channel, ctrl_handler);
    struct qpcie_dev *qdev = vch->qdev;

    switch (ctrl->id) {
    case V4L2_CID_QPCIE_PACER_ENABLE:
        vch->pacer_enable = !!ctrl->val;
        if (qdev && qdev->bar0_mmio && vb2_is_streaming(&vch->queue)) {
            iowrite32(vch->pacer_enable ? 1 : 0,
                      qdev->bar0_mmio + REG_PACER_CTRL);
            ioread32(qdev->bar0_mmio + REG_PACER_CTRL);
        }
        break;
    case V4L2_CID_TEST_PATTERN:
        if (vb2_is_streaming(&vch->queue))
            return -EBUSY;
        return qpcie_program_tpg(vch, qpcie_tpg_pattern_id(ctrl->val), true);
    }
    return 0;
}

static const struct v4l2_ctrl_ops qpcie_ctrl_ops = {
    .s_ctrl = qpcie_s_ctrl,
};

static const struct v4l2_ctrl_config qpcie_pacer_ctrl_config = {
    .ops  = &qpcie_ctrl_ops,
    .id   = V4L2_CID_QPCIE_PACER_ENABLE,
    .name = "QPCIe Frame Pacer Enable",
    .type = V4L2_CTRL_TYPE_BOOLEAN,
    .min  = 0,
    .max  = 1,
    .step = 1,
    .def  = 1,
};

int qpcie_v4l2_init(struct qpcie_dev *qdev)
{
    u32 hw_caps;
    unsigned int hw_video_ch;
    int i, ret;

    /* The capture engines emit 256-byte MWr payloads. A host that has not
     * negotiated MPS >= 256 would silently drop those TLPs, so refuse to
     * bring up video instead of risking silent data corruption. */
    ret = pcie_get_mps(qdev->pdev);
    if (ret < 0) {
        dev_err(&qdev->pdev->dev,
                "[V4L2] failed to read negotiated MPS: %d\n", ret);
        return ret;
    }
    if (ret < 256) {
        dev_err(&qdev->pdev->dev,
                "[V4L2] negotiated MaxPayloadSize %d < 256; add pci=pcie_bus_perf "
                "to the kernel command line and reload\n", ret);
        return -EOPNOTSUPP;
    }
    dev_info(&qdev->pdev->dev,
             "[V4L2] negotiated MaxPayloadSize %d bytes supports 256-byte MWr\n",
             ret);

    hw_caps = ioread32(qdev->bar0_mmio + REG_HARDWARE_CAPS);
    hw_video_ch = (hw_caps >> 8) & 0xff;
    if (hw_video_ch < NUM_VIDEO_CHANNELS) {
        dev_err(&qdev->pdev->dev,
                "[V4L2] FPGA reports only %u video channels (caps=0x%08x), need %u for TPG + 3 loopback channels\n",
                hw_video_ch, hw_caps, NUM_VIDEO_CHANNELS);
        return -EOPNOTSUPP;
    }
    dev_info(&qdev->pdev->dev,
             "[V4L2] FPGA capability check passed: %u video channels (caps=0x%08x)\n",
             hw_video_ch, hw_caps);

    dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.1] Registering top-level v4l2_device...\n");
    spin_lock_init(&qdev->ring_lock);
    snprintf(qdev->v4l2_dev.name, sizeof(qdev->v4l2_dev.name), "qpcie-v4l2");
    ret = v4l2_device_register(&qdev->pdev->dev, &qdev->v4l2_dev);
    if (ret) {
        dev_err(&qdev->pdev->dev, "[DEBUG ERROR] v4l2_device_register failed: %d\n", ret);
        return ret;
    }

    /* Bring up all 7 V4L2 nodes:
     * - /dev/video0: Channel 0 TPG Hardware Video Capture
     * - /dev/video1/2: Channel 1 Loopback Output/Capture
     * - /dev/video3/4: Channel 2 Loopback Output/Capture
     * - /dev/video5/6: Channel 3 Loopback Output/Capture */
    for (i = 0; i < NUM_VIDEO_NODES; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        struct video_device *vdev = &vch->vdev;

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.2] Initializing Video Node %d...\n", i);
        vch->qdev       = qdev;
        vch->width      = 1920;
        vch->height     = 1080;
        vch->stride     = 1920;
        vch->pixelformat= V4L2_PIX_FMT_NV12M;
        vch->pacer_enable = true;

        if (i == 0) {
            vch->channel_id = 0;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        } else if (i == 1) {
            vch->channel_id = 1;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        } else if (i == 2) {
            vch->channel_id = 1;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        } else if (i == 3) {
            vch->channel_id = 2;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        } else if (i == 4) {
            vch->channel_id = 2;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        } else if (i == 5) {
            vch->channel_id = 3;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        } else {
            vch->channel_id = 3;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        }

        mutex_init(&vch->lock);
        spin_lock_init(&vch->slock);
        INIT_LIST_HEAD(&vch->pending_buffers);
        INIT_LIST_HEAD(&vch->active_buffers);

        /* Initialize V4L2 Control Handler */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.3] Node %d: Initializing Control Handler...\n", i);
        v4l2_ctrl_handler_init(&vch->ctrl_handler, 2);
        if (i == 0) {
            v4l2_ctrl_new_std_menu_items(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                         V4L2_CID_TEST_PATTERN,
                                         4, BIT(0), 3, qpcie_tpg_pattern_strings);
        }
        v4l2_ctrl_new_custom(&vch->ctrl_handler,
                             &qpcie_pacer_ctrl_config, NULL);
        if (vch->ctrl_handler.error) {
            ret = vch->ctrl_handler.error;
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Node %d: Control handler error: %d\n", i, ret);
            goto unreg_v4l2;
        }

        /* Initialize vb2_queue: all nodes use vb2_dma_sg */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.4] Node %d: Initializing vb2_queue with vb2_dma_sg...\n", i);
        vch->queue.type            = vch->buf_type;
        vch->queue.io_modes        = VB2_MMAP | VB2_USERPTR | VB2_DMABUF;
        vch->queue.drv_priv        = vch;
        vch->queue.buf_struct_size = sizeof(struct qpcie_v4l2_buffer);
        vch->queue.ops             = &qpcie_vb2_ops;
        vch->queue.mem_ops         = &vb2_dma_sg_memops;
        vch->queue.dma_dir         =
            vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE ?
            DMA_TO_DEVICE : DMA_FROM_DEVICE;
        vch->queue.timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
        vch->queue.lock            = &vch->lock;
        vch->queue.dev             = &qdev->pdev->dev;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)
        vch->queue.min_queued_buffers = 2;
#else
        vch->queue.min_buffers_needed = 2;
#endif
        ret = vb2_queue_init(&vch->queue);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Node %d: vb2_queue_init failed: %d\n", i, ret);
            goto unreg_v4l2;
        }

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.5] Node %d: Registering Video Device /dev/videoX...\n", i);
        if (i == 0) {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-capture-tpg0");
            vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_RX;
        } else if (i == 1) {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-out1");
            vdev->device_caps = V4L2_CAP_VIDEO_OUTPUT_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_TX;
        } else if (i == 2) {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-cap1");
            vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_RX;
        } else if (i == 3) {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-out2");
            vdev->device_caps = V4L2_CAP_VIDEO_OUTPUT_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_TX;
        } else if (i == 4) {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-cap2");
            vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_RX;
        } else if (i == 5) {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-out3");
            vdev->device_caps = V4L2_CAP_VIDEO_OUTPUT_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_TX;
        } else {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-cap3");
            vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_RX;
        }
        vdev->fops         = &qpcie_v4l2_fops;
        vdev->ioctl_ops    = &qpcie_v4l2_ioctl_ops;
        vdev->release      = video_device_release_empty;
        vdev->v4l2_dev     = &qdev->v4l2_dev;
        vdev->ctrl_handler = &vch->ctrl_handler;
        vdev->queue        = &vch->queue;
        vdev->lock         = &vch->lock;
        video_set_drvdata(vdev, vch);

        ret = video_register_device(vdev, VFL_TYPE_VIDEO, -1);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Node %d: video_register_device failed: %d\n", i, ret);
            goto unreg_v4l2;
        }

        ret = v4l2_ctrl_handler_setup(&vch->ctrl_handler);
        if (ret) {
            dev_err(&qdev->pdev->dev,
                    "Node %d: control setup failed: %d\n", i, ret);
            goto unreg_v4l2;
        }

        dev_info(&qdev->pdev->dev,
                 " -> Node %d registered as /dev/video%d (%s)\n",
                 i, vdev->num, (vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) ? "Loopback Output" : "Capture");
    }

    qdev->v4l2_registered = true;
    dev_info(&qdev->pdev->dev,
             "[V4L2] 7 nodes initialized: /dev/video0 (TPG0), video1/2 (Ch1 LB), video3/4 (Ch2 LB), video5/6 (Ch3 LB)\n");
    return 0;

unreg_v4l2:
    for (i = 0; i < NUM_VIDEO_NODES; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        if (video_is_registered(&vch->vdev))
            video_unregister_device(&vch->vdev);
        v4l2_ctrl_handler_free(&vch->ctrl_handler);
    }
    v4l2_device_unregister(&qdev->v4l2_dev);
    return ret;
}

void qpcie_v4l2_remove(struct qpcie_dev *qdev)
{
    int i;
    if (!qdev->v4l2_registered)
        return;

    qdev->v4l2_registered = false;
    for (i = 0; i < NUM_VIDEO_NODES; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        if (video_is_registered(&vch->vdev))
            video_unregister_device(&vch->vdev);
        v4l2_ctrl_handler_free(&vch->ctrl_handler);
    }
    v4l2_device_unregister(&qdev->v4l2_dev);
}

void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev)
{
    u32 status = 0;
    int i;
    u32 slice_height = 0;

    if (qdev && qdev->bar0_mmio) {
        status = ioread32(qdev->bar0_mmio + REG_IRQ_STATUS);
        slice_height = ioread32(qdev->bar0_mmio + REG_SLICE_HEIGHT);
    }

    /* Bit 0: H2C Output Complete (Video Output Nodes) */
    if (status & BIT(0)) {
        for (i = 0; i < NUM_VIDEO_NODES; i++) {
            struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
            struct qpcie_v4l2_buffer *buf;

            if (vch->buf_type != V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE)
                continue;

            spin_lock(&vch->slock);
            if (!list_empty(&vch->active_buffers)) {
                buf = list_first_entry(&vch->active_buffers, struct qpcie_v4l2_buffer, list);
                list_del(&buf->list);
                buf->vb.vb2_buf.timestamp = ktime_get_ns();
                buf->vb.sequence = vch->sequence++;
                vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_DONE);
            }
            spin_unlock(&vch->slock);
        }
    }

    /* Bit 1: C2H Video Capture Complete (Video Capture Nodes) */
    if (status & BIT(1)) {
        for (i = 0; i < NUM_VIDEO_NODES; i++) {
            struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
            struct qpcie_v4l2_buffer *buf;

            if (vch->buf_type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
                continue;

            spin_lock(&vch->slock);
            if (!list_empty(&vch->active_buffers)) {
                buf = list_first_entry(&vch->active_buffers, struct qpcie_v4l2_buffer, list);

                if (slice_height > 0) {
                    /* Sub-Frame Low-Latency Slice DMA Mode */
                    u32 total_slices = (vch->height + slice_height - 1) / slice_height;
                    struct v4l2_event ev = {
                        .type = V4L2_EVENT_FRAME_SYNC,
                        .u.frame_sync.frame_sequence = vch->sequence,
                    };

                    vch->current_slice_idx++;
                    v4l2_event_queue(&vch->vdev, &ev);

                    if (vch->current_slice_idx >= total_slices) {
                        vch->current_slice_idx = 0;
                        list_del(&buf->list);
                        buf->vb.vb2_buf.timestamp = ktime_get_ns();
                        buf->vb.sequence = vch->sequence++;
                        vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_DONE);
                    }
                } else {
                    /* Standard Full-Frame IRQ Mode */
                    list_del(&buf->list);
                    buf->vb.vb2_buf.timestamp = ktime_get_ns();
                    buf->vb.sequence = vch->sequence++;
                    vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_DONE);
                }
            }
            spin_unlock(&vch->slock);
        }
    }
}
