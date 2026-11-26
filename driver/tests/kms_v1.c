// SPDX-License-Identifier: GPL-2.0
/* Exercise the actual register backend with independently controlled latch,
 * retirement, IRQ/frame count, drain, and failed reads. No PCI access. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include "../../include/qpcie_overlay.h"
#define __iomem
#define BIT(n) (1U << (n))
#define U32_MAX UINT32_MAX
#define lower_32_bits(v) ((uint32_t)(v))
#define upper_32_bits(v) ((uint32_t)((v) >> 32))
typedef uint32_t u32;
typedef uint64_t dma_addr_t;
static uint32_t regs[64];
static bool gone, admit, drain;
static unsigned submits, barriers;

static u32 readl(void *addr)
{
	return gone ? UINT32_MAX : *(u32 *)addr;
}
static void writel(u32 v, void *addr)
{
	unsigned offset = (char *)addr - (char *)regs;

	assert(!gone);
	regs[offset / 4] = v;
	if (offset == QOVL_REG_FLIP_SUBMIT) {
		assert(++submits == barriers);
		if (admit) {
			regs[QOVL_REG_FLIP_ADMITTED / 4] = v;
			regs[QOVL_REG_FLIP_PENDING / 4] = v;
		}
	}
	if (offset == QOVL_REG_FLIP_CTRL) {
		regs[QOVL_REG_FLIP_STATUS / 4] = 0;
		if (!v && drain) {
			regs[QOVL_REG_FLIP_STATUS / 4] = QOVL_FLIP_DRAINED;
			regs[QOVL_REG_FLIP_ACTIVE / 4] = 0;
			regs[QOVL_REG_FLIP_PENDING / 4] = 0;
		}
	}
}
#define dma_wmb() (++barriers)
#include "../qpcie_kms_v1.h"

int main(void)
{
	const dma_addr_t addr = UINT64_C(0x4200100000);
	bool shown;
	assert(dp_epoch_supported(0x26112407) && !dp_epoch_supported(0x26112405));
	assert(!dp_epoch_supported(0x26112406) && !dp_epoch_supported(U32_MAX));
	assert(!dp_present(regs));
	assert(dp_submit(regs, addr, 4, 0) < 0 && !submits);
	regs[QOVL_REG_FLIP_CAP / 4] = QOVL_FLIP_CAP_V1;
	regs[QOVL_REG_FLIP_STATUS / 4] = QOVL_FLIP_DRAINED;
	regs[QOVL_REG_CTRL / 4] = 1;
	assert(dp_submit(regs, addr, 4, 0) < 0 && !submits);
	regs[QOVL_REG_CTRL / 4] = 0;
	admit = true;
	assert(dp_submit(regs, addr, 4, 0) == 0);
	assert(regs[QOVL_REG_SRC_HI / 4] == 0x42);
	assert(regs[QOVL_REG_SRC_LO / 4] == 0x100000);
	assert(regs[QOVL_REG_XFER_BYTES / 4] == 33177600);
	for (unsigned frame = 0; frame < 30; ++frame) {
		regs[QOVL_REG_FLIP_FRAME / 4]++;
		assert(dp_completed(regs, 4, 0, &shown) == 0 && !shown);
	}
	assert(dp_submit(regs, addr, 5, 0) < 0 && submits == 1);
	regs[QOVL_REG_FLIP_ACTIVE / 4] = 4;
	regs[QOVL_REG_FLIP_PENDING / 4] = 0;
	assert(dp_completed(regs, 4, 0, &shown) == 1 && shown);
	assert(dp_submit(regs, addr + 0x2000000, 5, 4) == 0);
	regs[QOVL_REG_FLIP_ACTIVE / 4] = 5;
	regs[QOVL_REG_FLIP_PENDING / 4] = 0;
	assert(dp_completed(regs, 5, 4, &shown) == 0 && shown);
	regs[QOVL_REG_FLIP_RETIRED / 4] = 4;
	assert(dp_completed(regs, 5, 4, &shown) == 1 && shown);
	regs[QOVL_REG_FLIP_STATUS / 4] = QOVL_FLIP_FAULT;
	assert(dp_completed(regs, 5, 4, &shown) < 0);
	assert(dp_disable(regs, 5) < 0);
	drain = true;
	assert(dp_disable(regs, 5) == 0);
	regs[QOVL_REG_FLIP_ADMITTED / 4] = 0;
	assert(dp_disable(regs, 5) < 0); /* reset is not a drain fence */
	admit = false;
	assert(dp_submit(regs, addr, 6, 0) < 0);
	gone = true;
	assert(dp_completed(regs, 6, 0, &shown) < 0 && dp_disable(regs, 6) < 0);
	puts("PASS: ABI gate, admission, descriptor, hold, presentation, retirement, fault and disable/drain");
}
