/* SPDX-License-Identifier: GPL-2.0 */
#ifndef QPCIE_PLANE_GATE_H
#define QPCIE_PLANE_GATE_H

/* One atomic transition selects a writer, including across asynchronous
 * commit work. A PS exec may outlive its fd, so maintenance is sticky. */
enum qpcie_plane_owner { PL_LEGACY, PL_IDLE, PL_DISPLAY, PL_MAINT, PL_DEAD };
#define PL_MASK 7
#define PL_MEDIA 8 /* higher bits: open capture/PCM leases */

static inline int qpcie_plane_maintenance(atomic_t *gate)
{
	int was = atomic_cmpxchg(gate, PL_IDLE, PL_MAINT);

	return (was & PL_MASK) == PL_DEAD ? -ENODEV :
		was >= PL_MEDIA || was == PL_DISPLAY ? -EBUSY : 0;
}

static inline int qpcie_plane_claim(atomic_t *gate)
{
	int was;
	do {
		was = atomic_read(gate);
		switch (was & PL_MASK) {
		case PL_DISPLAY: return 0;
		case PL_DEAD: return -ENODEV;
		case PL_IDLE: break;
		default: return -EBUSY;
		}
	} while (atomic_cmpxchg(gate, was, (was & ~PL_MASK) | PL_DISPLAY) != was);
	return 0;
}

static inline void qpcie_plane_release(atomic_t *gate)
{
	int was;
	do {
		was = atomic_read(gate);
		if ((was & PL_MASK) != PL_DISPLAY)
			return;
	} while (atomic_cmpxchg(gate, was, (was & ~PL_MASK) | PL_IDLE) != was);
}

static inline int qpcie_media_claim(atomic_t *gate)
{
	int was;
	do {
		was = atomic_read(gate);
		if ((was & PL_MASK) == PL_DEAD)
			return -ENODEV;
		if ((was & PL_MASK) == PL_MAINT || was >= INT_MAX - PL_MEDIA)
			return -EBUSY;
	} while (atomic_cmpxchg(gate, was, was + PL_MEDIA) != was);
	return 0;
}

static inline int qpcie_plane_kill(atomic_t *gate)
{
	int was;
	do {
		was = atomic_read(gate);
	} while (atomic_cmpxchg(gate, was, (was & ~PL_MASK) | PL_DEAD) != was);
	return was & PL_MASK;
}
#endif
