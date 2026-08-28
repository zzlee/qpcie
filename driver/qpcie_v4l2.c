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

static void qpcie_build_variable_sgl(struct scatterlist *sgl, unsigned int nents,
                                     struct qpcie_sgl_entry *slots_virt, dma_addr_t slots_dma,
                                     unsigned int max_slots)
{
    struct scatterlist *sg;
    unsigned int i;
    unsigned int cur_slot = 0;
    unsigned int cur_entry = 0;
    struct qpcie_sgl_entry *slot_ptr = slots_virt;

    memset(slots_virt, 0, max_slots * 4096);

    for_each_sg(sgl, sg, nents, i) {
        dma_addr_t chunk_addr = sg_dma_address(sg);
        u32 chunk_len = sg_dma_len(sg);

        if (cur_slot >= max_slots)
            break;

        slot_ptr[cur_entry].phys_addr = (u64)chunk_addr;
        slot_ptr[cur_entry].len_bytes = chunk_len;
        slot_ptr[cur_entry].flags     = (i == nents - 1) ? SGL_FLAG_LAST_SEG : 0;
        cur_entry++;

        if (cur_entry == 255) {
            /* Chained pointer at Entry 255 (offset 0xFF0) */
            if (cur_slot + 1 < max_slots) {
                slot_ptr[255].phys_addr = (u64)(slots_dma + (cur_slot + 1) * 4096);
                slot_ptr[255].len_bytes = 0;
                slot_ptr[255].flags     = SGL_FLAG_CHAIN_PTR;
                cur_slot++;
                slot_ptr = (struct qpcie_sgl_entry *)((u8 *)slots_virt + cur_slot * 4096);
                cur_entry = 0;
            } else {
                slot_ptr[255].flags = 0;
                break;
            }
        }
    }
}

static void qpcie_buf_queue(struct vb2_buffer *vb)
{
    struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
    struct qpcie_v4l2_buffer *buf = container_of(vbuf, struct qpcie_v4l2_buffer, vb);
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    struct qpcie_dev *qdev = vch->qdev;
    struct qpcie_dma_desc_2d *desc;
    struct sg_table *sgt0, *sgt1;
    dma_addr_t plane0_dma, plane1_dma;
    u32 tail;

    sgt0 = vb2_dma_sg_plane_desc(vb, 0);
    sgt1 = vb2_dma_sg_plane_desc(vb, 1);
    if (WARN_ON(!sgt0 || !sgt1))
        return;

    plane0_dma = sg_dma_address(sgt0->sgl);
    plane1_dma = sg_dma_address(sgt1->sgl);
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

    if (vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) {
        /* Video Output (Host -> H2C FPGA Loopback Stream) */
        if (sgt0->nents > 1 || sgt1->nents > 1) {
            qpcie_build_variable_sgl(sgt0->sgl, sgt0->nents,
                                     (struct qpcie_sgl_entry *)buf->y_slots_virt,
                                     buf->y_slots_dma, QPCIE_MAX_PAGE_SLOTS_Y);
            qpcie_build_variable_sgl(sgt1->sgl, sgt1->nents,
                                     (struct qpcie_sgl_entry *)buf->uv_slots_virt,
                                     buf->uv_slots_dma, QPCIE_MAX_PAGE_SLOTS_UV);

            desc->plane0_src_addr = buf->y_slots_dma;
            desc->plane1_src_addr = buf->uv_slots_dma;
            desc->control = 0x09 | (vch->channel_id << 2) | DESC_CTRL_SG_FETCH_MODE;
        } else {
            desc->plane0_src_addr = plane0_dma;
            desc->plane1_src_addr = plane1_dma;
            desc->control = 0x09 | (vch->channel_id << 2);
        }
    } else {
        /* Video Capture (FPGA -> C2H Host Memory Stream) */
        if (sgt0->nents > 1 || sgt1->nents > 1) {
            qpcie_build_variable_sgl(sgt0->sgl, sgt0->nents,
                                     (struct qpcie_sgl_entry *)buf->y_slots_virt,
                                     buf->y_slots_dma, QPCIE_MAX_PAGE_SLOTS_Y);
            qpcie_build_variable_sgl(sgt1->sgl, sgt1->nents,
                                     (struct qpcie_sgl_entry *)buf->uv_slots_virt,
                                     buf->uv_slots_dma, QPCIE_MAX_PAGE_SLOTS_UV);

            desc->plane0_dst_addr = buf->y_slots_dma;
            desc->plane1_dst_addr = buf->uv_slots_dma;
            desc->control = 0x0B | (vch->channel_id << 2) | DESC_CTRL_SG_FETCH_MODE;
        } else {
            desc->plane0_dst_addr = plane0_dma;
            desc->plane1_dst_addr = plane1_dma;
            desc->control = 0x0B | (vch->channel_id << 2);
        }
    }

    /* Descriptor data must be globally visible before publishing the shared
     * hardware-ring tail doorbell. */
    dma_wmb();
    qdev->h2c_tail = (tail + 1) % RING_BUFFER_SIZE;
    qdev->c2h_tail = qdev->h2c_tail;
    iowrite32((qdev->h2c_tail << 16) | RING_BUFFER_SIZE,
              qdev->bar0_mmio + REG_H2C_RING_CFG);
    ioread32(qdev->bar0_mmio + REG_H2C_RING_CFG);

    spin_lock_irq(&vch->slock);
    list_add_tail(&buf->list, &vch->active_buffers);
    spin_unlock_irq(&vch->slock);
}

static void qpcie_return_all_buffers(struct qpcie_v4l2_channel *vch,
                                      enum vb2_buffer_state state)
{
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
    iowrite32(1, qdev->bar0_mmio + REG_DMA_CTRL);
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

    if (vch->channel_id == 0) {
        void __iomem *tpg = qdev->bar1_mmio + 0x000;
        /* Halt pacing and stop TPG before draining DMA */
        qpcie_tpg_pace_stop(qdev);
        iowrite32(0x00, tpg + 0x00);
    }
    iowrite32(0, qdev->bar0_mmio + REG_PACER_CTRL);
    do {
        u32 status = ioread32(qdev->bar0_mmio + REG_DMA_STATUS);
        u32 ptr = ioread32(qdev->bar0_mmio + 0x40);

        if (!(status & BIT(0)) && ((ptr & 0xffff) == (ptr >> 16))) {
            drained = true;
            break;
        }
        usleep_range(1000, 2000);
    } while (time_before(jiffies, timeout));

    iowrite32(0, qdev->bar0_mmio + REG_DMA_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    synchronize_irq(qdev->irq);
    {
        u32 errors = ioread32(qdev->bar0_mmio + REG_VIDEO_ERRORS);
        u32 ptr = ioread32(qdev->bar0_mmio + 0x40);

        if (!drained)
            dev_err(&qdev->pdev->dev,
                    "NV12M STREAMOFF timed out while draining DMA\n");
        if (errors != vch->error_count_start)
            dev_err(&qdev->pdev->dev,
                    "NV12M video protocol errors increased: %u -> %u\n",
                    vch->error_count_start, errors);
        dev_info(&qdev->pdev->dev,
                 "NV12M STREAMOFF: drained=%u head=%u tail=%u video_errors=%u\n",
                 drained, ptr & 0xffff, ptr >> 16, errors);
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

    dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.1] Registering top-level v4l2_device...\n");
    snprintf(qdev->v4l2_dev.name, sizeof(qdev->v4l2_dev.name), "qpcie-v4l2");
    ret = v4l2_device_register(&qdev->pdev->dev, &qdev->v4l2_dev);
    if (ret) {
        dev_err(&qdev->pdev->dev, "[DEBUG ERROR] v4l2_device_register failed: %d\n", ret);
        return ret;
    }

    /* Bring up 3 V4L2 nodes:
     * - /dev/video0: Channel 0 TPG Hardware Video Capture
     * - /dev/video1: Channel 1 Loopback Video Output (Host -> H2C)
     * - /dev/video2: Channel 1 Loopback Video Capture (C2H -> Host) */
    for (i = 0; i < 3; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        struct video_device *vdev = &vch->vdev;

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.2] Initializing Video Node %d...\n", i);
        vch->qdev       = qdev;
        vch->channel_id = (i == 0) ? 0 : 1;
        vch->width      = 1920;
        vch->height     = 1080;
        vch->stride     = 1920;
        vch->pixelformat= V4L2_PIX_FMT_NV12M;
        vch->pacer_enable = true;
        vch->buf_type   = (i == 1) ? V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE :
                                     V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

        mutex_init(&vch->lock);
        spin_lock_init(&vch->slock);
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

        /* Scatter-Gather DMA with MMAP, USERPTR, and DMABUF support */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.4] Node %d: Initializing vb2_queue with vb2_dma_sg...\n", i);
        vch->queue.type            = vch->buf_type;
        vch->queue.io_modes        = VB2_MMAP | VB2_USERPTR | VB2_DMABUF;
        vch->queue.drv_priv        = vch;
        vch->queue.buf_struct_size = sizeof(struct qpcie_v4l2_buffer);
        vch->queue.ops             = &qpcie_vb2_ops;
        vch->queue.mem_ops         = &vb2_dma_sg_memops;
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
        } else {
            snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-cap1");
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
                 i, vdev->num, (i == 1) ? "Loopback Output" : "Capture");
    }

    qdev->v4l2_registered = true;
    dev_info(&qdev->pdev->dev,
             "[V4L2] 3 nodes initialized: /dev/video0 (TPG0), /dev/video1 (Loopback Out), /dev/video2 (Loopback In)\n");
    return 0;

unreg_v4l2:
    for (i = 0; i < 3; i++) {
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
    for (i = 0; i < 3; i++) {
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

    /* Bit 0: H2C Output Complete (Node 1 Output /dev/video1) */
    if (status & BIT(0)) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[1];
        struct qpcie_v4l2_buffer *buf;

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

    /* Bit 1: C2H Video Capture Complete (Node 0 TPG or Node 2 Loopback In) */
    if (status & BIT(1)) {
        for (i = 0; i < 3; i++) {
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
