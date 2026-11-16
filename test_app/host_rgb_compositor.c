// SPDX-License-Identifier: GPL-2.0
/*
 * host_rgb_compositor.c - host half of SC7F0-RGB-COMPOSITOR-2PPC (0x26111503).
 *
 * Two independent directions, both proven against bytes rather than against a
 * return code:
 *
 *   tx   Host -> card (H2C).  RGBA8888 planes are written into a coherent slot
 *        ring that driver/qpcie_overlay.c allocated, so the bus address handed
 *        to the card is the one the card will actually put on the PCIe fabric.
 *        rtl/sc7f0_overlay_ingress.v then READS that address (256-bit intake in
 *        the 125 MHz user domain), rtl/sc7f0_overlay_writer.v lands it in the
 *        PS DDR overlay pool, and v_frmbuf_rd Reader-B scans it out behind the
 *        alpha blender, so the result is visible on the HDMI output.
 *
 *   rx   Card -> host (C2H).  Packed RGB24 frames, stride 3840*3 = 11520 B and
 *        11520*2160 = 24883200 B per frame, arriving in the channel-0 V4L2 MMAP
 *        ring.  rtl/sc7f0_rgb_overlay_ctrl.v:0x68[0] refuses to arm the overlay
 *        unless the channel-0 descriptor is this same packed RGB24 profile, so
 *        the geometry this program checks is the geometry the fabric expects.
 *
 * Control path, and why it is not a new one
 *   CSR 0xB00A0000 is clocked by pl_clk0 and belongs to the PS (device tree
 *   overlay-ctrl@b00a0000); the host has no window onto it and this program
 *   does not pretend otherwise.  Arming, consume and status therefore go
 *   through the already-audited debug mailbox, as
 *       sc7f0ctl exec 'sc7f0_rgb_overlay dump'
 *   which returns the machine-readable name=0xVALUE dump.  Inventing a BAR0
 *   alias for the same block would create a second, unaudited ABI to a controller
 *   whose abort semantics are subtle enough already.
 *
 * Slot recycling, which is the part that can corrupt a board
 *   A slot may only be refilled once the writer has published it: this program
 *   waits for frames (0x54) to advance AND for suppression (0x68) to be clear
 *   AND for status2 outstanding (0x44[5:0]) to reach zero, and it PUBLISHES the
 *   slot to the reader with `consume <slot>` before treating it as free.  It
 *   never resets the writer to manufacture an idle state and never reuses a
 *   slot on a timeout: an abandoned overlay tag is still owed a completion, and
 *   writing the buffer under a read that is still in flight is exactly the debt
 *   the drain-and-fence rule forbids.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#include "../include/qpcie_overlay.h"

#define QPCIE_VENDOR	0x12ABu
#define QPCIE_DEVICE	0xE380u

/* A card command is one mailbox frame: sc7f0ctl rejects a command whose length
 * reaches the 2048-byte DB_PAYLOAD window, and the "ctl exec ''" wrapper plus
 * quoting eats a few more.  Named locally so this file cannot collide with
 * qpcie_debug.h if that header is ever included here. */
#define OVL_CMD_MAX	(2048U - 64U)

#define PLANE_B_CSR	0xB0090000ULL	/* compositor Reader-B      */
#define READER_A_CSR	0xB0080000ULL	/* compositor Reader-A      */

/* ------------------------------------------------------------------ util */

static uint64_t now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void msleep(unsigned ms)
{
	struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000L };

	nanosleep(&ts, NULL);
}

/* Find the card by vendor:device rather than by a remembered BDF: the upgrade
 * flow removes and rescans the device, so a hard-coded 03:00.0 goes stale. */
static int find_bdf(char *out, size_t len)
{
	DIR *d = opendir("/sys/bus/pci/devices");
	struct dirent *e;
	int found = 0;

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		char p[256];
		FILE *f;
		unsigned v = 0, id = 0;

		if (sscanf(e->d_name, "%*x:%*x:%*x.%*1s") != 1 &&
		    strlen(e->d_name) < 12)
			continue;
		snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/vendor", e->d_name);
		if (!(f = fopen(p, "r")))
			continue;
		if (fscanf(f, "%x", &v) != 1) {
			fclose(f);
			continue;
		}
		fclose(f);
		snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/device", e->d_name);
		if (!(f = fopen(p, "r")))
			continue;
		if (fscanf(f, "%x", &id) == 1 && v == QPCIE_VENDOR && id == QPCIE_DEVICE) {
			snprintf(out, len, "%s", e->d_name);
			found = 1;
		}
		fclose(f);
		if (found)
			break;
	}
	closedir(d);
	return found ? 0 : -1;
}

/* ------------------------------------------------- control: mailbox exec */

/* Name the card-side helper absolutely, and let the operator override it.
 * A bare name resolved through the card's PATH is how a stale
 * /usr/bin/sc7f0_rgb_overlay (7-argument build, sha 4d299b57...) answered the
 * 8-argument `arm` with a usage error that the old ps_exec threw away, so the
 * Host reported "arm ok" while the PL had written nothing. */
static const char *ovl_tool(void)
{
	const char *t = getenv("SC7F0_OVL_TOOL");

	if (t && *t)
		return t;
	return "/usr/local/bin/sc7f0_rgb_overlay";
}

/* Run one command on the card PS and capture its stdout.  Returns 0 on a
 * clean card-side exit, the card's own exit status when the command ran and
 * failed, or -1 when the transport itself failed - which is NOT evidence the
 * card is unhealthy, so callers must not treat it as "no signal". */
static int ps_exec(const char *ctl, const char *cmd, char **out, size_t *out_len)
{
	FILE *f;
	char *buf = NULL;
	char shell[OVL_CMD_MAX + 128];
	size_t cap = 0, n = 0;
	int rc;

	if (strlen(cmd) > OVL_CMD_MAX) {
		fprintf(stderr, "card command too long\n");
		return -1;
	}
	fflush(stdout);
	snprintf(shell, sizeof shell, "%s exec '%s' 2>&1", ctl, cmd);
	f = popen(shell, "r");
	if (!f)
		return -1;
	for (;;) {
		char tmp[4096];
		size_t got = fread(tmp, 1, sizeof tmp, f);

		if (!got)
			break;
		if (n + got + 1 > cap) {
			cap = (n + got + 1) * 2;
			buf = realloc(buf, cap);
			if (!buf) {
				pclose(f);
				free(buf);
				return -1;
			}
		}
		memcpy(buf + n, tmp, got);
		n += got;
	}
	buf = realloc(buf, n + 1);
	if (!buf) {
		pclose(f);
		return -1;
	}
	buf[n] = '\0';
	rc = pclose(f);
	if (!WIFEXITED(rc) || WEXITSTATUS(rc) != 0) {
		/* A card-side refusal used to disappear here: stderr went to
		 * /dev/null and the exit status was never examined, so "the helper
		 * rejected the command and the PL wrote nothing" was
		 * indistinguishable from success.  Echo the card's own words and
		 * report the failure instead. */
		int st = WIFEXITED(rc) ? WEXITSTATUS(rc) : -1;

		fflush(stdout);
		fprintf(stderr, "card command failed (rc=%d): %s\n%s", st, cmd, buf);
		free(buf);
		return st;
	}
	if (out) {
		*out = buf;
		if (out_len)
			*out_len = n;
		return 0;
	}
	fputs(buf, stdout);
	free(buf);
	return 0;
}

/* Parse one `name=0xVALUE` line out of `sc7f0_rgb_overlay dump`. */
static int dump_get(const char *dump, const char *name, uint64_t *val)
{
	const char *p = dump;
	size_t l = strlen(name);

	while ((p = strstr(p, name))) {
		if ((p == dump || !isalnum((unsigned char)p[-1])) && p[l] == '=') {
			*val = strtoull(p + l + 1, NULL, 0);
			return 0;
		}
		p += l;
	}
	return -1;
}

struct ovl_state {
	uint64_t id, status, status2, suppression, frames, issued, staged, drained;
	uint64_t wr_bytes, lock_lost, sat_watchdog, wr_err_frames;
};

static int ovl_read(const char *ctl, struct ovl_state *s)
{
	char *dump = NULL;
	char cmd[OVL_CMD_MAX];
	size_t n;
	int rc;

	snprintf(cmd, sizeof cmd, "%s dump", ovl_tool());
	rc = ps_exec(ctl, cmd, &dump, &n);
	if (rc != 0 || !dump)
		return -1;
#define GET(field, name)							\
	dump_get(dump, name, &s->field)
	GET(id, "id"); GET(status, "status"); GET(status2, "status2");
	GET(suppression, "suppression"); GET(frames, "frames");
	GET(issued, "issued"); GET(staged, "staged"); GET(drained, "drained");
	GET(wr_bytes, "wr_bytes"); GET(lock_lost, "lock_lost");
	GET(sat_watchdog, "sat_watchdog"); GET(wr_err_frames, "wr_err_frames");
#undef GET
	free(dump);
	return rc;
}

/* ------------------------------------------------------------------ fill */

/*
 * RGBA8888 test plane.  Byte order is the one v_frmbuf_rd answers for
 * "abgr8888" (DRM_FORMAT_ABGR8888, fourcc "AB24"), i.e. little-endian memory
 * A,B,G,R at offsets 3,2,1,0 - and pixel 0 sits in the LSB of the 64-bit beat,
 * which the compositor already satisfies, so no pair swap is applied here.
 *
 * The alpha ramp is the point of the pattern: the blender computes
 *   out = ((255 - A) * BG + A * FG + 127) / 255
 * per channel, so a plane whose A is constant cannot tell a correct blend from
 * an opaque copy.  Column 0..255 sweeps A through a full range, and the block
 * index moves the colour so a slot that was never refilled is visible as a
 * frozen region rather than as a plausible frame.
 */
static void fill_rgba(uint8_t *p, uint32_t w, uint32_t h, uint32_t stride,
		      unsigned frame)
{
	for (uint32_t y = 0; y < h; y++) {
		uint32_t *row = (uint32_t *)(p + (size_t)y * stride);

		for (uint32_t x = 0; x < w; x++) {
			uint32_t a = (x + frame) & 0xffu;
			uint32_t r = (x >> 3) & 0xffu;
			uint32_t g = (y >> 2) & 0xffu;
			uint32_t b = ((x ^ y) >> 1) & 0xffu;

			row[x] = (a << 24) | (b << 16) | (g << 8) | r;
		}
	}
	/* Corner marker: frame number in the top-left 8 pixels' red channel, so
	 * "which frame is on the monitor" is readable without a capture. */
	for (uint32_t x = 0; x < 8 && x < w; x++)
		((uint32_t *)p)[x] = (0xffu << 24) | (frame & 0xffu);
}

/* ------------------------------------------------------- fill (ring only) */

/*
 * Pre-fill the retained host ring with one distinct fill_rgba() pattern per
 * slot and do NOTHING else: no arming, no mailbox command, no per-frame work.
 *
 * This exists to keep a resident arm-loop rate figure honest about its own
 * scope.  QOVL_IOC_SETUP with unchanged geometry reuses the ring the driver
 * already retained (same base_iova, same gen - driver/qpcie_overlay.c refuses a
 * different geometry with -EBUSY rather than reallocating under an armed
 * transfer), so the ring the card is about to re-read is the ring that is
 * already DMA-mapped.  Writing it once, before the loop starts, means the
 * measured rate is "the writer re-reads a static ring", not an end-to-end rate
 * that includes a producer refilling 33 MB per frame.  The per-slot fill time
 * printed here is the missing half, measured on its own.
 *
 * Slot k carries fill_rgba(..., frame = frame_base + k), which is exactly the
 * frame index test_app/sc7f0_fill_oracle.c hashes, so the destination can be
 * verified against a real expectation rather than a dummy.
 */
static int cmd_fill(int argc, char **argv)
{
	const char *dev = NULL, *bdf = NULL;
	uint32_t slot_bytes = QOVL_RGBA_FRAME_BYTES, slots = 4;
	uint32_t width = 3840, height = 2160, frame_base = 0, k, stride;
	char autobdf[64], path[128];
	struct qovl_ring ring;
	uint8_t *map;
	int fd, rc = 1;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--dev") && i + 1 < argc)	dev = argv[++i];
		else if (!strcmp(argv[i], "--bdf") && i + 1 < argc)
			bdf = argv[++i];
		else if (!strcmp(argv[i], "--slots") && i + 1 < argc)
			slots = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--slot-bytes") && i + 1 < argc)
			slot_bytes = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--width") && i + 1 < argc)
			width = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--height") && i + 1 < argc)
			height = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--frame-base") && i + 1 < argc)
			frame_base = strtoul(argv[++i], NULL, 0);
		else {
			fprintf(stderr, "fill: unknown argument %s\n", argv[i]);
			return 1;
		}
	}
	if (!slots || slots > 4) {
		fprintf(stderr, "fill: slots must be 1..4\n");
		return 1;
	}
	if (!height || slot_bytes % height) {
		fprintf(stderr, "fill: slot_bytes %u is not a whole number of rows\n",
			slot_bytes);
		return 1;
	}
	stride = slot_bytes / height;
	if (stride != width * 4u) {
		fprintf(stderr, "fill: row stride %u != RGBA width %u (%u B); "
			"fill_rgba writes no padding, refusing\n", stride, width,
			width * 4u);
		return 1;
	}
	if (!bdf) {
		if (find_bdf(autobdf, sizeof autobdf)) {
			fprintf(stderr, "no %04x:%04x device found\n",
				QPCIE_VENDOR, QPCIE_DEVICE);
			return 1;
		}
		bdf = autobdf;
	}
	if (!dev) {
		snprintf(path, sizeof path, "/dev/qpcie-ovl-%s", bdf);
		dev = path;
	}
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		return 1;
	}
	memset(&ring, 0, sizeof ring);
	ring.slot_bytes = slot_bytes;
	ring.nslots = slots;
	if (ioctl(fd, QOVL_IOC_SETUP, &ring)) {
		fprintf(stderr, "QOVL_IOC_SETUP %u x %u: %s\n", ring.nslots,
			ring.slot_bytes, strerror(errno));
		close(fd);
		return 1;
	}
	printf("ring  bdf=%s slots=%u slot_bytes=%u base_iova=0x%llx gen=%u\n", bdf,
	       ring.nslots, ring.slot_bytes, (unsigned long long)ring.base_iova,
	       ring.gen);
	if (ring.slot_bytes != slot_bytes || ring.nslots != slots ||
	    !ring.base_iova) {
		fprintf(stderr, "fill: ring came back inconsistent; refusing\n");
		close(fd);
		return 1;
	}
	map = mmap(NULL, (size_t)ring.stride * ring.nslots, PROT_READ | PROT_WRITE,
		   MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		fprintf(stderr, "mmap ring: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	for (k = 0; k < ring.nslots; k++) {
		uint64_t t = now_ms();

		fill_rgba(map + (size_t)k * ring.stride, width, height, stride,
			  frame_base + k);
		printf("fill  slot=%u pattern_frame=%u %u B in %" PRIu64 " ms\n", k,
		       frame_base + k, ring.slot_bytes, now_ms() - t);
	}
	printf("fill  done slots=%u slot_bytes=%u stride=%u pattern_frames=%u..%u "
	       "base_iova=0x%llx gen=%u (ring written once, before any arm; no "
	       "mailbox command issued)\n", ring.nslots, ring.slot_bytes, stride,
	       frame_base, frame_base + ring.nslots - 1,
	       (unsigned long long)ring.base_iova, ring.gen);
	rc = 0;
	munmap(map, (size_t)ring.stride * ring.nslots);
	close(fd);
	return rc;
}

/* -------------------------------------------------------------------- tx */

static int cmd_tx(int argc, char **argv)
{
	const char *ctl = "sc7f0ctl", *dev = NULL, *bdf = NULL;
	uint64_t dst_base = QOVL_PS_POOL_BASE;
	uint32_t slot_bytes = QOVL_RGBA_FRAME_BYTES;
	/* Diagnostic geometry.  The deployed target stays 3840x2160 RGBA8888
	 * (slot_bytes = QOVL_RGBA_FRAME_BYTES); these exist because the host
	 * kernel cannot hand out an arbitrarily large PHYSICALLY contiguous
	 * coherent block - with MAX_ORDER = 11 the ceiling is 4 MiB and there is
	 * no IOMMU on this test host (ACPI DMAR table absent), so a full 4K frame
	 * ring can only be allocated once VT-d gives the DMA layer an
	 * IOVA-contiguous mapping of scattered pages.  Being able to move a
	 * complete smaller frame is what proves the H2C path is real PCIe traffic
	 * rather than the PS writing its own DDR; it is not a reduction of the
	 * fabric or of the 4K60 target, and the writer block itself is
	 * geometry-agnostic (it walks src_addr..src_addr+xfer_bytes).
	 */
	unsigned width = 3840, height = 2160;
	unsigned frames = 4, slots = 4, fps = 0, verbose = 0;
	char autobdf[64];
	struct qovl_ring ring;
	struct ovl_state before, after;
	volatile uint8_t *map;
	int fd, i, rc;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];

		if (!strcmp(a, "--ctl") && i + 1 < argc)	ctl = argv[++i];
		else if (!strcmp(a, "--dev") && i + 1 < argc)	dev = argv[++i];
		else if (!strcmp(a, "--bdf") && i + 1 < argc)	bdf = argv[++i];
		else if (!strcmp(a, "--slot-bytes") && i + 1 < argc)
			slot_bytes = (uint32_t)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--width") && i + 1 < argc)
			width = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--height") && i + 1 < argc)
			height = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--frames") && i + 1 < argc)
			frames = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--slots") && i + 1 < argc)
			slots = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--fps") && i + 1 < argc)
			fps = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--dst") && i + 1 < argc)
			dst_base = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(a, "--verbose"))		verbose = 1;
		else {
			fprintf(stderr, "bad argument %s\n", a);
			return 2;
		}
	}
	if (!frames || slots > QOVL_MAX_SLOTS) {
		fprintf(stderr, "--frames >=1 and --slots 0..%u required\n",
			QOVL_MAX_SLOTS);
		return 2;
	}
	if (!width || !height || (slot_bytes & 63U) ||
	    (uint64_t)width * 4U * height > slot_bytes) {
		fprintf(stderr, "--slot-bytes must be a non-zero multiple of 64 and must hold --width x --height RGBA8888 (%u x %u needs %llu B)\n",
			width, height, (unsigned long long)width * 4ULL * height);
		return 2;
	}
	if (!bdf) {
		if (find_bdf(autobdf, sizeof autobdf)) {
			fprintf(stderr, "no %04x:%04x device found\n",
				QPCIE_VENDOR, QPCIE_DEVICE);
			return 1;
		}
		bdf = autobdf;
	}
	if (!dev) {
		char path[128];

		snprintf(path, sizeof path, "/dev/qpcie-ovl-%s", bdf);
		dev = strdup(path);
	}

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		fprintf(stderr, "(this window only exists on a card whose fabric "
			"answers 0x%08x; check `sc7f0ctl exec \"cat "
			"/sys/bus/pci/devices/%s/version\"` first)\n",
			0x26111503u, bdf);
		return 1;
	}

	memset(&ring, 0, sizeof ring);
	ring.slot_bytes = slot_bytes;
	ring.nslots = slots;
	if (ioctl(fd, QOVL_IOC_SETUP, &ring)) {
		fprintf(stderr, "QOVL_IOC_SETUP %u x %u: %s\n", ring.nslots,
			ring.slot_bytes, strerror(errno));
		close(fd);
		return 1;
	}
	printf("ring  slots=%u slot_bytes=%u base_iova=0x%llx gen=%u\n",
	       ring.nslots, ring.slot_bytes, (unsigned long long)ring.base_iova,
	       ring.gen);
	if (ring.slot_bytes != slot_bytes || ring.nslots != slots ||
	    !ring.base_iova) {
		fprintf(stderr, "ring came back inconsistent; refusing to arm\n");
		close(fd);
		return 1;
	}
	/* The writer lands every slot inside overlay-pool@54000000; if the PS
	 * pool moved, dst_base + nslots*slot would run off the end of a no-map
	 * region and the fault would show up as an AXI error, not as an errno. */
	if (dst_base < QOVL_PS_POOL_BASE ||
	    (dst_base - QOVL_PS_POOL_BASE) +
	        (uint64_t)ring.slot_bytes * ring.nslots > QOVL_PS_POOL_BYTES) {
		fprintf(stderr, "%u slots of %u B do not fit the %llu B overlay "
			"pool at 0x%llx\n", ring.nslots, ring.slot_bytes,
			(unsigned long long)QOVL_PS_POOL_BYTES,
			(unsigned long long)dst_base);
		close(fd);
		return 1;
	}

	map = mmap(NULL, (size_t)ring.stride * ring.nslots, PROT_READ | PROT_WRITE,
		   MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		fprintf(stderr, "mmap ring: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	/* Prove the aperture before writing it.  A read of 0 is what an absent
	 * block answers, which is exactly why ID moved to 0x78. */
	rc = ovl_read(ctl, &before);
	if (rc < 0) {
		fprintf(stderr, "mailbox unavailable; nothing was submitted\n");
		goto out;
	}
	printf("card  ID=0x%08llx frames=%llu issued=%llu drained=%llu "
	       "suppress=0x%llx\n", (unsigned long long)before.id,
	       (unsigned long long)before.frames,
	       (unsigned long long)before.issued,
	       (unsigned long long)before.drained,
	       (unsigned long long)before.suppression);
	if (before.id != QOVL_ID_RGB1) {
		fprintf(stderr, "ID(0x78)=0x%08llx is not \"RGB1\": this window is "
			"not the overlay controller. Refusing to write it.\n",
			(unsigned long long)before.id);
		rc = 1;
		goto out;
	}
	if (before.suppression) {
		fprintf(stderr, "SUPPRESSION=0x%llx is not clear (video guard, arm "
			"mismatch, an unfinished plane retirement or abandoned "
			"tags). Arming now would deepen the debt; stop and read "
			"`sc7f0_rgb_overlay status` on the card.\n",
			(unsigned long long)before.suppression);
		rc = 1;
		goto out;
	}

	uint64_t first_frames = before.frames;
	uint64_t t0 = now_ms();
	for (unsigned f = 0; f < frames; f++) {
		unsigned slot = f % ring.nslots;
		uint64_t iova = ring.base_iova + (uint64_t)slot * ring.stride;
		uint64_t dst = dst_base + (uint64_t)slot * ring.stride;
		char cmd[512], *dump = NULL;
		size_t dn;
		uint64_t frames_now = 0, want = first_frames + f + 1;

		fill_rgba((uint8_t *)(map + (uint64_t)slot * ring.stride), width,
			  height, (uint32_t)(width * 4U), f);

		/* The third argument is the CONSTANT ring base, not this slot's address:
		 * the writer forms the destination as dst_base + wslot * slot_bytes
		 * (sc7f0_overlay_writer.v:921).  The trailing argument is the slot this
		 * plane lands in; the helper converts it to CTRL[7:6] = (slot+1)%slots,
		 * because wslot is latched at end-of-plane (:1112) rather than at arm,
		 * so the value programmed now is the slot the NEXT plane uses.  Both
		 * wrong shapes were measured in
		 * offline-fixture/slot-seam-20261115T185234Z: leaving force at 0 gave the
		 * card's own signature (bytes in the right place, accounted slot 0,
		 * issued==staged==18432 / drained==2048 two frames later), and programming
		 * the plane's own slot wrote every plane one slot late (130432 bytes in the
		 * wrong slot at plane 1).  Programming the NEXT slot is what passes 8
		 * planes over two ring wraps byte-exact. */
		snprintf(cmd, sizeof cmd,
			 "%s arm 0x%" PRIx64 " %u 0x%" PRIx64
			 " %u %u %u %u", ovl_tool(), iova, ring.slot_bytes, dst_base,
			 ring.slot_bytes, ring.slot_bytes, ring.nslots, slot);
		if (ps_exec(ctl, cmd, &dump, &dn) != 0) {
			free(dump);
			fprintf(stderr, "frame %u: arm not submitted\n", f);
			rc = 1;
			goto out;
		}
		free(dump);
		if (verbose)
			printf("arm slot%u iova=0x%" PRIx64 " dst=0x%" PRIx64 "\n",
			       slot, iova, dst);

		/* Wait for the publish, not for a wall-clock guess. */
		for (;;) {
			struct ovl_state s;
			uint64_t outstanding;

			if (ovl_read(ctl, &s) < 0) {
				fprintf(stderr, "frame %u: status lost\n", f);
				rc = 1;
				goto out;
			}
			frames_now = s.frames;
			if (s.suppression) {
				fprintf(stderr, "frame %u: suppression=0x%llx "
					"issued=%llu drained=%llu; the plane was "
					"refused or retired. Stopping without "
					"recycling slot %u.\n", f,
					(unsigned long long)s.suppression,
					(unsigned long long)s.issued,
					(unsigned long long)s.drained, slot);
				rc = 1;
				goto out;
			}
			outstanding = s.status2 & 0x3f;
			if (frames_now >= want && outstanding == 0 &&
			    s.drained == s.issued)
				break;
			if (now_ms() - t0 > 30000) {
				fprintf(stderr, "frame %u: not published after "
					"30 s (frames=%llu want=%llu "
					"outstanding=%llu); slot %u stays owned by "
					"the writer - it is NOT refilled\n", f,
					(unsigned long long)frames_now,
					(unsigned long long)want,
					(unsigned long long)outstanding, slot);
				rc = 1;
				goto out;
			}
			msleep(2);
		}

		/* Publish the slot to Reader-B, then it is the reader's to hold.  Ask the
		 * hardware first whether it agrees that THIS is the slot it published:
		 * consume releases a bitmask, so consuming a slot the writer never named
		 * leaves the published slot owned forever, which is exactly how the
		 * read-order buffer pinned at issued==staged==18432 / drained==2048. */
		snprintf(cmd, sizeof cmd, "%s slotcheck %u", ovl_tool(), slot);
		if (ps_exec(ctl, cmd, &dump, &dn) != 0) {
			free(dump);
			fprintf(stderr, "frame %u: slot %u is not the slot the writer "
				"published; NOT consuming, stopping before the "
				"ledger goes out of sync\n", f, slot);
			rc = 1;
			goto out;
		}
		free(dump);

		snprintf(cmd, sizeof cmd, "%s consume %u", ovl_tool(), slot);
		if (ps_exec(ctl, cmd, &dump, &dn) != 0) {
			free(dump);
			rc = 1;
			goto out;
		}
		free(dump);

		if (fps) {
			uint64_t elapsed = now_ms() - t0;
			uint64_t need = (uint64_t)(f + 1) * 1000 / fps;

			if (need > elapsed)
				msleep((unsigned)(need - elapsed));
		}
	}

	uint64_t ms = now_ms() - t0;
	double gb = ms ? (double)ring.slot_bytes * frames / (double)ms * 1000.0 /
			 1e9 : 0.0;
	printf("tx PASS frames=%u slot_bytes=%u in %" PRIu64 " ms = %.2f GB/s "
	       "(%.1f fps)\n", frames, ring.slot_bytes, ms, gb,
	       ms ? frames * 1000.0 / (double)ms : 0.0);

	rc = ovl_read(ctl, &after);
	if (rc >= 0)
		printf("card  frames=%llu bytes=%llu beats_delta_unchanged "
		       "lock_lost=%llu sat_watchdog=%llu err_frames=%llu "
		       "suppress=0x%llx\n",
		       (unsigned long long)after.frames,
		       (unsigned long long)after.wr_bytes,
		       (unsigned long long)after.lock_lost,
		       (unsigned long long)after.sat_watchdog,
		       (unsigned long long)after.wr_err_frames,
		       (unsigned long long)after.suppression);
	rc = 0;
out:
	munmap((void *)map, (size_t)ring.stride * ring.nslots);
	/* The ring is left allocated on purpose: an armed read must not lose its
	 * pages.  `--release` (below) is the explicit way to hand it back. */
	close(fd);
	return rc;
}

/* -------------------------------------------------------------------- rx */

static int cmd_rx(int argc, char **argv)
{
	const char *dev = "/dev/video0";
	unsigned frames = 60;
	int i, fd, nbuf = 4;
	struct mapped_buffer { void *p; size_t len; } buf[16];

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--dev") && i + 1 < argc)	dev = argv[++i];
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc)
			frames = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--buffers") && i + 1 < argc)
			nbuf = atoi(argv[++i]);
		else {
			fprintf(stderr, "bad argument %s\n", argv[i]);
			return 2;
		}
	}
	if (nbuf < 2 || nbuf > 16 || !frames)
		return 2;

	fd = open(dev, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		return 1;
	}

	struct v4l2_format fmt;
	memset(&fmt, 0, sizeof fmt);
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	fmt.fmt.pix_mp.width = 3840;
	fmt.fmt.pix_mp.height = 2160;
	fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_RGB24;
	fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
	fmt.fmt.pix_mp.num_planes = 1;
	if (ioctl(fd, VIDIOC_S_FMT, &fmt)) {
		fprintf(stderr, "VIDIOC_S_FMT RGB24 3840x2160: %s\n",
			strerror(errno));
		close(fd);
		return 1;
	}
	printf("fmt   %ux%u fourcc=%.4s stride=%u sizeimage=%u\n",
	       fmt.fmt.pix_mp.width, fmt.fmt.pix_mp.height,
	       (char *)&fmt.fmt.pix_mp.pixelformat,
	       fmt.fmt.pix_mp.plane_fmt[0].bytesperline,
	       fmt.fmt.pix_mp.plane_fmt[0].sizeimage);
	/* The contract geometry is checked, not assumed.  0x68[0] of the overlay
	 * controller refuses any channel-0 descriptor that is not this packed
	 * RGB24 profile, so a mismatch here also explains a refused arm. */
	if (fmt.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_RGB24) {
		fprintf(stderr, "card answered a different fourcc; the RGB24 C2H "
			"contract is not met by this bitstream\n");
		close(fd);
		return 1;
	}

	struct v4l2_requestbuffers req;
	memset(&req, 0, sizeof req);
	req.count = nbuf;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	req.memory = V4L2_MEMORY_MMAP;
	if (ioctl(fd, VIDIOC_REQBUFS, &req)) {
		fprintf(stderr, "VIDIOC_REQBUFS: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	for (int i2 = 0; i2 < (int)req.count; i2++) {
		struct v4l2_buffer b;
		struct v4l2_plane pl[1];

		memset(&b, 0, sizeof b);
		memset(pl, 0, sizeof pl);
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i2;
		b.m.planes = pl;
		b.length = 1;
		if (ioctl(fd, VIDIOC_QUERYBUF, &b)) {
			fprintf(stderr, "VIDIOC_QUERYBUF %d: %s\n", i2,
				strerror(errno));
			close(fd);
			return 1;
		}
		buf[i2].len = pl[0].length;
		buf[i2].p = mmap(NULL, pl[0].length, PROT_READ | PROT_WRITE,
				 MAP_SHARED, fd, pl[0].m.mem_offset);
		if (buf[i2].p == MAP_FAILED) {
			fprintf(stderr, "mmap buf %d: %s\n", i2, strerror(errno));
			close(fd);
			return 1;
		}
		if (ioctl(fd, VIDIOC_QBUF, &b)) {
			fprintf(stderr, "VIDIOC_QBUF %d: %s\n", i2,
				strerror(errno));
			close(fd);
			return 1;
		}
	}

	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (ioctl(fd, VIDIOC_STREAMON, &type)) {
		fprintf(stderr, "VIDIOC_STREAMON: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	unsigned got = 0, bad_geometry = 0, all_zero = 0;
	uint64_t bytes = 0, t0 = now_ms();
	while (got < frames) {
		struct v4l2_buffer b;
		struct v4l2_plane pl[1];

		memset(&b, 0, sizeof b);
		memset(pl, 0, sizeof pl);
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		b.memory = V4L2_MEMORY_MMAP;
		b.m.planes = pl;
		b.length = 1;
		if (ioctl(fd, VIDIOC_DQBUF, &b)) {
			if (errno == EAGAIN) {
				if (now_ms() - t0 > 10000) {
					fprintf(stderr, "no frame for 10 s after "
						"%u; the capture graph produced "
						"nothing (this is NOT proof the "
						"HDMI source is absent - read the "
						"IT6663/VPSS state first)\n", got);
					break;
				}
				msleep(2);
				continue;
			}
			if (errno == EINTR)
				break;
			fprintf(stderr, "VIDIOC_DQBUF: %s\n", strerror(errno));
			break;
		}
		got++;
		t0 = now_ms();
		bytes += pl[0].bytesused;
		if (pl[0].bytesused != QOVL_RGB24_FRAME_BYTES &&
		    pl[0].bytesused != 3840U * 2160U * 3U) {
			bad_geometry++;
			if (bad_geometry <= 3)
				fprintf(stderr, "frame %u bytesused=%u, expected "
					"%u (4K RGB24)\n", got, pl[0].bytesused,
					QOVL_RGB24_FRAME_BYTES);
		}
		/* A buffer that is entirely zero means the DMA landed somewhere
		 * else, which a non-zero bytesused would otherwise hide. */
		{
			const uint64_t *w = buf[b.index].p;
			size_t n = pl[0].bytesused / 8, k;
			int nz = 0;

			for (k = 0; k < n; k += 997)
				if (w[k]) {
					nz = 1;
					break;
				}
			if (!nz)
				all_zero++;
		}
		if (ioctl(fd, VIDIOC_QBUF, &b)) {
			fprintf(stderr, "re-QBUF: %s\n", strerror(errno));
			break;
		}
	}

	type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	ioctl(fd, VIDIOC_STREAMOFF, &type);
	close(fd);

	{
		uint64_t ms = now_ms() - t0 ? now_ms() - t0 : 1;
		double gb = (double)bytes / (double)ms * 1000.0 / 1e9;
		printf("rx  frames=%u bytes=%llu %.2f GB/s (%.1f fps) "
		       "bad_geometry=%u all_zero=%u\n", got,
		       (unsigned long long)bytes, gb,
		       got * 1000.0 / (double)ms, bad_geometry, all_zero);
	}
	/* 4K60 RGB24 is 1.492992 GB/s; anything far below with bad_geometry==0
	 * is a source/framerate limit, not a transport fault, so it is reported
	 * rather than turned into a failure. */
	return (got == frames && !bad_geometry && !all_zero) ? 0 : 1;
}

/* ------------------------------------------------------------------ misc */

static int cmd_probe(int argc, char **argv)
{
	const char *ctl = "sc7f0ctl", *dev = NULL, *bdf = NULL;
	char autobdf[64], cmd[256];
	struct ovl_state s;
	struct qovl_ring ring;
	int fd;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--ctl") && i + 1 < argc)	ctl = argv[++i];
		else if (!strcmp(argv[i], "--dev") && i + 1 < argc) dev = argv[++i];
		else if (!strcmp(argv[i], "--bdf") && i + 1 < argc) bdf = argv[++i];
	}
	if (!bdf && find_bdf(autobdf, sizeof autobdf)) {
		printf("probe ABSENT  no %04x:%04x on this host\n",
		       QPCIE_VENDOR, QPCIE_DEVICE);
		return 1;
	}
	if (!bdf)
		bdf = autobdf;
	if (!dev) {
		snprintf(cmd, sizeof cmd, "/dev/qpcie-ovl-%s", bdf);
		dev = cmd;
	}
	printf("bdf   %s\n", bdf);
	printf("ctl   %s status -> ", ctl);
	fflush(stdout);
	{
		char shell[256];

		snprintf(shell, sizeof shell, "%s status", ctl);
		if (system(shell) != 0)
			printf("(sc7f0ctl status failed: PS debugd not answering)\n");
	}
	if (ovl_read(ctl, &s) < 0)
		printf("ovl   mailbox not answering; no CSR read attempted\n");
	else
		printf("ovl   ID=0x%08llx%s frames=%llu issued=%llu staged=%llu "
		       "drained=%llu suppress=0x%llx status2=0x%llx\n",
		       (unsigned long long)s.id,
		       s.id == QOVL_ID_RGB1 ? " \"RGB1\"" : " NOT-THE-CONTROLLER",
		       (unsigned long long)s.frames,
		       (unsigned long long)s.issued,
		       (unsigned long long)s.staged,
		       (unsigned long long)s.drained,
		       (unsigned long long)s.suppression,
		       (unsigned long long)s.status2);
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		printf("ring  %s: %s\n", dev, strerror(errno));
		return 0;
	}
	memset(&ring, 0, sizeof ring);
	if (!ioctl(fd, QOVL_IOC_INFO, &ring))
		printf("ring  gen=%u slots=%u slot_bytes=%u base_iova=0x%llx\n",
		       ring.gen, ring.nslots, ring.slot_bytes,
		       (unsigned long long)ring.base_iova);
	close(fd);
	return 0;
}

static int cmd_release(int argc, char **argv)
{
	const char *dev = NULL, *bdf = NULL;
	char autobdf[64], path[128];
	struct qovl_busy busy = { 0, 0 };
	int fd;

	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--dev") && i + 1 < argc) dev = argv[++i];
		else if (!strcmp(argv[i], "--bdf") && i + 1 < argc) bdf = argv[++i];
		else if (!strcmp(argv[i], "--forced")) busy.outstanding = 0;
	if (!bdf && find_bdf(autobdf, sizeof autobdf))
		return 1;
	if (!bdf)
		bdf = autobdf;
	if (!dev) {
		snprintf(path, sizeof path, "/dev/qpcie-ovl-%s", bdf);
		dev = path;
	}
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		return 1;
	}
	if (ioctl(fd, QOVL_IOC_FREE, &busy)) {
		fprintf(stderr, "QOVL_IOC_FREE: %s (the ring stays allocated; a "
			"plane may still be armed)\n", strerror(errno));
		close(fd);
		return 1;
	}
	printf("ring released (%s)\n", dev);
	close(fd);
	return 0;
}

static void usage(void)
{
	fputs(
	"host_rgb_compositor <command> [options]\n"
	"  probe   [--bdf B] [--ctl PATH]      card, mailbox, CSR identity, ring\n"
	"  tx      [--frames N] [--slots 1..4] [--fps F] [--dst ADDR] [--verbose]\n"
	"                                    H2C RGBA8888 4K planes -> Reader-B\n"
	"                                    -> alpha blend -> HDMI out\n"
	"  rx      [--dev /dev/videoN] [--frames N] [--buffers 2..16]\n"
	"                                    C2H packed RGB24 4K, stride 11520\n"
	"  release [--bdf B]                   free the ring (refused while a\n"
	"                                    plane is armed)\n"
	"  fill    [--slots N] [--frame-base F] [--width W] [--height H]\n"
	"                                    write one distinct fill_rgba pattern per\n"
	"                                    ring slot and stop; no arm, no mailbox.\n"
	"                                    Prints the per-slot fill time, which is\n"
	"                                    the producer cost an arm-loop rate omits.\n"
	"Control always goes through the debug mailbox:\n"
	"  sc7f0ctl exec 'sc7f0_rgb_overlay ...'  (0xB00A0000 is PS-side)\n",
	stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	if (argc < 2)
		usage();
	if (!strcmp(argv[1], "probe"))	return cmd_probe(argc - 1, argv + 1);
	if (!strcmp(argv[1], "tx"))	return cmd_tx(argc - 1, argv + 1);
	if (!strcmp(argv[1], "rx"))	return cmd_rx(argc - 1, argv + 1);
	if (!strcmp(argv[1], "release"))	return cmd_release(argc - 1, argv + 1);
	if (!strcmp(argv[1], "fill"))	return cmd_fill(argc - 1, argv + 1);
	usage();
}
