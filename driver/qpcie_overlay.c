// SPDX-License-Identifier: GPL-2.0
/*
 * qpcie_overlay.c - host-side RGBA overlay plane ring for the
 * SC7F0-RGB-COMPOSITOR-2PPC personality.
 *
 * Why this file exists
 *   rtl/sc7f0_overlay_ingress.v pulls an RGBA plane OUT of host memory: the
 *   address it reads is whatever software writes into CSR 0x04/0x08 of
 *   rtl/sc7f0_rgb_overlay_ctrl.v, and that number has to be the bus address
 *   the card puts on the PCIe fabric - the same class of value that
 *   driver/qpcie_upgrade.c obtains from dma_alloc_coherent() and forwards to
 *   REG_DMA_UPG_HOST_ADDR_L/H.  Userspace cannot obtain one: /proc/self/pagemap
 *   lies behind an IOMMU and is invalid across migration, and no other node
 *   this driver creates publishes a dma_addr_t.  Handing out a guest physical
 *   address guessed from virt_to_phys() would make the first 33 MB plane read
 *   either fault or silently land in the wrong pages.
 *
 * What it provides
 *   /dev/qpcie-ovl-<BDF>, mode 0600, one client at a time:
 *     QOVL_IOC_SETUP  allocate a 1..4 slot ring of coherent memory
 *     QOVL_IOC_INFO   re-read the ring (base iova, stride, generation)
 *     QOVL_IOC_FREE   release it, refused while the caller says a read is live
 *     mmap()          the same coherent pages, read/write, at slot offset
 *
 * What it deliberately does NOT do
 *   It never touches CSR 0xB00A0000.  That window is clocked by pl_clk0 and
 *   belongs to the PS (device tree overlay-ctrl@b00a0000); the host has no
 *   path to it and inventing a BAR0 alias for it would be a second, unaudited
 *   ABI to the same block.  Arming, consume and abort stay with
 *   test_app/sc7f0_rgb_overlay.c on the card.
 *
 *   It keeps no transfer state and no slot accounting.  The authoritative
 *   counters are CSR 0x48/0x4C/0x50 bytes_issued/staged/drained and 0x54
 *   wr_frames_done; duplicating them here is how a host-side idea of "done"
 *   ends up earlier than the hardware's, which is exactly the debt the M6/M10
 *   drain-and-fence rule forbids.
 *
 * Gate
 *   Registered only when the fabric answers with the RGB-compositor version,
 *   for the same reason qpcie_debug.c gates on an exact version: a bitstream
 *   without sc7f0_overlay_ingress.v would accept the writes and never issue a
 *   read, and a 33 MB ring would be allocated for a block that does not exist.
 */
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/kref.h>
#include <linux/mm.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/wait.h>

#include "qpcie_driver.h"
#include "../include/qpcie_overlay.h"
#include <linux/uaccess.h>

struct qpcie_overlay {
	struct miscdevice misc;
	char name[64];
	struct pci_dev *pdev;	/* held by a pci_dev_get() for as long as `o`
				 * exists: the last reference may drop long after
				 * pci_stop_and_remove_bus_device() released the
				 * function's own references */
	struct kref refs;	/* 1 for the registration + 1 per open struct
				 * file + 1 per live VMA */
	struct mutex lock;		/* ring + client slot */
	atomic_t busy;			/* a client has the ring open */
	void *vaddr;
	dma_addr_t iova;
	size_t bytes;
	u32 slot_bytes;
	u32 nslots;
	u32 gen;
	bool dead;		/* device detached: no open, no ioctl, no mmap */
	bool ring_retained;	/* ring had to be kept past detach */

	/* Phase C-B: BAR0 CSR window + MSI completion waitqueue */
	void __iomem *csr;
	bool bar0_csr_ok;
	wait_queue_head_t wq;
	spinlock_t irq_lock;
	bool inflight;
	u32 submit_seq;
	u32 done_seq;
	u32 frame_bytes;
};

/* SC7F0-RGB-COMPOSITOR-2PPC.  Exact on purpose (see the gate note above).
 * Round 26111502 re-presents the overlay completion cone: the RC header beat
 * now delivers all five of its payload DWords and the staging gearbox can wrap
 * DWords into the next row, so the Host-to-card plane is byte-correct rather
 * than merely byte-counted.
 * Round 26111503 additionally closes the RX interrupt path in the fabric: the
 * RGB personality connected only pl_ps_irq1, so the whole pl_ps_irq0 bank
 * (mailbox, VPHY SPI 90 / INTID 122, HDMI RX SS SPI 91 / INTID 123, dualpath,
 * capture writer) never reached the PS, which is why a proven, unmasked and
 * latched VPHY RX clock event raised zero GIC interrupts while the wired
 * pl_ps_irq1 bank did deliver one.  The fabric reports 0x26111503, so this gate
 * moves with it; an older card is refused here instead of half-working.
 *
 * Exact equality, however, locked the node out of every RGB build that was ever
 * flashed.  Measured 2026-11-17 against 0x26111602 on the card:
 *   open /dev/qpcie-ovl-0000:03:00.0: No such file or directory
 * (build/accept-26111602/b1-overlay-h2c.txt), while the same card's overlay
 * controller answers id=0x52474231 ("RGB1") at 0xB00A0000 and its status reads
 * 0x00000002 - the fabric is there and alive, only the node was refused.  The
 * gate had already excluded the deployed 0x26111601 for the same reason.
 *
 * Acceptance is now a personality check with a version floor behind it:
 *   - QPCIE_CAP_RGB_COMPOSITOR in the capability register is authoritative from
 *     0x26111701 onward: rtl/axil_reg_space.v sets that bit if and only if the
 *     H2C overlay + alpha-blend fabric is in the bitstream, so a future round
 *     without the fabric is refused whatever its version number says; and
 *   - the old floor admits the RGB rounds already sitting on cards, which predate
 *     the bit.  No non-RGB personality ever deployed is at or above the floor
 *     (the VCU/C2H releases are 0x2610xxxx through 0x26111204), so the floor on
 *     its own still cannot admit a card that lacks the fabric.
 */
#define QOVL_HW_VERSION_FLOOR 0x26111503U

/* open() reaches the structure through the miscdevice; everything after a
 * successful open() reaches it through file->private_data, because open()
 * replaces private_data with the reference-bearing owner of the ring. */
static struct qpcie_overlay *misc_to_ovl(struct miscdevice *misc)
{
	return container_of(misc, struct qpcie_overlay, misc);
}

static struct qpcie_overlay *file_ovl(struct file *file)
{
	return file->private_data;
}

/* ------------------------------------------------------------ references
 *
 * Two lifetime defects fixed here, both raised in review of the first draft.
 *
 * (1) A userspace-supplied "outstanding = 0" is not a hardware quiesce proof.
 *     The authoritative state is CSR 0x40 STATUS / 0x44 STATUS2 / 0x68
 *     SUPPRESSION, clocked by pl_clk0 on the PS side; the host driver cannot
 *     read them, and inventing a BAR0 alias to reach them would open a second
 *     unaudited window onto a block whose retirement rules already cost this
 *     board a hung interconnect.  So no host-side operation may release the
 *     ring: QOVL_IOC_FREE is refused, and the pages come back only at device
 *     detach, the one point where this driver can turn bus mastering OFF
 *     itself (pci_clear_master in remove()).  A queued-but-unissued command or
 *     a stale cached 0 would otherwise free pages under an in-flight read.
 *
 * (2) kfree() of the control structure while a struct file or an address-space
 *     mapping still pointed at it is a use-after-free.  `.owner = THIS_MODULE`
 *     blocks rmmod only; this workflow removes the function through
 *     /sys/bus/pci/devices/.../remove, which does not consult the module
 *     refcount.  Every reference is therefore counted - the registration, each
 *     open struct file, each live VMA - plus a pci_dev_get() so that the last
 *     put may run after the struct pci_dev itself would otherwise be gone.
 */
static void ovl_final_put(struct kref *ref)
{
	struct qpcie_overlay *o = container_of(ref, struct qpcie_overlay, refs);
	struct pci_dev *pdev = o->pdev;
	void *vaddr = o->vaddr;
	dma_addr_t iova = o->iova;
	size_t bytes = o->bytes;

	/* Only reachable after the registration reference was dropped - i.e.
	 * after remove() cleared bus mastering - and after every fd and every
	 * VMA that could touch the pages was gone. */
	if (vaddr) {
		o->vaddr = NULL;
		o->iova = 0;
		o->bytes = 0;
		dma_free_coherent(&pdev->dev, bytes, vaddr, iova);
	}
	if (o->ring_retained)
		dev_info(&pdev->dev,
			 "overlay ring released with the last reference; the device was already detached\n");
	pci_dev_put(pdev);
	kfree(o);
}

/* Caller holds o->lock. */
static void ovl_get(struct qpcie_overlay *o)
{
	kref_get(&o->refs);
}

static void ovl_put(struct qpcie_overlay *o)
{
	kref_put(&o->refs, ovl_final_put);
}

static int ovl_open(struct inode *inode, struct file *file)
{
	struct qpcie_overlay *o = misc_to_ovl(file->private_data);
	int rc = 0;

	mutex_lock(&o->lock);
	if (o->dead) {
		rc = -ENODEV;
	} else if (atomic_cmpxchg(&o->busy, 0, 1) != 0) {
		/* One client: two producers into one wr_slot_ready[3:0] rotation
		 * would each believe they own the slots the other is draining. */
		rc = -EBUSY;
	} else {
		ovl_get(o);
		file->private_data = o;
	}
	mutex_unlock(&o->lock);
	return rc;
}

static int ovl_close(struct inode *inode, struct file *file)
{
	struct qpcie_overlay *o = file_ovl(file);

	/* Only the client is released.  The ring survives on purpose: an armed
	 * PCIe read must not find its pages freed because the tool that armed it
	 * exited, and nothing on this side can prove it finished. */
	o->inflight = false;
	atomic_set(&o->busy, 0);
	ovl_put(o);
	return 0;
}

static long ovl_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct qpcie_overlay *o = file_ovl(file);
	struct qovl_ring ring;
	struct qovl_busy busy;
	struct qovl_config cfg;
	struct qovl_submit sub;
	struct qovl_wait wt;
	void *vaddr;
	dma_addr_t iova;
	size_t bytes;
	int rc = 0;

	if (o->dead)
		return -ENODEV;

	switch (cmd) {
	case QOVL_IOC_INFO:
		mutex_lock(&o->lock);
		ring.slot_bytes = o->slot_bytes;
		ring.nslots = o->nslots;
		ring.base_iova = o->vaddr ? (u64)o->iova : 0;
		ring.stride = (u64)o->slot_bytes;
		ring.gen = o->gen;
		ring.reserved = 0;
		mutex_unlock(&o->lock);
		return copy_to_user((void __user *)arg, &ring, sizeof(ring)) ?
		       -EFAULT : 0;

	case QOVL_IOC_SETUP:
		if (copy_from_user(&ring, (void __user *)arg, sizeof(ring)))
			return -EFAULT;
		if (ring.reserved)
			return -EINVAL;
		if (!ring.nslots || ring.nslots > QOVL_MAX_SLOTS)
			return -EINVAL;
		/* 64 B is the completion boundary (RCB), so a slot never starts
		 * mid-completion and first_be/last_be stay full for whole DWords. */
		if (!ring.slot_bytes || (ring.slot_bytes & 63U))
			return -EINVAL;
		/* All 4 slots have to fit the PS pool the writer lands into, or
		 * wr_dst_base walks off the end of overlay-pool@54000000. */
		if ((u64)ring.slot_bytes * ring.nslots > QOVL_PS_POOL_BYTES)
			return -EINVAL;
		bytes = (size_t)ring.slot_bytes * ring.nslots;
		mutex_lock(&o->lock);
		if (o->vaddr &&
		    (o->slot_bytes != ring.slot_bytes || o->nslots != ring.nslots)) {
			rc = -EBUSY;	/* the ring lives until the device is
					 * detached, so a different geometry is a
					 * reload, not a realloc: reallocating under
					 * an armed transfer is exactly the bug this
					 * file exists to avoid */
		} else if (!o->vaddr) {
			vaddr = dma_alloc_coherent(&o->pdev->dev, bytes, &iova,
						   GFP_KERNEL);
			if (!vaddr) {
				/* Not a transient out-of-memory.  Without an IOMMU
				 * the DMA address is the physical address, so the
				 * coherent buffer must be one physically contiguous
				 * block, and the buddy allocator cannot hand out more
				 * than 2^(MAX_ORDER-1) pages (4 MiB on current kernels,
				 * visible as the last column of /proc/buddyinfo).
				 * Compaction and drop_caches cannot fix that.  Either
				 * the platform exposes an IOMMU (ACPI DMAR present, VT-d
				 * enabled) so the DMA layer can map scattered pages as
				 * one IOVA range, or the ring has to be sized under the
				 * contiguous ceiling.  Saying so beats returning a bare
				 * ENOMEM that reads like the host simply had no RAM.
				 */
				dev_err(&o->pdev->dev,
					"overlay ring: %zu B contiguous coherent allocation failed; the card has no IOMMU domain (check /sys/bus/pci/devices/%s/iommu_group and the ACPI DMAR table), so this needs an IOVA-capable remap or a smaller ring\n",
					bytes, pci_name(o->pdev));
				rc = -ENOMEM;
			} else {
				o->vaddr = vaddr;
				o->iova = iova;
				o->bytes = bytes;
				o->slot_bytes = ring.slot_bytes;
				o->nslots = ring.nslots;
				o->gen++;
			}
		}
		ring.slot_bytes = o->slot_bytes;
		ring.nslots = o->nslots;
		ring.base_iova = o->vaddr ? (u64)o->iova : 0;
		ring.stride = (u64)o->slot_bytes;
		ring.gen = o->gen;
		mutex_unlock(&o->lock);
		if (!rc && copy_to_user((void __user *)arg, &ring, sizeof(ring)))
			return -EFAULT;
		return rc;

	case QOVL_IOC_FREE:
		/* Refused, deliberately.  The caller cannot prove the plane is
		 * retired from this side, and a freed page under a PCIe read that
		 * is still owed completions is the exact debt the drain-and-fence
		 * rule forbids.  The argument is still validated so a stale client
		 * cannot mistake a success for a release. */
		if (copy_from_user(&busy, (void __user *)arg, sizeof(busy)))
			return -EFAULT;
		if (busy.reserved || busy.outstanding)
			return -EINVAL;
		return -EOPNOTSUPP;

	case QOVL_IOC_CONFIG: {
		u64 dst;
		u32 fbytes, nslots, ctrl, comp;

		if (!o->bar0_csr_ok)
			return -EOPNOTSUPP;
		if (copy_from_user(&cfg, (void __user *)arg, sizeof(cfg)))
			return -EFAULT;
		if (cfg.reserved)
			return -EINVAL;

		mutex_lock(&o->lock);
		if (!o->vaddr) {
			mutex_unlock(&o->lock);
			return -EINVAL;
		}
		dst = cfg.ps_dst_base ? cfg.ps_dst_base : QOVL_PS_POOL_BASE;
		fbytes = cfg.frame_bytes ? cfg.frame_bytes : QOVL_RGBA_FRAME_BYTES;
		nslots = cfg.nslots ? cfg.nslots : o->nslots;
		if (!nslots || nslots > o->nslots || fbytes > o->slot_bytes) {
			mutex_unlock(&o->lock);
			return -EINVAL;
		}
		o->frame_bytes = fbytes;

		iowrite32((u32)dst, o->csr + QOVL_REG_DST_BASE_LO);
		iowrite32((u32)(dst >> 32), o->csr + QOVL_REG_DST_BASE_HI);
		iowrite32(o->slot_bytes, o->csr + QOVL_REG_SLOT_BYTES);
		iowrite32(fbytes, o->csr + QOVL_REG_FRAME_BYTES);
		iowrite32(fbytes, o->csr + QOVL_REG_XFER_BYTES);

		/* ovl_enable[0], wr_enable[4], wr_auto_advance[5], wr_slot_count[10:8] */
		ctrl = BIT(0) | BIT(4) | BIT(5) | ((nslots & 0x7U) << 8);
		iowrite32(ctrl, o->csr + QOVL_REG_CTRL);

		comp = (cfg.blend_enable ? BIT(0) : 0) |
		       (cfg.alpha_opaque ? BIT(1) : 0) |
		       ((cfg.flags & QOVL_CFG_RX_PASSTHROUGH) ? BIT(4) : 0);
		iowrite32(comp, o->csr + QOVL_REG_COMP_CTRL);
		ioread32(o->csr + QOVL_REG_COMP_CTRL);
		{
			unsigned long flags;
			spin_lock_irqsave(&o->irq_lock, flags);
			o->inflight = false;
			o->done_seq = o->submit_seq;
			spin_unlock_irqrestore(&o->irq_lock, flags);
		}
		mutex_unlock(&o->lock);
		return 0;
	}

	case QOVL_IOC_SUBMIT: {
		u32 xfer, seq, ctrl;
		dma_addr_t slot_iova;
		unsigned long flags;
		long wrc;

		if (!o->bar0_csr_ok)
			return -EOPNOTSUPP;
		if (copy_from_user(&sub, (void __user *)arg, sizeof(sub)))
			return -EFAULT;

		mutex_lock(&o->lock);
		if (!o->vaddr || sub.slot >= o->nslots) {
			mutex_unlock(&o->lock);
			return -EINVAL;
		}
		xfer = sub.bytes ? sub.bytes : o->frame_bytes;
		if (!xfer || xfer > o->slot_bytes || (xfer & 63U)) {
			mutex_unlock(&o->lock);
			return -EINVAL;
		}
		slot_iova = o->iova + (dma_addr_t)sub.slot * o->slot_bytes;
		mutex_unlock(&o->lock);

		/* Wait if previous frame is still in flight */
		spin_lock_irqsave(&o->irq_lock, flags);
		if (o->inflight) {
			spin_unlock_irqrestore(&o->irq_lock, flags);
			if (sub.flags & QOVL_SUBMIT_NONBLOCK)
				return -EAGAIN;
			wrc = wait_event_interruptible_timeout(
				o->wq, !READ_ONCE(o->inflight) || o->dead,
				msecs_to_jiffies(1000));
			if (o->dead)
				return -ENODEV;
			if (wrc < 0)
				return wrc;
			if (wrc == 0)
				return -ETIMEDOUT;
			spin_lock_irqsave(&o->irq_lock, flags);
		}
		o->inflight = true;
		seq = ++o->submit_seq;
		spin_unlock_irqrestore(&o->irq_lock, flags);

		/* Arm single frame transfer: ovl_go 0 -> 1 in pcie_user_clk */
		mutex_lock(&o->lock);
		ctrl = ioread32(o->csr + QOVL_REG_CTRL) & ~BIT(1);
		iowrite32(ctrl, o->csr + QOVL_REG_CTRL);
		iowrite32((u32)slot_iova, o->csr + QOVL_REG_SRC_LO);
		iowrite32((u32)(slot_iova >> 32), o->csr + QOVL_REG_SRC_HI);
		iowrite32(xfer, o->csr + QOVL_REG_XFER_BYTES);
		ioread32(o->csr + QOVL_REG_XFER_BYTES);
		iowrite32(ctrl | BIT(1), o->csr + QOVL_REG_CTRL);
		ioread32(o->csr + QOVL_REG_CTRL);
		{
			int tries;
			for (tries = 0; tries < 3; tries++) {
				u32 st = ioread32(o->csr + QOVL_REG_STATUS);
				if ((st & BIT(0)) || !READ_ONCE(o->inflight))
					break;
				iowrite32(ctrl, o->csr + QOVL_REG_CTRL);
				ioread32(o->csr + QOVL_REG_CTRL);
				iowrite32(ctrl | BIT(1), o->csr + QOVL_REG_CTRL);
				ioread32(o->csr + QOVL_REG_CTRL);
				dev_info_ratelimited(&o->pdev->dev,
					"ovl re-arm seq=%u try=%d st=0x%08x\n",
					seq, tries + 1, st);
			}
		}
		mutex_unlock(&o->lock);

		if (!(sub.flags & QOVL_SUBMIT_ASYNC)) {
			wrc = wait_event_interruptible_timeout(
				o->wq,
				(s32)(READ_ONCE(o->done_seq) - seq) >= 0 || o->dead,
				msecs_to_jiffies(1000));
			if (o->dead)
				return -ENODEV;
			if (wrc < 0)
				return wrc;
			if (wrc == 0)
				return -ETIMEDOUT;
		}
		sub.seq_out = seq;
		return copy_to_user((void __user *)arg, &sub, sizeof(sub)) ?
		       -EFAULT : 0;
	}

	case QOVL_IOC_WAIT: {
		u32 target, tmo_ms;
		long wrc;

		if (!o->bar0_csr_ok)
			return -EOPNOTSUPP;
		if (copy_from_user(&wt, (void __user *)arg, sizeof(wt)))
			return -EFAULT;

		target = wt.target_seq ? wt.target_seq : READ_ONCE(o->submit_seq);
		tmo_ms = wt.timeout_ms ? wt.timeout_ms : 1000U;
		wrc = wait_event_interruptible_timeout(
			o->wq,
			(s32)(READ_ONCE(o->done_seq) - target) >= 0 || o->dead,
			msecs_to_jiffies(tmo_ms));
		if (o->dead)
			return -ENODEV;
		if (wrc < 0)
			return wrc;
		if (wrc == 0) {
			dev_warn(&o->pdev->dev,
				 "ovl wait timeout: target=%u submit=%u done=%u inflight=%d status=0x%08x status2=0x%08x issued=%u\n",
				 target, READ_ONCE(o->submit_seq),
				 READ_ONCE(o->done_seq), READ_ONCE(o->inflight),
				 ioread32(o->csr + QOVL_REG_STATUS),
				 ioread32(o->csr + QOVL_REG_STATUS2),
				 ioread32(o->csr + 0x48));
			return -ETIMEDOUT;
		}

		wt.done_seq = READ_ONCE(o->done_seq);
		wt.status = ioread32(o->csr + QOVL_REG_STATUS);
		return copy_to_user((void __user *)arg, &wt, sizeof(wt)) ?
		       -EFAULT : 0;
	}

	default:
		return -ENOIOCTLCMD;
	}
}

static void ovl_vma_open(struct vm_area_struct *vma)
{
	struct qpcie_overlay *o = vma->vm_private_data;

	/* fork() duplicates the mapping: the child VMA is a second reference on
	 * pages the device may be reading. */
	mutex_lock(&o->lock);
	if (!o->dead)
		ovl_get(o);
	else
		vma->vm_private_data = NULL;
	mutex_unlock(&o->lock);
}

static void ovl_vma_close(struct vm_area_struct *vma)
{
	struct qpcie_overlay *o = vma->vm_private_data;

	if (o)
		ovl_put(o);
}

static const struct vm_operations_struct ovl_vm_ops = {
	.open	= ovl_vma_open,
	.close	= ovl_vma_close,
};

static int ovl_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct qpcie_overlay *o = file_ovl(file);
	unsigned long size = vma->vm_end - vma->vm_start;
	int rc = -ENODEV;

	mutex_lock(&o->lock);
	if (o->dead) {
		rc = -ENODEV;	/* device gone; do not create a new mapping */
	} else if (!o->vaddr) {
		rc = -ENXIO;		/* SETUP first; never map a stale iova */
	} else if (vma->vm_pgoff || size > o->bytes) {
		rc = -EINVAL;		/* one ring, mapped whole; slot offsets
					 * are added in the ring, not by pgoff,
					 * so a partial map cannot straddle it */
	} else {
		/* Take the VMA's reference before the pages are inserted, and
		 * hand vma_open() the same object so a fork is counted too. */
		ovl_get(o);
		vma->vm_private_data = o;
		vma->vm_ops = &ovl_vm_ops;
		rc = dma_mmap_coherent(&o->pdev->dev, vma, o->vaddr, o->iova,
				       size);
		if (rc) {
			vma->vm_private_data = NULL;
			vma->vm_ops = NULL;
			ovl_put(o);
		}
	}
	mutex_unlock(&o->lock);
	return rc;
}

static __poll_t ovl_poll(struct file *file, poll_table *wait)
{
	struct qpcie_overlay *o = file_ovl(file);
	__poll_t mask = 0;

	poll_wait(file, &o->wq, wait);
	if (o->dead)
		return EPOLLERR | EPOLLHUP;
	if (!READ_ONCE(o->inflight))
		mask |= EPOLLOUT | EPOLLWRNORM | EPOLLIN | EPOLLRDNORM;
	return mask;
}

static const struct file_operations ovl_fops = {
	.owner		= THIS_MODULE,
	.open		= ovl_open,
	.release	= ovl_close,
	.unlocked_ioctl	= ovl_ioctl,
	.compat_ioctl	= compat_ptr_ioctl,
	.poll		= ovl_poll,
	.mmap		= ovl_mmap,
};

void qpcie_overlay_irq_handler(struct qpcie_dev *qdev)
{
	struct qpcie_overlay *o = qdev->overlay;
	unsigned long flags;

	if (!o)
		return;
	spin_lock_irqsave(&o->irq_lock, flags);
	o->inflight = false;
	o->done_seq++;
	spin_unlock_irqrestore(&o->irq_lock, flags);
	wake_up_interruptible(&o->wq);
}

int qpcie_overlay_init(struct qpcie_dev *qdev)
{
	struct qpcie_overlay *o;
	int rc;
	u32 ver, caps;

	if (!qdev->is_zu4ev)
		return 0;
	ver  = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION);
	caps = ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_CAPS);
	if (!(caps & QPCIE_CAP_RGB_COMPOSITOR) && ver < QOVL_HW_VERSION_FLOOR) {
		dev_info(&qdev->pdev->dev,
			 "RGB overlay plane: fabric absent (version=%#x caps=%#x) -> no /dev node\n",
			 ver, caps);
		return 0;
	}

	o = kzalloc(sizeof(*o), GFP_KERNEL);
	if (!o)
		return -ENOMEM;
	/* The structure may outlive the PCI function (an fd or a mapping can be
	 * open across /sys/.../remove), so hold our own reference on the
	 * function: dma_free_coherent() in the final put needs &pdev->dev. */
	o->pdev = pci_dev_get(qdev->pdev);
	kref_init(&o->refs);	/* the registration reference */
	mutex_init(&o->lock);
	init_waitqueue_head(&o->wq);
	spin_lock_init(&o->irq_lock);
	o->frame_bytes = QOVL_RGBA_FRAME_BYTES;
	o->csr = qdev->bar0_mmio + QOVL_BAR0_OFFSET;
	o->bar0_csr_ok = (ioread32(o->csr + QOVL_REG_ID) == QOVL_ID_RGB1);
	atomic_set(&o->busy, 0);
	snprintf(o->name, sizeof(o->name), "qpcie-ovl-%s", pci_name(qdev->pdev));
	o->misc.minor = MISC_DYNAMIC_MINOR;
	o->misc.name = o->name;
	o->misc.fops = &ovl_fops;
	o->misc.mode = 0600;
	o->misc.parent = &qdev->pdev->dev;
	rc = misc_register(&o->misc);
	if (rc) {
		pci_dev_put(o->pdev);
		kfree(o);
		return rc;
	}
	qdev->overlay = o;
	dev_info(&qdev->pdev->dev,
		 "RGB overlay plane ring: /dev/%s (RGBA 4K slot = %u B, up to %u slots; admitted by %s, version=%#x caps=%#x)\n",
		 o->name, QOVL_RGBA_FRAME_BYTES, QOVL_MAX_SLOTS,
		 (caps & QPCIE_CAP_RGB_COMPOSITOR) ? "caps bit" : "version floor",
		 ver, caps);
	return 0;
}

void qpcie_overlay_remove(struct qpcie_dev *qdev)
{
	struct qpcie_overlay *o = qdev->overlay;

	if (!o)
		return;
	qdev->overlay = NULL;

	/* Order matters and is the whole point of this function.
	 *
	 * 1. dead=true under the lock: no new open, no ioctl, no mmap, and a
	 *    forked VMA refuses its extra reference.
	 * 2. misc_deregister(): the node disappears, so nothing can arrive after
	 *    this point.  Existing fds keep their own reference.
	 * 3. pci_clear_master(): Bus Master Enable is cleared in the PCIe
	 *     Command register, so the function must stop initiating Memory
	 *     Requests.  This is the only hardware-level isolation this driver
	 *     actually owns, and it is why releasing the ring is tied to detach
	 *     rather than to a number userspace typed.  module remove or rmmod
	 *     alone would not have said so; a /sys/.../remove does this too.
	 * 4. Only then drop the registration reference.  If an fd or a VMA still
	 *    holds the structure, the ring is deliberately retained (and the
	 *    pages stay owned by us) until the last one closes, instead of being
	 *    freed under a live mapping. */
	mutex_lock(&o->lock);
	o->dead = true;
	o->ring_retained = !!o->vaddr;
	mutex_unlock(&o->lock);
	wake_up_interruptible_all(&o->wq);

	misc_deregister(&o->misc);
	pci_clear_master(qdev->pdev);

	mutex_lock(&o->lock);
	if (o->ring_retained && !o->vaddr)
		o->ring_retained = false;
	mutex_unlock(&o->lock);

	ovl_put(o);	/* must be outside the lock: the last put frees */
}
