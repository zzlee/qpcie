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
    strscpy(cap->driver, "qpcie-v4l2", sizeof(cap->driver));
    strscpy(cap->card, "QPCIe NV12M Video Capture", sizeof(cap->card));
    strscpy(cap->bus_info, "PCIe:custom-dma", sizeof(cap->bus_info));
    cap->capabilities = V4L2_CAP_VIDEO_CAPTURE_MPLANE |
                        V4L2_CAP_STREAMING | V4L2_CAP_DEVICE_CAPS;
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
    u32 rb_width, rb_height, rb_pattern, rb_format, rb_ctrl;

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
    iowrite32(0x81, tpg + 0x00); /* AP_START | AUTO_RESTART */
    rb_ctrl = ioread32(tpg + 0x00);
    rb_width = ioread32(tpg + 0x18);
    rb_height = ioread32(tpg + 0x10);
    rb_pattern = ioread32(tpg + 0x20);
    rb_format = ioread32(tpg + 0x40);

    dev_info(&qdev->pdev->dev,
             "TPG%u readback: %ux%u YUV444 pattern=%u format=%u ctrl=0x%08X\n",
             vch->channel_id, rb_width, rb_height, rb_pattern,
             rb_format, rb_ctrl);
    if (rb_width != vch->width || rb_height != vch->height ||
        rb_pattern != pattern_id || rb_format != 1 ||
        !(rb_ctrl & BIT(7))) {
        dev_err(&qdev->pdev->dev,
                "TPG%u BAR1 control readback mismatch\n",
                vch->channel_id);
        return -EIO;
    }
    return 0;
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
    pattern_id = qpcie_tpg_pattern_id(pattern_ctrl ? pattern_ctrl->val : 3);
    ret = qpcie_program_tpg(vch, pattern_id, true);
    if (ret) {
        vch->width = old_width;
        vch->height = old_height;
        vch->stride = old_stride;
        vch->pixelformat = old_pixelformat;
        return ret;
    }

    qpcie_fill_pix_format(&f->fmt.pix_mp, mode);
    return 0;
}

static int qpcie_vidioc_g_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
    if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
        return -EINVAL;

    a->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
    a->parm.capture.timeperframe.numerator = 1;
    a->parm.capture.timeperframe.denominator = 60;

    return 0;
}

static int qpcie_vidioc_s_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
        return -EINVAL;

    /* v_tpg offset 0x30 is maskId, not a frame-pacer register. Keep the
     * bring-up mode fixed at 60 fps without corrupting TPG configuration.
     * The frame interval is informational only: actual pacing follows the
     * V4L2_CID_QPCIE_PACER_ENABLE control so userspace can disable it for
     * uncapped benchmarks without S_PARM silently re-enabling it. */
    a->parm.capture.timeperframe.numerator = 1;
    a->parm.capture.timeperframe.denominator = 60;
    dev_info(&vch->qdev->pdev->dev,
             "V4L2 channel %u configured for %ux%u@60 NV12M\n",
             vch->channel_id, vch->width, vch->height);
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

static void qpcie_buf_queue(struct vb2_buffer *vb)
{
    struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
    struct qpcie_v4l2_buffer *buf = container_of(vbuf, struct qpcie_v4l2_buffer, vb);
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    struct qpcie_dev *qdev = vch->qdev;
    struct qpcie_dma_desc_2d *desc;
    dma_addr_t plane0_dma, plane1_dma;
    u32 tail;

    plane0_dma = vb2_dma_contig_plane_dma_addr(vb, 0);
    plane1_dma = vb2_dma_contig_plane_dma_addr(vb, 1);
    tail = qdev->h2c_tail;
    desc = &qdev->h2c_ring_virt[tail];
    memset(desc, 0, sizeof(*desc));

    desc->plane0_dst_addr = plane0_dma;
    desc->plane1_dst_addr = plane1_dma;
    desc->line_width      = vch->width;
    desc->line_count      = vch->height;
    desc->src_stride      = vch->width;
    desc->dst_stride      = vch->stride;
    desc->plane12_width   = vch->width;
    desc->plane12_count   = vch->height / 2;
    desc->format          = 0x2; /* NV12M */
    desc->plane_count     = 2;
    desc->control         = 0x0B; /* Valid | C2H | IRQ */

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
    pacer_ctrl = ioread32(qdev->bar0_mmio + REG_PACER_CTRL);
    if (!!(pacer_ctrl & BIT(0)) != vch->pacer_enable) {
        dev_err(&qdev->pdev->dev,
                "NV12M pacer readback mismatch: requested=%u readback=0x%08x\n",
                vch->pacer_enable, pacer_ctrl);
        qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
        return -EIO;
    }
    iowrite32(0x3, qdev->bar0_mmio + REG_IRQ_STATUS);
    dma_wmb();
    iowrite32(1, qdev->bar0_mmio + REG_DMA_CTRL);
    ioread32(qdev->bar0_mmio + REG_DMA_CTRL);
    dev_info(&qdev->pdev->dev,
             "NV12M STREAMON: %u buffers, ring tail=%u, mode=%ux%u %s (pacer=0x%08x)\n",
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

    /* Drain every descriptor already published to hardware. This avoids
     * returning a vb2 plane while a posted PCIe MWr may still target it. */
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

    /* Bring up one capture channel first; additional channels and OUTPUT are
     * intentionally deferred until channel 0 passes physical NV12 testing. */
    for (i = 0; i < 1; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        struct video_device *vdev = &vch->vdev;

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.2] Initializing Video Channel %d...\n", i);
        vch->qdev       = qdev;
        vch->channel_id = i;
        vch->width      = 1920;
        vch->height     = 1080;
        vch->stride     = 1920;
        vch->pixelformat= V4L2_PIX_FMT_NV12M;
        vch->pacer_enable = true;

        mutex_init(&vch->lock);
        spin_lock_init(&vch->slock);
        INIT_LIST_HEAD(&vch->active_buffers);

        /* Initialize V4L2 Control Handler for Video TPG */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.3] Channel %d: Initializing Control Handler...\n", i);
        v4l2_ctrl_handler_init(&vch->ctrl_handler, 2);
        v4l2_ctrl_new_std_menu_items(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                     V4L2_CID_TEST_PATTERN,
                                     4, BIT(0), 3, qpcie_tpg_pattern_strings);
        v4l2_ctrl_new_custom(&vch->ctrl_handler,
                             &qpcie_pacer_ctrl_config, NULL);
        if (vch->ctrl_handler.error) {
            ret = vch->ctrl_handler.error;
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Channel %d: Control handler error: %d\n", i, ret);
            goto unreg_v4l2;
        }

        /* Stage 2 starts with physically contiguous MMAP planes only. */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.4] Channel %d: Initializing vb2_queue...\n", i);
        vch->queue.type            = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        vch->queue.io_modes        = VB2_MMAP;
        vch->queue.drv_priv        = vch;
        vch->queue.buf_struct_size = sizeof(struct qpcie_v4l2_buffer);
        vch->queue.ops             = &qpcie_vb2_ops;
        vch->queue.mem_ops         = &vb2_dma_contig_memops;
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
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Channel %d: vb2_queue_init failed: %d\n", i, ret);
            goto unreg_v4l2;
        }

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.5] Channel %d: Registering Video Device /dev/videoX...\n", i);
        snprintf(vdev->name, sizeof(vdev->name), "qpcie-video-ch%d", i);
        vdev->fops         = &qpcie_v4l2_fops;
        vdev->ioctl_ops    = &qpcie_v4l2_ioctl_ops;
        vdev->release      = video_device_release_empty;
        vdev->v4l2_dev     = &qdev->v4l2_dev;
        vdev->ctrl_handler = &vch->ctrl_handler;
        vdev->queue        = &vch->queue;
        vdev->lock         = &vch->lock;
        vdev->device_caps  = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_STREAMING;
        vdev->vfl_dir      = VFL_DIR_RX;
        video_set_drvdata(vdev, vch);

        ret = video_register_device(vdev, VFL_TYPE_VIDEO, -1);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Channel %d: video_register_device failed: %d\n", i, ret);
            goto unreg_v4l2;
        }

        ret = v4l2_ctrl_handler_setup(&vch->ctrl_handler);
        if (ret) {
            dev_err(&qdev->pdev->dev,
                    "Channel %d: TPG control setup failed: %d\n", i, ret);
            goto unreg_v4l2;
        }
        dev_info(&qdev->pdev->dev, " -> Channel %d registered as /dev/video%d\n", i, vdev->num);
    }
    dev_info(&qdev->pdev->dev,
             "[V4L2] One NV12M MMAP capture node initialized (1080p60/4K60)\n");
    return 0;

unreg_v4l2:
    for (; i >= 0; i--) {
        if (video_is_registered(&qdev->v4l2_ch[i].vdev))
            video_unregister_device(&qdev->v4l2_ch[i].vdev);
        v4l2_ctrl_handler_free(&qdev->v4l2_ch[i].ctrl_handler);
    }
    v4l2_device_unregister(&qdev->v4l2_dev);
    return ret;
}

void qpcie_v4l2_remove(struct qpcie_dev *qdev)
{
    int i;
    for (i = 0; i < 1; i++) {
        if (video_is_registered(&qdev->v4l2_ch[i].vdev))
            video_unregister_device(&qdev->v4l2_ch[i].vdev);
        v4l2_ctrl_handler_free(&qdev->v4l2_ch[i].ctrl_handler);
    }
    v4l2_device_unregister(&qdev->v4l2_dev);
}

void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev)
{
    int i;
    u32 slice_height = 0;

    if (qdev && qdev->bar0_mmio) {
        slice_height = ioread32(qdev->bar0_mmio + REG_SLICE_HEIGHT);
    }

    for (i = 0; i < 1; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        struct qpcie_v4l2_buffer *buf;

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

                /* Fire Sub-Frame Slice Ready V4L2 Event to Userspace */
                v4l2_event_queue(&vch->vdev, &ev);

                /* Complete frame when all slices land in Host DDR/VRAM */
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
