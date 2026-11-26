/* SPDX-License-Identifier: GPL-2.0 */
/* BAR access for docs/sc7f0_direct_pull_v1.md. The frontend uses no legacy
 * done IRQ, wall-clock vblank or inferred PCI address. */
#ifndef QPCIE_KMS_V1_H
#define QPCIE_KMS_V1_H
#include <linux/iopoll.h>
#include "../include/qpcie_overlay.h"

/* Same signature was advertised by pre-epoch-fix prototypes. */
#define QPCIE_KMS_FW 0x26112407U

static inline bool dp_epoch_supported(u32 fw)
{
	return fw == QPCIE_KMS_FW;
}

static inline bool dp_present(void __iomem *csr)
{
	return readl(csr + QOVL_REG_FLIP_CAP) == QOVL_FLIP_CAP_V1;
}

static inline bool dp_idle(void __iomem *csr)
{
	return readl(csr + QOVL_REG_FLIP_CTRL) == 0 &&
	       !(readl(csr + QOVL_REG_CTRL) & 3) &&
	       readl(csr + QOVL_REG_FLIP_STATUS) == QOVL_FLIP_DRAINED &&
	       readl(csr + QOVL_REG_FLIP_ACTIVE) == 0 &&
	       readl(csr + QOVL_REG_FLIP_PENDING) == 0 &&
	       dp_present(csr);
}

static inline int dp_disable(void __iomem *csr, u32 serial)
{
	u32 status;

	if (!dp_present(csr))
		return -ENODEV;
	/* Leave the live HDMI base path selected, with blend bypassed. */
	writel(BIT(4), csr + QOVL_REG_COMP_CTRL);
	writel(0, csr + QOVL_REG_FLIP_CTRL);
	if (readl_poll_timeout(csr + QOVL_REG_FLIP_STATUS, status,
			       status == QOVL_FLIP_DRAINED || status == U32_MAX,
			       500, 250000) || !dp_idle(csr) ||
	    readl(csr + QOVL_REG_FLIP_ADMITTED) != serial)
		return -EIO;
	return 0;
}

static inline int dp_submit(void __iomem *csr, dma_addr_t addr, u32 cookie,
			    u32 old)
{
	if (!dp_present(csr) || readl(csr + QOVL_REG_FLIP_PENDING) ||
	    readl(csr + QOVL_REG_FLIP_ACTIVE) != old ||
	    (readl(csr + QOVL_REG_FLIP_STATUS) & QOVL_FLIP_FAULT))
		return -EIO;
	if (!old) {
		if (!dp_idle(csr))
			return -EBUSY;
		writel(QOVL_FLIP_ENABLE | QOVL_FLIP_FRAME_IRQ,
		       csr + QOVL_REG_FLIP_CTRL);
		writel(BIT(4) | BIT(0), csr + QOVL_REG_COMP_CTRL);
	}
	writel(lower_32_bits(addr), csr + QOVL_REG_SRC_LO);
	writel(upper_32_bits(addr), csr + QOVL_REG_SRC_HI);
	writel(QOVL_RGBA_FRAME_BYTES, csr + QOVL_REG_XFER_BYTES);
	writel(0, csr + QOVL_REG_MAX_REQ);
	dma_wmb();
	writel(cookie, csr + QOVL_REG_FLIP_SUBMIT);
	return readl(csr + QOVL_REG_FLIP_ADMITTED) == cookie ? 0 : -EIO;
}

/* 0: still owned, +1: both proofs, negative: fail closed. Validate status
 * after cookie reads as well, so a dead BAR cannot look like a retired FB. */
static inline int dp_completed(void __iomem *csr, u32 cookie, u32 old,
			       bool *presented)
{
	bool shown = readl(csr + QOVL_REG_FLIP_ACTIVE) == cookie &&
		     readl(csr + QOVL_REG_FLIP_PENDING) == 0;
	bool retired = !old || readl(csr + QOVL_REG_FLIP_RETIRED) == old;

	if (!dp_present(csr) ||
	    readl(csr + QOVL_REG_FLIP_ADMITTED) != cookie ||
	    readl(csr + QOVL_REG_FLIP_CTRL) !=
			(QOVL_FLIP_ENABLE | QOVL_FLIP_FRAME_IRQ) ||
	    readl(csr + QOVL_REG_FLIP_STATUS) & QOVL_FLIP_FAULT)
		return -EIO;
	*presented = shown;
	return shown && retired;
}
#endif
