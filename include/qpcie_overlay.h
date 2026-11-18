/* SPDX-License-Identifier: GPL-2.0 */
/*
 * qpcie_overlay.h - host <-> card RGB-compositor overlay plane ABI.
 *
 * Direction: H2C.  rtl/sc7f0_overlay_ingress.v is a real PCIe read client: it
 * issues Memory Reads against a HOST address ("host IOVA of the plane",
 * rtl/sc7f0_rgb_overlay_ctrl.v CSR 0x04/0x08), reassembles the completions at
 * 256 bit in the 125 MHz user domain, and rtl/sc7f0_overlay_writer.v lands the
 * result in the PS DDR overlay pool for v_frmbuf_rd Reader-B.
 *
 * So the host must own a buffer that
 *   (a) is physically usable by the card, i.e. carries the same bus address
 *       dma_alloc_coherent() hands to the programming-DMA path in
 *       driver/qpcie_upgrade.c (REG_DMA_UPG_HOST_ADDR_L/H), and
 *   (b) is writable from userspace, because the RGBA pixels are produced there.
 *
 * (a) is a kernel-only fact: /proc/self/pagemap physical addresses are wrong
 * behind an IOMMU and break under any page migration, and no existing node in
 * this driver publishes a bus address.  This header therefore defines the
 * smallest interface that can be honest about it: the driver allocates a slot
 * ring, reports the bus address of each slot, and mmap()s the same coherent
 * pages into the client.
 *
 * Slot count is bounded by the hardware, not by taste: the ingress keeps one
 * reorder entry per outstanding read slot (NSLOT), rtl/
 * sc7f0_rgb_overlay_ctrl.v CSR 0x00[10:8] wr_slot_count is 3 bits and the
 * writer exposes wr_slot_ready[3:0], so the ring is 1..4 slots.  A ring longer
 * than 4 cannot be armed and would silently alias slot 0.
 *
 * Lifetime rule: the ring belongs to the device, not to the file descriptor.
 * A client that closes or crashes while a plane is armed must not yank the
 * pages out from under a PCIe read that is already in flight, so close() only
 * releases the client and QOVL_IOC_FREE is refused outright: nothing a client
 * can pass proves the plane retired, because CSR 0x40/0x44/0x68 are on the PS
 * side.  The ring returns when the device detaches, the one moment this driver
 * can clear Bus Master Enable itself.  The control structure and the
 * struct pci_dev are reference-counted (registration, every open struct file,
 * every live VMA) because removing the function through sysfs - which this
 * workflow does on every flash - does not respect the module refcount that
 * .owner protects.
 */
#ifndef QPCIE_OVERLAY_H
#define QPCIE_OVERLAY_H

#include <linux/types.h>
#include <linux/ioctl.h>

/* Contract geometry, both derived from the fabric, not chosen:
 *   RGBA8888 4K : stride 3840*4 = 15360 B, frame 15360*2160 = 33177600 B
 *   RGB24    4K : stride 3840*3 = 11520 B, frame 11520*2160 = 24883200 B
 * Full 4K60 needs 33177600*60 = 1.990656 GB/s (RGBA H2C) and 24883200*60 =
 * 1.492992 GB/s (RGB24 C2H); the 256-bit x 125 MHz intake is 4.0 GB/s. */
#define QOVL_RGBA_STRIDE_BYTES		15360U
#define QOVL_RGBA_FRAME_BYTES		33177600U
#define QOVL_RGB24_STRIDE_BYTES		11520U
#define QOVL_RGB24_FRAME_BYTES		24883200U

/* rtl/sc7f0_rgb_overlay_ctrl.v 0x00[10:8] wr_slot_count is 1..4. */
#define QOVL_MAX_SLOTS			4U

/* PS DDR landing area of the plane writer (device tree overlay-pool@54000000,
 * rtl/sc7f0_rgb_overlay_ctrl.v CSR 0x14/0x18 wr_dst_base). */
#define QOVL_PS_POOL_BASE		0x54000000ULL
#define QOVL_PS_POOL_BYTES		(128ULL << 20)

/* Overlay plane writer control window; the PS programs this (device tree
 * overlay-ctrl@b00a0000), never the host.  Recorded here so the host tool and
 * the PS tool quote the same number. */
#define QOVL_PS_CSR_BASE		0xB00A0000ULL
#define QOVL_CSR_ID			0x78U
#define QOVL_ID_RGB1			0x52474231U

#define QOVL_IOC_MAGIC			'Q'

/**
 * struct qovl_ring - SETUP in/out, INFO out.
 * @slot_bytes:  in, bytes per slot; must be a non-zero multiple of 64 and
 *               <= QOVL_PS_POOL_BYTES / nslots so 4 slots still fit the pool.
 * @nslots:      in, 1..QOVL_MAX_SLOTS.
 * @base_iova:   out, bus address of slot 0 as the card must use it.
 * @stride:      out, byte offset between consecutive slots.
 * @gen:         out, allocation generation; changes whenever the ring is
 *               (re)allocated, so a stale iova from a previous session is
 *               detectable instead of silently reading freed pages.
 * @reserved:    must be zero; lets the struct grow without a new number.
 */
struct qovl_ring {
	__u32 slot_bytes;
	__u32 nslots;
	__u64 base_iova;
	__u64 stride;
	__u32 gen;
	__u32 reserved;
};

/**
 * struct qovl_busy - argument of QOVL_IOC_FREE, retained but not honoured.
 * @outstanding: a value supplied by the caller.  It is NOT a hardware quiesce
 *               proof: CSR 0x40 STATUS, 0x44 STATUS2 and 0x68 SUPPRESSION are
 *               clocked by pl_clk0 on the PS side and this driver cannot read
 *               them, a command may still be queued rather than issued, and a
 *               cached read of 0 says nothing about completions still owed.
 *               Releasing coherent pages against those is how an in-flight
 *               Memory Read lands in recycled memory.  The ioctl therefore
 *               always fails with -EOPNOTSUPP and the ring is returned only
 *               when the device detaches, the one point where this driver can
 *               clear Bus Master Enable itself.  The struct is kept so an old
 *               client still gets a defined, non-silent answer.
 * @reserved:    must be zero.
 */
struct qovl_busy {
	__u32 outstanding;
	__u32 reserved;
};

#define QOVL_IOC_SETUP	_IOWR(QOVL_IOC_MAGIC, 0x40, struct qovl_ring)
#define QOVL_IOC_INFO	_IOR(QOVL_IOC_MAGIC, 0x41, struct qovl_ring)
/* Always -EOPNOTSUPP in this revision; see struct qovl_busy. */
#define QOVL_IOC_FREE	_IOW(QOVL_IOC_MAGIC, 0x42, struct qovl_busy)

/* Phase C-B: BAR0 Overlay CSR window (pcie_user_clk) + MSI frame sync */
#define QOVL_BAR0_OFFSET	0x4000U
#define QOVL_REG_CTRL		0x00U
#define QOVL_REG_SRC_LO		0x04U
#define QOVL_REG_SRC_HI		0x08U
#define QOVL_REG_XFER_BYTES	0x0CU
#define QOVL_REG_MAX_REQ	0x10U
#define QOVL_REG_DST_BASE_LO	0x14U
#define QOVL_REG_DST_BASE_HI	0x18U
#define QOVL_REG_SLOT_BYTES	0x1CU
#define QOVL_REG_FRAME_BYTES	0x20U
#define QOVL_REG_CONSUME	0x24U
#define QOVL_REG_COMP_CTRL	0x30U
#define QOVL_REG_STATUS		0x40U
#define QOVL_REG_STATUS2	0x44U
#define QOVL_REG_WR_FRAMES_DONE	0x54U
#define QOVL_REG_ID		0x78U

#define QOVL_SUBMIT_NONBLOCK	(1U << 0)
#define QOVL_SUBMIT_ASYNC	(1U << 1)

struct qovl_config {
	__u64 ps_dst_base;	/* 0 = default QOVL_PS_POOL_BASE (0x54000000) */
	__u32 frame_bytes;	/* 0 = default QOVL_RGBA_FRAME_BYTES */
	__u32 nslots;		/* 0 = keep ring nslots */
	__u32 blend_enable;	/* 0 or 1 */
	__u32 alpha_opaque;	/* 0 or 1 */
	__u32 flags;
	__u32 reserved;
};

struct qovl_submit {
	__u32 slot;		/* in: 0..nslots-1 */
	__u32 bytes;		/* in: 0 = frame_bytes */
	__u32 flags;		/* in: QOVL_SUBMIT_NONBLOCK | QOVL_SUBMIT_ASYNC */
	__u32 seq_out;		/* out: frame sequence number */
};

struct qovl_wait {
	__u32 target_seq;	/* in: 0 = wait for current submit_seq */
	__u32 timeout_ms;	/* in: 0 = 1000 ms default */
	__u32 done_seq;		/* out: latest completed seq */
	__u32 status;		/* out: BAR0 STATUS (0x40) */
};

#define QOVL_IOC_CONFIG	_IOW(QOVL_IOC_MAGIC, 0x43, struct qovl_config)
#define QOVL_IOC_SUBMIT	_IOWR(QOVL_IOC_MAGIC, 0x44, struct qovl_submit)
#define QOVL_IOC_WAIT	_IOWR(QOVL_IOC_MAGIC, 0x45, struct qovl_wait)

#endif /* QPCIE_OVERLAY_H */
