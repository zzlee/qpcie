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
    if (f->index == 0) {
        f->pixelformat = V4L2_PIX_FMT_NV12M;
        return 0;
    }
    if (f->index == 1) {
        f->pixelformat = V4L2_PIX_FMT_RGB24;
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

    tpg = qdev->bar1_mmio + (vch->channel_id * 0x100);
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

    qpcie_fill_pix_format(&f->fmt.pix_mp, &mode, vch->pixelformat, vch->stride);
    return 0;
}

static int qpcie_vidioc_try_fmt_vid_cap_mplane(struct file *file, void *priv,
                                                struct v4l2_format *f)
{
    const struct qpcie_video_mode *mode;
    u32 pixelformat = f->fmt.pix_mp.pixelformat;
    u32 req_stride = f->fmt.pix_mp.plane_fmt[0].bytesperline;

    if (pixelformat != V4L2_PIX_FMT_RGB24)
        pixelformat = V4L2_PIX_FMT_NV12M;

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
    u32 old_width, old_height, old_stride, old_pixelformat;
    u32 pixelformat = f->fmt.pix_mp.pixelformat;
    u32 req_stride = f->fmt.pix_mp.plane_fmt[0].bytesperline;
    int ret;

    if (vb2_is_busy(&vch->queue))
        return -EBUSY;

    if (pixelformat != V4L2_PIX_FMT_RGB24)
        pixelformat = V4L2_PIX_FMT_NV12M;

    mode = qpcie_find_video_mode(f->fmt.pix_mp.width,
                                 f->fmt.pix_mp.height);

    old_width = vch->width;
    old_height = vch->height;
    old_stride = vch->stride;
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
    if (fsize->pixel_format != V4L2_PIX_FMT_NV12M && fsize->pixel_format != V4L2_PIX_FMT_RGB24)
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
    if (fival->pixel_format != V4L2_PIX_FMT_NV12M && fival->pixel_format != V4L2_PIX_FMT_RGB24)
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

static int qpcie_vidioc_query_dv_timings(struct file *file, void *_fh,
                                         struct v4l2_dv_timings *timings)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    struct qpcie_dev *qdev = vch->qdev;
    u32 status, width, height, clk_hz;
    u32 hfp, hsw, hbp, vfp, vsw, vbp, pol, std;

    if (vch->channel_id != 0)
        return -ENODATA;

    if (!qdev || !qdev->bar0_mmio)
        return -ENODEV;

    status = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);
    if (!(status & HDMI_RX_STATUS_5V_DET))
        return -ENOLINK;

    width  = ioread32(qdev->bar0_mmio + REG_HDMI_RX_WIDTH);
    height = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HEIGHT);
    clk_hz = ioread32(qdev->bar0_mmio + REG_HDMI_RX_PIXEL_CLK);

    if (!width || !height) {
        /* Default fallback if uninitialized */
        width  = 1920;
        height = 1080;
        clk_hz = 148500000;
    }

    hfp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HFP);
    hsw = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HSW);
    hbp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HBP);
    vfp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_VFP);
    vsw = ioread32(qdev->bar0_mmio + REG_HDMI_RX_VSW);
    vbp = ioread32(qdev->bar0_mmio + REG_HDMI_RX_VBP);
    pol = ioread32(qdev->bar0_mmio + REG_HDMI_RX_POLARITIES);
    std = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STANDARDS);

    memset(timings, 0, sizeof(*timings));
    timings->type = V4L2_DV_BT_656_1120;
    timings->bt.width = width;
    timings->bt.height = height;
    timings->bt.interlaced = V4L2_DV_PROGRESSIVE;
    timings->bt.pixelclock = clk_hz ? (u64)clk_hz : 148500000ULL;
    timings->bt.hfrontporch = hfp ? hfp : 88;
    timings->bt.hsync = hsw ? hsw : 44;
    timings->bt.hbackporch = hbp ? hbp : 148;
    timings->bt.vfrontporch = vfp ? vfp : 4;
    timings->bt.vsync = vsw ? vsw : 5;
    timings->bt.vbackporch = vbp ? vbp : 36;
    timings->bt.polarities = pol ? pol : (V4L2_DV_VSYNC_POS_POL | V4L2_DV_HSYNC_POS_POL);
    timings->bt.standards = std ? std : V4L2_DV_BT_STD_CEA861;
    timings->bt.flags = V4L2_DV_FL_IS_CE_VIDEO;
    return 0;
}

static int qpcie_vidioc_g_dv_timings(struct file *file, void *_fh,
                                     struct v4l2_dv_timings *timings)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    if (vch->channel_id != 0)
        return -ENODATA;
    return qpcie_vidioc_query_dv_timings(file, _fh, timings);
}

static int qpcie_vidioc_s_dv_timings(struct file *file, void *_fh,
                                     struct v4l2_dv_timings *timings)
{
    struct qpcie_v4l2_channel *vch = video_drvdata(file);
    if (vch->channel_id != 0)
        return -ENODATA;
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
        return -ENODATA;

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
    unsigned int exp_planes = (vch->pixelformat == V4L2_PIX_FMT_RGB24) ? 1 : 2;
    unsigned int y_size = vch->stride * vch->height;
    unsigned int uv_size = (vch->pixelformat == V4L2_PIX_FMT_RGB24) ? 0 : (vch->stride * (vch->height / 2));

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
    *nbuffers = clamp_t(unsigned int, *nbuffers, 2, 8);
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

    buf->sgl_logged = false;
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
    u32 thin_tail;
    u32 entries_added = 0;
    bool is_rgb;

    if (!vch->thin_ring_virt) {
        dev_err(&qdev->pdev->dev, "V4L2 ch%d: thin ring not configured\n", vch->channel_id);
        return -EINVAL;
    }

    thin_tail = vch->thin_ring_tail;
    is_rgb = (vch->pixelformat == V4L2_PIX_FMT_RGB24);

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

    spin_lock(&vch->slock);
    list_add_tail(&buf->list, &vch->active_buffers);
    spin_unlock(&vch->slock);

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
        buf->sgl_logged = true;
    }
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
        /* REG_VIDEO_SUB_RESET resets v_tpg controls, so restore the user
         * selected motion state after the TPG configuration is reapplied. */
        ret = qpcie_program_tpg_motion(vch, motion_ctrl ? motion_ctrl->val : 0);
        if (ret) {
            qpcie_return_all_buffers(vch, VB2_BUF_STATE_QUEUED);
            return ret;
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
        bool is_rgb = (vch->pixelformat == V4L2_PIX_FMT_RGB24);
        u32 stride0 = is_rgb ? (vch->stride ? vch->stride : (vch->width * 3)) :
                               (vch->stride ? vch->stride : vch->width);
        u32 stride1 = is_rgb ? 0 :
                               (vch->stride1 ? vch->stride1 : (vch->stride ? vch->stride : vch->width));
        u32 ch_ctrl = BIT(0) | ((is_rgb ? 1 : 2) << 4) | BIT(8); /* enable=1, format, irq_en=1 */

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

        /* Enable CH */
        iowrite32(ch_ctrl, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
        ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
    }

    /* Start TPG AFTER DMA is enabled so frame 1 starts cleanly without FIFO backpressure */
    if (vch->channel_id == 0) {
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
            void __iomem *tpg = qdev->bar1_mmio + 0x000;
            iowrite32(0x81, tpg + 0x00); /* Continuous AUTO_RESTART */
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
    u32 head;

    qpcie_return_all_buffers(vch, VB2_BUF_STATE_ERROR);

    /* Return any buffers still in active_buffers for this channel */
    {
        struct qpcie_v4l2_buffer *b, *tmp;
        unsigned long flags;

        spin_lock_irqsave(&vch->slock, flags);
        list_for_each_entry_safe(b, tmp, &vch->active_buffers, list) {
            list_del(&b->list);
            vb2_buffer_done(&b->vb.vb2_buf, VB2_BUF_STATE_ERROR);
        }
        spin_unlock_irqrestore(&vch->slock, flags);
    }

    /* Stop fetching descriptors for this channel immediately in hardware */
    iowrite32(0, qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
    ioread32(qdev->bar0_mmio + vch->ch_reg_base + REG_VCH_OFFSET_CTRL);
    u32 stat_reg = vch->ch_reg_base + REG_VCH_OFFSET_STATUS;

    if (vch->channel_id == 0) {
        do {
            u32 status = ioread32(qdev->bar0_mmio + stat_reg);

            if (status & DMA_STATUS_VIDEO_TX_IDLE) {
                drained = true;
                break;
            }
            usleep_range(1000, 2000);
        } while (time_before(jiffies, timeout));

        /* Pulse reset on the video engine and its CDC FIFO before cancelling descriptors */
        iowrite32(1, qdev->bar0_mmio + REG_VIDEO_CTRL);
        ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
        usleep_range(1000, 2000);
        iowrite32(0, qdev->bar0_mmio + REG_VIDEO_CTRL);
        ioread32(qdev->bar0_mmio + REG_VIDEO_CTRL);
        timeout = jiffies + msecs_to_jiffies(500);
        do {
            u32 status = ioread32(qdev->bar0_mmio + stat_reg);

            if ((status & (DMA_STATUS_VIDEO_TX_IDLE |
                           DMA_STATUS_DESC_IDLE)) ==
                (DMA_STATUS_VIDEO_TX_IDLE | DMA_STATUS_DESC_IDLE))
                break;
            usleep_range(1000, 2000);
        } while (time_before(jiffies, timeout));
    } else {
        usleep_range(2000, 5000);
        drained = true;
    }

    /* Cancel descriptors and rebase this channel's producer pointers */
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

    /* Only reset global hardware and stop TPG if ALL active video channels have finished streaming */
    if (atomic_dec_return(&qdev->streaming_count) > 0) {
        dev_info(&qdev->pdev->dev,
                 "NV12M STREAMOFF (Ch%u): stream stopped, remaining active streams: %d\n",
                 vch->channel_id, atomic_read(&qdev->streaming_count));
        return;
    }

    /* All streams idle: halt TPG pacing and stop TPG */
    if (qdev->bar1_mmio) {
        void __iomem *tpg = qdev->bar1_mmio + 0x000;
        qpcie_tpg_pace_stop(qdev);
        iowrite32(0x00, tpg + 0x00);
    }

    iowrite32(0, qdev->bar0_mmio + REG_PACER_CTRL);

    qpcie_dma_soft_reset(qdev);
    qpcie_reprogram_rings(qdev);


    /* Freeze counters after all channel-0 writes have retired. */
    iowrite32(0, qdev->bar0_mmio + REG_PERF_CTRL);
    ioread32(qdev->bar0_mmio + REG_PERF_CTRL);
    synchronize_irq(qdev->irq);

    /* Re-anchor software in-flight counters after every pending completion
     * IRQ has been processed (complete after synchronize_irq to avoid a
     * late IRQ incrementing ring_completed past a zeroed ring_published). */
    qdev->ring_published = 0;
    qdev->ring_completed = 0;
    qdev->ring_rejects = 0;

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

void qpcie_v4l2_check_source_change(struct qpcie_v4l2_channel *vch)
{
    struct qpcie_dev *qdev;
    u32 cur_status, cur_width, cur_height, cur_res;

    if (!vch || vch->channel_id != 0)
        return;

    qdev = vch->qdev;
    if (!qdev || !qdev->bar0_mmio)
        return;

    cur_status = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);
    if (cur_status == 0xFFFFFFFF)
        return; /* PCIe link offline or unmapped: bail out immediately to prevent Tegra CBB error storm */

    cur_width  = ioread32(qdev->bar0_mmio + REG_HDMI_RX_WIDTH);
    cur_height = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HEIGHT);
    cur_res    = (cur_width << 16) | (cur_height & 0xFFFF);

    if (cur_status != vch->last_rx_status || cur_res != vch->last_rx_res) {
        static const struct v4l2_event ev = {
            .type = V4L2_EVENT_SOURCE_CHANGE,
            .u.src_change.changes = V4L2_EVENT_SRC_CH_RESOLUTION,
        };
        dev_info(&qdev->pdev->dev,
                 "[V4L2 HDMI RX] Source change detected! status: 0x%08x -> 0x%08x, res: 0x%08x -> 0x%08x\n",
                 vch->last_rx_status, cur_status, vch->last_rx_res, cur_res);
        vch->last_rx_status = cur_status;
        vch->last_rx_res = cur_res;
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
    node_count = 1 + (2 * min(hw_video_ch - 1,
                              (unsigned int)(NUM_VIDEO_CHANNELS - 1)));
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

        vch->ch_reg_base = REG_VCH_BASE(vch->channel_id);

        mutex_init(&vch->lock);
        spin_lock_init(&vch->slock);
        INIT_LIST_HEAD(&vch->pending_buffers);
        INIT_LIST_HEAD(&vch->active_buffers);

        /* Initialize V4L2 Control Handler */
        dev_info(&qdev->pdev->dev, "[DEBUG STEP 2.3] Node %d: Initializing Control Handler...\n", i);
        v4l2_ctrl_handler_init(&vch->ctrl_handler, i == 0 ? 5 : 1);
        if (i == 0) {
            v4l2_ctrl_new_std_menu_items(&vch->ctrl_handler, &qpcie_ctrl_ops,
                                         V4L2_CID_TEST_PATTERN,
                                         6, BIT(0), 3, qpcie_tpg_pattern_strings);
            v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                 &qpcie_tpg_motion_ctrl_config, NULL);
            v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                 &qpcie_frame_drop_ctrl_config, NULL);
            v4l2_ctrl_new_custom(&vch->ctrl_handler,
                                 &qpcie_tpg_overlay_ctrl_config, NULL);
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

    qdev->v4l2_node_count = node_count;
    qdev->v4l2_registered = true;

    /* Start HDMI RX Telemetry & Plug/Unplug Background Monitor on Node 0 (Channel 0) */
    if (node_count > 0 && qdev->bar0_mmio) {
        struct qpcie_v4l2_channel *vch0 = &qdev->v4l2_ch[0];
        u32 init_w = ioread32(qdev->bar0_mmio + REG_HDMI_RX_WIDTH);
        u32 init_h = ioread32(qdev->bar0_mmio + REG_HDMI_RX_HEIGHT);
        vch0->last_rx_status = ioread32(qdev->bar0_mmio + REG_HDMI_RX_STATUS);
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
        if (video_is_registered(&vch->vdev))
            video_unregister_device(&vch->vdev);
        v4l2_ctrl_handler_free(&vch->ctrl_handler);
    }
    v4l2_device_unregister(&qdev->v4l2_dev);
}

void qpcie_v4l2_node_done(struct qpcie_dev *qdev, int node_idx)
{
    struct qpcie_v4l2_channel *vch;
    struct qpcie_v4l2_buffer *buf;

    if (!qdev || node_idx < 0 || node_idx >= qdev->v4l2_node_count)
        return;

    vch = &qdev->v4l2_ch[node_idx];
    spin_lock(&vch->slock);
    if (!list_empty(&vch->active_buffers)) {
        buf = list_first_entry(&vch->active_buffers, struct qpcie_v4l2_buffer, list);
        list_del(&buf->list);
        qdev->ring_completed++;
        buf->vb.vb2_buf.timestamp = ktime_get_ns();
        buf->vb.sequence = vch->sequence++;
        vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_DONE);
    }
    spin_unlock(&vch->slock);

    if (node_idx == 0)
        qpcie_v4l2_check_source_change(vch);
}

void qpcie_v4l2_irq_handler(struct qpcie_dev *qdev)
{
    if (qdev && qdev->v4l2_registered)
        qpcie_v4l2_node_done(qdev, 0);
}
