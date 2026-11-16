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
#include <linux/slab.h>

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
 * moves with it; an older card is refused here instead of half-working. */
#define QOVL_HW_VERSION 0x26111503U

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
	atomic_set(&o->busy, 0);
	ovl_put(o);
	return 0;
}

static long ovl_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct qpcie_overlay *o = file_ovl(file);
	struct qovl_ring ring;
	struct qovl_busy busy;
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

static const struct file_operations ovl_fops = {
	.owner		= THIS_MODULE,
	.open		= ovl_open,
	.release	= ovl_close,
	.unlocked_ioctl	= ovl_ioctl,
	.compat_ioctl	= compat_ptr_ioctl,
	.mmap		= ovl_mmap,
};

int qpcie_overlay_init(struct qpcie_dev *qdev)
{
	struct qpcie_overlay *o;
	int rc;

	if (!qdev->is_zu4ev)
		return 0;
	if (ioread32(qdev->bar0_mmio + REG_NEW_GLOBAL_VERSION) != QOVL_HW_VERSION)
		return 0;

	o = kzalloc(sizeof(*o), GFP_KERNEL);
	if (!o)
		return -ENOMEM;
	/* The structure may outlive the PCI function (an fd or a mapping can be
	 * open across /sys/.../remove), so hold our own reference on the
	 * function: dma_free_coherent() in the final put needs &pdev->dev. */
	o->pdev = pci_dev_get(qdev->pdev);
	kref_init(&o->refs);	/* the registration reference */
	mutex_init(&o->lock);
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
		 "RGB overlay plane ring: /dev/%s (RGBA 4K slot = %u B, up to %u slots)\n",
		 o->name, QOVL_RGBA_FRAME_BYTES, QOVL_MAX_SLOTS);
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

	misc_deregister(&o->misc);
	pci_clear_master(qdev->pdev);

	mutex_lock(&o->lock);
	if (o->ring_retained && !o->vaddr)
		o->ring_retained = false;
	mutex_unlock(&o->lock);

	ovl_put(o);	/* must be outside the lock: the last put frees */
}
