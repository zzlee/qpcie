/* SPDX-License-Identifier: GPL-2.0 */
/* Bounded fake time for the v1 MMIO test only. */
#define readl_poll_timeout(addr, value, done, delay, timeout) ({ \
	int n = 4; \
	do { value = readl(addr); if (done) break; } while (--n); \
	n ? 0 : -ETIMEDOUT; })
