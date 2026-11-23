#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "qpcie_overlay.h"

#define W 3840U
#define H 2160U
#define STRIDE (W * 4U)
#define SLOT_BYTES (STRIDE * H)
#define BAND_Y0 1920U

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int sig) { (void)sig; g_stop = 1; }

struct pen { uint8_t r, g, b, a; };

static inline void put_px(uint8_t *fb, uint32_t x, uint32_t y, struct pen c)
{
	if (x >= W || y >= H) return;
	uint32_t *p = (uint32_t *)(fb + (size_t)y * STRIDE);
	p[x] = ((uint32_t)c.a << 24) | ((uint32_t)c.b << 16) |
	       ((uint32_t)c.g << 8) | (uint32_t)c.r;
}

static void rect_fill(uint8_t *fb, uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1, struct pen c)
{
	if (x1 > W) x1 = W;
	if (y1 > H) y1 = H;
	uint32_t val = ((uint32_t)c.a << 24) | ((uint32_t)c.b << 16) |
	               ((uint32_t)c.g << 8) | (uint32_t)c.r;
	for (uint32_t y = y0; y < y1; y++) {
		uint32_t *row = (uint32_t *)(fb + (size_t)y * STRIDE);
		for (uint32_t x = x0; x < x1; x++)
			row[x] = val;
	}
}

static void circle_fill(uint8_t *fb, int cx, int cy, int rad, struct pen body, struct pen border)
{
	int r2 = rad * rad;
	int inner2 = (rad - 5) * (rad - 5);
	for (int dy = -rad; dy <= rad; dy++) {
		int py = cy + dy;
		if (py < 0 || py >= (int)BAND_Y0) continue;
		uint32_t *row = (uint32_t *)(fb + (size_t)py * STRIDE);
		for (int dx = -rad; dx <= rad; dx++) {
			int px = cx + dx;
			if (px < 0 || px >= (int)W) continue;
			int d2 = dx * dx + dy * dy;
			if (d2 > r2) continue;
			struct pen c = (d2 >= inner2) ? border : body;
			/* Subtle 3D specular highlight on upper-left */
			if (d2 < inner2 && dx < -rad / 5 && dy < -rad / 5) {
				int dist = (dx + rad / 3) * (dx + rad / 3) + (dy + rad / 3) * (dy + rad / 3);
				if (dist < (rad / 3) * (rad / 3)) {
					c.r = (uint8_t)(c.r + (255 - c.r) / 2);
					c.g = (uint8_t)(c.g + (255 - c.g) / 2);
					c.b = (uint8_t)(c.b + (255 - c.b) / 2);
					c.a = 230;
				}
			}
			row[px] = ((uint32_t)c.a << 24) | ((uint32_t)c.b << 16) |
			          ((uint32_t)c.g << 8) | (uint32_t)c.r;
		}
	}
}

static const uint8_t glyph_blank[7] = { 0, 0, 0, 0, 0, 0, 0 };
static const uint8_t glyph_digit[10][7] = {
	{ 0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e },
	{ 0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e },
	{ 0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f },
	{ 0x1f, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0e },
	{ 0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02 },
	{ 0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e },
	{ 0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e },
	{ 0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
	{ 0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e },
	{ 0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c },
};
static const uint8_t glyph_upper[26][7] = {
	{ 0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 },
	{ 0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e },
	{ 0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e },
	{ 0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e },
	{ 0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f },
	{ 0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10 },
	{ 0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f },
	{ 0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 },
	{ 0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e },
	{ 0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0c },
	{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
	{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f },
	{ 0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11 },
	{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
	{ 0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e },
	{ 0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10 },
	{ 0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d },
	{ 0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11 },
	{ 0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e },
	{ 0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
	{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e },
	{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04 },
	{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x1b, 0x11 },
	{ 0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11 },
	{ 0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04 },
	{ 0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f },
};
static const uint8_t glyph_colon[7]   = { 0, 0x04, 0x04, 0, 0x04, 0x04, 0 };
static const uint8_t glyph_dash[7]    = { 0, 0, 0, 0x1f, 0, 0, 0 };
static const uint8_t glyph_dot[7]     = { 0, 0, 0, 0, 0, 0x0c, 0x0c };
static const uint8_t glyph_slash[7]   = { 0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10 };
static const uint8_t glyph_percent[7] = { 0x19, 0x1a, 0x02, 0x04, 0x08, 0x0b, 0x19 };
static const uint8_t glyph_arrow[7]   = { 0x10, 0x08, 0x04, 0x02, 0x04, 0x08, 0x10 };
static const uint8_t glyph_pipe[7]    = { 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 };
static const uint8_t glyph_hash[7]    = { 0x0a, 0x0a, 0x1f, 0x0a, 0x1f, 0x0a, 0x0a };
static const uint8_t glyph_plus[7]    = { 0, 0x04, 0x04, 0x1f, 0x04, 0x04, 0 };

static const uint8_t *glyph_for(char c)
{
	if (c >= '0' && c <= '9') return glyph_digit[c - '0'];
	if (c >= 'A' && c <= 'Z') return glyph_upper[c - 'A'];
	if (c >= 'a' && c <= 'z') return glyph_upper[c - 'a'];
	switch (c) {
	case ':': return glyph_colon;
	case '-': return glyph_dash;
	case '.': return glyph_dot;
	case '/': return glyph_slash;
	case '%': return glyph_percent;
	case '>': return glyph_arrow;
	case '|': return glyph_pipe;
	case '#': return glyph_hash;
	case '+': return glyph_plus;
	default:  return glyph_blank;
	}
}

static void text_draw(uint8_t *fb, uint32_t x, uint32_t y, uint32_t scale,
                      const char *s, struct pen c)
{
	for (; *s; s++) {
		const uint8_t *g = glyph_for(*s);
		for (uint32_t row = 0; row < 7; row++) {
			for (uint32_t col = 0; col < 5; col++) {
				if (!(g[row] & (1u << (4 - col)))) continue;
				for (uint32_t sy = 0; sy < scale; sy++) {
					uint32_t py = y + row * scale + sy;
					if (py >= H) continue;
					for (uint32_t sx = 0; sx < scale; sx++) {
						uint32_t px = x + col * scale + sx;
						if (px < W) put_px(fb, px, py, c);
					}
				}
			}
		}
		x += 6u * scale;
	}
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/qpcie-ovl-0000:03:00.0";
	unsigned seconds = 0; /* 0 = run until signal */
	int use_msi = 0;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--dev") && i + 1 < argc) dev = argv[++i];
		else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--msi")) use_msi = 1;
	}

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	int fd = open(dev, O_RDWR);
	if (fd < 0) { perror("open ovl"); return 1; }

	struct qovl_ring ring = { .nslots = 4, .slot_bytes = SLOT_BYTES };
	if (ioctl(fd, QOVL_IOC_SETUP, &ring)) { perror("QOVL_IOC_SETUP"); close(fd); return 1; }

	uint8_t *fb_base = mmap(NULL, (size_t)ring.stride * ring.nslots,
	                        PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb_base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

	printf("BASE_IOVA=0x%llx STRIDE=%llu NSLOTS=%u MSI=%d\n",
	       (unsigned long long)ring.base_iova,
	       (unsigned long long)ring.stride, ring.nslots, use_msi);
	fflush(stdout);

	if (use_msi) {
		struct qovl_config cfg = {
			.ps_dst_base = QOVL_PS_POOL_BASE,
			.frame_bytes = SLOT_BYTES,
			.nslots = ring.nslots,
			.blend_enable = 1,
			.alpha_opaque = 0,
			.flags = QOVL_CFG_RX_PASSTHROUGH,
		};
		if (ioctl(fd, QOVL_IOC_CONFIG, &cfg)) {
			perror("QOVL_IOC_CONFIG");
			munmap(fb_base, (size_t)ring.stride * ring.nslots);
			close(fd);
			return 1;
		}
	}

	struct pen banner_bg = { 10, 18, 36, 205 };
	struct pen cyan      = { 0, 220, 255, 255 };
	struct pen white     = { 255, 255, 255, 255 };
	struct pen muted     = { 170, 200, 230, 255 };

	for (unsigned s = 0; s < ring.nslots; s++) {
		uint8_t *fb = fb_base + (size_t)s * ring.stride;
		memset(fb, 0, SLOT_BYTES);
		rect_fill(fb, 0, BAND_Y0, W, H, banner_bg);
		rect_fill(fb, 0, BAND_Y0, W, BAND_Y0 + 5, cyan);
		text_draw(fb, 80, BAND_Y0 + 28, 4,
		          "SC7F0 4K60 HDMI LOOP-THROUGH + PCIE H2C ALPHA BLENDING", white);
		text_draw(fb, 80, BAND_Y0 + 82, 3,
		          "BASE: HDMI RX -> PL -> BLEND -> TX | OVERLAY: HOST RAM -> PCIE H2C -> URAM -> BLEND", muted);
		text_draw(fb, 2880, BAND_Y0 + 34, 3, "ALPHA RAMP 0% -> 100%", cyan);
		for (int k = 0; k < 16; k++) {
			uint32_t bx0 = 2880 + (uint32_t)k * 54u;
			struct pen step = { 0, 210, 255, (uint8_t)(k * 17) };
			rect_fill(fb, bx0, BAND_Y0 + 78, bx0 + 50, BAND_Y0 + 148, step);
		}
	}

	const struct { uint8_t r, g, b; const char *name; } pal[6] = {
		{   0, 220, 255, "CYAN" },
		{ 255, 200,   0, "GOLD" },
		{ 255,  60, 200, "MAGENTA" },
		{  60, 255, 120, "LIME" },
		{ 255, 120,  20, "ORANGE" },
		{  80, 160, 255, "SKY" },
	};

	const int rad = 140;
	int x = 400, y = 400;
	int vx = 14, vy = 10;
	int last_x[4] = {0}, last_y[4] = {0}, has_last[4] = {0};
	uint64_t bounces = 0, frame = 0;
	struct pen transparent = { 0, 0, 0, 0 };

	uint32_t inflight_q[2] = { 0, 0 };
	uint32_t last_seq = 0;
	struct timespec t0, t_rep;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	t_rep = t0;

	while (!g_stop) {
		unsigned s = (unsigned)(frame % ring.nslots);
		uint8_t *fb = fb_base + (size_t)s * ring.stride;

		if (has_last[s]) {
			int x0 = last_x[s] - rad - 2; if (x0 < 0) x0 = 0;
			int y0 = last_y[s] - rad - 2; if (y0 < 0) y0 = 0;
			int x1 = last_x[s] + rad + 2; if (x1 > (int)W) x1 = W;
			int y1 = last_y[s] + rad + 2; if (y1 > (int)BAND_Y0) y1 = BAND_Y0;
			rect_fill(fb, (uint32_t)x0, (uint32_t)y0, (uint32_t)x1, (uint32_t)y1, transparent);
		}

		x += vx;
		y += vy;
		if (x - rad < 20) { x = 20 + rad; vx = -vx; bounces++; }
		if (x + rad > (int)W - 20) { x = (int)W - 20 - rad; vx = -vx; bounces++; }
		if (y - rad < 20) { y = 20 + rad; vy = -vy; bounces++; }
		if (y + rad > (int)BAND_Y0 - 20) { y = (int)BAND_Y0 - 20 - rad; vy = -vy; bounces++; }

		unsigned ci = (unsigned)(bounces % 6);
		struct pen body   = { pal[ci].r, pal[ci].g, pal[ci].b, 195 };
		struct pen border = { pal[ci].r, pal[ci].g, pal[ci].b, 255 };
		circle_fill(fb, x, y, rad, body, border);

		text_draw(fb, (uint32_t)(x - 108), (uint32_t)(y - 52), 4, "SC7F0 4K", white);
		char btxt[32], ptxt[32];
		snprintf(btxt, sizeof(btxt), "BOUNCE #%llu", (unsigned long long)bounces);
		snprintf(ptxt, sizeof(ptxt), "%04d,%04d", x, y);
		text_draw(fb, (uint32_t)(x - (int)strlen(btxt) * 9), (uint32_t)(y + 4), 3, btxt, white);
		text_draw(fb, (uint32_t)(x - (int)strlen(ptxt) * 9), (uint32_t)(y + 40), 3, ptxt, white);

		/* Update dynamic bottom telemetry line */
		rect_fill(fb, 80, BAND_Y0 + 140, 2750, BAND_Y0 + 210, banner_bg);
		char info[160];
		snprintf(info, sizeof(info),
		         "3840X2160P60  |  FRAME: %06llu  |  BOUNCE: %03llu (%s)  |  POS: %04d,%04d",
		         (unsigned long long)frame, (unsigned long long)bounces,
		         pal[ci].name, x, y);
		text_draw(fb, 80, BAND_Y0 + 150, 4, info, cyan);

		last_x[s] = x; last_y[s] = y; has_last[s] = 1;
		frame++;

		if (use_msi) {
			/* Keep 2 frames pipelined (1 active + 1 pending in HW):
			 * dequeue (WAIT) the oldest in-flight frame before queuing the next. */
			if (inflight_q[0]) {
				struct qovl_wait wt = { .target_seq = inflight_q[0], .timeout_ms = 1000 };
				if (ioctl(fd, QOVL_IOC_WAIT, &wt)) {
					perror("QOVL_IOC_WAIT");
					break;
				}
			}
			struct qovl_submit sub = {
				.slot = s,
				.bytes = SLOT_BYTES,
				.flags = QOVL_SUBMIT_ASYNC | QOVL_SUBMIT_NONBLOCK,
			};
			if (ioctl(fd, QOVL_IOC_SUBMIT, &sub)) {
				if (errno == EAGAIN) {
					sub.flags = QOVL_SUBMIT_ASYNC;
					if (ioctl(fd, QOVL_IOC_SUBMIT, &sub)) {
						perror("QOVL_IOC_SUBMIT");
						break;
					}
				} else {
					perror("QOVL_IOC_SUBMIT");
					break;
				}
			}
			inflight_q[0] = inflight_q[1];
			inflight_q[1] = sub.seq_out;
			last_seq = sub.seq_out;
			if ((frame % 60) == 0) {
				struct timespec now;
				clock_gettime(CLOCK_MONOTONIC, &now);
				double dt = (now.tv_sec - t_rep.tv_sec) + (now.tv_nsec - t_rep.tv_nsec) * 1e-9;
				printf("MSI frames=%llu fps=%.2f\n", (unsigned long long)frame, 60.0 / (dt > 0 ? dt : 1e-6));
				fflush(stdout);
				t_rep = now;
			}
		}

		if (seconds > 0) {
			struct timespec now;
			clock_gettime(CLOCK_MONOTONIC, &now);
			if ((uint64_t)(now.tv_sec - t0.tv_sec) >= seconds) break;
		}

		if (!use_msi) {
			struct timespec nap = { .tv_sec = 0, .tv_nsec = 16666667L };
			nanosleep(&nap, NULL);
		}
	}

	if (use_msi && last_seq) {
		struct qovl_wait wt = { .target_seq = last_seq, .timeout_ms = 1000 };
		ioctl(fd, QOVL_IOC_WAIT, &wt);
	}

	int busy = 0;
	ioctl(fd, QOVL_IOC_FREE, &busy);
	munmap(fb_base, (size_t)ring.stride * ring.nslots);
	close(fd);
	return 0;
}
