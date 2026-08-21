// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Driver: qpcie_v4l2.c
 * Description: Video4Linux2 Multi-Planar Capture Driver for Custom PCIe 2D DMA.
 *              Supports Memory-Mapped (MMAP), User Pointer (USERPTR),
 *              DMA-BUF Import (DMABUF), and Export Buffer (EXPBUF).
 */

#include "qpcie_driver.h"
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
    strscpy(cap->card, "QPCIe Multi-Planar Video Capture & Output", sizeof(cap->card));
    strscpy(cap->bus_info, "PCIe:custom-dma", sizeof(cap->bus_info));
    cap->capabilities = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_VIDEO_OUTPUT_MPLANE | V4L2_CAP_STREAMING | V4L2_CAP_DEVICE_CAPS;
    return 0;
}

static int qpcie_vidioc_enum_fmt_vid_cap_mplane(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
    if (f->index == 0) {
        f->pixelformat = V4L2_PIX_FMT_YUV420M;
        return 0;
    } else if (f->index == 1) {
        f->pixelformat = V4L2_PIX_FMT_NV12M;
        return 0;
    }
    return -EINVAL;
}

static int qpcie_vidioc_g_fmt_vid_cap_mplane(struct file *file, void *priv, struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    f->fmt.pix_mp.width        = vch->width;
    f->fmt.pix_mp.height       = vch->height;
    f->fmt.pix_mp.pixelformat  = vch->pixelformat;
    f->fmt.pix_mp.field        = V4L2_FIELD_NONE;
    f->fmt.pix_mp.colorspace   = V4L2_COLORSPACE_REC709;
    f->fmt.pix_mp.num_planes   = (vch->pixelformat == V4L2_PIX_FMT_YUV420M) ? 3 : 2;

    f->fmt.pix_mp.plane_fmt[0].bytesperline = vch->stride;
    f->fmt.pix_mp.plane_fmt[0].sizeimage    = vch->stride * vch->height;

    if (vch->pixelformat == V4L2_PIX_FMT_YUV420M) {
        f->fmt.pix_mp.plane_fmt[1].bytesperline = vch->stride / 2;
        f->fmt.pix_mp.plane_fmt[1].sizeimage    = (vch->stride / 2) * (vch->height / 2);
        f->fmt.pix_mp.plane_fmt[2].bytesperline = vch->stride / 2;
        f->fmt.pix_mp.plane_fmt[2].sizeimage    = (vch->stride / 2) * (vch->height / 2);
    } else { /* NV12M */
        f->fmt.pix_mp.plane_fmt[1].bytesperline = vch->stride;
        f->fmt.pix_mp.plane_fmt[1].sizeimage    = vch->stride * (vch->height / 2);
    }

    return 0;
}

static int qpcie_vidioc_s_fmt_vid_cap_mplane(struct file *file, void *priv, struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    vch->width       = f->fmt.pix_mp.width;
    vch->height      = f->fmt.pix_mp.height;
    vch->pixelformat = f->fmt.pix_mp.pixelformat;
    vch->stride      = ALIGN(vch->width, 64); /* 64-byte alignment */

    return qpcie_vidioc_g_fmt_vid_cap_mplane(file, priv, f);
}

static int qpcie_vidioc_g_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    struct qpcie_dev *qdev = vch->qdev;
    u32 clks = 2083333;

    if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE && a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
        return -EINVAL;

    if (qdev && qdev->bar1_mmio) {
        clks = ioread32(qdev->bar1_mmio + 0x0000 + 0x30);
        if (clks == 0) clks = 2083333;
    }

    a->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
    a->parm.capture.timeperframe.numerator = 1;
    a->parm.capture.timeperframe.denominator = 125000000 / (clks ? clks : 2083333);

    return 0;
}

static int qpcie_vidioc_s_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    struct qpcie_dev *qdev = vch->qdev;

    if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE && a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
        return -EINVAL;

    u32 num = a->parm.capture.timeperframe.numerator;
    u32 den = a->parm.capture.timeperframe.denominator;

    if (num == 0 || den == 0) return -EINVAL;

    u64 target_clks = (125000000ULL * (u64)num) / (u64)den;

    if (qdev && qdev->bar1_mmio) {
        iowrite32((u32)target_clks, qdev->bar1_mmio + 0x0000 + 0x30);
        dev_info(&qdev->pdev->dev, "V4L2 VIDIOC_S_PARM: Set Hardware Frame Rate Pacer FPS %u/%u -> Clks %llu\n",
                 den, num, target_clks);
    }

    return qpcie_vidioc_g_parm(file, priv, a);
}

static const struct v4l2_frmsize_discrete supported_framesizes[] = {
    { 3840, 2160 },
    { 1920, 1080 },
    { 1280, 720 },
};

static int qpcie_vidioc_enum_framesizes(struct file *file, void *priv, struct v4l2_frmsizeenum *fsize)
{
    if (fsize->pixel_format != V4L2_PIX_FMT_YUV420M && fsize->pixel_format != V4L2_PIX_FMT_NV12M)
        return -EINVAL;

    if (fsize->index >= ARRAY_SIZE(supported_framesizes))
        return -EINVAL;

    fsize->type = V4L2_FRMSIZE_TYPE_DISCRETE;
    fsize->discrete = supported_framesizes[fsize->index];
    return 0;
}

static const struct v4l2_fract supported_frameintervals[] = {
    { 1, 60 },
    { 1001, 60000 }, /* 59.94 FPS */
    { 1, 50 },
    { 1, 30 },
    { 1, 25 },
    { 1, 24 },
};

static int qpcie_vidioc_enum_frameintervals(struct file *file, void *priv, struct v4l2_frmivalenum *fival)
{
    if (fival->pixel_format != V4L2_PIX_FMT_YUV420M && fival->pixel_format != V4L2_PIX_FMT_NV12M)
        return -EINVAL;

    if (fival->index >= ARRAY_SIZE(supported_frameintervals))
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
    .vidioc_s_fmt_vid_cap_mplane    = qpcie_vidioc_s_fmt_vid_cap_mplane,

    .vidioc_enum_fmt_vid_out        = qpcie_vidioc_enum_fmt_vid_cap_mplane,
    .vidioc_g_fmt_vid_out_mplane    = qpcie_vidioc_g_fmt_vid_cap_mplane,
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
    int num_planes = (vch->pixelformat == V4L2_PIX_FMT_YUV420M) ? 3 : 2;

    *nplanes = num_planes;
    sizes[0] = vch->stride * vch->height;

    if (num_planes == 3) {
        sizes[1] = (vch->stride / 2) * (vch->height / 2);
        sizes[2] = (vch->stride / 2) * (vch->height / 2);
    } else {
        sizes[1] = vch->stride * (vch->height / 2);
    }

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
            v4l2_err(&vch->v4l2_dev, "Plane %d size %lu < required %lu\n",
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
    dma_addr_t plane0_dma, plane1_dma, plane2_dma = 0;
    bool is_output = V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type);

    plane0_dma = vb2_dma_sg_plane_desc(vb, 0)->sgl->dma_address;
    plane1_dma = vb2_dma_sg_plane_desc(vb, 1)->sgl->dma_address;
    if (vb->num_planes == 3)
        plane2_dma = vb2_dma_sg_plane_desc(vb, 2)->sgl->dma_address;

    if (is_output) {
        /* H2C DMA Transfer (Host RAM -> FPGA Output Stream) */
        desc = &qdev->h2c_ring_virt[qdev->h2c_tail];
        memset(desc, 0, sizeof(*desc));

        desc->plane0_src_addr = plane0_dma;
        desc->plane0_dst_addr = 0x0000; /* FPGA Stream Out */
        desc->plane1_src_addr = plane1_dma;
        desc->plane2_src_addr = plane2_dma;

        desc->line_width = vch->width;
        desc->line_count = vch->height;
        desc->src_stride = vch->stride;
        desc->dst_stride = vch->width;
        desc->format     = (vb->num_planes == 3) ? 0x3 : 0x2;
        desc->plane_count= vb->num_planes;
        desc->control    = 0x0009; /* Valid=1, Is_C2H=0 (H2C), IRQ_EN=1 */

        qdev->h2c_tail = (qdev->h2c_tail + 1) % RING_BUFFER_SIZE;
        iowrite32(((u32)qdev->h2c_tail << 16) | RING_BUFFER_SIZE, qdev->bar0_mmio + REG_H2C_RING_CFG);
    } else {
        /* C2H DMA Transfer (FPGA Input Stream -> Host RAM) */
        desc = &qdev->c2h_ring_virt[qdev->c2h_tail];
        memset(desc, 0, sizeof(*desc));

        desc->plane0_src_addr = 0x0000; /* FPGA Stream In */
        desc->plane0_dst_addr = plane0_dma;
        desc->plane1_dst_addr = plane1_dma;
        desc->plane2_dst_addr = plane2_dma;

        desc->line_width = vch->width;
        desc->line_count = vch->height;
        desc->src_stride = vch->width;
        desc->dst_stride = vch->stride;
        desc->format     = (vb->num_planes == 3) ? 0x3 : 0x2;
        desc->plane_count= vb->num_planes;
        desc->control    = 0x000B; /* Valid=1, Is_C2H=1 (C2H), IRQ_EN=1 */

        qdev->c2h_tail = (qdev->c2h_tail + 1) % RING_BUFFER_SIZE;
        iowrite32(((u32)qdev->c2h_tail << 16) | RING_BUFFER_SIZE, qdev->bar0_mmio + REG_C2H_RING_CFG);
    }

    spin_lock_irq(&vch->slock);
    list_add_tail(&buf->list, &vch->active_buffers);
    spin_unlock_irq(&vch->slock);
}

static const struct vb2_ops qpcie_vb2_ops = {
    .queue_setup = qpcie_queue_setup,
    .buf_prepare = qpcie_buf_prepare,
    .buf_queue   = qpcie_buf_queue,
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
    case V4L2_CID_TEST_PATTERN:
        if (qdev && qdev->bar1_mmio) {
            u32 pat_id = ctrl->val;
            if (pat_id == 3) pat_id = 9;  /* Color Bars */
            if (pat_id == 4) pat_id = 10; /* Zone Plate */

            /* Write Pattern ID to BAR1 Offset 0x0020 */
            iowrite32(pat_id, qdev->bar1_mmio + 0x0000 + 0x20);
            /* Trigger AP_START & Auto-Restart on TPG Control Reg (0x0000) */
            iowrite32(0x81, qdev->bar1_mmio + 0x0000 + 0x00);
            dev_info(&qdev->pdev->dev, "V4L2 Ctrl: Set Video TPG Pattern Menu Val %d -> HW Pattern %u\n",
                     ctrl->val, pat_id);
        }
        break;
    }
    return 0;
}

static const struct v4l2_ctrl_ops qpcie_ctrl_ops = {
    .s_ctrl = qpcie_s_ctrl,
};

int qpcie_v4l2_init(struct qpcie_dev *qdev)
{
    int i, ret;

    dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.1] Registering top-level v4l2_device...\n");
    snprintf(qdev->v4l2_dev.name, sizeof(qdev->v4l2_dev.name), "qpcie-v4l2");
    ret = v4l2_device_register(&qdev->pdev->dev, &qdev->v4l2_dev);
    if (ret) {
        dev_err(&qdev->pdev->dev, "[DEBUG ERROR] v4l2_device_register failed: %d\n", ret);
        return ret;
    }

    for (i = 0; i < NUM_VIDEO_CHANNELS; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        struct video_device *vdev = &vch->vdev;

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.2] Initializing Video Channel %d...\n", i);
        vch->qdev       = qdev;
        vch->channel_id = i;
        vch->width      = 1920;
        vch->height     = 1080;
        vch->stride     = 2048;
        vch->pixelformat= V4L2_PIX_FMT_YUV420M;

        mutex_init(&vch->lock);
        spin_lock_init(&vch->slock);
        INIT_LIST_HEAD(&vch->active_buffers);

        /* Initialize V4L2 Control Handler for Video TPG */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.3] Channel %d: Initializing Control Handler...\n", i);
        v4l2_ctrl_handler_init(&vch->ctrl_handler, 2);
        v4l2_ctrl_new_std_menu_items(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                     V4L2_CID_TEST_PATTERN,
                                     4, 0, 0, qpcie_tpg_pattern_strings);
        if (vch->ctrl_handler.error) {
            ret = vch->ctrl_handler.error;
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Channel %d: Control handler error: %d\n", i, ret);
            goto unreg_v4l2;
        }

        /* Enable MMAP, USERPTR, and DMABUF (Import/Export) Modes */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.4] Channel %d: Initializing vb2_queue...\n", i);
        vch->queue.type            = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        vch->queue.io_modes        = VB2_MMAP | VB2_USERPTR | VB2_DMABUF;
        vch->queue.drv_priv        = vch;
        vch->queue.buf_struct_size = sizeof(struct qpcie_v4l2_buffer);
        vch->queue.ops             = &qpcie_vb2_ops;
        vch->queue.mem_ops         = &vb2_dma_sg_memops;
        vch->queue.timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
        vch->queue.lock            = &vch->lock;
        vch->queue.dev             = &qdev->pdev->dev;
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
        video_set_drvdata(vdev, vch);

        ret = video_register_device(vdev, VFL_TYPE_VIDEO, -1);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Channel %d: video_register_device failed: %d\n", i, ret);
            goto unreg_v4l2;
        }

        v4l2_ctrl_handler_setup(&vch->ctrl_handler);
        dev_info(&qdev->pdev->dev, " -> Channel %d registered as /dev/video%d\n", i, vdev->num);
    }
    dev_info(&qdev->pdev->dev, "🎉 [DEBUG STEP 2 COMPLETE] All V4L2 Channels Initialized Successfully!\n");
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
    for (i = 0; i < NUM_VIDEO_CHANNELS; i++) {
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

    for (i = 0; i < NUM_VIDEO_CHANNELS; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        struct qpcie_v4l2_buffer *buf;

        spin_lock(&vch->slock);
        if (!list_empty(&vch->active_buffers)) {
            buf = list_first_entry(&vch->active_buffers, struct qpcie_v4l2_buffer, list);

            if (slice_height > 0) {
                /* Sub-Frame Low-Latency Slice DMA Mode */
                u32 total_slices = (vch->height + slice_height - 1) / slice_height;
                vch->current_slice_idx++;

                /* Fire Sub-Frame Slice Ready V4L2 Event to Userspace */
                struct v4l2_event ev = {
                    .type = V4L2_EVENT_FRAME_SYNC,
                    .u.frame_sync.frame_sequence = vch->sequence,
                };
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
