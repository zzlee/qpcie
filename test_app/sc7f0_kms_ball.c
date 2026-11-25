/* Event-driven host client for the dedicated SC7F0 logical KMS output. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

enum { FLIP_MS = 5000, INPUT_MS = 30000 };
enum { FB, ROUTE, SX, SY, SW, SH, DX, DY, DW, DH, BLEND, ALPHA, NPROP };
static const char *const names[NPROP] = {"FB_ID","CRTC_ID","SRC_X","SRC_Y",
	"SRC_W","SRC_H","CRTC_X","CRTC_Y","CRTC_W","CRTC_H","pixel blend mode","alpha"};
struct buffer { uint32_t fb, pitch; uint8_t *data; };
struct client {
	int fd, front, pending;  /* -1 = none; pending 2 = disabling */
	char wanted, submitted, shown;
	uint32_t conn, crtc, plane, conn_route, active, mode_id, blob, p[NPROP];
	uint64_t coverage, alpha;
	drmModeModeInfo mode;
	bool modeset, primary;
	struct buffer buf[2];
	int64_t deadline;
};

static int64_t now(void)
{
	struct timespec t;
	if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock"); exit(1); }
	return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void record(const char *fmt, ...)
{
	va_list args;
	printf("mono_ms=%" PRId64 " ", now());
	va_start(args, fmt); vprintf(fmt, args); va_end(args);
	putchar('\n'); fflush(stdout);
}

static void fail(const char *msg)
{
	fprintf(stderr, "%s\n", msg); exit(1);
}

static void sysfail(const char *msg) { perror(msg); exit(1); }

static drmModePropertyPtr prop(int fd, uint32_t obj, uint32_t type,
			       const char *name, uint64_t *value)
{
	drmModeObjectPropertiesPtr list = drmModeObjectGetProperties(fd, obj, type);
	drmModePropertyPtr p = NULL;
	if (!list) sysfail("get properties");
	for (unsigned i = 0; i < list->count_props; i++) {
		p = drmModeGetProperty(fd, list->props[i]);
		if (!p) sysfail("get property");
		if (!strcmp(p->name, name)) {
			if (value) *value = list->prop_values[i];
			break;
		}
		drmModeFreeProperty(p); p = NULL;
	}
	drmModeFreeObjectProperties(list);
	return p;
}

static uint32_t required(int fd, uint32_t obj, uint32_t type, const char *name)
{
	drmModePropertyPtr p = prop(fd, obj, type, name, NULL);
	if (!p) { fprintf(stderr, "object %u missing %s\n", obj, name); exit(1); }
	uint32_t id = p->prop_id;
	drmModeFreeProperty(p); return id;
}

/* No property means the SC7F0 frontend has a fixed blend equation.
 * If exposed, straight alpha must be selectable (or already immutable). */
static bool straight_alpha(int fd, uint32_t plane, uint32_t *id, uint64_t *value)
{
	uint64_t current;
	drmModePropertyPtr p = prop(fd, plane, DRM_MODE_OBJECT_PLANE, names[BLEND], &current);
	*id = 0; *value = 0;
	if (!p) return true;
	bool ok = false;
	for (int i = 0; i < p->count_enums; i++) {
		if (strcmp(p->enums[i].name, "Coverage")) continue;
		*value = p->enums[i].value;
		if (p->flags & DRM_MODE_PROP_IMMUTABLE) ok = current == *value;
		else { *id = p->prop_id; ok = true; }
		break;
	}
	drmModeFreeProperty(p); return ok;
}

static void discover(struct client *c)
{
	int fd = c->fd;
	uint64_t cap;
	if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) sysfail("enable atomic");
	if (drmGetCap(fd, DRM_CAP_DUMB_BUFFER, &cap) || !cap) fail("dumb buffers unavailable");
	drmModeResPtr r = drmModeGetResources(fd);
	if (!r) sysfail("get KMS resources");
	drmModeConnectorPtr out = NULL;
	for (int i = 0; i < r->count_connectors; i++) {
		drmModeConnectorPtr k = drmModeGetConnector(fd, r->connectors[i]);
		if (!k) sysfail("get connector");
		if (k->connection != DRM_MODE_CONNECTED || !k->count_modes)
			drmModeFreeConnector(k);
		else if (out) fail("expected one connected logical output on dedicated node");
		else out = k;
	}
	if (!out) fail("no connected logical output with modes");
	c->conn = out->connector_id;
	uint32_t mask = 0, current = 0;
	for (int i = 0; i < out->count_encoders; i++) {
		drmModeEncoderPtr e = drmModeGetEncoder(fd, out->encoders[i]);
		if (!e) sysfail("get encoder");
		mask |= e->possible_crtcs;
		if (e->encoder_id == out->encoder_id) current = e->crtc_id;
		drmModeFreeEncoder(e);
	}
	drmModePlaneResPtr planes = drmModeGetPlaneResources(fd);
	if (!planes) sysfail("get planes");
	int best = -1;
	for (int i = 0; i < r->count_crtcs && i < 32; i++) {
		if (!(mask & (1u << i)) || (current && current != r->crtcs[i])) continue;
		for (unsigned j = 0; j < planes->count_planes; j++) {
			drmModePlanePtr p = drmModeGetPlane(fd, planes->planes[j]);
			if (!p) sysfail("get plane");
			uint64_t kind = DRM_PLANE_TYPE_CURSOR;
			drmModePropertyPtr t = prop(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "type", &kind);
			drmModeFreeProperty(t);
			int score = kind == DRM_PLANE_TYPE_OVERLAY ? 2 :
				kind == DRM_PLANE_TYPE_PRIMARY ? 1 : -1;
			for (unsigned f = 0; score > best && f < p->count_formats; f++) {
				if (p->formats[f] == DRM_FORMAT_ABGR8888 &&
				    (p->possible_crtcs & (1u << i)) &&
				    (!p->crtc_id || p->crtc_id == r->crtcs[i])) {
					uint32_t key; uint64_t value;
					if (!straight_alpha(fd, p->plane_id, &key, &value)) break;
					c->p[BLEND] = key; c->coverage = value;
					best = score; c->plane = p->plane_id; c->crtc = r->crtcs[i];
					c->primary = kind == DRM_PLANE_TYPE_PRIMARY;
				}
			}
			drmModeFreePlane(p);
		}
	}
	if (best < 0) fail("no routable ABGR8888 graphics plane");
	drmModeCrtcPtr cr = drmModeGetCrtc(fd, c->crtc);
	if (!cr) sysfail("get CRTC");
	c->modeset = !current || !cr->mode_valid;
	c->mode = cr->mode;
	if (c->modeset) {
		c->mode = out->modes[0];
		for (int i = 0; i < out->count_modes; i++)
			if (out->modes[i].type & DRM_MODE_TYPE_PREFERRED) { c->mode = out->modes[i]; break; }
		if (drmModeCreatePropertyBlob(fd, &c->mode, sizeof(c->mode), &c->blob))
			sysfail("create mode blob");
	}
	drmModeFreeCrtc(cr); drmModeFreeConnector(out);
	drmModeFreePlaneResources(planes); drmModeFreeResources(r);
	c->conn_route = required(fd, c->conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
	c->active = required(fd, c->crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE");
	c->mode_id = required(fd, c->crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
	for (int i = 0; i < BLEND; i++)
		c->p[i] = required(fd, c->plane, DRM_MODE_OBJECT_PLANE, names[i]);
	drmModePropertyPtr b = prop(fd, c->plane, DRM_MODE_OBJECT_PLANE, names[ALPHA], NULL);
	if (b) {
		if (b->count_values != 2) fail("unexpected alpha range");
		c->p[ALPHA] = b->prop_id; c->alpha = b->values[1]; drmModeFreeProperty(b);
	}
	record("route connector=%u crtc=%u plane=%u mode=%ux%u modeset=%d blend=%s",
	       c->conn,c->crtc,c->plane,c->mode.hdisplay,c->mode.vdisplay,c->modeset,
	       c->p[BLEND] ? "Coverage" : "fixed-hardware");
}

static void allocate(struct client *c, struct buffer *b)
{
	struct drm_mode_create_dumb d = {.width=c->mode.hdisplay, .height=c->mode.vdisplay, .bpp=32};
	if (drmIoctl(c->fd, DRM_IOCTL_MODE_CREATE_DUMB, &d)) sysfail("create dumb");
	if (d.pitch < d.width * 4 || d.size < (uint64_t)d.pitch * d.height || d.size > SIZE_MAX)
		fail("invalid dumb geometry");
	uint32_t handles[4] = {d.handle}, pitches[4] = {d.pitch}, offsets[4] = {0};
	if (drmModeAddFB2(c->fd,d.width,d.height,DRM_FORMAT_ABGR8888,
			  handles,pitches,offsets,&b->fb,0)) sysfail("add ABGR8888 FB");
	struct drm_mode_map_dumb m = {.handle=d.handle};
	if (drmIoctl(c->fd, DRM_IOCTL_MODE_MAP_DUMB, &m)) sysfail("map dumb");
	b->pitch = d.pitch;
	b->data = mmap(NULL,d.size,PROT_READ|PROT_WRITE,MAP_SHARED,c->fd,m.offset);
	if (b->data == MAP_FAILED) sysfail("mmap");
}

/* Big high-contrast IDs over a translucent saturated red panel. Outside the
 * panel the overlay is transparent, exposing the independent HDMI background. */
#define W 3840U
#define H 2160U
#define STRIDE (W * 4U)
#define SLOT_BYTES (STRIDE * H)
#define BAND_Y0 1920U

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


static unsigned long serial=0;static uint8_t*fb;
static void render(struct buffer*b,unsigned w,unsigned h,char id){(void)id;if(w!=W||h!=H||b->pitch!=STRIDE)fail("unexpected geometry");
	struct pen banner_bg = { 10, 18, 36, 205 };
	struct pen cyan      = { 0, 220, 255, 255 };
	struct pen white     = { 255, 255, 255, 255 };
	struct pen muted     = { 170, 200, 230, 255 };


if(!serial){fb=malloc(SLOT_BYTES);if(!fb)sysfail("shadow");
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
	static int x = 400, y = 400;
	static int vx = 14, vy = 10;
	static int last_x[4] = {0}, last_y[4] = {0}, has_last[4] = {0};
	static uint64_t bounces = 0, frame = 0;
	struct pen transparent = { 0, 0, 0, 0 };

		if (has_last[0]) {
			int x0 = last_x[0] - rad - 2; if (x0 < 0) x0 = 0;
			int y0 = last_y[0] - rad - 2; if (y0 < 0) y0 = 0;
			int x1 = last_x[0] + rad + 2; if (x1 > (int)W) x1 = W;
			int y1 = last_y[0] + rad + 2; if (y1 > (int)BAND_Y0) y1 = BAND_Y0;
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

		last_x[0] = x; last_y[0] = y; has_last[0] = 1;
		frame++;

memcpy(b->data,fb,SLOT_BYTES);__sync_synchronize();serial=frame;
}
static void add(drmModeAtomicReqPtr req, uint32_t object, uint32_t key, uint64_t value)
{
	if (drmModeAtomicAddProperty(req,object,key,value)<0) sysfail("atomic add");
}

static void submit(struct client *c)
{
	if (c->pending >= 0 || c->wanted == c->shown) return;
	char id = c->wanted;
	bool off = id == '-', first = !c->shown;
	int slot = off ? 2 : c->front == 0 ? 1 : 0;
	if (!off) render(&c->buf[slot],c->mode.hdisplay,c->mode.vdisplay,id);
	drmModeAtomicReqPtr req = drmModeAtomicAlloc();
	if (!req) sysfail("alloc request");
	uint32_t flags = DRM_MODE_ATOMIC_NONBLOCK | DRM_MODE_PAGE_FLIP_EVENT;
	if ((first && c->modeset) || (off && (c->modeset || c->primary))) {
		flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;
		add(req,c->conn,c->conn_route,off ? 0 : c->crtc);
		add(req,c->crtc,c->active,!off);
		add(req,c->crtc,c->mode_id,off ? 0 : c->blob);
	}
	add(req,c->plane,c->p[FB],off ? 0 : c->buf[slot].fb);
	if (first || off) add(req,c->plane,c->p[ROUTE],off ? 0 : c->crtc);
	if (first) {
		uint64_t w=c->mode.hdisplay, h=c->mode.vdisplay;
		uint64_t rect[] = {0,0,w<<16,h<<16,0,0,w,h,c->coverage,c->alpha};
		for (int i=SX; i<NPROP; i++) if (c->p[i]) add(req,c->plane,c->p[i],rect[i-SX]);
	}
	if (drmModeAtomicCommit(c->fd,req,flags,c)) sysfail("atomic commit");
	drmModeAtomicFree(req);
	c->pending=slot; c->submitted=id; c->deadline=now()+FLIP_MS;
	record("commit id=%c fb=%u serial=%lu",id,off ? 0 : c->buf[slot].fb,serial);
}

static void flipped(int fd, unsigned seq, unsigned sec, unsigned usec, void *data)
{
	struct client *c=data;
	if (fd!=c->fd || c->pending<0) fail("unexpected flip event");
	c->front=c->pending==2 ? -1 : c->pending;
	c->pending=-1; c->shown=c->submitted;
	record("flip id=%c seq=%u drm_time=%u.%06u serial=%lu",c->shown,seq,sec,usec,serial);
}

/* One slot for the latest input, independent of both mapped buffers. */
static void input(struct client *c, char id)
{
	c->wanted=id;
	record("input id=%c pending=%c",id,c->pending<0 ? '.' : c->submitted);
}

static void events(struct client *c, bool keyboard, int64_t until)
{
	drmEventContext ctx = {.version=2,.page_flip_handler=flipped};
	struct pollfd f[] = {{c->fd,POLLIN,0},{STDIN_FILENO,POLLIN,0}};
	if (c->pending>=0 && (until<0 || c->deadline<until)) until=c->deadline;
	int64_t left=until<0 ? -1 : until-now();
	int rc=poll(f,keyboard ? 2 : 1,until<0 ? -1 : left>0 ? (int)left : 0);
	if (rc<0) { if (errno==EINTR) return; sysfail("poll"); }
	if (f[0].revents & (POLLERR|POLLNVAL|POLLHUP)) fail("lost DRM fd");
	if (f[0].revents & POLLIN)
		if (drmHandleEvent(c->fd,&ctx)) sysfail("handle event");
	if (c->pending>=0 && now()>=c->deadline) {
		record("timeout id=%c",c->submitted); fail("flip timed out; no reuse or retry");
	}
	if (keyboard && f[1].revents) {
		char buf[256];
		ssize_t n=read(STDIN_FILENO,buf,sizeof(buf));
		if (n<0) { if (errno==EINTR) return; sysfail("stdin"); }
		if (!n) input(c,'-');
		for (ssize_t i=0; i<n; i++) {
			if (buf[i]=='q') { input(c,'-'); break; }
			if (buf[i]>='A' && buf[i]<='E') input(c,buf[i]);
		}
	}
}

static void drain(struct client *c)
{
	while (c->pending>=0 || c->wanted!=c->shown) {
		submit(c);
		if (c->pending>=0) events(c,false,-1);
	}
}

static void hold(struct client *c, int ms)
{
	int64_t end=now()+ms;
	record("hold-start id=%c ms=%d",c->shown,ms);
	while (now()<end) events(c,false,end);
	record("hold-end id=%c",c->shown);
}

static void usage(void)
{
	fail("usage: sc7f0_kms DEVICE [--script|--manual IDLE_MS]  (live stdin: A-E, q)");
}

int main(int argc, char **argv)
{
	if(argc==3 && !strcmp(argv[2],"ball60")){struct client c={.front=-1,.pending=-1};c.fd=open(argv[1],O_RDWR|O_CLOEXEC);if(c.fd<0)sysfail("drm");discover(&c);for(int i=0;i<2;i++)allocate(&c,&c.buf[i]);int64_t end=now()+607000;do{input(&c,c.shown=='A'?'B':'A');drain(&c);}while(now()<end);input(&c,'-');drain(&c);free(fb);close(c.fd);return 0;}
	if (argc!=2 && argc!=4) usage();
	bool manual=false; long idle=0;
	if (argc==4) {
		manual=!strcmp(argv[2],"--manual");
		if (!manual && strcmp(argv[2],"--script")) usage();
		char *end; idle=strtol(argv[3],&end,10);
		if (*end || idle<1 || idle>600000) usage();
	}
	struct client c={.front=-1,.pending=-1};
	c.fd=open(argv[1],O_RDWR|O_CLOEXEC);
	if (c.fd<0) sysfail(argv[1]);
	discover(&c);
	for (int i=0; i<2; i++) allocate(&c,&c.buf[i]);
	input(&c,'A'); drain(&c);
	if (argc==2) {
		while (c.shown!='-') {
			events(&c,c.wanted!='-',-1);
			submit(&c);
		}
	} else {
		hold(&c,idle);
		if (manual) {
			record("enter B then Return within 30s");
			int64_t end=now()+INPUT_MS;
			while (c.wanted=='A' && now()<end) events(&c,true,end);
			if (c.wanted!='B') fail("manual B missing");
		} else input(&c,'B');
		drain(&c); hold(&c,idle);
		input(&c,'C'); submit(&c);
		input(&c,'D'); input(&c,'E'); drain(&c);
		hold(&c,idle); input(&c,'-'); drain(&c);
	}
	/* One-shot process: file release and process exit drop FBs, handles,
	 * blobs and mappings. On ambiguous errors never write or resubmit. */
	close(c.fd);
	return 0;
}
