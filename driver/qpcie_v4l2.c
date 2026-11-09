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

/* Lab-only buffer-pressure comparison on frozen PL. This does not repair
 * the dual-ring doorbell race; default preserves the validated allocation.
 * Load-time only, and bounded by the existing eight-buffer maximum. */
static unsigned int sc7f0_nv_min_buffers = 2;
module_param(sc7f0_nv_min_buffers, uint, 0400);
MODULE_PARM_DESC(sc7f0_nv_min_buffers,
                 "Diagnostic minimum NV12/NV16 capture buffers (2..8, default2)");

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
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    if (vch && vch->channel_id == 1) {
        if (f->index == 0) {
            f->pixelformat = V4L2_PIX_FMT_H264;
            return 0;
        }
        if (f->index == 1) {
            f->pixelformat = V4L2_PIX_FMT_HEVC;
            return 0;
        }
        return -EINVAL;
    }
    if (f->index == 0) {
        f->pixelformat = V4L2_PIX_FMT_NV12M;
        return 0;
    }
    if (f->index == 1) {
        f->pixelformat = V4L2_PIX_FMT_RGB24;
        return 0;
    }
    if (f->index == 2) {
        struct qpcie_v4l2_channel *vch = video_drvdata(file);

        if (vch->channel_id != 0 || vch->buf_type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ||
            ioread32(vch->qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION) < 0x26102204)
            return -EINVAL;
        f->pixelformat = V4L2_PIX_FMT_NV16M;
        return 0;
    }
    return -EINVAL;
}

struct qpcie_video_mode {
    u32 width;
    u32 height;
};

static const struct qpcie_video_mode qpcie_video_modes[] = {
    { 1920, 1080 },
    { 3840, 2160 },
    { 4096, 2160 },
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
                                  const struct qpcie_video_mode *mode,
                                  u32 pixelformat, u32 req_stride)
{
    u32 stride;

    memset(pix, 0, sizeof(*pix));
    pix->width = mode->width;
    pix->height = mode->height;
    pix->field = V4L2_FIELD_NONE;
    pix->colorspace = V4L2_COLORSPACE_SRGB;

    if (pixelformat == V4L2_PIX_FMT_RGB24) {
        stride = req_stride ? req_stride : ALIGN(mode->width * 3, 128);
        if (stride < mode->width * 3)
            stride = ALIGN(mode->width * 3, 128);
        pix->pixelformat = V4L2_PIX_FMT_RGB24;
        pix->num_planes = 1;
        pix->plane_fmt[0].bytesperline = stride;
        pix->plane_fmt[0].sizeimage = stride * mode->height;
    } else if (pixelformat == V4L2_PIX_FMT_NV16M) {
        stride = req_stride >= mode->width ? req_stride : ALIGN(mode->width, 128);
        pix->pixelformat = V4L2_PIX_FMT_NV16M;
        pix->colorspace = V4L2_COLORSPACE_REC709;
        pix->num_planes = 2;
        pix->plane_fmt[0].bytesperline = stride;
        pix->plane_fmt[0].sizeimage = stride * mode->height;
        pix->plane_fmt[1].bytesperline = stride;
        pix->plane_fmt[1].sizeimage = stride * mode->height;
    } else {
        stride = req_stride ? req_stride : ALIGN(mode->width, 128);
        if (stride < mode->width)
            stride = ALIGN(mode->width, 128);
        pix->pixelformat = V4L2_PIX_FMT_NV12M;
        pix->colorspace = V4L2_COLORSPACE_REC709;
        pix->num_planes = 2;
        pix->plane_fmt[0].bytesperline = stride;
        pix->plane_fmt[0].sizeimage = stride * mode->height;
        pix->plane_fmt[1].bytesperline = stride;
        pix->plane_fmt[1].sizeimage = stride * (mode->height / 2);
    }
}

static u32 qpcie_tpg_pattern_id(int menu_value)
{
    if (menu_value == 0)
        return 9;  /* Pass-through is unavailable without a TPG input stream. */
    if (menu_value == 3)
        return 9;  /* Color Bars */
    if (menu_value == 4)
        return 10; /* Zone Plate */
    if (menu_value == 5)
        return 7;  /* Solid Black */
    if (menu_value == 6)
        return 8;  /* Solid White */
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

    tpg = qdev->bar1_mmio + qdev->bar1_offset_tpg + (vch->channel_id * 0x100);
    if (reset_pipeline) {
        /* Pulse reset on both TPG (bit 0) and video capture engine/FIFO (bit 1) */
        iowrite32(3, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        usleep_range(1000, 2000);
        iowrite32(0, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
        usleep_range(1000, 2000);
    }

    u32 tpg_fmt = (vch->pixelformat == V4L2_PIX_FMT_RGB24) ? 0 : 1; /* 0=RGB, 1=YUV444 */

    iowrite32(vch->height, tpg + 0x10);
    iowrite32(vch->width, tpg + 0x18);
    iowrite32(pattern_id, tpg + 0x20);
    iowrite32(tpg_fmt, tpg + 0x40);    /* XVIDC_CSF_RGB (0) or XVIDC_CSF_YCRCB_444 (1) */
    /* Hold TPG idle until STREAMON */
    iowrite32(0x00, tpg + 0x00);

    rb_width = ioread32(tpg + 0x18);
    rb_height = ioread32(tpg + 0x10);
    rb_pattern = ioread32(tpg + 0x20);
    rb_format = ioread32(tpg + 0x40);

    dev_info(&qdev->pdev->dev,
             "TPG%u configured: %ux%u %s pattern=%u format=%u\n",
             vch->channel_id, rb_width, rb_height,
             (tpg_fmt == 0) ? "RGB" : "YUV444", rb_pattern, rb_format);
    if (rb_width != vch->width || rb_height != vch->height ||
        rb_pattern != pattern_id || rb_format != tpg_fmt) {
        dev_err(&qdev->pdev->dev,
                "TPG%u BAR1 configuration readback mismatch (expected fmt=%u got %u)\n",
                vch->channel_id, tpg_fmt, rb_format);
        return -EIO;
    }
    return 0;
}

static int qpcie_program_tpg_motion(struct qpcie_v4l2_channel *vch, u32 speed)
{
    struct qpcie_dev *qdev = vch->qdev;
    void __iomem *tpg;
    u32 expected_enable;

    if (!qdev || !qdev->bar1_mmio)
        return -ENODEV;

    tpg = qdev->bar1_mmio + qdev->bar1_offset_tpg + (vch->channel_id * 0x100);
    expected_enable = speed ? 1 : 0;
    if (speed)
        iowrite32(speed, tpg + 0x38);
    /* motionSpeed=0 alone does not stop v_tpg Color Bars animation. */
    iowrite32(expected_enable, tpg + 0xd8);
    if ((ioread32(tpg + 0xd8) & BIT(0)) != expected_enable)
        return -EIO;

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
    u32 pulse_cnt = 0;

    /* Elevate to real-time FIFO priority to prevent preemption under 4K load */
    sched_set_fifo(current);
    set_freezable();

    while (!kthread_should_stop()) {
        unsigned long flags;

        if (READ_ONCE(qdev->tpg_pace_run) && qdev->bar1_mmio) {
            spin_lock_irqsave(&qdev->tpg_lock, flags);
            iowrite32(0x01, qdev->bar1_mmio + qdev->bar1_offset_tpg + 0x00); /* AP_START */
            spin_unlock_irqrestore(&qdev->tpg_lock, flags);
            if (++pulse_cnt <= 5)
                dev_info(&qdev->pdev->dev, "[TPG PACER] Pulse #%u AP_START fired\n", pulse_cnt);
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

    qpcie_fill_pix_format(&f->fmt.pix_mp, &mode, vch->pixelformat, vch->stride);
    return 0;
}

static int qpcie_vidioc_g_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    const struct qpcie_video_mode *mode;

    if (vch->channel_id == 1) {
        f->fmt.pix.width = vch->width ? vch->width : 3840;
        f->fmt.pix.height = vch->height ? vch->height : 2160;
        f->fmt.pix.field = V4L2_FIELD_NONE;
        f->fmt.pix.pixelformat = vch->pixelformat ? vch->pixelformat : V4L2_PIX_FMT_H264;
        f->fmt.pix.bytesperline = 0;
        f->fmt.pix.sizeimage = 4 * 1024 * 1024;
        f->fmt.pix.colorspace = V4L2_COLORSPACE_REC709;
        return 0;
    }

    mode = qpcie_find_video_mode(vch->width, vch->height);
    f->fmt.pix.width = mode->width;
    f->fmt.pix.height = mode->height;
    f->fmt.pix.field = V4L2_FIELD_NONE;
    if (vch->pixelformat == V4L2_PIX_FMT_RGB24) {
        f->fmt.pix.pixelformat = V4L2_PIX_FMT_RGB24;
        f->fmt.pix.bytesperline = mode->width * 3;
        f->fmt.pix.sizeimage = mode->width * 3 * mode->height;
        f->fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
    } else {
        f->fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
        f->fmt.pix.bytesperline = mode->width;
        f->fmt.pix.sizeimage = mode->width * mode->height * 3 / 2;
        f->fmt.pix.colorspace = V4L2_COLORSPACE_REC709;
    }
    return 0;
}

static int qpcie_vidioc_try_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    if (vch->channel_id == 1) {
        if (f->fmt.pix.pixelformat != V4L2_PIX_FMT_HEVC)
            f->fmt.pix.pixelformat = V4L2_PIX_FMT_H264;
        f->fmt.pix.field = V4L2_FIELD_NONE;
        f->fmt.pix.bytesperline = 0;
        f->fmt.pix.sizeimage = 4 * 1024 * 1024;
        f->fmt.pix.colorspace = V4L2_COLORSPACE_REC709;
        return 0;
    }
    if (f->fmt.pix.pixelformat != V4L2_PIX_FMT_RGB24)
        f->fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
    f->fmt.pix.field = V4L2_FIELD_NONE;
    f->fmt.pix.colorspace = (f->fmt.pix.pixelformat == V4L2_PIX_FMT_RGB24) ?
        V4L2_COLORSPACE_SRGB : V4L2_COLORSPACE_REC709;
    return 0;
}

static int qpcie_vidioc_s_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    if (vb2_is_busy(&vch->queue)) {
        if (vch->channel_id == 1 &&
            f->fmt.pix.pixelformat == vch->pixelformat &&
            (!f->fmt.pix.width || f->fmt.pix.width == vch->width) &&
            (!f->fmt.pix.height || f->fmt.pix.height == vch->height)) {
            return qpcie_vidioc_g_fmt_vid_cap(file, priv, f);
        }
        return -EBUSY;
    }

    if (vch->channel_id == 1) {
        if (f->fmt.pix.pixelformat == V4L2_PIX_FMT_HEVC)
            vch->pixelformat = V4L2_PIX_FMT_HEVC;
        else
            vch->pixelformat = V4L2_PIX_FMT_H264;
        if (f->fmt.pix.width && f->fmt.pix.height) {
            vch->width = f->fmt.pix.width;
            vch->height = f->fmt.pix.height;
        }
        vch->vcu_cfg.codec_type = (vch->pixelformat == V4L2_PIX_FMT_HEVC) ? 1 : 0;
        qpcie_vcu_sync_config(vch);
        return qpcie_vidioc_g_fmt_vid_cap(file, priv, f);
    }
    return -EINVAL;
}

static int qpcie_vidioc_try_fmt_vid_cap_mplane(struct file *file, void *priv,
                                                struct v4l2_format *f)
{
    const struct qpcie_video_mode *mode;
    u32 pixelformat = f->fmt.pix_mp.pixelformat;
    u32 req_stride = f->fmt.pix_mp.plane_fmt[0].bytesperline;

    if (pixelformat == V4L2_PIX_FMT_NV16M) {
        struct qpcie_v4l2_channel *channel = video_drvdata(file);

        if (channel->channel_id != 0 ||
            channel->buf_type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ||
            ioread32(channel->qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION) < 0x26102204)
            return -EINVAL;
    } else if (pixelformat != V4L2_PIX_FMT_RGB24) {
        pixelformat = V4L2_PIX_FMT_NV12M;
    }

    mode = qpcie_find_video_mode(f->fmt.pix_mp.width,
                                 f->fmt.pix_mp.height);
    qpcie_fill_pix_format(&f->fmt.pix_mp, mode, pixelformat, req_stride);
    return 0;
}

static int qpcie_vidioc_s_fmt_vid_cap_mplane(struct file *file, void *priv,
                                              struct v4l2_format *f)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    const struct qpcie_video_mode *mode;
    struct v4l2_ctrl *pattern_ctrl;
    u32 pattern_id;
    u32 old_width, old_height, old_stride, old_pixelformat, old_stride1;
    u32 pixelformat = f->fmt.pix_mp.pixelformat;
    u32 req_stride = f->fmt.pix_mp.plane_fmt[0].bytesperline;
    int ret;

    if (vb2_is_busy(&vch->queue))
        return -EBUSY;

    if (pixelformat == V4L2_PIX_FMT_NV16M) {
        struct qpcie_v4l2_channel *channel = video_drvdata(file);

        if (channel->channel_id != 0 ||
            channel->buf_type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ||
            ioread32(channel->qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION) < 0x26102204)
            return -EINVAL;
    } else if (pixelformat != V4L2_PIX_FMT_RGB24) {
        pixelformat = V4L2_PIX_FMT_NV12M;
    }

    if (req_stride > 65408 || (req_stride & 127) ||
        (f->fmt.pix_mp.plane_fmt[1].bytesperline &&
         f->fmt.pix_mp.plane_fmt[1].bytesperline != req_stride))
        return -EINVAL;

    mode = qpcie_find_video_mode(f->fmt.pix_mp.width,
                                 f->fmt.pix_mp.height);

    old_width = vch->width;
    old_height = vch->height;
    old_stride = vch->stride;
    old_stride1 = vch->stride1;
    old_pixelformat = vch->pixelformat;

    vch->width = mode->width;
    vch->height = mode->height;
    vch->pixelformat = pixelformat;
    if (pixelformat == V4L2_PIX_FMT_RGB24) {
        vch->stride = req_stride >= mode->width * 3 ? req_stride : ALIGN(mode->width * 3, 128);
        vch->stride1 = 0;
    } else {
        u32 req_stride1 = f->fmt.pix_mp.plane_fmt[1].bytesperline;
        vch->stride = req_stride >= mode->width ? req_stride : ALIGN(mode->width, 128);
        vch->stride1 = req_stride1 >= mode->width ? req_stride1 : vch->stride;
    }

    pattern_ctrl = v4l2_ctrl_find(&vch->ctrl_handler,
                                  V4L2_CID_TEST_PATTERN);
    if (pattern_ctrl && vch->channel_id == 0 &&
        (vch->video_source == 1 ||
         (vch->video_source == 0 &&
          !(ioread32(vch->qdev->bar0_mmio + REG_HDMI_RX_STATUS) & HDMI_RX_STATUS_5V_DET)))) {
        pattern_id = qpcie_tpg_pattern_id(pattern_ctrl->val);
        ret = qpcie_program_tpg(vch, pattern_id, true);
        if (ret) {
            vch->width = old_width;
            vch->height = old_height;
            vch->stride = old_stride;
            vch->stride1 = old_stride1;
            vch->pixelformat = old_pixelformat;
            return ret;
        }
    }

    qpcie_fill_pix_format(&f->fmt.pix_mp, mode, vch->pixelformat, vch->stride);
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
    if (fsize->pixel_format != V4L2_PIX_FMT_NV12M &&
        fsize->pixel_format != V4L2_PIX_FMT_NV16M &&
        fsize->pixel_format != V4L2_PIX_FMT_RGB24 &&
        fsize->pixel_format != V4L2_PIX_FMT_H264 &&
        fsize->pixel_format != V4L2_PIX_FMT_HEVC)
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
    if (fival->pixel_format != V4L2_PIX_FMT_NV12M &&
        fival->pixel_format != V4L2_PIX_FMT_NV16M &&
        fival->pixel_format != V4L2_PIX_FMT_RGB24 &&
        fival->pixel_format != V4L2_PIX_FMT_H264 &&
        fival->pixel_format != V4L2_PIX_FMT_HEVC)
        return -EINVAL;

    if (fival->index >= ARRAY_SIZE(supported_frameintervals))
        return -EINVAL;
    if ((fival->width != 1920 || fival->height != 1080) &&
        (fival->width != 3840 || fival->height != 2160) &&
        (fival->width != 4096 || fival->height != 2160))
        return -EINVAL;

    fival->type = V4L2_FRMIVAL_TYPE_DISCRETE;
    fival->discrete = supported_frameintervals[fival->index];
    return 0;
}

/*
 * Read one coherent telemetry snapshot from the PS publisher.
 * The publisher brackets an update with an odd/even SEQUENCE; we accept the
 * values only if SEQUENCE is even and identical before and after the payload
 * read. No payload field is invented when the ABI is absent or the snapshot
 * is torn: the caller must fail the query instead.
 */
int qpcie_hdmi_read_telemetry(struct qpcie_dev *qdev,
                              struct qpcie_hdmi_tlm *t)
{
    int retries;

    if (!qdev || !qdev->bar0_mmio)
        return -ENODEV;

    for (retries = 0; retries < 4; retries++) {
        u32 seq1, seq2;

        seq1 = ioread32(qdev->bar0_mmio + REG_HDMI_TLM_SEQ);
        if (seq1 & 1U) {
            /* This helper is also reachable from the hard IRQ frame-done
             * path, so never sleep in interrupt context. */
            if (in_interrupt())
                cpu_relax();
            else
                usleep_range(100, 200);
            continue;
        }
        rmb();

        t->abi_version = ioread32(qdev->bar0_mmio + REG_HDMI_TLM_ABI_VERSION);
        if (t->abi_version != HDMI_TLM_ABI_EXPECTED)
            return -ENODATA;
        t->flags = ioread32(qdev->bar0_mmio + REG_HDMI_TLM_FLAGS);
        t->heartbeat = ioread32(qdev->bar0_mmio + REG_HDMI_TLM_HEARTBEAT);
        t->mbus_code = ioread32(qdev->bar0_mmio + REG_HDMI_TLM_MBUS_CODE);
        t->width = ioread32(qdev->bar0_mmio + REG_HDMI_RX_WIDTH);
        t->height = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HEIGHT);
        t->hfp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HFP);
        t->hsw = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HSW);
        t->hbp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HBP);
        t->vfp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_VFP);
        t->vsw = ioread32(qdev->bar0_mmio + REG_HDMI_RX_VSW);
        t->vbp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_VBP);
        t->polarities = ioread32(qdev->bar0_mmio + REG_HDMI_RX_POLARITIES);
        t->standards = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STANDARDS);
        t->color_fmt = ioread32(qdev->bar0_mmio + REG_HDMI_RX_COLOR_FMT);
        t->pixelclock = (u64)ioread32(qdev->bar0_mmio + REG_HDMI_RX_PIXEL_CLK) |
                        ((u64)ioread32(qdev->bar0_mmio + REG_HDMI_TLM_PIXELCLK_HI) << 32);
        rmb();

        seq2 = ioread32(qdev->bar0_mmio + REG_HDMI_TLM_SEQ);
        if (seq1 == seq2 && !(seq2 & 1U))
            return 0;
        if (in_interrupt())
            cpu_relax();
        else
            usleep_range(100, 200);
    }

    return -EAGAIN;
}

/* Track publisher liveness using host time, not card clocks. */
bool qpcie_hdmi_telemetry_fresh(struct qpcie_dev *qdev, u32 heartbeat)
{
    unsigned long now = jiffies;

    if (!qdev->tlm_hb_valid || heartbeat != qdev->tlm_last_heartbeat) {
        qdev->tlm_last_heartbeat = heartbeat;
        qdev->tlm_last_change = now;
        qdev->tlm_hb_valid = true;
        return true;
    }

    return time_before(now, qdev->tlm_last_change +
                            msecs_to_jiffies(HDMI_TLM_HB_STALE_MS));
}

/*
 * A capture request for a real HDMI source may only succeed when the card
 * actually reports locked timing. Otherwise STREAMON would start a DMA path
 * with no valid geometry and report success for a stream that cannot work.
 */
static bool qpcie_hdmi_source_ready(struct qpcie_v4l2_channel *vch, int *err)
{
    struct qpcie_dev *qdev = vch->qdev;
    struct qpcie_hdmi_tlm t;
    u32 status = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);

    if (!(status & HDMI_RX_STATUS_5V_DET)) {
        *err = -ENOLINK;
        return false;
    }
    if (qpcie_hdmi_read_telemetry(qdev, &t)) {
        *err = -EAGAIN;
        return false;
    }
    if (!(t.flags & HDMI_TLM_F_TIMING_VALID) || !t.width || !t.height) {
        *err = -ENOLINK;
        return false;
    }
    /*
     * The capture engine is programmed with the geometry from S_FMT. Starting
     * it against a different incoming raster would DMA mis-framed data, so
     * refuse instead of silently capturing garbage.
     */
    if (t.width != vch->width || t.height != vch->height) {
        *err = -ERANGE;
        return false;
    }
    if (!qpcie_hdmi_telemetry_fresh(qdev, t.heartbeat)) {
        *err = -EAGAIN;
        return false;
    }
    /* RGB8 -> NV12/NV16 uses the BT.709 converter in HDMI08 rev04+.
     * Native YUV444/8 remains supported; no 422/420 expansion or deep color.
     */
    if (!(t.flags & HDMI_TLM_F_COLOR_VALID) ||
        (t.flags & HDMI_TLM_F_INTERLACED) ||
        ((t.color_fmt >> 20) & 0xf) != 8 ||
        (vch->pixelformat == V4L2_PIX_FMT_RGB24 ?
            ((t.color_fmt >> 24) & 0xf) != 0 :
            (((t.color_fmt >> 24) & 0xf) != 1 &&
             !(((t.color_fmt >> 24) & 0xf) == 0 &&
               ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION) >= 0x26102204)))) {
        dev_err(&qdev->pdev->dev,
                "HDMI format unsupported: color=0x%08x mbus=0x%x requested=0x%x; requires RGB8 or YUV444/8 progressive, and matching FPGA format support\n",
                t.color_fmt, t.mbus_code, vch->pixelformat);
        *err = -EOPNOTSUPP;
        return false;
    }
    return true;
}

static int qpcie_vidioc_query_dv_timings(struct file *file, void *_fh,
                                         struct v4l2_dv_timings *timings)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    struct qpcie_dev *qdev = vch->qdev;
    struct qpcie_hdmi_tlm t;
    u32 status;
    int ret;

    if (vch->channel_id != 0)
        return -ENOTTY;

    if (!qdev || !qdev->bar0_mmio)
        return -ENODEV;

    status = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);
    if (!(status & HDMI_RX_STATUS_5V_DET))
        return -ENOLINK;

    ret = qpcie_hdmi_read_telemetry(qdev, &t);
    if (ret)
        return ret;

    if (!(t.flags & HDMI_TLM_F_TIMING_VALID))
        return -ENODATA;
    if (!qpcie_hdmi_telemetry_fresh(qdev, t.heartbeat)) {
        dev_warn_ratelimited(&qdev->pdev->dev,
                             "HDMI RX telemetry publisher stalled (heartbeat=%u)\n",
                             t.heartbeat);
        return -ENODATA;
    }
    if (!t.width || !t.height || !t.pixelclock)
        return -ENODATA;

    memset(timings, 0, sizeof(*timings));
    timings->type = V4L2_DV_BT_656_1120;
    timings->bt.width = t.width;
    timings->bt.height = t.height;
    timings->bt.interlaced = (t.flags & HDMI_TLM_F_INTERLACED) ?
                             V4L2_DV_INTERLACED : V4L2_DV_PROGRESSIVE;
    timings->bt.pixelclock = t.pixelclock;
    timings->bt.hfrontporch = t.hfp;
    timings->bt.hsync = t.hsw;
    timings->bt.hbackporch = t.hbp;
    timings->bt.vfrontporch = t.vfp;
    timings->bt.vsync = t.vsw;
    timings->bt.vbackporch = t.vbp;
    timings->bt.polarities = t.polarities;
    timings->bt.standards = t.standards;
    if (t.standards & V4L2_DV_BT_STD_CEA861)
        timings->bt.flags |= V4L2_DV_FL_IS_CE_VIDEO;
    return 0;
}

static int qpcie_vidioc_g_dv_timings(struct file *file, void *_fh,
                                     struct v4l2_dv_timings *timings)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    if (vch->channel_id != 0)
        return -ENOTTY;
    return qpcie_vidioc_query_dv_timings(file, _fh, timings);
}

static int qpcie_vidioc_s_dv_timings(struct file *file, void *_fh,
                                     struct v4l2_dv_timings *timings)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    if (vch->channel_id != 0)
        return -ENOTTY;
    if (vb2_is_busy(&vch->queue))
        return -EBUSY;
    if (timings->type != V4L2_DV_BT_656_1120)
        return -EINVAL;
    vch->width = timings->bt.width;
    vch->height = timings->bt.height;
    vch->stride = (vch->pixelformat == V4L2_PIX_FMT_RGB24) ?
                  ALIGN(vch->width * 3, 128) : ALIGN(vch->width, 128);
    return 0;
}

static int qpcie_vidioc_dv_timings_cap(struct file *file, void *_fh,
                                       struct v4l2_dv_timings_cap *cap)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    if (vch->channel_id != 0)
        return -ENOTTY;

    memset(cap, 0, sizeof(*cap));
    cap->type = V4L2_DV_BT_656_1120;
    cap->bt.min_width = 640;
    cap->bt.max_width = 4096;
    cap->bt.min_height = 480;
    cap->bt.max_height = 2160;
    cap->bt.min_pixelclock = 25000000ULL;
    cap->bt.max_pixelclock = 600000000ULL;
    cap->bt.standards = V4L2_DV_BT_STD_CEA861 | V4L2_DV_BT_STD_DMT;
    cap->bt.capabilities = V4L2_DV_BT_CAP_PROGRESSIVE;
    return 0;
}

static int qpcie_vidioc_subscribe_event(struct v4l2_fh *fh,
                                        const struct v4l2_event_subscription *sub)
{
    switch (sub->type) {
    case V4L2_EVENT_FRAME_SYNC:
        return v4l2_event_subscribe(fh, sub, 16, NULL);
    case V4L2_EVENT_SOURCE_CHANGE:
        return v4l2_src_change_event_subscribe(fh, sub);
    case V4L2_EVENT_CTRL:
        return v4l2_ctrl_subscribe_event(fh, sub);
    default:
        return -EINVAL;
    }
}

static int qpcie_vidioc_enum_input(struct file *file, void *priv, struct v4l2_input *inp)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);

    if (inp->index > 0)
        return -EINVAL;
    inp->type = V4L2_INPUT_TYPE_CAMERA;
    inp->std = 0;
    if (vch && vch->channel_id != 0) {
        inp->capabilities = 0;
        strscpy(inp->name, "VCU Hardware Stream", sizeof(inp->name));
    } else {
        inp->capabilities = V4L2_IN_CAP_DV_TIMINGS;
        strscpy(inp->name, "HDMI / TPG Input", sizeof(inp->name));
    }
    return 0;
}

static int qpcie_vidioc_g_input(struct file *file, void *priv, unsigned int *i)
{
    *i = 0;
    return 0;
}

static int qpcie_vidioc_s_input(struct file *file, void *priv, unsigned int i)
{
    if (i != 0)
        return -EINVAL;
    return 0;
}

static const struct v4l2_ioctl_ops qpcie_v4l2_ioctl_ops = {
    .vidioc_querycap                = qpcie_vidioc_querycap,
    .vidioc_enum_input              = qpcie_vidioc_enum_input,
    .vidioc_g_input                 = qpcie_vidioc_g_input,
    .vidioc_s_input                 = qpcie_vidioc_s_input,
    .vidioc_enum_fmt_vid_cap        = qpcie_vidioc_enum_fmt_vid_cap_mplane,
    .vidioc_g_fmt_vid_cap           = qpcie_vidioc_g_fmt_vid_cap,
    .vidioc_try_fmt_vid_cap         = qpcie_vidioc_try_fmt_vid_cap,
    .vidioc_s_fmt_vid_cap           = qpcie_vidioc_s_fmt_vid_cap,
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

    /* Digital Video (DV) Timings IOCTLs (HDMI RX Ch0) */
    .vidioc_query_dv_timings        = qpcie_vidioc_query_dv_timings,
    .vidioc_g_dv_timings            = qpcie_vidioc_g_dv_timings,
    .vidioc_s_dv_timings            = qpcie_vidioc_s_dv_timings,
    .vidioc_dv_timings_cap          = qpcie_vidioc_dv_timings_cap,

    /* Videobuf2 Buffer Management IOCTLs (MMAP, USERPTR, DMABUF) */
    .vidioc_reqbufs                 = vb2_ioctl_reqbufs,
    .vidioc_querybuf                = vb2_ioctl_querybuf,
    .vidioc_qbuf                    = vb2_ioctl_qbuf,
    .vidioc_dqbuf                   = vb2_ioctl_dqbuf,
    .vidioc_prepare_buf             = vb2_ioctl_prepare_buf,
    .vidioc_create_bufs             = vb2_ioctl_create_bufs,

    /* DMA-BUF Export Buffer IOCTL */
    .vidioc_expbuf                  = vb2_ioctl_expbuf,

    /* Sub-Frame Low-Latency Slice DMA & Source Change V4L2 Event Subscription */
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
    struct qpcie_dev *qdev = vch->qdev;
    unsigned int exp_planes;
    unsigned int y_size, uv_size;

    if (vch->channel_id == 1) {
        unsigned int comp_size = 4 * 1024 * 1024;

        /* A fresh queue setup is a fresh capture session: the Card<->Host clock
         * offset is only valid while both sides keep running, so drop the
         * calibration and re-derive it from the first PTS of this session. */
        vch->vcu_offset_calibrated = false;
        vch->vcu_card_to_host_offset_ns = 0;

        /* Reconfiguring buffers means a fresh capture session and happens
         * before any QBUF, so this is the place to make the Host Ring pointers
         * agree again.  host_head lives in BRAM and survives session teardown
         * (and even driver reload, since the PS owns that BRAM): if the
         * previous session left host_head ahead of ps_tail, every QBUF of the
         * new session computes a huge in_flight and is rejected as Ring Full
         * (-ENOSPC) forever.  Snap host_head onto ps_tail so the new session
         * starts from a provably empty ring. */
        if (qdev->c2h_only && qdev->bar0_mmio) {
            void __iomem *ring_mmio = qdev->bar0_mmio + QPCIE_BAR0_VCU_RING_OFFSET;
            u32 ps_tail = ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring, ps_tail));

            iowrite32(ps_tail, ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));
            ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));

            dev_info(&qdev->pdev->dev,
                     "VCU Host Ring session reset: host_head <- ps_tail=%u\n",
                     ps_tail);
        }

        if (*nplanes) {
            if (*nplanes != 1 || sizes[0] < 65536)
                return -EINVAL;
            return 0;
        }
        *nplanes = 1;
        sizes[0] = comp_size;
        if (qdev->c2h_only) {
            /* The PS VCU keeps a full QPCIE_VCU_RING_SIZE-deep ring in flight
         * and its MSI is coalesced across several frames, so one interrupt can
         * retire up to 16 buffers at once.  If userspace (GStreamer) allocated
         * fewer buffers than the ring holds, the completed buffers have nowhere
         * to go: the ring fills, publish is rejected and frames are dropped.
         * Force at least the full ring depth so the host can always absorb a
         * coalesced burst.
         *
         * The pool is now deliberately DEEPER than the 16-slot hardware ring.
         * A QBUF that finds the ring momentarily full is no longer thrown back
         * at userspace as VB2_BUF_STATE_ERROR (a 0-byte hole in the H.264
         * stream: lost slices, "Frame num change", MB decode errors); it is
         * parked on vch->pending_buffers and republished by the next
         * completion.  Those parked buffers have to come out of the vb2 pool,
         * so the pool must be bigger than the ring or GStreamer simply runs
         * out of buffers while it waits.  24 frames ~= 400 ms of 60 fps slack
         * on top of the 16 ring slots; 32 is the ceiling so a deep pool can
         * never mask a genuinely stuck card for more than ~0.5 s. */
            unsigned int requested = *nbuffers;
            unsigned int depth = clamp_t(unsigned int, *nbuffers,
                                         QPCIE_VCU_RING_SIZE,
                                         QPCIE_VCU_RING_SIZE * 2);

            if (depth < QPCIE_VCU_RING_SIZE + 8)
                depth = QPCIE_VCU_RING_SIZE + 8;
            *nbuffers = depth;
            dev_info(&qdev->pdev->dev,
                     "VCU ch1 buffer pool: requested %u -> %u (ring %u + %u parked-slack frames)\n",
                     requested, depth, QPCIE_VCU_RING_SIZE,
                     depth - QPCIE_VCU_RING_SIZE);
        } else {
            *nbuffers = clamp_t(unsigned int, *nbuffers, 4, QPCIE_VCU_RING_SIZE);
        }
        return 0;
    }

    exp_planes = (vch->pixelformat == V4L2_PIX_FMT_RGB24) ? 1 : 2;
    y_size = vch->stride * vch->height;
    uv_size = (vch->pixelformat == V4L2_PIX_FMT_RGB24) ? 0 :
                            vch->stride * (vch->pixelformat == V4L2_PIX_FMT_NV16M ?
                                           vch->height : vch->height / 2);

    if (*nplanes) {
        if (*nplanes != exp_planes)
            return -EINVAL;
        if (sizes[0] < y_size)
            return -EINVAL;
        if (exp_planes == 2 && sizes[1] < uv_size)
            return -EINVAL;
        return 0;
    }

    *nplanes = exp_planes;
    sizes[0] = y_size;
    if (exp_planes == 2)
        sizes[1] = uv_size;
    *nbuffers = clamp_t(unsigned int, *nbuffers,
                       (vch->channel_id == 0 && exp_planes == 2) ?
                       clamp_t(unsigned int, sc7f0_nv_min_buffers, 2, 8) : 2, 8);
    return 0;
}

static int qpcie_buf_prepare(struct vb2_buffer *vb)
{
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    int i;

    if (vch->channel_id == 1) {
        if (vb2_plane_size(vb, 0) < 65536) {
            v4l2_err(&vch->qdev->v4l2_dev,
                     "Plane 0 size %lu < min required 65536\n",
                     vb2_plane_size(vb, 0));
            return -EINVAL;
        }
        /* No DMA has run yet: the payload is unknown, so stage 0 bytes.
         * Staging the full plane size (4MiB) here would let a buffer that is
         * never filled - or that retires with an error - export 4MiB of stale
         * page content to userspace.  The real length is applied at completion
         * from the DPC1 record (or the last-packet CSR fallback). */
        vb2_set_plane_payload(vb, 0, 0);
        return 0;
    }

    /* Validate plane size for MMAP, USERPTR, and DMABUF memory modes */
    for (i = 0; i < vb->num_planes; i++) {
        unsigned long size = (i == 0) ? (vch->stride * vch->height) :
                             vch->stride * (vch->pixelformat == V4L2_PIX_FMT_NV16M ?
                                            vch->height : vch->height / 2);

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

    buf->sgl_logged = false;
    buf->vcu_slot_idx = 0;
    buf->vcu_seq = 0;
    return 0;
}

static void qpcie_buf_cleanup(struct vb2_buffer *vb)
{
}

/*
 * Build a 4KiB-slot host SGL table for one NV12 plane.
 *
 * Each DMA-mapped scatterlist segment is represented by one SGL entry.  The
 * C2H packetizer splits PCIe writes at 4KiB IOVA boundaries, so splitting a
 * contiguous mapping here would only inflate the table.  A slot holds at most
 * 255 data entries; entry index 255 is reserved for the chain pointer to the
 * next slot.  The last data entry of the plane carries SGL_FLAG_LAST_SEG.
 *
 * Returns 0 on success (with the data-entry and chain counts filled in) or a
 * negative error when the plane cannot fit within @max_slots; on error the
 * table contents are undefined and must not be published.
 */
static int qpcie_publish_buffer(struct qpcie_v4l2_channel *vch,
                                struct qpcie_v4l2_buffer *buf)
{
    struct vb2_buffer *vb = &buf->vb.vb2_buf;
    struct qpcie_dev *qdev = vch->qdev;
    struct scatterlist *sg;
    struct sg_table *sgt0, *sgt1;
    unsigned int i;
    unsigned long flags;
    u32 thin_tail;
    u32 entries_added = 0;
    bool is_rgb;

    if (vch->channel_id == 1 && qdev->c2h_only) {
        void __iomem *ring_mmio = qdev->bar0_mmio + QPCIE_BAR0_VCU_RING_OFFSET;
        u32 host_head = ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));
        u32 ps_tail = ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring, ps_tail));
        u32 slot_idx = host_head % QPCIE_VCU_RING_SIZE;
        u32 next_head = host_head + 1;
        s32 in_flight = (s32)(next_head - ps_tail);
        void __iomem *slot_mmio;
        dma_addr_t dma_addr;
        u32 dma_len;

        if (in_flight <= 0) {
            /* ps_tail ran ahead of host_head (driver reload or PS/driver
             * pointer desync): the naive unsigned difference would underflow
             * into a huge value and reject every QBUF with -ENOSPC forever.
             * Snap host_head back onto ps_tail so the ring recovers health. */
            dev_warn(&qdev->pdev->dev,
                     "VCU Host Ring resync: host_head=%u behind ps_tail=%u; snapping to tail\n",
                     host_head, ps_tail);
            host_head = ps_tail;
            next_head = host_head + 1;
            slot_idx = host_head % QPCIE_VCU_RING_SIZE;
            in_flight = 1;
        }

        if (in_flight > QPCIE_VCU_RING_SIZE) {
            /* Back-pressure, not a fault: all 16 slots are handed to the card.
             * The caller parks the buffer on pending_buffers (QBUF) or leaves
             * it queued for the next completion (drain) - a buffer is NEVER
             * errored out on this path any more. */
            dev_warn_ratelimited(&qdev->pdev->dev,
                                 "VCU Host Ring full (head=%u, tail=%u, in_flight=%d): parking publisher, no buffer dropped\n",
                                 host_head, ps_tail, in_flight);
            return -ENOSPC;
        }

        sgt0 = vb2_dma_sg_plane_desc(vb, 0);
        if (WARN_ON(!sgt0 || sgt0->nents == 0))
            return -EINVAL;
        sg = sgt0->sgl;
        dma_addr = sg_dma_address(sg);
        dma_len = sg_dma_len(sg);

        slot_mmio = ring_mmio + offsetof(struct qpcie_vcu_host_ring, slots) +
                    slot_idx * sizeof(struct qpcie_vcu_buffer_slot);

        iowrite32(lower_32_bits(dma_addr), slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_phys_addr));
        iowrite32(upper_32_bits(dma_addr), slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_phys_addr) + 4);

        if (vch->comp_ring_dma) {
            dma_addr_t comp_addr = vch->comp_ring_dma + slot_idx * 64;
            iowrite32(lower_32_bits(comp_addr), slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_comp_addr));
            iowrite32(upper_32_bits(comp_addr), slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_comp_addr) + 4);
        } else {
            iowrite32(0, slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_comp_addr));
            iowrite32(0, slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_comp_addr) + 4);
        }

        iowrite32(dma_len, slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_buf_len));
        iowrite32(vb->index, slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, host_buf_id));
        iowrite32(0, slot_mmio + offsetof(struct qpcie_vcu_buffer_slot, flags));

        wmb();
        iowrite32(next_head, ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));
        ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));

        buf->vcu_slot_idx = slot_idx;
        /* Remember which ring sequence this buffer owns so the completion
         * path can ask the card PS whether the slot has already been
         * consumed even when its DPC1 record never arrived. */
        buf->vcu_seq = host_head;

        spin_lock_irqsave(&vch->slock, flags);
        list_add_tail(&buf->list, &vch->active_buffers);
        spin_unlock_irqrestore(&vch->slock, flags);

        if (!buf->sgl_logged) {
            dev_info(&qdev->pdev->dev,
                     "VCU Ring buf%u queued (slot %u, phys=0x%llx len=%u, head: %u -> %u)\n",
                     vb->index, slot_idx, (unsigned long long)dma_addr, dma_len, host_head, next_head);
            buf->sgl_logged = true;
        }
        return 0;
    }

    if (!vch->thin_ring_virt) {
        dev_err(&qdev->pdev->dev, "V4L2 ch%d: thin ring not configured\n", vch->channel_id);
        return -EINVAL;
    }

    thin_tail = vch->thin_ring_tail;
    is_rgb = (vch->pixelformat == V4L2_PIX_FMT_RGB24 ||
              vch->pixelformat == V4L2_PIX_FMT_H264 ||
              vch->pixelformat == V4L2_PIX_FMT_HEVC);

    sgt0 = vb2_dma_sg_plane_desc(vb, 0);
    if (WARN_ON(!sgt0))
        return -EINVAL;

    for_each_sg(sgt0->sgl, sg, sgt0->nents, i) {
        u32 slot = (thin_tail + entries_added) % RING_BUFFER_SIZE;
        vch->thin_ring_virt[slot].phys_addr = sg_dma_address(sg);
        vch->thin_ring_virt[slot].len_bytes = sg_dma_len(sg);
        vch->thin_ring_virt[slot].flags     = 0;
        entries_added++;
    }

    if (!is_rgb && vch->thin_ring1_virt) {
        u32 thin_tail1 = vch->thin_ring1_tail;
        u32 entries_added1 = 0;

        sgt1 = vb2_dma_sg_plane_desc(vb, 1);
        if (WARN_ON(!sgt1))
            return -EINVAL;

        for_each_sg(sgt1->sgl, sg, sgt1->nents, i) {
            u32 slot = (thin_tail1 + entries_added1) % RING_BUFFER_SIZE;
            vch->thin_ring1_virt[slot].phys_addr = sg_dma_address(sg);
            vch->thin_ring1_virt[slot].len_bytes = sg_dma_len(sg);
            vch->thin_ring1_virt[slot].flags     = 0;
            entries_added1++;
        }

        vch->thin_ring1_tail = (thin_tail1 + entries_added1) % RING_BUFFER_SIZE;
    }

    spin_lock_irqsave(&vch->slock, flags);
    list_add_tail(&buf->list, &vch->active_buffers);
    spin_unlock_irqrestore(&vch->slock, flags);

    /* Descriptor data must be globally visible before ringing doorbell */
    dma_wmb();
    vch->thin_ring_tail = (thin_tail + entries_added) % RING_BUFFER_SIZE;
    iowrite32((vch->thin_ring_tail << 16) | RING_BUFFER_SIZE,
              qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_CFG);
    ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_CFG);

    if (!is_rgb && vch->thin_ring1_virt) {
        iowrite32((vch->thin_ring1_tail << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_CFG);
        ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_CFG);
    }
    qdev->ring_published++;

    if (!buf->sgl_logged) {
        dev_info(&qdev->pdev->dev,
                 "Thin-SGL ch%d %s buf%u: %u descriptors queued (tail: %u -> %u, size=%u)\n",
                 vch->channel_id, is_rgb ? "RGB24" : "NV12M", vb->index, entries_added,
                 thin_tail, vch->thin_ring_tail, RING_BUFFER_SIZE);
        for (i = 0; i < entries_added; i++) {
            u32 slot = (thin_tail + i) % RING_BUFFER_SIZE;
            dev_info(&qdev->pdev->dev,
                     "  buf%u desc%u: phys=0x%llx len=%u\n",
                     vb->index, i,
                     (unsigned long long)vch->thin_ring_virt[slot].phys_addr,
                     vch->thin_ring_virt[slot].len_bytes);
        }
        buf->sgl_logged = true;
    }
    return 0;
}

/* Lifetime telemetry for the parked-buffer path: how many QBUFs found the
 * 16-slot VCU Host Ring full and were parked instead of being errored out. */
static atomic_t qpcie_vcu_ring_parks = ATOMIC_INIT(0);
static atomic_t qpcie_vcu_park_republished = ATOMIC_INIT(0);

/*
 * Republish buffers that a previous QBUF had to park because the VCU Host Ring
 * was full.
 *
 * qpcie_buf_queue() parks a ch1 QBUF on vch->pending_buffers rather than
 * calling vb2_buffer_done(VB2_BUF_STATE_ERROR): an ERROR completion hands
 * GStreamer a 0-byte payload, and one hole in the H.264 byte stream costs the
 * decoder a slice ("Frame num change from 8 to 9", "decode_slice_header
 * error", "top block unavailable for requested intra mode") plus visible
 * macroblock corruption until the next IDR.  Every slot this function
 * publishes is a frame that reaches userspace intact.
 *
 * Locking: called with no locks held.  It takes qdev->ring_lock for the whole
 * loop because qpcie_publish_buffer() writes the shared BRAM ring pointers and
 * takes vch->slock internally, so the ordering stays ring_lock -> slock, the
 * very same order qpcie_buf_queue() uses.  Callers must therefore never hold
 * vch->slock here (qpcie_v4l2_node_done() drops it first), otherwise an IRQ on
 * another CPU could invert the two locks.
 *
 * A rejected publish means the ring filled up again: the buffer is put back at
 * the head of the list so QBUF order (and therefore ring slot order) is
 * preserved, and the attempt is repeated on the next completion.
 */
static void qpcie_vcu_drain_pending(struct qpcie_v4l2_channel *vch)
{
    struct qpcie_dev *qdev = vch->qdev;
    unsigned long flags;
    int published = 0;

    if (vch->channel_id != 1 || !qdev->c2h_only || !qdev->bar0_mmio)
        return;

    spin_lock_irqsave(&qdev->ring_lock, flags);
    while (!list_empty(&vch->pending_buffers)) {
        struct qpcie_v4l2_buffer *pbuf =
            list_first_entry(&vch->pending_buffers,
                             struct qpcie_v4l2_buffer, list);

        /* Unlink BEFORE publishing: qpcie_publish_buffer() relinks this very
         * list_head into vch->active_buffers on success, so a list_del() after
         * the call would rip the freshly queued buffer straight back out of the
         * active list and wedge its completion. */
        list_del_init(&pbuf->list);
        if (qpcie_publish_buffer(vch, pbuf)) {
            list_add(&pbuf->list, &vch->pending_buffers);
            break;
        }
        published++;
    }
    spin_unlock_irqrestore(&qdev->ring_lock, flags);

    if (published) {
        atomic_add(published, &qpcie_vcu_park_republished);
        dev_dbg(&qdev->pdev->dev,
                "VCU Host Ring: republished %u parked buffer(s) (lifetime parks=%d republished=%d)\n",
                published, atomic_read(&qpcie_vcu_ring_parks),
                atomic_read(&qpcie_vcu_park_republished));
    }
}

static void qpcie_buf_queue(struct vb2_buffer *vb)
{
    struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
    struct qpcie_v4l2_buffer *buf =
        container_of(vbuf, struct qpcie_v4l2_buffer, vb);
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vb->vb2_queue);
    struct qpcie_dev *qdev = vch->qdev;
    struct qpcie_v4l2_channel *out_vch, *cap_vch;
    struct qpcie_v4l2_buffer *out_buf, *cap_buf, *pbuf;
    unsigned long flags;
    unsigned int depth;
    int ret;

    if (vch->channel_id == 0 || (qdev->c2h_only && vch->channel_id == 1)) {
        spin_lock_irqsave(&qdev->ring_lock, flags);
        ret = qpcie_publish_buffer(vch, buf);
        if (ret == -ENOSPC && vch->channel_id == 1 && qdev->c2h_only) {
            /* Ring temporarily full: PARK the buffer, never error it.
             *
             * -ENOSPC is not a buffer fault, it is back-pressure from a ring
             * that is 16 slots deep and full for a microsecond.  The buffer is
             * healthy, mapped, prepared and empty - exactly what the next free
             * slot needs.  Erroing it here was the direct cause of the periodic
             * stall + macroblock corruption: GStreamer received a 0-byte
             * buffer, h264parse lost a slice and ffmpeg/vah264dec reported
             * "Frame num change", "decode_slice_header error" and "top block
             * unavailable" while the picture broke up.
             *
             * Parked buffers stay in QBUF order on vch->pending_buffers and are
             * republished by qpcie_vcu_drain_pending() the moment a completion
             * frees a slot.  Harvest + drain below, which also covers a lost or
             * coalesced MSI for this very QBUF. */
            list_add_tail(&buf->list, &vch->pending_buffers);

            /* A park that clears on the next completion is normal back-pressure.
             * A deep parked queue means the card stopped consuming the ring at
             * all, which is a genuine stall - say so instead of hiding it. */
            depth = 0;
            list_for_each_entry(pbuf, &vch->pending_buffers, list)
                depth++;
            spin_unlock_irqrestore(&qdev->ring_lock, flags);

            if (atomic_inc_return(&qpcie_vcu_ring_parks) <= 4)
                dev_info(&qdev->pdev->dev,
                         "VCU ch1 buf%u: ring busy, parked in QBUF order (park#%d)\n",
                         vb->index, atomic_read(&qpcie_vcu_ring_parks));
            if (depth >= 8)
                dev_warn_ratelimited(&qdev->pdev->dev,
                                     "VCU ch1: %u QBUFs parked, card is not consuming the Host Ring\n",
                                     depth);

            qpcie_v4l2_node_done(qdev, 1);
            return;
        }
        spin_unlock_irqrestore(&qdev->ring_lock, flags);
        if (ret) {
            dev_err(&qdev->pdev->dev,
                    "V4L2 ch%u buf%u: descriptor publish rejected (%d)\n",
                    vch->channel_id, buf->vb.vb2_buf.index, ret);
            /* Nothing was ever written into this buffer: never hand the
             * staged payload of the VCU stream channel to userspace. */
            if (vch->channel_id == 1)
                vb2_set_plane_payload(&buf->vb.vb2_buf, 0, 0);
            vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_ERROR);
        } else if (vch->channel_id == 1 && qdev->c2h_only) {
            /* Opportunistic completion harvest in process context.  MSI
             * coalescing (and lost VCH1 interrupts) can leave already-completed
             * DPC1 slots sitting on active_buffers until the next interrupt
             * arrives; harvesting here bounds that latency.  Must run outside
             * ring_lock: node_done takes vch->slock and retires buffers.  It
             * also drains this channel's parked buffers. */
            qpcie_v4l2_node_done(qdev, 1);
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

/* Initial QBUF publishes descriptors before start_streaming validates HDMI.
 * On a pre-enable rejection, cancel those doorbells BEFORE returning buffers;
 * otherwise the next STREAMON can fetch addresses from already-freed buffers.
 * This helper is only called before this start attempt enables the channel.
 */
static void qpcie_cancel_unstarted_rings(struct qpcie_v4l2_channel *vch)
{
    struct qpcie_dev *qdev = vch->qdev;
    u32 head;

    if (!vch->thin_ring_virt)
        return;
    head = ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_HEAD) & 0xffff;
    vch->thin_ring_head = vch->thin_ring_tail = head;
    iowrite32((head << 16) | RING_BUFFER_SIZE,
              qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_CFG);
    ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_CFG);
    if (vch->thin_ring1_virt) {
        head = ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_HEAD) & 0xffff;
        vch->thin_ring1_head = vch->thin_ring1_tail = head;
        iowrite32((head << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_CFG);
        ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_CFG);
    }
}

static int qpcie_start_streaming(struct vb2_queue *vq, unsigned int count)
{
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vq);
    struct qpcie_dev *qdev = vch->qdev;
    u32 pacer_ctrl;
    bool is_tpg_source = false;
    bool convert_rgb = false;
    int ret;

    if (vch->channel_id == 1 && qdev->c2h_only) {
        atomic_inc(&qdev->streaming_count);
        dev_info(&qdev->pdev->dev,
                 "VCU STREAMON (Node 1): %u buffers queued, ring size=%u (parked republish armed)\n",
                 count, QPCIE_VCU_RING_SIZE);
        /* QBUFs that arrived before STREAMON (or that raced the session ring
         * reset) may already be parked; give them their first slot now. */
        qpcie_vcu_drain_pending(vch);
        return 0;
    }

    if (count < 2) {
        qpcie_cancel_unstarted_rings(vch);
        qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
        return -ENOBUFS;
    }

    /* Refuse to start a real HDMI capture that cannot work: no input, no
     * locked timing, or a stalled telemetry publisher must fail STREAMON
     * instead of silently DMA-ing invalid geometry to the host. */
    if (vch->channel_id == 0 && vch->video_source != 1) {
        u32 st = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);
        bool want_hdmi = (vch->video_source == 2) ||
                         (vch->video_source == 0 && (st & HDMI_RX_STATUS_5V_DET));

        if (want_hdmi) {
            int src_err = 0;

            if (!qpcie_hdmi_source_ready(vch, &src_err)) {
                if (src_err == -ERANGE)
                    dev_err(&qdev->pdev->dev,
                            "STREAMON refused: requested %ux%u does not match locked HDMI timing; use QUERY_DV_TIMINGS and S_FMT to match the source\n",
                            vch->width, vch->height);
                else
                    dev_err(&qdev->pdev->dev,
                            "STREAMON refused: HDMI RX source not ready (5V=0x%08x, err=%d)\n",
                            st, src_err);
                qpcie_cancel_unstarted_rings(vch);
                qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
                return src_err;
            }
            if (vch->pixelformat != V4L2_PIX_FMT_RGB24) {
                struct qpcie_hdmi_tlm t;

                ret = qpcie_hdmi_read_telemetry(qdev, &t);
                if (ret) {
                    qpcie_cancel_unstarted_rings(vch);
                    qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
                    return ret;
                }
                convert_rgb = ((t.color_fmt >> 24) & 0xf) == 0;
            }
            dev_info(&qdev->pdev->dev,
                     "STREAMON: HDMI RX source locked, RGB-to-YUV=%u\n", convert_rgb);
        }
    }

    vch->sequence = 0;
    vch->current_slice_idx = 0;
    vch->error_count_start = ioread32(qdev->bar0_mmio + REG_VIDEO_ERRORS);
    iowrite32(0, qdev->bar0_mmio + REG_VIDEO_CTRL);
    ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);

    /* Only Channel 0 uses the Video Test Pattern Generator (TPG0) & Pacer.
     * Channels 1 and 2 are dedicated hardware loopback and user streaming. */
    if (vch->channel_id == 0) {
        struct v4l2_ctrl *pattern_ctrl;
        struct v4l2_ctrl *motion_ctrl;
        u32 pattern_id;

        iowrite32(0, qdev->bar0_mmio + REG_VIDEO_CTRL);
        ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
        iowrite32(0, qdev->bar0_mmio + REG_SLICE_HEIGHT);
        iowrite32(vch->pacer_enable ? 1 : 0,
                  qdev->bar0_mmio + REG_PACER_CTRL);

        pattern_ctrl = v4l2_ctrl_find(&vch->ctrl_handler,
                                      V4L2_CID_TEST_PATTERN);
        motion_ctrl = v4l2_ctrl_find(&vch->ctrl_handler,
                                     V4L2_CID_QPCIE_TPG_MOTION_SPEED);
        pattern_id = qpcie_tpg_pattern_id(pattern_ctrl ? pattern_ctrl->val : 3);

        is_tpg_source = (vch->video_source == 1) ||
                        (vch->video_source == 0 &&
                         !(ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS) &
                           HDMI_RX_STATUS_5V_DET));

        if (!is_tpg_source) {
            /*
             * REG_VIDEO_SUB_RESET bit 1 also drives the RX subsystem's
             * s_axis_video_aresetn. Resetting a live HDMI receiver at
             * STREAMON needlessly disturbs a locked video path, and the
             * capture engine already re-aligns on the source SOF (tuser).
             * Only reset/reprogram the video path for the internal TPG.
             */
            dev_info(&qdev->pdev->dev,
                     "STREAMON: HDMI source, keeping RX video path out of reset\n");
        } else {
            /* Pulse reset on both TPG (bit 0) and video capture engine/FIFO (bit 1) */
            iowrite32(3, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            usleep_range(1000, 2000);
            iowrite32(0, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            usleep_range(1000, 2000);

            if (qpcie_program_tpg(vch, pattern_id, false)) {
                qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
                return -EIO;
            }
            /* REG_VIDEO_SUB_RESET resets v_tpg controls, so restore the user
             * selected motion state after the TPG configuration is reapplied. */
            ret = qpcie_program_tpg_motion(vch, motion_ctrl ? motion_ctrl->val : 0);
            if (ret) {
                qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
                return ret;
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
    } else {
        pacer_ctrl = 1;
    }

    dma_wmb();
    if (atomic_read(&qdev->streaming_count) == 0) {
        /* Reset for one PCIe clock, then count the complete streaming window. */
        iowrite32(0x03, qdev->bar0_mmio + REG_PERF_CTRL);
        ioread32(qdev->bar0_mmio + REG_PERF_CTRL);
    }

    if (vch->thin_ring_virt) {
        bool is_rgb = (vch->pixelformat == V4L2_PIX_FMT_RGB24 ||
                       vch->pixelformat == V4L2_PIX_FMT_H264 ||
                       vch->pixelformat == V4L2_PIX_FMT_HEVC);
        u32 stride0 = is_rgb ? (vch->stride ? vch->stride : (vch->width * 3)) :
                               (vch->stride ? vch->stride : vch->width);
        u32 stride1 = is_rgb ? 0 :
                               (vch->stride1 ? vch->stride1 : (vch->stride ? vch->stride : vch->width));
        u32 ch_fmt = is_rgb ? 1 : (vch->pixelformat == V4L2_PIX_FMT_NV16M ? 3 : 2);
        u32 ch_ctrl = BIT(0) | (ch_fmt << 4) | BIT(8) |
                      (convert_rgb ? BIT(9) : 0) |
                      ((vch->video_source & 0x3) << 20); /* enable=1, format, irq_en=1, video_source */

        /* Program CH Geometry */
        iowrite32(vch->width, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_WIDTH);
        iowrite32(vch->height, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_HEIGHT);
        iowrite32(stride0, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_STRIDE0);
        iowrite32(stride1, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_STRIDE1);
        iowrite32(vch->overlay_enable ? 1 : 0, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_OVERLAY);
        iowrite32(vch->overlay_enable ? 1 : 0, qdev->bar0_mmio + REG_VIDEO_OVERLAY);

        /* Program RING0 Base Address & CFG with current tail doorbell */
        iowrite32(lower_32_bits(vch->thin_ring_dma),
                  qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_BASE_L);
        iowrite32(upper_32_bits(vch->thin_ring_dma),
                  qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_BASE_H);
        dma_wmb();
        iowrite32((vch->thin_ring_tail << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_CFG);

        /* Program RING1 Base Address & CFG with current tail doorbell if multi-plane */
        if (!is_rgb && vch->thin_ring1_virt) {
            iowrite32(lower_32_bits(vch->thin_ring1_dma),
                      qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_BASE_L);
            iowrite32(upper_32_bits(vch->thin_ring1_dma),
                      qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_BASE_H);
            dma_wmb();
            iowrite32((vch->thin_ring1_tail << 16) | RING_BUFFER_SIZE,
                      qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_CFG);
        }

        /* Set RX packing/CSC mode with descriptor fetching still disabled.
         * Let the mode CDC and idle-drained FIFO settle before the engine can
         * accept SOF; otherwise a format switch could capture a stale marker.
         */
        if (vch->channel_id == 0) {
            iowrite32(ch_ctrl & ~BIT(0), qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
            ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
            usleep_range(1000, 2000);
        }
        /* Enable CH */
        iowrite32(ch_ctrl, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
        ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
    }

    /* Start TPG AFTER DMA is enabled so frame 1 starts cleanly without FIFO backpressure */
    if (vch->channel_id == 0) {
        if (is_tpg_source) {
            if (vch->pacer_enable) {
                ret = qpcie_tpg_pace_start(qdev);
                if (ret) {
                    dev_err(&qdev->pdev->dev,
                            "Cannot start TPG pacing kthread: %d\n", ret);
                    iowrite32(0, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
                    qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
                    return ret;
                }
            } else {
                void __iomem *tpg = qdev->bar1_mmio + qdev->bar1_offset_tpg;
                iowrite32(0x81, tpg + 0x00); /* Continuous AUTO_RESTART */
            }
        }
    }

    atomic_inc(&qdev->streaming_count);
    dev_info(&qdev->pdev->dev,
             "NV12M STREAMON (Ch%u %s): %u buffers, ring tail=%u, mode=%ux%u %s (pacer=0x%08x, active_streams=%d)\n",
             vch->channel_id,
             (vch->buf_type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) ? "Output" : "Capture",
             count, vch->thin_ring_tail, vch->width, vch->height,
             vch->pacer_enable ? "60 FPS paced" :
                                 "uncapped DMA benchmark",
             pacer_ctrl, atomic_read(&qdev->streaming_count));
    return 0;
}

static void qpcie_stop_streaming(struct vb2_queue *vq)
{
    struct qpcie_v4l2_channel *vch = vb2_get_drv_priv(vq);
    struct qpcie_dev *qdev = vch->qdev;
    unsigned long timeout = jiffies + msecs_to_jiffies(500);
    bool drained = false;
    bool last_stream;
    u32 head = 0;
    u32 stat_reg = vch->ch_reg_base + REG_VCH_OFFSET_STATUS;

    if (vch->channel_id == 1 && qdev->c2h_only) {
        /* The Card<->Host offset of this session is no longer meaningful once
         * streaming stops: force re-calibration on the next session. */
        vch->vcu_offset_calibrated = false;

        qpcie_return_all_buffers(vch, VB2_BUF_STATE_ERROR);

        /* The buffers are back in userspace, so this session owns nothing any
         * more - but host_head/ps_tail in BRAM still carry its unfinished
         * in_flight difference.  Align host_head onto ps_tail here so a dead
         * session cannot hand a full ring to the next STREAMON. */
        if (qdev->bar0_mmio) {
            void __iomem *ring_mmio = qdev->bar0_mmio + QPCIE_BAR0_VCU_RING_OFFSET;
            u32 ps_tail = ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring, ps_tail));

            iowrite32(ps_tail, ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));
            ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));

            dev_info(&qdev->pdev->dev,
                     "VCU Host Ring STREAMOFF reset: host_head <- ps_tail=%u\n",
                     ps_tail);
        }

        atomic_dec(&qdev->streaming_count);
        dev_info(&qdev->pdev->dev,
                 "VCU STREAMOFF (Node 1): ring parks=%d republished=%d\n",
                 atomic_read(&qpcie_vcu_ring_parks),
                 atomic_read(&qpcie_vcu_park_republished));
        return;
    }

    /*
     * Ordering is the whole point of this function: the card must be provably
     * done writing into these buffers BEFORE they are handed back to userspace.
     * Returning them first (as this code used to do) lets a still-running DMA
     * write into memory the next STREAMON may have already re-queued.
     */

    /* 1. Stop the frame source so no new frame enters the pipeline. */
    if (vch->channel_id == 0 && qdev->bar1_mmio && !qdev->c2h_only) {
        void __iomem *tpg = qdev->bar1_mmio + qdev->bar1_offset_tpg;

        qpcie_tpg_pace_stop(qdev);
        iowrite32(0x00, tpg + 0x00);
    }

    /* 2. Stop descriptor fetch without switching the mux in mid-frame. */
    iowrite32(ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL) & ~BIT(0),
              qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
    ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);

    /* 3. Wait for in-flight C2H writes to retire. */
    if (vch->channel_id == 0) {
        do {
            u32 status = ioread32(qdev->bar0_mmio + stat_reg);

            if (status & DMA_STATUS_VIDEO_TX_IDLE) {
                drained = true;
                break;
            }
            usleep_range(1000, 2000);
        } while (time_before(jiffies, timeout));

        /* Only abort with a reset when the graceful drain failed. The reset
         * touches the shared capture engine, so it must not be issued while
         * the drain already proved there is nothing in flight. */
        if (!drained) {
            dev_warn(&qdev->pdev->dev,
                     "NV12M STREAMOFF Ch0 drain timeout; pulsing video sub-reset\n");
            iowrite32(3, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            usleep_range(1000, 2000);
            iowrite32(0, qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            ioread32(qdev->bar0_mmio + REG_VIDEO_SUB_RESET);
            timeout = jiffies + msecs_to_jiffies(500);
            do {
                u32 status = ioread32(qdev->bar0_mmio + stat_reg);

                if ((status & (DMA_STATUS_VIDEO_TX_IDLE |
                               DMA_STATUS_DESC_IDLE)) ==
                    (DMA_STATUS_VIDEO_TX_IDLE | DMA_STATUS_DESC_IDLE)) {
                    drained = true;
                    break;
                }
                usleep_range(1000, 2000);
            } while (time_before(jiffies, timeout));
        }
    } else {
        usleep_range(2000, 5000);
        drained = true;
    }

    last_stream = (atomic_read(&qdev->streaming_count) <= 1);

    /* No new completion IRQ can be generated for a disabled, drained channel,
     * but one may already be running for a buffer we are about to return. Let
     * it finish before the buffers become visible to userspace again. */
    synchronize_irq(qdev->irq);

    /* 4. Global engine quiesce. This is what actually guarantees no further
     *    PCIe writes to any buffer of any channel, so it happens before the
     *    buffers are returned. */
    if (last_stream) {
        iowrite32(0, qdev->bar0_mmio + REG_PACER_CTRL);
        qpcie_dma_soft_reset(qdev);
        qpcie_reprogram_rings(qdev);
        /* Freeze counters after all channel-0 writes have retired. */
        iowrite32(0, qdev->bar0_mmio + REG_PERF_CTRL);
        ioread32(qdev->bar0_mmio + REG_PERF_CTRL);
        synchronize_irq(qdev->irq);
        qdev->ring_published = 0;
        qdev->ring_completed = 0;
        qdev->ring_rejects = 0;
    }

    /* 5. Cancel descriptors and rebase this channel's producer pointers. */
    if (vch->thin_ring_virt) {
        head = ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_HEAD) & 0xffff;
        vch->thin_ring_tail = head;
        vch->thin_ring_head = head;
        iowrite32((head << 16) | RING_BUFFER_SIZE,
                  qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_CFG);
        ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING0_CFG);
        if (vch->thin_ring1_virt) {
            u32 head1 = ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_HEAD) & 0xffff;
            vch->thin_ring1_tail = head1;
            vch->thin_ring1_head = head1;
            iowrite32((head1 << 16) | RING_BUFFER_SIZE,
                      qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_CFG);
            ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_RING1_CFG);
        }
    }

    /* 6. The card can no longer touch these buffers: return them now. */
    qpcie_return_all_buffers(vch, VB2_BUF_STATE_ERROR);
    atomic_dec(&qdev->streaming_count);

    if (!last_stream) {
        dev_info(&qdev->pdev->dev,
                 "NV12M STREAMOFF (Ch%u): stream stopped, remaining active streams: %d\n",
                 vch->channel_id, atomic_read(&qdev->streaming_count));
        return;
    }

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
                 "NV12M STREAMOFF: drained=%u head=%u video_errors=%u\n",
                 drained, head, errors);
    }
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
    "Solid Black",
    "Solid White",
    NULL
};

void qpcie_vcu_sync_config(struct qpcie_v4l2_channel *vch)
{
    struct qpcie_dev *qdev;
    void __iomem *target;
    const u32 *words;
    int i, count;

    if (!vch || vch->channel_id != 1)
        return;
    qdev = vch->qdev;
    if (!qdev || !qdev->bar0_mmio || !qdev->c2h_only)
        return;

    vch->vcu_cfg.magic = QPCIE_VCU_CFG_MAGIC;
    vch->vcu_cfg.version = 1;
    vch->vcu_cfg.config_seq++;

    /* The whole mailbox is mirrored word-by-word below, so the Card-side
     * pacer knobs land on their advertised offsets (0xBC / 0xC0 inside
     * QPCIE_BAR0_VCU_CFG_OFFSET, i.e. BAR0 0x21BC / 0x21C0).  Fail the build
     * if the mailbox layout ever shifts under these comments. */
    BUILD_BUG_ON(offsetof(struct qpcie_vcu_encoder_config, pacer_enable) !=
                 QPCIE_VCU_CFG_PACER_ENABLE_OFFSET);
    BUILD_BUG_ON(offsetof(struct qpcie_vcu_encoder_config, pacer_buffer_frames) !=
                 QPCIE_VCU_CFG_PACER_BUFFER_FRAMES_OFFSET);

    target = qdev->bar0_mmio + QPCIE_BAR0_VCU_CFG_OFFSET;
    words = (const u32 *)&vch->vcu_cfg;
    count = sizeof(struct qpcie_vcu_encoder_config) / sizeof(u32);

    for (i = 0; i < count; i++)
        iowrite32(words[i], target + (i * 4));

    /* Memory barrier and PCIe write flush */
    wmb();
    ioread32(target);
}

static int qpcie_s_ctrl(struct v4l2_ctrl *ctrl)
{
    struct qpcie_v4l2_channel *vch = container_of(ctrl->handler, struct qpcie_v4l2_channel, ctrl_handler);
    struct qpcie_dev *qdev = vch->qdev;

    switch (ctrl->id) {
    case V4L2_CID_MPEG_VIDEO_BITRATE_MODE:
        vch->vcu_cfg.bitrate_mode = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_BITRATE:
        vch->vcu_cfg.bitrate = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_BITRATE_PEAK:
        vch->vcu_cfg.bitrate_peak = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_FRAME_RC_ENABLE:
        vch->vcu_cfg.frame_rc_enable = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_MB_RC_ENABLE:
        vch->vcu_cfg.mb_rc_enable = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_CONSTANT_QUALITY:
        vch->vcu_cfg.const_quality = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_GOP_SIZE:
        vch->vcu_cfg.gop_size = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_B_FRAMES:
        vch->vcu_cfg.b_frames = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME:
        vch->vcu_cfg.force_idr = 1;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_REPEAT_SEQ_HEADER:
        vch->vcu_cfg.repeat_seq_header = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEADER_MODE:
        vch->vcu_cfg.header_mode = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_PROFILE:
        vch->vcu_cfg.h264_profile = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_LEVEL:
        vch->vcu_cfg.h264_level = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_ENTROPY_MODE:
        vch->vcu_cfg.h264_entropy_mode = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_MIN_QP:
        vch->vcu_cfg.h264_min_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_MAX_QP:
        vch->vcu_cfg.h264_max_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP:
        vch->vcu_cfg.h264_i_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_P_FRAME_QP:
        vch->vcu_cfg.h264_p_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_B_FRAME_QP:
        vch->vcu_cfg.h264_b_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_CPB_SIZE:
        vch->vcu_cfg.h264_cpb_size = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_LOOP_FILTER_MODE:
        vch->vcu_cfg.h264_loop_filter_mode = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_H264_8X8_TRANSFORM:
        vch->vcu_cfg.h264_8x8_transform = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_PROFILE:
        vch->vcu_cfg.hevc_profile = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_LEVEL:
        vch->vcu_cfg.hevc_level = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_TIER:
        vch->vcu_cfg.hevc_tier = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_MIN_QP:
        vch->vcu_cfg.hevc_min_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_MAX_QP:
        vch->vcu_cfg.hevc_max_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_I_FRAME_QP:
        vch->vcu_cfg.hevc_i_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_P_FRAME_QP:
        vch->vcu_cfg.hevc_p_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_B_FRAME_QP:
        vch->vcu_cfg.hevc_b_qp = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_LOOP_FILTER_MODE:
        vch->vcu_cfg.hevc_loop_filter_mode = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_REFRESH_TYPE:
        vch->vcu_cfg.hevc_refresh_type = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_STRONG_SMOOTHING:
        vch->vcu_cfg.hevc_strong_smoothing = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_CONST_INTRA_PRED:
        vch->vcu_cfg.hevc_const_intra_pred = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_HEVC_WAVEFRONT:
        vch->vcu_cfg.hevc_wavefront = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_MULTI_SLICE_MODE:
        vch->vcu_cfg.slice_mode = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_MULTI_SLICE_MAX_BYTES:
        vch->vcu_cfg.slice_max_bytes = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_MULTI_SLICE_MAX_MB:
        vch->vcu_cfg.slice_max_mb = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_MPEG_VIDEO_CYCLIC_INTRA_REFRESH_MB:
        vch->vcu_cfg.intra_refresh_mb = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_QPCIE_VCU_PACER_ENABLE:
        if (vch->vcu_cfg.pacer_enable == (u32)ctrl->val)
            break;
        vch->vcu_cfg.pacer_enable = !!ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
    case V4L2_CID_QPCIE_VCU_PACER_BUFFER_FRAMES:
        if (vch->vcu_cfg.pacer_buffer_frames == (u32)ctrl->val)
            break;
        vch->vcu_cfg.pacer_buffer_frames = ctrl->val;
        qpcie_vcu_sync_config(vch);
        break;
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
    case V4L2_CID_QPCIE_TPG_MOTION_SPEED:
        if (vb2_is_streaming(&vch->queue))
            return -EBUSY;
        return qpcie_program_tpg_motion(vch, ctrl->val);
    case V4L2_CID_QPCIE_TPG_OVERLAY:
        vch->overlay_enable = !!ctrl->val;
        if (qdev && qdev->bar0_mmio) {
            if (vch->ch_reg_base)
                iowrite32(vch->overlay_enable ? 1 : 0, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_OVERLAY);
            iowrite32(vch->overlay_enable ? 1 : 0, qdev->bar0_mmio + REG_VIDEO_OVERLAY);
            ioread32(qdev->bar0_mmio + REG_VIDEO_OVERLAY);
        }
        break;
    case V4L2_CID_QPCIE_VIDEO_SOURCE:
        if (qdev->c2h_only && ctrl->val != 2)
            return -EOPNOTSUPP;
        /* The mux selector crosses as a quasi-static level. Switching source
         * inside a frame would splice two rasters into one host buffer. */
        if (vb2_is_streaming(&vch->queue) && vch->video_source != ctrl->val)
            return -EBUSY;
        vch->video_source = ctrl->val;
        if (qdev && qdev->bar0_mmio && vch->ch_reg_base) {
            u32 cur_ctrl = ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
            cur_ctrl &= ~(0x3 << 20);
            cur_ctrl |= ((vch->video_source & 0x3) << 20);
            iowrite32(cur_ctrl, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
            ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);

            if (vb2_is_streaming(&vch->queue) && vch->channel_id == 0) {
                bool is_tpg = (vch->video_source == 1) ||
                              (vch->video_source == 0 && !(ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS) & HDMI_RX_STATUS_5V_DET));
                if (is_tpg && vch->pacer_enable)
                    qpcie_tpg_pace_start(qdev);
                else
                    qpcie_tpg_pace_stop(qdev);
            }
        }
        break;
    }
    return 0;
}

static int qpcie_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
    struct qpcie_v4l2_channel *vch =
        container_of(ctrl->handler, struct qpcie_v4l2_channel, ctrl_handler);
    struct qpcie_dev *qdev = vch->qdev;

    if (ctrl->id != V4L2_CID_QPCIE_FRAME_DROP_COUNT)
        return 0;
    if (!qdev || !qdev->bar0_mmio)
        return -ENODEV;

    ctrl->val = ioread32(qdev->bar0_mmio + REG_VIDEO_ERRORS) & INT_MAX;
    return 0;
}

static const struct v4l2_ctrl_ops qpcie_ctrl_ops = {
    .s_ctrl = qpcie_s_ctrl,
    .g_volatile_ctrl = qpcie_g_volatile_ctrl,
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

/* Card-side hardware pacer for the Channel 1 VCU output bitstream.  Instead of
 * pushing every finished frame onto the link immediately, the pacer meters the
 * stream out; the buffer depth says how many encoded frames may accumulate
 * before pacing kicks in.  Both values are delivered to the Card through the
 * VCU configuration mailbox (BAR0 + 0x21BC / + 0x21C0). */
static const struct v4l2_ctrl_config qpcie_vcu_pacer_enable_ctrl_config = {
    .ops  = &qpcie_ctrl_ops,
    .id   = V4L2_CID_QPCIE_VCU_PACER_ENABLE,
    .name = "VCU Pacer Enable",
    .type = V4L2_CTRL_TYPE_BOOLEAN,
    .min  = 0,
    .max  = 1,
    .step = 1,
    .def  = 1,
};

static const struct v4l2_ctrl_config qpcie_vcu_pacer_buffer_frames_ctrl_config = {
    .ops  = &qpcie_ctrl_ops,
    .id   = V4L2_CID_QPCIE_VCU_PACER_BUFFER_FRAMES,
    .name = "VCU Pacer Buffer Frames",
    .type = V4L2_CTRL_TYPE_INTEGER,
    .min  = 0,
    .max  = 30,
    .step = 1,
    .def  = 8,
};

static const struct v4l2_ctrl_config qpcie_tpg_motion_ctrl_config = {
    .ops  = &qpcie_ctrl_ops,
    .id   = V4L2_CID_QPCIE_TPG_MOTION_SPEED,
    .name = "QPCIe TPG Motion Speed (0=Static)",
    .type = V4L2_CTRL_TYPE_INTEGER,
    .min  = 0,
    .max  = 255,
    .step = 1,
    .def  = 0,
};

static const struct v4l2_ctrl_config qpcie_frame_drop_ctrl_config = {
    .ops   = &qpcie_ctrl_ops,
    .id    = V4L2_CID_QPCIE_FRAME_DROP_COUNT,
    .name  = "QPCIe TPG Frame Drop Count",
    .type  = V4L2_CTRL_TYPE_INTEGER,
    .min   = 0,
    .max   = INT_MAX,
    .step  = 1,
    .def   = 0,
    .flags = V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE,
};

static const struct v4l2_ctrl_config qpcie_tpg_overlay_ctrl_config = {
    .ops  = &qpcie_ctrl_ops,
    .id   = V4L2_CID_QPCIE_TPG_OVERLAY,
    .name = "QPCIe TPG Marker Overlay",
    .type = V4L2_CTRL_TYPE_BOOLEAN,
    .min  = 0,
    .max  = 1,
    .step = 1,
    .def  = 0,
};

static const char * const qpcie_video_source_strings[] = {
    "Auto (HDMI RX / TPG Fallback)",
    "Force TPG",
    "Force HDMI RX",
    NULL
};

static const struct v4l2_ctrl_config qpcie_video_source_ctrl_config = {
    .ops   = &qpcie_ctrl_ops,
    .id    = V4L2_CID_QPCIE_VIDEO_SOURCE,
    .name  = "QPCIe Video Input Source",
    .type  = V4L2_CTRL_TYPE_MENU,
    .min   = 0,
    .max   = 2,
    .def   = 0,
    .qmenu = qpcie_video_source_strings,
};

void qpcie_v4l2_check_source_change(struct qpcie_v4l2_channel *vch)
{
    struct qpcie_dev *qdev;
    struct qpcie_hdmi_tlm t;
    u32 cur_status, cur_res, cur_sig;

    if (!vch || vch->channel_id != 0)
        return;

    qdev = vch->qdev;
    if (!qdev || !qdev->bar0_mmio)
        return;

    cur_status = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);
    if (cur_status == 0xFFFFFFFF)
        return; /* PCIe link offline or unmapped: bail out immediately to prevent Tegra CBB error storm */

    if (qpcie_hdmi_read_telemetry(qdev, &t))
        return; /* torn snapshot or no publisher: retry on the next poll */

    if (t.flags & HDMI_TLM_F_TIMING_VALID)
        cur_res = (t.width << 16) | (t.height & 0xFFFF);
    else
        cur_res = 0;
    cur_sig = (t.mbus_code & 0xFFFF) |
              ((t.flags & (HDMI_TLM_F_TIMING_VALID | HDMI_TLM_F_INTERLACED |
                           HDMI_TLM_F_COLOR_VALID)) << 16);

    if (cur_status != vch->last_rx_status || cur_res != vch->last_rx_res ||
        cur_sig != vch->last_rx_tlm_sig) {
        static const struct v4l2_event ev = {
            .type = V4L2_EVENT_SOURCE_CHANGE,
            .u.src_change.changes = V4L2_EVENT_SRC_CH_RESOLUTION,
        };
        dev_info(&qdev->pdev->dev,
                 "[V4L2 HDMI RX] Source change detected! status: 0x%08x -> 0x%08x, res: 0x%08x -> 0x%08x, tlm: 0x%08x -> 0x%08x\n",
                 vch->last_rx_status, cur_status, vch->last_rx_res, cur_res,
                 vch->last_rx_tlm_sig, cur_sig);
        vch->last_rx_status = cur_status;
        vch->last_rx_res = cur_res;
        vch->last_rx_tlm_sig = cur_sig;
        v4l2_event_queue(&vch->vdev, &ev);
    }
}

static void qpcie_v4l2_hdmi_monitor_work_fn(struct work_struct *work)
{
    struct delayed_work *dwork = to_delayed_work(work);
    struct qpcie_v4l2_channel *vch =
        container_of(dwork, struct qpcie_v4l2_channel, hdmi_monitor_work);

    if (!vch || !vch->hdmi_monitor_running)
        return;

    if (vch->qdev && vch->qdev->pdev && pci_channel_offline(vch->qdev->pdev))
        return;

    qpcie_v4l2_check_source_change(vch);

    if (vch->hdmi_monitor_running)
        schedule_delayed_work(&vch->hdmi_monitor_work, msecs_to_jiffies(250));
}

int qpcie_v4l2_init(struct qpcie_dev *qdev)
{
    u32 hw_caps;
    unsigned int hw_video_ch;
    unsigned int node_count;
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

    hw_caps = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_CAPS);
    hw_video_ch = (hw_caps >> 8) & 0xff;
    if (hw_video_ch == 0) {
        dev_err(&qdev->pdev->dev,
                "[V4L2] FPGA reports no video channels (caps=0x%08x)\n",
                hw_caps);
        return -EOPNOTSUPP;
    }
    if (qdev->c2h_only) {
        node_count = 2; /* Node 0: Raw HDMI capture; Node 1: VCU Stream (Packet DMA) capture */
    } else {
        node_count = 1 + (2 * min(hw_video_ch - 1,
                                  (unsigned int)(NUM_VIDEO_CHANNELS - 1)));
    }
    dev_info(&qdev->pdev->dev,
             "[V4L2] FPGA capability check passed: %u video channels, registering %u node(s) (caps=0x%08x)\n",
             hw_video_ch, node_count, hw_caps);

    dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.1] Registering top-level v4l2_device...\n");
    spin_lock_init(&qdev->ring_lock);
    atomic_set(&qdev->streaming_count, 0);
    snprintf(qdev->v4l2_dev.name, sizeof(qdev->v4l2_dev.name), "qpcie-v4l2");
    ret = v4l2_device_register(&qdev->pdev->dev, &qdev->v4l2_dev);
    if (ret) {
        dev_err(&qdev->pdev->dev, "[DEBUG ERROR] v4l2_device_register failed: %d\n", ret);
        return ret;
    }

    /* Bring up the V4L2 nodes advertised by hardware:
     * - /dev/video0: Channel 0 TPG Hardware Video Capture
     * - /dev/video1/2: Channel 1 Loopback Output/Capture
     * - /dev/video3/4: Channel 2 Loopback Output/Capture
     * - /dev/video5/6: Channel 3 Loopback Output/Capture */
    for (i = 0; i < node_count; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        struct video_device *vdev = &vch->vdev;

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.2] Initializing Video Node %d...\n", i);
        vch->qdev       = qdev;
        vch->width      = 1920;
        vch->height     = 1080;
        vch->stride     = 1920;
        vch->pixelformat= V4L2_PIX_FMT_NV12M;
        vch->pacer_enable = true;
        if (qdev->c2h_only)
            vch->video_source = 2; /* No automatic TPG fallback. */

        if (i == 0) {
            vch->channel_id = 0;
            vch->buf_type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        } else if (i == 1) {
            vch->channel_id = 1;
            vch->buf_type   = qdev->c2h_only ?
                V4L2_BUF_TYPE_VIDEO_CAPTURE :
                V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
            if (qdev->c2h_only) {
                vch->pixelformat = V4L2_PIX_FMT_H264;
                vch->width = 3840;
                vch->height = 2160;
                vch->stride = 0;
            }
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

        vch->ch_reg_base = REG_VCH_BASE(vch->channel_id);

        mutex_init(&vch->lock);
        spin_lock_init(&vch->slock);
        INIT_LIST_HEAD(&vch->pending_buffers);
        INIT_LIST_HEAD(&vch->active_buffers);

        /* Initialize V4L2 Control Handler */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.3] Node %d: Initializing Control Handler...\n", i);
        if (i == 1 && qdev->c2h_only) {
            v4l2_ctrl_handler_init(&vch->ctrl_handler, 47);
            /* Standard V4L2 Rate Control */
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_BITRATE_MODE,
                                   V4L2_MPEG_VIDEO_BITRATE_MODE_CQ, 0,
                                   V4L2_MPEG_VIDEO_BITRATE_MODE_CBR);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_BITRATE,
                              25000, 100000000, 1000, 25000000);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_BITRATE_PEAK,
                              25000, 120000000, 1000, 30000000);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_FRAME_RC_ENABLE,
                              0, 1, 1, 1);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_MB_RC_ENABLE,
                              0, 1, 1, 1);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_CONSTANT_QUALITY,
                              0, 51, 1, 28);

            /* Standard V4L2 GOP & Framing */
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_GOP_SIZE,
                              1, 300, 1, 60);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_B_FRAMES,
                              0, 4, 1, 0);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME,
                              0, 0, 0, 0);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_REPEAT_SEQ_HEADER,
                              0, 1, 1, 1);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_HEADER_MODE,
                                   V4L2_MPEG_VIDEO_HEADER_MODE_JOINED_WITH_1ST_FRAME, 0,
                                   V4L2_MPEG_VIDEO_HEADER_MODE_JOINED_WITH_1ST_FRAME);

            /* Standard V4L2 H.264 Controls */
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_H264_PROFILE,
                                   V4L2_MPEG_VIDEO_H264_PROFILE_HIGH,
                                   ~((1 << V4L2_MPEG_VIDEO_H264_PROFILE_BASELINE) |
                                     (1 << V4L2_MPEG_VIDEO_H264_PROFILE_CONSTRAINED_BASELINE) |
                                     (1 << V4L2_MPEG_VIDEO_H264_PROFILE_MAIN) |
                                     (1 << V4L2_MPEG_VIDEO_H264_PROFILE_HIGH)),
                                   V4L2_MPEG_VIDEO_H264_PROFILE_HIGH);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_H264_LEVEL,
                                   V4L2_MPEG_VIDEO_H264_LEVEL_5_2, 0,
                                   V4L2_MPEG_VIDEO_H264_LEVEL_5_1);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_H264_ENTROPY_MODE,
                                   V4L2_MPEG_VIDEO_H264_ENTROPY_MODE_CABAC, 0,
                                   V4L2_MPEG_VIDEO_H264_ENTROPY_MODE_CABAC);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_H264_MIN_QP,
                              0, 51, 1, 10);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_H264_MAX_QP,
                              0, 51, 1, 51);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP,
                              0, 51, 1, 26);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_H264_P_FRAME_QP,
                              0, 51, 1, 28);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_H264_B_FRAME_QP,
                              0, 51, 1, 30);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_H264_CPB_SIZE,
                              64, 100000, 64, 10000);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_H264_LOOP_FILTER_MODE,
                                   V4L2_MPEG_VIDEO_H264_LOOP_FILTER_MODE_DISABLED_AT_SLICE_BOUNDARY, 0,
                                   V4L2_MPEG_VIDEO_H264_LOOP_FILTER_MODE_ENABLED);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_H264_8X8_TRANSFORM,
                              0, 1, 1, 1);

            /* Standard V4L2 HEVC / H.265 Controls */
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_HEVC_PROFILE,
                                   V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN_10, 0,
                                   V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_HEVC_LEVEL,
                                   V4L2_MPEG_VIDEO_HEVC_LEVEL_6_2, 0,
                                   V4L2_MPEG_VIDEO_HEVC_LEVEL_5_1);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_HEVC_TIER,
                                   V4L2_MPEG_VIDEO_HEVC_TIER_HIGH, 0,
                                   V4L2_MPEG_VIDEO_HEVC_TIER_MAIN);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_MIN_QP,
                              0, 51, 1, 10);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_MAX_QP,
                              0, 51, 1, 51);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_I_FRAME_QP,
                              0, 51, 1, 26);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_P_FRAME_QP,
                              0, 51, 1, 28);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_B_FRAME_QP,
                              0, 51, 1, 30);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_HEVC_LOOP_FILTER_MODE,
                                   V4L2_MPEG_VIDEO_HEVC_LOOP_FILTER_MODE_DISABLED_AT_SLICE_BOUNDARY, 0,
                                   V4L2_MPEG_VIDEO_HEVC_LOOP_FILTER_MODE_ENABLED);
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_HEVC_REFRESH_TYPE,
                                   V4L2_MPEG_VIDEO_HEVC_REFRESH_IDR, 0,
                                   V4L2_MPEG_VIDEO_HEVC_REFRESH_IDR);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_STRONG_SMOOTHING,
                              0, 1, 1, 1);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_CONST_INTRA_PRED,
                              0, 1, 1, 0);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_HEVC_WAVEFRONT,
                              0, 1, 1, 1);

            /* Slicing & Resilience */
            v4l2_ctrl_new_std_menu(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                   V4L2_CID_MPEG_VIDEO_MULTI_SLICE_MODE,
                                   V4L2_MPEG_VIDEO_MULTI_SLICE_MODE_MAX_BYTES, 0,
                                   V4L2_MPEG_VIDEO_MULTI_SLICE_MODE_SINGLE);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_MULTI_SLICE_MAX_BYTES,
                              0, 65535, 1, 0);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_MULTI_SLICE_MAX_MB,
                              0, 65535, 1, 0);
            v4l2_ctrl_new_std(&vch->ctrl_handler, &qpcie_ctrl_ops,
                              V4L2_CID_MPEG_VIDEO_CYCLIC_INTRA_REFRESH_MB,
                              0, 8192, 1, 0);

            /* Card-side hardware output pacer (VCU mailbox 0xBC / 0xC0) */
            v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                 &qpcie_vcu_pacer_enable_ctrl_config, NULL);
            v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                 &qpcie_vcu_pacer_buffer_frames_ctrl_config,
                                 NULL);

            /* Populate default struct values */
            vch->vcu_cfg.magic = QPCIE_VCU_CFG_MAGIC;
            vch->vcu_cfg.version = 1;
            vch->vcu_cfg.codec_type = (vch->pixelformat == V4L2_PIX_FMT_HEVC) ? 1 : 0;
            vch->vcu_cfg.bitrate_mode = V4L2_MPEG_VIDEO_BITRATE_MODE_CBR;
            vch->vcu_cfg.bitrate = 25000000;
            vch->vcu_cfg.bitrate_peak = 30000000;
            vch->vcu_cfg.frame_rc_enable = 1;
            vch->vcu_cfg.mb_rc_enable = 1;
            vch->vcu_cfg.const_quality = 28;
            vch->vcu_cfg.gop_size = 60;
            vch->vcu_cfg.b_frames = 0;
            vch->vcu_cfg.force_idr = 0;
            vch->vcu_cfg.repeat_seq_header = 1;
            vch->vcu_cfg.header_mode = V4L2_MPEG_VIDEO_HEADER_MODE_JOINED_WITH_1ST_FRAME;
            vch->vcu_cfg.h264_profile = V4L2_MPEG_VIDEO_H264_PROFILE_HIGH;
            vch->vcu_cfg.h264_level = V4L2_MPEG_VIDEO_H264_LEVEL_5_1;
            vch->vcu_cfg.h264_entropy_mode = V4L2_MPEG_VIDEO_H264_ENTROPY_MODE_CABAC;
            vch->vcu_cfg.h264_min_qp = 10;
            vch->vcu_cfg.h264_max_qp = 51;
            vch->vcu_cfg.h264_i_qp = 26;
            vch->vcu_cfg.h264_p_qp = 28;
            vch->vcu_cfg.h264_b_qp = 30;
            vch->vcu_cfg.h264_cpb_size = 10000;
            vch->vcu_cfg.h264_loop_filter_mode = V4L2_MPEG_VIDEO_H264_LOOP_FILTER_MODE_ENABLED;
            vch->vcu_cfg.h264_8x8_transform = 1;
            vch->vcu_cfg.hevc_profile = V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN;
            vch->vcu_cfg.hevc_level = V4L2_MPEG_VIDEO_HEVC_LEVEL_5_1;
            vch->vcu_cfg.hevc_tier = V4L2_MPEG_VIDEO_HEVC_TIER_MAIN;
            vch->vcu_cfg.hevc_min_qp = 10;
            vch->vcu_cfg.hevc_max_qp = 51;
            vch->vcu_cfg.hevc_i_qp = 26;
            vch->vcu_cfg.hevc_p_qp = 28;
            vch->vcu_cfg.hevc_b_qp = 30;
            vch->vcu_cfg.hevc_loop_filter_mode = V4L2_MPEG_VIDEO_HEVC_LOOP_FILTER_MODE_ENABLED;
            vch->vcu_cfg.hevc_refresh_type = V4L2_MPEG_VIDEO_HEVC_REFRESH_IDR;
            vch->vcu_cfg.hevc_strong_smoothing = 1;
            vch->vcu_cfg.hevc_const_intra_pred = 0;
            vch->vcu_cfg.hevc_wavefront = 1;
            vch->vcu_cfg.slice_mode = V4L2_MPEG_VIDEO_MULTI_SLICE_MODE_SINGLE;
            vch->vcu_cfg.slice_max_bytes = 0;
            vch->vcu_cfg.slice_max_mb = 0;
            vch->vcu_cfg.intra_refresh_mb = 0;
            vch->vcu_cfg.pacer_enable = 1;
            vch->vcu_cfg.pacer_buffer_frames = 8;
            qpcie_vcu_sync_config(vch);

            /* Allocate DPC1 completion record ring for Channel 1 */
            vch->comp_ring_virt = dma_alloc_coherent(&qdev->pdev->dev,
                                                     QPCIE_VCU_RING_SIZE * 64,
                                                     &vch->comp_ring_dma, GFP_KERNEL);
            if (vch->comp_ring_virt)
                memset(vch->comp_ring_virt, 0, QPCIE_VCU_RING_SIZE * 64);
            if (qdev->bar0_mmio) {
                void __iomem *ring_mmio = qdev->bar0_mmio + QPCIE_BAR0_VCU_RING_OFFSET;
                iowrite32(QPCIE_VCU_RING_MAGIC, ring_mmio + offsetof(struct qpcie_vcu_host_ring, magic));
                iowrite32(1, ring_mmio + offsetof(struct qpcie_vcu_host_ring, version));
                iowrite32(QPCIE_VCU_RING_SIZE, ring_mmio + offsetof(struct qpcie_vcu_host_ring, ring_size));
                iowrite32(0, ring_mmio + offsetof(struct qpcie_vcu_host_ring, host_head));
                iowrite32(0, ring_mmio + offsetof(struct qpcie_vcu_host_ring, ps_tail));
                iowrite32(0, ring_mmio + offsetof(struct qpcie_vcu_host_ring, dropped_count));
            }
        } else {
            v4l2_ctrl_handler_init(&vch->ctrl_handler, i == 0 ? 6 : 1);
            if (i == 0 && !qdev->c2h_only) {
                v4l2_ctrl_new_std_menu_items(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                             V4L2_CID_TEST_PATTERN,
                                             6, BIT(0), 3, qpcie_tpg_pattern_strings);
                v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                     &qpcie_tpg_motion_ctrl_config, NULL);
                v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                     &qpcie_frame_drop_ctrl_config, NULL);
                v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                     &qpcie_tpg_overlay_ctrl_config, NULL);
                v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                     &qpcie_video_source_ctrl_config, NULL);
            }
            if (i == 0 && qdev->c2h_only) {
                struct v4l2_ctrl_config source = qpcie_video_source_ctrl_config;

                source.def = 2;
                source.menu_skip_mask = BIT(0) | BIT(1);
                v4l2_ctrl_new_custom(&vch->ctrl_handler, &source, NULL);
            }
            v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                 &qpcie_pacer_ctrl_config, NULL);
        }
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
        vch->queue.min_queued_buffers = (vch->channel_id == 1) ? 8 : 2;
#else
        vch->queue.min_buffers_needed = (vch->channel_id == 1) ? 8 : 2;
#endif
        ret = vb2_queue_init(&vch->queue);
        if (ret) {
            dev_err(&qdev->pdev->dev, "[DEBUG ERROR] Node %d: vb2_queue_init failed: %d\n", i, ret);
            goto unreg_v4l2;
        }

        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.5] Node %d: Registering Video Device /dev/videoX...\n", i);
        if (i == 0) {
            snprintf(vdev->name, sizeof(vdev->name), "%s",
                     qdev->c2h_only ? "sc7f0-hdmi-raw" : "qpcie-capture-tpg0");
            vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE_MPLANE | V4L2_CAP_STREAMING;
            vdev->vfl_dir     = VFL_DIR_RX;
        } else if (i == 1) {
            if (qdev->c2h_only) {
                snprintf(vdev->name, sizeof(vdev->name), "sc7f0-vcu-stream");
                vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
                vdev->vfl_dir     = VFL_DIR_RX;
            } else {
                snprintf(vdev->name, sizeof(vdev->name), "qpcie-loopback-out1");
                vdev->device_caps = V4L2_CAP_VIDEO_OUTPUT_MPLANE | V4L2_CAP_STREAMING;
                vdev->vfl_dir     = VFL_DIR_TX;
            }
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

    qdev->v4l2_node_count = node_count;
    qdev->v4l2_registered = true;

    /* Start HDMI RX Telemetry & Plug/Unplug Background Monitor on Node 0 (Channel 0) */
    if (node_count > 0 && qdev->bar0_mmio) {
        struct qpcie_v4l2_channel *vch0 = &qdev->v4l2_ch[0];
        struct qpcie_hdmi_tlm tlm0;
        u32 init_w = 0, init_h = 0;

        vch0->last_rx_status = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);
        memset(&tlm0, 0, sizeof(tlm0));
        if (!qpcie_hdmi_read_telemetry(qdev, &tlm0) &&
            (tlm0.flags & HDMI_TLM_F_TIMING_VALID)) {
            init_w = tlm0.width;
            init_h = tlm0.height;
            vch0->last_rx_tlm_sig = (tlm0.mbus_code & 0xFFFF) |
                ((tlm0.flags & (HDMI_TLM_F_TIMING_VALID | HDMI_TLM_F_INTERLACED |
                                HDMI_TLM_F_COLOR_VALID)) << 16);
        }
        vch0->last_rx_res = (init_w << 16) | (init_h & 0xFFFF);
        vch0->hdmi_monitor_running = true;
        INIT_DELAYED_WORK(&vch0->hdmi_monitor_work, qpcie_v4l2_hdmi_monitor_work_fn);
        schedule_delayed_work(&vch0->hdmi_monitor_work, msecs_to_jiffies(100));
        dev_info(&qdev->pdev->dev,
                 "[V4L2 HDMI RX] Background telemetry monitor started (100ms interval, initial status=0x%08x, res=%ux%u)\n",
                 vch0->last_rx_status, init_w, init_h);
    }

    if (node_count == 1)
        dev_info(&qdev->pdev->dev,
                 "[V4L2] single-path node initialized: /dev/video0 (TPG0 RGB24 capture)\n");
    else
        dev_info(&qdev->pdev->dev,
                 "[V4L2] 7 nodes initialized: /dev/video0 (TPG0), video1/2 (Ch1 LB), video3/4 (Ch2 LB), video5/6 (Ch3 LB)\n");
    return 0;

unreg_v4l2:
    if (node_count > 0) {
        struct qpcie_v4l2_channel *vch0 = &qdev->v4l2_ch[0];
        if (vch0->hdmi_monitor_running) {
            vch0->hdmi_monitor_running = false;
            cancel_delayed_work_sync(&vch0->hdmi_monitor_work);
        }
    }
    for (i = 0; i < node_count; i++) {
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

    /* Stop HDMI RX Telemetry Background Monitor */
    if (qdev->v4l2_node_count > 0) {
        struct qpcie_v4l2_channel *vch0 = &qdev->v4l2_ch[0];
        if (vch0->hdmi_monitor_running) {
            vch0->hdmi_monitor_running = false;
            cancel_delayed_work_sync(&vch0->hdmi_monitor_work);
        }
    }

    qdev->v4l2_registered = false;
    for (i = 0; i < qdev->v4l2_node_count; i++) {
        struct qpcie_v4l2_channel *vch = &qdev->v4l2_ch[i];
        if (vch->comp_ring_virt) {
            dma_free_coherent(&qdev->pdev->dev,
                              QPCIE_VCU_RING_SIZE * 64,
                              vch->comp_ring_virt,
                              vch->comp_ring_dma);
            vch->comp_ring_virt = NULL;
        }
        if (video_is_registered(&vch->vdev))
            video_unregister_device(&vch->vdev);
        v4l2_ctrl_handler_free(&vch->ctrl_handler);
    }
    v4l2_device_unregister(&qdev->v4l2_dev);
}

/* "DPC1": magic the PS writes into a slot's 64-byte host completion record
 * once the frame DMA for that VCU ring slot has fully landed in host memory. */
#define QPCIE_VCU_DPC1_MAGIC        0x44504331

void qpcie_v4l2_node_done(struct qpcie_dev *qdev, int node_idx)
{
    struct qpcie_v4l2_channel *vch;
    struct qpcie_v4l2_buffer *buf;
    unsigned long flags;
    bool coalesced;

    if (!qdev || node_idx < 0 || node_idx >= qdev->v4l2_node_count)
        return;

    vch = &qdev->v4l2_ch[node_idx];
    /* Per-slot completion can only be proven where the PS writes a DPC1 record,
     * i.e. the c2h-only VCU stream on channel 1.  Raw video (ch0) and the
     * legacy/loopback paths keep the original one-buffer-per-interrupt path. */
    coalesced = (vch->channel_id == 1 && qdev->c2h_only && vch->comp_ring_virt);

    /* Runs from the MSI hardirq handler: must mask interrupts so a
     * process-context publisher cannot be deadlocked by this IRQ. */
    spin_lock_irqsave(&vch->slock, flags);
    /* The VCU MSI is coalesced: a single interrupt can cover several finished
     * frames.  Retiring only the head buffer per interrupt leaves completed
     * slots queued on active_buffers, starves the vb2 pool (buffer exhaustion
     * stall) and loses frames, so drain every slot whose DPC1 record landed. */
    while (!list_empty(&vch->active_buffers)) {
        u32 actual_len = 0;
        u64 pts_ns = 0;

        buf = list_first_entry(&vch->active_buffers, struct qpcie_v4l2_buffer, list);

        if (coalesced) {
            volatile u32 *comp = (volatile u32 *)((u8 *)vch->comp_ring_virt +
                                                  buf->vcu_slot_idx * 64);

            /* active_buffers is FIFO in publish order, so the head is the
             * oldest slot still in flight: if its completion has not landed,
             * no later slot can have either - stop and wait for the next MSI. */
            if (comp[0] != QPCIE_VCU_DPC1_MAGIC) {
                void __iomem *ring_mmio = qdev->bar0_mmio ?
                    qdev->bar0_mmio + QPCIE_BAR0_VCU_RING_OFFSET : NULL;
                u32 ps_tail = ring_mmio ?
                    ioread32(ring_mmio + offsetof(struct qpcie_vcu_host_ring,
                                                  ps_tail)) : 0;

                /* The card PS increments ps_tail *when it hands slot S to the
                 * Packet DMA engine*, not when the payload has landed: pushing
                 * buffer S advances ps_tail to S + 1, so a frame that is still
                 * in flight on the PCIe C2H DMA shows exactly
                 * (ps_tail - vcu_seq) == 1 while its DPC1 record has not been
                 * written yet.  Treating any ps_tail advance as "slot skipped"
                 * therefore retired healthy frames with VB2_BUF_STATE_ERROR on
                 * the microsecond-long window between the PS push and the DPC1
                 * write - dropped frames plus missing P-frame references (MB
                 * decode errors).  Only a PS that has moved on to genuinely
                 * later frames (>= 2 slots ahead, i.e. at least one further
                 * job submitted after this one while this DPC1 still never
                 * landed) proves the slot is lost for good; retire it with an
                 * error so one dead slot cannot wedge the completion queue (and
                 * starve the vb2 pool).  Anything <= 2 apart is still inside
                 * the normal DMA pipeline: keep waiting for the next MSI or the
                 * DPC1 write. */
                if (ring_mmio && (s32)(ps_tail - buf->vcu_seq) > 2) {
                    dev_warn_ratelimited(&qdev->pdev->dev,
                                         "VCU slot %u (seq %u) skipped by PS (tail %u): completing with ERROR\n",
                                         buf->vcu_slot_idx, buf->vcu_seq, ps_tail);

                    list_del(&buf->list);
                    qdev->ring_completed++;
                    buf->vb.sequence = vch->sequence++;
                    /* Frame DMA failed or its completion was lost: the buffer
                     * content is undefined, so export 0 payload. */
                    vb2_set_plane_payload(&buf->vb.vb2_buf, 0, 0);
                    vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_ERROR);
                    continue;
                }
                break;
            }

            actual_len = comp[10];           /* Transferred Payload Bytes */
            if (comp[6] || comp[7])          /* PTS hi:lo */
                pts_ns = (((u64)comp[7] << 32) | comp[6]) * 1000 / 150;

            /* Re-arm the slot before the buffer can be republished into it. */
            comp[0] = 0;                     /* Clear completion magic */
        }

        list_del(&buf->list);
        qdev->ring_completed++;

        if (!coalesced && vch->channel_id == 1 && qdev->bar0_mmio) {
            /* No completion ring (VCU without DPC1 records): fall back to the
             * last-packet CSRs, which describe the most recent frame only. */
            u32 pts_lo = ioread32(qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_PKT_LAST_PTS_LO);
            u32 pts_hi = ioread32(qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_PKT_LAST_PTS_HI);

            actual_len = ioread32(qdev->bar0_mmio + REG_VCH_BASE(1) + REG_VCH_OFFSET_PKT_LAST_LEN);
            if (pts_lo || pts_hi)
                pts_ns = (((u64)pts_hi << 32) | pts_lo) * 1000 / 150;
        }

        if (vch->channel_id == 1) {
            /* ch1 (VCU compressed bitstream): bytesused comes from the
             * completion only.  A zero-length completion must export 0, never
             * the full plane size staged at buffer_prepare. */
            if (actual_len > 0)
                vb2_set_plane_payload(&buf->vb.vb2_buf, 0, actual_len);
            else
                vb2_set_plane_payload(&buf->vb.vb2_buf, 0, 0);
        } else if (actual_len > 0) {
            vb2_set_plane_payload(&buf->vb.vb2_buf, 0, actual_len);
        }
        if (pts_ns > 0) {
            /* pts_ns is the Card (HDMI RX) capture timestamp, a different clock
             * domain than the Host CLOCK_MONOTONIC that vb2 timestamps use.
             * Calibrate once per session by sampling the instantaneous distance
             * between the two clocks, then shift every Card PTS into the Host
             * domain so downstream (rtcp / muxer / sync) sees monotonic values. */
            if (!vch->vcu_offset_calibrated) {
                vch->vcu_card_to_host_offset_ns = (s64)ktime_get_ns() - (s64)pts_ns;
                vch->vcu_offset_calibrated = true;
                dev_info(&qdev->pdev->dev,
                         "VCU PTS calibrated: Card %llu ns -> Host offset %+lld ns\n",
                         (unsigned long long)pts_ns, (long long)vch->vcu_card_to_host_offset_ns);
            }
            buf->vb.vb2_buf.timestamp = pts_ns + vch->vcu_card_to_host_offset_ns;
        } else {
            buf->vb.vb2_buf.timestamp = ktime_get_ns();
        }

        buf->vb.sequence = vch->sequence++;
        vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_DONE);

        /* Channels without a per-slot completion record signal one frame per
         * interrupt: keep the original single-shot behaviour and leave. */
        if (!coalesced)
            break;
    }
    spin_unlock_irqrestore(&vch->slock, flags);

    /* Harvesting above retired buffers, and every retired buffer freed one
     * VCU Host Ring slot.  QBUFs that found the ring full are parked on
     * pending_buffers waiting for precisely that space, so drain them here:
     * this is what keeps the 16-slot ring saturated instead of starving the
     * card for a frame every time the ring tips over full.  Must run after
     * slock is dropped (qpcie_publish_buffer() takes it) and it takes
     * ring_lock itself in the same order qpcie_buf_queue() uses. */
    if (vch->channel_id == 1 && qdev->c2h_only)
        qpcie_vcu_drain_pending(vch);

    if (node_idx == 0)
        qpcie_v4l2_check_source_change(vch);
}

void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev)
{
    if (qdev && qdev->v4l2_registered)
        qpcie_v4l2_node_done(qdev, 0);
}
