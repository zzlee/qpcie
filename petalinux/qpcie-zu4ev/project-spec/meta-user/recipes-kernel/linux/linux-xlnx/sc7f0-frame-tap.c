// SPDX-License-Identifier: GPL-2.0-only
// Passive RX observation + buffer credits/SOF metadata, not a DMA replacement.
#define SC7F0_TAP_IMPLEMENTATION
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/driver.h>
#include <linux/io.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <media/media-entity.h>
#include <media/v4l2-async.h>
#include <media/v4l2-subdev.h>
#include <media/videobuf2-v4l2.h>
#include "sc7f0-frame-tap.h"

#define TAP_STATUS 0x08
#define TAP_CONTROL 0x0c
#define TAP_BUSY BIT(0)
#define TAP_READY BIT(1)
#define TAP_META BIT(2)
#define TAP_ENABLED BIT(3)
#define TAP_RATE 300000000U
#define TAP_ABI 0x00010001U
#define TAP_STOP_REQUEST 0x68
#define TAP_STOP_ACK 0x6c
struct sc7f0_frame_tap {
	struct device *dev;
	void __iomem *regs;
	struct clk *clk;
	struct gpio_chip gpio;
	struct v4l2_subdev sd;
	struct media_pad pads[2];
	struct v4l2_mbus_framefmt format;
	struct mutex lock;
	spinlock_t reg_lock;
	u64 origin_ticks, origin_ns;
	bool streaming, start_unconfirmed, stop_waiting;
	u32 stop_token;
};
static inline struct sc7f0_frame_tap *to_tap(struct v4l2_subdev *sd)
{
	return container_of(sd, struct sc7f0_frame_tap, sd);
}
static int command(struct sc7f0_frame_tap *t, u32 reg, u32 value)
{
	unsigned long f;
	int ret = 0;
	spin_lock_irqsave(&t->reg_lock, f);
	if (!(readl(t->regs + TAP_STATUS) & TAP_READY))
		ret = -EBUSY;
	else
		writel(value, t->regs + reg);
	spin_unlock_irqrestore(&t->reg_lock, f);
	return ret;
}
/* A fresh token, not a sampled enable/busy combination, proves quiescence.
 * Readback also flushes the posted CONTROL write before we poll its ACK. */
static int stop_command(struct sc7f0_frame_tap *t, u32 *token)
{
	unsigned long f;
	int ret = 0;

	spin_lock_irqsave(&t->reg_lock, f);
	if (!(readl(t->regs + TAP_STATUS) & TAP_READY)) {
		ret = -EBUSY;
	} else {
		*token = readl(t->regs + TAP_STOP_REQUEST) + 1;
		writel(0, t->regs + TAP_CONTROL);
		if (readl(t->regs + TAP_STOP_REQUEST) != *token)
			ret = -EIO;
	}
	spin_unlock_irqrestore(&t->reg_lock, f);
	return ret;
}
struct sc7f0_frame_tap *sc7f0_tap_get(struct device *dev)
{
	struct device_node *np;
	struct platform_device *pdev;
	struct sc7f0_frame_tap *t;
	np = of_parse_phandle(dev->of_node, "yuan,frame-tap", 0);
	if (!np)
		return NULL;
	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev)
		return ERR_PTR(-EPROBE_DEFER);
	t = platform_get_drvdata(pdev);
	if (t && !device_link_add(dev, &pdev->dev, DL_FLAG_AUTOREMOVE_CONSUMER))
		t = ERR_PTR(-ENOMEM);
	put_device(&pdev->dev);
	return t ? t : ERR_PTR(-EPROBE_DEFER);
}
EXPORT_SYMBOL_GPL(sc7f0_tap_get);
int sc7f0_tap_credit(struct sc7f0_frame_tap *t, unsigned int n)
{
	if (!t)
		return 0;
	if (!n || n > 65535)
		return -EINVAL;
	return command(t, 0x28, n);
}
EXPORT_SYMBOL_GPL(sc7f0_tap_credit);
int sc7f0_tap_prepare(struct sc7f0_frame_tap *t)
{
	if (!t)
		return 0;
	return READ_ONCE(t->start_unconfirmed) || READ_ONCE(t->stop_waiting) ||
		(readl(t->regs + TAP_STATUS) & (TAP_BUSY | TAP_ENABLED)) ? -EBUSY : 0;
}
EXPORT_SYMBOL_GPL(sc7f0_tap_prepare);
int sc7f0_tap_finish(struct sc7f0_frame_tap *t, struct vb2_v4l2_buffer *b)
{
	unsigned long f;
	u64 tick, ns;
	u32 fid, flags;
	s64 delta;
	if (!t)
		return 0;
	spin_lock_irqsave(&t->reg_lock, f);
	if (!(readl(t->regs + TAP_STATUS) & TAP_META)) {
		spin_unlock_irqrestore(&t->reg_lock, f);
		return -EIO;
	}
	tick = readl(t->regs + 0x40);
	tick |= (u64)readl(t->regs + 0x44) << 32;
	fid = readl(t->regs + 0x48);
	flags = readl(t->regs + 0x4c);
	writel(1, t->regs + 0x1c); /* POP also retires one owned frame. */
	delta = (s64)(tick - t->origin_ticks);
	ns = t->origin_ns;
	spin_unlock_irqrestore(&t->reg_lock, f);
	if (delta < 0)
		return -ERANGE;
	b->vb2_buf.timestamp = ns + mul_u64_u32_div(delta, 1000000000U, TAP_RATE);
	b->sequence = fid;
	if (flags)
		dev_warn_ratelimited(t->dev,
			"Capture source=%u flags=0x%08x (fill=1 eol=2 stop=4 reset=8)\n",
			fid, flags);
	return flags ? -EIO : 0;
}
EXPORT_SYMBOL_GPL(sc7f0_tap_finish);
void sc7f0_tap_abort(struct sc7f0_frame_tap *t)
{
	unsigned long f;
	unsigned int n;
	if (!t)
		return;
	command(t, TAP_CONTROL, 0);
	/* Caller has terminated DMA. Drain available metadata only; never forge
	 * completions/reset unknown AXI ownership to hide a stuck transfer. */
	spin_lock_irqsave(&t->reg_lock, f);
	for (n = 0; n < 16 && (readl(t->regs + TAP_STATUS) & TAP_META); n++)
		writel(1, t->regs + 0x1c);
	spin_unlock_irqrestore(&t->reg_lock, f);
	t->streaming = false;
}
EXPORT_SYMBOL_GPL(sc7f0_tap_abort);
static int tap_stream(struct v4l2_subdev *sd, int on)
{
	struct sc7f0_frame_tap *t = to_tap(sd);
	unsigned long f;
	u64 before, after, tick;
	u32 status, stop_token = 0;
	int ret = 0, n;
	mutex_lock(&t->lock);
	if (on) {
		if (t->start_unconfirmed || t->stop_waiting ||
		    (readl(t->regs + TAP_STATUS) & (TAP_BUSY | TAP_ENABLED))) {
			ret = -EBUSY;
			goto out;
		}
		writel(t->format.width, t->regs + 0x10);
		writel(t->format.height, t->regs + 0x14);
		spin_lock_irqsave(&t->reg_lock, f);
		before = ktime_get_ns();
		tick = readl(t->regs + 0x60); /* low read latches high atomically */
		tick |= (u64)readl(t->regs + 0x64) << 32;
		after = ktime_get_ns();
		t->origin_ticks = tick;
		t->origin_ns = before + (after - before) / 2;
		spin_unlock_irqrestore(&t->reg_lock, f);
	}
	if (on) {
		ret = command(t, TAP_CONTROL, 1);
		if (!ret)
			WRITE_ONCE(t->start_unconfirmed, true);
	} else {
		/* Keep one fence outstanding across timeout/retry. Reissuing stop
		 * forever during a permanent fault would eventually wrap its u32
		 * sequence and could confuse an ancient ACK with a fresh barrier. */
		if (!t->stop_waiting) {
			ret = stop_command(t, &t->stop_token);
			if (!ret)
				WRITE_ONCE(t->stop_waiting, true);
		}
		stop_token = t->stop_token;
	}
	if (ret)
		goto out;
	/* VIPP stops upstream first. Keep CSC and framebuffer running until all
	 * admitted frames have finished DMA and their callback POPs retire them. */
	for (n = 0; n < 100; n++) {
		status = readl(t->regs + TAP_STATUS);
		/* An idle CSR snapshot alone cannot acknowledge a posted ENABLE
		 * when the memory clock stopped before applying that command. */
		if (status & TAP_ENABLED)
			WRITE_ONCE(t->start_unconfirmed, false);
		if (on ? !!(status & TAP_ENABLED) :
		    readl(t->regs + TAP_STOP_ACK) == stop_token)
			break;
		usleep_range(1000, 1500);
	}
	if (n == 100)
		ret = -ETIMEDOUT;
	else {
		t->streaming = !!on;
		/* A source-domain drain barrier also resolves an earlier
		 * unobserved ENABLE (including a stopped/resumed clock). */
		if (!on) {
			WRITE_ONCE(t->start_unconfirmed, false);
			WRITE_ONCE(t->stop_waiting, false);
		}
	}
out:
	mutex_unlock(&t->lock);
	return ret;
}
/*
 * VB2 stop_streaming cannot return an error: its caller will force-reclaim
 * ACTIVE buffers after this callback returns. Returning on a drain timeout,
 * or resetting an active writer to manufacture an idle state, is unsafe.
 *
 * Keep downstream CSC/DMA, callbacks and VB2 ownership alive until admitted
 * frames really retire. An unrecoverable AXI/IRQ fault can therefore leave
 * STREAMOFF/close blocked; this is deliberate fail-stop, not bounded recovery.
 * No busy-spin, forced reset, fake POP or optional-daemon board watchdog feed.
 */
void sc7f0_tap_quiesce(struct sc7f0_frame_tap *t)
{
	int ret;

	if (!t)
		return;
	for (;;) {
		ret = tap_stream(&t->sd, 0);
		if (!ret && !READ_ONCE(t->start_unconfirmed))
			return;
		dev_err_ratelimited(t->dev,
			"Frame drain incomplete (%d, start unconfirmed=%d); holding DMA/buffers, no reset\n",
			ret, READ_ONCE(t->start_unconfirmed));
		msleep(100);
	}
}
EXPORT_SYMBOL_GPL(sc7f0_tap_quiesce);

static bool supported(u32 code)
{
	return code == MEDIA_BUS_FMT_RBG888_1X24 || code == MEDIA_BUS_FMT_VUY8_1X24 ||
	       code == MEDIA_BUS_FMT_UYVY8_1X16 || code == MEDIA_BUS_FMT_VYYUYY8_1X24;
}
static int tap_enum(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
		    struct v4l2_subdev_mbus_code_enum *code)
{
	static const u32 formats[] = { MEDIA_BUS_FMT_RBG888_1X24, MEDIA_BUS_FMT_VUY8_1X24,
		MEDIA_BUS_FMT_UYVY8_1X16, MEDIA_BUS_FMT_VYYUYY8_1X24 };
	if (code->pad > 1 || code->index >= ARRAY_SIZE(formats))
		return -EINVAL;
	code->code = formats[code->index];
	return 0;
}
static int tap_get(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
		   struct v4l2_subdev_format *fmt)
{
	struct sc7f0_frame_tap *t = to_tap(sd);
	if (fmt->pad > 1)
		return -EINVAL;
	mutex_lock(&t->lock);
	fmt->format = fmt->which == V4L2_SUBDEV_FORMAT_TRY ?
		*v4l2_subdev_get_try_format(sd, state, fmt->pad) : t->format;
	mutex_unlock(&t->lock);
	return 0;
}
static int tap_set(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
		   struct v4l2_subdev_format *fmt)
{
	struct sc7f0_frame_tap *t = to_tap(sd);
	int ret = 0;
	if (fmt->pad > 1 || !supported(fmt->format.code) || fmt->format.width < 64 ||
	    fmt->format.width > 4096 || fmt->format.width % 16 || fmt->format.height < 64 ||
	    fmt->format.height > 2160 || fmt->format.height % 2)
		return -EINVAL;
	mutex_lock(&t->lock);
	fmt->format.field = V4L2_FIELD_NONE;
	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY) {
		*v4l2_subdev_get_try_format(sd, state, 0) = fmt->format;
		*v4l2_subdev_get_try_format(sd, state, 1) = fmt->format;
	} else if (t->streaming || t->start_unconfirmed || t->stop_waiting)
		ret = -EBUSY;
	else
		t->format = fmt->format;
	mutex_unlock(&t->lock);
	return ret;
}
static int tap_init_cfg(struct v4l2_subdev *sd, struct v4l2_subdev_state *state)
{
	struct sc7f0_frame_tap *t = to_tap(sd);
	*v4l2_subdev_get_try_format(sd, state, 0) = t->format;
	*v4l2_subdev_get_try_format(sd, state, 1) = t->format;
	return 0;
}
static const struct v4l2_subdev_video_ops video_ops = { .s_stream = tap_stream };
static const struct v4l2_subdev_pad_ops pad_ops = {
	.init_cfg = tap_init_cfg, .enum_mbus_code = tap_enum, .get_fmt = tap_get, .set_fmt = tap_set,
};
static const struct v4l2_subdev_ops subdev_ops = { .video = &video_ops, .pad = &pad_ops };
static const struct media_entity_operations entity_ops = { .link_validate = v4l2_subdev_link_validate };
static int gpio_get(struct gpio_chip *gc, unsigned int bit)
{
	struct sc7f0_frame_tap *t = gpiochip_get_data(gc);
	return !!(readl(t->regs + 0x30) & BIT(bit));
}
static void gpio_set(struct gpio_chip *gc, unsigned int bit, int value)
{
	struct sc7f0_frame_tap *t = gpiochip_get_data(gc);
	writel(BIT(bit), t->regs + (value ? 0x34 : 0x38));
}
static int gpio_output(struct gpio_chip *gc, unsigned int bit, int value)
{
	gpio_set(gc, bit, value);
	return 0;
}
static int tap_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct sc7f0_frame_tap *t;
	int ret;
	t = devm_kzalloc(dev, sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;
	t->dev = dev;
	t->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(t->regs))
		return PTR_ERR(t->regs);
	t->clk = devm_clk_get_enabled(dev, NULL);
	if (IS_ERR(t->clk))
		return PTR_ERR(t->clk);
	if (readl(t->regs) != 0x54415031 || readl(t->regs + 0x04) != TAP_ABI ||
	    readl(t->regs + 0x18) != TAP_RATE)
		return dev_err_probe(dev, -ENODEV, "Wrong frame-tap hardware/clock ABI\n");
	mutex_init(&t->lock);
	spin_lock_init(&t->reg_lock);
	t->gpio.label = dev_name(dev); t->gpio.parent = dev; t->gpio.owner = THIS_MODULE;
	t->gpio.base = -1; t->gpio.ngpio = 2; t->gpio.of_node = dev->of_node;
	t->gpio.get = gpio_get; t->gpio.set = gpio_set; t->gpio.direction_output = gpio_output;
	ret = devm_gpiochip_add_data(dev, &t->gpio, t);
	if (ret)
		return ret;
	v4l2_subdev_init(&t->sd, &subdev_ops);
	t->sd.owner = THIS_MODULE; t->sd.dev = dev; t->sd.fwnode = dev_fwnode(dev);
	t->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	snprintf(t->sd.name, sizeof(t->sd.name), "%s", dev_name(dev));
	t->sd.entity.function = MEDIA_ENT_F_VID_IF_BRIDGE; t->sd.entity.ops = &entity_ops;
	t->pads[0].flags = MEDIA_PAD_FL_SINK; t->pads[1].flags = MEDIA_PAD_FL_SOURCE;
	t->format.width = 3840; t->format.height = 2160;
	t->format.code = MEDIA_BUS_FMT_RBG888_1X24; t->format.field = V4L2_FIELD_NONE;
	ret = media_entity_pads_init(&t->sd.entity, 2, t->pads);
	if (ret)
		return ret;
	platform_set_drvdata(pdev, t);
	ret = v4l2_async_register_subdev(&t->sd);
	if (ret) {
		platform_set_drvdata(pdev, NULL);
		media_entity_cleanup(&t->sd.entity);
	}
	return ret;
}
static int tap_remove(struct platform_device *pdev)
{
	struct sc7f0_frame_tap *t = platform_get_drvdata(pdev);
	v4l2_async_unregister_subdev(&t->sd);
	media_entity_cleanup(&t->sd.entity);
	return 0;
}
static const struct of_device_id matches[] = { { .compatible = "yuan,sc7f0-frame-tap-1.0" }, {} };
MODULE_DEVICE_TABLE(of, matches);
static struct platform_driver sc7f0_tap_driver = {
	.probe = tap_probe, .remove = tap_remove,
	.driver = { .name = "sc7f0-frame-tap", .of_match_table = matches },
};
module_platform_driver(sc7f0_tap_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("SC7F0 frame-safe passive tap and SOF timestamp provider");
