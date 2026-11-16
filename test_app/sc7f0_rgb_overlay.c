/*
 * sc7f0_rgb_overlay - bring-up and verification tool for the
 * SC7F0-RGB-COMPOSITOR-2PPC (PL base 0x26111405) overlay path, run ON THE CARD.
 *
 * It is the userspace half of the contract that no kernel driver owns yet:
 *
 *   0xB00A0000  rtl/sc7f0_rgb_overlay_ctrl.v  PCIe H2C overlay ingress + PS-DDR
 *               plane writer + compositor control + Reader-B reset.
 *   0xB0090000  compositor Reader-B, an official v_frmbuf_rd (2 PPC, RGBA8,
 *               HP2 read).  Programmed here because the plane feeds the
 *               fixed-function blender and not a DMA-engine client, so
 *               xilinx_frmbuf.c has no reason to own it.
 *   0xB0080000  compositor Reader-A, same IP on HP1.  Only read here: its frame
 *               address belongs to the DRM / xlnx,pl-disp pipeline.
 *
 * Offsets and bits are transcribed, not invented:
 *   overlay control: the register map in the header comment of
 *     rtl/sc7f0_rgb_overlay_ctrl.v (0x00 CTRL ... 0x6C ID = "RGB1").
 *   reader: drivers/dma/xilinx/xilinx_frmbuf.c of this very kernel
 *     (CTRL 0x00, GIE 0x04, IE 0x08, ISR 0x0c, WIDTH 0x10, HEIGHT 0x18,
 *     STRIDE 0x20, FMT 0x28, ADDR 0x30 written as one 64-bit write because the
 *     IP has AXIMM_ADDR_WIDTH 64), with hsize = bytes_per_line * ppw * 8 / bpw
 *     exactly as xilinx_frmbuf_interleave_alloc() computes it (= pixels for
 *     RGBA8), and the format ids RGBA8 = 13 ("abgr8888"), BGRA8 = 26
 *     ("argb8888") from the same file.
 *
 * There is deliberately no "sleep then assume" here.  The writer exposes
 * quiesce/discard and busy/quiesced plus issued/staged/drained counters, so a
 * plane is re-armed only after STATUS says it may be, and every write is a
 * named subcommand so the session log says exactly what the hardware was told.
 *
 * Build: make -C test_app sc7f0_rgb_overlay   (static ARM64)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define OVL_BASE	0xB00A0000ULL	/* sc7f0_rgb_overlay_ctrl  */
#define OVL_SIZE	0x1000
#define PLANE_B		0xB0090000ULL	/* compositor Reader-B      */
#define PLANE_A		0xB0080000ULL	/* compositor Reader-A      */
#define PLANE_SIZE	0x10000

/* ---- rtl/sc7f0_rgb_overlay_ctrl.v ---- */
#define O_CTRL		0x00
#define  C_ENABLE	(1u << 0)
#define  C_GO		(1u << 1)
#define  C_QUIESCE	(1u << 2)
#define  C_DISCARD	(1u << 3)
#define  C_WR_ENABLE	(1u << 4)
#define  C_WR_AUTO	(1u << 5)
#define  C_FORCE_SLOT(s)	(((s) & 3u) << 6)
#define  C_SLOT_COUNT(n)	(((n) & 7u) << 8)
#define O_SRC_LO	0x04
#define O_SRC_HI	0x08
#define O_XFER		0x0C
#define O_MAX_REQ	0x10
#define O_DST_LO	0x14
#define O_DST_HI	0x18
#define O_SLOT_BYTES	0x1C
#define O_FRAME_BYTES	0x20
#define O_CONSUME	0x24
#define O_COMP		0x30
#define  M_BLEND_ENABLE	(1u << 0)
#define  M_ALPHA_OPAQUE	(1u << 1)
#define  M_BLEND_UNLOCK	(1u << 2)
#define  M_READER_B_RST	(1u << 3)
#define O_STATUS	0x40
#define O_STATUS2	0x44
#define O_ISSUED	0x48
#define O_STAGED	0x4C
#define O_DRAINED	0x50
#define O_FRAMES	0x54
#define O_WR_BYTES	0x58
#define O_BEATS		0x5C
#define O_LOCK_LOST	0x60
#define O_SAT_WDG	0x64
/* 0x68 is the suppression/retirement state the RTL review put outside 0x40 and
 * 0x44 "so no offset that software already reads changes meaning":
 *   [0] video_guard_sticky  a channel-0 video descriptor that is not this
 *                           profile's packed RGB24 (or out of range / larger
 *                           than the ring) was refused: zero C2H requests, and
 *                           the mailbox, programming, upgrade, MCU and
 *                           readback paths all kept running
 *   [1] arm_mismatch_sticky 0x0C != 0x20 at a go attempt, refused
 *   [2] wr_abort_busy       a plane retirement is still in progress
 *   [3] wr_sticky[5]        abandoned overlay tags still owed (video_poison)
 *   [4] wr_sticky[4]        a BRESP error cost a frame its publish
 *   [5] video_poison        ... arming stays refused until those tags retire
 */
#define O_SUPPRESSION	0x68
#define O_VIDEO_GUARD	0x70
#define O_WR_ERR_FRAMES	0x74
#define O_ABORT_STATUS	0x6C
#define O_ID		0x78
#define ID_RGB1		0x52474231u
/* 0x6C carries the abort status; ID lives at 0x78.  In the 0x26111405 fabric
 * both were written on 0x6C in one read mux, and a case statement answers the
 * FIRST matching label, so the ID item was dead code and the read returned 0 -
 * which is also exactly what an absent (or decoding-but-empty) aperture
 * returns.  Reading 0 therefore proved nothing.  Software must read 0x78. */

/* ---- drivers/dma/xilinx/xilinx_frmbuf.c, v_frmbuf_rd register set ---- */
#define R_CTRL		0x00
#define  R_START	(1u << 0)
#define  R_DONE		(1u << 1)
#define  R_IDLE		(1u << 2)
#define  R_READY	(1u << 3)
#define  R_FLUSH	(1u << 5)
#define  R_FLUSH_DONE	(1u << 6)
#define  R_AUTO		(1u << 7)
#define R_GIE		0x04
#define R_IE		0x08
#define R_ISR		0x0c
#define R_WIDTH		0x10
#define R_HEIGHT	0x18
#define R_STRIDE	0x20
#define R_FMT		0x28
#define R_ADDR		0x30
#define FMT_RGBA8	13u
#define FMT_BGRA8	26u

static uint32_t rd(volatile void *m, unsigned off)
{
	uint32_t v = *(volatile uint32_t *)((char *)m + off);
	__asm__ volatile("" ::: "memory");
	return v;
}

static void wr(volatile void *m, unsigned off, uint32_t v)
{
	__asm__ volatile("" ::: "memory");
	*(volatile uint32_t *)((char *)m + off) = v;
}

static volatile void *map(unsigned long long base, unsigned long size)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	void *p;
	if (fd < 0) {
		fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
		return NULL;
	}
	p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		 (off_t)base);
	if (p == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%llx: %s\n", base, strerror(errno));
		close(fd);
		return NULL;
	}
	return (volatile void *)p;
}

/* Reader-B reset is PS EMIO GPIO bit 3, i.e. zynqmp_gpio number 78+3 = 81
 * (the card exposes one zynqmp_gpio chip of 174 lines: 78 MIO then EMIO).
 * The same line also exists as CTRL bit 3 of the overlay window; sysfs is used
 * because it is the line the device tree names in reset-gpios. */
static int emio_export(int gpio, const char *dir, int value)
{
	char path[128], num[16];
	FILE *f;
	snprintf(path, sizeof path, "/sys/class/gpio/export");
	f = fopen(path, "w");
	if (f) {
		snprintf(num, sizeof num, "%d", gpio);
		if (fwrite(num, 1, strlen(num), f) == 0) { }
		fclose(f);
	}
	snprintf(path, sizeof path, "/sys/class/gpio/gpio%d/direction", gpio);
	f = fopen(path, "w");
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}
	fprintf(f, "%s", dir);
	fclose(f);
	if (value >= 0) {
		snprintf(path, sizeof path, "/sys/class/gpio/gpio%d/value", gpio);
		f = fopen(path, "w");
		if (!f) {
			fprintf(stderr, "open %s: %s\n", path, strerror(errno));
			return -1;
		}
		fprintf(f, "%d", value);
		fclose(f);
	}
	return 0;
}

static void status(volatile void *m)
{
	uint32_t s = rd(m, O_STATUS), s2 = rd(m, O_STATUS2);
	/* 0x40, in RTL order: {18'd0, ovl_irq_sticky, wr_irq_sticky,
	 * blend_busy_c, blend_locked_c, wr_slot_ready, wr_busy,
	 * ovl_ext_tag_blocked, ovl_quarantined, ovl_quiesced, ovl_busy} */
	static const char *bitnames[] = {
		"ovl_busy", "ovl_quiesced", "ovl_quarantined", "ovl_ext_tag_blocked",
		"wr_busy", "wr_slot_ready", "blend_locked", "blend_busy",
		"wr_irq_sticky", "ovl_irq_sticky"
	};
	/* 0x00, in RTL order: {21'd0, wr_slot_count, wr_force_slot,
	 * wr_auto_advance, wr_enable, ovl_discard_pending, ovl_quiesce_req,
	 * ovl_go, ovl_enable} */
	static const char *ctrlbits[] = {
		"ovl_enable", "ovl_go", "ovl_quiesce_req", "ovl_discard_pending",
		"wr_enable", "wr_auto_advance", "wr_force_slot0", "wr_force_slot1"
	};
	uint32_t c = rd(m, O_CTRL);
	printf("CTRL       = 0x%08x  slot_count=%u", c, (c >> 8) & 7);
	for (unsigned i = 0; i < 8; i++)
		if (c & (1u << i))
			printf(" %s", ctrlbits[i]);
	printf("\n");
	printf("COMP_CTRL  = 0x%08x%s%s%s%s\n", rd(m, O_COMP),
	       (rd(m, O_COMP) & M_BLEND_ENABLE) ? " blend_enable" : "",
	       (rd(m, O_COMP) & M_ALPHA_OPAQUE) ? " alpha_force_opaque" : "",
	       (rd(m, O_COMP) & M_READER_B_RST) ? " reader_b_reset" : "",
	       (rd(m, O_COMP) & M_BLEND_UNLOCK) ? " blend_unlock" : "");
	printf("STATUS     = 0x%08x", s);
	for (unsigned i = 0; i < 10; i++)
		if (s & (1u << i))
			printf(" %s", bitnames[i]);
	printf("\n");
	/* 0x44, from the read mux itself (rtl/sc7f0_rgb_overlay_ctrl.v:450), NOT from
	 * that file's header comment: {18'd0, ovl_counts[3:0], wr_sticky[3:0],
	 * wr_active_slot[1:0], ovl_outstanding[5:0]}.  So active_slot is [7:6] and
	 * 2 bits wide, wr_sticky is [11:8] and ovl_counts is [15:12]; the header
	 * claims [8:6]/[13:9], which would have made slot 2 read as 0 and shifted
	 * every sticky bit down by one.  The mux is what the silicon drives. */
	printf("STATUS2    = 0x%08x  outstanding=%u active_slot=%u wr_sticky=0x%x ovl_counts=0x%x\n",
	       s2, s2 & 0x3f, (s2 >> 6) & 3, (s2 >> 8) & 0xf, (s2 >> 12) & 0xf);
	printf("SUPPRESS   = 0x%08x%s%s%s%s%s%s  guard=%u err_frames=%u\n",
	       rd(m, O_SUPPRESSION),
	       (rd(m, O_SUPPRESSION) & 1u) ? " video_guard_sticky" : "",
	       (rd(m, O_SUPPRESSION) & 2u) ? " arm_mismatch_sticky" : "",
	       (rd(m, O_SUPPRESSION) & 4u) ? " wr_abort_busy" : "",
	       (rd(m, O_SUPPRESSION) & 8u) ? " wr_sticky5" : "",
	       (rd(m, O_SUPPRESSION) & 16u) ? " wr_sticky4_bresp" : "",
	       (rd(m, O_SUPPRESSION) & 32u) ? " video_poison" : "",
	       rd(m, O_VIDEO_GUARD), rd(m, O_WR_ERR_FRAMES));
	printf("bytes      issued=%u staged=%u drained=%u\n",
	       rd(m, O_ISSUED), rd(m, O_STAGED), rd(m, O_DRAINED));
	printf("writer     frames=%u bytes=%u\n", rd(m, O_FRAMES), rd(m, O_WR_BYTES));
	printf("compositor beats=%u lock_lost=%u sat_watchdog=%u\n",
	       rd(m, O_BEATS), rd(m, O_LOCK_LOST), rd(m, O_SAT_WDG));
}

/* Machine-readable register dump, one `name=0xVALUE` per line, for a host
 * client driving this tool over the debug mailbox (sc7f0ctl exec).  Parsing
 * the human status() text across two toolchains and a serial round trip is how
 * a counter silently changes meaning; these names are the ABI.  Only offsets
 * are read, nothing is written, so `dump` is always safe. */
static void dump(volatile void *m)
{
	static const struct { const char *name; unsigned off; } regs[] = {
		{ "ctrl", O_CTRL },           { "src_lo", O_SRC_LO },
		{ "src_hi", O_SRC_HI },       { "xfer", O_XFER },
		{ "dst_lo", O_DST_LO },       { "dst_hi", O_DST_HI },
		{ "slot_bytes", O_SLOT_BYTES }, { "frame_bytes", O_FRAME_BYTES },
		{ "comp_ctrl", O_COMP },      { "status", O_STATUS },
		{ "status2", O_STATUS2 },     { "issued", O_ISSUED },
		{ "staged", O_STAGED },       { "drained", O_DRAINED },
		{ "frames", O_FRAMES },       { "wr_bytes", O_WR_BYTES },
		{ "beats", O_BEATS },         { "lock_lost", O_LOCK_LOST },
		{ "sat_watchdog", O_SAT_WDG },{ "suppression", O_SUPPRESSION },
		{ "video_guard", O_VIDEO_GUARD }, { "wr_err_frames", O_WR_ERR_FRAMES },
		{ "abort_status", O_ABORT_STATUS }, { "id", O_ID },
	};
	for (unsigned i = 0; i < sizeof(regs) / sizeof(regs[0]); i++)
		printf("%s=0x%08x\n", regs[i].name, rd(m, regs[i].off));
}

static void plane_status(volatile void *m, const char *what)
{
	uint32_t c = rd(m, R_CTRL);
	printf("%s CTRL=0x%02x%s%s%s%s%s ISR=0x%x W=%u H=%u stride=%u fmt=%u addr=0x%08x%08x\n",
	       what, c & 0xff,
	       (c & R_START) ? " START" : "", (c & R_DONE) ? " DONE" : "",
	       (c & R_IDLE) ? " IDLE" : "", (c & R_READY) ? " READY" : "",
	       (c & R_AUTO) ? " AUTO" : "",
	       rd(m, R_ISR), rd(m, R_WIDTH), rd(m, R_HEIGHT), rd(m, R_STRIDE),
	       rd(m, R_FMT), rd(m, R_ADDR + 4), rd(m, R_ADDR));
}

static void usage(void)
{
	fputs(
	"sc7f0_rgb_overlay <command> [args]\n"
	"  id                      read 0x78, must be 0x52474231 'RGB1'\n"
	"  status                  overlay ctrl status and counters\n"
	"  plane a|b status        reader control/status/geometry\n"
	"  plane b config <addr> <w> <h> <stride> <fmt>   fmt: rgba8|bgra8\n"
	"  plane b start|stop|flush|auto <0|1>\n"
	"  blend on|off            compositor blend_enable\n"
	"  opaque on|off           alpha_force_opaque (A ignored, FG wins)\n"
	"  unlock                  blend_unlock pulse\n"
	"  readerb reset|release   EMIO gpio 81 (device tree reset-gpios)\n"
	"  arm <src_iova> <bytes> <dst_phys> <slot_bytes> <frame_bytes> <slots> [slot]\n"
	"                          arm one overlay plane and pulse go.  <dst_phys> is the\n"
	"                          CONSTANT ring base: the writer forms the destination\n"
	"                          as dst_base + slot * slot_bytes itself, so the caller\n"
	"                          must not pre-advance it.  [slot] is the slot THIS\n"
	"                          plane lands in (default 0); because CTRL[7:6] loads\n"
	"                          wslot at end-of-plane, the helper programs\n"
	"                          (slot+1)%slots so the rotation stays aligned, and the\n"
	"                          first plane of an epoch must be slot 0.\n"
	"  slotcheck <slot>        0x40[8:5] wr_slot_ready must equal (1<<slot); exits 1\n"
	"                          when the writer published a different slot than the\n"
	"                          one the caller is about to consume\n"
	"  arm-loop <src_iova> <bytes> <dst_phys> <slot_bytes> <frame_bytes>\n"
	"             <slots> <frames> [fps]\n"
	"                          resident writer: the ring geometry is passed ONCE\n"
	"                          and every later frame is armed, published, waited\n"
	"                          for and consumed here over MMIO, never by a per-frame\n"
	"                          host round trip (the mailbox carries 2 KB, a 4K frame\n"
	"                          needs 33 MB/s per stream)\n"
	"  verify <dst> <w> <h> <stride> <frame>\n"
	"                          recompute the Host fill pattern and compare every\n"
	"                          word of the destination; reports first mismatch\n"
	"  consume <slot>          release one written slot to the reader\n"
	"  quiesce|resume|discard  ingress flow control\n"
	"  dump                    raw regs as name=0xVALUE lines (host parses)\n", stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	volatile void *ovl, *plane;
	uint64_t u, src = 0, dst = 0;
	uint32_t bytes = 0, slotb = 0, frameb = 0, slots = 0, v;
	const char *cmd;

	if (argc < 2)
		usage();
	cmd = argv[1];
	ovl = map(OVL_BASE, OVL_SIZE);
	if (!ovl)
		return 1;

	if (!strcmp(cmd, "id")) {
		uint32_t id = rd(ovl, O_ID), c = rd(ovl, O_CTRL), st = rd(ovl, O_STATUS);
		printf("ID(0x78)        = 0x%08x", id);
		printf(id == ID_RGB1 ? "  \"RGB1\"\n" :
		       "  WRONG APERTURE: this window does not answer with the "
		       "overlay controller id; stop, do not write it\n");
		/* Reset signature of THIS block: slot_count field defaults to 1 and
		 * every enable/bit is 0, and STATUS says ovl_quiesced without
		 * ovl_busy.  No other block in this design reads back that pair. */
		if (c == 0x100 && (st & 3u) == 2u) {
			printf("CTRL(0x00)      = 0x%08x  slot_count=1, no enables\n", c);
			printf("STATUS(0x40)    = 0x%08x  ovl_quiesced, not busy\n", st);
			printf("OVERLAY_CTRL_PRESENT\n");
			return 0;
		}
		printf("CTRL(0x00)      = 0x%08x\n", c);
		printf("STATUS(0x40)    = 0x%08x\n", st);
		printf("OVERLAY_CTRL_ABSENT_OR_BUSY\n");
		return 1;
	}
	if (!strcmp(cmd, "dump")) {
		dump(ovl);
		return 0;
	}
	if (!strcmp(cmd, "status")) {
		status(ovl);
		return 0;
	}
	if (!strcmp(cmd, "plane")) {
		if (argc < 3)
			usage();
		plane = map(!strcmp(argv[2], "a") ? PLANE_A : PLANE_B, PLANE_SIZE);
		if (!plane)
			return 1;
		if (!strcmp(argv[3], "status")) {
			plane_status(plane, argv[2]);
			return 0;
		}
		if (!strcmp(argv[3], "config") && argc == 9) {
			unsigned fmt = !strcmp(argv[8], "bgra8") ? FMT_BGRA8 : FMT_RGBA8;
			unsigned long long addr = strtoull(argv[4], NULL, 0);
			unsigned w = strtoul(argv[5], NULL, 0), h = strtoul(argv[6], NULL, 0);
			unsigned stride = strtoul(argv[7], NULL, 0);
			/* xilinx_frmbuf.c writes geometry and format, then starts. */
			wr(plane, R_ADDR, (uint32_t)(addr & 0xffffffffu));
			wr(plane, R_ADDR + 4, (uint32_t)(addr >> 32));
			wr(plane, R_WIDTH, w);
			wr(plane, R_HEIGHT, h);
			wr(plane, R_STRIDE, stride);
			wr(plane, R_FMT, fmt);
			plane_status(plane, argv[2]);
			return 0;
		}
		if (!strcmp(argv[3], "start")) {
			wr(plane, R_CTRL, rd(plane, R_CTRL) | R_START);
			plane_status(plane, argv[2]);
			return 0;
		}
		if (!strcmp(argv[3], "flush")) {
			wr(plane, R_CTRL, rd(plane, R_CTRL) | R_FLUSH);
			plane_status(plane, argv[2]);
			return 0;
		}
		if (!strcmp(argv[3], "stop")) {
			wr(plane, R_CTRL, 0);
			plane_status(plane, argv[2]);
			return 0;
		}
		if (!strcmp(argv[3], "auto") && argc == 5) {
			v = strtoul(argv[4], NULL, 0) ? R_AUTO : 0;
			wr(plane, R_CTRL, (rd(plane, R_CTRL) & ~R_AUTO) | v);
			plane_status(plane, argv[2]);
			return 0;
		}
		usage();
	}
	if (!strcmp(cmd, "blend") || !strcmp(cmd, "opaque")) {
		uint32_t bit = !strcmp(cmd, "blend") ? M_BLEND_ENABLE : M_ALPHA_OPAQUE;
		int on = !strcmp(argv[2], "on");
		uint32_t c = rd(ovl, O_COMP);
		wr(ovl, O_COMP, on ? (c | bit) : (c & ~bit));
		printf("COMP_CTRL = 0x%08x\n", rd(ovl, O_COMP));
		return 0;
	}
	if (!strcmp(cmd, "unlock")) {
		wr(ovl, O_COMP, rd(ovl, O_COMP) | M_BLEND_UNLOCK);
		wr(ovl, O_COMP, rd(ovl, O_COMP) & ~M_BLEND_UNLOCK);
		printf("COMP_CTRL = 0x%08x\n", rd(ovl, O_COMP));
		return 0;
	}
	if (!strcmp(cmd, "readerb")) {
		int assert = !strcmp(argv[2], "reset");
		/* CTRL bit 3 and the EMIO line are the same reset; drive both so
		 * neither the PL view nor the GPIO view is left stale. */
		uint32_t c = rd(ovl, O_COMP);
		wr(ovl, O_COMP, assert ? (c | M_READER_B_RST) : (c & ~M_READER_B_RST));
		if (emio_export(81, "out", assert ? 0 : 1) != 0)
			fprintf(stderr, "EMIO gpio 81 not driven; CTRL bit alone was written\n");
		printf("COMP_CTRL = 0x%08x (reader_b_reset %s)\n", rd(ovl, O_COMP),
		       assert ? "asserted" : "released");
		return 0;
	}
	if (!strcmp(cmd, "arm")) {
		unsigned slot = 0, next_slot = 0;

		if (argc != 8 && argc != 9)
			usage();
		if (argc == 9) {
			slot = strtoul(argv[8], NULL, 0);
			if (slot > 3u) {
				fprintf(stderr, "slot must be 0..3\n");
				return 1;
			}
		}
		src = strtoull(argv[2], NULL, 0);
		bytes = strtoul(argv[3], NULL, 0);
		dst = strtoull(argv[4], NULL, 0);
		slotb = strtoul(argv[5], NULL, 0);
		frameb = strtoul(argv[6], NULL, 0);
		slots = strtoul(argv[7], NULL, 0);
		{
			/* Guard against the old call shape, which fails silently rather than
			 * loudly.  The writer forms dst_base + wslot * slot_bytes and dst_base
			 * is a register, so re-arming with dst_base advanced by
			 * slot * slot_bytes does NOT select a slot; it only moves the whole
			 * ring window while wr_slot_ready keeps accounting one slot.  That is
			 * exactly what the old compositor did (0x120000000 -> +0x10000 ->
			 * +0x20000).  It is detectable here because the previous arm leaves
			 * its base latched; moving the ring is a deliberate act - reset first. */
			uint64_t prev = ((uint64_t)rd(ovl, O_DST_HI) << 32) |
				      (uint64_t)rd(ovl, O_DST_LO);

			if (prev != 0 && prev != dst) {
				fprintf(stderr, "refusing to arm: dst_base changes 0x%llx -> "
				        "0x%llx. dst_base is the CONSTANT ring base (the writer "
				        "adds slot * slot_bytes itself); advancing it per frame is "
				        "the old bug. Run 'reset' first to move the ring.\n",
				        (unsigned long long)prev, (unsigned long long)dst);
				return 1;
			}
		}
		wr(ovl, O_SRC_LO, (uint32_t)(src & 0xffffffffu));
		wr(ovl, O_SRC_HI, (uint32_t)(src >> 32));
		wr(ovl, O_XFER, bytes);
		wr(ovl, O_DST_LO, (uint32_t)(dst & 0xffffffffu));
		wr(ovl, O_DST_HI, (uint32_t)(dst >> 32));
		wr(ovl, O_SLOT_BYTES, slotb);
		wr(ovl, O_FRAME_BYTES, frameb);
		/* The RTL refuses go unless 0x0C == 0x20, and says so sticky at
		 * 0x68[1] instead of half-starting a plane.  Check before writing. */
		if (bytes != frameb) {
			fprintf(stderr, "refusing to arm: 0x0C xfer=%u != 0x20 "
			        "frame_bytes=%u (RTL would set arm_mismatch_sticky)\n",
			        bytes, frameb);
			return 1;
		}
		/* Without auto-advance the writer takes its slot index from
		 * wr_force_slot, and the RTL order matters:
		 *   sc7f0_overlay_writer.v:1112  wslot <= c_auto_adv ? wslot+1 : c_force_slot
		 *                                ... on eof_beat, NOT on arm
		 *   sc7f0_overlay_writer.v:921   slot_addr = c_dst_base + wslot * c_slot_bytes
		 *                                ... captured at start-of-frame
		 * so the slot a plane lands in (and is accounted in wr_slot_ready) is the
		 * force value that was programmed during the PREVIOUS plane; the first
		 * plane of an epoch always uses the reset value 0.
		 * Two wrong shapes were measured, both in
		 * offline-fixture/slot-seam-20261115T185234Z (real ctrl + ingress + writer,
		 * real AXI-Lite CSR writes):
		 *   force left at 0 (the old tool): plane 1 lands correctly but is
		 *     accounted slot 0, consume <1> releases nothing, plane 2 never starts
		 *     and the read-order buffer pins at issued==staged==18432 /
		 *     drained==2048 - the exact on-card numbers of boot df858ffb;
		 *   force = this plane's own slot (the first correction attempt): every
		 *     plane is written one slot late, measured 130432 bytes in the wrong
		 *     slot at plane 1.
		 * Programming (slot + 1) % slots makes "<slot> is the slot this plane goes
		 * to" true for a ring rotation that starts at 0, and +SEQ=next in that
		 * fixture passes 8 consecutive planes over two wraps byte-exact with
		 * wr_slot_ready naming the same slot the Host consumes.  With slots == 1
		 * this is force 0, i.e. the single-slot sequence that passed 231 planes is
		 * bit-for-bit unchanged (CTRL 0x113 / 0x111).
		 */
		if (slots == 0u || slots > 4u) {
			fprintf(stderr, "refusing to arm: slots must be 1..4 (got %u)\n", slots);
			return 1;
		}
		if (slot >= slots) {
			fprintf(stderr, "refusing to arm: slot %u >= slots %u\n", slot, slots);
			return 1;
		}
		if (rd(ovl, O_SUPPRESSION)) {
			fprintf(stderr, "refusing to arm: suppression 0x%x already set; the "
			        "plane ledger is not clean\n", rd(ovl, O_SUPPRESSION));
			return 1;
		}
		if (rd(ovl, O_FRAMES) == 0 && slot != 0u) {
			fprintf(stderr, "refusing to arm: frames_done is 0, so this is the "
			        "first plane of the epoch and the writer will use slot 0 "
			        "whatever CTRL[7:6] says; asked for slot %u\n", slot);
			return 1;
		}
		/* A continued epoch must be continued where the hardware stands, not where the
		 * caller remembers standing.  wslot is only ever 0 (reset) or the CTRL[7:6] that
		 * the previous plane left behind, and that register reads back, so ask it
		 * instead of assuming: a session that restarts mid-rotation, or one that
		 * switches slot count without a reset, is refused rather than silently
		 * re-aligned. Cleaning up is explicit: 'reset' (or a fresh epoch) first. */
		if (rd(ovl, O_FRAMES) != 0) {
			unsigned expect = (rd(ovl, O_CTRL) >> 6) & 3u;

			if (expect >= slots)
				expect = 0u;
			if (slot != expect) {
				fprintf(stderr, "refusing to arm: the epoch is live "
				        "(frames_done=%u) and CTRL[7:6] says the next plane lands "
				        "in slot %u, but slot %u was requested. Do not assume a "
				        "restart starts at slot 0 - run 'reset' (or reboot the "
				        "epoch) before changing rotation or slot count.\n",
				        rd(ovl, O_FRAMES), expect, slot);
				return 1;
			}
		}
		next_slot = (slot + 1u) % slots;
		wr(ovl, O_CTRL, C_ENABLE | C_WR_ENABLE | C_FORCE_SLOT(next_slot) |
		   C_SLOT_COUNT(slots));
		wr(ovl, O_CTRL, C_ENABLE | C_WR_ENABLE | C_FORCE_SLOT(next_slot) |
		   C_SLOT_COUNT(slots) | C_GO);
		printf("arm plane_slot=%u force_slot(next plane)=%u slot_count=%u "
		       "CTRL=0x%08x dst_base=0x%llx (constant: the writer adds slot*slot_bytes)\n",
		       slot, next_slot, slots, rd(ovl, O_CTRL),
		       (unsigned long long)dst);
		status(ovl);
		return (rd(ovl, O_SUPPRESSION) & 2u) ? 1 : 0;
	}
	if (!strcmp(cmd, "slotcheck")) {
		/* The lease question, asked of the hardware rather than of the caller's
		 * own bookkeeping: after a plane is published, 0x40[8:5] wr_slot_ready
		 * names the slot the writer actually wrote and protected.  If it is not
		 * the slot the Host is about to consume, the Host is releasing a bit that
		 * was never set, and the plane the writer did publish will never retire.
		 * Failing here is cheap; the alternative was a wedged read-order buffer. */
		uint32_t st, s;

		if (argc != 3)
			usage();
		s = strtoul(argv[2], NULL, 0);
		st = rd(ovl, O_STATUS);
		printf("slotcheck slot=%u slot_ready=0x%x expected=0x%x STATUS=0x%08x "
		       "STATUS2=0x%08x suppression=0x%x %s\n",
		       s, (st >> 5) & 0xfu, 1u << s, st, rd(ovl, O_STATUS2),
		       rd(ovl, O_SUPPRESSION),
		       (((st >> 5) & 0xfu) == (1u << s)) ? "MATCH" : "MISMATCH");
		return (((st >> 5) & 0xfu) == (1u << s)) ? 0 : 1;
	}
	if (!strcmp(cmd, "verify")) {
		/* Independent content oracle over the destination in PS DDR.
		 *
		 * "tx PASS" only means the counters reached the byte count the writer
		 * was asked for; it says nothing about whether the bytes that landed are
		 * the bytes the Host put in the ring.  This recomputes the Host fill
		 * pattern from its own formula (test_app/host_rgb_compositor.c
		 * fill_rgba()) and reads every byte of the destination through /dev/mem,
		 * so a layout problem shows up as a first-mismatch offset rather than
		 * being smoothed over by sampling a handful of words or by trusting
		 * issued == drained.  It also reports whether the destination is a
		 * constant word shift of the source, which is what an AXIS
		 * tkeep/tready or tail-byte handling bug looks like, as opposed to
		 * scattered single-bit damage.
		 */
		uint64_t base;
		unsigned long w, h, total, mismatch = 0, first = 0, k, shift;
		unsigned frame;
		volatile void *d;
		int have_first = 0;

		if (argc != 7)
			usage();
		base = strtoull(argv[2], NULL, 0);
		w = strtoul(argv[3], NULL, 0);
		h = strtoul(argv[4], NULL, 0);
		/* argv[5] is the destination stride in bytes; the fill only writes
		 * w*4 bytes per row, so the comparison covers the pixel span and skips
		 * the padding the same way the writer's geometry does. */
		frame = strtoul(argv[6], NULL, 0);
		total = w * h;
		d = map(base, total * 4);
		if (!d)
			return 1;
		for (unsigned long i = 0; i < total; i++) {
			unsigned long x = i % w, y = i / w;
			uint32_t a = (uint32_t)((x + frame) & 0xffu);
			uint32_t r = (uint32_t)((x >> 3) & 0xffu);
			uint32_t g = (uint32_t)((y >> 2) & 0xffu);
			uint32_t b = (uint32_t)(((x ^ y) >> 1) & 0xffu);
			uint32_t exp = (a << 24) | (b << 16) | (g << 8) | r;
			uint32_t got;

			if (x < 8 && y == 0)
				exp = (0xffu << 24) | (frame & 0xffu);
			got = rd(d, (unsigned)(i * 4));
			if (got == exp)
				continue;
			if (!have_first) {
				have_first = 1;
				first = i;
				printf("first_mismatch word=%lu byte=0x%lx expected=0x%08x got=0x%08x\n",
				       i, (unsigned long)(base + i * 4), exp, got);
			}
			mismatch++;
		}
		/* Is the whole destination just the source shifted by a constant number
		 * of words?  Test against the same pattern read from the destination
		 * itself, so a pure shift is identified without re-deriving geometry. */
		shift = 0;
		for (k = 1; k <= 256; k *= 2) {
			unsigned long bad = 0;

			for (unsigned long i = k; i < total; i += 97) {
				unsigned long x = (i - k) % w, y = (i - k) / w;
				uint32_t a = (uint32_t)((x + frame) & 0xffu);
				uint32_t r = (uint32_t)((x >> 3) & 0xffu);
				uint32_t g = (uint32_t)((y >> 2) & 0xffu);
				uint32_t b = (uint32_t)(((x ^ y) >> 1) & 0xffu);
				uint32_t exp = (a << 24) | (b << 16) | (g << 8) | r;

				if (rd(d, (unsigned)(i * 4)) != exp)
					bad++;
			}
			if (bad * 97 * 4 < (total - k) / 20) {
				shift = k;
				break;
			}
		}
		printf("verify dst=0x%llx %lux%lu frame=%u words=%lu mismatch=%lu (%.6f%%) "
		       "first=%s%lu shift_words=%lu\n",
		       (unsigned long long)base, w, h, frame, total, mismatch,
		       total ? 100.0 * (double)mismatch / (double)total : 0.0,
		       have_first ? "" : "none(", (unsigned long)(have_first ? first : 0),
		       shift);
		return mismatch ? 1 : 0;
	}

	if (!strcmp(cmd, "arm-loop")) {
		/* Resident arm loop.  This is the piece a per-frame control channel
		 * can never provide: 2 KB of mailbox cannot carry 1.99 GB/s, so the
		 * Host hands over src_iova / slot_bytes / frame_bytes / slots ONCE and
		 * the PS then owns the arm-publish-consume cycle locally.
		 *
		 * Nothing here waits on a timer to decide the hardware is idle: every
		 * step is gated on a counter or a status bit, and a timeout only stops
		 * the loop and reports - it never clears outstanding debt, which is the
		 * failure mode this block was hardened against.
		 */
		unsigned long f, want, published = 0, fps_div = 0, ms = 0;
		unsigned long start_slot = 0;
		uint32_t done0, frames_want, suppress;
		uint32_t *dt_us = NULL;	/* per-frame service time, microseconds */
		struct timespec t0, t, tprev, tnow;

		/* Diagnostic timing, per parent scope: what this loop can answer is
		 * "how long does one arm-publish-consume cycle cost the PS when no RPC
		 * is in it".  It is NOT a delivery-path rate; the delivery path is a
		 * V4L2 output the host driver does not expose yet. */

		if (argc < 9 || argc > 10)
			usage();
		src = strtoull(argv[2], NULL, 0);
		bytes = strtoul(argv[3], NULL, 0);
		dst = strtoull(argv[4], NULL, 0);
		slotb = strtoul(argv[5], NULL, 0);
		frameb = strtoul(argv[6], NULL, 0);
		slots = strtoul(argv[7], NULL, 0);
		frames_want = strtoul(argv[8], NULL, 0);
		if (argc == 10)
			fps_div = strtoul(argv[9], NULL, 0);
		if (!frames_want || !slots || slots > 4 || bytes != frameb) {
			fprintf(stderr, "arm-loop: need 1<=slots<=4, frames>=1 and "
					"bytes == frame_bytes (0x0C must equal 0x20)\n");
			return 1;
		}
		if (rd(ovl, O_ID) != ID_RGB1) {
			fprintf(stderr, "arm-loop: 0x78 is not RGB1; refusing to write\n");
			return 1;
		}
		suppress = rd(ovl, O_SUPPRESSION);
		if (suppress) {
			fprintf(stderr, "arm-loop: suppression 0x%x already set; "
					"refusing to arm\n", suppress);
			return 1;
		}
		/* Where this loop begins is measured, not assumed.  wslot is loaded from
		 * CTRL[7:6] at end-of-plane (rtl/sc7f0_overlay_writer.v:1112) and the
		 * destination is slot_addr = c_dst_base + wslot * c_slot_bytes (:922), and
		 * CTRL is a readable register (rtl/sc7f0_rgb_overlay_ctrl.v:320), so "which
		 * slot does the NEXT plane land in" is a quantity the hardware answers.
		 * A continued epoch therefore resumes where the writer stands; only
		 * frames_done == 0 - a genuine first plane, where CTRL[7:6] has not been
		 * consulted yet - starts at 0.  A measured slot that does not exist in the
		 * requested ring is still a refusal, not a silent realignment: that is a
		 * slot-count change mid-epoch, which re-bases the ring under the writer. */
		done0 = rd(ovl, O_FRAMES);
		if (done0 == 0)
			start_slot = 0u;
		else
			start_slot = (rd(ovl, O_CTRL) >> 6) & 3u;
		if (start_slot >= slots) {
			fprintf(stderr, "arm-loop: refusing to start: frames_done=%u and "
					"CTRL[7:6]=%u names slot %lu, which is outside the "
					"requested %u-slot ring; a slot-count change mid-epoch "
					"re-bases the ring under the writer. Run 'reset' (or start "
					"a fresh epoch) before changing the ring shape.\n",
					done0, (rd(ovl, O_CTRL) >> 6) & 3u, start_slot, slots);
			return 1;
		}
		printf("arm-loop start: frames_done=%u CTRL=0x%08x CTRL[7:6]=%u "
		       "start_slot=%lu slots=%u\n",
		       done0, rd(ovl, O_CTRL), (rd(ovl, O_CTRL) >> 6) & 3u,
		       start_slot, slots);
		dt_us = calloc(frames_want, sizeof *dt_us);
		if (!dt_us) {
			fprintf(stderr, "arm-loop: no memory for %u timestamps\n",
				frames_want);
			return 1;
		}
		wr(ovl, O_SRC_LO, (uint32_t)(src & 0xffffffffu));
		wr(ovl, O_SRC_HI, (uint32_t)(src >> 32));
		wr(ovl, O_XFER, bytes);
		wr(ovl, O_DST_LO, (uint32_t)(dst & 0xffffffffu));
		wr(ovl, O_DST_HI, (uint32_t)(dst >> 32));
		wr(ovl, O_SLOT_BYTES, slotb);
		wr(ovl, O_FRAME_BYTES, frameb);
		clock_gettime(CLOCK_MONOTONIC, &t0);
		done0 = rd(ovl, O_FRAMES);
		for (f = 0; f < frames_want; f++) {
			uint64_t deadline_ns, fsrc;
			uint32_t ctrl, st, want_slot;
			unsigned spin, cur_slot;

			cur_slot = (unsigned)((start_slot + f) % slots);
			clock_gettime(CLOCK_MONOTONIC, &tprev);
			/* The ring advances on the SOURCE (the Host refilled ring slot
			 * cur_slot); the destination base stays constant and the writer forms
			 * dst_base + wslot * slot_bytes, so the geometry is still handed over
			 * exactly once.  cur_slot < slots keeps every read inside the ring the
			 * driver allocated; nothing here invents an address. */
			fsrc = src + (uint64_t)cur_slot * slotb;
			wr(ovl, O_SRC_LO, (uint32_t)(fsrc & 0xffffffffu));
			wr(ovl, O_SRC_HI, (uint32_t)(fsrc >> 32));
			/* Hand the slot back BEFORE re-arming it, which is the ownership
			 * ledger made explicit rather than discovered as an abort.
			 * 0x24 is a bitmap (one release pulse per set bit), NOT an index:
			 * writing the index released nothing, which is how a published slot
			 * stayed owned and the read-order buffer pinned at 18432/2048. */
			if (published & (1UL << cur_slot)) {
				wr(ovl, O_CONSUME, 1u << cur_slot);
				wr(ovl, O_CONSUME, 0u);
			}
			/* CTRL[7:6] is loaded into wslot at end-of-plane, so it names the NEXT
			 * plane's slot; with slots == 1 it is 0, i.e. the single-slot sequence
			 * that passed 231 planes.  No auto-advance: that would start a second
			 * rotation mechanism on a card that is currently offline. */
			ctrl = C_ENABLE | C_WR_ENABLE | C_SLOT_COUNT(slots) |
			       C_FORCE_SLOT((cur_slot + 1u) % slots);
			wr(ovl, O_CTRL, ctrl);
			wr(ovl, O_CTRL, ctrl | C_GO);
			published |= 1UL << cur_slot;
			/* Wait on the publish counter, not on a sleep. */
			for (spin = 0; spin < 500000u; spin++) {
				if (rd(ovl, O_FRAMES) == done0 + (uint32_t)(f + 1))
					break;
				usleep(10);
			}
			if (spin >= 500000u) {
				fprintf(stderr, "arm-loop: frame %lu (slot %u) never "
					"published; frames=0x%x suppression=0x%x "
					"err_frames=0x%x - stopping, debt NOT cleared\n",
					f, cur_slot, rd(ovl, O_FRAMES),
					rd(ovl, O_SUPPRESSION), rd(ovl, O_WR_ERR_FRAMES));
				return 1;
			}
			/* The writer has to name the slot this loop believes it just wrote, or
			 * the consume below releases a bit that was never set. */
			st = rd(ovl, O_STATUS);
			want_slot = 1u << cur_slot;
			if (((st >> 5) & 0xfu) != want_slot) {
				fprintf(stderr, "arm-loop: frame %lu published slot mask 0x%x "
					"but this loop owns 0x%x; STATUS=0x%08x "
					"suppression=0x%x - stopping, debt NOT cleared\n",
					f, (st >> 5) & 0xfu, want_slot, st,
					rd(ovl, O_SUPPRESSION));
				return 1;
			}
			suppress = rd(ovl, O_SUPPRESSION);
			if (suppress) {
				fprintf(stderr, "arm-loop: suppression 0x%x after frame "
					"%lu; stopping without recycling\n",
					suppress, f);
				return 1;
			}
			/* Release this slot now, not on the next visit to it.  0x40[8:5]
			 * wr_slot_ready is a bitmap of every written, not-yet-released
			 * slot, so holding slot N until the loop wraps to it makes the
			 * equality check above false by construction for any slots > 1:
			 * measured on-card at native 4K, frame 1 published with
			 * slot_ready=0x3 (slots 0 AND 1 outstanding) and the loop stopped
			 * on a healthy ledger - suppression=0, no abort, issued==
			 * staged==drained, both planes byte-exact.  The native-4K
			 * 8-plane silicon run this loop reproduces released each slot
			 * right after publishing it (test_app/host_rgb_compositor.c tx),
			 * so do the same here; it also leaves the ring at slot_ready == 0
			 * when the loop exits instead of handing back nothing. */
			wr(ovl, O_CONSUME, 1u << cur_slot);
			wr(ovl, O_CONSUME, 0u);
			published &= ~(1UL << cur_slot);
			clock_gettime(CLOCK_MONOTONIC, &tnow);
			dt_us[f] = (uint32_t)((long)(tnow.tv_sec - tprev.tv_sec) * 1000000l +
					   (tnow.tv_nsec - tprev.tv_nsec) / 1000);
			if (!fps_div)
				continue;
			deadline_ns = ((uint64_t)(f + 1) * 1000000000ull) / fps_div;
			clock_gettime(CLOCK_MONOTONIC, &t);
			{
				uint64_t now = (uint64_t)t.tv_sec * 1000000000ull +
					     (uint64_t)t.tv_nsec;
				if (now < deadline_ns) {
					struct timespec nap = {
						.tv_sec = (time_t)((deadline_ns - now) / 1000000000ull),
						.tv_nsec = (long)((deadline_ns - now) % 1000000000ull),
					};
					nanosleep(&nap, NULL);
				}
			}
		}
		clock_gettime(CLOCK_MONOTONIC, &t);
		want = (unsigned long)frames_want * bytes;
		ms = (unsigned long)(((t.tv_sec - t0.tv_sec) * 1000 +
				      (t.tv_nsec - t0.tv_nsec) / 1000000));
		if (!ms)
			ms = 1;
		printf("arm-loop frames=%u slots=%u slot_bytes=%u issued=%u staged=%u "
		       "drained=%u written=%u frames_done=%u suppression=0x%x "
		       "err_frames=0x%x ms=%lu GBps=%.3f (want %lu B)\n",
		       frames_want, slots, slotb, rd(ovl, O_ISSUED),
		       rd(ovl, O_STAGED), rd(ovl, O_DRAINED), rd(ovl, O_WR_BYTES),
		       rd(ovl, O_FRAMES), suppress, rd(ovl, O_WR_ERR_FRAMES),
		       ms,
		       (double)want / ((double)ms * 1.0e6),
		       want);
		if (dt_us) {
			uint32_t mn = ~0u, mx = 0, key, p50, p90, p99;
			unsigned long i, j, tot_us = 0;

			for (i = 0; i < frames_want; i++) {
				if (dt_us[i] < mn)
					mn = dt_us[i];
				if (dt_us[i] > mx)
					mx = dt_us[i];
				tot_us += dt_us[i];
			}
			for (i = 1; i < frames_want; i++) {
				key = dt_us[i];
				for (j = i; j > 0 && dt_us[j - 1] > key; j--)
					dt_us[j] = dt_us[j - 1];
				dt_us[j] = key;
			}
			p50 = dt_us[(frames_want - 1) / 2];
			p90 = dt_us[(frames_want - 1) * 90 / 100];
			p99 = dt_us[(frames_want - 1) * 99 / 100];
			printf("arm-loop SERVICE_TIME per frame, PS-local MMIO, no RPC "
			       "(scaffold, not a delivery-path rate): frames=%u "
			       "min=%u us p50=%u us p90=%u us p99=%u us max=%u us "
			       "sum=%lu us -> p50 %.2f fps, mean %.2f fps\n",
			       frames_want, mn, p50, p90, p99, mx, tot_us,
			       p50 ? 1e6 / (double)p50 : 0.0,
			       tot_us ? (double)frames_want * 1e6 / (double)tot_us : 0.0);
			free(dt_us);
		}
		return (rd(ovl, O_ISSUED) == rd(ovl, O_DRAINED)) ? 0 : 1;
	}

	if (!strcmp(cmd, "consume")) {
		v = strtoul(argv[2], NULL, 0);
		wr(ovl, O_CONSUME, 1u << v);
		wr(ovl, O_CONSUME, 0);
		status(ovl);
		return 0;
	}
	if (!strcmp(cmd, "quiesce") || !strcmp(cmd, "resume") || !strcmp(cmd, "discard")) {
		uint32_t c = rd(ovl, O_CTRL);
		if (!strcmp(cmd, "quiesce"))
			wr(ovl, O_CTRL, c | C_ENABLE | C_QUIESCE);
		else if (!strcmp(cmd, "discard"))
			wr(ovl, O_CTRL, c | C_ENABLE | C_DISCARD);
		else
			wr(ovl, O_CTRL, c & ~(C_QUIESCE | C_DISCARD));
		status(ovl);
		return 0;
	}
	(void)u;
	usage();
	return 2;
}
