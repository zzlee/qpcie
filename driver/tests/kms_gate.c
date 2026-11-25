// SPDX-License-Identifier: GPL-2.0
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
typedef atomic_int atomic_t;
#define atomic_read(p) atomic_load(p)
static int atomic_cmpxchg(atomic_t *p, int old, int new)
{
	atomic_compare_exchange_strong(p, &old, new);
	return old;
}
#include "../qpcie_plane_gate.h"

static atomic_t gate;
static pthread_barrier_t barrier;
static int mgmt;
enum { N = 10000 };
static void *writer(void *arg)
{
	for (int i = 0; i < N; ++i) {
		pthread_barrier_wait(&barrier);
		mgmt = qpcie_plane_maintenance(&gate);
		pthread_barrier_wait(&barrier);
	}
	return arg;
}
int main(void)
{
	pthread_t t;
	pthread_barrier_init(&barrier, NULL, 2);
	assert(!pthread_create(&t, NULL, writer, NULL));
	for (int i = 0; i < N; ++i) {
		atomic_store(&gate, PL_IDLE);
		pthread_barrier_wait(&barrier);
		int kms = (i & 1) ? qpcie_plane_claim(&gate) : qpcie_media_claim(&gate);
		pthread_barrier_wait(&barrier);
		assert((kms == 0 && mgmt == -EBUSY) ||
		       (kms == -EBUSY && mgmt == 0));
		if (!(i & 1) && !kms) {
			assert(!qpcie_plane_claim(&gate)); /* display during capture */
			assert(!qpcie_media_claim(&gate)); /* simultaneous PCM/VCU */
			qpcie_plane_release(&gate);
			atomic_fetch_sub(&gate, PL_MEDIA);
			assert(qpcie_plane_maintenance(&gate) == -EBUSY);
			atomic_fetch_sub(&gate, PL_MEDIA);
		} else
			qpcie_plane_release(&gate);
		if (kms) /* Arbitrary PS command may still be executing. */
			assert(qpcie_plane_claim(&gate) == -EBUSY);
		else
			assert(qpcie_plane_maintenance(&gate) == 0);
	}
	pthread_join(t, NULL);
	atomic_store(&gate, PL_DISPLAY + PL_MEDIA);
	assert(qpcie_plane_kill(&gate) == PL_DISPLAY);
	qpcie_plane_release(&gate);
	assert(qpcie_plane_claim(&gate) == -ENODEV &&
	       qpcie_plane_maintenance(&gate) == -ENODEV &&
	       qpcie_media_claim(&gate) == -ENODEV);
	assert(atomic_fetch_sub(&gate, PL_MEDIA) == PL_DEAD + PL_MEDIA);
	atomic_store(&gate, PL_LEGACY);
	assert(qpcie_plane_maintenance(&gate) == 0);
	assert(qpcie_plane_claim(&gate) == -EBUSY);
	puts("PASS: 10000 concurrent media/display vs management claims, simultaneous media/display, sticky maintenance, quarantine");
}
