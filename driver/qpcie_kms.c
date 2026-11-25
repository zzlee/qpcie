// SPDX-License-Identifier: GPL-2.0
/* A logical graphics layer over the independent HDMI base, not an HDMI
 * timing controller. Only the commit worker and serialized detach touch v1. */
#include <linux/delay.h>
#include <linux/dma-fence.h>
#include <linux/fs_struct.h>
#include <linux/magic.h>
#include <linux/security.h>
#include <linux/init_task.h>
#include <drm/drm_atomic.h>
#include <drm/drm_atomic_helper.h>
#include <drm/drm_drv.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_dma_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_managed.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_simple_kms_helper.h>
#include <drm/drm_vblank.h>
#include "qpcie_driver.h"
#include "qpcie_kms.h"
#include "qpcie_kms_v1.h"
#include "qpcie_kms_policy.h"

struct qpcie_kms {
	struct drm_device drm;
	struct drm_simple_display_pipe pipe;
	struct drm_connector output;
	struct qpcie_dev *qdev;
	void __iomem *csr;
	struct mutex admission;
	wait_queue_head_t wait;
	wait_queue_head_t terminal;
	struct work_struct work;
	atomic_t irq_serial;
	struct drm_atomic_state *job;
	bool stopping, failed, dma_pinned, quarantine;
	u32 serial, active;
	u32 observed_frame;
	struct timespec64 observed_time;
	/* Independent of DRM's logical plane state: pinned until retirement,
	 * proven drain, or PCI fencing on remove. */
	struct drm_framebuffer *front, *issued;
};

void qpcie_kms_frame_irq(struct qpcie_dev *qdev)
{
	struct qpcie_kms *k = READ_ONCE(qdev->kms);

	if (!k)
		return;
	atomic_inc(&k->irq_serial);
	wake_up(&k->wait);
}

static const struct drm_display_mode mode = {
	DRM_MODE("3840x2160", DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
		 594000, 3840, 4016, 4104, 4400, 0, 2160, 2168, 2178, 2250, 0,
		 DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_PVSYNC)
};

static int get_modes(struct drm_connector *connector)
{
	struct drm_display_mode *m = drm_mode_duplicate(connector->dev, &mode);

	if (!m)
		return 0;
	drm_mode_probed_add(connector, m);
	return 1;
}

static bool rx_ready(struct qpcie_kms *k)
{
	struct qpcie_hdmi_tlm t;

	return !qpcie_hdmi_read_telemetry(k->qdev, &t) &&
		qpcie_hdmi_telemetry_fresh(k->qdev, t.heartbeat) &&
		(t.flags & (HDMI_TLM_F_TIMING_VALID | HDMI_TLM_F_INTERLACED |
			    HDMI_TLM_F_QUERY_ERROR)) == HDMI_TLM_F_TIMING_VALID &&
		t.width == 3840 && t.height == 2160 && t.pixelclock == 594000000;
}

static enum drm_connector_status detect(struct drm_connector *connector, bool force)
{
	struct qpcie_kms *k = container_of(connector, struct qpcie_kms, output);

	int idx;
	bool ready;

	if (!drm_dev_enter(&k->drm, &idx))
		return connector_status_disconnected;
	ready = !READ_ONCE(k->failed) && !READ_ONCE(k->stopping) && rx_ready(k);
	drm_dev_exit(idx);
	return ready ? connector_status_connected : connector_status_disconnected;
}

static const struct drm_connector_helper_funcs connector_helpers = {
	.get_modes = get_modes,
};
static const struct drm_connector_funcs connector_funcs = {
	.detect = detect,
	.fill_modes = drm_helper_probe_single_connector_modes,
	.destroy = drm_connector_cleanup,
	.reset = drm_atomic_helper_connector_reset,
	.atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_connector_destroy_state,
};

static enum drm_mode_status mode_valid(struct drm_simple_display_pipe *pipe,
				       const struct drm_display_mode *m)
{
	return drm_mode_equal(m, &mode) ? MODE_OK : MODE_BAD;
}

static int check_plane(struct drm_simple_display_pipe *pipe,
		       struct drm_plane_state *p, struct drm_crtc_state *c)
{
	struct drm_framebuffer *fb = p->fb;
	struct drm_gem_object *obj;

	if (!fb)
		return 0;
	obj = drm_gem_fb_get_obj(fb, 0);
	if (!obj || fb->width != mode.hdisplay || fb->height != mode.vdisplay ||
	    fb->format->format != DRM_FORMAT_ABGR8888 ||
	    fb->modifier != DRM_FORMAT_MOD_LINEAR || fb->offsets[0] ||
	    fb->pitches[0] != QOVL_RGBA_STRIDE_BYTES ||
	    obj->size < QOVL_RGBA_FRAME_BYTES ||
	    !IS_ALIGNED(to_drm_gem_dma_obj(obj)->dma_addr, 32) ||
	    p->src_x || p->src_y || p->src_w != (3840U << 16) ||
	    p->src_h != (2160U << 16) || p->crtc_x || p->crtc_y ||
	    p->crtc_w != 3840 || p->crtc_h != 2160)
		return -EINVAL;
	return 0;
}

static const struct drm_simple_display_pipe_funcs pipe_funcs = {
	.mode_valid = mode_valid,
	.check = check_plane,
};

static int check(struct drm_device *dev, struct drm_atomic_state *s)
{
	struct qpcie_kms *k = container_of(dev, struct qpcie_kms, drm);
	struct drm_plane_state *p;
	struct drm_crtc_state *c;

	/* Include both objects even for plane-only flips or CRTC-only events. */
	p = drm_atomic_get_plane_state(s, &k->pipe.plane);
	if (IS_ERR(p))
		return PTR_ERR(p);
	c = drm_atomic_get_crtc_state(s, &k->pipe.crtc);
	if (IS_ERR(c))
		return PTR_ERR(c);
	if (c->active != !!p->fb || (c->active &&
	    (p->crtc != &k->pipe.crtc || !drm_mode_equal(&c->mode, &mode))))
		return -EINVAL;
	return drm_atomic_helper_check(dev, s);
}

static void drop_fb(struct drm_framebuffer **fb)
{
	if (*fb)
		drm_framebuffer_put(*fb);
	*fb = NULL;
}

static void drained_refs(struct qpcie_kms *k)
{
	drop_fb(&k->issued);
	drop_fb(&k->front);
	k->active = 0;
	qpcie_plane_release(&k->qdev->lease->owner);
	if (k->dma_pinned) {
		k->dma_pinned = false;
		module_put(THIS_MODULE);
	}
}

static int present(struct qpcie_kms *k, struct drm_plane_state *p)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(3000);
	u32 cookie;
	bool observed = false;
	int rc;

	if (!p->fb) {
		rc = dp_disable(k->csr, k->serial);
		if (!rc) {
			k->observed_frame = readl(k->csr + QOVL_REG_FLIP_FRAME);
			ktime_get_ts64(&k->observed_time);
			drained_refs(k);
		}
		return rc;
	}
	/* Simple-pipe prepare_fb supplies the explicit/implicit GEM producer
	 * fence. Wait outside the ioctl for NONBLOCK; unplug can interrupt. */
	while (p->fence) {
		rc = dma_fence_get_status(p->fence);
		if (rc < 0)
			return rc;
		if (rc > 0)
			break;
		if (READ_ONCE(k->stopping))
			return -ENODEV;
		if (time_after_eq(jiffies, deadline))
			return -ETIMEDOUT;
		dma_fence_wait_timeout(p->fence, false, msecs_to_jiffies(10));
	}
	if (READ_ONCE(k->stopping))
		return -ENODEV;
	/* Keep all-ones reserved as a failed MMIO read. Never recycle cookies. */
	if (k->serial >= U32_MAX - 1)
		return -EOVERFLOW;
	if (!k->dma_pinned) {
		if (!try_module_get(THIS_MODULE))
			return -ENODEV;
		k->dma_pinned = true;
	}
	cookie = ++k->serial;
	drm_framebuffer_get(p->fb);
	k->issued = p->fb;
	rc = dp_submit(k->csr,
		       to_drm_gem_dma_obj(drm_gem_fb_get_obj(p->fb, 0))->dma_addr,
		       cookie, k->active);
	if (rc)
		return rc;
	deadline = jiffies + msecs_to_jiffies(3000);
	do {
		int generation = atomic_read(&k->irq_serial);
		bool shown;

		if (READ_ONCE(k->stopping))
			return -ENODEV;
		rc = dp_completed(k->csr, cookie, k->active, &shown);
		if (rc < 0)
			return rc;
		if (shown && !observed) {
			k->observed_frame = readl(k->csr + QOVL_REG_FLIP_FRAME);
			ktime_get_ts64(&k->observed_time);
			observed = true;
		}
		if (rc > 0) {
			drop_fb(&k->front);
			k->front = k->issued;
			k->issued = NULL;
			k->active = cookie;
			return 0;
		}
		/* IRQ 9 wakes a status check, never a flip in its own right.
		 * Recheck if the cookie CDC trails SOF or an MSI coalesced. */
		wait_event_timeout(k->wait, atomic_read(&k->irq_serial) != generation ||
				   READ_ONCE(k->stopping), msecs_to_jiffies(5));
	} while (time_before(jiffies, deadline));
	return -ETIMEDOUT;
}

static void abort_job(struct qpcie_kms *k, int rc)
{
	dev_err(k->drm.dev, "KMS error=%d cookie=%u old=%u admitted=%u pending=%u active=%u retired=%u frame=%u status=%x irq=%d comp=%x ingress=%x\n",
		rc, k->serial, k->active, readl(k->csr + QOVL_REG_FLIP_ADMITTED),
		readl(k->csr + QOVL_REG_FLIP_PENDING), readl(k->csr + QOVL_REG_FLIP_ACTIVE),
		readl(k->csr + QOVL_REG_FLIP_RETIRED), readl(k->csr + QOVL_REG_FLIP_FRAME),
		readl(k->csr + QOVL_REG_FLIP_STATUS), atomic_read(&k->irq_serial),
		readl(k->csr + QOVL_REG_COMP_CTRL), readl(k->csr + QOVL_REG_STATUS));
	if (!dp_disable(k->csr, k->serial)) {
		dev_info(k->drm.dev, "KMS drain verified cookie=%u\n", k->serial);
		drained_refs(k);
	} else {
		dev_err(k->drm.dev, "KMS drain unverified; quarantine cookie=%u\n", k->serial);
		k->quarantine = true;
		qpcie_plane_kill(&k->qdev->lease->owner);
	}
	WRITE_ONCE(k->failed, true);
	wake_up_all(&k->terminal);
}

static void finish_event(struct qpcie_kms *k, struct drm_crtc_state *c, int rc)
{
	struct drm_pending_vblank_event *e = c->event;

	if (!e)
		return;
	c->event = NULL;
	if (rc) {
		if (e->base.fence) {
			dma_fence_set_error(e->base.fence, rc);
			dma_fence_signal(e->base.fence);
		}
		drm_event_cancel_free(&k->drm, &e->base);
		return;
	}
	/* v1 exposes SOF count and matching cookie, not a latched hardware
	 * timestamp. Timestamp the observation. A disabled CRTC completes on
	 * confirmed off/drain, without claiming another visible frame. */
	e->event.vbl.sequence = k->observed_frame;
	e->event.vbl.tv_sec = k->observed_time.tv_sec;
	e->event.vbl.tv_usec = k->observed_time.tv_nsec / NSEC_PER_USEC;
	drm_send_event(&k->drm, &e->base);
}

static void run_job(struct work_struct *work)
{
	struct qpcie_kms *k = container_of(work, struct qpcie_kms, work);
	struct drm_atomic_state *s = k->job;
	int rc = present(k, drm_atomic_get_new_plane_state(s, &k->pipe.plane));

	if (rc)
		abort_job(k, rc);
	/* Release the admission slot in the same critical section as event
	 * publication: a client reacting immediately can submit the next FB. */
	drm_atomic_helper_cleanup_planes(&k->drm, s);
	mutex_lock(&k->admission);
	finish_event(k, drm_atomic_get_new_crtc_state(s, &k->pipe.crtc), rc);
	WRITE_ONCE(k->job, NULL);
	drm_atomic_state_put(s);
	wake_up_all(&k->wait);
	mutex_unlock(&k->admission);
}

static int commit(struct drm_device *dev, struct drm_atomic_state *s,
		  bool nonblock)
{
	struct qpcie_kms *k = container_of(dev, struct qpcie_kms, drm);
	struct drm_plane_state *p = drm_atomic_get_new_plane_state(s, &k->pipe.plane);
	int rc;

	mutex_lock(&k->admission);
	while (k->job && !nonblock && !k->stopping) {
		mutex_unlock(&k->admission);
		rc = wait_event_interruptible(k->wait, !READ_ONCE(k->job) ||
					      READ_ONCE(k->stopping));
		if (rc)
			return rc;
		mutex_lock(&k->admission);
	}
	if (k->stopping || (k->failed && p->fb) || k->job) {
		rc = k->stopping ? -ENODEV : k->failed ? -EIO : -EBUSY;
		goto out;
	}
	rc = drm_atomic_helper_prepare_planes(dev, s);
	if (rc)
		goto out;
	rc = qpcie_plane_claim(&k->qdev->lease->owner);
	if (rc) {
		drm_atomic_helper_unprepare_planes(dev, s);
		goto out;
	}
	if (p->fb && !k->front && !k->issued) {
		rc = rx_ready(k) ? dp_base_ready(k->csr) : -EAGAIN;
		dev_info_ratelimited(dev->dev, "KMS cold submit comm=%s tgid=%d fb=%u base_rc=%d frame=%u irq=%d\n",
			current->comm, task_tgid_nr(current), p->fb->base.id, rc,
			readl(k->csr + QOVL_REG_FLIP_FRAME), atomic_read(&k->irq_serial));
		if (rc) {
			if (rc == -EAGAIN)
				qpcie_plane_release(&k->qdev->lease->owner);
			else {
				qpcie_plane_kill(&k->qdev->lease->owner);
				WRITE_ONCE(k->failed, true);
				wake_up_all(&k->terminal);
			}
			drm_atomic_helper_unprepare_planes(dev, s);
			goto out;
		}
	}
	if (!nonblock) {
		/* Blocking callers may receive a real producer/HW error. Do not
		 * publish the new logical state until the operation succeeded. */
		rc = present(k, p);
		if (rc) {
			abort_job(k, rc);
			drm_atomic_helper_unprepare_planes(dev, s);
			goto out;
		}
	}
	rc = drm_atomic_helper_swap_state(s, false);
	if (rc) {
		if (!nonblock)
			abort_job(k, rc);
		else if (!k->dma_pinned)
			qpcie_plane_release(&k->qdev->lease->owner);
		drm_atomic_helper_unprepare_planes(dev, s);
		goto out;
	}
	drm_atomic_helper_update_legacy_modeset_state(dev, s);
	if (!nonblock) {
		drm_atomic_helper_cleanup_planes(dev, s);
		finish_event(k, drm_atomic_get_new_crtc_state(s, &k->pipe.crtc), 0);
		goto out;
	}
	drm_atomic_state_get(s);
	WRITE_ONCE(k->job, s);
	schedule_work(&k->work);
	mutex_unlock(&k->admission);
	return 0;
out:
	mutex_unlock(&k->admission);
	return rc;
}

static const struct drm_mode_config_funcs config_funcs = {
	.fb_create = drm_gem_fb_create,
	.atomic_check = check,
	.atomic_commit = commit,
};
/* FLIP_COMPLETE has no error field. On an unpresented accepted commit,
 * report POLLERR instead of silently stranding event-only users or forging
 * a success event. OUT_FENCE_PTR gets the original error as well. */
static __poll_t kms_poll(struct file *file, poll_table *wait)
{
	struct drm_file *priv = file->private_data;
	struct qpcie_kms *k = container_of(priv->minor->dev, struct qpcie_kms, drm);
	__poll_t mask;

	poll_wait(file, &k->terminal, wait);
	mask = drm_poll(file, wait);
	if (READ_ONCE(k->failed))
		mask |= EPOLLERR;
	if (READ_ONCE(k->stopping))
		mask |= EPOLLHUP;
	return mask;
}

static const struct file_operations fops = {
	.owner = THIS_MODULE,
	.open = drm_open,
	.release = drm_release,
	.unlocked_ioctl = drm_ioctl,
	.compat_ioctl = drm_compat_ioctl,
	.poll = kms_poll,
	.read = drm_read,
	.llseek = noop_llseek,
	.mmap = drm_gem_mmap,
	.fop_flags = FOP_UNSIGNED_OFFSET,
	DRM_GEM_DMA_UNMAPPED_AREA_FOPS
};
static const struct drm_driver driver = {
	.driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
	.fops = &fops,
	DRM_GEM_DMA_DRIVER_OPS,
	.name = "sc7f0-kms",
	.desc = "SC7F0 host graphics plane",
	.major = 1,
};

/* The generic PCI sysfs binary attrs use the shared iomem mapping on x86.
 * Exclusive requests alone do NOT block resourceN with iomem=relaxed.
 * Withdraw both aliases and invalidate pre-bind PTEs for exactly these BARs.
 * kernfs deactivation bars faults from re-establishing the old mappings. */
static void restore_raw_bars(void *data)
{
	struct qpcie_dev *qdev = data;
	struct pci_dev *pdev = qdev->pdev;
	int bar;

	if (qdev->dma_isolated)
		return;
	for (bar = 0; bar < 2; ++bar) {
		if (pdev->res_attr[bar] &&
		    device_create_bin_file(&pdev->dev, pdev->res_attr[bar]))
			dev_err(&pdev->dev, "cannot restore resource%d\n", bar);
		if (pdev->res_attr_wc[bar] &&
		    device_create_bin_file(&pdev->dev, pdev->res_attr_wc[bar]))
			dev_err(&pdev->dev, "cannot restore resource%d_wc\n", bar);
	}
}

/* iomem_is_exclusive() is not exported to modules. On Linux 7 x86 its
 * strict_iomem_checks defaults to CONFIG_STRICT_DEVMEM. Our busy regions
 * explicitly have IORESOURCE_EXCLUSIVE; IO_STRICT_DEVMEM extends the check
 * to ordinary busy regions and is not a prerequisite for these BARs. */
static bool devmem_excluded(void)
{
	struct path root;
	struct file *f;
	char *line;
	char tail;
	ssize_t n;
	loff_t pos = 0;
	bool safe = false;

	if (!IS_ENABLED(CONFIG_DEVMEM) || security_locked_down(LOCKDOWN_DEV_MEM))
		return true;
	if (!IS_ENABLED(CONFIG_STRICT_DEVMEM))
		return false;
	get_fs_root(init_task.fs, &root);
	f = file_open_root(&root, "proc/cmdline", O_RDONLY | O_NOFOLLOW, 0);
	path_put(&root);
	if (IS_ERR(f))
		return false;
	if (file_inode(f)->i_sb->s_magic != PROC_SUPER_MAGIC ||
	    f->f_path.dentry->d_parent != file_inode(f)->i_sb->s_root ||
	    strcmp(f->f_path.dentry->d_name.name, "cmdline"))
		goto close;
	line = kmalloc(PAGE_SIZE, GFP_KERNEL);
	if (!line)
		goto close;
	n = kernel_read(f, line, PAGE_SIZE - 1, &pos);
	if (n > 0 && kernel_read(f, &tail, 1, &pos) == 0)
		safe = qpcie_cmdline_excludes_raw(line, n, IS_ENABLED(CONFIG_STRICT_DEVMEM));
	kfree(line);
close:
	filp_close(f, NULL);
	return safe;
}

static int hide_raw_bars(struct qpcie_dev *qdev)
{
	struct pci_dev *pdev = qdev->pdev;
	int bar;

	for (bar = 0; bar < 2; ++bar) {
		const struct bin_attribute *a = pdev->res_attr[bar];

		if (pci_resource_len(pdev, bar) && (!a || !a->f_mapping ||
		    !(pci_resource_flags(pdev, bar) & IORESOURCE_MEM)))
			return -EOPNOTSUPP;
	}
	for (bar = 0; bar < 2; ++bar) {
		const struct bin_attribute *a = pdev->res_attr[bar];

		if (!a)
			continue;
		device_remove_bin_file(&pdev->dev, a);
		if (pdev->res_attr_wc[bar])
			device_remove_bin_file(&pdev->dev, pdev->res_attr_wc[bar]);
		unmap_mapping_range(a->f_mapping(), pci_resource_start(pdev, bar),
				    pci_resource_len(pdev, bar), 1);
	}
	return devm_add_action_or_reset(&pdev->dev, restore_raw_bars, qdev);
}

int qpcie_kms_protect(struct qpcie_dev *qdev)
{
	struct pci_dev *pdev = qdev->pdev;
	void __iomem *csr = qdev->bar0_mmio + QOVL_BAR0_OFFSET;
	u32 caps;

	if (pci_resource_len(pdev, 0) < QOVL_BAR0_OFFSET + QOVL_REG_FLIP_STATUS + 4 ||
	    readl(qdev->bar0_mmio + REG_NEW_GLOBAL_ID) != 0x12abe380)
		return -ENODEV;
	caps = readl(qdev->bar0_mmio + REG_NEW_GLOBAL_CAPS);
	if (caps == U32_MAX || !(caps & QPCIE_CAP_C2H_ONLY) ||
	    !(caps & QPCIE_CAP_RGB_COMPOSITOR) ||
	    readl(csr + QOVL_REG_ID) != QOVL_ID_RGB1 || !dp_present(csr))
		return -ENODEV;
	/* Earlier prototypes advertised the same signature but reset ADMITTED.
	 * 26112408 retains admission and uses the issuer's reset-ready signal. */
	if (!dp_epoch_supported(readl(qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION)))
		return -EPROTONOSUPPORT;
	if (!devmem_excluded()) {
		dev_err(&pdev->dev, "KMS withheld: raw physical BAR access not excluded (requires strict iomem policy or lockdown)\n");
		return -EACCES;
	}
	return hide_raw_bars(qdev);
}

int qpcie_kms_register(struct qpcie_dev *qdev)
{
	static const u32 formats[] = { DRM_FORMAT_ABGR8888 };
	static const u64 modifiers[] = { DRM_FORMAT_MOD_LINEAR, DRM_FORMAT_MOD_INVALID };
	struct pci_dev *pdev = qdev->pdev;
	void __iomem *csr = qdev->bar0_mmio + QOVL_BAR0_OFFSET;
	struct qpcie_kms *k;
	struct drm_device *dev;
	int rc;

	if (!dp_idle(csr))
		return -EBUSY;
	k = devm_drm_dev_alloc(&pdev->dev, &driver, struct qpcie_kms, drm);
	if (IS_ERR(k))
		return PTR_ERR(k);
	k->csr = csr;
	k->qdev = qdev;
	k->serial = readl(csr + QOVL_REG_FLIP_ADMITTED);
	if (k->serial >= U32_MAX - 1)
		return -EOVERFLOW;
	mutex_init(&k->admission);
	init_waitqueue_head(&k->wait);
	init_waitqueue_head(&k->terminal);
	INIT_WORK(&k->work, run_job);
	dev = &k->drm;
	rc = drmm_mode_config_init(dev);
	if (rc)
		return rc;
	dev->mode_config.min_width = dev->mode_config.max_width = mode.hdisplay;
	dev->mode_config.min_height = dev->mode_config.max_height = mode.vdisplay;
	dev->mode_config.funcs = &config_funcs;
	rc = drm_connector_init(dev, &k->output, &connector_funcs,
				DRM_MODE_CONNECTOR_VIRTUAL);
	if (rc)
		return rc;
	drm_connector_helper_add(&k->output, &connector_helpers);
	k->output.display_info.non_desktop = true;
	rc = drm_object_property_set_value(&k->output.base,
		dev->mode_config.non_desktop_property, 1);
	if (rc)
		return rc;
	rc = drm_simple_display_pipe_init(dev, &k->pipe, &pipe_funcs, formats,
					  ARRAY_SIZE(formats), modifiers, &k->output);
	if (rc)
		return rc;
	drm_mode_config_reset(dev);
	mutex_lock(&qdev->plane_lifecycle);
	if ((atomic_read(&qdev->lease->owner) & PL_MASK) != PL_IDLE) {
		mutex_unlock(&qdev->plane_lifecycle);
		return -EBUSY;
	}
	WRITE_ONCE(qdev->kms, k);
	rc = drm_dev_register(dev, 0);
	if (rc) {
		WRITE_ONCE(qdev->kms, NULL);
		synchronize_irq(qdev->irq);
	}
	mutex_unlock(&qdev->plane_lifecycle);
	return rc;
}

static void stop_jobs(struct qpcie_kms *k)
{
	mutex_lock(&k->admission);
	WRITE_ONCE(k->stopping, true);
	wake_up_all(&k->wait);
	wake_up_all(&k->terminal);
	mutex_unlock(&k->admission);
	flush_work(&k->work);
}

/* Serialized against capture recovery, PCI reset and unbind. Stop software
 * first; never write compositor registers owned by a maintenance epoch. */
static void stop_plane(struct qpcie_dev *qdev, struct qpcie_kms *k)
{
	int owner;

	stop_jobs(k);
	owner = qpcie_plane_kill(&qdev->lease->owner);
	if (owner == PL_DISPLAY) {
		if (!dp_disable(k->csr, k->serial))
			drained_refs(k);
		else
			k->quarantine = true;
	}
	if (k->quarantine) {
		WRITE_ONCE(qdev->dma_isolated, true);
		pci_clear_master(qdev->pdev);
	}
}

void qpcie_kms_capture_fault(struct qpcie_dev *qdev)
{
	mutex_lock(&qdev->plane_lifecycle);
	if (qdev->kms)
		stop_plane(qdev, qdev->kms);
	else if (qdev->lease)
		qpcie_plane_kill(&qdev->lease->owner);
	mutex_unlock(&qdev->plane_lifecycle);
}

void qpcie_kms_reset_prepare(struct pci_dev *pdev)
{
	struct qpcie_dev *qdev = pci_get_drvdata(pdev);

	if (qdev && qdev->kms_overlay)
		qpcie_kms_capture_fault(qdev);
}

void qpcie_kms_remove(struct qpcie_dev *qdev)
{
	struct qpcie_kms *k;

	mutex_lock(&qdev->plane_lifecycle);
	k = qdev->kms;
	if (!k)
		goto out;
	stop_plane(qdev, k);
	drm_dev_unplug(&k->drm);
	WRITE_ONCE(qdev->kms, NULL);
	synchronize_irq(qdev->irq);
	/* Clearing BME stops new transactions now, but a subsequent driver
	 * could re-enable it. Only the engine's drain proof releases pins. */
	if (k->issued || k->front) {
		/* mode_config cleanup forcibly frees leaked FBs. Pin both the
		 * device and our callbacks, not just a stranded framebuffer. */
		drm_dev_get(&k->drm);
		dev_err(&qdev->pdev->dev, "KMS DMA isolation unproven; quarantining framebuffer references\n");
	}
out:
	mutex_unlock(&qdev->plane_lifecycle);
}
