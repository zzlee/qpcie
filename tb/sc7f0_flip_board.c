/* Stage-1 x86 board fixture. Use only with exclusive access, a live base and
 * the legacy allocator with pinned-until-detach ring lifetime. No /dev/mem. */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include "../include/qpcie_overlay.h"

static volatile uint32_t *bar;
static uint32_t rd(unsigned off) { return bar[off/4]; }
static void wr(unsigned off, uint32_t x) { bar[off/4]=x; }
static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC,&t);
	return t.tv_sec+t.tv_nsec*1e-9;
}
static int wait_reg(unsigned off, uint32_t v) {
	double t=now()+2;
	do {
		if (rd(off)==v) return 0;
		if (rd(QOVL_REG_FLIP_STATUS)&QOVL_FLIP_FAULT) break;
		usleep(200);
	} while (now()<t);
	fprintf(stderr,"timeout/fault off=%x want=%x got=%x status=%x\n",
		off,v,rd(off),rd(QOVL_REG_FLIP_STATUS));
	return -1;
}
int main(int argc, char **argv) {
	struct qovl_ring ring={.slot_bytes=QOVL_RGBA_FRAME_BYTES,.nslots=2};
	int rc=1;
	if (argc!=3) { fprintf(stderr,"usage: %s PCI_RESOURCE0 QOVL_DEVICE\n",argv[0]);return 2; }
	int dev=open(argv[2],O_RDWR|O_CLOEXEC), res=open(argv[1],O_RDWR|O_SYNC|O_CLOEXEC);
	if (dev<0 || res<0) { perror("open");return 1; }
	bar=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,res,QOVL_BAR0_OFFSET);
	if (bar==MAP_FAILED) { perror("BAR mmap");return 1; }
	printf("block=%08x capability=%08x frame=%u\n",rd(QOVL_REG_ID),rd(QOVL_REG_FLIP_CAP),rd(QOVL_REG_FLIP_FRAME));
	if (rd(QOVL_REG_ID)!=QOVL_ID_RGB1 || rd(QOVL_REG_FLIP_CAP)!=QOVL_FLIP_CAP_V1 ||
	    rd(QOVL_REG_FLIP_CTRL)!=0 || (rd(QOVL_REG_CTRL)&15) ||
	    rd(QOVL_REG_FLIP_STATUS)!=QOVL_FLIP_DRAINED) return 1;
	uint32_t first=rd(QOVL_REG_FLIP_ADMITTED)+1;
	if (!first || first>0xffffff00U) return 1;
	if (ioctl(dev,QOVL_IOC_SETUP,&ring)) { perror("setup");return 1; }
	if (ring.nslots!=2 || ring.stride<QOVL_RGBA_FRAME_BYTES || (ring.base_iova|ring.stride)&31) return 1;
	size_t bytes=ring.stride*ring.nslots;
	unsigned char *pixels=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,dev,0);
	if (pixels==MAP_FAILED) { perror("pixels mmap");return 1; }
	for (int i=0;i<2;i++) {
		uint32_t *slot=(void *)(pixels+i*ring.stride);
		for (unsigned j=0;j<QOVL_RGBA_FRAME_BYTES/4;j++) slot[j]=i?0x8844ff00U:0x880000ffU;
	}
	__sync_synchronize();
	uint32_t comp=rd(QOVL_REG_COMP_CTRL);
	wr(QOVL_REG_COMP_CTRL,(comp|1)&~4U);
	wr(QOVL_REG_FLIP_CTRL,QOVL_FLIP_ENABLE); /* poll; legacy IRQ handler inactive */
	if (rd(QOVL_REG_FLIP_CTRL)!=QOVL_FLIP_ENABLE) goto cleanup;
	wr(QOVL_REG_XFER_BYTES,QOVL_RGBA_FRAME_BYTES);wr(QOVL_REG_MAX_REQ,2048);
	for (unsigned i=0;i<32;i++) {
		uint32_t c=first+i;
		uint64_t addr=ring.base_iova+(i%2)*ring.stride;
		wr(QOVL_REG_SRC_LO,(uint32_t)addr);wr(QOVL_REG_SRC_HI,addr>>32);
		wr(QOVL_REG_FLIP_SUBMIT,c);
		if (rd(QOVL_REG_FLIP_ADMITTED)!=c || wait_reg(QOVL_REG_FLIP_ACTIVE,c) ||
		    rd(QOVL_REG_FLIP_PENDING)!=0 || (i && rd(QOVL_REG_FLIP_RETIRED)!=c-1)) goto cleanup;
		if (!i) {
			uint32_t f=rd(QOVL_REG_FLIP_FRAME);
			sleep(10);
			uint32_t elapsed=rd(QOVL_REG_FLIP_FRAME)-f;
			printf("idle=10s active=%08x frame_delta=%u\n",rd(QOVL_REG_FLIP_ACTIVE),elapsed);
			if (rd(QOVL_REG_FLIP_ACTIVE)!=c || elapsed<570 || elapsed>630) goto cleanup;
		}
		usleep((i*7919)%35000);
	}
	rc=0;
cleanup:
	wr(QOVL_REG_FLIP_CTRL,0);
	if (wait_reg(QOVL_REG_FLIP_STATUS,QOVL_FLIP_DRAINED)) rc=1;
	wr(QOVL_REG_COMP_CTRL,comp);
	printf("drain=%x active=%x pending=%x result=%s\n",rd(QOVL_REG_FLIP_STATUS),
	       rd(QOVL_REG_FLIP_ACTIVE),rd(QOVL_REG_FLIP_PENDING),rc?"FAIL":"PASS");
	return rc;
}
