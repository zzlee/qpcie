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
static void render(struct buffer *b, unsigned w, unsigned h, char id)
{
	static const uint8_t glyph[][7] = {
		{14,17,17,31,17,17,17},{30,17,17,30,17,17,30},{15,16,16,16,16,16,15},
		{30,17,17,17,17,17,30},{31,16,16,30,16,16,31}
	};
	unsigned s = h/12 < w/12 ? h/12 : w/12;
	if (!s) fail("mode too small");
	for (unsigned y = 0; y < h; y++) {
		uint8_t *row = b->data + (size_t)b->pitch*y;
		memset(row, 0, w*4);
		if (y < s || y >= 10*s) continue;
		for (unsigned x = s; x < 8*s; x++) {
			uint8_t *p = row + 4*x;
			unsigned gx = x/s-1, gy = y/s-1;
			bool ink = gx>=1 && gx<=5 && gy>=1 && gy<=7 &&
				(glyph[id-'A'][gy-1] & (1u<<(5-gx)));
			p[0]=255; p[1]=p[2]=ink ? 255 : 0; p[3]=ink ? 255 : 128;
		}
	}
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
	record("commit id=%c fb=%u",id,off ? 0 : c->buf[slot].fb);
}

static void flipped(int fd, unsigned seq, unsigned sec, unsigned usec, void *data)
{
	struct client *c=data;
	if (fd!=c->fd || c->pending<0) fail("unexpected flip event");
	c->front=c->pending==2 ? -1 : c->pending;
	c->pending=-1; c->shown=c->submitted;
	record("flip id=%c seq=%u drm_time=%u.%06u",c->shown,seq,sec,usec);
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
